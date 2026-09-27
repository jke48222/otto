//
//  NotchNeighborsTests.swift
//  Otto
//

import XCTest
@testable import Otto

final class NotchNeighborsTests: XCTestCase {
    private func neighbor(_ name: String) -> NotchNeighbor? {
        NotchNeighbor.known.first { $0.name == name }
    }

    func testBundleIDMatch() {
        XCTAssertEqual(NotchNeighbor.match(bundleID: "lo.cafe.NotchNook", localizedName: nil)?.name, "NotchNook")
        XCTAssertEqual(NotchNeighbor.match(bundleID: "theboringteam.boringnotch", localizedName: "Something")?.name,
                       "boring.notch")
        XCTAssertEqual(NotchNeighbor.match(bundleID: "com.henrikruscon.Alcove", localizedName: nil)?.name, "Alcove")
        XCTAssertEqual(NotchNeighbor.match(bundleID: "com.lakr233.NotchDrop", localizedName: nil)?.name, "NotchDrop")
    }

    func testBundleIDMatchIgnoresCase() {
        XCTAssertEqual(NotchNeighbor.match(bundleID: "LO.CAFE.NOTCHNOOK", localizedName: nil)?.name, "NotchNook")
    }

    func testBundleIDWinsOverName() {
        XCTAssertEqual(NotchNeighbor.match(bundleID: "com.henrikruscon.Alcove", localizedName: "NotchNook")?.name,
                       "Alcove")
    }

    func testNamePatternFallback() {
        XCTAssertEqual(NotchNeighbor.match(bundleID: "com.example.renamed", localizedName: "NotchNook")?.name,
                       "NotchNook")
        XCTAssertEqual(NotchNeighbor.match(bundleID: nil, localizedName: "MediaMate")?.name, "MediaMate")
        XCTAssertEqual(NotchNeighbor.match(bundleID: nil, localizedName: "Dynamic Lake Pro")?.name, "DynamicLake")
        XCTAssertEqual(NotchNeighbor.match(bundleID: nil, localizedName: "boring.notch")?.name, "boring.notch")
    }

    func testUnrelatedAndNotchHidingAppsDoNotMatch() {
        XCTAssertNil(NotchNeighbor.match(bundleID: "com.apple.Safari", localizedName: "Safari"))
        XCTAssertNil(NotchNeighbor.match(bundleID: "com.jalenedusei.otto", localizedName: "Otto"))
        XCTAssertNil(NotchNeighbor.match(bundleID: "de.iarecrazy.TopNotch", localizedName: "TopNotch"))
        XCTAssertNil(NotchNeighbor.match(bundleID: nil, localizedName: nil))
        XCTAssertNil(NotchNeighbor.match(bundleID: "", localizedName: ""))
    }

    func testKnownNeighborsHaveUniqueNamesAndLowercasePatterns() {
        let names = NotchNeighbor.known.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        for neighbor in NotchNeighbor.known {
            XCTAssertFalse(neighbor.bundleIDs.isEmpty && neighbor.namePatterns.isEmpty, neighbor.name)
            for pattern in neighbor.namePatterns {
                XCTAssertEqual(pattern, pattern.lowercased(), neighbor.name)
            }
        }
    }

    @MainActor
    func testRunningNeighborsAreDedupedAndSortedByName() {
        let apps: [(bundleID: String?, localizedName: String?)] = [
            ("com.lakr233.NotchDrop", "NotchDrop"),
            ("com.apple.finder", "Finder"),
            ("com.henrikruscon.Alcove", "Alcove"),
            ("com.henrikruscon.Alcove", "Alcove Helper"),
            (nil, "MediaMate"),
        ]
        XCTAssertEqual(NotchNeighborMonitor.neighbors(in: apps).map(\.name), ["Alcove", "MediaMate", "NotchDrop"])
        XCTAssertEqual(NotchNeighborMonitor.neighbors(in: []), [])
    }
}
