//
//  ReplyPreview.swift
//  Otto
//
//  The line that drops below the closed notch when a reply finishes: its outcome, the first line of
//  the answer as plain text, and the drop's size and timing. The iPhone app shows the same preview in its
//  Live Activity; the drop's metrics are the Mac's alone.
//

#if os(macOS)
import AppKit
import CoreText
#endif
import Foundation

struct ReplyPreview: Equatable, Identifiable, Sendable {
    enum Outcome: Equatable, Sendable { case answered, failed, refused }

    /// The assistant message the preview comes from.
    let id: UUID
    let outcome: Outcome
    let text: String

    init(id: UUID, outcome: Outcome, text: String) {
        self.id = id
        self.outcome = outcome
        self.text = text
    }

    /// A preview of a finished assistant reply: complete → the answer's first line ("Reply ready" when it
    /// has none); failed / refused → the user-facing copy. nil for user messages, replies still streaming
    /// and cancelled replies (a closed notch can't be stopped by the user, so a cancel needs no preview).
    static func make(from message: ChatMessage) -> ReplyPreview? {
        guard message.role == .assistant else { return nil }
        switch message.state {
        case .complete:
            return ReplyPreview(id: message.id, outcome: .answered, text: ReplyPreviewText.firstLine(of: message.text))
        case .failed(let copy):
            return ReplyPreview(id: message.id, outcome: .failed, text: ReplyPreviewText.firstLine(of: copy))
        case .refused(let copy):
            return ReplyPreview(id: message.id, outcome: .refused, text: ReplyPreviewText.firstLine(of: copy))
        case .streaming, .cancelled:
            return nil
        }
    }
}

/// Markdown → the first readable line, as plain text.
enum ReplyPreviewText {
    /// Shown when a reply has no prose at all.
    static let emptyReply = "Reply ready"
    /// Shown when a reply's only content is fenced code.
    static let codeOnlyReply = "Reply with code"

    /// First prose line of a Markdown reply as plain text. Skips blank lines, rules, table separators and
    /// fenced code ("Reply with code" if that's all there is); strips heading, quote, list and task
    /// markers, `**` `__` `*` `_` `` ` `` `~~`; `[text](url)` → text, `![alt](url)` → nothing, HTML tags
    /// removed; cleaned by `DisplayText` (controls, bidi, whitespace runs). Longer than `limit` characters →
    /// cut on a word boundary with "…". No prose → "Reply ready".
    static func firstLine(of markdown: String, limit: Int = 140) -> String {
        guard limit > 0 else { return "" }
        var isInFence = false
        var sawCode = false

        for rawLine in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if isFence(line) {
                isInFence.toggle()
                continue
            }
            if isInFence {
                if !line.isEmpty { sawCode = true }
                continue
            }
            if isRule(line) || isTableSeparator(line) { continue }
            let text = DisplayText.sanitized(plainText(ofLine: line), maxLength: Int.max)
            if !text.isEmpty { return truncated(text, limit: limit) }
        }
        return truncated(sawCode ? codeOnlyReply : emptyReply, limit: limit)
    }

    // MARK: - Private

    private static func isFence(_ line: String) -> Bool {
        line.hasPrefix("```") || line.hasPrefix("~~~")
    }

    /// `---`, `***`, `___` (spaces allowed), three or more of one character.
    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// `| --- | :---: |` and friends.
    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        return line.allSatisfy { "|-: ".contains($0) }
    }

    /// At most `limit` characters (grapheme clusters, so emoji and CJK are never split): cut at the last
    /// word boundary in the second half of the allowance, else mid-word, and end with "…".
    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let kept = text.prefix(limit - 1)
        if let space = kept.lastIndex(where: \.isWhitespace),
           kept.distance(from: kept.startIndex, to: space) >= (limit - 1) / 2 {
            return kept[..<space].trimmingCharacters(in: .whitespaces) + "…"
        }
        return kept.trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func plainText(ofLine line: String) -> String {
        var result = String(stripBlockPrefixes(Substring(line)))
        result = replaceLinksImagesAndTags(in: result)
        result = stripInlineMarkers(in: result)
        return result
    }

    /// Headings, block quotes, list bullets, ordered-list numbers and task boxes, in any nesting.
    private static func stripBlockPrefixes(_ line: Substring) -> Substring {
        var text = line
        var changed = true
        while changed {
            changed = false
            let trimmed = text.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.count != text.count { text = trimmed; changed = true }

            if text.hasPrefix(">") {
                text = text.dropFirst()
                changed = true
                continue
            }
            let hashes = text.prefix(while: { $0 == "#" })
            if !hashes.isEmpty, hashes.count <= 6 {
                let rest = text.dropFirst(hashes.count)
                if rest.isEmpty || rest.first == " " {
                    text = rest
                    changed = true
                    continue
                }
            }
            if let first = text.first, "-*+".contains(first), text.dropFirst().first == " " {
                text = text.dropFirst(2)
                changed = true
                continue
            }
            let digits = text.prefix(while: \.isNumber)
            if !digits.isEmpty, digits.count <= 9 {
                let rest = text.dropFirst(digits.count)
                if let marker = rest.first, marker == "." || marker == ")", rest.dropFirst().first == " " {
                    text = rest.dropFirst(2)
                    changed = true
                    continue
                }
            }
            for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) {
                text = text.dropFirst(box.count)
                changed = true
                break
            }
        }
        // A heading's closing hashes ("## Title ##").
        var trailing = text
        while trailing.hasSuffix("#") { trailing = trailing.dropLast() }
        if trailing.count != text.count, trailing.hasSuffix(" ") { text = trailing }
        return text
    }

    /// `![alt](url)` → nothing, `[text](url)` → text, `<https://…>` → the address, other `<tags>` removed.
    private static func replaceLinksImagesAndTags(in line: String) -> String {
        var output = ""
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            let isImage = character == "!" && next < line.endIndex && line[next] == "["
            let openBracket = isImage ? next : index
            if isImage || character == "[",
               let closeBracket = line[openBracket...].firstIndex(of: "]"),
               line.index(after: closeBracket) < line.endIndex,
               line[line.index(after: closeBracket)] == "(",
               let closeParen = line[closeBracket...].firstIndex(of: ")") {
                if !isImage { output += line[line.index(after: openBracket)..<closeBracket] }
                index = line.index(after: closeParen)
                continue
            }
            if character == "<", let close = line[index...].firstIndex(of: ">") {
                let inner = line[next..<close]
                if inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:") {
                    output += inner
                    index = line.index(after: close)
                    continue
                }
                if let first = inner.first, first.isLetter || first == "/" || first == "!" {
                    index = line.index(after: close)
                    continue
                }
            }
            output.append(character)
            index = next
        }
        return output
    }

    /// Emphasis (`**`, `__`, `*`, `_` at word edges), strikethrough and inline-code ticks.
    private static func stripInlineMarkers(in line: String) -> String {
        var text = line
        for marker in ["**", "__", "~~", "`"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        let characters = Array(text)
        var output = ""
        for (offset, character) in characters.enumerated() {
            if character == "*" || character == "_" {
                let before = offset > 0 ? characters[offset - 1] : " "
                let after = offset + 1 < characters.count ? characters[offset + 1] : " "
                let opens = !before.isLetter && !before.isNumber && !after.isWhitespace
                let closes = !after.isLetter && !after.isNumber && !before.isWhitespace
                if opens || closes { continue }
            }
            output.append(character)
        }
        return output
    }
}

#if os(macOS)
/// Size and timing of the reply-preview drop (§4.2 shape rules).
enum ReplyPreviewMetrics {
    static let dropHeight: CGFloat = 28
    static let maxWidth: CGFloat = 380
    static let horizontalPadding: CGFloat = 16
    static let visibleDuration: Duration = .seconds(4)
    static let resumeMinimum: Duration = .milliseconds(1500)

    /// The drop's text size, and its leading outcome icon and the gap after it (glance.md §1.3).
    static let fontSize: CGFloat = 12.5
    static let iconSize: CGFloat = 11
    static let iconSpacing: CGFloat = 6

    /// icon 11 + gap 6 + text (system 12.5 pt) + 2 × 16 padding + 2 × `closedTopRadius`. Not capped;
    /// `ClosedNotchLayout` caps it at `maxWidth`.
    @MainActor static func idealWidth(for text: String) -> CGFloat {
        measuredIdealWidth(for: text)
    }

    /// `idealWidth` without actor isolation (Core Text measurement is thread-safe), for pure layout code.
    static func measuredIdealWidth(for text: String) -> CGFloat {
        let chrome = iconSize + iconSpacing + horizontalPadding * 2 + NotchMetrics.closedTopRadius * 2
        guard !text.isEmpty else { return ceil(chrome) }
        let font = NSFont.systemFont(ofSize: fontSize)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return ceil(chrome + textWidth)
    }
}
#endif
