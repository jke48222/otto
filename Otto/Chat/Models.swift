//
//  Models.swift
//  Otto
//
//  Shared contract types. Every module codes against these — change them only
//  in coordination with every caller.
//

import AppKit
import Foundation

// MARK: - Layout metrics shared by the window controller and the SwiftUI views

enum NotchMetrics {
    /// Width of the expanded panel.
    static let openWidth: CGFloat = 580
    /// Hard cap on the expanded panel height (conversation scrolls beyond this).
    static let maxOpenHeight: CGFloat = 560
    /// Transparent margin around the shape inside the window, so SwiftUI shadows are not clipped.
    static let shadowMargin: CGFloat = 36
    /// Fixed size of the borderless notch window. The shape is drawn top-centered inside it.
    static var windowSize: CGSize {
        CGSize(width: openWidth + shadowMargin * 2, height: maxOpenHeight + shadowMargin)
    }
    /// Width added to each side of the closed notch while a reply is streaming / unread.
    static let activityEarWidth: CGFloat = 34
    /// Virtual notch used on displays without a camera housing.
    static let virtualNotchSize = CGSize(width: 190, height: 32)
    /// Corner radii of the notch shape.
    static let closedTopRadius: CGFloat = 6
    static let closedBottomRadius: CGFloat = 12
    static let openTopRadius: CGFloat = 20
    static let openBottomRadius: CGFloat = 36
}

// MARK: - JSONValue

/// Loss-tolerant JSON tree used for request bodies and for echoing API content blocks
/// back to the API unchanged (thinking signatures, server-tool blocks, citations, …).
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// Encoder with sorted keys so request bodies are byte-stable (required for prompt caching).
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func decode(_ string: String) throws -> JSONValue {
        try decode(Data(string.utf8))
    }

    func encodedData() throws -> Data {
        try JSONValue.makeEncoder().encode(self)
    }

    func encodedString() -> String {
        guard let data = try? encodedData() else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return Int(value)
        case .double(let value): return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// The `"type"` field of a content block / event, if any.
    var typeName: String? { self["type"]?.stringValue }

    /// Returns a copy of an object with `key` set to `value` (no-op for non-objects).
    func setting(_ key: String, to value: JSONValue) -> JSONValue {
        guard case .object(var object) = self else { return self }
        object[key] = value
        return .object(object)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(Int64(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    init(nilLiteral: ()) { self = .null }
}

// MARK: - Models & settings enums

enum ModelOption: String, CaseIterable, Codable, Identifiable, Sendable {
    case opus5 = "claude-opus-5"
    case sonnet5 = "claude-sonnet-5"
    case haiku45 = "claude-haiku-4-5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus5: return "Claude Opus 5"
        case .sonnet5: return "Claude Sonnet 5"
        case .haiku45: return "Claude Haiku 4.5"
        }
    }

    var shortName: String {
        switch self {
        case .opus5: return "Opus 5"
        case .sonnet5: return "Sonnet 5"
        case .haiku45: return "Haiku 4.5"
        }
    }

    var subtitle: String {
        switch self {
        case .opus5: return "Most capable"
        case .sonnet5: return "Fast and capable"
        case .haiku45: return "Fastest"
        }
    }

    /// `thinking: {type: "adaptive", display: "summarized"}` is valid.
    var supportsAdaptiveThinking: Bool { self != .haiku45 }
    /// `output_config: {effort: …}` is valid.
    var supportsEffort: Bool { self != .haiku45 }
    /// Send `fallbacks: "default"` + `anthropic-beta: server-side-fallback-2026-07-01`.
    var supportsServerFallbacks: Bool { self == .opus5 }
    /// Server web search tool `type` for this model.
    var webSearchToolType: String { self == .haiku45 ? "web_search_20250305" : "web_search_20260209" }
    /// Server web fetch tool `type`, or nil when this app does not enable fetch for the model.
    var webFetchToolType: String? { self == .haiku45 ? nil : "web_fetch_20260209" }
    /// `max_tokens` for a streaming request (thinking + visible text share this cap).
    var maxOutputTokens: Int { self == .haiku45 ? 32_000 : 64_000 }
}

enum EffortLevel: String, CaseIterable, Codable, Identifiable, Sendable {
    case low, medium, high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "Quick"
        case .medium: return "Balanced"
        case .high: return "Thorough"
        }
    }
}

// MARK: - Attachments

enum AttachmentKind: String, Codable, Sendable {
    case image
    case pdf
    case text
    case webPage
}

enum AttachmentPayload: Equatable, Sendable {
    /// Base64 image data. `mediaType` is one of image/jpeg, image/png, image/gif, image/webp.
    case image(mediaType: String, base64: String)
    /// Base64 PDF data.
    case pdf(base64: String)
    /// Plain UTF-8 text (source files, notes, extracted rich-text documents…).
    case text(String)
    /// A web page the user is looking at (title + address only; Claude can web-fetch it).
    case webPage(title: String, url: URL)
}

struct Attachment: Identifiable, Equatable, @unchecked Sendable {
    let id: UUID
    var kind: AttachmentKind
    /// Human-readable name shown on the chip, e.g. "cat-meme.txt" or "TechCrunch".
    var displayName: String
    /// Short uppercase type badge shown on the chip: "TXT", "PDF", "PNG", "WEB", …
    var badge: String
    /// File URL for files, page URL for web pages.
    var sourceURL: URL?
    /// Bundle identifier of the app the attachment came from (browser tabs) — used for the chip icon.
    var appBundleID: String?
    /// Small preview (image thumbnail / file icon). Not part of equality.
    var thumbnail: NSImage?
    var payload: AttachmentPayload
    /// Size of the encoded payload, for limits and display.
    var byteCount: Int
    /// False for window captures and selection/Services text: History keeps the chip (name, badge,
    /// thumbnail) but never writes the payload, so after a relaunch the chip reads "no longer stored on
    /// this Mac".
    var retainsPayloadInHistory: Bool

    init(
        id: UUID = UUID(),
        kind: AttachmentKind,
        displayName: String,
        badge: String,
        sourceURL: URL? = nil,
        appBundleID: String? = nil,
        thumbnail: NSImage? = nil,
        payload: AttachmentPayload,
        byteCount: Int,
        retainsPayloadInHistory: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.badge = badge
        self.sourceURL = sourceURL
        self.appBundleID = appBundleID
        self.thumbnail = thumbnail
        self.payload = payload
        self.byteCount = byteCount
        self.retainsPayloadInHistory = retainsPayloadInHistory
    }

    static func == (lhs: Attachment, rhs: Attachment) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.displayName == rhs.displayName
            && lhs.badge == rhs.badge && lhs.sourceURL == rhs.sourceURL && lhs.payload == rhs.payload
            && lhs.retainsPayloadInHistory == rhs.retainsPayloadInHistory
    }

    /// Messages API content blocks for this attachment. Placed before the user's text block.
    func contentBlocks() -> [JSONValue] {
        switch payload {
        case .image(let mediaType, let base64):
            return [[
                "type": "image",
                "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(base64)],
            ]]
        case .pdf(let base64):
            return [[
                "type": "document",
                "source": ["type": "base64", "media_type": "application/pdf", "data": .string(base64)],
                "title": .string(displayName),
            ]]
        case .text(let text):
            return [[
                "type": "document",
                "source": ["type": "text", "media_type": "text/plain", "data": .string(text)],
                "title": .string(displayName),
            ]]
        case .webPage(let title, let url):
            // A page title is written by the page's author: clean it and turn angle brackets into
            // look-alikes, so it can never close the wrapper early and pose as the user's own words.
            let safeTitle = DisplayText.sanitized(title, maxLength: 300)
                .replacingOccurrences(of: "<", with: "\u{2039}")
                .replacingOccurrences(of: ">", with: "\u{203A}")
            let text = "<browser_tab>\nTitle: \(safeTitle)\nURL: \(url.absoluteString)\n</browser_tab>"
            return [["type": "text", "text": .string(text)]]
        }
    }
}

// MARK: - Conversation

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
}

enum MessageState: Equatable, Sendable {
    case complete
    case streaming
    case cancelled
    /// The model (or its safety classifiers) declined. Associated value is user-facing copy.
    case refused(String)
    /// Request failed. Associated value is user-facing copy.
    case failed(String)
}

struct ToolActivity: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case webSearch
        case webFetch
        case other
    }

    /// The `server_tool_use` block id.
    let id: String
    var kind: Kind
    /// e.g. `Searching “swift concurrency”` or `Reading techcrunch.com`.
    var label: String
    var isDone: Bool
}

struct SourceLink: Identifiable, Hashable, Sendable {
    var id: String { url.absoluteString }
    let title: String
    let url: URL
}

struct ChatMessage: Identifiable, Equatable, @unchecked Sendable {
    let id: UUID
    let role: ChatRole
    /// User: the typed text. Assistant: visible reply text accumulated from text deltas.
    var text: String
    /// User messages only (for display).
    var attachments: [Attachment]
    /// Assistant: summarized thinking text (may stay empty).
    var thinking: String
    /// Assistant: true while thinking and before the first text delta.
    var isThinking: Bool
    /// Assistant: server tool calls (web search / fetch) in order.
    var activities: [ToolActivity]
    /// Assistant: deduplicated sources from search results, fetches and citations.
    var sources: [SourceLink]
    /// Exact content blocks to send back to the API for this turn.
    /// User: attachment blocks + text block. Assistant: raw response content blocks.
    var apiContent: [JSONValue]
    var state: MessageState
    /// Assistant: the model that produced the reply (may differ from the requested one after a fallback).
    var model: String?
    /// Whether this message is sent as history on later turns.
    var includeInContext: Bool
    let createdAt: Date
    /// Assistant: client tool calls across all rounds, in model order.
    var toolCalls: [ToolCall]
    /// Assistant: the points where client tool results were (or will be) sent.
    var toolExchanges: [ToolExchange]

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String = "",
        attachments: [Attachment] = [],
        thinking: String = "",
        isThinking: Bool = false,
        activities: [ToolActivity] = [],
        sources: [SourceLink] = [],
        apiContent: [JSONValue] = [],
        state: MessageState = .complete,
        model: String? = nil,
        includeInContext: Bool = true,
        createdAt: Date = Date(),
        toolCalls: [ToolCall] = [],
        toolExchanges: [ToolExchange] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.thinking = thinking
        self.isThinking = isThinking
        self.activities = activities
        self.sources = sources
        self.apiContent = apiContent
        self.state = state
        self.model = model
        self.includeInContext = includeInContext
        self.createdAt = createdAt
        self.toolCalls = toolCalls
        self.toolExchanges = toolExchanges
    }
}

// MARK: - Client tool calls on assistant messages

enum ToolCallStatus: Equatable, Sendable, Codable {
    /// The tool_use block is still streaming.
    case preparing
    /// Input complete; waiting for its turn in the round.
    case queued
    /// The permission card is in the dock (a macOS permission is missing).
    case needsPermission
    /// The approval or consent card is in the dock.
    case awaitingApproval
    /// A macOS dialog Otto triggered is up; the value is the app it is about ("Finder").
    case waitingForSystem(String)
    case running
    case succeeded
    /// Short user-facing reason ("Timed out", "Shortcut not found").
    case failed(String)
    /// The user declined (or Decline All, decline fatigue, or the approval expired).
    case denied
    /// Refused by policy before asking ("it asked for administrator privileges").
    case blocked(String)
    /// The user stopped the reply.
    case cancelled
    /// Never ran: cut off, limit reached, turned off, permission not granted.
    case skipped(String)
    /// The created item was removed with Undo.
    case undone

    var isTerminal: Bool {
        switch self {
        case .preparing, .queued, .needsPermission, .awaitingApproval, .waitingForSystem, .running: return false
        case .succeeded, .failed, .denied, .blocked, .cancelled, .skipped, .undone: return true
        }
    }
}

/// Exact text revealed by a row's "Show details" (script source, shortcut input, URL). Never truncated in storage.
struct ToolDisclosure: Equatable, Sendable, Codable {
    /// "Script", "Input", "Address".
    var label: String
    var text: String
    /// "AppleScript" enables highlighting; nil is plain monospaced text.
    var language: String?
}

/// How a call is described to the user (row and card header). Produced by the tool from a validated input.
struct ToolCallPresentation: Equatable, Sendable, Codable {
    /// SF Symbol, e.g. "calendar.badge.plus".
    var symbol: String
    /// Imperative: "Add “Dentist” to Calendar".
    var title: String
    /// "Adding to Calendar…".
    var activeTitle: String
    /// "Added “Dentist” · Tue, Sep 29, 3:00 PM".
    var doneTitle: String
    /// Secondary line: "Home · 3:00–4:00 PM".
    var detail: String?
    var disclosure: ToolDisclosure?

    /// While input streams, or for unknown tools.
    static func generic(toolName: String) -> ToolCallPresentation {
        ToolCallPresentation(symbol: "wand.and.stars", title: "Use \(toolName)", activeTitle: "Using \(toolName)…",
                             doneTitle: "Used \(toolName)", detail: nil, disclosure: nil)
    }
}

/// What a tool returns to Claude as the `tool_result` content.
struct ToolOutput: Equatable, Sendable, Codable {
    enum Part: Equatable, Sendable, Codable {
        case text(String)
        /// mediaType image/png|jpeg|gif|webp; base64 ≤ AttachmentLoader.maxImageBase64Bytes.
        case image(mediaType: String, base64: String)
    }

    var parts: [Part]
    var isError: Bool

    static let maxTextCharacters = 16_000
    static let maxImages = 4
    /// Characters of text in `previewText`.
    static let previewCharacters = 600

    /// A successful text result.
    static func text(_ text: String) -> ToolOutput {
        ToolOutput(parts: [.text(text)], isError: false)
    }

    /// An error result (`is_error: true`).
    static func error(_ text: String) -> ToolOutput {
        ToolOutput(parts: [.text(text)], isError: true)
    }

    /// Adjacent text parts are joined with a newline; text beyond `maxTextCharacters` in total is cut with
    /// "\n…(truncated: N more characters)"; only the first `maxImages` images are kept; NUL and C0 controls
    /// except \n and \t are stripped; an empty output becomes "Done." (the API rejects empty text blocks).
    func normalized() -> ToolOutput {
        var joined: [Part] = []
        var imageCount = 0
        for part in parts {
            switch part {
            case .text(let text):
                let clean = Self.strippingControls(text)
                if case .text(let previous)? = joined.last {
                    joined[joined.count - 1] = .text(previous + "\n" + clean)
                } else {
                    joined.append(.text(clean))
                }
            case .image:
                guard imageCount < Self.maxImages else { continue }
                imageCount += 1
                joined.append(part)
            }
        }

        let totalText = joined.reduce(0) { total, part in
            if case .text(let text) = part { return total + text.count }
            return total
        }
        var result: [Part] = []
        var budget = Self.maxTextCharacters
        var truncationNoted = false
        for part in joined {
            switch part {
            case .text(let text):
                if text.count <= budget {
                    budget -= text.count
                    if !text.isEmpty { result.append(part) }
                } else {
                    let kept = String(text.prefix(budget))
                    budget = 0
                    if !truncationNoted {
                        truncationNoted = true
                        let dropped = totalText - Self.maxTextCharacters
                        result.append(.text(kept + "\n…(truncated: \(dropped) more characters)"))
                    }
                }
            case .image:
                result.append(part)
            }
        }
        if result.isEmpty { result = [.text("Done.")] }
        return ToolOutput(parts: result, isError: isError)
    }

    /// {"type":"tool_result","tool_use_id":id,"content":[{"type":"text",…}|{"type":"image",…}], "is_error":true?}
    /// (`is_error` present only when isError).
    func toolResultBlock(toolUseID: String) -> JSONValue {
        let content: [JSONValue] = parts.map { part in
            switch part {
            case .text(let text):
                return ["type": "text", "text": .string(text)]
            case .image(let mediaType, let base64):
                return [
                    "type": "image",
                    "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(base64)],
                ]
            }
        }
        var block: [String: JSONValue] = [
            "type": "tool_result",
            "tool_use_id": .string(toolUseID),
            "content": .array(content),
        ]
        if isError { block["is_error"] = true }
        return .object(block)
    }

    /// Image parts replaced by a text note (history persistence and the echo of older turns).
    func strippingImages(note: String = "[Image omitted]") -> ToolOutput {
        ToolOutput(parts: parts.map { part in
            if case .image = part { return .text(note) }
            return part
        }, isError: isError)
    }

    /// First ~600 characters of text, for the row's Output box.
    var previewText: String {
        let text = parts.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined(separator: "\n")
        guard text.count > Self.previewCharacters else { return text }
        return String(text.prefix(Self.previewCharacters)) + "…"
    }

    private static func strippingControls(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20, scalar != "\n", scalar != "\t" { continue }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}

enum ToolRecovery: Equatable, Sendable, Codable {
    case openSystemSettings(Permission)
    case openActionsSettings
}

/// How a call came to run (row copy: "(always allowed)").
enum ApprovalVia: Equatable, Sendable, Codable {
    case notRequired, userApproved, consent, rememberedScope(label: String)
}

/// Undo for a created item (calendar event, reminder). The executor routes it back to the tool.
struct UndoToken: Equatable, Sendable, Codable {
    let toolName: String
    /// Events: `EKEvent.eventIdentifier`; reminders: `calendarItemIdentifier`. Neither survives every sync (a full
    /// sync or a calendar move can change it), so `fallback` finds the item again.
    let itemID: String
    let fallback: UndoFallback?
    /// Created + 10 minutes.
    let expires: Date
    /// Row copy after undo: "Removed “Dentist”".
    let doneTitle: String
    /// "the calendar event “Dentist” on Tue, Sep 29 was removed".
    let noteForClaude: String
}

/// How to find a created item when lookup by identifier fails: exact title and dates in the calendar or list it
/// was created in.
struct UndoFallback: Equatable, Sendable, Codable {
    let title: String
    /// Events: start; reminders: due date (nil when none).
    let start: Date?
    /// Events only.
    let end: Date?
    let calendarIdentifier: String
}

struct ToolCall: Identifiable, Equatable, Sendable, Codable {
    /// The tool_use id.
    let id: String
    let name: String
    /// nil while preparing, or when the JSON was invalid.
    var input: JSONValue?
    /// Raw streamed text when input == nil (≤ 2,000 characters).
    var invalidInput: String?
    var presentation: ToolCallPresentation
    var status: ToolCallStatus
    /// Exactly what is sent back as tool_result. Set for every call in a ToolExchange before the next
    /// request is built (synthesized for denied, cancelled, skipped and blocked calls).
    var result: ToolOutput?
    /// "after reading example.com".
    var provenance: String?
    var caution: Bool = false
    var approvedVia: ApprovalVia?
    var recovery: ToolRecovery?
    var undo: UndoToken?
    /// "Converting 3 of 12…" (throttled to 4 per second).
    var progressNote: String?
    var startedAt: Date?
    var finishedAt: Date?
}

/// A point in an assistant turn where client tool results were (or will be) sent.
struct ToolExchange: Equatable, Sendable, Codable {
    /// `apiContent.count` right after the round that requested these calls.
    let contentEnd: Int
    /// `text.count` (Characters) at that moment; splits the visible text for interleaving.
    let textEnd: Int
    /// tool_use ids of this round, in model order.
    let callIDs: [String]
}

// MARK: - LLM client contract

struct MessagesRequest: Sendable {
    var model: ModelOption
    var system: String
    /// `[{"role": "user"|"assistant", "content": [blocks…]}, …]`
    var messages: [JSONValue]
    var maxTokens: Int
    var effort: EffortLevel
    var webAccess: Bool
    /// Client tool definitions, sent after the server tools, already sorted by name. Each one is
    /// {"name","description","input_schema","eager_input_streaming":true,"strict":true?} (ToolRegistry.definitions).
    var clientTools: [JSONValue] = []
    /// Sent as `tool_choice` only when non-nil AND the request defines at least one tool.
    /// Otto only ever sends {"type":"none"} (the wrap-up request after the action limit).
    var toolChoice: JSONValue? = nil
    /// `max_uses` for each server tool in THIS request (only read when `webAccess`). 0 omits that tool from `tools`.
    /// The loop derives it from the per-turn budget and the web pause.
    var serverToolLimits = ServerToolLimits()
}

/// Per-request `max_uses` of the server tools.
struct ServerToolLimits: Equatable, Sendable {
    var webSearch = 5
    var webFetch = 5
    static let none = ServerToolLimits(webSearch: 0, webFetch: 0)
}

struct StreamResult: Sendable {
    /// Fully assembled response content blocks (text with citations, thinking with signature,
    /// server_tool_use with parsed input, *_tool_result, fallback, …) in index order.
    var content: [JSONValue]
    var stopReason: String?
    var stopDetails: JSONValue?
    var model: String?
    var usage: JSONValue?
}

enum StreamEvent: Sendable {
    /// `message_start` — the model actually serving this response.
    case messageStart(model: String)
    /// A thinking block started.
    case thinkingStarted
    /// Summarized thinking text.
    case thinkingDelta(String)
    /// Visible reply text.
    case textDelta(String)
    /// A server tool call started (isDone == false) or finished (isDone == true). Same id updates in place.
    case toolActivity(ToolActivity)
    /// New sources discovered (search results, fetched pages, citations).
    case sources([SourceLink])
    /// The server re-ran the request on a fallback model after a refusal.
    case fallback(fromModel: String?, toModel: String?)
    /// Terminal event: the complete response.
    case completed(StreamResult)
    /// A client `tool_use` block started (input still streaming). Emitted only when id and name are non-empty.
    case toolUseStarted(id: String, name: String)
    /// A client `tool_use` block finished. `input` is nil when the accumulated JSON is not a JSON object
    /// (eager input streaming can deliver cut-off or invalid JSON); `rawInput` is the accumulated text ("" when
    /// no delta arrived). The stored content block keeps its start input `{}` when parsing fails.
    case toolUseReady(id: String, name: String, input: JSONValue?, rawInput: String)
    /// Cumulative usage of the current response so far (after `message_start` and each `message_delta` that
    /// carries usage). Never mutates a message; ChatSession keeps the latest for partial-usage accounting.
    case usage(JSONValue)
}

protocol LLMClient: Sendable {
    /// Streams one Messages API response. The stream finishes after `.completed`, or throws `LLMError`
    /// (or `CancellationError` when the consuming task is cancelled).
    func stream(_ request: MessagesRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

enum LLMError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited(retryAfter: TimeInterval?)
    case overloaded
    case http(status: Int, type: String?, message: String)
    case streamError(type: String?, message: String)
    case network(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your Anthropic API key in Settings to start chatting with Otto."
        case .invalidAPIKey:
            return "Your Anthropic API key was rejected. Check it in Settings."
        case .rateLimited(let retryAfter):
            if let retryAfter, retryAfter > 0 {
                return "Otto is being rate limited. Try again in \(Int(retryAfter.rounded(.up))) seconds."
            }
            return "Otto is being rate limited. Try again in a moment."
        case .overloaded:
            return "Claude is overloaded right now. Try again in a moment."
        case .http(let status, _, let message):
            return message.isEmpty ? "Request failed (HTTP \(status))." : message
        case .streamError(_, let message):
            return message.isEmpty ? "The response was interrupted." : message
        case .network(let message):
            return message.isEmpty ? "Couldn't reach the Anthropic API. Check your connection." : message
        case .decoding(let message):
            return "Couldn't read the response: \(message)"
        }
    }

    /// Whether a retry (before any output was received) may succeed.
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .network: return true
        case .http(let status, _, _): return status == 408 || status == 409 || status >= 500
        case .streamError(let type, _): return type == "overloaded_error" || type == "api_error"
        case .missingAPIKey, .invalidAPIKey, .decoding: return false
        }
    }
}
