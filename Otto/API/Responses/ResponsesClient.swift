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
//  It also stands in for the server tool the gateway lacks: when Claude calls `web_fetch` (SetappWebFetch), the
//  client reads the page on the Mac and, unless the response also asked for client tools, sends the conversation
//  back with the page so the reply goes on, all within one `stream`, the way Anthropic runs its web fetch inside one
//  response. ChatSession sees "Reading example.com", the page as a source, an Anthropic-shaped `web_fetch` pair in
//  the result and the read in the usage's `server_tool_use`, as after an Anthropic fetch.
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
    /// How long the gateway may take to send its first event. A Setapp that never answers (a stalled handshake
    /// with the Setapp app, a token request that never returns) would otherwise leave the reply on "Thinking…".
    static let defaultFirstEventTimeout: TimeInterval = 45
    /// The longest gap between two events, as long as AnthropicClient's request timeout (also an idle timeout).
    static let defaultEventGapTimeout: TimeInterval = AnthropicClient.requestTimeout
    static let stallMessage = "Setapp AI didn't answer in time."

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "ResponsesClient")

    private let transport: any ResponsesTransport
    private let retryDelays: [TimeInterval]
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let firstEventTimeout: TimeInterval
    private let eventGapTimeout: TimeInterval
    private let pageReader: any WebPageReading

    /// `retryDelays` sets both the backoff schedule and the retry count. `pageReader` reads the pages Claude fetches.
    init(transport: any ResponsesTransport, retryDelays: [TimeInterval] = [1, 3],
         pageReader: any WebPageReading = WebPageReader.live) {
        self.init(transport: transport, retryDelays: retryDelays, sleep: { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }, pageReader: pageReader)
    }

    /// Tests pass `sleep` to see each backoff without waiting it out, and short timeouts to see a stall end.
    init(transport: any ResponsesTransport, retryDelays: [TimeInterval],
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
         firstEventTimeout: TimeInterval = ResponsesClient.defaultFirstEventTimeout,
         eventGapTimeout: TimeInterval = ResponsesClient.defaultEventGapTimeout,
         pageReader: any WebPageReading = WebPageReader.live) {
        self.transport = transport
        self.retryDelays = retryDelays
        self.sleep = sleep
        self.firstEventTimeout = firstEventTimeout
        self.eventGapTimeout = eventGapTimeout
        self.pageReader = pageReader
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

    /// What one reply has gathered over its gateway requests (more than one when Claude reads pages).
    private struct ReplyProgress {
        var content: [JSONValue] = []
        var model: String?
        /// The gateway's usage, summed over the requests.
        var usage: JSONValue?
        /// Web fetch calls that spent a fetch from the request's `max_uses`.
        var pageReads = 0

        /// The usage ChatSession and the ledger see: the gateway's, plus the pages read as `web_fetch_requests`.
        var reportedUsage: JSONValue? {
            guard pageReads > 0 else { return usage }
            return ResponsesClient.addingUsage(usage, ["server_tool_use": ["web_fetch_requests": .int(Int64(pageReads))]])
        }
    }

    private func run(_ request: MessagesRequest, continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        var options = ResponsesRequestOptions.standard
        var reply = ReplyProgress()
        var readsLeft = request.serverToolLimits.webFetch
        // Each read can take a request of its own; after that many (and one more for a call past the limit) the
        // last request asks for an answer, so a model that keeps calling can't run the reply on.
        let maxRequests = max(0, request.serverToolLimits.webFetch) + 2
        var next = request
        var requestsSent = 0
        while true {
            let accumulator = try await respond(to: next, options: &options, isContinuation: requestsSent > 0,
                                                usageBase: reply.reportedUsage, continuation: continuation)
            requestsSent += 1
            let result = accumulator.result()
            if reply.model == nil { reply.model = result.model }
            reply.usage = Self.addingUsage(reply.usage, result.usage)
            var content = result.content

            let calls = accumulator.localToolCalls()
            // A call cut off by the output limit, in a refused response or in a wrap-up request isn't run; its half of
            // the pair goes too, as History would drop it anyway.
            let runsCalls = !calls.isEmpty && next.toolChoice?["type"]?.stringValue != "none"
                && (result.stopReason == "end_turn" || result.stopReason == "tool_use")
            guard runsCalls else {
                let ids = Set(calls.map(\.id))
                content.removeAll { block in
                    ProviderBlocks.isMacPageRead(block) && block["id"]?.stringValue.map(ids.contains) == true
                }
                reply.content += content
                try finish(reply, stopReason: result.stopReason, continuation: continuation)
                return
            }

            // What the model has been sent so far, this response included.
            let allowlist = SetappWebFetch.Allowlist(
                messages: request.messages + [Self.assistantEntry(reply.content + content)]
            )
            let results = try await readPages(calls, allowlist: allowlist, readsLeft: &readsLeft, reply: &reply,
                                              continuation: continuation)
            reply.content += Self.pairing(content, with: results)
            try Self.yield(.usage(reply.reportedUsage ?? [:]), to: continuation)

            // Client tools are waiting too: the tool loop runs them and sends everything back in its next request.
            if result.stopReason == "tool_use" {
                try finish(reply, stopReason: "tool_use", continuation: continuation)
                return
            }
            // Only pages were read: the reply goes on with them, as after an Anthropic server tool.
            next = request
            next.messages = request.messages + [Self.assistantEntry(reply.content)]
            if requestsSent >= maxRequests - 1 {
                next.toolChoice = ["type": "none"]
            }
        }
    }

    private func finish(_ reply: ReplyProgress, stopReason: String?,
                        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) throws {
        let result = StreamResult(content: reply.content, stopReason: stopReason, stopDetails: nil,
                                  model: reply.model, usage: reply.reportedUsage)
        try Self.yield(.completed(result), to: continuation)
    }

    private static func yield(_ event: StreamEvent,
                              to continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) throws {
        if case .terminated = continuation.yield(event) {
            throw CancellationError()
        }
    }

    private static func assistantEntry(_ content: [JSONValue]) -> JSONValue {
        ["role": "assistant", "content": .array(content)]
    }

    /// One gateway request, retried the way AnthropicClient retries, until it completes. The first request of a reply
    /// may also be sent once with `.compatible` options; a later one (the reply going on after a page was read) keeps
    /// the options the first one succeeded with.
    private func respond(
        to request: MessagesRequest,
        options: inout ResponsesRequestOptions,
        isContinuation: Bool,
        usageBase: JSONValue?,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> ResponsesStreamAccumulator {
        var triedCompatible = isContinuation
        var retriesUsed = 0
        while true {
            try Task.checkCancellation()
            let body = ResponsesRequestBuilder.body(for: request, options: options)
            let localTools: Set<String> = SetappWebFetch.isOffered(request, options: options) ? [SetappWebFetch.toolName] : []
            var progress = AttemptProgress()
            do {
                return try await performAttempt(body: body, request: request, localTools: localTools,
                                                isContinuation: isContinuation, usageBase: usageBase,
                                                continuation: continuation, progress: &progress)
            } catch {
                if Task.isCancelled || Self.isCancellation(error) {
                    throw CancellationError()
                }
                let failure = Self.normalize(error, model: request.model)
                // The gateway's translation of reasoning, strict schemas and Otto's web fetch tool for Anthropic
                // models can't be checked offline: a request carrying them that is refused outright is sent once more
                // without them. An overflow is left alone; ChatSession compacts the conversation for that.
                if !triedCompatible, let message = Self.refusalBeforeOutput(failure, progress: progress),
                   !ResponsesStreamAccumulator.isContextOverflow(code: nil, message: message),
                   Self.usesNegotiableFeatures(body) {
                    triedCompatible = true
                    options = .compatible
                    Self.logger.info("Setapp AI refused a request with reasoning, strict tools or web fetch; sending it once without them")
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

    /// Streams one gateway response into `continuation` and returns it complete. A later request of the reply sends
    /// no second `.messageStart`, and every `.usage` counts what the reply's earlier requests used (`usageBase`).
    private func performAttempt(
        body: JSONValue,
        request: MessagesRequest,
        localTools: Set<String>,
        isContinuation: Bool,
        usageBase: JSONValue?,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        progress: inout AttemptProgress
    ) async throws -> ResponsesStreamAccumulator {
        var accumulator = ResponsesStreamAccumulator(requestedModel: request.model, maxOutputTokens: request.maxTokens,
                                                     localTools: localTools)
        // The gateway acknowledges a request (`response.created`) before the model has read it, so `.messageStart`
        // waits for the first event after it. A response that fails before any output (a prompt too long for the
        // model, a failure upstream) then reaches ChatSession with nothing delivered, the way a request Anthropic
        // refused does: ChatSession compacts and resends an overflow, and `run` retries a transient failure.
        var heldStart: StreamEvent?
        func deliver(_ streamEvent: StreamEvent) throws {
            let pending = (heldStart.map { [$0] } ?? []) + [streamEvent]
            heldStart = nil
            for next in pending {
                try Self.yield(next, to: continuation)
                progress.didYield = true
            }
        }
        // Cancelling this task terminates the transport's stream, which cancels the gateway call; so does a stall.
        for try await event in boundedEvents(for: body) {
            progress.receivedEvent = true
            for streamEvent in try accumulator.handle(event) {
                switch streamEvent {
                case .messageStart:
                    if !isContinuation { heldStart = streamEvent }
                case .usage(let usage):
                    try deliver(.usage(Self.addingUsage(usageBase, usage) ?? usage))
                default:
                    try deliver(streamEvent)
                }
            }
            if accumulator.isComplete { break }
        }
        try Task.checkCancellation()

        guard accumulator.isComplete else {
            throw LLMError.network(Self.prematureEOFMessage)
        }
        if let heldStart {
            try deliver(heldStart)
        }
        return accumulator
    }

    // MARK: - Web fetch

    /// Answers the response's web fetch calls: each spends one of the request's reads (a call past them is told so),
    /// must name an address already in the conversation (`allowlist`), and is read on the Mac. The reads run side by
    /// side; each call's row finishes, with its page as a source, as soon as its read does. Returns the result block of
    /// every call, by call id. Stopping the reply cancels the reads.
    private func readPages(
        _ calls: [ResponsesStreamAccumulator.LocalToolCall],
        allowlist: SetappWebFetch.Allowlist,
        readsLeft: inout Int,
        reply: inout ReplyProgress,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> [String: JSONValue] {
        var results: [String: JSONValue] = [:]
        var reads: [(call: ResponsesStreamAccumulator.LocalToolCall, url: URL)] = []
        for call in calls {
            let failure: SetappWebFetch.Failure
            if readsLeft <= 0 {
                failure = .maxUsesExceeded
            } else {
                readsLeft -= 1
                reply.pageReads += 1
                guard let raw = call.input?["url"]?.stringValue else {
                    results[call.id] = SetappWebFetch.errorBlock(id: call.id, failure: .invalidInput)
                    try Self.yield(.toolActivity(Self.finishedActivity(call)), to: continuation)
                    continue
                }
                switch allowlist.permit(raw) {
                case .success(let url):
                    reads.append((call, url))
                    continue
                case .failure(let refusal):
                    failure = refusal
                }
            }
            Self.logger.info("Web fetch for Setapp AI refused: \(failure.code, privacy: .public)")
            results[call.id] = SetappWebFetch.errorBlock(id: call.id, failure: failure)
            try Self.yield(.toolActivity(Self.finishedActivity(call)), to: continuation)
        }

        let reader = pageReader
        try await withThrowingTaskGroup(of: (Int, Result<WebPage, WebPageReadError>).self) { group in
            for (index, read) in reads.enumerated() {
                let url = read.url
                group.addTask {
                    do {
                        return (index, .success(try await reader.read(url)))
                    } catch let error as WebPageReadError {
                        return (index, .failure(error))
                    }
                }
            }
            for try await (index, outcome) in group {
                let call = reads[index].call
                switch outcome {
                case .success(let page):
                    Self.logger.info("Read a page for Setapp AI: \(page.text.count, privacy: .public) characters from \(page.url.host ?? "", privacy: .private)")
                    results[call.id] = SetappWebFetch.resultBlock(id: call.id, page: page)
                    try Self.yield(.toolActivity(Self.finishedActivity(call)), to: continuation)
                    if let url = StreamAccumulator.webURL(page.url.absoluteString) {
                        let title = page.title ?? StreamAccumulator.displayHost(of: url)
                        try Self.yield(.sources([SourceLink(title: title, url: url)]), to: continuation)
                    }
                case .failure(let error):
                    Self.logger.info("Couldn't read a page for Setapp AI: \(error.code, privacy: .public)")
                    results[call.id] = SetappWebFetch.errorBlock(id: call.id, failure: .read(error))
                    try Self.yield(.toolActivity(Self.finishedActivity(call)), to: continuation)
                }
            }
        }
        try Task.checkCancellation()
        return results
    }

    /// The call's "Reading example.com" row, finished.
    private static func finishedActivity(_ call: ResponsesStreamAccumulator.LocalToolCall) -> ToolActivity {
        var activity = StreamAccumulator.makeActivity(id: call.id, name: call.name, input: call.input)
        activity.isDone = true
        return activity
    }

    /// `content` with each page read's result placed straight after its call, as Anthropic places a server tool's.
    private static func pairing(_ content: [JSONValue], with results: [String: JSONValue]) -> [JSONValue] {
        var paired: [JSONValue] = []
        for block in content {
            paired.append(block)
            if ProviderBlocks.isMacPageRead(block), block.typeName == "server_tool_use",
               let id = block["id"]?.stringValue, let result = results[id] {
                paired.append(result)
            }
        }
        return paired
    }

    /// Two usage objects added up, number by number and inside `server_tool_use`; either alone when the other is nil.
    static func addingUsage(_ base: JSONValue?, _ more: JSONValue?) -> JSONValue? {
        guard case .object(var merged)? = base else { return more }
        guard case .object(let added)? = more else { return base }
        for (key, value) in added {
            switch (merged[key], value) {
            case (.int(let left)?, .int(let right)):
                merged[key] = .int(left + right)
            case (.object?, .object):
                merged[key] = addingUsage(merged[key], value)
            case (nil, _):
                merged[key] = value
            default:
                merged[key] = value
            }
        }
        return .object(merged)
    }

    /// The transport's events for `body`, ended with `ResponsesTransportError.unavailable(stallMessage)` (and the
    /// transport's stream cancelled) when the first event takes longer than `firstEventTimeout` or the gap between
    /// two events is longer than `eventGapTimeout`. The time is measured where the events arrive, so a slow
    /// consumer doesn't count against the gateway.
    private func boundedEvents(for body: JSONValue) -> AsyncThrowingStream<JSONValue, Error> {
        let transport = self.transport
        let watch = StallWatch(firstEventTimeout: firstEventTimeout, eventGapTimeout: eventGapTimeout)
        return AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    for try await event in transport.events(for: body) {
                        guard watch.noteEvent() else { return }
                        continuation.yield(event)
                    }
                    if watch.finish() { continuation.finish() }
                } catch {
                    if watch.finish() { continuation.finish(throwing: error) }
                }
            }
            let watchdog = Task {
                while let wait = watch.timeLeft() {
                    if wait <= 0 {
                        guard watch.finish() else { return }
                        let firstEvent = !watch.receivedEvent
                        Self.logger.error("Setapp AI stalled \(firstEvent ? "before its first event" : "between events", privacy: .public); ending the request")
                        pump.cancel()
                        continuation.finish(throwing: ResponsesTransportError.unavailable(Self.stallMessage))
                        return
                    }
                    do {
                        try await Task.sleep(nanoseconds: UInt64(min(wait, 3_600) * 1_000_000_000))
                    } catch {
                        return
                    }
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
                watchdog.cancel()
            }
        }
    }

    /// The gateway's message when it refused the request before anything reached the user: a `badRequest` before any
    /// event, or an invalid-request error event after only the acknowledgement (LiteLLM can refuse mid-stream, once
    /// it has answered `response.created`). Nil for every other failure.
    private static func refusalBeforeOutput(_ failure: Failure, progress: AttemptProgress) -> String? {
        if !progress.receivedEvent, case .badRequest(_, let message)? = failure.transportError {
            return message
        }
        if !progress.didYield, failure.transportError == nil,
           case .http(let status, let type, let message) = failure.error,
           status == 400, type == "invalid_request_error" {
            return message
        }
        return nil
    }

    /// Whether `body` carries what `.compatible` leaves out: reasoning, a replayed reasoning item, a strict tool or
    /// Otto's web fetch tool.
    static func usesNegotiableFeatures(_ body: JSONValue) -> Bool {
        if let reasoning = body["reasoning"], reasoning != .null { return true }
        if body["input"]?.arrayValue?.contains(where: { $0.typeName == "reasoning" }) == true { return true }
        return body["tools"]?.arrayValue?.contains(where: { tool in
            tool["strict"]?.boolValue == true
                || (tool.typeName == "function" && tool["name"]?.stringValue == SetappWebFetch.toolName)
        }) == true
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

/// The deadline of one attempt's next event: `firstEventTimeout` after the start, then `eventGapTimeout` after each
/// event. Whichever of the stream and the watchdog finishes first wins; the other then does nothing.
private final class StallWatch: @unchecked Sendable {
    private let lock = NSLock()
    private let eventGapTimeout: TimeInterval
    private var deadline: Date
    private var events = 0
    private var finished = false

    init(firstEventTimeout: TimeInterval, eventGapTimeout: TimeInterval) {
        self.eventGapTimeout = eventGapTimeout
        deadline = Date().addingTimeInterval(firstEventTimeout)
    }

    var receivedEvent: Bool { lock.withLock { events > 0 } }

    /// Moves the deadline on; false once the stream has finished (the watchdog ended it).
    func noteEvent() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            events += 1
            deadline = Date().addingTimeInterval(eventGapTimeout)
            return true
        }
    }

    /// Seconds until the deadline (0 or less when it passed), nil once the stream has finished.
    func timeLeft() -> TimeInterval? {
        lock.withLock { finished ? nil : deadline.timeIntervalSinceNow }
    }

    /// Marks the stream finished; true only for the first caller.
    func finish() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
    }
}
