//
//  LicenseBackendsTests.swift
//  OttoTests
//
//  LicenseBackends.make: Polar first, then Gumroad, a store with no configuration left out, and the user agent
//  every request carries. Also the answer rules both stores share.
//

#if OTTO_LICENSING
import XCTest
@testable import Otto

final class LicenseBackendsTests: XCTestCase {
    private typealias Fixtures = LicenseFixtures

    private let polar = PolarConfiguration(apiHost: LicenseConfiguration.polarProductionHost,
                                           organizationID: LicenseFixtures.organizationID,
                                           benefitID: LicenseFixtures.benefitID, portalSlug: "otto")

    private func configuration(polar: PolarConfiguration?, gumroadProductID: String?) -> LicenseConfiguration {
        LicenseConfiguration(siteHost: "otto.test", supportEmail: "help@otto.test", polar: polar,
                             gumroad: gumroadProductID.map(GumroadConfiguration.init(productID:)),
                             gumroadExplicitlyOff: gumroadProductID == nil, problems: [])
    }

    private func make(_ configuration: LicenseConfiguration, transport: FakeLicenseTransport = FakeLicenseTransport(),
                      userAgent: String = "Otto/1.1.0") -> [any LicenseBackend] {
        LicenseBackends.make(configuration: configuration, transport: transport, store: FakeLicenseStore(),
                             userAgent: userAgent)
    }

    func testPolarComesFirstThenGumroad() {
        let backends = make(configuration(polar: polar, gumroadProductID: Fixtures.gumroadProductID))
        XCTAssertEqual(backends.map(\.kind), [.polar, .gumroad])
        XCTAssertTrue(backends[0] is PolarLicenseBackend)
        XCTAssertTrue(backends[1] is GumroadLicenseBackend)
    }

    func testANilConfigurationLeavesItsBackendOut() {
        XCTAssertEqual(make(configuration(polar: polar, gumroadProductID: nil)).map(\.kind), [.polar])
        XCTAssertEqual(make(configuration(polar: nil, gumroadProductID: Fixtures.gumroadProductID)).map(\.kind),
                       [.gumroad])
        XCTAssertTrue(make(configuration(polar: nil, gumroadProductID: nil)).isEmpty)
        XCTAssertEqual(make(.preview).map(\.kind), [.polar], "the preview configuration has Gumroad off")
    }

    func testEveryRequestCarriesTheUserAgent() async {
        let transport = FakeLicenseTransport()
        let backends = make(configuration(polar: polar, gumroadProductID: Fixtures.gumroadProductID),
                            transport: transport, userAgent: "Otto/9.8.7")
        for backend in backends {
            _ = await backend.activate(key: Fixtures.polarKey, label: "Mac 7F3A", existing: nil)
        }
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.map { $0.headers["User-Agent"] }, ["Otto/9.8.7", "Otto/9.8.7"])
        XCTAssertEqual(transport.requests.map { $0.headers["Accept-Language"] }, ["en", "en"])
    }

    func testUserAgentComesFromTheShortVersion() throws {
        let version = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        XCTAssertEqual(LicenseBackends.userAgent(bundle: .main), "Otto/\(version)")
        XCTAssertEqual(LicenseBackends.userAgent(), "Otto/\(version)")
    }

    func testSharedAnswerRules() {
        XCTAssertEqual(LicenseBackends.unavailableReason(for: .offline), .offline)
        XCTAssertEqual(LicenseBackends.unavailableReason(for: .timeout), .timeout)
        XCTAssertEqual(LicenseBackends.unavailableReason(for: .other("cancelled")), .offline)
        XCTAssertEqual(LicenseBackends.retryAfter(in: ["retry-after": "2"]), 2)
        XCTAssertEqual(LicenseBackends.retryAfter(in: ["Retry-After": " 1.5 "]), 1.5)
        XCTAssertNil(LicenseBackends.retryAfter(in: ["retry-after": "-1"]))
        XCTAssertNil(LicenseBackends.retryAfter(in: ["retry-after": "soon"]))
        XCTAssertNil(LicenseBackends.retryAfter(in: [:]))
    }
}
#endif
