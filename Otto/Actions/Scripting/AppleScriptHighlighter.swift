//
//  AppleScriptHighlighter.swift
//  Otto
//
//  Syntax colors for the AppleScript shown on approval cards and in tool rows. The text of the result
//  is exactly the source (every character, tabs and line breaks included); only attributes are added,
//  so the code view can never show something other than what runs.
//

import SwiftUI

enum AppleScriptHighlighter {
    /// Keywords drawn in `Theme.link` semibold.
    static let keywords: Set<String> = [
        "tell", "end", "to", "set", "get", "copy", "if", "then", "else", "repeat", "with", "while", "until", "times",
        "from", "in", "by", "of", "return", "on", "try", "error", "the", "application", "app", "every", "whose",
        "as", "and", "or", "not", "is", "contains", "my", "it", "me", "script", "property", "global", "local",
        "considering", "ignoring", "exit",
    ]

    enum Palette {
        static let keyword = Theme.link
        static let string = Theme.rgb(0xC9D3B4)
        static let comment = Theme.textTertiary
        static let number = Theme.rgb(0xD8B98A)
        /// `do shell script` and raw «…» codes.
        static let danger = Theme.error
        static let plain = Theme.codeText
    }

    static let fontSize: CGFloat = 12

    /// Pure: the characters of the result equal `source`.
    static func highlight(_ source: String) -> AttributedString {
        let tokens = ScriptLexer.tokenizeLeniently(source)
        let styles = styles(for: tokens)
        var result = AttributedString()
        var cursor = source.startIndex
        for (token, style) in zip(tokens, styles) {
            if cursor < token.range.lowerBound {
                result.append(segment(source[cursor..<token.range.lowerBound], style: .plain))
            }
            result.append(segment(source[token.range], style: style))
            cursor = token.range.upperBound
        }
        if cursor < source.endIndex {
            result.append(segment(source[cursor...], style: .plain))
        }
        return result
    }

    // MARK: - Styles

    enum Style: Equatable {
        case plain, keyword, string, appName, comment, number, danger
    }

    /// One style per token. `do shell script` is danger as a phrase; the string after `application`/`app`
    /// (optionally `id`) is an app name.
    static func styles(for tokens: [ScriptToken]) -> [Style] {
        var styles: [Style] = tokens.map { token in
            switch token.kind {
            case .word:
                return !token.isPiped && keywords.contains(token.text.lowercased()) ? .keyword : .plain
            case .string: return .string
            case .comment: return .comment
            case .number: return .number
            case .chevron: return .danger
            case .ampersand, .possessive, .continuation, .newline, .symbol: return .plain
            }
        }

        let words = tokens.indices.filter { tokens[$0].kind == .word && !tokens[$0].isPiped }
        for (position, index) in words.enumerated() where position + 2 < words.count {
            let phrase = [index, words[position + 1], words[position + 2]]
            guard phrase == [index, index + 1, index + 2] else { continue }
            let text = phrase.map { tokens[$0].text.lowercased() }
            if text == ["do", "shell", "script"] {
                for member in phrase { styles[member] = .danger }
            }
        }

        for index in tokens.indices where tokens[index].kind == .word && !tokens[index].isPiped {
            let word = tokens[index].text.lowercased()
            guard word == "application" || word == "app" else { continue }
            var next = index + 1
            if next < tokens.count, tokens[next].kind == .word, tokens[next].text.lowercased() == "id" { next += 1 }
            if next < tokens.count, tokens[next].kind == .string { styles[next] = .appName }
        }
        return styles
    }

    private static func segment(_ text: Substring, style: Style) -> AttributedString {
        var container = AttributeContainer()
        switch style {
        case .plain:
            container.swiftUI.foregroundColor = Palette.plain
            container.swiftUI.font = Theme.mono(fontSize)
        case .keyword:
            container.swiftUI.foregroundColor = Palette.keyword
            container.swiftUI.font = Theme.mono(fontSize, .semibold)
        case .string:
            container.swiftUI.foregroundColor = Palette.string
            container.swiftUI.font = Theme.mono(fontSize)
        case .appName:
            container.swiftUI.foregroundColor = Palette.string
            container.swiftUI.font = Theme.mono(fontSize)
            container.swiftUI.underlineStyle = .single
        case .comment:
            container.swiftUI.foregroundColor = Palette.comment
            container.swiftUI.font = Theme.mono(fontSize).italic()
        case .number:
            container.swiftUI.foregroundColor = Palette.number
            container.swiftUI.font = Theme.mono(fontSize)
        case .danger:
            container.swiftUI.foregroundColor = Palette.danger
            container.swiftUI.font = Theme.mono(fontSize, .semibold)
        }
        return AttributedString(String(text), attributes: container)
    }
}
