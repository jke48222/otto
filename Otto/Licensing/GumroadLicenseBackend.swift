//
//  GumroadLicenseBackend.swift
//  Otto
//
//  Gumroad license keys (§14.7). Gumroad has no activations, so seats are counted with its use counter: a key is
//  counted once per Mac (the counted-hash store remembers it), a license holds 3 × quantity seats, and background
//  checks never count. Records carry their own product id; when it differs from this build's, a "gone" answer
//  never reads as gone. Deactivation is local only: freeing a seat needs the seller's token.
//

#if OTTO_LICENSING
import CryptoKit
import Foundation
import os

struct GumroadLicenseBackend: LicenseBackend {
    let kind: LicenseBackendKind = .gumroad

    private let configuration: GumroadConfiguration
    private let transport: LicenseHTTPTransport
    private let counted: LicenseStoring
    private let userAgent: String

    init(configuration: GumroadConfiguration, transport: LicenseHTTPTransport, counted: LicenseStoring,
         userAgent: String) {
        self.configuration = configuration
        self.transport = transport
        self.counted = counted
        self.userAgent = userAgent
    }

    /// SHA-256 hex of "<productID>|<key>": what the counted-hash store remembers instead of the key.
    static func countedHash(productID: String, key: String) -> String {
        SHA256.hash(data: Data("\(productID)|\(key)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Activate

    func activate(key: String, label: String, existing: LicenseRecord?) async -> Result<LicenseRecord, LicenseActivationError> {
        let productID = configuration.productID

        // 1. Look without counting.
        let check: GumroadAPI.Verification
        switch await verify(key: key, productID: productID, increment: false) {
        case .success(let verification): check = verification
        case .failure(let error): return .failure(error)
        }

        // 2. A key already counted on this Mac is free to enter again.
        let hash = Self.countedHash(productID: productID, key: key)
        let countedKeys = counted.loadGumroadCounted()
        if case .success(let keys) = countedKeys, keys?.hashes.contains(hash) == true {
            Self.log("activate", outcome: "activated (already counted on this Mac)")
            return .success(record(key: key, productID: productID, verification: check))
        }

        // 3. No seat left.
        guard check.uses < check.seatLimit else {
            Self.log("activate", outcome: "seatLimitReached")
            return .failure(.seatLimitReached(limit: check.seatLimit))
        }

        // 4. Count this Mac, then remember that it was counted.
        let final: GumroadAPI.Verification
        switch await verify(key: key, productID: productID, increment: true) {
        case .success(let verification): final = verification
        case .failure(let error): return .failure(error)
        }
        remember(hash, loaded: countedKeys)
        Self.log("activate", outcome: "activated")
        return .success(record(key: key, productID: productID, verification: final))
    }

    /// One verify during activation, mapped to the activation's errors.
    private func verify(key: String, productID: String,
                        increment: Bool) async -> Result<GumroadAPI.Verification, LicenseActivationError> {
        switch await send(key: key, productID: productID, increment: increment) {
        case .verified(let verification):
            if verification.goneReason != nil {
                Self.log("activate", outcome: "keyNotActive")
                return .failure(.keyNotActive)
            }
            return .success(verification)
        case .notFound:
            return .failure(.keyNotFound)
        case .productRejected:
            return .failure(.unavailable(.misconfigured(GumroadAPI.productRejectedDetail)))
        case .unavailable(let reason):
            return .failure(.unavailable(reason))
        }
    }

    private func record(key: String, productID: String, verification: GumroadAPI.Verification) -> LicenseRecord {
        // Provisional: LicenseController re-stamps these with its effectiveNow (§14.6).
        let now = Date()
        return LicenseRecord(
            schema: LicenseRecord.currentSchema,
            backend: .gumroad,
            apiHost: GumroadAPI.host,
            organizationID: nil,
            benefitID: nil,
            gumroadProductID: productID,
            key: key,
            licenseKeyID: nil,
            activationID: nil,
            label: "",
            displayKey: LicenseKeyRouter.displayKey(for: key),
            seatLimit: verification.seatLimit,
            activatedAt: now,
            lastValidatedAt: now,
            lastAttemptAt: now,
            pendingRevocation: nil
        )
    }

    /// Adds the hash to the counted store (sorted, unique). An unreadable store is never overwritten, so a Mac
    /// whose store can't be read may count the same key again on a later activation.
    private func remember(_ hash: String, loaded: Result<GumroadCountedKeys?, LicenseStoreError>) {
        guard case .success(let existing) = loaded else {
            Self.logger.error("Gumroad: the counted-keys item is unreadable, so this activation isn't remembered")
            return
        }
        let hashes = Set((existing?.hashes ?? []) + [hash]).sorted()
        do {
            try counted.saveGumroadCounted(GumroadCountedKeys(schema: GumroadCountedKeys.currentSchema, hashes: hashes))
        } catch {
            Self.logger.error("Gumroad: saving the counted keys failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Validate

    func validate(_ record: LicenseRecord) async -> LicenseCheckOutcome {
        guard record.backend == .gumroad, record.apiHost == GumroadAPI.host,
              let productID = record.gumroadProductID else {
            Self.logger.fault("Gumroad validate: the record belongs to \(record.apiHost, privacy: .public) or is incomplete; nothing sent")
            return .unavailable(.recordMismatch)
        }
        let mismatched = productID != configuration.productID
        switch await send(key: record.key, productID: productID, increment: false) {
        case .verified(let verification):
            if let reason = verification.goneReason {
                return countsAsGone(mismatched: mismatched) ? .gone(reason) : .unavailable(.recordMismatch)
            }
            return .valid(LicenseValidation(seatLimit: verification.seatLimit, displayKey: nil))
        case .notFound:
            return countsAsGone(mismatched: mismatched) ? .gone(.disabled) : .unavailable(.recordMismatch)
        case .productRejected:
            return .unavailable(.misconfigured(GumroadAPI.productRejectedDetail))
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }

    /// A "gone" answer counts only when the record's product id is this build's (a wrong-but-present product id
    /// answers the same 404 as a disabled key).
    private func countsAsGone(mismatched: Bool) -> Bool {
        guard mismatched else { return true }
        Self.logger.fault("Gumroad validate said gone for a record whose product id differs from this build's; kept as recordMismatch")
        return false
    }

    // MARK: - Deactivate

    /// Local only: the seat and its hash stay counted; support frees seats with the seller's token.
    func deactivate(_ record: LicenseRecord) async -> LicenseDeactivationOutcome {
        Self.log("deactivate", outcome: "localOnly")
        return .localOnly
    }

    // MARK: - Transport

    private func send(key: String, productID: String, increment: Bool) async -> GumroadAPI.Answer {
        guard let request = GumroadAPI.verifyRequest(key: key, productID: productID, incrementUsesCount: increment,
                                                     userAgent: userAgent) else {
            Self.logger.fault("Gumroad verify: no request could be built")
            return .unavailable(.misconfigured("the Gumroad endpoint is not valid"))
        }
        do {
            let response = try await transport.send(request)
            let answer = GumroadAPI.classify(status: response.status, headers: response.headers, body: response.body)
            Self.logger.info("Gumroad verify (count \(increment, privacy: .public)): HTTP \(response.status, privacy: .public)")
            if case .productRejected = answer {
                Self.logger.fault("Gumroad rejected the product id (HTTP \(response.status, privacy: .public))")
            }
            return answer
        } catch {
            let reason = LicenseBackends.unavailableReason(for: error as? LicenseTransportError ?? .other("unknown"))
            Self.logger.info("Gumroad verify (count \(increment, privacy: .public)): \(LicenseBackends.logName(reason), privacy: .public)")
            return .unavailable(reason)
        }
    }

    private static func log(_ operation: String, outcome: String) {
        logger.info("Gumroad \(operation, privacy: .public): \(outcome, privacy: .public)")
    }

    private static let logger = LicenseBackends.logger
}
#endif
