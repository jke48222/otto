//
//  SpeechChunker.swift
//  Otto
//
//  Turns a streaming Markdown reply into sentences worth reading aloud. It works on complete lines only
//  (until the reply is final), skips code, tables, rules and Otto's own notes, keeps the words of links
//  and emphasis, and holds the last sentence back until more text, a paragraph break or the end completes
//  it. Feeding the reply character by character gives exactly the sentences that feeding it whole gives.
//

import Foundation
import NaturalLanguage

struct SpeechChunker {
    /// Said once per reply, where the first code block starts.
    static let codePhrase = "I've put the code in the notch."
    /// Said for a bare web address.
    static let linkPhrase = "a link"

    private static let newline = UTF16.CodeUnit(0x0A)

    /// UTF-16 offset of the first character not yet read as part of a line.
    private var consumedOffset = 0
    private var inCodeFence = false
    private var announcedCode = false
    /// Cleaned prose that hasn't been spoken yet; its last sentence may still be growing.
    private var pending = ""

    init() {}

    /// Feed the whole reply text so far; returns the sentences that became complete since the last call.
    /// `isFinal` flushes the trailing sentence.
    mutating func consume(_ fullText: String, isFinal: Bool) -> [String] {
        let utf16 = fullText.utf16
        guard utf16.count >= consumedOffset else { return [] }
        let unread = utf16.dropFirst(consumedOffset)
        let end: String.UTF16View.Index
        if isFinal {
            end = unread.endIndex
        } else if let lastNewline = unread.lastIndex(of: Self.newline) {
            end = utf16.index(after: lastNewline)
        } else {
            end = unread.startIndex
        }
        // Line ends are "\n" code units, so the chunk never starts or ends inside a character.
        let chunk = unread[unread.startIndex..<end]
        consumedOffset += chunk.count
        let readable = String(decoding: chunk, as: UTF16.self)

        var output: [String] = []
        if !readable.isEmpty {
            var lines = readable.components(separatedBy: "\n")
            // "a\nb\n" splits into ["a", "b", ""]: the empty tail is the next line, not a blank line.
            if readable.hasSuffix("\n") { lines.removeLast() }
            for line in lines {
                output += read(line: line)
            }
        }
        if isFinal {
            output += drain(flush: true)
        }
        return output
    }

    // MARK: - Lines

    private enum LineKind {
        case fence, blank, skipped, block(String), prose(String)
    }

    private mutating func read(line: String) -> [String] {
        switch Self.classify(line, inCodeFence: inCodeFence) {
        case .fence:
            inCodeFence.toggle()
            guard inCodeFence else { return [] }
            var output = drain(flush: true)
            if !announcedCode {
                announcedCode = true
                output.append(Self.codePhrase)
            }
            return output
        case .blank, .skipped:
            return drain(flush: true)
        case .block(let text):
            var output = drain(flush: true)
            pending = text
            output += drain(flush: true)
            return output
        case .prose(let text):
            pending = pending.isEmpty ? text : pending + " " + text
            return drain(flush: false)
        }
    }

    private static func classify(_ line: String, inCodeFence: Bool) -> LineKind {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { return .fence }
        if inCodeFence { return .skipped }
        if trimmed.isEmpty { return .blank }
        if trimmed.hasPrefix("|") || isHorizontalRule(trimmed) || isOttoNote(trimmed) { return .skipped }
        let isBlock = trimmed.hasPrefix("#") || listMarker.firstMatch(in: trimmed, range: nsRange(trimmed)) != nil
        let text = speakable(trimmed)
        guard !text.isEmpty else { return .skipped }
        return isBlock ? .block(text) : .prose(text)
    }

    /// "---", "***", "___" (three or more, spaces allowed).
    private static func isHorizontalRule(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// Otto's own italic notes, like "_(Reply truncated.)_" and "_(Stopped after several web lookups.)_".
    private static func isOttoNote(_ line: String) -> Bool {
        line.hasPrefix("_(") && line.hasSuffix(")_")
    }

    // MARK: - Sentences

    /// Splits the pending prose into sentences. Everything but the last sentence is complete; the last one
    /// is complete only when flushing.
    private mutating func drain(flush: Bool) -> [String] {
        guard !pending.isEmpty else { return [] }
        let text = pending
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let ranges = tokenizer.tokens(for: text.startIndex..<text.endIndex)
        guard let last = ranges.last else {
            if flush { pending = "" }
            return flush ? Self.spoken([text[...]]) : []
        }
        if flush {
            pending = ""
            return Self.spoken(ranges.map { text[$0] })
        }
        pending = String(text[last.lowerBound...])
        return Self.spoken(ranges.dropLast().map { text[$0] })
    }

    private static func spoken(_ pieces: [Substring]) -> [String] {
        pieces.compactMap { piece in
            let sentence = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasWords = sentence.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            return hasWords ? sentence : nil
        }
    }

    // MARK: - Markdown → words

    private static func speakable(_ line: String) -> String {
        var text = line
        text = replace(heading, in: text, with: "")
        text = replace(quote, in: text, with: "")
        text = replace(listMarker, in: text, with: "")
        text = replace(taskBox, in: text, with: "")
        text = replace(image, in: text, with: "$1")
        text = replace(link, in: text, with: "$1")
        text = replace(autolink, in: text, with: linkPhrase)
        text = replace(bareURL, in: text, with: linkPhrase)
        text = replace(inlineCode, in: text, with: "$1")
        text = replace(strong, in: text, with: "$2")
        text = replace(strike, in: text, with: "$1")
        text = replace(emphasisStar, in: text, with: "$1")
        text = replace(emphasisUnderscore, in: text, with: "$1")
        text = replace(whitespace, in: text, with: " ")
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static let heading = regex("^#{1,6}\\s*")
    private static let quote = regex("^(?:>\\s?)+")
    private static let listMarker = regex("^(?:[-*+]|\\d{1,3}[.)])\\s+")
    private static let taskBox = regex("^\\[[ xX]\\]\\s+")
    private static let image = regex("!\\[([^\\]]*)\\]\\([^)]*\\)")
    private static let link = regex("\\[([^\\]]+)\\]\\([^)]*\\)")
    private static let autolink = regex("<https?://[^>\\s]+>")
    private static let bareURL = regex("https?://[^\\s<>]*[^\\s<>.,;:!?'\")\\]]")
    private static let inlineCode = regex("`+([^`]*)`+")
    private static let strong = regex("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let strike = regex("~~(?=\\S)(.+?)(?<=\\S)~~")
    private static let emphasisStar = regex("(?<![\\w*])\\*(?=\\S)(.+?)(?<=\\S)\\*(?![\\w*])")
    private static let emphasisUnderscore = regex("(?<![\\w_])_(?=\\S)(.+?)(?<=\\S)_(?![\\w_])")
    private static let whitespace = regex("\\s+")

    private static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("SpeechChunker pattern \(pattern) doesn't compile: \(error)")
        }
    }

    private static func replace(_ expression: NSRegularExpression, in text: String, with template: String) -> String {
        expression.stringByReplacingMatches(in: text, range: nsRange(text), withTemplate: template)
    }

    private static func nsRange(_ text: String) -> NSRange {
        NSRange(text.startIndex..<text.endIndex, in: text)
    }
}
