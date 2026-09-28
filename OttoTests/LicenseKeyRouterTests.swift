//
//  LicenseKeyRouterTests.swift
//  OttoTests
//
//  Key clean-up and routing: a Polar-shaped key only ever goes to Polar and a Gumroad-shaped key only to Gumroad;
//  only a key of neither shape is offered to both, and disabled stores drop out.
//

#if OTTO_LICENSING
import XCTest
@testable import Otto

final class LicenseKeyRouterTests: XCTestCase {
    private let both: Set<LicenseBackendKind> = [.polar, .gumroad]

    // MARK: - normalize

    func testNormalizeRemovesWhitespaceAndLineBreaksButKeepsCase() {
        XCTAssertEqual(LicenseKeyRouter.normalize("  OTTO-1C285B2D-6CE6-\n4BC7-B8BE-\r\nADB6A7E304DA \n"),
                       LicenseFixtures.polarKey)
        XCTAssertEqual(LicenseKeyRouter.normalize("\totto-1c285b2d-6ce6-4bc7 -b8be-adb6a7e304da\t"),
                       "otto-1c285b2d-6ce6-4bc7-b8be-adb6a7e304da")
        XCTAssertEqual(LicenseKeyRouter.normalize("A1B2C3D4-\nE5F60718-\n293A4B5C-\n6D7E8F90"), LicenseFixtures.gumroadKey)
    }

    func testNormalizeRejectsEmptyAndOverlongKeys() {
        XCTAssertNil(LicenseKeyRouter.normalize(""))
        XCTAssertNil(LicenseKeyRouter.normalize(" \n\t "))
        XCTAssertEqual(LicenseKeyRouter.normalize(String(repeating: "A", count: 128))?.count, 128)
        XCTAssertNil(LicenseKeyRouter.normalize(String(repeating: "A", count: 129)))
        // Whitespace doesn't count toward the limit.
        XCTAssertNotNil(LicenseKeyRouter.normalize(String(repeating: "A", count: 128) + "   \n"))
    }

    // MARK: - Shapes

    func testPolarShapes() {
        XCTAssertTrue(LicenseKeyRouter.looksLikePolar(LicenseFixtures.polarKey))
        XCTAssertTrue(LicenseKeyRouter.looksLikePolar(LicenseFixtures.polarKey.lowercased()))
        XCTAssertTrue(LicenseKeyRouter.looksLikePolar(LicenseFixtures.polarKeyUnprefixed))
        XCTAssertTrue(LicenseKeyRouter.looksLikePolar("ACME2026-1C285B2D-6CE6-4BC7-B8BE-ADB6A7E304DA"))
        XCTAssertTrue(LicenseKeyRouter.looksLikePolar(String(repeating: "P", count: 24) + "-" + LicenseFixtures.polarKeyUnprefixed))
        XCTAssertFalse(LicenseKeyRouter.looksLikePolar(String(repeating: "P", count: 25) + "-" + LicenseFixtures.polarKeyUnprefixed))
        XCTAssertFalse(LicenseKeyRouter.looksLikePolar("OTTO_1C285B2D-6CE6-4BC7-B8BE-ADB6A7E304DA"))
        XCTAssertFalse(LicenseKeyRouter.looksLikePolar("OTTO-1C285B2D-6CE6-4BC7-B8BE-ADB6A7E304D"))
        XCTAssertFalse(LicenseKeyRouter.looksLikePolar("OTTO-1C285B2D-6CE6-4BC7-B8BE-ADB6A7E304DAX"))
        XCTAssertFalse(LicenseKeyRouter.looksLikePolar(LicenseFixtures.polarKey + "\n"))
        XCTAssertFalse(LicenseKeyRouter.looksLikePolar(LicenseFixtures.gumroadKey))
    }

    func testGumroadShapes() {
        XCTAssertTrue(LicenseKeyRouter.looksLikeGumroad(LicenseFixtures.gumroadKey))
        XCTAssertTrue(LicenseKeyRouter.looksLikeGumroad(LicenseFixtures.gumroadKey.lowercased()))
        XCTAssertFalse(LicenseKeyRouter.looksLikeGumroad("A1B2C3D4-E5F60718-293A4B5C"))
        XCTAssertFalse(LicenseKeyRouter.looksLikeGumroad("A1B2C3D4-E5F60718-293A4B5C-6D7E8F9G"))
        XCTAssertFalse(LicenseKeyRouter.looksLikeGumroad(LicenseFixtures.polarKey))
        XCTAssertFalse(LicenseKeyRouter.looksLikeGumroad(LicenseFixtures.polarKeyUnprefixed))
    }

    func testNoKeyMatchesBothShapes() {
        var samples = [LicenseFixtures.polarKey, LicenseFixtures.polarKeyUnprefixed, LicenseFixtures.gumroadKey,
                       "OTTO-A1B2C3D4-E5F60718-293A4B5C-6D7E8F90", "A1B2C3D4-E5F6-0718-293A-4B5C6D7E8F90"]
        // Every split of 32 hex digits into dash-separated groups of the two shapes' sizes, with and without a prefix.
        let hex = "0123456789ABCDEF0123456789ABCDEF"
        let layouts: [[Int]] = [[8, 4, 4, 4, 12], [8, 8, 8, 8], [4, 8, 8, 8, 4], [12, 4, 4, 4, 8], [32]]
        for layout in layouts {
            var index = hex.startIndex
            var groups: [String] = []
            for size in layout {
                let end = hex.index(index, offsetBy: size)
                groups.append(String(hex[index..<end]))
                index = end
            }
            let key = groups.joined(separator: "-")
            samples += [key, "OTTO-" + key, "ABCDEF01-" + key]
        }
        for key in samples {
            XCTAssertFalse(LicenseKeyRouter.looksLikePolar(key) && LicenseKeyRouter.looksLikeGumroad(key), key)
        }
    }

    // MARK: - candidates

    func testPolarShapedKeysGoToPolarOnly() {
        for key in [LicenseFixtures.polarKey, LicenseFixtures.polarKey.lowercased(), LicenseFixtures.polarKeyUnprefixed] {
            XCTAssertEqual(LicenseKeyRouter.candidates(for: key, enabled: both), [.polar], key)
        }
    }

    func testGumroadShapedKeysGoToGumroadOnly() {
        XCTAssertEqual(LicenseKeyRouter.candidates(for: LicenseFixtures.gumroadKey, enabled: both), [.gumroad])
    }

    func testKeysOfNeitherShapeTryPolarThenGumroad() {
        for key in ["OTTO_1C285B2D-6CE6-4BC7-B8BE-ADB6A7E304DA", "not-a-key", "12345"] {
            XCTAssertFalse(LicenseKeyRouter.looksLikePolar(key), key)
            XCTAssertFalse(LicenseKeyRouter.looksLikeGumroad(key), key)
            XCTAssertEqual(LicenseKeyRouter.candidates(for: key, enabled: both), [.polar, .gumroad], key)
        }
    }

    func testDisabledBackendsDropOutWithoutFallingThrough() {
        XCTAssertEqual(LicenseKeyRouter.candidates(for: LicenseFixtures.polarKey, enabled: [.gumroad]), [])
        XCTAssertEqual(LicenseKeyRouter.candidates(for: LicenseFixtures.gumroadKey, enabled: [.polar]), [])
        XCTAssertEqual(LicenseKeyRouter.candidates(for: "not-a-key", enabled: [.polar]), [.polar])
        XCTAssertEqual(LicenseKeyRouter.candidates(for: "not-a-key", enabled: [.gumroad]), [.gumroad])
        XCTAssertEqual(LicenseKeyRouter.candidates(for: LicenseFixtures.polarKey, enabled: []), [])
    }

    // MARK: - displayKey and randomLabel

    func testDisplayKeyShowsTheLastSixCharacters() {
        XCTAssertEqual(LicenseKeyRouter.displayKey(for: LicenseFixtures.gumroadKey), "****-7E8F90")
        XCTAssertEqual(LicenseKeyRouter.displayKey(for: LicenseFixtures.polarKey), LicenseFixtures.polarDisplayKey)
        XCTAssertEqual(LicenseKeyRouter.displayKey(for: "abc"), "****-abc")
    }

    func testRandomLabelIsFourUppercaseHexDigits() {
        var labels = Set<String>()
        for _ in 0..<200 {
            let label = LicenseKeyRouter.randomLabel()
            XCTAssertNotNil(label.range(of: "^Mac [0-9A-F]{4}$", options: .regularExpression), label)
            labels.insert(label)
        }
        XCTAssertGreaterThan(labels.count, 1)
    }
}
#endif
