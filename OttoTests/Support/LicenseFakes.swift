//
//  LicenseFakes.swift
//  OttoTests
//
//  Test doubles and fixtures for the paid build's licensing: a scripted backend, a transport keyed by URL, a store
//  with injectable failures, a manually advanced scheduler, and the Polar and Gumroad answers the backends are
//  tested against. Nothing here touches the network, the Keychain or a clock. Read-only after WMa (§14.4.6).
//

#if OTTO_LICENSING
import Foundation
import os
@testable import Otto

// MARK: - Backend

/// Lock-protected fakes (@unchecked Sendable). Nothing here touches the network, the Keychain or a clock.
final class FakeLicenseBackend: LicenseBackend, @unchecked Sendable {
    private struct State {
        var activations: [Result<LicenseRecord, LicenseActivationError>] = []
        var validations: [LicenseCheckOutcome] = []
        var deactivations: [LicenseDeactivationOutcome] = []
        var calls: [String] = []
    }

    let kind: LicenseBackendKind
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(kind: LicenseBackendKind) {
        self.kind = kind
    }

    /// Scripted answers, consumed in order. With nothing left: activate → .failure(.unavailable(.offline)),
    /// validate → .unavailable(.offline), deactivate → .unavailable(.offline).
    func scriptActivate(_ results: [Result<LicenseRecord, LicenseActivationError>]) {
        state.withLock { $0.activations.append(contentsOf: results) }
    }

    func scriptValidate(_ outcomes: [LicenseCheckOutcome]) {
        state.withLock { $0.validations.append(contentsOf: outcomes) }
    }

    func scriptDeactivate(_ outcomes: [LicenseDeactivationOutcome]) {
        state.withLock { $0.deactivations.append(contentsOf: outcomes) }
    }

    /// "activate:<key>|<label>|<existing activationID or nil>", "validate:<activationID or displayKey>", "deactivate:…"
    var calls: [String] { state.withLock { $0.calls } }

    func activate(key: String, label: String, existing: LicenseRecord?) async -> Result<LicenseRecord, LicenseActivationError> {
        state.withLock { state in
            state.calls.append("activate:\(key)|\(label)|\(existing?.activationID ?? "nil")")
            return state.activations.isEmpty ? .failure(.unavailable(.offline)) : state.activations.removeFirst()
        }
    }

    func validate(_ record: LicenseRecord) async -> LicenseCheckOutcome {
        state.withLock { state in
            state.calls.append("validate:\(Self.identity(of: record))")
            return state.validations.isEmpty ? .unavailable(.offline) : state.validations.removeFirst()
        }
    }

    func deactivate(_ record: LicenseRecord) async -> LicenseDeactivationOutcome {
        state.withLock { state in
            state.calls.append("deactivate:\(Self.identity(of: record))")
            return state.deactivations.isEmpty ? .unavailable(.offline) : state.deactivations.removeFirst()
        }
    }

    private static func identity(of record: LicenseRecord) -> String {
        record.activationID ?? record.displayKey
    }
}

// MARK: - Transport

final class FakeLicenseTransport: LicenseHTTPTransport, @unchecked Sendable {
    private struct State {
        var answers: [String: [Result<LicenseHTTPResponse, LicenseTransportError>]] = [:]
        var requests: [LicenseHTTPRequest] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// Answers per absolute URL string, consumed in order; a URL with nothing queued throws LicenseTransportError.offline.
    func enqueue(_ url: String, _ answer: Result<LicenseHTTPResponse, LicenseTransportError>) {
        state.withLock { $0.answers[url, default: []].append(answer) }
    }

    var requests: [LicenseHTTPRequest] { state.withLock { $0.requests } }

    func send(_ request: LicenseHTTPRequest) async throws -> LicenseHTTPResponse {
        let answer = state.withLock { state -> Result<LicenseHTTPResponse, LicenseTransportError> in
            state.requests.append(request)
            let url = request.url.absoluteString
            guard var queued = state.answers[url], !queued.isEmpty else { return .failure(.offline) }
            let next = queued.removeFirst()
            state.answers[url] = queued
            return next
        }
        return try answer.get()
    }
}

// MARK: - Store

final class FakeLicenseStore: LicenseStoring, @unchecked Sendable {
    private struct State {
        var license: LicenseRecord?
        var trial: TrialRecord?
        var counted: GumroadCountedKeys?
        var loadFailure: LicenseStoreError?
        var saveFailure: LicenseStoreError?
        var writes: [String] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(license: LicenseRecord? = nil, trial: TrialRecord? = nil, counted: GumroadCountedKeys? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(license: license, trial: trial, counted: counted))
    }

    /// every load returns it while set
    var loadFailure: LicenseStoreError? {
        get { state.withLock { $0.loadFailure } }
        set { state.withLock { $0.loadFailure = newValue } }
    }

    /// every save and delete throws it while set
    var saveFailure: LicenseStoreError? {
        get { state.withLock { $0.saveFailure } }
        set { state.withLock { $0.saveFailure = newValue } }
    }

    /// "saveLicense", "deleteLicense", "saveTrial", "saveGumroadCounted"
    var writes: [String] { state.withLock { $0.writes } }

    func loadLicense() -> Result<LicenseRecord?, LicenseStoreError> {
        state.withLock { state in state.loadFailure.map { .failure($0) } ?? .success(state.license) }
    }

    func saveLicense(_ record: LicenseRecord) throws {
        try write("saveLicense") { $0.license = record }
    }

    func deleteLicense() throws {
        try write("deleteLicense") { $0.license = nil }
    }

    func loadTrial() -> Result<TrialRecord?, LicenseStoreError> {
        state.withLock { state in state.loadFailure.map { .failure($0) } ?? .success(state.trial) }
    }

    func saveTrial(_ record: TrialRecord) throws {
        try write("saveTrial") { $0.trial = record }
    }

    func loadGumroadCounted() -> Result<GumroadCountedKeys?, LicenseStoreError> {
        state.withLock { state in state.loadFailure.map { .failure($0) } ?? .success(state.counted) }
    }

    func saveGumroadCounted(_ keys: GumroadCountedKeys) throws {
        try write("saveGumroadCounted") { $0.counted = keys }
    }

    /// Records the attempt; applies `change` unless a save failure is injected, which is thrown instead.
    private func write(_ name: String, _ change: (inout State) -> Void) throws {
        let failure = state.withLock { state -> LicenseStoreError? in
            state.writes.append(name)
            if let failure = state.saveFailure { return failure }
            change(&state)
            return nil
        }
        if let failure { throw failure }
    }
}

// MARK: - Scheduler

@MainActor final class ManualLicenseScheduler: LicenseScheduling {
    private struct Item {
        let id: Int
        let deadline: Duration
        let work: @MainActor () -> Void
    }

    private var now: Duration = .zero
    private var nextID = 0
    private var items: [Item] = []

    init() {}

    func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) -> LicenseScheduledWork {
        let id = nextID
        nextID += 1
        items.append(Item(id: id, deadline: now + max(delay, .zero), work: work))
        return LicenseScheduledWork { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }

    /// runs every item whose delay has elapsed, in order
    func advance(by delay: Duration) {
        now += max(delay, .zero)
        // Work that schedules more work due by then runs in the same advance, still in deadline order.
        while let next = items.filter({ $0.deadline <= now }).min(by: { ($0.deadline, $0.id) < ($1.deadline, $1.id) }) {
            items.removeAll { $0.id == next.id }
            next.work()
        }
    }

    var pendingCount: Int { items.count }
}

// MARK: - Fixtures

enum LicenseFixtures {
    // Fixed test UUIDs (lowercase v4), never real ones.
    static let organizationID = "3b0d8c2e-5f1a-4e6b-9c7d-2a4f6e8b0c1d"
    static let otherOrganizationID = "9e7c5a3b-1d2f-4a6c-8e0b-4d6f8a0c2e4b"
    static let benefitID = "c4e6a8b0-2d4f-4b6d-8f0a-6c8e0a2c4e6f"
    static let otherBenefitID = "5a7c9e1b-3d5f-4c7e-a9b1-8d0f2b4d6f8a"
    static let gumroadProductID = "OttoFixtureProduct=="
    static let otherGumroadProductID = "AnotherFixtureProduct=="

    /// Polar's generated shape: "<PREFIX>-<UUID>", uppercase.
    static let polarKey = "OTTO-1C285B2D-6CE6-4BC7-B8BE-ADB6A7E304DA"
    /// The same UUID without a prefix.
    static let polarKeyUnprefixed = "1C285B2D-6CE6-4BC7-B8BE-ADB6A7E304DA"
    /// "8-8-8-8" hex shape.
    static let gumroadKey = "A1B2C3D4-E5F60718-293A4B5C-6D7E8F90"

    /// The activation and license key ids the documented Polar shapes carry.
    static let activationID = "b6724bc8-7ad9-4ca0-b143-7c896fcbb6fe"
    static let licenseKeyID = "508176f7-065a-4b5d-b524-4e9c8a11ed63"
    static let polarDisplayKey = "****-E304DA"

    // Live captures of 2026-09-27 (bogus key and organization id), headers lowercased:

    /// 404, polar-version: 2026-10, {"error":"ResourceNotFound","detail":"Not found"}
    static let polarNotFoundPinned = response(404, polarVersion: "2026-10",
                                              #"{"error":"ResourceNotFound","detail":"Not found"}"#)
    /// 404, polar-version: 2026-04, the same body
    static let polarNotFoundUnpinned = response(404, polarVersion: "2026-04",
                                                #"{"error":"ResourceNotFound","detail":"Not found"}"#)
    /// 404, no polar-version, {"detail":"Not Found"}
    static let polarVersionRefused = response(404, polarVersion: nil, #"{"detail":"Not Found"}"#)
    /// 422, polar-version: 2026-10, {"error":"RequestValidationError","detail":[…]}. The detail entry is the one a bogus
    /// organization id produces; the classification reads only the status.
    static let polarValidationError = response(422, polarVersion: "2026-10", """
        {"error":"RequestValidationError","detail":[{"type":"uuid_parsing","loc":["body","organization_id"],\
        "msg":"Input should be a valid UUID","input":"not-a-uuid"}]}
        """)

    // Documented shapes (Polar docs and source; Gumroad source):

    /// carries a customer object on purpose
    static func polarActivated(benefitID: String, limit: Int?) -> LicenseHTTPResponse {
        let licenseKey = polarLicenseKey(benefitID: benefitID, limit: limit)
        let body: [String: Any] = [
            "id": activationID,
            "license_key_id": licenseKeyID,
            "label": "Mac 7F3A",
            "meta": [String: Any](),
            "created_at": "2026-10-12T14:03:00Z",
            "modified_at": NSNull(),
            "license_key": licenseKey,
        ]
        return json(200, polarVersion: "2026-10", body)
    }

    static func polarValidated(benefitID: String, activationID: String?, limit: Int?) -> LicenseHTTPResponse {
        var body = polarLicenseKey(benefitID: benefitID, limit: limit)
        if let activationID {
            body["activation"] = [
                "id": activationID,
                "license_key_id": licenseKeyID,
                "label": "Mac 7F3A",
                "meta": [String: Any](),
                "created_at": "2026-10-12T14:03:00Z",
                "modified_at": NSNull(),
            ] as [String: Any]
        } else {
            body["activation"] = NSNull()
        }
        return json(200, polarVersion: "2026-10", body)
    }

    /// 403 {"error":"NotPermitted","detail":"License key activation limit already reached"}
    static let polarNotPermitted = response(403, polarVersion: "2026-10",
                                            #"{"error":"NotPermitted","detail":"License key activation limit already reached"}"#)
    /// 403 NotPermitted "This license key does not support activations. Use the /validate endpoint instead to check
    /// license validity."
    static let polarNotPermittedNoActivations = response(403, polarVersion: "2026-10", """
        {"error":"NotPermitted","detail":"This license key does not support activations. \
        Use the /validate endpoint instead to check license validity."}
        """)
    /// 204, empty body
    static let polarDeactivated = LicenseHTTPResponse(status: 204, headers: ["polar-version": "2026-10"], body: Data())

    /// carries email and full_name on purpose
    static func gumroadVerified(uses: Int, quantity: Int, refunded: Bool, chargebacked: Bool,
                                disputed: Bool, disputeWon: Bool) -> LicenseHTTPResponse {
        let purchase: [String: Any] = [
            "seller_id": "fixture-seller",
            "product_id": gumroadProductID,
            "product_name": "Otto for Mac",
            "permalink": "otto",
            "product_permalink": "https://fixture.gumroad.com/l/otto",
            "email": "buyer@example.com",
            "full_name": "Fixture Buyer",
            "purchaser_id": "1234567890",
            "price": 1900,
            "gumroad_fee": 190,
            "currency": "usd",
            "quantity": quantity,
            "discover_fee_charged": false,
            "can_contact": true,
            "referrer": "direct",
            "card": ["visual": "**** **** **** 4242", "type": "visa"],
            "order_number": 424242,
            "sale_id": "fixture-sale==",
            "sale_timestamp": "2026-10-12T14:03:00Z",
            "subscription_id": NSNull(),
            "variants": "",
            "license_key": gumroadKey,
            "is_multiseat_license": quantity > 1,
            "ip_country": "United States",
            "recurrence": NSNull(),
            "is_gift_receiver_purchase": false,
            "refunded": refunded,
            "partially_refunded": false,
            "chargebacked": chargebacked,
            "disputed": disputed,
            "dispute_won": disputeWon,
            "id": "fixture-purchase==",
            "created_at": "2026-10-12T14:03:00Z",
            "custom_fields": [String](),
        ]
        return json(200, polarVersion: nil, ["success": true, "uses": uses, "purchase": purchase])
    }

    /// 404 {"success":false,"message":"That license does not exist for the provided product."}
    /// (also Gumroad's answer to a wrong product_id)
    static let gumroadNotFound = response(404, polarVersion: nil,
                                          #"{"success":false,"message":"That license does not exist for the provided product."}"#)
    /// 404 {"success":false,"message":"This license key has been disabled."}
    static let gumroadDisabled = response(404, polarVersion: nil,
                                          #"{"success":false,"message":"This license key has been disabled."}"#)
    /// 500 {"success":false,"message":"The 'product_id' parameter is required …"}
    static let gumroadMissingProductID = response(500, polarVersion: nil, """
        {"success":false,"message":"The 'product_id' parameter is required to verify the license for this product."}
        """)

    // MARK: - Builders

    private static func polarLicenseKey(benefitID: String, limit: Int?) -> [String: Any] {
        [
            "id": licenseKeyID,
            "created_at": "2026-10-12T14:02:41Z",
            "modified_at": NSNull(),
            "organization_id": organizationID,
            "customer_id": "7d1e3f5a-9b2c-4d6e-8f0a-1b3c5d7e9f20",
            "customer": [
                "id": "7d1e3f5a-9b2c-4d6e-8f0a-1b3c5d7e9f20",
                "email": "buyer@example.com",
                "name": "Fixture Buyer",
                "organization_id": organizationID,
                "metadata": [String: Any](),
            ] as [String: Any],
            "benefit_id": benefitID,
            "key": polarKey,
            "display_key": polarDisplayKey,
            "status": "granted",
            "limit_activations": limit.map { $0 as Any } ?? NSNull(),
            "usage": 0,
            "limit_usage": NSNull(),
            "validations": 4,
            "last_validated_at": "2026-10-13T09:12:44Z",
            "expires_at": NSNull(),
        ]
    }

    private static func response(_ status: Int, polarVersion: String?, _ body: String) -> LicenseHTTPResponse {
        var headers = ["content-type": "application/json"]
        if let polarVersion { headers["polar-version"] = polarVersion }
        return LicenseHTTPResponse(status: status, headers: headers, body: Data(body.utf8))
    }

    private static func json(_ status: Int, polarVersion: String?, _ object: [String: Any]) -> LicenseHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        var headers = ["content-type": "application/json"]
        if let polarVersion { headers["polar-version"] = polarVersion }
        return LicenseHTTPResponse(status: status, headers: headers, body: body)
    }
}
#endif
