//
//  RichTextRenderer.swift
//  Otto
//
//  Turns a finished Markdown answer into what other apps paste well: readable plain text, a semantic HTML
//  fragment and RTF. Pure; reuses the chat's own Markdown parser and link policy, so a link Otto wouldn't
//  open in the chat is pasted as plain text too.
//

import AppKit
import Foundation

enum RichTextRenderer {
    // MARK: Code-only answers

    /// The content of the only block when the answer is exactly one *closed* fenced code block
    /// (whitespace allowed around it); nil otherwise.
    static func codeOnlyContent(_ markdown: String) -> String? {
        codeOnlyBlock(markdown)?.code
    }

    /// `codeOnlyContent` plus the fence's language tag (the first word of its info string), when present.
    /// The content is kept byte for byte (tabs included).
    static func codeOnlyBlock(_ markdown: String) -> (language: String?, code: String)? {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        guard lines.count >= 2, let opening = openingFence(lines[0]) else { return nil }
        guard let lastLine = lines.last, isClosingFence(lastLine, for: opening) else { return nil }
        let body = lines[1..<(lines.count - 1)]
        // A closing fence inside means the block ended early and more follows.
        guard !body.contains(where: { isClosingFence($0, for: opening) }) else { return nil }
        let code = body.map { removingIndent($0, upTo: opening.indent) }.joined(separator: "\n")
        return (opening.language, code)
    }

    // MARK: Plain text

    /// Readable plain text: blocks separated by one blank line; headings as their text; lists `- ` / `1. ` with a
    /// 2-space indent per level, tasks `[ ] `/`[x] `; quotes keep `> `; code blocks verbatim without fences; links
    /// `text (url)` unless text == url; tables tab-separated; rules become the blank line between blocks.
    static func plainText(_ markdown: String) -> String {
        plain(MarkdownParser.parse(markdown))
    }

    private static func plain(_ blocks: [MarkdownBlock]) -> String {
        blocks.compactMap(plain).joined(separator: "\n\n")
    }

    private static func plain(_ block: MarkdownBlock) -> String? {
        switch block {
        case .heading(_, let text):
            return inlinePlain(text)
        case .paragraph(let text):
            return inlinePlain(text)
        case .list(let items):
            return items.map { item in
                let indent = String(repeating: "  ", count: max(item.level, 0))
                let marker: String
                switch item.marker {
                case .bullet: marker = "- "
                case .ordered(let number): marker = "\(number). "
                case .task(let done): marker = done ? "- [x] " : "- [ ] "
                }
                return indent + marker + inlinePlain(item.text)
            }.joined(separator: "\n")
        case .quote(let blocks):
            let inner = plain(blocks)
            return inner.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? ">" : "> " + $0 }
                .joined(separator: "\n")
        case .code(_, let code, _):
            return code
        case .table(let table):
            let header = table.header.map(inlinePlain).joined(separator: "\t")
            let rows = table.rows.map { $0.map(inlinePlain).joined(separator: "\t") }
            return ([header] + rows).joined(separator: "\n")
        case .rule:
            return nil
        }
    }

    private static func inlinePlain(_ text: String) -> String {
        var output = ""
        for group in linkGroups(inlineRuns(text)) {
            let visible = group.runs.map(\.text).joined()
            guard let url = group.link else {
                output += visible
                continue
            }
            let address = url.absoluteString
            let bareAddress = address.hasPrefix("mailto:") ? String(address.dropFirst("mailto:".count)) : address
            output += (visible == address || visible == bareAddress) ? visible : "\(visible) (\(bareAddress))"
        }
        return output
    }

    // MARK: HTML

    /// Semantic HTML fragment wrapped in <html><head><meta charset="utf-8"></head><body>…</body></html>.
    static func html(_ markdown: String) -> String {
        "<html><head><meta charset=\"utf-8\"></head><body>" + htmlBlocks(MarkdownParser.parse(markdown)) + "</body></html>"
    }

    private static func htmlBlocks(_ blocks: [MarkdownBlock]) -> String {
        blocks.map(htmlBlock).joined()
    }

    private static func htmlBlock(_ block: MarkdownBlock) -> String {
        switch block {
        case .heading(let level, let text):
            let tag = "h\(headingLevel(level))"
            return "<\(tag)>\(inlineHTML(text))</\(tag)>"
        case .paragraph(let text):
            return "<p>\(inlineHTML(text))</p>"
        case .list(let items):
            return htmlList(items)
        case .quote(let blocks):
            return "<blockquote>\(htmlBlocks(blocks))</blockquote>"
        case .code(let language, let code, _):
            let languageClass = language.map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : " class=\"language-\(escape($0))\"" } ?? ""
            return "<pre><code\(languageClass)>\(escape(code))</code></pre>"
        case .table(let table):
            let header = table.header.map { "<th>\(inlineHTML($0))</th>" }.joined()
            let rows = table.rows.map { row in "<tr>" + row.map { "<td>\(inlineHTML($0))</td>" }.joined() + "</tr>" }
            return "<table><thead><tr>\(header)</tr></thead><tbody>\(rows.joined())</tbody></table>"
        case .rule:
            return "<hr>"
        }
    }

    /// Nested `<ul>`/`<ol>` from the parser's flat items with levels.
    private static func htmlList(_ items: [MarkdownListItem]) -> String {
        var output = ""
        var open: [(level: Int, tag: String)] = []
        for item in items {
            let level = max(item.level, 0)
            let tag: String
            var start = ""
            switch item.marker {
            case .ordered(let number):
                tag = "ol"
                if number != 1 { start = " start=\"\(number)\"" }
            case .bullet, .task:
                tag = "ul"
            }
            while let top = open.last, top.level > level {
                output += "</li></\(top.tag)>"
                open.removeLast()
            }
            if let top = open.last, top.level == level {
                if top.tag == tag {
                    output += "</li>"
                } else {
                    output += "</li></\(top.tag)><\(tag)\(start)>"
                    open[open.count - 1] = (level, tag)
                }
            } else {
                output += "<\(tag)\(start)>"
                open.append((level, tag))
            }
            var prefix = ""
            if case .task(let done) = item.marker { prefix = done ? "☑ " : "☐ " }
            output += "<li>" + prefix + inlineHTML(item.text)
        }
        while let top = open.popLast() { output += "</li></\(top.tag)>" }
        return output
    }

    private static func inlineHTML(_ text: String) -> String {
        var output = ""
        for group in linkGroups(inlineRuns(text)) {
            let body = group.runs.map { run -> String in
                var piece = escape(run.text).replacingOccurrences(of: "\n", with: "<br>")
                if run.intent.contains(.code) { piece = "<code>\(piece)</code>" }
                if run.intent.contains(.strikethrough) { piece = "<del>\(piece)</del>" }
                if run.intent.contains(.emphasized) { piece = "<em>\(piece)</em>" }
                if run.intent.contains(.stronglyEmphasized) { piece = "<strong>\(piece)</strong>" }
                return piece
            }.joined()
            if let url = group.link {
                output += "<a href=\"\(escape(url.absoluteString))\">\(body)</a>"
            } else {
                output += body
            }
        }
        return output
    }

    /// Escapes `& < > " '`.
    static func escape(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&#39;"
            default: output.append(character)
            }
        }
        return output
    }

    // MARK: RTF

    /// RTF data of `attributedString(_:)`.
    static func rtf(_ markdown: String) -> Data? {
        let attributed = attributedString(markdown)
        return attributed.rtf(from: NSRange(location: 0, length: attributed.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// Helvetica Neue 13 body, bold headings, Menlo 12 code, list indents, no colors (the destination picks the
    /// text color, so dark-mode apps stay legible).
    static func attributedString(_ markdown: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        appendBlocks(MarkdownParser.parse(markdown), indent: 0, to: output)
        // Every paragraph ends with a newline; the last one isn't needed.
        if output.length > 0, output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
    }

    private enum Metrics {
        static let bodySize: CGFloat = 13
        static let codeSize: CGFloat = 12
        static let listIndent: CGFloat = 18
        static let quoteIndent: CGFloat = 14
        static let paragraphSpacing: CGFloat = 8
        static let codeSpacing: CGFloat = 6

        static func headingSize(_ level: Int) -> CGFloat {
            switch RichTextRenderer.headingLevel(level) {
            case 1: return 18
            case 2: return 16
            default: return 14
            }
        }
    }

    private static func appendBlocks(_ blocks: [MarkdownBlock], indent: CGFloat, to output: NSMutableAttributedString) {
        for block in blocks {
            switch block {
            case .heading(let level, let text):
                let font = bodyFont(size: Metrics.headingSize(level), bold: true)
                output.append(inlineAttributed(text, font: font, paragraph: paragraphStyle(indent: indent)))
                output.append(newline(paragraph: paragraphStyle(indent: indent)))
            case .paragraph(let text):
                let style = paragraphStyle(indent: indent)
                output.append(inlineAttributed(text, font: bodyFont(size: Metrics.bodySize), paragraph: style))
                output.append(newline(paragraph: style))
            case .list(let items):
                appendList(items, indent: indent, to: output)
            case .quote(let blocks):
                appendBlocks(blocks, indent: indent + Metrics.quoteIndent, to: output)
            case .code(_, let code, _):
                let style = paragraphStyle(indent: indent, spacing: Metrics.codeSpacing)
                output.append(NSAttributedString(string: code + "\n", attributes: [
                    .font: codeFont(),
                    .paragraphStyle: style,
                ]))
            case .table(let table):
                let style = paragraphStyle(indent: indent, spacing: 2)
                let headerFont = bodyFont(size: Metrics.bodySize, bold: true)
                let cellFont = bodyFont(size: Metrics.bodySize)
                appendTableRow(table.header, font: headerFont, paragraph: style, to: output)
                for row in table.rows { appendTableRow(row, font: cellFont, paragraph: style, to: output) }
            case .rule:
                output.append(newline(paragraph: paragraphStyle(indent: indent)))
            }
        }
    }

    private static func appendList(_ items: [MarkdownListItem], indent: CGFloat, to output: NSMutableAttributedString) {
        for item in items {
            let level = CGFloat(max(item.level, 0))
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = indent + Metrics.listIndent * level
            style.headIndent = indent + Metrics.listIndent * (level + 1)
            style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
            style.defaultTabInterval = Metrics.listIndent
            style.paragraphSpacing = 2
            let marker: String
            switch item.marker {
            case .bullet: marker = "•\t"
            case .ordered(let number): marker = "\(number).\t"
            case .task(let done): marker = done ? "•\t☑ " : "•\t☐ "
            }
            let font = bodyFont(size: Metrics.bodySize)
            output.append(NSAttributedString(string: marker, attributes: [.font: font, .paragraphStyle: style]))
            output.append(inlineAttributed(item.text, font: font, paragraph: style))
            output.append(newline(paragraph: style))
        }
    }

    private static func appendTableRow(_ cells: [String], font: NSFont, paragraph: NSParagraphStyle,
                                       to output: NSMutableAttributedString) {
        for (index, cell) in cells.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\t", attributes: [.font: font, .paragraphStyle: paragraph]))
            }
            output.append(inlineAttributed(cell, font: font, paragraph: paragraph))
        }
        output.append(newline(paragraph: paragraph))
    }

    private static func inlineAttributed(_ text: String, font: NSFont, paragraph: NSParagraphStyle) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for group in linkGroups(inlineRuns(text)) {
            for run in group.runs {
                var runFont = run.intent.contains(.code) ? codeFont() : font
                let bold = run.intent.contains(.stronglyEmphasized)
                let italic = run.intent.contains(.emphasized)
                if bold || italic { runFont = withTraits(runFont, bold: bold, italic: italic) }
                var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .paragraphStyle: paragraph]
                if run.intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if let url = group.link { attributes[.link] = url }
                output.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        return output
    }

    private static func newline(paragraph: NSParagraphStyle) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.font: bodyFont(size: Metrics.bodySize), .paragraphStyle: paragraph])
    }

    private static func paragraphStyle(indent: CGFloat, spacing: CGFloat = Metrics.paragraphSpacing) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.paragraphSpacing = spacing
        return style
    }

    /// "Helvetica Neue" (never `.AppleSystemUIFont`, which maps badly in other apps), else the system font.
    private static func bodyFont(size: CGFloat, bold: Bool = false) -> NSFont {
        let regular = NSFont(name: "HelveticaNeue", size: size) ?? NSFont.systemFont(ofSize: size)
        return bold ? withTraits(regular, bold: true, italic: false) : regular
    }

    private static func codeFont() -> NSFont {
        NSFont(name: "Menlo-Regular", size: Metrics.codeSize)
            ?? NSFont.monospacedSystemFont(ofSize: Metrics.codeSize, weight: .regular)
    }

    private static func withTraits(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    // MARK: Inline runs

    private struct InlineRun {
        var text: String
        var intent: InlinePresentationIntent
        var link: URL?
    }

    private struct LinkGroup {
        var link: URL?
        var runs: [InlineRun]
    }

    /// `AttributedString(markdown:)` runs; a link survives only when `MarkdownLinkPolicy` allows it.
    private static func inlineRuns(_ text: String) -> [InlineRun] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: text, options: options) else {
            return [InlineRun(text: text, intent: [], link: nil)]
        }
        return attributed.runs.map { run in
            let link = run.link.flatMap { MarkdownLinkPolicy.isAllowed($0) ? $0 : nil }
            return InlineRun(text: String(attributed[run.range].characters),
                             intent: run.inlinePresentationIntent ?? [], link: link)
        }
    }

    /// Consecutive runs sharing one link, so a link's visible text is handled as a whole.
    private static func linkGroups(_ runs: [InlineRun]) -> [LinkGroup] {
        var groups: [LinkGroup] = []
        for run in runs {
            if let last = groups.last, last.link == run.link, run.link != nil {
                groups[groups.count - 1].runs.append(run)
            } else {
                groups.append(LinkGroup(link: run.link, runs: [run]))
            }
        }
        return groups
    }

    // MARK: Fences

    private struct Fence {
        var character: Character
        var count: Int
        var indent: Int
        var language: String?
    }

    private static func openingFence(_ line: String) -> Fence? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let character = rest.first, character == "`" || character == "~" else { return nil }
        let count = rest.prefix(while: { $0 == character }).count
        guard count >= 3 else { return nil }
        let info = rest.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if character == "`", info.contains("`") { return nil }
        let language = info.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return Fence(character: character, count: count, indent: indent, language: language)
    }

    private static func isClosingFence(_ line: String, for opening: Fence) -> Bool {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return false }
        let rest = line.dropFirst(indent)
        let count = rest.prefix(while: { $0 == opening.character }).count
        guard count >= opening.count else { return false }
        return rest.dropFirst(count).allSatisfy(\.isWhitespace)
    }

    private static func removingIndent(_ line: String, upTo count: Int) -> String {
        guard count > 0 else { return line }
        let spaces = line.prefix(while: { $0 == " " }).count
        return String(line.dropFirst(min(spaces, count)))
    }

    private static func headingLevel(_ level: Int) -> Int {
        min(max(level, 1), 3)
    }
}
