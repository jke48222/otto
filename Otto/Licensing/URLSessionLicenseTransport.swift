//
//  URLSessionLicenseTransport.swift
//  Otto
//
//  The live LicenseHTTPTransport (§14.4.4, §14.6, §14.16): one ephemeral URLSession with no cookies, no cache and
//  no credential storage, `Accept-Language: en` pinned as a backstop, and a 15 s timeout. Redirects are never
//  followed, so a request body (which carries the key) only ever goes to the host it was built for. URLSession
//  errors map to LicenseTransportError through one pure function the tests call directly.
//

#if OTTO_LICENSING
import Foundation
import os

struct URLSessionLicenseTransport: LicenseHTTPTransport {
    /// The URLError codes that mean "this Mac can't reach the network right now" (§14.6 classification table).
    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .dataNotAllowed, .internationalRoamingOff,
    ]

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "License")

    let timeout: TimeInterval
    /// Internal so the tests can read its configuration; nothing else uses it directly.
    let session: URLSession

    init(timeout: TimeInterval = LicensePolicy.requestTimeout) {
        self.timeout = timeout
        session = URLSession(configuration: Self.makeConfiguration(timeout: timeout))
    }

    /// Ephemeral: no cookies, no URL cache, no credential storage; `Accept-Language: en` so no request carries the
    /// Mac's language list; the timeout for both the request and the whole transfer.
    static func makeConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = ["Accept-Language": "en"]
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        return configuration
    }

    /// Pure (§14.6): timedOut → .timeout; the offline codes → .offline; anything else → .other with the code.
    static func transportError(for error: URLError) -> LicenseTransportError {
        if error.code == .timedOut { return .timeout }
        if offlineCodes.contains(error.code) { return .offline }
        return .other("URLError \(error.code.rawValue)")
    }

    /// Throws LicenseTransportError only.
    func send(_ request: LicenseHTTPRequest) async throws -> LicenseHTTPResponse {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData,
                                    timeoutInterval: timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: RedirectRefuser())
        } catch let error as URLError {
            let mapped = Self.transportError(for: error)
            Self.logger.info("License request failed: URLError \(error.code.rawValue, privacy: .public)")
            throw mapped
        } catch is CancellationError {
            throw LicenseTransportError.other("cancelled")
        } catch {
            Self.logger.error("License request failed: \(String(describing: type(of: error)), privacy: .public)")
            throw LicenseTransportError.other(String(describing: type(of: error)))
        }

        guard let http = response as? HTTPURLResponse else {
            throw LicenseTransportError.other("not an HTTP response")
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        return LicenseHTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

/// Refuses every redirect, so the 3xx answer itself comes back (and classifies as an unexpected response), and
/// answers every authentication challenge other than server trust by cancelling it: Otto never sends credentials.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            return (.performDefaultHandling, nil)
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}
#endif
