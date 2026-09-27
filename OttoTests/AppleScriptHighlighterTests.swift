//
//  AppleScriptHighlighterTests.swift
//  OttoTests
//
//  Highlighting adds colors only: the text is always exactly the source. Keywords, strings with escaped
//  quotes, nested block comments, numbers, app names and `do shell script` get their token styles.
//

import SwiftUI
import XCTest
@testable import Otto

final class AppleScriptHighlighterTests: XCTestCase {
    private typealias Style = AppleScriptHighlighter.Style

    /// The style of the first token whose source text is `text`.
    private func style(of text: String, in source: String) -> Style? {
        let tokens = ScriptLexer.tokenizeLeniently(source)
        let styles = AppleScriptHighlighter.styles(for: tokens)
        guard let index = tokens.firstIndex(where: { String(source[$0.range]) == text }) else { return nil }
        return styles[index]
    }

    /// The foreground color of the attributed run that covers the first occurrence of `text`.
    private func color(of text: String, in source: String) -> Color? {
        let attributed = AppleScriptHighlighter.highlight(source)
        guard let range = attributed.range(of: text) else { return nil }
        return attributed[range].runs.first?[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self]
    }

    func testTextIsExactlyTheSource() {
        let sources = [
            "tell application \"Finder\" to get name of every disk",
            "set s to \"a \\\"b\\\"\"\t-- comment\r\nbeep 3\n",
            "(* outer (* inner *) *) do shell script \"id\"",
            "display dialog \"unterminated",
            "«event sysoexec» ¬\n  \"x\"",
            "",
            "   \n\n\t",
        ]
        for source in sources {
            XCTAssertEqual(String(AppleScriptHighlighter.highlight(source).characters), source)
        }
    }

    func testKeywords() {
        let source = "tell application \"Finder\" to get name of every disk"
        XCTAssertEqual(style(of: "tell", in: source), .keyword)
        XCTAssertEqual(style(of: "every", in: source), .keyword)
        XCTAssertEqual(style(of: "name", in: source), .plain)
        XCTAssertEqual(color(of: "tell", in: source), AppleScriptHighlighter.Palette.keyword)
        XCTAssertEqual(color(of: "disk", in: source), AppleScriptHighlighter.Palette.plain)
    }

    func testStringsWithEscapedQuotes() {
        let source = "set s to \"say \\\"hi\\\"\" & 5"
        XCTAssertEqual(style(of: "\"say \\\"hi\\\"\"", in: source), .string)
        XCTAssertEqual(style(of: "5", in: source), .number)
        XCTAssertEqual(color(of: "say", in: source), AppleScriptHighlighter.Palette.string)
    }

    func testBlockAndLineComments() {
        let source = "(* a (* nested *) b *) beep -- trailing"
        XCTAssertEqual(style(of: "(* a (* nested *) b *)", in: source), .comment)
        XCTAssertEqual(style(of: "-- trailing", in: source), .comment)
        XCTAssertEqual(color(of: "nested", in: source), AppleScriptHighlighter.Palette.comment)
        XCTAssertEqual(style(of: "beep", in: source), .plain)
    }

    func testDoShellScriptIsDanger() {
        let source = "do shell script \"ls\""
        XCTAssertEqual(style(of: "do", in: source), .danger)
        XCTAssertEqual(style(of: "shell", in: source), .danger)
        XCTAssertEqual(style(of: "script", in: source), .danger)
        XCTAssertEqual(color(of: "shell", in: source), AppleScriptHighlighter.Palette.danger)
        // "script" alone stays a keyword.
        XCTAssertEqual(style(of: "script", in: "run script x"), .keyword)
    }

    func testAppNamesAreUnderlined() {
        let source = "tell application id \"com.apple.Music\" to pause"
        XCTAssertEqual(style(of: "\"com.apple.Music\"", in: source), .appName)
        let attributed = AppleScriptHighlighter.highlight("tell app \"Safari\" to activate")
        let range = attributed.range(of: "\"Safari\"")
        XCTAssertNotNil(range)
        if let range {
            XCTAssertEqual(attributed[range].runs.first?[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self], .single)
        }
    }

    func testChevronsAreDanger() {
        XCTAssertEqual(style(of: "«event sysoexec»", in: "«event sysoexec» \"id\""), .danger)
    }

    func testUnterminatedStringRunsToTheEnd() {
        let source = "display dialog \"open"
        XCTAssertEqual(style(of: "\"open", in: source), .string)
    }
}
