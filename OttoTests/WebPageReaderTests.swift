//
//  WebPageReaderTests.swift
//  OttoTests
//
//  `WebPageReader`, the Mac side of Setapp AI's web fetch (SPEC §19): every page is served by `PageStubProtocol` and
//  every host resolved from a `ResolverTable`, so nothing reaches DNS or the network. Covers the address checks on
//  each hop (each refused range, local names, redirects to them, https to http, too many redirects), the ephemeral
//  session and its headers, the 5 MB cap, each content type, the deadline and cancellation.
//

import XCTest
@testable import Otto

final class WebPageReaderTests: XCTestCase {
    private static let host = "docs.example"
    private static let pageURL = "https://docs.example/guide"

    private var resolver = ResolverTable([:])
    private var connections = ConnectionTable()

    override func tearDown() {
        PageStubProtocol.serve([:])
        super.tearDown()
    }

    /// A reader on the stub, with `table` for DNS (every `.example` host in the tests resolves publicly by default)
    /// and `reached` for the post-connect check (every connection reached a public address by default).
    private func makeReader(
        _ pages: [String: PageStubProtocol.Page],
        table: [String: [ResolvedAddress]]? = nil,
        reached: ConnectionTable = ConnectionTable(),
        timeout: TimeInterval = 5,
        maxBytes: Int = WebPageReader.maxBytes,
        onStart: (@Sendable (URLRequest) -> Void)? = nil
    ) -> WebPageReader {
        PageStubProtocol.serve(pages, onStart: onStart)
        var hosts: [String: [ResolvedAddress]] = [:]
        for key in pages.keys {
            if let host = URL(string: key)?.host { hosts[host] = [ResolverTable.publicV4] }
        }
        for (host, addresses) in table ?? [:] { hosts[host] = addresses }
        resolver = ResolverTable(hosts)
        connections = reached
        return WebPageReader(timeout: timeout, maxBytes: maxBytes, resolve: resolver.resolver,
                             connections: reached.source, protocolClasses: [PageStubProtocol.self],
                             userAgent: "Otto/9.9")
    }

    private func read(_ reader: WebPageReader, _ url: String = pageURL) async throws -> WebPage {
        try await reader.read(try XCTUnwrap(URL(string: url)))
    }

    private func expectFailure(_ expected: WebPageReadError, reading url: String = pageURL, with reader: WebPageReader,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let page = try await read(reader, url)
            XCTFail("Read \(page.url) instead of failing with \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? WebPageReadError, expected, "\(error)", file: file, line: line)
        }
    }

    // MARK: Session and headers

    func testTheSessionIsEphemeralWithoutCookiesCacheOrCredentials() {
        let configuration = WebPageReader.makeConfiguration(timeout: 20, protocolClasses: nil)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 20)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 20)
        XCTAssertEqual(configuration.httpAdditionalHeaders?["Accept-Language"] as? String, "en")
        XCTAssertEqual(WebPageReader.timeout, 20)
        XCTAssertEqual(WebPageReader.maxBytes, 5 * 1_024 * 1_024)
        XCTAssertEqual(WebPageReader.maxRedirects, 5)
        XCTAssertEqual(WebPageReader.live.timeout, 20)
        XCTAssertEqual(WebPageReader.live.maxBytes, 5 * 1_024 * 1_024)
    }

    func testTheUserAgentIsOttoAndTheVersion() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertEqual(WebPageReader.defaultUserAgent(), "Otto/\(version ?? "0")")
        XCTAssertTrue(WebPageReader.live.userAgent.hasPrefix("Otto/"))
    }

    func testARequestIsAPlainGetWithOttosHeadersAndNoCookies() async throws {
        let reader = makeReader([Self.pageURL: .html("<p>Hello</p>")])
        _ = try await read(reader)
        let request = try XCTUnwrap(PageStubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Otto/9.9")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "en")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), WebPageReader.acceptHeader)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(resolver.lookups, [Self.host], "the host was checked before it was requested")
    }

    // MARK: Address checks

    func testEveryLocalAndPrivateAddressClassIsRefused() async {
        let refused: [(String, String)] = [
            ("loopback", "127.0.0.1"), ("loopback, elsewhere in 127/8", "127.8.9.10"),
            ("RFC 1918 10/8", "10.1.2.3"), ("RFC 1918 172.16/12", "172.20.0.5"), ("RFC 1918 192.168/16", "192.168.1.1"),
            ("link-local (cloud metadata)", "169.254.169.254"), ("CGNAT 100.64/10", "100.100.1.1"),
            ("multicast", "224.0.0.251"), ("unspecified", "0.0.0.0"), ("broadcast", "255.255.255.255"),
            ("IPv6 loopback", "::1"), ("IPv6 unspecified", "::"), ("IPv6 unique local", "fd12:3456::1"),
            ("IPv6 link-local", "fe80::1"), ("IPv6 multicast", "ff02::1"), ("IPv4-mapped loopback", "::ffff:127.0.0.1"),
            ("IPv4-mapped private", "::ffff:192.168.0.1"),
        ]
        for (label, address) in refused {
            let reader = makeReader([Self.pageURL: .html("<p>Secret router page</p>")],
                                    table: [Self.host: [ResolverTable.address(address)]])
            await expectFailure(.blockedAddress, with: reader)
            XCTAssertTrue(PageStubProtocol.requests.isEmpty, "\(label): nothing was requested")
        }
    }

    func testAHostWithAnyLocalAddressIsRefused() async {
        let reader = makeReader([Self.pageURL: .html("<p>Hi</p>")],
                                table: [Self.host: [ResolverTable.publicV4, ResolverTable.address("10.0.0.7")]])
        await expectFailure(.blockedAddress, with: reader)
        XCTAssertTrue(PageStubProtocol.requests.isEmpty)
    }

    func testPublicAddressesAreRead() async throws {
        for address in ["93.184.216.34", "2606:2800:21f:cb07:6820:80da:af6b:8b2c", "100.128.0.1", "172.32.0.1"] {
            let reader = makeReader([Self.pageURL: .html("<p>Public</p>")], table: [Self.host: [ResolverTable.address(address)]])
            let page = try await read(reader)
            XCTAssertEqual(page.text, "Public", address)
        }
    }

    func testLocalNamesAndLiteralsAreRefusedWithoutALookup() async {
        for url in ["http://printer.local/status", "http://intranet/", "http://localhost:8080/", "http://router.home.arpa/",
                    "http://127.0.0.1/", "http://[::1]/", "http://10.0.0.1/admin", "http://0x7f000001/"] {
            let reader = makeReader([url: .html("<p>Local</p>")])
            await expectFailure(.blockedAddress, reading: url, with: reader)
            XCTAssertTrue(resolver.lookups.isEmpty, url)
            XCTAssertTrue(PageStubProtocol.requests.isEmpty, url)
        }
    }

    func testAHostThatDoesntResolveIsNotFound() async {
        let reader = makeReader([Self.pageURL: .html("<p>Hi</p>")], table: [Self.host: []])
        await expectFailure(.hostNotFound, with: reader)
    }

    /// DNS can answer differently when URLSession asks: whatever a request came back with, the address its
    /// connection reached decides, so a host that resolved publicly and then connected locally tells Claude nothing.
    func testTheAddressAConnectionReachedIsCheckedOnEveryPath() async {
        let big = String(repeating: "word ", count: 2_000)
        var held = PageStubProtocol.Page.html("<p>\(big)</p>")
        held.holdsOpen = true
        var failing = PageStubProtocol.Page()
        failing.failure = URLError(.secureConnectionFailed)
        let paths: [(String, PageStubProtocol.Page, Int)] = [
            ("a page", .html("<p>Router admin</p>"), WebPageReader.maxBytes),
            ("a page cut at the cap", held, 1_024),
            ("a redirect", .redirect(to: "https://elsewhere.example/"), WebPageReader.maxBytes),
            ("an error status", PageStubProtocol.Page(status: 401), WebPageReader.maxBytes),
            ("a PDF over the cap", PageStubProtocol.Page(headers: ["Content-Type": "application/pdf",
                                                                   "Content-Length": "999999"], body: Data("%PDF-1.7".utf8)),
             1_024),
            ("a failure", failing, WebPageReader.maxBytes),
        ]
        let blocked = [ConnectionRecord(remoteAddress: "192.168.1.1")]
        for (label, page, cap) in paths {
            let reached = ConnectionTable([Self.pageURL: blocked])
            await expectFailure(.blockedAddress, with: makeReader([Self.pageURL: page], reached: reached, maxBytes: cap))
            XCTAssertEqual(reached.checkedURLs, [Self.pageURL], label)

            for (missing, records) in [("no metrics", nil), ("no transactions", []),
                                       ("no address", [ConnectionRecord(remoteAddress: nil)]),
                                       ("an unreadable address", [ConnectionRecord(remoteAddress: "router.example")]),
                                       ("one of two unreadable", [ConnectionRecord(remoteAddress: "93.184.216.34"),
                                                                  ConnectionRecord(remoteAddress: "")])]
                as [(String, [ConnectionRecord]?)] {
                await expectFailure(.unverifiedConnection,
                                    with: makeReader([Self.pageURL: page], reached: ConnectionTable([Self.pageURL: records]),
                                                     maxBytes: cap))
                XCTAssertEqual(connections.checkedURLs, [Self.pageURL], "\(label), \(missing): fails closed")
            }
        }
        XCTAssertEqual(WebPageReadError.unverifiedConnection.code, "url_not_accessible")
    }

    /// A connection through a proxy reports the proxy's address (often on this Mac), so it isn't held against the page;
    /// the lookup before the request still vouched for the site.
    func testAProxyConnectionIsLeftToTheLookup() async throws {
        let reached = ConnectionTable([Self.pageURL: [ConnectionRecord(remoteAddress: "127.0.0.1", isProxyConnection: true)]])
        let page = try await read(makeReader([Self.pageURL: .html("<p>Through the proxy</p>")], reached: reached))
        XCTAssertEqual(page.text, "Through the proxy")
        let mixed = ConnectionTable([Self.pageURL: [ConnectionRecord(remoteAddress: "127.0.0.1", isProxyConnection: true),
                                                    ConnectionRecord(remoteAddress: "10.0.0.2")]])
        await expectFailure(.blockedAddress, with: makeReader([Self.pageURL: .html("<p>Hi</p>")], reached: mixed))
    }

    /// Each redirect's request is checked before the next hop is looked up.
    func testEachHopsConnectionIsChecked() async {
        let reached = ConnectionTable(["https://docs.example/guide/v2": [ConnectionRecord(remoteAddress: "fd00::7")]])
        await expectFailure(.blockedAddress, with: makeReader([
            Self.pageURL: .redirect(to: "/guide/v2"),
            "https://docs.example/guide/v2": .html("<p>Rebound</p>"),
        ], reached: reached))
        XCTAssertEqual(reached.checkedURLs, [Self.pageURL, "https://docs.example/guide/v2"])
    }

    /// Being offline never reaches an address, so there is nothing to check and the reason stands.
    func testOfflineNeedsNoConnectionCheck() async {
        var page = PageStubProtocol.Page()
        page.failure = URLError(.notConnectedToInternet)
        await expectFailure(.offline, with: makeReader([Self.pageURL: page], reached: ConnectionTable(fallback: nil)))
    }

    /// The reader the app builds reads URLSession's own metrics. A URLProtocol stub's carry no remote address, so with
    /// nothing standing in for them every read fails closed.
    func testURLSessionsOwnMetricsFailClosedWithoutAnAddress() async {
        PageStubProtocol.serve([Self.pageURL: .html("<p>Hi</p>")])
        resolver = ResolverTable([Self.host: [ResolverTable.publicV4]])
        let reader = WebPageReader(timeout: 5, resolve: resolver.resolver, protocolClasses: [PageStubProtocol.self])
        let start = ContinuousClock.now
        await expectFailure(.unverifiedConnection, with: reader)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(WebPageReader.metricsWait + 1),
                          "the wait for metrics is bounded")
    }

    func testTheRemoteAddressOfAConnectionIsCheckedToo() {
        XCTAssertEqual(ResolvedAddress("127.0.0.1"), .v4(0x7F00_0001))
        XCTAssertEqual(ResolvedAddress("127.0.0.1")?.isBlocked, true)
        XCTAssertEqual(ResolvedAddress("192.168.4.20")?.isBlocked, true)
        XCTAssertEqual(ResolvedAddress("fe80::1%en0")?.isBlocked, true, "a zone suffix is ignored")
        XCTAssertEqual(ResolvedAddress("::ffff:10.0.0.1")?.isBlocked, true)
        XCTAssertEqual(ResolvedAddress("93.184.216.34")?.isBlocked, false)
        XCTAssertEqual(ResolvedAddress("2606:4700::6810:84e5")?.isBlocked, false)
        XCTAssertNil(ResolvedAddress("docs.example"))
        XCTAssertNil(ResolvedAddress(""))
    }

    // MARK: Redirects

    func testRedirectsAreFollowedAfterEachHopIsChecked() async throws {
        let reader = makeReader([
            Self.pageURL: .redirect(to: "/guide/v2"),
            "https://docs.example/guide/v2": .redirect(to: "https://mirror.example/guide", status: 301),
            "https://mirror.example/guide": .html("<title>Guide</title><p>Moved here</p>"),
        ])
        let page = try await read(reader)
        XCTAssertEqual(page.url.absoluteString, "https://mirror.example/guide", "the final address")
        XCTAssertEqual(page.title, "Guide")
        XCTAssertEqual(page.text, "Moved here")
        XCTAssertEqual(PageStubProtocol.requestedURLs,
                       [Self.pageURL, "https://docs.example/guide/v2", "https://mirror.example/guide"])
        XCTAssertEqual(resolver.lookups, ["docs.example", "docs.example", "mirror.example"])
    }

    func testARedirectToAPrivateHostIsRefused() async {
        let reader = makeReader([
            Self.pageURL: .redirect(to: "https://internal.example/admin"),
            "https://internal.example/admin": .html("<p>Admin</p>"),
        ], table: ["internal.example": [ResolverTable.address("192.168.0.10")]])
        await expectFailure(.blockedAddress, with: reader)
        XCTAssertEqual(PageStubProtocol.requestedURLs, [Self.pageURL], "the private host was never requested")
    }

    func testARedirectToALocalLiteralOrNameIsRefused() async {
        let locations = ["127.0.0.1:8080/", "[::1]/", "169.254.169.254/latest/meta-data/", "nas.local/", "localhost/",
                         "0x7f.1/"]
        for location in locations {
            let reader = makeReader([Self.pageURL: .redirect(to: "https://" + location)])
            await expectFailure(.blockedAddress, with: reader)
            XCTAssertEqual(PageStubProtocol.requestedURLs, [Self.pageURL], location)
        }
        // From an http page the downgrade rule doesn't apply, and the address check still refuses them.
        let start = "http://docs.example/guide"
        for location in locations {
            let reader = makeReader([start: .redirect(to: "http://" + location)])
            await expectFailure(.blockedAddress, reading: start, with: reader)
            XCTAssertEqual(PageStubProtocol.requestedURLs, [start], location)
        }
    }

    func testARedirectFromHTTPSToHTTPIsRefused() async {
        let reader = makeReader([
            Self.pageURL: .redirect(to: "http://docs.example/guide"),
            "http://docs.example/guide": .html("<p>Insecure</p>"),
        ])
        await expectFailure(.insecureRedirect, with: reader)
        XCTAssertEqual(PageStubProtocol.requestedURLs, [Self.pageURL])
    }

    func testARedirectFromHTTPToHTTPSIsFollowed() async throws {
        let reader = makeReader([
            "http://docs.example/guide": .redirect(to: "https://docs.example/guide"),
            Self.pageURL: .html("<p>Secure</p>"),
        ])
        let page = try await read(reader, "http://docs.example/guide")
        XCTAssertEqual(page.url.absoluteString, Self.pageURL)
    }

    func testARedirectToAnotherSchemeIsRefused() async {
        for location in ["file:///etc/hosts", "ftp://docs.example/guide", "javascript:alert(1)"] {
            let reader = makeReader([Self.pageURL: .redirect(to: location)])
            await expectFailure(.unsupportedRedirect, with: reader)
        }
    }

    func testFiveRedirectsAreFollowedAndASixthIsRefused() async throws {
        func chain(_ hops: Int) -> [String: PageStubProtocol.Page] {
            var pages: [String: PageStubProtocol.Page] = [:]
            for hop in 0..<hops {
                let from = hop == 0 ? Self.pageURL : "https://docs.example/hop\(hop)"
                pages[from] = .redirect(to: "https://docs.example/hop\(hop + 1)")
            }
            pages["https://docs.example/hop\(hops)"] = .html("<p>Arrived</p>")
            return pages
        }
        let five = try await read(makeReader(chain(5)))
        XCTAssertEqual(five.url.absoluteString, "https://docs.example/hop5")
        XCTAssertEqual(PageStubProtocol.requests.count, 6)

        await expectFailure(.tooManyRedirects, with: makeReader(chain(6)))
        XCTAssertEqual(PageStubProtocol.requests.count, 6, "the sixth redirect was never followed")
    }

    // MARK: Status and size

    func testAnErrorStatusIsReported() async {
        await expectFailure(.httpStatus(404), with: makeReader([Self.pageURL: PageStubProtocol.Page(status: 404)]))
        await expectFailure(.httpStatus(503), with: makeReader([Self.pageURL: PageStubProtocol.Page(status: 503)]))
        XCTAssertTrue(WebPageReadError.httpStatus(403).message.contains("sign-in"))
        XCTAssertEqual(WebPageReadError.httpStatus(404).message, "The site answered with HTTP 404.")
    }

    func testReadingStopsAtTheCapAndSaysTheTextIsPartial() async throws {
        let paragraph = "<p>" + String(repeating: "word ", count: 200) + "</p>"
        let html = String(repeating: paragraph, count: 50)
        // The page never finishes: only stopping at the cap returns.
        var page = PageStubProtocol.Page.html(html)
        page.holdsOpen = true
        let reader = makeReader([Self.pageURL: page], maxBytes: 4_096)
        let read = try await read(reader)
        XCTAssertTrue(read.isPartial)
        XCTAssertLessThanOrEqual(read.text.utf8.count, 4_096)
        XCTAssertTrue(read.text.hasPrefix("word word"))
        await waitUntil { PageStubProtocol.stopCount > 0 }
        XCTAssertGreaterThan(PageStubProtocol.stopCount, 0, "the rest of the download was cancelled")
    }

    /// The body is counted as URLSession decodes it and the download is cancelled once it passes 5 MB, so a page
    /// (or a compressed body that inflates) never piles up past the cap, whether it comes in pieces or in one go.
    func testMoreThanFiveMegabytesIsCutAtTheCap() async throws {
        let body = Data(String(repeating: "abcdefgh\n", count: 8 * 1_024 * 1_024 / 9).utf8)
        XCTAssertGreaterThan(body.count, WebPageReader.maxBytes)
        for chunk in [16 * 1_024, body.count] {
            var page = PageStubProtocol.Page(headers: ["Content-Type": "text/plain; charset=utf-8"], body: body)
            page.chunkSize = chunk
            page.holdsOpen = true
            let read = try await read(makeReader([Self.pageURL: page]))
            XCTAssertTrue(read.isPartial, "\(chunk)")
            XCTAssertEqual(read.text.utf8.count, WebPageReader.maxBytes, "exactly the cap, \(chunk)-byte pieces")
            await waitUntil { PageStubProtocol.stopCount > 0 }
            XCTAssertGreaterThan(PageStubProtocol.stopCount, 0, "the download was cancelled")
        }
    }

    func testAPageUnderTheCapIsWhole() async throws {
        let reader = makeReader([Self.pageURL: .html("<p>Short</p>")], maxBytes: 4_096)
        let page = try await read(reader)
        XCTAssertFalse(page.isPartial)
    }

    func testAPDFLargerThanTheCapIsRefused() async {
        let pdf = makePDF(text: "Big report")
        var declared = PageStubProtocol.Page(headers: ["Content-Type": "application/pdf",
                                                        "Content-Length": String(pdf.count)], body: pdf)
        await expectFailure(.pdfTooLarge, with: makeReader([Self.pageURL: declared], maxBytes: pdf.count - 1))
        declared.headers = ["Content-Type": "application/pdf"]
        await expectFailure(.pdfTooLarge, with: makeReader([Self.pageURL: declared], maxBytes: pdf.count - 1))
    }

    // MARK: Content

    func testHTMLBecomesReadableTextWithItsTitleAndLinks() async throws {
        let html = """
            <!doctype html><html><head><title>  Swift &amp; You </title>
            <style>p { color: red }</style><script>var secret = "x";</script></head>
            <body><h1>Getting started</h1><p>Install the <a href="/download?os=mac&amp;v=6">toolchain</a>.</p>
            <ul><li><a href="https://forums.example/t/1#reply">Forum thread</a></li>
            <li><a href="mailto:help@docs.example">Mail us</a></li><li><a href="#top">Back to top</a></li>
            <li><a href='/download?os=mac&amp;v=6'>Again</a></li></ul></body></html>
            """
        let reader = makeReader([Self.pageURL: .html(html)])
        let page = try await read(reader)
        XCTAssertEqual(page.title, "Swift & You")
        XCTAssertTrue(page.text.contains("Getting started"))
        XCTAssertTrue(page.text.contains("Install the toolchain."))
        XCTAssertFalse(page.text.contains("secret"), "scripts are dropped")
        XCTAssertFalse(page.text.contains("color"), "styles are dropped")
        XCTAssertEqual(page.links, [
            WebLink(text: "toolchain", url: try XCTUnwrap(URL(string: "https://docs.example/download?os=mac&v=6"))),
            WebLink(text: "Forum thread", url: try XCTUnwrap(URL(string: "https://forums.example/t/1"))),
        ], "absolute, without fragments, mail links, links to the page itself or repeats")
        XCTAssertFalse(page.isPartial)
    }

    func testLinksFollowTheBaseAddressAndStopAtTheLimit() throws {
        let page = URL(string: "https://docs.example/a/b")!
        let base = try HTMLPageInfo.links(in: #"<base href="https://cdn.example/root/"><a href="x">X</a>"#, pageURL: page)
        XCTAssertEqual(base.map(\.url.absoluteString), ["https://cdn.example/root/x"])
        let many = (0..<300).map { #"<a href="/p\#($0)">Page \#($0)</a>"# }.joined()
        let links = try HTMLPageInfo.links(in: many, pageURL: page)
        XCTAssertEqual(links.count, HTMLPageInfo.maxLinks)
        XCTAssertEqual(links.first, WebLink(text: "Page 0", url: URL(string: "https://docs.example/p0")!))
    }

    func testAttributeSpellingsStillParse() throws {
        let page = URL(string: "https://docs.example/")!
        let html = #"<A class="x" HREF = 'https://one.example/'>One</A> <a data-x=1 href=https://two.example/?a=1&amp;b=2 "#
            + #"target=_blank>Two</a> <a id=y href="/three" title='a > b'>Three</a>"#
        XCTAssertEqual(try HTMLPageInfo.links(in: html, pageURL: page).map(\.url.absoluteString),
                       ["https://one.example/", "https://two.example/?a=1&b=2", "https://docs.example/three"])
        XCTAssertEqual(HTMLPageInfo.title(in: "<head><TITLE lang=en>Hello &amp; welcome</title ></head>"),
                       "Hello & welcome")
        XCTAssertNil(HTMLPageInfo.title(in: "<title>Never closed"))
    }

    /// Links are looked for in the first 1 MB of the source, and an address longer than 4,096 characters is skipped.
    func testTheLinkSearchIsBounded() throws {
        let page = URL(string: "https://docs.example/")!
        let filler = String(repeating: "x", count: HTMLPageInfo.linkSearchLength)
        let html = #"<a href="https://early.example/">Early</a>"# + filler + #"<a href="https://late.example/">Late</a>"#
        XCTAssertEqual(try HTMLPageInfo.links(in: html, pageURL: page).map(\.url.absoluteString),
                       ["https://early.example/"])
        let long = "https://long.example/" + String(repeating: "a", count: HTMLPageInfo.maxHrefCharacters)
        XCTAssertEqual(try HTMLPageInfo.links(in: #"<a href="\#(long)">L</a><a href="/ok">OK</a>"#, pageURL: page)
            .map(\.url.absoluteString), ["https://docs.example/ok"])
    }

    /// A page made of tags that never close costs one pass. The old patterns took 16 s on 60 KB of `<a ` and more
    /// than two minutes on 180 KB, and nothing could stop them.
    func testHostileMarkupIsReadInLinearTime() throws {
        let fiveMB = 5 * 1_024 * 1_024
        func repeated(_ unit: String) -> String {
            String(repeating: unit, count: (fiveMB + unit.utf8.count - 1) / unit.utf8.count)
        }
        let runs = [
            repeated("<a "), repeated("<a href=x "), repeated(#"<a href="x" "#), repeated("<title "),
            "<title>" + repeated("<title>"), repeated("<base "), repeated("<base href=y "),
            repeated("<a href=x <title <base href=y "), repeated("<a\thref\t=\t"),
        ]
        let url = try XCTUnwrap(URL(string: Self.pageURL))
        for run in runs {
            let data = Data((run + "<p>Readable</p>").utf8)
            XCTAssertGreaterThanOrEqual(data.count, fiveMB)
            let start = ContinuousClock.now
            _ = try? WebPageReader.page(from: data, mimeType: "text/html", charset: "utf-8", url: url, isPartial: false)
            let elapsed = ContinuousClock.now - start
            XCTAssertLessThan(elapsed, .seconds(1), "\(run.prefix(24))… took \(elapsed)")
        }
    }

    /// A stopped read (or one past its deadline) ends between the steps of the conversion and inside the link search.
    func testTheConversionStopsAtACheckpoint() throws {
        struct Stopped: Error {}
        let url = try XCTUnwrap(URL(string: Self.pageURL))
        let html = Data(((0..<500).map { #"<a href="/p\#($0)">Page</a>"# }.joined()).utf8)
        var calls = 0
        XCTAssertThrowsError(try WebPageReader.page(from: html, mimeType: "text/html", charset: nil, url: url,
                                                    isPartial: false, checkpoint: { calls += 1; throw Stopped() })) {
            XCTAssertTrue($0 is Stopped)
        }
        XCTAssertEqual(calls, 1, "the first checkpoint, after decoding")
        calls = 0
        XCTAssertThrowsError(try HTMLPageInfo.links(in: String(decoding: html, as: UTF8.self), pageURL: url,
                                                    limit: 1_000, checkpoint: {
            calls += 1
            if calls == 2 { throw Stopped() }
        })) { XCTAssertTrue($0 is Stopped) }
        XCTAssertEqual(calls, 2, "every 100 anchors")
    }

    func testTheHTMLCharsetIsHonored() async throws {
        let latin1 = try XCTUnwrap("<p>Caf\u{E9} cr\u{E8}me</p>".data(using: .isoLatin1))
        let reader = makeReader([Self.pageURL: PageStubProtocol.Page(
            headers: ["Content-Type": "text/html; charset=iso-8859-1"], body: latin1)])
        let page = try await read(reader)
        XCTAssertEqual(page.text, "Caf\u{E9} cr\u{E8}me")
    }

    func testPlainTextIsReturnedAsItIs() async throws {
        let text = "Line one\n  indented line two\n\nThree: https://links.example/raw"
        let reader = makeReader([Self.pageURL: PageStubProtocol.Page(
            headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))])
        let page = try await read(reader)
        XCTAssertEqual(page.text, text)
        XCTAssertNil(page.title)
        XCTAssertTrue(page.links.isEmpty)
    }

    func testJSONAndXMLAreReadAsText() async throws {
        for type in ["application/json", "application/rss+xml", "text/markdown"] {
            let reader = makeReader([Self.pageURL: PageStubProtocol.Page(headers: ["Content-Type": type],
                                                                          body: Data(#"{"ok": true}"#.utf8))])
            let page = try await read(reader)
            XCTAssertEqual(page.text, #"{"ok": true}"#, type)
        }
    }

    func testAPDFsTextComesOutThroughPDFKit() async throws {
        let pdf = makePDF(text: "Quarterly results were strong", title: "Q3 Report")
        let reader = makeReader([Self.pageURL: PageStubProtocol.Page(headers: ["Content-Type": "application/pdf"],
                                                                      body: pdf)])
        let page = try await read(reader)
        XCTAssertTrue(page.text.contains("Quarterly results were strong"), page.text)
        XCTAssertEqual(page.title, "Q3 Report")
    }

    func testAPDFWithoutATypeIsRecognizedByItsBytes() async throws {
        let pdf = makePDF(text: "Untyped PDF")
        let reader = makeReader([Self.pageURL: PageStubProtocol.Page(headers: [:], body: pdf)])
        let page = try await read(reader)
        XCTAssertTrue(page.text.contains("Untyped PDF"))
        XCTAssertEqual(page.title, "guide", "without a title, the last part of the address")
    }

    func testALockedPDFIsRefused() async {
        let pdf = makePDF(text: "Private", password: "hunter2")
        await expectFailure(.pdfLocked, with: makeReader([Self.pageURL: PageStubProtocol.Page(
            headers: ["Content-Type": "application/pdf"], body: pdf)]))
    }

    func testOtherContentTypesAreRefused() async {
        let cases: [(String?, Data)] = [
            ("image/png", Data([0x89, 0x50, 0x4E, 0x47])),
            ("video/mp4", Data(repeating: 1, count: 32)),
            ("application/zip", Data([0x50, 0x4B, 0x03, 0x04])),
            (nil, Data([0x00, 0x01, 0x02])),
        ]
        for (type, body) in cases {
            let headers = type.map { ["Content-Type": $0] } ?? [:]
            do {
                let page = try await read(makeReader([Self.pageURL: PageStubProtocol.Page(headers: headers, body: body)]))
                XCTFail("Read \(page.text) from \(type ?? "no type")")
            } catch WebPageReadError.unsupportedContent(let reported) {
                if let type { XCTAssertEqual(reported, type) }
            } catch {
                XCTFail("\(type ?? "no type"): \(error)")
            }
        }
        XCTAssertEqual(WebPageReadError.unsupportedContent("image/png").message,
                       "Otto reads web pages, plain text and PDFs, and this address returned image/png.")
    }

    func testAPageWithNoReadableTextSaysSo() async {
        await expectFailure(.noText, with: makeReader([Self.pageURL: .html("<script>render()</script><div></div>")]))
    }

    // MARK: Deadline, failures and cancellation

    func testAPageThatHangsTimesOut() async {
        var page = PageStubProtocol.Page.html("")
        page.holdsOpen = true
        let reader = makeReader([Self.pageURL: page], timeout: 0.3)
        await expectFailure(.timedOut, with: reader)
    }

    func testNetworkFailuresMapToReadableReasons() async {
        let cases: [(URLError.Code, WebPageReadError)] = [
            (.notConnectedToInternet, .offline), (.cannotFindHost, .hostNotFound), (.timedOut, .timedOut),
            (.secureConnectionFailed, .secureConnectionFailed), (.userAuthenticationRequired, .needsSignIn),
        ]
        for (code, expected) in cases {
            var page = PageStubProtocol.Page()
            page.failure = URLError(code)
            await expectFailure(expected, with: makeReader([Self.pageURL: page]))
        }
    }

    func testCancellingStopsTheDownload() async throws {
        var page = PageStubProtocol.Page.html("<p>Partial")
        page.holdsOpen = true
        let started = expectation(description: "request started")
        let reader = makeReader([Self.pageURL: page], timeout: 30) { _ in started.fulfill() }
        let task = Task { try await reader.read(try XCTUnwrap(URL(string: Self.pageURL))) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled read returned a page")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        await waitUntil { PageStubProtocol.stopCount > 0 }
        XCTAssertGreaterThan(PageStubProtocol.stopCount, 0)
    }

    func testCancellingDuringTheLookupEndsTheRead() async {
        let reader = WebPageReader(timeout: 30, resolve: { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return [ResolverTable.publicV4]
        }, protocolClasses: [PageStubProtocol.self])
        PageStubProtocol.serve([Self.pageURL: .html("<p>Hi</p>")])
        let task = Task { try await reader.read(URL(string: Self.pageURL)!) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled read returned a page")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(PageStubProtocol.requests.isEmpty)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
