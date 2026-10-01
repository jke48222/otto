//
//  OttoDeepLinkTests.swift
//  OttoiOSTests
//

import XCTest
@testable import Otto

final class OttoDeepLinkTests: XCTestCase {
    func testLinksRoundTrip() {
        let id = UUID()
        for link in [OttoDeepLink.ask, .newChat, .open, .reply(id)] {
            XCTAssertEqual(OttoDeepLink(url: link.url), link, link.url.absoluteString)
        }
    }

    func testURLsAreReadable() {
        XCTAssertEqual(OttoDeepLink.ask.url.absoluteString, "otto://ask")
        XCTAssertEqual(OttoDeepLink.newChat.url.absoluteString, "otto://new")
        let id = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
        XCTAssertEqual(OttoDeepLink.reply(id).url.absoluteString, "otto://reply/E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
    }

    func testRejectsOtherLinks() {
        XCTAssertNil(OttoDeepLink(url: URL(string: "https://ask")!))
        XCTAssertNil(OttoDeepLink(url: URL(string: "otto://settings")!))
        XCTAssertNil(OttoDeepLink(url: URL(string: "otto://reply/not-a-uuid")!))
        XCTAssertNil(OttoDeepLink(url: URL(string: "otto://reply")!))
    }

    func testHostsAreCaseInsensitive() {
        XCTAssertEqual(OttoDeepLink(url: URL(string: "OTTO://Ask")!), .ask)
    }
}
