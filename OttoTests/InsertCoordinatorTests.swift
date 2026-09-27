//
//  InsertCoordinatorTests.swift
//  OttoTests
//
//  Paste targets keyed by the user message, preferred modes, confirmation and activity state, and the
//  closed-notch flash lifetime, over an AnswerInserter with a fake environment and a private pasteboard.
//

import AppKit
import XCTest
@testable import Otto

@MainActor
final class InsertCoordinatorTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var environment: CoordinatorFakeEnvironment!
    private var keys: CoordinatorFakeKeys!
    private var settings: AppSettings!
    private var coordinator: InsertCoordinator!

    private let notes = AppRef(pid: 5151, bundleID: "com.apple.Notes", name: "Notes")

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("otto.tests.coordinator.\(UUID().uuidString)"))
        environment = CoordinatorFakeEnvironment(frontmost: notes.pid)
        keys = CoordinatorFakeKeys()
        settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        let inserter = AnswerInserter(pasteboard: pasteboard, keys: keys, environment: environment)
        coordinator = InsertCoordinator(inserter: inserter, settings: settings)
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        pasteboard = nil
    }

    private func conversation() -> (user: ChatMessage, assistant: ChatMessage) {
        (ChatMessage(role: .user, text: "Rewrite this"), ChatMessage(role: .assistant, text: "Done."))
    }

    private func selection() -> SelectionSnapshot {
        SelectionSnapshot(text: "old", app: notes, windowTitle: nil, range: nil, element: nil, source: .service)
    }

    // MARK: Targets

    func testTargetIsFoundThroughThePrecedingUserMessage() {
        let (user, assistant) = conversation()
        let target = InsertTarget(app: notes, selection: nil)
        coordinator.recordTarget(userMessageID: user.id, target: target)

        XCTAssertEqual(coordinator.targets[user.id], target)
        XCTAssertEqual(coordinator.target(forAssistant: assistant.id, in: [user, assistant]), target)
    }

    func testTargetSurvivesRetryBecauseItIsKeyedByTheUserMessage() {
        let (user, assistant) = conversation()
        let target = InsertTarget(app: notes, selection: nil)
        coordinator.recordTarget(userMessageID: user.id, target: target)

        // Retry replaces the assistant message with a new one after the same question.
        let retried = ChatMessage(role: .assistant, text: "Done again.")
        XCTAssertNil(coordinator.target(forAssistant: assistant.id, in: [user, retried]))
        XCTAssertEqual(coordinator.target(forAssistant: retried.id, in: [user, retried]), target)
    }

    func testTargetBelongsToItsOwnTurn() {
        let (firstUser, firstAssistant) = conversation()
        let secondUser = ChatMessage(role: .user, text: "Another")
        let secondAssistant = ChatMessage(role: .assistant, text: "Reply")
        let messages = [firstUser, firstAssistant, secondUser, secondAssistant]
        coordinator.recordTarget(userMessageID: firstUser.id, target: InsertTarget(app: notes, selection: nil))

        XCTAssertNotNil(coordinator.target(forAssistant: firstAssistant.id, in: messages))
        XCTAssertNil(coordinator.target(forAssistant: secondAssistant.id, in: messages))
        XCTAssertNil(coordinator.target(forAssistant: firstUser.id, in: messages))
    }

    func testTargetIsNilOnceTheAppQuit() {
        let (user, assistant) = conversation()
        coordinator.recordTarget(userMessageID: user.id, target: InsertTarget(app: notes, selection: nil))
        environment.running = false

        XCTAssertNil(coordinator.target(forAssistant: assistant.id, in: [user, assistant]))
    }

    func testPreferredModeIsReplaceWhenTheQuestionCarriedASelection() {
        let (user, assistant) = conversation()
        XCTAssertEqual(coordinator.preferredMode(forAssistant: assistant.id, in: [user, assistant]), .paste)

        coordinator.recordTarget(userMessageID: user.id, target: InsertTarget(app: notes, selection: selection()))
        XCTAssertEqual(coordinator.preferredMode(forAssistant: assistant.id, in: [user, assistant]), .replaceSelection)
    }

    func testResetClearsTargetsAndActivity() {
        let (user, _) = conversation()
        coordinator.recordTarget(userMessageID: user.id, target: InsertTarget(app: notes, selection: nil))
        coordinator.setConfirmation(.selectionChanged(messageID: UUID(), appName: "Notes"))

        coordinator.reset()

        XCTAssertTrue(coordinator.targets.isEmpty)
        XCTAssertNil(coordinator.activity)
    }

    // MARK: Preflight and perform

    func testPreflightUsesThePolicyAndEnvironment() async {
        let target = InsertTarget(app: notes, selection: nil)
        let ready = await coordinator.preflight(markdown: "Hi", target: target, mode: .paste)
        XCTAssertEqual(ready, .ready)

        environment.isAccessibilityTrusted = false
        let untrusted = await coordinator.preflight(markdown: "Hi", target: target, mode: .paste)
        XCTAssertEqual(untrusted, .needsAccessibility)
    }

    func testConfirmationRowStateAndConfirmedPerform() async {
        let terminal = AppRef(pid: 5252, bundleID: "com.googlecode.iterm2", name: "iTerm")
        environment.frontmost = terminal.pid
        let target = InsertTarget(app: terminal, selection: nil)
        let messageID = UUID()
        let preflight = await coordinator.preflight(markdown: "ls\npwd", target: target, mode: .paste)
        XCTAssertEqual(preflight, .confirmMultiline(lines: 2))

        let pending = InsertActivity.confirmMultiline(messageID: messageID, mode: .paste, lines: 2, appName: "iTerm")
        coordinator.setConfirmation(pending)
        XCTAssertEqual(coordinator.activity, pending)

        let outcome = await coordinator.perform(markdown: "ls\npwd", target: target, mode: .paste, messageID: messageID,
                                                confirmed: true, relinquishFocus: {})
        XCTAssertEqual(outcome, .pasted(verified: nil, clipboard: .restored))
        XCTAssertEqual(keys.pasteCount, 1)
        XCTAssertNil(coordinator.activity)
    }

    func testActivityIsInsertingWhilePasting() async {
        let messageID = UUID()
        var during: InsertActivity?
        _ = await coordinator.perform(markdown: "Hi", target: InsertTarget(app: notes, selection: nil), mode: .paste,
                                      messageID: messageID, confirmed: false) { [unowned self] in
            during = coordinator.activity
        }
        XCTAssertEqual(during, .inserting(messageID: messageID))
        XCTAssertNil(coordinator.activity)
    }

    func testRestoreClipboardSettingIsHonored() async {
        settings.context.restoreClipboard = false
        let outcome = await coordinator.perform(markdown: "Hi", target: InsertTarget(app: notes, selection: nil),
                                                mode: .paste, messageID: UUID(), confirmed: false, relinquishFocus: {})
        XCTAssertEqual(outcome, .pasted(verified: nil, clipboard: .keptAnswer))
        XCTAssertEqual(pasteboard.string(forType: .string), "Hi")
    }

    func testCopyFallbackSetsNoFlash() async {
        keys.secure = true
        let outcome = await coordinator.perform(markdown: "Hi", target: InsertTarget(app: notes, selection: nil),
                                                mode: .paste, messageID: UUID(), confirmed: false, relinquishFocus: {})
        XCTAssertEqual(outcome, .copiedOnly(.secureInput))
        XCTAssertNil(coordinator.closedFlash)
    }

    // MARK: Flash

    func testClosedFlashClearsAfterOnePointFourSeconds() async throws {
        let outcome = await coordinator.perform(markdown: "Hi", target: InsertTarget(app: notes, selection: nil),
                                                mode: .paste, messageID: UUID(), confirmed: false, relinquishFocus: {})
        XCTAssertEqual(outcome, .pasted(verified: nil, clipboard: .restored))
        XCTAssertEqual(coordinator.closedFlash, .pasted(appName: "Notes"))
        XCTAssertEqual(InsertCoordinator.flashLifetime, .milliseconds(1400))

        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertEqual(coordinator.closedFlash, .pasted(appName: "Notes"))

        let deadline = ContinuousClock.now + .seconds(3)
        while coordinator.closedFlash != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(coordinator.closedFlash)
    }

    // MARK: Copy

    func testCopyOnlyWritesUnmarkedForTheTargetCategory() {
        let xcode = AppRef(pid: 5353, bundleID: "com.apple.dt.Xcode", name: "Xcode")
        coordinator.copyOnly(markdown: "Use **this**", target: InsertTarget(app: xcode, selection: nil))
        XCTAssertEqual(pasteboard.string(forType: .string), "Use **this**")
        XCTAssertFalse(pasteboard.types?.contains(ClipboardMarkers.transient) ?? false)

        coordinator.copyOnly(markdown: "Use **this**", target: nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "Use this")
        XCTAssertNotNil(pasteboard.data(forType: .rtf))
    }
}

// MARK: - Fakes

@MainActor private final class CoordinatorFakeEnvironment: InsertEnvironment {
    var isAccessibilityTrusted = true
    var frontmost: pid_t?
    var running = true

    init(frontmost: pid_t?) {
        self.frontmost = frontmost
    }

    func frontmostPID() -> pid_t? { frontmost }
    func isRunning(_ app: AppRef) -> Bool { running }
    func requestActivation(of app: AppRef) { frontmost = app.pid }
    func isChromiumOrElectron(_ app: AppRef) -> Bool { false }
    func focusedElementIsSecure(in app: AppRef) async -> Bool { false }
    func focusedValueFingerprint(in app: AppRef) async -> ValueFingerprint? { nil }
    func selectionState(of snapshot: SelectionSnapshot) async -> SelectionState { .unknown }
    func restoreSelection(_ snapshot: SelectionSnapshot) async -> Bool { true }
    func sleep(for duration: Duration) async {}
}

private final class CoordinatorFakeKeys: KeySending {
    var secure = false
    private(set) var pasteCount = 0

    var isSecureInputEnabled: Bool { secure }
    func areModifiersDown() -> Bool { false }
    func postPaste() throws { pasteCount += 1 }
}
