//
//  InsertPolicyTests.swift
//  OttoTests
//
//  Target categories, the payload decision table, payload hygiene (line separators, control characters,
//  bracketed-paste escapes), line counting and when a paste needs confirmation.
//

import AppKit
import XCTest
@testable import Otto

final class InsertPolicyTests: XCTestCase {
    // MARK: Categories

    func testKnownBundleIDs() {
        XCTAssertEqual(TargetCategory.of(bundleID: "com.apple.Terminal"), .terminal)
        XCTAssertEqual(TargetCategory.of(bundleID: "com.googlecode.iterm2"), .terminal)
        XCTAssertEqual(TargetCategory.of(bundleID: "dev.warp.Warp-Stable"), .terminal)
        XCTAssertEqual(TargetCategory.of(bundleID: "dev.warp.Warp-Preview"), .terminal)
        XCTAssertEqual(TargetCategory.of(bundleID: "com.mitchellh.ghostty"), .terminal)
        XCTAssertEqual(TargetCategory.of(bundleID: "org.alacritty"), .terminal)
        XCTAssertEqual(TargetCategory.of(bundleID: "io.alacritty"), .terminal)
        XCTAssertEqual(TargetCategory.of(bundleID: "org.tabby"), .terminal)
        XCTAssertEqual(TargetCategory.of(bundleID: "com.termius-dmg.mac"), .terminal)
        XCTAssertEqual(TargetCategory.of(bundleID: "com.raphaelamorim.rio"), .terminal)
        XCTAssertEqual(TargetCategory.of(bundleID: "net.kovidgoyal.kitty"), .terminal)

        XCTAssertEqual(TargetCategory.of(bundleID: "com.apple.dt.Xcode"), .codeEditor)
        XCTAssertEqual(TargetCategory.of(bundleID: "com.microsoft.VSCode"), .codeEditor)
        XCTAssertEqual(TargetCategory.of(bundleID: "com.microsoft.VSCodeInsiders"), .codeEditor)
        XCTAssertEqual(TargetCategory.of(bundleID: "com.todesktop.230313mzl4w4u92"), .codeEditor)
        XCTAssertEqual(TargetCategory.of(bundleID: "com.jetbrains.intellij"), .codeEditor)
        XCTAssertEqual(TargetCategory.of(bundleID: "com.jetbrains.pycharm.ce"), .codeEditor)

        XCTAssertEqual(TargetCategory.of(bundleID: "md.obsidian"), .markdownNative)
        XCTAssertEqual(TargetCategory.of(bundleID: "net.shinyfrog.bear"), .markdownNative)
        XCTAssertEqual(TargetCategory.of(bundleID: "abnerworks.Typora"), .markdownNative)

        XCTAssertEqual(TargetCategory.of(bundleID: "com.apple.Notes"), .standard)
        XCTAssertEqual(TargetCategory.of(bundleID: "com.google.Chrome"), .standard)
        XCTAssertEqual(TargetCategory.of(bundleID: nil), .standard)
    }

    func testTermHeuristicOnlyAddsCaution() {
        XCTAssertEqual(TargetCategory.of(bundleID: "com.example.cool-term", appName: "Cool"), .terminal)
        XCTAssertEqual(TargetCategory.of(bundleID: "com.example.shell", appName: "Retro TERMinal"), .terminal)
        XCTAssertEqual(TargetCategory.of(bundleID: nil, appName: "Termite"), .terminal)
        // Known terminals stay terminals whatever their name says.
        XCTAssertEqual(TargetCategory.of(bundleID: "com.apple.Terminal", appName: "Notes"), .terminal)
        XCTAssertEqual(TargetCategory.of(bundleID: "com.apple.Notes", appName: "Notes"), .standard)
    }

    // MARK: Payload table

    private let prose = "Here is **bold** and a [link](https://example.com).\n\n- one\n- two"
    private let codeOnly = "```swift\nlet x = 1\nprint(x)\n```"

    func testTerminalRows() {
        let code = InsertPolicy.payload(for: codeOnly + "\n\n", category: .terminal, mode: .paste)
        XCTAssertEqual(code, PastePayload(plain: "let x = 1\nprint(x)"))

        let text = InsertPolicy.payload(for: prose, category: .terminal, mode: .replaceSelection)
        XCTAssertEqual(text.plain, "Here is bold and a link (https://example.com).\n\n- one\n- two")
        XCTAssertNil(text.rtf)
        XCTAssertNil(text.html)
    }

    func testTerminalTrimsTrailingNewlines() {
        let payload = InsertPolicy.payload(for: "```\nrm -rf build\n\n```", category: .terminal, mode: .paste)
        XCTAssertEqual(payload.plain, "rm -rf build")
        XCTAssertEqual(payload.lineCount, 1)
    }

    func testCodeEditorRows() {
        XCTAssertEqual(InsertPolicy.payload(for: codeOnly, category: .codeEditor, mode: .paste).plain,
                       "let x = 1\nprint(x)")
        let source = InsertPolicy.payload(for: prose, category: .codeEditor, mode: .paste)
        XCTAssertEqual(source.plain, prose)
        XCTAssertNil(source.rtf)
    }

    func testMarkdownNativeKeepsTheMarkdown() {
        XCTAssertEqual(InsertPolicy.payload(for: codeOnly, category: .markdownNative, mode: .paste).plain, codeOnly)
        XCTAssertEqual(InsertPolicy.payload(for: prose, category: .markdownNative, mode: .pastePlain).plain, prose)
    }

    func testStandardRows() {
        let code = InsertPolicy.payload(for: codeOnly, category: .standard, mode: .paste)
        XCTAssertEqual(code, PastePayload(plain: "let x = 1\nprint(x)"))

        let rich = InsertPolicy.payload(for: prose, category: .standard, mode: .paste)
        XCTAssertEqual(rich.plain, RichTextRenderer.plainText(prose))
        XCTAssertNotNil(rich.rtf)
        XCTAssertEqual(rich.html, RichTextRenderer.html(prose))

        let replace = InsertPolicy.payload(for: prose, category: .standard, mode: .replaceSelection)
        XCTAssertNotNil(replace.rtf)

        let plain = InsertPolicy.payload(for: prose, category: .standard, mode: .pastePlain)
        XCTAssertEqual(plain, PastePayload(plain: RichTextRenderer.plainText(prose)))

        let plainCode = InsertPolicy.payload(for: codeOnly, category: .standard, mode: .pastePlain)
        XCTAssertEqual(plainCode, PastePayload(plain: "let x = 1\nprint(x)"))
    }

    func testTruncationMarkerIsStripped() {
        XCTAssertEqual(InsertPolicy.cleanedAnswer("The answer is" + "\n\n_(Reply truncated.)_"), "The answer is")
        XCTAssertEqual(InsertPolicy.cleanedAnswer("Done.  \n\n"), "Done.")
        let payload = InsertPolicy.payload(for: "Partial answer\n\n_(Reply truncated.)_\n", category: .standard,
                                           mode: .pastePlain)
        XCTAssertEqual(payload.plain, "Partial answer")
    }

    func testDelays() {
        XCTAssertEqual(InsertPolicy.restoreDelay(isChromiumOrElectron: false), .milliseconds(700))
        XCTAssertEqual(InsertPolicy.restoreDelay(isChromiumOrElectron: true), .milliseconds(1500))
        XCTAssertEqual(InsertPolicy.verifyDelay(isChromiumOrElectron: false), .milliseconds(300))
        XCTAssertEqual(InsertPolicy.verifyDelay(isChromiumOrElectron: true), .milliseconds(600))
    }

    // MARK: Hygiene

    func testLineSeparatorsAreNormalized() {
        let raw = "a\r\nb\rc\u{2028}d\u{2029}e\u{0085}f\u{000B}g\u{000C}h\ni"
        XCTAssertEqual(InsertPolicy.sanitized(raw), "a\nb\nc\nd\ne\nf\ng\nh\ni")
        let payload = InsertPolicy.payload(for: "echo one\recho two\u{2028}echo three", category: .terminal, mode: .paste)
        XCTAssertEqual(payload.plain, "echo one\necho two\necho three")
        XCTAssertEqual(payload.lineCount, 3)
    }

    func testControlCharactersAreStripped() {
        let raw = "safe\u{1B}[201~rm -rf ~\u{7F}\u{0080}\u{009B}\u{0000}\u{0007}\tend"
        XCTAssertEqual(InsertPolicy.sanitized(raw), "safe[201~rm -rf ~\tend")

        for category in [TargetCategory.terminal, .codeEditor, .markdownNative, .standard] {
            let payload = InsertPolicy.payload(for: "```\necho hi\u{1B}[201~\u{009B}31m\n```", category: category,
                                               mode: .paste)
            XCTAssertFalse(payload.plain.unicodeScalars.contains { $0.value == 0x1B }, "\(category)")
            XCTAssertFalse(payload.plain.unicodeScalars.contains { (0x80...0x9F).contains($0.value) }, "\(category)")
            XCTAssertTrue(payload.plain.contains("[201~"), "\(category)")
        }
        let rich = InsertPolicy.payload(for: "Hello\u{1B}[201~ world", category: .standard, mode: .paste)
        XCTAssertFalse(rich.html?.contains("\u{1B}") ?? true)
        XCTAssertFalse(rich.plain.contains("\u{1B}"))
    }

    func testLineCountIsTakenAfterNormalizing() {
        XCTAssertEqual(PastePayload(plain: "").lineCount, 0)
        XCTAssertEqual(PastePayload(plain: "one").lineCount, 1)
        XCTAssertEqual(PastePayload(plain: "one\n").lineCount, 1)
        XCTAssertEqual(PastePayload(plain: "one\ntwo\n\n").lineCount, 2)
        // A lone CR would run as a second command in a terminal: counted as a line.
        let payload = InsertPolicy.payload(for: "ls\rwhoami", category: .terminal, mode: .paste)
        XCTAssertEqual(payload.lineCount, 2)
        XCTAssertTrue(InsertPolicy.needsMultilineConfirmation(payload, category: .terminal))
    }

    // MARK: Confirmation

    func testTerminalMultilineNeedsConfirmation() {
        let single = InsertPolicy.payload(for: "ls -la", category: .terminal, mode: .paste)
        XCTAssertFalse(InsertPolicy.needsMultilineConfirmation(single, category: .terminal))
        let multi = InsertPolicy.payload(for: "ls\npwd", category: .terminal, mode: .paste)
        XCTAssertTrue(InsertPolicy.needsMultilineConfirmation(multi, category: .terminal))
        XCTAssertFalse(InsertPolicy.needsMultilineConfirmation(multi, category: .standard))
    }

    func testCodeEditorShellBlockNeedsConfirmation() {
        for language in ["bash", "sh", "zsh", "console", "shell", "fish", "BASH"] {
            let payload = InsertPolicy.payload(for: "```\(language)\nbrew update\nbrew upgrade\n```",
                                               category: .codeEditor, mode: .paste)
            XCTAssertTrue(payload.isShellCommandBlock, language)
            XCTAssertTrue(InsertPolicy.needsMultilineConfirmation(payload, category: .codeEditor), language)
        }
        let oneLine = InsertPolicy.payload(for: "```bash\nbrew update\n```", category: .codeEditor, mode: .paste)
        XCTAssertFalse(InsertPolicy.needsMultilineConfirmation(oneLine, category: .codeEditor))

        let swift = InsertPolicy.payload(for: "```swift\nlet a = 1\nlet b = 2\n```", category: .codeEditor, mode: .paste)
        XCTAssertFalse(InsertPolicy.needsMultilineConfirmation(swift, category: .codeEditor))

        let prose = InsertPolicy.payload(for: "Run this:\n\n```bash\na\nb\n```", category: .codeEditor, mode: .paste)
        XCTAssertFalse(prose.isShellCommandBlock)
        XCTAssertFalse(InsertPolicy.needsMultilineConfirmation(prose, category: .codeEditor))
    }
}
