//
//  URLSessionLicenseTransportTests.swift
//  OttoTests
//
//  The live transport without a single request: the pure URLError → LicenseTransportError mapping of §14.6 and the
//  ephemeral session configuration (no cookies, no cache, no credentials, Accept-Language "en", the timeout).
//

#if OTTO_LICENSING
import Foundation
import XCTest
@testable import Otto

final class URLSessionLicenseTransportTests: XCTestCase {
    func testATimeoutMapsToTimeout() {
        XCTAssertEqual(URLSessionLicenseTransport.transportError(for: URLError(.timedOut)), .timeout)
    }

    func testTheOfflineCodesMapToOffline() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .dataNotAllowed, .internationalRoamingOff,
        ]
        for code in codes {
            XCTAssertEqual(URLSessionLicenseTransport.transportError(for: URLError(code)), .offline, "\(code)")
        }
        XCTAssertEqual(URLSessionLicenseTransport.offlineCodes, Set(codes))
    }

    func testEveryOtherCodeMapsToOtherWithTheCode() {
        let codes: [URLError.Code] = [
            .secureConnectionFailed, .serverCertificateUntrusted, .badServerResponse, .cancelled,
            .httpTooManyRedirects, .userAuthenticationRequired, .unknown,
        ]
        for code in codes {
            XCTAssertEqual(URLSessionLicenseTransport.transportError(for: URLError(code)),
                           .other("URLError \(code.rawValue)"), "\(code)")
        }
    }

    func testTheSessionIsEphemeral() {
        let transport = URLSessionLicenseTransport()
        let configuration = transport.session.configuration
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.httpAdditionalHeaders?["Accept-Language"] as? String, "en")
        XCTAssertEqual(configuration.httpAdditionalHeaders?.count, 1)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    func testTheTimeoutDefaultsToFifteenSeconds() {
        let transport = URLSessionLicenseTransport()
        XCTAssertEqual(transport.timeout, LicensePolicy.requestTimeout)
        XCTAssertEqual(transport.session.configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(transport.session.configuration.timeoutIntervalForResource, 15)

        let quick = URLSessionLicenseTransport(timeout: 4)
        XCTAssertEqual(quick.session.configuration.timeoutIntervalForRequest, 4)
        XCTAssertEqual(quick.session.configuration.timeoutIntervalForResource, 4)
    }
}
#endif
