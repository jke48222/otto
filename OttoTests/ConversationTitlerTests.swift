//
//  ConversationTitlerTests.swift
//  Otto
//
//  Local conversation titles, previews, Markdown-to-plain-text and search snippets.
//

import XCTest
@testable import Otto

private func fileAttachment(_ name: String) -> Attachment {
    Attachment(kind: .pdf, displayName: name, badge: "PDF", payload: .pdf(base64: "JVBERi0="), byteCount: 8)
}

final class ConversationTitlerTests: XCTestCase {
    func testGreetingNameAndRequestAreStripped() {
        let title = ConversationTitler.title(userText: "hey otto, can you explain Swift actors? I keep getting lost", attachments: [])
        XCTAssertEqual(title, "Explain Swift actors?")
        XCTAssertEqual(ConversationTitler.title(userText: "Please summarize the notes.", attachments: []), "Summarize the notes")
        XCTAssertEqual(ConversationTitler.title(userText: "okay could you please fix this", attachments: []), "Fix this")
    }

    func testLeadInsStayWhenTooLittleWouldRemain() {
        XCTAssertEqual(ConversationTitler.title(userText: "hi", attachments: []), "Hi")
        XCTAssertEqual(ConversationTitler.title(userText: "hello hi", attachments: []), "Hello hi")
        XCTAssertEqual(ConversationTitler.title(userText: "Hello there", attachments: []), "There")
    }

    func testLongSentenceIsCutAtAWordBoundary() {
        let text = "Walk me through every step of migrating a large Core Data store to SwiftData without losing anything"
        let title = ConversationTitler.title(userText: text, attachments: [])
        XCTAssertLessThanOrEqual(title.count, ConversationTitler.maxTitleLength)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertEqual(title, "Walk me through every step of migrating a large…")
    }

    func testTextWithoutWordBoundaryIsHardCut() {
        let text = String(repeating: "a", count: 80)
        let title = ConversationTitler.title(userText: text, attachments: [])
        XCTAssertEqual(title, "A" + String(repeating: "a", count: 50) + "…")
        XCTAssertEqual(title.count, 52)
    }

    func testMarkdownAndCodeFencesAreStripped() {
        let markdown = """
        ```swift
        let x = 1
        ```
        ## **Why** does `map` crash?
        """
        XCTAssertEqual(ConversationTitler.title(userText: markdown, attachments: []), "Why does map crash?")
        XCTAssertEqual(ConversationTitler.plainText(fromMarkdown: "- item one\n- see [the docs](https://x.y)\n> quoted _text_"),
                       "item one see the docs quoted text")
        XCTAssertEqual(ConversationTitler.plainText(fromMarkdown: "keep snake_case names"), "keep snake_case names")
    }

    func testMultipleLinesCollapseAndTrailingPeriodGoesButQuestionMarkStays() {
        XCTAssertEqual(ConversationTitler.title(userText: "rename   the\nfiles.", attachments: []), "Rename the files")
        XCTAssertEqual(ConversationTitler.title(userText: "is this safe?", attachments: []), "Is this safe?")
    }

    func testAttachmentOnlyTitles() {
        XCTAssertEqual(ConversationTitler.title(userText: "", attachments: [fileAttachment("report.pdf")]), "report.pdf")
        let page = Attachment(kind: .webPage, displayName: "Swift.org", badge: "WEB",
                              payload: .webPage(title: "Swift.org - Welcome", url: URL(fileURLWithPath: "/")), byteCount: 0)
        XCTAssertEqual(ConversationTitler.title(userText: "", attachments: [page]), "Swift.org - Welcome")
        let three = ["a.pdf", "b.pdf", "c.pdf"].map(fileAttachment)
        XCTAssertEqual(ConversationTitler.title(userText: "  ", attachments: three), "a.pdf + 2 more")
        XCTAssertEqual(ConversationTitler.title(userText: "", attachments: []), "New conversation")
    }

    func testNonLatinSentenceSplitting() {
        let title = ConversationTitler.title(userText: "東京は日本の首都です。人口がとても多いです。", attachments: [])
        XCTAssertEqual(title, "東京は日本の首都です。")
    }

    func testEmojiLeadingTextKeepsItsFirstCharacter() {
        XCTAssertEqual(ConversationTitler.title(userText: "🎉 party ideas for Friday", attachments: []), "🎉 party ideas for Friday")
    }

    func testTitleForMessagesUsesTheFirstUserMessage() {
        let messages = [
            ChatMessage(role: .user, text: "what is a monad"),
            ChatMessage(role: .assistant, text: "A monad is…"),
            ChatMessage(role: .user, text: "second question"),
        ]
        XCTAssertEqual(ConversationTitler.title(for: messages), "What is a monad")
        XCTAssertEqual(ConversationTitler.title(for: []), "New conversation")
    }

    func testPreviewPicksTheLatestCompleteReply() {
        let messages = [
            ChatMessage(role: .user, text: "q1"),
            ChatMessage(role: .assistant, text: "# Short answer\n\nFirst reply"),
            ChatMessage(role: .user, text: "q2"),
            ChatMessage(role: .assistant, text: "partial", state: .cancelled),
        ]
        XCTAssertEqual(ConversationTitler.preview(for: messages), "Short answer")
    }

    func testPreviewFallsBackToUserTextAndIsCapped() {
        let long = String(repeating: "word ", count: 60)
        let messages = [ChatMessage(role: .user, text: "\n\n" + long), ChatMessage(role: .assistant, text: "", state: .failed("x"))]
        let preview = ConversationTitler.preview(for: messages)
        XCTAssertEqual(preview.count, ConversationTitler.maxPreviewLength)
        XCTAssertTrue(preview.hasPrefix("word word"))
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    func testSnippetIsCentredOnTheMatchWithEllipses() throws {
        let text = "The actor model isolates state. Every await is a suspension point where other work can run first, "
            + "so invariants must hold across it. That is reentrancy in a nutshell."
        let range = try XCTUnwrap(text.range(of: "suspension"))
        let snippet = ConversationTitler.snippet(in: text, around: range, radius: 20)
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertTrue(snippet.contains("suspension"))
        XCTAssertEqual(snippet, "…Every await is a suspension point where other…")

        let start = try XCTUnwrap(text.range(of: "The actor"))
        XCTAssertFalse(ConversationTitler.snippet(in: text, around: start, radius: 10).hasPrefix("…"))
    }
}
