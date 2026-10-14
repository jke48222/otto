//
//  WebPageFakes.swift
//  OttoTests
//
//  Stand-ins for Setapp AI's web fetch: a URLProtocol that serves canned pages to `WebPageReader` (no request leaves
//  the process), a resolver table for its address checks, and a `WebPageReading` fake for `ResponsesClient`.
//

import AppKit
import CoreText
import Foundation
@testable import Otto

/// Serves canned pages by absolute URL to a URLSession whose configuration lists it, records every request, and
/// counts the loads URLSession stopped (cancellation, a download cut off at the cap). An unknown URL fails with
/// `cannotFindHost`.
final class PageStubProtocol: URLProtocol {
    struct Page {
        var status = 200
        var headers: [String: String] = ["Content-Type": "text/html; charset=utf-8"]
        var body = Data()
        /// Sends the headers and body, then never finishes: only a stop ends the load.
        var holdsOpen = false
        var failure: URLError?

        static func html(_ html: String) -> Page {
            Page(body: Data(html.utf8))
        }

        static func redirect(to location: String, status: Int = 302) -> Page {
            Page(status: status, headers: ["Location": location])
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pages: [String: Page] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var stops = 0
    nonisolated(unsafe) private static var startHandler: (@Sendable (URLRequest) -> Void)?

    /// Replaces the pages and clears what was recorded.
    static func serve(_ served: [String: Page], onStart: (@Sendable (URLRequest) -> Void)? = nil) {
        lock.withLock {
            pages = served
            recorded = []
            stops = 0
            startHandler = onStart
        }
    }

    static var requests: [URLRequest] { lock.withLock { recorded } }
    static var requestedURLs: [String] { requests.compactMap { $0.url?.absoluteString } }
    static var stopCount: Int { lock.withLock { stops } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (page, handler) = Self.lock.withLock { () -> (Page?, (@Sendable (URLRequest) -> Void)?) in
            Self.recorded.append(request)
            return (Self.pages[request.url?.absoluteString ?? ""], Self.startHandler)
        }
        handler?(request)
        guard let page, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        if let failure = page.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: page.status, httpVersion: "HTTP/1.1",
                                             headerFields: page.headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In pieces, as a network delivers it, so a reader can stop part way.
        var offset = 0
        while offset < page.body.count {
            let end = min(page.body.count, offset + 16 * 1_024)
            client?.urlProtocol(self, didLoad: page.body.subdata(in: offset..<end))
            offset = end
        }
        if !page.holdsOpen {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.stops += 1 }
    }
}

/// Answers host lookups from a table; a host not in it has no addresses. Records every lookup.
final class ResolverTable: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: [ResolvedAddress]]
    private var looked: [String] = []

    init(_ table: [String: [ResolvedAddress]]) {
        self.table = table
    }

    var lookups: [String] { lock.withLock { looked } }

    var resolver: WebPageReader.Resolver {
        { [self] host in
            lock.withLock {
                looked.append(host)
                return table[host] ?? []
            }
        }
    }

    /// 93.184.216.34, an address outside every refused range.
    static let publicV4 = ResolvedAddress.v4(0x5DB8_D822)

    static func address(_ text: String) -> ResolvedAddress {
        guard let address = ResolvedAddress(text) else { preconditionFailure("not an address: \(text)") }
        return address
    }
}

/// A `WebPageReading` that answers from a table by absolute URL, records each read, and can hold a read open until
/// it is cancelled.
final class ScriptedPageReader: WebPageReading, @unchecked Sendable {
    enum Answer {
        case page(WebPage)
        case failure(WebPageReadError)
        /// Waits until cancelled, then throws CancellationError.
        case hang
    }

    private let lock = NSLock()
    private var answers: [String: Answer]
    private var readURLs: [String] = []
    private var cancelled = 0
    private var startHandler: (@Sendable (URL) -> Void)?

    init(_ answers: [String: Answer] = [:]) {
        self.answers = answers
    }

    var reads: [String] { lock.withLock { readURLs } }
    var cancellations: Int { lock.withLock { cancelled } }

    func onStart(_ handler: @escaping @Sendable (URL) -> Void) {
        lock.withLock { startHandler = handler }
    }

    func read(_ url: URL) async throws -> WebPage {
        let (answer, handler) = lock.withLock { () -> (Answer?, (@Sendable (URL) -> Void)?) in
            readURLs.append(url.absoluteString)
            return (answers[url.absoluteString], startHandler)
        }
        handler?(url)
        switch answer {
        case .page(let page):
            return page
        case .failure(let error):
            throw error
        case .hang:
            do {
                while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
            } catch {
                lock.withLock { cancelled += 1 }
                throw CancellationError()
            }
        case nil:
            throw WebPageReadError.hostNotFound
        }
    }

    /// A page with `text` at `url` (its final address), titled `title`.
    static func page(_ url: String, title: String? = "A page", text: String, links: [WebLink] = []) -> WebPage {
        guard let parsed = URL(string: url) else { preconditionFailure("not a URL: \(url)") }
        return WebPage(url: parsed, title: title, text: text, links: links)
    }
}

/// A one-page PDF whose page shows `text` (drawn with Core Text, so PDFKit can read it back), titled `title`, and
/// locked with `password` when one is given.
func makePDF(text: String, title: String? = nil, password: String? = nil) -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
    var info: [CFString: Any] = [:]
    if let title { info[kCGPDFContextTitle] = title }
    if let password {
        info[kCGPDFContextUserPassword] = password
        info[kCGPDFContextOwnerPassword] = password
    }
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { return Data() }
    context.beginPDFPage(nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(
        string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)]
    ))
    context.textPosition = CGPoint(x: 72, y: 700)
    CTLineDraw(line, context)
    context.endPDFPage()
    context.closePDF()
    return data as Data
}
