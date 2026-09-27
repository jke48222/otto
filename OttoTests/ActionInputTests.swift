//
//  ActionInputTests.swift
//  OttoTests
//
//  Local input limits of the scripting tools (actions.md §5.1): lengths counted in characters after
//  trimming, whitespace-only values treated as missing, and hidden characters refused where a person
//  reads the value on the card.
//

import XCTest
@testable import Otto

final class ActionInputTests: XCTestCase {
    private let shortcuts = DemoShortcutsService(delay: .zero)
    private lazy var listTool = ScriptListShortcutsTool(shortcuts: shortcuts)
    private lazy var runTool = ScriptRunShortcutTool(shortcuts: NoListing())
    private let scriptTool = ScriptRunAppleScriptTool(scripts: DemoAppleScriptRunner(delay: .zero))
    private let urlTool = ScriptOpenURLTool(opener: DemoURLOpener())

    private func text(_ count: Int, _ character: Character = "a") -> JSONValue {
        .string(String(repeating: character, count: count))
    }

    private func assertInvalid(_ error: ToolError?, mentions field: String, file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertEqual(error?.code, .invalidInput, file: file, line: line)
        XCTAssertTrue(error?.modelMessage.hasPrefix("$.\(field):") ?? false, error?.modelMessage ?? "no error",
                      file: file, line: line)
    }

    func testFolderLimit() {
        XCTAssertNil(listTool.validate([:]))
        XCTAssertNil(listTool.validate(["folder": text(200)]))
        assertInvalid(listTool.validate(["folder": text(201)]), mentions: "folder")
        assertInvalid(listTool.validate(["folder": "   "]), mentions: "folder")
    }

    func testShortcutNameLimits() {
        XCTAssertNil(runTool.validate(["name": text(200)]))
        assertInvalid(runTool.validate(["name": text(201)]), mentions: "name")
        assertInvalid(runTool.validate(["name": ""]), mentions: "name")
        assertInvalid(runTool.validate(["name": " \n\t "]), mentions: "name")
        assertInvalid(runTool.validate([:]), mentions: "name")
        assertInvalid(runTool.validate(["name": "Log\u{200B} Water"]), mentions: "name")
    }

    func testTrimmingDecidesTheCount() {
        let padded = JSONValue.string("  " + String(repeating: "a", count: 200) + "  ")
        XCTAssertNil(runTool.validate(["name": padded]))
    }

    func testCharactersNotBytesAreCounted() {
        XCTAssertNil(runTool.validate(["name": text(200, "é")]))
        XCTAssertNil(runTool.validate(["name": text(200, "👩‍💻")]), "an emoji joiner sequence is one visible emoji")
        assertInvalid(runTool.validate(["name": "Log\u{200D}Water"]), mentions: "name")
    }

    func testShortcutInputLimit() {
        XCTAssertNil(runTool.validate(["name": "Log Water", "input": text(20_000)]))
        assertInvalid(runTool.validate(["name": "Log Water", "input": text(20_001)]), mentions: "input")
        XCTAssertNil(runTool.validate(["name": "Log Water", "input": "line one\n\tline two"]))
        assertInvalid(runTool.validate(["name": "Log Water", "input": "500 ml\u{202E}"]), mentions: "input")
    }

    func testScriptAndPurposeLimits() {
        XCTAssertNil(scriptTool.validate(["script": text(20_000), "purpose": text(300)]))
        assertInvalid(scriptTool.validate(["script": text(20_001), "purpose": "Beep."]), mentions: "script")
        assertInvalid(scriptTool.validate(["script": "   ", "purpose": "Beep."]), mentions: "script")
        assertInvalid(scriptTool.validate(["script": "beep", "purpose": text(301)]), mentions: "purpose")
        assertInvalid(scriptTool.validate(["script": "beep", "purpose": ""]), mentions: "purpose")
        assertInvalid(scriptTool.validate(["script": "beep"]), mentions: "purpose")
        assertInvalid(scriptTool.validate(["script": "beep", "purpose": "Beep\u{2066} once."]), mentions: "purpose")
    }

    func testURLLimitAndShape() {
        let base = "https://example.com/"
        XCTAssertNil(urlTool.validate(["url": .string(base + String(repeating: "a", count: 2_048 - base.count))]))
        assertInvalid(urlTool.validate(["url": .string(base + String(repeating: "a", count: 2_049 - base.count))]),
                      mentions: "url")
        assertInvalid(urlTool.validate(["url": ""]), mentions: "url")
        assertInvalid(urlTool.validate(["url": "https://example.com/a b"]), mentions: "url")
        assertInvalid(urlTool.validate(["url": "https://ex_ample.com:70000/"]), mentions: "url")
        // Blocked addresses are not input errors; they're refused before asking.
        XCTAssertNil(urlTool.validate(["url": "http://localhost:3000/"]))
        XCTAssertEqual(urlTool.blockReason(for: ["url": "http://localhost:3000/"]), URLGuard.Reason.local)
        XCTAssertEqual(urlTool.blockReason(for: ["url": "file:///etc/hosts"]), URLGuard.Reason.scheme)
    }

    func testInvalidInputCopy() {
        let error = runTool.validate(["name": text(201)])
        XCTAssertEqual(error?.toolResultText, "invalid_input: $.name: must be 200 characters or fewer (it has 201)")
        XCTAssertEqual(error?.userMessage, "Invalid request")
    }
}

/// A service with no listing yet, so validation applies only the local limits.
private final class NoListing: ShortcutsProviding, @unchecked Sendable {
    func list(folder: String?) async throws -> [ScriptShortcut] { [] }
    func resolve(_ name: String) async throws -> ScriptShortcut {
        throw ToolError(code: .notFound, modelMessage: "not found", userMessage: "not found")
    }
    func run(_ shortcut: ScriptShortcut, input: String?, timeout: Duration) async throws -> ScriptShortcutRunResult {
        ScriptShortcutRunResult(output: nil, outputWasNonText: false, duration: .zero)
    }
    func cachedLookup(_ name: String) -> ScriptShortcutLookup { .unknown }
    func prefetch() {}
}
