//
//  LicenseConfiguration+Load.swift
//  Otto
//
//  Reads the paid build's commercial configuration from Info.plist and validates it with the rules of §14.3, the
//  same ones scripts/check_commercial_config.sh applies before the build. A Release build can only see a problem
//  here if someone bypassed that build phase; it then logs a fault and behaves like a misconfigured Debug build.
//

#if OTTO_LICENSING
import Foundation
import os

extension LicenseConfiguration {
    /// Validates with the rules of §14.3 (the same ones scripts/check_commercial_config.sh applies at build time).
    static func load(infoDictionary: [String: Any]) -> LicenseConfiguration {
        #if DEBUG
        return load(infoDictionary: infoDictionary, isRelease: false)
        #else
        return load(infoDictionary: infoDictionary, isRelease: true)
        #endif
    }

    static func load(bundle: Bundle) -> LicenseConfiguration {
        load(infoDictionary: bundle.infoDictionary ?? [:])
    }

    /// The loader with the configuration made explicit, so tests can check the Release-only rules from a Debug build.
    static func load(infoDictionary: [String: Any], isRelease: Bool) -> LicenseConfiguration {
        var reader = LoadReader(info: infoDictionary)

        let siteHost = reader.value(for: .siteHost) { value in
            guard LoadRules.matches(value, LoadRules.hostPattern) else { return "is not a host name (no scheme or path)" }
            guard !value.hasSuffix("-projects.vercel.app") else {
                return "is a *-projects.vercel.app address, which sends visitors to the Vercel login"
            }
            return nil
        }
        let supportEmail = reader.value(for: .supportEmail) { value in
            guard LoadRules.matches(value, LoadRules.emailPattern) else { return "is not an email address" }
            return value.contains("@example.") ? "is an example address" : nil
        }
        let apiHost = reader.value(for: .polarAPIHost) { value in
            if isRelease {
                return value == polarProductionHost ? nil : "must be \(polarProductionHost) in a Release build"
            }
            return [polarProductionHost, polarSandboxHost].contains(value)
                ? nil : "must be \(polarProductionHost) or \(polarSandboxHost)"
        }
        let organizationID = reader.value(for: .polarOrganizationID, LoadRules.checkUUID)
        let benefitID = reader.value(for: .polarBenefitID, LoadRules.checkUUID)
        let portalSlug = reader.value(for: .polarPortalSlug) { value in
            LoadRules.matches(value, LoadRules.slugPattern) ? nil : "is not a Polar organization slug"
        }
        let gumroadValue = reader.value(for: .gumroadProductID) { value in
            value == "none" || LoadRules.matches(value, LoadRules.gumroadPattern)
                ? nil : "is neither none nor a Gumroad product id"
        }

        var polar: PolarConfiguration?
        if let apiHost, let organizationID, let benefitID, let portalSlug {
            polar = PolarConfiguration(apiHost: apiHost, organizationID: organizationID, benefitID: benefitID,
                                       portalSlug: portalSlug)
        }
        let gumroadExplicitlyOff = gumroadValue == "none"
        var gumroad: GumroadConfiguration?
        if let gumroadValue, !gumroadExplicitlyOff {
            gumroad = GumroadConfiguration(productID: gumroadValue)
        }

        let problems = reader.problems
        if isRelease && !problems.isEmpty {
            loadLogger.fault("Release build with \(problems.count, privacy: .public) commercial configuration problems: \(problems.joined(separator: "; "), privacy: .public)")
        }
        return LicenseConfiguration(siteHost: siteHost ?? "", supportEmail: supportEmail ?? "", polar: polar,
                                    gumroad: gumroad, gumroadExplicitlyOff: gumroadExplicitlyOff,
                                    problems: problems)
    }

    private static let loadLogger = Logger(subsystem: "com.jalenedusei.otto", category: "License")
}

/// The Info.plist keys of §14.2.2 and the build settings they come from (the names problems are reported under).
private enum LoadSetting: String {
    case siteHost = "OttoSiteHost"
    case supportEmail = "OttoSupportEmail"
    case polarAPIHost = "OttoPolarAPIHost"
    case polarOrganizationID = "OttoPolarOrganizationID"
    case polarBenefitID = "OttoPolarBenefitID"
    case polarPortalSlug = "OttoPolarPortalSlug"
    case gumroadProductID = "OttoGumroadProductID"

    var buildSetting: String {
        switch self {
        case .siteHost: return "OTTO_SITE_HOST"
        case .supportEmail: return "OTTO_SUPPORT_EMAIL"
        case .polarAPIHost: return "OTTO_POLAR_API_HOST"
        case .polarOrganizationID: return "OTTO_POLAR_ORGANIZATION_ID"
        case .polarBenefitID: return "OTTO_POLAR_BENEFIT_ID"
        case .polarPortalSlug: return "OTTO_POLAR_PORTAL_SLUG"
        case .gumroadProductID: return "OTTO_GUMROAD_PRODUCT_ID"
        }
    }
}

/// Reads one value at a time and collects one problem per bad value, in the order of the §14.3 table.
private struct LoadReader {
    let info: [String: Any]
    private(set) var problems: [String] = []

    init(info: [String: Any]) {
        self.info = info
    }

    /// The trimmed value when it passes `check` (which returns a problem phrase or nil); nil otherwise.
    mutating func value(for setting: LoadSetting, _ check: (String) -> String?) -> String? {
        let raw = (info[setting.rawValue] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let problem: String?
        if raw.isEmpty || raw.contains("$(") {
            problem = "is not set"
        } else if raw.contains("JALEN_MUST_SET") {
            problem = "is still a placeholder"
        } else {
            problem = check(raw)
        }
        if let problem {
            problems.append("\(setting.buildSetting) \(problem)")
            return nil
        }
        return raw
    }
}

/// The §14.3 rules. scripts/check_commercial_config.sh carries the same patterns.
private enum LoadRules {
    static let hostPattern = #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$"#
    static let emailPattern = #"^[^@ ]+@[^@ ]+\.[^@ ]+$"#
    static let uuidV4Pattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#
    static let slugPattern = #"^[a-z0-9][a-z0-9-]{1,63}$"#
    static let gumroadPattern = #"^[A-Za-z0-9_=+/-]{10,64}$"#

    static func checkUUID(_ value: String) -> String? {
        guard matches(value, uuidV4Pattern) else { return "is not a lowercase UUID v4" }
        return isAllZeros(value) ? "is all zeros" : nil
    }

    /// Every hex digit is 0 apart from the version (4) and variant nibbles a v4 UUID must carry.
    static func isAllZeros(_ uuid: String) -> Bool {
        let digits = Array(uuid.filter { $0 != "-" })
        return digits.indices.allSatisfy { index in index == 12 || index == 16 || digits[index] == "0" }
    }

    /// true when the whole of `value` matches `pattern`.
    static func matches(_ value: String, _ pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }
}
#endif
