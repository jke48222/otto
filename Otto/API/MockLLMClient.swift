//
//  MockLLMClient.swift
//  Otto
//
//  Scripted stand-in for the Messages API, used by `--demo`, snapshots and tests. It replays the
//  same event shapes a real response produces: thinking, a web search with sources, then a Markdown
//  answer streamed word by word, the response's usage, and a final `.completed` carrying matching content
//  blocks. A few exact phrases ("run my shortcut", "add … to my calendar", "run a script") make it call the
//  matching client tool instead, when the request offers it; the next request answers from the tool result.
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
        let inputTokens = estimatedTokens(for: request)
        if let results = leadingToolResults(in: request.messages) {
            return toolAnswerScript(for: results, inputTokens: inputTokens)
        }

        let prompt = lastUserPrompt(in: request.messages)
        let quote = shortened(prompt.text, limit: 80)

        if prompt.text.range(of: #"\brefuse\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let usage = makeUsage(inputTokens: inputTokens, outputTokens: 0)
            let result = StreamResult(
                content: [],
                stopReason: "refusal",
                stopDetails: [
                    "type": "refusal",
                    "category": nil,
                    "explanation": "Demo refusal: the message contained the word \u{201C}refuse\u{201D}.",
                ],
                model: demoModel,
                usage: usage
            )
            return [
                .pause(250...400),
                .emit(.messageStart(model: demoModel)),
                .pause(300...500),
                .emit(.usage(usage)),
                .emit(.completed(result)),
            ]
        }

        let offeredTools = Set(request.clientTools.compactMap { $0["name"]?.stringValue })
        if request.toolChoice?["type"]?.stringValue != "none",
           let tool = scriptedTool(forPrompt: prompt.text), offeredTools.contains(tool.name) {
            return toolCallScript(for: tool, inputTokens: inputTokens)
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
        let usage = makeUsage(inputTokens: inputTokens, outputTokens: outputTokens, webSearches: 1)
        let result = StreamResult(
            content: content,
            stopReason: "end_turn",
            stopDetails: nil,
            model: demoModel,
            usage: usage
        )
        steps.append(.emit(.usage(usage)))
        steps.append(.emit(.completed(result)))
        return steps
    }

    // MARK: - Tool scripting

    /// A client tool the demo calls when the typed prompt contains its phrase.
    struct ScriptedTool {
        let name: String
        /// Case-insensitive regular expression with word boundaries around whole phrases.
        let pattern: String
        /// The one sentence streamed before the call.
        let sentence: String
        /// What the user asked for, for the thinking text.
        let request: String
        let input: JSONValue
    }

    /// The tool the typed `text` asks for, if any. Only these exact phrases match, so ordinary questions ("what's
    /// the keyboard shortcut for…", "my calendar app is slow", "explain JavaScript") never ask for an action.
    static func scriptedTool(forPrompt text: String, now: Date = Date()) -> ScriptedTool? {
        scriptedTools(now: now).first { tool in
            text.range(of: tool.pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func scriptedTools(now: Date) -> [ScriptedTool] {
        let day = tomorrow(after: now)
        return [
            ScriptedTool(
                name: "run_shortcut",
                pattern: #"\brun my shortcut\b"#,
                sentence: "I'll run your **Resize Images** shortcut on your screenshots.",
                request: "run their Resize Images shortcut",
                input: ["name": "Resize Images", "input": "~/Desktop/Screenshots"]
            ),
            ScriptedTool(
                name: "calendar_create_event",
                pattern: #"\badd\b.+\bto my calendar\b"#,
                sentence: "I'll add the dentist to your calendar for tomorrow at 3 PM.",
                request: "add an event to their calendar",
                input: ["title": "Dentist", "start": .string("\(day)T15:00"), "end": .string("\(day)T16:00")]
            ),
            ScriptedTool(
                name: "run_applescript",
                pattern: #"\brun a script\b"#,
                sentence: "I'll run a short script that lists your disks.",
                request: "run a script",
                input: [
                    "script": "tell application \"Finder\" to get name of every disk",
                    "purpose": "List your disks.",
                ]
            ),
        ]
    }

    /// "yyyy-MM-dd" of the day after `date`, in the current time zone.
    private static func tomorrow(after date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let next = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        let components = calendar.dateComponents([.year, .month, .day], from: next)
        return String(format: "%04d-%02d-%02d", components.year ?? 2026, components.month ?? 1, components.day ?? 1)
    }

    /// Thinking, one sentence, then the tool call; the response stops for `tool_use`.
    private static func toolCallScript(for tool: ScriptedTool, inputTokens: Int) -> [Step] {
        let toolUseID = "toolu_demo_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20).lowercased()
        let thinkingParts = [
            "The user wants me to \(tool.request). ",
            "That needs an action on their \(OttoDevice.name), so I'll call the tool and they can approve it.",
        ]
        let thinking = thinkingParts.joined()
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
        steps.append(.pause(150...250))
        for chunk in wordChunks(tool.sentence) {
            steps.append(.emit(.textDelta(chunk)))
            steps.append(.pause(25...45))
        }
        steps += [
            .emit(.toolUseStarted(id: toolUseID, name: tool.name)),
            .pause(150...250),
            .emit(.toolUseReady(id: toolUseID, name: tool.name, input: tool.input, rawInput: tool.input.encodedString())),
        ]
        let content: [JSONValue] = [
            [
                "type": "thinking",
                "thinking": .string(thinking),
                "signature": .string("demo-signature-" + UUID().uuidString),
            ],
            ["type": "text", "text": .string(tool.sentence)],
            ["type": "tool_use", "id": .string(toolUseID), "name": .string(tool.name), "input": tool.input],
        ]
        let usage = makeUsage(inputTokens: inputTokens,
                              outputTokens: (thinking.count + tool.sentence.count + tool.input.encodedString().count) / 4)
        steps.append(.emit(.usage(usage)))
        steps.append(.emit(.completed(StreamResult(content: content, stopReason: "tool_use", stopDetails: nil,
                                                   model: demoModel, usage: usage))))
        return steps
    }

    /// The `tool_result` blocks the last user entry starts with, or nil when it doesn't (a typed message).
    private static func leadingToolResults(in messages: [JSONValue]) -> [JSONValue]? {
        guard let message = messages.last(where: { $0["role"]?.stringValue == "user" }),
              let blocks = message["content"]?.arrayValue,
              blocks.first?.typeName == "tool_result" else { return nil }
        return blocks.filter { $0.typeName == "tool_result" }
    }

    /// A short answer after a tool round: it says what was added, quotes the first result, or says the user declined.
    private static func toolAnswerScript(for results: [JSONValue], inputTokens: Int) -> [Step] {
        let resultText = results.first?["content"]?.arrayValue?
            .first(where: { $0.typeName == "text" })?["text"]?.stringValue ?? ""
        let answer: String
        if resultText.hasPrefix("declined:") {
            answer = "You declined, so I left things as they are."
        } else if let added = addedItemAnswer(resultText) {
            answer = added
        } else {
            answer = "Done. It reported: \u{201C}\(shortened(resultText, limit: 300))\u{201D}"
        }
        var steps: [Step] = [
            .pause(250...400),
            .emit(.messageStart(model: demoModel)),
            .pause(150...250),
        ]
        for chunk in wordChunks(answer) {
            steps.append(.emit(.textDelta(chunk)))
            steps.append(.pause(25...45))
        }
        let usage = makeUsage(inputTokens: inputTokens, outputTokens: answer.count / 4)
        steps.append(.emit(.usage(usage)))
        steps.append(.emit(.completed(StreamResult(content: [["type": "text", "text": .string(answer)]],
                                                   stopReason: "end_turn", stopDetails: nil, model: demoModel,
                                                   usage: usage))))
        return steps
    }

    /// "Done. “Dentist” is on your Home calendar." for an event or reminder a tool created; nil for other results.
    private static func addedItemAnswer(_ resultText: String) -> String? {
        guard let result = try? JSONValue.decode(resultText), result["status"]?.stringValue == "created",
              let title = result["title"]?.stringValue, !title.isEmpty else { return nil }
        let quoted = "\u{201C}\(shortened(title, limit: 80))\u{201D}"
        if let calendar = result["calendar"]?.stringValue, !calendar.isEmpty {
            return "Done. \(quoted) is on your \(calendar) calendar."
        }
        if let list = result["list"]?.stringValue, !list.isEmpty {
            return "Done. \(quoted) is on your \(list) list."
        }
        return "Done. I added \(quoted)."
    }

    /// Usage shaped like the API's: token counts, cache fields and, after a search, server-tool use.
    private static func makeUsage(inputTokens: Int, outputTokens: Int, webSearches: Int = 0) -> JSONValue {
        var usage: [String: JSONValue] = [
            "input_tokens": .int(Int64(inputTokens)),
            "output_tokens": .int(Int64(outputTokens)),
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
        ]
        if webSearches > 0 {
            usage["server_tool_use"] = ["web_search_requests": .int(Int64(webSearches))]
        }
        return .object(usage)
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

    /// The demo reply's last "with an API key" bullet.
    #if os(macOS)
    private static let streamingBullet = "Answers streamed straight into the notch"
    #else
    private static let streamingBullet = "Answers that keep streaming in the Dynamic Island when you leave"
    #endif

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
        - \(streamingBullet)

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
