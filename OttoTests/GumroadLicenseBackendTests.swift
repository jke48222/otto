//
//  GumroadLicenseBackendTests.swift
//  OttoTests
//
//  Gumroad's license backend against FakeLicenseTransport, FakeLicenseStore and LicenseFixtures: the exact form
//  request, seat counting with the counted-hash store, the refund and dispute flags, the 404 and 500 rows, records
//  that carry their own product id, and buyer details that never leave the answer. Nothing touches the network.
//

#if OTTO_LICENSING
import XCTest
@testable import Otto

final class GumroadLicenseBackendTests: XCTestCase {
    private typealias Fixtures = LicenseFixtures

    private let verifyURL = "https://api.gumroad.com/v2/licenses/verify"
    private let userAgent = "Otto/1.1.0"
    private var transport = FakeLicenseTransport()
    private var store = FakeLicenseStore()

    override func setUp() {
        super.setUp()
        transport = FakeLicenseTransport()
        store = FakeLicenseStore()
    }

    // MARK: - Helpers

    private func backend(productID: String = Fixtures.gumroadProductID) -> GumroadLicenseBackend {
        GumroadLicenseBackend(configuration: GumroadConfiguration(productID: productID), transport: transport,
                              counted: store, userAgent: userAgent)
    }

    private func verified(uses: Int = 0, quantity: Int = 1, refunded: Bool = false, chargebacked: Bool = false,
                          disputed: Bool = false, disputeWon: Bool = false) -> LicenseHTTPResponse {
        Fixtures.gumroadVerified(uses: uses, quantity: quantity, refunded: refunded, chargebacked: chargebacked,
                                 disputed: disputed, disputeWon: disputeWon)
    }

    private func enqueue(_ responses: LicenseHTTPResponse...) {
        for response in responses { transport.enqueue(verifyURL, .success(response)) }
    }

    private func record(productID: String = Fixtures.gumroadProductID, host: String = "api.gumroad.com") -> LicenseRecord {
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        return LicenseRecord(schema: 1, backend: .gumroad, apiHost: host, organizationID: nil, benefitID: nil,
                             gumroadProductID: productID, key: Fixtures.gumroadKey, licenseKeyID: nil,
                             activationID: nil, label: "", displayKey: "****-7E8F90", seatLimit: 3,
                             activatedAt: date, lastValidatedAt: date, lastAttemptAt: date, pendingRevocation: nil)
    }

    private func body(_ index: Int) -> String {
        String(decoding: transport.requests[index].body, as: UTF8.self)
    }

    private var countingBody: String {
        "increment_uses_count=true&license_key=A1B2C3D4-E5F60718-293A4B5C-6D7E8F90&product_id=OttoFixtureProduct%3D%3D"
    }

    private var lookingBody: String {
        "increment_uses_count=false&license_key=A1B2C3D4-E5F60718-293A4B5C-6D7E8F90&product_id=OttoFixtureProduct%3D%3D"
    }

    // MARK: - Requests are exact

    func testVerifyRequestHasExactURLHeadersAndFormBody() throws {
        let request = try XCTUnwrap(GumroadAPI.verifyRequest(key: "AB CD+/=&", productID: "p=1", incrementUsesCount: false,
                                                             userAgent: userAgent))
        XCTAssertEqual(request.url.absoluteString, verifyURL)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers, ["Content-Type": "application/x-www-form-urlencoded",
                                         "Accept": "application/json", "Accept-Language": "en",
                                         "User-Agent": userAgent])
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self),
                       "increment_uses_count=false&license_key=AB%20CD%2B%2F%3D%26&product_id=p%3D1")
    }

    func testActivationLooksFirstThenCountsOnceWithTheConfiguredProduct() async throws {
        enqueue(verified(uses: 0), verified(uses: 1))
        let activated = try await backend().activate(key: Fixtures.gumroadKey, label: "Mac 7F3A", existing: nil).get()

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(body(0), lookingBody)
        XCTAssertEqual(body(1), countingBody)
        XCTAssertEqual(activated.gumroadProductID, Fixtures.gumroadProductID)
    }

    func testValidateNeverCountsAndSendsTheRecordsProductID() async {
        enqueue(verified(uses: 2))
        _ = await backend(productID: Fixtures.otherGumroadProductID).validate(record())
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(body(0), lookingBody)
        XCTAssertFalse(body(0).contains("AnotherFixtureProduct"))
    }

    // MARK: - Activation and seats

    func testActivationRecordIsStampedForGumroad() async throws {
        enqueue(verified(uses: 0, quantity: 1), verified(uses: 1, quantity: 1))
        let before = Date()
        let activated = try await backend().activate(key: Fixtures.gumroadKey, label: "Mac 7F3A", existing: nil).get()

        XCTAssertEqual(activated.schema, 1)
        XCTAssertEqual(activated.backend, .gumroad)
        XCTAssertEqual(activated.apiHost, "api.gumroad.com")
        XCTAssertNil(activated.organizationID)
        XCTAssertNil(activated.benefitID)
        XCTAssertNil(activated.activationID)
        XCTAssertNil(activated.licenseKeyID)
        XCTAssertEqual(activated.label, "")
        XCTAssertEqual(activated.key, Fixtures.gumroadKey)
        XCTAssertEqual(activated.displayKey, "****-7E8F90")
        XCTAssertEqual(activated.seatLimit, 3)
        XCTAssertEqual(activated.activatedAt, activated.lastValidatedAt)
        XCTAssertGreaterThanOrEqual(activated.activatedAt, before)
        XCTAssertNil(activated.pendingRevocation)
    }

    func testCountedHashIsRememberedAndMakesReentryFree() async throws {
        enqueue(verified(uses: 0), verified(uses: 1))
        let gumroad = backend()
        _ = try await gumroad.activate(key: Fixtures.gumroadKey, label: "", existing: nil).get()

        let hash = GumroadLicenseBackend.countedHash(productID: Fixtures.gumroadProductID, key: Fixtures.gumroadKey)
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(hash, hash.lowercased())
        XCTAssertEqual(try store.loadGumroadCounted().get(), GumroadCountedKeys(schema: 1, hashes: [hash]))
        XCTAssertEqual(store.writes, ["saveGumroadCounted"])

        // A reinstall or a re-entry: looks, finds the hash, and never counts again, even with every seat used.
        enqueue(verified(uses: 3))
        let again = try await gumroad.activate(key: Fixtures.gumroadKey, label: "", existing: nil).get()
        XCTAssertEqual(again.key, Fixtures.gumroadKey)
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(body(2), lookingBody)
        XCTAssertEqual(store.writes, ["saveGumroadCounted"])
    }

    func testCountedHashesStaySortedAndUnique() async throws {
        let other = GumroadLicenseBackend.countedHash(productID: Fixtures.gumroadProductID, key: "OTHER")
        let zero = String(repeating: "0", count: 64)
        let store = FakeLicenseStore(counted: GumroadCountedKeys(schema: 1, hashes: [zero, other]))
        self.store = store
        enqueue(verified(uses: 0), verified(uses: 1))
        _ = try await backend().activate(key: Fixtures.gumroadKey, label: "", existing: nil).get()

        let hash = GumroadLicenseBackend.countedHash(productID: Fixtures.gumroadProductID, key: Fixtures.gumroadKey)
        XCTAssertEqual(try store.loadGumroadCounted().get()?.hashes, [zero, other, hash].sorted())
    }

    func testHashDependsOnProductAndKey() {
        let hash = GumroadLicenseBackend.countedHash(productID: "p", key: "k")
        // printf 'p|k' | shasum -a 256
        XCTAssertEqual(hash, "858a2116bd8ce4146b3449d9cf7a458d9631193f62ec93d5fc188bcac68f9fa1")
        XCTAssertEqual(GumroadLicenseBackend.countedHash(productID: Fixtures.gumroadProductID, key: Fixtures.gumroadKey),
                       "07bcd86500ab2895a92b38ccfd916375b2ae791239fc4ec1fb8c821d9bed13ae")
        XCTAssertNotEqual(hash, GumroadLicenseBackend.countedHash(productID: "q", key: "k"))
        XCTAssertNotEqual(hash, GumroadLicenseBackend.countedHash(productID: "p", key: "K"))
    }

    func testSeatLimitIsThreeTimesQuantity() async throws {
        enqueue(verified(uses: 3, quantity: 1))
        let full = await backend().activate(key: Fixtures.gumroadKey, label: "", existing: nil)
        XCTAssertEqual(full, .failure(.seatLimitReached(limit: 3)))
        XCTAssertEqual(transport.requests.count, 1, "no counting call once the seats are used")

        enqueue(verified(uses: 5, quantity: 2), verified(uses: 6, quantity: 2))
        let twoLicenses = try await backend().activate(key: Fixtures.gumroadKey, label: "", existing: nil).get()
        XCTAssertEqual(twoLicenses.seatLimit, 6)

        store = FakeLicenseStore()
        enqueue(verified(uses: 6, quantity: 2))
        let fullTwo = await backend().activate(key: Fixtures.gumroadKey, label: "", existing: nil)
        XCTAssertEqual(fullTwo, .failure(.seatLimitReached(limit: 6)))

        store = FakeLicenseStore()
        enqueue(verified(uses: 0, quantity: 0), verified(uses: 1, quantity: 0))
        let zeroQuantity = try await backend().activate(key: Fixtures.gumroadKey, label: "", existing: nil).get()
        XCTAssertEqual(zeroQuantity.seatLimit, 3)
    }

    func testActivationRefusesRefundedAndDisputedKeys() async {
        enqueue(verified(refunded: true))
        enqueue(verified(chargebacked: true))
        enqueue(verified(disputed: true, disputeWon: false))
        let gumroad = backend()
        for _ in 0..<3 {
            let result = await gumroad.activate(key: Fixtures.gumroadKey, label: "", existing: nil)
            XCTAssertEqual(result, .failure(.keyNotActive))
        }
        XCTAssertEqual(transport.requests.count, 3, "never counts a key that isn't active")
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testActivationErrorRows() async {
        enqueue(Fixtures.gumroadNotFound, Fixtures.gumroadDisabled, Fixtures.gumroadMissingProductID,
                LicenseHTTPResponse(status: 404, headers: [:], body: Data("<html>Not Found</html>".utf8)),
                LicenseHTTPResponse(status: 400, headers: [:], body: Data()))
        let gumroad = backend()
        var results: [Result<LicenseRecord, LicenseActivationError>] = []
        for _ in 0..<6 { results.append(await gumroad.activate(key: Fixtures.gumroadKey, label: "", existing: nil)) }
        XCTAssertEqual(results, [
            .failure(.keyNotFound),
            .failure(.keyNotFound),
            .failure(.unavailable(.misconfigured("Gumroad rejected the product id"))),
            .failure(.unavailable(.unexpectedResponse(status: 404))),
            .failure(.unavailable(.misconfigured("Gumroad rejected the product id"))),
            .failure(.unavailable(.offline)),
        ])
    }

    func testCountingCallFailureIsReportedAndNothingIsRemembered() async {
        enqueue(verified(uses: 0), LicenseHTTPResponse(status: 503, headers: [:], body: Data()))
        let result = await backend().activate(key: Fixtures.gumroadKey, label: "", existing: nil)
        XCTAssertEqual(result, .failure(.unavailable(.server(status: 503))))
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testUnreadableCountedStoreIsNeverOverwritten() async throws {
        store.loadFailure = .undecodable(account: "gumroad-counted.sandbox", createdAt: nil)
        enqueue(verified(uses: 0), verified(uses: 1))
        let activated = try await backend().activate(key: Fixtures.gumroadKey, label: "", existing: nil).get()
        XCTAssertEqual(activated.backend, .gumroad)
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testCountedSaveFailureStillActivates() async throws {
        store.saveFailure = .keychain(-25_308)
        enqueue(verified(uses: 0), verified(uses: 1))
        let activated = try await backend().activate(key: Fixtures.gumroadKey, label: "", existing: nil).get()
        XCTAssertEqual(activated.backend, .gumroad)
        XCTAssertEqual(store.writes, ["saveGumroadCounted"])
    }

    // MARK: - Classification

    func testClassifyRows() {
        func classify(_ response: LicenseHTTPResponse) -> GumroadAPI.Answer {
            GumroadAPI.classify(status: response.status, headers: response.headers, body: response.body)
        }
        XCTAssertEqual(classify(verified(uses: 2, quantity: 1)),
                       .verified(GumroadAPI.Verification(uses: 2, quantity: 1, refunded: false, chargebacked: false,
                                                         disputed: false, disputeWon: false)))
        XCTAssertEqual(classify(Fixtures.gumroadNotFound), .notFound)
        XCTAssertEqual(classify(Fixtures.gumroadDisabled), .notFound)
        XCTAssertEqual(classify(LicenseHTTPResponse(status: 404, headers: [:], body: Data("Not Found".utf8))),
                       .unavailable(.unexpectedResponse(status: 404)))
        XCTAssertEqual(classify(LicenseHTTPResponse(status: 404, headers: [:], body: Data(#"{"error":"x"}"#.utf8))),
                       .unavailable(.unexpectedResponse(status: 404)))
        XCTAssertEqual(classify(Fixtures.gumroadMissingProductID), .productRejected)
        XCTAssertEqual(classify(LicenseHTTPResponse(status: 400, headers: [:], body: Data())), .productRejected)
        XCTAssertEqual(classify(LicenseHTTPResponse(status: 500, headers: [:], body: Data("oops".utf8))),
                       .unavailable(.server(status: 500)))
        XCTAssertEqual(classify(LicenseHTTPResponse(status: 502, headers: [:], body: Data())),
                       .unavailable(.server(status: 502)))
        XCTAssertEqual(classify(LicenseHTTPResponse(status: 429, headers: ["retry-after": "12"], body: Data())),
                       .unavailable(.rateLimited(retryAfter: 12)))
        XCTAssertEqual(classify(LicenseHTTPResponse(status: 200, headers: [:], body: Data(#"{"success":false}"#.utf8))),
                       .unavailable(.unexpectedResponse(status: 200)))
        XCTAssertEqual(classify(LicenseHTTPResponse(status: 200, headers: [:], body: Data("{}".utf8))),
                       .unavailable(.unexpectedResponse(status: 200)))
        XCTAssertEqual(classify(LicenseHTTPResponse(status: 302, headers: [:], body: Data())),
                       .unavailable(.unexpectedResponse(status: 302)))
    }

    // MARK: - Validate

    func testValidateOutcomes() async {
        enqueue(verified(uses: 1, quantity: 2),
                verified(refunded: true),
                verified(chargebacked: true),
                verified(disputed: true, disputeWon: false),
                verified(disputed: true, disputeWon: true),
                Fixtures.gumroadNotFound,
                Fixtures.gumroadDisabled,
                LicenseHTTPResponse(status: 404, headers: [:], body: Data("<html>".utf8)),
                Fixtures.gumroadMissingProductID,
                LicenseHTTPResponse(status: 429, headers: [:], body: Data()))
        transport.enqueue(verifyURL, .failure(.timeout))
        let gumroad = backend()
        var outcomes: [LicenseCheckOutcome] = []
        for _ in 0..<12 { outcomes.append(await gumroad.validate(record())) }
        XCTAssertEqual(outcomes, [
            .valid(LicenseValidation(seatLimit: 6, displayKey: nil)),
            .gone(.refunded),
            .gone(.chargedBack),
            .gone(.chargedBack),
            .valid(LicenseValidation(seatLimit: 3, displayKey: nil)),
            .gone(.disabled),
            .gone(.disabled),
            .unavailable(.unexpectedResponse(status: 404)),
            .unavailable(.misconfigured("Gumroad rejected the product id")),
            .unavailable(.rateLimited(retryAfter: nil)),
            .unavailable(.timeout),
            .unavailable(.offline),
        ])
        XCTAssertTrue(transport.requests.allSatisfy {
            String(decoding: $0.body, as: UTF8.self).hasPrefix("increment_uses_count=false&")
        })
    }

    func testRecordUnderAnotherProductNeverReadsGone() async {
        let gumroad = backend(productID: Fixtures.otherGumroadProductID)
        let recordA = record(productID: Fixtures.gumroadProductID)
        enqueue(verified(uses: 1), Fixtures.gumroadNotFound, verified(refunded: true),
                verified(disputed: true, disputeWon: false))
        var outcomes: [LicenseCheckOutcome] = []
        for _ in 0..<4 { outcomes.append(await gumroad.validate(recordA)) }

        XCTAssertEqual(outcomes, [
            .valid(LicenseValidation(seatLimit: 3, displayKey: nil)),
            .unavailable(.recordMismatch),
            .unavailable(.recordMismatch),
            .unavailable(.recordMismatch),
        ])
        XCTAssertTrue(transport.requests.allSatisfy {
            String(decoding: $0.body, as: UTF8.self).hasSuffix("product_id=OttoFixtureProduct%3D%3D")
        })
        let now = recordA.lastValidatedAt.addingTimeInterval(86_400)
        guard case .keep(let kept) = LicensePolicy.apply(outcomes[1], to: recordA, trial: nil, now: now) else {
            return XCTFail("the policy revoked a mismatched record")
        }
        XCTAssertNil(kept.pendingRevocation)
    }

    func testRecordFromAnotherHostOrIncompleteSendsNothing() async {
        var noProduct = record()
        noProduct.gumroadProductID = nil
        let gumroad = backend()
        let otherHost = await gumroad.validate(record(host: "api.polar.sh"))
        let incomplete = await gumroad.validate(noProduct)
        XCTAssertEqual(otherHost, .unavailable(.recordMismatch))
        XCTAssertEqual(incomplete, .unavailable(.recordMismatch))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: - Deactivate

    func testDeactivationIsLocalOnlyAndKeepsTheSeatCounted() async {
        let hash = GumroadLicenseBackend.countedHash(productID: Fixtures.gumroadProductID, key: Fixtures.gumroadKey)
        store = FakeLicenseStore(counted: GumroadCountedKeys(schema: 1, hashes: [hash]))
        let outcome = await backend().deactivate(record())
        XCTAssertEqual(outcome, .localOnly)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertEqual(try store.loadGumroadCounted().get()?.hashes, [hash])
    }

    // MARK: - Privacy

    func testBuyerDetailsNeverReachARecordOrAMessage() async throws {
        let personal = ["buyer@example.com", "Fixture Buyer", "United States", "1234567890", "4242", "fixture-sale=="]
        let fixture = String(decoding: verified().body, as: UTF8.self)
        XCTAssertTrue(personal.allSatisfy { fixture.contains($0) }, "the fixture must carry the buyer on purpose")

        enqueue(verified(uses: 0), verified(uses: 1), verified(uses: 1))
        let gumroad = backend()
        let activated = try await gumroad.activate(key: Fixtures.gumroadKey, label: "", existing: nil).get()
        let validation = await gumroad.validate(activated)

        let stored = try LicenseCodec.encode(activated)
        let counted = try LicenseCodec.encode(try XCTUnwrap(try store.loadGumroadCounted().get()))
        let messages = [String(describing: activated), String(describing: validation),
                        String(describing: GumroadAPI.classify(status: 200, headers: [:], body: verified().body))]
        for value in personal {
            XCTAssertFalse(stored.contains(value), value)
            XCTAssertFalse(counted.contains(value), value)
            for message in messages { XCTAssertFalse(message.contains(value), value) }
        }
        XCTAssertFalse(counted.contains(Fixtures.gumroadKey), "the counted store keeps hashes, never keys")
    }
}
#endif
