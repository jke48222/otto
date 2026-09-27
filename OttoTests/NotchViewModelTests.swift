//
//  NotchViewModelTests.swift
//  Otto
//
//  NotchViewModel state: attachments and their budgets, sending, open/close hooks, the suggested
//  tab, unread replies, transient errors and New Chat; and the v1.1 core: holds, the fold for system UI,
//  approval visibility and arming input, the dock's prompts and permission flows, the history notice, soft
//  focus, pin, tall mode, editing, model notices and the reading anchor.
//

import AppKit
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import Otto

// MARK: - Fixtures

private func textBlock(_ text: String) -> JSONValue {
    ["type": "text", "text": .string(text)]
}

private func completed(_ content: [JSONValue], stopReason: String? = "end_turn") -> StreamEvent {
    .completed(StreamResult(content: content, stopReason: stopReason, stopDetails: nil, model: "claude-opus-5", usage: nil))
}

/// A complete one-text-block reply.
private func reply(_ text: String, stopReason: String? = "end_turn") -> ScriptedLLMClient.Response {
    .events([.messageStart(model: "claude-opus-5"), .textDelta(text), completed([textBlock(text)], stopReason: stopReason)])
}

private func textAttachment(_ name: String, _ text: String = "hello") -> Attachment {
    Attachment(
        kind: .text,
        displayName: name,
        badge: "TXT",
        sourceURL: URL(fileURLWithPath: "/tmp/otto-tests/\(name)"),
        payload: .text(text),
        byteCount: text.utf8.count
    )
}

private func pdfAttachment(_ name: String, pages: Int) -> Attachment {
    let document = PDFDocument()
    for index in 0..<pages {
        document.insert(PDFPage(), at: index)
    }
    let base64 = (document.dataRepresentation() ?? Data()).base64EncodedString()
    return Attachment(
        kind: .pdf,
        displayName: name,
        badge: "PDF",
        sourceURL: URL(fileURLWithPath: "/tmp/otto-tests/\(name)"),
        payload: .pdf(base64: base64),
        byteCount: base64.utf8.count
    )
}

private func webAttachment(_ url: String, title: String = "Page") -> Attachment {
    let pageURL = URL(string: url) ?? URL(fileURLWithPath: "/")
    return Attachment(
        kind: .webPage,
        displayName: title,
        badge: "WEB",
        sourceURL: pageURL,
        appBundleID: "com.google.Chrome",
        payload: .webPage(title: title, url: pageURL),
        byteCount: 0
    )
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for condition", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

@MainActor
private func waitForReply(_ chat: ChatSession, file: StaticString = #filePath, line: UInt = #line) async {
    await waitUntil(file: file, line: line) { !chat.isStreaming }
}

@MainActor
private extension XCTestCase {
    /// Settings backed by a throwaway UserDefaults suite that is removed after the test.
    func makeSettings() -> AppSettings {
        let suiteName = "otto.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        return AppSettings(defaults: defaults)
    }
}

// MARK: - Core harness

/// A clock the History controller and the view model read.
@MainActor
private final class TestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    var uptime: TimeInterval = 5_000
}

/// Counts "Quit & Reopen Otto" instead of quitting.
@MainActor
private final class RecordingRelauncher: AppRelaunching {
    private(set) var count = 0
    func relaunch() { count += 1 }
}

/// A view model over inert services, except for a permissions center driven by a MutablePermissionProbe (a 20 ms
/// poll, System Settings never really opens), a fake tool executor, and History on a test clock.
@MainActor
private final class CoreHarness {
    let settings: AppSettings
    let chat: ChatSession
    let probe: MutablePermissionProbe
    let center: PermissionsCenter
    let relauncher = RecordingRelauncher()
    let executor = FakeToolExecutor()
    let clock = TestClock()
    let vm: NotchViewModel

    init(_ testCase: XCTestCase, statuses: [Permission: PermissionStatus] = [:],
         client: ScriptedLLMClient = ScriptedLLMClient([])) {
        settings = AppSettings(defaults: TestDefaults.make(for: testCase), usesKeychain: false)
        // Keep the tests away from AppleScript lookups of whatever browser happens to be frontmost.
        settings.suggestBrowserTab = false
        chat = ChatSession(settings: settings, makeClient: { client }, executor: executor)
        probe = MutablePermissionProbe(statuses, default: .notDetermined)
        center = PermissionsCenter(probe: probe, defaults: TestDefaults.make(for: testCase),
                                   openURL: { _ in }, pollInterval: .milliseconds(20),
                                   relauncher: relauncher)
        var services = NotchServices.inert(settings: settings, chat: chat)
        let clock = self.clock
        let history = HistoryController(settings: settings, chat: chat, store: ConversationStore(location: .inMemory),
                                        now: { clock.date })
        services.permissions = center
        services.history = history
        services.recents = RecentsState(history: history)
        vm = NotchViewModel(settings: settings, chat: chat, services: services)
        vm.grantedCardLifetime = .milliseconds(20)
        vm.now = { clock.date }
        vm.uptime = { clock.uptime }
    }
}

private func approval(_ callID: String, armingDelay: Duration = .seconds(1),
                      kind: PendingApproval.Kind = .approval(rememberScope: nil),
                      body: ApprovalBody = .text(TextPreview(label: "Input", text: "hello", language: nil))) -> PendingApproval {
    PendingApproval(callID: callID, messageID: UUID(), toolName: "side_effect", kind: kind,
                    presentation: .generic(toolName: "side_effect"), body: body, confirmLabel: "Run",
                    declineLabel: "Don't run", provenance: nil, caution: nil, armingDelay: armingDelay,
                    presentedAt: Date(timeIntervalSince1970: 0), position: 1, total: 1)
}

private func keyPress(at uptime: TimeInterval, isRepeat: Bool = false) -> InputEvidence {
    InputEvidence(source: .keyboard, isHardware: true, isRepeat: isRepeat, uptime: uptime)
}

private let voiceConsentCard = NotchCard(
    kind: .voiceConsent(pendingMode: .toggle(.micButton)), symbol: "mic", title: "Talk to Otto",
    message: "Otto listens only while you ask.", footnote: nil,
    primary: NotchCard.ActionButton(title: "Turn On Voice", action: .enableVoice(.toggle(.micButton))),
    secondary: NotchCard.ActionButton(title: "Not Now", action: .dismiss),
    escapeAction: .dismiss, requiresDecision: true)

private func conversation() -> [ChatMessage] {
    [ChatMessage(role: .user, text: "Question", apiContent: [textBlock("Question")]),
     ChatMessage(role: .assistant, text: "Answer.", apiContent: [textBlock("Answer.")])]
}

// MARK: - NotchViewModel

@MainActor
final class NotchViewModelTests: XCTestCase {
    private func makeViewModel(_ client: ScriptedLLMClient = ScriptedLLMClient([])) -> NotchViewModel {
        let settings = makeSettings()
        // Keep the tests away from AppleScript lookups of whatever browser happens to be frontmost.
        settings.suggestBrowserTab = false
        let chat = ChatSession(settings: settings, makeClient: { client })
        return NotchViewModel(settings: settings, chat: chat)
    }

    func testAddAttachmentDedupesBySourceAndCapsAtTen() {
        let vm = makeViewModel()
        vm.addAttachment(textAttachment("a.txt"))
        vm.addAttachment(textAttachment("a.txt"))
        XCTAssertEqual(vm.attachments.count, 1)

        for index in 1...12 {
            vm.addAttachment(textAttachment("file\(index).txt"))
        }
        XCTAssertEqual(vm.attachments.count, NotchViewModel.maxAttachments)
        XCTAssertEqual(vm.transientError, NotchViewModel.attachmentLimitMessage)

        vm.removeAttachment(id: vm.attachments[0].id)
        XCTAssertEqual(vm.attachments.count, NotchViewModel.maxAttachments - 1)
    }

    func testAddAttachmentRefusesWhatWouldExceedTheRequestBudget() {
        let vm = makeViewModel()
        vm.open(reason: .click, focus: true)
        let big = String(repeating: "a", count: 16_000_000)
        vm.addAttachment(textAttachment("big1.txt", big))
        vm.addAttachment(textAttachment("big2.txt", big))

        XCTAssertEqual(vm.attachments.map(\.displayName), ["big1.txt"])
        XCTAssertNotNil(vm.transientError)
    }

    func testSendRechecksThePageLimitAfterTheModelChanged() {
        let vm = makeViewModel()
        vm.settings.model = .opus5
        vm.open(reason: .click, focus: true)
        vm.addAttachment(pdfAttachment("long.pdf", pages: 101))
        XCTAssertEqual(vm.attachments.count, 1)
        vm.composerText = "Summarize"

        vm.settings.model = .haiku45
        vm.send()

        XCTAssertTrue(vm.chat.messages.isEmpty)
        XCTAssertEqual(vm.transientError?.contains("100 pages"), true)
        XCTAssertEqual(vm.attachments.count, 1)
        XCTAssertEqual(vm.composerText, "Summarize")
    }

    func testHistoryStripsEarlierPDFsOverTheModelsPageLimit() {
        let pdf = pdfAttachment("long.pdf", pages: 101)
        let earlier = ChatMessage(role: .user, text: "Read this", attachments: [pdf],
                                  apiContent: pdf.contentBlocks() + [textBlock("Read this")])
        let answer = ChatMessage(role: .assistant, text: "Done.", apiContent: [textBlock("Done.")])
        let latest = ChatMessage(role: .user, text: "Thanks", apiContent: [textBlock("Thanks")])
        let messages = [earlier, answer, latest]

        let haiku = ChatSession.requestHistory(for: messages, inFlight: nil, resumingInFlight: false,
                                               enabledServerTools: [], model: .haiku45)
        XCTAssertEqual(haiku[0]["content"]?[0]?.typeName, "text")
        let opus = ChatSession.requestHistory(for: messages, inFlight: nil, resumingInFlight: false,
                                              enabledServerTools: [], model: .opus5)
        XCTAssertEqual(opus[0]["content"]?[0]?.typeName, "document")
    }

    func testAutoAttachOnlyForTabsKnownToBeNonPrivate() {
        let vm = makeViewModel()
        vm.settings.autoAttachBrowserTab = true
        vm.open(reason: .click, focus: true)

        let url = URL(string: "https://example.com/private") ?? URL(fileURLWithPath: "/")
        vm.applySuggestion(BrowserTab(title: "Maybe private", url: url, bundleID: "com.apple.Safari"))
        XCTAssertTrue(vm.attachments.isEmpty)
        XCTAssertEqual(vm.suggestedTab?.sourceURL, url)

        let normal = URL(string: "https://example.com/normal") ?? URL(fileURLWithPath: "/")
        vm.applySuggestion(BrowserTab(title: "Normal", url: normal, bundleID: "com.google.Chrome", isKnownNonPrivate: true))
        XCTAssertEqual(vm.attachments.map(\.sourceURL), [normal])
        XCTAssertNil(vm.suggestedTab)

        // Moving to an unverified tab takes the earlier auto-attached chip back out.
        vm.applySuggestion(BrowserTab(title: "Maybe private", url: url, bundleID: "com.apple.Safari"))
        XCTAssertTrue(vm.attachments.isEmpty)
        XCTAssertEqual(vm.suggestedTab?.sourceURL, url)
    }

    func testStreamedDeltasAreCoalescedButFinalTextIsExact() async {
        let words = (1...200).map { "w\($0) " }
        let full = words.joined()
        let events: [StreamEvent] = [.messageStart(model: "claude-opus-5")]
            + words.map { StreamEvent.textDelta($0) }
            + [completed([textBlock(full)])]
        let client = ScriptedLLMClient([.events(events)])
        let session = ChatSession(settings: makeSettings(), makeClient: { client })

        var observedTexts = 0
        var lastSeen = ""
        func track() {
            withObservationTracking {
                lastSeen = session.messages.last?.text ?? ""
            } onChange: {
                Task { @MainActor in
                    observedTexts += 1
                    track()
                }
            }
        }
        track()
        session.send(text: "Go", attachments: [])
        XCTAssertEqual(session.messageCount, 2)
        XCTAssertEqual(session.lastMessageState, .streaming)
        XCTAssertFalse(session.hasCopyableReply)
        await waitUntil { !session.isStreaming }

        XCTAssertEqual(session.messages.last?.text, full)
        XCTAssertEqual(session.lastMessageState, .complete)
        XCTAssertTrue(session.hasCopyableReply)
        // 200 deltas delivered back-to-back must not produce 200 transcript writes.
        XCTAssertLessThan(observedTexts, 50)
        _ = lastSeen
    }

    func testDropLoadsOnlyWhatFits() async {
        let vm = makeViewModel()
        vm.open(reason: .click, focus: true)
        for index in 1...8 {
            vm.addAttachment(textAttachment("kept\(index).txt"))
        }
        let providers = (1...5).map { index in
            NSItemProvider(
                item: URL(fileURLWithPath: "/tmp/otto-tests/missing-\(index).pdf") as NSURL,
                typeIdentifier: UTType.fileURL.identifier
            )
        }

        XCTAssertTrue(vm.handleDrop(providers))
        XCTAssertEqual(vm.pendingAttachmentLoads, 2)
        XCTAssertEqual(vm.transientError, NotchViewModel.attachmentLimitMessage)
        await waitUntil { vm.pendingAttachmentLoads == 0 }
    }

    func testCanSendAndSendClearsComposer() async {
        let client = ScriptedLLMClient([reply("Hi!")])
        let vm = makeViewModel(client)
        vm.open(reason: .click, focus: true)

        XCTAssertFalse(vm.canSend)
        vm.composerText = "   "
        XCTAssertFalse(vm.canSend)
        vm.composerText = "Hi otto"
        XCTAssertTrue(vm.canSend)

        let notes = textAttachment("notes.txt")
        vm.addAttachment(notes)
        vm.send()

        XCTAssertEqual(vm.composerText, "")
        XCTAssertTrue(vm.attachments.isEmpty)
        XCTAssertTrue(vm.isOpen)
        XCTAssertTrue(vm.isEngaged)
        XCTAssertFalse(vm.canSend)
        XCTAssertEqual(vm.chat.messages.first?.text, "Hi otto")
        XCTAssertEqual(vm.chat.messages.first?.attachments, [notes])

        await waitForReply(vm.chat)
        vm.composerText = "Next"
        XCTAssertTrue(vm.canSend)
    }

    func testOpenAndCloseDriveWindowHooks() {
        let vm = makeViewModel()
        var keyRequests: [Bool] = []
        var presentations: [NotchViewModel.Presentation] = []
        vm.onRequestKey = { keyRequests.append($0) }
        vm.onPresentationChange = { presentations.append($0) }
        vm.hasUnreadReply = true

        vm.open(reason: .hover, focus: false)
        XCTAssertTrue(vm.isOpen)
        XCTAssertEqual(vm.openReason, .hover)
        XCTAssertFalse(vm.isEngaged)
        XCTAssertFalse(vm.hasUnreadReply)
        XCTAssertEqual(vm.focusRequest, 0)
        XCTAssertEqual(keyRequests, [])

        vm.open(reason: .click, focus: true)
        XCTAssertTrue(vm.isEngaged)
        XCTAssertEqual(vm.focusRequest, 1)
        XCTAssertEqual(keyRequests, [true])
        XCTAssertEqual(presentations, [.open])

        vm.isMenuPresented = true
        XCTAssertTrue(vm.shouldStayOpen)
        vm.close()
        XCTAssertFalse(vm.isOpen)
        XCTAssertNil(vm.openReason)
        XCTAssertFalse(vm.isEngaged)
        XCTAssertFalse(vm.isMenuPresented)
        XCTAssertFalse(vm.shouldStayOpen)
        XCTAssertEqual(keyRequests, [true, false])
        XCTAssertEqual(presentations, [.open, .closed])

        vm.toggle(reason: .hotkey)
        XCTAssertTrue(vm.isOpen)
        XCTAssertTrue(vm.isEngaged)
        vm.toggle(reason: .hotkey)
        XCTAssertFalse(vm.isOpen)
    }

    func testSuggestedTabAcceptAndDismiss() {
        let vm = makeViewModel()
        let tab = webAttachment("https://techcrunch.com", title: "TechCrunch")

        vm.debugSeed(presentation: .open, composerText: "", attachments: [], suggestedTab: tab, hasUnreadReply: false)
        vm.acceptSuggestedTab()
        XCTAssertNil(vm.suggestedTab)
        XCTAssertEqual(vm.attachments, [tab])

        vm.debugSeed(presentation: .open, composerText: "", attachments: [], suggestedTab: tab, hasUnreadReply: false)
        vm.dismissSuggestedTab()
        XCTAssertNil(vm.suggestedTab)
        XCTAssertTrue(vm.attachments.isEmpty)

        vm.debugSeed(presentation: .open, composerText: "", attachments: [], suggestedTab: tab, hasUnreadReply: false)
        vm.close()
        XCTAssertNil(vm.suggestedTab)
    }

    func testReplyFinishingWhileClosedIsUnread() async {
        let client = ScriptedLLMClient([reply("Done while you were away.")])
        let vm = makeViewModel(client)

        vm.chat.send(text: "Background question", attachments: [])
        XCTAssertTrue(vm.showsClosedActivity)
        await waitForReply(vm.chat)

        XCTAssertTrue(vm.hasUnreadReply)
        XCTAssertTrue(vm.showsClosedActivity)
        vm.open(reason: .click, focus: true)
        XCTAssertFalse(vm.hasUnreadReply)
        XCTAssertFalse(vm.showsClosedActivity)
    }

    func testTransientErrorClearsItself() async {
        let vm = makeViewModel()
        vm.transientErrorLifetime = .milliseconds(40)

        vm.transientError = "Something went wrong"
        XCTAssertEqual(vm.transientError, "Something went wrong")
        await waitUntil(timeout: 2) { vm.transientError == nil }
    }

    func testNewChatClearsConversationAndComposer() async {
        let client = ScriptedLLMClient([reply("Hello.")])
        let vm = makeViewModel(client)
        vm.open(reason: .click, focus: true)
        vm.composerText = "Hi"
        vm.send()
        await waitForReply(vm.chat)
        vm.composerText = "Draft"
        vm.addAttachment(textAttachment("draft.txt"))

        vm.newChat()

        XCTAssertTrue(vm.chat.messages.isEmpty)
        XCTAssertEqual(vm.composerText, "")
        XCTAssertTrue(vm.attachments.isEmpty)
    }

    // MARK: - Core: holds

    func testHoldsDriveShouldStayOpenAndIsMenuPresented() {
        let vm = CoreHarness(self).vm
        vm.open(reason: .hover, focus: false)
        XCTAssertFalse(vm.shouldStayOpen)

        vm.setHold(.voiceReplyHold, true)
        XCTAssertTrue(vm.voiceReplyHold)
        XCTAssertTrue(vm.shouldStayOpen)
        XCTAssertFalse(vm.isMenuPresented)
        vm.setHold(.voiceReplyHold, false)
        XCTAssertFalse(vm.voiceReplyHold)
        XCTAssertFalse(vm.shouldStayOpen)

        vm.setModalHold(.quickLook, true)
        XCTAssertTrue(vm.isMenuPresented)
        XCTAssertTrue(vm.shouldStayOpen)
        vm.setModalHold(.quickLook, false)
        XCTAssertFalse(vm.isMenuPresented)

        // A card that needs an answer holds against hover-exit until it is answered.
        vm.present(card: voiceConsentCard)
        XCTAssertEqual(vm.stayOpenHolds, [.promptDecision])
        XCTAssertTrue(vm.shouldStayOpen)
        vm.performCardAction(.dismiss)
        XCTAssertTrue(vm.stayOpenHolds.isEmpty)

        vm.togglePin()
        XCTAssertTrue(vm.shouldStayOpen)
        vm.setHold(.voiceReplyHold, true)
        vm.close(.outsideClick)
        XCTAssertFalse(vm.isPinned)
        XCTAssertFalse(vm.voiceReplyHold)
        XCTAssertTrue(vm.stayOpenHolds.isEmpty)
        XCTAssertFalse(vm.shouldStayOpen)
    }

    // MARK: - Core: fold for system UI

    func testNotchStartedPermissionWaitFoldsAndReopensUnfocused() async {
        let harness = CoreHarness(self, statuses: [.calendars: .denied])
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        let flow = Task { await vm.requestPermission(.calendars, for: .calendarGlance) }
        await waitUntil { vm.permissionPrompt?.phase == .explain }
        XCTAssertEqual(vm.permissionCardContent?.primaryAction, .openSystemSettings)

        vm.permissionPromptAction(.openSystemSettings)
        await waitUntil { vm.isFolded }
        XCTAssertFalse(vm.isOpen)
        XCTAssertEqual(vm.systemUIWait, .systemSettings(.calendars))
        XCTAssertEqual(vm.systemUIWait?.dropText, "Waiting for System Settings…")
        XCTAssertEqual(vm.permissionPrompt?.phase, .waiting, "the fold keeps the prompt")
        XCTAssertEqual(harness.center.awaiting, .systemSettings(.calendars))

        harness.probe.set(.calendars, .granted)
        await waitUntil { vm.isOpen }
        XCTAssertFalse(vm.isFolded)
        XCTAssertFalse(vm.isEngaged, "the reopen leaves the keyboard with the user's app")
        XCTAssertEqual(vm.openReason, .programmatic)
        let granted = await flow.value
        XCTAssertTrue(granted)
        XCTAssertNil(vm.permissionPrompt)
        XCTAssertNil(vm.systemUIWait)
    }

    func testClickDuringTheWaitEndsTheFoldAndNothingReopensAfterTheUserClosed() async {
        let harness = CoreHarness(self, statuses: [.calendars: .denied])
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        let flow = Task { await vm.requestPermission(.calendars, for: .calendarGlance) }
        await waitUntil { vm.permissionPrompt != nil }
        vm.permissionPromptAction(.openSystemSettings)
        await waitUntil { vm.isFolded }

        // The user clicks the closed notch: it opens as usual on the waiting card and the fold is theirs now.
        vm.open(reason: .click, focus: true)
        XCTAssertFalse(vm.isFolded)
        XCTAssertEqual(vm.permissionPrompt?.phase, .waiting)
        // An outside click closes it normally; the prompt stays while macOS still waits.
        vm.close(.outsideClick)
        XCTAssertNotNil(vm.permissionPrompt)

        harness.probe.set(.calendars, .granted)
        let granted = await flow.value
        XCTAssertTrue(granted)
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(vm.isOpen, "only a notch that is still folded reopens")
    }

    func testSettingsWindowRequestsNeverFold() async {
        let harness = CoreHarness(self)
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        harness.center.openSystemSettings(for: .calendars)
        XCTAssertEqual(harness.center.awaiting, .systemSettings(.calendars))
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(vm.isOpen)
        XCTAssertFalse(vm.isFolded)
        XCTAssertNil(vm.systemUIWait)
    }

    func testOpenHeightLimitIgnoresTallModeWhileSystemUIWaits() async {
        let harness = CoreHarness(self)
        let vm = harness.vm
        vm.tallOpenHeight = 800
        var limits: [CGFloat] = []
        vm.onWillChangeOpenHeightLimit = { limits.append($0) }
        vm.open(reason: .click, focus: true)

        vm.setTallMode(true)
        XCTAssertFalse(vm.isTallMode, "tall mode needs a conversation")
        XCTAssertEqual(vm.transientNotice?.text, "Tall mode is for reading. Start a conversation first.")

        harness.chat.debugSeed(messages: conversation(), isStreaming: false)
        vm.setTallMode(true)
        XCTAssertTrue(vm.isTallMode)
        XCTAssertEqual(vm.openHeightLimit, 800)

        vm.automationPromptInFlight = .automation(bundleID: "com.apple.Safari", appName: "Safari")
        await waitUntil { vm.systemUIWait != nil }
        XCTAssertEqual(vm.systemUIWait, .systemPrompt(.automation(bundleID: "com.apple.Safari", appName: "Safari")))
        XCTAssertEqual(vm.openHeightLimit, NotchMetrics.maxOpenHeight)
        XCTAssertTrue(vm.isTallMode, "tall mode is only suspended")
        XCTAssertTrue(vm.isFolded)

        vm.automationPromptInFlight = nil
        await waitUntil { vm.systemUIWait == nil }
        XCTAssertEqual(vm.openHeightLimit, 800)
        XCTAssertTrue(vm.isOpen)
        XCTAssertEqual(limits, [800, NotchMetrics.maxOpenHeight, 800])
    }

    func testTheFoldKeepsRoutePinTallModeAndPrompt() async {
        let harness = CoreHarness(self)
        let vm = harness.vm
        harness.chat.debugSeed(messages: conversation(), isStreaming: false)
        vm.open(reason: .click, focus: true)
        vm.navigate(to: .shelf)
        vm.togglePin()
        vm.setTallMode(true)
        let flow = Task { await vm.requestPermission(.microphone, for: .voice) }
        await waitUntil { vm.permissionPrompt != nil }

        vm.automationPromptInFlight = .automation(bundleID: "com.spotify.client", appName: "Spotify")
        await waitUntil { vm.isFolded }
        XCTAssertEqual(vm.route, .shelf)
        XCTAssertTrue(vm.isPinned)
        XCTAssertTrue(vm.isTallMode)
        XCTAssertNotNil(vm.permissionPrompt)

        vm.automationPromptInFlight = nil
        await waitUntil { vm.isOpen }
        XCTAssertEqual(vm.route, .shelf)
        XCTAssertTrue(vm.isPinned)
        vm.permissionPromptAction(.dismiss)
        let granted = await flow.value
        XCTAssertFalse(granted)
    }

    // MARK: - Core: approval visibility

    func testApprovalVisibilityIsStampedOnlyWhileVisibleAndReviewed() async {
        let harness = CoreHarness(self)
        let vm = harness.vm
        harness.executor.pendingApproval = approval("call-1")
        vm.refreshApprovalVisibility()
        vm.noteApprovalReviewed(callID: "call-1")
        XCTAssertNil(vm.approvalVisibility, "a card created while closed isn't visible")

        vm.open(reason: .click, focus: true)
        XCTAssertNil(vm.approvalVisibility, "not reviewed yet")
        harness.clock.uptime = 100
        vm.noteApprovalReviewed(callID: "call-1")
        XCTAssertEqual(vm.approvalVisibility,
                       NotchViewModel.ApprovalVisibility(callID: "call-1", since: harness.clock.date, sinceUptime: 100))

        // Route change clears it; coming back needs a fresh review and restarts arming.
        vm.navigate(to: .history)
        XCTAssertNil(vm.approvalVisibility)
        vm.navigate(to: .chat)
        XCTAssertNil(vm.approvalVisibility)
        harness.clock.uptime = 200
        vm.noteApprovalReviewed(callID: "call-1")
        XCTAssertEqual(vm.approvalVisibility?.sinceUptime, 200)

        // A screen capture hides the panel.
        var captureEnded = false
        vm.onEndScreenCapture = { captureEnded = true }
        let (gate, release) = AsyncStream<Void>.makeStream()
        vm.captureInteractive = {
            for await _ in gate { break }
            return nil
        }
        vm.captureScreenshot()
        XCTAssertNil(vm.approvalVisibility)
        release.finish()
        await waitUntil { captureEnded }
        vm.noteApprovalReviewed(callID: "call-1")
        XCTAssertNotNil(vm.approvalVisibility)

        // Close clears it.
        vm.close(.outsideClick)
        XCTAssertNil(vm.approvalVisibility)

        // So does the fold.
        vm.open(reason: .click, focus: true)
        vm.noteApprovalReviewed(callID: "call-1")
        XCTAssertNotNil(vm.approvalVisibility)
        vm.automationPromptInFlight = .automation(bundleID: "com.apple.Music", appName: "Music")
        await waitUntil { vm.isFolded }
        XCTAssertNil(vm.approvalVisibility)
    }

    func testResolveApprovalPassesMayApproveAndVisibleSince() {
        let harness = CoreHarness(self)
        let vm = harness.vm
        harness.executor.pendingApproval = approval("call-1", armingDelay: .seconds(1))
        vm.open(reason: .click, focus: true)
        harness.clock.uptime = 500
        vm.noteApprovalReviewed(callID: "call-1")
        let since = harness.clock.date

        // Before the card armed (500 + 1 s), and a held key: never hardware-confirmed.
        vm.resolveApproval(.run(ApprovalOptions()), input: keyPress(at: 500.5))
        vm.resolveApproval(.run(ApprovalOptions()), input: keyPress(at: 501.5, isRepeat: true))
        vm.resolveApproval(.run(ApprovalOptions()), input: .programmatic)
        XCTAssertEqual(harness.executor.resolveCalls.map(\.hardwareConfirmed), [false, false, false])
        XCTAssertEqual(harness.executor.resolveCalls.map(\.visibleSince), [since, since, since])
        XCTAssertNotNil(harness.chat.pendingApproval)

        vm.performPromptPrimary(input: keyPress(at: 501.2))
        XCTAssertEqual(harness.executor.resolveCalls.last,
                       FakeToolExecutor.ResolveCall(decision: .run(ApprovalOptions()), callID: "call-1",
                                                    hardwareConfirmed: true, visibleSince: since))
        XCTAssertNil(harness.chat.pendingApproval)
    }

    func testDeclineNeedsNeitherVisibilityNorHardwareInput() {
        let harness = CoreHarness(self)
        let vm = harness.vm
        harness.executor.pendingApproval = approval("call-2")
        vm.open(reason: .click, focus: true)
        vm.performPromptSecondary()
        XCTAssertEqual(harness.executor.resolveCalls.last?.decision, .deny)
        XCTAssertEqual(harness.executor.resolveCalls.last?.visibleSince, nil)
        XCTAssertNil(harness.chat.pendingApproval)
    }

    // MARK: - Core: history notice

    func testInertGraphNeverQueuesTheHistoryNotice() async {
        let vm = makeViewModel()
        vm.open(reason: .click, focus: true)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(vm.history.isIndexLoaded)
        XCTAssertTrue(vm.cardQueue.isEmpty)
        XCTAssertNil(vm.currentPrompt)
    }

    func testHistoryNoticeIsQueuedOnlyAfterHistoryStarts() async {
        let harness = CoreHarness(self)
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(vm.cardQueue.isEmpty)

        await vm.history.start()
        await waitUntil { vm.card?.kind == .historyNotice }
        XCTAssertEqual(vm.card?.primary.title, "Got It")
        XCTAssertEqual(vm.card?.secondary?.action, .declineHistory)
        XCTAssertFalse(vm.stayOpenHolds.contains(.promptDecision))

        // Over a conversation it stays queued but out of sight.
        harness.chat.debugSeed(messages: conversation(), isStreaming: false)
        XCTAssertNil(vm.card)
        XCTAssertEqual(vm.cardQueue.count, 1)
        harness.chat.debugSeed(messages: [], isStreaming: false)
        XCTAssertEqual(vm.card?.kind, .historyNotice)

        // Esc performs the escape action: acknowledge, never "Don't Save History".
        vm.performPromptSecondary()
        XCTAssertTrue(harness.settings.history.noticeAcknowledged)
        XCTAssertTrue(harness.settings.history.enabled)
        XCTAssertTrue(vm.cardQueue.isEmpty)
    }

    // MARK: - Core: prompts

    func testPromptPriorityIsApprovalThenPermissionThenCard() async {
        let harness = CoreHarness(self)
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        vm.present(card: voiceConsentCard)
        vm.present(card: voiceConsentCard)
        XCTAssertEqual(vm.cardQueue.count, 1, "cards are de-duplicated by kind")
        XCTAssertEqual(vm.currentPrompt, .card(voiceConsentCard))

        let flow = Task { await vm.requestPermission(.microphone, for: .voice) }
        await waitUntil { vm.permissionPrompt != nil }
        guard case .permission? = vm.currentPrompt else { return XCTFail("expected the permission prompt") }

        let pending = approval("call-3")
        harness.executor.pendingApproval = pending
        XCTAssertEqual(vm.currentPrompt, .approval(pending))
        XCTAssertTrue(vm.needsAttention)
        var context = vm.keyContext(hasMarkedText: false, composerIsFirstResponder: true,
                                    clipboardWantsAttachmentPaste: false)
        XCTAssertEqual(context.prompt, .approval)
        vm.navigate(to: .history)
        context = vm.keyContext(hasMarkedText: false, composerIsFirstResponder: false, clipboardWantsAttachmentPaste: false)
        XCTAssertEqual(context.prompt, .none, "prompts count only where they are rendered")
        vm.navigate(to: .chat)

        harness.executor.pendingApproval = nil
        vm.performPromptSecondary()
        let granted = await flow.value
        XCTAssertFalse(granted)
        XCTAssertEqual(vm.currentPrompt, .card(voiceConsentCard))

        // Esc on a card performs its escape action; the default for .dismiss is to drop the card.
        vm.performPromptSecondary()
        XCTAssertNil(vm.currentPrompt)
        XCTAssertFalse(harness.settings.voice.enabled)
    }

    func testAwaitCardDecisionReturnsTheActionInsteadOfRunningTheDefault() async {
        let harness = CoreHarness(self)
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        let decision = Task { await vm.awaitCardDecision(voiceConsentCard) }
        await waitUntil { vm.card != nil }
        vm.performPromptPrimary(input: .programmatic)
        let action = await decision.value
        XCTAssertEqual(action, .enableVoice(.toggle(.micButton)))
        XCTAssertFalse(harness.settings.voice.enabled, "the caller decides what the action does")
        XCTAssertTrue(vm.cardQueue.isEmpty)
    }

    func testPermissionFlowExplainThenGrantedResumesOnce() async {
        let harness = CoreHarness(self, statuses: [.microphone: .notDetermined])
        let vm = harness.vm
        let flow = Task { await vm.requestPermission(.microphone, for: .voice) }
        await waitUntil { vm.permissionPrompt != nil }
        XCTAssertTrue(vm.isOpen, "a feature flow opens the notch")
        XCTAssertTrue(vm.isEngaged)
        XCTAssertEqual(vm.permissionPrompt?.phase, .explain)
        XCTAssertEqual(vm.permissionCardContent?.primaryAction, .request)
        XCTAssertTrue(vm.stayOpenHolds.contains(.promptDecision))

        // The user allows it in the macOS dialog: "You're all set", then the flow resumes its caller.
        harness.probe.set(.microphone, .granted)
        vm.performPromptPrimary(input: .programmatic)
        await waitUntil { vm.permissionPrompt?.phase == .granted || vm.permissionPrompt == nil }
        XCTAssertFalse(vm.stayOpenHolds.contains(.promptDecision))
        let granted = await flow.value
        XCTAssertTrue(granted)
        XCTAssertNil(vm.permissionPrompt)
        XCTAssertNil(vm.lastPermissionDeclineAction)

        // Resumed once: later actions have no flow to act on, and a new request supersedes an old one.
        vm.permissionPromptAction(.dismiss)
        vm.close(.user)
        XCTAssertNil(vm.permissionPrompt)
        let first = Task { await vm.requestPermission(.speechRecognition, for: .voice) }
        await waitUntil { vm.permissionPrompt?.permission == .speechRecognition }
        let second = Task { await vm.requestPermission(.accessibility, for: .selection(appName: "Notes")) }
        await waitUntil { vm.permissionPrompt?.permission == .accessibility }
        let firstResult = await first.value
        XCTAssertFalse(firstResult)
        vm.permissionPromptAction(.dismiss)
        let secondResult = await second.value
        XCTAssertFalse(secondResult)
    }

    func testAlreadyGrantedPermissionShowsNoCardAndJustCopyIsReported() async {
        let harness = CoreHarness(self, statuses: [.calendars: .granted, .accessibility: .denied])
        let vm = harness.vm
        let granted = await vm.requestPermission(.calendars, for: .calendarGlance)
        XCTAssertTrue(granted)
        XCTAssertFalse(vm.isOpen)
        XCTAssertNil(vm.permissionPrompt)

        let flow = Task { await vm.requestPermission(.accessibility, for: .paste(appName: "Notes")) }
        await waitUntil { vm.permissionPrompt != nil }
        XCTAssertEqual(vm.permissionCardContent?.secondaryTitle, "Just Copy")
        vm.performPromptSecondary()
        let result = await flow.value
        XCTAssertFalse(result)
        XCTAssertEqual(vm.lastPermissionDeclineAction, .justCopy)
    }

    func testRelaunchStepNeedsCommandReturn() async {
        let harness = CoreHarness(self, statuses: [.screenRecording: .needsRelaunch])
        let vm = harness.vm
        let flow = Task { await vm.requestPermission(.screenRecording, for: .windowCapture(appName: "Xcode")) }
        await waitUntil { vm.permissionPrompt != nil }
        XCTAssertEqual(vm.permissionCardContent?.primaryAction, .relaunch)
        let context = vm.keyContext(hasMarkedText: false, composerIsFirstResponder: true,
                                    clipboardWantsAttachmentPaste: false)
        XCTAssertTrue(context.promptPrimaryRequiresCommand)
        XCTAssertEqual(context.prompt, .other)
        vm.performPromptPrimary(input: .trusted())
        XCTAssertEqual(harness.relauncher.count, 1)
        vm.permissionPromptAction(.dismiss)
        _ = await flow.value
    }

    func testToolPermissionCardWaitsForMacOSThenApprovesTheSamePress() async {
        let harness = CoreHarness(self, statuses: [.calendars: .denied])
        let vm = harness.vm
        let consent = ConsentPreview(symbol: "calendar", title: "Let Otto read your calendar?",
                                     body: "Otto looks only when you ask. Event details are sent to Claude to answer.",
                                     footnote: nil)
        harness.executor.pendingApproval = approval("call-4", kind: .permission([.calendars], consent: nil),
                                                    body: .consent(consent))
        vm.open(reason: .click, focus: true)
        await harness.center.refresh([.calendars])
        let content = vm.permissionCardContent
        XCTAssertEqual(content?.primaryAction, .openSystemSettings)
        XCTAssertEqual(content?.title, "Otto needs Calendars access")
        XCTAssertTrue(content?.body.hasSuffix("Event details are sent to Claude to answer.") ?? false)

        harness.clock.uptime = 10
        vm.noteApprovalReviewed(callID: "call-4")
        let since = harness.clock.date
        // Synthetic input never reaches macOS.
        vm.performPromptPrimary(input: .programmatic)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(harness.center.awaiting)
        XCTAssertTrue(harness.executor.resolveCalls.isEmpty)

        vm.performPromptPrimary(input: keyPress(at: 11.5))
        await waitUntil { vm.isFolded }
        XCTAssertEqual(vm.systemUIWait, .systemSettings(.calendars))
        XCTAssertEqual(vm.toolPermission?.phase, .waiting)
        harness.probe.set(.calendars, .granted)
        await waitUntil { !harness.executor.resolveCalls.isEmpty }
        XCTAssertEqual(harness.executor.resolveCalls.last?.hardwareConfirmed, true)
        XCTAssertEqual(harness.executor.resolveCalls.last?.visibleSince, since)
        await waitUntil { vm.isOpen }
    }

    // MARK: - Core: open, close, focus

    func testOpenStartsFreshBeforeThePresentationChanges() async {
        let client = ScriptedLLMClient([reply("Hello.")])
        let harness = CoreHarness(self, client: client)
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        vm.composerText = "Hi"
        vm.send()
        await waitForReply(harness.chat)
        vm.close(.user)
        harness.clock.date = harness.clock.date.addingTimeInterval(16 * 60)

        var messagesAtOpen: Int?
        vm.onPresentationChange = { presentation in
            if presentation == .open { messagesAtOpen = vm.chat.messages.count }
        }
        vm.open(reason: .click, focus: true)
        XCTAssertEqual(messagesAtOpen, 0, "the idle fresh start runs before the notch presents")
        XCTAssertTrue(vm.chat.messages.isEmpty)
    }

    func testCloseResetsRouteOverlayPinSoftFocusAndPrompt() async {
        let harness = CoreHarness(self)
        let vm = harness.vm
        vm.open(reason: .hover, focus: false)
        vm.toggleShortcutSheet()
        XCTAssertEqual(vm.overlay, .shortcutSheet)
        vm.navigate(to: .shelf)
        vm.togglePin()
        vm.softFocus()
        XCTAssertTrue(vm.isSoftFocused)
        let flow = Task { await vm.requestPermission(.microphone, for: .voice) }
        await waitUntil { vm.permissionPrompt != nil }

        vm.close(.outsideClick)
        XCTAssertEqual(vm.route, .chat)
        XCTAssertNil(vm.overlay)
        XCTAssertFalse(vm.isPinned)
        XCTAssertFalse(vm.isSoftFocused)
        XCTAssertNil(vm.permissionPrompt)
        XCTAssertNil(vm.suggestedTab)
        let granted = await flow.value
        XCTAssertFalse(granted)
    }

    func testSoftFocusTakesAndReturnsTheKeyboard() {
        let vm = CoreHarness(self).vm
        var keyRequests: [Bool] = []
        vm.onRequestKey = { keyRequests.append($0) }
        vm.open(reason: .hover, focus: false)
        vm.softFocus()
        XCTAssertTrue(vm.isSoftFocused)
        XCTAssertFalse(vm.isEngaged)
        XCTAssertEqual(vm.focusRequest, 1)
        XCTAssertFalse(vm.keyContext(hasMarkedText: false, composerIsFirstResponder: true,
                                     clipboardWantsAttachmentPaste: false).isEngaged)
        vm.releaseSoftFocus()
        XCTAssertEqual(keyRequests, [true, false])

        vm.softFocus()
        vm.engage()
        XCTAssertFalse(vm.isSoftFocused)
        XCTAssertTrue(vm.isEngaged)
        vm.releaseSoftFocus()
        XCTAssertEqual(keyRequests, [true, false, true, true], "engaged: releasing soft focus keeps the key")

        vm.panelDidLoseKey()
        XCTAssertFalse(vm.isEngaged)
        vm.disengage()
        XCTAssertEqual(keyRequests.last, false)
    }

    func testPinShowsItsNoticeOncePerSession() {
        let vm = CoreHarness(self).vm
        vm.open(reason: .click, focus: true)
        vm.togglePin()
        XCTAssertTrue(vm.isPinned)
        XCTAssertEqual(vm.transientNotice?.text, "Pinned. Otto stays open while you work")
        vm.togglePin()
        vm.showNotice("Something else")
        vm.togglePin()
        XCTAssertTrue(vm.isPinned)
        XCTAssertEqual(vm.transientNotice?.text, "Something else")
    }

    func testRecallEditAndResendReplacesTheLastTurn() async {
        let client = ScriptedLLMClient([reply("First."), reply("Second.")])
        let harness = CoreHarness(self, client: client)
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        vm.composerText = "Hello"
        vm.send()
        await waitForReply(harness.chat)

        XCTAssertTrue(vm.recallLastMessage())
        XCTAssertEqual(vm.composerText, "Hello")
        XCTAssertTrue(vm.isEditing)
        XCTAssertFalse(vm.recallLastMessage(), "only an empty composer recalls")
        vm.cancelEditing()
        XCTAssertFalse(vm.isEditing)
        XCTAssertEqual(vm.composerText, "")

        XCTAssertTrue(vm.recallLastMessage())
        vm.composerText = "Hello again"
        vm.send()
        XCTAssertFalse(vm.isEditing)
        await waitForReply(harness.chat)
        XCTAssertEqual(harness.chat.messages.map(\.text), ["Hello again", "Second."])
    }

    func testSelectModelSaysWhatChangedAndWhen() {
        let harness = CoreHarness(self)
        let vm = harness.vm
        harness.settings.model = .opus5
        vm.selectModel(.sonnet5)
        XCTAssertEqual(harness.settings.model, .sonnet5)
        XCTAssertEqual(vm.transientNotice?.text, "Switched to Sonnet 5")

        harness.settings.model = .opus5
        vm.addAttachment(pdfAttachment("long.pdf", pages: 101))
        harness.chat.debugSeed(messages: conversation(), isStreaming: true)
        vm.selectModel(.haiku45)
        XCTAssertEqual(vm.transientNotice?.text,
                       "Haiku 4.5 from your next message · a PDF here is too long for Haiku 4.5")
    }

    func testReadingAnchorLandsOnAReplyThatFinishedWhileClosed() async {
        let client = ScriptedLLMClient([reply("Long answer.")])
        let harness = CoreHarness(self, client: client)
        let vm = harness.vm
        harness.chat.send(text: "Question", attachments: [])
        await waitForReply(harness.chat)
        let answerID = harness.chat.messages.last?.id
        XCTAssertEqual(vm.unreadReplyID, answerID)

        vm.open(reason: .click, focus: true)
        XCTAssertNil(vm.unreadReplyID)
        XCTAssertEqual(vm.readingAnchor?.messageID, answerID)
        XCTAssertEqual(vm.consumeReadingAnchor()?.messageID, answerID)
        XCTAssertNil(vm.consumeReadingAnchor())

        // Where the user stopped reading, if the conversation hasn't moved on since.
        let questionID = harness.chat.messages.first?.id ?? UUID()
        vm.noteReadingPosition(ReadingPosition(anchorMessageID: questionID, fractionScrolledPast: 0.3, isAtBottom: false,
                                               lastMessageID: answerID, savedAt: harness.clock.date))
        vm.close(.pointerExit)
        vm.open(reason: .hover, focus: false)
        XCTAssertEqual(vm.readingAnchor?.messageID, questionID)
    }

    func testOpenSettingsClosesThenCallsTheTabHook() {
        let vm = CoreHarness(self).vm
        var requests: [String] = []
        vm.onOpenSettingsTab = { tab, anchor in requests.append("\(tab?.rawValue ?? "-")|\(anchor?.rawValue ?? "-")") }
        vm.open(reason: .click, focus: true)
        vm.togglePin()
        vm.openSettings(tab: .models, anchor: .usage)
        XCTAssertFalse(vm.isOpen)
        XCTAssertFalse(vm.isPinned)
        vm.openSettings()
        XCTAssertEqual(requests, ["models|usage", "-|-"])
    }

    func testNewChatResetsRouteTallModeAndEditing() async {
        let client = ScriptedLLMClient([reply("Hello.")])
        let harness = CoreHarness(self, client: client)
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        vm.composerText = "Hi"
        vm.send()
        await waitForReply(harness.chat)
        vm.setTallMode(true)
        vm.recallLastMessage()
        vm.navigate(to: .history)

        vm.newChat()
        XCTAssertTrue(harness.chat.messages.isEmpty)
        XCTAssertEqual(vm.route, .chat)
        XCTAssertFalse(vm.isTallMode)
        XCTAssertFalse(vm.isEditing)
        XCTAssertEqual(vm.composerText, "")
    }

    func testDebugSeedFeaturesHoldsTheSeededFold() async {
        let harness = CoreHarness(self)
        let vm = harness.vm
        harness.executor.pendingApproval = approval("call-5")
        vm.debugSeed(presentation: .closed, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
        let since = harness.clock.date.addingTimeInterval(-2)
        vm.debugSeed(features: NotchDebugSeed(route: .chat, isPinned: true, card: voiceConsentCard,
                                              systemUIWait: .systemSettings(.accessibility),
                                              approvalVisibleSince: since))
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(vm.systemUIWait, .systemSettings(.accessibility))
        XCTAssertTrue(vm.isFolded)
        XCTAssertTrue(vm.isPinned)
        XCTAssertEqual(vm.card, voiceConsentCard)
        XCTAssertEqual(vm.approvalVisibility?.since, since)
        XCTAssertEqual(vm.approvalVisibility?.callID, "call-5")
    }
}
