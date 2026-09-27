//
//  AnswerInserterTests.swift
//  OttoTests
//
//  The paste sequence against a fake environment, a recording key sender and a private pasteboard:
//  no real apps, Accessibility calls or key events.
//

import AppKit
import ApplicationServices
import XCTest
@testable import Otto

@MainActor
final class AnswerInserterTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var environment: InserterFakeEnvironment!
    private var keys: InserterRecordingKeys!
    private var inserter: AnswerInserter!
    private var log: InserterEventLog!

    private let notes = AppRef(pid: 4242, bundleID: "com.apple.Notes", name: "Notes")
    private let terminal = AppRef(pid: 4343, bundleID: "com.apple.Terminal", name: "Terminal")

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("otto.tests.inserter.\(UUID().uuidString)"))
        log = InserterEventLog()
        environment = InserterFakeEnvironment(frontmost: notes.pid, log: log)
        keys = InserterRecordingKeys(log: log)
        inserter = AnswerInserter(pasteboard: pasteboard, keys: keys, environment: environment)
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        pasteboard = nil
    }

    // MARK: Helpers

    private func request(_ markdown: String = "Hello **there**", app: AppRef? = nil, mode: InsertMode = .paste,
                         selection: SelectionSnapshot? = nil, restore: Bool = true) -> InsertRequest {
        InsertRequest(markdown: markdown, target: InsertTarget(app: app ?? notes, selection: selection),
                      mode: mode, restoreClipboard: restore)
    }

    private func putOnClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func perform(_ request: InsertRequest) async -> InsertOutcome {
        await inserter.perform(request) { [log] in log?.record("relinquish") }
    }

    private var clipboardIsMarkedTransient: Bool {
        pasteboard.types?.contains(ClipboardMarkers.transient) ?? false
    }

    private func selectionSnapshot() -> SelectionSnapshot {
        SelectionSnapshot(text: "old text", app: notes, windowTitle: nil, range: CFRange(location: 3, length: 8),
                          element: AXElementRef(AXUIElementCreateApplication(notes.pid)), source: .accessibility)
    }

    // MARK: Happy path

    func testPastesOnceAndRestoresTheClipboardAfterTheDelay() async {
        putOnClipboard("what I had copied")
        environment.fingerprints = [ValueFingerprint(characterCount: 3, valueHash: "a"),
                                    ValueFingerprint(characterCount: 18, valueHash: "b")]
        var clipboardDuringPaste: String?
        var transientDuringPaste = false
        keys.onPaste = { [unowned self] in
            clipboardDuringPaste = pasteboard.string(forType: .string)
            transientDuringPaste = clipboardIsMarkedTransient
        }

        let outcome = await perform(request())

        XCTAssertEqual(outcome, .pasted(verified: true, clipboard: .restored))
        XCTAssertEqual(keys.pasteCount, 1)
        XCTAssertEqual(clipboardDuringPaste, "Hello there")
        XCTAssertTrue(transientDuringPaste)
        XCTAssertEqual(pasteboard.string(forType: .string), "what I had copied")
        XCTAssertEqual(log.events, ["relinquish", "paste"])
        // Verify after 300 ms, restore 400 ms later (700 ms after ⌘V).
        XCTAssertEqual(environment.sleeps.filter { $0 >= .milliseconds(300) },
                       [.milliseconds(300), .milliseconds(400)])
        XCTAssertFalse(inserter.isInserting)
    }

    func testUserCopyingDuringTheDelayIsNeverOverwritten() async {
        putOnClipboard("before")
        keys.onPaste = { [unowned self] in
            pasteboard.clearContents()
            pasteboard.setString("copied meanwhile", forType: .string)
        }

        let outcome = await perform(request())

        XCTAssertEqual(outcome, .pasted(verified: nil, clipboard: .changedMeanwhile))
        XCTAssertEqual(pasteboard.string(forType: .string), "copied meanwhile")
    }

    func testRestoreOffLeavesTheAnswerUnmarked() async {
        putOnClipboard("before")

        let outcome = await perform(request(restore: false))

        XCTAssertEqual(outcome, .pasted(verified: nil, clipboard: .keptAnswer))
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello there")
        XCTAssertFalse(clipboardIsMarkedTransient)
    }

    func testChromiumTargetsWaitLonger() async {
        environment.chromium = true

        _ = await perform(request())

        XCTAssertEqual(environment.sleeps.filter { $0 >= .milliseconds(300) },
                       [.milliseconds(600), .milliseconds(900)])
    }

    func testWaitsForHeldModifiersThenSettles() async {
        keys.modifierPollsBeforeRelease = 3

        _ = await perform(request())

        XCTAssertEqual(environment.sleeps.prefix(4), [.milliseconds(10), .milliseconds(10), .milliseconds(10),
                                                      .milliseconds(60)])
        XCTAssertEqual(keys.pasteCount, 1)
    }

    // MARK: Preflight

    func testPreflightNeedsAccessibilityWhenUntrusted() async {
        environment.isAccessibilityTrusted = false
        let preflight = await inserter.preflight(request())
        XCTAssertEqual(preflight, .needsAccessibility)
    }

    func testPreflightTargetGone() async {
        environment.running = false
        let preflight = await inserter.preflight(request())
        XCTAssertEqual(preflight, .targetGone)
    }

    func testPreflightReady() async {
        let preflight = await inserter.preflight(request())
        XCTAssertEqual(preflight, .ready)
    }

    func testTerminalMultilineNeedsConfirmationThenProceeds() async {
        environment.frontmost = terminal.pid
        let answer = "```bash\ncd ~/src\nmake\nmake install\n```"
        let first = await inserter.preflight(request(answer, app: terminal))
        XCTAssertEqual(first, .confirmMultiline(lines: 3))

        var confirmed = request(answer, app: terminal)
        confirmed.confirmedMultiline = true
        let second = await inserter.preflight(confirmed)
        XCTAssertEqual(second, .ready)

        let outcome = await perform(confirmed)
        XCTAssertEqual(outcome, .pasted(verified: nil, clipboard: .restored))
        XCTAssertEqual(keys.pasteCount, 1)
    }

    func testChangedSelectionAsksUnlessPastingAtCursor() async {
        environment.selectionStateResult = .changed
        let replace = request(mode: .replaceSelection, selection: selectionSnapshot())
        let preflight = await inserter.preflight(replace)
        XCTAssertEqual(preflight, .selectionChanged)

        var atCursor = replace
        atCursor.allowPasteAtCursor = true
        let allowed = await inserter.preflight(atCursor)
        XCTAssertEqual(allowed, .ready)
    }

    func testReplaceRestoresAMovedSelectionBeforePasting() async {
        environment.selectionStateResult = .restorable

        let outcome = await perform(request(mode: .replaceSelection, selection: selectionSnapshot()))

        XCTAssertEqual(outcome, .pasted(verified: nil, clipboard: .restored))
        XCTAssertEqual(log.events, ["relinquish", "restoreSelection", "paste"])
    }

    // MARK: Fallbacks

    func testSecureInputPostsNoKeysAndLeavesTheAnswerUnmarked() async {
        putOnClipboard("before")
        keys.secure = true

        let outcome = await perform(request())

        XCTAssertEqual(outcome, .copiedOnly(.secureInput))
        XCTAssertEqual(keys.pasteCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello there")
        XCTAssertFalse(clipboardIsMarkedTransient)
    }

    func testSecureFocusedFieldPostsNoKeys() async {
        environment.secureField = true

        let outcome = await perform(request())

        XCTAssertEqual(outcome, .copiedOnly(.secureInput))
        XCTAssertEqual(keys.pasteCount, 0)
    }

    func testActivationTimeoutCopiesWithoutRestoring() async {
        putOnClipboard("before")
        environment.frontmost = 1
        environment.activatesOnRequest = false

        let outcome = await perform(request())

        XCTAssertEqual(outcome, .copiedOnly(.couldNotActivate))
        XCTAssertEqual(environment.activationRequests, [notes])
        XCTAssertEqual(keys.pasteCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello there")
        XCTAssertFalse(clipboardIsMarkedTransient)
        // Polled every 15 ms for at most 700 ms.
        XCTAssertEqual(environment.sleeps.filter { $0 == .milliseconds(15) }.count, 46)
    }

    func testActivationThatSucceedsPastes() async {
        environment.frontmost = 1

        let outcome = await perform(request())

        XCTAssertEqual(environment.activationRequests, [notes])
        XCTAssertEqual(outcome, .pasted(verified: nil, clipboard: .restored))
        XCTAssertEqual(keys.pasteCount, 1)
    }

    func testFrontmostAppChangingDuringTheSettleCopiesAndPostsNoPaste() async {
        putOnClipboard("before")
        environment.onSleep = { [unowned self] duration in
            if duration == AnswerInserter.Timing.settle { environment.frontmost = 999 }
        }

        let outcome = await perform(request())

        XCTAssertEqual(outcome, .copiedOnly(.couldNotActivate))
        XCTAssertEqual(keys.pasteCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello there")
        XCTAssertFalse(clipboardIsMarkedTransient)
    }

    func testUnchangedFingerprintMeansPasteNotObservedAndNoRestore() async {
        putOnClipboard("before")
        let same = ValueFingerprint(characterCount: 5, valueHash: "same")
        environment.fingerprints = [same, same]

        let outcome = await perform(request())

        XCTAssertEqual(outcome, .copiedOnly(.pasteNotObserved))
        XCTAssertEqual(keys.pasteCount, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello there")
        XCTAssertFalse(clipboardIsMarkedTransient)
    }

    func testTargetGoneCopiesUnmarked() async {
        environment.running = false

        let outcome = await perform(request())

        XCTAssertEqual(outcome, .copiedOnly(.targetGone))
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello there")
        XCTAssertFalse(clipboardIsMarkedTransient)
        XCTAssertEqual(log.events, [])
    }

    func testFailingToCreateKeyEventsFallsBackToCopy() async {
        keys.failsToPost = true

        let outcome = await perform(request())

        XCTAssertEqual(outcome, .copiedOnly(.pasteNotObserved))
        XCTAssertFalse(clipboardIsMarkedTransient)
    }

    // MARK: Password-manager clipboards

    func testConcealedClipboardIsClearedNotRestored() async {
        pasteboard.clearContents()
        let secret = NSPasteboardItem()
        secret.setString("hunter2", forType: .string)
        secret.setData(Data(), forType: ClipboardMarkers.concealed)
        pasteboard.writeObjects([secret])

        let outcome = await perform(request())

        XCTAssertEqual(outcome, .pasted(verified: nil, clipboard: .clearedConcealed))
        XCTAssertEqual(keys.pasteCount, 1)
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
    }

    func testConcealedClipboardIsNotClearedWhenTheUserCopiedMeanwhile() async {
        pasteboard.clearContents()
        let secret = NSPasteboardItem()
        secret.setString("hunter2", forType: .string)
        secret.setData(Data(), forType: ClipboardMarkers.concealed)
        pasteboard.writeObjects([secret])
        keys.onPaste = { [unowned self] in putOnClipboard("new copy") }

        let outcome = await perform(request())

        XCTAssertEqual(outcome, .pasted(verified: nil, clipboard: .changedMeanwhile))
        XCTAssertEqual(pasteboard.string(forType: .string), "new copy")
    }

    func testTooLargeClipboardIsReplaced() async {
        pasteboard.clearContents()
        let promise = NSPasteboardItem()
        promise.setString("public.png", forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"))
        pasteboard.writeObjects([promise])

        let outcome = await perform(request())

        XCTAssertEqual(outcome, .pasted(verified: nil, clipboard: .tooLargeToKeep))
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello there")
    }

    // MARK: Re-entry and copy

    func testASecondPasteDuringAPasteIsIgnored() async {
        var nested: InsertOutcome?
        let outcome = await inserter.perform(request()) { [unowned self] in
            nested = await inserter.perform(request()) {}
        }
        XCTAssertEqual(nested, .busy)
        XCTAssertEqual(outcome, .pasted(verified: nil, clipboard: .restored))
        XCTAssertEqual(keys.pasteCount, 1)
    }

    func testCopyWritesRichTextUnmarked() {
        inserter.copy("Some **bold** text", category: .standard)

        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "Some bold text")
        XCTAssertNotNil(pasteboard.data(forType: .rtf))
        XCTAssertNotNil(pasteboard.string(forType: .html))
        XCTAssertFalse(clipboardIsMarkedTransient)
    }
}

// MARK: - Fakes

@MainActor private final class InserterEventLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

@MainActor private final class InserterFakeEnvironment: InsertEnvironment {
    var isAccessibilityTrusted = true
    var frontmost: pid_t?
    var running = true
    var chromium = false
    var secureField = false
    var activatesOnRequest = true
    /// Returned by successive fingerprint reads; nil once exhausted.
    var fingerprints: [ValueFingerprint?] = []
    var selectionStateResult: SelectionState = .unknown
    var onSleep: ((Duration) -> Void)?

    private(set) var activationRequests: [AppRef] = []
    private(set) var sleeps: [Duration] = []
    private let log: InserterEventLog

    init(frontmost: pid_t?, log: InserterEventLog) {
        self.frontmost = frontmost
        self.log = log
    }

    func frontmostPID() -> pid_t? { frontmost }
    func isRunning(_ app: AppRef) -> Bool { running }

    func requestActivation(of app: AppRef) {
        activationRequests.append(app)
        if activatesOnRequest { frontmost = app.pid }
    }

    func isChromiumOrElectron(_ app: AppRef) -> Bool { chromium }
    func focusedElementIsSecure(in app: AppRef) async -> Bool { secureField }

    func focusedValueFingerprint(in app: AppRef) async -> ValueFingerprint? {
        fingerprints.isEmpty ? nil : fingerprints.removeFirst()
    }

    func selectionState(of snapshot: SelectionSnapshot) async -> SelectionState { selectionStateResult }

    func restoreSelection(_ snapshot: SelectionSnapshot) async -> Bool {
        log.record("restoreSelection")
        return true
    }

    func sleep(for duration: Duration) async {
        sleeps.append(duration)
        onSleep?(duration)
    }
}

@MainActor private final class InserterRecordingKeys: KeySending {
    var secure = false
    var failsToPost = false
    /// `areModifiersDown()` answers true this many times first.
    var modifierPollsBeforeRelease = 0
    var onPaste: (() -> Void)?
    private(set) var pasteCount = 0
    private let log: InserterEventLog

    init(log: InserterEventLog) {
        self.log = log
    }

    nonisolated var isSecureInputEnabled: Bool { MainActor.assumeIsolated { secure } }

    nonisolated func areModifiersDown() -> Bool {
        MainActor.assumeIsolated {
            guard modifierPollsBeforeRelease > 0 else { return false }
            modifierPollsBeforeRelease -= 1
            return true
        }
    }

    nonisolated func postPaste() throws {
        try MainActor.assumeIsolated {
            if failsToPost { throw KeySendError.cannotCreateEvent }
            pasteCount += 1
            log.record("paste")
            onPaste?()
        }
    }
}
