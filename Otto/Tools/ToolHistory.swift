//
//  ToolHistory.swift
//  Otto
//
//  Pure rendering of assistant turns into Messages API history. A turn that ran client tools is split at
//  each `ToolExchange` into segments: every segment's assistant content is followed by one user entry with
//  all of that round's `tool_result` blocks, in model order. Server-tool pairs are kept per segment, signed
//  thinking stays verbatim, orphaned `tool_use` blocks (a reply cut off or stopped at the action limit) are
//  never echoed, and rounds whose tools are no longer offered are downgraded to fenced
//  `<earlier_action_result>` data blocks so a request never references an undefined tool.
//

import Foundation
import os

enum ToolHistory {
    /// One history entry before it is wrapped as {"role","content"}.
    typealias Entry = (role: ChatRole, content: [JSONValue])

    /// Model-facing `tool_result` text the loop writes itself (SPEC-v2 §5.6).
    enum Copy {
        static let cancelledBeforeRun = "cancelled: The user stopped Otto before this action started."
        static let cancelledWhileRunning =
            "cancelled: The user stopped Otto while this action was running. It may have partly completed."
        static let actionLimit = "limit: Otto's limit on actions per reply was reached. Answer with what you have "
            + "and tell the user what's left to do."

        static func unknownTool(_ name: String) -> String {
            "unknown_tool: There is no tool named \u{201C}\(name)\u{201D}. Use only the tools provided."
        }
    }

    /// Characters of result text kept in a downgraded `<earlier_action_result>` block.
    static let maxEarlierResultCharacters = 2_000

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Tools")

    // MARK: - Assistant turns

    /// History entries for one assistant message.
    ///
    /// - Without exchanges: the in-flight message sends its resumed content only when `resuming` (a
    ///   `pause_turn` continuation); any other message sends `contextContent(forAssistant:enabledServerTools:)`.
    /// - With exchanges: each segment's content, then a user entry with that round's results. The trailing
    ///   segment (after the last exchange) is the resumed content for the in-flight message when `resuming`,
    ///   the sanitized content of a complete turn, the visible text typed after the last exchange for a
    ///   cancelled turn, and nothing for a failed one (its partial round never ran). Refused and settled
    ///   streaming messages send nothing.
    /// - `enabledServerTools` nil keeps the complete call/result pairs of every server tool (the transcript the
    ///   executor's trust check reads, which must see every page Claude read even when this request defines no web
    ///   tools).
    static func entries(
        for message: ChatMessage,
        enabledServerTools: Set<String>?,
        clientToolNames: Set<String>,
        isInFlight: Bool,
        resuming: Bool
    ) -> [Entry] {
        guard !message.toolExchanges.isEmpty else {
            let content = isInFlight
                ? (resuming ? resumedContent(message.apiContent) : [])
                : contextContent(forAssistant: message, enabledServerTools: enabledServerTools)
            return content.isEmpty ? [] : [(.assistant, content)]
        }
        if !isInFlight {
            switch message.state {
            case .complete, .cancelled, .failed: break
            case .streaming, .refused: return []
            }
        }

        var callsByID: [String: ToolCall] = [:]
        for call in message.toolCalls where callsByID[call.id] == nil {
            callsByID[call.id] = call
        }
        var images = ImageBudget(keepsNewest: isInFlight ? ToolOutput.maxImages : 0,
                                 total: isInFlight ? imageCount(in: message) : 0)

        var entries: [Entry] = []
        var start = 0
        for exchange in message.toolExchanges {
            let end = min(max(exchange.contentEnd, start), message.apiContent.count)
            let segment = Array(message.apiContent[start..<end])
            start = end

            var blocks = pairedServerToolBlocks(
                withoutUnsignedThinking(sanitizedAssistantContent(segment)),
                allowedTools: enabledServerTools
            )
            let downgrade = exchange.callIDs.contains { id in
                guard let name = callsByID[id]?.name ?? clientToolName(id, in: segment) else { return true }
                return !clientToolNames.contains(name)
            }
            blocks = blocks.filter { block in
                guard isClientToolUse(block) else { return true }
                guard !downgrade, let id = block["id"]?.stringValue else { return false }
                return exchange.callIDs.contains(id)
            }
            if blocks.contains(where: { !isThinkingBlock($0) }) {
                entries.append((.assistant, blocks))
            }
            let echoedIDs = Set(blocks.filter(isClientToolUse).compactMap { $0["id"]?.stringValue })

            var results: [JSONValue] = []
            var notes: [JSONValue] = []
            for id in exchange.callIDs {
                let call = callsByID[id]
                let name = call?.name ?? clientToolName(id, in: segment) ?? "unknown"
                let title = call?.presentation.title ?? name
                let output = recordedResult(of: call, id: id).normalized()
                let shown = images.filter(output, title: title)
                if echoedIDs.contains(id) {
                    results.append(shown.toolResultBlock(toolUseID: id))
                } else {
                    notes.append(textBlock(earlierActionResult(tool: name, title: title, output: shown)))
                }
            }
            let userContent = results + notes
            if !userContent.isEmpty {
                entries.append((.user, userContent))
            }
        }

        let trailing = Array(message.apiContent[min(start, message.apiContent.count)...])
        if isInFlight {
            if resuming {
                let content = resumedContent(trailing).filter { !isClientToolUse($0) }
                if !content.isEmpty { entries.append((.assistant, content)) }
            }
        } else {
            switch message.state {
            case .complete:
                let blocks = pairedServerToolBlocks(
                    withoutUnsignedThinking(sanitizedAssistantContent(trailing)),
                    allowedTools: enabledServerTools
                ).filter { !isClientToolUse($0) }
                if blocks.contains(where: { !isThinkingBlock($0) }) {
                    entries.append((.assistant, blocks))
                }
            case .cancelled:
                let textEnd = message.toolExchanges.last?.textEnd ?? 0
                let text = String(message.text.dropFirst(max(0, textEnd)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { entries.append((.assistant, [textBlock(text)])) }
            case .failed, .streaming, .refused:
                break
            }
        }
        return entries
    }

    /// Content sent for a finished assistant turn without exchanges, or [] to leave the turn out.
    ///
    /// - `.complete`: the sanitized API content, with server-tool calls reduced to complete call/result pairs
    ///   for tools this request defines (a call issued by a dropped call goes with it), unsigned thinking and
    ///   orphaned client `tool_use` blocks dropped. A turn left with nothing but thinking is skipped.
    /// - `.cancelled`: a single text block with the visible text, if there is any.
    /// - `.refused` / `.failed` / `.streaming`: never sent.
    static func contextContent(forAssistant message: ChatMessage, enabledServerTools: Set<String>?) -> [JSONValue] {
        switch message.state {
        case .complete:
            let blocks = pairedServerToolBlocks(
                withoutUnsignedThinking(sanitizedAssistantContent(message.apiContent)),
                allowedTools: enabledServerTools
            ).filter { !isClientToolUse($0) }
            return blocks.contains(where: { !isThinkingBlock($0) }) ? blocks : []
        case .cancelled:
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [textBlock(text)]
        case .streaming, .refused, .failed:
            return []
        }
    }

    /// A restored assistant turn sent as text only (after the API rejected it as stored): one text block of
    /// its visible text, without exchanges or citations; [] when there is no text or the turn is never sent.
    static func compactedContent(forAssistant message: ChatMessage) -> [JSONValue] {
        switch message.state {
        case .complete, .cancelled, .failed:
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [textBlock(text)]
        case .streaming, .refused:
            return []
        }
    }

    /// Content for the partial in-flight assistant turn when continuing after `pause_turn`.
    ///
    /// The API only resumes a paused turn that is sent back as it came, ending in the pending server-tool
    /// call, so no tool filtering happens here (the turn's tool set is fixed by its configuration). Unsigned
    /// thinking is still dropped, and trailing whitespace is trimmed from a final text block because the API
    /// rejects a final assistant turn ending in whitespace.
    static func resumedContent(_ content: [JSONValue]) -> [JSONValue] {
        var blocks = withoutUnsignedThinking(sanitizedAssistantContent(content))
        if let last = blocks.last, last.typeName == "text", let text = last["text"]?.stringValue {
            blocks.removeLast()
            let trimmed = trimmingTrailingWhitespace(text)
            if !trimmed.isEmpty {
                blocks.append(last.setting("text", to: .string(trimmed)))
            }
        }
        return blocks
    }

    // MARK: - Downgraded rounds

    /// `<earlier_action_result tool="‹name›" title="‹title›" untrusted="true">‹text›</earlier_action_result>`,
    /// with the text cut to `maxEarlierResultCharacters` and `&` `<` `>` `"` escaped in the title and payload,
    /// so the result can never close its fence.
    static func earlierActionResult(tool: String, title: String, output: ToolOutput) -> String {
        let text = output.parts.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined(separator: "\n")
        let payload = String(text.prefix(maxEarlierResultCharacters))
        return "<earlier_action_result tool=\"\(escaped(tool))\" title=\"\(escaped(title))\" untrusted=\"true\">"
            + escaped(payload) + "</earlier_action_result>"
    }

    /// `&` `<` `>` `"` as XML entities.
    static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    // MARK: - Client tool blocks

    static func isClientToolUse(_ block: JSONValue) -> Bool {
        block.typeName == "tool_use"
    }

    /// Ids of the client `tool_use` blocks in `content`, in order, without duplicates.
    static func clientToolUseIDs(in content: [JSONValue]) -> [String] {
        var seen: Set<String> = []
        return content.compactMap { block in
            guard isClientToolUse(block), let id = block["id"]?.stringValue, !id.isEmpty,
                  seen.insert(id).inserted else { return nil }
            return id
        }
    }

    private static func clientToolName(_ id: String, in content: [JSONValue]) -> String? {
        content.first { isClientToolUse($0) && $0["id"]?.stringValue == id }?["name"]?.stringValue
    }

    /// The result a call carries; a call in an exchange without one is a programming error, answered as if
    /// the user had stopped Otto before it started.
    private static func recordedResult(of call: ToolCall?, id: String) -> ToolOutput {
        if let result = call?.result { return result }
        logger.fault("Tool call \(id, privacy: .public) is in an exchange without a result")
        return .error(Copy.cancelledBeforeRun)
    }

    // MARK: - Images

    /// Images of `tool_result`s: the in-flight turn keeps its newest `ToolOutput.maxImages`; every other image
    /// becomes "[Image from ‹title› omitted]".
    private struct ImageBudget {
        let keepsNewest: Int
        let total: Int
        private var seen = 0

        init(keepsNewest: Int, total: Int) {
            self.keepsNewest = keepsNewest
            self.total = total
        }

        mutating func filter(_ output: ToolOutput, title: String) -> ToolOutput {
            let parts = output.parts.map { part -> ToolOutput.Part in
                guard case .image = part else { return part }
                defer { seen += 1 }
                return keepsNewest > 0 && total - seen <= keepsNewest ? part : .text("[Image from \(title) omitted]")
            }
            return ToolOutput(parts: parts, isError: output.isError)
        }
    }

    private static func imageCount(in message: ChatMessage) -> Int {
        let exchanged = Set(message.toolExchanges.flatMap(\.callIDs))
        return message.toolCalls.reduce(0) { total, call in
            guard exchanged.contains(call.id), let result = call.result else { return total }
            return total + result.normalized().parts.filter { part in
                if case .image = part { return true }
                return false
            }.count
        }
    }

    // MARK: - Shared block helpers

    /// Applies the fallback boundary and drops empty text blocks.
    ///
    /// If a `fallback` block exists, the content before the last one came from the model that was replaced:
    /// of it only `text` blocks and complete server-tool call/result pairs are kept (the text's citations
    /// point into those results); thinking, `tool_use`, unpaired `server_tool_use` and anything unknown is
    /// dropped. All `fallback` blocks are dropped, and so are text blocks with no non-whitespace text (the API
    /// rejects them).
    static func sanitizedAssistantContent(_ content: [JSONValue]) -> [JSONValue] {
        var blocks = content
        if let lastFallback = blocks.lastIndex(where: { $0.typeName == "fallback" }) {
            let before = Array(blocks[..<lastFallback])
            let pairedCalls = keptServerToolCalls(in: before, allowedTools: nil, keepPendingCalls: false)
            let kept = before.filter { block in
                if block.typeName == "text" { return true }
                if let id = serverToolCallID(of: block) { return pairedCalls.contains(id) }
                return false
            }
            blocks = kept + blocks[lastFallback...]
        }
        return blocks.filter { block in
            switch block.typeName {
            case "fallback":
                return false
            case "text":
                let text = block["text"]?.stringValue ?? ""
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return true
            }
        }
    }

    /// Thinking cut off before its signature arrived (e.g. max_tokens mid-thought) cannot be verified by the
    /// API, so it is not sent back.
    static func withoutUnsignedThinking(_ blocks: [JSONValue]) -> [JSONValue] {
        blocks.filter { block in
            guard block.typeName == "thinking" else { return true }
            return !(block["signature"]?.stringValue ?? "").isEmpty
        }
    }

    /// Keeps only complete call/result pairs of tools the request defines (the API rejects history that uses
    /// undefined tools, e.g. after web access was switched off or on Haiku); nil allows every tool. A call issued
    /// by another call (`caller.tool_id`, e.g. a search run inside dynamic filtering) goes with it.
    static func pairedServerToolBlocks(_ blocks: [JSONValue], allowedTools: Set<String>?) -> [JSONValue] {
        let keptCalls = keptServerToolCalls(in: blocks, allowedTools: allowedTools, keepPendingCalls: false)
        return blocks.filter { block in
            guard let id = serverToolCallID(of: block) else {
                // A server-tool block without an id can't be paired; drop it rather than send it.
                return block.typeName != "server_tool_use" && !isServerToolResult(block)
            }
            return keptCalls.contains(id)
        }
    }

    /// Ids of the `server_tool_use` calls in `blocks` worth keeping: the tool is in `allowedTools` (any tool
    /// when nil), its `*_tool_result` is present unless `keepPendingCalls`, and the call that issued it
    /// (`caller.tool_id`), if any, is itself kept.
    static func keptServerToolCalls(
        in blocks: [JSONValue],
        allowedTools: Set<String>?,
        keepPendingCalls: Bool
    ) -> Set<String> {
        var calls: [String: (name: String, callerID: String?)] = [:]
        var resultIDs: Set<String> = []
        for block in blocks {
            if block.typeName == "server_tool_use", let id = block["id"]?.stringValue {
                calls[id] = (block["name"]?.stringValue ?? "", block["caller"]?["tool_id"]?.stringValue)
            } else if isServerToolResult(block), let id = block["tool_use_id"]?.stringValue {
                resultIDs.insert(id)
            }
        }

        var kept = Set(calls.compactMap { id, call -> String? in
            if let allowedTools, !allowedTools.contains(call.name) { return nil }
            guard keepPendingCalls || resultIDs.contains(id) else { return nil }
            return id
        })
        // Drop calls whose issuing call was dropped (or is missing), until nothing changes.
        var changed = true
        while changed {
            changed = false
            for id in kept {
                if let callerID = calls[id]?.callerID, !kept.contains(callerID) {
                    kept.remove(id)
                    changed = true
                }
            }
        }
        return kept
    }

    /// The call id a server-tool block belongs to: `id` of a `server_tool_use`, `tool_use_id` of a
    /// `*_tool_result`; nil for every other block.
    static func serverToolCallID(of block: JSONValue) -> String? {
        if block.typeName == "server_tool_use" { return block["id"]?.stringValue }
        if isServerToolResult(block) { return block["tool_use_id"]?.stringValue }
        return nil
    }

    /// Server-tool results end in `_tool_result`; a client `tool_result` (sent by Otto, never received) does not.
    static func isServerToolResult(_ block: JSONValue) -> Bool {
        guard let type = block.typeName else { return false }
        return type.hasSuffix("_tool_result")
    }

    static func isThinkingBlock(_ block: JSONValue) -> Bool {
        block.typeName == "thinking" || block.typeName == "redacted_thinking"
    }

    static func trimmingTrailingWhitespace(_ text: String) -> String {
        var result = text
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        return result
    }

    static func textBlock(_ text: String) -> JSONValue {
        ["type": "text", "text": .string(text)]
    }
}
