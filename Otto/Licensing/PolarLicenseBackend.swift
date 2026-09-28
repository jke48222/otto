//
//  PolarLicenseBackend.swift
//  Otto
//
//  Polar license keys (§14.6): activation stamps the record with this build's host, organization and benefit;
//  validate and deactivate always send the record's own host and IDs. A record whose IDs differ from the build's
//  can still read as valid but never as gone, and a record from another host is never sent anywhere. Only a
//  versioned 404 ResourceNotFound is definitive; any other 404 gets one retry without the version pin.
//

#if OTTO_LICENSING
import Foundation
import os

struct PolarLicenseBackend: LicenseBackend {
    let kind: LicenseBackendKind = .polar

    private let configuration: PolarConfiguration
    private let transport: LicenseHTTPTransport
    private let userAgent: String

    init(configuration: PolarConfiguration, transport: LicenseHTTPTransport, userAgent: String) {
        self.configuration = configuration
        self.transport = transport
        self.userAgent = userAgent
    }

    // MARK: - Activate

    func activate(key: String, label: String, existing: LicenseRecord?) async -> Result<LicenseRecord, LicenseActivationError> {
        if let existing, existing.backend == .polar, let rekeyed = await rekey(key: key, existing: existing) {
            return .success(rekeyed)
        }

        let fields = PolarAPI.activateFields(key: key, label: label, organizationID: configuration.organizationID)
        switch await send(.activate, host: configuration.apiHost, fields: fields) {
        case .success(let body):
            guard let activation = PolarAPI.decodeActivation(body) else {
                return .failure(.unavailable(.unexpectedResponse(status: 200)))
            }
            return await finishActivation(activation, key: key, label: label)
        case .notFound:
            return .failure(.keyNotFound)
        case .notPermitted:
            return .failure(await explainNotPermitted(key: key))
        case .requestRejected:
            return .failure(.malformedKey)
        case .unavailable(let reason):
            return .failure(.unavailable(reason))
        }
    }

    /// A key rotated in Polar's portal keeps its activations, so the new key is validated on this Mac's existing
    /// activation with the existing record's IDs. nil means "activate normally".
    private func rekey(key: String, existing: LicenseRecord) async -> LicenseRecord? {
        guard existing.apiHost == configuration.apiHost, let activationID = existing.activationID,
              let organizationID = existing.organizationID, let benefitID = existing.benefitID else { return nil }
        let fields = PolarAPI.validateFields(key: key, activationID: activationID, organizationID: organizationID,
                                             benefitID: benefitID)
        guard case .success(let body) = await send(.validate, host: existing.apiHost, fields: fields),
              let validation = PolarAPI.decodeValidation(body),
              validation.benefitID == benefitID, validation.status == PolarAPI.grantedStatus else { return nil }
        let now = Date()
        var record = existing
        record.key = key
        if let licenseKeyID = validation.licenseKeyID { record.licenseKeyID = licenseKeyID }
        record.displayKey = validation.displayKey ?? LicenseKeyRouter.displayKey(for: key)
        if let limit = validation.limitActivations { record.seatLimit = limit }
        record.lastValidatedAt = now
        record.lastAttemptAt = now
        record.pendingRevocation = nil
        Self.log(.activate, outcome: "rekeyed")
        return record
    }

    private func finishActivation(_ activation: PolarAPI.Activation, key: String,
                                  label: String) async -> Result<LicenseRecord, LicenseActivationError> {
        guard activation.benefitID == configuration.benefitID, activation.status == PolarAPI.grantedStatus else {
            // The key activated, but not as Otto's license: give the seat back (best effort) before refusing it.
            let fields = PolarAPI.deactivateFields(key: key, activationID: activation.activationID,
                                                   organizationID: configuration.organizationID)
            _ = await send(.deactivate, host: configuration.apiHost, fields: fields)
            let wrongProduct = activation.benefitID != configuration.benefitID
            Self.log(.activate, outcome: wrongProduct ? "wrongProduct" : "keyNotActive")
            return .failure(wrongProduct ? .wrongProduct : .keyNotActive)
        }
        let now = Date()
        let record = LicenseRecord(
            schema: LicenseRecord.currentSchema,
            backend: .polar,
            apiHost: configuration.apiHost,
            organizationID: configuration.organizationID,
            benefitID: configuration.benefitID,
            gumroadProductID: nil,
            key: key,
            licenseKeyID: activation.licenseKeyID,
            activationID: activation.activationID,
            label: label,
            displayKey: activation.displayKey ?? LicenseKeyRouter.displayKey(for: key),
            seatLimit: activation.limitActivations,
            activatedAt: now,
            lastValidatedAt: now,
            lastAttemptAt: now,
            pendingRevocation: nil
        )
        Self.log(.activate, outcome: "activated")
        return .success(record)
    }

    /// Polar refuses an activation with 403 NotPermitted when the seats are used up, when the key is no longer
    /// granted, and when the benefit has no activation limit at all. One validate without an activation tells
    /// them apart.
    private func explainNotPermitted(key: String) async -> LicenseActivationError {
        let fields = PolarAPI.validateFields(key: key, activationID: nil, organizationID: configuration.organizationID,
                                             benefitID: configuration.benefitID)
        switch await send(.validate, host: configuration.apiHost, fields: fields) {
        case .success(let body):
            guard let validation = PolarAPI.decodeValidation(body) else {
                return .unavailable(.unexpectedResponse(status: 200))
            }
            guard validation.benefitID == configuration.benefitID else { return .wrongProduct }
            guard validation.status == PolarAPI.grantedStatus else { return .keyNotActive }
            guard let limit = validation.limitActivations else {
                Self.logger.fault("Polar refused an activation because the benefit has no activation limit; set one in the Polar dashboard")
                return .unavailable(.misconfigured("Polar benefit has no activation limit"))
            }
            return .seatLimitReached(limit: limit)
        case .notFound:
            return .keyNotActive
        case .notPermitted:
            return .unavailable(.unexpectedResponse(status: 403))
        case .requestRejected:
            Self.logger.fault("Polar rejected Otto's validate request (422)")
            return .unavailable(.unexpectedResponse(status: 422))
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }

    // MARK: - Validate

    func validate(_ record: LicenseRecord) async -> LicenseCheckOutcome {
        guard let target = target(for: record, operation: .validate), let activationID = record.activationID else {
            return .unavailable(.recordMismatch)
        }
        let fields = PolarAPI.validateFields(key: record.key, activationID: activationID,
                                             organizationID: target.organizationID, benefitID: target.benefitID)
        switch await send(.validate, host: record.apiHost, fields: fields) {
        case .success(let body):
            guard let validation = PolarAPI.decodeValidation(body) else {
                return .unavailable(.unexpectedResponse(status: 200))
            }
            guard validation.benefitID == target.benefitID, validation.status == PolarAPI.grantedStatus else {
                // The API doesn't answer this way; treated as definitive, like a versioned 404.
                return countsAsGone(mismatched: target.mismatched, operation: .validate)
                    ? .gone(.notFound) : .unavailable(.recordMismatch)
            }
            return .valid(LicenseValidation(seatLimit: validation.limitActivations, displayKey: validation.displayKey))
        case .notFound:
            return countsAsGone(mismatched: target.mismatched, operation: .validate)
                ? .gone(.notFound) : .unavailable(.recordMismatch)
        case .notPermitted:
            return .unavailable(.unexpectedResponse(status: 403))
        case .requestRejected:
            Self.logger.fault("Polar rejected Otto's validate request (422)")
            return .unavailable(.unexpectedResponse(status: 422))
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }

    // MARK: - Deactivate

    func deactivate(_ record: LicenseRecord) async -> LicenseDeactivationOutcome {
        guard let target = target(for: record, operation: .deactivate), let activationID = record.activationID else {
            return .unavailable(.recordMismatch)
        }
        let fields = PolarAPI.deactivateFields(key: record.key, activationID: activationID,
                                               organizationID: target.organizationID)
        switch await send(.deactivate, host: record.apiHost, fields: fields) {
        case .success:
            return .freedSeat
        case .notFound:
            return countsAsGone(mismatched: target.mismatched, operation: .deactivate)
                ? .alreadyGone : .unavailable(.recordMismatch)
        case .notPermitted:
            return .unavailable(.unexpectedResponse(status: 403))
        case .requestRejected:
            Self.logger.fault("Polar rejected Otto's deactivate request (422)")
            return .unavailable(.unexpectedResponse(status: 422))
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }

    // MARK: - Records carry their own IDs

    private struct Target {
        let organizationID: String
        let benefitID: String
        /// The record's organization or benefit differs from this build's configuration.
        let mismatched: Bool
    }

    /// The IDs a check sends: always the record's. nil (send nothing) when the record isn't a complete Polar record
    /// or belongs to another host.
    private func target(for record: LicenseRecord, operation: PolarAPI.Operation) -> Target? {
        guard record.backend == .polar, let organizationID = record.organizationID,
              let benefitID = record.benefitID else {
            Self.logger.fault("Polar \(operation.rawValue, privacy: .public): the license record is incomplete; nothing sent")
            return nil
        }
        guard record.apiHost == configuration.apiHost else {
            Self.logger.fault("Polar \(operation.rawValue, privacy: .public): the record belongs to \(record.apiHost, privacy: .public), this build to \(configuration.apiHost, privacy: .public); nothing sent")
            return nil
        }
        let mismatched = organizationID != configuration.organizationID || benefitID != configuration.benefitID
        return Target(organizationID: organizationID, benefitID: benefitID, mismatched: mismatched)
    }

    /// A definitive "gone" counts only when the record's IDs are this build's; otherwise the answer may be about
    /// the build's IDs, so it never moves a license toward revocation.
    private func countsAsGone(mismatched: Bool, operation: PolarAPI.Operation) -> Bool {
        guard mismatched else { return true }
        Self.logger.fault("Polar \(operation.rawValue, privacy: .public) said gone for a record whose organization or benefit differs from this build's; kept as recordMismatch")
        return false
    }

    // MARK: - Transport

    private enum Reply {
        case success(Data)
        case notFound
        case notPermitted
        case requestRejected
        case unavailable(LicenseUnavailableReason)
    }

    /// Sends pinned to PolarConfiguration.apiVersion; a 404 that isn't a versioned ResourceNotFound gets exactly
    /// one retry without the pin (Polar then answers with its Current version), and a second such 404 reads as
    /// versionRefused.
    private func send(_ operation: PolarAPI.Operation, host: String, fields: [String: String]) async -> Reply {
        let first = await exchange(operation, host: host, fields: fields, pinned: true)
        guard case .unversionedNotFound = first else { return reply(first) }
        let retry = await exchange(operation, host: host, fields: fields, pinned: false)
        if case .unversionedNotFound = retry { return .unavailable(.versionRefused) }
        return reply(retry)
    }

    private func exchange(_ operation: PolarAPI.Operation, host: String, fields: [String: String],
                          pinned: Bool) async -> PolarAPI.Answer {
        guard let request = PolarAPI.request(operation, host: host, fields: fields, userAgent: userAgent,
                                             pinned: pinned) else {
            Self.logger.fault("Polar \(operation.rawValue, privacy: .public): no request could be built for host \(host, privacy: .public)")
            return .unavailable(.misconfigured("the Polar API host is not valid"))
        }
        let pin = pinned ? PolarConfiguration.apiVersion : "none"
        do {
            let response = try await transport.send(request)
            let answer = PolarAPI.classify(status: response.status, headers: response.headers, body: response.body)
            Self.logger.info("Polar \(operation.rawValue, privacy: .public): HTTP \(response.status, privacy: .public), pinned \(pin, privacy: .public), polar-version echoed \(PolarAPI.echoedVersion(response.headers), privacy: .public)")
            return answer
        } catch {
            let reason = LicenseBackends.unavailableReason(for: error as? LicenseTransportError ?? .other("unknown"))
            Self.logger.info("Polar \(operation.rawValue, privacy: .public): \(LicenseBackends.logName(reason), privacy: .public), pinned \(pin, privacy: .public)")
            return .unavailable(reason)
        }
    }

    private func reply(_ answer: PolarAPI.Answer) -> Reply {
        switch answer {
        case .success(let body): return .success(body)
        case .notFound: return .notFound
        case .unversionedNotFound: return .unavailable(.versionRefused)
        case .notPermitted: return .notPermitted
        case .requestRejected: return .requestRejected
        case .unavailable(let reason): return .unavailable(reason)
        }
    }

    private static func log(_ operation: PolarAPI.Operation, outcome: String) {
        logger.info("Polar \(operation.rawValue, privacy: .public): \(outcome, privacy: .public)")
    }

    private static let logger = LicenseBackends.logger
}
#endif
