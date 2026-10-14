//
//  ResponsesContracts.swift
//  Otto
//
//  Shared contract types for Setapp AI (SPEC §19, "Setapp AI"). Otto keeps one conversation format, Anthropic
//  Messages blocks; `ResponsesClient` translates a `MessagesRequest` into an OpenAI Responses request for Setapp's
//  AI Gateway and the gateway's events back into `StreamEvent`s and Anthropic blocks. Only the transport touches
//  the Setapp Framework, so everything here builds and is tested in every Mac flavor. Change these only in
//  coordination with every caller.
//

import Foundation

/// Carries one Responses API request to a gateway and its events back.
///
/// `body` is a complete Responses request body as the gateway takes it (`"model": "anthropic/claude-opus-5"`,
/// `"stream": true`, `"store": false`, …), built by `ResponsesRequestBuilder`. The stream yields every streaming
/// event as its JSON object, keyed by `"type"` exactly as OpenAI documents them ("response.created",
/// "response.output_item.added", "response.output_text.delta", "response.reasoning_summary_text.delta",
/// "response.function_call_arguments.delta", "response.output_item.done", "response.completed",
/// "response.incomplete", "response.failed", "error", …), and finishes after the terminal event. Failures before
/// or during the stream are thrown as `ResponsesTransportError` (or `CancellationError`).
///
/// `SetappSDKTransport` (Setapp build) is the live implementation; tests use a scripted one.
protocol ResponsesTransport: Sendable {
    func events(for body: JSONValue) -> AsyncThrowingStream<JSONValue, Error>
}

/// What a transport can report, already mapped from HTTP statuses, the gateway's error codes
/// (`INSUFFICIENT_CREDITS`, `FORBIDDEN`, …) or `SetappAIError.code`. `ResponsesClient.mapError` turns these into
/// the `LLMError`s ChatSession and MessageView already understand.
enum ResponsesTransportError: Error, Equatable, Sendable {
    /// 402 `INSUFFICIENT_CREDITS` / `.insufficientCredits`.
    case insufficientCredits
    /// 403 `FORBIDDEN` / `.modelNotAllowed`.
    case modelNotAllowed
    /// 429 `RATE_LIMIT_EXCEEDED` / `.rateLimit`.
    case rateLimited(retryAfter: TimeInterval?)
    /// 401 `UNAUTHORIZED`: the Setapp token is missing, expired or refused.
    case unauthorized
    /// The build has no OAuth client id and secret (J22).
    case notConfigured
    /// 400 `BAD_REQUEST`, 413, 422 `VALIDATION`: the gateway or the provider behind it rejected the request.
    /// `message` is the gateway's text, passed through so "prompt is too long" still reads as an overflow.
    case badRequest(status: Int, message: String)
    /// 5xx, or a `response.failed` / `error` event: the gateway or the provider failed.
    case server(status: Int, message: String)
    /// `SetappAIError.general` and anything else that never reached the gateway (Setapp not running, not signed in).
    case unavailable(String)
    /// The connection dropped or timed out.
    case network(String)
}

/// Knobs `ResponsesClient` turns down for its single compatibility retry (§19): when the gateway answers a request
/// that carried reasoning, strict tool schemas or Otto's own web fetch tool with `badRequest` before any event, the
/// client sends it once more without them, because the gateway's translation of those features for Anthropic models
/// can't be checked offline.
struct ResponsesRequestOptions: Equatable, Sendable {
    /// Send `reasoning` (effort and an auto summary) and replay stored `otto_responses_reasoning` items.
    var includeReasoning = true
    /// Pass each client tool's `"strict": true` through.
    var strictTools = true
    /// Offer `SetappWebFetch`'s `web_fetch` function (when the request allows a fetch) and replay the pages Otto read.
    var offersWebFetch = true

    static let standard = ResponsesRequestOptions()
    static let compatible = ResponsesRequestOptions(includeReasoning: false, strictTools: false, offersWebFetch: false)
}
