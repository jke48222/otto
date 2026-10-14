//
//  ResponsesClient.swift
//  Otto
//
//  Answers a MessagesRequest through Setapp's AI Gateway (OpenAI Responses API), producing the same StreamEvents
//  and StreamResult as AnthropicClient, so ChatSession, the tool loop, TrustLedger and the usage books work the
//  same with either provider (SPEC §19, Setapp AI). The transport carries the request; this client builds the
//  body, retries the way AnthropicClient does, and maps the transport's failures to the LLMErrors the reply
//  footer already understands.
//

import Foundation
import os

struct ResponsesClient: LLMClient {
    /// Backoff before retry 1 and retry 2. A request is attempted at most `defaultRetryDelays.count + 1` times,
    /// plus the one compatibility retry.
    static let defaultRetryDelays: [TimeInterval] = [1, 3]
    /// A `retryAfter` from the gateway is honored up to this many seconds; longer waits are surfaced instead.
    static let maxHonoredRetryAfter: TimeInterval = 20
    static let prematureEOFMessage = "The connection to Setapp AI closed before the reply finished."

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "ResponsesClient")

    private let transport: any ResponsesTransport
    private let retryDelays: [TimeInterval]
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// `retryDelays` sets both the backoff schedule and the retry count.
    init(transport: any ResponsesTransport, retryDelays: [TimeInterval] = [1, 3]) {
        self.init(transport: transport, retryDelays: retryDelays, sleep: { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        })
    }

    /// Tests pass `sleep` to see each backoff without waiting it out.
    init(transport: any ResponsesTransport, retryDelays: [TimeInterval],
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.transport = transport
        self.retryDelays = retryDelays
        self.sleep = sleep
    }

    // MARK: - LLMClient

    func stream(_ request: MessagesRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Streaming

    /// How far one attempt got, for the retry rules.
    private struct AttemptProgress {
        /// The transport delivered at least one event (the gateway accepted the request).
        var receivedEvent = false
        /// The consumer has seen output; a retry would duplicate it.
        var didYield = false
    }

    private func run(_ request: MessagesRequest, continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        var options = ResponsesRequestOptions.standard
        var triedCompatible = false
        var retriesUsed = 0
        while true {
            try Task.checkCancellation()
            let body = ResponsesRequestBuilder.body(for: request, options: options)
            var progress = AttemptProgress()
            do {
                try await performAttempt(body: body, request: request, continuation: continuation, progress: &progress)
                return
            } catch {
                if Task.isCancelled || Self.isCancellation(error) {
                    throw CancellationError()
                }
                let failure = Self.normalize(error, model: request.model)
                // The gateway's translation of reasoning and strict schemas for Anthropic models can't be checked
                // offline: a request carrying them that is refused outright is sent once more without them. An
                // overflow is left alone; ChatSession compacts the conversation for that.
                if !progress.receivedEvent, !triedCompatible, case .badRequest(_, let message)? = failure.transportError,
                   !ResponsesStreamAccumulator.isContextOverflow(code: nil, message: message),
                   Self.usesNegotiableFeatures(body) {
                    triedCompatible = true
                    options = .compatible
                    Self.logger.info("Setapp AI refused a request with reasoning or strict tools; sending it once without them")
                    continue
                }
                // Once anything has been shown to the user a retry would duplicate output, so only failures before
                // the first event are retried.
                guard !progress.didYield, retriesUsed < retryDelays.count, Self.isRetryable(failure.error),
                      let delay = retryDelay(forRetry: retriesUsed, retryAfter: failure.retryAfter) else {
                    Self.logger.error("Setapp AI request failed: \(LoggedError(failure.error), privacy: .public) \(failure.error.localizedDescription, privacy: .private)")
                    throw failure.error
                }
                retriesUsed += 1
                Self.logger.info("Retrying Setapp AI request (\(retriesUsed)/\(self.retryDelays.count)) in \(delay, format: .fixed(precision: 1))s after: \(LoggedError(failure.error), privacy: .public) \(failure.error.localizedDescription, privacy: .private)")
                if delay > 0 {
                    try await sleep(delay)
                }
            }
        }
    }

    /// Delay before retry number `retry` (0-based), or nil when the gateway asked for a longer wait than is worth
    /// holding the user for.
    private func retryDelay(forRetry retry: Int, retryAfter: TimeInterval?) -> TimeInterval? {
        if let retryAfter {
            return retryAfter <= Self.maxHonoredRetryAfter ? max(0, retryAfter) : nil
        }
        return retryDelays[min(retry, retryDelays.count - 1)]
    }

    private func performAttempt(
        body: JSONValue,
        request: MessagesRequest,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        progress: inout AttemptProgress
    ) async throws {
        var accumulator = ResponsesStreamAccumulator(requestedModel: request.model)
        // Cancelling this task terminates the transport's stream, which cancels the gateway call.
        for try await event in transport.events(for: body) {
            progress.receivedEvent = true
            for streamEvent in try accumulator.handle(event) {
                if case .terminated = continuation.yield(streamEvent) {
                    throw CancellationError()
                }
                progress.didYield = true
            }
            if accumulator.isComplete { break }
        }
        try Task.checkCancellation()

        guard accumulator.isComplete else {
            throw LLMError.network(Self.prematureEOFMessage)
        }
        if case .terminated = continuation.yield(.completed(accumulator.result())) {
            throw CancellationError()
        }
        progress.didYield = true
    }

    /// Whether `body` carries what `.compatible` leaves out: reasoning, a replayed reasoning item or a strict tool.
    static func usesNegotiableFeatures(_ body: JSONValue) -> Bool {
        if let reasoning = body["reasoning"], reasoning != .null { return true }
        if body["input"]?.arrayValue?.contains(where: { $0.typeName == "reasoning" }) == true { return true }
        return body["tools"]?.arrayValue?.contains(where: { $0["strict"]?.boolValue == true }) == true
    }

    // MARK: - Error handling

    private struct Failure {
        let error: LLMError
        let retryAfter: TimeInterval?
        let transportError: ResponsesTransportError?
    }

    private static func normalize(_ error: Error, model: ModelOption) -> Failure {
        switch error {
        case let transportError as ResponsesTransportError:
            var retryAfter: TimeInterval?
            if case .rateLimited(let seconds) = transportError { retryAfter = seconds }
            return Failure(error: mapError(transportError, model: model), retryAfter: retryAfter,
                           transportError: transportError)
        case let llmError as LLMError:
            var retryAfter: TimeInterval?
            if case .rateLimited(let seconds) = llmError { retryAfter = seconds }
            return Failure(error: llmError, retryAfter: retryAfter, transportError: nil)
        case let urlError as URLError:
            return Failure(error: mapError(.network(urlError.localizedDescription), model: model), retryAfter: nil,
                           transportError: nil)
        default:
            // The transport maps everything it knows; anything else happened between Otto and Setapp.
            return Failure(error: mapError(.unavailable(error.localizedDescription), model: model), retryAfter: nil,
                           transportError: nil)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// The failures a retry before any output may cure.
    static func isRetryable(_ error: LLMError) -> Bool {
        switch error {
        case .rateLimited, .overloaded, .network:
            return true
        case .http(let status, _, _):
            return status >= 500
        case .streamError(let type, _):
            return type == "api_error"
        case .setappAI(let failure):
            return failure == .unavailable
        case .missingAPIKey, .invalidAPIKey, .decoding:
            return false
        }
    }

    static let badRequestFallback = "Setapp AI couldn't take this request."
    static let serverFallback = "Setapp AI had a problem. Try again."
    static let networkFallback = "Couldn't reach Setapp AI. Check your connection."

    /// Maps a transport failure to the LLMError ChatSession and the reply footer understand (unit tested).
    static func mapError(_ error: ResponsesTransportError, model: ModelOption) -> LLMError {
        switch error {
        case .insufficientCredits:
            return .setappAI(.insufficientCredits)
        case .modelNotAllowed:
            return .setappAI(.modelNotAllowed(model.shortName))
        case .notConfigured:
            return .setappAI(.notConfigured)
        case .unauthorized, .unavailable:
            return .setappAI(.unavailable)
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case .badRequest(let status, let message):
            if ResponsesStreamAccumulator.isContextOverflow(code: nil, message: message) {
                return ResponsesStreamAccumulator.overflowError(message: message)
            }
            return .http(status: status, type: "invalid_request_error", message: message.isEmpty ? badRequestFallback : message)
        case .server(let status, let message):
            if status == 529 || message.lowercased().contains("overloaded") {
                return .overloaded
            }
            return .http(status: status == 0 ? 500 : status, type: "api_error",
                         message: message.isEmpty ? serverFallback : message)
        case .network(let message):
            return .network(message.isEmpty ? networkFallback : message)
        }
    }
}
