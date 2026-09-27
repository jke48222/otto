//
//  SSEParser.swift
//  Otto
//
//  Server-sent-events decoding for the Messages API stream.
//
//  Every Anthropic event carries its complete JSON payload (including its own `"type"`) on a single
//  `data:` line, so events are decoded line by line instead of waiting for the blank-line dispatch
//  the SSE spec describes (which `AsyncBytes.lines` would swallow anyway).
//

import Foundation
import os

/// Parses SSE `data:` lines into JSONValue events.
struct SSEParser {
    /// Upper bound for a payload that is being reassembled from several `data:` lines.
    static let maxPendingDataBytes = 32 * 1024 * 1024

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "SSEParser")

    /// Name from the most recent `event:` field; used only when a payload lacks its own `"type"`.
    private var eventName: String?
    /// Data that did not decode on its own. Per the SSE spec, consecutive `data:` lines of one event
    /// are joined with "\n"; Anthropic never splits payloads, so this is purely defensive.
    private var pendingData: String?

    init() {}

    /// Consumes one line of the stream (with or without its line terminator). Returns the decoded
    /// event object when the line completes one; nil for `event:`/`id:`/`retry:` fields, comments,
    /// blank lines, `ping` events and undecodable data.
    mutating func consume(line rawLine: String) -> JSONValue? {
        var line = rawLine
        while let last = line.unicodeScalars.last, last == "\n" || last == "\r" {
            line.unicodeScalars.removeLast()
        }
        if line.unicodeScalars.first == "\u{FEFF}" {
            line.unicodeScalars.removeFirst()
        }

        if line.isEmpty {
            // Dispatch boundary: whatever is still pending can never complete.
            discardPending(reason: "blank line")
            eventName = nil
            return nil
        }
        if line.hasPrefix(":") {
            return nil  // comment / keep-alive
        }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "data":
            return consumeData(String(value))
        case "event":
            discardPending(reason: "new event")
            eventName = value.isEmpty ? nil : String(value)
            return nil
        default:
            return nil  // id, retry and unknown fields carry nothing for us
        }
    }

    private mutating func consumeData(_ data: String) -> JSONValue? {
        guard !data.isEmpty else { return nil }

        if let pending = pendingData {
            if let event = decodeEvent(data) {
                // The new line stands on its own, so the pending fragment was garbage.
                discardPending(reason: "superseded")
                return filtered(event)
            }
            let joined = pending + "\n" + data
            if let event = decodeEvent(joined) {
                pendingData = nil
                return filtered(event)
            }
            store(pending: joined)
            return nil
        }

        if let event = decodeEvent(data) {
            return filtered(event)
        }
        store(pending: data)
        return nil
    }

    private func decodeEvent(_ text: String) -> JSONValue? {
        guard let value = try? JSONValue.decode(text), case .object = value else { return nil }
        if value.typeName == nil, let eventName {
            return value.setting("type", to: .string(eventName))
        }
        return value
    }

    private func filtered(_ event: JSONValue) -> JSONValue? {
        // Spelled out: in a ternary, `nil` would become JSONValue.null (it is ExpressibleByNilLiteral).
        if event.typeName == "ping" { return Optional.none }
        return event
    }

    private mutating func store(pending: String) {
        if pending.utf8.count <= Self.maxPendingDataBytes {
            pendingData = pending
        } else {
            Self.logger.error("Dropping an oversized undecodable SSE payload (\(pending.utf8.count) bytes)")
            pendingData = nil
        }
    }

    private mutating func discardPending(reason: StaticString) {
        guard let pending = pendingData else { return }
        Self.logger.error("Dropping undecodable SSE data (\(pending.utf8.count) bytes, \(reason))")
        pendingData = nil
    }
}

/// Splits a raw byte stream into lines on LF, CRLF or a lone CR (the SSE line terminators).
///
/// Used instead of `AsyncBytes.lines`, which also splits on U+0085/U+2028/U+2029 — characters that
/// may legally appear unescaped inside a JSON string and would corrupt an event.
struct SSELineSplitter {
    /// A single event line larger than this is treated as a broken stream.
    static let maxLineBytes = 64 * 1024 * 1024

    private var buffer: [UInt8] = []
    private var lastByteWasCR = false

    init() {}

    /// Feeds one byte; returns a completed line (without terminator) when `byte` ends one.
    mutating func append(_ byte: UInt8) throws -> String? {
        switch byte {
        case 0x0A:
            if lastByteWasCR {
                lastByteWasCR = false  // second half of CRLF; the line was already emitted
                return nil
            }
            return flush()
        case 0x0D:
            lastByteWasCR = true
            return flush()
        default:
            lastByteWasCR = false
            guard buffer.count < Self.maxLineBytes else {
                throw LLMError.decoding("A streamed event was larger than \(Self.maxLineBytes / 1_048_576) MB.")
            }
            buffer.append(byte)
            return nil
        }
    }

    /// Returns the trailing unterminated line, if any, once the stream has ended.
    mutating func finish() -> String? {
        buffer.isEmpty ? nil : flush()
    }

    private mutating func flush() -> String {
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return line
    }
}
