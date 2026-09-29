//
//  AnthropicClient.swift
//  Otto
//
//  Streams Claude Messages API responses over raw HTTPS + server-sent events. Requests carry the web
//  tools (with per-request `max_uses`) followed by Otto's client tools.
//

import Foundation
import os

final class AnthropicClient: LLMClient, @unchecked Sendable {
    static let apiVersion = "2023-06-01"
    static let serverFallbackBeta = "server-side-fallback-2026-07-01"
    static let requestTimeout: TimeInterval = 300
    /// Backoff before retry 1 and retry 2. A request is attempted at most `defaultRetryDelays.count + 1` times.
    static let defaultRetryDelays: [TimeInterval] = [1, 3]
    /// A server-provided `retry-after` is honored up to this many seconds; longer waits are surfaced instead.
    static let maxHonoredRetryAfter: TimeInterval = 20
    static let prematureEOFMessage = "The connection closed before the reply finished."

    private static let maxErrorBodyBytes = 256 * 1024
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "AnthropicClient")

    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession
    private let retryDelays: [TimeInterval]

    convenience init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!, session: URLSession = .shared) {
        self.init(apiKey: apiKey, baseURL: baseURL, session: session, retryDelays: Self.defaultRetryDelays)
    }

    /// `retryDelays` sets both the backoff schedule and the retry count (tests pass zeros).
    init(apiKey: String, baseURL: URL, session: URLSession, retryDelays: [TimeInterval]) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL
        self.session = session
        self.retryDelays = retryDelays
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

    // MARK: - Request building

    /// Pure request-body builder (unit tested).
    static func makeRequestBody(_ request: MessagesRequest) -> JSONValue {
        let model = request.model
        var body: [String: JSONValue] = [
            "model": .string(model.rawValue),
            "max_tokens": .int(Int64(request.maxTokens)),
            "stream": true,
            "messages": .array(request.messages),
            // Top-level automatic prompt caching: the breakpoint follows the conversation as it grows.
            "cache_control": ["type": "ephemeral"],
        ]
        // The API rejects empty text blocks, so an empty system prompt is omitted rather than sent.
        if !request.system.isEmpty {
            body["system"] = [["type": "text", "text": .string(request.system)]]
        }
        if model.supportsAdaptiveThinking {
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
        }
        if model.supportsEffort {
            body["output_config"] = ["effort": .string(request.effort.rawValue)]
        }
        if model.supportsServerFallbacks {
            body["fallbacks"] = "default"
        }
        // Server tools first (web search, then fetch), then the client tools, already sorted by name, so
        // the tool list is byte-stable for a given model and settings.
        var tools: [JSONValue] = request.webAccess ? serverTools(for: model, limits: request.serverToolLimits) : []
        tools += request.clientTools
        if !tools.isEmpty {
            body["tools"] = .array(tools)
            if let toolChoice = request.toolChoice {
                body["tool_choice"] = toolChoice
            }
        }
        return .object(body)
    }

    /// The web tools with this request's `max_uses`; a tool whose limit is 0 is left out.
    private static func serverTools(for model: ModelOption, limits: ServerToolLimits) -> [JSONValue] {
        var tools: [JSONValue] = []
        if limits.webSearch > 0 {
            tools.append(["type": .string(model.webSearchToolType), "name": "web_search",
                          "max_uses": .int(Int64(limits.webSearch))])
        }
        if let fetchType = model.webFetchToolType, limits.webFetch > 0 {
            tools.append(["type": .string(fetchType), "name": "web_fetch", "max_uses": .int(Int64(limits.webFetch))])
        }
        return tools
    }

    /// Headers for a request (unit tested). Includes anthropic-beta only when needed.
    static func makeHeaders(apiKey: String, request: MessagesRequest) -> [String: String] {
        var headers = [
            "x-api-key": apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "anthropic-version": apiVersion,
            "content-type": "application/json",
            "accept": "text/event-stream",
        ]
        if request.model.supportsServerFallbacks {
            headers["anthropic-beta"] = serverFallbackBeta
        }
        return headers
    }

    private func makeURLRequest(for request: MessagesRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appending(path: "v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = Self.requestTimeout
        for (field, value) in Self.makeHeaders(apiKey: apiKey, request: request) {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        do {
            // Sorted keys keep the body byte-stable, which prompt caching relies on.
            urlRequest.httpBody = try JSONValue.makeEncoder().encode(Self.makeRequestBody(request))
        } catch {
            Self.logger.error("Failed to encode request body: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            throw LLMError.http(status: 0, type: "invalid_request_error", message: "Otto couldn't prepare the request.")
        }
        return urlRequest
    }

    // MARK: - Streaming

    private func run(_ request: MessagesRequest, continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }
        let urlRequest = try makeURLRequest(for: request)

        var retriesUsed = 0
        while true {
            try Task.checkCancellation()
            var didYield = false
            do {
                try await performAttempt(urlRequest, request: request, continuation: continuation, didYield: &didYield)
                return
            } catch {
                if Task.isCancelled || Self.isCancellation(error) {
                    throw CancellationError()
                }
                let failure = Self.normalize(error)
                // Once anything has been shown to the user a retry would duplicate output, so only
                // failures before the first event are retried.
                guard !didYield, retriesUsed < retryDelays.count, failure.error.isRetryable,
                      failure.shouldRetryHint != false,
                      let delay = retryDelay(forRetry: retriesUsed, retryAfter: failure.retryAfter) else {
                    throw failure.error
                }
                retriesUsed += 1
                Self.logger.info("Retrying request (\(retriesUsed)/\(self.retryDelays.count)) in \(delay, format: .fixed(precision: 1))s after: \(LoggedError(failure.error), privacy: .public) \(failure.error.localizedDescription, privacy: .private)")
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
    }

    /// Delay before retry number `retry` (0-based), or nil when the server asked for a longer wait
    /// than is worth holding the user for.
    private func retryDelay(forRetry retry: Int, retryAfter: TimeInterval?) -> TimeInterval? {
        if let retryAfter {
            return retryAfter <= Self.maxHonoredRetryAfter ? max(0, retryAfter) : nil
        }
        return retryDelays[min(retry, retryDelays.count - 1)]
    }

    private func performAttempt(
        _ urlRequest: URLRequest,
        request: MessagesRequest,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        didYield: inout Bool
    ) async throws {
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.network("Received an unexpected response from the Anthropic API.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = try await Self.collectBody(bytes)
            let retryAfter = Self.retryAfter(from: http)
            let error = Self.mapHTTPError(status: http.statusCode, body: body, retryAfter: retryAfter)
            Self.logger.error("Messages API returned HTTP \(http.statusCode): \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            throw HTTPFailure(error: error, retryAfter: retryAfter, shouldRetryHint: Self.shouldRetryHint(from: http))
        }

        if let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           contentType.contains("application/json") {
            // A proxy or gateway answered without streaming; surface its error if it sent one.
            let body = try await Self.collectBody(bytes)
            if let decoded = try? JSONValue.decode(body), decoded.typeName == "error" {
                throw StreamAccumulator.streamError(from: decoded)
            }
            throw LLMError.decoding("The API didn't return a streaming response.")
        }

        var splitter = SSELineSplitter()
        var parser = SSEParser()
        var accumulator = StreamAccumulator()
        accumulator.registerPriorToolUses(in: request.messages)

        func process(_ line: String, didYield: inout Bool) throws {
            guard let event = parser.consume(line: line) else { return }
            for streamEvent in try accumulator.handle(event) {
                if case .terminated = continuation.yield(streamEvent) {
                    throw CancellationError()
                }
                didYield = true
            }
        }

        for try await byte in bytes {
            guard let line = try splitter.append(byte) else { continue }
            try process(line, didYield: &didYield)
            if accumulator.isComplete { break }
        }
        if !accumulator.isComplete, let line = splitter.finish() {
            try process(line, didYield: &didYield)
        }
        try Task.checkCancellation()

        guard accumulator.isComplete else {
            throw LLMError.network(Self.prematureEOFMessage)
        }
        if case .terminated = continuation.yield(.completed(accumulator.result())) {
            throw CancellationError()
        }
        didYield = true
    }

    // MARK: - Error handling

    /// A non-2xx response, with the server's retry hints.
    private struct HTTPFailure: Error {
        let error: LLMError
        let retryAfter: TimeInterval?
        /// `x-should-retry` header; `false` suppresses retries.
        let shouldRetryHint: Bool?
    }

    private static func normalize(_ error: Error) -> HTTPFailure {
        switch error {
        case let failure as HTTPFailure:
            return failure
        case let llmError as LLMError:
            return HTTPFailure(error: llmError, retryAfter: nil, shouldRetryHint: nil)
        case let urlError as URLError:
            return HTTPFailure(error: .network(networkMessage(for: urlError)), retryAfter: nil, shouldRetryHint: nil)
        default:
            return HTTPFailure(error: .network(error.localizedDescription), retryAfter: nil, shouldRetryHint: nil)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private static func networkMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed:
            return "You're offline. Check your internet connection and try again."
        case .timedOut:
            return "The request to the Anthropic API timed out."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "Couldn't reach the Anthropic API. Check your connection."
        case .networkConnectionLost:
            return "The network connection was lost."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "Couldn't establish a secure connection to the Anthropic API."
        default:
            return error.localizedDescription
        }
    }

    /// Shown for a 403 whose body carries no usable message.
    static let permissionDeniedFallback = "Your API key doesn't have access to this model or feature."

    /// Maps a non-2xx response to an `LLMError` (unit tested). Only 401 means the key itself was
    /// rejected; 403 (`permission_error`) is a valid key without access, so it keeps the server message.
    static func mapHTTPError(status: Int, body: Data, retryAfter: TimeInterval?) -> LLMError {
        let decoded = try? JSONValue.decode(body)
        let type = decoded?["error"]?["type"]?.stringValue
        let message = decoded?["error"]?["message"]?.stringValue ?? ""
        switch status {
        case 401:
            return .invalidAPIKey
        case 403:
            // permission_error: the key authenticated but lacks access (model, feature, org policy).
            // Surface the server's reason instead of blaming the key.
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return .http(status: 403, type: type,
                         message: trimmed.isEmpty ? Self.permissionDeniedFallback : trimmed)
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 529:
            return .overloaded
        default:
            if type == "overloaded_error" {
                return .overloaded
            }
            return .http(status: status, type: type, message: message)
        }
    }

    /// Seconds from `retry-after-ms` / `retry-after` (delta-seconds or HTTP-date).
    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        if let milliseconds = response.value(forHTTPHeaderField: "retry-after-ms")
            .flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), milliseconds.isFinite, milliseconds >= 0 {
            return milliseconds / 1000
        }
        guard let value = response.value(forHTTPHeaderField: "retry-after")?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private static func shouldRetryHint(from response: HTTPURLResponse) -> Bool? {
        switch response.value(forHTTPHeaderField: "x-should-retry")?.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func collectBody(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxErrorBodyBytes else { break }
            data.append(byte)
        }
        return data
    }
}
