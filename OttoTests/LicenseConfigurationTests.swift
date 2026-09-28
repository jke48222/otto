//
//  LicenseConfigurationTests.swift
//  OttoTests
//
//  Loading the commercial configuration from Info.plist values with the §14.3 rules: valid, placeholder, malformed
//  and sandbox values, the problems list, enabled backends, Gumroad "none", portal and site URLs, and which
//  Keychain accounts a configuration may use.
//

#if OTTO_LICENSING
import XCTest
@testable import Otto

final class LicenseConfigurationTests: XCTestCase {
    private func info(_ overrides: [String: String] = [:]) -> [String: Any] {
        var values: [String: String] = [
            "OttoSiteHost": "otto.example.test",
            "OttoSupportEmail": "help@otto-fixture.test",
            "OttoPolarAPIHost": "api.polar.sh",
            "OttoPolarOrganizationID": LicenseFixtures.organizationID,
            "OttoPolarBenefitID": LicenseFixtures.benefitID,
            "OttoPolarPortalSlug": "otto-fixture",
            "OttoGumroadProductID": LicenseFixtures.gumroadProductID,
        ]
        values.merge(overrides) { _, new in new }
        return values
    }

    private func load(_ overrides: [String: String] = [:], isRelease: Bool = false) -> LicenseConfiguration {
        LicenseConfiguration.load(infoDictionary: info(overrides), isRelease: isRelease)
    }

    // MARK: - Valid values

    func testValidProductionValues() {
        for isRelease in [false, true] {
            let configuration = load(isRelease: isRelease)
            XCTAssertEqual(configuration.problems, [])
            XCTAssertEqual(configuration.siteHost, "otto.example.test")
            XCTAssertEqual(configuration.supportEmail, "help@otto-fixture.test")
            XCTAssertEqual(configuration.polar, PolarConfiguration(apiHost: "api.polar.sh",
                                                                   organizationID: LicenseFixtures.organizationID,
                                                                   benefitID: LicenseFixtures.benefitID,
                                                                   portalSlug: "otto-fixture"))
            XCTAssertEqual(configuration.gumroad, GumroadConfiguration(productID: LicenseFixtures.gumroadProductID))
            XCTAssertFalse(configuration.gumroadExplicitlyOff)
            XCTAssertEqual(configuration.enabledBackends, [.polar, .gumroad])
            XCTAssertEqual(configuration.keychainAccounts, .production)
        }
    }

    func testTheBuildLoaderMatchesThisBuildsConfiguration() {
        #if DEBUG
        XCTAssertEqual(LicenseConfiguration.load(infoDictionary: info(["OttoPolarAPIHost": "sandbox-api.polar.sh"])).problems, [])
        #else
        XCTAssertFalse(LicenseConfiguration.load(infoDictionary: info(["OttoPolarAPIHost": "sandbox-api.polar.sh"])).problems.isEmpty)
        #endif
        XCTAssertEqual(LicenseConfiguration.load(bundle: Bundle(for: Self.self)).polar, nil)
    }

    func testURLs() throws {
        let configuration = load()
        XCTAssertEqual(configuration.buyURL?.absoluteString, "https://otto.example.test/buy")
        XCTAssertEqual(configuration.sitePage("terms")?.absoluteString, "https://otto.example.test/terms")
        XCTAssertEqual(configuration.sitePage("privacy")?.absoluteString, "https://otto.example.test/privacy")
        XCTAssertEqual(configuration.sitePage("refunds")?.absoluteString, "https://otto.example.test/refunds")
        let polar = try XCTUnwrap(configuration.polar)
        XCTAssertFalse(polar.isSandbox)
        XCTAssertEqual(polar.portalURL?.absoluteString, "https://polar.sh/otto-fixture/portal")
        XCTAssertEqual(polar.endpoint("activate")?.absoluteString,
                       "https://api.polar.sh/v1/customer-portal/license-keys/activate")
        XCTAssertEqual(polar.endpoint("validate")?.absoluteString,
                       "https://api.polar.sh/v1/customer-portal/license-keys/validate")
        XCTAssertEqual(polar.endpoint("deactivate")?.absoluteString,
                       "https://api.polar.sh/v1/customer-portal/license-keys/deactivate")
        XCTAssertEqual(PolarConfiguration.apiVersion, "2026-10")
        XCTAssertEqual(GumroadConfiguration.verifyEndpoint, "https://api.gumroad.com/v2/licenses/verify")
    }

    // MARK: - Sandbox

    func testSandboxHostInDebugUsesTheSandboxEverywhere() throws {
        let configuration = load(["OttoPolarAPIHost": "sandbox-api.polar.sh"])
        XCTAssertEqual(configuration.problems, [])
        let polar = try XCTUnwrap(configuration.polar)
        XCTAssertTrue(polar.isSandbox)
        XCTAssertEqual(polar.portalURL?.absoluteString, "https://sandbox.polar.sh/otto-fixture/portal")
        XCTAssertEqual(polar.endpoint("validate")?.absoluteString,
                       "https://sandbox-api.polar.sh/v1/customer-portal/license-keys/validate")
        XCTAssertEqual(configuration.keychainAccounts, .sandbox)
    }

    func testSandboxHostInReleaseIsAProblem() {
        let configuration = load(["OttoPolarAPIHost": "sandbox-api.polar.sh"], isRelease: true)
        XCTAssertEqual(configuration.problems, ["OTTO_POLAR_API_HOST must be api.polar.sh in a Release build"])
        XCTAssertNil(configuration.polar)
        XCTAssertEqual(configuration.enabledBackends, [.gumroad])
        XCTAssertEqual(configuration.keychainAccounts, .sandbox)
    }

    func testAnyOtherPolarHostIsAProblem() {
        XCTAssertEqual(load(["OttoPolarAPIHost": "api.polar.example.test"]).problems,
                       ["OTTO_POLAR_API_HOST must be api.polar.sh or sandbox-api.polar.sh"])
    }

    // MARK: - Placeholders and malformed values

    func testPlaceholdersAreReportedPerSetting() {
        let configuration = load([
            "OttoSiteHost": "JALEN_MUST_SET_SITE_HOST",
            "OttoSupportEmail": "JALEN_MUST_SET_SUPPORT_EMAIL",
            "OttoPolarOrganizationID": "JALEN_MUST_SET_POLAR_SANDBOX_ORGANIZATION_ID",
            "OttoPolarBenefitID": "JALEN_MUST_SET_POLAR_SANDBOX_BENEFIT_ID",
            "OttoPolarPortalSlug": "JALEN_MUST_SET_POLAR_ORGANIZATION_SLUG",
            "OttoGumroadProductID": "JALEN_MUST_SET_GUMROAD_PRODUCT_ID_OR_none",
        ])
        XCTAssertEqual(configuration.problems, [
            "OTTO_SITE_HOST is still a placeholder",
            "OTTO_SUPPORT_EMAIL is still a placeholder",
            "OTTO_POLAR_ORGANIZATION_ID is still a placeholder",
            "OTTO_POLAR_BENEFIT_ID is still a placeholder",
            "OTTO_POLAR_PORTAL_SLUG is still a placeholder",
            "OTTO_GUMROAD_PRODUCT_ID is still a placeholder",
        ])
        XCTAssertEqual(configuration.siteHost, "")
        XCTAssertEqual(configuration.supportEmail, "")
        XCTAssertNil(configuration.polar)
        XCTAssertNil(configuration.gumroad)
        XCTAssertFalse(configuration.gumroadExplicitlyOff)
        XCTAssertEqual(configuration.enabledBackends, [])
        XCTAssertNil(configuration.buyURL)
        XCTAssertNil(configuration.sitePage("terms"))
        XCTAssertEqual(configuration.keychainAccounts, .sandbox)
    }

    func testMissingAndUnexpandedValuesAreNotSet() {
        var dictionary = info()
        dictionary.removeValue(forKey: "OttoSiteHost")
        dictionary["OttoSupportEmail"] = ""
        dictionary["OttoPolarPortalSlug"] = "$(OTTO_POLAR_PORTAL_SLUG)"
        dictionary["OttoPolarBenefitID"] = 42
        let configuration = LicenseConfiguration.load(infoDictionary: dictionary, isRelease: false)
        XCTAssertEqual(configuration.problems, [
            "OTTO_SITE_HOST is not set",
            "OTTO_SUPPORT_EMAIL is not set",
            "OTTO_POLAR_BENEFIT_ID is not set",
            "OTTO_POLAR_PORTAL_SLUG is not set",
        ])
        XCTAssertEqual(LicenseConfiguration.load(infoDictionary: [:], isRelease: false).problems.count, 7)
    }

    func testMalformedValues() {
        let cases: [(String, String, String)] = [
            ("OttoSiteHost", "https://otto.example.test", "OTTO_SITE_HOST is not a host name (no scheme or path)"),
            ("OttoSiteHost", "otto.example.test/buy", "OTTO_SITE_HOST is not a host name (no scheme or path)"),
            ("OttoSiteHost", "Otto.Example.test", "OTTO_SITE_HOST is not a host name (no scheme or path)"),
            ("OttoSiteHost", "localhost", "OTTO_SITE_HOST is not a host name (no scheme or path)"),
            ("OttoSiteHost", "otto-jke48222s-projects.vercel.app",
             "OTTO_SITE_HOST is a *-projects.vercel.app address, which sends visitors to the Vercel login"),
            ("OttoSupportEmail", "help at otto.test", "OTTO_SUPPORT_EMAIL is not an email address"),
            ("OttoSupportEmail", "help@example.com", "OTTO_SUPPORT_EMAIL is an example address"),
            ("OttoPolarOrganizationID", "3B0D8C2E-5F1A-4E6B-9C7D-2A4F6E8B0C1D",
             "OTTO_POLAR_ORGANIZATION_ID is not a lowercase UUID v4"),
            ("OttoPolarOrganizationID", "3b0d8c2e-5f1a-1e6b-9c7d-2a4f6e8b0c1d",
             "OTTO_POLAR_ORGANIZATION_ID is not a lowercase UUID v4"),
            ("OttoPolarBenefitID", "00000000-0000-4000-8000-000000000000", "OTTO_POLAR_BENEFIT_ID is all zeros"),
            ("OttoPolarPortalSlug", "Otto", "OTTO_POLAR_PORTAL_SLUG is not a Polar organization slug"),
            ("OttoPolarPortalSlug", "o", "OTTO_POLAR_PORTAL_SLUG is not a Polar organization slug"),
            ("OttoGumroadProductID", "short", "OTTO_GUMROAD_PRODUCT_ID is neither none nor a Gumroad product id"),
            ("OttoGumroadProductID", "None", "OTTO_GUMROAD_PRODUCT_ID is neither none nor a Gumroad product id"),
        ]
        for (key, value, problem) in cases {
            XCTAssertEqual(load([key: value]).problems, [problem], "\(key) = \(value)")
        }
    }

    func testValidEdgeValues() {
        XCTAssertEqual(load(["OttoSiteHost": "otto-sandy.vercel.app"]).problems, [])
        XCTAssertEqual(load(["OttoSiteHost": "  otto.example.test \n"]).siteHost, "otto.example.test")
        XCTAssertEqual(load(["OttoPolarPortalSlug": "ab"]).problems, [])
        XCTAssertEqual(load(["OttoGumroadProductID": "abc_DEF=+/-1"]).problems, [])
    }

    // MARK: - Gumroad

    func testGumroadNoneIsAnExplicitOff() {
        let configuration = load(["OttoGumroadProductID": "none"])
        XCTAssertEqual(configuration.problems, [])
        XCTAssertNil(configuration.gumroad)
        XCTAssertTrue(configuration.gumroadExplicitlyOff)
        XCTAssertEqual(configuration.enabledBackends, [.polar])
        XCTAssertEqual(configuration.keychainAccounts, .production)
    }

    // MARK: - Keychain accounts

    func testKeychainAccountsAreProductionOnlyForACleanProductionConfiguration() {
        XCTAssertEqual(load().keychainAccounts, .production)
        XCTAssertEqual(load(["OttoPolarAPIHost": "sandbox-api.polar.sh"]).keychainAccounts, .sandbox)
        // Any problem, even one that leaves Polar configured, keeps a build off the production items.
        let emailProblem = load(["OttoSupportEmail": "JALEN_MUST_SET_SUPPORT_EMAIL"])
        XCTAssertNotNil(emailProblem.polar)
        XCTAssertEqual(emailProblem.keychainAccounts, .sandbox)
        XCTAssertEqual(LicenseConfiguration.load(infoDictionary: [:], isRelease: false).keychainAccounts, .sandbox)
        XCTAssertEqual(LicenseConfiguration.preview.keychainAccounts, .sandbox)
    }

    // MARK: - Preview

    func testPreview() throws {
        let preview = LicenseConfiguration.preview
        XCTAssertEqual(preview.siteHost, "otto-sandy.vercel.app")
        XCTAssertEqual(preview.supportEmail, "support@example.com")
        XCTAssertEqual(preview.problems, [])
        XCTAssertNil(preview.gumroad)
        XCTAssertTrue(preview.gumroadExplicitlyOff)
        XCTAssertEqual(preview.enabledBackends, [.polar])
        XCTAssertEqual(preview.buyURL?.absoluteString, "https://otto-sandy.vercel.app/buy")
        let polar = try XCTUnwrap(preview.polar)
        XCTAssertTrue(polar.isSandbox)
        XCTAssertNotNil(polar.organizationID.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                                                   options: .regularExpression))
        XCTAssertNotNil(polar.benefitID.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                                              options: .regularExpression))
    }
}
#endif
