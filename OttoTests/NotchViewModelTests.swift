//
//  NotchViewModelTests.swift
//  Otto
//
//  NotchViewModel state: attachments and their budgets, sending, open/close hooks, the suggested
//  tab, unread replies, transient errors and New Chat.
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
}
