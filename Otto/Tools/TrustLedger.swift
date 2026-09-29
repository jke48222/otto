//
//  TrustLedger.swift
//  Otto
//
//  Where the text in a conversation came from. Web pages, search results, attached files, images,
//  the browser tab, the clipboard and some tools' output are written by other people and can hide
//  instructions; the ledger lists them, marks what arrived since the user's latest real message, and
//  turns that into the provenance line and the caution state of the approval card. Pure: it reads
//  the request transcript only.
//

import Foundation

struct ProvenanceSource: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case webFetch(host: String), webSearch, browserTab(host: String),
             file(name: String), image(name: String?), clipboard, toolOutput(tool: String)
    }
    enum Severity: Int, Comparable, Sendable {
        case low, medium, high
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let kind: Kind; let severity: Severity

    /// A page Otto fetched or a web search: the "untrusted web content" `.fewerPrompts` stops counting against an
    /// "Always allow" shortcut. Everything else (files, images, the clipboard, the browser tab block, tool output)
    /// still does.
    var isWeb: Bool {
        switch kind {
        case .webFetch, .webSearch: return true
        default: return false
        }
    }

    /// "reading example.com", "searching the web", "reading report.pdf".
    var phrase: String {
        switch kind {
        case .webFetch(let host), .browserTab(let host):
            return "reading \(host)"
        case .webSearch:
            return "searching the web"
        case .file(let name):
            return "reading \(name)"
        case .image(let name):
            return name.map { "reading \($0)" } ?? "reading an image"
        case .clipboard:
            return "reading your clipboard"
        case .toolOutput(let tool):
            switch tool {
            case "run_shortcut": return "running a shortcut"
            case "run_applescript": return "running a script"
            case "calendar_list_events": return "reading your calendar"
            case "reminders_list": return "reading your reminders"
            case "media_control": return "checking what's playing"
            default: return "using \(tool)"
            }
        }
    }

    /// What the caution banner and the web pause name: "example.com", "a web search", "report.pdf".
    var sourceName: String {
        switch kind {
        case .webFetch(let host), .browserTab(let host):
            return host
        case .webSearch:
            return "a web search"
        case .file(let name):
            return name
        case .image(let name):
            return name ?? "an image"
        case .clipboard:
            return "your clipboard"
        case .toolOutput(let tool):
            switch tool {
            case "run_shortcut": return "a shortcut's output"
            case "run_applescript": return "a script's output"
            case "calendar_list_events": return "your calendar"
            case "reminders_list": return "your reminders"
            case "media_control": return "the track info"
            default: return "\(tool)'s output"
            }
        }
    }
}

struct TrustAssessment: Equatable, Sendable {
    /// Since the user's latest real message (attachments inside that message count as fresh).
    var fresh: [ProvenanceSource]
    /// Everything in context, in transcript order.
    var all: [ProvenanceSource]
    /// Typed text of the user's latest real message ("" when none), for the remembered-scope input test.
    var latestUserText: String

    /// Any fresh source with severity ≥ .medium.
    var caution: Bool { fresh.contains { $0.severity >= .medium } }

    /// Any fresh source with severity ≥ .medium that is not web content (see `ProvenanceSource.isWeb`).
    var hasFreshNonWebCaution: Bool { fresh.contains { $0.severity >= .medium && !$0.isWeb } }

    /// Any source in `all` with severity .high (a page or search anywhere in context).
    var hasHighSource: Bool { all.contains { $0.severity == .high } }

    /// "Requested after reading example.com" (the most severe, then most recent, fresh source) /
    /// "Earlier in this chat Otto read example.com" (no fresh source, an older high one); else nil.
    var provenanceLine: String? {
        if let source = primaryFreshSource { return "Requested after \(source.phrase)" }
        guard let older = all.last(where: { $0.severity == .high }) else { return nil }
        switch older.kind {
        case .webSearch:
            return "Earlier in this chat Otto searched the web"
        default:
            return "Earlier in this chat Otto read \(older.sourceName)"
        }
    }

    /// "example.com" for the banner: the most severe, then most recent, fresh source of at least medium severity.
    var cautionHeadlineSource: String? {
        guard let source = primaryFreshSource, source.severity >= .medium else { return nil }
        return source.sourceName
    }

    /// The fresh source the card names: highest severity, the latest among equals.
    var primaryFreshSource: ProvenanceSource? {
        var best: ProvenanceSource?
        for source in fresh where best.map({ source.severity >= $0.severity }) ?? true {
            best = source
        }
        return best
    }
}

enum TrustLedger {
    /// `untrustedTools`: names of tools with producesUntrustedOutput (their tool_results are sources).
    /// - Assistant `web_fetch_tool_result` → webFetch(host), high; `web_search_tool_result` → webSearch, high
    ///   (error results carry no page text and are skipped).
    /// - User `document` → file(title), medium ("Clipboard.txt" → clipboard); `image` → image, medium; a text
    ///   block that starts with `<browser_tab>` → browserTab(host), medium, and the whole block is the tab, whatever
    ///   its title contains.
    /// - User `tool_result` of a tool in `untrustedTools` → toolOutput(tool) with that severity.
    /// - A user text block `<earlier_action_result tool="X" …>…</earlier_action_result>` (a downgraded exchange) is
    ///   `toolOutput(tool: X)` with X's severity from `untrustedTools` (medium when X is unknown).
    /// - `<earlier_action_result>` blocks, `[Note: …]` blocks and `<context>` blocks never make a user entry
    ///   "the user's latest real message" (the fresh boundary needs a typed text block).
    static func assess(transcript: [JSONValue], untrustedTools: [String: ProvenanceSource.Severity]) -> TrustAssessment {
        var toolNames: [String: String] = [:]
        var sourcesByEntry: [[ProvenanceSource]] = []
        var boundary: Int?
        var latestUserText = ""

        for (index, entry) in transcript.enumerated() {
            let role = entry["role"]?.stringValue
            let blocks = contentBlocks(of: entry)
            var sources: [ProvenanceSource] = []
            var typed: [String] = []

            for block in blocks {
                switch (role, block.typeName) {
                case ("assistant", "tool_use"?):
                    if let id = block["id"]?.stringValue, let name = block["name"]?.stringValue {
                        toolNames[id] = name
                    }
                case ("assistant", "web_fetch_tool_result"?):
                    if let urlText = block["content"]?["url"]?.stringValue {
                        sources.append(ProvenanceSource(kind: .webFetch(host: displayHost(urlText)), severity: .high))
                    }
                case ("assistant", "web_search_tool_result"?):
                    if block["content"]?.arrayValue != nil {
                        sources.append(ProvenanceSource(kind: .webSearch, severity: .high))
                    }
                case ("user", "document"?):
                    let title = block["title"]?.stringValue ?? ""
                    let name = DisplayText.sanitized(title, maxLength: 80)
                    let kind: ProvenanceSource.Kind = title == AttachmentLoader.clipboardTextName
                        ? .clipboard : .file(name: name.isEmpty ? "a document" : name)
                    sources.append(ProvenanceSource(kind: kind, severity: .medium))
                case ("user", "image"?):
                    sources.append(ProvenanceSource(kind: .image(name: nil), severity: .medium))
                case ("user", "tool_result"?):
                    if let id = block["tool_use_id"]?.stringValue, let name = toolNames[id],
                       let severity = untrustedTools[name] {
                        sources.append(ProvenanceSource(kind: .toolOutput(tool: name), severity: severity))
                    }
                case ("user", "text"?):
                    let text = block["text"]?.stringValue ?? ""
                    switch classify(text) {
                    case .typed:
                        typed.append(text)
                    case .browserTab(let host):
                        sources.append(ProvenanceSource(kind: .browserTab(host: host), severity: .medium))
                    case .earlierResult(let tool):
                        let severity = tool.flatMap { untrustedTools[$0] } ?? .medium
                        sources.append(ProvenanceSource(kind: .toolOutput(tool: tool ?? "an earlier action"),
                                                        severity: severity))
                    case .trustedNote:
                        break
                    }
                default:
                    break
                }
            }

            if role == "user", !typed.isEmpty {
                boundary = index
                latestUserText = typed.joined(separator: "\n")
            }
            sourcesByEntry.append(sources)
        }

        let all = sourcesByEntry.flatMap { $0 }
        let fresh = sourcesByEntry.enumerated()
            .filter { index, _ in boundary.map { index >= $0 } ?? true }
            .flatMap(\.element)
        return TrustAssessment(fresh: fresh, all: all, latestUserText: latestUserText)
    }

    // MARK: - Private

    private enum TextBlockKind: Equatable {
        case typed
        case browserTab(host: String)
        case earlierResult(tool: String?)
        case trustedNote
    }

    private static func classify(_ text: String) -> TextBlockKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .trustedNote }
        if trimmed.hasPrefix("<browser_tab>") { return .browserTab(host: browserTabHost(trimmed)) }
        if trimmed.hasPrefix("<earlier_action_result") { return .earlierResult(tool: attribute("tool", in: trimmed)) }
        if trimmed.hasPrefix("<context>") || trimmed.hasPrefix("[Note:") { return .trustedNote }
        return .typed
    }

    /// The host of the block's URL line. The title line can't be trusted to hold no fake "URL:" line, so the last
    /// one wins (Otto writes the URL after the title).
    private static func browserTabHost(_ block: String) -> String {
        let urlLine = block.split(whereSeparator: \.isNewline).last { $0.hasPrefix("URL: ") }
        guard let urlLine else { return "a browser tab" }
        return displayHost(String(urlLine.dropFirst("URL: ".count)).trimmingCharacters(in: .whitespaces))
    }

    /// The value of `name="…"` in the block's opening tag (values are escaped, so they never contain a quote).
    private static func attribute(_ name: String, in block: String) -> String? {
        guard let tagEnd = block.firstIndex(of: ">") else { return nil }
        let tag = block[block.startIndex..<tagEnd]
        guard let start = tag.range(of: " \(name)=\"") else { return nil }
        let rest = tag[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let value = unescape(String(rest[rest.startIndex..<end]))
        return value.isEmpty ? nil : value
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func contentBlocks(of entry: JSONValue) -> [JSONValue] {
        switch entry["content"] {
        case .array(let blocks)?:
            return blocks
        case .string(let text)?:
            return [["type": "text", "text": .string(text)]]
        default:
            return []
        }
    }

    /// Lowercased host without "www."; the whole string when it isn't a URL with a host.
    private static func displayHost(_ urlText: String) -> String {
        guard let host = URLComponents(string: urlText)?.host?.lowercased(), !host.isEmpty else {
            return DisplayText.sanitized(urlText, maxLength: 80)
        }
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return DisplayText.sanitized(trimmed, maxLength: 80)
    }
}
