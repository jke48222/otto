//
//  PromoScripts.swift
//  Otto
//
//  Content for the promo stage: the attachments dropped into the notch, the conversations it has
//  and a scripted LLM client that streams those replies with the pacing of a real response
//  (thinking, a page read, a web search with sources, then the answer word by word).
//
//  Everything here is fictional and brand-neutral: the article, its site, the sources and the
//  people are made up for the demo. Every web address uses the reserved `.example` top-level
//  domain (RFC 2606), so no real site ever appears in the media.
//

// Debug tooling: compiled only into Debug builds, or into a Release build made with the
// OTTO_TOOLS compilation condition (scripts/make_media.sh does this to record footage).
#if DEBUG || OTTO_TOOLS

import AppKit
import Foundation

// MARK: - Conversations

/// The client tool an action turn calls.
struct PromoToolCall {
    let name: String
    let input: JSONValue
    /// The one line that streams before the call (what Otto says it's about to do).
    let sentence: String
}

/// One scripted exchange: what the user asks and how Otto answers.
struct PromoConversation {
    /// The prompt as typed into the composer. The client matches on it.
    let prompt: String
    let thinking: String
    /// Server tool calls, in order, each with the sources it turns up.
    let activities: [PromoActivity]
    /// The Markdown reply.
    let answer: String
    /// Scales the gap between answer chunks (above 1 streams slower, so the film can be read).
    var pace: Double = 1
    /// A beat (seconds) before the answer's closing paragraph streams, as a real reply sometimes
    /// pauses between its list and its wrap-up. It lets the films tuck the notch away after the
    /// list has landed while the reply is still visibly working.
    var tailPause: Double = 0
    /// An action turn: after thinking, `toolCall.sentence` streams and the response stops for
    /// `tool_use` with this client tool call (the real registry and executor take it from there).
    /// `answer` is then the sentence, so a finished turn reads the same.
    var toolCall: PromoToolCall?
    /// What streams once the tool result comes back (`end_turn`). Action turns only.
    var afterTool: String?
    /// Seconds between thinking and the answer (nil: 0.7 without server tools, 0.35 with them).
    var leadPause: Double?

    struct PromoActivity {
        let kind: ToolActivity.Kind
        let label: String
        /// Seconds the call spends "running" before it completes.
        let duration: Double
        let sources: [SourceLink]
    }

    /// Every activity marked done, every source, in order: the finished message's decorations.
    var finishedActivities: [ToolActivity] {
        activities.enumerated().map { index, activity in
            ToolActivity(id: "srvtoolu_promo_\(index)", kind: activity.kind, label: activity.label, isDone: true)
        }
    }

    var allSources: [SourceLink] {
        var seen = Set<URL>()
        return activities.flatMap(\.sources).filter { seen.insert($0.url).inserted }
    }
}

enum PromoContent {
    // MARK: Sources

    private static func link(_ title: String, _ address: String) -> SourceLink {
        // The addresses are literals, so this only guards against a typo.
        SourceLink(title: title, url: URL(string: address) ?? URL(fileURLWithPath: "/"))
    }

    static let articleURL = URL(string: "https://calm-notes.example/on-calm-software") ?? URL(fileURLWithPath: "/")
    static let articleTitle = "On Calm Software"

    // MARK: Stage clock

    /// The stage's world runs on a fixed future morning: Tuesday 8 October 2030, 9:41 AM in New York
    /// (the menu bar's "Tue 9:41 AM"). The calendar tool and the demo calendar read this clock, so
    /// "tomorrow at 10" is always Wednesday the 9th and misses every seeded demo event. It is in the
    /// future on purpose: an Undo token expires 10 minutes after `stageNow`, checked against the real
    /// clock, so the Undo link stays live on camera. No year is ever shown (`DateInput.display`
    /// omits it). The tool executor stays on the real clock (it times arming with it).
    static let stageZone = TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -4 * 3600) ?? .current
    static let stageLocale = Locale(identifier: "en_US")
    /// 2030-10-08 09:41 EDT (13:41 UTC).
    static let stageNow = Date(timeIntervalSince1970: 1_917_697_260)
    static let stageClock = CalendarToolClock(now: { stageNow }, timeZone: { stageZone }, locale: stageLocale)

    /// `YYYY-MM-DD` of the stage day `offset` days after `stageNow`, in the stage's zone.
    static func stageDay(_ offset: Int) -> String {
        DateInput.isoDay(stageNow.addingTimeInterval(Double(offset) * 86_400), in: stageZone)
    }

    // MARK: Frontmost app

    /// The app the stage is "in": a fictional one, named like the menu bar's frontmost app. The notch
    /// records it instead of the Mac's real frontmost app (`NotchViewModel.debugFrontmostApp`), so no
    /// footage can name or show an app from the machine it was recorded on. It has no bundle, so no
    /// icon, and the stage's insert environment reports it as not running, so no reply ever offers
    /// "Paste into" anything.
    static let studioApp = AppRef(pid: -4_141, bundleID: "example.promo.studio", name: "Studio", bundleURL: nil)

    // MARK: Conversations

    /// The hero exchange: the browser tab the user is reading, summarized, with a web search.
    static let summarize = PromoConversation(
        prompt: "Summarize this in 3 bullets",
        thinking: "They want the gist of the article in their browser. I'll read the page first, then check whether other writers agree before summarizing it in three tight bullets.",
        activities: [
            .init(
                kind: .webFetch,
                label: "Reading calm-notes.example",
                duration: 0.75,
                sources: [link(articleTitle, articleURL.absoluteString)]
            ),
            .init(
                kind: .webSearch,
                label: "Searching \u{201C}calm software design principles\u{201D}",
                duration: 0.95,
                sources: [
                    link("Designing for Attention", "https://quiet-ui.example/designing-for-attention"),
                    link("The Notification Budget", "https://slow-web.example/notification-budget"),
                ]
            ),
        ],
        answer: """
        - **Interruptions are the real cost.** Every ping breaks your focus, and getting back into the work takes far longer than the ping itself.
        - **Batch, don't broadcast.** Fold non-urgent updates into a few calm digests a day instead of a steady drip.
        - **Quiet by default.** Stay out of the way until asked, then step aside.

        Two other design writers make the same case, so it's close to consensus.
        """,
        tailPause: 0.6
    )

    /// The promo film's exchange: three dropped files and the open tab, one question about all of it.
    static let friday = PromoConversation(
        prompt: "What should I fix before Friday?",
        thinking: "Friday is the launch date in launch-plan.md. The screenshot shows the sign-up button stuck disabled, and the invoice is due the same day. I'll check the usual cause of an email field that never validates, then list what's left in order.",
        activities: [
            .init(
                kind: .webSearch,
                label: "Searching \u{201C}email validation trailing space\u{201D}",
                duration: 0.9,
                sources: [
                    link("Forgiving Form Fields", "https://quiet-ui.example/forgiving-form-fields"),
                    link("Trim Before You Validate", "https://slow-web.example/trim-before-you-validate"),
                ]
            ),
        ],
        answer: """
        Three things stand between you and a calm Friday launch:

        - **Fix the sign-up bug.** The email field keeps a trailing space, so **Create Account** never enables. Trim the input before validating:

          ```swift
          let email = input.trimmingCharacters(in: .whitespaces)
          ```

        - **Get the release notes signed off.** Sam's review is the last open item in the launch plan.
        - **Pay invoice #1042.** It's due Friday, the same day you ship.

        Then take the article's advice: one digest to the team on launch day, not a steady drip.
        """,
        pace: 1.25,
        tailPause: 0.7
    )

    /// A screenshot of a sign-up form with a subtle bug.
    static let screenshot = PromoConversation(
        prompt: "What's wrong in this screenshot?",
        thinking: "The form shows a disabled Create Account button while every field looks filled in. The email field has a red border, and there's a stray space before the cursor, so validation is failing on whitespace.",
        activities: [],
        answer: """
        The **Create Account** button is disabled because the email field fails validation: there's a **trailing space** after `.com`, so the address never matches.

        - Trim whitespace before validating, so a pasted address just works.
        - Say *why* the field is invalid, not only that it is.

        ```swift
        let email = input.trimmingCharacters(in: .whitespaces)
        signUpButton.isEnabled = isValidEmail(email)
        ```
        """
    )

    /// A friendly team update drafted from a launch plan.
    static let draft = PromoConversation(
        prompt: "Draft a friendly update for the team",
        thinking: "Pull the three open items from the launch plan and turn them into a short, warm update with owners and dates.",
        activities: [],
        answer: """
        Here's a short update you can paste:

        **Launch is on track for Friday.** Quick status on what's left:

        - **Landing page** is final and live on staging.
        - **Release notes** need one last read from Sam by Thursday noon.
        - **Support replies** are drafted; Priya is testing them today.

        Thanks, everyone. This one's in great shape!
        """
    )

    // MARK: Action turns

    /// Books Sam's review through the real calendar tool: one line, then `calendar_create_event`
    /// (the approval card), then a short confirmation. Dates come from `stageNow`, so the card reads
    /// WED 9, 10:00 – 10:30 AM. The prompt says "schedule", never "add … to my calendar", so it can't
    /// match the demo client's tool phrases.
    static let schedule = PromoConversation(
        prompt: "Schedule Sam's review for tomorrow at 10",
        thinking: "Sam's review is the last open item before Friday. Thirty minutes tomorrow at 10, on the Work calendar.",
        activities: [],
        answer: "I'll add a 30-minute release notes review with Sam for tomorrow at 10.",
        toolCall: PromoToolCall(
            name: "calendar_create_event",
            input: [
                "title": "Release notes review",
                "start": .string("\(stageDay(1))T10:00"),
                "end": .string("\(stageDay(1))T10:30"),
                "calendar": "Work",
            ],
            sentence: "I'll add a 30-minute release notes review with Sam for tomorrow at 10."
        ),
        afterTool: "Done. It's on your Work calendar for Wednesday at 10.",
        leadPause: 0.4
    )

    /// The voice beat's ask: a team update built from what the film has settled (the fix, Sam's review
    /// tomorrow, the invoice). Plain `end_turn`, and no demo client phrase matches it.
    static let launchUpdate = PromoConversation(
        prompt: "Write a quick launch update for the team",
        thinking: "A short update from what's settled: the fix, Sam's review tomorrow and the invoice.",
        activities: [],
        answer: """
        Here's one you can paste:

        **We're on track for Friday.** The sign-up fix ships with the launch, Sam reviews the release notes tomorrow at 10, and invoice #1042 gets paid Friday.

        Thanks, everyone.
        """,
        pace: 1.1,
        leadPause: 0.4
    )

    /// Conversations that end in `end_turn` on their first response.
    static let all = [summarize, friday, screenshot, draft, launchUpdate]
    /// Conversations whose first response stops for a client tool call.
    static let actionTurns = [schedule]

    static func conversation(forPrompt prompt: String) -> PromoConversation {
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (all + actionTurns).first { $0.prompt.lowercased() == normalized } ?? summarize
    }

    // MARK: Voice

    /// What the scripted recognizer "hears" for `launchUpdate`: cumulative partials a word at a time,
    /// a step every 0.14 s (about 1.8 s in all), with level-only steps between words so the waveform
    /// keeps moving. The whole prompt is 40 characters, so the closed pill never head-truncates it.
    static let voiceScript: [(delay: Duration, text: String, level: Float)] = {
        let words = launchUpdate.prompt.split(separator: " ").map(String.init)
        let wordLevels: [Float] = [0.55, 0.7, 0.45, 0.8, 0.6, 0.4, 0.5, 0.75]
        let breathLevels: [Float] = [0.3, 0.42, 0.35, 0.5, 0.32]
        var steps: [(delay: Duration, text: String, level: Float)] = []
        var heard = ""
        for (index, word) in words.enumerated() {
            heard = heard.isEmpty ? word : heard + " " + word
            steps.append((.milliseconds(140), heard, wordLevels[index % wordLevels.count]))
            // A level-only step after most words: the same text, a softer level.
            if index % 3 != 2, index < words.count - 1 {
                steps.append((.milliseconds(140), heard, breathLevels[index % breathLevels.count]))
            }
        }
        return steps
    }()

    // MARK: Fixture files

    /// The five desktop files as real files (the Shelf needs files on disk): the names the desktop icons
    /// show, with small made-up contents. The two images are only a PNG signature, as the snapshot
    /// fixtures do; `PromoShelfThumbnailer` paints every tile, so their bytes are never rendered.
    static let desktopFixtures: [(name: String, contents: Data)] = [
        ("launch-plan.md", Data("# Launch plan\n\n- Landing page: final\n- Release notes: review (Sam)\n".utf8)),
        ("screenshot.png", Data([0x89, 0x50, 0x4E, 0x47])),
        ("invoice.pdf", Data("%PDF-1.4\n%promo\n".utf8)),
        ("release-notes.md", Data("# Release notes\n\n- Sign-up works with pasted addresses\n- Calmer notifications\n".utf8)),
        ("hero-draft.png", Data([0x89, 0x50, 0x4E, 0x47])),
    ]

    /// The two files the shelf-voice take parks on the Shelf (the desktop's last two icons).
    static var shelfFixtures: [(name: String, contents: Data)] { Array(desktopFixtures.suffix(2)) }

    /// Writes `fixtures` into `directory` and returns their URLs, in order.
    static func writeFixtures(_ fixtures: [(name: String, contents: Data)], to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try fixtures.map { fixture in
            let url = directory.appendingPathComponent(fixture.name)
            try fixture.contents.write(to: url, options: .atomic)
            return url
        }
    }

    // MARK: Recents

    /// Six past conversations from the film's world (recents.png), across Today, Yesterday and the
    /// Previous 7 Days relative to `now`. The first is the current conversation.
    static func recentSummaries(currentID: UUID, now: Date) -> [ConversationSummary] {
        let rows: [(title: String, preview: String, question: String, hoursAgo: Double, messages: Int)] = [
            ("What to fix before Friday", "Three things stand between you and a calm Friday launch.",
             friday.prompt, 0.2, 2),
            ("Summarize On Calm Software", "Interruptions are the real cost.",
             summarize.prompt, 1.5, 2),
            ("Why the sign-up button stays disabled", "The email field keeps a trailing space.",
             "Why does Create Account stay disabled?", 20, 4),
            ("Team update for launch day", "Launch is on track for Friday.",
             "Draft a friendly update for the team", 26, 2),
            ("Ideas for the hero image", "A calmer palette and more room for the headline.",
             "How could the hero image feel calmer?", 72, 6),
            ("Invoice #1042 questions", "It's due Friday, the same day you ship.",
             "When is invoice #1042 due?", 120, 2),
        ]
        return rows.enumerated().map { index, row in
            let updated = now.addingTimeInterval(-row.hoursAgo * 3_600)
            return ConversationSummary(
                id: index == 0 ? currentID : UUID(),
                title: row.title,
                preview: row.preview,
                searchText: row.question + "\n" + row.preview,
                createdAt: updated.addingTimeInterval(-600),
                updatedAt: updated,
                messageCount: row.messages,
                attachmentCount: 0,
                model: ModelOption.opus5.rawValue,
                blobs: [:],
                fileBytes: 4_096,
                fileModifiedAt: updated
            )
        }
    }

    // MARK: Attachments

    /// The page the user is reading, offered as the dashed suggestion chip (generic globe icon).
    static func browserTab() -> Attachment {
        AttachmentLoader.makeWebPage(url: articleURL, title: articleTitle, appBundleID: nil)
    }

    static func launchPlan() -> Attachment {
        Attachment(
            kind: .text,
            displayName: "launch-plan.md",
            badge: "MD",
            sourceURL: URL(fileURLWithPath: "/Users/Shared/Promo/launch-plan.md"),
            payload: .text("# Launch plan\n\n- Landing page: final\n- Release notes: review (Sam)\n- Support replies: testing (Priya)"),
            byteCount: 1_840
        )
    }

    static func screenshotImage() -> Attachment {
        Attachment(
            kind: .image,
            displayName: "screenshot.png",
            badge: "PNG",
            sourceURL: URL(fileURLWithPath: "/Users/Shared/Promo/screenshot.png"),
            thumbnail: screenshotThumbnail(),
            payload: .image(mediaType: "image/png", base64: ""),
            byteCount: 412_096
        )
    }

    static func invoice() -> Attachment {
        Attachment(
            kind: .pdf,
            displayName: "invoice.pdf",
            badge: "PDF",
            sourceURL: URL(fileURLWithPath: "/Users/Shared/Promo/invoice.pdf"),
            payload: .pdf(base64: ""),
            byteCount: 96_512
        )
    }

    /// The three files dragged onto the notch in the context scene, in drop order.
    static func droppedFiles() -> [Attachment] {
        [launchPlan(), screenshotImage(), invoice()]
    }

    /// A tiny painting of a light sign-up form with one red-outlined field.
    static func screenshotThumbnail() -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: true) { rect in
            NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1).setFill()
            rect.fill()
            let card = NSRect(x: 10, y: 8, width: 44, height: 48)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: card, xRadius: 4, yRadius: 4).fill()
            let gray = NSColor(srgbRed: 0.82, green: 0.84, blue: 0.87, alpha: 1)
            for (index, y) in [15.0, 25.0, 35.0].enumerated() {
                let field = NSRect(x: 15, y: y, width: 34, height: 6)
                let path = NSBezierPath(roundedRect: field, xRadius: 1.5, yRadius: 1.5)
                if index == 1 {
                    NSColor(srgbRed: 0.93, green: 0.30, blue: 0.27, alpha: 1).setStroke()
                    path.lineWidth = 1.2
                    path.stroke()
                } else {
                    gray.setStroke()
                    path.lineWidth = 0.8
                    path.stroke()
                }
            }
            NSColor(srgbRed: 0.72, green: 0.76, blue: 0.84, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 15, y: 45, width: 34, height: 6), xRadius: 3, yRadius: 3).fill()
            return true
        }
    }

    // MARK: Finished messages (stills)

    /// The finished user + assistant pair for a conversation, as the stills show it.
    static func finishedTurn(_ conversation: PromoConversation, attachments: [Attachment], streamedFraction: Double? = nil) -> [ChatMessage] {
        let user = ChatMessage(
            role: .user,
            text: conversation.prompt,
            attachments: attachments,
            createdAt: Date(timeIntervalSinceReferenceDate: 810_000_000)
        )
        var text = conversation.answer
        var state = MessageState.complete
        if let fraction = streamedFraction {
            let words = MockLLMClient.wordChunks(conversation.answer)
            text = words.prefix(Int(Double(words.count) * fraction)).joined()
            state = .streaming
        }
        let assistant = ChatMessage(
            role: .assistant,
            text: text,
            thinking: conversation.thinking,
            activities: conversation.finishedActivities,
            sources: conversation.allSources,
            state: state,
            model: ModelOption.opus5.rawValue,
            createdAt: Date(timeIntervalSinceReferenceDate: 810_000_004)
        )
        return [user, assistant]
    }
}

// MARK: - Client

/// Streams the promo conversations with deterministic, natural pacing. Used only by the promo
/// stage; `MockLLMClient` stays the general demo/test client.
final class PromoLLMClient: LLMClient, @unchecked Sendable {
    /// Seconds between answer chunks (two words per chunk reads like a fast, real stream).
    private let chunkInterval: Double
    /// Scales every pause (0 ⇒ no delays, for tests).
    private let timeScale: Double

    init(chunkInterval: Double = 0.06, timeScale: Double = 1) {
        self.chunkInterval = chunkInterval
        self.timeScale = max(0, timeScale)
    }

    func stream(_ request: MessagesRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let isToolRound = Self.startsWithToolResults(request.messages)
        let conversation = PromoContent.conversation(forPrompt: Self.lastTypedPrompt(in: request.messages))
        let offeredTools = Set(request.clientTools.compactMap { $0["name"]?.stringValue })
        let chunkInterval = chunkInterval
        let timeScale = timeScale
        let model = request.model.rawValue
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let player = Player(model: model, chunkInterval: chunkInterval, timeScale: timeScale, continuation: continuation)
                    if isToolRound {
                        try await player.playAfterTool(conversation)
                    } else if let call = conversation.toolCall {
                        if offeredTools.contains(call.name) {
                            try await player.playToolCall(conversation, call: call)
                        } else {
                            // As the snapshot client does when the action is turned off.
                            try await player.playText("That action is turned off, so I can't do it from here.", pace: 1, leadPause: 0.22)
                        }
                    } else {
                        try await player.play(conversation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The last user entry starts with `tool_result` blocks: this request continues an action turn.
    static func startsWithToolResults(_ messages: [JSONValue]) -> Bool {
        guard let last = messages.last(where: { $0["role"]?.stringValue == "user" }),
              let blocks = last["content"]?.arrayValue else { return false }
        return blocks.first?.typeName == "tool_result"
    }

    /// The prompt the user typed last: tool-result entries are skipped, and within an entry the last
    /// text block is the typed one (context blocks come first).
    static func lastTypedPrompt(in messages: [JSONValue]) -> String {
        let typed = messages.last { entry in
            guard entry["role"]?.stringValue == "user" else { return false }
            if entry["content"]?.stringValue != nil { return true }
            return entry["content"]?.arrayValue?.first?.typeName != "tool_result"
        }
        guard let typed else { return "" }
        return MockLLMClient.lastUserPrompt(in: [typed]).text
    }

    /// Emits one response's events with promo pacing.
    private struct Player {
        let model: String
        let chunkInterval: Double
        let timeScale: Double
        let continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation

        func emit(_ event: StreamEvent) throws {
            if case .terminated = continuation.yield(event) { throw CancellationError() }
        }

        func pause(_ seconds: Double) async throws {
            let scaled = seconds * timeScale
            if scaled > 0 {
                try await Task.sleep(nanoseconds: UInt64(scaled * 1_000_000_000))
            } else {
                try Task.checkCancellation()
            }
        }

        func think(_ thinking: String) async throws {
            try emit(.thinkingStarted)
            let thoughts = MockLLMClient.wordChunks(thinking)
            for (index, word) in thoughts.enumerated() {
                try emit(.thinkingDelta(word))
                if index % 4 == 3 { try await pause(0.06) }
            }
        }

        /// Two words per delta, like a real stream's token groups, lingering a touch at line ends.
        func stream(_ text: String, pace: Double) async throws {
            let words = MockLLMClient.wordChunks(text)
            var index = 0
            while index < words.count {
                let chunk = words[index..<min(index + 2, words.count)].joined()
                try emit(.textDelta(chunk))
                index += 2
                let interval = chunkInterval * pace
                try await pause(chunk.contains("\n") ? interval * 2.5 : interval)
            }
        }

        func usage(output: Int) -> JSONValue {
            ["input_tokens": 1_200, "output_tokens": .int(Int64(max(1, output)))]
        }

        func complete(text: String) throws {
            let usage = usage(output: text.count / 4)
            try emit(.usage(usage))
            try emit(.completed(StreamResult(
                content: [["type": "text", "text": .string(text)]],
                stopReason: "end_turn",
                stopDetails: nil,
                model: model,
                usage: usage
            )))
        }

        /// Thinking, server tools with their sources, then the answer (`end_turn`).
        func play(_ conversation: PromoConversation) async throws {
            try await pause(0.22)
            try emit(.messageStart(model: model))
            try await think(conversation.thinking)
            try await pause(conversation.leadPause ?? (conversation.activities.isEmpty ? 0.7 : 0.35))

            for (index, activity) in conversation.activities.enumerated() {
                let id = "srvtoolu_promo_\(index)"
                try emit(.toolActivity(ToolActivity(id: id, kind: activity.kind, label: activity.label, isDone: false)))
                try await pause(activity.duration)
                try emit(.toolActivity(ToolActivity(id: id, kind: activity.kind, label: activity.label, isDone: true)))
                if !activity.sources.isEmpty {
                    try emit(.sources(activity.sources))
                }
                try await pause(0.18)
            }

            // The closing paragraph (after the last blank line) streams after `tailPause`.
            let answer = conversation.answer
            var parts = [answer]
            if conversation.tailPause > 0, let split = answer.range(of: "\n\n", options: .backwards) {
                parts = [String(answer[..<split.upperBound]), String(answer[split.upperBound...])]
            }
            for (partIndex, part) in parts.enumerated() {
                if partIndex > 0 { try await pause(conversation.tailPause) }
                try await stream(part, pace: conversation.pace)
            }
            try complete(text: answer)
        }

        /// Thinking, the sentence, then the client tool call; the response stops for `tool_use`.
        /// A port of `SnapshotLLMClient.toolCall` at promo pacing.
        func playToolCall(_ conversation: PromoConversation, call: PromoToolCall) async throws {
            let toolUseID = "toolu_promo_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20).lowercased()
            try await pause(0.22)
            try emit(.messageStart(model: model))
            try await think(conversation.thinking)
            try await pause(conversation.leadPause ?? 0.7)
            try await stream(call.sentence, pace: conversation.pace)
            try emit(.toolUseStarted(id: toolUseID, name: call.name))
            try await pause(0.2)
            let raw = call.input.encodedString()
            try emit(.toolUseReady(id: toolUseID, name: call.name, input: call.input, rawInput: raw))
            let content: [JSONValue] = [
                [
                    "type": "thinking",
                    "thinking": .string(conversation.thinking),
                    "signature": .string("promo-signature"),
                ],
                ["type": "text", "text": .string(call.sentence)],
                ["type": "tool_use", "id": .string(toolUseID), "name": .string(call.name), "input": call.input],
            ]
            let usage = usage(output: (conversation.thinking.count + call.sentence.count + raw.count) / 4)
            try emit(.usage(usage))
            try emit(.completed(StreamResult(content: content, stopReason: "tool_use", stopDetails: nil, model: model, usage: usage)))
        }

        /// After the tool result: a short beat, then the confirmation (`end_turn`).
        func playAfterTool(_ conversation: PromoConversation) async throws {
            try await playText(conversation.afterTool ?? "Done.", pace: conversation.pace, leadPause: 0.22)
        }

        /// Plain text with no thinking (`end_turn`).
        func playText(_ text: String, pace: Double, leadPause: Double) async throws {
            try await pause(leadPause)
            try emit(.messageStart(model: model))
            try await stream(text, pace: pace)
            try complete(text: text)
        }
    }
}

#endif
