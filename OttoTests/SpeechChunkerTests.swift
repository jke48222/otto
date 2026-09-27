//
//  SpeechChunkerTests.swift
//  OttoTests
//
//  Streaming Markdown → sentences to read aloud: code fences, held partial sentences, paragraph breaks,
//  links and bare URLs, Otto's own notes, and the promise that streaming and whole-text feeding agree.
//

import XCTest
@testable import Otto

@MainActor
final class SpeechChunkerTests: XCTestCase {
    /// Feeds the whole text once, final.
    private func whole(_ text: String) -> [String] {
        var chunker = SpeechChunker()
        return chunker.consume(text, isFinal: true)
    }

    /// Feeds every prefix (character by character) and then the whole text as final.
    private func streamed(_ text: String) -> [String] {
        var chunker = SpeechChunker()
        var output: [String] = []
        var prefix = ""
        for character in text {
            prefix.append(character)
            output += chunker.consume(prefix, isFinal: false)
        }
        output += chunker.consume(text, isFinal: true)
        return output
    }

    // MARK: - Sentences

    func testPartialSentenceIsHeldUntilMoreTextArrives() {
        var chunker = SpeechChunker()
        XCTAssertEqual(chunker.consume("The meeting moved to Thursday.", isFinal: false), [])
        XCTAssertEqual(chunker.consume("The meeting moved to Thursday. It starts at", isFinal: false), [])
        XCTAssertEqual(
            chunker.consume("The meeting moved to Thursday. It starts at noon.\n", isFinal: false),
            ["The meeting moved to Thursday."])
        XCTAssertEqual(
            chunker.consume("The meeting moved to Thursday. It starts at noon.\nBring the slides.", isFinal: false),
            [])
        XCTAssertEqual(
            chunker.consume("The meeting moved to Thursday. It starts at noon.\nBring the slides.", isFinal: true),
            ["It starts at noon.", "Bring the slides."])
    }

    func testParagraphBreakCompletesTheLastSentence() {
        var chunker = SpeechChunker()
        XCTAssertEqual(chunker.consume("First point is short\n", isFinal: false), [])
        XCTAssertEqual(chunker.consume("First point is short\n\n", isFinal: false), ["First point is short"])
        XCTAssertEqual(chunker.consume("First point is short\n\nSecond one.", isFinal: true), ["Second one."])
    }

    func testFinalFlushesTheTrailingSentence() {
        XCTAssertEqual(whole("Yes. It works"), ["Yes.", "It works"])
    }

    func testReFeedingTheSameTextEmitsNothingNew() {
        var chunker = SpeechChunker()
        let text = "One. Two.\n\nThree.\n"
        let first = chunker.consume(text, isFinal: false)
        XCTAssertEqual(first, ["One.", "Two."])
        XCTAssertEqual(chunker.consume(text, isFinal: false), [])
        XCTAssertEqual(chunker.consume(text, isFinal: true), ["Three."])
        XCTAssertEqual(chunker.consume(text, isFinal: true), [])
    }

    // MARK: - Code

    func testCodeFenceIsSkippedWithThePhraseOnce() {
        let reply = """
        Here's a fix.
        ```swift
        let x = 1
        print(x)
        ```
        And another one.
        ```
        rm -rf build
        ```
        That's all.
        """
        XCTAssertEqual(whole(reply), [
            "Here's a fix.",
            SpeechChunker.codePhrase,
            "And another one.",
            "That's all.",
        ])
    }

    func testUnclosedFenceAtTheEndIsSkipped() {
        XCTAssertEqual(whole("Try this:\n```python\nprint('hi')\nmore code"), ["Try this:", SpeechChunker.codePhrase])
    }

    func testTildeFencesCountAsCode() {
        XCTAssertEqual(whole("Run it.\n~~~\nmake\n~~~\nDone."), ["Run it.", SpeechChunker.codePhrase, "Done."])
    }

    // MARK: - Markdown

    func testLinksReadAsTheirTextAndBareURLsAsALink() {
        XCTAssertEqual(
            whole("Read [the release notes](https://example.com/notes) first."),
            ["Read the release notes first."])
        XCTAssertEqual(whole("It's at https://example.com/path?q=1."), ["It's at a link."])
        XCTAssertEqual(whole("See <https://example.com> for more."), ["See a link for more."])
        XCTAssertEqual(whole("Logo: ![Otto logo](https://example.com/logo.png)."), ["Logo: Otto logo."])
    }

    func testTruncationAndStopNotesAreDropped() {
        XCTAssertEqual(whole("The answer is 42." + ChatSession.truncationNote), ["The answer is 42."])
        XCTAssertEqual(whole("Here's what I found." + ChatSession.pauseLimitNote), ["Here's what I found."])
    }

    func testTablesAndRulesAreDropped() {
        let reply = """
        Prices below.

        | Plan | Price |
        |------|-------|
        | Pro  | $5    |

        ---
        That's it.
        """
        XCTAssertEqual(whole(reply), ["Prices below.", "That's it."])
    }

    func testMarkupIsStrippedButWordsStay() {
        let reply = """
        ## Summary
        - **Bold** item
        * an _italic_ one
        1. Use `git status` to check.
        > Quoted ~~old~~ text.
        """
        XCTAssertEqual(whole(reply), [
            "Summary",
            "Bold item",
            "an italic one",
            "Use git status to check.",
            "Quoted old text.",
        ])
    }

    func testSnakeCaseAndMathKeepTheirCharacters() {
        XCTAssertEqual(whole("Set max_tokens to 2 * 3 now."), ["Set max_tokens to 2 * 3 now."])
    }

    // MARK: - Streaming equivalence

    func testCharacterByCharacterMatchesWholeText() {
        let reply = """
        # Plan for today
        Sure. Here's the plan for the week: first, move the meeting. Then email Sam.

        Some code:
        ```js
        console.log("hi")
        ```
        - Pick up **groceries**
        - Call [Mom](tel:555) at 5 p.m. tomorrow.

        | a | b |
        |---|---|
        Visit https://example.com/a.b for details. That's all
        """ + ChatSession.truncationNote
        let expected = whole(reply)
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(streamed(reply), expected)
        XCTAssertEqual(expected.filter { $0 == SpeechChunker.codePhrase }.count, 1)
        XCTAssertFalse(expected.contains { $0.contains("console") || $0.contains("|") || $0.contains("http") })
        XCTAssertEqual(Set(expected).count, expected.count, "no sentence is emitted twice")
    }

    func testLineByLineChunksMatchWholeText() {
        let reply = "One two three. Four five.\nSix seven\n\nEight.\n```\ncode\n```\nNine ten. Eleven"
        var chunker = SpeechChunker()
        var output: [String] = []
        for index in reply.indices where reply[index] == "\n" {
            output += chunker.consume(String(reply[..<index]), isFinal: false)
            output += chunker.consume(String(reply[...index]), isFinal: false)
        }
        output += chunker.consume(reply, isFinal: true)
        XCTAssertEqual(output, whole(reply))
    }
}
