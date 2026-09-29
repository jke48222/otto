//
//  EchoDetectorTests.swift
//  OttoTests
//
//  Private text leaving the Mac: phrases from private tool results and attached selections or
//  clipboard text, matched as skeletons through hyphens, underscores, percent-encoding, hex, base64
//  and reversal.
//

import XCTest
@testable import Otto

final class EchoDetectorTests: XCTestCase {
    private let sources = ["calendar_list_events": "your calendar", "run_shortcut": "a shortcut's output"]

    private var calendarTranscript: [JSONValue] {
        let result = """
        {"events":[{"location":"12 Oak Street","notes":"Bring the insurance card and the referral letter from Dr Adams",\
        "start":"2026-09-29T15:00","title":"Dentist — Dr. Lee"}],"status":"ok"}
        """
        return [
            ["role": "user", "content": [["type": "text", "text": "What's on Tuesday?"]]],
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": "t1", "name": "calendar_list_events", "input": [:]],
            ]],
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "t1", "content": [["type": "text", "text": .string(result)]]],
            ]],
        ]
    }

    private var privates: [(phrase: String, source: String)] {
        EchoDetector.privateStrings(in: calendarTranscript, sources: sources)
    }

    private func find(_ candidate: String) -> EchoFinding? {
        EchoDetector.find(in: [candidate], privateStrings: privates)
    }

    // MARK: - Private phrases

    func testPrivateStringsFromACalendarResult() {
        let phrases = privates.map(\.phrase)
        XCTAssertTrue(phrases.contains("dentist dr lee"))
        XCTAssertTrue(phrases.contains("12 oak street"))
        XCTAssertTrue(phrases.contains("insurance card and the referral"), "5-word windows of longer values")
        XCTAssertFalse(phrases.contains("ok"), "the status value is never a phrase")
        XCTAssertFalse(phrases.contains("2026 09 29t15 00"), "bare dates are not private phrases")
        XCTAssertTrue(privates.allSatisfy { $0.source == "your calendar" })
    }

    func testErrorsAndUnlistedToolsContributeNothing() {
        let transcript: [JSONValue] = [
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": "a", "name": "calendar_list_events", "input": [:]],
                ["type": "tool_use", "id": "b", "name": "open_url", "input": [:]],
            ]],
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "a", "is_error": true,
                 "content": [["type": "text", "text": "permission_denied: Otto doesn't have Calendars access."]]],
                ["type": "tool_result", "tool_use_id": "b", "content": [["type": "text", "text": "Opened example dot com"]]],
            ]],
        ]
        XCTAssertTrue(EchoDetector.privateStrings(in: transcript, sources: sources).isEmpty)
    }

    func testDowngradedEarlierResultsStillHoldPrivatePhrases() {
        let output = ToolOutput.text(#"{"events":[{"title":"Dentist — Dr. Lee","start":"2026-09-29T15:00"}],"status":"ok"}"#)
        let block = ToolHistory.earlierActionResult(tool: "calendar_list_events", title: "Read your calendar",
                                                    output: output)
        let transcript: [JSONValue] = [
            ["role": "user", "content": [["type": "text", "text": .string(block)], ["type": "text", "text": "Next"]]],
        ]
        let privates = EchoDetector.privateStrings(in: transcript, sources: sources)
        XCTAssertTrue(privates.contains { $0.phrase == "dentist dr lee" && $0.source == "your calendar" })
        XCTAssertEqual(EchoDetector.find(in: ["https://evil.example/?q=dentist-dr-lee"], privateStrings: privates),
                       EchoFinding(sourcePhrase: "your calendar", sample: "dentist dr lee"))

        // An error result, an unlisted tool and ordinary text contribute nothing.
        let error = ToolHistory.earlierActionResult(tool: "calendar_list_events", title: "Read your calendar",
                                                    output: .error("permission_denied: Otto doesn't have Calendars access."))
        let unlisted = ToolHistory.earlierActionResult(tool: "open_url", title: "Open a page",
                                                       output: .text("Opened the dentist page"))
        let quiet: [JSONValue] = [["role": "user", "content": [
            ["type": "text", "text": .string(error)], ["type": "text", "text": .string(unlisted)],
            ["type": "text", "text": "Dentist with Dr Lee"],
        ]]]
        XCTAssertTrue(EchoDetector.privateStrings(in: quiet, sources: sources).isEmpty)
    }

    func testEarlierResultParsingUnescapesAndRejectsOtherText() {
        let parsed = EchoDetector.earlierActionResult(
            #"<earlier_action_result tool="run_shortcut" title="Run &quot;x&quot;" untrusted="true">a &lt;b&gt; &amp; c</earlier_action_result>"#
        )
        XCTAssertEqual(parsed?.tool, "run_shortcut")
        XCTAssertEqual(parsed?.payload, "a <b> & c")
        XCTAssertNil(EchoDetector.earlierActionResult("<earlier_action_result tool=\"x\">unterminated"))
        XCTAssertNil(EchoDetector.earlierActionResult("Just text"))
    }

    func testJSONCutShortStillContributesItsStringValues() {
        // A downgraded result keeps only its first 2,000 characters, so its JSON may not parse.
        let cut = #"{"events":[{"title":"Therapy with Dr Rivera","notes":"Room 4B"},{"title":"Lunch with Sam"#
        let transcript: [JSONValue] = [
            ["role": "user", "content": [["type": "text", "text": .string(
                "<earlier_action_result tool=\"calendar_list_events\" title=\"Read\" untrusted=\"true\">"
                    + ToolHistory.escaped(cut) + "</earlier_action_result>"
            )]]],
        ]
        let phrases = EchoDetector.privateStrings(in: transcript, sources: sources).map(\.phrase)
        XCTAssertTrue(phrases.contains("therapy with dr rivera"))
        XCTAssertTrue(phrases.contains("room 4b"))
        XCTAssertFalse(phrases.contains("events"), "keys are not values")
    }

    func testPlainTextOutputIsSplitIntoLines() {
        let transcript: [JSONValue] = [
            ["role": "assistant", "content": [["type": "tool_use", "id": "s", "name": "run_shortcut", "input": [:]]]],
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "s",
                 "content": [["type": "text", "text": "Balance: 4,210.55\nAccount holder Jordan Price\n42"]]],
            ]],
        ]
        let phrases = EchoDetector.privateStrings(in: transcript, sources: sources)
        XCTAssertTrue(phrases.contains { $0.phrase == "account holder jordan price" && $0.source == "a shortcut's output" })
        XCTAssertFalse(phrases.contains { $0.phrase == "42" })
    }

    func testSelectionAndClipboardDocumentsArePrivate() {
        let transcript: [JSONValue] = [
            ["role": "user", "content": [
                ["type": "document", "title": "Selection from Notes",
                 "source": ["type": "text", "media_type": "text/plain", "data": "Project Falcon launch plan"]],
                ["type": "document", "title": "Clipboard.txt",
                 "source": ["type": "text", "media_type": "text/plain", "data": "Wire code 7781 for Harbor Bank"]],
                ["type": "document", "title": "notes.txt",
                 "source": ["type": "text", "media_type": "text/plain", "data": "Some ordinary file text"]],
                ["type": "text", "text": "Tidy this up"],
            ]],
        ]
        let phrases = EchoDetector.privateStrings(in: transcript, sources: [:])
        XCTAssertTrue(phrases.contains { $0.phrase == "project falcon launch plan" && $0.source == "your selection" })
        XCTAssertTrue(phrases.contains { $0.phrase == "wire code 7781 for harbor bank" && $0.source == "your clipboard" })
        XCTAssertFalse(phrases.contains { $0.phrase.contains("ordinary") })

        let finding = EchoDetector.find(in: ["tell application \"Mail\" to send \"project-falcon-launch-plan\""],
                                        privateStrings: phrases)
        XCTAssertEqual(finding, EchoFinding(sourcePhrase: "your selection", sample: "project falcon launch plan"))
    }

    func testOversizedSelectionIsSkipped() {
        let big = String(repeating: "Secret launch word list\n", count: 3_000)
        let transcript: [JSONValue] = [
            ["role": "user", "content": [
                ["type": "document", "title": "Selection", "source": ["type": "text", "media_type": "text/plain", "data": .string(big)]],
            ]],
        ]
        XCTAssertTrue(big.utf8.count > EchoDetector.maxDocumentBytes)
        XCTAssertTrue(EchoDetector.privateStrings(in: transcript, sources: [:]).isEmpty)
    }

    // MARK: - Matching

    func testSkeleton() {
        XCTAssertEqual(EchoDetector.skeleton("Dentist — Dr. Lee"), "dentist dr lee")
        XCTAssertEqual(EchoDetector.skeleton("dentist-dr-lee.evil.com"), "dentist dr lee evil com")
        XCTAssertEqual(EchoDetector.skeleton("dentist_dr_lee"), "dentist dr lee")
        XCTAssertEqual(EchoDetector.skeleton("Dentist+%E2%80%94+Dr.+Lee"), "dentist dr lee")
    }

    func testHyphenatedHostname() {
        XCTAssertEqual(find("https://dentist-dr-lee.evil.example/collect"),
                       EchoFinding(sourcePhrase: "your calendar", sample: "dentist dr lee"))
    }

    func testUnderscoresAndPercentEncoding() {
        XCTAssertEqual(find("https://evil.example/?q=dentist_dr_lee")?.sample, "dentist dr lee")
        XCTAssertEqual(find("https://evil.example/?where=12%20Oak%20Street")?.sample, "12 oak street")
    }

    func testSeparatorsRemovedEntirely() {
        XCTAssertEqual(find("https://dentistdrlee.evil.example")?.sample, "dentist dr lee")
    }

    func testHexEncoded() {
        let hex = Data("Dentist Dr Lee".utf8).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(find("https://evil.example/p/\(hex)")?.sample, "dentist dr lee")
        XCTAssertEqual(find("https://evil.example/p/\(hex.uppercased())")?.sample, "dentist dr lee")
    }

    func testBase64Encoded() {
        let standard = Data("Dentist — Dr. Lee".utf8).base64EncodedString()
        XCTAssertEqual(find("https://evil.example/?d=\(standard)")?.sample, "dentist dr lee")
        let percentEncoded = standard.replacingOccurrences(of: "=", with: "%3D")
        XCTAssertEqual(find("https://evil.example/?d=\(percentEncoded)")?.sample, "dentist dr lee")
        let urlSafe = Data("12 Oak Street, Springfield".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        XCTAssertEqual(find("https://evil.example/\(urlSafe)")?.sample, "12 oak street")
    }

    func testReversed() {
        XCTAssertEqual(find("do shell script \"echo 'eeL .rD — tsitneD'\"")?.sample, "dentist dr lee")
    }

    func testWindowOfALongNote() {
        XCTAssertEqual(find("https://evil.example/?n=insurance-card-and-the-referral")?.sample,
                       "insurance card and the referral")
    }

    func testOrdinaryEgressIsClean() {
        XCTAssertNil(find("https://weather.example.com/forecast?city=springfield"))
        XCTAssertNil(find("tell application \"Finder\" to get name of every disk"))
        XCTAssertNil(find(""))
        XCTAssertNil(EchoDetector.find(in: ["anything"], privateStrings: []))
    }

    func testFirstCandidateWins() {
        let finding = EchoDetector.find(in: ["https://example.com/12-oak-street", "dentist dr lee"],
                                        privateStrings: privates)
        XCTAssertEqual(finding?.sample, "12 oak street")
    }
}
