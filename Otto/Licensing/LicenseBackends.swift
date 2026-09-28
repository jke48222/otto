//
//  LicenseBackends.swift
//  Otto
//
//  Builds the paid build's license backends from its configuration (Polar first, then Gumroad; a store whose
//  configuration is nil is left out), plus the few answer rules both stores share: transport failures, Retry-After,
//  and the License log category.
//

#if OTTO_LICENSING
import Foundation
import os

enum LicenseBackends {
    /// Polar first, then Gumroad; a backend whose configuration is nil is left out. userAgent: "Otto/<CFBundleShortVersionString>".
    static func make(configuration: LicenseConfiguration, transport: LicenseHTTPTransport, store: LicenseStoring,
                     userAgent: String) -> [any LicenseBackend] {
        var backends: [any LicenseBackend] = []
        if let polar = configuration.polar {
            backends.append(PolarLicenseBackend(configuration: polar, transport: transport, userAgent: userAgent))
        }
        if let gumroad = configuration.gumroad {
            backends.append(GumroadLicenseBackend(configuration: gumroad, transport: transport, counted: store,
                                                  userAgent: userAgent))
        }
        return backends
    }

    /// "Otto/<CFBundleShortVersionString>", the only user agent license requests carry.
    static func userAgent(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Otto/\(version ?? "0")"
    }

    // MARK: - Shared answer rules

    /// `offline` and `timeout` keep their meaning; any other transport failure (TLS, a cancelled task) also means
    /// the store couldn't be reached, so it reads as offline. Never a downgrade.
    static func unavailableReason(for error: LicenseTransportError) -> LicenseUnavailableReason {
        switch error {
        case .offline, .other: return .offline
        case .timeout: return .timeout
        }
    }

    /// `Retry-After` in seconds (the form Polar and Gumroad send); nil when absent, negative or an HTTP date.
    static func retryAfter(in headers: [String: String]) -> TimeInterval? {
        guard let raw = PolarAPI.header("retry-after", in: headers),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    /// Short, public names for log lines: the outcome's case, never its payload's personal parts.
    static func logName(_ reason: LicenseUnavailableReason) -> String {
        switch reason {
        case .offline: return "offline"
        case .timeout: return "timeout"
        case .rateLimited: return "rateLimited"
        case .server(let status): return "server(\(status))"
        case .versionRefused: return "versionRefused"
        case .unexpectedResponse(let status): return "unexpectedResponse(\(status))"
        case .misconfigured: return "misconfigured"
        case .recordMismatch: return "recordMismatch"
        }
    }

    /// Category License (§0.3). Keys, activation ids, labels and emails are never logged.
    static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "License")
}
#endif
