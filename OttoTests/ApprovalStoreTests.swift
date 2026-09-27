//
//  ApprovalStoreTests.swift
//  OttoTests
//
//  One-time consents and "Always allow" scopes: grant, revoke, persistence under the frozen keys,
//  ordering, and unreadable stored data.
//

import XCTest
@testable import Otto

@MainActor
final class ApprovalStoreTests: XCTestCase {
    private let calendarRead = ConsentKey(rawValue: "calendar.read", label: "Read your calendar")
    private let shortcutsList = ConsentKey(rawValue: "shortcuts.list", label: "See your shortcut names")
    private let logWater = ApprovalScope(toolName: "run_shortcut", key: "shortcut:1111", label: "“Log water”")
    private let resize = ApprovalScope(toolName: "run_shortcut", key: "shortcut:2222", label: "“Resize Images”")

    func testConsentGrantRevokeAndPersistence() {
        let defaults = TestDefaults.make(for: self)
        let store = ApprovalStore(defaults: defaults)
        XCTAssertFalse(store.hasConsent(calendarRead))

        store.grantConsent(shortcutsList)
        store.grantConsent(calendarRead)
        store.grantConsent(calendarRead)
        XCTAssertTrue(store.hasConsent(calendarRead))
        XCTAssertEqual(store.consents, [calendarRead, shortcutsList], "sorted by label, no duplicates")
        XCTAssertEqual(defaults.stringArray(forKey: ApprovalStore.consentsKey), ["calendar.read", "shortcuts.list"])

        let reloaded = ApprovalStore(defaults: defaults)
        XCTAssertEqual(reloaded.consents, [calendarRead, shortcutsList], "labels come back for Otto's own consents")

        reloaded.revokeConsent(calendarRead)
        XCTAssertFalse(reloaded.hasConsent(calendarRead))
        XCTAssertEqual(ApprovalStore(defaults: defaults).consents, [shortcutsList])
    }

    func testConsentMatchesByRawValue() {
        let store = ApprovalStore(defaults: TestDefaults.make(for: self))
        store.grantConsent(calendarRead)
        XCTAssertTrue(store.hasConsent(ConsentKey(rawValue: "calendar.read", label: "Another label")))
    }

    func testUnknownStoredConsentKeepsItsRawValueAsLabel() {
        let defaults = TestDefaults.make(for: self)
        defaults.set(["test.read"], forKey: ApprovalStore.consentsKey)
        let store = ApprovalStore(defaults: defaults)
        XCTAssertEqual(store.consents, [ConsentKey(rawValue: "test.read", label: "test.read")])
    }

    func testRememberedScopesNewestFirstAndPersisted() {
        let defaults = TestDefaults.make(for: self)
        let store = ApprovalStore(defaults: defaults)
        XCTAssertFalse(store.isRemembered(logWater))

        store.remember(logWater)
        store.remember(resize)
        store.remember(logWater)
        XCTAssertTrue(store.isRemembered(logWater))
        XCTAssertEqual(store.remembered.map(\.scope), [resize, logWater])
        XCTAssertEqual(store.remembered.first?.id, "run_shortcut|shortcut:2222")

        let reloaded = ApprovalStore(defaults: defaults)
        XCTAssertEqual(reloaded.remembered.map(\.scope), [resize, logWater])
        // A renamed shortcut keeps its identifier, so the scope still matches.
        XCTAssertTrue(reloaded.isRemembered(ApprovalScope(toolName: "run_shortcut", key: "shortcut:1111", label: "“Drink”")))
    }

    func testRevokeOneAndRevokeAll() {
        let defaults = TestDefaults.make(for: self)
        let store = ApprovalStore(defaults: defaults)
        store.remember(logWater)
        store.remember(resize)
        store.grantConsent(calendarRead)

        store.revoke("run_shortcut|shortcut:1111")
        XCTAssertFalse(store.isRemembered(logWater))
        XCTAssertTrue(store.isRemembered(resize))

        store.revokeAll()
        XCTAssertEqual(store.remembered, [])
        XCTAssertEqual(store.consents, [])
        XCTAssertNil(defaults.object(forKey: ApprovalStore.consentsKey))
        XCTAssertNil(defaults.object(forKey: ApprovalStore.rememberedKey))
        let reloaded = ApprovalStore(defaults: defaults)
        XCTAssertEqual(reloaded.remembered, [])
        XCTAssertEqual(reloaded.consents, [])
    }

    func testUnreadableRememberedDataIsIgnored() {
        let defaults = TestDefaults.make(for: self)
        defaults.set(Data("not json".utf8), forKey: ApprovalStore.rememberedKey)
        let store = ApprovalStore(defaults: defaults)
        XCTAssertEqual(store.remembered, [])
        store.remember(logWater)
        XCTAssertEqual(ApprovalStore(defaults: defaults).remembered.map(\.scope), [logWater])
    }

    func testStoredRememberedHoldsScopeKeysOnly() throws {
        let defaults = TestDefaults.make(for: self)
        let store = ApprovalStore(defaults: defaults)
        store.remember(logWater)
        let data = try XCTUnwrap(defaults.data(forKey: ApprovalStore.rememberedKey))
        let decoded = try JSONDecoder().decode([RememberedApproval].self, from: data)
        XCTAssertEqual(decoded.map(\.scope), [logWater])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("input"))
    }
}
