//
//  BuildInfoFooterTests.swift
//  OttoTests
//
//  The General tab's footer line: the version and build, the label of every flavor, the demo suffix, a missing
//  build number, and that it lays out inside a grouped Form.
//

import AppKit
import SwiftUI
import XCTest
@testable import Otto

@MainActor
final class BuildInfoFooterTests: XCTestCase {
    func testFooterLabelPerFlavor() {
        XCTAssertEqual(BuildInfoFooter.text(version: "1.1.0", build: "42", flavor: .source, isDemo: false),
                       "Otto 1.1.0 (42) · built from source")
        XCTAssertEqual(BuildInfoFooter.text(version: "1.1.0", build: "42", flavor: .paid, isDemo: false),
                       "Otto 1.1.0 (42) · signed app")
        XCTAssertEqual(BuildInfoFooter.text(version: "1.1.0", build: "42", flavor: .setapp, isDemo: false),
                       "Otto 1.1.0 (42) · Setapp")
    }

    func testDemoSuffix() {
        XCTAssertEqual(BuildInfoFooter.text(version: "1.1.0", build: "42", flavor: .source, isDemo: true),
                       "Otto 1.1.0 (42) · built from source · demo")
        XCTAssertEqual(BuildInfoFooter.text(version: "1.1.0", build: "7", flavor: .paid, isDemo: true),
                       "Otto 1.1.0 (7) · signed app · demo")
    }

    func testMissingBuildNumberDropsItsParentheses() {
        XCTAssertEqual(BuildInfoFooter.text(version: "1.1.0", build: "", flavor: .paid, isDemo: false),
                       "Otto 1.1.0 · signed app")
        XCTAssertEqual(BuildInfoFooter.text(version: "1.1.0", build: "  ", flavor: .setapp, isDemo: true),
                       "Otto 1.1.0 · Setapp · demo")
    }

    func testThisBuildsFlavorHasALabel() {
        let text = BuildInfoFooter.text(version: "1.1.0", build: "1", flavor: OttoBuild.flavor, isDemo: false)
        XCTAssertTrue(text.hasSuffix(" · \(OttoBuild.flavor.footerLabel)"))
    }

    func testLaysOutInAGroupedForm() async throws {
        let view = Form {
            Section {
                BuildInfoFooter(version: "1.1.0", build: "42", flavor: OttoBuild.flavor, isDemo: true)
            }
        }
        .formStyle(.grouped)
        let size = NSSize(width: 560, height: 160)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertEqual(host.frame.size, size)
    }
}
