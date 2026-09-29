//
//  APIClientTests.swift
//  Otto
//

import XCTest
@testable import Otto

// MARK: - URL loading stub

/// Serves queued canned responses to URLSessions configured with it and records every request.
private final class StubURLProtocol: URLProtocol {
    struct CannedResponse {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "text/event-stream; charset=utf-8"]
        var body: Data = Data()
        /// Deliver the body but never finish (simulates a long-running stream).
        var holdOpen = false
        var failure: URLError?
    }

    struct RecordedRequest {
        let request: URLRequest
        let body: Data
    }

    private static let lock = NSLock()
    private static var queue: [CannedResponse] = []
    private static var recorded: [RecordedRequest] = []
    private static var stopHandler: (() -> Void)?

    static func prepare(_ responses: [CannedResponse], onStop: (() -> Void)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        queue = responses
        recorded = []
        stopHandler = onStop
    }

    static var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(of: request)
        Self.lock.lock()
        Self.recorded.append(RecordedRequest(request: request, body: body))
        let canned = Self.queue.isEmpty ? nil : Self.queue.removeFirst()
        Self.lock.unlock()

        guard let client else { return }
        guard let canned, let url = request.url else {
            client.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let failure = canned.failure {
            client.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: canned.status, httpVersion: "HTTP/1.1",
                                             headerFields: canned.headers) else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !canned.body.isEmpty {
            client.urlProtocol(self, didLoad: canned.body)
        }
        if !canned.holdOpen {
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.lock.lock()
        let handler = Self.stopHandler
        Self.lock.unlock()
        handler?()
    }

    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private func sse(_ text: String) -> Data { Data(text.utf8) }

private func eventLabel(_ event: StreamEvent) -> String {
    switch event {
    case .messageStart: return "messageStart"
    case .thinkingStarted: return "thinkingStarted"
    case .thinkingDelta: return "thinkingDelta"
    case .textDelta(let text): return "textDelta(\(text))"
    case .toolActivity(let activity): return "toolActivity(\(activity.isDone ? "done" : "running"))"
    case .sources(let links): return "sources(\(links.count))"
    case .fallback: return "fallback"
    case .completed(let result): return "completed(\(result.stopReason ?? "nil"))"
    case .toolUseStarted(let id, let name): return "toolUseStarted(\(id)|\(name))"
    case .toolUseReady(let id, let name, let input, _):
        return "toolUseReady(\(id)|\(name)|\(input.map { $0.encodedString() } ?? "invalid"))"
    case .usage: return "usage"
    }
}

// MARK: - Tests

final class APIClientTests: XCTestCase {
    private let baseURL = URL(string: "https://api.anthropic.test")!

    override func tearDown() {
        StubURLProtocol.prepare([])
        super.tearDown()
    }

    private func makeRequest(
        model: ModelOption,
        effort: EffortLevel = .medium,
        webAccess: Bool = true,
        system: String = "You are Otto."
    ) -> MessagesRequest {
        MessagesRequest(
            model: model,
            system: system,
            messages: [["role": "user", "content": [["type": "text", "text": "What changed in this release?"]]]],
            maxTokens: model.maxOutputTokens,
            effort: effort,
            webAccess: webAccess
        )
    }

    private func makeClient(apiKey: String = "sk-ant-test-key") -> AnthropicClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return AnthropicClient(apiKey: apiKey, baseURL: baseURL, session: URLSession(configuration: configuration),
                               retryDelays: [0, 0])
    }

    private func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async -> (events: [StreamEvent], error: Error?) {
        var events: [StreamEvent] = []
        do {
            for try await event in stream {
                events.append(event)
            }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    // MARK: Request body

    func testOpus5RequestBodyHasThinkingEffortFallbacksAndBothTools() {
        let body = AnthropicClient.makeRequestBody(makeRequest(model: .opus5, effort: .high))
        let expected: JSONValue = [
            "model": "claude-opus-5",
            "max_tokens": 64_000,
            "stream": true,
            "system": [["type": "text", "text": "You are Otto."]],
            "messages": [["role": "user", "content": [["type": "text", "text": "What changed in this release?"]]]],
            "cache_control": ["type": "ephemeral"],
            "thinking": ["type": "adaptive", "display": "summarized"],
            "output_config": ["effort": "high"],
            "fallbacks": "default",
            "tools": [
                ["type": "web_search_20260209", "name": "web_search", "max_uses": 5],
                ["type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 5],
            ],
        ]
        XCTAssertEqual(body, expected)
    }

    func testSonnet5RequestBodyHasThinkingAndEffortButNoFallbacks() {
        let body = AnthropicClient.makeRequestBody(makeRequest(model: .sonnet5, effort: .low))
        XCTAssertEqual(body["model"], "claude-sonnet-5")
        XCTAssertEqual(body["max_tokens"], 64_000)
        XCTAssertEqual(body["thinking"], ["type": "adaptive", "display": "summarized"])
        XCTAssertEqual(body["output_config"], ["effort": "low"])
        XCTAssertNil(body["fallbacks"])
        XCTAssertEqual(body["tools"]?.arrayValue?.compactMap { $0["type"]?.stringValue },
                       ["web_search_20260209", "web_fetch_20260209"])
    }

    func testHaiku45RequestBodyHasNoThinkingEffortOrFallbacksAndOnlyWebSearch() {
        let body = AnthropicClient.makeRequestBody(makeRequest(model: .haiku45, effort: .high))
        XCTAssertEqual(body["model"], "claude-haiku-4-5")
        XCTAssertEqual(body["max_tokens"], 32_000)
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["output_config"])
        XCTAssertNil(body["fallbacks"])
        XCTAssertEqual(body["tools"], [["type": "web_search_20250305", "name": "web_search", "max_uses": 5]])
        XCTAssertEqual(body["cache_control"], ["type": "ephemeral"])
        XCTAssertEqual(body["stream"], true)
    }

    func testWebAccessOffOmitsTools() {
        for model in ModelOption.allCases {
            XCTAssertNil(AnthropicClient.makeRequestBody(makeRequest(model: model, webAccess: false))["tools"], model.rawValue)
        }
    }

    func testBodyNeverSendsSamplingBudgetOrPrefill() throws {
        for model in ModelOption.allCases {
            let body = AnthropicClient.makeRequestBody(makeRequest(model: model))
            let keys = Set(try XCTUnwrap(body.objectValue).keys)
            XCTAssertTrue(keys.isDisjoint(with: ["temperature", "top_p", "top_k", "budget_tokens"]), model.rawValue)
            XCTAssertFalse(body.encodedString().contains("budget_tokens"), model.rawValue)
            XCTAssertEqual(body["messages"]?.arrayValue?.last?["role"], "user")
        }
    }

    func testEmptySystemPromptIsOmitted() {
        XCTAssertNil(AnthropicClient.makeRequestBody(makeRequest(model: .opus5, system: ""))["system"])
    }

    func testEncodedBodyIsByteStableWithSortedKeys() throws {
        let request = makeRequest(model: .opus5)
        let first = try JSONValue.makeEncoder().encode(AnthropicClient.makeRequestBody(request))
        let second = try JSONValue.makeEncoder().encode(AnthropicClient.makeRequestBody(request))
        XCTAssertEqual(first, second)
        let text = String(decoding: first, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(#"{"cache_control":{"type":"ephemeral"},"fallbacks":"default","max_tokens":64000,"#), text)
    }

    // MARK: Headers

    func testHeadersIncludeFallbackBetaOnlyForOpus5() {
        let opus = AnthropicClient.makeHeaders(apiKey: "sk-ant-1\n", request: makeRequest(model: .opus5))
        XCTAssertEqual(opus, [
            "x-api-key": "sk-ant-1",
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
            "accept": "text/event-stream",
            "anthropic-beta": "server-side-fallback-2026-07-01",
        ])
        for model in [ModelOption.sonnet5, .haiku45] {
            let headers = AnthropicClient.makeHeaders(apiKey: "sk-ant-1", request: makeRequest(model: model))
            XCTAssertNil(headers["anthropic-beta"], model.rawValue)
            XCTAssertEqual(headers.count, 4, model.rawValue)
        }
    }

    // MARK: Error mapping

    func testHTTPErrorMapping() {
        func body(_ type: String, _ message: String) -> Data {
            Data(#"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#.utf8)
        }
        XCTAssertEqual(AnthropicClient.mapHTTPError(status: 401, body: body("authentication_error", "invalid x-api-key"), retryAfter: nil),
                       .invalidAPIKey)
        XCTAssertEqual(AnthropicClient.mapHTTPError(status: 403, body: body("permission_error", "Your key is not permitted to use this model"), retryAfter: nil),
                       .http(status: 403, type: "permission_error", message: "Your key is not permitted to use this model"))
        XCTAssertEqual(AnthropicClient.mapHTTPError(status: 403, body: body("permission_error", ""), retryAfter: nil),
                       .http(status: 403, type: "permission_error", message: AnthropicClient.permissionDeniedFallback))
        XCTAssertEqual(AnthropicClient.mapHTTPError(status: 403, body: Data(), retryAfter: nil),
                       .http(status: 403, type: nil, message: AnthropicClient.permissionDeniedFallback))
        let forbidden = AnthropicClient.mapHTTPError(status: 403, body: body("permission_error", "nope"), retryAfter: nil)
        XCTAssertNotEqual(forbidden, .invalidAPIKey)
        XCTAssertFalse(forbidden.isRetryable)
        XCTAssertEqual(forbidden.errorDescription, "nope")
        XCTAssertEqual(AnthropicClient.mapHTTPError(status: 429, body: body("rate_limit_error", "slow down"), retryAfter: 12),
                       .rateLimited(retryAfter: 12))
        XCTAssertEqual(AnthropicClient.mapHTTPError(status: 529, body: Data(), retryAfter: nil), .overloaded)
        XCTAssertEqual(AnthropicClient.mapHTTPError(status: 503, body: body("overloaded_error", "Overloaded"), retryAfter: nil),
                       .overloaded)
        XCTAssertEqual(AnthropicClient.mapHTTPError(status: 400, body: body("invalid_request_error", "max_tokens: too large"), retryAfter: nil),
                       .http(status: 400, type: "invalid_request_error", message: "max_tokens: too large"))
        XCTAssertEqual(AnthropicClient.mapHTTPError(status: 502, body: Data("<html>Bad gateway</html>".utf8), retryAfter: nil),
                       .http(status: 502, type: nil, message: ""))
    }

    func testRetryAfterHeaderParsing() throws {
        func response(_ headers: [String: String]) throws -> HTTPURLResponse {
            try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 429, httpVersion: nil, headerFields: headers))
        }
        XCTAssertEqual(AnthropicClient.retryAfter(from: try response(["retry-after": "7"])), 7)
        XCTAssertEqual(AnthropicClient.retryAfter(from: try response(["Retry-After": "1.5"])), 1.5)
        XCTAssertEqual(AnthropicClient.retryAfter(from: try response(["retry-after-ms": "250", "retry-after": "9"])), 0.25)
        XCTAssertNil(AnthropicClient.retryAfter(from: try response([:])))
        XCTAssertNil(AnthropicClient.retryAfter(from: try response(["retry-after": "soon"])))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let date = formatter.string(from: Date().addingTimeInterval(30))
        let seconds = try XCTUnwrap(AnthropicClient.retryAfter(from: try response(["retry-after": date])))
        XCTAssertEqual(seconds, 30, accuracy: 2)
    }

    // MARK: Streaming transport

    func testStreamsRecordedResponseAndSendsExpectedRequest() async throws {
        StubURLProtocol.prepare([.init(body: sse(APIStreamFixtures.webSearchTranscript))])
        let request = makeRequest(model: .opus5)

        let (events, error) = await collect(makeClient().stream(request))

        XCTAssertNil(error)
        XCTAssertEqual(events.map(eventLabel), [
            "messageStart", "usage", "thinkingStarted", "thinkingDelta", "thinkingDelta",
            "toolActivity(running)", "toolActivity(done)", "sources(2)",
            "textDelta(Swift 6.2 focuses on )", "textDelta(approachable concurrency.)", "sources(1)",
            "textDelta( Code now runs on the main actor by default in app targets.)",
            "usage", "completed(end_turn)",
        ])
        guard case .completed(let result) = events.last else { return XCTFail("missing .completed") }
        XCTAssertEqual(result.content.count, 5)
        XCTAssertEqual(result.model, "claude-opus-5")

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.url?.absoluteString, "https://api.anthropic.test/v1/messages")
        XCTAssertEqual(sent.request.timeoutInterval, 300)
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test-key")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "accept"), "text/event-stream")
        XCTAssertEqual(try JSONValue.decode(sent.body), AnthropicClient.makeRequestBody(request))
    }

    func testUnauthorizedIsNotRetried() async {
        StubURLProtocol.prepare([
            .init(status: 401, headers: ["Content-Type": "application/json"],
                  body: sse(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)),
        ])
        let (events, error) = await collect(makeClient().stream(makeRequest(model: .sonnet5)))
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(error as? LLMError, .invalidAPIKey)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testOverloadedBeforeFirstEventIsRetried() async {
        StubURLProtocol.prepare([
            .init(status: 529, headers: ["Content-Type": "application/json"],
                  body: sse(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)),
            .init(body: sse(APIStreamFixtures.fallbackTranscript)),
        ])
        let (events, error) = await collect(makeClient().stream(makeRequest(model: .opus5)))
        XCTAssertNil(error)
        XCTAssertEqual(events.last.map(eventLabel), "completed(end_turn)")
        XCTAssertTrue(events.contains { if case .fallback = $0 { return true } else { return false } })
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testRetriesStopAfterTwoAttempts() async {
        let serverError = StubURLProtocol.CannedResponse(
            status: 500, headers: ["Content-Type": "application/json"],
            body: sse(#"{"type":"error","error":{"type":"api_error","message":"Internal server error"}}"#))
        StubURLProtocol.prepare([serverError, serverError, serverError, serverError])
        let (_, error) = await collect(makeClient().stream(makeRequest(model: .haiku45)))
        XCTAssertEqual(error as? LLMError, .http(status: 500, type: "api_error", message: "Internal server error"))
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
    }

    func testLongRetryAfterIsSurfacedWithoutRetrying() async {
        StubURLProtocol.prepare([
            .init(status: 429, headers: ["Content-Type": "application/json", "retry-after": "60"],
                  body: sse(#"{"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}}"#)),
        ])
        let (_, error) = await collect(makeClient().stream(makeRequest(model: .opus5)))
        XCTAssertEqual(error as? LLMError, .rateLimited(retryAfter: 60))
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testShouldRetryFalseHeaderSuppressesRetry() async {
        StubURLProtocol.prepare([
            .init(status: 503, headers: ["Content-Type": "application/json", "x-should-retry": "false"], body: Data()),
        ])
        let (_, error) = await collect(makeClient().stream(makeRequest(model: .opus5)))
        XCTAssertEqual(error as? LLMError, .http(status: 503, type: nil, message: ""))
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testNetworkFailureBeforeFirstEventIsRetried() async {
        StubURLProtocol.prepare([
            .init(failure: URLError(.networkConnectionLost)),
            .init(body: Data()),  // connects, then closes without a single event
            .init(body: sse(APIStreamFixtures.webSearchTranscript)),
        ])
        let (events, error) = await collect(makeClient().stream(makeRequest(model: .opus5)))
        XCTAssertNil(error)
        XCTAssertEqual(events.last.map(eventLabel), "completed(end_turn)")
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
    }

    func testPrematureEOFAfterOutputThrowsWithoutRetrying() async {
        let truncated = """
        event: message_start
        data: {"type":"message_start","message":{"model":"claude-opus-5","content":[],"usage":{"input_tokens":10}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Partial"}}

        """
        StubURLProtocol.prepare([.init(body: sse(truncated)), .init(body: sse(APIStreamFixtures.webSearchTranscript))])
        let (events, error) = await collect(makeClient().stream(makeRequest(model: .opus5)))
        XCTAssertEqual(events.map(eventLabel), ["messageStart", "usage", "textDelta(Partial)"])
        XCTAssertEqual(error as? LLMError, .network("The connection closed before the reply finished."))
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testErrorEventMidStreamIsThrown() async {
        let transcript = """
        event: message_start
        data: {"type":"message_start","message":{"model":"claude-opus-5","content":[]}}

        event: error
        data: {"type":"error","error":{"type":"api_error","message":"Internal server error"}}

        """
        StubURLProtocol.prepare([.init(body: sse(transcript)), .init(body: sse(APIStreamFixtures.webSearchTranscript))])
        let (events, error) = await collect(makeClient().stream(makeRequest(model: .opus5)))
        XCTAssertEqual(events.map(eventLabel), ["messageStart"])
        XCTAssertEqual(error as? LLMError, .streamError(type: "api_error", message: "Internal server error"))
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testNonStreamingJSONErrorIsSurfaced() async {
        StubURLProtocol.prepare([
            .init(status: 200, headers: ["Content-Type": "application/json"],
                  body: sse(#"{"type":"error","error":{"type":"invalid_request_error","message":"stream not supported"}}"#)),
        ])
        let (_, error) = await collect(makeClient().stream(makeRequest(model: .sonnet5)))
        XCTAssertEqual(error as? LLMError, .streamError(type: "invalid_request_error", message: "stream not supported"))
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testMissingAPIKeyFailsWithoutARequest() async {
        StubURLProtocol.prepare([])
        let (_, error) = await collect(makeClient(apiKey: "  \n").stream(makeRequest(model: .opus5)))
        XCTAssertEqual(error as? LLMError, .missingAPIKey)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testCancellingTheConsumerCancelsTheRequest() async {
        let stopped = expectation(description: "request stopped")
        stopped.assertForOverFulfill = false
        let firstEvent = expectation(description: "first event")
        StubURLProtocol.prepare([
            .init(body: sse(#"data: {"type":"message_start","message":{"model":"claude-opus-5","content":[]}}"# + "\n\n"),
                  holdOpen: true),
        ], onStop: { stopped.fulfill() })

        let stream = makeClient().stream(makeRequest(model: .opus5))
        let consumer = Task { () -> Int in
            var received = 0
            do {
                for try await _ in stream {
                    received += 1
                    if received == 1 { firstEvent.fulfill() }
                }
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
            return received
        }

        await fulfillment(of: [firstEvent], timeout: 5)
        consumer.cancel()
        await fulfillment(of: [stopped], timeout: 5)
        let received = await consumer.value
        XCTAssertEqual(received, 1)
    }

    // MARK: Mock client

    func testMockClientStreamsScriptedReply() async throws {
        let request = MessagesRequest(
            model: .opus5,
            system: "You are Otto.",
            messages: [
                ["role": "user", "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="]],
                    ["type": "document", "source": ["type": "text", "media_type": "text/plain", "data": "notes"], "title": "meeting-notes.txt"],
                    ["type": "text", "text": "How do I animate the notch?"],
                ]],
            ],
            maxTokens: 64_000,
            effort: .medium,
            webAccess: true
        )
        let (events, error) = await collect(MockLLMClient(latencyScale: 0).stream(request))
        XCTAssertNil(error)

        guard case .messageStart(let model) = events.first else { return XCTFail("expected messageStart first") }
        XCTAssertEqual(model, "claude-opus-5 (demo)")
        XCTAssertEqual(events.map(eventLabel).prefix(2), ["messageStart", "thinkingStarted"])
        XCTAssertGreaterThanOrEqual(events.filter { eventLabel($0) == "thinkingDelta" }.count, 2)
        let activityStates = events.compactMap { event -> Bool? in
            if case .toolActivity(let activity) = event { return activity.isDone }
            return nil
        }
        XCTAssertEqual(activityStates, [false, true])
        let sources = events.flatMap { event -> [SourceLink] in
            if case .sources(let links) = event { return links }
            return []
        }
        XCTAssertEqual(sources.count, 2)

        let streamedText = events.compactMap { event -> String? in
            if case .textDelta(let text) = event { return text }
            return nil
        }.joined()
        XCTAssertTrue(streamedText.contains("How do I animate the notch?"))
        XCTAssertTrue(streamedText.contains("2 attachments"))
        XCTAssertTrue(streamedText.contains("```swift"))
        XCTAssertTrue(streamedText.contains("\n- "))

        guard case .completed(let result) = events.last else { return XCTFail("expected .completed last") }
        XCTAssertEqual(result.stopReason, "end_turn")
        XCTAssertNil(result.stopDetails)
        XCTAssertEqual(result.content.map { $0.typeName ?? "?" },
                       ["thinking", "server_tool_use", "web_search_tool_result", "text"])
        XCTAssertEqual(result.content.last?["text"]?.stringValue, streamedText)
        XCTAssertFalse(result.content[0]["signature"]?.stringValue?.isEmpty ?? true)
        XCTAssertEqual(result.content[1]["id"], result.content[2]["tool_use_id"])
    }

    func testMockClientRefusesWhenAsked() async {
        let request = MessagesRequest(
            model: .sonnet5, system: "", messages: [["role": "user", "content": [["type": "text", "text": "Please REFUSE this."]]]],
            maxTokens: 1_000, effort: .low, webAccess: false
        )
        let (events, error) = await collect(MockLLMClient(latencyScale: 0).stream(request))
        XCTAssertNil(error)
        XCTAssertFalse(events.contains { if case .textDelta = $0 { return true } else { return false } })
        guard case .completed(let result) = events.last else { return XCTFail("expected .completed last") }
        XCTAssertEqual(result.stopReason, "refusal")
        XCTAssertTrue(result.content.isEmpty)
    }

    func testMockWordChunksReassembleExactly() {
        let text = "Hello  world,\n\n- item one\n```swift\nlet x = 1\n```\n"
        let chunks = MockLLMClient.wordChunks(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertEqual(chunks.first, "Hello  ")
        XCTAssertGreaterThan(chunks.count, 5)
    }

    // MARK: Client tools and server-tool limits

    private let echoDefinition: JSONValue = [
        "name": "echo", "description": "Echo.", "eager_input_streaming": true, "strict": true,
        "input_schema": ["type": "object", "properties": [:], "required": [], "additionalProperties": false],
    ]
    private let shortcutDefinition: JSONValue = [
        "name": "run_shortcut", "description": "Run a shortcut.", "eager_input_streaming": true,
        "input_schema": ["type": "object", "properties": [:]],
    ]

    func testClientToolsFollowServerTools() {
        var request = makeRequest(model: .opus5)
        request.clientTools = [echoDefinition, shortcutDefinition]
        let tools = AnthropicClient.makeRequestBody(request)["tools"]?.arrayValue ?? []
        XCTAssertEqual(tools.map { $0["name"]?.stringValue ?? "?" }, ["web_search", "web_fetch", "echo", "run_shortcut"])
        XCTAssertEqual(tools[2], echoDefinition)
        XCTAssertEqual(tools[3], shortcutDefinition)
    }

    func testToolsKeyIsPresentWhenOnlyClientToolsExist() {
        for model in ModelOption.allCases {
            var request = makeRequest(model: model, webAccess: false)
            request.clientTools = [echoDefinition]
            XCTAssertEqual(AnthropicClient.makeRequestBody(request)["tools"], [echoDefinition], model.rawValue)
        }
    }

    func testToolChoiceIsSentOnlyWithTools() {
        var withoutTools = makeRequest(model: .sonnet5, webAccess: false)
        withoutTools.toolChoice = ["type": "none"]
        let bare = AnthropicClient.makeRequestBody(withoutTools)
        XCTAssertNil(bare["tools"])
        XCTAssertNil(bare["tool_choice"])

        var withClientTools = withoutTools
        withClientTools.clientTools = [echoDefinition]
        XCTAssertEqual(AnthropicClient.makeRequestBody(withClientTools)["tool_choice"], ["type": "none"])

        var withServerTools = makeRequest(model: .sonnet5)
        withServerTools.toolChoice = ["type": "none"]
        XCTAssertEqual(AnthropicClient.makeRequestBody(withServerTools)["tool_choice"], ["type": "none"])

        let noChoice = makeRequest(model: .sonnet5)
        XCTAssertNil(AnthropicClient.makeRequestBody(noChoice)["tool_choice"])
    }

    func testServerToolLimitsSetMaxUsesAndOmitSpentTools() {
        var request = makeRequest(model: .opus5)
        request.serverToolLimits = ServerToolLimits(webSearch: 3, webFetch: 1)
        XCTAssertEqual(AnthropicClient.makeRequestBody(request)["tools"], [
            ["type": "web_search_20260209", "name": "web_search", "max_uses": 3],
            ["type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 1],
        ])

        request.serverToolLimits = ServerToolLimits(webSearch: 0, webFetch: 2)
        XCTAssertEqual(AnthropicClient.makeRequestBody(request)["tools"], [
            ["type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 2],
        ])

        request.serverToolLimits = ServerToolLimits(webSearch: 2, webFetch: 0)
        XCTAssertEqual(AnthropicClient.makeRequestBody(request)["tools"], [
            ["type": "web_search_20260209", "name": "web_search", "max_uses": 2],
        ])

        request.serverToolLimits = .none
        XCTAssertNil(AnthropicClient.makeRequestBody(request)["tools"])
        request.clientTools = [echoDefinition]
        request.toolChoice = ["type": "none"]
        let body = AnthropicClient.makeRequestBody(request)
        XCTAssertEqual(body["tools"], [echoDefinition], "a paused web leaves only the client tools")
        XCTAssertEqual(body["tool_choice"], ["type": "none"])
    }

    func testHaikuHasNoFetchWhateverItsLimit() {
        var request = makeRequest(model: .haiku45)
        request.serverToolLimits = ServerToolLimits(webSearch: 4, webFetch: 5)
        XCTAssertEqual(AnthropicClient.makeRequestBody(request)["tools"], [
            ["type": "web_search_20250305", "name": "web_search", "max_uses": 4],
        ])
    }

    func testServerToolLimitsAreIgnoredWithoutWebAccess() {
        var request = makeRequest(model: .opus5, webAccess: false)
        request.serverToolLimits = ServerToolLimits(webSearch: 5, webFetch: 5)
        XCTAssertNil(AnthropicClient.makeRequestBody(request)["tools"])
    }

    func testMockClientReportsUsageBeforeCompleting() async {
        let (events, error) = await collect(MockLLMClient(latencyScale: 0).stream(makeRequest(model: .opus5)))
        XCTAssertNil(error)
        XCTAssertEqual(events.suffix(2).map(eventLabel), ["usage", "completed(end_turn)"])
        guard case .usage(let usage) = events[events.count - 2], case .completed(let result) = events.last else {
            return XCTFail("expected usage then completed")
        }
        XCTAssertEqual(usage, result.usage)
        XCTAssertNotNil(usage["input_tokens"]?.intValue)
        XCTAssertNotNil(usage["output_tokens"]?.intValue)
        XCTAssertEqual(usage["cache_read_input_tokens"], 0)
        XCTAssertEqual(usage["cache_creation_input_tokens"], 0)
        XCTAssertEqual(usage["server_tool_use"]?["web_search_requests"], 1)
    }
}
