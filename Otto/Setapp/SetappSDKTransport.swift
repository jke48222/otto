//
//  SetappSDKTransport.swift
//  Otto
//
//  The Setapp build's `ResponsesTransport` (SPEC §19, "Setapp AI"): one Responses request through the Setapp
//  Framework's SetappAI module (`SetappManager.shared.ai.responses.createStream(parameters:)`) and its events back
//  as OpenAI-shaped JSON for `ResponsesStreamAccumulator`.
//
//  What the SDK (5.5.0) does with JSON, found by the adapter check (`--setapp-ai-check`, Otto/Debug/SetappAICheck.swift):
//
//  - Its own connector encodes requests with `.convertToSnakeCase` and decodes events with `.convertFromSnakeCase`,
//    `.secondsSince1970` dates and base64 data (read from its binary). `SetappSDKCoding` mirrors those settings.
//  - The top-level fields Otto sends (model, instructions, max_output_tokens, reasoning, include, tool_choice,
//    max_tool_calls, store, stream) survive a decode and re-encode. Typed inputs and tools don't all: `input_image`
//    loses `image_url` (the property is `imageURL`, which `.convertFromSnakeCase` spells `imageUrl`), `input_file`
//    refuses a data URL in `file_data` (the SDK wants bare base64 and sends bare base64), and a function tool
//    without `strict` fails to decode. So every `input` item and every tool travels verbatim, as the SDK's
//    `.unsupported` value, which it encodes as given. (`previous_response_id`, `prompt_cache_key`, `user` and
//    `safety_identifier` would be dropped; Otto sends none of them.)
//  - No JSON null survives either path: typed decoding drops it and the raw-JSON encoder refuses it. Otto's strict
//    tool schemas carry one in every nullable enum, so tools are rewritten without it (`withoutNulls`).
//  - Its raw-JSON values (`UnsupportedObject.object`) can't hold null or Int64, drop nulls when decoding, and
//    hold numbers as NSNumber. A non-boolean NSNumber 0 or 1 encodes as false or true, so request values are
//    built from Swift types and event values are read with a CFBoolean check (`SendableJSON`).
//  - Only text deltas, text done, lifecycle and `error` events are typed; everything else arrives as
//    `.unsupported` with its JSON intact. Typed decoding is strict: a `url_citation` needs `star_index` (the
//    property is misspelled `starIndex`), text parts need `annotations`, usage needs `total_tokens` and an
//    `error` event needs a non-null `param`. The connector throws when an event doesn't decode, which ends the
//    stream, so `SetappSDKEventMapper` recovers what it can (see `recover(from:)`).
//  - LiteLLM, which the gateway most likely runs, sends a failure mid-stream as `{"error": {…}}` with no `type`,
//    which the SDK can't decode either; the mapper turns it into an `error` event.
//

#if OTTO_SETAPP
import Foundation
import os
import Setapp
import SetappAI

struct SetappSDKTransport: ResponsesTransport {
    typealias StreamFactory = @Sendable (SetappAIAPI.Responses.CreateRequestParameters) async throws
        -> CancellableAsyncStream<SetappAIAPI.StreamingEvent>

    static let clientIDKey = "OttoSetappAIClientID"
    static let clientSecretKey = "OttoSetappAIClientSecret"

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "SetappAI")
    @MainActor private static var configured: Bool?

    private let isConfigured: @MainActor @Sendable () -> Bool
    private let makeStream: StreamFactory

    /// The live transport: Setapp's SDK, configured from Info.plist on first use.
    init() {
        self.init(
            isConfigured: { SetappSDKTransport.configureIfNeeded() },
            makeStream: { try await SetappManager.shared.ai.responses.createStream(parameters: $0) }
        )
    }

    /// The adapter check and tests: a scripted SDK stream in place of `createStream(parameters:)`.
    init(isConfigured: @escaping @MainActor @Sendable () -> Bool, makeStream: @escaping StreamFactory) {
        self.isConfigured = isConfigured
        self.makeStream = makeStream
    }

    // MARK: - Configuration (J22)

    /// Reads `OttoSetappAIClientID` / `OttoSetappAIClientSecret` from the main bundle's Info.plist and, the first time
    /// both are usable, calls `SetappManager.shared.ai.set(configuration:)` with `mode: .propagate`, so failures reach
    /// the notch instead of the SDK's own windows. Mode and auth go in one call because a second `set` replaces the
    /// first. Returns whether Setapp AI is configured; the answer is cached, since Info.plist can't change.
    @MainActor static func configureIfNeeded() -> Bool {
        if let configured { return configured }
        guard let client = SetappAIOAuthClient.load(infoDictionary: Bundle.main.infoDictionary ?? [:]) else {
            logger.info("Setapp AI isn't set up in this build: no OAuth client in Info.plist (J22)")
            configured = false
            return false
        }
        SetappManager.shared.ai.set(configuration: AIConfiguration(
            authConfiguration: AuthConfiguration(oauthClientId: client.clientID, oauthSecret: client.secret),
            mode: .propagate
        ))
        logger.info("Configured Setapp AI")
        configured = true
        return true
    }

    // MARK: - ResponsesTransport

    func events(for body: JSONValue) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { continuation in
            let handle = SDKStreamHandle()
            let task = Task {
                do {
                    try await run(body, handle: handle, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                handle.cancel()
                task.cancel()
            }
        }
    }

    private func run(
        _ body: JSONValue,
        handle: SDKStreamHandle,
        continuation: AsyncThrowingStream<JSONValue, Error>.Continuation
    ) async throws {
        guard await isConfigured() else { throw ResponsesTransportError.notConfigured }

        let parameters: SetappAIAPI.Responses.CreateRequestParameters
        do {
            parameters = try SetappSDKRequest.parameters(from: body)
        } catch {
            Self.logger.error("Couldn't turn the request into SDK parameters: \(LoggedError(error), privacy: .public) \(String(describing: error), privacy: .private)")
            throw ResponsesTransportError.badRequest(status: 400, message: SetappSDKRequest.unpreparedMessage)
        }
        try Task.checkCancellation()

        var mapper = SetappSDKEventMapper()
        do {
            let stream = try await makeStream(parameters)
            guard handle.attach(stream) else { throw CancellationError() }
            for try await event in stream {
                try Self.yield(mapper.map(event), to: continuation)
                if mapper.isFinished { break }
            }
            // A stream that ends without a terminal event ends here too: ResponsesClient reports the early end
            // rather than finishing a reply from whatever items happened to arrive.
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled || SetappSDKErrors.isCancellation(error) { throw CancellationError() }
            switch mapper.recover(from: error) {
            case .events(let events):
                if mapper.didStandIn {
                    Self.logger.error("Stood in for a terminal event the SDK couldn't decode, from the finished items (\(events.first?.typeName ?? "?", privacy: .public), no usage): \(LoggedError(error), privacy: .public)")
                } else {
                    Self.logger.notice("Recovered \(events.count) event(s) after the SDK stream failed: \(LoggedError(error), privacy: .public)")
                }
                try Self.yield(events, to: continuation)
            case .failure(let failure):
                Self.logger.error("Setapp AI stream failed: \(SetappSDKErrors.logLabel(failure), privacy: .public) from \(LoggedError(error), privacy: .public) \(String(describing: error), privacy: .private)")
                throw failure
            }
        }
    }

    private static func yield(_ events: [JSONValue], to continuation: AsyncThrowingStream<JSONValue, Error>.Continuation) throws {
        for event in events {
            if case .terminated = continuation.yield(event) { throw CancellationError() }
        }
    }
}

// MARK: - OAuth client

/// The OAuth client id and secret the Setapp build carries (J22). Setapp's design for macOS ships the secret inside
/// the app; the SDK pairs it with an authorization code from the member's Setapp app for a token with scope
/// `ai.openai`. The rules match `scripts/check_commercial_config.sh`, which checks the same values before the build.
struct SetappAIOAuthClient: Equatable {
    let clientID: String
    let secret: String

    /// The example values in Setapp's documentation, which mean "not set" (as `JALEN_MUST_SET…` does).
    static let placeholders = ["your-oauth-client-id", "your-oauth-secret", "your_client_id_here", "your_secret_here"]

    /// Nil unless both values are usable: non-empty, no whitespace, no unexpanded `$(…)`, not a placeholder.
    static func load(infoDictionary: [String: Any]) -> SetappAIOAuthClient? {
        guard let clientID = usable(infoDictionary[SetappSDKTransport.clientIDKey]),
              let secret = usable(infoDictionary[SetappSDKTransport.clientSecretKey]) else { return nil }
        return SetappAIOAuthClient(clientID: clientID, secret: secret)
    }

    static func usable(_ raw: Any?) -> String? {
        guard let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              !value.contains("$("), !value.contains("JALEN_MUST_SET"),
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !placeholders.contains(value.lowercased()) else { return nil }
        return value
    }
}

// MARK: - JSON settings

/// The JSON settings of the SDK's own connector (read from its binary: `SetappAI-URLSessionConnector.o` sets these
/// strategies and no others), so Otto decodes request bodies and re-encodes SDK values exactly as the wire sees them.
enum SetappSDKCoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        decoder.dataDecodingStrategy = .base64
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// `value` as the SDK would send it.
    static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONValue.decode(encoder().encode(value))
    }
}

// MARK: - Request

enum SetappSDKRequest {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// `badRequest` copy when a body can't become SDK parameters (a bug in Otto, not something the user can fix).
    static let unpreparedMessage = "Otto couldn't prepare this request for Setapp AI."

    /// The SDK parameters for a Responses body. Top-level fields decode into the SDK's own types; each `input` item
    /// and each tool rides verbatim as the SDK's `.unsupported` value (see the file header for why), tools through
    /// `withoutNulls`.
    static func parameters(from body: JSONValue) throws -> SetappAIAPI.Responses.CreateRequestParameters {
        guard case .object(var top) = body else { throw Failure(description: "the body isn't a JSON object") }
        let items = top["input"]?.arrayValue
        let tools = top["tools"]?.arrayValue
        if items != nil { top["input"] = .array([]) }
        top["tools"] = nil
        var parameters = try SetappSDKCoding.decoder().decode(
            SetappAIAPI.Responses.CreateRequestParameters.self, from: JSONValue.object(top).encodedData())
        if let items {
            parameters.input = try items.enumerated().map { index, item in
                let object = try verbatimObject(item, at: "input[\(index)]")
                let type = item["type"]?.stringValue ?? "message"
                return SetappAIAPI.Responses.Input.unsupported(SetappAIAPI.UnsupportedObject(
                    type: SetappAIAPI.Responses.Input.InputType(rawValue: type), object: object))
            }
        }
        if let tools {
            parameters.tools = try tools.enumerated().map { index, tool in
                let object = try verbatimObject(withoutNulls(tool), at: "tools[\(index)]")
                guard let type = tool["type"]?.stringValue else { throw Failure(description: "tools[\(index)] has no type") }
                return SetappAIAPI.Responses.Tool.unsupported(SetappAIAPI.UnsupportedObject(
                    type: SetappAIAPI.Responses.Tool.ToolType(rawValue: type), object: object))
            }
        }
        return parameters
    }

    /// The body the SDK will be asked to send: `body` with its tools passed through `withoutNulls` and every other
    /// null left out. The adapter check compares the SDK's encoding with this.
    static func intendedBody(_ body: JSONValue) -> JSONValue {
        guard case .object(var top) = body else { return body }
        if case .array(let tools)? = top["tools"] { top["tools"] = .array(tools.map(withoutNulls)) }
        return droppingNulls(.object(top))
    }

    /// A tool without JSON nulls, which the SDK can't send (its raw JSON has no null, typed or not). Otto's strict
    /// schemas make an optional enum property nullable by adding null to the enum (`ToolSchema.wireSchema`), so
    /// `{"enum": [a, b, null], …}` becomes `{"anyOf": [{"enum": [a, b], …}, {"type": "null"}]}` (a description or
    /// title stays outside) and `{"const": null}` becomes `{"type": "null"}`: the same schema, without the literal.
    /// Any other null (a `default: null`) is left out.
    static func withoutNulls(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(var object):
            if object["const"] == .null {
                object.removeValue(forKey: "const")
                object["type"] = "null"
            }
            if case .array(let values)? = object["enum"], values.contains(.null) {
                let kept = values.filter { $0 != .null }
                var outer: [String: JSONValue] = [:]
                for key in ["description", "title"] {
                    if let annotation = object.removeValue(forKey: key) { outer[key] = annotation }
                }
                object["enum"] = .array(kept)
                let nullType: JSONValue = ["type": "null"]
                outer["anyOf"] = kept.isEmpty ? [nullType] : [withoutNulls(.object(object)), nullType]
                return droppingNulls(.object(outer))
            }
            var cleaned: [String: JSONValue] = [:]
            for (key, child) in object where child != .null { cleaned[key] = withoutNulls(child) }
            return .object(cleaned)
        case .array(let array):
            return .array(array.filter { $0 != .null }.map(withoutNulls))
        default:
            return value
        }
    }

    static func droppingNulls(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object): return .object(object.filter { $0.value != .null }.mapValues(droppingNulls))
        case .array(let array): return .array(array.filter { $0 != .null }.map(droppingNulls))
        default: return value
        }
    }

    /// An object for the SDK's `.unsupported` values, which it encodes as given (adding `type` only when the object
    /// has none). Nulls are left out: the SDK's raw JSON can't carry them.
    static func verbatimObject(_ value: JSONValue, at path: String) throws -> [String: any Sendable] {
        guard let object = SendableJSON.object(value) else { throw Failure(description: "\(path) isn't a JSON object") }
        return object
    }

    /// The body the SDK will send for `parameters` (the adapter check compares it with the body Otto built).
    static func wireBody(_ parameters: SetappAIAPI.Responses.CreateRequestParameters) throws -> JSONValue {
        try SetappSDKCoding.json(parameters)
    }
}

// MARK: - Events

/// Turns the SDK's events into the OpenAI-shaped JSON `ResponsesStreamAccumulator` reads, and keeps enough of the
/// stream to stand in for a terminal event the SDK couldn't decode.
struct SetappSDKEventMapper {
    enum Recovery {
        /// Yield these, then end the stream normally.
        case events([JSONValue])
        case failure(ResponsesTransportError)
    }

    /// Copy for a stream the SDK ended on an event it couldn't decode, when nothing could be recovered.
    static let unreadableMessage = "Setapp AI sent a reply Otto couldn't read."

    static let terminalTypes: Set<String> = ["response.completed", "response.incomplete", "response.failed", "error"]

    /// A terminal event (or `error`) has been mapped; nothing after it matters.
    private(set) var isFinished = false
    /// `recover(from:)` stood in for the terminal event with `synthesizedTerminal()`.
    private(set) var didStandIn = false
    private var responseID: String?
    private var model: String?
    /// Items announced and not finished yet, by key (item id, else "#<output_index>"), with their output indexes
    /// (-1 when unknown).
    private var openItems: [String: Int] = [:]
    /// Finished items in the order they finished, by key: older LiteLLM numbers every item 0, so an output index
    /// can't tell them apart.
    private var doneItems: [(key: String, item: JSONValue)] = []

    mutating func map(_ event: SetappAIAPI.StreamingEvent) -> [JSONValue] {
        guard !isFinished, let mapped = Self.json(for: event) else { return [] }
        let json = Self.errorEvent(fromFrame: mapped) ?? mapped
        note(json)
        return [json]
    }

    /// What to do when the SDK stream throws `error`, in order:
    /// 1. A thrown `error` event (the connector throws them instead of yielding them): yield it as an `error` event.
    /// 2. An event the connector couldn't decode whose text still reaches Otto (it logs "Failed to parse SSE event:
    ///    …, line: <event>"): yield it as the gateway sent it when it is terminal; the stream ended there either way.
    ///    A typeless `{"error": {…}}` frame (LiteLLM's) is yielded as the `error` event it means.
    /// 3. A decoding failure in a lifecycle event's `output` or `usage` (in practice the terminal event, the only one
    ///    with a full output): stand in for it with `synthesizedTerminal()` when every announced item finished.
    ///    This is the only place a terminal event is ever built.
    /// 4. Any other decoding failure: `.server` with `unreadableMessage`. Anything else: what the SDK error maps to.
    mutating func recover(from error: Error) -> Recovery {
        let chain = SetappSDKErrors.Chain(error)
        if let streamError = chain.streamError {
            isFinished = true
            return .events([Self.errorJSON(code: streamError.code, message: streamError.message,
                                           param: streamError.param, sequenceNumber: streamError.sequenceNumber)])
        }
        let unreadable = Recovery.failure(.server(status: 0, message: Self.unreadableMessage))
        if let raw = chain.unparsedEvent {
            guard !isFinished else { return .events([]) }
            if let errorEvent = Self.errorEvent(fromFrame: raw) {
                isFinished = true
                return .events([errorEvent])
            }
            if raw.typeName != nil {
                note(raw)
                return isFinished ? .events([raw]) : unreadable
            }
        }
        guard let decodingError = chain.decodingError else {
            return .failure(SetappSDKErrors.transportError(for: chain))
        }
        guard Self.isTerminalPayloadFailure(decodingError), !isFinished, let terminal = synthesizedTerminal() else {
            return unreadable
        }
        isFinished = true
        didStandIn = true
        return .events([terminal])
    }

    /// A terminal event built from the `response.output_item.done` items, for a terminal event the SDK couldn't
    /// decode. Only when at least one item finished and none is still open, so a stream cut mid-item still fails.
    /// `response.incomplete` with `max_output_tokens` when an item finished incomplete (the output limit cut it
    /// off), else `response.completed`. It has no usage: the gateway's token counts went with the lost event.
    func synthesizedTerminal() -> JSONValue? {
        guard !doneItems.isEmpty, openItems.isEmpty else { return nil }
        let output = doneItems.map(\.item)
        let incomplete = output.contains { $0["status"]?.stringValue == "incomplete" }
        var response: [String: JSONValue] = [
            "id": .string(responseID ?? ""),
            "status": incomplete ? "incomplete" : "completed",
            "output": .array(output),
        ]
        if incomplete { response["incomplete_details"] = ["reason": "max_output_tokens"] }
        if let model { response["model"] = .string(model) }
        return ["type": incomplete ? "response.incomplete" : "response.completed", "response": .object(response)]
    }

    private mutating func note(_ event: JSONValue) {
        guard let type = event.typeName else { return }
        if let response = event["response"] {
            if let id = response["id"]?.stringValue, !id.isEmpty { responseID = id }
            if let model = response["model"]?.stringValue, !model.isEmpty { self.model = model }
        }
        let index = event["output_index"]?.intValue
        switch type {
        case "response.output_item.added":
            openItems[Self.itemKey(event["item"], index: index)] = index ?? -1
        case "response.output_item.done":
            guard let item = event["item"], item.objectValue != nil else { break }
            let key = Self.itemKey(item, index: index)
            if openItems.removeValue(forKey: key) == nil, let index,
               let opened = openItems.first(where: { $0.value == index })?.key {
                // Announced under another id (or none): the open item at the same index is this one.
                openItems.removeValue(forKey: opened)
            }
            if let existing = doneItems.firstIndex(where: { $0.key == key }) {
                doneItems[existing].item = item
            } else {
                doneItems.append((key, item))
            }
        case _ where Self.terminalTypes.contains(type):
            isFinished = true
        default:
            break
        }
    }

    private static func itemKey(_ item: JSONValue?, index: Int?) -> String {
        if let id = item?["id"]?.stringValue, !id.isEmpty { return id }
        return "#\(index.map(String.init) ?? "?")"
    }

    /// LiteLLM's mid-stream failure, `{"error": {"message", "type", "param", "code"}}` with no `type` of its own, as
    /// the `error` event it means: code = its `code` (string or number), else its `type`. Nil for anything else.
    static func errorEvent(fromFrame frame: JSONValue) -> JSONValue? {
        // Every Responses event type but "error" has a dot; a frame without one (or without a type) isn't an event.
        let type = frame.typeName ?? ""
        guard !type.contains("."), type != "error", let error = frame["error"], error.objectValue != nil else {
            return nil
        }
        let code = error["code"]?.stringValue ?? error["code"]?.intValue.map(String.init) ?? error["type"]?.stringValue
        return errorJSON(code: code, message: error["message"]?.stringValue ?? "", param: error["param"]?.stringValue,
                         sequenceNumber: nil)
    }

    /// A decoding failure inside a lifecycle event's `output` or `usage`.
    private static func isTerminalPayloadFailure(_ error: DecodingError) -> Bool {
        let path = SetappSDKErrors.codingPath(of: error).map(\.stringValue)
        return path.first == "response" && (path.contains("output") || path.contains("usage"))
    }

    // MARK: Mapping

    /// One SDK event as the gateway's JSON. Nil for events Otto doesn't use (image generation, kinds newer than 5.5.0).
    static func json(for event: SetappAIAPI.StreamingEvent) -> JSONValue? {
        switch event {
        case .response(let response):
            return json(for: response)
        case .unsupported(let unsupported):
            guard case .object(var object) = SendableJSON.value(unsupported.object) else { return nil }
            if object["type"] == nil { object["type"] = .string(unsupported.type.rawValue) }
            return .object(object)
        case .imageGeneration:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func json(for response: SetappAIAPI.StreamingEvent.Response) -> JSONValue? {
        switch response {
        case .outputText(.delta(let delta)):
            return textJSON(type: "response.output_text.delta", itemID: delta.itemID, outputIndex: delta.outputIndex,
                            contentIndex: delta.contentIndex, sequenceNumber: delta.sequenceNumber,
                            field: ("delta", delta.delta))
        case .outputText(.done(let done)):
            return textJSON(type: "response.output_text.done", itemID: done.itemID, outputIndex: done.outputIndex,
                            contentIndex: done.contentIndex, sequenceNumber: done.sequenceNumber,
                            field: ("text", done.text))
        case .responseLifecycle(let lifecycle):
            switch lifecycle {
            case .created(let event): return lifecycleJSON(type: "response.created", event: event)
            case .inProgress(let event): return lifecycleJSON(type: "response.in_progress", event: event)
            case .completed(let event): return lifecycleJSON(type: "response.completed", event: event)
            case .failed(let event): return lifecycleJSON(type: "response.failed", event: event)
            case .incomplete(let event): return lifecycleJSON(type: "response.incomplete", event: event)
            case .queued(let event): return lifecycleJSON(type: "response.queued", event: event)
            @unknown default: return nil
            }
        case .error(let error):
            return errorJSON(code: error.code, message: error.message, param: error.param,
                             sequenceNumber: error.sequenceNumber)
        @unknown default:
            return nil
        }
    }

    private static func textJSON(type: String, itemID: String, outputIndex: Int?, contentIndex: Int?,
                                 sequenceNumber: Int?, field: (String, String)) -> JSONValue {
        var object: [String: JSONValue] = ["type": .string(type), "item_id": .string(itemID), field.0: .string(field.1)]
        if let outputIndex { object["output_index"] = .int(Int64(outputIndex)) }
        if let contentIndex { object["content_index"] = .int(Int64(contentIndex)) }
        if let sequenceNumber { object["sequence_number"] = .int(Int64(sequenceNumber)) }
        return .object(object)
    }

    static func errorJSON(code: String?, message: String?, param: String?, sequenceNumber: Int?) -> JSONValue {
        var object: [String: JSONValue] = ["type": "error"]
        if let code { object["code"] = .string(code) }
        if let message { object["message"] = .string(message) }
        if let param { object["param"] = .string(param) }
        if let sequenceNumber { object["sequence_number"] = .int(Int64(sequenceNumber)) }
        return .object(object)
    }

    private static func lifecycleJSON(type: String, event: SetappAIAPI.StreamingEvent.Response.ResponseLifecycle.Event)
        -> JSONValue {
        let response = event.response
        var object: [String: JSONValue] = [
            "id": .string(response.id),
            "model": .string(response.model),
            "status": .string(response.status.rawValue),
        ]
        if let output = response.output { object["output"] = .array(output.compactMap(outputJSON)) }
        if let usage = response.usage { object["usage"] = usageJSON(usage) }
        if let reason = response.incompleteDetails?.reason { object["incomplete_details"] = ["reason": .string(reason)] }
        if let error = response.error {
            object["error"] = ["code": .string(error.code), "message": .string(error.message)]
        }
        var wrapper: [String: JSONValue] = ["type": .string(type), "response": .object(object)]
        if let sequence = event.sequenceNumber { wrapper["sequence_number"] = .int(Int64(sequence)) }
        return .object(wrapper)
    }

    /// One output item as JSON. Typed items go through the SDK's encoder (with the misspelled `star_index` put
    /// back to `start_index`); `.unsupported` ones are read directly, which keeps their numbers numbers.
    static func outputJSON(_ output: SetappAIAPI.Responses.Output) -> JSONValue? {
        if case .unsupported(let unsupported) = output {
            guard case .object(var object) = SendableJSON.value(unsupported.object) else { return nil }
            if object["type"] == nil { object["type"] = .string(unsupported.type.rawValue) }
            return .object(object)
        }
        guard let json = try? SetappSDKCoding.json(output) else { return nil }
        return renamingKey("star_index", to: "start_index", in: json)
    }

    private static func usageJSON(_ usage: SetappAIAPI.Responses.Usage) -> JSONValue {
        var object: [String: JSONValue] = [
            "input_tokens": .int(Int64(usage.inputTokens)),
            "output_tokens": .int(Int64(usage.outputTokens)),
            "total_tokens": .int(Int64(usage.totalTokens)),
        ]
        if let details = usage.inputTokensDetails {
            object["input_tokens_details"] = ["cached_tokens": .int(Int64(details.cachedTokens))]
        }
        if let details = usage.outputTokensDetails {
            object["output_tokens_details"] = ["reasoning_tokens": .int(Int64(details.reasoningTokens))]
        }
        return .object(object)
    }

    private static func renamingKey(_ key: String, to newKey: String, in value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var renamed: [String: JSONValue] = [:]
            for (name, child) in object {
                renamed[name == key && object[newKey] == nil ? newKey : name] = renamingKey(key, to: newKey, in: child)
            }
            return .object(renamed)
        case .array(let array):
            return .array(array.map { renamingKey(key, to: newKey, in: $0) })
        default:
            return value
        }
    }
}

// MARK: - Errors

/// Maps what the SDK throws to `ResponsesTransportError`. The SDK's `SetappAIError` names four codes; everything else
/// is `.general` with the real cause underneath (`NSUnderlyingErrorKey`): the connector's private HTTP error with
/// its `statusCode` and the gateway's body, a `URLError`, a `DecodingError`. `Chain` reads those by reflection, so a
/// 400 "prompt is too long" still reaches `ResponsesClient` as an overflow and a 5xx as a retryable server error.
enum SetappSDKErrors {
    /// Everything reachable from a thrown error: the error, its underlying errors, and their payloads.
    struct Chain {
        private(set) var errors: [Error] = []
        private(set) var strings: [(label: String, value: String)] = []
        private(set) var integers: [(label: String, value: Int)] = []

        init(_ error: Error) {
            visit(error, label: "", depth: 0)
        }

        var setappAIError: SetappAIError? { errors.lazy.compactMap { $0 as? SetappAIError }.first }
        var streamError: SetappAIAPI.StreamingEvent.Response.Error? {
            errors.lazy.compactMap { $0 as? SetappAIAPI.StreamingEvent.Response.Error }.first
        }
        var decodingError: DecodingError? { errors.lazy.compactMap { $0 as? DecodingError }.first }
        var urlError: URLError? {
            errors.lazy.compactMap { error -> URLError? in
                if let urlError = error as? URLError { return urlError }
                let nsError = error as NSError
                return nsError.domain == NSURLErrorDomain ? URLError(URLError.Code(rawValue: nsError.code)) : nil
            }.first
        }

        /// The HTTP status the connector recorded (`statusCode`), if any.
        var statusCode: Int? {
            integers.first { $0.label.lowercased() == "statuscode" || $0.label.lowercased() == "status" }?.value
        }

        /// The gateway's stable code (`INSUFFICIENT_CREDITS`, …) or an OpenAI-style error code, if any.
        var code: String? {
            strings.first { $0.label.lowercased() == "code" }?.value ?? bodyField("code")
        }

        /// The gateway's or provider's message, if any.
        var message: String? {
            let labels: Set<String> = ["message", "detail", "reason"]
            if let message = strings.first(where: { labels.contains($0.label.lowercased()) })?.value { return message }
            return bodyField("message")
        }

        /// The raw event the connector failed to decode, recovered from its "… line: <event>" text.
        var unparsedEvent: JSONValue? {
            for (_, text) in strings {
                guard text.contains("Failed to parse SSE event"), let marker = text.range(of: ", line: ") else { continue }
                var line = text[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("data:") { line = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                if let event = try? JSONValue.decode(line), event.objectValue != nil { return event }
            }
            return nil
        }

        /// A field of a JSON error body found among the strings: `{"code", "message"}` (gateway format) or
        /// `{"error": {"code", "message"}}` (OpenAI format).
        private func bodyField(_ key: String) -> String? {
            for (_, text) in strings where text.hasPrefix("{") {
                guard let body = try? JSONValue.decode(text) else { continue }
                if let value = body[key]?.stringValue ?? body["error"]?[key]?.stringValue { return value }
            }
            return nil
        }

        private mutating func visit(_ value: Any, label: String, depth: Int) {
            guard depth < 8, errors.count + strings.count + integers.count < 96 else { return }
            if let error = value as? Error {
                errors.append(error)
                let nsError = error as NSError
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] {
                    visit(underlying, label: "underlying", depth: depth + 1)
                }
                if let many = nsError.userInfo["NSMultipleUnderlyingErrorsKey"] as? [Any] {
                    for underlying in many { visit(underlying, label: "underlying", depth: depth + 1) }
                }
                if error is DecodingError { return }
            }
            // Before reflection: these bridge to Foundation and would otherwise be taken apart.
            switch value {
            case let string as String:
                strings.append((label, string))
                return
            case let integer as Int:
                integers.append((label, integer))
                return
            case let data as Data:
                if let text = String(data: data, encoding: .utf8) { strings.append((label, text)) }
                return
            default:
                break
            }
            // Enum payloads, tuples and structs; an Optional's single child keeps the label it was found under.
            for child in Mirror(reflecting: value).children {
                let childLabel = child.label.flatMap { $0 == "some" ? nil : $0 } ?? label
                visit(child.value, label: childLabel, depth: depth + 1)
            }
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let chain = Chain(error)
        return chain.errors.contains { $0 is CancellationError } || chain.urlError?.code == .cancelled
    }

    static func transportError(for error: Error) -> ResponsesTransportError {
        transportError(for: Chain(error))
    }

    /// `SetappAIError.code` first, then the gateway's stable code, the HTTP status, a network failure, and
    /// `.unavailable` for the rest (Setapp not running, the member not signed in, an SDK problem).
    static func transportError(for chain: Chain) -> ResponsesTransportError {
        if let setappError = chain.setappAIError {
            switch setappError.code {
            case .insufficientCredits: return .insufficientCredits
            case .modelNotAllowed: return .modelNotAllowed
            case .rateLimit: return .rateLimited(retryAfter: nil)
            case .general: break
            @unknown default: break
            }
        }
        let message = chain.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch chain.code?.uppercased() {
        case "INSUFFICIENT_CREDITS": return .insufficientCredits
        case "FORBIDDEN": return .modelNotAllowed
        case "RATE_LIMIT_EXCEEDED": return .rateLimited(retryAfter: nil)
        case "UNAUTHORIZED": return .unauthorized
        case "BAD_REQUEST": return .badRequest(status: chain.statusCode ?? 400, message: message)
        case "VALIDATION": return .badRequest(status: chain.statusCode ?? 422, message: message)
        case "INTERNAL_SERVER_ERROR": return .server(status: chain.statusCode ?? 500, message: message)
        default: break
        }
        if let status = chain.statusCode, (400..<600).contains(status) {
            return transportError(status: status, message: message)
        }
        if let urlError = chain.urlError {
            return .network(networkMessage(for: urlError))
        }
        if chain.decodingError != nil {
            return .server(status: 0, message: SetappSDKEventMapper.unreadableMessage)
        }
        return .unavailable(chain.errors.first?.localizedDescription ?? "")
    }

    /// The gateway's status table (SPEC §1).
    static func transportError(status: Int, message: String) -> ResponsesTransportError {
        switch status {
        case 401: return .unauthorized
        case 402: return .insufficientCredits
        case 403: return .modelNotAllowed
        case 429: return .rateLimited(retryAfter: nil)
        case 500..<600: return .server(status: status, message: message)
        default: return .badRequest(status: status, message: message)
        }
    }

    /// User-facing text for a network failure; empty means `ResponsesClient`'s own default.
    static func networkMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed:
            return "You're offline. Check your internet connection and try again."
        case .timedOut:
            return "The request to Setapp AI timed out."
        case .networkConnectionLost:
            return "The network connection was lost."
        default:
            return ""
        }
    }

    /// A transport error's case, for logs (never its message).
    static func logLabel(_ error: ResponsesTransportError) -> String {
        switch error {
        case .insufficientCredits: return "insufficientCredits"
        case .modelNotAllowed: return "modelNotAllowed"
        case .rateLimited: return "rateLimited"
        case .unauthorized: return "unauthorized"
        case .notConfigured: return "notConfigured"
        case .badRequest(let status, _): return "badRequest(\(status))"
        case .server(let status, _): return "server(\(status))"
        case .unavailable: return "unavailable"
        case .network: return "network"
        }
    }

    static func codingPath(of error: DecodingError) -> [CodingKey] {
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return context.codingPath
        case .keyNotFound(let key, let context):
            return context.codingPath + [key]
        @unknown default:
            return []
        }
    }
}

// MARK: - Raw JSON

/// The SDK's raw JSON (`[String: any Sendable]`) to and from `JSONValue`. Reading: booleans are CFBooleans (a Swift
/// `Bool` bridges to one too), so they are told apart from the numbers 0 and 1 before anything is read as a number.
/// Writing: only String, Bool, Int, Double, arrays and dictionaries, the types the SDK's encoder takes; nulls are
/// left out.
enum SendableJSON {
    static func value(_ raw: Any) -> JSONValue {
        switch raw {
        case is NSNull:
            return .null
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            let typeID = CFGetTypeID(number)
            if typeID == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if typeID == CFNumberGetTypeID(), !CFNumberIsFloatType(number) { return .int(number.int64Value) }
            return .double(number.doubleValue)
        case let dictionary as [String: Any]:
            return .object(dictionary.mapValues(value))
        case let array as [Any]:
            return .array(array.map(value))
        default:
            return .string(String(describing: raw))
        }
    }

    static func sendable(_ value: JSONValue) -> (any Sendable)? {
        switch value {
        case .null: return nil
        case .bool(let bool): return bool
        case .int(let int): return Int(int)
        case .double(let double): return double
        case .string(let string): return string
        case .array(let array): return array.compactMap(sendable) as [any Sendable]
        case .object: return object(value)
        }
    }

    static func object(_ value: JSONValue) -> [String: any Sendable]? {
        guard case .object(let object) = value else { return nil }
        var result: [String: any Sendable] = [:]
        for (key, child) in object {
            if let converted = sendable(child) { result[key] = converted }
        }
        return result
    }
}

// MARK: - Cancellation

/// The SDK stream of one request, so `onTermination` can cancel it from any thread, even before it exists.
private final class SDKStreamHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: CancellableAsyncStream<SetappAIAPI.StreamingEvent>?
    private var isCancelled = false

    /// Keeps `stream`; false (after cancelling it) when the request was already cancelled.
    func attach(_ stream: CancellableAsyncStream<SetappAIAPI.StreamingEvent>) -> Bool {
        lock.lock()
        let cancelled = isCancelled
        if !cancelled { self.stream = stream }
        lock.unlock()
        if cancelled { stream.cancel() }
        return !cancelled
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let stream = self.stream
        self.stream = nil
        lock.unlock()
        stream?.cancel()
    }
}
#endif
