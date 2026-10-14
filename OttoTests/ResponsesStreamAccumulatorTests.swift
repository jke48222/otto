//
//  ResponsesStreamAccumulatorTests.swift
//  Otto
//

import XCTest
@testable import Otto

/// Stable, comparable rendering of a StreamEvent (StreamEvent itself is not Equatable).
private func describe(_ event: StreamEvent) -> String {
    switch event {
    case .messageStart(let model):
        return "messageStart(\(model))"
    case .thinkingStarted:
        return "thinkingStarted"
    case .thinkingDelta(let text):
        return "thinkingDelta(\(text))"
    case .textDelta(let text):
        return "textDelta(\(text))"
    case .toolActivity(let activity):
        return "toolActivity(\(activity.id)|\(activity.kind.rawValue)|\(activity.label)|\(activity.isDone ? "done" : "running"))"
    case .sources(let links):
        return "sources(" + links.map { "\($0.title)|\($0.url.absoluteString)" }.joined(separator: ", ") + ")"
    case .fallback(let from, let to):
        return "fallback(\(from ?? "nil")->\(to ?? "nil"))"
    case .completed(let result):
        return "completed(\(result.stopReason ?? "nil"))"
    case .toolUseStarted(let id, let name):
        return "toolUseStarted(\(id)|\(name))"
    case .toolUseReady(let id, let name, let input, let rawInput):
        return "toolUseReady(\(id)|\(name)|\(input.map { $0.encodedString() } ?? "invalid")|\(rawInput))"
    case .usage(let usage):
        return "usage(\(usage.encodedString()))"
    }
}

final class ResponsesStreamAccumulatorTests: XCTestCase {
    private static let swiftBlog = "https://www.swift.example/blog/swift-6-2-released/"
    private static let newsPage = "https://news.example/swift-6-2"
    private static let forumThread = "https://forums.swift.example/t/migrating-to-swift-6-2"
    private static let dentistArguments = #"{"title":"Dentist","start":"2026-10-15T09:00","end":"2026-10-15T10:00"}"#
    private static let dentistInput = #"{"end":"2026-10-15T10:00","start":"2026-10-15T09:00","title":"Dentist"}"#

    private struct Replay {
        var events: [StreamEvent]
        var accumulator: ResponsesStreamAccumulator
        var descriptions: [String] { events.map(describe) }
        var result: StreamResult { accumulator.result() }
    }

    private func replay(_ lines: [String], model: ModelOption = .opus5) throws -> Replay {
        try replay(events: lines.map(ScriptedResponsesTransport.decode), model: model)
    }

    private func replay(events: [JSONValue], model: ModelOption = .opus5) throws -> Replay {
        var accumulator = ResponsesStreamAccumulator(requestedModel: model)
        var produced: [StreamEvent] = []
        for event in events {
            produced += try accumulator.handle(event)
        }
        return Replay(events: produced, accumulator: accumulator)
    }

    /// The error a scenario throws, or nil.
    private func failure(of lines: [String], model: ModelOption = .opus5) -> Error? {
        do {
            _ = try replay(lines, model: model)
            return nil
        } catch {
            return error
        }
    }

    private func created(model: String? = "anthropic/claude-opus-5") -> JSONValue {
        var response: JSONValue = ["id": "resp_t", "object": "response", "status": "in_progress", "output": []]
        if let model { response = response.setting("model", to: .string(model)) }
        return ["type": "response.created", "response": response]
    }

    private func completed(_ output: [JSONValue], model: String? = "anthropic/claude-opus-5",
                           usage: JSONValue? = nil) -> JSONValue {
        var response: JSONValue = ["id": "resp_t", "object": "response", "status": "completed", "output": .array(output)]
        if let model { response = response.setting("model", to: .string(model)) }
        if let usage { response = response.setting("usage", to: usage) }
        return ["type": "response.completed", "response": response]
    }

    private func message(_ id: String, _ text: String, annotations: [JSONValue] = []) -> JSONValue {
        [
            "id": .string(id), "type": "message", "status": "completed", "role": "assistant",
            "content": [["type": "output_text", "text": .string(text), "annotations": .array(annotations)]],
        ]
    }

    private func textDelta(_ itemID: String, _ delta: String, index: Int = 0) -> JSONValue {
        ["type": "response.output_text.delta", "item_id": .string(itemID), "output_index": .int(Int64(index)),
         "content_index": 0, "delta": .string(delta)]
    }

    private func webCall(_ id: String, action: JSONValue) -> JSONValue {
        ["id": .string(id), "type": "web_search_call", "status": "completed", "action": action]
    }

    private func functionCall(_ itemID: String, callID: String, name: String, arguments: String) -> JSONValue {
        ["id": .string(itemID), "type": "function_call", "status": "completed", "call_id": .string(callID),
         "name": .string(name), "arguments": .string(arguments)]
    }

    // MARK: - Fixture scenarios

    func testFixturesAreOpenAIStreamingEvents() throws {
        for (name, lines) in ResponsesFixtures.all {
            XCTAssertFalse(lines.isEmpty, name)
            for line in lines {
                let event = try JSONValue.decode(line)
                let type = try XCTUnwrap(event.typeName, "\(name): \(line)")
                XCTAssertTrue(type.hasPrefix("response.") || type == "error", "\(name): \(type)")
            }
        }
    }

    func testTextScenario() throws {
        let run = try replay(ResponsesFixtures.text)

        XCTAssertEqual(run.descriptions, [
            "messageStart(anthropic/claude-opus-5)",
            "textDelta(Swift 6.2 makes concurrency )",
            "textDelta(easier to adopt: app code runs on the main actor by default.)",
            #"usage({"cache_read_input_tokens":1536,"input_tokens":304,"output_tokens":22})"#,
        ])
        XCTAssertTrue(run.accumulator.isComplete)
        let result = run.result
        XCTAssertEqual(result.content, [
            ["type": "text", "text": "Swift 6.2 makes concurrency easier to adopt: app code runs on the main actor by default."],
        ])
        XCTAssertEqual(result.stopReason, "end_turn")
        XCTAssertNil(result.stopDetails)
        XCTAssertEqual(result.model, "anthropic/claude-opus-5")
        XCTAssertEqual(result.usage, ["input_tokens": 304, "cache_read_input_tokens": 1536, "output_tokens": 22])
    }

    func testUsageReadsAsTokenUsage() throws {
        let usage = try XCTUnwrap(try replay(ResponsesFixtures.text).result.usage)
        XCTAssertEqual(TokenUsage(json: usage), TokenUsage(input: 304, output: 22, cacheRead: 1536))
        // 1,840 prompt tokens either way: OpenAI counts the cached ones inside input_tokens, Anthropic beside it.
        XCTAssertEqual(TokenUsage(json: usage).promptTokens, 1840)

        let web = try XCTUnwrap(try replay(ResponsesFixtures.webSearch).result.usage)
        XCTAssertEqual(TokenUsage(json: web), TokenUsage(input: 5210, output: 184, webSearches: 1))
    }

    func testReasoningThenTextScenario() throws {
        let run = try replay(ResponsesFixtures.reasoningThenText, model: .sonnet5)

        XCTAssertEqual(run.descriptions, [
            "messageStart(anthropic/claude-sonnet-5)",
            "thinkingStarted",
            "thinkingDelta(**Checking the meeting time**\n\n)",
            "thinkingDelta(The invite says 3 PM Pacific.)",
            "thinkingDelta(\n\n)",
            "thinkingDelta(That is 6 PM in New York.)",
            "textDelta(The meeting starts at 6 PM )",
            "textDelta(in New York.)",
            #"usage({"cache_read_input_tokens":0,"input_tokens":920,"output_tokens":140})"#,
        ])

        let result = run.result
        let item = try XCTUnwrap(ScriptedResponsesTransport.decode(ResponsesFixtures.reasoningThenText.last!)["response"]?["output"]?[0])
        let summary = "**Checking the meeting time**\n\nThe invite says 3 PM Pacific.\n\nThat is 6 PM in New York."
        XCTAssertEqual(result.content, [
            ["type": "thinking", "thinking": .string(summary), "signature": ""],
            ["type": "otto_responses_reasoning", "item": item],
            ["type": "text", "text": "The meeting starts at 6 PM in New York."],
        ])
        // The reasoning item is kept verbatim, encrypted content included, for the next gateway request.
        XCTAssertEqual(result.content[1]["item"]?["encrypted_content"], "gAAAAABsynthetic-encrypted-reasoning-02")
        XCTAssertEqual(result.stopReason, "end_turn")
        XCTAssertEqual(result.model, "anthropic/claude-sonnet-5")

        // What streamed reads the same as what is stored.
        let streamed = run.events.compactMap { event -> String? in
            if case .thinkingDelta(let text) = event { return text }
            return nil
        }.joined()
        XCTAssertEqual(streamed, summary)
    }

    func testWebSearchScenario() throws {
        let run = try replay(ResponsesFixtures.webSearch)

        XCTAssertEqual(run.descriptions, [
            "messageStart(anthropic/claude-opus-5)",
            "toolActivity(ws_03search|webSearch|Searching the web|running)",
            "toolActivity(ws_03search|webSearch|Searching \u{201C}Swift 6.2 release notes\u{201D}|done)",
            "sources(swift.example|\(Self.swiftBlog), news.example|\(Self.newsPage))",
            "toolActivity(ws_03page|webSearch|Searching the web|running)",
            "toolActivity(ws_03page|webFetch|Reading swift.example|done)",
            "textDelta(Swift 6.2 focuses on approachable concurrency.)",
            "textDelta( The forums cover the migration.)",
            "sources(Migrating to Swift 6.2|\(Self.forumThread))",
            #"usage({"cache_read_input_tokens":0,"input_tokens":5210,"output_tokens":184,"server_tool_use":{"web_fetch_requests":1,"web_search_requests":1}})"#,
        ])

        let result = run.result
        XCTAssertEqual(result.content, [
            [
                "type": "server_tool_use", "id": "ws_03search", "name": "web_search",
                "input": ["query": "Swift 6.2 release notes"], "otto_provider": "setapp-ai",
            ],
            [
                "type": "web_search_tool_result", "tool_use_id": "ws_03search", "otto_provider": "setapp-ai",
                "content": [
                    ["type": "web_search_result", "url": .string(Self.swiftBlog), "title": "Swift 6.2 Released",
                     "encrypted_content": "", "page_age": nil],
                    ["type": "web_search_result", "url": .string(Self.newsPage), "title": .string(Self.newsPage),
                     "encrypted_content": "", "page_age": nil],
                ],
            ],
            [
                "type": "server_tool_use", "id": "ws_03page", "name": "web_fetch",
                "input": ["url": .string(Self.swiftBlog)], "otto_provider": "setapp-ai",
            ],
            [
                "type": "web_fetch_tool_result", "tool_use_id": "ws_03page", "otto_provider": "setapp-ai",
                "content": [
                    "type": "web_fetch_result",
                    "url": .string(Self.swiftBlog),
                    "content": [
                        "type": "document",
                        "source": ["type": "text", "media_type": "text/plain", "data": ""],
                        "title": "Swift 6.2 Released",
                    ],
                ],
            ],
            // No citations: Anthropic would reject Setapp AI's.
            ["type": "text", "text": "Swift 6.2 focuses on approachable concurrency. The forums cover the migration."],
        ])
        XCTAssertEqual(result.stopReason, "end_turn")
    }

    func testFunctionCallScenario() throws {
        let run = try replay(ResponsesFixtures.functionCall)

        XCTAssertEqual(run.descriptions, [
            "messageStart(anthropic/claude-opus-5)",
            "textDelta(I'll add the dentist appointment to your calendar.)",
            "toolUseStarted(call_04event|calendar_create_event)",
            "toolUseReady(call_04event|calendar_create_event|\(Self.dentistInput)|\(Self.dentistArguments))",
            #"usage({"cache_read_input_tokens":2048,"input_tokens":972,"output_tokens":61})"#,
        ])
        let result = run.result
        XCTAssertEqual(result.content, [
            ["type": "text", "text": "I'll add the dentist appointment to your calendar."],
            ["type": "tool_use", "id": "call_04event", "name": "calendar_create_event",
             "input": ["title": "Dentist", "start": "2026-10-15T09:00", "end": "2026-10-15T10:00"]],
        ])
        XCTAssertEqual(result.stopReason, "tool_use")
    }

    func testFunctionCallCompletedOnlyIsReconciledFromTheTerminalOutput() throws {
        let run = try replay(ResponsesFixtures.functionCallCompletedOnly)

        XCTAssertEqual(run.descriptions, [
            "messageStart(anthropic/claude-opus-5)",
            "textDelta(I'll add the dentist )",
            "textDelta(appointment to your calendar.)",
            "toolUseStarted(call_04event|calendar_create_event)",
            "toolUseReady(call_04event|calendar_create_event|\(Self.dentistInput)|\(Self.dentistArguments))",
            #"usage({"cache_read_input_tokens":2048,"input_tokens":972,"output_tokens":61})"#,
        ])
        // The same blocks as when every event arrives.
        let full = try replay(ResponsesFixtures.functionCall).result
        XCTAssertEqual(run.result.content, full.content)
        XCTAssertEqual(run.result.stopReason, "tool_use")
        XCTAssertEqual(run.result.usage, full.usage)
    }

    func testParallelFunctionCallsScenario() throws {
        let run = try replay(ResponsesFixtures.parallelFunctionCalls, model: .sonnet5)

        XCTAssertEqual(run.descriptions, [
            "messageStart(anthropic/claude-sonnet-5)",
            "toolUseStarted(call_05events|calendar_list_events)",
            #"toolUseReady(call_05events|calendar_list_events|{"end":"2026-10-15","start":"2026-10-14"}|{"start":"2026-10-14","end":"2026-10-15"})"#,
            "toolUseStarted(call_05reminders|reminders_list)",
            "toolUseReady(call_05reminders|reminders_list|{}|{})",
            #"usage({"cache_read_input_tokens":0,"input_tokens":2890,"output_tokens":48})"#,
        ])
        XCTAssertEqual(run.result.content, [
            ["type": "tool_use", "id": "call_05events", "name": "calendar_list_events",
             "input": ["start": "2026-10-14", "end": "2026-10-15"]],
            ["type": "tool_use", "id": "call_05reminders", "name": "reminders_list", "input": [:]],
        ])
        XCTAssertEqual(run.result.stopReason, "tool_use")
    }

    func testIncompleteMaxTokensScenario() throws {
        let run = try replay(ResponsesFixtures.incompleteMaxTokens, model: .haiku45)

        XCTAssertEqual(run.descriptions, [
            "messageStart(anthropic/claude-haiku-4-5)",
            "textDelta(Here is the full history, starting in 1984 when)",
            #"usage({"cache_read_input_tokens":0,"input_tokens":410,"output_tokens":32000})"#,
        ])
        XCTAssertTrue(run.accumulator.isComplete)
        XCTAssertEqual(run.result.content, [["type": "text", "text": "Here is the full history, starting in 1984 when"]])
        XCTAssertEqual(run.result.stopReason, "max_tokens")
        XCTAssertEqual(run.result.model, "anthropic/claude-haiku-4-5")
    }

    func testRefusalScenario() throws {
        let run = try replay(ResponsesFixtures.refusal)

        // The refusal text is never streamed: ChatSession shows its own refusal copy.
        XCTAssertEqual(run.descriptions, [
            "messageStart(anthropic/claude-opus-5)",
            #"usage({"cache_read_input_tokens":0,"input_tokens":650,"output_tokens":9})"#,
        ])
        XCTAssertEqual(run.result.content, [])
        XCTAssertEqual(run.result.stopReason, "refusal")
    }

    @MainActor
    func testFailedOverflowScenarioThrowsAnErrorChatSessionCompactsFor() throws {
        let error = try XCTUnwrap(failure(of: ResponsesFixtures.failedOverflow, model: .sonnet5))
        XCTAssertEqual(error as? LLMError, .http(
            status: 400, type: "invalid_request_error",
            message: "prompt is too long: This model's maximum context length is 200000 tokens. However, your messages resulted in 214318 tokens."
        ))
        XCTAssertTrue(ChatSession.isContextOverflow(error))
        XCTAssertTrue(ChatSession.isRejectedRequestContent(error))
    }

    func testFailedCreditsScenarioThrowsInsufficientCredits() {
        XCTAssertEqual(failure(of: ResponsesFixtures.failedCredits) as? LLMError, .setappAI(.insufficientCredits))
    }

    func testMessageStartIsEmittedExactlyOnceAndFirst() throws {
        for (name, lines) in ResponsesFixtures.all where !name.hasPrefix("failed") {
            let run = try replay(lines)
            let starts = run.events.filter { if case .messageStart = $0 { return true } else { return false } }
            XCTAssertEqual(starts.count, 1, name)
            guard case .messageStart? = run.events.first else { return XCTFail("\(name) starts with \(run.descriptions.first ?? "nothing")") }
        }
    }

    // MARK: - Model

    func testModelIsPrefixedWhenTheGatewayOmitsIt() throws {
        let run = try replay(events: [created(model: "claude-opus-5"), completed([message("m", "Hi")], model: "claude-opus-5")])
        XCTAssertEqual(run.descriptions.first, "messageStart(anthropic/claude-opus-5)")
        XCTAssertEqual(run.result.model, "anthropic/claude-opus-5")
        XCTAssertEqual(ModelProvenance.split(run.result.model ?? "").viaSetappAI, true)

        XCTAssertEqual(ResponsesStreamAccumulator.gatewayModelID("anthropic/claude-sonnet-5"), "anthropic/claude-sonnet-5")
        XCTAssertEqual(ResponsesStreamAccumulator.gatewayModelID("claude-haiku-4-5"), "anthropic/claude-haiku-4-5")
    }

    func testRequestedModelStandsInWhenTheGatewayNamesNone() throws {
        let run = try replay(events: [created(model: nil), completed([message("m", "Hi")], model: nil)], model: .haiku45)
        XCTAssertEqual(run.descriptions.first, "messageStart(anthropic/claude-haiku-4-5)")
        XCTAssertEqual(run.result.model, "anthropic/claude-haiku-4-5")
    }

    func testFirstReportedModelWins() throws {
        let run = try replay(events: [created(model: "claude-sonnet-5"), completed([message("m", "Hi")], model: "claude-opus-5")])
        XCTAssertEqual(run.descriptions.first, "messageStart(anthropic/claude-sonnet-5)")
        XCTAssertEqual(run.result.model, "anthropic/claude-sonnet-5")
    }

    // MARK: - Reconciliation

    func testReasoningOnlyInTheTerminalOutputIsShownOnce() throws {
        let reasoning: JSONValue = [
            "id": "rs_x", "type": "reasoning", "encrypted_content": "gAAAA-x",
            "summary": [["type": "summary_text", "text": "First."], ["type": "summary_text", "text": "Second."]],
        ]
        let run = try replay(events: [created(), completed([reasoning, message("msg_x", "Done.")])])

        XCTAssertEqual(run.descriptions, [
            "messageStart(anthropic/claude-opus-5)",
            "thinkingStarted",
            "thinkingDelta(First.\n\nSecond.)",
            "textDelta(Done.)",
        ])
        XCTAssertEqual(run.result.content.map { $0.typeName ?? "?" }, ["thinking", "otto_responses_reasoning", "text"])
        XCTAssertEqual(run.result.content[0]["thinking"], "First.\n\nSecond.")
        XCTAssertEqual(run.result.content[1]["item"], reasoning)
    }

    func testReasoningWithoutSummaryKeepsOnlyThePassthroughBlock() throws {
        let reasoning: JSONValue = ["id": "rs_y", "type": "reasoning", "summary": [], "encrypted_content": "gAAAA-y"]
        let run = try replay(events: [
            created(),
            ["type": "response.output_item.added", "output_index": 0, "item": ["id": "rs_y", "type": "reasoning", "summary": []]],
            completed([reasoning, message("msg_y", "Ok.")]),
        ])
        XCTAssertEqual(run.descriptions, ["messageStart(anthropic/claude-opus-5)", "thinkingStarted", "textDelta(Ok.)"])
        XCTAssertEqual(run.result.content, [
            ["type": "otto_responses_reasoning", "item": reasoning],
            ["type": "text", "text": "Ok."],
        ])
    }

    func testSummaryDeltasWithoutPartEventsStillSeparateParts() throws {
        let delta: (Int, String) -> JSONValue = { index, text in
            ["type": "response.reasoning_summary_text.delta", "item_id": "rs_z", "output_index": 0,
             "summary_index": .int(Int64(index)), "delta": .string(text)]
        }
        let run = try replay(events: [created(), delta(0, "One."), delta(1, "Two.")])
        XCTAssertEqual(run.descriptions, [
            "messageStart(anthropic/claude-opus-5)", "thinkingStarted",
            "thinkingDelta(One.)", "thinkingDelta(\n\n)", "thinkingDelta(Two.)",
        ])
    }

    func testWebSearchOnlyInTheTerminalOutputIsShownAndStored() throws {
        // The SDK's typed search action carries `queries`, not `query`.
        let search = webCall("ws_sdk", action: [
            "type": "search", "queries": ["swift testing macros"],
            "sources": [["type": "url", "url": .string(Self.newsPage)]],
        ])
        let run = try replay(events: [
            created(),
            textDelta("msg_sdk", "Swift Testing uses macros."),
            completed([search, message("msg_sdk", "Swift Testing uses macros.")],
                      usage: ["input_tokens": 100, "output_tokens": 10]),
        ])

        XCTAssertEqual(run.descriptions, [
            "messageStart(anthropic/claude-opus-5)",
            "textDelta(Swift Testing uses macros.)",
            "toolActivity(ws_sdk|webSearch|Searching \u{201C}swift testing macros\u{201D}|done)",
            "sources(news.example|\(Self.newsPage))",
            #"usage({"cache_read_input_tokens":0,"input_tokens":100,"output_tokens":10,"server_tool_use":{"web_fetch_requests":0,"web_search_requests":1}})"#,
        ])
        XCTAssertEqual(run.result.content.map { $0.typeName ?? "?" }, ["server_tool_use", "web_search_tool_result", "text"])
        XCTAssertEqual(run.result.content[0]["input"], ["query": "swift testing macros"])
    }

    func testMessageTextOnlyInTheTerminalOutputIsShownOnce() throws {
        let cited = message("msg_t", "Read the notes.", annotations: [
            ["type": "url_citation", "url": .string(Self.forumThread), "title": "Notes", "start_index": 0, "end_index": 15],
        ])
        let run = try replay(events: [created(), completed([cited])])
        XCTAssertEqual(run.descriptions, [
            "messageStart(anthropic/claude-opus-5)",
            "textDelta(Read the notes.)",
            "sources(Notes|\(Self.forumThread))",
        ])
    }

    func testItemDoneFillsInWhatDidNotStream() throws {
        // `output_item.done` without the deltas before it: shown when it arrives, not again at the end.
        let run = try replay(events: [
            created(),
            ["type": "response.output_item.done", "output_index": 0,
             "item": functionCall("fc_d", callID: "call_d", name: "reminders_list", arguments: "{}")],
            completed([functionCall("fc_d", callID: "call_d", name: "reminders_list", arguments: "{}")]),
        ])
        XCTAssertEqual(run.descriptions, [
            "messageStart(anthropic/claude-opus-5)",
            "toolUseStarted(call_d|reminders_list)",
            "toolUseReady(call_d|reminders_list|{}|{})",
        ])
    }

    func testItemsThatStreamedButAreMissingFromTheTerminalOutputAreKept() throws {
        // OpenAI's own `response.incomplete` example carries `"output": []`.
        let page = webCall("ws_p", action: ["type": "open_page", "url": .string(Self.swiftBlog)])
        let run = try replay(events: [
            created(),
            ["type": "response.output_item.done", "output_index": 0, "item": page],
            textDelta("msg_p", "Partial answer", index: 1),
            ["type": "response.incomplete", "response": [
                "status": "incomplete", "output": [], "incomplete_details": ["reason": "max_output_tokens"],
            ]],
        ])
        XCTAssertEqual(run.result.content.map { $0.typeName ?? "?" },
                       ["server_tool_use", "web_fetch_tool_result", "text"])
        XCTAssertEqual(run.result.content[2]["text"], "Partial answer")
        XCTAssertEqual(run.result.stopReason, "max_tokens")
        XCTAssertEqual(run.result.usage, ["server_tool_use": ["web_search_requests": 0, "web_fetch_requests": 1]])
    }

    func testEventsAfterTheTerminalEventAreIgnored() throws {
        let run = try replay(events: [created(), completed([message("m", "Hi")]), textDelta("m", "late")])
        XCTAssertEqual(run.descriptions, ["messageStart(anthropic/claude-opus-5)", "textDelta(Hi)"])
        XCTAssertEqual(run.result.content, [["type": "text", "text": "Hi"]])
    }

    // MARK: - Function calls

    func testInvalidArgumentsKeepTheRawInputAndStoreAnEmptyObject() throws {
        let cutOff = #"{"title": "Dent"#
        let run = try replay(events: [
            created(),
            ["type": "response.output_item.added", "output_index": 0, "item": [
                "id": "fc_bad", "type": "function_call", "call_id": "call_bad", "name": "calendar_create_event",
                "arguments": "",
            ]],
            ["type": "response.function_call_arguments.delta", "item_id": "fc_bad", "output_index": 0,
             "delta": .string(cutOff)],
            ["type": "response.output_item.done", "output_index": 0, "item": [
                "id": "fc_bad", "type": "function_call", "call_id": "call_bad", "name": "calendar_create_event",
            ]],
            completed([functionCall("fc_bad", callID: "call_bad", name: "calendar_create_event", arguments: cutOff)]),
        ])

        XCTAssertEqual(run.descriptions, [
            "messageStart(anthropic/claude-opus-5)",
            "toolUseStarted(call_bad|calendar_create_event)",
            "toolUseReady(call_bad|calendar_create_event|invalid|\(cutOff))",
        ])
        XCTAssertEqual(run.result.content, [
            ["type": "tool_use", "id": "call_bad", "name": "calendar_create_event", "input": [:]],
        ])
        XCTAssertEqual(run.result.stopReason, "tool_use")
    }

    func testArgumentsFallBackToTheDoneEventThenTheDeltas() throws {
        let added: JSONValue = ["type": "response.output_item.added", "output_index": 0, "item": [
            "id": "fc_a", "type": "function_call", "call_id": "call_a", "name": "reminders_list", "arguments": "",
        ]]
        let doneWithoutArguments: JSONValue = ["type": "response.output_item.done", "output_index": 0, "item": [
            "id": "fc_a", "type": "function_call", "call_id": "call_a", "name": "reminders_list",
        ]]
        let delta: JSONValue = ["type": "response.function_call_arguments.delta", "item_id": "fc_a", "output_index": 0,
                                "delta": #"{"list":"Errands"}"#]
        let argumentsDone: JSONValue = ["type": "response.function_call_arguments.done", "item_id": "fc_a",
                                        "output_index": 0, "arguments": #"{"list":"Home"}"#]

        let fromDone = try replay(events: [created(), added, delta, argumentsDone, doneWithoutArguments])
        XCTAssertEqual(fromDone.descriptions.last, #"toolUseReady(call_a|reminders_list|{"list":"Home"}|{"list":"Home"})"#)

        let fromDeltas = try replay(events: [created(), added, delta, doneWithoutArguments])
        XCTAssertEqual(fromDeltas.descriptions.last, #"toolUseReady(call_a|reminders_list|{"list":"Errands"}|{"list":"Errands"})"#)
    }

    func testEmptyArgumentsAreAnEmptyObject() throws {
        let run = try replay(events: [created(), completed([functionCall("fc_e", callID: "call_e", name: "reminders_list", arguments: "")])])
        XCTAssertEqual(run.descriptions.last, "toolUseReady(call_e|reminders_list|{}|)")
        XCTAssertEqual(run.result.content.first?["input"], [:])
    }

    func testCallWithoutIDOrNameIsNotAnnounced() throws {
        let run = try replay(events: [created(), completed([functionCall("fc_n", callID: "", name: "reminders_list", arguments: "{}")])])
        XCTAssertEqual(run.descriptions, ["messageStart(anthropic/claude-opus-5)"])
        XCTAssertEqual(run.result.content, [])
        XCTAssertEqual(run.result.stopReason, "end_turn")
    }

    // MARK: - Web search

    func testSourcesAreDedupedByURLAcrossTheResponse() throws {
        let first = webCall("ws_1", action: ["type": "search", "query": "a", "sources": [
            ["type": "url", "url": .string(Self.newsPage)], ["type": "url", "url": .string(Self.newsPage)],
        ]])
        let second = webCall("ws_2", action: ["type": "search", "query": "b", "sources": [
            ["type": "url", "url": .string(Self.newsPage)], ["type": "url", "url": .string(Self.swiftBlog)],
        ]])
        let citation: JSONValue = ["type": "url_citation", "url": .string(Self.swiftBlog), "title": "Blog",
                                   "start_index": 0, "end_index": 2]
        let run = try replay(events: [
            created(),
            ["type": "response.output_item.done", "output_index": 0, "item": first],
            ["type": "response.output_item.done", "output_index": 1, "item": second],
            textDelta("msg_s", "Hi", index: 2),
            ["type": "response.output_text.annotation.added", "item_id": "msg_s", "output_index": 2,
             "content_index": 0, "annotation_index": 0, "annotation": citation],
            completed([first, second, message("msg_s", "Hi", annotations: [citation])]),
        ])

        let sources = run.descriptions.filter { $0.hasPrefix("sources(") }
        XCTAssertEqual(sources, [
            "sources(news.example|\(Self.newsPage))",
            "sources(swift.example|\(Self.swiftBlog))",
        ])
        // A search result lists each URL once, titled from the citations when one names it.
        XCTAssertEqual(run.result.content[1]["content"]?.arrayValue?.count, 1)
        XCTAssertEqual(run.result.content[3]["content"]?.arrayValue?.map { $0["title"] },
                       [.string(Self.newsPage), "Blog"])
    }

    func testPageReadWithoutAURLCountsAsASearch() throws {
        let page = webCall("ws_u", action: ["type": "open_page"])
        let run = try replay(events: [created(), completed([page])])
        XCTAssertEqual(run.descriptions[1], "toolActivity(ws_u|webSearch|Searching the web|done)")
        XCTAssertEqual(run.result.content, [
            ["type": "server_tool_use", "id": "ws_u", "name": "web_search", "input": [:], "otto_provider": "setapp-ai"],
            ["type": "web_search_tool_result", "tool_use_id": "ws_u", "content": [], "otto_provider": "setapp-ai"],
        ])
        XCTAssertEqual(run.result.usage, ["server_tool_use": ["web_search_requests": 1, "web_fetch_requests": 0]])
    }

    func testFindInPageIsAPageRead() throws {
        let find = webCall("ws_f", action: ["type": "find_in_page", "url": .string(Self.forumThread), "pattern": "actor"])
        let run = try replay(events: [created(), completed([find])])
        XCTAssertEqual(run.descriptions[1], "toolActivity(ws_f|webFetch|Reading forums.swift.example|done)")
        XCTAssertEqual(run.result.content.first?["name"], "web_fetch")
    }

    func testTrustLedgerRecordsSynthesizedWebBlocks() throws {
        let content = try replay(ResponsesFixtures.webSearch).result.content
        let transcript: [JSONValue] = [
            ["role": "user", "content": [["type": "text", "text": "What's new in Swift 6.2?"]]],
            ["role": "assistant", "content": .array(content)],
        ]
        let trust = TrustLedger.assess(transcript: transcript, untrustedTools: [:])

        XCTAssertEqual(trust.fresh, [
            ProvenanceSource(kind: .webSearch, severity: .high),
            ProvenanceSource(kind: .webFetch(host: "swift.example"), severity: .high),
        ])
        XCTAssertTrue(trust.caution)
        XCTAssertEqual(trust.provenanceLine, "Requested after reading swift.example")

        // A search with no sources and a page read with no URL still count as web content.
        let bare = try replay(events: [created(), completed([webCall("ws_b", action: ["type": "open_page"])])]).result.content
        let bareTrust = TrustLedger.assess(
            transcript: [transcript[0], ["role": "assistant", "content": .array(bare)]], untrustedTools: [:])
        XCTAssertEqual(bareTrust.fresh, [ProvenanceSource(kind: .webSearch, severity: .high)])
    }

    @MainActor
    func testWebBudgetCountsSynthesizedCalls() throws {
        let content = try replay(ResponsesFixtures.webSearch).result.content
        let left = ChatSession.webBudgetLeft(in: content)
        XCTAssertEqual(left.searches, ToolLimits.webSearchesPerTurn - 1)
        XCTAssertEqual(left.fetches, ToolLimits.webFetchesPerTurn - 1)
    }

    func testSynthesizedBlocksAreSetappAIOnly() throws {
        let content = try replay(ResponsesFixtures.webSearch).result.content
            + replay(ResponsesFixtures.reasoningThenText, model: .sonnet5).result.content
        for block in content {
            switch block.typeName {
            case "server_tool_use", "web_search_tool_result", "web_fetch_tool_result", "otto_responses_reasoning":
                XCTAssertTrue(ProviderBlocks.isSetappAIOnly(block), block.encodedString())
            default:
                XCTAssertFalse(ProviderBlocks.isSetappAIOnly(block), block.encodedString())
            }
        }
        // So a switch to the user's own key sends only the text (the unsigned thinking is dropped from history).
        let kept = AnthropicClient.anthropicMessages([["role": "assistant", "content": .array(content)]])
        XCTAssertEqual(kept.first?["content"]?.arrayValue?.map { $0.typeName ?? "?" }, ["text", "thinking", "text"])
    }

    // MARK: - Stop reasons

    func testContentFilterIsARefusal() throws {
        let run = try replay(events: [
            created(),
            ["type": "response.incomplete", "response": [
                "status": "incomplete", "output": [], "incomplete_details": ["reason": "content_filter"],
            ]],
        ])
        XCTAssertEqual(run.result.stopReason, "refusal")
    }

    func testRefusalWinsOverToolUse() throws {
        let refused: JSONValue = ["id": "msg_r", "type": "message", "content": [["type": "refusal", "refusal": "No."]]]
        let run = try replay(events: [created(), completed([refused, functionCall("fc", callID: "c", name: "reminders_list", arguments: "{}")])])
        XCTAssertEqual(run.result.stopReason, "refusal")
    }

    // MARK: - Errors

    func testErrorEventsMapToLLMErrors() {
        func error(_ event: JSONValue) -> LLMError? {
            var accumulator = ResponsesStreamAccumulator(requestedModel: .opus5)
            do {
                _ = try accumulator.handle(event)
                return nil
            } catch {
                return error as? LLMError
            }
        }

        XCTAssertEqual(error(["type": "error", "code": "server_error", "message": "The model failed."]),
                       .streamError(type: "api_error", message: "The model failed."))
        // Some gateways nest the error object.
        XCTAssertEqual(error(["type": "error", "error": ["code": "INSUFFICIENT_CREDITS", "message": "No credits"]]),
                       .setappAI(.insufficientCredits))
        XCTAssertEqual(error(["type": "response.failed", "response": ["status": "failed", "error": nil]]),
                       .streamError(type: "api_error", message: ""))
        XCTAssertEqual(error(["type": "error", "code": "invalid_request_error", "message": "Too many tokens in the request"]),
                       .http(status: 400, type: "invalid_request_error", message: "prompt is too long: Too many tokens in the request"))
        // Anthropic's wording passes through without a second prefix.
        XCTAssertEqual(error(["type": "error", "code": "invalid_request_error", "message": "prompt is too long: 214318 tokens > 200000 maximum"]),
                       .http(status: 400, type: "invalid_request_error", message: "prompt is too long: 214318 tokens > 200000 maximum"))
        XCTAssertEqual(error(["type": "error", "code": "context_length_exceeded", "message": "Input exceeds the window."]),
                       .http(status: 400, type: "invalid_request_error", message: "prompt is too long: Input exceeds the window."))
    }

    @MainActor
    func testEveryOverflowWordingReadsAsAContextOverflow() {
        for message in ["prompt is too long: 210000 tokens", "Exceeds the context length of the model",
                        "too many tokens", "This model's maximum context length is 200000 tokens"] {
            let error = ResponsesStreamAccumulator.eventError(code: nil, message: message)
            XCTAssertTrue(ChatSession.isContextOverflow(error), message)
        }
        XCTAssertFalse(ChatSession.isContextOverflow(ResponsesStreamAccumulator.eventError(code: nil, message: "Something broke")))
    }
}
