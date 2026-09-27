//
//  NotchViewModelFeatureTests.swift
//  OttoTests
//
//  The view model's feature flows over fakes: voice (consent from the mic button only, macOS permissions, the
//  Dictation card, what a transcript does, the watchdog), Services, pasting an answer back with its permission
//  step, confirmations and clipboard notices, drop routing and the Shelf, history continuity, the closed notch's
//  glance inputs, media and calendar actions, action rows and the neighbor card. Nothing here touches TCC, the
//  microphone, Apple Events, the user's clipboard or their files.
//

import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Otto

// MARK: - Harness

/// A clock that only moves when the test advances it (the voice watchdog and timeouts).
final class NotchFeatureClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Swift.Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumeNow: Bool = lock.withLock {
                    if Task.isCancelled || deadline <= current { return true }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return false
                }
                if resumeNow {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    var hasSleeperAfterNow: Bool {
        lock.withLock { sleepers.values.contains { $0.deadline > current } }
    }

    func advance(by duration: Swift.Duration) {
        let due: [Sleeper] = lock.withLock {
            current = current.advanced(by: duration)
            let dueIDs = sleepers.filter { $0.value.deadline <= current }.map(\.key)
            return dueIDs.compactMap { sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}

/// The speech engines the voice controller made, playing `script`.
@MainActor final class NotchFeatureEngines {
    var script: [(delay: Duration, text: String, level: Float)] = []
    private(set) var made: [ScriptedSpeechEngine] = []

    func make() -> SpeechEngine {
        let engine = ScriptedSpeechEngine(script: script)
        made.append(engine)
        return engine
    }
}

/// The paste target's world: which apps run and are frontmost, secure fields, the selection's state. Accessibility
/// trust comes from the harness's permissions center, so granting it on the probe lets the retry paste.
@MainActor final class NotchFeatureInsertEnvironment: InsertEnvironment {
    let permissions: PermissionsCenter
    var frontmost: pid_t?
    var running: Set<pid_t> = []
    var secureField = false
    var selection: SelectionState = .unchanged

    init(permissions: PermissionsCenter) {
        self.permissions = permissions
    }

    var isAccessibilityTrusted: Bool { permissions.status(.accessibility) == .granted }
    func frontmostPID() -> pid_t? { frontmost }
    func isRunning(_ app: AppRef) -> Bool { running.contains(app.pid) }
    func requestActivation(of app: AppRef) { frontmost = app.pid }
    func isChromiumOrElectron(_ app: AppRef) -> Bool { false }
    func focusedElementIsSecure(in app: AppRef) async -> Bool { secureField }
    func focusedValueFingerprint(in app: AppRef) async -> ValueFingerprint? { nil }
    func selectionState(of snapshot: SelectionSnapshot) async -> SelectionState { selection }
    func restoreSelection(_ snapshot: SelectionSnapshot) async -> Bool { true }
    func sleep(for duration: Duration) async {}
}

/// Counts ⌘V instead of posting it.
final class NotchFeatureKeys: KeySending {
    var isSecureInputEnabled = false
    private(set) var pastes = 0
    func areModifiersDown() -> Bool { false }
    func postPaste() throws { pastes += 1 }
}

/// Counts "Quit & Reopen Otto" instead of quitting.
@MainActor final class NotchFeatureRelauncher: AppRelaunching {
    private(set) var count = 0
    func relaunch() { count += 1 }
}

/// Media players behind a switch: Automation "would prompt" until `allowed`, then commands run.
final class NotchFeatureMediaScripting: MediaScripting, @unchecked Sendable {
    private let lock = NSLock()
    private var isAllowed = false
    private var commands: [MediaCommand] = []

    var allowed: Bool {
        get { lock.withLock { isAllowed } }
        set { lock.withLock { isAllowed = newValue } }
    }

    var ran: [MediaCommand] { lock.withLock { commands } }

    func isRunning(_ player: MediaPlayer) -> Bool { player == .music }

    func consent(for player: MediaPlayer, askUser: Bool) async -> BrowserContext.AutomationConsent {
        allowed ? .authorized : .wouldPrompt
    }

    func run(_ command: MediaCommand, on player: MediaPlayer, allowLaunch: Bool) async throws -> PlaybackState? {
        lock.withLock { commands.append(command) }
        return .paused
    }

    func nowPlaying(_ player: MediaPlayer) async -> NowPlayingItem? { nil }
}

/// A view model over inert services, except: a permissions center on a MutablePermissionProbe (20 ms polls, System
/// Settings never opens), a fake tool executor, voice on scripted engines and a manual clock, paste on a fake
/// environment and a private pasteboard, and the Shelf on a private pasteboard. The window hooks are recorded.
@MainActor final class NotchFeatureHarness {
    let settings: AppSettings
    let chat: ChatSession
    let executor = FakeToolExecutor()
    let probe: MutablePermissionProbe
    let permissions: PermissionsCenter
    let relauncher = NotchFeatureRelauncher()
    let engines = NotchFeatureEngines()
    let voiceClock = NotchFeatureClock()
    let insertEnvironment: NotchFeatureInsertEnvironment
    let keys = NotchFeatureKeys()
    let pasteboard: NSPasteboard
    let shelfPasteboard: NSPasteboard
    let history: HistoryController
    let vm: NotchViewModel
    var uptime: TimeInterval = 5_000
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private(set) var openedURLs: [URL] = []
    private(set) var settingsRequests: [(tab: SettingsTab?, anchor: SettingsAnchor?)] = []
    private(set) var keyRequests: [Bool] = []
    private(set) var announcements: [String] = []

    let notes = AppRef(pid: 5151, bundleID: "com.apple.Notes", name: "Notes")

    init(_ testCase: XCTestCase, statuses: [Permission: PermissionStatus] = [:],
         responses: [ScriptedLLMClient.Response] = [],
         media: MediaScripting = DemoMediaScripting()) {
        settings = AppSettings(defaults: TestDefaults.make(for: testCase), usesKeychain: false)
        settings.suggestBrowserTab = false
        let client = ScriptedLLMClient(responses)
        chat = ChatSession(settings: settings, makeClient: { client }, executor: executor)
        probe = MutablePermissionProbe(statuses, default: .notDetermined)
        permissions = PermissionsCenter(probe: probe, defaults: TestDefaults.make(for: testCase),
                                        openURL: { _ in }, pollInterval: .milliseconds(20), relauncher: relauncher)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("otto.tests.vm-features.\(UUID().uuidString)"))
        shelfPasteboard = NSPasteboard(name: NSPasteboard.Name("otto.tests.vm-shelf.\(UUID().uuidString)"))
        insertEnvironment = NotchFeatureInsertEnvironment(permissions: permissions)

        var services = NotchServices.inert(settings: settings, chat: chat)
        services.permissions = permissions
        history = HistoryController(settings: settings, chat: chat, store: ConversationStore(location: .inMemory))
        services.history = history
        services.recents = RecentsState(history: history)
        let engines = self.engines
        services.voice = VoiceController(settings: settings, makeEngine: { engines.make() },
                                         speaker: ReplySpeaker(settings: settings, volume: 0),
                                         interruptions: InertVoiceInterruptions(), holdProbe: { _ in nil },
                                         clock: voiceClock)
        let inserter = AnswerInserter(pasteboard: pasteboard, keys: keys, environment: insertEnvironment)
        services.inserter = InsertCoordinator(inserter: inserter, settings: settings)
        services.nowPlaying = NowPlayingMonitor(settings: settings, scripting: media)
        services.suggestions = ContextSuggestions(settings: settings, permissions: permissions,
                                                  reader: InertSelectionReader(), capture: InertWindowCapture())
        vm = NotchViewModel(settings: settings, chat: chat, services: services)

        vm.shelf.pasteboard = shelfPasteboard
        vm.grantedCardLifetime = .milliseconds(20)
        let now = self.now
        vm.now = { now }
        vm.uptime = { [unowned self] in self.uptime }
        vm.announce = { [unowned self] in self.announcements.append($0) }
        vm.openExternalURL = { [unowned self] in self.openedURLs.append($0) }
        vm.onOpenSettingsTab = { [unowned self] tab, anchor in self.settingsRequests.append((tab, anchor)) }
        vm.onRequestKey = { [unowned self] in self.keyRequests.append($0) }

        testCase.addTeardownBlock { [pasteboard, shelfPasteboard] in
            pasteboard.releaseGlobally()
            shelfPasteboard.releaseGlobally()
        }
    }

    /// Voice on and both permissions granted (on the probe and in the center's cache).
    func enableVoice() async {
        settings.voice.enabled = true
        probe.set(.microphone, .granted)
        probe.set(.speechRecognition, .granted)
        await permissions.refresh([.microphone, .speechRecognition])
    }

    /// A finished exchange whose question was asked from `app` (running and frontmost).
    func answeredQuestion(from app: AppRef, reply text: String) async {
        insertEnvironment.running.insert(app.pid)
        insertEnvironment.frontmost = app.pid
        vm.setOpenContextApp(app)
        vm.composerText = "Rewrite this"
        vm.send()
        await waitForIdle()
        XCTAssertEqual(chat.messages.last?.text, text)
    }

    func waitForIdle(file: StaticString = #filePath, line: UInt = #line) async {
        await notchWaitUntil(file: file, line: line) { !self.chat.isStreaming }
    }

    /// Moves the voice clock and lets the controller's ticker run every tick that became due.
    func advanceVoice(_ duration: Duration) async {
        voiceClock.advance(by: duration)
        let deadline = Date().addingTimeInterval(3)
        repeat {
            try? await Task.sleep(for: .milliseconds(2))
        } while !(voiceClock.hasSleeperAfterNow || vm.voice.phase == .idle) && Date() < deadline
        await Task.yield()
    }

    /// Writes a file in a fresh temporary folder (removed by the test's teardown).
    func temporaryFile(_ name: String, contents: String = "hello", testCase: XCTestCase) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("otto-vm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}

/// A complete one-text-block reply.
func notchFeatureReply(_ text: String) -> ScriptedLLMClient.Response {
    let block: JSONValue = ["type": "text", "text": .string(text)]
    return .events([
        .messageStart(model: "claude-opus-5"),
        .textDelta(text),
        .completed(StreamResult(content: [block], stopReason: "end_turn", stopDetails: nil,
                                model: "claude-opus-5", usage: nil)),
    ])
}

@MainActor
func notchWaitUntil(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                    _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for condition", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

// MARK: - Tests

@MainActor
final class NotchViewModelFeatureTests: XCTestCase {
    // MARK: Voice

    func testVoiceConsentComesOnlyFromTheMicButton() async {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm

        // Holding the shortcut with voice off is an ordinary tap: nothing opens, nothing is asked.
        vm.beginVoice(.hold(.shortcut))
        XCTAssertFalse(vm.isOpen)
        XCTAssertNil(vm.card)
        XCTAssertEqual(vm.micState, .off)

        vm.beginVoice(.toggle(.micButton))
        XCTAssertTrue(vm.isOpen)
        XCTAssertTrue(vm.isEngaged)
        await notchWaitUntil { vm.card != nil }
        guard case .voiceConsent(let pending)? = vm.card?.kind else {
            return XCTFail("Expected the voice consent card, got \(String(describing: vm.card))")
        }
        XCTAssertEqual(pending, .toggle(.micButton))
        XCTAssertEqual(vm.card?.primary.title, "Turn On Voice")
        XCTAssertTrue(vm.card?.message.contains(harness.settings.shortcuts.hotKey.displayString) ?? false)
        XCTAssertTrue(vm.stayOpenHolds.contains(.promptDecision))

        // Esc is the safe choice: voice stays off.
        vm.performPromptSecondary()
        await notchWaitUntil { vm.card == nil }
        XCTAssertFalse(harness.settings.voice.enabled)
        XCTAssertFalse(vm.voice.isActive)
    }

    func testTurningVoiceOnWithAccessStartsListeningInToggleMode() async {
        let harness = NotchFeatureHarness(self, statuses: [.microphone: .granted, .speechRecognition: .granted])
        let vm = harness.vm
        harness.engines.script = [(.zero, "remind me", 0.5)]
        vm.beginVoice(.hold(.micButton))
        await notchWaitUntil { vm.card != nil }
        vm.performPromptPrimary(input: .trusted())

        await notchWaitUntil { vm.voice.isListening }
        XCTAssertTrue(harness.settings.voice.enabled)
        XCTAssertEqual(vm.voice.mode, .toggle(.micButton), "a session that waited on a card is a toggle")
        XCTAssertEqual(vm.micState, .listening)
        XCTAssertTrue(vm.stayOpenHolds.contains(.voiceSession))
        vm.cancelVoice()
    }

    func testRefusedMicrophoneShowsTheVoicePermissionCard() async {
        let harness = NotchFeatureHarness(self, statuses: [.microphone: .denied, .speechRecognition: .granted])
        let vm = harness.vm
        vm.beginVoice(.toggle(.micButton))
        await notchWaitUntil { vm.card != nil }
        vm.performCardAction(.enableVoice(.toggle(.micButton)))

        await notchWaitUntil { vm.permissionPrompt != nil }
        XCTAssertEqual(vm.permissionPrompt?.permission, .microphone)
        XCTAssertEqual(vm.permissionPrompt?.purpose, .voice)
        XCTAssertEqual(vm.permissionCardContent?.primaryAction, .openSystemSettings)
        XCTAssertEqual(vm.micState, .unavailable(.microphoneDenied))
        XCTAssertFalse(vm.voice.isActive)

        // Allowed in System Settings: the flow resumes and Otto starts listening.
        vm.permissionPromptAction(.openSystemSettings)
        await notchWaitUntil { vm.permissionPrompt?.phase == .waiting }
        harness.probe.set(.microphone, .granted)
        await notchWaitUntil { vm.voice.isListening }
        vm.cancelVoice()
    }

    func testDictationOffShowsItsCardUntilAStartSucceeds() async {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        await harness.enableVoice()
        vm.open(reason: .click, focus: true)

        vm.beginVoice(.toggle(.micButton))
        await notchWaitUntil { vm.voice.isListening }
        harness.engines.made.last?.simulateError(.dictationDisabled)

        await notchWaitUntil { vm.card != nil }
        XCTAssertEqual(vm.card?.kind, .voiceUnavailable(.dictationDisabled))
        XCTAssertEqual(vm.card?.title, "Dictation is off")
        XCTAssertEqual(vm.card?.primary.action, .openDictationSettings)
        XCTAssertEqual(vm.micState, .unavailable(.dictationDisabled))

        vm.performPromptPrimary(input: .trusted())
        await notchWaitUntil { !harness.openedURLs.isEmpty }
        XCTAssertEqual(harness.openedURLs, [URL(string: NotchViewModel.dictationSettingsURL)])
        XCTAssertEqual(vm.micState, .ready)

        // The next press tries again and succeeds.
        vm.beginVoice(.toggle(.micButton))
        await notchWaitUntil { vm.voice.isListening }
        XCTAssertNil(vm.card)
        vm.cancelVoice()
    }

    func testTranscriptIsSentWithTheComposersAttachments() async {
        let harness = NotchFeatureHarness(self, responses: [notchFeatureReply("Done.")])
        let vm = harness.vm
        await harness.enableVoice()
        harness.engines.script = [(.zero, "summarize this", 0.5)]
        vm.open(reason: .click, focus: true)
        let attachment = Attachment(kind: .text, displayName: "notes.txt", badge: "TXT",
                                    sourceURL: URL(fileURLWithPath: "/tmp/otto-tests/notes.txt"),
                                    payload: .text("hello"), byteCount: 5)
        vm.addAttachment(attachment)

        vm.beginVoice(.hold(.micButton))
        await notchWaitUntil { vm.voice.transcript == "summarize this" }
        vm.finishVoice(send: true)

        await notchWaitUntil { harness.chat.lastUserMessage != nil }
        let question = harness.chat.lastUserMessage
        XCTAssertEqual(question?.text, "summarize this")
        XCTAssertEqual(question?.attachments.map(\.displayName), ["notes.txt"])
        XCTAssertTrue(vm.composerText.isEmpty)
        XCTAssertTrue(vm.attachments.isEmpty)
        XCTAssertTrue(vm.voiceTurnUserMessageIDs.contains(question?.id ?? UUID()))
        await harness.waitForIdle()
    }

    func testSpokenQuestionWithTheNotchClosedOpensUnfocusedAndHolds() async {
        let harness = NotchFeatureHarness(self, responses: [notchFeatureReply("Sure.")])
        let vm = harness.vm
        await harness.enableVoice()
        harness.engines.script = [(.zero, "what time is it in Tokyo", 0.5)]

        vm.beginVoice(.hold(.shortcut))
        XCTAssertFalse(vm.isOpen, "the closed notch shows the listening pill instead")
        XCTAssertTrue(vm.closedLayout.showsPill)
        await notchWaitUntil { !vm.voice.transcript.isEmpty }
        vm.finishVoice(send: true)

        await notchWaitUntil { vm.isOpen }
        XCTAssertEqual(vm.openReason, .voice)
        XCTAssertFalse(vm.isEngaged)
        XCTAssertTrue(vm.voiceReplyHold)
        XCTAssertTrue(vm.shouldStayOpen)
        await harness.waitForIdle()

        // Clicking in ends the hold.
        vm.engage()
        XCTAssertFalse(vm.voiceReplyHold)
    }

    func testEmptyTranscriptShowsANoticeAndSendsNothing() async {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        await harness.enableVoice()
        harness.engines.script = []
        vm.open(reason: .click, focus: true)
        vm.beginVoice(.toggle(.micButton))
        await notchWaitUntil { vm.voice.isListening }
        vm.finishVoice(send: true)

        await notchWaitUntil { vm.transientNotice != nil }
        XCTAssertEqual(vm.transientNotice?.text, NotchViewModel.heardNothingNotice)
        XCTAssertNil(harness.chat.lastUserMessage)
    }

    func testTranscriptWhileAReplyStreamsGoesToTheComposer() async {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        await harness.enableVoice()
        harness.engines.script = [(.zero, "and in French", 0.5)]
        harness.chat.debugSeed(messages: [ChatMessage(role: .user, text: "Translate hello"),
                                          ChatMessage(role: .assistant, text: "Hola", state: .streaming)],
                               isStreaming: true)
        vm.open(reason: .click, focus: true)
        let userID = harness.chat.lastUserMessage?.id

        vm.beginVoice(.toggle(.micButton))
        await notchWaitUntil { !vm.voice.transcript.isEmpty }
        vm.finishVoice(send: true)

        await notchWaitUntil { vm.composerText == "and in French" }
        XCTAssertEqual(vm.transientNotice?.text, NotchViewModel.stillReplyingNotice)
        XCTAssertEqual(harness.chat.lastUserMessage?.id, userID)
    }

    func testWatchdogPutsTheWordsInTheComposerAndLeavesAClosedNotchClosed() async {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        await harness.enableVoice()
        harness.engines.script = [(.zero, "draft a note about the offsite", 0.6)]

        vm.beginVoice(.hold(.shortcut))
        await notchWaitUntil { !vm.voice.transcript.isEmpty }
        await harness.advanceVoice(.milliseconds(119_900))
        XCTAssertTrue(vm.voice.isListening)
        await harness.advanceVoice(.milliseconds(100))
        await notchWaitUntil { vm.voice.phase == .idle }

        XCTAssertEqual(vm.composerText, "draft a note about the offsite")
        XCTAssertNil(harness.chat.lastUserMessage, "the watchdog never sends")
        XCTAssertFalse(vm.isOpen, "nothing takes focus while the user may be away")
        XCTAssertNil(vm.transientNotice)

        // The notice waits for the next open.
        vm.open(reason: .click, focus: true)
        await notchWaitUntil { vm.transientNotice != nil }
        XCTAssertEqual(vm.transientNotice?.text, VoiceController.Notice.timeLimit)
    }

    func testRouteChangeWithoutInputFinishesIntoTheComposer() async {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        await harness.enableVoice()
        harness.engines.script = [(.zero, "the quarterly numbers", 0.5)]
        vm.open(reason: .click, focus: true)
        vm.beginVoice(.toggle(.micButton))
        await notchWaitUntil { !vm.voice.transcript.isEmpty }

        harness.engines.made.last?.simulateConfigurationChange(hasInput: true)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(vm.voice.isListening, "a route change that keeps an input keeps listening")

        harness.engines.made.last?.simulateConfigurationChange(hasInput: false)
        await notchWaitUntil { vm.voice.phase == .idle }
        XCTAssertEqual(vm.composerText, "the quarterly numbers")
        XCTAssertNil(harness.chat.lastUserMessage)
        await notchWaitUntil { vm.transientNotice != nil }
        XCTAssertEqual(vm.transientNotice?.text, VoiceController.Notice.noMicrophone)
    }

    // MARK: Services

    func testAskAboutServiceTextOpensFocusedWithASelectionChip() async {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        await vm.askAbout(serviceText: "Their going to the store", app: harness.notes)

        XCTAssertTrue(vm.isOpen)
        XCTAssertTrue(vm.isEngaged)
        XCTAssertEqual(vm.route, .chat)
        XCTAssertEqual(vm.openContextApp, harness.notes)
        XCTAssertEqual(vm.attachments.map(\.displayName), ["Selection from Notes"])
        XCTAssertFalse(vm.attachments.first?.retainsPayloadInHistory ?? true)
        let snapshot = vm.attachments.first.flatMap { vm.selectionSnapshots[$0.id] }
        XCTAssertEqual(snapshot?.text, "Their going to the store")
        XCTAssertEqual(snapshot?.source, .service)
        XCTAssertEqual(vm.composerPlaceholder, "Ask about your selection…")

        // Blank text never opens the notch.
        vm.close(.user)
        await vm.askAbout(serviceText: "  \n ", app: harness.notes)
        XCTAssertFalse(vm.isOpen)
    }

    func testAskAboutFilesAttachesThemOnChat() async throws {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        let file = try harness.temporaryFile("brief.txt", testCase: self)
        vm.navigate(to: .shelf)
        vm.askAbout(fileURLs: [file], app: harness.notes)

        XCTAssertTrue(vm.isOpen)
        XCTAssertTrue(vm.isEngaged)
        XCTAssertEqual(vm.route, .chat)
        await notchWaitUntil { !vm.attachments.isEmpty }
        XCTAssertEqual(vm.attachments.first?.displayName, "brief.txt")
    }

    func testAddToShelfOpensTheShelfUnfocused() async throws {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        let file = try harness.temporaryFile("plan.txt", testCase: self)
        vm.addToShelf(fileURLs: [file], openShelf: true)

        XCTAssertTrue(vm.isOpen)
        XCTAssertFalse(vm.isEngaged)
        XCTAssertEqual(vm.route, .shelf)
        XCTAssertEqual(vm.shelf.store.items.map(\.name), ["plan.txt"])
        XCTAssertEqual(vm.shelf.selection, Set(vm.shelf.store.items.map(\.id)))
        XCTAssertTrue(vm.stayOpenHolds.contains(.shelfLanding))

        harness.settings.shelf.enabled = false
        vm.close(.user)
        vm.addToShelf(fileURLs: [file], openShelf: true)
        XCTAssertEqual(vm.transientError, NotchViewModel.shelfOffMessage)
        XCTAssertEqual(vm.route, .chat)
    }

    // MARK: Insert

    func testPasteAsksForAccessibilityThenRetriesOnce() async {
        let harness = NotchFeatureHarness(self, responses: [notchFeatureReply("Their → They're")])
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        await harness.answeredQuestion(from: harness.notes, reply: "Their → They're")
        XCTAssertTrue(vm.canInsertLastAnswer)
        XCTAssertEqual(vm.insertTarget(forAssistant: harness.chat.messages.last?.id ?? UUID())?.app, harness.notes)

        vm.insertLastAnswer(mode: nil)
        await notchWaitUntil { vm.permissionPrompt != nil }
        XCTAssertEqual(vm.permissionPrompt?.permission, .accessibility)
        XCTAssertEqual(vm.permissionPrompt?.purpose, .paste(appName: "Notes"))
        XCTAssertEqual(harness.keys.pastes, 0)

        harness.probe.set(.accessibility, .granted)
        vm.permissionPromptAction(.request)
        await notchWaitUntil { harness.keys.pastes == 1 }
        XCTAssertFalse(vm.isOpen, "Otto closes and hands focus back before ⌘V")
        XCTAssertEqual(harness.keyRequests.last, false)
        XCTAssertEqual(vm.inserter.closedFlash, .pasted(appName: "Notes"))
        XCTAssertEqual(vm.closedGlance.right, .checkmark)
        XCTAssertEqual(harness.announcements.last, "Pasted into Notes")
    }

    func testJustCopyCopiesAndHandsTheKeyboardBack() async {
        let harness = NotchFeatureHarness(self, responses: [notchFeatureReply("Hello there")])
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        await harness.answeredQuestion(from: harness.notes, reply: "Hello there")

        vm.insertLastAnswer(mode: .paste)
        await notchWaitUntil { vm.permissionPrompt != nil }
        vm.permissionPromptAction(.justCopy)

        await notchWaitUntil { vm.transientNotice != nil }
        XCTAssertEqual(vm.transientNotice?.text, "Copied. Click in Notes and press ⌘V.")
        XCTAssertEqual(harness.pasteboard.string(forType: .string), "Hello there")
        XCTAssertEqual(harness.keys.pastes, 0)
        XCTAssertTrue(vm.isOpen)
        XCTAssertFalse(vm.isEngaged)
        XCTAssertEqual(harness.keyRequests.last, false)
    }

    func testMultilineTerminalPasteWaitsForConfirmation() async {
        let terminal = AppRef(pid: 6262, bundleID: "com.apple.Terminal", name: "Terminal")
        let script = "brew update\nbrew upgrade"
        let harness = NotchFeatureHarness(self, statuses: [.accessibility: .granted],
                                          responses: [notchFeatureReply(script)])
        let vm = harness.vm
        await harness.permissions.refresh([.accessibility])
        vm.open(reason: .click, focus: true)
        await harness.answeredQuestion(from: terminal, reply: script)

        vm.insertLastAnswer(mode: nil)
        await notchWaitUntil { vm.inserter.activity != nil }
        guard case .confirmMultiline(_, .paste, 2, "Terminal")? = vm.inserter.activity else {
            return XCTFail("Expected the multi-line confirmation, got \(String(describing: vm.inserter.activity))")
        }
        let context = vm.keyContext(hasMarkedText: false, composerIsFirstResponder: true,
                                    clipboardWantsAttachmentPaste: false)
        XCTAssertTrue(context.hasInsertConfirmation)
        await notchWaitUntil { vm.stayOpenHolds.contains(.insertInProgress) }
        XCTAssertEqual(harness.keys.pastes, 0)

        // Esc cancels; ⌘↩ asks again; Return confirms.
        XCTAssertTrue(vm.perform(.cancelInsertConfirmation, hardwareConfirmed: true))
        XCTAssertNil(vm.inserter.activity)
        vm.insertLastAnswer(mode: nil)
        await notchWaitUntil { vm.inserter.activity != nil }
        XCTAssertTrue(vm.perform(.confirmInsert, hardwareConfirmed: true))
        await notchWaitUntil { harness.keys.pastes == 1 }
        XCTAssertNil(vm.inserter.activity)
    }

    func testChangedSelectionOffersPasteAtCursorOrCopy() async {
        let harness = NotchFeatureHarness(self, statuses: [.accessibility: .granted],
                                          responses: [notchFeatureReply("They're going")])
        let vm = harness.vm
        await harness.permissions.refresh([.accessibility])
        harness.insertEnvironment.running.insert(harness.notes.pid)
        harness.insertEnvironment.frontmost = harness.notes.pid
        harness.insertEnvironment.selection = .changed
        let element = AXElementRef(AXUIElementCreateApplication(harness.notes.pid))
        let selection = SelectionSnapshot(text: "Their going", app: harness.notes, windowTitle: nil,
                                          range: CFRange(location: 0, length: 11), element: element,
                                          source: .accessibility)
        vm.open(reason: .click, focus: true)
        vm.setOpenContextApp(harness.notes)
        guard let chip = try? selection.makeAttachment() else { return XCTFail("No chip") }
        vm.addAttachment(chip)
        vm.selectionSnapshots[chip.id] = selection
        vm.composerText = "Fix this"
        vm.send()
        await harness.waitForIdle()

        vm.insertLastAnswer(mode: nil)
        await notchWaitUntil { vm.inserter.activity != nil }
        guard case .selectionChanged(_, "Notes")? = vm.inserter.activity else {
            return XCTFail("Expected the changed-selection row, got \(String(describing: vm.inserter.activity))")
        }

        // Copy: the answer goes to the clipboard, nothing is typed.
        vm.cancelPendingInsert()
        XCTAssertNil(vm.inserter.activity)
        XCTAssertEqual(harness.pasteboard.string(forType: .string), "They're going")
        XCTAssertEqual(vm.transientNotice?.text, "Copied. Click in Notes and press ⌘V.")
        XCTAssertEqual(harness.keys.pastes, 0)

        // Paste at Cursor pastes without re-selecting.
        vm.insertLastAnswer(mode: nil)
        await notchWaitUntil { vm.inserter.activity != nil }
        vm.confirmPendingInsert()
        await notchWaitUntil { harness.keys.pastes == 1 }
    }

    func testCopyFallbacksExplainWhatHappened() async {
        let harness = NotchFeatureHarness(self, statuses: [.accessibility: .granted],
                                          responses: [notchFeatureReply("Answer")])
        let vm = harness.vm
        await harness.permissions.refresh([.accessibility])
        vm.open(reason: .click, focus: true)
        await harness.answeredQuestion(from: harness.notes, reply: "Answer")

        // A password field is focused in the target: no keystroke.
        harness.insertEnvironment.secureField = true
        vm.insertLastAnswer(mode: nil)
        await notchWaitUntil { vm.transientNotice != nil }
        XCTAssertEqual(vm.transientNotice?.text,
                       "A password field is active in Notes, so Otto won't type there. The answer is on your clipboard.")
        XCTAssertEqual(harness.keys.pastes, 0)
        XCTAssertEqual(harness.pasteboard.string(forType: .string), "Answer")

        // The app quit: the paste control goes away, and ⌘↩ copies with a note.
        harness.insertEnvironment.secureField = false
        harness.insertEnvironment.running.remove(harness.notes.pid)
        XCTAssertFalse(vm.canInsertLastAnswer)
        XCTAssertFalse(vm.perform(.insertLastAnswer(nil), hardwareConfirmed: true))
        vm.insertAnswer(messageID: harness.chat.messages.last?.id ?? UUID(), mode: .paste)
        XCTAssertEqual(vm.transientNotice?.text, "Notes isn't open anymore. The answer is on your clipboard.")
        XCTAssertEqual(harness.keys.pastes, 0)
    }

    func testConcealedClipboardIsClearedWithANotice() async {
        let harness = NotchFeatureHarness(self, statuses: [.accessibility: .granted],
                                          responses: [notchFeatureReply("Pasted text")])
        let vm = harness.vm
        await harness.permissions.refresh([.accessibility])
        vm.open(reason: .click, focus: true)
        await harness.answeredQuestion(from: harness.notes, reply: "Pasted text")

        // A password manager's copy is on the clipboard.
        let item = NSPasteboardItem()
        item.setString("hunter2", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        harness.pasteboard.clearContents()
        harness.pasteboard.writeObjects([item])

        vm.insertLastAnswer(mode: nil)
        await notchWaitUntil { harness.keys.pastes == 1 && vm.transientNotice != nil }
        XCTAssertEqual(vm.transientNotice?.text, NotchViewModel.concealedClipboardNotice)
        XCTAssertNil(harness.pasteboard.string(forType: .string), "neither the secret nor the answer lingers")
    }

    // MARK: Drop routing and the Shelf

    func testShelfDropKeepsFilesWithoutTakingFocus() async throws {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        let file = try harness.temporaryFile("photo-notes.txt", testCase: self)
        vm.open(reason: .drag, focus: false)
        vm.updateDropSession(DropSession(zone: .shelf, itemCount: 1, acceptsShelf: true))
        XCTAssertEqual(vm.dropSession?.zone, .shelf)

        let provider = NSItemProvider(object: file as NSURL)
        XCTAssertTrue(vm.performDrop([provider], zone: .shelf))
        XCTAssertNil(vm.dropSession)
        XCTAssertEqual(vm.route, .shelf)
        XCTAssertFalse(vm.isEngaged)
        await notchWaitUntil { !vm.shelf.store.items.isEmpty }
        XCTAssertEqual(vm.shelf.store.items.first?.name, "photo-notes.txt")
        await notchWaitUntil { vm.stayOpenHolds.contains(.shelfLanding) }
        XCTAssertTrue(vm.attachments.isEmpty)
    }

    func testAskDropAttachesOnChatAndShelfOffRoutesToAsk() async throws {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        let file = try harness.temporaryFile("draft.txt", testCase: self)
        vm.open(reason: .drag, focus: false)
        vm.navigate(to: .shelf)

        XCTAssertTrue(vm.performDrop([NSItemProvider(object: file as NSURL)], zone: .ask))
        XCTAssertEqual(vm.route, .chat)
        XCTAssertTrue(vm.isEngaged)
        await notchWaitUntil { !vm.attachments.isEmpty }
        XCTAssertEqual(vm.attachments.first?.displayName, "draft.txt")

        harness.settings.shelf.enabled = false
        let other = try harness.temporaryFile("other.txt", testCase: self)
        XCTAssertTrue(vm.performDrop([NSItemProvider(object: other as NSURL)], zone: .shelf))
        await notchWaitUntil { vm.attachments.count == 2 }
        XCTAssertTrue(vm.shelf.store.items.isEmpty)
    }

    func testAskingAboutShelfItemsSkipsFolders() async throws {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        let file = try harness.temporaryFile("report.txt", testCase: self)
        let folder = file.deletingLastPathComponent()
        vm.addToShelf(fileURLs: [file, folder], openShelf: true)
        XCTAssertEqual(vm.shelf.store.items.count, 2)

        XCTAssertTrue(vm.perform(.shelfAskAboutSelection, hardwareConfirmed: true))
        XCTAssertEqual(vm.route, .chat)
        XCTAssertTrue(vm.isEngaged)
        XCTAssertEqual(vm.transientError, NotchViewModel.foldersNotSupportedMessage)
        await notchWaitUntil { !vm.attachments.isEmpty }
        XCTAssertEqual(vm.attachments.map(\.displayName), ["report.txt"])
    }

    func testShelfPasteAddsTheClipboardsFiles() async throws {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        let file = try harness.temporaryFile("pasted.txt", testCase: self)
        harness.shelfPasteboard.clearContents()
        harness.shelfPasteboard.writeObjects([file as NSURL])
        vm.open(reason: .click, focus: true)
        vm.navigate(to: .shelf)

        XCTAssertTrue(vm.perform(.shelfPaste, hardwareConfirmed: true))
        XCTAssertEqual(vm.shelf.store.items.map(\.name), ["pasted.txt"])
        XCTAssertEqual(vm.shelf.selection.count, 1)
    }

    // MARK: History

    func testContinueBringsBackTheConversationSetAside() async {
        let harness = NotchFeatureHarness(self, responses: [notchFeatureReply("Paris.")])
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        vm.composerText = "Capital of France?"
        vm.send()
        await harness.waitForIdle()
        let conversationID = harness.chat.conversationID

        vm.newChat()
        XCTAssertTrue(harness.chat.messages.isEmpty)
        XCTAssertEqual(harness.history.continuation?.id, conversationID)

        vm.continuePreviousConversation()
        await notchWaitUntil { harness.chat.conversationID == conversationID }
        XCTAssertEqual(harness.chat.messages.map(\.text), ["Capital of France?", "Paris."])
        XCTAssertNil(harness.history.continuation)
        XCTAssertEqual(vm.route, .chat)

        vm.newChat()
        vm.dismissContinuation()
        XCTAssertNil(harness.history.continuation)
    }

    func testRecentsOpenDeleteAndUndo() async {
        let harness = NotchFeatureHarness(self, responses: [notchFeatureReply("One."), notchFeatureReply("Two.")])
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        vm.composerText = "First"
        vm.send()
        await harness.waitForIdle()
        let first = harness.chat.conversationID
        vm.newChat()
        vm.composerText = "Second"
        vm.send()
        await harness.waitForIdle()
        await notchWaitUntil { harness.history.summaries.count == 2 }

        XCTAssertTrue(vm.perform(.toggleHistory, hardwareConfirmed: true))
        XCTAssertEqual(vm.route, .history)
        vm.recents.selectedID = first
        XCTAssertTrue(vm.perform(.historyOpenSelected, hardwareConfirmed: true))
        await notchWaitUntil { harness.chat.conversationID == first }
        XCTAssertEqual(vm.route, .chat)
        XCTAssertEqual(harness.chat.messages.first?.text, "First")

        vm.toggleHistory()
        vm.recents.selectedID = harness.history.summaries.first { $0.id != first }?.id
        XCTAssertTrue(vm.perform(.historyDeleteSelected, hardwareConfirmed: true))
        XCTAssertNotNil(harness.history.pendingDeletion)
        XCTAssertEqual(harness.history.summaries.count, 1)
        XCTAssertTrue(vm.perform(.historyUndoDelete, hardwareConfirmed: true))
        XCTAssertNil(harness.history.pendingDeletion)
        XCTAssertEqual(harness.history.summaries.count, 2)
        XCTAssertFalse(vm.perform(.historyUndoDelete, hardwareConfirmed: true))
    }

    func testDecliningHistoryTurnsItOff() async {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        vm.present(card: NotchViewModel.historyNoticeCard(retention: harness.settings.history.retention))
        vm.declineHistory()
        XCTAssertTrue(harness.settings.history.noticeAcknowledged)
        XCTAssertTrue(vm.cardQueue.isEmpty)
        XCTAssertEqual(vm.transientError, NotchViewModel.historyOffMessage)
        await notchWaitUntil { !harness.settings.history.enabled }

        harness.settings.history.noticeAcknowledged = false
        vm.present(card: NotchViewModel.historyNoticeCard(retention: harness.settings.history.retention))
        vm.acknowledgeHistoryNotice()
        XCTAssertTrue(harness.settings.history.noticeAcknowledged)
        XCTAssertTrue(vm.cardQueue.isEmpty)
    }

    // MARK: Glance

    func testClosedGlanceFollowsItsInputs() async {
        let harness = NotchFeatureHarness(self, responses: [notchFeatureReply("All done.")])
        let vm = harness.vm
        XCTAssertEqual(vm.closedGlance, GlanceResolver.resolve(vm.glanceInputs))
        XCTAssertFalse(vm.closedGlance.hasEars)

        // A reply that finished while closed: preview drop, unread.
        vm.composerText = "Summarize"
        vm.send()
        await harness.waitForIdle()
        XCTAssertTrue(vm.hasUnreadReply)
        XCTAssertTrue(vm.glanceInputs.hasUnreadReply)
        XCTAssertNotNil(vm.glance.preview)
        guard case .preview? = vm.closedGlance.drop else { return XCTFail("Expected the reply preview drop") }
        XCTAssertGreaterThan(vm.closedLayout.size.height, vm.closedNotchSize.height)

        // An approval outranks it.
        harness.executor.pendingApproval = PendingApproval(
            callID: "call-1", messageID: UUID(), toolName: "side_effect", kind: .approval(rememberScope: nil),
            presentation: .generic(toolName: "side_effect"),
            body: .text(TextPreview(label: "Input", text: "hello", language: nil)), confirmLabel: "Run",
            declineLabel: "Don't run", provenance: nil, caution: nil, armingDelay: .seconds(1),
            presentedAt: Date(timeIntervalSince1970: 0), position: 1, total: 1)
        XCTAssertEqual(vm.glanceInputs.approvalTitle, harness.chat.pendingApproval?.presentation.title)
        XCTAssertEqual(vm.closedGlance.right, .approval)

        // Waiting on system UI outranks the approval.
        vm.debugSeed(features: NotchDebugSeed(systemUIWait: .systemSettings(.calendars)))
        XCTAssertEqual(vm.glanceInputs.systemWait, .systemSettings(.calendars))
        XCTAssertEqual(vm.closedGlance.right, .systemWait)
        XCTAssertEqual(vm.closedGlance.drop, .systemWait("Waiting for System Settings…"))
    }

    func testMediaControlExplainsAutomationThenRetriesOnce() async {
        let media = NotchFeatureMediaScripting()
        let harness = NotchFeatureHarness(self, media: media)
        let vm = harness.vm
        harness.settings.glance.nowPlayingEnabled = true
        vm.nowPlaying.debugSeed(item: NowPlayingItem(id: "music|Low Tide", player: .music, title: "Low Tide",
                                                     artist: "Marlow Vey", album: "Demo", duration: 200,
                                                     position: 10, positionDate: harness.now, state: .playing,
                                                     artworkURL: nil),
                                artwork: nil)
        vm.open(reason: .click, focus: true)
        let context = vm.keyContext(hasMarkedText: false, composerIsFirstResponder: true,
                                    clipboardWantsAttachmentPaste: false)
        XCTAssertTrue(context.hasNowPlaying)

        XCTAssertTrue(vm.perform(.media(.playPause), hardwareConfirmed: true))
        await notchWaitUntil { vm.permissionPrompt != nil }
        XCTAssertEqual(vm.permissionPrompt?.purpose, .nowPlayingControl(appName: "Music"))
        XCTAssertEqual(vm.permissionPrompt?.permission, .automation(bundleID: "com.apple.Music", appName: "Music"))
        XCTAssertTrue(media.ran.isEmpty)

        harness.probe.set(.automation(bundleID: "com.apple.Music", appName: "Music"), .granted)
        media.allowed = true
        vm.performPromptPrimary(input: .trusted())
        await notchWaitUntil { !media.ran.isEmpty }
        XCTAssertEqual(media.ran, [.playPause])
    }

    func testJoinMeetingOpensItsLinkAndUsageOpensSettings() async {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        harness.settings.glance.calendarChipEnabled = true
        let link = URL(string: "https://zoom.us/j/123456")
        let event = CalendarEventSnapshot(id: "standup|1", title: "Standup", start: harness.now,
                                          end: harness.now.addingTimeInterval(900), colorRGBA: nil, isAllDay: false,
                                          isCanceled: false, isDeclined: false, meetingLink: link)
        vm.calendar.debugSeed(next: EventGlance(event: event, chipSuffix: "now", spokenText: "Standup now",
                                                isImminent: true))
        vm.open(reason: .click, focus: true)
        XCTAssertTrue(vm.keyContext(hasMarkedText: false, composerIsFirstResponder: true,
                                    clipboardWantsAttachmentPaste: false).hasMeetingChip)

        XCTAssertTrue(vm.perform(.joinMeeting, hardwareConfirmed: true))
        XCTAssertEqual(harness.openedURLs, link.map { [$0] })
        XCTAssertFalse(vm.isOpen)

        vm.calendar.debugSeed(next: nil)
        XCTAssertFalse(vm.perform(.joinMeeting, hardwareConfirmed: true))

        XCTAssertTrue(vm.perform(.showUsage, hardwareConfirmed: true))
        XCTAssertEqual(harness.settingsRequests.last?.tab, .models)
        XCTAssertEqual(harness.settingsRequests.last?.anchor, .usage)
    }

    // MARK: Actions

    func testActionRowControls() async {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        let scope = ApprovalScope(toolName: "run_shortcut", key: "shortcut:1234", label: "“Log water”")
        vm.approvals.remember(scope)
        vm.stopAllowing(scope)
        XCTAssertFalse(vm.approvals.isRemembered(scope))
        XCTAssertEqual(vm.transientNotice?.text, "Otto will ask before running “Log water” again.")

        vm.stopToolCall("call-9")
        XCTAssertEqual(harness.executor.stoppedCallIDs, ["call-9"])

        let messageID = UUID()
        harness.executor.undoResult = "the time to undo it has passed"
        vm.undoToolCall("call-3", in: messageID)
        await notchWaitUntil { vm.transientError != nil }
        XCTAssertEqual(vm.transientError, "Couldn't undo: the time to undo it has passed.")
        XCTAssertEqual(harness.executor.undoRequests, [FakeToolExecutor.UndoRequest(callID: "call-3",
                                                                                     messageID: messageID)])

        vm.openActionsSettings()
        XCTAssertEqual(harness.settingsRequests.last?.tab, .actions)
        XCTAssertEqual(harness.settingsRequests.last?.anchor, .approvals)
    }

    // MARK: Neighbors

    func testNeighborCardShowsOnceWithTheLiveShortcut() {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        let neighbors = Array(NotchNeighbor.known.prefix(2))
        harness.settings.shortcuts.hotKey = HotKeyCombo(keyCode: UInt32(kVK_ANSI_K),
                                                        carbonModifiers: UInt32(cmdKey | optionKey))
        let combo = harness.settings.shortcuts.hotKey.displayString

        vm.presentNeighborCardIfNeeded(neighbors)
        vm.presentNeighborCardIfNeeded(neighbors)
        let queued = vm.cardQueue.filter {
            if case .notchNeighbor = $0.card.kind { return true }
            return false
        }
        XCTAssertEqual(queued.count, 1)
        XCTAssertNil(vm.card, "the card waits for the next open")
        XCTAssertTrue(queued.first?.card.message.contains(combo) ?? false)
        XCTAssertFalse(queued.first?.card.message.contains("⌥Space") ?? true)

        vm.open(reason: .click, focus: true)
        XCTAssertEqual(vm.card?.kind, .notchNeighbor(name: neighbors[0].name))
        XCTAssertTrue(vm.perform(.promptPrimary, hardwareConfirmed: true))
        XCTAssertFalse(harness.settings.notch.hoverToOpen)
        XCTAssertEqual(vm.transientNotice?.text, "Otto now opens on click or \(combo)")
        XCTAssertEqual(harness.settings.notch.acknowledgedNeighbors, [neighbors[0].name])

        // Hover is off now: no more cards.
        vm.presentNeighborCardIfNeeded(neighbors)
        XCTAssertTrue(vm.cardQueue.isEmpty)
    }

    func testNeighborCardWithoutAShortcutUsesTheClickOnlyCopy() {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        harness.settings.hotKeyEnabled = false
        let card = NotchViewModel.neighborCard(name: "NotchNook", settings: harness.settings)
        XCTAssertTrue(card.message.hasSuffix("Otto can open only when you click the notch."))
        XCTAssertEqual(card.escapeAction, .keepHover(neighbor: "NotchNook"))
        XCTAssertFalse(card.requiresDecision)

        vm.presentNeighborCardIfNeeded([NotchNeighbor.known[0]])
        vm.open(reason: .click, focus: true)
        vm.performCardAction(.useClickToOpen)
        XCTAssertEqual(vm.transientNotice?.text, "Otto now opens when you click the notch.")

        // An acknowledged neighbor never asks again.
        harness.settings.notch.hoverToOpen = true
        vm.presentNeighborCardIfNeeded([NotchNeighbor.known[0]])
        XCTAssertTrue(vm.cardQueue.isEmpty)
    }
}
