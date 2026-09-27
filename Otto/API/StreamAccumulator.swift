//
//  StreamAccumulator.swift
//  Otto
//
//  Folds Messages API streaming events into complete content blocks (so they can be sent back to the
//  API verbatim on later turns) and translates them into the UI-facing `StreamEvent`s: text, thinking,
//  server-tool activity and sources, client `tool_use` calls (with their raw streamed input) and the
//  cumulative usage of the response.
//
//  Blocks are keyed by the event `index`. Growing fields (text, thinking, citations, partial tool
//  input JSON) live in side buffers while a block is open so appends stay amortized O(1); they are
//  folded back into the block on `content_block_stop` and whenever `result()` is taken.
//

import Foundation

/// Folds Messages streaming events into content blocks and emits StreamEvents.
struct StreamAccumulator {
    /// Content blocks as started by `content_block_start` (open blocks are completed from the buffers).
    private var blocks: [Int: JSONValue] = [:]
    private var textBuffers: [Int: String] = [:]
    private var thinkingBuffers: [Int: String] = [:]
    private var signatures: [Int: String] = [:]
    private var citationBuffers: [Int: [JSONValue]] = [:]
    private var partialJSON: [Int: String] = [:]

    /// Server tool calls by `server_tool_use` id, so their result blocks can reuse kind and label.
    private var activities: [String: ToolActivity] = [:]

    private var model: String?
    private var usage: JSONValue?
    private var stopReason: String?
    private var stopDetails: JSONValue?

    /// True after `message_stop`.
    private(set) var isComplete = false

    init() {}

    /// Registers the server tool calls of a trailing assistant message (a `pause_turn` continuation),
    /// so result blocks that arrive in this response for calls made in the previous one keep their
    /// original labels instead of generic ones.
    mutating func registerPriorToolUses(in messages: [JSONValue]) {
        guard let last = messages.last, last["role"]?.stringValue == "assistant",
              let content = last["content"]?.arrayValue else { return }
        for block in content where block.typeName == "server_tool_use" {
            guard let id = block["id"]?.stringValue else { continue }
            activities[id] = Self.makeActivity(id: id, name: block["name"]?.stringValue, input: block["input"])
        }
    }

    /// Returns zero or more StreamEvents for one decoded SSE event. Throws LLMError.streamError on `error` events.
    mutating func handle(_ event: JSONValue) throws -> [StreamEvent] {
        switch event.typeName {
        case "message_start":
            return handleMessageStart(event)
        case "content_block_start":
            return handleBlockStart(event)
        case "content_block_delta":
            return handleBlockDelta(event)
        case "content_block_stop":
            return handleBlockStop(event)
        case "message_delta":
            return handleMessageDelta(event)
        case "message_stop":
            isComplete = true
            return []
        case "error":
            throw Self.streamError(from: event)
        default:
            return []  // `ping` and event types added to the API later
        }
    }

    func result() -> StreamResult {
        let content = blocks.keys.sorted().compactMap { materializedBlock(at: $0) }
        return StreamResult(content: content, stopReason: stopReason, stopDetails: stopDetails, model: model, usage: usage)
    }

    // MARK: - Message events

    private mutating func handleMessageStart(_ event: JSONValue) -> [StreamEvent] {
        let message = event["message"]
        var events: [StreamEvent] = []
        if let model = message?["model"]?.stringValue, !model.isEmpty {
            self.model = model
            events.append(.messageStart(model: model))
        }
        if let usage = message?["usage"], let merged = Self.merge(self.usage, with: usage) {
            self.usage = merged
            events.append(.usage(merged))
        }
        return events
    }

    /// Records the stop reason and details; reports the cumulative usage when the event carries some.
    private mutating func handleMessageDelta(_ event: JSONValue) -> [StreamEvent] {
        if let delta = event["delta"] {
            if let reason = delta["stop_reason"]?.stringValue {
                stopReason = reason
            }
            if let details = delta["stop_details"] {
                // Explicit `Optional.none`: a bare `nil` here could be taken as JSONValue.null.
                stopDetails = details == .null ? Optional.none : Optional.some(details)
            }
        }
        guard let usage = event["usage"], let merged = Self.merge(self.usage, with: usage) else { return [] }
        self.usage = merged
        return [.usage(merged)]
    }

    // MARK: - Content block events

    private mutating func handleBlockStart(_ event: JSONValue) -> [StreamEvent] {
        guard let index = event["index"]?.intValue, let block = event["content_block"],
              case .object = block, let type = block.typeName else { return [] }

        blocks[index] = block
        clearBuffers(at: index)

        switch type {
        case "thinking":
            var events: [StreamEvent] = [.thinkingStarted]
            if let thinking = block["thinking"]?.stringValue, !thinking.isEmpty {
                events.append(.thinkingDelta(thinking))
            }
            return events

        case "text":
            if let text = block["text"]?.stringValue, !text.isEmpty {
                return [.textDelta(text)]
            }
            return []

        case "server_tool_use":
            // Announced on content_block_stop, once the streamed input JSON is complete.
            return []

        case "tool_use":
            // A client tool call: the loop shows a row while its input streams. Never a server activity.
            guard let id = block["id"]?.stringValue, !id.isEmpty,
                  let name = block["name"]?.stringValue, !name.isEmpty else { return [] }
            return [.toolUseStarted(id: id, name: name)]

        case "web_search_tool_result":
            return webSearchResultEvents(block)

        case "web_fetch_tool_result":
            return webFetchResultEvents(block)

        case "fallback":
            let fromModel = block["from"]?["model"]?.stringValue
            let toModel = block["to"]?["model"]?.stringValue
            if let toModel, !toModel.isEmpty {
                model = toModel
            }
            return [.fallback(fromModel: fromModel, toModel: toModel)]

        default:
            // Results of other server tools (e.g. the code execution behind dynamic web filtering):
            // finish the matching activity so the UI does not keep a spinner running.
            guard type.hasSuffix("_tool_result"), let toolUseID = block["tool_use_id"]?.stringValue,
                  var activity = activities[toolUseID], !activity.isDone else { return [] }
            activity.isDone = true
            activities[toolUseID] = activity
            return [.toolActivity(activity)]
        }
    }

    private mutating func handleBlockDelta(_ event: JSONValue) -> [StreamEvent] {
        guard let index = event["index"]?.intValue, let delta = event["delta"] else { return [] }

        switch delta.typeName {
        case "text_delta":
            guard let text = delta["text"]?.stringValue else { return [] }
            if blocks[index] == nil {
                blocks[index] = ["type": "text", "text": ""]  // tolerate a missing block start
            }
            let base = blocks[index]?["text"]?.stringValue ?? ""
            textBuffers[index, default: base].append(text)
            return text.isEmpty ? [] : [.textDelta(text)]

        case "thinking_delta":
            guard let thinking = delta["thinking"]?.stringValue else { return [] }
            if blocks[index] == nil {
                blocks[index] = ["type": "thinking", "thinking": "", "signature": ""]
            }
            let base = blocks[index]?["thinking"]?.stringValue ?? ""
            thinkingBuffers[index, default: base].append(thinking)
            return thinking.isEmpty ? [] : [.thinkingDelta(thinking)]

        case "signature_delta":
            guard blocks[index] != nil, let signature = delta["signature"]?.stringValue else { return [] }
            signatures[index] = signature
            return []

        case "input_json_delta":
            guard blocks[index] != nil, let fragment = delta["partial_json"]?.stringValue else { return [] }
            partialJSON[index, default: ""].append(fragment)
            return []

        case "citations_delta":
            guard blocks[index] != nil, let citation = delta["citation"], case .object = citation else { return [] }
            let base = blocks[index]?["citations"]?.arrayValue ?? []
            citationBuffers[index, default: base].append(citation)
            guard let url = citation["url"]?.stringValue.flatMap(Self.webURL) else { return [] }
            return [.sources([SourceLink(title: Self.title(citation["title"]?.stringValue, fallbackURL: url), url: url)])]

        default:
            return []  // unknown delta types are ignored
        }
    }

    private mutating func handleBlockStop(_ event: JSONValue) -> [StreamEvent] {
        guard let index = event["index"]?.intValue, let block = materializedBlock(at: index) else { return [] }
        // Read before the buffers are cleared: eager input streaming can end on cut-off or invalid JSON,
        // and the loop echoes the raw text back to Claude when it does.
        let rawInput = partialJSON[index] ?? ""
        let startInput = blocks[index]?["input"]
        blocks[index] = block
        clearBuffers(at: index)

        switch block.typeName {
        case "server_tool_use":
            guard let id = block["id"]?.stringValue else { return [] }
            let activity = Self.makeActivity(id: id, name: block["name"]?.stringValue, input: block["input"])
            activities[id] = activity
            return [.toolActivity(activity)]
        case "tool_use":
            guard let id = block["id"]?.stringValue, !id.isEmpty,
                  let name = block["name"]?.stringValue, !name.isEmpty else { return [] }
            let input: JSONValue?
            if rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Nothing streamed: the start input is the whole input (normally `{}`).
                if case .object? = startInput { input = startInput } else { input = nil }
            } else {
                input = Self.parseToolInput(rawInput)
            }
            return [.toolUseReady(id: id, name: name, input: input, rawInput: rawInput)]
        default:
            return []
        }
    }

    // MARK: - Server tool results

    private mutating func webSearchResultEvents(_ block: JSONValue) -> [StreamEvent] {
        guard let toolUseID = block["tool_use_id"]?.stringValue else { return [] }
        var events: [StreamEvent] = [
            .toolActivity(finishActivity(id: toolUseID, fallbackKind: .webSearch, fallbackLabel: "Searching the web")),
        ]

        // An array is a successful search; an object is a `web_search_tool_result_error`.
        if let results = block["content"]?.arrayValue {
            var seen = Set<URL>()
            let links: [SourceLink] = results.compactMap { item in
                guard item.typeName == "web_search_result",
                      let url = item["url"]?.stringValue.flatMap(Self.webURL),
                      seen.insert(url).inserted else { return nil }
                return SourceLink(title: Self.title(item["title"]?.stringValue, fallbackURL: url), url: url)
            }
            if !links.isEmpty {
                events.append(.sources(links))
            }
        }
        return events
    }

    private mutating func webFetchResultEvents(_ block: JSONValue) -> [StreamEvent] {
        guard let toolUseID = block["tool_use_id"]?.stringValue else { return [] }
        let content = block["content"]
        // `content.url` exists only on a successful `web_fetch_result`, not on an error object.
        let url = content?["url"]?.stringValue.flatMap(Self.webURL)
        let fallbackLabel = url.map { "Reading \(Self.displayHost(of: $0))" } ?? "Reading a web page"

        var events: [StreamEvent] = [
            .toolActivity(finishActivity(id: toolUseID, fallbackKind: .webFetch, fallbackLabel: fallbackLabel)),
        ]
        if let url {
            let title = Self.title(content?["content"]?["title"]?.stringValue, fallbackURL: url)
            events.append(.sources([SourceLink(title: title, url: url)]))
        }
        return events
    }

    /// Marks the activity for `id` done, synthesizing one when its tool call was never seen.
    private mutating func finishActivity(id: String, fallbackKind: ToolActivity.Kind, fallbackLabel: String) -> ToolActivity {
        var activity = activities[id] ?? ToolActivity(id: id, kind: fallbackKind, label: fallbackLabel, isDone: true)
        activity.isDone = true
        activities[id] = activity
        return activity
    }

    // MARK: - Block assembly

    /// The block at `index` with its buffered deltas folded in.
    private func materializedBlock(at index: Int) -> JSONValue? {
        guard var block = blocks[index] else { return nil }
        if let text = textBuffers[index] {
            block = block.setting("text", to: .string(text))
        }
        if let thinking = thinkingBuffers[index] {
            block = block.setting("thinking", to: .string(thinking))
        }
        if let signature = signatures[index] {
            block = block.setting("signature", to: .string(signature))
        }
        if let citations = citationBuffers[index] {
            block = block.setting("citations", to: .array(citations))
        }
        // Keep the start `input` when nothing streamed or the JSON does not parse.
        if let json = partialJSON[index], let input = Self.parseToolInput(json) {
            block = block.setting("input", to: input)
        }
        return block
    }

    private mutating func clearBuffers(at index: Int) {
        textBuffers[index] = nil
        thinkingBuffers[index] = nil
        signatures[index] = nil
        citationBuffers[index] = nil
        partialJSON[index] = nil
    }

    // MARK: - Helpers

    static func parseToolInput(_ json: String) -> JSONValue? {
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let value = try? JSONValue.decode(json), case .object = value else { return nil }
        return value
    }

    static func makeActivity(id: String, name: String?, input: JSONValue?) -> ToolActivity {
        switch name {
        case "web_search":
            let query = input?["query"]?.stringValue.map(collapsingWhitespace) ?? ""
            let label = query.isEmpty ? "Searching the web" : "Searching \u{201C}\(query)\u{201D}"
            return ToolActivity(id: id, kind: .webSearch, label: label, isDone: false)
        case "web_fetch":
            let url = input?["url"]?.stringValue.flatMap(webURL)
            let label = url.map { "Reading \(displayHost(of: $0))" } ?? "Reading a web page"
            return ToolActivity(id: id, kind: .webFetch, label: label, isDone: false)
        default:
            let label = (name?.isEmpty == false ? name : nil) ?? "Using a tool"
            return ToolActivity(id: id, kind: .other, label: label, isDone: false)
        }
    }

    static func streamError(from event: JSONValue) -> LLMError {
        let type = event["error"]?["type"]?.stringValue
        let message = event["error"]?["message"]?.stringValue ?? ""
        if type == "overloaded_error" {
            return .overloaded
        }
        return .streamError(type: type, message: message)
    }

    /// Shallow object merge; later non-null values win (`message_delta` usage is cumulative).
    private static func merge(_ base: JSONValue?, with update: JSONValue) -> JSONValue? {
        guard case .object(let updateFields) = update else { return base }
        var merged = base?.objectValue ?? [:]
        for (key, value) in updateFields where value != .null {
            merged[key] = value
        }
        return .object(merged)
    }

    /// Only http(s) URLs become sources: the UI opens them on click.
    static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    static func displayHost(of url: URL) -> String {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func title(_ title: String?, fallbackURL url: URL) -> String {
        let trimmed = title.map(collapsingWhitespace) ?? ""
        return trimmed.isEmpty ? displayHost(of: url) : trimmed
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
