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
        tailPause: 0.9
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
        pace: 1.4,
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

    static let all = [summarize, friday, screenshot, draft]

    static func conversation(forPrompt prompt: String) -> PromoConversation {
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.prompt.lowercased() == normalized } ?? summarize
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
        let prompt = MockLLMClient.lastUserPrompt(in: request.messages).text
        let conversation = PromoContent.conversation(forPrompt: prompt)
        let chunkInterval = chunkInterval
        let timeScale = timeScale
        let model = request.model.rawValue
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.play(conversation, model: model, chunkInterval: chunkInterval, timeScale: timeScale, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func play(
        _ conversation: PromoConversation,
        model: String,
        chunkInterval: Double,
        timeScale: Double,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
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

        try await pause(0.22)
        try emit(.messageStart(model: model))
        try emit(.thinkingStarted)
        let thoughts = MockLLMClient.wordChunks(conversation.thinking)
        for (index, word) in thoughts.enumerated() {
            try emit(.thinkingDelta(word))
            if index % 4 == 3 { try await pause(0.06) }
        }
        try await pause(conversation.activities.isEmpty ? 0.7 : 0.35)

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

        // Two words per delta, like a real stream's token groups. The closing paragraph (after the
        // last blank line) streams after `tailPause`.
        let answer = conversation.answer
        var parts = [answer]
        if conversation.tailPause > 0, let split = answer.range(of: "\n\n", options: .backwards) {
            parts = [String(answer[..<split.upperBound]), String(answer[split.upperBound...])]
        }
        for (partIndex, part) in parts.enumerated() {
            if partIndex > 0 { try await pause(conversation.tailPause) }
            let words = MockLLMClient.wordChunks(part)
            var index = 0
            while index < words.count {
                let chunk = words[index..<min(index + 2, words.count)].joined()
                try emit(.textDelta(chunk))
                index += 2
                // Linger a touch at line ends so structure lands as it streams.
                let interval = chunkInterval * conversation.pace
                try await pause(chunk.contains("\n") ? interval * 2.5 : interval)
            }
        }

        let result = StreamResult(
            content: [["type": "text", "text": .string(conversation.answer)]],
            stopReason: "end_turn",
            stopDetails: nil,
            model: model,
            usage: ["input_tokens": 1_200, "output_tokens": .int(Int64(conversation.answer.count / 4))]
        )
        try emit(.completed(result))
    }
}

#endif
