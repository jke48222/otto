//
//  AppleScriptCodeLayout.swift
//  Otto
//
//  The pure row layout behind the code and text boxes on approval cards: it wraps text by character at a
//  column count, so a long line continues on the next row instead of running off to the right where the
//  user can't see it. The rows are exact slices of the source, so joined back together they are the
//  source, character for character.
//

import AppKit
import SwiftUI

enum AppleScriptCodeLayout {
    /// One visual row: the first row of a source line carries its line number, continuation rows carry none.
    struct CodeLine: Equatable, Sendable, Identifiable {
        /// Position among all rows (0-based).
        let index: Int
        /// The exact slice of the source, including the line terminator on a line's last row.
        let text: String
        /// 1-based source line number on a line's first row; nil on continuation rows.
        let lineNumber: Int?
        /// Columns the row takes (tabs count `tabWidth`, wide characters 2, line terminators 0).
        let width: Int

        var id: Int { index }
        var isContinuation: Bool { lineNumber == nil }

        /// What the row draws: no line terminator, tabs as `tabWidth` spaces.
        var displayText: String { AppleScriptCodeLayout.displayText(text) }
    }

    /// Tabs render as this many spaces (and take as many columns).
    static let tabWidth = 4

    /// Wraps `source` into rows of at most `columns` columns (at least `tabWidth`, so any single character
    /// fits a row). Only line terminators end a source line; every other character, spaces included, stays
    /// on screen. A row that runs out of room breaks after the last space or separator in it (`breaksAfter`)
    /// when that keeps at least half the row, so a word or identifier moves to the next row whole; otherwise
    /// it breaks at the character. Indentation is never a break point. A terminator at the very end doesn't
    /// add an empty last row.
    static func wrap(_ source: String, columns: Int) -> [CodeLine] {
        let limit = max(columns, tabWidth)
        var rows: [CodeLine] = []
        var rowStart = source.startIndex
        var rowWidth = 0
        var lineNumber = 1
        var rowIsLineStart = true
        /// The last place the current row may break (just after a space or separator) and its width there.
        var breakPoint: (index: String.Index, width: Int)?
        var rowHasContent = false

        func closeRow(at end: String.Index, width: Int) {
            rows.append(CodeLine(index: rows.count, text: String(source[rowStart..<end]),
                                 lineNumber: rowIsLineStart ? lineNumber : nil, width: width))
            rowStart = end
        }

        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if character.isNewline {
                closeRow(at: next, width: rowWidth)
                rowWidth = 0
                lineNumber += 1
                rowIsLineStart = true
                breakPoint = nil
                rowHasContent = false
            } else {
                let width = columnWidth(of: character)
                if rowWidth > 0, rowWidth + width > limit {
                    if let point = breakPoint, point.width * 2 >= limit {
                        closeRow(at: point.index, width: point.width)
                        rowWidth -= point.width
                    } else {
                        closeRow(at: index, width: rowWidth)
                        rowWidth = 0
                    }
                    rowIsLineStart = false
                    breakPoint = nil
                    rowHasContent = rowWidth > 0
                }
                rowWidth += width
                let isSpace = character == " " || character == "\t"
                if rowHasContent, isSpace || breaksAfter.contains(character) {
                    breakPoint = (next, rowWidth)
                }
                if !isSpace { rowHasContent = true }
            }
            index = next
        }
        if rowStart < source.endIndex {
            closeRow(at: source.endIndex, width: rowWidth)
        }
        return rows
    }

    /// Separators a row may break after (besides spaces): the joints of paths, addresses and expressions.
    static let breaksAfter: Set<Character> = ["/", "-", ".", ",", ";", "&", "?", "=", ")", "]", "}"]

    /// Columns a character takes in the monospaced code font.
    static func columnWidth(of character: Character) -> Int {
        if character.isNewline { return 0 }
        if character == "\t" { return tabWidth }
        guard let first = character.unicodeScalars.first else { return 1 }
        if character.unicodeScalars.count > 1, character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }) {
            return 2
        }
        return isWide(first) ? 2 : 1
    }

    /// Source lines as the gutter numbers them (a trailing terminator doesn't start another line).
    static func lineCount(of source: String) -> Int {
        wrap(source, columns: Int.max).count
    }

    /// Columns that fit `width` points of `font`-sized monospaced text (never fewer than `tabWidth`).
    @MainActor
    static func columns(forWidth width: CGFloat, fontSize: CGFloat) -> Int {
        let advance = characterWidth(fontSize: fontSize)
        guard width.isFinite, advance > 0 else { return tabWidth }
        return max(tabWidth, Int((width / advance).rounded(.down)))
    }

    /// The widest advance of the code font across the weights the highlighter uses.
    @MainActor
    static func characterWidth(fontSize: CGFloat) -> CGFloat {
        if let cached = advanceCache[fontSize] { return cached }
        let advance = [NSFont.Weight.regular, .semibold].map { weight -> CGFloat in
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
            return ("M" as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? fontSize * 0.6
        advanceCache[fontSize] = advance
        return advance
    }

    @MainActor private static var advanceCache: [CGFloat: CGFloat] = [:]

    /// Whether the rows run taller than the box, so the user has to scroll to see them all.
    static func needsScrollToReview(rowCount: Int, rowHeight: CGFloat, verticalPadding: CGFloat,
                                    maxHeight: CGFloat) -> Bool {
        CGFloat(rowCount) * rowHeight + verticalPadding > maxHeight + 0.5
    }

    /// The last row counts as shown once its bottom edge is inside the scroll viewport.
    static func isLastRowVisible(lastRowMaxY: CGFloat, viewportHeight: CGFloat) -> Bool {
        lastRowMaxY <= viewportHeight + 1
    }

    /// "12 lines" / "1 line".
    static func lineCountLabel(_ count: Int) -> String {
        count == 1 ? "1 line" : "\(count) lines"
    }

    /// The footer under a script that doesn't fit: "40 lines · scroll to review".
    static func reviewFooter(lineCount: Int) -> String {
        "\(lineCountLabel(lineCount)) · scroll to review"
    }

    /// Splits `attributed` (whose characters are the rows' text joined) into one styled string per row, drawn
    /// as `displayText`. Walks Unicode scalars, so grapheme boundaries across attribute runs can't shift a row.
    static func attributedRows(_ attributed: AttributedString, rows: [CodeLine]) -> [AttributedString] {
        var pieces: [(scalars: [Unicode.Scalar], attributes: AttributeContainer)] = []
        for run in attributed.runs {
            let scalars = Array(String(attributed[run.range].characters).unicodeScalars)
            pieces.append((scalars, run.attributes))
        }
        var pieceIndex = 0
        var offset = 0
        var result: [AttributedString] = []
        result.reserveCapacity(rows.count)
        for row in rows {
            var remaining = row.text.unicodeScalars.count
            var rowString = AttributedString()
            while remaining > 0, pieceIndex < pieces.count {
                let piece = pieces[pieceIndex]
                let take = min(remaining, piece.scalars.count - offset)
                var view = String.UnicodeScalarView()
                view.append(contentsOf: piece.scalars[offset..<(offset + take)])
                rowString.append(AttributedString(displayText(String(view)), attributes: piece.attributes))
                remaining -= take
                offset += take
                if offset == piece.scalars.count {
                    pieceIndex += 1
                    offset = 0
                }
            }
            result.append(rowString)
        }
        return result
    }

    /// Drops line terminators and expands tabs, for drawing only.
    static func displayText(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for character in text where !character.isNewline {
            if character == "\t" {
                output.append(String(repeating: " ", count: tabWidth))
            } else {
                output.append(character)
            }
        }
        return output
    }

    /// East Asian wide and fullwidth ranges plus emoji blocks: two cells in a monospaced font.
    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isEmojiPresentation { return true }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
