//
//  PolarLicenseBackendTests.swift
//  OttoTests
//
//  Polar's license backend against FakeLicenseTransport and the recorded answers in LicenseFixtures: exact requests,
//  every classification row (including the four live captures of 2026-09-27), the single unpinned retry, the 403
//  paths, re-keying, and records that carry their own host and IDs. Nothing here touches the network.
//

#if OTTO_LICENSING
import OSLog
import XCTest
@testable import Otto

final class PolarLicenseBackendTests: XCTestCase {
    private typealias Fixtures = LicenseFixtures

    private let host = LicenseConfiguration.polarProductionHost
    private let userAgent = "Otto/1.1.0"
    private let label = "Mac 7F3A"
    private var transport = FakeLicenseTransport()

    override func setUp() {
        super.setUp()
        transport = FakeLicenseTransport()
    }

    // MARK: - Helpers

    private func configuration(organizationID: String = Fixtures.organizationID,
                               benefitID: String = Fixtures.benefitID,
                               host: String? = nil) -> PolarConfiguration {
        PolarConfiguration(apiHost: host ?? self.host, organizationID: organizationID, benefitID: benefitID,
                           portalSlug: "otto")
    }

    private func backend(_ configuration: PolarConfiguration? = nil) -> PolarLicenseBackend {
        PolarLicenseBackend(configuration: configuration ?? self.configuration(), transport: transport,
                            userAgent: userAgent)
    }

    private func url(_ operation: String, host: String? = nil) -> String {
        "https://\(host ?? self.host)/v1/customer-portal/license-keys/\(operation)"
    }

    private func record(organizationID: String = Fixtures.organizationID, benefitID: String = Fixtures.benefitID,
                        host: String? = nil, pending: PendingRevocation? = nil) -> LicenseRecord {
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        return LicenseRecord(schema: 1, backend: .polar, apiHost: host ?? self.host, organizationID: organizationID,
                             benefitID: benefitID, gumroadProductID: nil, key: Fixtures.polarKey,
                             licenseKeyID: Fixtures.licenseKeyID, activationID: Fixtures.activationID, label: label,
                             displayKey: Fixtures.polarDisplayKey, seatLimit: 3, activatedAt: date,
                             lastValidatedAt: date, lastAttemptAt: date, pendingRevocation: pending)
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    private func expectedHeaders(pinned: Bool = true) -> [String: String] {
        var headers = ["Content-Type": "application/json", "Accept": "application/json", "Accept-Language": "en",
                       "User-Agent": userAgent]
        if pinned { headers["Polar-Version"] = "2026-10" }
        return headers
    }

    /// A documented 200 answer with one field changed.
    private func editing(_ response: LicenseHTTPResponse, _ change: (inout [String: Any]) -> Void) -> LicenseHTTPResponse {
        var object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        change(&object)
        var edited = response
        edited.body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return edited
    }

    private func validated(limit: Int? = 3, benefitID: String = Fixtures.benefitID) -> LicenseHTTPResponse {
        Fixtures.polarValidated(benefitID: benefitID, activationID: Fixtures.activationID, limit: limit)
    }

    // MARK: - Requests are exact

    func testActivateRequestHasExactURLHeadersAndBody() async {
        transport.enqueue(url("activate"), .success(Fixtures.polarActivated(benefitID: Fixtures.benefitID, limit: 3)))
        _ = await backend().activate(key: Fixtures.polarKey, label: label, existing: nil)

        XCTAssertEqual(transport.requests.count, 1)
        let request = transport.requests[0]
        XCTAssertEqual(request.url.absoluteString, url("activate"))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers, expectedHeaders())
        XCTAssertEqual(text(request.body), #"{"key":"OTTO-1C285B2D-6CE6-4BC7-B8BE-ADB6A7E304DA","label":"Mac 7F3A","#
                       + #""organization_id":"3b0d8c2e-5f1a-4e6b-9c7d-2a4f6e8b0c1d"}"#)
    }

    func testValidateRequestHasExactURLHeadersAndBody() async {
        transport.enqueue(url("validate"), .success(validated()))
        _ = await backend().validate(record())

        let request = transport.requests[0]
        XCTAssertEqual(request.url.absoluteString, url("validate"))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers, expectedHeaders())
        XCTAssertEqual(text(request.body), #"{"activation_id":"b6724bc8-7ad9-4ca0-b143-7c896fcbb6fe","#
                       + #""benefit_id":"c4e6a8b0-2d4f-4b6d-8f0a-6c8e0a2c4e6f","#
                       + #""key":"OTTO-1C285B2D-6CE6-4BC7-B8BE-ADB6A7E304DA","#
                       + #""organization_id":"3b0d8c2e-5f1a-4e6b-9c7d-2a4f6e8b0c1d"}"#)
        for field in ["increment_usage", "conditions", "customer_id", "meta"] {
            XCTAssertFalse(text(request.body).contains(field), field)
        }
    }

    func testDeactivateRequestHasExactURLHeadersAndBody() async {
        transport.enqueue(url("deactivate"), .success(Fixtures.polarDeactivated))
        let outcome = await backend().deactivate(record())

        XCTAssertEqual(outcome, .freedSeat)
        let request = transport.requests[0]
        XCTAssertEqual(request.url.absoluteString, url("deactivate"))
        XCTAssertEqual(request.headers, expectedHeaders())
        XCTAssertEqual(text(request.body), #"{"activation_id":"b6724bc8-7ad9-4ca0-b143-7c896fcbb6fe","#
                       + #""key":"OTTO-1C285B2D-6CE6-4BC7-B8BE-ADB6A7E304DA","#
                       + #""organization_id":"3b0d8c2e-5f1a-4e6b-9c7d-2a4f6e8b0c1d"}"#)
    }

    func testSandboxConfigurationSendsToTheSandboxHost() async {
        let sandbox = LicenseConfiguration.polarSandboxHost
        transport.enqueue(url("validate", host: sandbox), .success(validated()))
        let outcome = await backend(configuration(host: sandbox)).validate(record(host: sandbox))
        XCTAssertEqual(outcome, .valid(LicenseValidation(seatLimit: 3, displayKey: Fixtures.polarDisplayKey)))
        XCTAssertEqual(transport.requests.map(\.url.absoluteString), [url("validate", host: sandbox)])
    }

    // MARK: - Classification (pure)

    func testClassifyLiveCaptures() {
        func classify(_ response: LicenseHTTPResponse) -> PolarAPI.Answer {
            PolarAPI.classify(status: response.status, headers: response.headers, body: response.body)
        }
        // Pinned 2026-10: echoed, ResourceNotFound → definitive.
        XCTAssertEqual(classify(Fixtures.polarNotFoundPinned), .notFound)
        // Unpinned: Polar echoes 2026-04 with the same body → definitive.
        XCTAssertEqual(classify(Fixtures.polarNotFoundUnpinned), .notFound)
        // A refused version (2026-07): bare 404, no polar-version → retry without the pin.
        XCTAssertEqual(classify(Fixtures.polarVersionRefused), .unversionedNotFound)
        // A bad UUID: 422 RequestValidationError.
        XCTAssertEqual(classify(Fixtures.polarValidationError), .requestRejected)
    }

    func testClassifyEveryOtherRow() {
        let json = Data(#"{"error":"ResourceNotFound","detail":"Not found"}"#.utf8)
        XCTAssertEqual(PolarAPI.classify(status: 200, headers: [:], body: Data("{}".utf8)), .success(Data("{}".utf8)))
        XCTAssertEqual(PolarAPI.classify(status: 204, headers: [:], body: Data()), .success(Data()))
        // A 404 needs both the echo and the error code to be definitive.
        XCTAssertEqual(PolarAPI.classify(status: 404, headers: [:], body: json), .unversionedNotFound)
        XCTAssertEqual(PolarAPI.classify(status: 404, headers: ["polar-version": ""], body: json), .unversionedNotFound)
        XCTAssertEqual(PolarAPI.classify(status: 404, headers: ["polar-version": "2026-10"],
                                         body: Data(#"{"detail":"Not Found"}"#.utf8)), .unversionedNotFound)
        XCTAssertEqual(PolarAPI.classify(status: 404, headers: ["polar-version": "2026-10"], body: Data("<html>".utf8)),
                       .unversionedNotFound)
        XCTAssertEqual(PolarAPI.classify(status: 404, headers: ["Polar-Version": "2026-10"], body: json), .notFound)
        // 403 is NotPermitted only with that error code.
        XCTAssertEqual(PolarAPI.classify(status: 403, headers: Fixtures.polarNotPermitted.headers,
                                         body: Fixtures.polarNotPermitted.body), .notPermitted)
        XCTAssertEqual(PolarAPI.classify(status: 403, headers: Fixtures.polarNotPermittedNoActivations.headers,
                                         body: Fixtures.polarNotPermittedNoActivations.body), .notPermitted)
        XCTAssertEqual(PolarAPI.classify(status: 403, headers: [:], body: Data(#"{"detail":"Forbidden"}"#.utf8)),
                       .unavailable(.unexpectedResponse(status: 403)))
        XCTAssertEqual(PolarAPI.classify(status: 422, headers: [:], body: Data()), .requestRejected)
        XCTAssertEqual(PolarAPI.classify(status: 429, headers: ["retry-after": "7"], body: Data()),
                       .unavailable(.rateLimited(retryAfter: 7)))
        XCTAssertEqual(PolarAPI.classify(status: 429, headers: [:], body: Data()),
                       .unavailable(.rateLimited(retryAfter: nil)))
        XCTAssertEqual(PolarAPI.classify(status: 429, headers: ["retry-after": "Wed, 21 Oct 2026 07:28:00 GMT"],
                                         body: Data()), .unavailable(.rateLimited(retryAfter: nil)))
        XCTAssertEqual(PolarAPI.classify(status: 500, headers: [:], body: Data()), .unavailable(.server(status: 500)))
        XCTAssertEqual(PolarAPI.classify(status: 503, headers: [:], body: Data()), .unavailable(.server(status: 503)))
        XCTAssertEqual(PolarAPI.classify(status: 301, headers: [:], body: Data()),
                       .unavailable(.unexpectedResponse(status: 301)))
        XCTAssertEqual(PolarAPI.classify(status: 401, headers: [:], body: Data()),
                       .unavailable(.unexpectedResponse(status: 401)))
    }

    func testTransportErrorsAreUnavailable() async {
        transport.enqueue(url("validate"), .failure(.timeout))
        transport.enqueue(url("validate"), .failure(.other("TLS")))
        let polar = backend()
        let timedOut = await polar.validate(record())
        let other = await polar.validate(record())
        let offline = await polar.validate(record()) // nothing queued: the fake throws .offline
        XCTAssertEqual(timedOut, .unavailable(.timeout))
        XCTAssertEqual(other, .unavailable(.offline))
        XCTAssertEqual(offline, .unavailable(.offline))
    }

    func testServerAndRateLimitAnswersNeverDowngrade() async {
        transport.enqueue(url("validate"), .success(LicenseHTTPResponse(status: 502, headers: [:], body: Data())))
        transport.enqueue(url("validate"), .success(LicenseHTTPResponse(status: 429, headers: ["retry-after": "30"],
                                                                        body: Data())))
        let polar = backend()
        let server = await polar.validate(record())
        let limited = await polar.validate(record())
        XCTAssertEqual(server, .unavailable(.server(status: 502)))
        XCTAssertEqual(limited, .unavailable(.rateLimited(retryAfter: 30)))
        XCTAssertEqual(transport.requests.count, 2, "no retry on 429 or 5xx")
    }

    // MARK: - The single retry without Polar-Version

    func testBareNotFoundRetriesOnceUnpinnedAndTheVersionedAnswerCounts() async {
        transport.enqueue(url("validate"), .success(Fixtures.polarVersionRefused))
        transport.enqueue(url("validate"), .success(Fixtures.polarNotFoundUnpinned))
        let outcome = await backend().validate(record())

        XCTAssertEqual(outcome, .gone(.notFound))
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].headers["Polar-Version"], "2026-10")
        XCTAssertEqual(transport.requests[1].headers, expectedHeaders(pinned: false))
        XCTAssertEqual(transport.requests[1].body, transport.requests[0].body)
        XCTAssertEqual(transport.requests[1].url, transport.requests[0].url)
    }

    func testRetryThatIsStillBareIsVersionRefused() async {
        transport.enqueue(url("validate"), .success(Fixtures.polarVersionRefused))
        transport.enqueue(url("validate"), .success(Fixtures.polarVersionRefused))
        let outcome = await backend().validate(record())
        XCTAssertEqual(outcome, .unavailable(.versionRefused))
        XCTAssertEqual(transport.requests.count, 2, "exactly one retry")
    }

    func testRetryAnswersMapNormally() async {
        transport.enqueue(url("validate"), .success(Fixtures.polarVersionRefused))
        transport.enqueue(url("validate"), .success(validated()))
        transport.enqueue(url("validate"), .success(Fixtures.polarVersionRefused))
        transport.enqueue(url("validate"), .success(LicenseHTTPResponse(status: 500, headers: [:], body: Data())))
        transport.enqueue(url("activate"), .success(Fixtures.polarVersionRefused))
        transport.enqueue(url("activate"), .success(Fixtures.polarNotFoundUnpinned))
        let polar = backend()
        let valid = await polar.validate(record())
        let server = await polar.validate(record())
        let activation = await polar.activate(key: Fixtures.polarKey, label: label, existing: nil)
        XCTAssertEqual(valid, .valid(LicenseValidation(seatLimit: 3, displayKey: Fixtures.polarDisplayKey)))
        XCTAssertEqual(server, .unavailable(.server(status: 500)))
        XCTAssertEqual(activation, .failure(.keyNotFound))
    }

    // MARK: - Activate mappings

    func testActivateStampsTheConfigurationOnTheRecord() async throws {
        transport.enqueue(url("activate"), .success(Fixtures.polarActivated(benefitID: Fixtures.benefitID, limit: 3)))
        let before = Date()
        let activated = try await backend().activate(key: Fixtures.polarKey, label: label, existing: nil).get()

        XCTAssertEqual(activated.schema, 1)
        XCTAssertEqual(activated.backend, .polar)
        XCTAssertEqual(activated.apiHost, host)
        XCTAssertEqual(activated.organizationID, Fixtures.organizationID)
        XCTAssertEqual(activated.benefitID, Fixtures.benefitID)
        XCTAssertNil(activated.gumroadProductID)
        XCTAssertEqual(activated.key, Fixtures.polarKey)
        XCTAssertEqual(activated.activationID, Fixtures.activationID)
        XCTAssertEqual(activated.licenseKeyID, Fixtures.licenseKeyID)
        XCTAssertEqual(activated.label, label)
        XCTAssertEqual(activated.displayKey, Fixtures.polarDisplayKey)
        XCTAssertEqual(activated.seatLimit, 3)
        XCTAssertEqual(activated.activatedAt, activated.lastValidatedAt)
        XCTAssertGreaterThanOrEqual(activated.activatedAt, before)
        XCTAssertNil(activated.pendingRevocation)
    }

    func testActivateDefinitiveNotFoundIsKeyNotFound() async {
        transport.enqueue(url("activate"), .success(Fixtures.polarNotFoundPinned))
        let result = await backend().activate(key: Fixtures.polarKey, label: label, existing: nil)
        XCTAssertEqual(result, .failure(.keyNotFound))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testActivateValidationErrorIsMalformedKey() async {
        transport.enqueue(url("activate"), .success(Fixtures.polarValidationError))
        let result = await backend().activate(key: "not-a-key", label: label, existing: nil)
        XCTAssertEqual(result, .failure(.malformedKey))
    }

    func testActivateAnswerMissingRequiredFieldsIsUnexpected() async {
        transport.enqueue(url("activate"), .success(LicenseHTTPResponse(status: 200, headers: [:],
                                                                        body: Data(#"{"id":"x"}"#.utf8))))
        let result = await backend().activate(key: Fixtures.polarKey, label: label, existing: nil)
        XCTAssertEqual(result, .failure(.unavailable(.unexpectedResponse(status: 200))))
    }

    func testActivateForAnotherBenefitGivesTheSeatBackAndIsWrongProduct() async {
        transport.enqueue(url("activate"),
                          .success(Fixtures.polarActivated(benefitID: Fixtures.otherBenefitID, limit: 3)))
        transport.enqueue(url("deactivate"), .success(Fixtures.polarDeactivated))
        let result = await backend().activate(key: Fixtures.polarKey, label: label, existing: nil)

        XCTAssertEqual(result, .failure(.wrongProduct))
        XCTAssertEqual(transport.requests.map(\.url.absoluteString), [url("activate"), url("deactivate")])
        XCTAssertEqual(text(transport.requests[1].body), #"{"activation_id":"b6724bc8-7ad9-4ca0-b143-7c896fcbb6fe","#
                       + #""key":"OTTO-1C285B2D-6CE6-4BC7-B8BE-ADB6A7E304DA","#
                       + #""organization_id":"3b0d8c2e-5f1a-4e6b-9c7d-2a4f6e8b0c1d"}"#)
    }

    func testWrongProductStaysWrongProductWhenTheBestEffortDeactivateFails() async {
        transport.enqueue(url("activate"),
                          .success(Fixtures.polarActivated(benefitID: Fixtures.otherBenefitID, limit: 3)))
        let result = await backend().activate(key: Fixtures.polarKey, label: label, existing: nil)
        XCTAssertEqual(result, .failure(.wrongProduct))
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testNotPermittedWithALimitIsSeatLimitReached() async {
        transport.enqueue(url("activate"), .success(Fixtures.polarNotPermitted))
        transport.enqueue(url("validate"), .success(Fixtures.polarValidated(benefitID: Fixtures.benefitID,
                                                                            activationID: nil, limit: 3)))
        let result = await backend().activate(key: Fixtures.polarKey, label: label, existing: nil)

        XCTAssertEqual(result, .failure(.seatLimitReached(limit: 3)))
        let follow = transport.requests[1]
        XCTAssertEqual(follow.url.absoluteString, url("validate"))
        XCTAssertEqual(follow.headers, expectedHeaders())
        XCTAssertEqual(text(follow.body), #"{"benefit_id":"c4e6a8b0-2d4f-4b6d-8f0a-6c8e0a2c4e6f","#
                       + #""key":"OTTO-1C285B2D-6CE6-4BC7-B8BE-ADB6A7E304DA","#
                       + #""organization_id":"3b0d8c2e-5f1a-4e6b-9c7d-2a4f6e8b0c1d"}"#)
    }

    func testNotPermittedWithoutALimitIsMisconfiguredNeverSeatLimit() async {
        transport.enqueue(url("activate"), .success(Fixtures.polarNotPermittedNoActivations))
        transport.enqueue(url("validate"), .success(Fixtures.polarValidated(benefitID: Fixtures.benefitID,
                                                                            activationID: nil, limit: nil)))
        let result = await backend().activate(key: Fixtures.polarKey, label: label, existing: nil)

        XCTAssertEqual(result, .failure(.unavailable(.misconfigured("Polar benefit has no activation limit"))))
        XCTAssertNotEqual(result, .failure(.seatLimitReached(limit: nil)))
    }

    func testNotPermittedThenNotFoundIsKeyNotActive() async {
        transport.enqueue(url("activate"), .success(Fixtures.polarNotPermitted))
        transport.enqueue(url("validate"), .success(Fixtures.polarNotFoundPinned))
        let result = await backend().activate(key: Fixtures.polarKey, label: label, existing: nil)
        XCTAssertEqual(result, .failure(.keyNotActive))
    }

    func testNotPermittedThenAnOutageIsUnavailable() async {
        transport.enqueue(url("activate"), .success(Fixtures.polarNotPermitted))
        transport.enqueue(url("validate"), .success(LicenseHTTPResponse(status: 503, headers: [:], body: Data())))
        let result = await backend().activate(key: Fixtures.polarKey, label: label, existing: nil)
        XCTAssertEqual(result, .failure(.unavailable(.server(status: 503))))
    }

    func testActivateTransportFailureIsUnavailable() async {
        let result = await backend().activate(key: Fixtures.polarKey, label: label, existing: nil)
        XCTAssertEqual(result, .failure(.unavailable(.offline)))
    }

    // MARK: - Re-key

    func testRekeyValidatesTheNewKeyOnTheExistingActivationAndKeepsTheRecordsIDs() async throws {
        // The existing record was activated under organization and benefit A; this build is configured for B.
        let pending = PendingRevocation(firstSeenAt: Date(timeIntervalSince1970: 1_792_100_000), reason: .notFound)
        let existing = record(organizationID: Fixtures.otherOrganizationID, benefitID: Fixtures.otherBenefitID,
                              pending: pending)
        let newKey = "OTTO-2D396C3E-7DF7-4CD8-89CF-BEC7B8F415EB"
        transport.enqueue(url("validate"), .success(editing(validated(benefitID: Fixtures.otherBenefitID)) {
            $0["display_key"] = "****-F415EB"
            $0["key"] = newKey
        }))
        let activated = try await backend().activate(key: newKey, label: "Mac 0000", existing: existing).get()

        XCTAssertEqual(transport.requests.count, 1, "no new seat is taken")
        XCTAssertEqual(text(transport.requests[0].body), #"{"activation_id":"b6724bc8-7ad9-4ca0-b143-7c896fcbb6fe","#
                       + #""benefit_id":"5a7c9e1b-3d5f-4c7e-a9b1-8d0f2b4d6f8a","#
                       + #""key":"OTTO-2D396C3E-7DF7-4CD8-89CF-BEC7B8F415EB","#
                       + #""organization_id":"9e7c5a3b-1d2f-4a6c-8e0b-4d6f8a0c2e4b"}"#)
        XCTAssertEqual(activated.key, newKey)
        XCTAssertEqual(activated.displayKey, "****-F415EB")
        XCTAssertEqual(activated.apiHost, existing.apiHost)
        XCTAssertEqual(activated.organizationID, Fixtures.otherOrganizationID)
        XCTAssertEqual(activated.benefitID, Fixtures.otherBenefitID)
        XCTAssertEqual(activated.activationID, existing.activationID)
        XCTAssertEqual(activated.licenseKeyID, existing.licenseKeyID)
        XCTAssertEqual(activated.label, existing.label)
        XCTAssertEqual(activated.activatedAt, existing.activatedAt)
        XCTAssertNil(activated.pendingRevocation)
    }

    func testFailedRekeyFallsBackToANormalActivation() async throws {
        transport.enqueue(url("validate"), .success(Fixtures.polarNotFoundPinned))
        transport.enqueue(url("activate"), .success(Fixtures.polarActivated(benefitID: Fixtures.benefitID, limit: 3)))
        let existing = record(pending: PendingRevocation(firstSeenAt: Date(), reason: .notFound))
        let activated = try await backend().activate(key: Fixtures.polarKey, label: label, existing: existing).get()

        XCTAssertEqual(transport.requests.map(\.url.absoluteString), [url("validate"), url("activate")])
        XCTAssertEqual(activated.organizationID, Fixtures.organizationID)
        XCTAssertNil(activated.pendingRevocation)
    }

    func testNoRekeyForARecordFromAnotherHost() async {
        let existing = record(host: LicenseConfiguration.polarSandboxHost)
        transport.enqueue(url("activate"), .success(Fixtures.polarNotFoundPinned))
        _ = await backend().activate(key: Fixtures.polarKey, label: label, existing: existing)
        XCTAssertEqual(transport.requests.map(\.url.absoluteString), [url("activate")])
    }

    // MARK: - Validate mappings

    func testValidateGrantedIsValidWithReportedValues() async {
        transport.enqueue(url("validate"), .success(validated(limit: 5)))
        let outcome = await backend().validate(record())
        XCTAssertEqual(outcome, .valid(LicenseValidation(seatLimit: 5, displayKey: Fixtures.polarDisplayKey)))
    }

    func testValidateDefinitiveNotFoundIsGone() async {
        transport.enqueue(url("validate"), .success(Fixtures.polarNotFoundPinned))
        let outcome = await backend().validate(record())
        XCTAssertEqual(outcome, .gone(.notFound))
        XCTAssertEqual(transport.requests.count, 1, "a versioned 404 is not retried")
    }

    func testValidateOtherBenefitOrStatusIsGone() async {
        transport.enqueue(url("validate"), .success(validated(benefitID: Fixtures.otherBenefitID)))
        transport.enqueue(url("validate"), .success(editing(validated()) { $0["status"] = "revoked" }))
        let polar = backend()
        let otherBenefit = await polar.validate(record())
        let revoked = await polar.validate(record())
        XCTAssertEqual(otherBenefit, .gone(.notFound))
        XCTAssertEqual(revoked, .gone(.notFound))
    }

    func testValidateMalformedAnswersAreUnexpected() async {
        transport.enqueue(url("validate"), .success(Fixtures.polarValidationError))
        transport.enqueue(url("validate"), .success(Fixtures.polarNotPermitted))
        transport.enqueue(url("validate"), .success(editing(validated()) { $0.removeValue(forKey: "benefit_id") }))
        let polar = backend()
        let rejected = await polar.validate(record())
        let forbidden = await polar.validate(record())
        let incomplete = await polar.validate(record())
        XCTAssertEqual(rejected, .unavailable(.unexpectedResponse(status: 422)))
        XCTAssertEqual(forbidden, .unavailable(.unexpectedResponse(status: 403)))
        XCTAssertEqual(incomplete, .unavailable(.unexpectedResponse(status: 200)))
    }

    // MARK: - Deactivate mappings

    func testDeactivateOutcomes() async {
        transport.enqueue(url("deactivate"), .success(Fixtures.polarNotFoundPinned))
        transport.enqueue(url("deactivate"), .success(Fixtures.polarValidationError))
        transport.enqueue(url("deactivate"), .success(LicenseHTTPResponse(status: 500, headers: [:], body: Data())))
        let polar = backend()
        let gone = await polar.deactivate(record())
        let rejected = await polar.deactivate(record())
        let server = await polar.deactivate(record())
        let offline = await polar.deactivate(record())
        XCTAssertEqual(gone, .alreadyGone)
        XCTAssertEqual(rejected, .unavailable(.unexpectedResponse(status: 422)))
        XCTAssertEqual(server, .unavailable(.server(status: 500)))
        XCTAssertEqual(offline, .unavailable(.offline))
    }

    // MARK: - Records carry their own IDs

    func testRecordFromAnotherOrganizationSendsItsOwnIDs() async {
        let polar = backend(configuration(organizationID: Fixtures.organizationID))
        let recordA = record(organizationID: Fixtures.otherOrganizationID)
        transport.enqueue(url("validate"), .success(validated()))
        transport.enqueue(url("validate"), .success(Fixtures.polarNotFoundPinned))

        let valid = await polar.validate(recordA)
        let notFound = await polar.validate(recordA)

        XCTAssertEqual(valid, .valid(LicenseValidation(seatLimit: 3, displayKey: Fixtures.polarDisplayKey)))
        XCTAssertEqual(notFound, .unavailable(.recordMismatch))
        for request in transport.requests {
            XCTAssertTrue(text(request.body).contains(#""organization_id":"\#(Fixtures.otherOrganizationID)""#))
            XCTAssertFalse(text(request.body).contains(Fixtures.organizationID))
        }
        assertPolicyKeepsTheLicense(notFound, record: recordA)
    }

    func testRecordFromAnotherBenefitSendsItsOwnIDs() async {
        let polar = backend(configuration(benefitID: Fixtures.benefitID))
        let recordA = record(benefitID: Fixtures.otherBenefitID)
        transport.enqueue(url("validate"), .success(validated(benefitID: Fixtures.otherBenefitID)))
        transport.enqueue(url("validate"), .success(Fixtures.polarNotFoundPinned))
        transport.enqueue(url("validate"), .success(validated(benefitID: Fixtures.benefitID)))

        let valid = await polar.validate(recordA)
        let notFound = await polar.validate(recordA)
        let otherAnswer = await polar.validate(recordA)

        XCTAssertEqual(valid, .valid(LicenseValidation(seatLimit: 3, displayKey: Fixtures.polarDisplayKey)))
        XCTAssertEqual(notFound, .unavailable(.recordMismatch))
        XCTAssertEqual(otherAnswer, .unavailable(.recordMismatch))
        for request in transport.requests {
            XCTAssertTrue(text(request.body).contains(#""benefit_id":"\#(Fixtures.otherBenefitID)""#))
            XCTAssertFalse(text(request.body).contains(Fixtures.benefitID))
        }
        assertPolicyKeepsTheLicense(notFound, record: recordA)
    }

    func testDeactivateUnderAMismatchSendsTheRecordsIDsAndNeverReadsGone() async {
        let polar = backend(configuration(organizationID: Fixtures.organizationID))
        transport.enqueue(url("deactivate"), .success(Fixtures.polarDeactivated))
        transport.enqueue(url("deactivate"), .success(Fixtures.polarNotFoundPinned))
        let recordA = record(organizationID: Fixtures.otherOrganizationID)
        let freed = await polar.deactivate(recordA)
        let notFound = await polar.deactivate(recordA)
        XCTAssertEqual(freed, .freedSeat)
        XCTAssertEqual(notFound, .unavailable(.recordMismatch))
        XCTAssertTrue(transport.requests.allSatisfy {
            text($0.body).contains(#""organization_id":"\#(Fixtures.otherOrganizationID)""#)
        })
    }

    func testRecordFromAnotherHostSendsNothing() async {
        let polar = backend(configuration(host: LicenseConfiguration.polarProductionHost))
        let sandboxRecord = record(host: LicenseConfiguration.polarSandboxHost)
        let validation = await polar.validate(sandboxRecord)
        let deactivation = await polar.deactivate(sandboxRecord)
        XCTAssertEqual(validation, .unavailable(.recordMismatch))
        XCTAssertEqual(deactivation, .unavailable(.recordMismatch))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testIncompleteRecordSendsNothing() async {
        var incomplete = record()
        incomplete.benefitID = nil
        var noActivation = record()
        noActivation.activationID = nil
        let polar = backend()
        let first = await polar.validate(incomplete)
        let second = await polar.validate(noActivation)
        let third = await polar.deactivate(noActivation)
        XCTAssertEqual(first, .unavailable(.recordMismatch))
        XCTAssertEqual(second, .unavailable(.recordMismatch))
        XCTAssertEqual(third, .unavailable(.recordMismatch))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    private func assertPolicyKeepsTheLicense(_ outcome: LicenseCheckOutcome, record: LicenseRecord,
                                             file: StaticString = #filePath, line: UInt = #line) {
        let now = record.lastValidatedAt.addingTimeInterval(86_400)
        guard case .keep(let kept) = LicensePolicy.apply(outcome, to: record, trial: nil, now: now) else {
            return XCTFail("the policy revoked a mismatched record", file: file, line: line)
        }
        XCTAssertNil(kept.pendingRevocation, file: file, line: line)
        XCTAssertEqual(kept.lastValidatedAt, record.lastValidatedAt, file: file, line: line)
    }

    // MARK: - Privacy

    func testCustomerDetailsNeverReachARecordAMessageOrTheLog() async throws {
        let start = Date()
        let personal = ["buyer@example.com", "Fixture Buyer", "7d1e3f5a-9b2c-4d6e-8f0a-1b3c5d7e9f20"]
        XCTAssertTrue(personal.allSatisfy {
            text(Fixtures.polarActivated(benefitID: Fixtures.benefitID, limit: 3).body).contains($0)
        }, "the fixture must carry the customer on purpose")

        transport.enqueue(url("activate"), .success(Fixtures.polarActivated(benefitID: Fixtures.benefitID, limit: 3)))
        transport.enqueue(url("validate"), .success(validated()))
        // A fault path, so the log store has at least one License entry from this test to read.
        transport.enqueue(url("activate"), .success(Fixtures.polarNotPermittedNoActivations))
        transport.enqueue(url("validate"), .success(Fixtures.polarValidated(benefitID: Fixtures.benefitID,
                                                                            activationID: nil, limit: nil)))
        let polar = backend()
        let activated = try await polar.activate(key: Fixtures.polarKey, label: label, existing: nil).get()
        let validation = await polar.validate(activated)
        let refusal = await polar.activate(key: Fixtures.polarKey, label: label, existing: nil)

        let stored = try LicenseCodec.encode(activated)
        var messages = [String(describing: activated), String(describing: validation), String(describing: refusal)]
        if case .failure(let error) = refusal {
            messages.append(LicenseCopy.activationFailure(error, backend: .polar, supportEmail: "help@otto.test").text)
        }
        for value in personal {
            XCTAssertFalse(stored.contains(value), value)
            for message in messages { XCTAssertFalse(message.contains(value), value) }
        }

        let logs = try licenseLogLines(since: start)
        XCTAssertFalse(logs.isEmpty, "expected License log entries from this test")
        for line in logs {
            for value in personal + [Fixtures.polarKey, Fixtures.activationID, label] {
                XCTAssertFalse(line.contains(value), "a License log line carries \(value)")
            }
        }
    }

    private func licenseLogLines(since start: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@ AND category == %@", "com.jalenedusei.otto", "License")
        return try store.getEntries(at: store.position(date: start.addingTimeInterval(-1)), matching: predicate)
            .compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
    }
}
#endif
