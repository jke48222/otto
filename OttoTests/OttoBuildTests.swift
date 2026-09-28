//
//  OttoBuildTests.swift
//  OttoTests
//
//  The flavor this binary was compiled as, the bundle ids every flavor shares the launch guard with, and the
//  General footer's flavor labels.
//

import XCTest
@testable import Otto

final class OttoBuildTests: XCTestCase {
    func testFlavorFollowsTheCompilationConditions() {
        #if OTTO_SETAPP
        XCTAssertEqual(OttoBuild.flavor, .setapp)
        #elseif OTTO_LICENSING
        XCTAssertEqual(OttoBuild.flavor, .paid)
        #else
        XCTAssertEqual(OttoBuild.flavor, .source)
        #endif
    }

    func testAllBundleIDsCoverEveryFlavor() {
        XCTAssertEqual(OttoBuild.allBundleIDs, ["com.jalenedusei.otto", "com.jalenedusei.otto-setapp"])
        if let running = Bundle.main.bundleIdentifier, !running.hasSuffix(".tests") {
            XCTAssertTrue(OttoBuild.allBundleIDs.contains(running), "the test host is one of Otto's flavors")
        }
    }

    func testFooterLabels() {
        XCTAssertEqual(OttoBuild.Flavor.source.footerLabel, "built from source")
        XCTAssertEqual(OttoBuild.Flavor.paid.footerLabel, "signed app")
        XCTAssertEqual(OttoBuild.Flavor.setapp.footerLabel, "Setapp")
        XCTAssertEqual(OttoBuild.Flavor(rawValue: "paid"), .paid)
    }
}
