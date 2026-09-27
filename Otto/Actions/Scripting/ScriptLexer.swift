//
//  ScriptLexer.swift
//  Otto
//
//  A small AppleScript lexer shared by the analyzer and the highlighter. It knows where strings,
//  comments, raw «…» codes, piped identifiers and continuations start and end, so nothing hidden
//  inside a string (like `--`) can make the analyzer skip real code.
//

import Foundation

/// One lexical token of an AppleScript source. `range` always points into the source it came from.
struct ScriptToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// An identifier or keyword; `text` as written. A `|piped identifier|` is a word whose text is its inside.
        case word
        /// A string literal; `text` is the decoded contents (escapes resolved).
        case string
        case number
        /// `-- …`, `# …` or a nested `(* … *)`; `text` is the whole comment.
        case comment
        /// `«…»` or `<<…>>` raw event and class codes; `text` is the inside.
        case chevron
        /// The concatenation operator `&`.
        case ampersand
        /// The possessive `'s` (or `’s`).
        case possessive
        /// `¬`, which joins the next line to this one.
        case continuation
        case newline
        /// Any other punctuation: `(`, `)`, `,`, `:`, `{`, `}`, operators.
        case symbol
    }

    let kind: Kind
    let text: String
    let range: Range<String.Index>
    /// True for a word written as `|…|`, and for a string, comment, chevron or piped word that reaches the end of
    /// the source without its closing delimiter (lenient mode only).
    var isPiped = false
    var isUnterminated = false
}

enum ScriptLexer {
    /// Why a source can't be read safely.
    enum Failure: Error, Equatable, Sendable {
        case unterminatedString, unterminatedComment, unterminatedChevron, unterminatedIdentifier
        case unbalancedChevron, unbalancedParentheses
    }

    /// Strict: an unterminated string, comment, chevron or piped identifier, a stray `»`, or unbalanced
    /// parentheses fail the whole source.
    static func tokenize(_ source: String) -> Result<[ScriptToken], Failure> {
        var scanner = Scanner(source: source, lenient: false)
        return scanner.run()
    }

    /// Lenient (highlighting): never fails; an unterminated token runs to the end of the source.
    static func tokenizeLeniently(_ source: String) -> [ScriptToken] {
        var scanner = Scanner(source: source, lenient: true)
        switch scanner.run() {
        case .success(let tokens): return tokens
        case .failure: return scanner.tokens
        }
    }

    // MARK: - Scanner

    private struct Scanner {
        let source: String
        let lenient: Bool
        var index: String.Index
        var tokens: [ScriptToken] = []
        var parenthesisDepth = 0

        init(source: String, lenient: Bool) {
            self.source = source
            self.lenient = lenient
            index = source.startIndex
        }

        mutating func run() -> Result<[ScriptToken], Failure> {
            while index < source.endIndex {
                let character = source[index]
                let start = index
                if character.isNewline {
                    advance()
                    append(.newline, text: String(character), from: start)
                } else if character.isWhitespace {
                    advance()
                } else if character == "\"" {
                    if let failure = scanString(from: start) { return .failure(failure) }
                } else if character == "-", peek(1) == "-" {
                    scanLineComment(from: start)
                } else if character == "#" {
                    scanLineComment(from: start)
                } else if character == "(", peek(1) == "*" {
                    if let failure = scanBlockComment(from: start) { return .failure(failure) }
                } else if character == "«" {
                    if let failure = scanChevron(from: start, closing: "»") { return .failure(failure) }
                } else if character == "<", peek(1) == "<" {
                    if let failure = scanChevron(from: start, closing: ">>") { return .failure(failure) }
                } else if character == "»" {
                    advance()
                    if !lenient { return .failure(.unbalancedChevron) }
                    append(.symbol, text: "»", from: start)
                } else if character == "|" {
                    if let failure = scanPipedIdentifier(from: start) { return .failure(failure) }
                } else if character == "¬" {
                    advance()
                    append(.continuation, text: "¬", from: start)
                } else if character == "&" {
                    advance()
                    append(.ampersand, text: "&", from: start)
                } else if (character == "'" || character == "’"), let next = peek(1), next == "s" || next == "S",
                          !isWordCharacter(peek(2)) {
                    advance(2)
                    append(.possessive, text: String(source[start..<index]), from: start)
                } else if character.isLetter || character == "_" {
                    while index < source.endIndex, isWordCharacter(source[index]) { advance() }
                    append(.word, text: String(source[start..<index]), from: start)
                } else if character.isASCII, character.isNumber {
                    scanNumber()
                    append(.number, text: String(source[start..<index]), from: start)
                } else {
                    advance()
                    if character == "(" {
                        parenthesisDepth += 1
                    } else if character == ")" {
                        parenthesisDepth -= 1
                        if parenthesisDepth < 0, !lenient { return .failure(.unbalancedParentheses) }
                    }
                    append(.symbol, text: String(character), from: start)
                }
            }
            if parenthesisDepth != 0, !lenient { return .failure(.unbalancedParentheses) }
            return .success(tokens)
        }

        // MARK: Token scanners

        /// `"…"` with `\"` and `\\` (and `\n`, `\t`, `\r`) escapes; strings may span lines.
        private mutating func scanString(from start: String.Index) -> Failure? {
            advance()
            var text = ""
            while index < source.endIndex {
                let character = source[index]
                if character == "\\" {
                    advance()
                    guard index < source.endIndex else { break }
                    let escaped = source[index]
                    switch escaped {
                    case "n": text.append("\n")
                    case "t": text.append("\t")
                    case "r": text.append("\r")
                    default: text.append(escaped)
                    }
                    advance()
                } else if character == "\"" {
                    advance()
                    append(.string, text: text, from: start)
                    return nil
                } else {
                    text.append(character)
                    advance()
                }
            }
            if !lenient { return .unterminatedString }
            append(.string, text: text, from: start, unterminated: true)
            return nil
        }

        /// `--` or `#` up to (not including) the end of the line.
        private mutating func scanLineComment(from start: String.Index) {
            while index < source.endIndex, !source[index].isNewline { advance() }
            append(.comment, text: String(source[start..<index]), from: start)
        }

        /// `(* … *)`, nested. The first `*)` at depth 1 closes it, whatever quotes sit inside.
        private mutating func scanBlockComment(from start: String.Index) -> Failure? {
            advance(2)
            var depth = 1
            while index < source.endIndex {
                if source[index] == "(", peek(1) == "*" {
                    depth += 1
                    advance(2)
                } else if source[index] == "*", peek(1) == ")" {
                    depth -= 1
                    advance(2)
                    if depth == 0 {
                        append(.comment, text: String(source[start..<index]), from: start)
                        return nil
                    }
                } else {
                    advance()
                }
            }
            if !lenient { return .unterminatedComment }
            append(.comment, text: String(source[start..<index]), from: start, unterminated: true)
            return nil
        }

        /// `«…»` or `<<…>>`; a nested opener is unbalanced.
        private mutating func scanChevron(from start: String.Index, closing: String) -> Failure? {
            let openerLength = closing.count
            advance(openerLength)
            let contentStart = index
            while index < source.endIndex {
                if source[index...].hasPrefix(closing) {
                    let content = String(source[contentStart..<index])
                    advance(openerLength)
                    append(.chevron, text: content, from: start)
                    return nil
                }
                if source[index] == "«" || source[index...].hasPrefix("<<") {
                    if !lenient { return .unbalancedChevron }
                }
                advance()
            }
            if !lenient { return .unterminatedChevron }
            append(.chevron, text: String(source[contentStart..<index]), from: start, unterminated: true)
            return nil
        }

        /// `|any text|` on one line.
        private mutating func scanPipedIdentifier(from start: String.Index) -> Failure? {
            advance()
            let contentStart = index
            while index < source.endIndex, !source[index].isNewline {
                if source[index] == "|" {
                    let content = String(source[contentStart..<index])
                    advance()
                    append(.word, text: content, from: start, piped: true)
                    return nil
                }
                advance()
            }
            if !lenient { return .unterminatedIdentifier }
            append(.word, text: String(source[contentStart..<index]), from: start, piped: true, unterminated: true)
            return nil
        }

        /// Digits, an optional fraction and an optional exponent.
        private mutating func scanNumber() {
            while index < source.endIndex, source[index].isASCII, source[index].isNumber { advance() }
            if index < source.endIndex, source[index] == ".", let next = peek(1), next.isASCII, next.isNumber {
                advance()
                while index < source.endIndex, source[index].isASCII, source[index].isNumber { advance() }
            }
            if index < source.endIndex, source[index] == "e" || source[index] == "E" {
                var lookahead = 1
                if let sign = peek(1), sign == "+" || sign == "-" { lookahead = 2 }
                if let digit = peek(lookahead), digit.isASCII, digit.isNumber {
                    advance(lookahead)
                    while index < source.endIndex, source[index].isASCII, source[index].isNumber { advance() }
                }
            }
        }

        // MARK: Helpers

        private func peek(_ offset: Int) -> Character? {
            guard let position = source.index(index, offsetBy: offset, limitedBy: source.endIndex),
                  position < source.endIndex else { return nil }
            return source[position]
        }

        private func isWordCharacter(_ character: Character?) -> Bool {
            guard let character else { return false }
            return character.isLetter || character.isNumber || character == "_"
        }

        private mutating func advance(_ count: Int = 1) {
            index = source.index(index, offsetBy: count, limitedBy: source.endIndex) ?? source.endIndex
        }

        private mutating func append(_ kind: ScriptToken.Kind, text: String, from start: String.Index,
                                     piped: Bool = false, unterminated: Bool = false) {
            tokens.append(ScriptToken(kind: kind, text: text, range: start..<index, isPiped: piped,
                                      isUnterminated: unterminated))
        }
    }
}
