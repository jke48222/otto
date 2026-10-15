//
//  ResponsesClientWebFetchTests.swift
//  OttoTests
//
//  How `ResponsesClient` answers Claude's `web_fetch` calls on Setapp AI (SPEC §19): it reads the pages on the Mac
//  and ends the response with `pause_turn` (or `tool_use` beside client calls), and never sends a gateway request of
//  its own; ChatSession's next request carries the pages (SetappAIIntegrationTests). The read, the per-request limit,
//  refusals Claude reads, a call beside client tools, calls that won't run, the compatibility retry, cancellation,
//  and the usage. Gateway streams are synthesized in OpenAI's documented Responses format; pages come from a
//  `ScriptedPageReader`, so nothing reaches the network.
//

import XCTest
@testable import Otto

private let tabURL = "https://docs.example/guide"
private let question = "What does this page say?"

/// A complete gateway response: created, each item added and done (a function call streams its arguments), then
/// `response.completed` (or `response.incomplete` with `reason`) carrying every item and the usage.
private func gatewayStream(_ id: String, _ items: [JSONValue], inputTokens: Int = 1_000, outputTokens: Int = 40,
                           incomplete reason: String? = nil) -> [JSONValue] {
    var events: [JSONValue] = [["type": "response.created", "response": [
        "id": .string(id), "status": "in_progress", "model": "anthropic/claude-opus-5", "output": [],
    ]]]
    for (index, item) in items.enumerated() {
        let outputIndex = JSONValue.int(Int64(index))
        events.append(["type": "response.output_item.added", "output_index": outputIndex,
                       "item": item.typeName == "function_call" ? item.setting("arguments", to: "") : item])
        if item.typeName == "function_call" {
            events.append(["type": "response.function_call_arguments.delta", "item_id": item["id"] ?? "",
                           "output_index": outputIndex, "delta": item["arguments"] ?? ""])
        }
        if item.typeName == "message" {
            events.append(["type": "response.output_text.delta", "item_id": item["id"] ?? "", "output_index": outputIndex,
                           "content_index": 0, "delta": item["content"]?[0]?["text"] ?? ""])
        }
        events.append(["type": "response.output_item.done", "output_index": outputIndex, "item": item])
    }
    events.append([
        "type": .string(reason == nil ? "response.completed" : "response.incomplete"),
        "response": [
            "id": .string(id), "status": .string(reason == nil ? "completed" : "incomplete"),
            "model": "anthropic/claude-opus-5", "output": .array(items),
            "incomplete_details": reason.map { ["reason": .string($0)] as JSONValue } ?? .null,
            "usage": ["input_tokens": .int(Int64(inputTokens)), "input_tokens_details": ["cached_tokens": 0],
                      "output_tokens": .int(Int64(outputTokens))],
        ],
    ])
    return events
}

private func fetchCall(_ callID: String, url: String) -> JSONValue {
    ["id": .string("fc_" + callID), "type": "function_call", "status": "completed", "call_id": .string(callID),
     "name": "web_fetch", "arguments": .string(#"{"url":"\#(url)"}"#)]
}

private func clientCall(_ callID: String, name: String = "echo", arguments: String = #"{"text":"hi"}"#) -> JSONValue {
    ["id": .string("fc_" + callID), "type": "function_call", "status": "completed", "call_id": .string(callID),
     "name": .string(name), "arguments": .string(arguments)]
}

private func message(_ id: String, _ text: String) -> JSONValue {
    ["id": .string(id), "type": "message", "status": "completed", "role": "assistant",
     "content": [["type": "output_text", "text": .string(text), "annotations": []]]]
}

private func label(_ event: StreamEvent) -> String {
    switch event {
    case .messageStart: return "start"
    case .thinkingStarted: return "thinking"
    case .thinkingDelta: return "thinkingDelta"
    case .textDelta(let text): return "text(\(text))"
    case .toolActivity(let activity): return "\(activity.label)\(activity.isDone ? " (done)" : "")"
    case .sources(let links): return "sources(\(links.map(\.url.absoluteString).joined(separator: ",")))"
    case .fallback: return "fallback"
    case .completed(let result): return "completed(\(result.stopReason ?? "nil"))"
    case .toolUseStarted(let id, _): return "toolUseStarted(\(id))"
    case .toolUseReady(let id, _, _, _): return "toolUseReady(\(id))"
    case .usage: return "usage"
    }
}

private func inputItems(_ body: JSONValue?) -> [JSONValue] {
    body?["input"]?.arrayValue ?? []
}

private func toolNames(_ body: JSONValue?) -> [String] {
    (body?["tools"]?.arrayValue ?? []).compactMap { $0.typeName == "function" ? $0["name"]?.stringValue : $0.typeName }
}

final class ResponsesClientWebFetchTests: XCTestCase {
    private func makeRequest(
        messages: [JSONValue]? = nil,
        limits: ServerToolLimits = ServerToolLimits(),
        clientTools: [JSONValue] = [],
        toolChoice: JSONValue? = nil
    ) -> MessagesRequest {
        let tab = "<browser_tab>\nTitle: Guide\nURL: \(tabURL)\n</browser_tab>"
        return MessagesRequest(
            model: .opus5,
            system: "You are Otto.",
            messages: messages ?? [["role": "user", "content": [["type": "text", "text": .string(tab)],
                                                                 ["type": "text", "text": .string(question)]]]],
            maxTokens: 64_000,
            effort: .medium,
            webAccess: true,
            clientTools: clientTools,
            toolChoice: toolChoice,
            serverToolLimits: limits
        )
    }

    private func run(_ attempts: [[JSONValue]], reader: ScriptedPageReader, request: MessagesRequest? = nil)
        async -> (events: [StreamEvent], error: Error?, transport: ScriptedResponsesTransport) {
        let transport = ScriptedResponsesTransport(attempts.map { .events($0) })
        let client = ResponsesClient(transport: transport, retryDelays: [], sleep: { _ in }, pageReader: reader)
        var events: [StreamEvent] = []
        do {
            for try await event in client.stream(request ?? makeRequest()) {
                events.append(event)
            }
            return (events, nil, transport)
        } catch {
            return (events, error, transport)
        }
    }

    private struct NoResult: Error {}

    private func result(_ events: [StreamEvent], file: StaticString = #filePath, line: UInt = #line) throws -> StreamResult {
        guard case .completed(let result)? = events.last else {
            XCTFail("No completed event: \(events.map(label))", file: file, line: line)
            throw NoResult()
        }
        return result
    }

    // MARK: The response pauses after the pages

    func testAPageReadEndsTheResponseWithPauseTurn() async throws {
        let page = ScriptedPageReader.page("https://docs.example/guide/v2", title: "The Guide", text: "Install it with Homebrew.",
                                           links: [WebLink(text: "FAQ", url: URL(string: "https://docs.example/faq")!)])
        let reader = ScriptedPageReader([tabURL: .page(page)])
        let (events, error, transport) = await run([
            gatewayStream("resp_1", [message("msg_1", "Reading your tab."), fetchCall("call_page", url: tabURL)],
                          inputTokens: 1_000, outputTokens: 30),
            gatewayStream("resp_2", [message("msg_2", "Never requested.")]),
        ], reader: reader)

        XCTAssertNil(error)
        XCTAssertEqual(events.map(label), [
            "start", "text(Reading your tab.)", "Reading docs.example", "usage",
            "Reading docs.example (done)", "sources(https://docs.example/guide/v2)", "usage", "completed(pause_turn)",
        ])
        XCTAssertEqual(reader.reads, [tabURL])
        XCTAssertEqual(transport.bodies.count, 1, "the client sends no request of its own; ChatSession sends the next")

        let completed = try result(events)
        XCTAssertEqual(completed.model, "anthropic/claude-opus-5")
        XCTAssertEqual(completed.content, [
            ["type": "text", "text": "Reading your tab."],
            SetappWebFetch.callBlock(id: "call_page", input: ["url": .string(tabURL)]),
            SetappWebFetch.resultBlock(id: "call_page", page: page),
        ])
        XCTAssertEqual(completed.usage, [
            "input_tokens": 1_000, "cache_read_input_tokens": 0, "output_tokens": 30,
            "server_tool_use": ["web_fetch_requests": 1],
        ], "the gateway's tokens, and the read as a fetch")
        if case .usage(let usage)? = events.dropLast().last {
            XCTAssertEqual(usage, completed.usage, "the last usage before the end counts the read too")
        }
        if case .sources(let links)? = events.first(where: { if case .sources = $0 { return true }; return false }) {
            XCTAssertEqual(links.first?.title, "The Guide")
        }
        XCTAssertEqual(toolNames(transport.bodies.first), ["web_search", "web_fetch"])
    }

    func testAnAddressNotInTheConversationIsRefusedAndClaudeIsToldWhy() async throws {
        let reader = ScriptedPageReader()
        let (events, error, _) = await run([
            gatewayStream("resp_1", [fetchCall("call_made_up", url: "https://docs.example/guide?user=jalen")]),
        ], reader: reader)

        XCTAssertNil(error)
        XCTAssertTrue(reader.reads.isEmpty, "nothing was requested")
        XCTAssertFalse(events.contains { if case .sources = $0 { return true }; return false })
        let completed = try result(events)
        XCTAssertEqual(completed.stopReason, "pause_turn")
        XCTAssertEqual(completed.content[1]["content"]?["error_code"], "url_not_allowed")
        XCTAssertEqual(SetappWebFetch.outputText(ofResult: completed.content[1]),
                       "Error: " + SetappWebFetch.Failure.notInConversation.message)
        XCTAssertEqual(completed.usage?["server_tool_use"]?["web_fetch_requests"], 1, "a refused call spends its fetch")
    }

    func testAPageThatCantBeReadIsReportedToClaude() async throws {
        let reader = ScriptedPageReader([tabURL: .failure(.blockedAddress)])
        let (events, error, _) = await run([gatewayStream("resp_1", [fetchCall("call_page", url: tabURL)])], reader: reader)

        XCTAssertNil(error)
        XCTAssertEqual(reader.reads, [tabURL])
        XCTAssertTrue(events.contains { label($0) == "Reading docs.example (done)" })
        let completed = try result(events)
        XCTAssertEqual(completed.content.count, 2)
        XCTAssertEqual(SetappWebFetch.outputText(ofResult: completed.content[1]),
                       "Error: " + WebPageReadError.blockedAddress.message)
    }

    // MARK: Limits

    func testCallsPastTheRequestsLimitAreToldSoWithoutSpendingAFetch() async throws {
        let reader = ScriptedPageReader([tabURL: .page(ScriptedPageReader.page(tabURL, text: "Guide text."))])
        let (events, error, transport) = await run([
            gatewayStream("resp_1", [fetchCall("call_1", url: tabURL), fetchCall("call_2", url: tabURL),
                                     fetchCall("call_3", url: tabURL)]),
        ], reader: reader, request: makeRequest(limits: ServerToolLimits(webSearch: 5, webFetch: 2)))

        XCTAssertNil(error)
        XCTAssertEqual(reader.reads, [tabURL, tabURL], "only the first two calls were read")
        XCTAssertEqual(transport.bodies.count, 1)
        let completed = try result(events)
        XCTAssertEqual(completed.stopReason, "pause_turn")
        XCTAssertEqual(completed.content.map { $0["content"]?.typeName ?? $0.typeName ?? "" },
                       ["server_tool_use", "web_fetch_result", "server_tool_use", "web_fetch_result",
                        "server_tool_use", "web_fetch_tool_error"])
        XCTAssertEqual(completed.content[5]["content"]?["error_code"], "max_uses_exceeded")
        XCTAssertEqual(SetappWebFetch.outputText(ofResult: completed.content[5]),
                       "Error: " + SetappWebFetch.Failure.maxUsesExceeded.message)
        XCTAssertEqual(completed.usage?["server_tool_use"]?["web_fetch_requests"], 2)
    }

    /// A call reusing the id of one the conversation already holds is never run, so no two pairs share an id.
    func testACallReusingAnEarlierIDIsNotRun() async throws {
        let reader = ScriptedPageReader([tabURL: .page(ScriptedPageReader.page(tabURL, text: "Guide text."))])
        let earlier = makeRequest().messages + [
            ["role": "assistant", "content": [
                SetappWebFetch.callBlock(id: "call_page", input: ["url": .string(tabURL)]),
                SetappWebFetch.resultBlock(id: "call_page", page: ScriptedPageReader.page(tabURL, text: "Guide text.")),
            ]],
        ]
        let (events, _, _) = await run([
            gatewayStream("resp_2", [fetchCall("call_page", url: tabURL), message("msg_2", "Done.")]),
        ], reader: reader, request: makeRequest(messages: earlier))
        XCTAssertTrue(reader.reads.isEmpty)
        let completed = try result(events)
        XCTAssertEqual(completed.stopReason, "end_turn")
        XCTAssertEqual(completed.content, [["type": "text", "text": "Done."]])
        XCTAssertNil(completed.usage?["server_tool_use"])
    }

    // MARK: Beside client tools, and calls that don't run

    func testAPageReadBesideAClientCallEndsWithTheToolRound() async throws {
        let page = ScriptedPageReader.page(tabURL, text: "Guide text.")
        let reader = ScriptedPageReader([tabURL: .page(page)])
        let echo = EchoTool().definition()
        let (events, error, transport) = await run([
            gatewayStream("resp_1", [fetchCall("call_page", url: tabURL), clientCall("call_echo")]),
        ], reader: reader, request: makeRequest(clientTools: [echo]))

        XCTAssertNil(error)
        XCTAssertEqual(transport.bodies.count, 1, "the tool loop sends the next request")
        XCTAssertEqual(reader.reads, [tabURL])
        let labels = events.map(label)
        XCTAssertTrue(labels.contains("toolUseReady(call_echo)"))
        XCTAssertFalse(labels.contains("toolUseStarted(call_page)"), "a page read never becomes a tool row")
        XCTAssertFalse(labels.contains("toolUseReady(call_page)"))
        let completed = try result(events)
        XCTAssertEqual(completed.stopReason, "tool_use")
        XCTAssertEqual(completed.content, [
            SetappWebFetch.callBlock(id: "call_page", input: ["url": .string(tabURL)]),
            SetappWebFetch.resultBlock(id: "call_page", page: page),
            ["type": "tool_use", "id": "call_echo", "name": "echo", "input": ["text": "hi"]],
        ])
        XCTAssertEqual(toolNames(transport.bodies.first), ["web_search", "web_fetch", "echo"])
    }

    func testACallCutOffByTheOutputLimitIsNotRun() async throws {
        let reader = ScriptedPageReader([tabURL: .page(ScriptedPageReader.page(tabURL, text: "Guide text."))])
        let (events, error, transport) = await run([
            gatewayStream("resp_1", [message("msg_1", "Let me read"), fetchCall("call_page", url: tabURL)],
                          incomplete: "max_output_tokens"),
        ], reader: reader)

        XCTAssertNil(error)
        XCTAssertTrue(reader.reads.isEmpty)
        XCTAssertEqual(transport.bodies.count, 1)
        let completed = try result(events)
        XCTAssertEqual(completed.stopReason, "max_tokens")
        XCTAssertEqual(completed.content, [["type": "text", "text": "Let me read"]])
        XCTAssertNil(completed.usage?["server_tool_use"])
    }

    func testAWrapUpRequestRunsNoRead() async throws {
        let reader = ScriptedPageReader([tabURL: .page(ScriptedPageReader.page(tabURL, text: "Guide text."))])
        let (events, _, transport) = await run([
            gatewayStream("resp_1", [message("msg_1", "Wrapping up."), fetchCall("call_page", url: tabURL)]),
        ], reader: reader, request: makeRequest(toolChoice: ["type": "none"]))
        XCTAssertTrue(reader.reads.isEmpty)
        XCTAssertEqual(transport.bodies.count, 1)
        XCTAssertEqual(try result(events).content, [["type": "text", "text": "Wrapping up."]])
    }

    func testWithoutWebFetchInTheRequestACallIsAnOrdinaryToolCall() async throws {
        let reader = ScriptedPageReader([tabURL: .page(ScriptedPageReader.page(tabURL, text: "Guide text."))])
        let (events, _, transport) = await run([
            gatewayStream("resp_1", [fetchCall("call_page", url: tabURL)]),
        ], reader: reader, request: makeRequest(limits: .none))
        XCTAssertTrue(reader.reads.isEmpty)
        XCTAssertFalse(toolNames(transport.bodies.first).contains("web_fetch"))
        XCTAssertTrue(events.map(label).contains("toolUseReady(call_page)"), "the tool loop answers it as unknown")
        XCTAssertEqual(try result(events).stopReason, "tool_use")
    }

    // MARK: Compatibility retry and cancellation

    func testTheCompatibilityRetryLeavesWebFetchOut() async throws {
        let request = makeRequest()
        let transport = ScriptedResponsesTransport([
            .failure(ResponsesTransportError.badRequest(status: 400, message: "tools.1: unknown tool"), after: []),
            .events(gatewayStream("resp_1", [message("msg_1", "Answer.")])),
        ])
        let client = ResponsesClient(transport: transport, retryDelays: [], sleep: { _ in },
                                     pageReader: ScriptedPageReader())
        var last: StreamEvent?
        for try await event in client.stream(request) { last = event }
        XCTAssertEqual(last.map(label), "completed(end_turn)")
        XCTAssertEqual(transport.bodies.count, 2)
        XCTAssertEqual(toolNames(transport.bodies[0]), ["web_search", "web_fetch"])
        XCTAssertEqual(toolNames(transport.bodies[1]), ["web_search"])
        XCTAssertTrue(ResponsesClient.usesNegotiableFeatures(["tools": [SetappWebFetch.functionTool(strict: false)]]))
        XCTAssertFalse(ResponsesClient.usesNegotiableFeatures(["tools": [["type": "function", "name": "echo", "strict": false]]]))
    }

    func testStoppingTheReplyCancelsTheRead() async throws {
        let reader = ScriptedPageReader([tabURL: .hang])
        let started = expectation(description: "read started")
        reader.onStart { _ in started.fulfill() }
        let transport = ScriptedResponsesTransport([
            .events(gatewayStream("resp_1", [fetchCall("call_page", url: tabURL)])),
            .events(gatewayStream("resp_2", [message("msg_2", "Never sent.")])),
        ])
        let client = ResponsesClient(transport: transport, retryDelays: [], sleep: { _ in }, pageReader: reader)
        let consumer = Task {
            var labels: [String] = []
            for try await event in client.stream(makeRequest()) { labels.append(label(event)) }
            return labels
        }
        await fulfillment(of: [started], timeout: 5)
        consumer.cancel()
        let outcome = await consumer.result
        if case .success(let labels) = outcome {
            XCTAssertFalse(labels.contains { $0.hasPrefix("completed") }, "\(labels)")
        }
        let deadline = Date().addingTimeInterval(5)
        while reader.cancellations == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(reader.cancellations, 1, "the read was cancelled")
        XCTAssertEqual(transport.bodies.count, 1)
    }

    // MARK: Usage

    func testUsageAddsUpNumberByNumber() {
        XCTAssertNil(ResponsesClient.addingUsage(nil, nil))
        XCTAssertEqual(ResponsesClient.addingUsage(nil, ["output_tokens": 3]), ["output_tokens": 3])
        XCTAssertEqual(ResponsesClient.addingUsage(["output_tokens": 3], nil), ["output_tokens": 3])
        XCTAssertEqual(ResponsesClient.addingUsage(
            ["input_tokens": 10, "output_tokens": 3, "server_tool_use": ["web_search_requests": 1]],
            ["input_tokens": 5, "cache_read_input_tokens": 2, "server_tool_use": ["web_search_requests": 1,
                                                                                    "web_fetch_requests": 1]]
        ), ["input_tokens": 15, "output_tokens": 3, "cache_read_input_tokens": 2,
            "server_tool_use": ["web_search_requests": 2, "web_fetch_requests": 1]])
    }
}
