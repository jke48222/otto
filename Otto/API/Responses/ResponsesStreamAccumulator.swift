//
//  ResponsesStreamAccumulator.swift
//  Otto
//
//  Folds OpenAI Responses streaming events from Setapp's AI Gateway into Anthropic Messages content blocks (Otto's
//  only stored format) and translates them into the same `StreamEvent`s `StreamAccumulator` produces: text,
//  summarized thinking, web search activity and sources, client tool calls and usage (SPEC §19, Setapp AI).
//
//  The Setapp SDK types only text deltas and lifecycle events; reasoning summaries, function-call arguments,
//  output items and web search events may arrive untyped or not at all. So whatever streams is shown as it
//  arrives, and each finished output item (`response.output_item.done`, then the terminal event's
//  `response.output`) fills in what didn't: every item is shown exactly once, by whichever path reaches it first.
//  The terminal output is authoritative for `result()`.
//
//  Live state is keyed by item id, or by "#<output_index>" when an event carries none. Reasoning is also keyed by
//  output index, because LiteLLM (which the gateway most likely runs) has given each summary delta an id of its own
//  and the finished item another. LiteLLM's shapes differ from OpenAI's in a few more places this file reads: a
//  terminal `response.completed` whose status is "incomplete" with no reason, a reasoning item with `content`
//  instead of `summary`, and url_citations with no web_search_call behind them.
//

import Foundation

/// Folds Responses streaming events into Anthropic content blocks and emits StreamEvents.
struct ResponsesStreamAccumulator {
    /// The running label of a web search call, before its action is known.
    static let searchingLabel = "Searching the web"

    private struct ReasoningProgress {
        var started = false
        /// The summary part being streamed; a higher index starts a new paragraph.
        var part = 0
        /// Summary text streamed, by part.
        var parts: [Int: String] = [:]
        /// The whole summary was shown from the finished item instead.
        var reconciled = false
        var hasText: Bool { parts.values.contains { !$0.isEmpty } }
    }

    private struct CallProgress {
        var callID = ""
        var name = ""
        var arguments = ""
        var finalArguments: String?
    }

    private struct StreamedText {
        var index: Int?
        var text: String
    }

    private struct DoneItem {
        var key: String
        var index: Int
        var item: JSONValue
    }

    private let requestedModel: ModelOption
    /// The request's `max_output_tokens`: a response cut off with no reason that used this many is a truncation.
    private let outputLimit: Int
    private var model: String?
    private var didStart = false

    private var reasoning: [String: ReasoningProgress] = [:]
    /// The reasoning progress key of each output index (see the file header).
    private var reasoningKeys: [Int: String] = [:]
    /// Text or a client call has been shown in this response.
    private var emittedOutput = false
    /// Text shown per message item (streamed, or the whole text of a finished item that streamed none).
    private var texts: [String: StreamedText] = [:]
    private var calls: [String: CallProgress] = [:]
    /// Client calls by `call_id` that got `.toolUseStarted`.
    private var startedCalls: Set<String> = []
    /// Client calls by `call_id` that got `.toolUseReady`, with the item that did: a repeated call id in the same
    /// response is the same call, so it is announced, run and stored once.
    private var readyCalls: [String: String] = [:]
    private var runningWebCalls: Set<String> = []
    private var finishedWebCalls: Set<String> = []
    /// Every source URL announced in this response (search sources, opened pages, citations).
    private var seenSources: Set<URL> = []
    /// Titles from `url_citation` annotations, by URL, for the synthesized search results.
    private var citationTitles: [String: String] = [:]
    /// Every `url_citation` URL in this response, in the order they arrived.
    private var citedURLs: [String] = []
    /// Items from `response.output_item.done`, in the order they finished. Keyed by item id (or index), so a gateway
    /// that numbers every item 0 (older LiteLLM) can't make one overwrite another.
    private var doneItems: [DoneItem] = []
    private var itemIndices: [String: Int] = [:]
    /// The `response` object of `response.completed` / `response.incomplete`.
    private var terminal: JSONValue?
    private var terminalType: String?

    /// True after `response.completed` or `response.incomplete`.
    private(set) var isComplete = false

    /// `maxOutputTokens` is the request's output limit, `requestedModel.maxOutputTokens` when not given.
    init(requestedModel: ModelOption, maxOutputTokens: Int? = nil) {
        self.requestedModel = requestedModel
        self.outputLimit = maxOutputTokens ?? requestedModel.maxOutputTokens
    }

    /// One gateway event in, the StreamEvents it produces out. Throws LLMError for `error` / `response.failed`.
    mutating func handle(_ event: JSONValue) throws -> [StreamEvent] {
        guard !isComplete else { return [] }
        let response = event["response"].flatMap { $0.objectValue == nil ? nil : $0 }
        if let response {
            adoptModel(response["model"]?.stringValue)
        }
        let produced = try events(for: event)
        // `.messageStart` comes first, once: on the first event that carries a response, or before the first
        // other StreamEvent when the SDK delivered none (only text deltas and the terminal event).
        guard !didStart, response != nil || !produced.isEmpty else { return produced }
        didStart = true
        let model = self.model ?? requestedModel.setappAIModelID
        self.model = model
        return [.messageStart(model: model)] + produced
    }

    /// The assembled response (Anthropic blocks). Valid once `isComplete`.
    func result() -> StreamResult {
        let items = finalItems()
        let titles = allCitationTitles(items)
        let keptCalls = keptCallItems(items)

        var content: [JSONValue] = []
        var refused = false
        var calledTools = false
        for (position, entry) in items.enumerated() {
            let (index, item) = entry
            switch item.typeName {
            case "reasoning":
                content += reasoningBlocks(item, index: index)
            case "web_search_call":
                content += Self.webBlocks(item, id: Self.itemID(item, fallbackIndex: index), titles: titles)
            case "message":
                if Self.hasRefusal(item) { refused = true }
                let text = Self.outputText(of: item)
                if !text.isEmpty {
                    content.append(["type": "text", "text": .string(text)])
                }
            case "function_call":
                guard keptCalls.contains(position), let block = toolUseBlock(item, index: index) else { continue }
                content.append(block)
                calledTools = true
            default:
                break
            }
        }
        // Text that cites the web read the web, even when the gateway sent no web_search_call for it: without
        // these blocks TrustLedger, the "Safer" pause and the web budget would never see that search.
        let cited = uncoveredCitations(items)
        if !cited.isEmpty {
            content += Self.citationSearchBlocks(urls: cited, titles: titles,
                                                 id: "ws_cited_" + (terminal?["id"]?.stringValue ?? "response"))
        }

        let incompleteReason = self.incompleteReason
        let stopReason: String
        // A response cut off by the output limit reports that even when it got as far as a tool call: the call's
        // arguments are probably cut off too, and Anthropic says `max_tokens` in the same spot.
        if refused || incompleteReason == "content_filter" {
            stopReason = "refusal"
        } else if incompleteReason == "max_output_tokens" {
            stopReason = "max_tokens"
        } else if calledTools {
            stopReason = "tool_use"
        } else {
            stopReason = "end_turn"
        }
        return StreamResult(content: content, stopReason: stopReason, stopDetails: nil,
                            model: model ?? requestedModel.setappAIModelID, usage: mappedUsage(items))
    }

    /// Why the response stopped early, if it did. LiteLLM ends every stream with `response.completed` and maps
    /// Anthropic's `max_tokens`, `refusal` and content filtering all to the status "incomplete", often with no
    /// `incomplete_details`: a response that used its whole output limit (or reported no usage) was cut off by it,
    /// anything shorter was stopped for its content.
    private var incompleteReason: String? {
        if let reason = terminal?["incomplete_details"]?["reason"]?.stringValue, !reason.isEmpty { return reason }
        let status = terminal?["status"]?.stringValue ?? (terminalType == "response.incomplete" ? "incomplete" : nil)
        guard status == "incomplete" else { return nil }
        guard let used = terminal?["usage"]?["output_tokens"]?.intValue else { return "max_output_tokens" }
        return used >= outputLimit ? "max_output_tokens" : "content_filter"
    }

    // MARK: - Events

    private mutating func events(for event: JSONValue) throws -> [StreamEvent] {
        switch event.typeName {
        case "response.output_item.added":
            return itemAdded(event)
        case "response.output_item.done":
            return itemDone(event)
        case "response.reasoning_summary_part.added":
            return summaryPartAdded(event)
        case "response.reasoning_summary_text.delta":
            return summaryDelta(event)
        case "response.output_text.delta":
            return textDelta(event)
        case "response.output_text.annotation.added":
            guard let annotation = event["annotation"] else { return [] }
            let links = newSources(fromCitations: [annotation])
            return links.isEmpty ? [] : [.sources(links)]
        case "response.function_call_arguments.delta":
            guard let delta = event["delta"]?.stringValue else { return [] }
            calls[Self.key(of: event), default: CallProgress()].arguments.append(delta)
            return []
        case "response.function_call_arguments.done":
            if let arguments = event["arguments"]?.stringValue {
                calls[Self.key(of: event), default: CallProgress()].finalArguments = arguments
            }
            return []
        case "response.completed", "response.incomplete":
            terminalType = event.typeName
            return finish(event["response"])
        case "response.failed":
            let error = event["response"]?["error"]
            throw Self.eventError(code: Self.code(of: error), message: error?["message"]?.stringValue ?? "",
                                  model: requestedModel)
        case "error":
            // OpenAI documents `code` and `message` on the event itself; some gateways nest them in `error`.
            let error = event["error"]?.objectValue == nil ? event : event["error"]
            throw Self.eventError(code: Self.code(of: error), message: error?["message"]?.stringValue ?? "",
                                  model: requestedModel)
        case nil where event["error"]?.objectValue != nil:
            // LiteLLM reports a failure mid-stream as `{"error": {"message", "type", "param", "code"}}`, no type.
            let error = event["error"]
            throw Self.eventError(code: Self.code(of: error), message: error?["message"]?.stringValue ?? "",
                                  model: requestedModel)
        default:
            return []  // lifecycle, content parts, `*.done` text, web search progress and event types added later
        }
    }

    private mutating func itemAdded(_ event: JSONValue) -> [StreamEvent] {
        guard let item = event["item"], item.objectValue != nil else { return [] }
        let outputIndex = event["output_index"]?.intValue
        let id = Self.itemID(item, fallbackIndex: outputIndex)
        if let outputIndex {
            itemIndices[id] = outputIndex
        }
        switch item.typeName {
        case "reasoning":
            let key = reasoningKey(itemID: Self.nonEmpty(item["id"]?.stringValue), index: outputIndex)
            var progress = reasoning[key] ?? ReasoningProgress()
            defer { reasoning[key] = progress }
            guard !progress.started else { return [] }
            progress.started = true
            return [.thinkingStarted]
        case "function_call":
            var call = calls[id] ?? CallProgress()
            if let callID = Self.nonEmpty(item["call_id"]?.stringValue) { call.callID = callID }
            if let name = Self.nonEmpty(item["name"]?.stringValue) { call.name = name }
            calls[id] = call
            return announce(callID: call.callID, name: call.name)
        case "web_search_call":
            guard !finishedWebCalls.contains(id), runningWebCalls.insert(id).inserted else { return [] }
            return [.toolActivity(ToolActivity(id: id, kind: .webSearch, label: Self.searchingLabel, isDone: false))]
        default:
            return []
        }
    }

    private mutating func itemDone(_ event: JSONValue) -> [StreamEvent] {
        guard let item = event["item"], item.objectValue != nil else { return [] }
        let knownIndex = item["id"]?.stringValue.flatMap { itemIndices[$0] }
        let index = event["output_index"]?.intValue ?? knownIndex ?? nextDoneIndex()
        let key = Self.itemID(item, fallbackIndex: index)
        if let existing = doneItems.firstIndex(where: { $0.key == key }) {
            doneItems[existing] = DoneItem(key: key, index: index, item: item)
        } else {
            doneItems.append(DoneItem(key: key, index: index, item: item))
        }
        itemIndices[key] = index
        return reconcile(item, index: index)
    }

    /// One past the highest index a finished item has, for an item that came without one.
    private func nextDoneIndex() -> Int {
        let highest = doneItems.map(\.index).max() ?? -1
        return highest == Int.max ? Int.max : highest + 1
    }

    private mutating func summaryPartAdded(_ event: JSONValue) -> [StreamEvent] {
        let key = reasoningKey(itemID: Self.nonEmpty(event["item_id"]?.stringValue),
                               index: event["output_index"]?.intValue)
        var progress = reasoning[key] ?? ReasoningProgress()
        guard !progress.reconciled else { return [] }
        let events = enterSummaryPart(&progress, index: event["summary_index"]?.intValue ?? 0)
        reasoning[key] = progress
        return events
    }

    private mutating func summaryDelta(_ event: JSONValue) -> [StreamEvent] {
        guard let delta = event["delta"]?.stringValue, !delta.isEmpty else { return [] }
        let key = reasoningKey(itemID: Self.nonEmpty(event["item_id"]?.stringValue),
                               index: event["output_index"]?.intValue)
        var progress = reasoning[key] ?? ReasoningProgress()
        guard !progress.reconciled else { return [] }
        let index = event["summary_index"]?.intValue ?? progress.part
        var events = enterSummaryPart(&progress, index: index)
        progress.parts[index, default: ""].append(delta)
        reasoning[key] = progress
        events.append(.thinkingDelta(delta))
        return events
    }

    /// Starts the thinking row if needed, and separates a new summary part from the text before it.
    private func enterSummaryPart(_ progress: inout ReasoningProgress, index: Int) -> [StreamEvent] {
        var events: [StreamEvent] = []
        if !progress.started {
            progress.started = true
            events.append(.thinkingStarted)
        }
        if index > progress.part {
            if progress.hasText { events.append(.thinkingDelta("\n\n")) }
            progress.part = index
        }
        return events
    }

    private mutating func textDelta(_ event: JSONValue) -> [StreamEvent] {
        guard let delta = event["delta"]?.stringValue, !delta.isEmpty else { return [] }
        let id = Self.key(of: event)
        texts[id, default: StreamedText(index: event["output_index"]?.intValue, text: "")].text.append(delta)
        emittedOutput = true
        return [.textDelta(delta)]
    }

    /// The terminal event: shows every item that hasn't been shown, then the usage.
    private mutating func finish(_ response: JSONValue?) -> [StreamEvent] {
        if let response, response.objectValue != nil {
            terminal = response
        }
        var events: [StreamEvent] = []
        let items = finalItems()
        for (index, item) in items {
            events += reconcile(item, index: index)
        }
        if let usage = mappedUsage(items) {
            events.append(.usage(usage))
        }
        isComplete = true
        return events
    }

    // MARK: - Reconciliation

    /// What a finished item still needs to show; nothing when it streamed (or was reconciled) already.
    private mutating func reconcile(_ item: JSONValue, index: Int) -> [StreamEvent] {
        let id = Self.itemID(item, fallbackIndex: index)
        switch item.typeName {
        case "reasoning":
            let key = reasoningKey(itemID: Self.nonEmpty(item["id"]?.stringValue), index: index)
            var progress = reasoning[key] ?? ReasoningProgress()
            guard !progress.hasText, !progress.reconciled else { return [] }
            let summary = Self.summaryText(of: item)
            guard !summary.isEmpty else { return [] }
            // After text or a call, "Thinking…" would come back above the finished answer: the summary only
            // joins the thinking row.
            var events: [StreamEvent] = progress.started || emittedOutput ? [] : [.thinkingStarted]
            events.append(.thinkingDelta(summary))
            progress.started = true
            progress.reconciled = true
            reasoning[key] = progress
            return events

        case "message":
            var events: [StreamEvent] = []
            if texts[id] == nil, texts["#\(index)"] == nil {
                let text = Self.outputText(of: item)
                if !text.isEmpty {
                    texts[id] = StreamedText(index: index, text: text)
                    emittedOutput = true
                    events.append(.textDelta(text))
                }
            }
            let links = newSources(fromCitations: Self.citations(of: item))
            if !links.isEmpty {
                events.append(.sources(links))
            }
            return events

        case "function_call":
            let progress = calls[id]
            let callID = Self.nonEmpty(item["call_id"]?.stringValue) ?? progress?.callID ?? ""
            let name = Self.nonEmpty(item["name"]?.stringValue) ?? progress?.name ?? ""
            guard !callID.isEmpty, !name.isEmpty, readyCalls[callID] == nil else { return [] }
            readyCalls[callID] = id
            let rawInput = arguments(of: item, progress: progress)
            emittedOutput = true
            return announce(callID: callID, name: name)
                + [.toolUseReady(id: callID, name: name, input: Self.toolInput(rawInput), rawInput: rawInput)]

        case "web_search_call":
            guard finishedWebCalls.insert(id).inserted else { return [] }
            runningWebCalls.remove(id)
            let call = WebCall(item)
            var activity = call.activity(id: id)
            activity.isDone = true
            var events: [StreamEvent] = [.toolActivity(activity)]
            let links = newSources(fromURLs: call.sourceURLs)
            if !links.isEmpty {
                events.append(.sources(links))
            }
            return events

        default:
            return []
        }
    }

    /// `.toolUseStarted` for a call not yet announced, when both id and name are known.
    private mutating func announce(callID: String, name: String) -> [StreamEvent] {
        guard !callID.isEmpty, !name.isEmpty, startedCalls.insert(callID).inserted else { return [] }
        emittedOutput = true
        return [.toolUseStarted(id: callID, name: name)]
    }

    /// A finished call's arguments: the item's own, else the `.done` event's, else the streamed deltas.
    private func arguments(of item: JSONValue, progress: CallProgress?) -> String {
        item["arguments"]?.stringValue ?? progress?.finalArguments ?? progress?.arguments ?? ""
    }

    /// The key of a reasoning item's progress: its id when that is known, else the one already used at its output
    /// index, else a new one (its id, or "#<index>"), remembered for the index.
    private mutating func reasoningKey(itemID: String?, index: Int?) -> String {
        if let key = existingReasoningKey(itemID: itemID, index: index) { return key }
        let key = itemID ?? "#\(index ?? -1)"
        if let index { reasoningKeys[index] = key }
        return key
    }

    private func existingReasoningKey(itemID: String?, index: Int?) -> String? {
        if let itemID, reasoning[itemID] != nil { return itemID }
        return index.flatMap { reasoningKeys[$0] }
    }

    // MARK: - Sources

    private mutating func newSources(fromCitations citations: [JSONValue]) -> [SourceLink] {
        var links: [SourceLink] = []
        for citation in citations where citation.typeName == "url_citation" {
            guard let urlText = citation["url"]?.stringValue, !urlText.isEmpty else { continue }
            if !citedURLs.contains(urlText) { citedURLs.append(urlText) }
            guard let url = StreamAccumulator.webURL(urlText) else { continue }
            let title = Self.cleanTitle(citation["title"]?.stringValue)
            if let title, citationTitles[urlText] == nil {
                citationTitles[urlText] = title
            }
            if seenSources.insert(url).inserted {
                links.append(SourceLink(title: title ?? StreamAccumulator.displayHost(of: url), url: url))
            }
        }
        return links
    }

    private mutating func newSources(fromURLs urls: [String]) -> [SourceLink] {
        urls.compactMap { urlText in
            guard let url = StreamAccumulator.webURL(urlText), seenSources.insert(url).inserted else { return nil }
            return SourceLink(title: citationTitles[urlText] ?? StreamAccumulator.displayHost(of: url), url: url)
        }
    }

    /// Citation titles by URL: the streamed ones, then the final messages'.
    private func allCitationTitles(_ items: [(index: Int, item: JSONValue)]) -> [String: String] {
        var titles = citationTitles
        for (_, item) in items where item.typeName == "message" {
            for citation in Self.citations(of: item) {
                guard let url = citation["url"]?.stringValue, titles[url] == nil,
                      let title = Self.cleanTitle(citation["title"]?.stringValue) else { continue }
                titles[url] = title
            }
        }
        return titles
    }

    /// The cited URLs, in order, when the response cites the web but has no web_search_call; empty otherwise.
    private func uncoveredCitations(_ items: [(index: Int, item: JSONValue)]) -> [String] {
        guard !items.contains(where: { $0.item.typeName == "web_search_call" }) else { return [] }
        var urls = citedURLs
        for (_, item) in items where item.typeName == "message" {
            for citation in Self.citations(of: item) {
                guard let url = citation["url"]?.stringValue, !url.isEmpty, !urls.contains(url) else { continue }
                urls.append(url)
            }
        }
        return urls
    }

    // MARK: - Result

    /// The response's output items with their output indexes, in order: the terminal output; when it names every
    /// item, plus the items that finished streaming but are missing from it and text that streamed for a message
    /// that never arrived whole (a stream that ended without its terminal event, or a terminal output the SDK
    /// couldn't carry in full).
    private func finalItems() -> [(index: Int, item: JSONValue)] {
        let output = (terminal?["output"]?.arrayValue ?? []).filter { $0.objectValue != nil }
        var items: [(index: Int, item: JSONValue)] = output.enumerated().map { position, item in
            (item["id"]?.stringValue.flatMap { itemIndices[$0] } ?? position, item)
        }
        let terminalItems = items
        let ids = Set(output.compactMap { Self.nonEmpty($0["id"]?.stringValue) })
        if ids.count == output.count {
            var known = ids
            for done in doneItems.enumerated().sorted(by: Self.byIndex).map(\.element) {
                guard let id = Self.nonEmpty(done.item["id"]?.stringValue), known.insert(id).inserted else { continue }
                // The same item under another id: older LiteLLM gives a finished reasoning item one id and the
                // terminal output's copy another.
                if terminalItems.contains(where: { $0.index == done.index && $0.item.typeName == done.item.typeName }) {
                    continue
                }
                items.append((done.index, done.item))
            }
            let hasMessage = items.contains { $0.item.typeName == "message" }
            for (key, streamed) in texts.sorted(by: { $0.key < $1.key }) where !known.contains(key) {
                // Text keyed only by output index can't be matched to an item; it stands in for a missing message.
                if key.hasPrefix("#") && hasMessage { continue }
                known.insert(key)
                let message: JSONValue = [
                    "type": "message",
                    "id": .string(key),
                    "role": "assistant",
                    "content": [["type": "output_text", "text": .string(streamed.text)]],
                ]
                items.append((streamed.index ?? itemIndices[key] ?? Int.max, message))
            }
        }
        return items.enumerated()
            .sorted { lhs, rhs in
                lhs.element.index == rhs.element.index ? lhs.offset < rhs.offset : lhs.element.index < rhs.element.index
            }
            .map(\.element)
    }

    private static func byIndex(_ lhs: (offset: Int, element: DoneItem), _ rhs: (offset: Int, element: DoneItem)) -> Bool {
        lhs.element.index == rhs.element.index ? lhs.offset < rhs.offset : lhs.element.index < rhs.element.index
    }

    /// Positions in `items` of the function calls `result()` stores: one per `call_id`, the item that was announced
    /// as ready (else the first), so a repeated id can't add a second call the stream never showed.
    private func keptCallItems(_ items: [(index: Int, item: JSONValue)]) -> Set<Int> {
        var byCallID: [String: [Int]] = [:]
        var order: [String] = []
        for (position, entry) in items.enumerated() where entry.item.typeName == "function_call" {
            let progress = calls[Self.itemID(entry.item, fallbackIndex: entry.index)]
            let callID = Self.nonEmpty(entry.item["call_id"]?.stringValue) ?? progress?.callID ?? ""
            if byCallID[callID] == nil { order.append(callID) }
            byCallID[callID, default: []].append(position)
        }
        var kept: Set<Int> = []
        for callID in order {
            let positions = byCallID[callID] ?? []
            let owner = readyCalls[callID]
            let chosen = positions.first { position in
                owner == Self.itemID(items[position].item, fallbackIndex: items[position].index)
            } ?? positions.first
            if let chosen { kept.insert(chosen) }
        }
        return kept
    }

    /// `thinking` (when there is a summary) and the reasoning item itself, kept for the next gateway request.
    private func reasoningBlocks(_ item: JSONValue, index: Int) -> [JSONValue] {
        var summary = Self.summaryText(of: item)
        if summary.isEmpty,
           let key = existingReasoningKey(itemID: Self.nonEmpty(item["id"]?.stringValue), index: index),
           let progress = reasoning[key] {
            summary = progress.parts.sorted { $0.key < $1.key }.map(\.value).filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
        var blocks: [JSONValue] = []
        if !summary.isEmpty {
            blocks.append(["type": "thinking", "thinking": .string(summary), "signature": ""])
        }
        blocks.append(["type": .string(ProviderBlocks.responsesReasoningType), "item": item])
        return blocks
    }

    private func toolUseBlock(_ item: JSONValue, index: Int) -> JSONValue? {
        let progress = calls[Self.itemID(item, fallbackIndex: index)]
        let callID = Self.nonEmpty(item["call_id"]?.stringValue) ?? progress?.callID ?? ""
        let name = Self.nonEmpty(item["name"]?.stringValue) ?? progress?.name ?? ""
        guard !callID.isEmpty, !name.isEmpty else { return nil }
        // Invalid JSON is stored as `{}`; the loop echoes the raw text back from `.toolUseReady`.
        let input = Self.toolInput(arguments(of: item, progress: progress)) ?? [:]
        return ["type": "tool_use", "id": .string(callID), "name": .string(name), "input": input]
    }

    /// `server_tool_use` + `*_tool_result` in the shapes an Anthropic web search or fetch has, so TrustLedger, the
    /// web budget and History read a gateway search like one of Anthropic's. Marked Setapp AI only: they carry no
    /// `encrypted_content`, so Anthropic can't take them back.
    private static func webBlocks(_ item: JSONValue, id: String, titles: [String: String]) -> [JSONValue] {
        let call = WebCall(item)
        let blocks: [JSONValue]
        switch call.kind {
        case .search(let query):
            blocks = searchBlocks(id: id, input: query.map { ["query": .string($0)] } ?? [:],
                                  urls: call.sourceURLs, titles: titles)
        case .page(let url):
            var document: JSONValue = [
                "type": "document",
                "source": ["type": "text", "media_type": "text/plain", "data": ""],
            ]
            if let title = titles[url] {
                document = document.setting("title", to: .string(title))
            }
            blocks = [
                ["type": "server_tool_use", "id": .string(id), "name": "web_fetch", "input": ["url": .string(url)]],
                [
                    "type": "web_fetch_tool_result",
                    "tool_use_id": .string(id),
                    "content": ["type": "web_fetch_result", "url": .string(url), "content": document],
                ],
            ]
        }
        return blocks.map { $0.setting(ProviderBlocks.providerField, to: .string(ProviderBlocks.setappAIMarker)) }
    }

    /// The search pair for text that cites pages no web_search_call announced: the query is unknown, the results are
    /// the cited pages.
    private static func citationSearchBlocks(urls: [String], titles: [String: String], id: String) -> [JSONValue] {
        let pages = urls.filter { StreamAccumulator.webURL($0) != nil }
        return searchBlocks(id: id, input: ["query": ""], urls: pages, titles: titles)
            .map { $0.setting(ProviderBlocks.providerField, to: .string(ProviderBlocks.setappAIMarker)) }
    }

    private static func searchBlocks(id: String, input: JSONValue, urls: [String], titles: [String: String]) -> [JSONValue] {
        var seen = Set<String>()
        let results: [JSONValue] = urls.compactMap { url in
            guard seen.insert(url).inserted else { return nil }
            return [
                "type": "web_search_result",
                "url": .string(url),
                "title": .string(titles[url] ?? url),
                "encrypted_content": "",
                "page_age": nil,
            ]
        }
        return [
            ["type": "server_tool_use", "id": .string(id), "name": "web_search", "input": input],
            ["type": "web_search_tool_result", "tool_use_id": .string(id), "content": .array(results)],
        ]
    }

    /// Anthropic-shaped usage, so `UsageLedger` and the web budget read it unchanged: OpenAI counts cached tokens
    /// inside `input_tokens`, Anthropic outside it. Nil when the gateway reported no usage and nothing searched.
    ///
    /// Every web_search_call spends a search, page reads included: they all went through the one search tool whose
    /// calls `max_tool_calls` caps, so a page read can't step around the reply's search budget. A page read also
    /// counts as a fetch. Text citing the web with no web_search_call behind it counts as one search.
    private func mappedUsage(_ items: [(index: Int, item: JSONValue)]) -> JSONValue? {
        var searches = 0
        var fetches = 0
        for (_, item) in items where item.typeName == "web_search_call" {
            searches += 1
            if case .page = WebCall(item).kind { fetches += 1 }
        }
        if !uncoveredCitations(items).isEmpty { searches += 1 }
        var usage: [String: JSONValue] = [:]
        if let reported = terminal?["usage"], reported.objectValue != nil {
            let input = max(0, reported["input_tokens"]?.intValue ?? 0)
            let cached = max(0, reported["input_tokens_details"]?["cached_tokens"]?.intValue ?? 0)
            let written = max(0, reported["input_tokens_details"]?["cache_write_tokens"]?.intValue ?? 0)
            // Responses counts cache reads and writes inside input_tokens; Anthropic's usage keeps them apart.
            // Every value is at least 0 and each subtraction stops at 0, so nothing a gateway reports overflows.
            let afterReads = input - min(input, cached)
            usage["input_tokens"] = .int(Int64(afterReads - min(afterReads, written)))
            usage["cache_read_input_tokens"] = .int(Int64(cached))
            if written > 0 { usage["cache_creation_input_tokens"] = .int(Int64(written)) }
            usage["output_tokens"] = .int(Int64(max(0, reported["output_tokens"]?.intValue ?? 0)))
        }
        if searches > 0 || fetches > 0 {
            usage["server_tool_use"] = [
                "web_search_requests": .int(Int64(searches)),
                "web_fetch_requests": .int(Int64(fetches)),
            ]
        }
        return usage.isEmpty ? nil : .object(usage)
    }

    // MARK: - Model

    private mutating func adoptModel(_ id: String?) {
        guard model == nil, !didStart, let id = Self.nonEmpty(id?.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        model = Self.gatewayModelID(id)
    }

    /// `id` as Otto stores a Setapp AI reply's model: with `ModelProvenance.setappAIPrefix`, which keeps it out of
    /// dollar pricing even when the gateway reports the bare Anthropic id.
    static func gatewayModelID(_ id: String) -> String {
        id.hasPrefix(ModelProvenance.setappAIPrefix) ? id : ModelProvenance.setappAIPrefix + id
    }

    // MARK: - Errors

    /// The LLMError for a `response.failed` / `error` event's `code` and `message`, by the code's family (any
    /// case): the gateway's own codes (`BAD_REQUEST`, `FORBIDDEN`, …), OpenAI's, Anthropic's error types and HTTP
    /// statuses as LiteLLM passes them on.
    static func eventError(code: String?, message: String, model: ModelOption) -> LLMError {
        if isContextOverflow(code: code, message: message) {
            return overflowError(message: message)
        }
        let code = (code ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch code {
        case "insufficient_credits", "402":
            return .setappAI(.insufficientCredits)
        case "forbidden", "model_not_allowed", "403":
            return .setappAI(.modelNotAllowed(model.shortName))
        case "invalid_prompt", "bad_request", "validation", "400", "413", "422":
            return rejectedRequest(message: message)
        case "529":
            return .overloaded
        case "429":
            return .rateLimited(retryAfter: nil)
        case _ where code.hasPrefix("invalid_request"):
            // The request's content was refused: ChatSession takes the offending turn out of the context.
            return rejectedRequest(message: message)
        case _ where code.hasPrefix("rate_limit"):
            return .rateLimited(retryAfter: nil)
        case _ where code.hasPrefix("overloaded"):
            return .overloaded
        default:
            return .streamError(type: "api_error", message: message)
        }
    }

    /// The error ChatSession reads as a request the API rejected for its content (`isRejectedRequestContent`).
    private static func rejectedRequest(message: String) -> LLMError {
        .http(status: 400, type: "invalid_request_error",
              message: message.isEmpty ? ResponsesClient.badRequestFallback : message)
    }

    /// An error object's `code` (a string, or a number LiteLLM passes on), else its `type`.
    private static func code(of error: JSONValue?) -> String? {
        if let code = nonEmpty(error?["code"]?.stringValue) { return code }
        if let code = error?["code"]?.intValue { return String(code) }
        return nonEmpty(error?["type"]?.stringValue).flatMap { $0 == "error" ? nil : $0 }
    }

    /// Whether the gateway says the request is longer than the model's context window.
    static func isContextOverflow(code: String?, message: String) -> Bool {
        if code?.lowercased() == "context_length_exceeded" { return true }
        let lowered = message.lowercased()
        return ["prompt is too long", "context length", "too many tokens", "maximum context"]
            .contains { lowered.contains($0) }
    }

    /// The error `ChatSession.isContextOverflow` reads as "prompt is too long", so it compacts and resends.
    static func overflowError(message: String) -> LLMError {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "prompt is too long"
        let wording = text.lowercased().hasPrefix(prefix) ? text : prefix + ": " + text
        return .http(status: 400, type: "invalid_request_error", message: wording)
    }

    // MARK: - Helpers

    private static func key(of event: JSONValue) -> String {
        nonEmpty(event["item_id"]?.stringValue) ?? "#\(event["output_index"]?.intValue ?? -1)"
    }

    private static func itemID(_ item: JSONValue, fallbackIndex: Int?) -> String {
        nonEmpty(item["id"]?.stringValue) ?? "#\(fallbackIndex ?? -1)"
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// Parsed arguments: `{}` for a call that streamed none (a tool without parameters), nil for invalid JSON.
    static func toolInput(_ rawInput: String) -> JSONValue? {
        if rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        return StreamAccumulator.parseToolInput(rawInput)
    }

    /// A message item's `output_text` parts, joined.
    static func outputText(of item: JSONValue) -> String {
        (item["content"]?.arrayValue ?? [])
            .filter { $0.typeName == "output_text" }
            .compactMap { $0["text"]?.stringValue }
            .joined()
    }

    private static func hasRefusal(_ item: JSONValue) -> Bool {
        item["content"]?.arrayValue?.contains { $0.typeName == "refusal" } ?? false
    }

    private static func citations(of item: JSONValue) -> [JSONValue] {
        (item["content"]?.arrayValue ?? []).flatMap { part in
            (part["annotations"]?.arrayValue ?? []).filter { $0.typeName == "url_citation" }
        }
    }

    /// A reasoning item's summary texts, one paragraph each; without a summary, its `content` texts. LiteLLM's
    /// finished reasoning item carries `content: [{"type": "output_text", "text"}]` and no summary (the SDK
    /// re-encodes those parts as `reasoning_text`).
    static func summaryText(of item: JSONValue) -> String {
        let summary = paragraphs(item["summary"], types: ["summary_text"])
        return summary.isEmpty ? paragraphs(item["content"], types: ["output_text", "reasoning_text"]) : summary
    }

    private static func paragraphs(_ parts: JSONValue?, types: Set<String>) -> String {
        (parts?.arrayValue ?? [])
            .filter { $0.typeName.map(types.contains) ?? true }
            .compactMap { $0["text"]?.stringValue }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func cleanTitle(_ title: String?) -> String? {
        let cleaned = (title ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return cleaned.isEmpty ? nil : cleaned
    }
}

// MARK: - Web search calls

/// What a `web_search_call` item did. `open_page` and `find_in_page` read one page (Anthropic's web fetch); a
/// page action without a URL, and every other action, counts as a search, so provenance still sees web content.
private struct WebCall {
    enum Kind: Equatable {
        case search(query: String?)
        case page(url: String)
    }

    let kind: Kind
    /// `action.sources` URLs, then the opened page.
    let sourceURLs: [String]

    init(_ item: JSONValue) {
        let action = item["action"]
        let sources = (action?["sources"]?.arrayValue ?? []).compactMap { $0["url"]?.stringValue }
        switch action?.typeName {
        case "open_page", "find_in_page":
            if let url = action?["url"]?.stringValue, !url.trimmingCharacters(in: .whitespaces).isEmpty {
                kind = .page(url: url)
                sourceURLs = sources + [url]
                return
            }
            kind = .search(query: nil)
        default:
            // OpenAI documents `query`; the Setapp SDK's typed action keeps only `queries`.
            let query = action?["query"]?.stringValue ?? action?["queries"]?.arrayValue?.first?.stringValue
            kind = .search(query: query.flatMap { $0.isEmpty ? nil : $0 })
        }
        sourceURLs = sources
    }

    /// The row for this call, as `StreamAccumulator` labels an Anthropic search or fetch.
    func activity(id: String) -> ToolActivity {
        switch kind {
        case .search(let query):
            return StreamAccumulator.makeActivity(id: id, name: "web_search",
                                                  input: query.map { ["query": .string($0)] })
        case .page(let url):
            return StreamAccumulator.makeActivity(id: id, name: "web_fetch", input: ["url": .string(url)])
        }
    }
}
