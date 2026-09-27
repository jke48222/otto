//
//  ContextSuggestionsTests.swift
//  OttoTests
//
//  The selection and window ghost chips: settings, permissions, sensitive apps, browsers, dismissal,
//  stale reads and captures, with a fake reader, a fake capture and FakePermissionProvider.
//

import AppKit
import XCTest
@testable import Otto

@MainActor
final class ContextSuggestionsTests: XCTestCase {
    private var settings: AppSettings!
    private var permissions: FakePermissionProvider!
    private var reader: SuggestionsFakeReader!
    private var capture: SuggestionsFakeCapture!
    private var suggestions: ContextSuggestions!

    private let notes = AppRef(pid: 9191, bundleID: "com.apple.Notes", name: "Notes")
    private let chrome = AppRef(pid: 9292, bundleID: "com.google.Chrome", name: "Google Chrome")
    private let keychain = AppRef(pid: 9393, bundleID: "com.apple.keychainaccess", name: "Keychain Access")

    override func setUp() async throws {
        settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        settings.context.offerSelection = true
        settings.context.offerWindow = true
        permissions = FakePermissionProvider([.accessibility: .granted, .screenRecording: .granted])
        reader = SuggestionsFakeReader()
        capture = SuggestionsFakeCapture()
        suggestions = ContextSuggestions(settings: settings, permissions: permissions, reader: reader, capture: capture)
    }

    private func snapshot(_ text: String, app: AppRef? = nil) -> SelectionSnapshot {
        SelectionSnapshot(text: text, app: app ?? notes, windowTitle: nil, range: nil, element: nil,
                          source: .accessibility)
    }

    private func refresh(_ app: AppRef?, allowSelection: Bool = true) async {
        suggestions.refresh(for: app, allowSelection: allowSelection)
        await suggestions.waitForRefresh()
    }

    // MARK: Selection chip

    func testOffersTheSelectionWithItsLabel() async {
        reader.result = snapshot("Fix typo")
        await refresh(notes)

        XCTAssertEqual(suggestions.selection?.snapshot.text, "Fix typo")
        XCTAssertEqual(suggestions.selection?.label, "Selection · “Fix typo”")
        XCTAssertEqual(reader.reads, [notes])
    }

    func testSelectionNeedsTheSettingPermissionAndANonDragOpen() async {
        reader.result = snapshot("text")

        settings.context.offerSelection = false
        await refresh(notes)
        XCTAssertNil(suggestions.selection)

        settings.context.offerSelection = true
        permissions.statuses[.accessibility] = .denied
        await refresh(notes)
        XCTAssertNil(suggestions.selection)

        permissions.statuses[.accessibility] = .granted
        await refresh(notes, allowSelection: false)
        XCTAssertNil(suggestions.selection)

        XCTAssertTrue(reader.reads.isEmpty)
    }

    func testSensitiveAppsAreNeitherReadNorOffered() async {
        reader.result = snapshot("secret", app: keychain)
        capture.hasWindow = true
        await refresh(keychain)

        XCTAssertNil(suggestions.selection)
        XCTAssertNil(suggestions.window)
        XCTAssertTrue(reader.reads.isEmpty)
        XCTAssertTrue(capture.windowChecks.isEmpty)
        let menuOffer = await suggestions.hasCapturableWindow(keychain)
        XCTAssertFalse(menuOffer)
        let menuRead = await suggestions.readSelectionNow(from: keychain)
        XCTAssertNil(menuRead)
    }

    func testDismissedSelectionIsNotOfferedAgainUntilItChanges() async {
        reader.result = snapshot("same text")
        await refresh(notes)
        suggestions.dismissSelection()
        XCTAssertNil(suggestions.selection)

        await refresh(notes)
        XCTAssertNil(suggestions.selection)

        reader.result = snapshot("new text")
        await refresh(notes)
        XCTAssertEqual(suggestions.selection?.snapshot.text, "new text")

        // Selecting the first text again later is a new selection.
        reader.result = snapshot("same text")
        await refresh(notes)
        XCTAssertEqual(suggestions.selection?.snapshot.text, "same text")
    }

    func testAcceptingMakesANonRetainedAttachment() async throws {
        reader.result = snapshot("Accept me")
        await refresh(notes)

        let accepted = try XCTUnwrap(try suggestions.acceptSelection())
        XCTAssertEqual(accepted.attachment.displayName, "Selection from Notes")
        XCTAssertEqual(accepted.attachment.badge, "SEL")
        XCTAssertFalse(accepted.attachment.retainsPayloadInHistory)
        XCTAssertEqual(accepted.snapshot.text, "Accept me")
        XCTAssertNil(suggestions.selection)
        XCTAssertNil(try suggestions.acceptSelection())
    }

    func testAReadThatLandsAfterCloseIsDropped() async {
        reader.result = snapshot("late")
        reader.holdsReads = true
        suggestions.refresh(for: notes, allowSelection: true)
        suggestions.clear()
        reader.release()
        await suggestions.waitForRefresh()
        // Let the held read finish and try to land.
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(suggestions.selection)
    }

    func testReopeningSupersedesAnEarlierRead() async {
        reader.result = snapshot("first")
        reader.holdsReads = true
        suggestions.refresh(for: notes, allowSelection: true)
        reader.holdsReads = false
        reader.result = snapshot("second")
        suggestions.refresh(for: notes, allowSelection: true)
        await suggestions.waitForRefresh()
        reader.release()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(suggestions.selection?.snapshot.text, "second")
    }

    func testReadSelectionNowNeedsAccessibilityButNotTheSetting() async {
        settings.context.offerSelection = false
        reader.result = snapshot("menu")
        let read = await suggestions.readSelectionNow(from: notes)
        XCTAssertEqual(read?.text, "menu")

        permissions.statuses[.accessibility] = .notDetermined
        let denied = await suggestions.readSelectionNow(from: notes)
        XCTAssertNil(denied)
    }

    // MARK: Window chip

    func testOffersTheWindowChip() async {
        capture.hasWindow = true
        await refresh(notes)
        XCTAssertEqual(suggestions.window?.app, notes)
        XCTAssertEqual(suggestions.window?.label, "Window: Notes")
    }

    func testNoWindowChipForBrowsersWithoutAWindowOrWithTheSettingOff() async {
        capture.hasWindow = true
        await refresh(chrome)
        XCTAssertNil(suggestions.window)

        capture.hasWindow = false
        await refresh(notes)
        XCTAssertNil(suggestions.window)

        capture.hasWindow = true
        settings.context.offerWindow = false
        await refresh(notes)
        XCTAssertNil(suggestions.window)

        // The + menu still sees a browser's window.
        let browserWindow = await suggestions.hasCapturableWindow(chrome)
        XCTAssertTrue(browserWindow)
    }

    func testDismissedWindowChipReturnsOnTheNextOpen() async {
        capture.hasWindow = true
        await refresh(notes)
        suggestions.dismissWindow()
        XCTAssertNil(suggestions.window)

        await refresh(notes)
        XCTAssertNil(suggestions.window)

        suggestions.clear()
        await refresh(notes)
        XCTAssertNotNil(suggestions.window)
    }

    func testClearRemovesBothChips() async {
        reader.result = snapshot("text")
        capture.hasWindow = true
        await refresh(notes)
        XCTAssertNotNil(suggestions.selection)
        XCTAssertNotNil(suggestions.window)

        suggestions.clear()
        XCTAssertNil(suggestions.selection)
        XCTAssertNil(suggestions.window)

        await refresh(nil)
        XCTAssertNil(suggestions.selection)
        XCTAssertNil(suggestions.window)
    }

    // MARK: Capture

    func testCaptureNeedsScreenRecording() async {
        permissions.statuses[.screenRecording] = .denied
        do {
            _ = try await suggestions.captureWindow(of: notes)
            XCTFail("Captured without permission")
        } catch {
            XCTAssertEqual(error as? WindowCaptureError, .permissionNeeded)
        }
        XCTAssertEqual(capture.captures, 0)
    }

    func testCaptureRefusesPasswordManagers() async {
        do {
            _ = try await suggestions.captureWindow(of: keychain)
            XCTFail("Captured a password manager")
        } catch {
            XCTAssertEqual(error as? WindowCaptureError, .passwordManager(appName: "Keychain Access"))
        }
        XCTAssertEqual(capture.captures, 0)
    }

    func testCapturedWindowIsNotKeptInHistoryAndRemovesTheChip() async throws {
        capture.hasWindow = true
        await refresh(notes)
        XCTAssertNotNil(suggestions.window)

        let attachment = try await suggestions.captureWindow(of: notes)
        XCTAssertFalse(attachment.retainsPayloadInHistory)
        XCTAssertEqual(capture.captures, 1)
        XCTAssertNil(suggestions.window)
    }
}

// MARK: - Fakes

private final class SuggestionsFakeReader: SelectionReading, @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: SelectionSnapshot?
    private var storedReads: [AppRef] = []
    private var hold = false
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var result: SelectionSnapshot? {
        get { lock.withLock { storedResult } }
        set { lock.withLock { storedResult = newValue } }
    }

    var holdsReads: Bool {
        get { lock.withLock { hold } }
        set {
            lock.withLock {
                hold = newValue
                if newValue { released = false }
            }
        }
    }

    var reads: [AppRef] { lock.withLock { storedReads } }

    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { waiting.removeAll() }
            return waiting
        }
        pending.forEach { $0.resume() }
    }

    func read(from app: AppRef) async -> SelectionSnapshot? {
        let (answer, shouldHold) = lock.withLock { () -> (SelectionSnapshot?, Bool) in
            storedReads.append(app)
            return (storedResult, hold)
        }
        if shouldHold {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if released { return true }
                    waiting.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return answer
    }

    func snapshot(serviceText: String, app: AppRef?) async -> SelectionSnapshot {
        SelectionSnapshot(text: serviceText, app: app, windowTitle: nil, range: nil, element: nil, source: .service)
    }
}

private final class SuggestionsFakeCapture: WindowCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedHasWindow = false
    private var checks: [AppRef] = []
    private var captureCount = 0

    var hasWindow: Bool {
        get { lock.withLock { storedHasWindow } }
        set { lock.withLock { storedHasWindow = newValue } }
    }

    var windowChecks: [AppRef] { lock.withLock { checks } }
    var captures: Int { lock.withLock { captureCount } }

    func hasCapturableWindow(_ app: AppRef) async -> Bool {
        lock.withLock {
            checks.append(app)
            return storedHasWindow
        }
    }

    func capture(_ app: AppRef) async throws -> Attachment {
        lock.withLock { captureCount += 1 }
        return Attachment(kind: .image, displayName: "\(app.name) window.png", badge: "PNG",
                          payload: .image(mediaType: "image/png", base64: "iVBORw0KGgo="), byteCount: 12)
    }
}
