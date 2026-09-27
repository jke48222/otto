//
//  ReplyPreviewTextTests.swift
//  OttoTests
//
//  First-line extraction from Markdown, previews built from finished messages, the drop metrics, and
//  the controller's 4-second countdown with its hover pause.
//

import XCTest
@testable import Otto

final class ReplyPreviewTextTests: XCTestCase {
    private func first(_ markdown: String, limit: Int = 140) -> String {
        ReplyPreviewText.firstLine(of: markdown, limit: limit)
    }

    func testPlainFirstLine() {
        XCTAssertEqual(first("Sure. Here's how.\nSecond line."), "Sure. Here's how.")
    }

    func testSkipsBlankLinesAndRules() {
        XCTAssertEqual(first("\n\n   \n---\n***\nAnswer"), "Answer")
    }

    func testStripsHeadingsQuotesAndLists() {
        XCTAssertEqual(first("## The short version ##"), "The short version")
        XCTAssertEqual(first("# Title"), "Title")
        XCTAssertEqual(first("> Quoted advice"), "Quoted advice")
        XCTAssertEqual(first("> > Nested quote"), "Nested quote")
        XCTAssertEqual(first("- First bullet"), "First bullet")
        XCTAssertEqual(first("* Star bullet"), "Star bullet")
        XCTAssertEqual(first("1. Step one"), "Step one")
        XCTAssertEqual(first("12) Step twelve"), "Step twelve")
        XCTAssertEqual(first("- [ ] Buy milk"), "Buy milk")
        XCTAssertEqual(first("- [x] Done thing"), "Done thing")
        XCTAssertEqual(first("#hashtag stays"), "#hashtag stays")
    }

    func testStripsInlineMarkup() {
        XCTAssertEqual(first("**Bold** and *italic* and _under_ and ~~gone~~"), "Bold and italic and under and gone")
        XCTAssertEqual(first("Run `brew update` first"), "Run brew update first")
        XCTAssertEqual(first("See [the docs](https://example.com/docs) now"), "See the docs now")
        XCTAssertEqual(first("![A chart](https://example.com/c.png) shows it"), "shows it")
        XCTAssertEqual(first("![Only an image](https://example.com/c.png)\nThen text"), "Then text")
        XCTAssertEqual(first("Mail <mailto:a@b.co> or <https://x.dev>"), "Mail mailto:a@b.co or https://x.dev")
    }

    func testStripsHTMLTags() {
        XCTAssertEqual(first("<b>Bold</b> and <span class=\"x\">styled</span>"), "Bold and styled")
        XCTAssertEqual(first("Line<br/>break"), "Linebreak")
        XCTAssertEqual(first("<!-- note -->Visible"), "Visible")
        XCTAssertEqual(first("1 < 2 and 3 > 2"), "1 < 2 and 3 > 2")
    }

    func testKeepsMeaningfulSymbols() {
        XCTAssertEqual(first("2 * 3 = 6"), "2 * 3 = 6")
        XCTAssertEqual(first("Use snake_case_names here"), "Use snake_case_names here")
        XCTAssertEqual(first("[not a link] stays"), "[not a link] stays")
    }

    func testSkipsCodeBlocksAndNamesCodeOnlyReplies() {
        XCTAssertEqual(first("```swift\nlet x = 1\n```\nThat sets x."), "That sets x.")
        XCTAssertEqual(first("```\n\nprint(\"hi\")\n```"), "Reply with code")
        XCTAssertEqual(first("~~~\ncode\n~~~"), "Reply with code")
        XCTAssertEqual(first("```\nunterminated fence"), "Reply with code")
    }

    func testSkipsTableSeparators() {
        XCTAssertEqual(first("|---|:---:|\nAfter"), "After")
        XCTAssertEqual(first("| Name | Size |\n|---|---|"), "| Name | Size |")
    }

    func testCleansAndCaps() {
        XCTAssertEqual(first("Hidden\u{200B}text\u{202E} here"), "Hiddentext here")
        XCTAssertEqual(first("a    lot   of\tspace"), "a lot of space")
        XCTAssertEqual(first("Anything", limit: 0), "")
    }

    func testTruncatesOnAWordBoundary() {
        let long = String(repeating: "word ", count: 60)
        let capped = first(long)
        XCTAssertLessThanOrEqual(capped.count, 140)
        XCTAssertEqual(capped, String(repeating: "word ", count: 26) + "word…")
        XCTAssertEqual(first("Swift actors isolate state", limit: 20), "Swift actors…")
        // One long word has no boundary to cut at: it is cut mid-word.
        XCTAssertEqual(first("Twelvecharacters", limit: 6), "Twelv…")
    }

    func testTruncationKeepsGraphemesWhole() {
        let emoji = String(repeating: "👍🏽", count: 10)
        let cut = first(emoji, limit: 5)
        XCTAssertEqual(cut, String(repeating: "👍🏽", count: 4) + "…")
        let cjk = String(repeating: "東京", count: 100)
        let cutCJK = first(cjk)
        XCTAssertEqual(cutCJK.count, 140)
        XCTAssertEqual(cutCJK, String(cjk.prefix(139)) + "…")
    }

    func testEmptyInputSaysReplyReady() {
        XCTAssertEqual(first(""), "Reply ready")
        XCTAssertEqual(first("\n\n---\n"), "Reply ready")
        XCTAssertEqual(first("**  **"), "Reply ready")
    }

    func testCRLFLines() {
        XCTAssertEqual(first("First\r\nSecond"), "First")
    }

    // MARK: - ReplyPreview.make

    func testPreviewFromAnswer() {
        let message = ChatMessage(role: .assistant, text: "# Plan\nDetails", state: .complete)
        XCTAssertEqual(ReplyPreview.make(from: message), ReplyPreview(id: message.id, outcome: .answered, text: "Plan"))
    }

    func testPreviewFromFailureAndRefusal() {
        let failed = ChatMessage(role: .assistant, text: "Partial", state: .failed("Otto couldn't reach Claude."))
        XCTAssertEqual(ReplyPreview.make(from: failed)?.outcome, .failed)
        XCTAssertEqual(ReplyPreview.make(from: failed)?.text, "Otto couldn't reach Claude.")

        let refused = ChatMessage(role: .assistant, state: .refused("Otto can't help with that one."))
        XCTAssertEqual(ReplyPreview.make(from: refused), ReplyPreview(id: refused.id, outcome: .refused,
                                                                      text: "Otto can't help with that one."))
    }

    func testNoPreviewForUserStreamingOrCancelled() {
        XCTAssertNil(ReplyPreview.make(from: ChatMessage(role: .user, text: "Hi")))
        XCTAssertNil(ReplyPreview.make(from: ChatMessage(role: .assistant, text: "Hi", state: .streaming)))
        XCTAssertNil(ReplyPreview.make(from: ChatMessage(role: .assistant, text: "Hi", state: .cancelled)))
    }

    func testEmptyAnswerPreviewsAsReplyReady() {
        let empty = ChatMessage(role: .assistant, text: "  \n", state: .complete)
        XCTAssertEqual(ReplyPreview.make(from: empty), ReplyPreview(id: empty.id, outcome: .answered, text: "Reply ready"))
    }

    // MARK: - Metrics

    func testMetrics() {
        XCTAssertEqual(ReplyPreviewMetrics.dropHeight, 28)
        XCTAssertEqual(ReplyPreviewMetrics.maxWidth, 380)
        XCTAssertEqual(ReplyPreviewMetrics.horizontalPadding, 16)
        XCTAssertEqual(ReplyPreviewMetrics.visibleDuration, .seconds(4))
        XCTAssertEqual(ReplyPreviewMetrics.resumeMinimum, .milliseconds(1500))
    }

    @MainActor
    func testIdealWidthGrowsWithTextAndIncludesChrome() {
        // icon 11 + gap 6 + 2 × 16 padding + 2 × closedTopRadius (6).
        let chrome: CGFloat = 11 + 6 + 32 + 12
        XCTAssertEqual(ReplyPreviewMetrics.fontSize, 12.5)
        XCTAssertEqual(ReplyPreviewMetrics.idealWidth(for: ""), chrome)
        let short = ReplyPreviewMetrics.idealWidth(for: "OK")
        let long = ReplyPreviewMetrics.idealWidth(for: "A considerably longer first line")
        XCTAssertGreaterThan(short, chrome)
        XCTAssertGreaterThan(long, short)
        XCTAssertEqual(long, ReplyPreviewMetrics.measuredIdealWidth(for: "A considerably longer first line"))
        XCTAssertEqual(long, long.rounded(.up))
    }
}

@MainActor
final class GlancePreviewCountdownTests: XCTestCase {
    /// A sleep that parks until the test releases it; records the requested durations. A cancelled
    /// sleep throws right away, so only the countdown that is still current can be fired.
    private final class ManualSleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var requestedDurations: [Duration] = []
        private var waiting: [UUID: CheckedContinuation<Void, Error>] = [:]
        private var cancelled: Set<UUID> = []

        var requested: [Duration] { lock.withLock { requestedDurations } }

        func sleep(_ duration: Duration) async throws {
            let id = UUID()
            lock.withLock { requestedDurations.append(duration) }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let alreadyCancelled = lock.withLock {
                        if cancelled.contains(id) { return true }
                        waiting[id] = continuation
                        return false
                    }
                    if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let continuation = lock.withLock {
                    cancelled.insert(id)
                    return waiting.removeValue(forKey: id)
                }
                continuation?.resume(throwing: CancellationError())
            }
        }

        func fireAll() {
            let pending = lock.withLock {
                let all = Array(waiting.values)
                waiting = [:]
                return all
            }
            pending.forEach { $0.resume() }
        }
    }

    private var clock = Date(timeIntervalSinceReferenceDate: 5_000)
    private let sleeper = ManualSleeper()

    private func makeController(previews: Bool = true) -> (GlanceController, ChatSession, ChatMessage) {
        let settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        settings.glance.replyPreviews = previews
        let chat = ChatSession(settings: settings, makeClient: { MockLLMClient(latencyScale: 0) })
        let answer = ChatMessage(role: .assistant, text: "Your flight leaves at 9:40.", state: .complete)
        chat.debugSeed(messages: [ChatMessage(role: .user, text: "When?"), answer], isStreaming: false)
        let glance = GlanceController.inert(settings: settings, chat: chat)
        glance.now = { [unowned self] in self.clock }
        glance.sleep = { [sleeper] in try await sleeper.sleep($0) }
        return (glance, chat, answer)
    }

    /// Lets the countdown task (and the sleeper it calls off the main actor) catch up.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(40))
    }

    func testPreviewShowsWhenClosedAndExpires() async {
        let (glance, _, answer) = makeController()
        glance.replyDidFinish(messageID: answer.id, notchIsOpen: false)
        XCTAssertEqual(glance.preview, ReplyPreview(id: answer.id, outcome: .answered, text: "Your flight leaves at 9:40."))
        await settle()
        XCTAssertEqual(sleeper.requested, [.seconds(4)])

        sleeper.fireAll()
        await settle()
        XCTAssertNil(glance.preview)
    }

    func testNoPreviewWhenOpenOrDisabled() {
        let (open, _, answer) = makeController()
        open.replyDidFinish(messageID: answer.id, notchIsOpen: true)
        XCTAssertNil(open.preview)

        let (disabled, _, other) = makeController(previews: false)
        disabled.replyDidFinish(messageID: other.id, notchIsOpen: false)
        XCTAssertNil(disabled.preview)
    }

    func testUnknownMessageShowsNothing() {
        let (glance, _, _) = makeController()
        glance.replyDidFinish(messageID: UUID(), notchIsOpen: false)
        XCTAssertNil(glance.preview)
    }

    func testHoverPausesAndResumesWithTheRemainder() async {
        let (glance, _, answer) = makeController()
        glance.replyDidFinish(messageID: answer.id, notchIsOpen: false)
        await settle()

        clock = clock.addingTimeInterval(1)
        glance.isPreviewHovered = true
        await settle()
        XCTAssertNotNil(glance.preview, "hovering keeps the preview up")

        clock = clock.addingTimeInterval(30)
        glance.isPreviewHovered = false
        await settle()
        XCTAssertEqual(sleeper.requested.last, .seconds(3), "3 s were left when the hover began")
        sleeper.fireAll()
        await settle()
        XCTAssertNil(glance.preview)
    }

    func testResumeKeepsAtLeastTheMinimum() async {
        let (glance, _, answer) = makeController()
        glance.replyDidFinish(messageID: answer.id, notchIsOpen: false)
        await settle()

        clock = clock.addingTimeInterval(3.8)
        glance.isPreviewHovered = true
        await settle()
        glance.isPreviewHovered = false
        await settle()
        XCTAssertEqual(sleeper.requested.last, ReplyPreviewMetrics.resumeMinimum)
    }

    func testHoverBeforeTheDropStartsDefersTheCountdown() async {
        let (glance, _, answer) = makeController()
        glance.isPreviewHovered = true
        glance.replyDidFinish(messageID: answer.id, notchIsOpen: false)
        await settle()
        XCTAssertTrue(sleeper.requested.isEmpty)
        glance.isPreviewHovered = false
        await settle()
        XCTAssertEqual(sleeper.requested, [.seconds(4)])
    }

    func testNotchDidOpenClearsThePreview() async {
        let (glance, _, answer) = makeController()
        glance.replyDidFinish(messageID: answer.id, notchIsOpen: false)
        await settle()
        glance.notchDidOpen()
        XCTAssertNil(glance.preview)
        sleeper.fireAll()
        await settle()
        XCTAssertNil(glance.preview)
    }

    func testANewReplyRestartsTheCountdown() async {
        let (glance, chat, answer) = makeController()
        glance.replyDidFinish(messageID: answer.id, notchIsOpen: false)
        await settle()

        let second = ChatMessage(role: .assistant, text: "Gate B12.", state: .complete)
        chat.debugSeed(messages: chat.messages + [ChatMessage(role: .user, text: "Gate?"), second], isStreaming: false)
        glance.replyDidFinish(messageID: second.id, notchIsOpen: false)
        await settle()
        XCTAssertEqual(glance.preview?.text, "Gate B12.")
        XCTAssertEqual(sleeper.requested, [.seconds(4), .seconds(4)])

        sleeper.fireAll()
        await settle()
        XCTAssertNil(glance.preview)
    }
}
