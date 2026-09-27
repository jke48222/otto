//
//  RichTextRendererTests.swift
//  OttoTests
//
//  Code-only detection, plain text, HTML and RTF for pasted answers.
//

import AppKit
import XCTest
@testable import Otto

final class RichTextRendererTests: XCTestCase {
    // MARK: Code-only answers

    func testSingleClosedFenceIsCodeOnly() {
        XCTAssertEqual(RichTextRenderer.codeOnlyContent("```swift\nlet x = 1\n```"), "let x = 1")
        XCTAssertEqual(RichTextRenderer.codeOnlyContent("\n\n  ```\nline one\n\tindented\n```  \n\n"), "line one\n\tindented")
        XCTAssertEqual(RichTextRenderer.codeOnlyContent("~~~~\n```\nnested\n```\n~~~~"), "```\nnested\n```")
        XCTAssertEqual(RichTextRenderer.codeOnlyBlock("```bash title\necho hi\n```")?.language, "bash")
        XCTAssertNil(RichTextRenderer.codeOnlyBlock("```\necho hi\n```")?.language)
        XCTAssertEqual(RichTextRenderer.codeOnlyContent("```\n```"), "")
    }

    func testProseAroundAFenceIsNotCodeOnly() {
        XCTAssertNil(RichTextRenderer.codeOnlyContent("Try this:\n\n```\nls\n```"))
        XCTAssertNil(RichTextRenderer.codeOnlyContent("```\nls\n```\n\nThat lists files."))
    }

    func testUnclosedFenceIsNotCodeOnly() {
        XCTAssertNil(RichTextRenderer.codeOnlyContent("```swift\nlet x = 1"))
        XCTAssertNil(RichTextRenderer.codeOnlyContent("````\ncode\n```"))
    }

    func testTwoFencesAreNotCodeOnly() {
        XCTAssertNil(RichTextRenderer.codeOnlyContent("```\none\n```\n```\ntwo\n```"))
        XCTAssertNil(RichTextRenderer.codeOnlyContent("```\none\n```\n\n```\ntwo\n```"))
    }

    // MARK: Plain text

    func testPlainHeadingsParagraphsAndInline() {
        let markdown = "# Title\n\nSome **bold**, *italic*, `code` and ~~gone~~ text."
        XCTAssertEqual(RichTextRenderer.plainText(markdown), "Title\n\nSome bold, italic, code and gone text.")
    }

    func testPlainLists() {
        let markdown = "- one\n  - nested\n- two\n\nSteps:\n\n1. first\n2. second\n\nTasks:\n\n- [ ] todo\n- [x] done"
        XCTAssertEqual(RichTextRenderer.plainText(markdown),
                       "- one\n  - nested\n- two\n\nSteps:\n\n1. first\n2. second\n\nTasks:\n\n- [ ] todo\n- [x] done")
    }

    func testPlainQuotesKeepTheirMarker() {
        XCTAssertEqual(RichTextRenderer.plainText("> quoted line\n> second"), "> quoted line\n> second")
    }

    func testPlainLinks() {
        XCTAssertEqual(RichTextRenderer.plainText("See [the docs](https://example.com/docs)."),
                       "See the docs (https://example.com/docs).")
        XCTAssertEqual(RichTextRenderer.plainText("<https://example.com>"), "https://example.com")
        XCTAssertEqual(RichTextRenderer.plainText("[https://example.com](https://example.com)"), "https://example.com")
        // A link Otto wouldn't open keeps only its text.
        XCTAssertEqual(RichTextRenderer.plainText("[run me](file:///Applications/Calculator.app)"), "run me")
    }

    func testPlainCodeBlocksAreVerbatimWithoutFences() {
        XCTAssertEqual(RichTextRenderer.plainText("Before\n\n```sh\necho hi\n```\n\nAfter"), "Before\n\necho hi\n\nAfter")
    }

    func testPlainTablesAreTabSeparated() {
        let markdown = "| Name | Size |\n|---|---|\n| a.txt | 1 KB |\n| **b** | 2 KB |"
        XCTAssertEqual(RichTextRenderer.plainText(markdown), "Name\tSize\na.txt\t1 KB\nb\t2 KB")
    }

    func testPlainRulesBecomeTheBlankLine() {
        XCTAssertEqual(RichTextRenderer.plainText("Above\n\n---\n\nBelow"), "Above\n\nBelow")
    }

    // MARK: HTML

    func testHTMLIsWrappedAndEscaped() {
        let html = RichTextRenderer.html("Use <b> & \"quotes\" 'here'")
        XCTAssertTrue(html.hasPrefix("<html><head><meta charset=\"utf-8\"></head><body>"))
        XCTAssertTrue(html.hasSuffix("</body></html>"))
        XCTAssertTrue(html.contains("<p>Use &lt;b&gt; &amp; &quot;quotes&quot; &#39;here&#39;</p>"))
    }

    func testHTMLInlineAndBlocks() {
        let html = RichTextRenderer.html("## Heading\n\n**b** *i* `c` ~~s~~ [l](https://example.com?a=1&b=2)\n\n> quote\n\n---")
        XCTAssertTrue(html.contains("<h2>Heading</h2>"))
        XCTAssertTrue(html.contains("<strong>b</strong>"))
        XCTAssertTrue(html.contains("<em>i</em>"))
        XCTAssertTrue(html.contains("<code>c</code>"))
        XCTAssertTrue(html.contains("<del>s</del>"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com?a=1&amp;b=2\">l</a>"))
        XCTAssertTrue(html.contains("<blockquote><p>quote</p></blockquote>"))
        XCTAssertTrue(html.contains("<hr>"))
    }

    func testHTMLNestedLists() {
        let html = RichTextRenderer.html("- a\n  1. x\n  2. y\n- b\n\nNext:\n\n3. three\n4. four\n\nTasks:\n\n- [x] done")
        XCTAssertTrue(html.contains("<ul><li>a<ol><li>x</li><li>y</li></ol></li><li>b</li></ul>"), html)
        XCTAssertTrue(html.contains("<ol start=\"3\"><li>three</li><li>four</li></ol>"), html)
        XCTAssertTrue(html.contains("<ul><li>☑ done</li></ul>"), html)
    }

    func testHTMLCodeAndTables() {
        let html = RichTextRenderer.html("```swift\nif a < b {}\n```\n\n| H |\n|---|\n| <x> |")
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">if a &lt; b {}</code></pre>"), html)
        XCTAssertTrue(html.contains("<table><thead><tr><th>H</th></tr></thead><tbody><tr><td>&lt;x&gt;</td></tr></tbody></table>"),
                      html)
    }

    func testHTMLDropsDisallowedLinkSchemes() {
        let html = RichTextRenderer.html("[open](smb://server/share) and [mail](mailto:a@example.com)")
        XCTAssertFalse(html.contains("smb:"))
        XCTAssertTrue(html.contains("open"))
        XCTAssertTrue(html.contains("<a href=\"mailto:a@example.com\">mail</a>"))
    }

    // MARK: RTF

    func testRTFRoundTripsTheVisibleTextWithFonts() throws {
        let markdown = "# Title\n\nSome **bold** and `code`.\n\n- item"
        let data = try XCTUnwrap(RichTextRenderer.rtf(markdown))
        let decoded = try XCTUnwrap(NSAttributedString(rtf: data, documentAttributes: nil))
        XCTAssertEqual(decoded.string, "Title\nSome bold and code.\n•\titem")

        var sawBold = false
        var sawCode = false
        var sawColor = false
        decoded.enumerateAttributes(in: NSRange(location: 0, length: decoded.length)) { attributes, range, _ in
            let text = (decoded.string as NSString).substring(with: range)
            if let font = attributes[.font] as? NSFont {
                if text.contains("bold"), font.fontDescriptor.symbolicTraits.contains(.bold) { sawBold = true }
                if text.contains("code"), font.fontName.hasPrefix("Menlo") { sawCode = true }
            }
            if attributes[.foregroundColor] != nil { sawColor = true }
        }
        XCTAssertTrue(sawBold)
        XCTAssertTrue(sawCode)
        XCTAssertFalse(sawColor)
    }

    func testAttributedStringUsesHelveticaNeueAndLinks() {
        let attributed = RichTextRenderer.attributedString("Read [this](https://example.com)")
        let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.familyName, "Helvetica Neue")
        let linkIndex = (attributed.string as NSString).range(of: "this").location
        XCTAssertEqual(attributed.attribute(.link, at: linkIndex, effectiveRange: nil) as? URL,
                       URL(string: "https://example.com"))
    }
}
