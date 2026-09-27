//
//  MessageSegments.swift
//  Otto
//
//  How an assistant turn is laid out (§5.8): Otto's own notes and the server activity rows on top, then the
//  reply text cut at each tool round with that round's action rows in between, then the text still arriving
//  and the rows of calls that aren't in a round yet. A refused turn keeps the calls that already ran under
//  "Done before Otto stopped". Pure, so the order is tested without rendering anything.
//

import Foundation

struct MessageSegments: Equatable {
    /// One piece of the reply body, in reading order.
    enum Item: Equatable {
        /// Reply text that a tool round followed.
        case text(String)
        /// The action rows of one round, or the calls not in any round yet (trailing).
        case calls([ToolCall])
        /// The text after the last round: where streamed text lands and the caret blinks. Exactly one per
        /// turn that isn't refused; it may be empty.
        case tail(String)
    }

    /// A row above the reply body.
    enum ActivityRow: Equatable, Identifiable {
        /// Web search or fetch, run on Anthropic's side.
        case server(ToolActivity)
        /// Otto's own note (a `kind: .other` activity whose id starts with `otto.`, such as the web pause).
        case note(ToolActivity)

        var id: String {
            switch self {
            case .server(let activity), .note(let activity): return activity.id
            }
        }
    }

    /// Caption over the calls a refused turn keeps.
    static let keptCallsCaption = "Done before Otto stopped"
    /// Activity ids Otto writes itself start with this.
    static let notePrefix = "otto."

    let activities: [ActivityRow]
    let items: [Item]
    /// Refused turns only: the calls that ran before the refusal, shown under `keptCallsCaption`.
    let keptCalls: [ToolCall]
    /// Some call hasn't settled (preparing, queued, waiting or running): the streaming caret stays hidden.
    let hasUnsettledCall: Bool

    init(message: ChatMessage) {
        activities = message.activities.map { Self.isNote($0) ? .note($0) : .server($0) }
        hasUnsettledCall = message.toolCalls.contains { !$0.status.isTerminal }
        if case .refused = message.state {
            // A refusal clears the rounds; whatever already ran is listed under the caption instead.
            items = [.tail(message.text)]
            keptCalls = message.toolCalls
        } else {
            items = Self.interleave(text: message.text, calls: message.toolCalls, exchanges: message.toolExchanges)
            keptCalls = []
        }
    }

    static func isNote(_ activity: ToolActivity) -> Bool {
        activity.kind == .other && activity.id.hasPrefix(notePrefix)
    }

    /// `text[0..<ex0.textEnd]` → rows(ex0) → `text[ex0.textEnd..<ex1.textEnd]` → rows(ex1) … → tail text → rows of
    /// the calls in no exchange. Blank text between rounds is dropped; a `textEnd` past the text (or behind the
    /// previous one) is clamped, so a malformed exchange can never cut text out or repeat it.
    static func interleave(text: String, calls: [ToolCall], exchanges: [ToolExchange]) -> [Item] {
        let callsByID = Dictionary(calls.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var placed: Set<String> = []
        var items: [Item] = []
        var cursor = text.startIndex
        var consumed = 0

        for exchange in exchanges {
            let end = min(max(exchange.textEnd, consumed), text.count)
            let endIndex = text.index(cursor, offsetBy: end - consumed)
            let piece = String(text[cursor..<endIndex])
            if !isBlank(piece) { items.append(.text(piece)) }
            cursor = endIndex
            consumed = end

            let roundCalls = exchange.callIDs.compactMap { id -> ToolCall? in
                guard !placed.contains(id), let call = callsByID[id] else { return nil }
                placed.insert(id)
                return call
            }
            if !roundCalls.isEmpty { items.append(.calls(roundCalls)) }
        }

        items.append(.tail(String(text[cursor...])))
        let trailing = calls.filter { !placed.contains($0.id) }
        if !trailing.isEmpty { items.append(.calls(trailing)) }
        return items
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}
