//
//  StreamAccumulatorTests.swift
//  Otto
//

import XCTest
@testable import Otto

/// Recorded Messages API SSE transcripts shared by the API tests.
enum APIStreamFixtures {
    static let searchToolUseID = "srvtoolu_01WYG3ziw53XMcoyKL4XcZmE"
    static let thinkingSignature = "EuYBCkQYAiJAgCs6vY3ukbQoUQf6Wn0xMSxQ/f1g7rjT0dJ1Pb3sB9pD1mJv2hFyuPiT4sEWNnS+3o5f2+CqWn1d2x5Y1Dg=="

    /// Opus 5 with adaptive thinking (summarized), one web search, a cited text block and usage.
    static let webSearchTranscript = #"""
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_01Wq7Hn5Jd9bVxkqJ3Ze2Yc8","type":"message","role":"assistant","model":"claude-opus-5","content":[],"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{"input_tokens":2143,"cache_creation_input_tokens":1790,"cache_read_input_tokens":0,"output_tokens":4,"service_tier":"standard"}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

    event: ping
    data: {"type": "ping"}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The user wants to know what's new in Swift 6.2."}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" I'll search for the release announcement."}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EuYBCkQYAiJAgCs6vY3ukbQoUQf6Wn0xMSxQ/f1g7rjT0dJ1Pb3sB9pD1mJv2hFyuPiT4sEWNnS+3o5f2+CqWn1d2x5Y1Dg=="}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srvtoolu_01WYG3ziw53XMcoyKL4XcZmE","name":"web_search","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"Swift 6.2"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" release notes\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: content_block_start
    data: {"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_01WYG3ziw53XMcoyKL4XcZmE","content":[{"type":"web_search_result","title":"Swift 6.2 Released | Swift.org","url":"https://www.swift.org/blog/swift-6.2-released/","encrypted_content":"EqgfCioIARgBIiQ3YTAwMjY1Mi1mZjM5LTQ1NGUtODgxNC1kNjNjNTk1ZWI3Y2YSDAmv","page_age":"September 15, 2025"},{"type":"web_search_result","title":"","url":"https://www.hackingwithswift.com/articles/277/whats-new-in-swift-6-2","encrypted_content":"Ep4BCioIARgBIiQ","page_age":null}]}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":2}

    event: content_block_start
    data: {"type":"content_block_start","index":3,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"Swift 6.2 focuses on "}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"approachable concurrency."}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":3}

    event: content_block_start
    data: {"type":"content_block_start","index":4,"content_block":{"type":"text","text":"","citations":[]}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":4,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","cited_text":"Swift 6.2 makes concurrency more approachable…","url":"https://www.swift.org/blog/swift-6.2-released/","title":"Swift 6.2 Released | Swift.org","encrypted_index":"Eo8BCioIAhgBIiQyYjQ0OWJmZi1lNm"}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":4,"delta":{"type":"text_delta","text":" Code now runs on the main actor by default in app targets."}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":4}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null,"stop_details":null},"usage":{"input_tokens":9872,"cache_creation_input_tokens":1790,"cache_read_input_tokens":0,"output_tokens":412,"server_tool_use":{"web_search_requests":1}}}

    event: message_stop
    data: {"type":"message_stop"}


    """#

    /// Opus 5 declines mid-stream; the server re-runs on the default fallback model.
    static let fallbackTranscript = #"""
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_01FbK2","type":"message","role":"assistant","model":"claude-opus-5","content":[],"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{"input_tokens":812,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Sure — to probe that port"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":{"model":"claude-opus-5"},"to":{"model":"claude-opus-4-8"}}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: content_block_start
    data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Use `nc -zv host 443` to check the port."}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":2}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null,"stop_details":null},"usage":{"output_tokens":58}}

    event: message_stop
    data: {"type":"message_stop"}

    """#
}

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
    }
}

final class StreamAccumulatorTests: XCTestCase {
    private struct Replay {
        var events: [StreamEvent]
        var accumulator: StreamAccumulator
        var descriptions: [String] { events.map(describe) }
    }

    /// Runs a raw SSE transcript through the same splitter → parser → accumulator path the client uses.
    private func replay(_ transcript: String, priorMessages: [JSONValue] = []) throws -> Replay {
        var splitter = SSELineSplitter()
        var parser = SSEParser()
        var accumulator = StreamAccumulator()
        accumulator.registerPriorToolUses(in: priorMessages)
        var events: [StreamEvent] = []

        func feed(_ line: String) throws {
            if let event = parser.consume(line: line) {
                events += try accumulator.handle(event)
            }
        }
        for byte in transcript.utf8 {
            if let line = try splitter.append(byte) {
                try feed(line)
            }
        }
        if let line = splitter.finish() {
            try feed(line)
        }
        return Replay(events: events, accumulator: accumulator)
    }

    private func replay(events: [JSONValue], priorMessages: [JSONValue] = []) throws -> Replay {
        let transcript = events.map { "data: \($0.encodedString())\n\n" }.joined()
        return try replay(transcript, priorMessages: priorMessages)
    }

    // MARK: - Recorded stream

    func testRecordedWebSearchStreamEmitsEventsInOrder() throws {
        let run = try replay(APIStreamFixtures.webSearchTranscript)
        let id = APIStreamFixtures.searchToolUseID

        XCTAssertEqual(run.descriptions, [
            "messageStart(claude-opus-5)",
            "thinkingStarted",
            "thinkingDelta(The user wants to know what's new in Swift 6.2.)",
            "thinkingDelta( I'll search for the release announcement.)",
            "toolActivity(\(id)|webSearch|Searching \u{201C}Swift 6.2 release notes\u{201D}|running)",
            "toolActivity(\(id)|webSearch|Searching \u{201C}Swift 6.2 release notes\u{201D}|done)",
            "sources(Swift 6.2 Released | Swift.org|https://www.swift.org/blog/swift-6.2-released/, "
                + "hackingwithswift.com|https://www.hackingwithswift.com/articles/277/whats-new-in-swift-6-2)",
            "textDelta(Swift 6.2 focuses on )",
            "textDelta(approachable concurrency.)",
            "sources(Swift 6.2 Released | Swift.org|https://www.swift.org/blog/swift-6.2-released/)",
            "textDelta( Code now runs on the main actor by default in app targets.)",
        ])
        XCTAssertTrue(run.accumulator.isComplete)
    }

    func testRecordedWebSearchStreamAssemblesContentBlocks() throws {
        let result = try replay(APIStreamFixtures.webSearchTranscript).accumulator.result()

        XCTAssertEqual(result.model, "claude-opus-5")
        XCTAssertEqual(result.stopReason, "end_turn")
        XCTAssertNil(result.stopDetails)
        XCTAssertEqual(result.content.map { $0.typeName ?? "?" },
                       ["thinking", "server_tool_use", "web_search_tool_result", "text", "text"])

        XCTAssertEqual(result.content[0], [
            "type": "thinking",
            "thinking": "The user wants to know what's new in Swift 6.2. I'll search for the release announcement.",
            "signature": .string(APIStreamFixtures.thinkingSignature),
        ])
        XCTAssertEqual(result.content[1], [
            "type": "server_tool_use",
            "id": .string(APIStreamFixtures.searchToolUseID),
            "name": "web_search",
            "input": ["query": "Swift 6.2 release notes"],
        ])
        // Result blocks are echoed back verbatim, encrypted content included.
        XCTAssertEqual(result.content[2]["content"]?[0]?["encrypted_content"],
                       "EqgfCioIARgBIiQ3YTAwMjY1Mi1mZjM5LTQ1NGUtODgxNC1kNjNjNTk1ZWI3Y2YSDAmv")
        XCTAssertEqual(result.content[2]["content"]?.arrayValue?.count, 2)
        XCTAssertEqual(result.content[3], ["type": "text", "text": "Swift 6.2 focuses on approachable concurrency."])

        let cited = result.content[4]
        XCTAssertEqual(cited["text"], " Code now runs on the main actor by default in app targets.")
        XCTAssertEqual(cited["citations"]?.arrayValue?.count, 1)
        XCTAssertEqual(cited["citations"]?[0]?["encrypted_index"], "Eo8BCioIAhgBIiQyYjQ0OWJmZi1lNm")
        XCTAssertEqual(cited["citations"]?[0]?["type"], "web_search_result_location")
    }

    func testMessageDeltaMergesUsage() throws {
        let usage = try XCTUnwrap(replay(APIStreamFixtures.webSearchTranscript).accumulator.result().usage)
        XCTAssertEqual(usage["input_tokens"], 9872)
        XCTAssertEqual(usage["output_tokens"], 412)
        XCTAssertEqual(usage["cache_creation_input_tokens"], 1790)
        XCTAssertEqual(usage["service_tier"], "standard")  // kept from message_start
        XCTAssertEqual(usage["server_tool_use"]?["web_search_requests"], 1)
    }

    func testRefusalStopDetailsAreRecorded() throws {
        let run = try replay(events: [
            ["type": "message_start", "message": ["model": "claude-opus-5", "content": [], "usage": ["input_tokens": 40]]],
            ["type": "message_delta",
             "delta": ["stop_reason": "refusal",
                       "stop_details": ["type": "refusal", "category": "cyber", "explanation": "Declined."]],
             "usage": ["output_tokens": 0]],
            ["type": "message_stop"],
        ])
        let result = run.accumulator.result()
        XCTAssertEqual(result.stopReason, "refusal")
        XCTAssertEqual(result.stopDetails?["category"], "cyber")
        XCTAssertTrue(result.content.isEmpty)
        XCTAssertEqual(run.descriptions, ["messageStart(claude-opus-5)"])
    }

    // MARK: - Tool input assembly

    func testPartialJSONToolInputAssembly() throws {
        let fragments = [#"{"locat"#, #"ion": "San Francisco, CA", "#, #""unit": "celsius", "#,
                         #""tags": ["a\"b", "café"], "#, #""nested": {"n": 3}}"#]
        var events: [JSONValue] = [
            ["type": "message_start", "message": ["model": "claude-sonnet-5"]],
            ["type": "content_block_start", "index": 0,
             "content_block": ["type": "tool_use", "id": "toolu_01A", "name": "get_weather", "input": [:]]],
        ]
        events += fragments.map { fragment in
            ["type": "content_block_delta", "index": 0,
             "delta": ["type": "input_json_delta", "partial_json": .string(fragment)]]
        }
        events += [["type": "content_block_stop", "index": 0], ["type": "message_stop"]]

        let run = try replay(events: events)
        let block = try XCTUnwrap(run.accumulator.result().content.first)
        XCTAssertEqual(block["input"], [
            "location": "San Francisco, CA",
            "unit": "celsius",
            "tags": ["a\"b", "caf\u{e9}"],
            "nested": ["n": 3],
        ])
        XCTAssertEqual(block["id"], "toolu_01A")
        // Client tool calls are not server activity.
        XCTAssertEqual(run.descriptions, ["messageStart(claude-sonnet-5)"])
    }

    func testUnparseableOrEmptyToolInputKeepsStartInput() throws {
        let run = try replay(events: [
            ["type": "content_block_start", "index": 0,
             "content_block": ["type": "server_tool_use", "id": "srvtoolu_bad", "name": "web_fetch", "input": ["url": "https://example.com"]]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": "{\"url\": \"https://"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1,
             "content_block": ["type": "tool_use", "id": "toolu_empty", "name": "noop", "input": [:]]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": ""]],
            ["type": "content_block_stop", "index": 1],
            ["type": "message_stop"],
        ])
        let content = run.accumulator.result().content
        XCTAssertEqual(content[0]["input"], ["url": "https://example.com"])
        XCTAssertEqual(content[1]["input"], [:])
        XCTAssertEqual(run.descriptions, ["toolActivity(srvtoolu_bad|webFetch|Reading example.com|running)"])
    }

    // MARK: - Server tools

    func testWebFetchResultMarksDoneAndEmitsSource() throws {
        let run = try replay(events: [
            ["type": "content_block_start", "index": 0,
             "content_block": ["type": "server_tool_use", "id": "srvtoolu_f1", "name": "web_fetch", "input": [:]]],
            ["type": "content_block_delta", "index": 0,
             "delta": ["type": "input_json_delta", "partial_json": "{\"url\": \"https://www.techcrunch.com/2026/09/25/story/\"}"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": [
                "type": "web_fetch_tool_result", "tool_use_id": "srvtoolu_f1",
                "content": ["type": "web_fetch_result", "url": "https://www.techcrunch.com/2026/09/25/story/",
                            "retrieved_at": "2026-09-26T10:00:00Z",
                            "content": ["type": "document", "title": "A TechCrunch story",
                                        "source": ["type": "text", "media_type": "text/plain", "data": "Body"]]],
            ]],
            ["type": "content_block_stop", "index": 1],
            // A fetch whose document has no title falls back to the host.
            ["type": "content_block_start", "index": 2, "content_block": [
                "type": "web_fetch_tool_result", "tool_use_id": "srvtoolu_f2",
                "content": ["type": "web_fetch_result", "url": "https://example.org/a",
                            "content": ["type": "document", "source": ["type": "text", "media_type": "text/plain", "data": "x"]]],
            ]],
            ["type": "content_block_stop", "index": 2],
        ])
        XCTAssertEqual(run.descriptions, [
            "toolActivity(srvtoolu_f1|webFetch|Reading techcrunch.com|running)",
            "toolActivity(srvtoolu_f1|webFetch|Reading techcrunch.com|done)",
            "sources(A TechCrunch story|https://www.techcrunch.com/2026/09/25/story/)",
            "toolActivity(srvtoolu_f2|webFetch|Reading example.org|done)",
            "sources(example.org|https://example.org/a)",
        ])
    }

    func testToolResultErrorsStillMarkActivityDone() throws {
        let run = try replay(events: [
            ["type": "content_block_start", "index": 0,
             "content_block": ["type": "server_tool_use", "id": "srvtoolu_s", "name": "web_search", "input": ["query": "notch apps"]]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": [
                "type": "web_search_tool_result", "tool_use_id": "srvtoolu_s",
                "content": ["type": "web_search_tool_result_error", "error_code": "max_uses_exceeded"],
            ]],
            ["type": "content_block_stop", "index": 1],
            ["type": "content_block_start", "index": 2,
             "content_block": ["type": "server_tool_use", "id": "srvtoolu_f", "name": "web_fetch", "input": ["url": "https://blocked.example/"]]],
            ["type": "content_block_stop", "index": 2],
            ["type": "content_block_start", "index": 3, "content_block": [
                "type": "web_fetch_tool_result", "tool_use_id": "srvtoolu_f",
                "content": ["type": "web_fetch_tool_result_error", "error_code": "url_not_accessible"],
            ]],
            ["type": "content_block_stop", "index": 3],
        ])
        XCTAssertEqual(run.descriptions, [
            "toolActivity(srvtoolu_s|webSearch|Searching \u{201C}notch apps\u{201D}|running)",
            "toolActivity(srvtoolu_s|webSearch|Searching \u{201C}notch apps\u{201D}|done)",
            "toolActivity(srvtoolu_f|webFetch|Reading blocked.example|running)",
            "toolActivity(srvtoolu_f|webFetch|Reading blocked.example|done)",
        ])
    }

    func testOtherServerToolResultFinishesItsActivity() throws {
        let run = try replay(events: [
            ["type": "content_block_start", "index": 0,
             "content_block": ["type": "server_tool_use", "id": "srvtoolu_c", "name": "code_execution", "input": [:]]],
            ["type": "content_block_delta", "index": 0,
             "delta": ["type": "input_json_delta", "partial_json": "{\"code\": \"print(1)\"}"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": [
                "type": "code_execution_tool_result", "tool_use_id": "srvtoolu_c",
                "content": ["type": "code_execution_result", "stdout": "1\n", "stderr": "", "return_code": 0],
            ]],
            ["type": "content_block_stop", "index": 1],
        ])
        XCTAssertEqual(run.descriptions, [
            "toolActivity(srvtoolu_c|other|code_execution|running)",
            "toolActivity(srvtoolu_c|other|code_execution|done)",
        ])
    }

    func testPauseTurnContinuationKeepsPriorToolLabels() throws {
        let prior: [JSONValue] = [
            ["role": "user", "content": [["type": "text", "text": "Find notch apps"]]],
            ["role": "assistant", "content": [
                ["type": "server_tool_use", "id": "srvtoolu_p", "name": "web_search", "input": ["query": "mac notch apps"]],
            ]],
        ]
        let run = try replay(events: [
            ["type": "message_start", "message": ["model": "claude-opus-5"]],
            ["type": "content_block_start", "index": 0, "content_block": [
                "type": "web_search_tool_result", "tool_use_id": "srvtoolu_p",
                "content": [["type": "web_search_result", "title": "Notch apps", "url": "https://example.com/notch"]],
            ]],
            ["type": "content_block_stop", "index": 0],
        ], priorMessages: prior)
        XCTAssertEqual(run.descriptions, [
            "messageStart(claude-opus-5)",
            "toolActivity(srvtoolu_p|webSearch|Searching \u{201C}mac notch apps\u{201D}|done)",
            "sources(Notch apps|https://example.com/notch)",
        ])
    }

    func testSourcesOnlyAcceptWebURLs() throws {
        let run = try replay(events: [
            ["type": "content_block_start", "index": 0, "content_block": [
                "type": "web_search_tool_result", "tool_use_id": "srvtoolu_u",
                "content": [
                    ["type": "web_search_result", "title": "Local", "url": "file:///etc/hosts"],
                    ["type": "web_search_result", "title": "Good", "url": "https://example.com/"],
                    ["type": "web_search_result", "title": "Duplicate", "url": "https://example.com/"],
                ],
            ]],
        ])
        XCTAssertEqual(run.descriptions, [
            "toolActivity(srvtoolu_u|webSearch|Searching the web|done)",
            "sources(Good|https://example.com/)",
        ])
    }

    // MARK: - Fallback & errors

    func testFallbackBlockEmitsFallbackEvent() throws {
        let run = try replay(APIStreamFixtures.fallbackTranscript)
        XCTAssertEqual(run.descriptions, [
            "messageStart(claude-opus-5)",
            "textDelta(Sure — to probe that port)",
            "fallback(claude-opus-5->claude-opus-4-8)",
            "textDelta(Use `nc -zv host 443` to check the port.)",
        ])
        let result = run.accumulator.result()
        XCTAssertEqual(result.model, "claude-opus-4-8")
        XCTAssertEqual(result.content.map { $0.typeName ?? "?" }, ["text", "fallback", "text"])
        XCTAssertEqual(result.content[1], [
            "type": "fallback", "from": ["model": "claude-opus-5"], "to": ["model": "claude-opus-4-8"],
        ])
    }

    func testErrorEventThrowsStreamError() throws {
        var accumulator = StreamAccumulator()
        _ = try accumulator.handle(["type": "message_start", "message": ["model": "claude-opus-5"]])

        XCTAssertThrowsError(try accumulator.handle(
            ["type": "error", "error": ["type": "api_error", "message": "Internal server error"]]
        )) { error in
            XCTAssertEqual(error as? LLMError, .streamError(type: "api_error", message: "Internal server error"))
        }
        XCTAssertThrowsError(try accumulator.handle(
            ["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]]
        )) { error in
            XCTAssertEqual(error as? LLMError, .overloaded)
        }
        XCTAssertFalse(accumulator.isComplete)
    }

    func testErrorEventInTranscriptThrows() {
        let transcript = """
        event: message_start
        data: {"type":"message_start","message":{"model":"claude-opus-5","content":[]}}

        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

        """
        XCTAssertThrowsError(try replay(transcript)) { error in
            XCTAssertEqual(error as? LLMError, .overloaded)
        }
    }

    // MARK: - Block bookkeeping

    func testInitialTextAndThinkingAreEmitted() throws {
        let run = try replay(events: [
            ["type": "content_block_start", "index": 0,
             "content_block": ["type": "thinking", "thinking": "Already thinking", "signature": ""]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": "Hello"]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": ", world"]],
            ["type": "content_block_stop", "index": 1],
        ])
        XCTAssertEqual(run.descriptions, [
            "thinkingStarted", "thinkingDelta(Already thinking)", "textDelta(Hello)", "textDelta(, world)",
        ])
        XCTAssertEqual(run.accumulator.result().content[1]["text"], "Hello, world")
    }

    func testResultIsInIndexOrderWithoutGapsAndIncludesOpenBlocks() throws {
        let run = try replay(events: [
            ["type": "content_block_start", "index": 3, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 3, "delta": ["type": "text_delta", "text": "later"]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "redacted_thinking", "data": "EmwKAhgB"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_delta", "index": 7, "delta": ["type": "signature_delta", "signature": "orphan"]],
            ["type": "content_block_delta", "index": 3, "delta": ["type": "future_delta", "value": 1]],
        ])
        let content = run.accumulator.result().content
        XCTAssertEqual(content, [
            ["type": "redacted_thinking", "data": "EmwKAhgB"],
            ["type": "text", "text": "later"],
        ])
    }

    func testIsCompleteOnlyAfterMessageStop() throws {
        var accumulator = StreamAccumulator()
        XCTAssertTrue(try accumulator.handle(["type": "ping"]).isEmpty)
        _ = try accumulator.handle(["type": "message_delta", "delta": ["stop_reason": "max_tokens"]])
        XCTAssertFalse(accumulator.isComplete)
        _ = try accumulator.handle(["type": "message_stop"])
        XCTAssertTrue(accumulator.isComplete)
        XCTAssertEqual(accumulator.result().stopReason, "max_tokens")
    }

    // MARK: - SSE parsing

    func testParserIgnoresNonDataLinesAndPings() {
        var parser = SSEParser()
        XCTAssertNil(parser.consume(line: ": keep-alive"))
        XCTAssertNil(parser.consume(line: "event: content_block_delta"))
        XCTAssertNil(parser.consume(line: "id: 42"))
        XCTAssertNil(parser.consume(line: "retry: 1000"))
        XCTAssertNil(parser.consume(line: ""))
        XCTAssertNil(parser.consume(line: "data: {\"type\": \"ping\"}"))
        XCTAssertEqual(parser.consume(line: "data:{\"type\":\"message_stop\"}\r"), ["type": "message_stop"])
        XCTAssertEqual(parser.consume(line: "\u{FEFF}data: {\"type\":\"message_stop\"}"), ["type": "message_stop"])
    }

    func testParserUsesEventNameWhenPayloadHasNoType() {
        var parser = SSEParser()
        XCTAssertNil(parser.consume(line: "event: message_stop"))
        XCTAssertEqual(parser.consume(line: "data: {}"), ["type": "message_stop"])
    }

    func testParserJoinsPayloadSplitAcrossDataLines() {
        var parser = SSEParser()
        XCTAssertNil(parser.consume(line: "data: {\"type\":\"content_block_stop\","))
        XCTAssertEqual(parser.consume(line: "data: \"index\":2}"), ["type": "content_block_stop", "index": 2])
        // A fragment that never completes is dropped once a self-contained event arrives.
        XCTAssertNil(parser.consume(line: "data: {\"type\":"))
        XCTAssertEqual(parser.consume(line: "data: {\"type\":\"message_stop\"}"), ["type": "message_stop"])
    }

    func testLineSplitterHandlesAllTerminatorsAndKeepsUnicodeSeparators() throws {
        var splitter = SSELineSplitter()
        var lines: [String] = []
        for byte in "a\r\nb\rc\n\nd\u{2028}e\u{85}f".utf8 {
            if let line = try splitter.append(byte) {
                lines.append(line)
            }
        }
        if let tail = splitter.finish() {
            lines.append(tail)
        }
        XCTAssertEqual(lines, ["a", "b", "c", "", "d\u{2028}e\u{85}f"])
    }

    func testTranscriptWithCRLFLineEndingsParsesIdentically() throws {
        let crlf = APIStreamFixtures.webSearchTranscript.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(try replay(crlf).descriptions, try replay(APIStreamFixtures.webSearchTranscript).descriptions)
    }
}
