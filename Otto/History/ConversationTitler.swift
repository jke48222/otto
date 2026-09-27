//
//  ConversationTitler.swift
//  Otto
//
//  Titles, previews, plain text and search snippets for saved conversations, computed on the Mac from text
//  Otto already has (no model calls). Pure.
//

import Foundation
import NaturalLanguage

enum ConversationTitler {
    static let maxTitleLength = 52
    static let maxPreviewLength = 120
    static let untitled = "New conversation"

    /// From the first user message; computed at the conversation's first save and never changed.
    static func title(for messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.role == .user }) else { return untitled }
        return title(userText: first.text, attachments: first.attachments)
    }

    static func title(userText: String, attachments: [Attachment]) -> String {
        var text = plainText(fromMarkdown: userText)
        text = strippingLeadIns(text)
        text = firstSentence(of: text)
        if text.count > maxTitleLength {
            text = cut(text, to: maxTitleLength - 1) + "…"
        } else {
            text = trimmingTrailingPunctuation(text)
        }
        text = uppercasingFirstCharacter(text)
        if !text.isEmpty { return text }

        let names = attachments.map { attachmentName($0) }.filter { !$0.isEmpty }
        guard let firstName = names.first else { return untitled }
        let label = names.count == 1 ? firstName : "\(firstName) + \(names.count - 1) more"
        return DisplayText.sanitized(label, maxLength: maxTitleLength)
    }

    /// First non-empty line of the latest completed assistant reply, else of the latest user text.
    static func preview(for messages: [ChatMessage]) -> String {
        let reply = messages.last { message in
            message.role == .assistant && message.state == .complete && firstLine(of: message.text) != nil
        }
        let source = reply ?? messages.last { $0.role == .user && firstLine(of: $0.text) != nil }
        guard let source, let line = firstLine(of: source.text) else { return "" }
        return DisplayText.sanitized(line, maxLength: maxPreviewLength)
    }

    /// Markdown reduced to one line of plain text: fenced code dropped, heading/quote/list markers, emphasis
    /// and backticks removed, links reduced to their text, all whitespace collapsed to single spaces.
    static func plainText(fromMarkdown markdown: String) -> String {
        let joined = plainLines(fromMarkdown: markdown).joined(separator: " ")
        return DisplayText.sanitized(joined, maxLength: Int.max)
    }

    /// About `radius` characters either side of `range`, widened to whole words, with "…" where text was cut.
    static func snippet(in text: String, around range: Range<String.Index>, radius: Int = 40) -> String {
        guard range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex else {
            return DisplayText.sanitized(text, maxLength: radius * 2)
        }
        var start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        var end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        if start > text.startIndex, let space = text[start..<range.lowerBound].firstIndex(where: \.isWhitespace) {
            start = text.index(after: space)
        }
        if end < text.endIndex, let space = text[range.upperBound..<end].lastIndex(where: \.isWhitespace) {
            end = space
        }
        let body = DisplayText.sanitized(String(text[start..<end]), maxLength: Int.max)
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }

    // MARK: - Private

    private static let leadIns: [NSRegularExpression] = [
        #"^(hey|hi|hello|yo|ok|okay)\b[,!.]*\s*"#,
        #"^otto\b[,:!.]*\s*"#,
        #"^(can|could|would|will) you (please )?"#,
        #"^please\s+"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let markdownLink = try? NSRegularExpression(pattern: #"!?\[([^\]]*)\]\([^)]*\)"#)
    private static let lineMarker = try? NSRegularExpression(pattern: #"^\s*(#{1,6}\s+|>\s?|[-*+]\s+|\d{1,9}[.)]\s+)+"#)
    private static let underscoreEmphasis = try? NSRegularExpression(pattern: #"(^|[^\p{L}\p{N}])_+|_+(?=$|[^\p{L}\p{N}])"#)

    /// Lines of the text without fenced code, markers, emphasis or link syntax.
    private static func plainLines(fromMarkdown markdown: String) -> [String] {
        var lines: [String] = []
        var fence: String?
        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                lines.append(" ")
                continue
            }
            var line = String(rawLine)
            line = replacing(lineMarker, in: line, with: "")
            line = replacing(markdownLink, in: line, with: "$1")
            line = line.replacingOccurrences(of: "~~", with: "")
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "`", with: "")
            line = replacing(underscoreEmphasis, in: line, with: "$1")
            lines.append(line)
        }
        return lines
    }

    private static func replacing(_ expression: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let expression else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func firstLine(of markdown: String) -> String? {
        plainLines(fromMarkdown: markdown)
            .map { DisplayText.sanitized($0, maxLength: Int.max) }
            .first { !$0.isEmpty }
    }

    /// Greetings, "Otto,", "can you", "please": removed repeatedly while at least 3 characters remain.
    private static func strippingLeadIns(_ text: String) -> String {
        var current = text
        var changed = true
        while changed {
            changed = false
            for expression in leadIns {
                let range = NSRange(current.startIndex..., in: current)
                let stripped = expression.stringByReplacingMatches(in: current, range: range, withTemplate: "")
                if stripped != current, stripped.trimmingCharacters(in: .whitespaces).count >= 3 {
                    current = stripped
                    changed = true
                }
            }
        }
        return current.trimmingCharacters(in: .whitespaces)
    }

    private static func firstSentence(of text: String) -> String {
        guard !text.isEmpty else { return text }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentence: String?
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let candidate = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.isEmpty { return true }
            sentence = candidate
            return false
        }
        return sentence ?? text
    }

    /// At most `limit` characters, cut at the last word boundary (a hard cut when there is none).
    private static func cut(_ text: String, to limit: Int) -> String {
        let prefix = String(text.prefix(limit + 1))
        if prefix.count > limit, let space = prefix.lastIndex(where: \.isWhitespace), space > prefix.startIndex {
            return trimmingTrailingPunctuation(String(prefix[..<space]).trimmingCharacters(in: .whitespaces))
        }
        return trimmingTrailingPunctuation(String(text.prefix(limit)).trimmingCharacters(in: .whitespaces))
    }

    private static func trimmingTrailingPunctuation(_ text: String) -> String {
        var result = text
        while let last = result.last, ".,;:".contains(last) { result.removeLast() }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func uppercasingFirstCharacter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).localizedCapitalized + text.dropFirst()
    }

    private static func attachmentName(_ attachment: Attachment) -> String {
        if case .webPage(let title, _) = attachment.payload, !title.isEmpty {
            return DisplayText.sanitized(title, maxLength: maxTitleLength)
        }
        return DisplayText.sanitized(attachment.displayName, maxLength: maxTitleLength)
    }
}
