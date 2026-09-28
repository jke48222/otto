//
//  PolarSandboxLiveTests.swift
//  OttoTests
//
//  Opt-in, against sandbox-api.polar.sh only: activate, validate, deactivate a real sandbox key (gate H2). Skipped
//  unless OTTO_POLAR_SANDBOX_TESTS=1 and OTTO_TEST_POLAR_ORG, OTTO_TEST_POLAR_BENEFIT and OTTO_TEST_POLAR_KEY are
//  set (with xcodebuild, prefix each with TEST_RUNNER_). A default run never touches the network.
//

#if OTTO_LICENSING
import XCTest
@testable import Otto

final class PolarSandboxLiveTests: XCTestCase {
    private struct Settings {
        let organizationID: String
        let benefitID: String
        let key: String
    }

    private func settings() throws -> Settings {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OTTO_POLAR_SANDBOX_TESTS"] == "1" else {
            throw XCTSkip("Set OTTO_POLAR_SANDBOX_TESTS=1 to run the Polar sandbox round trip.")
        }
        guard let organizationID = environment["OTTO_TEST_POLAR_ORG"], !organizationID.isEmpty,
              let benefitID = environment["OTTO_TEST_POLAR_BENEFIT"], !benefitID.isEmpty,
              let key = environment["OTTO_TEST_POLAR_KEY"], !key.isEmpty else {
            throw XCTSkip("Set OTTO_TEST_POLAR_ORG, OTTO_TEST_POLAR_BENEFIT and OTTO_TEST_POLAR_KEY.")
        }
        return Settings(organizationID: organizationID, benefitID: benefitID, key: key)
    }

    func testSandboxActivateValidateDeactivate() async throws {
        let settings = try settings()
        let configuration = PolarConfiguration(apiHost: LicenseConfiguration.polarSandboxHost,
                                               organizationID: settings.organizationID,
                                               benefitID: settings.benefitID, portalSlug: "otto")
        let backend = PolarLicenseBackend(configuration: configuration, transport: LiveTransport(),
                                          userAgent: LicenseBackends.userAgent())

        let record = try await backend.activate(key: settings.key, label: LicenseKeyRouter.randomLabel(),
                                                existing: nil).get()
        XCTAssertEqual(record.apiHost, LicenseConfiguration.polarSandboxHost)
        XCTAssertEqual(record.organizationID, settings.organizationID)
        XCTAssertEqual(record.benefitID, settings.benefitID)
        XCTAssertNotNil(record.activationID)

        let validation = await backend.validate(record)
        guard case .valid = validation else {
            _ = await backend.deactivate(record)
            return XCTFail("validate answered \(validation)")
        }

        let deactivation = await backend.deactivate(record)
        XCTAssertEqual(deactivation, .freedSeat)
    }

    /// A minimal ephemeral URLSession transport for this opt-in test only: no cookies, no cache, no credentials.
    private struct LiveTransport: LicenseHTTPTransport {
        private let session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = LicensePolicy.requestTimeout
            configuration.httpAdditionalHeaders = ["Accept-Language": "en"]
            return URLSession(configuration: configuration)
        }()

        func send(_ request: LicenseHTTPRequest) async throws -> LicenseHTTPResponse {
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = request.method
            urlRequest.httpBody = request.body
            for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
            do {
                let (data, response) = try await session.data(for: urlRequest)
                guard let http = response as? HTTPURLResponse else { throw LicenseTransportError.other("not HTTP") }
                var headers: [String: String] = [:]
                for (name, value) in http.allHeaderFields {
                    headers[String(describing: name).lowercased()] = String(describing: value)
                }
                return LicenseHTTPResponse(status: http.statusCode, headers: headers, body: data)
            } catch let error as URLError {
                throw error.code == .timedOut ? LicenseTransportError.timeout : LicenseTransportError.offline
            }
        }
    }
}
#endif
