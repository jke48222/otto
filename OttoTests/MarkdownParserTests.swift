//
//  MarkdownParserTests.swift
//  Otto
//

import XCTest
@testable import Otto

/// Covers the Markdown renderer's parser: streaming-tail healing, CommonMark paragraph interruption,
/// the incremental (streaming) parse, the link policy and ordered-marker measurement.
@MainActor
final class MarkdownParserTests: XCTestCase {
    // MARK: Healing

    func testHealClosesOpenCodeSpanWithRunOfSameLength() {
        XCTAssertEqual(MarkdownParser.healStreamingTail("use `code"), "use `code`")
        XCTAssertEqual(MarkdownParser.healStreamingTail("``x ` y"), "``x ` y``")
        // A partially streamed closing run is completed rather than doubled.
        XCTAssertEqual(MarkdownParser.healStreamingTail("``x ` y`"), "``x ` y``")
        // Closed double-backtick spans are left alone.
        XCTAssertEqual(MarkdownParser.healStreamingTail("``x ` y``"), "``x ` y``")
        // An opening run with nothing after it yet is dropped.
        XCTAssertEqual(MarkdownParser.healStreamingTail("done `"), "done ")
    }

    func testHealIgnoresBracketsInsideCodeAndSubscripts() {
        XCTAssertEqual(MarkdownParser.healStreamingTail("Index with `items[i"), "Index with `items[i`")
        XCTAssertEqual(MarkdownParser.healStreamingTail("use `arr[i` now"), "use `arr[i` now")
        XCTAssertEqual(MarkdownParser.healStreamingTail("arr[0"), "arr[0")
    }

    func testHealDanglingLinks() {
        XCTAssertEqual(MarkdownParser.healStreamingTail("see [the docs"), "see the docs")
        XCTAssertEqual(MarkdownParser.healStreamingTail("see [the docs](https://exa"), "see the docs")
        XCTAssertEqual(MarkdownParser.healStreamingTail("[a](b) and [c"), "[a](b) and c")
        XCTAssertEqual(MarkdownParser.healStreamingTail("![alt](https://x"), "")
    }

    func testHealStrongOutsideCodeOnly() {
        XCTAssertEqual(MarkdownParser.healStreamingTail("**bold"), "**bold**")
        XCTAssertEqual(MarkdownParser.healStreamingTail("**bold "), "**bold**")
        XCTAssertEqual(MarkdownParser.healStreamingTail("**bold `co"), "**bold `co`**")
        XCTAssertEqual(MarkdownParser.healStreamingTail("`**` and **x"), "`**` and **x**")
    }

    // MARK: Paragraph interruption

    func testOnlyOrderedItemStartingAtOneInterruptsParagraph() {
        XCTAssertEqual(
            MarkdownParser.parse("The year was\n2024. It was great."),
            [.paragraph("The year was\n2024. It was great.")]
        )
        XCTAssertEqual(MarkdownParser.parse("Steps:\n1. Open\n2. Paste").count, 2)
        XCTAssertEqual(MarkdownParser.parse("Intro\n- a\n- b").count, 2)
        // An empty item never interrupts a paragraph.
        XCTAssertEqual(MarkdownParser.parse("Intro\n-\nmore").count, 1)
        // Not interrupting a paragraph, any number starts a list.
        XCTAssertEqual(
            MarkdownParser.parse("2024. A year"),
            [.list([MarkdownListItem(level: 0, marker: .ordered(2024), text: "A year")])]
        )
    }

    // MARK: Incremental streaming parse

    func testStreamingParseMatchesFullParseForEveryPrefix() {
        let documents = [
            "# Title\n\nSome **bold** text\nwith two lines.\n\n- one\n- two\n\n  continued para\n\n- three\n\n1. a\n2. b\n\n10. c\n\nPara after list.\n\n```swift\nlet x = 1\n\nlet y = 2\n```\n\n> quote\n> more\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n---\n\nFinal `code` para.\n",
            "Intro:\n\n```\nunclosed fence\n\n- not a list\n\nstill code\n",
            "- a\n\n- b\n\n    - nested\n\nend\n\n~~~\ntilde\n~~~\n\nx\ty\n\n\tindented tab\n\nlast",
            "Line\r\n\r\nCRLF para\r\n\r\n- item\r\n\r\nafter\r\n",
            "> q1\n\n> q2\n\npara\n* star\n\n+ plus\n\n3) paren\n\ntext",
        ]
        for document in documents {
            let cache = MarkdownCache()
            var prefix = ""
            for character in document {
                prefix.append(character)
                XCTAssertEqual(
                    cache.blocks(for: prefix, streaming: true),
                    MarkdownParser.parse(prefix),
                    "prefix: \(prefix.debugDescription)"
                )
            }
        }
    }

    func testStreamingParseRecoversWhenTextIsReplaced() {
        let cache = MarkdownCache()
        _ = cache.blocks(for: "First para.\n\nSecond para.\n\nThird", streaming: true)
        // A different reply (e.g. a retry) must not reuse the old settled blocks.
        let other = "Other.\n\nText"
        XCTAssertEqual(cache.blocks(for: other, streaming: true), MarkdownParser.parse(other))
    }

    func testSplitPointsAvoidFencesAndListContinuations() {
        let text = "a\n\n```\ncode\n\nmore\n```\n\n- item\n\n  continuation\n\nnext\n"
        guard let split = MarkdownParser.lastSafeSplit(in: text, from: text.startIndex) else {
            return XCTFail("expected a split point")
        }
        XCTAssertTrue(text[split...].hasPrefix("next"))
    }

    // MARK: Links

    func testOnlyWebAndMailLinksStayClickable() {
        XCTAssertTrue(MarkdownLinkPolicy.isAllowed(URL(string: "https://example.com")!))
        XCTAssertTrue(MarkdownLinkPolicy.isAllowed(URL(string: "http://example.com/a")!))
        XCTAssertTrue(MarkdownLinkPolicy.isAllowed(URL(string: "mailto:someone@example.com")!))
        for blocked in [
            "file:///System/Applications/Calculator.app",
            "smb://evil.example/share",
            "shortcuts://run-shortcut?name=Upload",
            "javascript:alert(1)",
            "vscode://file/etc/passwd",
            "x-apple.systempreferences:com.apple.preference.security",
            "relative/path",
        ] {
            XCTAssertFalse(MarkdownLinkPolicy.isAllowed(URL(string: blocked)!), blocked)
        }

        let styled = MarkdownCache().inline(
            "[a](file:///x) and [b](https://ok.example) and [c](smb://evil.example/s)",
            codeSize: 12
        )
        XCTAssertEqual(styled.runs.compactMap(\.link), [URL(string: "https://ok.example")!])
        XCTAssertEqual(String(styled.characters), "a and b and c")
    }

    // MARK: Lists

    func testOrderedMarkerColumnFitsItsWidestLabel() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        for number in [1, 9, 10, 99, 100, 2024] {
            let label = MarkdownListMetrics.orderedLabel(number) as NSString
            let needed = label.size(withAttributes: [.font: font]).width
            let items = [MarkdownListItem(level: 0, marker: .ordered(number), text: "x")]
            XCTAssertGreaterThanOrEqual(MarkdownListMetrics.markerColumnWidth(for: items, baseSize: 14), needed, "\(number).")
        }
    }
}
