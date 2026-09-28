//
//  LicenseContracts.swift
//  Otto
//
//  The paid build's licensing contracts (§14.4.2): the records kept in the Keychain and their codec, backend,
//  transport, storage and scheduling seams, the build's commercial configuration, the computed status and the
//  controller protocol the UI and the composition use. The whole file is inside OTTO_LICENSING, so the source and
//  Setapp builds compile it to nothing.
//

#if OTTO_LICENSING
import Foundation

// MARK: - Backends

enum LicenseBackendKind: String, Codable, CaseIterable, Sendable {
    case polar, gumroad

    /// "Polar", "Gumroad"
    var displayName: String {
        switch self {
        case .polar: return "Polar"
        case .gumroad: return "Gumroad"
        }
    }
}

// MARK: - Records kept in the Keychain (§14.9)

/// Records are JSON (sorted keys, ISO 8601 UTC dates) stored as UTF-8 text by LicenseCodec.
protocol LicenseSchemaVersioned {
    static var currentSchema: Int { get }
    var schema: Int { get }
}

struct PendingRevocation: Codable, Equatable, Sendable {
    let firstSeenAt: Date
    let reason: LicenseGoneReason
}

struct LicenseRecord: Codable, Equatable, Sendable, LicenseSchemaVersioned {
    static let currentSchema = 1
    var schema: Int
    var backend: LicenseBackendKind
    /// The configuration the activation succeeded under (§14.6 "Records carry their own IDs"). Validate and deactivate
    /// always send these, never the build's current values, so a later build with a mistyped or changed ID can't
    /// turn existing licenses off.
    var apiHost: String                // "api.polar.sh", "sandbox-api.polar.sh" (Debug) or "api.gumroad.com"
    var organizationID: String?        // Polar organization_id; nil for Gumroad
    var benefitID: String?             // Polar benefit_id; nil for Gumroad
    var gumroadProductID: String?      // Gumroad product_id; nil for Polar
    var key: String
    var licenseKeyID: String?          // Polar license_key_id (rotation keeps it); nil for Gumroad
    var activationID: String?          // Polar activation id; nil for Gumroad
    var label: String                  // "Mac 7F3A" (Polar, random); "" (Gumroad)
    var displayKey: String             // "****-E304DA"
    var seatLimit: Int?                // Polar limit_activations; Gumroad 3 × quantity
    var activatedAt: Date
    var lastValidatedAt: Date          // the last definitive "valid" answer (activation counts as one)
    var lastAttemptAt: Date?           // the last check attempt of any outcome
    var pendingRevocation: PendingRevocation?
}

enum LicenseRemovalReason: String, Codable, Sendable {
    case revoked, refunded, chargedBack, disabled, wrongProduct   // from a confirmed LicenseGoneReason
    case deactivatedByUser, removedByUser                          // Settings actions

    /// notFound → .revoked, refunded → .refunded, chargedBack → .chargedBack, disabled → .disabled,
    /// wrongProduct → .wrongProduct
    init(_ gone: LicenseGoneReason) {
        switch gone {
        case .notFound: self = .revoked
        case .refunded: self = .refunded
        case .chargedBack: self = .chargedBack
        case .disabled: self = .disabled
        case .wrongProduct: self = .wrongProduct
        }
    }
}

struct LicenseRemoval: Codable, Equatable, Sendable {
    let at: Date
    let reason: LicenseRemovalReason
}

struct TrialRecord: Codable, Equatable, Sendable, LicenseSchemaVersioned {
    static let currentSchema = 1
    var schema: Int
    var startedAt: Date                // first launch of a live paid build on this Mac; never reset
    var lastSeenAt: Date               // high-water mark of the wall clock (setting the clock back never extends
                                       // anything); moved only by LicensePolicy.nextLastSeen (§14.5)
    var lastLicenseRemoval: LicenseRemoval?   // why the last license left this Mac; cleared by the next activation
}

struct GumroadCountedKeys: Codable, Equatable, Sendable, LicenseSchemaVersioned {
    static let currentSchema = 1
    var schema: Int
    var hashes: [String]               // sorted, unique SHA-256 hex of "<productID>|<key>": keys already counted on this Mac
}

enum LicenseCodec {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try makeEncoder().encode(value)
        // JSONEncoder always produces UTF-8.
        return String(decoding: data, as: UTF8.self)
    }

    /// Throws LicenseStoreError.undecodable(account:createdAt: nil) for malformed JSON or `schema > T.currentSchema`;
    /// KeychainLicenseStore fills in createdAt.
    static func decode<T: Decodable & LicenseSchemaVersioned>(_ type: T.Type, from text: String,
                                                            account: String) throws -> T {
        let data = Data(text.utf8)
        let decoder = makeDecoder()
        // Read the schema on its own first: a newer record may not decode as this version's type at all, and it
        // must be reported as newer (never overwritten) either way.
        guard let probe = try? decoder.decode(SchemaProbe.self, from: data), probe.schema <= T.currentSchema,
              let value = try? decoder.decode(T.self, from: data) else {
            throw LicenseStoreError.undecodable(account: account, createdAt: nil)
        }
        return value
    }

    private struct SchemaProbe: Decodable {
        let schema: Int
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Outcomes

/// A definitive answer that the license no longer holds. Counts toward revocation (§14.5), never acts alone.
enum LicenseGoneReason: String, Codable, Sendable {
    case notFound        // Polar versioned 404 ResourceNotFound: revoked, disabled, expired, rotated, benefit
                         // mismatch, or this Mac's activation was removed in the portal
    case refunded        // Gumroad purchase.refunded
    case chargedBack     // Gumroad purchase.chargebacked, or disputed and not won
    case disabled        // Gumroad 404 {"success":false}
    case wrongProduct    // a key for another Polar benefit or Gumroad product
}

/// Anything that is not a definitive answer. Never changes a license.
enum LicenseUnavailableReason: Equatable, Sendable {
    case offline, timeout
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case versionRefused                 // Polar bare 404 without a polar-version echo, also after the unpinned retry
    case unexpectedResponse(status: Int)
    case misconfigured(String)          // a placeholder or malformed value (Debug only; Release can't be built with
                                        // one), or a store setting Otto can't work with ("Polar benefit has no
                                        // activation limit", §14.6)
    case recordMismatch                 // the record's host or IDs differ from this build's configuration and the
                                        // store said "gone" (or the host differs): never a downgrade (§14.6)
}

struct LicenseValidation: Equatable, Sendable {
    var seatLimit: Int?
    var displayKey: String?
}

enum LicenseCheckOutcome: Equatable, Sendable {
    case valid(LicenseValidation)
    case gone(LicenseGoneReason)
    case unavailable(LicenseUnavailableReason)
}

enum LicenseActivationError: Error, Equatable, Sendable {
    case malformedKey
    case keyNotFound
    case keyNotActive                   // refunded, revoked, disabled or expired
    case wrongProduct
    case seatLimitReached(limit: Int?)
    case backendDisabled(LicenseBackendKind)   // a Gumroad-format key in a build with OTTO_GUMROAD_PRODUCT_ID = none
    case unavailable(LicenseUnavailableReason)
}

enum LicenseDeactivationOutcome: Equatable, Sendable {
    case freedSeat                      // Polar 204
    case alreadyGone                    // Polar versioned 404
    case localOnly                      // the backend can't free a seat from a client (Gumroad)
    case unavailable(LicenseUnavailableReason)
}

// MARK: - Backend seam (one file per merchant; §14.6–§14.8)

protocol LicenseBackend: Sendable {
    var kind: LicenseBackendKind { get }
    /// `label` is "Mac XXXX" (random, never the Mac's name). `existing` is this Mac's current record when it came from
    /// the same backend (Polar re-keys a rotated key on the existing activation instead of taking a new seat). A new
    /// record carries apiHost and the IDs of the backend's configuration; a re-keyed record keeps `existing`'s.
    func activate(key: String, label: String, existing: LicenseRecord?) async -> Result<LicenseRecord, LicenseActivationError>
    /// Both send the record's own apiHost and IDs; a record/configuration mismatch never yields .gone (§14.6).
    func validate(_ record: LicenseRecord) async -> LicenseCheckOutcome
    func deactivate(_ record: LicenseRecord) async -> LicenseDeactivationOutcome
}

// MARK: - HTTP seam (no test ever touches the network)

struct LicenseHTTPRequest: Equatable, Sendable {
    var url: URL
    var method: String                  // "POST" for every call in 1.x
    var headers: [String: String]
    var body: Data
}

struct LicenseHTTPResponse: Equatable, Sendable {
    var status: Int
    var headers: [String: String]       // names lowercased
    var body: Data
}

enum LicenseTransportError: Error, Equatable, Sendable { case offline, timeout, other(String) }

protocol LicenseHTTPTransport: Sendable {
    /// Throws LicenseTransportError only.
    func send(_ request: LicenseHTTPRequest) async throws -> LicenseHTTPResponse
}

// MARK: - Storage seam (§14.9)

enum LicenseStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)             // any status other than errSecItemNotFound
    /// Present but unreadable (malformed or a newer schema): never overwritten. `createdAt` is the item's
    /// kSecAttrCreationDate when the Keychain reports one; §14.5 dates an unreadable trial record from it.
    case undecodable(account: String, createdAt: Date?)
}

/// Keychain account names (§14.9). Only a production configuration uses the plain names, so a Debug, sandbox or
/// misconfigured build can never read, validate or delete a production record or advance the production trial.
struct LicenseKeychainAccounts: Equatable, Sendable {
    let license: String
    let trial: String
    let gumroadCounted: String

    /// "license", "trial", "gumroad-counted"
    static let production = LicenseKeychainAccounts(license: "license", trial: "trial",
                                                    gumroadCounted: "gumroad-counted")
    /// "license.sandbox", "trial.sandbox", "gumroad-counted.sandbox"
    static let sandbox = LicenseKeychainAccounts(license: "license.sandbox", trial: "trial.sandbox",
                                                 gumroadCounted: "gumroad-counted.sandbox")
}

protocol LicenseStoring: AnyObject, Sendable {
    func loadLicense() -> Result<LicenseRecord?, LicenseStoreError>
    func saveLicense(_ record: LicenseRecord) throws
    func deleteLicense() throws
    func loadTrial() -> Result<TrialRecord?, LicenseStoreError>
    func saveTrial(_ record: TrialRecord) throws
    func loadGumroadCounted() -> Result<GumroadCountedKeys?, LicenseStoreError>
    func saveGumroadCounted(_ keys: GumroadCountedKeys) throws
}

// MARK: - Scheduling seam (tests drive a manual scheduler)

@MainActor protocol LicenseScheduling: AnyObject {
    func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) -> LicenseScheduledWork
}

/// A handle to scheduled work. `cancel()` runs the scheduler's cancellation once; later calls do nothing.
@MainActor final class LicenseScheduledWork {
    private var onCancel: (@MainActor () -> Void)?

    init(cancel: @escaping @MainActor () -> Void) {
        onCancel = cancel
    }

    func cancel() {
        guard let onCancel else { return }
        self.onCancel = nil
        onCancel()
    }
}

// MARK: - Configuration (§14.2.3 values, read from Info.plist)

struct PolarConfiguration: Equatable, Sendable {
    /// Polar-Version pin (§14.6). Verified 2026-09-27: accepted and echoed by api.polar.sh and sandbox-api.polar.sh.
    static let apiVersion = "2026-10"
    let apiHost: String                 // "api.polar.sh"; "sandbox-api.polar.sh" only in Debug
    let organizationID: String          // lowercase UUID v4
    let benefitID: String               // lowercase UUID v4
    let portalSlug: String

    /// apiHost == "sandbox-api.polar.sh"
    var isSandbox: Bool { apiHost == LicenseConfiguration.polarSandboxHost }

    /// https://polar.sh/<slug>/portal (https://sandbox.polar.sh/<slug>/portal when isSandbox)
    var portalURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = isSandbox ? "sandbox.polar.sh" : "polar.sh"
        components.path = "/\(portalSlug)/portal"
        return components.url
    }

    /// https://<apiHost>/v1/customer-portal/license-keys/<name>  (name: "activate", "validate", "deactivate")
    func endpoint(_ name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = apiHost
        components.path = "/v1/customer-portal/license-keys/\(name)"
        return components.url
    }
}

struct GumroadConfiguration: Equatable, Sendable {
    static let verifyEndpoint = "https://api.gumroad.com/v2/licenses/verify"
    let productID: String
}

struct LicenseConfiguration: Equatable, Sendable {
    let siteHost: String                // OttoSiteHost ("" when misconfigured)
    let supportEmail: String            // OttoSupportEmail ("" when misconfigured)
    let polar: PolarConfiguration?      // nil only when misconfigured (Debug)
    let gumroad: GumroadConfiguration?  // nil when OTTO_GUMROAD_PRODUCT_ID = none, or misconfigured (Debug)
    let gumroadExplicitlyOff: Bool      // the value was the literal "none"
    let problems: [String]              // "OTTO_POLAR_ORGANIZATION_ID is still a placeholder", …; empty in Release

    var enabledBackends: Set<LicenseBackendKind> {
        var kinds: Set<LicenseBackendKind> = []
        if polar != nil { kinds.insert(.polar) }
        if gumroad != nil { kinds.insert(.gumroad) }
        return kinds
    }

    /// .production only when polar != nil, !polar.isSandbox and problems.isEmpty; otherwise .sandbox (Debug builds on
    /// the Polar sandbox, the licensing-check build, any misconfigured build).
    var keychainAccounts: LicenseKeychainAccounts {
        guard let polar, !polar.isSandbox, problems.isEmpty else { return .sandbox }
        return .production
    }

    /// https://<siteHost>/buy
    var buyURL: URL? { sitePage("buy") }

    /// https://<siteHost>/<path> ("terms", "privacy", "refunds"); nil while the site host is misconfigured.
    func sitePage(_ path: String) -> URL? {
        guard !siteHost.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = siteHost
        components.path = "/\(path)"
        return components.url
    }

    /// Snapshots, previews and tests: otto-sandy.vercel.app, support@example.com, sandbox Polar with fixed UUIDs,
    /// Gumroad off. Never used by a live graph.
    static let preview = LicenseConfiguration(
        siteHost: "otto-sandy.vercel.app",
        supportEmail: "support@example.com",
        polar: PolarConfiguration(apiHost: polarSandboxHost,
                                  organizationID: "6f1c2a4e-8d3b-4c5a-9e7f-1a2b3c4d5e6f",
                                  benefitID: "0b9e8d7c-6a5f-4e3d-8c2b-1a0f9e8d7c6b",
                                  portalSlug: "otto-preview"),
        gumroad: nil,
        gumroadExplicitlyOff: true,
        problems: []
    )

    static let polarProductionHost = "api.polar.sh"
    static let polarSandboxHost = "sandbox-api.polar.sh"
}

// MARK: - Status (computed by LicensePolicy, §14.4.3 and §14.5)

struct LicenseSummary: Equatable, Sendable {
    let backend: LicenseBackendKind
    let displayKey: String
    let label: String
    let seatLimit: Int?
    let lastValidatedAt: Date
    let pendingRevocation: PendingRevocation?

    init(record: LicenseRecord) {
        backend = record.backend
        displayKey = record.displayKey
        label = record.label
        seatLimit = record.seatLimit
        lastValidatedAt = record.lastValidatedAt
        pendingRevocation = record.pendingRevocation
    }
}

enum LicenseStatus: Equatable, Sendable {
    case trial(endsAt: Date, daysLeft: Int)                           // daysLeft 1…14
    case trialEnded(endedAt: Date)
    case licensed(LicenseSummary)                                     // last good check ≤ 30 days ago
    case licensedCheckOverdue(LicenseSummary, sendingPausesAt: Date)  // 30–44 days
    case licensedCheckRequired(LicenseSummary)                        // more than 44 days
    case unavailable(LicenseStoreError)                               // Keychain unreadable: fail open

    /// false only for .trialEnded and .licensedCheckRequired
    var allowsSending: Bool {
        switch self {
        case .trialEnded, .licensedCheckRequired: return false
        case .trial, .licensed, .licensedCheckOverdue, .unavailable: return true
        }
    }

    var summary: LicenseSummary? {
        switch self {
        case .licensed(let summary), .licensedCheckOverdue(let summary, _), .licensedCheckRequired(let summary):
            return summary
        case .trial, .trialEnded, .unavailable:
            return nil
        }
    }
}

// MARK: - The seam every UI and the composition use

enum LicenseActivity: Equatable, Sendable { case idle, activating, checking, deactivating }

struct LicenseMessage: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case success, info, problem }
    let tone: Tone
    let text: String
}

@MainActor protocol LicenseControlling: ComposerGating {
    var status: LicenseStatus { get }
    var activity: LicenseActivity { get }
    var lastMessage: LicenseMessage? { get }          // the outcome of the last user action (§14.10.2 copy)
    var lastRemoval: LicenseRemoval? { get }
    var configuration: LicenseConfiguration { get }
    /// Each returns at once; work runs in a Task and lands in status / activity / lastMessage.
    func activate(key: String)                        // ignored unless activity == .idle
    func checkNow()                                   // honors LicensePolicy.manualCheckCooldown
    func deactivate()                                 // Polar frees the seat; Gumroad is local only
    func removeFromThisMac()                          // forget the license locally (after a failed deactivation)
    func dismissMessage()
}
#endif
