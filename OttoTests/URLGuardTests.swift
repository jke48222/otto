//
//  URLGuardTests.swift
//  OttoTests
//
//  Every spelling of a local address browsers accept (numeric IPv4 forms, bracketed IPv6, mapped
//  addresses, trailing dots, local suffixes, dotless names) is blocked; internationalized hosts show
//  their punycode; and opening goes through the default-browser API, never the link's own handler.
//

import XCTest
@testable import Otto

final class URLGuardTests: XCTestCase {
    private func rejection(_ raw: String) -> URLGuard.Rejection? {
        if case .failure(let rejection) = URLGuard.check(raw) { return rejection }
        return nil
    }

    private func checked(_ raw: String, file: StaticString = #filePath, line: UInt = #line) -> URLGuard.Checked? {
        switch URLGuard.check(raw) {
        case .success(let value):
            return value
        case .failure(let rejection):
            XCTFail("\(raw) was rejected: \(rejection.reason)", file: file, line: line)
            return nil
        }
    }

    private func assertBlockedAsLocal(_ raw: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rejection(raw), URLGuard.Rejection(kind: .blocked, reason: URLGuard.Reason.local),
                       raw, file: file, line: line)
    }

    // MARK: - Local addresses

    func testLoopbackInEveryIPv4Encoding() {
        for host in ["127.0.0.1", "127.1", "2130706433", "0x7f000001", "0x7F.1", "0177.0.0.1", "0177.1", "127.0.0.1.",
                     "127.000.000.001", "%31%32%37.0.0.1", "127.0.1", "0x7f.0x0.0x0.0x1", "017700000001"] {
            assertBlockedAsLocal("http://\(host)/admin")
        }
    }

    func testPrivateAndSpecialIPv4Ranges() {
        for host in ["10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.254", "192.168.1.1", "169.254.169.254",
                     "100.64.0.1", "100.127.255.255", "0.0.0.0", "0", "224.0.0.1", "255.255.255.255", "240.0.0.1"] {
            assertBlockedAsLocal("https://\(host)/")
        }
        for host in ["172.15.255.255", "172.32.0.1", "100.63.255.255", "100.128.0.1", "8.8.8.8", "1.1.1.1"] {
            XCTAssertNotNil(checked("https://\(host)/"), host)
        }
    }

    func testIPv6LoopbackAndLocalRanges() {
        for host in ["[::1]", "[::]", "[0:0:0:0:0:0:0:1]", "[::ffff:127.0.0.1]", "[::ffff:7f00:1]", "[::ffff:10.0.0.1]",
                     "[::ffff:192.168.0.1]", "[::127.0.0.1]", "[fc00::1]", "[fd12:3456:789a::1]", "[fe80::1]",
                     "[febf::1]", "[ff02::1]", "[64:ff9b::7f00:1]", "[2002:c0a8:0101::1]", "[::1]:8080"] {
            assertBlockedAsLocal("http://\(host)/")
        }
        let publicV6 = checked("https://[2606:4700:4700::1111]/dns-query")
        XCTAssertEqual(publicV6?.displayHost, "[2606:4700:4700::1111]")
    }

    func testInvalidIPv6IsRejected() {
        XCTAssertEqual(rejection("http://[::1/")?.kind, .invalid)
        XCTAssertEqual(rejection("http://[fe80::1%25en0]/")?.kind, .invalid)
        XCTAssertEqual(rejection("http://[not-an-address]/")?.kind, .invalid)
    }

    func testLocalNamesAndSuffixes() {
        for host in ["localhost", "localhost.", "LOCALHOST", "printer.local", "printer.local.", "app.localhost",
                     "a.b.localhost", "nas.home.arpa", "home.arpa", "service.internal", "router.lan", "intranet",
                     "intranet.", "xn--nxasmq6b"] {
            assertBlockedAsLocal("https://\(host)/")
        }
    }

    func testTrailingDotIsStrippedOnce() {
        XCTAssertEqual(checked("https://example.com./path")?.url.host, "example.com")
        XCTAssertEqual(rejection("https://example.com../")?.kind, .invalid)
    }

    func testMalformedNumericHostsAreInvalid() {
        XCTAssertEqual(rejection("http://1.2.3.4.5/")?.kind, .invalid)
        XCTAssertEqual(rejection("http://256.1.1.1/")?.kind, .invalid)
        XCTAssertEqual(rejection("http://1.2.3.256/")?.kind, .invalid)
        XCTAssertEqual(rejection("http://4294967296/")?.kind, .invalid)
        XCTAssertEqual(rejection("http://09.1.1.1/")?.kind, .invalid)
        XCTAssertEqual(rejection("http://example.0x/")?.kind, .invalid)
    }

    func testWHATWGIPv4Parser() {
        XCTAssertEqual(URLGuard.parseIPv4(["127", "1"]), 0x7F00_0001)
        XCTAssertEqual(URLGuard.parseIPv4(["2130706433"]), 0x7F00_0001)
        XCTAssertEqual(URLGuard.parseIPv4(["0x7f000001"]), 0x7F00_0001)
        XCTAssertEqual(URLGuard.parseIPv4(["0177", "0", "0", "1"]), 0x7F00_0001)
        XCTAssertEqual(URLGuard.parseIPv4(["192", "168", "257"]), 0xC0A8_0101)
        XCTAssertNil(URLGuard.parseIPv4(["1", "2", "3", "4", "5"]))
        XCTAssertEqual(URLGuard.dotted(0xC0A8_0101), "192.168.1.1")
    }

    // MARK: - Schemes and shapes

    func testOnlyHTTPAndHTTPS() {
        for raw in ["mailto:someone@example.com", "file:///etc/passwd", "javascript:alert(1)", "ftp://example.com/",
                    "x-apple.systempreferences:com.apple.preference.security", "data:text/html,hi"] {
            XCTAssertEqual(rejection(raw), URLGuard.Rejection(kind: .blocked, reason: URLGuard.Reason.scheme), raw)
        }
        XCTAssertNotNil(checked("HTTPS://Example.COM/Path"))
        XCTAssertEqual(checked("HTTPS://Example.COM/Path")?.url.absoluteString, "https://example.com/Path")
    }

    func testUserInfoIsBlocked() {
        XCTAssertEqual(rejection("https://user:pass@example.com/"),
                       URLGuard.Rejection(kind: .blocked, reason: URLGuard.Reason.userInfo))
        XCTAssertEqual(rejection("https://google.com@evil.example/")?.kind, .blocked)
    }

    func testWhitespaceControlAndHiddenCharactersAreInvalid() {
        for raw in ["https://example.com/a b", " https://example.com/", "https://exa\u{0000}mple.com/",
                    "https://example.com/\u{202E}gpj.exe", "https://exam\u{200B}ple.com/", "https://example.com/\n"] {
            XCTAssertEqual(rejection(raw)?.kind, .invalid, raw.debugDescription)
        }
        XCTAssertEqual(rejection("https://example.com\\@127.0.0.1/")?.kind, .invalid)
    }

    func testLengthLimit() {
        let base = "https://example.com/"
        XCTAssertNotNil(checked(base + String(repeating: "a", count: URLGuard.maxLength - base.count)))
        XCTAssertEqual(rejection(base + String(repeating: "a", count: URLGuard.maxLength - base.count + 1)),
                       URLGuard.Rejection(kind: .invalid, reason: URLGuard.Reason.tooLong))
    }

    func testPortsAndMissingHost() {
        XCTAssertEqual(checked("https://example.com:8443/x")?.url.port, 8443)
        XCTAssertEqual(checked("https://example.com:/x")?.url.port, nil)
        XCTAssertEqual(rejection("https://example.com:99999/")?.kind, .invalid)
        XCTAssertEqual(rejection("https://example.com:80a/")?.kind, .invalid)
        XCTAssertEqual(rejection("https:///path")?.kind, .invalid)
        XCTAssertEqual(rejection("https:example.com")?.kind, .invalid)
    }

    // MARK: - Display

    func testInternationalizedHostShowsPunycode() {
        let unicode = checked("https://bücher.de/katalog?q=1")
        XCTAssertEqual(unicode?.displayHost, "bücher.de")
        XCTAssertEqual(unicode?.punycodeHost, "xn--bcher-kva.de")
        XCTAssertEqual(unicode?.url.host, "xn--bcher-kva.de")
        XCTAssertEqual(unicode?.warnings, [.unusualHost])

        let ascii = checked("https://xn--bcher-kva.de/")
        XCTAssertEqual(ascii?.displayHost, "bücher.de")
        XCTAssertEqual(ascii?.punycodeHost, "xn--bcher-kva.de")

        let lookalike = checked("https://аpple.com/")   // Cyrillic а
        XCTAssertEqual(lookalike?.punycodeHost, "xn--pple-43d.com")
        XCTAssertTrue(lookalike?.warnings.contains(.unusualHost) ?? false)

        XCTAssertEqual(checked("https://ＥＸＡＭＰＬＥ。com/")?.url.host, "example.com", "full-width forms map like IDNA")
    }

    func testPunycodeRoundTrip() {
        for label in ["bücher", "münchen", "ü", "日本語", "пример", "a-ü-b"] {
            let encoded = URLGuard.Punycode.encode(label)
            XCTAssertNotNil(encoded, label)
            XCTAssertEqual(encoded.flatMap(URLGuard.Punycode.decode), label)
        }
        XCTAssertEqual(URLGuard.Punycode.encode("münchen"), "mnchen-3ya")
        XCTAssertNil(URLGuard.Punycode.decode("bcher-kva!"))
    }

    func testWarnings() {
        XCTAssertEqual(checked("http://example.com/")?.warnings, [.insecure])
        let longQuery = "https://example.com/search?q=" + String(repeating: "x", count: 200)
        XCTAssertEqual(checked(longQuery)?.warnings, [.longQuery])
        XCTAssertEqual(checked("https://example.com/?q=short")?.warnings, [])
        XCTAssertEqual(URLGuard.Warning.insecure.label, "Not secure (http)")
    }

    func testPathQueryAndFragmentArePercentEncodedNotChanged() {
        let result = checked("https://example.com/über/a%20b?q=\"x\"&r=%zz#frag")
        XCTAssertEqual(result?.url.absoluteString, "https://example.com/%C3%BCber/a%20b?q=%22x%22&r=%25zz#frag")
        XCTAssertEqual(checked("https://example.com")?.url.absoluteString, "https://example.com/")
        XCTAssertEqual(checked("https://example.com?q=1")?.url.absoluteString, "https://example.com/?q=1")
    }

    // MARK: - Default browser

    func testOpeningUsesTheDefaultBrowserForAPlainHTTPSProbe() async {
        let recorder = OpenRecorder()
        let browser = URL(fileURLWithPath: "/Applications/Safari.app")
        let opener = DefaultBrowserOpener(
            browserLocator: { probe in
                await recorder.recordProbe(probe)
                return browser
            },
            launcher: { url, application in
                await recorder.recordOpen(url, application)
            }
        )
        let target = URL(string: "https://maps.apple.com/?q=coffee")
        guard let target else { return XCTFail("bad test URL") }
        let opened = await opener.open(target)

        XCTAssertTrue(opened)
        let probes = await recorder.probes
        let opens = await recorder.opens
        XCTAssertEqual(probes.map(\.absoluteString), ["https://example.com"])
        XCTAssertEqual(opens.count, 1)
        XCTAssertEqual(opens.first?.url, target)
        XCTAssertEqual(opens.first?.application, browser)
    }

    func testNoDefaultBrowserOrFailedLaunchReportsFailure() async {
        let noBrowser = DefaultBrowserOpener(browserLocator: { _ in nil }, launcher: { _, _ in
            XCTFail("must not launch without a browser")
        })
        let target = URL(string: "https://example.com/")
        guard let target else { return XCTFail("bad test URL") }
        let noBrowserResult = await noBrowser.open(target)
        XCTAssertFalse(noBrowserResult)

        struct LaunchFailure: Error {}
        let failing = DefaultBrowserOpener(browserLocator: { _ in URL(fileURLWithPath: "/Applications/Safari.app") },
                                           launcher: { _, _ in throw LaunchFailure() })
        let failingResult = await failing.open(target)
        XCTAssertFalse(failingResult)
    }
}

private actor OpenRecorder {
    private(set) var probes: [URL] = []
    private(set) var opens: [(url: URL, application: URL)] = []

    func recordProbe(_ url: URL) { probes.append(url) }
    func recordOpen(_ url: URL, _ application: URL) { opens.append((url, application)) }
}
