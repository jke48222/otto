//
//  MarkdownText.swift
//  Otto
//
//  A small block-level Markdown renderer tuned for streamed chat replies: headings, paragraphs,
//  nested lists, quotes, fenced code, simple tables and rules. Inline formatting is delegated to
//  `AttributedString(markdown:)`. Parsing tolerates partial input (an unclosed fence renders as code,
//  an unclosed `**`/`` ` ``/link is healed in the streaming tail). While a reply streams, only the
//  blocks after the last settled block boundary are re-parsed on each delta, and settled block views
//  are equatable so SwiftUI skips them; finished messages are parsed once and cached.
//
//  Links: only http(s) and mailto links stay clickable, and they open through `MarkdownLinkPolicy`
//  rather than SwiftUI's default handler (which would hand any scheme — file:, smb:, shortcuts:,
//  custom app schemes — straight to NSWorkspace).
//

import AppKit
import SwiftUI

// MARK: - Block model

enum MarkdownBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case quote([MarkdownBlock])
    case code(language: String?, code: String, isClosed: Bool)
    case table(MarkdownTable)
    case rule
}

struct MarkdownListItem: Hashable {
    enum Marker: Hashable {
        case bullet
        case ordered(Int)
        case task(done: Bool)
    }

    var level: Int
    var marker: Marker
    var text: String
}

struct MarkdownTable: Hashable {
    enum ColumnAlignment: Hashable {
        case leading, center, trailing
    }

    var header: [String]
    var alignments: [ColumnAlignment]
    var rows: [[String]]

    var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }
}

// MARK: - Parser

enum MarkdownParser {
    /// Maximum nesting for block quotes (guards against pathological `>>>>>>…` input).
    static let maxQuoteDepth = 6

    static func parse(_ text: String) -> [MarkdownBlock] {
        var normalized = text
        if text.utf8.contains(UInt8(ascii: "\r")) {
            normalized = normalized
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        }
        if text.utf8.contains(UInt8(ascii: "\t")) {
            normalized = normalized.replacingOccurrences(of: "\t", with: "    ")
        }
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return parse(lines: lines, depth: 0)
    }

    fileprivate static func parse(lines: [String], depth: Int) -> [MarkdownBlock] {
        var parser = MarkdownBlockParser(lines: lines, depth: depth)
        return parser.parseBlocks()
    }

    /// Closes constructs that are still open at the end of a streaming reply so they render
    /// formatted instead of as raw markers (`**bold`, `` `code ``, `[link](htt`). Code spans follow
    /// CommonMark: a backtick run is closed only by a run of the same length, and nothing inside a
    /// code span (brackets, stars) is treated as syntax.
    static func healStreamingTail(_ source: String) -> String {
        var chars = Array(source)

        // 1. Dangling link: "[title](partial-url" → "title"; "[partial title" → "partial title".
        //    A "[" glued to a word ("arr[0") is left alone — it is far more likely a subscript.
        var scan = InlineCodeScan(chars)
        if let open = scan.lastLinkOpener(in: chars) {
            let isImage = open > 0 && chars[open - 1] == "!"
            if let close = scan.firstIndex(of: "]", in: chars, from: open + 1) {
                let after = close + 1
                if after < chars.count, chars[after] == "(", !chars[(after + 1)...].contains(")") {
                    let start = isImage ? open - 1 : open
                    let title = isImage ? [] : Array(chars[(open + 1)..<close])
                    chars.replaceSubrange(start..., with: title)
                }
            } else if !chars[(open + 1)...].contains("(") {
                if isImage {
                    chars.removeSubrange((open - 1)...open)
                } else if open == 0 || !Self.isWordCharacter(chars[open - 1]) {
                    chars.remove(at: open)
                }
            }
        }

        // 2. An open code span: close it with a run of the same length (completing a partially
        //    streamed closing run), or drop an opening run that nothing follows yet.
        scan = InlineCodeScan(chars)
        if let open = scan.openRun {
            let contentStart = open.start + open.length
            if contentStart >= chars.count {
                chars.removeSubrange(open.start...)
            } else {
                var trailing = 0
                var index = chars.count - 1
                while index >= contentStart, chars[index] == "`" {
                    trailing += 1
                    index -= 1
                }
                if trailing < open.length {
                    chars.append(contentsOf: repeatElement(Character("`"), count: open.length - trailing))
                }
            }
        }

        // 3. An unbalanced strong run ("**bold") outside code spans.
        scan = InlineCodeScan(chars)
        let inCode = scan.codeMask(count: chars.count)
        var strongMarkers = 0
        var previousWasStar = false
        var index = 0
        while index < chars.count {
            let character = chars[index]
            if inCode[index] {
                previousWasStar = false
            } else if character == "\\" {
                previousWasStar = false
                index += 1
            } else if character == "*" {
                if previousWasStar {
                    strongMarkers += 1
                    previousWasStar = false
                } else {
                    previousWasStar = true
                }
            } else {
                previousWasStar = false
            }
            index += 1
        }
        if strongMarkers % 2 == 1 {
            if chars.count >= 2, chars[chars.count - 1] == "*", chars[chars.count - 2] == "*" {
                chars.removeLast(2)
            } else {
                // "**bold " → close before trailing spaces so the marker hugs the text.
                while chars.last == " " { chars.removeLast() }
                chars.append(contentsOf: ["*", "*"])
            }
        }
        return String(chars)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    // MARK: Streaming split points

    /// The start of the last split point in `text[start...]` (see `MarkdownSplitScanner`), or nil.
    /// `start` must itself be a split point or the start of the text.
    static func lastSafeSplit(in text: String, from start: String.Index) -> String.Index? {
        var scanner = MarkdownSplitScanner(offset: text.utf8.distance(from: text.utf8.startIndex, to: start))
        return scanner.advance(in: text)
    }
}

/// Finds the points where a streaming reply's parse can be split: everything before such a point
/// parses to exactly the same blocks on its own as it does as part of the whole text, and the parse
/// from it onward starts fresh at the top level. A split point is the start of a complete, non-blank
/// line that follows a blank line outside any code fence and cannot continue a list (not a list item,
/// not indented as an item continuation). The scan is resumable, so each delta only scans the lines
/// it completed — even deep inside a long code fence, where there is no split point to settle on.
struct MarkdownSplitScanner {
    /// UTF-8 offset of the first line not scanned yet (always a line start).
    private(set) var offset: Int
    private var openFence: CodeFence?
    private var previousWasBlank = false

    init(offset: Int = 0) {
        self.offset = offset
    }

    /// Scans the complete lines of `text` after `offset`, which must extend the text scanned so far,
    /// and returns the last split point among them. The last, unterminated line is left for later:
    /// it may still change what it is.
    mutating func advance(in text: String) -> String.Index? {
        let utf8 = text.utf8
        guard offset <= utf8.count else { return nil }
        var result: String.Index?
        var lineStart = utf8.index(utf8.startIndex, offsetBy: offset)
        while lineStart < utf8.endIndex, let newline = utf8[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
            guard let line = Self.normalizedLine(text[lineStart..<newline]) else {
                // A bare carriage return is a line break for the parser but not for this scan; stop
                // for good rather than risk splitting inside a block.
                break
            }
            if let fence = openFence {
                if fence.isClosed(by: line) { openFence = nil }
                previousWasBlank = false
            } else if line.markdownIsBlank {
                previousWasBlank = true
            } else {
                let fence = CodeFence(line: line)
                if previousWasBlank, MarkdownBlockParser.listItem(in: line) == nil,
                   line.markdownIndent < 2 || fence != nil {
                    result = lineStart
                }
                openFence = fence
                previousWasBlank = false
            }
            lineStart = utf8.index(after: newline)
            offset = utf8.distance(from: utf8.startIndex, to: lineStart)
        }
        return result
    }

    /// A raw line normalized the way `parse` normalizes it (tabs → 4 spaces, CRLF → LF), or nil when
    /// it contains a bare carriage return.
    private static func normalizedLine(_ raw: Substring) -> String? {
        var line = String(raw)
        if line.utf8.last == UInt8(ascii: "\r") { line.unicodeScalars.removeLast() }
        if line.utf8.contains(UInt8(ascii: "\r")) { return nil }
        if line.utf8.contains(UInt8(ascii: "\t")) { line = line.replacingOccurrences(of: "\t", with: "    ") }
        return line
    }
}

/// CommonMark code spans in one run of inline text: a backtick run opens a span that only a run of
/// exactly the same length closes. The first opening run without a closer is treated as a span that
/// is still streaming, so everything after it is code.
private struct InlineCodeScan {
    /// Closed spans, delimiters included.
    private(set) var closed: [Range<Int>] = []
    /// The unclosed opening run, if any.
    private(set) var openRun: (start: Int, length: Int)?

    init(_ chars: [Character]) {
        let count = chars.count
        var index = 0
        while index < count {
            let character = chars[index]
            if character == "\\" {
                // A backslash escapes the next character outside code spans ("\`" is a literal tick).
                index += 2
                continue
            }
            guard character == "`" else {
                index += 1
                continue
            }
            let start = index
            while index < count, chars[index] == "`" { index += 1 }
            let length = index - start

            var probe = index
            var closeEnd: Int?
            while probe < count {
                guard chars[probe] == "`" else {
                    probe += 1
                    continue
                }
                let runStart = probe
                while probe < count, chars[probe] == "`" { probe += 1 }
                if probe - runStart == length {
                    closeEnd = probe
                    break
                }
            }
            guard let closeEnd else {
                openRun = (start, length)
                return
            }
            closed.append(start..<closeEnd)
            index = closeEnd
        }
    }

    /// `true` for every character inside a code span (closed or still open), delimiters included.
    func codeMask(count: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: count)
        for range in closed {
            for index in range where index < count { mask[index] = true }
        }
        if let openRun {
            for index in openRun.start..<max(openRun.start, count) { mask[index] = true }
        }
        return mask
    }

    /// The last unescaped "[" outside code spans.
    func lastLinkOpener(in chars: [Character]) -> Int? {
        let mask = codeMask(count: chars.count)
        var index = chars.count - 1
        while index >= 0 {
            if chars[index] == "[", !mask[index], index == 0 || chars[index - 1] != "\\" {
                return index
            }
            index -= 1
        }
        return nil
    }

    /// The first `character` at or after `start` that is outside code spans.
    func firstIndex(of character: Character, in chars: [Character], from start: Int) -> Int? {
        guard start < chars.count else { return nil }
        let mask = codeMask(count: chars.count)
        for index in start..<chars.count where chars[index] == character && !mask[index] {
            return index
        }
        return nil
    }
}

private struct MarkdownBlockParser {
    let lines: [String]
    let depth: Int
    var index = 0

    init(lines: [String], depth: Int) {
        self.lines = lines
        self.depth = depth
    }

    mutating func parseBlocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        while index < lines.count {
            let line = lines[index]
            if line.markdownIsBlank {
                index += 1
                continue
            }
            if let fence = CodeFence(line: line) {
                blocks.append(parseCode(fence: fence))
            } else if let heading = Self.heading(in: line) {
                index += 1
                if !heading.text.isEmpty { blocks.append(.heading(level: heading.level, text: heading.text)) }
            } else if Self.isRule(line) {
                index += 1
                blocks.append(.rule)
            } else if Self.quoteContent(of: line) != nil, depth < MarkdownParser.maxQuoteDepth {
                blocks.append(parseQuote())
            } else if Self.listItem(in: line) != nil {
                blocks.append(parseList())
            } else if isTableStart(at: index) {
                blocks.append(parseTable())
            } else {
                blocks.append(parseParagraph())
            }
        }
        return blocks
    }

    // MARK: Code

    private mutating func parseCode(fence: CodeFence) -> MarkdownBlock {
        index += 1
        var body: [String] = []
        var isClosed = false
        while index < lines.count {
            let line = lines[index]
            index += 1
            if fence.isClosed(by: line) {
                isClosed = true
                break
            }
            body.append(Self.removingIndent(fence.indent, from: line))
        }
        let language = fence.info.split(separator: " ").first.map(String.init)
        return .code(language: language, code: body.joined(separator: "\n"), isClosed: isClosed)
    }

    // MARK: Quote

    private mutating func parseQuote() -> MarkdownBlock {
        var content: [String] = []
        while index < lines.count, let inner = Self.quoteContent(of: lines[index]) {
            content.append(inner)
            index += 1
        }
        return .quote(MarkdownParser.parse(lines: content, depth: depth + 1))
    }

    // MARK: List

    private mutating func parseList() -> MarkdownBlock {
        var items: [MarkdownListItem] = []
        var indentStack: [Int] = []

        while index < lines.count {
            let line = lines[index]

            if line.markdownIsBlank {
                var next = index + 1
                while next < lines.count, lines[next].markdownIsBlank { next += 1 }
                guard next < lines.count, !items.isEmpty else { break }
                let nextLine = lines[next]
                if Self.listItem(in: nextLine) != nil {
                    index = next
                    continue
                }
                // An indented paragraph after a blank line belongs to the previous item.
                if nextLine.markdownIndent >= 2, CodeFence(line: nextLine) == nil {
                    items[items.count - 1].text += "\n" + nextLine.trimmingCharacters(in: .whitespaces)
                    index = next + 1
                    continue
                }
                break
            }

            if let match = Self.listItem(in: line) {
                let level = Self.resolveLevel(indent: match.indent, stack: &indentStack)
                items.append(MarkdownListItem(level: level, marker: match.marker, text: match.content))
                index += 1
                continue
            }

            // Other block starts end the list (a fenced block inside an item renders full width).
            if CodeFence(line: line) != nil || Self.heading(in: line) != nil || Self.isRule(line)
                || Self.quoteContent(of: line) != nil || items.isEmpty {
                break
            }

            // Continuation line (indented or lazy) of the previous item.
            items[items.count - 1].text += "\n" + line.trimmingCharacters(in: .whitespaces)
            index += 1
        }
        return .list(items)
    }

    /// Maps raw indentation to a nesting level relative to the enclosing items.
    private static func resolveLevel(indent: Int, stack: inout [Int]) -> Int {
        while let last = stack.last, last > indent { stack.removeLast() }
        if let last = stack.last {
            if indent > last + 1 { stack.append(indent) }
        } else {
            stack.append(indent)
        }
        return max(0, stack.count - 1)
    }

    // MARK: Table

    private func isTableStart(at position: Int) -> Bool {
        guard position + 1 < lines.count else { return false }
        return lines[position].contains("|") && Self.isTableSeparator(lines[position + 1])
    }

    private mutating func parseTable() -> MarkdownBlock {
        let header = Self.tableCells(lines[index])
        let alignments = Self.tableCells(lines[index + 1]).map { cell -> MarkdownTable.ColumnAlignment in
            let leading = cell.hasPrefix(":")
            let trailing = cell.hasSuffix(":")
            if leading && trailing { return .center }
            return trailing ? .trailing : .leading
        }
        index += 2
        var rows: [[String]] = []
        while index < lines.count, !lines[index].markdownIsBlank, lines[index].contains("|") {
            rows.append(Self.tableCells(lines[index]))
            index += 1
        }
        return .table(MarkdownTable(header: header, alignments: alignments, rows: rows))
    }

    private static func tableCells(_ line: String) -> [String] {
        let placeholder = "\u{0}"
        var trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: placeholder)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: placeholder, with: "|") }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") else { return false }
        let cells = tableCells(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            var body = Substring(cell)
            if body.hasPrefix(":") { body = body.dropFirst() }
            if body.hasSuffix(":") { body = body.dropLast() }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    // MARK: Paragraph

    private mutating func parseParagraph() -> MarkdownBlock {
        var collected: [String] = [lines[index].trimmingCharacters(in: .whitespaces)]
        index += 1
        while index < lines.count {
            let line = lines[index]
            if line.markdownIsBlank || CodeFence(line: line) != nil || Self.heading(in: line) != nil || Self.isRule(line)
                || Self.quoteContent(of: line) != nil || Self.listItemInterruptsParagraph(line) || isTableStart(at: index) {
                break
            }
            collected.append(line.trimmingCharacters(in: .whitespaces))
            index += 1
        }
        return .paragraph(collected.joined(separator: "\n"))
    }

    /// CommonMark: a list item interrupts a paragraph only if it has content, and an ordered one only
    /// if it starts at 1 — so "The year was\n2024. It was great." stays one paragraph.
    fileprivate static func listItemInterruptsParagraph(_ line: String) -> Bool {
        guard let match = listItem(in: line), !match.content.markdownIsBlank else { return false }
        if case .ordered(let number) = match.marker { return number == 1 }
        return true
    }

    // MARK: Line classifiers

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let indent = line.markdownIndent
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        let hashes = rest.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let afterHashes = rest.dropFirst(hashes)
        guard afterHashes.isEmpty || afterHashes.first == " " else { return nil }
        var text = afterHashes.trimmingCharacters(in: .whitespaces)
        // Optional closing sequence: "## Title ##".
        if let range = text.range(of: "\\s+#+$", options: .regularExpression) {
            text.removeSubrange(range)
        } else if text.allSatisfy({ $0 == "#" }) {
            text = ""
        }
        return (hashes, text)
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func quoteContent(of line: String) -> String? {
        let indent = line.markdownIndent
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard rest.first == ">" else { return nil }
        var inner = rest.dropFirst()
        if inner.first == " " { inner = inner.dropFirst() }
        return String(inner)
    }

    fileprivate struct ListMatch {
        let indent: Int
        let marker: MarkdownListItem.Marker
        let content: String
    }

    fileprivate static func listItem(in line: String) -> ListMatch? {
        let indent = line.markdownIndent
        let rest = line.dropFirst(indent)
        guard let first = rest.first else { return nil }

        if first == "-" || first == "*" || first == "+" {
            let afterMarker = rest.dropFirst()
            guard afterMarker.isEmpty || afterMarker.first == " " else { return nil }
            var content = afterMarker.drop(while: { $0 == " " })
            var marker = MarkdownListItem.Marker.bullet
            if content.hasPrefix("[ ]") {
                marker = .task(done: false)
                content = content.dropFirst(3).drop(while: { $0 == " " })
            } else if content.hasPrefix("[x]") || content.hasPrefix("[X]") {
                marker = .task(done: true)
                content = content.dropFirst(3).drop(while: { $0 == " " })
            }
            return ListMatch(indent: indent, marker: marker, content: String(content))
        }

        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard (1...9).contains(digits.count) else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
        let afterDelimiter = afterDigits.dropFirst()
        guard afterDelimiter.isEmpty || afterDelimiter.first == " " else { return nil }
        let number = Int(digits) ?? 1
        let content = afterDelimiter.drop(while: { $0 == " " })
        return ListMatch(indent: indent, marker: .ordered(number), content: String(content))
    }

    private static func removingIndent(_ count: Int, from line: String) -> String {
        guard count > 0 else { return line }
        let removable = min(count, line.markdownIndent)
        return String(line.dropFirst(removable))
    }
}

/// An opening code fence (``` or ~~~, optionally indented, with an info string).
private struct CodeFence {
    let character: Character
    let length: Int
    let indent: Int
    let info: String

    init?(line: String) {
        let indent = line.markdownIndent
        let rest = line.dropFirst(indent)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let run = rest.prefix(while: { $0 == first }).count
        guard run >= 3 else { return nil }
        let info = rest.dropFirst(run).trimmingCharacters(in: .whitespaces)
        // ```inline``` on one line is inline code, not a fence.
        if first == "`" && info.contains("`") { return nil }
        self.character = first
        self.length = run
        self.indent = indent
        self.info = info
    }

    func isClosed(by line: String) -> Bool {
        // Fast path for the common case (a code line): its first non-space character decides.
        guard line.first(where: { $0 != " " }) == character else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= length && trimmed.allSatisfy { $0 == character }
    }
}

private extension String {
    var markdownIsBlank: Bool { allSatisfy { $0 == " " || $0 == "\t" } }
    var markdownIndent: Int { prefix(while: { $0 == " " }).count }
}

// MARK: - Link policy

/// Which Markdown links stay clickable, and how they open. A reply can carry links the model copied
/// from a page it read (prompt injection), and SwiftUI's default `openURL` hands *any* scheme to
/// NSWorkspace — `file:` launches apps, `smb:` mounts shares (sending credentials), `shortcuts:` runs
/// Shortcuts, custom schemes drive other apps — on a single click, with the target hidden behind the
/// link text. Only web and mail links are kept; every other link renders as plain text, and the
/// handler refuses anything else that reaches it.
enum MarkdownLinkPolicy {
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else { return false }
        if scheme == "mailto" { return true }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return false }
        return true
    }

    /// Installed as the `openURL` action of every `MarkdownText`.
    static var openURLAction: OpenURLAction {
        OpenURLAction { url in
            guard isAllowed(url) else { return .discarded }
            return NSWorkspace.shared.open(url) ? .handled : .discarded
        }
    }
}

// MARK: - Cache

/// Caches parsed blocks per finished message and styled inline strings per source. A streaming
/// reply is parsed incrementally instead: the blocks before its last settled block boundary are
/// kept and only the text after it is re-parsed on each delta.
@MainActor
final class MarkdownCache {
    static let shared = MarkdownCache()

    private final class BlocksBox {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    private final class InlineBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    /// Incremental parse state of one streaming reply.
    private struct StreamingParse {
        /// The latest text seen, kept to verify that the next text extends it.
        var source: String
        /// UTF-8 length of the settled prefix of `source` (a split point).
        var settledLength = 0
        /// Blocks of the settled prefix.
        var settledBlocks: [MarkdownBlock] = []
        /// Split-point scan of `source`, resumed on the next delta.
        var scanner = MarkdownSplitScanner()

        /// How much of `source` this state depends on (the scanner never lags the settled prefix).
        var verifiedLength: Int { scanner.offset }
    }

    private let blockCache = NSCache<NSString, BlocksBox>()
    private let inlineCache = NSCache<NSString, InlineBox>()
    /// Most recent first. More than one only matters when several streaming texts render at once.
    private var streams: [StreamingParse] = []
    /// The healed tail of the streaming reply. It changes on every delta, so it gets one slot that
    /// is overwritten rather than an entry in `inlineCache`.
    private var tailSlot: (source: String, codeSize: CGFloat, strongSize: CGFloat?, value: AttributedString)?
    /// Incremental styling of the streaming tail block (see `streamingInline`). One slot, like `tailSlot`.
    private var streamingSlot: StreamingInline?

    /// The styled tail of a streaming reply, split in two: the settled prefix (whole lines or sentences whose
    /// inline syntax is all closed, styled once) and the unsettled rest (healed and styled on every delta).
    ///
    /// The settled prefix has a firm part and, after it, an optional provisional part: chunks that leave an emphasis
    /// or strikethrough run open ("takes ~5 minutes", "2*3") that later text could still close. A provisional chunk
    /// styles the same on its own as it does followed by any text without one of its open delimiter characters, so it
    /// stays settled until such a character arrives; then the settled prefix falls back to the firm part.
    private struct StreamingInline {
        var codeSize: CGFloat
        var strongSize: CGFloat?
        /// The latest source seen; the next one must extend it for the slot to be reused.
        var source: String
        var value: AttributedString
        /// UTF-8 length of the settled prefix of `source` (just after a line break or a sentence's space).
        var settledLength = 0
        var settledStyled = AttributedString()
        /// UTF-8 length up to which settling was last tried and refused (an open construct spans it).
        var attemptedLength = 0
        /// The part of the settled prefix no later text can change (`settledLength` when nothing is provisional).
        var firmLength = 0
        var firmStyled = AttributedString()
        /// Delimiter bytes (`*`, `_`, `~`) left open by the provisional chunks; empty = nothing provisional.
        var openDelimiters: Set<UInt8> = []
        /// UTF-8 length of `source` already checked for `openDelimiters`.
        var checkedLength = 0
    }

    /// How much newly completed text a streaming block collects before its lines are settled. Settling styles
    /// that stretch once; below it, re-styling the few unsettled lines on every delta costs less than trying.
    static let settleChunkLength = 1024

    private static let maxStreams = 4

    init() {
        blockCache.countLimit = 200
        blockCache.totalCostLimit = 4_000_000
        inlineCache.countLimit = 3000
        inlineCache.totalCostLimit = 2_000_000
    }

    func blocks(for text: String, streaming: Bool) -> [MarkdownBlock] {
        if streaming { return streamingBlocks(for: text) }
        let key = text as NSString
        if let hit = blockCache.object(forKey: key) { return hit.blocks }
        let blocks = MarkdownParser.parse(text)
        blockCache.setObject(BlocksBox(blocks), forKey: key, cost: text.utf8.count)
        return blocks
    }

    /// Styled inline Markdown. Pass `cacheable: false` for text that is only ever seen once (the
    /// healed tail of a streaming reply) so it does not fill the cache and evict settled entries.
    ///
    /// `strongSize`, when set, renders `**strong**` runs semibold at that size instead of the
    /// default (heavier) bold.
    func inline(_ source: String, codeSize: CGFloat, strongSize: CGFloat? = nil, cacheable: Bool = true) -> AttributedString {
        guard cacheable else {
            if let slot = tailSlot, slot.codeSize == codeSize, slot.strongSize == strongSize, slot.source == source {
                return slot.value
            }
            let value = Self.styledInline(source, codeSize: codeSize, strongSize: strongSize)
            tailSlot = (source, codeSize, strongSize, value)
            return value
        }
        let key = "\(codeSize)\u{1}\(strongSize ?? 0)\u{1}\(source)" as NSString
        if let hit = inlineCache.object(forKey: key) { return hit.value }
        let value = Self.styledInline(source, codeSize: codeSize, strongSize: strongSize)
        inlineCache.setObject(InlineBox(value), forKey: key, cost: source.utf8.count)
        return value
    }

    /// The healed, styled tail block of a streaming reply (what `inline(healStreamingTail(source), …,
    /// cacheable: false)` returns), without re-styling the whole block on every delta: completed lines whose
    /// inline syntax is all closed are styled once and kept, so each delta heals and styles only the lines
    /// after them. A long block (a log or a poem is one paragraph) otherwise costs O(n) per delta.
    func streamingInline(_ source: String, codeSize: CGFloat, strongSize: CGFloat? = nil) -> AttributedString {
        var slot: StreamingInline
        // Reuse the slot only for the same block grown further: a new block (or a retry) starts over, so it never
        // inherits another block's settled prefix or its refused attempts.
        if let existing = streamingSlot, existing.codeSize == codeSize, existing.strongSize == strongSize,
           Self.sharePrefix(source, existing.source, length: existing.source.utf8.count) {
            if existing.source.utf8.count == source.utf8.count { return existing.value }
            slot = existing
        } else {
            slot = StreamingInline(codeSize: codeSize, strongSize: strongSize, source: source, value: AttributedString())
        }
        let utf8 = source.utf8
        if !slot.openDelimiters.isEmpty {
            // A character that could close a provisional chunk's open run arrived: only the firm part stays.
            let from = utf8.index(utf8.startIndex, offsetBy: max(slot.checkedLength, slot.settledLength))
            if utf8[from...].contains(where: slot.openDelimiters.contains) {
                slot.settledLength = slot.firmLength
                slot.settledStyled = slot.firmStyled
                slot.openDelimiters = []
                slot.attemptedLength = slot.firmLength
            }
        }
        slot.checkedLength = utf8.count
        var settledEnd = utf8.index(utf8.startIndex, offsetBy: slot.settledLength)
        if let candidate = Self.lastSettleCandidate(in: utf8[settledEnd...]) {
            let candidateLength = utf8.distance(from: utf8.startIndex, to: candidate)
            if candidateLength - max(slot.settledLength, slot.attemptedLength) >= Self.settleChunkLength {
                let raw = source[settledEnd..<candidate]
                if settle(raw, upTo: candidate, in: source, slot: &slot) {
                    settledEnd = candidate
                } else {
                    slot.attemptedLength = candidateLength
                }
            }
        }
        let rest = MarkdownParser.healStreamingTail(String(source[settledEnd...]))
        let restStyled = Self.styledInline(rest, codeSize: codeSize, strongSize: strongSize)
        slot.value = slot.settledLength == 0 ? restStyled : slot.settledStyled + restStyled
        slot.source = source
        streamingSlot = slot
        return slot.value
    }

    /// Settles `raw` (the text from the settled prefix up to `candidate`) firmly when nothing in it is open, or
    /// provisionally when only emphasis or strikethrough runs are and no text after it holds their characters yet.
    private func settle(_ raw: Substring, upTo candidate: String.Index, in source: String,
                        slot: inout StreamingInline) -> Bool {
        // Escapes draw literals whose source neighbors differ; and the healer must leave the chunk as it is (no odd
        // `**` or open code span for it to close at the end of the whole text).
        guard !Self.hasEscapes(raw), MarkdownParser.healStreamingTail(String(raw)) == String(raw) else { return false }
        let chunk = Self.styledInline(String(raw), codeSize: slot.codeSize, strongSize: slot.strongSize)
        guard let open = Self.openDelimiters(in: chunk) else { return false }
        let openBytes = slot.openDelimiters.union(open.map { UInt8(ascii: $0.unicodeScalars.first!) })
        guard Self.closesNothing(after: raw, styled: chunk, except: openBytes, codeSize: slot.codeSize,
                                 strongSize: slot.strongSize) else { return false }
        let length = source.utf8.distance(from: source.utf8.startIndex, to: candidate)
        if openBytes.isEmpty {
            slot.firmStyled += chunk
            slot.firmLength = length
        } else {
            // Nothing after it may close its open runs yet.
            guard !source.utf8[candidate...].contains(where: openBytes.contains) else { return false }
            slot.openDelimiters = openBytes
        }
        slot.settledStyled += chunk
        slot.settledLength = length
        return true
    }

    /// The latest point in `text` that settling may end at: just after a line break, after the space that follows
    /// a sentence's period (a paragraph can be one long line), or after an ideographic full stop, exclamation or
    /// question mark (CJK text has no spaces). The text after it starts fresh, after whitespace or punctuation,
    /// as it would on its own.
    private static func lastSettleCandidate(in text: Substring.UTF8View) -> String.Index? {
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            let byte = text[previous]
            if byte == UInt8(ascii: "\n") { return index }
            if byte == UInt8(ascii: " "), previous > text.startIndex,
               text[text.index(before: previous)] == UInt8(ascii: "."), index < text.endIndex {
                return index
            }
            if Self.endsCJKSentence(text, at: index) { return index }
            index = previous
        }
        return nil
    }

    /// Whether the three UTF-8 bytes before `index` are "。" (E3 80 82), "！" (EF BC 81) or "？" (EF BC 9F).
    private static func endsCJKSentence(_ text: Substring.UTF8View, at index: String.Index) -> Bool {
        guard text.distance(from: text.startIndex, to: index) >= 3 else { return false }
        let third = text.index(before: index)
        let second = text.index(before: third)
        let first = text.index(before: second)
        switch (text[first], text[second], text[third]) {
        case (0xE3, 0x80, 0x82), (0xEF, 0xBC, 0x81), (0xEF, 0xBC, 0x9F): return true
        default: return false
        }
    }

    /// UTF-8 length of the settled prefix of the streaming tail (tests).
    var settledStreamingLength: Int { streamingSlot?.settledLength ?? 0 }

    /// Whether nothing in styled inline text can still pair with text that follows it, so text before a line break
    /// that passes styles the same on its own as it does followed by anything (see `openDelimiters(in:)`).
    static func isSettledInline(_ styled: AttributedString) -> Bool {
        openDelimiters(in: styled)?.isEmpty == true
    }

    /// What in styled inline text could still pair with text that follows it. Later text can only close what is
    /// still open, so only literal openers matter (code spans excluded). nil: a backtick run (a code span) or a `[`
    /// (a link) is open, or a `]` is followed by `(` or `[`. Otherwise the characters of the `*`, `_` and `~` runs
    /// that are not followed by whitespace (a run followed by whitespace can't open emphasis; an `_` between letters
    /// or digits can't either); empty when there are none. A `[` closed by a later literal `]` (a citation like "[1]")
    /// can't become a link any more. Unmatched closers are harmless. Callers also rule out escapes and character
    /// references (`hasEscapes`), whose literals have other neighbors in the source.
    static func openDelimiters(in styled: AttributedString) -> Set<Character>? {
        var characters: [Character] = []
        var inCode: [Bool] = []
        var inLink: [Bool] = []
        for run in styled.runs {
            let isCode = run.inlinePresentationIntent?.contains(.code) == true
            let isLink = run.link != nil
            for character in styled[run.range].characters {
                characters.append(character)
                inCode.append(isCode)
                inLink.append(isLink)
            }
        }
        var open: Set<Character> = []
        var openBrackets = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard !inCode[index] else {
                index += 1
                continue
            }
            switch character {
            case "`":
                return nil
            case "[" where !inLink[index]:
                openBrackets += 1
                index += 1
            case "]" where !inLink[index]:
                if openBrackets > 0 {
                    openBrackets -= 1
                    let next = index + 1 < characters.count ? characters[index + 1] : nil
                    if next == "(" || next == "[" { return nil }
                }
                index += 1
            case "*", "_", "~":
                var runEnd = index + 1
                while runEnd < characters.count, characters[runEnd] == character, !inCode[runEnd] { runEnd += 1 }
                // A neighbor inside a code span stood next to a backtick in the source, never whitespace.
                let before = index > 0 && !inCode[index - 1] ? characters[index - 1] : nil
                let after = runEnd < characters.count && !inCode[runEnd] ? characters[runEnd] : nil
                let followedBySpace = runEnd == characters.count || after?.isWhitespace == true
                let intraword = character == "_" && (before.map { $0.isLetter || $0.isNumber } ?? false)
                    && (after.map { $0.isLetter || $0.isNumber } ?? false)
                if !followedBySpace && !intraword { open.insert(character) }
                index = runEnd
            default:
                index += 1
            }
        }
        return openBrackets == 0 ? open : nil
    }

    /// Closers of every kind and length, one per word: emphasis and strikethrough runs, then a link's end.
    private static let closerProbeWords = ["x***", "x**", "x*", "x___", "x__", "x_", "x~~", "x~", "x](u)"]

    /// The check behind `openDelimiters(in:)`'s reading of the rendered text: `raw` followed by a line of closers
    /// styles as the two styled apart, so no opener in `raw` (one whose source neighbors the rendered text hides,
    /// such as `**[](url)`) pairs with later text. Closers made of `except` bytes are left out of the line: the
    /// caller already knows those runs are open.
    private static func closesNothing(after raw: Substring, styled: AttributedString, except: Set<UInt8> = [],
                                      codeSize: CGFloat, strongSize: CGFloat?) -> Bool {
        let words = closerProbeWords.filter { word in !word.utf8.dropFirst().contains(where: except.contains) }
        let probe = words.joined(separator: " ")
        let probeStyled = styledInline(probe, codeSize: codeSize, strongSize: strongSize)
        return styledInline(String(raw) + probe, codeSize: codeSize, strongSize: strongSize) == styled + probeStyled
    }

    /// Whether `text` holds a backslash escape of punctuation or a character reference (`&#42;`, `&ast;`). Either
    /// draws a literal character whose neighbors in the source differ from those `isSettledInline` sees, so a
    /// chunk holding one is never settled (it stays in the part re-styled on each delta).
    static func hasEscapes(_ text: Substring) -> Bool {
        let bytes = Array(text.utf8)
        for (index, byte) in bytes.enumerated() {
            if byte == UInt8(ascii: "\\"), index + 1 < bytes.count, Self.isASCIIPunctuation(bytes[index + 1]) {
                return true
            }
            if byte == UInt8(ascii: "&") {
                var cursor = index + 1
                while cursor < bytes.count, cursor - index <= 32,
                      bytes[cursor] == UInt8(ascii: "#") || Self.isASCIIAlphanumeric(bytes[cursor]) {
                    cursor += 1
                }
                if cursor > index + 1, cursor < bytes.count, bytes[cursor] == UInt8(ascii: ";") { return true }
            }
        }
        return false
    }

    private static func isASCIIPunctuation(_ byte: UInt8) -> Bool {
        (0x21...0x2F).contains(byte) || (0x3A...0x40).contains(byte) || (0x5B...0x60).contains(byte)
            || (0x7B...0x7E).contains(byte)
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    // MARK: Streaming

    private func streamingBlocks(for text: String) -> [MarkdownBlock] {
        var state = takeStream(extendedBy: text) ?? StreamingParse(source: text)
        let utf8 = text.utf8
        var settledEnd = utf8.index(utf8.startIndex, offsetBy: state.settledLength)
        if let split = state.scanner.advance(in: text), split > settledEnd {
            state.settledBlocks += MarkdownParser.parse(String(text[settledEnd..<split]))
            state.settledLength = utf8.distance(from: utf8.startIndex, to: split)
            settledEnd = split
        }
        state.source = text
        if state.verifiedLength > 0 { remember(state) }
        return state.settledBlocks + MarkdownParser.parse(String(text[settledEnd...]))
    }

    /// Removes and returns the state with the longest scanned prefix that `text` still starts with.
    private func takeStream(extendedBy text: String) -> StreamingParse? {
        var best: Int?
        for (index, stream) in streams.enumerated() {
            if let best, streams[best].verifiedLength >= stream.verifiedLength { continue }
            if Self.sharePrefix(text, stream.source, length: stream.verifiedLength) { best = index }
        }
        return best.map { streams.remove(at: $0) }
    }

    private func remember(_ state: StreamingParse) {
        streams.insert(state, at: 0)
        if streams.count > Self.maxStreams { streams.removeLast(streams.count - Self.maxStreams) }
    }

    /// Whether the first `length` UTF-8 bytes of both strings exist and are equal.
    private static func sharePrefix(_ lhs: String, _ rhs: String, length: Int) -> Bool {
        guard length > 0 else { return true }
        guard lhs.utf8.count >= length, rhs.utf8.count >= length else { return false }
        var left = lhs
        var right = rhs
        return left.withUTF8 { leftBytes in
            right.withUTF8 { rightBytes in
                guard let leftBase = leftBytes.baseAddress, let rightBase = rightBytes.baseAddress else { return false }
                return memcmp(leftBase, rightBase, length) == 0
            }
        }
    }

    // MARK: Inline styling

    private static func styledInline(_ source: String, codeSize: CGFloat, strongSize: CGFloat?) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var attributed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)

        var codeRanges: [Range<AttributedString.Index>] = []
        var strongRanges: [(Range<AttributedString.Index>, InlinePresentationIntent)] = []
        var linkRanges: [Range<AttributedString.Index>] = []
        var blockedLinkRanges: [Range<AttributedString.Index>] = []
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                codeRanges.append(run.range)
            }
            if strongSize != nil, let intent = run.inlinePresentationIntent, intent.contains(.stronglyEmphasized) {
                strongRanges.append((run.range, intent))
            }
            if let url = run.link {
                if MarkdownLinkPolicy.isAllowed(url) {
                    linkRanges.append(run.range)
                } else {
                    blockedLinkRanges.append(run.range)
                }
            }
        }
        for range in blockedLinkRanges {
            // Not clickable and not styled as a link; the text itself stays.
            attributed[range].link = nil
        }
        if let strongSize {
            // Semibold rather than the intent's bold, which reads harsh at body size. The strong
            // bit is dropped so the font is not emboldened again; emphasis (italic) is kept.
            for (range, intent) in strongRanges {
                attributed[range].swiftUI.font = Theme.font(strongSize, .semibold)
                attributed[range].inlinePresentationIntent = intent.subtracting(.stronglyEmphasized)
            }
        }
        for range in codeRanges {
            attributed[range].swiftUI.font = Theme.mono(codeSize, .medium)
            attributed[range].swiftUI.foregroundColor = Theme.inlineCodeText
            attributed[range].swiftUI.backgroundColor = Theme.inlineCodeBackground
        }
        for range in linkRanges {
            attributed[range].swiftUI.foregroundColor = Theme.link
            attributed[range].swiftUI.underlineStyle = Text.LineStyle(pattern: .solid, color: Theme.link.opacity(0.45))
        }
        return attributed
    }
}

// MARK: - View

/// Renders Markdown chat text. `isStreaming` shows a blinking caret after the last block and
/// heals unfinished inline syntax in that block.
struct MarkdownText: View {
    let text: String
    var isStreaming: Bool
    var baseSize: CGFloat
    var color: Color

    init(_ text: String, isStreaming: Bool = false, baseSize: CGFloat = Theme.bodySize, color: Color = Theme.textBody) {
        self.text = text
        self.isStreaming = isStreaming
        self.baseSize = baseSize
        self.color = color
    }

    /// Blocks are laid out in fixed groups of this many. A long reply has hundreds of blocks; in one
    /// flat stack every streamed delta re-lays out (and re-diffs) all of them, while with groups only
    /// the outer stack of groups and the last group are touched.
    static let blocksPerGroup = 12

    var body: some View {
        let blocks = MarkdownCache.shared.blocks(for: text, streaming: isStreaming)
        let style = MarkdownStyle(baseSize: baseSize, color: color)
        VStack(alignment: .leading, spacing: Self.blockSpacing) {
            if blocks.isEmpty {
                if isStreaming {
                    InlineMarkdownText(
                        source: "",
                        font: style.bodyFont,
                        color: color,
                        codeSize: style.codeSize,
                        strongSize: style.baseSize,
                        showsCaret: true
                    )
                }
            } else {
                // Index identity is stable while streaming: settled blocks keep their position and
                // value, so their (equatable) groups are skipped and only the tail re-renders.
                ForEach(Array(stride(from: 0, to: blocks.count, by: Self.blocksPerGroup)), id: \.self) { start in
                    let end = min(start + Self.blocksPerGroup, blocks.count)
                    MarkdownBlockGroup(
                        blocks: Array(blocks[start..<end]),
                        style: style,
                        streamingTailOffset: isStreaming && end == blocks.count ? end - start - 1 : nil
                    )
                    .equatable()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, MarkdownLinkPolicy.openURLAction)
    }

    fileprivate static let blockSpacing: CGFloat = 8
}

/// A run of consecutive blocks; `streamingTailOffset` marks the block that is still streaming.
private struct MarkdownBlockGroup: View, Equatable {
    let blocks: [MarkdownBlock]
    let style: MarkdownStyle
    let streamingTailOffset: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownText.blockSpacing) {
            ForEach(blocks.indices, id: \.self) { offset in
                MarkdownBlockView(block: blocks[offset], style: style, isStreamingTail: offset == streamingTailOffset)
                    .equatable()
            }
        }
    }
}

private struct MarkdownStyle: Equatable {
    var baseSize: CGFloat
    var color: Color

    var bodyFont: Font { Theme.font(baseSize) }
    var codeSize: CGFloat { max(10, baseSize - 1.5) }

    func headingFont(level: Int) -> Font {
        switch level {
        case 1: return Theme.font(baseSize + 3, .semibold)
        case 2: return Theme.font(baseSize + 1.5, .semibold)
        default: return Theme.font(baseSize, .semibold)
        }
    }
}

private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let style: MarkdownStyle
    let isStreamingTail: Bool

    var body: some View {
        switch block {
        case .heading(let level, let text):
            InlineMarkdownText(
                source: text,
                font: style.headingFont(level: level),
                color: style.color,
                codeSize: style.codeSize,
                showsCaret: isStreamingTail
            )
            .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let text):
            InlineMarkdownText(
                source: text,
                font: style.bodyFont,
                color: style.color,
                codeSize: style.codeSize,
                strongSize: style.baseSize,
                showsCaret: isStreamingTail
            )

        case .list(let items):
            MarkdownListView(items: items, style: style, isStreamingTail: isStreamingTail)

        case .quote(let blocks):
            let quoteStyle = MarkdownStyle(baseSize: style.baseSize, color: Theme.textSecondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(blocks.indices, id: \.self) { offset in
                    MarkdownBlockView(
                        block: blocks[offset],
                        style: quoteStyle,
                        isStreamingTail: isStreamingTail && offset == blocks.count - 1
                    )
                    .equatable()
                }
            }
            .padding(.leading, 13)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.25, style: .continuous)
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 2.5)
            }

        case .code(let language, let code, _):
            MarkdownCodeBlock(language: language, code: code, showsCaret: isStreamingTail)

        case .table(let table):
            MarkdownTableView(table: table, style: style)

        case .rule:
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }
}

/// One run of inline Markdown. When `showsCaret`, heals partial syntax and appends a blinking caret (styling only
/// the lines of the block that are still settling; see `MarkdownCache.streamingInline`).
private struct InlineMarkdownText: View, Equatable {
    let source: String
    let font: Font
    let color: Color
    let codeSize: CGFloat
    /// Size of semibold `**strong**` runs; nil keeps the default bold (headings, already semibold).
    var strongSize: CGFloat? = nil
    let showsCaret: Bool
    var lineSpacing: CGFloat = 3.5

    var body: some View {
        if showsCaret {
            let healed = MarkdownCache.shared.streamingInline(source, codeSize: codeSize, strongSize: strongSize)
            TimelineView(.animation(minimumInterval: 0.5)) { context in
                let visible = Int(context.date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2)
                styled(healed + Self.caret(visible: visible))
            }
        } else {
            styled(MarkdownCache.shared.inline(source, codeSize: codeSize, strongSize: strongSize))
        }
    }

    private func styled(_ attributed: AttributedString) -> some View {
        Text(attributed)
            .font(font)
            .foregroundStyle(color)
            .lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func caret(visible: Bool) -> AttributedString {
        var caret = AttributedString("\u{258D}")
        caret.swiftUI.foregroundColor = visible ? Theme.textSecondary : Color.clear
        return caret
    }
}

private struct MarkdownListView: View, Equatable {
    let items: [MarkdownListItem]
    let style: MarkdownStyle
    let isStreamingTail: Bool

    var body: some View {
        let markerWidth = MarkdownListMetrics.markerColumnWidth(for: items, baseSize: style.baseSize)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items.indices, id: \.self) { offset in
                MarkdownListRow(
                    item: items[offset],
                    style: style,
                    markerWidth: markerWidth,
                    showsCaret: isStreamingTail && offset == items.count - 1
                )
                .equatable()
            }
        }
    }
}

private struct MarkdownListRow: View, Equatable {
    let item: MarkdownListItem
    let style: MarkdownStyle
    let markerWidth: CGFloat
    let showsCaret: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            marker
                // Never wrap "10." onto two lines; the column width is measured to fit it anyway.
                .lineLimit(1)
                .fixedSize()
                .frame(width: markerWidth, alignment: .trailing)
            InlineMarkdownText(
                source: item.text,
                font: style.bodyFont,
                color: style.color,
                codeSize: style.codeSize,
                strongSize: style.baseSize,
                showsCaret: showsCaret
            )
        }
        .padding(.leading, CGFloat(min(item.level, 4)) * 18)
    }

    @ViewBuilder
    private var marker: some View {
        switch item.marker {
        case .bullet:
            Text(Self.bulletGlyph(level: item.level))
                .font(Theme.font(style.baseSize, .bold))
                .foregroundStyle(Theme.textSecondary)
        case .ordered(let number):
            Text(MarkdownListMetrics.orderedLabel(number))
                .font(Theme.font(style.baseSize, .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        case .task(let done):
            Text(Image(systemName: done ? "checkmark.square.fill" : "square"))
                .font(Theme.font(style.baseSize - 1))
                .foregroundStyle(done ? Theme.textSecondary : Theme.textTertiary)
        }
    }

    private static func bulletGlyph(level: Int) -> String {
        switch level % 3 {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪︎"
        }
    }
}

/// Width of a list's marker column, measured with the font the markers render in, so ordered
/// markers ("9.", "10.", "2024.") always fit on one line and the item text lines up after them.
@MainActor
enum MarkdownListMetrics {
    private static var orderedWidths: [String: CGFloat] = [:]

    static func orderedLabel(_ number: Int) -> String { "\(number)." }

    static func markerColumnWidth(for items: [MarkdownListItem], baseSize: CGFloat) -> CGFloat {
        var widest: CGFloat = 9
        var widestDigits = 0
        for item in items {
            switch item.marker {
            case .bullet:
                break
            case .ordered(let number):
                widestDigits = max(widestDigits, String(number).count)
            case .task:
                widest = max(widest, baseSize + 1)
            }
        }
        if widestDigits > 0 {
            widest = max(widest, orderedWidth(digits: widestDigits, baseSize: baseSize))
        }
        return widest
    }

    /// Width of an ordered marker with `digits` digits. Digits are monospaced (`.monospacedDigit()`),
    /// so all markers with the same digit count are equally wide.
    static func orderedWidth(digits: Int, baseSize: CGFloat) -> CGFloat {
        let key = "\(digits)|\(baseSize)"
        if let cached = orderedWidths[key] { return cached }
        let font = NSFont.monospacedDigitSystemFont(ofSize: baseSize, weight: .medium)
        let sample = String(repeating: "0", count: max(1, digits)) + "."
        let width = ceil((sample as NSString).size(withAttributes: [.font: font]).width) + 1
        orderedWidths[key] = width
        return width
    }
}

private struct MarkdownCodeBlock: View {
    let language: String?
    let code: String
    let showsCaret: Bool
    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    /// Long code is laid out as several `Text`s so that, while it streams, only the last chunk is
    /// re-laid out (and its grain redrawn) on each delta instead of the whole block.
    private static let linesPerChunk = 40
    private static let maxLinesInOneText = 60
    static let lineSpacing: CGFloat = 2.5
    static let cornerRadius: CGFloat = 12
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 10
    static let grainOpacity: Double = 0.05

    private var displayCode: String {
        var trimmed = code
        while trimmed.hasSuffix("\n") { trimmed.removeLast() }
        return trimmed
    }

    private var languageLabel: String {
        guard let language, !language.isEmpty else { return "code" }
        return language.lowercased()
    }

    // The well grows with every streamed line, so nothing drawn at its full size may need
    // rasterizing: gradients and tiled images would be redrawn over the whole (possibly
    // thousands-of-points-tall) area on each line. The fill and side border are solid colors
    // (composited, not rasterized), the lit/shaded edges are fixed-size pieces, and the grain is
    // drawn per header and per code chunk, so only the last chunk's grain is redrawn as it grows.
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            header
                .background { NoiseTexture(opacity: Self.grainOpacity) }

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)

            codeText
        }
        .background { shape.fill(Theme.codeFill) }
        .clipShape(shape)
        .overlay { CodeWellEdges(cornerRadius: Self.cornerRadius) }
        .onDisappear { resetTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(languageLabel)
                .font(Theme.mono(10.5, .medium))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 8)
            Button(action: copy) {
                HStack(spacing: 4) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                    Text(didCopy ? "Copied" : "Copy")
                        .font(Theme.font(11, .medium))
                }
                .foregroundStyle(didCopy ? Theme.textSecondary : Theme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .help("Copy code")
            .accessibilityLabel("Copy code")
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.top, 7)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var codeText: some View {
        let code = displayCode
        let chunks = Self.chunks(of: code)
        if chunks.count <= 1 {
            CodeChunkText(code: code, showsCaret: showsCaret, topPadding: Self.verticalPadding, bottomPadding: Self.verticalPadding)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(chunks.indices, id: \.self) { index in
                    let isLast = index == chunks.count - 1
                    CodeChunkText(
                        code: chunks[index],
                        showsCaret: showsCaret && isLast,
                        topPadding: index == 0 ? Self.verticalPadding : 0,
                        // Between chunks, the gap a line break would have left.
                        bottomPadding: isLast ? Self.verticalPadding : Self.lineSpacing
                    )
                    .equatable()
                }
            }
        }
    }

    /// Splits long code into fixed runs of lines (earlier chunks never change as code streams in).
    static func chunks(of code: String) -> [String] {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLinesInOneText else { return [code] }
        return stride(from: 0, to: lines.count, by: linesPerChunk).map { start in
            lines[start..<min(start + linesPerChunk, lines.count)].joined(separator: "\n")
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(displayCode, forType: .string)
        didCopy = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}

/// The recessed-well edge of a code block: a dark top edge and a faint lit bottom edge over a
/// neutral side border. The top and bottom pieces have a fixed height, so they are drawn once no
/// matter how tall the block grows; the side border is a solid color.
private struct CodeWellEdges: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let capHeight = cornerRadius + 3
        ZStack {
            shape.strokeBorder(Color.white.opacity(0.025), lineWidth: 1)
            VStack(spacing: 0) {
                edge(shape, color: Color.black.opacity(0.55), alignment: .top, capHeight: capHeight)
                Spacer(minLength: 0)
                edge(shape, color: Color.white.opacity(0.06), alignment: .bottom, capHeight: capHeight)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The top (or bottom) `capHeight` of a rounded-rect border: the straight edge and its corners.
    private func edge(_ shape: RoundedRectangle, color: Color, alignment: Alignment, capHeight: CGFloat) -> some View {
        shape
            .strokeBorder(color, lineWidth: 1)
            .frame(height: cornerRadius * 2 + 2)
            .frame(height: capHeight, alignment: alignment)
            .clipped()
    }
}

private struct CodeChunkText: View, Equatable {
    let code: String
    let showsCaret: Bool
    let topPadding: CGFloat
    let bottomPadding: CGFloat

    var body: some View {
        content
            .padding(.horizontal, MarkdownCodeBlock.horizontalPadding)
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
            .background { NoiseTexture(opacity: MarkdownCodeBlock.grainOpacity) }
    }

    @ViewBuilder
    private var content: some View {
        if showsCaret {
            TimelineView(.animation(minimumInterval: 0.5)) { context in
                let visible = Int(context.date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2)
                label(AttributedString(code) + InlineMarkdownText.caret(visible: visible))
            }
        } else {
            label(AttributedString(code))
        }
    }

    private func label(_ attributed: AttributedString) -> some View {
        Text(attributed)
            .font(Theme.mono(Theme.codeSize))
            .foregroundStyle(Theme.codeText)
            .lineSpacing(MarkdownCodeBlock.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let style: MarkdownStyle

    var body: some View {
        let columns = table.columnCount
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
            GridRow {
                ForEach(0..<columns, id: \.self) { column in
                    cell(Self.value(in: table.header, at: column) ?? "", bold: true)
                        .gridColumnAlignment(alignment(for: column))
                }
            }
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .gridCellUnsizedAxes(.horizontal)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(Self.value(in: row, at: column) ?? "", bold: false)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                }
        }
    }

    private func cell(_ source: String, bold: Bool) -> some View {
        Text(MarkdownCache.shared.inline(source, codeSize: style.codeSize - 0.5, strongSize: style.baseSize - 1))
            .font(Theme.font(style.baseSize - 1, bold ? .semibold : .regular))
            .foregroundStyle(bold ? style.color : style.color.opacity(0.92))
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func value<Element>(in array: [Element], at index: Int) -> Element? {
        array.indices.contains(index) ? array[index] : nil
    }

    private func alignment(for column: Int) -> HorizontalAlignment {
        switch Self.value(in: table.alignments, at: column) ?? .leading {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
