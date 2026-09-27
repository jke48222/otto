//
//  ChatSessionTests.swift
//  Otto
//
//  ChatSession history/streaming behaviour and its transcript, phase and usage reporting, plus the
//  SystemPrompt and AppSettings state it reads.
//

import XCTest
@testable import Otto

// MARK: - Fixtures

private func textBlock(_ text: String) -> JSONValue {
    ["type": "text", "text": .string(text)]
}

private func thinkingBlock(_ text: String, signature: String = "sig") -> JSONValue {
    ["type": "thinking", "thinking": .string(text), "signature": .string(signature)]
}

private func serverToolUse(id: String, name: String = "web_search", query: String = "swift") -> JSONValue {
    ["type": "server_tool_use", "id": .string(id), "name": .string(name), "input": ["query": .string(query)]]
}

private func searchResult(for id: String) -> JSONValue {
    [
        "type": "web_search_tool_result",
        "tool_use_id": .string(id),
        "content": [["type": "web_search_result", "title": "Swift", "url": "https://swift.org"]],
    ]
}

private func codeExecutionResult(for id: String) -> JSONValue {
    [
        "type": "code_execution_tool_result",
        "tool_use_id": .string(id),
        "content": ["type": "code_execution_result", "stdout": "1\n", "stderr": "", "return_code": 0],
    ]
}

/// A web search issued from inside a dynamic-filtering code_execution call.
private func nestedSearch(id: String, caller: String) -> JSONValue {
    serverToolUse(id: id).setting("caller", to: ["type": "code_execution_20260120", "tool_id": .string(caller)])
}

private let fallbackBlock: JSONValue = [
    "type": "fallback",
    "from": ["model": "claude-opus-5"],
    "to": ["model": "claude-sonnet-5"],
]

private func completed(_ content: [JSONValue], stopReason: String? = "end_turn") -> StreamEvent {
    .completed(StreamResult(content: content, stopReason: stopReason, stopDetails: nil, model: "claude-opus-5", usage: nil))
}

/// A complete one-text-block reply.
private func reply(_ text: String, stopReason: String? = "end_turn") -> ScriptedLLMClient.Response {
    .events([.messageStart(model: "claude-opus-5"), .textDelta(text), completed([textBlock(text)], stopReason: stopReason)])
}

private func entry(_ role: String, _ content: [JSONValue]) -> JSONValue {
    ["role": .string(role), "content": .array(content)]
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

/// A completed response that reports `usage`.
private func completed(_ content: [JSONValue], stopReason: String?, usage: JSONValue?) -> StreamEvent {
    .completed(StreamResult(content: content, stopReason: stopReason, stopDetails: nil, model: "claude-opus-5", usage: usage))
}

private func usage(output: Int64) -> JSONValue {
    ["input_tokens": 1_200, "output_tokens": .int(output)]
}

/// What ChatSession reported to its observers, in order.
private enum SessionEvent: Equatable {
    case transcript(TranscriptChange)
    case replyFinished
}

/// Set from observation callbacks (which may not mutate captured locals).
private final class FlagBox {
    var isSet = false
}

/// An LLMClient whose single open response is fed one event at a time by the test. The session asks for
/// the next event only after it has applied the previous one, so `isAwaitingEvent` tells the test that
/// everything pushed so far has landed.
private final class SteppedLLMClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [StreamEvent] = []
    private var pulls = 0
    private var delivered = 0

    /// The session is waiting inside the stream and nothing it hasn't taken is queued.
    var isAwaitingEvent: Bool {
        lock.withLock { queue.isEmpty && pulls > delivered }
    }

    func push(_ event: StreamEvent) {
        lock.withLock { queue.append(event) }
    }

    func stream(_ request: MessagesRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream(unfolding: { [self] in
            lock.withLock { pulls += 1 }
            while true {
                let next: StreamEvent? = lock.withLock {
                    guard !queue.isEmpty else { return nil }
                    delivered += 1
                    return queue.removeFirst()
                }
                if let next { return next }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        })
    }
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

// MARK: - ChatSession

@MainActor
final class ChatSessionTests: XCTestCase {
    private func makeSession(
        _ client: ScriptedLLMClient,
        settings: AppSettings? = nil
    ) -> (ChatSession, AppSettings) {
        let settings = settings ?? makeSettings()
        let chat = ChatSession(settings: settings, makeClient: { client })
        return (chat, settings)
    }

    // MARK: Sending

    func testSendBuildsUserBlocksWithAttachmentsFirst() async {
        let client = ScriptedLLMClient([reply("Sure.")])
        let (chat, settings) = makeSession(client)
        let notes = textAttachment("notes.txt", "remember the milk")
        let page = webAttachment("https://techcrunch.com/story", title: "TechCrunch")

        chat.send(text: "  What is this?\n", attachments: [notes, page])

        XCTAssertTrue(chat.isStreaming)
        XCTAssertEqual(chat.messages.count, 2)
        let user = chat.messages[0]
        XCTAssertEqual(user.role, .user)
        XCTAssertEqual(user.text, "What is this?")
        XCTAssertEqual(user.attachments, [notes, page])
        XCTAssertEqual(user.apiContent, notes.contentBlocks() + page.contentBlocks() + [textBlock("What is this?")])
        XCTAssertEqual(chat.messages[1].role, .assistant)
        XCTAssertEqual(chat.messages[1].state, .streaming)

        await waitForReply(chat)

        XCTAssertEqual(client.requests.count, 1)
        let request = client.requests[0]
        XCTAssertEqual(request.messages, [entry("user", user.apiContent)])
        XCTAssertEqual(request.model, settings.model)
        XCTAssertEqual(request.maxTokens, settings.model.maxOutputTokens)
        XCTAssertEqual(request.effort, settings.effort)
        XCTAssertEqual(request.webAccess, settings.webAccess)
        XCTAssertTrue(request.system.hasPrefix("You are Otto"))
        XCTAssertTrue(request.system.contains("Today's date is"))
    }

    func testAttachmentsOnlySendsPlaceholderPrompt() async {
        let client = ScriptedLLMClient([reply("Looks like a note.")])
        let (chat, _) = makeSession(client)
        let notes = textAttachment("notes.txt")

        chat.send(text: "   ", attachments: [notes])
        await waitForReply(chat)

        XCTAssertEqual(chat.messages[0].text, "")
        XCTAssertEqual(chat.messages[0].apiContent, notes.contentBlocks() + [textBlock(ChatSession.attachmentsOnlyPrompt)])
    }

    func testSendIgnoresBlankInputAndWhileStreaming() async {
        let client = ScriptedLLMClient([.stall([.messageStart(model: "claude-opus-5")])])
        let (chat, _) = makeSession(client)

        chat.send(text: " \n ", attachments: [])
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertFalse(chat.isStreaming)

        chat.send(text: "First", attachments: [])
        chat.send(text: "Second", attachments: [])
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages[0].text, "First")
        chat.cancel()
    }

    // MARK: Streaming

    func testStreamFoldsIntoAssistantMessage() async {
        let swiftOrg = SourceLink(title: "Swift", url: URL(fileURLWithPath: "/swift"))
        let docs = SourceLink(title: "Docs", url: URL(fileURLWithPath: "/docs"))
        let forums = SourceLink(title: "Forums", url: URL(fileURLWithPath: "/forums"))
        let content: [JSONValue] = [
            thinkingBlock("Let me check."),
            serverToolUse(id: "srvtoolu_1"),
            searchResult(for: "srvtoolu_1"),
            textBlock("Hello, world"),
        ]
        let client = ScriptedLLMClient([
            .events([
                .messageStart(model: "claude-opus-5"),
                .thinkingStarted,
                .thinkingDelta("Let me "),
                .thinkingDelta("check."),
                .toolActivity(ToolActivity(id: "srvtoolu_1", kind: .webSearch, label: "Searching “swift”", isDone: false)),
                .toolActivity(ToolActivity(id: "srvtoolu_1", kind: .webSearch, label: "Searching “swift”", isDone: true)),
                .sources([swiftOrg, docs]),
                .sources([swiftOrg, forums, forums]),
                .textDelta("Hello"),
                .textDelta(", world"),
                completed(content),
            ]),
        ])
        let (chat, _) = makeSession(client)
        var finishedCount = 0
        chat.onReplyFinished = { finishedCount += 1 }

        chat.send(text: "Hi", attachments: [])
        await waitForReply(chat)

        let assistant = chat.messages[1]
        XCTAssertEqual(assistant.state, .complete)
        XCTAssertEqual(assistant.model, "claude-opus-5")
        XCTAssertEqual(assistant.thinking, "Let me check.")
        XCTAssertFalse(assistant.isThinking)
        XCTAssertEqual(assistant.text, "Hello, world")
        XCTAssertEqual(assistant.activities, [
            ToolActivity(id: "srvtoolu_1", kind: .webSearch, label: "Searching “swift”", isDone: true),
        ])
        XCTAssertEqual(assistant.sources, [swiftOrg, docs, forums])
        XCTAssertEqual(assistant.apiContent, content)
        XCTAssertTrue(assistant.includeInContext)
        XCTAssertFalse(chat.isStreaming)
        XCTAssertEqual(finishedCount, 1)
        XCTAssertEqual(chat.lastAssistantText, "Hello, world")
    }

    func testThinkingFlagStaysOnUntilFirstText() async {
        let client = ScriptedLLMClient([
            .stall([.messageStart(model: "claude-opus-5"), .thinkingStarted, .thinkingDelta("Hmm")]),
        ])
        let (chat, _) = makeSession(client)

        chat.send(text: "Think", attachments: [])
        await waitUntil { chat.messages.last?.thinking == "Hmm" }
        XCTAssertEqual(chat.messages.last?.isThinking, true)

        chat.cancel()
        XCTAssertEqual(chat.messages.last?.isThinking, false)
    }

    func testFallbackEventUpdatesModel() async {
        let client = ScriptedLLMClient([
            .events([
                .messageStart(model: "claude-opus-5"),
                .fallback(fromModel: "claude-opus-5", toModel: "claude-sonnet-5"),
                .textDelta("Answer"),
                completed([fallbackBlock, textBlock("Answer")]),
            ]),
        ])
        let (chat, _) = makeSession(client)

        chat.send(text: "Hi", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(chat.messages[1].model, "claude-sonnet-5")
        XCTAssertEqual(chat.messages[1].state, .complete)
    }

    func testMockClientCompletesATurn() async {
        let settings = makeSettings()
        let chat = ChatSession(settings: settings, makeClient: { MockLLMClient(latencyScale: 0) })

        chat.send(text: "Hello there", attachments: [textAttachment("notes.txt")])
        await waitForReply(chat)

        let assistant = chat.messages[1]
        XCTAssertEqual(assistant.state, .complete)
        XCTAssertFalse(assistant.text.isEmpty)
        XCTAssertFalse(assistant.isThinking)
        XCTAssertNotNil(assistant.model)
        XCTAssertTrue(assistant.apiContent.contains { $0.typeName == "text" })
    }

    func testMockClientRefusal() async {
        let settings = makeSettings()
        let chat = ChatSession(settings: settings, makeClient: { MockLLMClient(latencyScale: 0) })

        chat.send(text: "Please refuse this one", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(chat.messages[1].state, .refused(ChatSession.refusalMessage))
        XCTAssertFalse(chat.messages[0].includeInContext)
        XCTAssertFalse(chat.messages[1].includeInContext)
    }

    // MARK: Stop reasons

    func testRefusalExcludesBothTurnsFromHistory() async {
        let client = ScriptedLLMClient([
            .events([.messageStart(model: "claude-opus-5"), completed([], stopReason: "refusal")]),
            reply("Happy to help."),
        ])
        let (chat, _) = makeSession(client)

        chat.send(text: "Something bad", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(chat.messages[1].state, .refused(ChatSession.refusalMessage))
        XCTAssertFalse(chat.messages[0].includeInContext)
        XCTAssertFalse(chat.messages[1].includeInContext)

        chat.send(text: "Something fine", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(client.requests[1].messages, [entry("user", [textBlock("Something fine")])])
    }

    func testMidStreamRefusalDiscardsPartialOutput() async {
        let client = ScriptedLLMClient([
            .events([
                .messageStart(model: "claude-opus-5"),
                .thinkingStarted,
                .thinkingDelta("Considering"),
                .textDelta("Here are several paragraphs"),
                .sources([SourceLink(title: "Swift", url: URL(fileURLWithPath: "/tmp/source"))]),
                completed([textBlock("Here are several paragraphs")], stopReason: "refusal"),
            ]),
        ])
        let (chat, _) = makeSession(client)

        chat.send(text: "Question", attachments: [])
        await waitForReply(chat)

        let assistant = chat.messages[1]
        XCTAssertEqual(assistant.state, .refused(ChatSession.refusalMessage))
        XCTAssertEqual(assistant.text, "")
        XCTAssertEqual(assistant.thinking, "")
        XCTAssertTrue(assistant.sources.isEmpty)
        XCTAssertTrue(assistant.apiContent.isEmpty)
        XCTAssertNil(chat.lastAssistantText)
    }

    func testPauseTurnResumesWithPartialAssistantContent() async {
        let firstContent: [JSONValue] = [
            textBlock("Searching. "),
            serverToolUse(id: "srvtoolu_1"),
            searchResult(for: "srvtoolu_1"),
        ]
        let secondContent: [JSONValue] = [textBlock("Done.")]
        let client = ScriptedLLMClient([
            .events([
                .messageStart(model: "claude-opus-5"),
                .textDelta("Searching. "),
                completed(firstContent, stopReason: "pause_turn"),
            ]),
            .events([
                .messageStart(model: "claude-opus-5"),
                .textDelta("Done."),
                completed(secondContent),
            ]),
        ])
        let (chat, _) = makeSession(client)

        chat.send(text: "Look it up", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(client.requests[0].messages, [entry("user", [textBlock("Look it up")])])
        // The continuation replays the partial assistant turn last, with no new user message.
        XCTAssertEqual(client.requests[1].messages, [
            entry("user", [textBlock("Look it up")]),
            entry("assistant", firstContent),
        ])

        XCTAssertEqual(chat.messages.count, 2)
        let assistant = chat.messages[1]
        XCTAssertEqual(assistant.state, .complete)
        XCTAssertEqual(assistant.text, "Searching. Done.")
        XCTAssertEqual(assistant.apiContent, firstContent + secondContent)
    }

    func testPauseTurnTrimsTrailingWhitespaceOfResumedText() async {
        let client = ScriptedLLMClient([
            .events([.textDelta("Working on it.\n\n"), completed([textBlock("Working on it.\n\n")], stopReason: "pause_turn")]),
            reply("Finished."),
        ])
        let (chat, _) = makeSession(client)

        chat.send(text: "Go", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(client.requests[1].messages.last, entry("assistant", [textBlock("Working on it.")]))
    }

    func testPauseTurnGivesUpAfterFiveContinuations() async {
        let paused = ScriptedLLMClient.Response.events([completed([textBlock("step")], stopReason: "pause_turn")])
        let client = ScriptedLLMClient(Array(repeating: paused, count: 1 + ChatSession.maxPauseContinuations))
        let (chat, _) = makeSession(client)

        chat.send(text: "Long task", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(client.requests.count, 1 + ChatSession.maxPauseContinuations)
        XCTAssertEqual(chat.messages[1].state, .complete)
        XCTAssertEqual(chat.messages[1].apiContent.count, 1 + ChatSession.maxPauseContinuations)
        XCTAssertTrue(chat.messages[1].text.hasSuffix(ChatSession.pauseLimitNote))
    }

    func testPauseTurnResumesPendingDynamicFilteringCallVerbatim() async {
        let paused: [JSONValue] = [
            thinkingBlock("plan"),
            serverToolUse(id: "srvtoolu_1"),
            searchResult(for: "srvtoolu_1"),
            textBlock("Let me filter these."),
            serverToolUse(id: "srvtoolu_c", name: "code_execution", query: "filter"),
        ]
        let client = ScriptedLLMClient([
            .events([.textDelta("Let me filter these."), completed(paused, stopReason: "pause_turn")]),
            reply("Filtered."),
        ])
        let (chat, _) = makeSession(client)

        chat.send(text: "Research this", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(client.requests.count, 2)
        // The paused response goes back as it came, ending in the pending code_execution call.
        XCTAssertEqual(client.requests[1].messages.last, entry("assistant", paused))
        XCTAssertEqual(chat.messages[1].state, .complete)
    }

    func testPauseTurnWithOnlyAPendingCodeExecutionCallResumes() async {
        let paused: [JSONValue] = [serverToolUse(id: "srvtoolu_c", name: "code_execution", query: "filter")]
        let client = ScriptedLLMClient([
            .events([completed(paused, stopReason: "pause_turn")]),
            reply("Done."),
        ])
        let (chat, _) = makeSession(client)

        chat.send(text: "Go", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(client.requests[1].messages.last, entry("assistant", paused))
        XCTAssertEqual(chat.messages[1].state, .complete)
        XCTAssertEqual(chat.messages[1].text, "Done.")
    }

    func testDynamicFilteringBlocksFollowTheToolSet() {
        let content: [JSONValue] = [
            serverToolUse(id: "srvtoolu_c", name: "code_execution", query: "filter"),
            codeExecutionResult(for: "srvtoolu_c"),
            nestedSearch(id: "srvtoolu_s", caller: "srvtoolu_c"),
            searchResult(for: "srvtoolu_s"),
            serverToolUse(id: "srvtoolu_top"),
            searchResult(for: "srvtoolu_top"),
            textBlock("Answer"),
        ]
        let message = ChatMessage(role: .assistant, text: "Answer", apiContent: content)

        // Same tool set: everything is echoed.
        let opusTools = ChatSession.serverToolNames(model: .opus5, webAccess: true)
        XCTAssertEqual(opusTools, ["web_search", "web_fetch", "code_execution"])
        XCTAssertEqual(ChatSession.contextContent(forAssistant: message, enabledServerTools: opusTools), content)

        // Haiku has no dynamic filtering: the code_execution pair goes, and so does the search it issued.
        let haikuTools = ChatSession.serverToolNames(model: .haiku45, webAccess: true)
        XCTAssertEqual(ChatSession.contextContent(forAssistant: message, enabledServerTools: haikuTools), [
            serverToolUse(id: "srvtoolu_top"),
            searchResult(for: "srvtoolu_top"),
            textBlock("Answer"),
        ])

        // Web access off: only the text is left.
        XCTAssertEqual(ChatSession.contextContent(forAssistant: message, enabledServerTools: []), [textBlock("Answer")])
    }

    func testMaxTokensMarksReplyTruncated() async {
        let client = ScriptedLLMClient([reply("A very long", stopReason: "max_tokens")])
        let (chat, _) = makeSession(client)

        chat.send(text: "Write a novel", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(chat.messages[1].state, .complete)
        XCTAssertEqual(chat.messages[1].text, "A very long" + ChatSession.truncationNote)
        XCTAssertEqual(chat.messages[1].apiContent, [textBlock("A very long")])
    }

    // MARK: Sanitization

    func testFallbackSanitization() {
        let content: [JSONValue] = [
            thinkingBlock("first model"),
            serverToolUse(id: "srvtoolu_1"),
            searchResult(for: "srvtoolu_1"),
            textBlock("Partial "),
            fallbackBlock,
            thinkingBlock("second model"),
            textBlock(""),
            textBlock(" \n "),
            textBlock("Final answer"),
        ]
        // Text and complete server-tool pairs from the replaced model are echoed (the text's citations
        // point into the results); its thinking is not.
        XCTAssertEqual(ChatSession.sanitizedAssistantContent(content), [
            serverToolUse(id: "srvtoolu_1"),
            searchResult(for: "srvtoolu_1"),
            textBlock("Partial "),
            thinkingBlock("second model"),
            textBlock("Final answer"),
        ])

        // Before the boundary, unpaired calls, client tool_use and redacted thinking go too.
        let mixed: [JSONValue] = [
            ["type": "redacted_thinking", "data": "abc"],
            serverToolUse(id: "srvtoolu_pending"),
            ["type": "tool_use", "id": "toolu_1", "name": "calc", "input": [:]],
            textBlock("Cited"),
            fallbackBlock,
            textBlock("After"),
        ]
        XCTAssertEqual(ChatSession.sanitizedAssistantContent(mixed), [textBlock("Cited"), textBlock("After")])

        // Only the last fallback marks the boundary.
        let twice: [JSONValue] = [
            thinkingBlock("a"), fallbackBlock, thinkingBlock("b"), textBlock("x"), fallbackBlock, textBlock("y"),
        ]
        XCTAssertEqual(ChatSession.sanitizedAssistantContent(twice), [textBlock("x"), textBlock("y")])

        // Without a fallback only empty text blocks go.
        let plain: [JSONValue] = [thinkingBlock("t"), textBlock(""), textBlock("ok")]
        XCTAssertEqual(ChatSession.sanitizedAssistantContent(plain), [thinkingBlock("t"), textBlock("ok")])
    }

    func testHistoryUsesSanitizedAssistantContent() async {
        let client = ScriptedLLMClient([reply("Sure.")])
        let (chat, _) = makeSession(client)
        chat.debugSeed(messages: [
            ChatMessage(role: .user, text: "Q1", apiContent: [textBlock("Q1")]),
            ChatMessage(role: .assistant, text: "A1", apiContent: [
                thinkingBlock("refused thought"), fallbackBlock, thinkingBlock("kept"), textBlock(""), textBlock("A1"),
            ]),
            ChatMessage(role: .user, text: "Q2", apiContent: [textBlock("Q2")]),
            // Sanitizes to nothing, so the turn is skipped entirely.
            ChatMessage(role: .assistant, apiContent: [textBlock(""), textBlock("  ")]),
        ], isStreaming: false)

        chat.send(text: "Q3", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(client.requests[0].messages, [
            entry("user", [textBlock("Q1")]),
            entry("assistant", [thinkingBlock("kept"), textBlock("A1")]),
            entry("user", [textBlock("Q2")]),
            entry("user", [textBlock("Q3")]),
        ])
    }

    func testWebToolBlocksAreDroppedWhenWebAccessIsOff() async {
        let client = ScriptedLLMClient([reply("Sure.")])
        let (chat, settings) = makeSession(client)
        settings.webAccess = false
        chat.debugSeed(messages: [
            ChatMessage(role: .user, text: "Q1", apiContent: [textBlock("Q1")]),
            ChatMessage(role: .assistant, text: "A1", apiContent: [
                serverToolUse(id: "srvtoolu_1"), searchResult(for: "srvtoolu_1"), textBlock("A1"),
            ]),
        ], isStreaming: false)

        chat.send(text: "Q2", attachments: [])
        await waitForReply(chat)

        XCTAssertFalse(client.requests[0].webAccess)
        XCTAssertEqual(client.requests[0].messages[1], entry("assistant", [textBlock("A1")]))
    }

    // MARK: Cancellation, failure, retry

    func testCancelKeepsVisibleTextInContext() async {
        let client = ScriptedLLMClient([
            .stall([.messageStart(model: "claude-opus-5"), .thinkingStarted, .textDelta("Partial answer ")]),
            reply("Continuing."),
        ])
        let (chat, _) = makeSession(client)
        var finishedCount = 0
        chat.onReplyFinished = { finishedCount += 1 }

        chat.send(text: "Tell me", attachments: [])
        await waitUntil { chat.messages.last?.text == "Partial answer " }
        chat.cancel()

        XCTAssertFalse(chat.isStreaming)
        XCTAssertEqual(chat.messages[1].state, .cancelled)
        XCTAssertEqual(chat.messages[1].text, "Partial answer ")
        XCTAssertTrue(chat.messages[1].includeInContext)
        XCTAssertEqual(finishedCount, 1)
        await waitUntil { client.cancellations == 1 }

        chat.send(text: "Go on", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(client.requests[1].messages, [
            entry("user", [textBlock("Tell me")]),
            entry("assistant", [textBlock("Partial answer")]),
            entry("user", [textBlock("Go on")]),
        ])
        // The cancelled turn is not disturbed by its winding-down task.
        XCTAssertEqual(chat.messages[1].state, .cancelled)
        XCTAssertEqual(finishedCount, 2)
    }

    func testCancelWithoutTextIsLeftOutOfContext() async {
        let client = ScriptedLLMClient([
            .stall([.messageStart(model: "claude-opus-5"), .thinkingStarted]),
            reply("Hi again."),
        ])
        let (chat, _) = makeSession(client)

        chat.send(text: "First", attachments: [])
        await waitUntil { chat.messages.last?.isThinking == true }
        chat.cancel()
        XCTAssertEqual(chat.messages[1].state, .cancelled)

        chat.send(text: "Second", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(client.requests[1].messages, [
            entry("user", [textBlock("First")]),
            entry("user", [textBlock("Second")]),
        ])
    }

    func testFailureKeepsUserMessageButDropsAssistant() async {
        let client = ScriptedLLMClient([
            .failure(LLMError.overloaded, after: [.messageStart(model: "claude-opus-5")]),
            reply("Back now."),
        ])
        let (chat, _) = makeSession(client)

        chat.send(text: "Hello?", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(chat.messages[1].state, .failed(LLMError.overloaded.localizedDescription))
        XCTAssertFalse(chat.messages[1].includeInContext)
        XCTAssertTrue(chat.messages[0].includeInContext)

        chat.send(text: "Anyone?", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(client.requests[1].messages, [
            entry("user", [textBlock("Hello?")]),
            entry("user", [textBlock("Anyone?")]),
        ])
    }

    func testRejectedRequestLeavesItsUserMessageOutOfContext() async {
        let tooLarge = LLMError.http(status: 413, type: "request_too_large", message: "Request exceeds the maximum size")
        let client = ScriptedLLMClient([
            .failure(tooLarge, after: []),
            reply("Hi there."),
            .failure(tooLarge, after: []),
        ])
        let (chat, _) = makeSession(client)

        chat.send(text: "Huge PDF", attachments: [textAttachment("huge.txt")])
        await waitForReply(chat)

        XCTAssertEqual(
            chat.messages[1].state,
            .failed(tooLarge.localizedDescription + " " + ChatSession.excludedFromContextNote)
        )
        XCTAssertFalse(chat.messages[0].includeInContext)
        XCTAssertFalse(chat.messages[1].includeInContext)

        // The conversation keeps working without the rejected message.
        chat.send(text: "hello?", attachments: [])
        await waitForReply(chat)
        XCTAssertEqual(client.requests[1].messages, [entry("user", [textBlock("hello?")])])
        XCTAssertEqual(chat.messages[3].state, .complete)

        // Retry puts it back (and here fails again the same way).
        chat.retry(messageID: chat.messages[1].id)
        await waitForReply(chat)
        XCTAssertEqual(client.requests[2].messages.first, entry("user", chat.messages[0].apiContent))
    }

    func testRequestContentErrorsAreToldApartFromTransientOnes() {
        XCTAssertTrue(ChatSession.isRejectedRequestContent(LLMError.http(status: 400, type: "invalid_request_error", message: "x")))
        XCTAssertTrue(ChatSession.isRejectedRequestContent(LLMError.http(status: 413, type: nil, message: "")))
        XCTAssertTrue(ChatSession.isRejectedRequestContent(LLMError.streamError(type: "invalid_request_error", message: "x")))
        XCTAssertFalse(ChatSession.isRejectedRequestContent(LLMError.overloaded))
        XCTAssertFalse(ChatSession.isRejectedRequestContent(LLMError.rateLimited(retryAfter: 3)))
        XCTAssertFalse(ChatSession.isRejectedRequestContent(LLMError.http(status: 500, type: "api_error", message: "")))
        XCTAssertFalse(ChatSession.isRejectedRequestContent(LLMError.network("offline")))
        XCTAssertFalse(ChatSession.isRejectedRequestContent(CancellationError()))
    }

    func testUnfinishedToolActivitiesSettleWhenTheTurnEnds() async {
        let searching = ToolActivity(id: "srvtoolu_1", kind: .webSearch, label: "Searching “swift”", isDone: false)
        let client = ScriptedLLMClient([.stall([.messageStart(model: "claude-opus-5"), .toolActivity(searching)])])
        let (chat, _) = makeSession(client)

        chat.send(text: "Look it up", attachments: [])
        await waitUntil { chat.messages.last?.activities.isEmpty == false }
        chat.cancel()

        XCTAssertEqual(chat.messages[1].state, .cancelled)
        XCTAssertEqual(chat.messages[1].activities.map(\.isDone), [true])
    }

    func testOlderAttachmentsAreOmittedOnceOverBudget() {
        let bigText = String(repeating: "a", count: 400_000)
        let old = textAttachment("old.txt", bigText)
        let recent = textAttachment("recent.txt", bigText)
        let newest = textAttachment("newest.txt", bigText)
        let messages = [
            ChatMessage(role: .user, text: "One", apiContent: old.contentBlocks() + [textBlock("One")]),
            ChatMessage(role: .assistant, text: "A1", apiContent: [textBlock("A1")]),
            ChatMessage(role: .user, text: "Two", apiContent: recent.contentBlocks() + [textBlock("Two")]),
            ChatMessage(role: .assistant, text: "A2", apiContent: [textBlock("A2")]),
            ChatMessage(role: .user, text: "Three", apiContent: newest.contentBlocks() + [textBlock("Three")]),
        ]

        let history = ChatSession.requestHistory(for: messages, inFlight: nil, resumingInFlight: false, enabledServerTools: [])

        XCTAssertEqual(history.count, 5)
        // The newest message is always whole, the next-older document fits the history budget, and the
        // oldest is replaced by a note.
        XCTAssertEqual(history[4], entry("user", newest.contentBlocks() + [textBlock("Three")]))
        XCTAssertEqual(history[2], entry("user", recent.contentBlocks() + [textBlock("Two")]))
        guard let note = history[0]["content"]?[0]?["text"]?.stringValue else {
            return XCTFail("Expected a text note in place of the oldest attachment")
        }
        XCTAssertTrue(note.contains("old.txt"))
        XCTAssertEqual(history[0]["content"]?[1], textBlock("One"))
    }

    func testStreamEndingWithoutCompletionFails() async {
        let client = ScriptedLLMClient([.events([.messageStart(model: "claude-opus-5"), .textDelta("Half")])])
        let (chat, _) = makeSession(client)

        chat.send(text: "Hi", attachments: [])
        await waitForReply(chat)

        guard case .failed(let message) = chat.messages[1].state else {
            return XCTFail("Expected a failed turn, got \(chat.messages[1].state)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(chat.lastAssistantText)
    }

    func testMissingClientFailsTheTurn() async {
        let settings = makeSettings()
        let chat = ChatSession(settings: settings, makeClient: { throw LLMError.missingAPIKey })
        var finishedCount = 0
        chat.onReplyFinished = { finishedCount += 1 }

        chat.send(text: "Hi", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(chat.messages[1].state, .failed(LLMError.missingAPIKey.localizedDescription))
        XCTAssertFalse(chat.messages[1].includeInContext)
        XCTAssertEqual(finishedCount, 1)
    }

    func testRetryReplacesFailedTurn() async {
        let client = ScriptedLLMClient([.failure(LLMError.overloaded, after: []), reply("Here you go.")])
        let (chat, _) = makeSession(client)

        chat.send(text: "Question", attachments: [])
        await waitForReply(chat)
        let failedID = chat.messages[1].id

        chat.retry(messageID: failedID)
        XCTAssertTrue(chat.isStreaming)
        await waitForReply(chat)

        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertNotEqual(chat.messages[1].id, failedID)
        XCTAssertEqual(chat.messages[1].state, .complete)
        XCTAssertEqual(chat.messages[1].text, "Here you go.")
        XCTAssertEqual(client.requests[1].messages, [entry("user", [textBlock("Question")])])
    }

    func testRetryOfRefusalReincludesUserMessage() async {
        let client = ScriptedLLMClient([
            .events([completed([], stopReason: "refusal")]),
            reply("Okay."),
        ])
        let (chat, _) = makeSession(client)

        chat.send(text: "Try this", attachments: [])
        await waitForReply(chat)
        XCTAssertFalse(chat.messages[0].includeInContext)

        chat.retry(messageID: chat.messages[1].id)
        await waitForReply(chat)

        XCTAssertTrue(chat.messages[0].includeInContext)
        XCTAssertEqual(chat.messages[1].state, .complete)
        XCTAssertEqual(client.requests[1].messages, [entry("user", [textBlock("Try this")])])
    }

    func testRetryIgnoresCompletedMessages() async {
        let client = ScriptedLLMClient([reply("Done.")])
        let (chat, _) = makeSession(client)

        chat.send(text: "Hi", attachments: [])
        await waitForReply(chat)
        chat.retry(messageID: chat.messages[1].id)

        XCTAssertFalse(chat.isStreaming)
        XCTAssertEqual(client.requests.count, 1)
    }

    func testRetryOfEarlierTurnOnlySendsConversationUpToIt() async {
        let client = ScriptedLLMClient([reply("Better answer.")])
        let (chat, _) = makeSession(client)
        let failed = ChatMessage(role: .assistant, state: .failed("Overloaded"), includeInContext: false)
        chat.debugSeed(messages: [
            ChatMessage(role: .user, text: "Q1", apiContent: [textBlock("Q1")]),
            failed,
            ChatMessage(role: .user, text: "Q2", apiContent: [textBlock("Q2")]),
            ChatMessage(role: .assistant, text: "A2", apiContent: [textBlock("A2")]),
        ], isStreaming: false)

        chat.retry(messageID: failed.id)
        await waitForReply(chat)

        XCTAssertEqual(client.requests[0].messages, [entry("user", [textBlock("Q1")])])
        XCTAssertEqual(chat.messages.map(\.text), ["Q1", "Better answer.", "Q2", "A2"])
    }

    func testResetCancelsAndClears() async {
        let client = ScriptedLLMClient([.stall([.textDelta("Streaming…")]), reply("Fresh start.")])
        let (chat, _) = makeSession(client)
        var finishedCount = 0
        chat.onReplyFinished = { finishedCount += 1 }

        chat.send(text: "Old chat", attachments: [])
        await waitUntil { chat.messages.last?.text == "Streaming…" }
        chat.reset()

        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertFalse(chat.isStreaming)
        XCTAssertEqual(finishedCount, 0)

        chat.send(text: "New chat", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages[1].text, "Fresh start.")
        XCTAssertEqual(client.requests[1].messages, [entry("user", [textBlock("New chat")])])
    }

    func testMessageTooLargeForARequestFailsWithoutCallingTheAPIAndLeavesTheContext() async {
        let client = ScriptedLLMClient([reply("Unused")])
        let (chat, _) = makeSession(client)
        let huge = textAttachment("huge.txt", String(repeating: "a", count: AttachmentBudget.maxRequestContentBytes + 10))

        chat.send(text: "Read it", attachments: [huge])
        await waitForReply(chat)

        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertFalse(chat.messages[0].includeInContext)
        guard case .failed(let description) = chat.messages[1].state else {
            return XCTFail("Expected a failed turn, got \(chat.messages[1].state)")
        }
        XCTAssertTrue(description.hasPrefix(AttachmentBudget.requestTooLargeDescription))
        XCTAssertTrue(description.hasSuffix(ChatSession.excludedFromContextNote))
    }

    // MARK: Transcript, phase and usage

    private func restoredConversation() -> (LoadedConversation, user: ChatMessage, assistant: ChatMessage) {
        let user = ChatMessage(role: .user, text: "Old question", apiContent: [textBlock("Old question")])
        let assistant = ChatMessage(role: .assistant, text: "Old answer", apiContent: [textBlock("Old answer")],
                                    model: "claude-opus-5")
        let conversation = LoadedConversation(
            id: UUID(),
            title: "Old question",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_600),
            messages: [user, assistant],
            unavailableAttachmentIDs: [UUID()],
            textOnlyContextMessageIDs: [assistant.id],
            readingPosition: nil
        )
        return (conversation, user, assistant)
    }

    /// Sends `text` on a stepped client and waits until the reply's stream is open.
    private func startSteppedTurn(_ chat: ChatSession, _ client: SteppedLLMClient, text: String = "Go") async {
        chat.send(text: text, attachments: [])
        await waitUntil { client.isAwaitingEvent }
    }

    private func deliver(_ event: StreamEvent, to client: SteppedLLMClient) async {
        client.push(event)
        await waitUntil { client.isAwaitingEvent }
    }

    func testTranscriptEmissionsFollowTheTurnAndPrecedeReplyFinished() async {
        let client = ScriptedLLMClient([reply("Hi there."), reply("Again.")])
        let (chat, _) = makeSession(client)
        var events: [SessionEvent] = []
        chat.onTranscriptChanged = { change in
            events.append(.transcript(change))
            switch change {
            case .userMessageAdded:
                XCTAssertEqual(chat.messages.last(where: { $0.role == .user })?.text, events.count == 1 ? "Hello" : "More")
            case .turnFinished:
                XCTAssertFalse(chat.isStreaming)
                XCTAssertEqual(chat.phase, .idle)
                XCTAssertEqual(chat.lastFinishedAssistantID, chat.messages.last?.id)
                XCTAssertEqual(chat.transcriptSnapshot().messages.last?.state, .complete)
            case .messagesRemoved, .willReset, .loaded:
                XCTFail("Unexpected \(change)")
            }
        }
        chat.onReplyFinished = { events.append(.replyFinished) }
        let conversationID = chat.conversationID

        chat.send(text: "Hello", attachments: [])
        XCTAssertEqual(events, [.transcript(.userMessageAdded)])
        await waitForReply(chat)
        chat.send(text: "More", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(events, [
            .transcript(.userMessageAdded), .transcript(.turnFinished), .replyFinished,
            .transcript(.userMessageAdded), .transcript(.turnFinished), .replyFinished,
        ])
        XCTAssertEqual(chat.conversationID, conversationID)
        XCTAssertEqual(chat.transcriptSnapshot().conversationID, conversationID)
    }

    func testCancelAndRetryReportTheTurnFinishingButNoNewUserMessage() async {
        // The first turn is stopped before its task asks for a response, so the only one is the retry's.
        let client = ScriptedLLMClient([reply("Second try.")])
        let (chat, _) = makeSession(client)
        var events: [SessionEvent] = []
        chat.onTranscriptChanged = { events.append(.transcript($0)) }
        chat.onReplyFinished = { events.append(.replyFinished) }

        chat.send(text: "Question", attachments: [])
        chat.cancel()
        chat.retry(messageID: chat.messages[1].id)
        await waitForReply(chat)

        XCTAssertEqual(events, [
            .transcript(.userMessageAdded), .transcript(.turnFinished), .replyFinished,
            .transcript(.turnFinished), .replyFinished,
        ])
        XCTAssertEqual(chat.messages.map(\.text), ["Question", "Second try."])
        XCTAssertEqual(client.requests.count, 1)
    }

    func testResetReportsWillResetOnlyWhenNonEmptyAndStartsANewConversation() async {
        let client = ScriptedLLMClient([.stall([.messageStart(model: "claude-opus-5"), .textDelta("Streaming")])])
        let (chat, _) = makeSession(client)
        var events: [SessionEvent] = []
        var snapshotAtWillReset: TranscriptSnapshot?
        chat.onTranscriptChanged = { change in
            events.append(.transcript(change))
            if change == .willReset { snapshotAtWillReset = chat.transcriptSnapshot() }
        }
        chat.onReplyFinished = { events.append(.replyFinished) }

        let firstID = chat.conversationID
        let firstCreatedAt = chat.conversationCreatedAt
        chat.reset()
        XCTAssertTrue(events.isEmpty)
        XCTAssertNotEqual(chat.conversationID, firstID)
        XCTAssertGreaterThanOrEqual(chat.conversationCreatedAt, firstCreatedAt)

        let secondID = chat.conversationID
        chat.send(text: "Old chat", attachments: [])
        await waitUntil { chat.messages.last?.text == "Streaming" }
        chat.reset()

        XCTAssertEqual(events, [.transcript(.userMessageAdded), .transcript(.willReset)])
        XCTAssertEqual(snapshotAtWillReset?.conversationID, secondID)
        XCTAssertEqual(snapshotAtWillReset?.messages.map(\.text), ["Old chat", "Streaming"])
        XCTAssertNotEqual(chat.conversationID, secondID)
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertEqual(chat.phase, .idle)
        XCTAssertNil(chat.lastFinishedAssistantID)
    }

    func testLoadReplacesTheConversationAndReportsLoaded() async {
        let client = ScriptedLLMClient([reply("Next.")])
        let (chat, _) = makeSession(client)
        let (conversation, user, assistant) = restoredConversation()
        var events: [SessionEvent] = []
        chat.onTranscriptChanged = { events.append(.transcript($0)) }

        chat.load(conversation)

        XCTAssertEqual(events, [.transcript(.loaded)])
        XCTAssertEqual(chat.conversationID, conversation.id)
        XCTAssertEqual(chat.conversationCreatedAt, conversation.createdAt)
        XCTAssertEqual(chat.messages, [user, assistant])
        XCTAssertEqual(chat.unavailableAttachmentIDs, conversation.unavailableAttachmentIDs)
        XCTAssertEqual(chat.messageCount, 2)
        XCTAssertEqual(chat.lastMessageState, .complete)
        XCTAssertTrue(chat.hasCopyableReply)
        XCTAssertEqual(chat.lastAssistantText, "Old answer")
        XCTAssertFalse(chat.isStreaming)
        XCTAssertEqual(chat.phase, .idle)
        let snapshot = chat.transcriptSnapshot()
        XCTAssertEqual(snapshot.conversationID, conversation.id)
        XCTAssertEqual(snapshot.createdAt, conversation.createdAt)
        XCTAssertEqual(snapshot.messages, [user, assistant])
        XCTAssertEqual(snapshot.unavailableAttachmentIDs, conversation.unavailableAttachmentIDs)

        // Continuing the restored conversation sends it as context and keeps its identity.
        chat.send(text: "Go on", attachments: [])
        await waitForReply(chat)
        XCTAssertEqual(client.requests[0].messages, [
            entry("user", [textBlock("Old question")]),
            entry("assistant", [textBlock("Old answer")]),
            entry("user", [textBlock("Go on")]),
        ])
        XCTAssertEqual(chat.conversationID, conversation.id)

        chat.reset()
        XCTAssertTrue(chat.unavailableAttachmentIDs.isEmpty)
        XCTAssertNotEqual(chat.conversationID, conversation.id)
    }

    func testLoadCancelsARunningReplyAndReportsItFinishedFirst() async {
        let client = ScriptedLLMClient([.stall([.messageStart(model: "claude-opus-5"), .textDelta("Half an ans")])])
        let (chat, _) = makeSession(client)
        let (conversation, user, assistant) = restoredConversation()
        var events: [SessionEvent] = []
        var snapshotAtTurnFinished: TranscriptSnapshot?
        chat.onTranscriptChanged = { change in
            events.append(.transcript(change))
            if change == .turnFinished { snapshotAtTurnFinished = chat.transcriptSnapshot() }
        }
        chat.onReplyFinished = { events.append(.replyFinished) }

        chat.send(text: "Current question", attachments: [])
        let currentID = chat.conversationID
        await waitUntil { chat.messages.last?.text == "Half an ans" }
        chat.load(conversation)

        XCTAssertEqual(events, [
            .transcript(.userMessageAdded), .transcript(.turnFinished), .replyFinished, .transcript(.loaded),
        ])
        XCTAssertEqual(snapshotAtTurnFinished?.conversationID, currentID)
        XCTAssertEqual(snapshotAtTurnFinished?.messages.last?.state, .cancelled)
        XCTAssertEqual(snapshotAtTurnFinished?.messages.last?.text, "Half an ans")
        XCTAssertEqual(chat.messages, [user, assistant])
        XCTAssertEqual(chat.conversationID, conversation.id)
        XCTAssertFalse(chat.isStreaming)
        XCTAssertEqual(chat.phase, .idle)
        await waitUntil { client.cancellations == 1 }
    }

    func testSnapshotFlushesPendingDeltas() async {
        let client = SteppedLLMClient()
        let chat = ChatSession(settings: makeSettings(), makeClient: { client })
        await startSteppedTurn(chat, client)
        await deliver(.messageStart(model: "claude-opus-5"), to: client)
        await deliver(.textDelta("Hello"), to: client)
        XCTAssertEqual(chat.messages.last?.text, "Hello")

        // Text right after a flush waits for the next one (deltaFlushInterval); the snapshot must not.
        await deliver(.textDelta(" world"), to: client)
        let snapshot = chat.transcriptSnapshot()

        XCTAssertEqual(snapshot.messages.last?.text, "Hello world")
        XCTAssertEqual(chat.messages.last?.text, "Hello world")
        XCTAssertEqual(snapshot.conversationID, chat.conversationID)
        chat.cancel()
    }

    func testPhaseFollowsTheReplyAndIgnoresLaterDeltas() async {
        let client = SteppedLLMClient()
        let chat = ChatSession(settings: makeSettings(), makeClient: { client })
        let searching = ToolActivity(id: "srvtoolu_1", kind: .webSearch, label: "Searching “swift”", isDone: false)
        XCTAssertEqual(chat.phase, .idle)

        chat.send(text: "Go", attachments: [])
        XCTAssertEqual(chat.phase, .connecting)
        await waitUntil { client.isAwaitingEvent }

        await deliver(.messageStart(model: "claude-opus-5"), to: client)
        XCTAssertEqual(chat.phase, .thinking)
        await deliver(.thinkingStarted, to: client)
        XCTAssertEqual(chat.phase, .thinking)
        await deliver(.toolActivity(searching), to: client)
        XCTAssertEqual(chat.phase, .searching(label: "Searching “swift”"))
        var finished = searching
        finished.isDone = true
        await deliver(.toolActivity(finished), to: client)
        XCTAssertEqual(chat.phase, .thinking)
        await deliver(.textDelta("The answer"), to: client)
        XCTAssertEqual(chat.phase, .writing)

        let phaseChanged = FlagBox()
        withObservationTracking {
            _ = chat.phase
        } onChange: {
            phaseChanged.isSet = true
        }
        for word in [" is", " forty", " two", "."] {
            await deliver(.textDelta(word), to: client)
        }
        await deliver(.sources([SourceLink(title: "Swift", url: URL(fileURLWithPath: "/swift"))]), to: client)
        XCTAssertEqual(chat.phase, .writing)
        XCTAssertFalse(phaseChanged.isSet)

        client.push(completed([textBlock("The answer is forty two.")]))
        await waitForReply(chat)
        XCTAssertEqual(chat.phase, .idle)
        XCTAssertTrue(phaseChanged.isSet)
    }

    func testPhaseOfASeededConversation() {
        let (chat, _) = makeSession(ScriptedLLMClient([]))
        chat.debugSeed(messages: [
            ChatMessage(role: .user, text: "Hi"),
            ChatMessage(role: .assistant, text: "Wri", state: .streaming, model: "claude-opus-5"),
        ], isStreaming: true)
        XCTAssertEqual(chat.phase, .writing)

        chat.cancel()
        XCTAssertEqual(chat.phase, .idle)
    }

    func testLastFinishedAssistantIDNamesARetriedOlderTurn() async {
        let client = ScriptedLLMClient([reply("Better answer.")])
        let (chat, _) = makeSession(client)
        let failed = ChatMessage(role: .assistant, state: .failed("Overloaded"), includeInContext: false)
        chat.debugSeed(messages: [
            ChatMessage(role: .user, text: "Q1", apiContent: [textBlock("Q1")]),
            failed,
            ChatMessage(role: .user, text: "Q2", apiContent: [textBlock("Q2")]),
            ChatMessage(role: .assistant, text: "A2", apiContent: [textBlock("A2")]),
        ], isStreaming: false)
        var idAtReplyFinished: UUID?
        chat.onReplyFinished = { idAtReplyFinished = chat.lastFinishedAssistantID }

        chat.retry(messageID: failed.id)
        await waitForReply(chat)

        XCTAssertEqual(chat.lastFinishedAssistantID, chat.messages[1].id)
        XCTAssertEqual(idAtReplyFinished, chat.messages[1].id)
        XCTAssertNotEqual(chat.lastFinishedAssistantID, chat.messages.last?.id)
    }

    func testUsageIsRecordedOncePerCompletedRequest() async {
        let first = usage(output: 40)
        let streamed = usage(output: 5)
        let client = ScriptedLLMClient([
            .events([
                .messageStart(model: "claude-opus-5"),
                .textDelta("Looking"),
                .usage(usage(output: 1)),
                completed([textBlock("Looking")], stopReason: "pause_turn", usage: first),
            ]),
            .events([
                .messageStart(model: "claude-opus-5"),
                .usage(streamed),
                completed([textBlock(" it up.")], stopReason: "end_turn", usage: nil),
            ]),
        ])
        let (chat, settings) = makeSession(client)
        let recorder = FakeUsageRecorder()
        chat.usageRecorder = recorder
        var finishedAnswersAtReplyFinished: [UUID] = []
        chat.onReplyFinished = { finishedAnswersAtReplyFinished = recorder.finishedAnswers }

        chat.send(text: "Search", attachments: [])
        let assistantID = chat.messages[1].id
        await waitForReply(chat)

        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(recorder.records.map(\.usage), [first, streamed])
        XCTAssertEqual(recorder.records.map(\.stopReason), ["pause_turn", "end_turn"])
        XCTAssertEqual(recorder.records.map(\.isPartial), [false, false])
        XCTAssertEqual(recorder.records.map(\.messageID), [assistantID, assistantID])
        XCTAssertEqual(recorder.records.map(\.requestedModel), [settings.model.rawValue, settings.model.rawValue])
        XCTAssertEqual(recorder.records.map(\.servedModel), ["claude-opus-5", "claude-opus-5"])
        XCTAssertEqual(recorder.finishedAnswers, [assistantID])
        XCTAssertEqual(finishedAnswersAtReplyFinished, [assistantID])
    }

    func testNothingIsRecordedForAResponseWithoutUsage() async {
        let client = ScriptedLLMClient([reply("Hi.")])
        let (chat, _) = makeSession(client)
        let recorder = FakeUsageRecorder()
        chat.usageRecorder = recorder

        chat.send(text: "Hello", attachments: [])
        await waitForReply(chat)

        XCTAssertTrue(recorder.records.isEmpty)
        XCTAssertEqual(recorder.finishedAnswers, [chat.messages[1].id])
    }

    func testCancelAfterUsageRecordsAPartialRequest() async {
        let spent = usage(output: 12)
        let client = ScriptedLLMClient([
            .stall([.messageStart(model: "claude-opus-5"), .usage(spent), .textDelta("Part")]),
        ])
        let (chat, settings) = makeSession(client)
        let recorder = FakeUsageRecorder()
        chat.usageRecorder = recorder

        chat.send(text: "Long question", attachments: [])
        let assistantID = chat.messages[1].id
        await waitUntil { chat.messages.last?.text == "Part" }
        chat.cancel()

        XCTAssertEqual(recorder.records, [FakeUsageRecorder.Record(
            usage: spent, requestedModel: settings.model.rawValue, servedModel: "claude-opus-5", stopReason: nil,
            isPartial: true, messageID: assistantID, date: recorder.records.first?.date ?? Date()
        )])
        XCTAssertEqual(recorder.finishedAnswers, [assistantID])
        await waitUntil { client.cancellations == 1 }
        XCTAssertEqual(recorder.records.count, 1)
    }

    func testFailureAfterUsageRecordsAPartialRequest() async {
        let spent = usage(output: 3)
        let client = ScriptedLLMClient([
            .failure(LLMError.overloaded, after: [.messageStart(model: "claude-opus-5"), .usage(spent)]),
        ])
        let (chat, _) = makeSession(client)
        let recorder = FakeUsageRecorder()
        chat.usageRecorder = recorder

        chat.send(text: "Question", attachments: [])
        await waitForReply(chat)

        XCTAssertEqual(recorder.records.map(\.usage), [spent])
        XCTAssertEqual(recorder.records.map(\.isPartial), [true])
        XCTAssertEqual(recorder.finishedAnswers, [chat.messages[1].id])
    }
}

// MARK: - SystemPrompt & AppSettings

@MainActor
final class SystemPromptAndSettingsTests: XCTestCase {
    func testSystemPromptIncludesDateAndCustomInstructions() {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 26
        components.hour = 12
        let utc = TimeZone(identifier: "UTC") ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        guard let date = calendar.date(from: components) else { return XCTFail("Invalid date") }

        let plain = SystemPrompt.make(customInstructions: "  ", now: date, timeZone: utc)
        XCTAssertTrue(plain.hasPrefix("You are Otto, a friendly, sharp assistant"))
        XCTAssertTrue(plain.contains("Today's date is Saturday, September 26, 2026."))
        XCTAssertFalse(plain.contains("<user_instructions>"))

        let custom = SystemPrompt.make(customInstructions: "Answer in French.", now: date, timeZone: utc)
        XCTAssertTrue(custom.hasSuffix("\n\n<user_instructions>\nAnswer in French.\n</user_instructions>"))
    }

    func testSettingsDefaultsAndPersistence() {
        let suiteName = "otto.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.model, .opus5)
        XCTAssertEqual(settings.effort, .medium)
        XCTAssertTrue(settings.webAccess)
        XCTAssertTrue(settings.suggestBrowserTab)
        XCTAssertFalse(settings.autoAttachBrowserTab)
        XCTAssertTrue(settings.hotKeyEnabled)
        XCTAssertTrue(settings.showMenuBarIcon)
        XCTAssertEqual(settings.customInstructions, "")

        settings.model = .haiku45
        settings.effort = .high
        settings.webAccess = false
        settings.autoAttachBrowserTab = true
        settings.customInstructions = "Be brief."
        XCTAssertEqual(defaults.string(forKey: "otto.model"), ModelOption.haiku45.rawValue)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.model, .haiku45)
        XCTAssertEqual(reloaded.effort, .high)
        XCTAssertFalse(reloaded.webAccess)
        XCTAssertTrue(reloaded.autoAttachBrowserTab)
        XCTAssertEqual(reloaded.customInstructions, "Be brief.")
    }
}
