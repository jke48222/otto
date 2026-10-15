//
//  WebPageReader.swift
//  Otto
//
//  Reads one web page on the Mac for Setapp AI's web fetch (`SetappWebFetch`, SPEC §19). Each read is a plain GET
//  from an ephemeral URLSession (no cookies, cache or credentials) with `Accept-Language: en` and `User-Agent:
//  Otto/<version>`, like Otto's other requests, a 20 s deadline for the whole read and a 5 MB cap on what it
//  downloads. Every hop is checked before it is requested: http or https only, never from https down to http, at
//  most 5 redirects (followed here, one at a time), and a host whose address is on this Mac, the local network or
//  another private range (URLGuard's ranges) is refused, so a page can't point Otto at the user's router or a
//  service on localhost. Every request is checked again against the address its connection reached, and refused
//  when that address is local or can't be confirmed. HTML becomes readable text with HTMLText, as attachments do,
//  plain text stays as it is, and a PDF is passed on whole, the way Anthropic's fetch returns one: nothing parses
//  a PDF from the web on the Mac.
//

import Darwin
import Foundation
import os

/// A link found on a page: its text (possibly empty) and absolute http or https address, without a fragment.
struct WebLink: Equatable, Sendable {
    let text: String
    let url: URL
}

/// What a read returns: the address the content came from (after redirects), its title and readable text, or a PDF.
struct WebPage: Equatable, Sendable {
    let url: URL
    let title: String?
    let text: String
    var links: [WebLink] = []
    /// The page was longer than the download cap; `text` is what the first part held.
    var isPartial = false
    /// The PDF the address returned, whole and unparsed (`text` is then empty): the model reads it as a document.
    var pdf: Data?
}

/// Why a page couldn't be read. `message` is what Claude reads, after "Error: ".
enum WebPageReadError: Error, Equatable, Sendable {
    /// The host (or a redirect's host) is on this Mac or a local or private network.
    case blockedAddress
    case hostNotFound
    /// A redirect from https to http.
    case insecureRedirect
    /// A redirect to an address that isn't http or https, or isn't an address at all.
    case unsupportedRedirect
    case tooManyRedirects
    case httpStatus(Int)
    case timedOut
    case offline
    case secureConnectionFailed
    /// The site asked for a user name and password (or a client certificate).
    case needsSignIn
    /// The MIME type that came back, or "an unknown type".
    case unsupportedContent(String)
    case pdfTooLarge
    case pdfLocked
    /// The bytes couldn't be decoded as text, or what came back as a PDF isn't one.
    case unreadable
    case noText
    /// The connection's remote address was missing or unreadable, so Otto couldn't confirm it wasn't local.
    case unverifiedConnection
    /// Any other network failure (the URLError code).
    case failed(String)

    /// Anthropic's `web_fetch_tool_error` code for this failure.
    var code: String {
        switch self {
        case .blockedAddress: return "url_not_allowed"
        case .unsupportedContent, .pdfTooLarge, .pdfLocked, .unreadable, .noText:
            return "unsupported_content_type"
        case .offline: return "unavailable"
        case .hostNotFound, .insecureRedirect, .unsupportedRedirect, .tooManyRedirects, .httpStatus, .timedOut,
             .secureConnectionFailed, .needsSignIn, .unverifiedConnection, .failed:
            return "url_not_accessible"
        }
    }

    var message: String {
        switch self {
        case .blockedAddress:
            return "That address leads to this Mac or its local network, so Otto won't open it."
        case .hostNotFound:
            return "Otto couldn't find that site."
        case .insecureRedirect:
            return "The page redirected from https to an insecure http address, so Otto stopped."
        case .unsupportedRedirect:
            return "The page redirected to an address Otto can't open."
        case .tooManyRedirects:
            return "The page redirected more than \(WebPageReader.maxRedirects) times, so Otto stopped."
        case .httpStatus(let status) where status == 401 || status == 403:
            return "The site answered with HTTP \(status). It may need a sign-in, and Otto opens pages without the "
                + "user's accounts."
        case .httpStatus(let status):
            return "The site answered with HTTP \(status)."
        case .timedOut:
            return "The page didn't load within \(Int(WebPageReader.timeout)) seconds."
        case .offline:
            return "This Mac is offline."
        case .secureConnectionFailed:
            return "Otto couldn't make a secure connection to that site."
        case .needsSignIn:
            return "The page asks for a sign-in, and Otto opens pages without the user's accounts."
        case .unsupportedContent(let type):
            return "Otto reads web pages, plain text and PDFs, and this address returned \(type)."
        case .pdfTooLarge:
            return "The PDF is larger than 5 MB, so Otto didn't read it."
        case .pdfLocked:
            return "The PDF is protected with a password."
        case .unreadable:
            return "Otto couldn't read the page's contents."
        case .noText:
            return "The page has no text Otto can read. It may need scripts to show anything."
        case .unverifiedConnection:
            return "Otto couldn't confirm which address the page came from, so it didn't use it."
        case .failed(let detail):
            return "Otto couldn't load the page (\(detail))."
        }
    }
}

/// Reads a page; `WebPageReader` on the Mac, a stub in tests.
protocol WebPageReading: Sendable {
    /// `url` is http or https and already allowed (SetappWebFetch.Allowlist). Throws `WebPageReadError`, or
    /// `CancellationError` when the reply is stopped.
    func read(_ url: URL) async throws -> WebPage
}

/// An IP address a host resolved to, or that a connection reached.
enum ResolvedAddress: Equatable, Sendable {
    case v4(UInt32)
    case v6([UInt8])

    /// Loopback, private, link-local, CGNAT, multicast, unspecified and the other local ranges URLGuard refuses.
    var isBlocked: Bool {
        switch self {
        case .v4(let address): return URLGuard.isBlockedIPv4(address)
        case .v6(let bytes): return URLGuard.isBlockedIPv6(bytes)
        }
    }

    /// "93.184.216.34", "2606:2800:21f:cb07::1", "fe80::1%en0" (the zone is ignored).
    init?(_ text: String) {
        let bare = String(text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        var v4 = in_addr()
        if bare.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            self = .v4(UInt32(bigEndian: v4.s_addr))
        } else if let bytes = URLGuard.parseIPv6(bare) {
            self = .v6(bytes)
        } else {
            return nil
        }
    }
}

/// One connection a request used, as URLSession's task metrics describe it.
struct ConnectionRecord: Equatable, Sendable {
    /// "93.184.216.34", "2606:2800:21f:cb07::1"; nil when the metrics don't say.
    var remoteAddress: String?
    /// The connection went to a proxy, so `remoteAddress` is the proxy's.
    var isProxyConnection = false
}

struct WebPageReader: WebPageReading {
    /// Resolves a host name (ASCII) to its addresses. Tests answer from a table; nothing touches DNS.
    typealias Resolver = @Sendable (_ host: String) async throws -> [ResolvedAddress]
    /// The connections a finished request used: URLSession's metrics (`collected`, nil when they never arrived) on the
    /// Mac. Tests answer from a table, because a URLProtocol stub's metrics carry no address.
    typealias ConnectionSource = @Sendable (_ url: URL, _ collected: [ConnectionRecord]?) -> [ConnectionRecord]?

    /// For the whole read: every hop, the download and the conversion.
    static let timeout: TimeInterval = 20
    static let maxBytes = 5 * 1_024 * 1_024
    static let maxRedirects = 5
    static let acceptHeader = "text/html,application/xhtml+xml,text/plain;q=0.9,application/pdf;q=0.9,*/*;q=0.5"
    /// HTML converted past this many bytes of text is cut anyway (SetappWebFetch keeps 100,000 characters).
    static let maxHTMLTextBytes = 1_000_000
    /// How long a finished request waits for its metrics, which can arrive a little after the request ends.
    static let metricsWait: TimeInterval = 1

    /// The reader the app uses: one ephemeral session, the system resolver.
    static let live = WebPageReader()

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "WebFetch")

    let session: URLSession
    let timeout: TimeInterval
    let maxBytes: Int
    let userAgent: String
    private let resolve: Resolver
    private let connections: ConnectionSource

    /// Tests pass `protocolClasses` (a URLProtocol stub), a `resolve` table, a `connections` table and short limits.
    init(
        timeout: TimeInterval = WebPageReader.timeout,
        maxBytes: Int = WebPageReader.maxBytes,
        resolve: @escaping Resolver = { try await WebPageReader.systemResolve($0) },
        connections: @escaping ConnectionSource = { _, collected in collected },
        protocolClasses: [AnyClass]? = nil,
        userAgent: String = WebPageReader.defaultUserAgent()
    ) {
        self.timeout = timeout
        self.maxBytes = maxBytes
        self.resolve = resolve
        self.connections = connections
        self.userAgent = userAgent
        session = URLSession(configuration: Self.makeConfiguration(timeout: timeout, protocolClasses: protocolClasses))
    }

    /// "Otto/<CFBundleShortVersionString>", the user agent Otto's license requests carry too.
    static func defaultUserAgent(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Otto/\(version ?? "0")"
    }

    /// Ephemeral: no cookies, no URL cache, no credential storage; `Accept-Language: en` so no request carries the
    /// Mac's language list; the timeout for each request and for the whole transfer.
    static func makeConfiguration(timeout: TimeInterval, protocolClasses: [AnyClass]?) -> URLSessionConfiguration {
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
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return configuration
    }

    // MARK: - Reading

    func read(_ url: URL) async throws -> WebPage {
        let seconds = max(0, timeout)
        let deadline = ContinuousClock.now + .milliseconds(Int64(seconds * 1_000))
        return try await withThrowingTaskGroup(of: WebPage.self) { group in
            // The group returns only once both tasks have ended: the reading task stops at its next checkpoint when the
            // deadline passes (or the reply is stopped), because synchronous work can't be interrupted from outside.
            group.addTask { try await self.follow(url, deadline: deadline) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw WebPageReadError.timedOut
            }
            defer { group.cancelAll() }
            guard let page = try await group.next() else { throw CancellationError() }
            return page
        }
    }

    /// Throws when the read was stopped or its deadline passed.
    private static func checkpoint(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        if ContinuousClock.now >= deadline { throw WebPageReadError.timedOut }
    }

    /// Requests `start`, following each redirect only after checking where it goes.
    private func follow(_ start: URL, deadline: ContinuousClock.Instant) async throws -> WebPage {
        var url = start
        var redirects = 0
        while true {
            try Self.checkpoint(deadline)
            try await checkAddress(of: url)
            let hop = try await fetch(url)
            try Task.checkCancellation()
            // DNS can answer differently the second time it's asked, so the address the request actually reached must
            // pass the same check, whatever came back: a page, a redirect, an error status or a failure all say
            // something about what is at that address.
            try await verifyConnections(of: hop, url: url)
            if let error = hop.error { throw error }
            guard let http = hop.response else { throw WebPageReadError.failed("not an HTTP response") }
            if (300...399).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location") {
                guard redirects < Self.maxRedirects else { throw WebPageReadError.tooManyRedirects }
                redirects += 1
                url = try Self.redirectTarget(location, from: url)
                continue
            }
            guard (200...299).contains(http.statusCode) else { throw WebPageReadError.httpStatus(http.statusCode) }
            let mimeType = http.mimeType?.lowercased()
            if hop.pdfTooLarge { throw WebPageReadError.pdfTooLarge }
            try Self.checkpoint(deadline)
            return try Self.page(from: hop.body, mimeType: mimeType, charset: http.textEncodingName, url: url,
                                 isPartial: hop.isPartial, checkpoint: { try Self.checkpoint(deadline) })
        }
    }

    /// Refuses a host that is, or resolves to, a local or private address.
    private func checkAddress(of url: URL) async throws {
        guard let host = Self.host(of: url) else { throw WebPageReadError.unsupportedRedirect }
        if URLGuard.isBlocked(host) { throw WebPageReadError.blockedAddress }
        guard case .domain(let ascii, _) = host else { return }
        let addresses: [ResolvedAddress]
        do {
            addresses = try await resolve(ascii)
        } catch let error as WebPageReadError {
            throw error
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw WebPageReadError.hostNotFound
        }
        guard !addresses.isEmpty else { throw WebPageReadError.hostNotFound }
        if addresses.contains(where: \.isBlocked) { throw WebPageReadError.blockedAddress }
    }

    /// What one request came back with. Throws only CancellationError.
    private func fetch(_ url: URL) async throws -> Hop {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.acceptHeader, forHTTPHeaderField: "Accept")
        let maxBytes = self.maxBytes
        let load = PageLoad(maxBytes: maxBytes) { response in
            // Only a page is downloaded: a redirect, an error status or a PDF over the cap stops at the headers.
            (200...299).contains(response.statusCode)
                && !(Self.isPDF(response.mimeType?.lowercased()) && response.expectedContentLength > Int64(maxBytes))
        }
        await load.run(request, in: session)
        try Task.checkCancellation()
        var hop = load.outcome()
        hop.connections = await load.connections(within: Self.metricsWait)
        if let error = hop.error {
            hop.error = Self.mapped(error, refusedChallenge: hop.refusedChallenge)
        }
        if hop.error == nil, hop.response == nil {
            hop.error = WebPageReadError.failed("not an HTTP response")
        }
        return hop
    }

    /// Throws `blockedAddress` when a connection of `hop` that didn't go to a proxy reached a local or private address,
    /// and `unverifiedConnection` when the request's metrics, or a connection's remote address, are missing or
    /// unreadable. A connection through a proxy reports the proxy's address, so only the lookup before the request
    /// vouches for the site behind it. A failure that never leaves the Mac (offline) needs no check.
    private func verifyConnections(of hop: Hop, url: URL) async throws {
        if let error = hop.error as? WebPageReadError, error == .offline { return }
        guard let records = connections(url, hop.connections), !records.isEmpty else {
            Self.logger.error("A page read had no connection metrics; refusing it")
            throw WebPageReadError.unverifiedConnection
        }
        for record in records where !record.isProxyConnection {
            guard let text = record.remoteAddress, let address = ResolvedAddress(text) else {
                Self.logger.error("A page read's connection had no readable remote address; refusing it")
                throw WebPageReadError.unverifiedConnection
            }
            if address.isBlocked {
                Self.logger.error("A page read reached a local address after its host resolved to a public one")
                throw WebPageReadError.blockedAddress
            }
        }
    }

    // MARK: - Hops

    /// The parsed host of an address URLGuard already canonicalized (IPv6 hosts come back bracketed).
    static func host(of url: URL) -> URLGuard.Host? {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedHost, !raw.isEmpty
        else { return nil }
        let bracketed = raw.contains(":") && !raw.hasPrefix("[") ? "[\(raw)]" : raw
        guard case .success(let host) = URLGuard.parseHost(bracketed) else { return nil }
        return host
    }

    /// Where a redirect from `current` goes: an absolute http or https address, never from https to http, refused
    /// when it names a local address.
    static func redirectTarget(_ location: String, from current: URL) throws -> URL {
        let trimmed = location.trimmingCharacters(in: .whitespaces)
        guard let resolved = URL(string: trimmed, relativeTo: current)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw WebPageReadError.unsupportedRedirect
        }
        if current.scheme?.lowercased() == "https", scheme == "http" { throw WebPageReadError.insecureRedirect }
        switch URLGuard.check(resolved.absoluteString) {
        case .success(let checked):
            return checked.url
        case .failure(let rejection):
            throw rejection.reason == URLGuard.Reason.local
                ? WebPageReadError.blockedAddress : WebPageReadError.unsupportedRedirect
        }
    }

    // MARK: - Content

    private static func isPDF(_ mimeType: String?) -> Bool {
        mimeType == "application/pdf" || mimeType == "application/x-pdf"
    }

    private enum ContentKind { case html, text, pdf }

    /// From the MIME type, or for a missing or generic one from the first bytes.
    private static func contentKind(mimeType: String?, data: Data) throws -> ContentKind {
        switch mimeType {
        case "text/html", "application/xhtml+xml":
            return .html
        case let type? where isPDF(type):
            return .pdf
        case let type? where type.hasPrefix("text/") || type.hasSuffix("+xml") || type.hasSuffix("/xml")
            || type.hasSuffix("+json") || type.hasSuffix("/json"):
            return .text
        case nil, "application/octet-stream", "binary/octet-stream":
            if data.starts(with: Array("%PDF-".utf8)) { return .pdf }
            let prefix = String(decoding: data.prefix(1_024), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") { return .html }
            throw WebPageReadError.unsupportedContent(mimeType ?? "an unknown type")
        case let type?:
            throw WebPageReadError.unsupportedContent(type)
        }
    }

    /// The readable page in `data`. Internal for tests. `checkpoint` runs between the steps of the conversion (and
    /// inside the link search) and throws to stop it: each step is bounded, and none can be interrupted part way.
    static func page(from data: Data, mimeType: String?, charset: String?, url: URL, isPartial: Bool,
                     checkpoint: () throws -> Void = {}) throws -> WebPage {
        switch try contentKind(mimeType: mimeType, data: data) {
        case .pdf:
            guard !isPartial else { throw WebPageReadError.pdfTooLarge }
            return try pdfPage(data, url: url)
        case .html:
            guard let source = AttachmentLoader.decodeHTML(data, declaredCharset: charset, fileURL: nil) else {
                throw WebPageReadError.unreadable
            }
            try checkpoint()
            let text = HTMLText.plainText(fromHTML: source, maxOutputBytes: maxHTMLTextBytes)
            guard text.contains(where: { !$0.isWhitespace }) else { throw WebPageReadError.noText }
            try checkpoint()
            let title = HTMLPageInfo.title(in: source)
            try checkpoint()
            let links = try HTMLPageInfo.links(in: source, pageURL: url, checkpoint: checkpoint)
            return WebPage(url: url, title: title, text: text, links: links, isPartial: isPartial)
        case .text:
            let declared = charset.flatMap(HTMLText.encoding(ianaName:))
            guard let text = declared.flatMap({ String(data: data, encoding: $0) })
                ?? AttachmentLoader.decodeText(data, fileURL: nil, allowLegacyEncodings: true) else {
                throw WebPageReadError.unreadable
            }
            guard text.contains(where: { !$0.isWhitespace }) else { throw WebPageReadError.noText }
            return WebPage(url: url, title: nil, text: text, isPartial: isPartial)
        }
    }

    /// A PDF as it came, for the model to read: never opened on the Mac, where a hostile one could take minutes and
    /// gigabytes to parse. Only two byte checks: it starts like a PDF (within the first kilobyte, as readers allow), and
    /// it isn't encrypted (an `/Encrypt` entry), which the model couldn't open. Its title is the address's file name.
    private static func pdfPage(_ data: Data, url: URL) throws -> WebPage {
        guard data.prefix(1_024).range(of: Data("%PDF-".utf8)) != nil else { throw WebPageReadError.unreadable }
        if data.range(of: Data("/Encrypt".utf8)) != nil { throw WebPageReadError.pdfLocked }
        let name = url.lastPathComponent
        let title = HTMLPageInfo.cleaned(name == "/" || name.isEmpty ? nil : name)
        return WebPage(url: url, title: title, text: "", pdf: data)
    }

    // MARK: - Errors

    private static func mapped(_ error: Error, refusedChallenge: Bool) -> Error {
        if error is CancellationError { return error }
        if let error = error as? WebPageReadError { return error }
        guard let urlError = error as? URLError else {
            return Task.isCancelled ? CancellationError() : WebPageReadError.failed(String(describing: type(of: error)))
        }
        if refusedChallenge { return WebPageReadError.needsSignIn }
        switch urlError.code {
        case .cancelled:
            return Task.isCancelled ? CancellationError() : WebPageReadError.failed("cancelled")
        case .timedOut:
            return WebPageReadError.timedOut
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return WebPageReadError.offline
        case .cannotFindHost, .dnsLookupFailed:
            return WebPageReadError.hostNotFound
        case .userAuthenticationRequired, .userCancelledAuthentication, .clientCertificateRequired,
             .clientCertificateRejected:
            return WebPageReadError.needsSignIn
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .appTransportSecurityRequiresSecureConnection:
            return WebPageReadError.secureConnectionFailed
        case .httpTooManyRedirects:
            return WebPageReadError.tooManyRedirects
        default:
            return WebPageReadError.failed("error \(urlError.code.rawValue)")
        }
    }

    // MARK: - DNS

    /// The host's addresses from the system resolver (getaddrinfo, off the cooperative pool). Cancelling stops the
    /// wait at once; the lookup itself finishes on its own.
    static func systemResolve(_ host: String) async throws -> [ResolvedAddress] {
        let gate = ResolveGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[ResolvedAddress], Error>) in
                gate.install(continuation)
                DispatchQueue.global(qos: .userInitiated).async {
                    gate.finish(Result { try addresses(of: host) })
                }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    private static func addresses(of host: String) throws -> [ResolvedAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else {
            throw WebPageReadError.hostNotFound
        }
        defer { freeaddrinfo(first) }
        var result: [ResolvedAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let address = entry.pointee.ai_addr {
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                        result.append(.v4(UInt32(bigEndian: pointer.pointee.sin_addr.s_addr)))
                    }
                case AF_INET6:
                    address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                        var raw = pointer.pointee.sin6_addr
                        result.append(.v6(withUnsafeBytes(of: &raw) { Array($0) }))
                    }
                default:
                    break
                }
            }
            cursor = entry.pointee.ai_next
        }
        return result
    }
}

/// Resumes a lookup's continuation once: with the lookup's answer, or with CancellationError if that comes first.
private final class ResolveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[ResolvedAddress], Error>?
    private var early: Result<[ResolvedAddress], Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<[ResolvedAddress], Error>) {
        let result: Result<[ResolvedAddress], Error>? = lock.withLock {
            if let early {
                finished = true
                return early
            }
            self.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    func finish(_ result: Result<[ResolvedAddress], Error>) {
        let waiting: CheckedContinuation<[ResolvedAddress], Error>? = lock.withLock {
            guard !finished else { return nil }
            guard let continuation else {
                if early == nil { early = result }
                return nil
            }
            finished = true
            self.continuation = nil
            return continuation
        }
        waiting?.resume(with: result)
    }
}

/// What one request came back with.
private struct Hop {
    var response: HTTPURLResponse?
    /// The body as URLSession decoded it, at most the reader's cap.
    var body = Data()
    /// The body passed the cap and the rest was never downloaded.
    var isPartial = false
    /// A PDF declared larger than the cap: its body was never downloaded.
    var pdfTooLarge = false
    /// How the request failed; nil when it finished, or Otto stopped it on purpose.
    var error: Error?
    var refusedChallenge = false
    /// The request's connections, from its metrics; nil when they never arrived.
    var connections: [ConnectionRecord]?
}

/// One request and its delegate: follows no redirect (the reader checks each one first), answers every authentication
/// challenge except server trust by cancelling it, so Otto never sends credentials, downloads only a 2xx body Otto wants
/// and counts it as URLSession decodes it, cancelling as soon as it passes the cap (a compressed body is never inflated
/// far past it), and keeps the connections the request used.
private final class PageLoad: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private enum Stop { case none, headers, cap }

    private let lock = NSLock()
    private let maxBytes: Int
    private let wantsBody: @Sendable (HTTPURLResponse) -> Bool
    private var task: URLSessionDataTask?
    private var finished: CheckedContinuation<Void, Never>?
    private var response: URLResponse?
    private var body = Data()
    private var stop = Stop.none
    private var error: Error?
    private var refused = false
    private var records: [ConnectionRecord]?

    init(maxBytes: Int, wantsBody: @escaping @Sendable (HTTPURLResponse) -> Bool) {
        self.maxBytes = maxBytes
        self.wantsBody = wantsBody
    }

    /// Runs `request` until URLSession reports the task complete. Cancelling the caller cancels the task.
    func run(_ request: URLRequest, in session: URLSession) async {
        let task = session.dataTask(with: request)
        task.delegate = self
        lock.withLock { self.task = task }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { finished = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// The request's outcome, once `run` returned.
    func outcome() -> Hop {
        lock.withLock {
            var hop = Hop(response: response as? HTTPURLResponse, body: body, isPartial: stop == .cap,
                          refusedChallenge: refused)
            if let http = hop.response, stop == .headers, (200...299).contains(http.statusCode) {
                hop.pdfTooLarge = true
            }
            // Otto's own cancellation (headers only, or the cap) isn't a failure.
            if stop == .none || (error as? URLError)?.code != .cancelled { hop.error = error }
            if response != nil, !(response is HTTPURLResponse), hop.error == nil {
                hop.error = WebPageReadError.failed("not an HTTP response")
            }
            return hop
        }
    }

    /// The request's connections, waiting up to `timeout` for its metrics; nil when they never arrive.
    func connections(within timeout: TimeInterval) async -> [ConnectionRecord]? {
        let end = ContinuousClock.now + .milliseconds(Int64(timeout * 1_000))
        while true {
            if let records = lock.withLock({ self.records }) { return records }
            guard ContinuousClock.now < end, !Task.isCancelled else { return nil }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let allowed = (response as? HTTPURLResponse).map(wantsBody) ?? false
        lock.withLock {
            self.response = response
            if !allowed { stop = .headers }
        }
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let passedCap: Bool = lock.withLock {
            guard stop == .none else { return false }
            let room = maxBytes - body.count
            guard data.count > room else {
                body.append(data)
                return false
            }
            body.append(data.prefix(max(0, room)))
            stop = .cap
            return true
        }
        if passedCap { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        lock.withLock { refused = true }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let collected = metrics.transactionMetrics.map {
            ConnectionRecord(remoteAddress: $0.remoteAddress, isProxyConnection: $0.isProxyConnection)
        }
        lock.withLock { records = collected }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            self.error = error
            defer { finished = nil }
            return finished
        }
        continuation?.resume()
    }
}

// MARK: - HTML title and links

/// A page's `<title>` and its links, read from the HTML source with patterns (HTMLText drops both). Every pattern
/// runs in linear time: no part of one can run past a `<` or `>` it doesn't own, so a page full of tags that never
/// close (`<a `, `<title`, `<base` over and over) costs one pass, not one pass per tag. The title is looked for in
/// the first 512 KB, links in the first 1 MB, at most `maxAnchors` anchors are read and `maxLinks` kept.
enum HTMLPageInfo {
    static let maxTitleCharacters = 300
    static let maxLinkTextCharacters = 120
    static let maxLinks = 100
    static let maxAnchors = 2_000
    /// An address longer than this is skipped rather than decoded.
    static let maxHrefCharacters = 4_096
    /// Where the title is looked for: it sits in the head.
    private static let titleSearchLength = 512 * 1_024
    /// How much of the source links are looked for in, in UTF-16 units.
    static let linkSearchLength = 1_024 * 1_024

    /// The attribute value: double-quoted, single-quoted, or bare up to whitespace, a quote or a tag bracket.
    private static let hrefValue = #"\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'<>]+))"#
    private static let titlePattern = try! NSRegularExpression(
        pattern: #"<title\b[^<>]*>([^<]*)</title\s*>"#, options: [.caseInsensitive])
    private static let basePattern = try! NSRegularExpression(
        pattern: #"<base\b[^<>]*?"# + hrefValue, options: [.caseInsensitive])
    private static let anchorPattern = try! NSRegularExpression(
        pattern: #"<a\b[^<>]*?"# + hrefValue + #"[^<>]*>"#, options: [.caseInsensitive])

    static func title(in html: String) -> String? {
        let source = html as NSString
        let range = NSRange(location: 0, length: min(source.length, titleSearchLength))
        guard let match = titlePattern.firstMatch(in: html, range: range) else { return nil }
        let inner = source.substring(with: match.range(at: 1))
        return cleaned(HTMLText.plainText(fromHTML: inner), maxLength: maxTitleCharacters)
    }

    /// The page's http and https links in order, resolved against its `<base>` (else `pageURL`), without fragments,
    /// links back to the page itself or repeats. `checkpoint` runs every 100 anchors and throws to stop (the reply
    /// was stopped, or the read's deadline passed).
    static func links(in html: String, pageURL: URL, limit: Int = maxLinks,
                      checkpoint: () throws -> Void = {}) throws -> [WebLink] {
        let source = html as NSString
        let searched = NSRange(location: 0, length: min(source.length, linkSearchLength))
        var base = pageURL
        if let match = basePattern.firstMatch(in: html, range: searched),
           let href = attribute(of: match, in: source).flatMap(decodedAttribute),
           let resolved = URL(string: href, relativeTo: pageURL)?.absoluteURL {
            base = resolved
        }
        let page = withoutFragment(pageURL)
        var seen: Set<URL> = page.map { [$0] } ?? []
        var links: [WebLink] = []
        var anchors = 0
        var stopped: Error?
        anchorPattern.enumerateMatches(in: html, range: searched) { match, _, stop in
            anchors += 1
            if anchors > maxAnchors || links.count >= limit {
                stop.pointee = true
                return
            }
            if anchors % 100 == 0 {
                do { try checkpoint() } catch {
                    stopped = error
                    stop.pointee = true
                    return
                }
            }
            guard let match, let href = attribute(of: match, in: source).flatMap(decodedAttribute),
                  let resolved = URL(string: href, relativeTo: base)?.absoluteURL,
                  let scheme = resolved.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  resolved.host?.isEmpty == false,
                  let url = withoutFragment(resolved), seen.insert(url).inserted else { return }
            links.append(WebLink(text: anchorText(after: match.range, in: source), url: url))
        }
        if let stopped { throw stopped }
        return links
    }

    /// Whitespace collapsed, controls removed, cut to `maxLength`; nil when nothing is left.
    static func cleaned(_ text: String?, maxLength: Int = maxTitleCharacters) -> String? {
        guard let text else { return nil }
        let result = DisplayText.sanitized(text, maxLength: maxLength)
        return result.isEmpty ? nil : result
    }

    private static func attribute(of match: NSTextCheckingResult, in source: NSString) -> String? {
        for group in 1...3 where match.range(at: group).location != NSNotFound {
            guard match.range(at: group).length <= maxHrefCharacters else { return nil }
            return source.substring(with: match.range(at: group))
        }
        return nil
    }

    /// An attribute value with its entities decoded (`&amp;` in a query string), trimmed; nil when empty.
    private static func decodedAttribute(_ value: String) -> String? {
        let decoded = value.contains("&") ? HTMLText.plainText(fromHTML: value) : value
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The text of the anchor that ends at `tag`: up to its `</a>`, within 2,000 characters.
    private static func anchorText(after tag: NSRange, in source: NSString) -> String {
        let start = tag.location + tag.length
        let window = NSRange(location: start, length: min(2_000, source.length - start))
        let close = source.range(of: "</a", options: [.caseInsensitive], range: window)
        guard close.location != NSNotFound else { return "" }
        let inner = source.substring(with: NSRange(location: start, length: close.location - start))
        return cleaned(HTMLText.plainText(fromHTML: inner), maxLength: maxLinkTextCharacters) ?? ""
    }

    private static func withoutFragment(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        return components.url
    }
}
