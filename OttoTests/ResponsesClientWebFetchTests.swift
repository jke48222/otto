//
//  ResponsesClientWebFetchTests.swift
//  OttoTests
//
//  How `ResponsesClient` answers Claude's `web_fetch` calls on Setapp AI (SPEC §19): within one stream, like an
//  Anthropic server tool. The read on the Mac, the reply going on with the page, the per-request limit, refusals
//  Claude reads, a call beside client tools, a call that won't run, the compatibility retry, cancellation, and the
//  usage. Gateway streams are synthesized in OpenAI's documented Responses format; pages come from a
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

    // MARK: The reply goes on with the page

    func testAPageReadContinuesTheReplyInOneStream() async throws {
        let page = ScriptedPageReader.page("https://docs.example/guide/v2", title: "The Guide", text: "Install it with Homebrew.",
                                           links: [WebLink(text: "FAQ", url: URL(string: "https://docs.example/faq")!)])
        let reader = ScriptedPageReader([tabURL: .page(page)])
        let (events, error, transport) = await run([
            gatewayStream("resp_1", [message("msg_1", "Reading your tab."), fetchCall("call_page", url: tabURL)],
                          inputTokens: 1_000, outputTokens: 30),
            gatewayStream("resp_2", [message("msg_2", " It says to install it with Homebrew.")],
                          inputTokens: 1_500, outputTokens: 20),
        ], reader: reader)

        XCTAssertNil(error)
        XCTAssertEqual(events.map(label), [
            "start", "text(Reading your tab.)", "Reading docs.example", "usage",
            "Reading docs.example (done)", "sources(https://docs.example/guide/v2)", "usage",
            "text( It says to install it with Homebrew.)", "usage", "completed(end_turn)",
        ])
        XCTAssertEqual(reader.reads, [tabURL])

        let completed = try result(events)
        XCTAssertEqual(completed.model, "anthropic/claude-opus-5")
        XCTAssertEqual(completed.content, [
            ["type": "text", "text": "Reading your tab."],
            SetappWebFetch.callBlock(id: "call_page", input: ["url": .string(tabURL)]),
            SetappWebFetch.resultBlock(id: "call_page", page: page),
            ["type": "text", "text": " It says to install it with Homebrew."],
        ])
        XCTAssertEqual(completed.usage, [
            "input_tokens": 2_500, "cache_read_input_tokens": 0, "output_tokens": 50,
            "server_tool_use": ["web_fetch_requests": 1],
        ], "both requests' tokens, and the read as a fetch")
        if case .sources(let links)? = events.first(where: { if case .sources = $0 { return true }; return false }) {
            XCTAssertEqual(links.first?.title, "The Guide")
        }

        // The second request is the first plus the call and the page, so Claude reads the page and goes on.
        let bodies = transport.bodies
        XCTAssertEqual(bodies.count, 2)
        let first = inputItems(bodies.first)
        let second = inputItems(bodies.last)
        XCTAssertEqual(Array(second.prefix(first.count)), first)
        XCTAssertEqual(Array(second.dropFirst(first.count)), [
            ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Reading your tab."]]],
            ["type": "function_call", "call_id": "call_page", "name": "web_fetch",
             "arguments": .string(#"{"url":"\#(tabURL)"}"#)],
            ["type": "function_call_output", "call_id": "call_page",
             "output": "URL: https://docs.example/guide/v2\nTitle: The Guide\n\nInstall it with Homebrew.\n\nLinks on the page:\n- FAQ: https://docs.example/faq"],
        ])
        for body in bodies {
            XCTAssertEqual(toolNames(body), ["web_search", "web_fetch"])
            XCTAssertNil(body["tool_choice"])
        }
    }

    func testAnAddressNotInTheConversationIsRefusedAndClaudeIsToldWhy() async throws {
        let reader = ScriptedPageReader()
        let (events, error, transport) = await run([
            gatewayStream("resp_1", [fetchCall("call_made_up", url: "https://docs.example/guide?user=jalen")]),
            gatewayStream("resp_2", [message("msg_2", "I can only read pages from this chat.")]),
        ], reader: reader)

        XCTAssertNil(error)
        XCTAssertTrue(reader.reads.isEmpty, "nothing was requested")
        XCTAssertFalse(events.contains { if case .sources = $0 { return true }; return false })
        let output = inputItems(transport.bodies.last).last
        XCTAssertEqual(output, ["type": "function_call_output", "call_id": "call_made_up",
                                "output": .string("Error: " + SetappWebFetch.Failure.notInConversation.message)])
        XCTAssertEqual(output?["output"]?.stringValue?.hasPrefix(
            "Error: This URL isn't in the conversation, so Otto can't open it."), true)
        let completed = try result(events)
        XCTAssertEqual(completed.content[1]["content"]?["error_code"], "url_not_allowed")
        XCTAssertEqual(completed.usage?["server_tool_use"]?["web_fetch_requests"], 1, "a refused call spends its fetch")
    }

    func testAPageThatCantBeReadIsReportedToClaude() async throws {
        let reader = ScriptedPageReader([tabURL: .failure(.blockedAddress)])
        let (events, error, transport) = await run([
            gatewayStream("resp_1", [fetchCall("call_page", url: tabURL)]),
            gatewayStream("resp_2", [message("msg_2", "That page is on your local network.")]),
        ], reader: reader)

        XCTAssertNil(error)
        XCTAssertEqual(reader.reads, [tabURL])
        XCTAssertEqual(inputItems(transport.bodies.last).last?["output"],
                       .string("Error: " + WebPageReadError.blockedAddress.message))
        XCTAssertTrue(events.contains { label($0) == "Reading docs.example (done)" })
        XCTAssertEqual(try result(events).content.count, 3)
    }

    // MARK: Limits

    func testCallsPastTheRequestsLimitAreToldSoWithoutSpendingAFetch() async throws {
        let other = "https://docs.example/faq"
        let reader = ScriptedPageReader([tabURL: .page(ScriptedPageReader.page(tabURL, text: "Guide text. See \(other)"))])
        let (events, error, transport) = await run([
            gatewayStream("resp_1", [fetchCall("call_1", url: tabURL), fetchCall("call_2", url: tabURL)]),
            gatewayStream("resp_2", [fetchCall("call_3", url: other)]),
            gatewayStream("resp_3", [message("msg_3", "Here's the gist.")]),
        ], reader: reader, request: makeRequest(limits: ServerToolLimits(webSearch: 5, webFetch: 1)))

        XCTAssertNil(error)
        XCTAssertEqual(reader.reads, [tabURL], "only the first call was read")
        let second = inputItems(transport.bodies[1])
        XCTAssertEqual(second.last, ["type": "function_call_output", "call_id": "call_2",
                                     "output": .string("Error: " + SetappWebFetch.Failure.maxUsesExceeded.message)])
        XCTAssertEqual(inputItems(transport.bodies[2]).last?["output"],
                       .string("Error: " + SetappWebFetch.Failure.maxUsesExceeded.message))
        XCTAssertEqual(try result(events).usage?["server_tool_use"]?["web_fetch_requests"], 1)
    }

    func testAReplyThatKeepsCallingIsAskedToAnswer() async throws {
        let reader = ScriptedPageReader([tabURL: .page(ScriptedPageReader.page(tabURL, text: "Guide text."))])
        let limit = 2
        let calls = (0..<(limit + 2)).map { index in
            gatewayStream("resp_\(index)", [fetchCall("call_\(index)", url: tabURL)])
        }
        let (events, error, transport) = await run(calls + [gatewayStream("resp_end", [message("msg_end", "Done.")])],
                                                   reader: reader,
                                                   request: makeRequest(limits: ServerToolLimits(webSearch: 5, webFetch: limit)))

        XCTAssertNil(error)
        XCTAssertEqual(reader.reads.count, limit)
        XCTAssertEqual(transport.bodies.count, limit + 2, "the limit's requests, one more, then the last one")
        XCTAssertEqual(transport.bodies.map { $0["tool_choice"] },
                       Array(repeating: nil, count: limit + 1) + ["none"], "the last request asks for an answer")
        let completed = try result(events)
        XCTAssertEqual(completed.stopReason, "end_turn")
        XCTAssertFalse(completed.content.contains { $0.typeName == "server_tool_use" && $0["id"]?.stringValue == "call_\(limit + 1)" },
                       "a call the forced answer still made is dropped, not run")
        XCTAssertEqual(completed.usage?["server_tool_use"]?["web_fetch_requests"], .int(Int64(limit)))
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
        XCTAssertEqual(transport.bodies.count, 1, "the reply didn't go on")
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
