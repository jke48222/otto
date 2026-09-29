//
//  EchoDetector.swift
//  Otto
//
//  Notices when an action would carry private text out of the Mac: calendar and reminder details,
//  script or shortcut output, or a selection or clipboard the user attached, showing up in a URL, a
//  shortcut's input or a script. Both sides are reduced to a "skeleton" (lowercase words joined by
//  single spaces) so separators, percent-encoding, base64, hex or reversal don't hide a match. Pure.
//

import Foundation

struct EchoFinding: Equatable, Sendable {
    let sourcePhrase: String
    let sample: String
}

enum EchoDetector {
    /// Largest attached selection or clipboard document (UTF-8 bytes) that is scanned for private phrases.
    static let maxDocumentBytes = 64 * 1024
    /// Longer values also contribute every run of this many consecutive words, so a part of a note is caught too.
    static let windowWords = 5
    /// Upper bound on the phrases taken from one transcript.
    static let maxPhrases = 4_000

    /// Private phrases come from (a) tool_results of tools with a privateDataSource (tool name → phrase: calendar and
    /// reminders tools, run_applescript "your Mac", run_shortcut "a shortcut's output"), (b) the same tools' results
    /// downgraded to `<earlier_action_result tool="…">` user text blocks (a round of a tool that is no longer offered;
    /// error results are skipped) and (c) user document blocks titled "Selection from …" or "Clipboard.txt"
    /// (text ≤ 64 KB; "your selection" / "your clipboard").
    /// Each phrase is kept as its skeleton and must be ≥ 2 tokens or ≥ 8 characters.
    static func privateStrings(in transcript: [JSONValue], sources: [String: String]) -> [(phrase: String, source: String)] {
        var toolNames: [String: String] = [:]
        var result: [(phrase: String, source: String)] = []
        var seen = Set<String>()

        func add(_ texts: [String], source: String) {
            for text in texts {
                for phrase in phrases(from: text) where result.count < maxPhrases && seen.insert(phrase).inserted {
                    result.append((phrase, source))
                }
            }
        }

        for entry in transcript {
            let role = entry["role"]?.stringValue
            guard case .array(let blocks)? = entry["content"] else { continue }
            for block in blocks {
                switch (role, block.typeName) {
                case ("assistant", "tool_use"?):
                    if let id = block["id"]?.stringValue, let name = block["name"]?.stringValue {
                        toolNames[id] = name
                    }
                case ("user", "tool_result"?):
                    guard block["is_error"]?.boolValue != true,
                          let id = block["tool_use_id"]?.stringValue, let name = toolNames[id],
                          let source = sources[name] else { continue }
                    add(resultStrings(block["content"]), source: source)
                case ("user", "text"?):
                    guard let text = block["text"]?.stringValue,
                          let earlier = earlierActionResult(text), let source = sources[earlier.tool],
                          !isErrorText(earlier.payload) else { continue }
                    add(resultStrings(.string(earlier.payload)), source: source)
                case ("user", "document"?):
                    guard let source = documentSource(title: block["title"]?.stringValue),
                          block["source"]?["type"]?.stringValue == "text",
                          let data = block["source"]?["data"]?.stringValue,
                          data.utf8.count <= maxDocumentBytes else { continue }
                    add([data], source: source)
                default:
                    break
                }
            }
        }
        return result
    }

    /// Skeleton = lowercase, percent-decode, '+' → ' ', then every run of non-alphanumeric characters → one ' '
    /// (so "dentist-dr-lee.evil.com", "dentist_dr_lee" and "Dentist — Dr. Lee" all contain "dentist dr lee").
    /// Each candidate is also tested as: the base64-decoded variant of every ≥ 16-char base64 token, the hex-decoded
    /// variant of every ≥ 16-char hex run, and the reversed string. First match wins.
    static func find(in candidates: [String], privateStrings: [(phrase: String, source: String)]) -> EchoFinding? {
        guard !privateStrings.isEmpty else { return nil }
        for candidate in candidates where !candidate.isEmpty {
            for variant in variants(of: candidate) {
                let skeleton = skeleton(variant)
                guard !skeleton.isEmpty else { continue }
                let spaced = " \(skeleton) "
                let joined = skeleton.replacingOccurrences(of: " ", with: "")
                for (phrase, source) in privateStrings {
                    if spaced.contains(" \(phrase) ") {
                        return EchoFinding(sourcePhrase: source, sample: phrase)
                    }
                    let compact = phrase.replacingOccurrences(of: " ", with: "")
                    if compact.count >= 8, joined.contains(compact) {
                        return EchoFinding(sourcePhrase: source, sample: phrase)
                    }
                }
            }
        }
        return nil
    }

    /// Lowercase, percent-decoded, '+' as a space, every run of non-alphanumerics as one space, trimmed.
    static func skeleton(_ text: String) -> String {
        let decoded = (text.removingPercentEncoding ?? text).lowercased().replacingOccurrences(of: "+", with: " ")
        var result = ""
        var pendingSpace = false
        for character in decoded {
            if character.isLetter || character.isNumber {
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.append(character)
            } else {
                pendingSpace = true
            }
        }
        return result
    }

    // MARK: - Private

    private static func documentSource(title: String?) -> String? {
        guard let title else { return nil }
        if title == AttachmentLoader.clipboardTextName { return "your clipboard" }
        if title == "Selection" || title.hasPrefix("Selection from ") { return "your selection" }
        return nil
    }

    /// The tool and unescaped payload of a `<earlier_action_result tool="‹name›" …>‹payload›</earlier_action_result>`
    /// block (`ToolHistory.earlierActionResult`); nil for any other text.
    static func earlierActionResult(_ text: String) -> (tool: String, payload: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let closing = "</earlier_action_result>"
        guard trimmed.hasPrefix("<earlier_action_result"), trimmed.hasSuffix(closing),
              let tagEnd = trimmed.firstIndex(of: ">") else { return nil }
        let tag = trimmed[trimmed.startIndex..<tagEnd]
        guard let start = tag.range(of: " tool=\""),
              let end = tag[start.upperBound...].firstIndex(of: "\"") else { return nil }
        let tool = unescaped(String(tag[start.upperBound..<end]))
        let payloadStart = trimmed.index(after: tagEnd)
        let payloadEnd = trimmed.index(trimmed.endIndex, offsetBy: -closing.count)
        guard !tool.isEmpty, payloadStart <= payloadEnd else { return nil }
        return (tool, unescaped(String(trimmed[payloadStart..<payloadEnd])))
    }

    /// A result the loop or a tool wrote as an error ("declined: …", "permission_denied: …").
    private static func isErrorText(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        return ToolError.Code(rawValue: String(text[text.startIndex..<colon])) != nil
    }

    private static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The text of a tool_result's content. JSON results contribute their string values (except "status"); JSON
    /// cut short (a downgraded result keeps its first 2,000 characters) contributes its complete string values;
    /// other text contributes itself.
    private static func resultStrings(_ content: JSONValue?) -> [String] {
        let texts: [String]
        switch content {
        case .string(let text)?:
            texts = [text]
        case .array(let parts)?:
            texts = parts.compactMap { $0.typeName == "text" ? $0["text"]?.stringValue : nil }
        default:
            texts = []
        }
        return texts.flatMap { text -> [String] in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return [text] }
            if let json = try? JSONValue.decode(trimmed) {
                var strings: [String] = []
                collectStrings(json, key: nil, into: &strings)
                return strings
            }
            let literals = stringLiterals(in: trimmed)
            return literals.isEmpty ? [text] : literals
        }
    }

    /// The complete JSON string values (not keys) of JSON text that doesn't parse, decoded.
    private static func stringLiterals(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)"(\s*:)?"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.range(at: 2).location == NSNotFound, let whole = Range(match.range, in: text),
                  case .string(let value)? = try? JSONValue.decode(String(text[whole])) else { return nil }
            return value
        }
    }

    private static func collectStrings(_ value: JSONValue, key: String?, into strings: inout [String]) {
        switch value {
        case .string(let text):
            if key != "status" { strings.append(text) }
        case .array(let items):
            for item in items { collectStrings(item, key: key, into: &strings) }
        case .object(let object):
            for (childKey, child) in object { collectStrings(child, key: childKey, into: &strings) }
        default:
            break
        }
    }

    /// Each line's skeleton when it is ≥ 2 tokens or ≥ 8 characters and has a word of at least 3 letters (so bare
    /// dates and numbers aren't private phrases), plus every `windowWords`-word run of longer lines.
    private static func phrases(from text: String) -> [String] {
        var result: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let lineSkeleton = skeleton(String(line))
            guard isPhrase(lineSkeleton) else { continue }
            result.append(lineSkeleton)
            let words = lineSkeleton.split(separator: " ")
            guard words.count > windowWords else { continue }
            for start in 0...(words.count - windowWords) {
                let window = words[start..<(start + windowWords)].joined(separator: " ")
                if isPhrase(window) { result.append(window) }
            }
        }
        return result
    }

    private static func isPhrase(_ skeleton: String) -> Bool {
        let words = skeleton.split(separator: " ")
        guard words.count >= 2 || skeleton.count >= 8 else { return false }
        return words.contains { word in word.filter(\.isLetter).count >= 3 }
    }

    /// The candidate, then the decoded form of each base64 token and each hex run, then the reversed candidate.
    private static func variants(of candidate: String) -> [String] {
        let decoded = candidate.removingPercentEncoding ?? candidate
        var result = [candidate]
        // A path can glue a token to the segment before it ("example/<token>"), so segments are tried too.
        let tokens = matches(of: base64Token, in: decoded).flatMap { token -> [String] in
            let segments = token.split(separator: "/").map(String.init).filter { $0.count >= 16 && $0 != token }
            return [token] + segments
        }
        result += tokens.compactMap(decodeBase64)
        result += matches(of: hexRun, in: decoded).compactMap(decodeHex)
        result.append(String(candidate.reversed()))
        return result
    }

    private static let base64Token = "[A-Za-z0-9+/_-]{16,}={0,2}"
    private static let hexRun = "[0-9A-Fa-f]{16,}"

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func decodeBase64(_ token: String) -> String? {
        var standard = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard = standard.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let remainder = standard.count % 4
        if remainder == 1 { standard.removeLast() }
        if standard.count % 4 != 0 { standard += String(repeating: "=", count: 4 - standard.count % 4) }
        guard let data = Data(base64Encoded: standard) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeHex(_ run: String) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(run.count / 2)
        var iterator = run.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            guard let byte = UInt8(String([high, low]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return String(data: Data(bytes), encoding: .utf8)
    }
}
