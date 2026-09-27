//
//  MessageSegmentsTests.swift
//  Otto
//
//  The reply layout of §5.8: text cut at each tool round with that round's rows in between, the calls in no
//  round after the tail, the refused turn's kept rows, Otto's own note rows; MessageView equality, which
//  decides when a turn in the transcript re-renders; and the transcript's reading anchors and tall-mode fill,
//  read off a real AppKit scroll view in an off-screen window.
//

import AppKit
import SwiftUI
import XCTest
@testable import Otto

final class MessageSegmentsTests: XCTestCase {
    // MARK: - Interleaving

    func testTextIsSplitAtEachExchangeWithThatRoundsCalls() {
        let add = Self.call("a", status: .succeeded)
        let remind = Self.call("b", status: .succeeded)
        let open = Self.call("c", status: .succeeded)
        let message = Self.reply(
            text: "Adding it. Now the reminder. Done, and opened the page.",
            calls: [add, remind, open],
            exchanges: [
                ToolExchange(contentEnd: 2, textEnd: 11, callIDs: ["a"]),
                ToolExchange(contentEnd: 4, textEnd: 29, callIDs: ["b", "c"]),
            ]
        )

        XCTAssertEqual(MessageSegments(message: message).items, [
            .text("Adding it. "),
            .calls([add]),
            .text("Now the reminder. "),
            .calls([remind, open]),
            .tail("Done, and opened the page."),
        ])
    }

    func testCallsInNoExchangeFollowTheTailInCallOrder() {
        let ran = Self.call("a", status: .succeeded)
        let preparing = Self.call("b", status: .preparing)
        let queued = Self.call("c", status: .queued)
        let message = Self.reply(
            text: "First. Then two more.",
            calls: [ran, preparing, queued],
            exchanges: [ToolExchange(contentEnd: 2, textEnd: 7, callIDs: ["a"])],
            state: .streaming
        )

        let segments = MessageSegments(message: message)
        XCTAssertEqual(segments.items, [.text("First. "), .calls([ran]), .tail("Then two more."), .calls([preparing, queued])])
        XCTAssertTrue(segments.hasUnsettledCall, "the caret waits while calls are still in flight")
    }

    func testATurnWithoutToolsIsOneTail() {
        let segments = MessageSegments(message: Self.reply(text: "Just words."))
        XCTAssertEqual(segments.items, [.tail("Just words.")])
        XCTAssertTrue(segments.keptCalls.isEmpty)
        XCTAssertFalse(segments.hasUnsettledCall)
    }

    func testEveryTurnHasOneTailEvenWhenEmpty() {
        let call = Self.call("a", status: .succeeded)
        let message = Self.reply(
            text: "Checking.",
            calls: [call],
            exchanges: [ToolExchange(contentEnd: 2, textEnd: 9, callIDs: ["a"])],
            state: .streaming
        )
        XCTAssertEqual(MessageSegments(message: message).items, [.text("Checking."), .calls([call]), .tail("")])
    }

    func testBlankTextBetweenRoundsIsDropped() {
        let first = Self.call("a", status: .succeeded)
        let second = Self.call("b", status: .succeeded)
        let message = Self.reply(
            text: "  \nDone.",
            calls: [first, second],
            exchanges: [
                ToolExchange(contentEnd: 2, textEnd: 0, callIDs: ["a"]),
                ToolExchange(contentEnd: 4, textEnd: 3, callIDs: ["b"]),
            ]
        )
        XCTAssertEqual(MessageSegments(message: message).items, [.calls([first]), .calls([second]), .tail("Done.")])
    }

    func testOutOfRangeTextEndsNeverLoseOrRepeatText() {
        let first = Self.call("a", status: .succeeded)
        let second = Self.call("b", status: .succeeded)
        let text = "Short reply."
        let message = Self.reply(
            text: text,
            calls: [first, second],
            exchanges: [
                ToolExchange(contentEnd: 2, textEnd: 6, callIDs: ["a"]),
                // Behind the previous exchange, then past the end of the text.
                ToolExchange(contentEnd: 4, textEnd: 2, callIDs: ["b"]),
                ToolExchange(contentEnd: 6, textEnd: 500, callIDs: []),
            ]
        )

        let items = MessageSegments(message: message).items
        XCTAssertEqual(items, [.text("Short "), .calls([first]), .calls([second]), .text("reply."), .tail("")])
        let shown = items.compactMap { item -> String? in
            switch item {
            case .text(let piece), .tail(let piece): return piece
            case .calls: return nil
            }
        }.joined()
        XCTAssertEqual(shown, text)
    }

    func testTextEndsCountCharactersNotUTF16() {
        let call = Self.call("a", status: .succeeded)
        let message = Self.reply(
            text: "👍🏽 Added. Next?",
            calls: [call],
            exchanges: [ToolExchange(contentEnd: 2, textEnd: 8, callIDs: ["a"])]
        )
        XCTAssertEqual(MessageSegments(message: message).items, [.text("👍🏽 Added."), .calls([call]), .tail(" Next?")])
    }

    func testMissingAndRepeatedCallIDsArePlacedOnce() {
        let call = Self.call("a", status: .succeeded)
        let message = Self.reply(
            text: "One. Two.",
            calls: [call],
            exchanges: [
                ToolExchange(contentEnd: 2, textEnd: 5, callIDs: ["a", "ghost"]),
                ToolExchange(contentEnd: 4, textEnd: 9, callIDs: ["a"]),
            ]
        )
        XCTAssertEqual(MessageSegments(message: message).items, [.text("One. "), .calls([call]), .text("Two."), .tail("")])
    }

    // MARK: - Refused turns

    func testRefusedTurnKeepsTheCallsThatRanUnderTheCaption() {
        let ran = Self.call("a", status: .succeeded)
        let failed = Self.call("b", status: .failed("Timed out"))
        let message = Self.reply(
            text: "I started on that.",
            calls: [ran, failed],
            exchanges: [],
            state: .refused("Claude stopped this reply.")
        )

        let segments = MessageSegments(message: message)
        XCTAssertEqual(segments.items, [.tail("I started on that.")])
        XCTAssertEqual(segments.keptCalls, [ran, failed])
        XCTAssertEqual(MessageSegments.keptCallsCaption, "Done before Otto stopped")
    }

    func testRefusedTurnWithoutCallsHasNothingUnderTheCaption() {
        let segments = MessageSegments(message: Self.reply(text: "", state: .refused("Claude stopped this reply.")))
        XCTAssertTrue(segments.keptCalls.isEmpty)
    }

    func testOtherEndingsKeepTheirRoundsInline() {
        let call = Self.call("a", status: .cancelled)
        let message = Self.reply(
            text: "Working on it.",
            calls: [call],
            exchanges: [ToolExchange(contentEnd: 2, textEnd: 14, callIDs: ["a"])],
            state: .cancelled
        )
        let segments = MessageSegments(message: message)
        XCTAssertEqual(segments.items, [.text("Working on it."), .calls([call]), .tail("")])
        XCTAssertTrue(segments.keptCalls.isEmpty)
    }

    // MARK: - Activity rows

    @MainActor
    func testOttoActivitiesAreNoteRowsAndTheRestAreServerRows() {
        let pause = ToolActivity(id: ChatSession.webPausedActivityID, kind: .other,
                                 label: "Web access paused for the rest of this reply.", isDone: true)
        let search = ToolActivity(id: "srvtoolu_1", kind: .webSearch, label: "Searching “notch apps”", isDone: true)
        let otherServer = ToolActivity(id: "srvtoolu_2", kind: .other, label: "Using a tool", isDone: false)
        let spoofedKind = ToolActivity(id: "otto.search", kind: .webSearch, label: "Searching", isDone: true)
        let message = Self.reply(text: "", activities: [search, pause, otherServer, spoofedKind])

        XCTAssertEqual(MessageSegments(message: message).activities, [
            .server(search), .note(pause), .server(otherServer), .server(spoofedKind),
        ])
        XCTAssertTrue(MessageSegments.isNote(pause))
        XCTAssertFalse(MessageSegments.isNote(otherServer))
        XCTAssertFalse(MessageSegments.isNote(spoofedKind), "only kind .other rows are Otto's notes")
    }

    func testSettledCallsLetTheCaretShow() {
        let calls = [
            Self.call("a", status: .succeeded), Self.call("b", status: .denied), Self.call("c", status: .skipped("Cut off")),
        ]
        XCTAssertFalse(MessageSegments(message: Self.reply(text: "Done.", calls: calls, state: .streaming)).hasUnsettledCall)
        for status: ToolCallStatus in [.awaitingApproval, .needsPermission, .running, .waitingForSystem("Finder")] {
            let message = Self.reply(text: "Done.", calls: [Self.call("d", status: status)], state: .streaming)
            XCTAssertTrue(MessageSegments(message: message).hasUnsettledCall, "\(status)")
        }
    }

    // MARK: - MessageView equality

    @MainActor
    func testMessageViewEqualityFollowsEveryInput() {
        let settings = AppSettings(defaults: TestDefaults.make(for: self))
        let chat = ChatSession(settings: settings, makeClient: { MockLLMClient(latencyScale: 0) })
        let viewModel = NotchViewModel(settings: settings, chat: chat)
        let otherViewModel = NotchViewModel(settings: settings, chat: chat)
        let message = Self.reply(text: "Here you go.")
        let notes = AppRef(pid: 4242, bundleID: "com.apple.Notes", name: "Notes")
        let base = MessageView(
            message: message,
            viewModel: viewModel,
            isLast: true,
            availableWidth: 500,
            unavailableAttachmentIDs: [],
            versionInfo: VersionPager.position(currentIndex: 0, storedCount: 2),
            insertTarget: InsertTarget(app: notes, selection: nil)
        )

        XCTAssertTrue(base == base)
        XCTAssertTrue(base == MessageView(
            message: message, viewModel: viewModel, isLast: true, availableWidth: 500, unavailableAttachmentIDs: [],
            versionInfo: VersionPager.position(currentIndex: 0, storedCount: 2),
            insertTarget: InsertTarget(app: notes, selection: nil)
        ), "equal inputs are an equal view")

        var edited = message
        edited.text += " More."
        var changes: [String: MessageView] = [:]
        changes["message"] = Self.with(base, message: edited)
        changes["viewModel"] = MessageView(
            message: message, viewModel: otherViewModel, isLast: true, availableWidth: 500,
            versionInfo: base.versionInfo, insertTarget: base.insertTarget
        )
        var view = base
        view.isLast = false
        changes["isLast"] = view
        view = base
        view.availableWidth = 480
        changes["availableWidth"] = view
        view = base
        view.unavailableAttachmentIDs = [UUID()]
        changes["unavailableAttachmentIDs"] = view
        view = base
        view.versionInfo = VersionPager.position(currentIndex: 1, storedCount: 2)
        changes["versionInfo"] = view
        view = base
        view.versionInfo = nil
        changes["versionInfo removed"] = view
        view = base
        view.insertTarget = InsertTarget(app: AppRef(pid: 4343, bundleID: "com.apple.TextEdit", name: "TextEdit"),
                                         selection: nil)
        changes["insertTarget"] = view
        view = base
        view.insertTarget = nil
        changes["insertTarget removed"] = view

        for (input, changed) in changes {
            XCTAssertFalse(base == changed, "changing \(input) must re-render the message")
        }
    }

    // MARK: - Fixtures

    private static func reply(
        text: String,
        calls: [ToolCall] = [],
        exchanges: [ToolExchange] = [],
        activities: [ToolActivity] = [],
        state: MessageState = .complete
    ) -> ChatMessage {
        ChatMessage(
            id: UUID(uuidString: "5E6A2F4C-0000-4000-8000-000000000001") ?? UUID(),
            role: .assistant,
            text: text,
            activities: activities,
            state: state,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            toolCalls: calls,
            toolExchanges: exchanges
        )
    }

    private static func call(_ id: String, status: ToolCallStatus) -> ToolCall {
        ToolCall(
            id: id,
            name: "calendar_create_event",
            input: nil,
            invalidInput: nil,
            presentation: .generic(toolName: "calendar_create_event"),
            status: status
        )
    }

    private static func with(_ view: MessageView, message: ChatMessage) -> MessageView {
        MessageView(
            message: message, viewModel: view.viewModel, isLast: view.isLast, availableWidth: view.availableWidth,
            unavailableAttachmentIDs: view.unavailableAttachmentIDs, versionInfo: view.versionInfo,
            insertTarget: view.insertTarget
        )
    }
}

// MARK: - Reading anchors and tall mode

@MainActor
final class ConversationReadingTests: XCTestCase {
    /// A reply that finished while the notch was closed opens at its start, not at the bottom, and the
    /// transcript then reports that reply as the place the user is reading.
    func testAnchorLandsOnTheStartOfTheReply() async throws {
        let (viewModel, firstReplyID) = makeViewModel(paragraphs: 10)
        viewModel.setReadingAnchor(firstReplyID)
        let host = await ReadingHost(ConversationView(viewModel: viewModel, maxHeight: 320, topInset: 8))
        defer { host.close() }

        let position = try XCTUnwrap(host.scrollPosition)
        XCTAssertGreaterThan(position.hiddenBelow, 200, "it must not rest at the bottom")
        XCTAssertGreaterThan(position.hiddenAbove, 20, "the question above the reply scrolls out of view")
        XCTAssertNil(viewModel.readingAnchor, "the anchor is consumed")

        try await Task.sleep(for: .milliseconds(600))
        let reported = try XCTUnwrap(viewModel.history.currentReadingPosition)
        XCTAssertEqual(reported.anchorMessageID, firstReplyID)
        XCTAssertFalse(reported.isAtBottom)
        XCTAssertEqual(reported.lastMessageID, viewModel.chat.messages.last?.id)
    }

    /// With nothing to scroll, an anchor falls back to the bottom.
    func testAnchorInATranscriptThatFitsStaysAtTheBottom() async throws {
        let (viewModel, firstReplyID) = makeViewModel(paragraphs: 1)
        viewModel.setReadingAnchor(firstReplyID)
        let host = await ReadingHost(ConversationView(viewModel: viewModel, maxHeight: 460, topInset: 8))
        defer { host.close() }

        let position = try XCTUnwrap(host.scrollPosition)
        XCTAssertEqual(position.hiddenBelow, 0, accuracy: 0.5)
    }

    /// Tall mode: a short transcript still takes the whole height it is given; otherwise it hugs its content.
    func testFillsHeightTakesTheWholeMaximum() {
        let (viewModel, _) = makeViewModel(paragraphs: 1)
        let hugging = NSHostingView(rootView: ConversationView(viewModel: viewModel, maxHeight: 400).frame(width: 508))
        let filling = NSHostingView(
            rootView: ConversationView(viewModel: viewModel, maxHeight: 400, fillsHeight: true).frame(width: 508)
        )
        XCTAssertLessThan(hugging.fittingSize.height, 399)
        XCTAssertEqual(filling.fittingSize.height, 400, accuracy: 0.5)
    }

    private func makeViewModel(paragraphs: Int) -> (NotchViewModel, UUID) {
        let settings = AppSettings(defaults: TestDefaults.make(for: self))
        settings.suggestBrowserTab = false
        let chat = ChatSession(settings: settings, makeClient: { MockLLMClient(latencyScale: 0) })
        let reply = (1...paragraphs)
            .map { "\($0). A paragraph long enough to wrap onto a second line in the notch, so replies run tall." }
            .joined(separator: "\n\n")
        let firstReply = ChatMessage(role: .assistant, text: reply)
        chat.debugSeed(
            messages: [
                ChatMessage(role: .user, text: "What changed this week?"),
                firstReply,
                ChatMessage(role: .user, text: "And next week?"),
                ChatMessage(role: .assistant, text: reply),
            ],
            isStreaming: false
        )
        return (NotchViewModel(settings: settings, chat: chat), firstReply.id)
    }
}

/// A view in an off-screen window, laid out until it settles.
@MainActor
private final class ReadingHost {
    struct ScrollPosition {
        var hiddenAbove: CGFloat
        var hiddenBelow: CGFloat
    }

    private static let size = CGSize(width: 508, height: 520)
    private let hostingView: NSHostingView<AnyView>
    private let window: NSWindow

    init(_ view: some View) async {
        hostingView = NSHostingView(rootView: AnyView(
            view.frame(width: Self.size.width).frame(height: Self.size.height, alignment: .top)
                .environment(\.colorScheme, .dark)
        ))
        hostingView.frame = CGRect(origin: .zero, size: Self.size)
        window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: Self.size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFrontRegardless()
        for _ in 0..<15 {
            hostingView.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    var scrollPosition: ScrollPosition? {
        guard let scrollView = Self.scrollView(in: hostingView), let document = scrollView.documentView else {
            return nil
        }
        let visible = scrollView.contentView.bounds
        return ScrollPosition(hiddenAbove: visible.minY, hiddenBelow: document.frame.height - visible.maxY)
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }
}
