//
//  ResponsesClientTests.swift
//  Otto
//

import XCTest
@testable import Otto

private func eventLabel(_ event: StreamEvent) -> String {
    switch event {
    case .messageStart(let model): return "messageStart(\(model))"
    case .thinkingStarted: return "thinkingStarted"
    case .thinkingDelta: return "thinkingDelta"
    case .textDelta(let text): return "textDelta(\(text))"
    case .toolActivity(let activity): return "toolActivity(\(activity.isDone ? "done" : "running"))"
    case .sources(let links): return "sources(\(links.count))"
    case .fallback: return "fallback"
    case .completed(let result): return "completed(\(result.stopReason ?? "nil"))"
    case .toolUseStarted(let id, let name): return "toolUseStarted(\(id)|\(name))"
    case .toolUseReady(let id, let name, _, _): return "toolUseReady(\(id)|\(name))"
    case .usage: return "usage"
    }
}

/// Records the backoff the client asked for instead of waiting it out.
private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var delays: [TimeInterval] { lock.withLock { recorded } }

    func sleep(_ seconds: TimeInterval) async throws {
        lock.withLock { recorded.append(seconds) }
        try Task.checkCancellation()
    }
}

final class ResponsesClientTests: XCTestCase {
    private static let strictTool: JSONValue = [
        "name": "calendar_create_event",
        "description": "Create an event.",
        "input_schema": ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"]],
        "eager_input_streaming": true,
        "strict": true,
    ]

    private let sleeper = SleepRecorder()

    private func makeRequest(
        model: ModelOption = .opus5,
        webAccess: Bool = false,
        clientTools: [JSONValue] = [],
        messages: [JSONValue] = [["role": "user", "content": [["type": "text", "text": "What changed in Swift 6.2?"]]]]
    ) -> MessagesRequest {
        MessagesRequest(
            model: model,
            system: "You are Otto.",
            messages: messages,
            maxTokens: model.maxOutputTokens,
            effort: .medium,
            webAccess: webAccess,
            clientTools: clientTools
        )
    }

    private func makeClient(_ transport: ScriptedResponsesTransport, retryDelays: [TimeInterval] = [0, 0]) -> ResponsesClient {
        let sleeper = self.sleeper
        return ResponsesClient(transport: transport, retryDelays: retryDelays, sleep: { try await sleeper.sleep($0) })
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

    private func run(_ attempts: [ScriptedResponsesTransport.Attempt], request: MessagesRequest? = nil,
                     retryDelays: [TimeInterval] = [0, 0])
        async -> (events: [StreamEvent], error: Error?, transport: ScriptedResponsesTransport) {
        let transport = ScriptedResponsesTransport(attempts)
        let (events, error) = await collect(makeClient(transport, retryDelays: retryDelays).stream(request ?? makeRequest()))
        return (events, error, transport)
    }

    private func result(of events: [StreamEvent]) -> StreamResult? {
        guard case .completed(let result)? = events.last else { return nil }
        return result
    }

    // MARK: - Streaming

    func testStreamsAScenarioAndSendsTheStandardBody() async throws {
        let (events, error, transport) = await run([.lines(ResponsesFixtures.text)])

        XCTAssertNil(error)
        XCTAssertEqual(events.map(eventLabel), [
            "messageStart(anthropic/claude-opus-5)",
            "textDelta(Swift 6.2 makes concurrency )",
            "textDelta(easier to adopt: app code runs on the main actor by default.)",
            "usage",
            "completed(end_turn)",
        ])
        let result = try XCTUnwrap(result(of: events))
        XCTAssertEqual(result.model, "anthropic/claude-opus-5")
        XCTAssertEqual(result.usage?["cache_read_input_tokens"], 1536)

        XCTAssertEqual(transport.bodies.count, 1)
        let body = try XCTUnwrap(transport.bodies.first)
        XCTAssertEqual(body, ResponsesRequestBuilder.body(for: makeRequest(), options: .standard))
        XCTAssertEqual(body["model"], "anthropic/claude-opus-5")
        XCTAssertEqual(body["stream"], true)
        XCTAssertEqual(body["store"], false)
        XCTAssertNotNil(body["reasoning"])
        XCTAssertTrue(sleeper.delays.isEmpty)
    }

    func testEveryScenarioEndsTheWayChatSessionExpects() async {
        let expected: [(lines: [String], model: ModelOption, outcome: String)] = [
            (ResponsesFixtures.text, .opus5, "completed(end_turn)"),
            (ResponsesFixtures.reasoningThenText, .sonnet5, "completed(end_turn)"),
            (ResponsesFixtures.webSearch, .opus5, "completed(end_turn)"),
            (ResponsesFixtures.functionCall, .opus5, "completed(tool_use)"),
            (ResponsesFixtures.functionCallCompletedOnly, .opus5, "completed(tool_use)"),
            (ResponsesFixtures.parallelFunctionCalls, .sonnet5, "completed(tool_use)"),
            (ResponsesFixtures.incompleteMaxTokens, .haiku45, "completed(max_tokens)"),
            (ResponsesFixtures.refusal, .opus5, "completed(refusal)"),
        ]
        for (lines, model, outcome) in expected {
            let (events, error, transport) = await run([.lines(lines)], request: makeRequest(model: model))
            XCTAssertNil(error, outcome)
            XCTAssertEqual(events.last.map(eventLabel), outcome)
            XCTAssertEqual(transport.bodies.count, 1, outcome)
        }
    }

    @MainActor
    func testFailedOverflowIsThrownWithoutARetryForChatSessionToCompact() async {
        let (events, error, transport) = await run([.lines(ResponsesFixtures.failedOverflow), .lines(ResponsesFixtures.text)],
                                                   request: makeRequest(model: .sonnet5))
        XCTAssertEqual(events.map(eventLabel), ["messageStart(anthropic/claude-sonnet-5)"])
        XCTAssertTrue(ChatSession.isContextOverflow(error ?? CancellationError()), "\(String(describing: error))")
        XCTAssertEqual(transport.bodies.count, 1)
    }

    func testFailedCreditsIsThrownWithoutARetry() async {
        let (events, error, transport) = await run([.lines(ResponsesFixtures.failedCredits), .lines(ResponsesFixtures.text)])
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(error as? LLMError, .setappAI(.insufficientCredits))
        XCTAssertEqual(transport.bodies.count, 1)
    }

    func testStreamEndingWithoutATerminalEventThrows() async {
        let truncated = Array(ResponsesFixtures.text.prefix(5))
        let (events, error, transport) = await run([.lines(truncated), .lines(ResponsesFixtures.text)])

        XCTAssertEqual(events.map(eventLabel), ["messageStart(anthropic/claude-opus-5)", "textDelta(Swift 6.2 makes concurrency )"])
        XCTAssertEqual(error as? LLMError, .network("The connection to Setapp AI closed before the reply finished."))
        // Output was shown, so it isn't retried.
        XCTAssertEqual(transport.bodies.count, 1)
    }

    func testStreamClosingBeforeAnyEventIsRetried() async {
        let (events, error, transport) = await run([.events([]), .lines(ResponsesFixtures.text)])
        XCTAssertNil(error)
        XCTAssertEqual(events.last.map(eventLabel), "completed(end_turn)")
        XCTAssertEqual(transport.bodies.count, 2)
    }

    func testCancellingTheConsumerStopsTheTransport() async {
        let transport = ScriptedResponsesTransport([.stall(lines: ResponsesFixtures.text, count: 5)])
        let stopped = expectation(description: "transport stream cancelled")
        stopped.assertForOverFulfill = false
        transport.onCancel { stopped.fulfill() }
        let firstEvent = expectation(description: "first event")

        let stream = makeClient(transport).stream(makeRequest())
        let consumer = Task { () -> (received: Int, error: Error?) in
            var received = 0
            do {
                for try await _ in stream {
                    received += 1
                    if received == 1 { firstEvent.fulfill() }
                }
                return (received, nil)
            } catch {
                return (received, error)
            }
        }

        await fulfillment(of: [firstEvent], timeout: 5)
        consumer.cancel()
        await fulfillment(of: [stopped], timeout: 5)
        let outcome = await consumer.value
        XCTAssertEqual(transport.cancellations, 1)
        XCTAssertEqual(transport.bodies.count, 1)
        XCTAssertTrue(outcome.error == nil || outcome.error is CancellationError, "\(String(describing: outcome.error))")
    }

    // MARK: - Retries

    func testTransientFailuresBeforeTheFirstEventAreRetriedOnTheBackoffSchedule() async {
        let (events, error, transport) = await run([
            .failure(ResponsesTransportError.server(status: 503, message: "busy"), after: []),
            .failure(ResponsesTransportError.network(""), after: []),
            .lines(ResponsesFixtures.text),
        ], retryDelays: [1, 3])

        XCTAssertNil(error)
        XCTAssertEqual(events.last.map(eventLabel), "completed(end_turn)")
        XCTAssertEqual(transport.bodies.count, 3)
        XCTAssertEqual(sleeper.delays, [1, 3])
        // Ordinary retries resend the standard body.
        let standard = ResponsesRequestBuilder.body(for: makeRequest(), options: .standard)
        XCTAssertEqual(transport.bodies, [standard, standard, standard])
    }

    func testRetriesStopOnceTheScheduleIsSpent() async {
        let failure = ScriptedResponsesTransport.Attempt.failure(ResponsesTransportError.server(status: 500, message: ""), after: [])
        let (_, error, transport) = await run([failure, failure, failure, failure], retryDelays: [2, 5])

        XCTAssertEqual(error as? LLMError, .http(status: 500, type: "api_error", message: "Setapp AI had a problem. Try again."))
        XCTAssertEqual(transport.bodies.count, 3)
        XCTAssertEqual(sleeper.delays, [2, 5])
    }

    func testShortRetryAfterIsHonored() async {
        let (_, error, transport) = await run([
            .failure(ResponsesTransportError.rateLimited(retryAfter: 7), after: []),
            .lines(ResponsesFixtures.text),
        ], retryDelays: [1, 3])
        XCTAssertNil(error)
        XCTAssertEqual(transport.bodies.count, 2)
        XCTAssertEqual(sleeper.delays, [7])
    }

    func testLongRetryAfterIsSurfacedWithoutRetrying() async {
        let (_, error, transport) = await run([
            .failure(ResponsesTransportError.rateLimited(retryAfter: 30), after: []),
            .lines(ResponsesFixtures.text),
        ])
        XCTAssertEqual(error as? LLMError, .rateLimited(retryAfter: 30))
        XCTAssertEqual(transport.bodies.count, 1)
        XCTAssertTrue(sleeper.delays.isEmpty)
    }

    func testRetryableFailuresAreRetried() async {
        let retryable: [Error] = [
            ResponsesTransportError.unauthorized,
            ResponsesTransportError.unavailable("Setapp isn't running."),
            ResponsesTransportError.server(status: 529, message: ""),
            ResponsesTransportError.rateLimited(retryAfter: nil),
            URLError(.networkConnectionLost),
            NSError(domain: "SetappAI", code: 1),
        ]
        for failure in retryable {
            let (_, error, transport) = await run([.failure(failure, after: []), .lines(ResponsesFixtures.text)])
            XCTAssertNil(error, "\(failure)")
            XCTAssertEqual(transport.bodies.count, 2, "\(failure)")
        }
    }

    func testFailuresTheUserMustFixAreNotRetried() async {
        let final: [(ResponsesTransportError, LLMError)] = [
            (.insufficientCredits, .setappAI(.insufficientCredits)),
            (.modelNotAllowed, .setappAI(.modelNotAllowed("Haiku 4.5"))),
            (.notConfigured, .setappAI(.notConfigured)),
            (.badRequest(status: 422, message: "Unsupported input."),
             .http(status: 422, type: "invalid_request_error", message: "Unsupported input.")),
        ]
        // Haiku 4.5 without tools: nothing the compatibility retry could turn off.
        for (failure, expected) in final {
            let (_, error, transport) = await run([.failure(failure, after: []), .lines(ResponsesFixtures.text)],
                                                  request: makeRequest(model: .haiku45))
            XCTAssertEqual(error as? LLMError, expected)
            XCTAssertEqual(transport.bodies.count, 1, "\(failure)")
        }
    }

    func testNoRetryAfterTheFirstYieldedEvent() async {
        let prefix = ResponsesFixtures.text.prefix(5).map(ScriptedResponsesTransport.decode)
        let (events, error, transport) = await run([
            .failure(ResponsesTransportError.network("The network connection was lost."), after: prefix),
            .lines(ResponsesFixtures.text),
        ])
        XCTAssertEqual(events.map(eventLabel), ["messageStart(anthropic/claude-opus-5)", "textDelta(Swift 6.2 makes concurrency )"])
        XCTAssertEqual(error as? LLMError, .network("The network connection was lost."))
        XCTAssertEqual(transport.bodies.count, 1)
        XCTAssertTrue(sleeper.delays.isEmpty)
    }

    func testErrorEventBeforeAnyOutputIsRetried() async {
        let (events, error, transport) = await run([
            .events([["type": "error", "code": "server_error", "message": "The model failed to generate a response."]]),
            .lines(ResponsesFixtures.text),
        ])
        XCTAssertNil(error)
        XCTAssertEqual(events.first.map(eventLabel), "messageStart(anthropic/claude-opus-5)")
        XCTAssertEqual(events.filter { if case .messageStart = $0 { return true } else { return false } }.count, 1)
        XCTAssertEqual(transport.bodies.count, 2)
    }

    // MARK: - Compatibility retry

    func testBadRequestIsRetriedOnceWithCompatibleOptions() async throws {
        let request = makeRequest(clientTools: [Self.strictTool])
        let (events, error, transport) = await run([
            .failure(ResponsesTransportError.badRequest(status: 400, message: "reasoning.summary is not supported"), after: []),
            .lines(ResponsesFixtures.text),
        ], request: request, retryDelays: [])

        XCTAssertNil(error)
        XCTAssertEqual(events.last.map(eventLabel), "completed(end_turn)")
        XCTAssertEqual(transport.bodies.count, 2)
        let (first, second) = (transport.bodies[0], transport.bodies[1])
        XCTAssertEqual(first, ResponsesRequestBuilder.body(for: request, options: .standard))
        XCTAssertEqual(second, ResponsesRequestBuilder.body(for: request, options: .compatible))
        XCTAssertNotNil(first["reasoning"])
        XCTAssertEqual(first["tools"]?[0]?["strict"], true)
        XCTAssertNil(second["reasoning"])
        XCTAssertEqual(second["tools"]?[0]?["strict"], false)
        // At once, and not counted against the backoff schedule (which is empty here).
        XCTAssertTrue(sleeper.delays.isEmpty)
    }

    func testCompatibilityRetryFailureIsTheErrorThrown() async {
        let (_, error, transport) = await run([
            .failure(ResponsesTransportError.badRequest(status: 400, message: "first"), after: []),
            .failure(ResponsesTransportError.badRequest(status: 400, message: "second"), after: []),
            .lines(ResponsesFixtures.text),
        ], request: makeRequest(clientTools: [Self.strictTool]))

        XCTAssertEqual(error as? LLMError, .http(status: 400, type: "invalid_request_error", message: "second"))
        XCTAssertEqual(transport.bodies.count, 2)
    }

    func testCompatibilityRetryDoesNotSpendTheBackoffSchedule() async {
        let (_, error, transport) = await run([
            .failure(ResponsesTransportError.badRequest(status: 400, message: "strict is not supported"), after: []),
            .failure(ResponsesTransportError.server(status: 502, message: ""), after: []),
            .failure(ResponsesTransportError.server(status: 502, message: ""), after: []),
            .lines(ResponsesFixtures.text),
        ], retryDelays: [1, 3])

        XCTAssertNil(error)
        XCTAssertEqual(transport.bodies.count, 4)
        XCTAssertEqual(sleeper.delays, [1, 3])
        // The retries after it keep the compatible body.
        XCTAssertNil(transport.bodies[3]["reasoning"])
    }

    func testOnlyABadRequestTriggersTheCompatibilityRetry() async {
        let request = makeRequest(clientTools: [Self.strictTool])
        let standard = ResponsesRequestBuilder.body(for: request, options: .standard)
        let others: [ResponsesTransportError] = [
            .server(status: 500, message: ""), .unauthorized, .network(""), .rateLimited(retryAfter: 1),
        ]
        for failure in others {
            let (_, error, transport) = await run([.failure(failure, after: []), .lines(ResponsesFixtures.text)],
                                                  request: request)
            XCTAssertNil(error, "\(failure)")
            XCTAssertEqual(transport.bodies, [standard, standard], "\(failure)")
        }
        let (_, error, transport) = await run([.failure(ResponsesTransportError.insufficientCredits, after: [])],
                                              request: request)
        XCTAssertEqual(error as? LLMError, .setappAI(.insufficientCredits))
        XCTAssertEqual(transport.bodies, [standard])
    }

    func testCompatibilityRetryNeedsSomethingToTurnOff() async {
        // Haiku 4.5 sends no reasoning; no tools, no stored reasoning items.
        let (_, error, transport) = await run([
            .failure(ResponsesTransportError.badRequest(status: 400, message: "Bad input."), after: []),
            .lines(ResponsesFixtures.text),
        ], request: makeRequest(model: .haiku45))
        XCTAssertEqual(error as? LLMError, .http(status: 400, type: "invalid_request_error", message: "Bad input."))
        XCTAssertEqual(transport.bodies.count, 1)
    }

    func testCompatibilityRetryCoversAReplayedReasoningItem() async throws {
        let reasoningItem: JSONValue = ["id": "rs_1", "type": "reasoning", "summary": [], "encrypted_content": "gAAAA"]
        let messages: [JSONValue] = [
            ["role": "user", "content": [["type": "text", "text": "Hi"]]],
            ["role": "assistant", "content": [["type": "otto_responses_reasoning", "item": reasoningItem],
                                              ["type": "text", "text": "Hello."]]],
            ["role": "user", "content": [["type": "text", "text": "And now?"]]],
        ]
        let (_, error, transport) = await run([
            .failure(ResponsesTransportError.badRequest(status: 400, message: "Unknown item type."), after: []),
            .lines(ResponsesFixtures.text),
        ], request: makeRequest(model: .sonnet5, messages: messages))

        XCTAssertNil(error)
        XCTAssertEqual(transport.bodies.count, 2)
        guard transport.bodies.count == 2 else { return }
        XCTAssertTrue(transport.bodies[0]["input"]?.arrayValue?.contains(reasoningItem) ?? false)
        XCTAssertFalse(transport.bodies[1]["input"]?.arrayValue?.contains(reasoningItem) ?? true)
        XCTAssertFalse(ResponsesClient.usesNegotiableFeatures(transport.bodies[1]))
    }

    /// Haiku sends no reasoning, so a stored reasoning item never reaches the gateway, and a bad request on a body
    /// with nothing negotiable is the user's error to see, not a retry.
    func testHaikuNeverReplaysReasoningSoItsBadRequestIsNotRetried() async throws {
        let reasoningItem: JSONValue = ["id": "rs_1", "type": "reasoning", "summary": [], "encrypted_content": "gAAAA"]
        let messages: [JSONValue] = [
            ["role": "user", "content": [["type": "text", "text": "Hi"]]],
            ["role": "assistant", "content": [["type": "otto_responses_reasoning", "item": reasoningItem],
                                              ["type": "text", "text": "Hello."]]],
            ["role": "user", "content": [["type": "text", "text": "And now?"]]],
        ]
        let (_, error, transport) = await run([
            .failure(ResponsesTransportError.badRequest(status: 400, message: "Unknown item type."), after: []),
            .lines(ResponsesFixtures.text),
        ], request: makeRequest(model: .haiku45, messages: messages))

        XCTAssertEqual(error as? LLMError, .http(status: 400, type: "invalid_request_error", message: "Unknown item type."))
        XCTAssertEqual(transport.bodies.count, 1)
        XCTAssertFalse(transport.bodies.first.map(ResponsesClient.usesNegotiableFeatures) ?? true)
    }

    func testCompatibilityRetryOnlyBeforeTheFirstEvent() async {
        let created = ScriptedResponsesTransport.decode(ResponsesFixtures.text[0])
        let (events, error, transport) = await run([
            .failure(ResponsesTransportError.badRequest(status: 400, message: "Rejected."), after: [created]),
            .lines(ResponsesFixtures.text),
        ], request: makeRequest(clientTools: [Self.strictTool]))

        XCTAssertEqual(events.map(eventLabel), ["messageStart(anthropic/claude-opus-5)"])
        XCTAssertEqual(error as? LLMError, .http(status: 400, type: "invalid_request_error", message: "Rejected."))
        XCTAssertEqual(transport.bodies.count, 1)
    }

    @MainActor
    func testOverflowIsNotSentAgainWithCompatibleOptions() async {
        let (_, error, transport) = await run([
            .failure(ResponsesTransportError.badRequest(status: 400, message: "prompt is too long: 214318 tokens > 200000 maximum"),
                     after: []),
            .lines(ResponsesFixtures.text),
        ], request: makeRequest(clientTools: [Self.strictTool]))

        XCTAssertEqual(transport.bodies.count, 1)
        XCTAssertTrue(ChatSession.isContextOverflow(error ?? CancellationError()))
    }

    func testNegotiableFeaturesAreFoundInTheBody() {
        XCTAssertTrue(ResponsesClient.usesNegotiableFeatures(["reasoning": ["effort": "medium", "summary": "auto"]]))
        XCTAssertTrue(ResponsesClient.usesNegotiableFeatures(["input": [["type": "reasoning", "id": "rs_1", "summary": []]]]))
        XCTAssertTrue(ResponsesClient.usesNegotiableFeatures(["tools": [["type": "web_search"], ["type": "function", "strict": true]]]))
        XCTAssertFalse(ResponsesClient.usesNegotiableFeatures([
            "reasoning": nil,
            "input": [["type": "message", "role": "user", "content": []], ["type": "function_call_output", "call_id": "c", "output": "ok"]],
            "tools": [["type": "web_search"], ["type": "function", "strict": false]],
        ]))
    }

    // MARK: - Error mapping

    func testMapErrorCoversEveryTransportError() {
        let cases: [(ResponsesTransportError, LLMError)] = [
            (.insufficientCredits, .setappAI(.insufficientCredits)),
            (.modelNotAllowed, .setappAI(.modelNotAllowed("Sonnet 5"))),
            (.notConfigured, .setappAI(.notConfigured)),
            (.unauthorized, .setappAI(.unavailable)),
            (.unavailable("Setapp isn't running."), .setappAI(.unavailable)),
            (.rateLimited(retryAfter: 12), .rateLimited(retryAfter: 12)),
            (.rateLimited(retryAfter: nil), .rateLimited(retryAfter: nil)),
            (.badRequest(status: 400, message: "Invalid tool schema."),
             .http(status: 400, type: "invalid_request_error", message: "Invalid tool schema.")),
            (.badRequest(status: 422, message: ""),
             .http(status: 422, type: "invalid_request_error", message: "Setapp AI couldn't take this request.")),
            (.badRequest(status: 413, message: "Input exceeds the model's maximum context."),
             .http(status: 400, type: "invalid_request_error", message: "prompt is too long: Input exceeds the model's maximum context.")),
            (.server(status: 529, message: ""), .overloaded),
            (.server(status: 500, message: "Anthropic is Overloaded"), .overloaded),
            (.server(status: 502, message: "Bad gateway"), .http(status: 502, type: "api_error", message: "Bad gateway")),
            (.server(status: 0, message: ""), .http(status: 500, type: "api_error", message: "Setapp AI had a problem. Try again.")),
            (.network(""), .network("Couldn't reach Setapp AI. Check your connection.")),
            (.network("The request timed out."), .network("The request timed out.")),
        ]
        for (transportError, expected) in cases {
            XCTAssertEqual(ResponsesClient.mapError(transportError, model: .sonnet5), expected, "\(transportError)")
        }
        // The reply footer offers the matching action for each Setapp AI failure.
        XCTAssertEqual(SetappAIFailure.action(forCopy: ResponsesClient.mapError(.insufficientCredits, model: .opus5).localizedDescription),
                       .getCredits)
        XCTAssertEqual(SetappAIFailure.action(forCopy: ResponsesClient.mapError(.modelNotAllowed, model: .opus5).localizedDescription),
                       .openModelsSettings)
    }

    @MainActor
    func testOverflowMappingIsReadByChatSession() {
        for message in ["prompt is too long: 214318 tokens > 200000 maximum",
                        "This model's maximum context length is 200000 tokens.",
                        "Too many tokens: the context length is exceeded"] {
            let error = ResponsesClient.mapError(.badRequest(status: 400, message: message), model: .opus5)
            XCTAssertTrue(ChatSession.isContextOverflow(error), message)
            XCTAssertTrue(ChatSession.isRejectedRequestContent(error), message)
        }
        XCTAssertFalse(ChatSession.isContextOverflow(ResponsesClient.mapError(.badRequest(status: 400, message: "Bad image."), model: .opus5)))
        XCTAssertFalse(ChatSession.isContextOverflow(ResponsesClient.mapError(.insufficientCredits, model: .opus5)))
    }

    func testRetryableMatchesTheSpec() {
        XCTAssertTrue(ResponsesClient.isRetryable(.rateLimited(retryAfter: 3)))
        XCTAssertTrue(ResponsesClient.isRetryable(.overloaded))
        XCTAssertTrue(ResponsesClient.isRetryable(.network("")))
        XCTAssertTrue(ResponsesClient.isRetryable(.http(status: 503, type: "api_error", message: "")))
        XCTAssertTrue(ResponsesClient.isRetryable(.streamError(type: "api_error", message: "")))
        XCTAssertTrue(ResponsesClient.isRetryable(.setappAI(.unavailable)))
        XCTAssertFalse(ResponsesClient.isRetryable(.http(status: 400, type: "invalid_request_error", message: "")))
        XCTAssertFalse(ResponsesClient.isRetryable(.http(status: 409, type: "invalid_request_error", message: "")))
        XCTAssertFalse(ResponsesClient.isRetryable(.setappAI(.insufficientCredits)))
        XCTAssertFalse(ResponsesClient.isRetryable(.setappAI(.modelNotAllowed("Opus 5"))))
        XCTAssertFalse(ResponsesClient.isRetryable(.setappAI(.notConfigured)))
    }
}
