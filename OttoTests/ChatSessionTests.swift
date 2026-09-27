//
//  ChatSessionTests.swift
//  Otto
//
//  ChatSession history/streaming behaviour, plus the NotchViewModel and AppSettings state it feeds.
//

import AppKit
import UniformTypeIdentifiers
import PDFKit
import XCTest
@testable import Otto

// MARK: - Scripted client

/// An LLMClient that replays one scripted response per request and records every request.
private final class ScriptedLLMClient: LLMClient, @unchecked Sendable {
    enum Response {
        /// Yields the events, then finishes.
        case events([StreamEvent])
        /// Yields `prefix`, then throws `error`.
        case failure(Error, after: [StreamEvent])
        /// Yields the events and then never finishes; only cancellation ends it.
        case stall([StreamEvent])
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var recordedRequests: [MessagesRequest] = []
    private var recordedCancellations = 0

    init(_ responses: [Response]) {
        self.responses = responses
    }

    var requests: [MessagesRequest] { lock.withLock { recordedRequests } }
    var cancellations: Int { lock.withLock { recordedCancellations } }

    func stream(_ request: MessagesRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let response: Response? = lock.withLock {
            recordedRequests.append(request)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination, let self else { return }
                self.lock.withLock { self.recordedCancellations += 1 }
            }
            switch response {
            case .events(let events):
                events.forEach { continuation.yield($0) }
                continuation.finish()
            case .failure(let error, let prefix):
                prefix.forEach { continuation.yield($0) }
                continuation.finish(throwing: error)
            case .stall(let events):
                events.forEach { continuation.yield($0) }
            case nil:
                continuation.finish(throwing: LLMError.network("No scripted response left."))
            }
        }
    }
}

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
