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

    // MARK: Streaming tail styling

    /// The streaming tail block styles its settled lines once and only re-styles the rest, yet every delta renders
    /// exactly what healing and styling the whole block would.
    func testStreamingInlineMatchesFullStylingForEveryDelta() {
        let lines = (0..<160).map { index -> String in
            switch index % 6 {
            case 0: return "line \(index) with **bold** and `code_\(index)` then [link](https://e.com/\(index))"
            case 1: return "plain entry snake_case_name \(index)"
            case 2: return "an *emphasis* here and ~~strike~~ there \(index)"
            case 3: return "**strong that spans"
            case 4: return "the next line** and a `span that"
            default: return "also spans` lines \(index), 2 * 3 = 6"
            }
        }
        let text = lines.joined(separator: "\n")
        let characters = Array(text)
        let cache = MarkdownCache()
        var end = 0
        var settledAtSomePoint = false
        while end < characters.count {
            end = min(characters.count, end + 37)
            let source = String(characters[..<end])
            let incremental = cache.streamingInline(source, codeSize: 12, strongSize: 14)
            let full = cache.inline(MarkdownParser.healStreamingTail(source), codeSize: 12, strongSize: 14,
                                    cacheable: false)
            XCTAssertEqual(incremental, full, "at \(end)")
            if cache.settledStreamingLength > 0 { settledAtSomePoint = true }
        }
        XCTAssertTrue(settledAtSomePoint, "a long block settles its closed lines")
    }

    func testStreamingInlineStartsOverForAnotherBlock() {
        let cache = MarkdownCache()
        let first = String(repeating: "A settled line with **bold** text.\n", count: 60) + "tail"
        _ = cache.streamingInline(first, codeSize: 12)
        XCTAssertGreaterThan(cache.settledStreamingLength, 0)
        let other = "A different block with `code"
        XCTAssertEqual(cache.streamingInline(other, codeSize: 12),
                       cache.inline(MarkdownParser.healStreamingTail(other), codeSize: 12, cacheable: false))
        XCTAssertEqual(cache.settledStreamingLength, 0)
    }

    /// Streams `text` in 120-character deltas, checking every delta against healing and styling the whole block;
    /// returns the settled length at the end.
    @discardableResult
    private func streamAndCompare(_ text: String, cache: MarkdownCache? = nil, step: Int = 120,
                                  file: StaticString = #filePath, line: UInt = #line) -> Int {
        let cache = cache ?? MarkdownCache()
        let characters = Array(text)
        var end = 0
        while end < characters.count {
            end = min(characters.count, end + step)
            let source = String(characters[..<end])
            let incremental = cache.streamingInline(source, codeSize: 12, strongSize: 14)
            let full = cache.inline(MarkdownParser.healStreamingTail(source), codeSize: 12, strongSize: 14,
                                    cacheable: false)
            XCTAssertEqual(incremental, full, "at \(end)", file: file, line: line)
        }
        return cache.settledStreamingLength
    }

    /// One literal `~`, `[1]` or glued `*` near the start of a long paragraph no longer keeps the rest of it from
    /// settling, and the paragraph still renders exactly as a full restyle would, including once the run closes.
    func testStreamingParagraphSettlesPastAnEarlyOpenRun() {
        let sentence = "Each step writes its output to the shelf before the next one starts. "
        let body = String(repeating: sentence, count: 90)
        for opener in ["This usually takes ~5 minutes. ", "As the docs say [1], it works. ", "Compute 2*3 first. "] {
            let settled = streamAndCompare(opener + body)
            XCTAssertGreaterThan(settled, body.utf8.count / 2, "settles after \(opener.debugDescription)")
        }
        // The open run closes much later: the provisional part falls back and styling stays exact throughout.
        let closing = "This usually takes ~5 minutes. " + body + "and then 10~ more. " + body + "Also 2*3 and 4* done. "
            + body
        XCTAssertGreaterThan(streamAndCompare(closing), 0)
    }

    /// A block that follows one whose settling was refused starts from scratch instead of inheriting its attempts.
    func testNewStreamingBlockDoesNotInheritRefusedAttempts() {
        let cache = MarkdownCache()
        let refused = "`" + String(repeating: "an open code span that never closes here. ", count: 80)
        streamAndCompare(refused, cache: cache)
        XCTAssertEqual(cache.settledStreamingLength, 0)
        let clean = String(repeating: "A clean sentence in the next block. ", count: 60)
        XCTAssertGreaterThan(streamAndCompare(clean, cache: cache), 0)
    }

    func testStreamingCJKParagraphSettles() {
        let text = String(repeating: "这是一个很长的段落，用来测试流式渲染。它没有空格！真的吗？", count: 80)
        XCTAssertGreaterThan(streamAndCompare(text), 0)
    }

    func testCitationBracketsAndOpenRunsAreReadCorrectly() {
        func open(_ source: String) -> Set<Character>? {
            MarkdownCache.openDelimiters(in: MarkdownCache().inline(source, codeSize: 12, cacheable: false))
        }
        XCTAssertEqual(open("as cited [1] and [2, 3] here\n"), [])
        XCTAssertNil(open("see [1](foo\n"), "a link destination can continue on the next line")
        XCTAssertNil(open("see [the docs\n"), "an open bracket")
        XCTAssertEqual(open("takes ~5 minutes\n"), ["~"])
        XCTAssertEqual(open("compute 2*3 now\n"), ["*"])
        XCTAssertEqual(open("a ~b~ c and ~~d~~\n"), [])
    }

    func testOnlyFullyClosedInlineTextSettles() {
        func settled(_ source: String) -> Bool {
            MarkdownCache.isSettledInline(MarkdownCache().inline(source, codeSize: 12, cacheable: false))
        }
        XCTAssertTrue(settled("plain words and snake_case_names\n"))
        XCTAssertTrue(settled("**bold** *em* `a*b[c]` [link](https://e.com) ~~gone~~\n"))
        XCTAssertFalse(settled("**bold that spans\n"), "an open strong run")
        XCTAssertFalse(settled("*a * b\n"), "a star that a later one could close")
        XCTAssertFalse(settled("a `span that\n"), "an open code span")
        XCTAssertFalse(settled("[title](https://e.com/part\n"), "an open link")
        XCTAssertFalse(settled("_leading underscore\n"), "an underscore that can open emphasis")
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
