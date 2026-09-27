//
//  MockLLMClient.swift
//  Otto
//
//  Scripted stand-in for the Messages API, used by `--demo`, snapshots and tests. It replays the
//  same event shapes a real response produces: thinking, a web search with sources, then a Markdown
//  answer streamed word by word, and a final `.completed` carrying matching content blocks.
//

import Foundation

final class MockLLMClient: LLMClient, @unchecked Sendable {
    static let demoModel = "claude-opus-5 (demo)"

    /// 0 => no delays (tests/snapshots).
    private let latencyScale: Double

    init(latencyScale: Double = 1.0) {
        self.latencyScale = latencyScale.isFinite ? max(0, latencyScale) : 1.0
    }

    func stream(_ request: MessagesRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let script = Self.makeScript(for: request)
        let latencyScale = latencyScale
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.play(script, scale: latencyScale, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Script

    enum Step {
        /// Pause for a random duration in this range of milliseconds (scaled by latencyScale).
        case pause(ClosedRange<Double>)
        case emit(StreamEvent)
    }

    static func makeScript(for request: MessagesRequest) -> [Step] {
        let prompt = lastUserPrompt(in: request.messages)
        let quote = shortened(prompt.text, limit: 80)
        let inputTokens = estimatedTokens(for: request)

        if prompt.text.range(of: #"\brefuse\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let result = StreamResult(
                content: [],
                stopReason: "refusal",
                stopDetails: [
                    "type": "refusal",
                    "category": nil,
                    "explanation": "Demo refusal: the message contained the word \u{201C}refuse\u{201D}.",
                ],
                model: demoModel,
                usage: ["input_tokens": .int(Int64(inputTokens)), "output_tokens": 0]
            )
            return [
                .pause(250...400),
                .emit(.messageStart(model: demoModel)),
                .pause(300...500),
                .emit(.completed(result)),
            ]
        }

        let toolUseID = "srvtoolu_demo_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20).lowercased()
        let query = quote.isEmpty ? "Otto demo" : shortened(prompt.text, limit: 60)
        let thinkingParts = makeThinking(quote: quote, attachmentCount: prompt.attachmentCount)
        let thinking = thinkingParts.joined()
        let answer = makeAnswer(quote: quote, attachmentCount: prompt.attachmentCount)
        let activity = ToolActivity(id: toolUseID, kind: .webSearch, label: "Searching \u{201C}\(query)\u{201D}", isDone: false)
        var finishedActivity = activity
        finishedActivity.isDone = true

        var steps: [Step] = [
            .pause(250...400),
            .emit(.messageStart(model: demoModel)),
            .pause(80...140),
            .emit(.thinkingStarted),
        ]
        for part in thinkingParts {
            steps.append(.pause(120...220))
            steps.append(.emit(.thinkingDelta(part)))
        }
        steps += [
            .pause(150...250),
            .emit(.toolActivity(activity)),
            .pause(500...800),
            .emit(.toolActivity(finishedActivity)),
            .emit(.sources(demoSources)),
            .pause(150...250),
        ]
        for chunk in wordChunks(answer) {
            steps.append(.emit(.textDelta(chunk)))
            steps.append(.pause(25...45))
        }

        let content: [JSONValue] = [
            [
                "type": "thinking",
                "thinking": .string(thinking),
                "signature": .string("demo-signature-" + UUID().uuidString),
            ],
            [
                "type": "server_tool_use",
                "id": .string(toolUseID),
                "name": "web_search",
                "input": ["query": .string(query)],
            ],
            [
                "type": "web_search_tool_result",
                "tool_use_id": .string(toolUseID),
                "content": .array(demoSources.map { source in
                    [
                        "type": "web_search_result",
                        "title": .string(source.title),
                        "url": .string(source.url.absoluteString),
                        "encrypted_content": "demo",
                        "page_age": nil,
                    ]
                }),
            ],
            ["type": "text", "text": .string(answer)],
        ]
        let outputTokens = (thinking.count + answer.count) / 4
        let result = StreamResult(
            content: content,
            stopReason: "end_turn",
            stopDetails: nil,
            model: demoModel,
            usage: [
                "input_tokens": .int(Int64(inputTokens)),
                "output_tokens": .int(Int64(outputTokens)),
                "server_tool_use": ["web_search_requests": 1],
            ]
        )
        steps.append(.emit(.completed(result)))
        return steps
    }

    private static func play(
        _ script: [Step],
        scale: Double,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        for step in script {
            try Task.checkCancellation()
            switch step {
            case .pause(let milliseconds):
                let duration = Double.random(in: milliseconds) * scale
                if duration > 0 {
                    try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000))
                }
            case .emit(let event):
                if case .terminated = continuation.yield(event) {
                    throw CancellationError()
                }
            }
        }
    }

    // MARK: - Content

    private static let demoSources: [SourceLink] = [
        SourceLink(title: "Swift.org - Documentation", url: URL(string: "https://www.swift.org/documentation/")!),
        SourceLink(title: "SwiftUI | Apple Developer Documentation", url: URL(string: "https://developer.apple.com/documentation/swiftui")!),
    ]

    private static func makeThinking(quote: String, attachmentCount: Int) -> [String] {
        let subject = quote.isEmpty ? "a quick demo" : "\u{201C}\(quote)\u{201D}"
        let attachments = attachmentCount == 0
            ? "There's nothing attached, so the message itself is all the context."
            : "They attached \(attachmentPhrase(attachmentCount)), which I should acknowledge."
        return [
            "The user is asking about \(subject). ",
            "\(attachments) ",
            "A quick web search for references first, then a concise answer with a short list and a code sample.",
        ]
    }

    private static func makeAnswer(quote: String, attachmentCount: Int) -> String {
        let opening = quote.isEmpty
            ? "Here's a demo reply"
            : "Here's a demo reply to \u{201C}\(quote)\u{201D}"
        let attachmentNote = attachmentCount == 0
            ? "with no attachments in context."
            : "with \(attachmentPhrase(attachmentCount)) in context."
        return """
        \(opening), \(attachmentNote)

        Otto is running in **demo mode**, so this answer comes from a scripted client instead of Claude. \
        With an API key you'd get:

        - **Summarized thinking** you can expand above the reply
        - **Web search and fetch** results, listed as sources
        - Answers streamed straight into the notch

        A small SwiftUI view, to show how code renders:

        ```swift
        struct Greeting: View {
            var body: some View {
                Text("Hello from Otto")
                    .font(.system(.title3, design: .serif))
            }
        }
        ```

        Add your Anthropic API key in Settings to chat with Claude for real.
        """
    }

    private static func attachmentPhrase(_ count: Int) -> String {
        count == 1 ? "1 attachment" : "\(count) attachments"
    }

    /// The typed text (the last `text` block) and the number of image/document blocks of the most
    /// recent user message.
    static func lastUserPrompt(in messages: [JSONValue]) -> (text: String, attachmentCount: Int) {
        guard let message = messages.last(where: { $0["role"]?.stringValue == "user" }) else { return ("", 0) }
        if let text = message["content"]?.stringValue {
            return (text, 0)
        }
        let blocks = message["content"]?.arrayValue ?? []
        let attachmentCount = blocks.filter { $0.typeName == "image" || $0.typeName == "document" }.count
        let text = blocks.last(where: { $0.typeName == "text" })?["text"]?.stringValue ?? ""
        return (text, attachmentCount)
    }

    /// Splits text into word-sized chunks, each carrying its trailing whitespace; joined they
    /// reproduce the input exactly.
    static func wordChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var inTrailingWhitespace = false
        for character in text {
            if character.isWhitespace {
                inTrailingWhitespace = true
            } else if inTrailingWhitespace {
                chunks.append(current)
                current = ""
                inTrailingWhitespace = false
            }
            current.append(character)
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private static func shortened(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    private static func estimatedTokens(for request: MessagesRequest) -> Int {
        let bytes = request.system.utf8.count + request.messages.reduce(0) { $0 + $1.encodedString().utf8.count }
        return max(1, bytes / 4)
    }
}
