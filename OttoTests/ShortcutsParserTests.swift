//
//  ShortcutsParserTests.swift
//  OttoTests
//
//  `shortcuts list --show-identifiers` parsing, name resolution (exact, case-insensitive, ambiguous, not
//  found with suggestions), and ShortcutsService's commands, cache, folders, output and errors, all
//  through a fake process runner that never starts the real Shortcuts tool.
//

import XCTest
@testable import Otto

final class ShortcutsParserTests: XCTestCase {
    private let listing = """
    Log Water (4F6B2C1E-8A3D-4B7E-9C21-5D0E6F7A8B91)
    Resize Images (for web) (c8b4a2e6-3f1d-4e9a-b7c5-2a4e6c8b0d37)

    Open Roku Remote (A1E3C5B7-9D2F-4A6C-8E0B-3D5F7A9C1E26)
    not a shortcut line
    log water (E5D3F1A9-7B2C-4D6E-9A8F-1C3E5B7D9F48)
    Water Plants (7C2D9E4F-1B6A-4C8D-A3E5-0F9B2D7C6E14)

    """

    // MARK: - Parsing

    func testParsesNamesWithParenthesesBlankLinesAndLowercaseUUIDs() {
        let shortcuts = ScriptShortcutMatching.parseList(listing)
        XCTAssertEqual(shortcuts.map(\.name),
                       ["Log Water", "Resize Images (for web)", "Open Roku Remote", "log water", "Water Plants"])
        XCTAssertEqual(shortcuts[1].identifier, "C8B4A2E6-3F1D-4E9A-B7C5-2A4E6C8B0D37", "identifiers are uppercased")
        XCTAssertEqual(ScriptShortcutMatching.parseList(""), [])
        XCTAssertEqual(ScriptShortcutMatching.parseList("Name (not-a-uuid)\n"), [])
    }

    func testParsesWindowsLineEndings() {
        let shortcuts = ScriptShortcutMatching.parseList("A (4F6B2C1E-8A3D-4B7E-9C21-5D0E6F7A8B91)\r\nB (A1E3C5B7-9D2F-4A6C-8E0B-3D5F7A9C1E26)\r\n")
        XCTAssertEqual(shortcuts.map(\.name), ["A", "B"])
    }

    // MARK: - Lookup

    func testExactMatchWins() {
        let shortcuts = ScriptShortcutMatching.parseList(listing)
        XCTAssertEqual(ScriptShortcutMatching.lookup("Log Water", in: shortcuts), .found(shortcuts[0]))
        XCTAssertEqual(ScriptShortcutMatching.lookup("log water", in: shortcuts), .found(shortcuts[3]))
    }

    func testUniqueCaseInsensitiveMatch() {
        let shortcuts = ScriptShortcutMatching.parseList(listing)
        XCTAssertEqual(ScriptShortcutMatching.lookup("open roku remote", in: shortcuts), .found(shortcuts[2]))
        XCTAssertEqual(ScriptShortcutMatching.lookup("  Water plants ", in: shortcuts), .found(shortcuts[4]))
    }

    func testAmbiguousCaseInsensitiveMatch() {
        let shortcuts = ScriptShortcutMatching.parseList(listing)
        XCTAssertEqual(ScriptShortcutMatching.lookup("LOG WATER", in: shortcuts), .ambiguous(["Log Water", "log water"]))
        let error = ScriptShortcutMatching.error(for: .ambiguous(["Log Water", "log water"]), name: "LOG WATER")
        XCTAssertEqual(error?.code, .ambiguous)
    }

    func testNotFoundSuggestsPrefixThenSubstringMatches() {
        let shortcuts = ScriptShortcutMatching.parseList(listing)
        XCTAssertEqual(ScriptShortcutMatching.lookup("Wat", in: shortcuts),
                       .notFound(suggestions: ["Water Plants", "Log Water", "log water"]))
        XCTAssertEqual(ScriptShortcutMatching.lookup("Roku", in: shortcuts),
                       .notFound(suggestions: ["Open Roku Remote"]))
        XCTAssertEqual(ScriptShortcutMatching.lookup("Tetris", in: shortcuts), .notFound(suggestions: []))

        let error = ScriptShortcutMatching.error(for: .notFound(suggestions: ["Water Plants"]), name: "Water")
        XCTAssertEqual(error?.toolResultText, "not_found: There's no shortcut named “Water”. Similar names: “Water Plants”.")
        let bare = ScriptShortcutMatching.error(for: .notFound(suggestions: []), name: "Tetris")
        XCTAssertEqual(bare?.toolResultText,
                       "not_found: There's no shortcut named “Tetris”. Call list_shortcuts to see the exact names.")
    }

    func testSuggestionsAreCappedAtFive() {
        let many = (1...9).map { ScriptShortcut(name: "Log \($0)", identifier: UUID().uuidString) }
        XCTAssertEqual(ScriptShortcutMatching.suggestions(for: "log", in: many).count, 5)
    }

    // MARK: - ShortcutsService

    func testListRunsTheCLIOnceAndCachesForAMinute() async throws {
        let clock = TestClock()
        let runner = ShortcutsFakeRunner()
        runner.listOutput = listing
        let service = ShortcutsService(runner: runner, now: { clock.now }, toolIsInstalled: { true },
                                       temporaryDirectory: temporaryDirectory())

        XCTAssertEqual(service.cachedLookup("Log Water"), .unknown)
        let first = try await service.list(folder: nil)
        XCTAssertEqual(first.count, 5)
        XCTAssertEqual(runner.calls.map(\.arguments), [["list", "--show-identifiers"]])
        XCTAssertEqual(runner.calls.first?.executable.path, "/usr/bin/shortcuts")

        _ = try await service.list(folder: nil)
        XCTAssertEqual(runner.calls.count, 1, "cached")
        XCTAssertEqual(service.cachedLookup("Log Water"), .found(first[0]))

        clock.advance(61)
        XCTAssertEqual(service.cachedLookup("Log Water"), .unknown, "stale")
        _ = try await service.list(folder: nil)
        XCTAssertEqual(runner.calls.count, 2)
    }

    func testPrefetchWarmsTheCacheOnce() async throws {
        let runner = ShortcutsFakeRunner()
        runner.listOutput = listing
        let service = ShortcutsService(runner: runner, toolIsInstalled: { true }, temporaryDirectory: temporaryDirectory())
        service.prefetch()
        service.prefetch()
        for _ in 0..<200 where service.cachedLookup("Log Water") == .unknown {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(service.cachedLookup("Log Water"), .unknown)
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testFolderIsResolvedByIdentifierAndMissingFolderIsNotFound() async throws {
        let runner = ShortcutsFakeRunner()
        runner.listOutput = listing
        runner.foldersOutput = "Home (11111111-2222-3333-4444-555555555555)\nPhotos (66666666-7777-8888-9999-AAAAAAAAAAAA)\n"
        runner.folderOutput = "Log Water (4F6B2C1E-8A3D-4B7E-9C21-5D0E6F7A8B91)\n"
        let service = ShortcutsService(runner: runner, toolIsInstalled: { true }, temporaryDirectory: temporaryDirectory())

        let home = try await service.list(folder: "home")
        XCTAssertEqual(home.map(\.name), ["Log Water"])
        XCTAssertEqual(runner.calls.map(\.arguments), [
            ["list", "--folders", "--show-identifiers"],
            ["list", "--show-identifiers", "--folder-name", "11111111-2222-3333-4444-555555555555"],
        ])

        do {
            _ = try await service.list(folder: "Work")
            XCTFail("expected not_found")
        } catch let error as ToolError {
            XCTAssertEqual(error.toolResultText, "not_found: There's no Shortcuts folder named “Work”.")
        }
    }

    func testRunPassesInputAsAPrivateFileAndReadsTextOutput() async throws {
        let runner = ShortcutsFakeRunner()
        runner.runOutputFile = Data("Logged 500 ml\n".utf8)
        let temp = temporaryDirectory()
        let service = ShortcutsService(runner: runner, toolIsInstalled: { true }, temporaryDirectory: temp)
        let shortcut = ScriptShortcut(name: "Log Water", identifier: "4F6B2C1E-8A3D-4B7E-9C21-5D0E6F7A8B91")

        let result = try await service.run(shortcut, input: "500 ml", timeout: .seconds(60))

        XCTAssertEqual(result.output, "Logged 500 ml")
        XCTAssertFalse(result.outputWasNonText)
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(Array(call.arguments.prefix(2)), ["run", "4F6B2C1E-8A3D-4B7E-9C21-5D0E6F7A8B91"])
        XCTAssertEqual(call.timeout, .seconds(60))
        XCTAssertTrue(call.arguments.contains("--output-type"))
        XCTAssertTrue(call.arguments.contains("public.plain-text"))
        XCTAssertEqual(runner.inputSeen, "500 ml")
        XCTAssertEqual(runner.inputPermissions, 0o600)
        XCTAssertEqual(runner.folderPermissions, 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: temp.appendingPathComponent("otto-actions").path)
        XCTAssertEqual(leftovers, [], "the run folder is removed")
    }

    func testRunWithoutInputOrOutput() async throws {
        let runner = ShortcutsFakeRunner()
        let service = ShortcutsService(runner: runner, toolIsInstalled: { true }, temporaryDirectory: temporaryDirectory())
        let result = try await service.run(ScriptShortcut(name: "A", identifier: "X"), input: nil, timeout: .seconds(60))
        XCTAssertNil(result.output)
        XCTAssertFalse(result.outputWasNonText)
        XCTAssertFalse(runner.calls.first?.arguments.contains("--input-path") ?? true)
    }

    func testBinaryOutputIsReportedAsNonText() async throws {
        let runner = ShortcutsFakeRunner()
        runner.runOutputFile = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])
        let service = ShortcutsService(runner: runner, toolIsInstalled: { true }, temporaryDirectory: temporaryDirectory())
        let result = try await service.run(ScriptShortcut(name: "A", identifier: "X"), input: nil, timeout: .seconds(60))
        XCTAssertNil(result.output)
        XCTAssertTrue(result.outputWasNonText)
    }

    func testRunErrors() async {
        let runner = ShortcutsFakeRunner()
        let service = ShortcutsService(runner: runner, toolIsInstalled: { true }, temporaryDirectory: temporaryDirectory())
        let shortcut = ScriptShortcut(name: "A", identifier: "X")

        runner.runResult = ProcessOutput(stdout: "", stderr: "Error: The shortcut couldn't run.\nmore", exitCode: 1,
                                         timedOut: false, duration: .seconds(1))
        await assertThrows(code: .failed, text: "failed: Error: The shortcut couldn't run.") {
            _ = try await service.run(shortcut, input: nil, timeout: .seconds(60))
        }

        runner.runResult = ProcessOutput(stdout: "", stderr: "", exitCode: 15, timedOut: true, duration: .seconds(60))
        await assertThrows(code: .timeout,
                           text: "timeout: The shortcut didn't finish within 60 seconds and was stopped.") {
            _ = try await service.run(shortcut, input: nil, timeout: .seconds(60))
        }

        let missing = ShortcutsService(runner: runner, toolIsInstalled: { false }, temporaryDirectory: temporaryDirectory())
        await assertThrows(code: .failed, text: "failed: The Shortcuts command-line tool isn't available.") {
            _ = try await missing.list(folder: nil)
        }
    }

    func testResolveUsesTheListing() async throws {
        let runner = ShortcutsFakeRunner()
        runner.listOutput = listing
        let service = ShortcutsService(runner: runner, toolIsInstalled: { true }, temporaryDirectory: temporaryDirectory())
        let found = try await service.resolve("water plants")
        XCTAssertEqual(found.identifier, "7C2D9E4F-1B6A-4C8D-A3E5-0F9B2D7C6E14")
        await assertThrows(code: .notFound, text: nil) { _ = try await service.resolve("Nope") }
    }

    // MARK: - Helpers

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("otto-shortcuts-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func assertThrows(code: ToolError.Code, text: String?, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as ToolError {
            XCTAssertEqual(error.code, code, file: file, line: line)
            if let text { XCTAssertEqual(error.toolResultText, text, file: file, line: line) }
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

/// A settable clock for cache expiry.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Answers `shortcuts list` / `run` like the real tool, writing `runOutputFile` to the `--output-path` it is
/// given and remembering the input file it saw. Never starts a process.
private final class ShortcutsFakeRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: URL
        let arguments: [String]
        let timeout: Duration
    }

    private let lock = NSLock()
    private var storage = State()

    private struct State {
        var listOutput = ""
        var foldersOutput = ""
        var folderOutput = ""
        var runOutputFile: Data?
        var runResult = ProcessOutput(stdout: "", stderr: "", exitCode: 0, timedOut: false, duration: .milliseconds(120))
        var calls: [Call] = []
        var inputSeen: String?
        var inputPermissions: Int?
        var folderPermissions: Int?
    }

    var listOutput: String {
        get { lock.withLock { storage.listOutput } }
        set { lock.withLock { storage.listOutput = newValue } }
    }
    var foldersOutput: String {
        get { lock.withLock { storage.foldersOutput } }
        set { lock.withLock { storage.foldersOutput = newValue } }
    }
    var folderOutput: String {
        get { lock.withLock { storage.folderOutput } }
        set { lock.withLock { storage.folderOutput = newValue } }
    }
    var runOutputFile: Data? {
        get { lock.withLock { storage.runOutputFile } }
        set { lock.withLock { storage.runOutputFile = newValue } }
    }
    var runResult: ProcessOutput {
        get { lock.withLock { storage.runResult } }
        set { lock.withLock { storage.runResult = newValue } }
    }
    var calls: [Call] { lock.withLock { storage.calls } }
    var inputSeen: String? { lock.withLock { storage.inputSeen } }
    var inputPermissions: Int? { lock.withLock { storage.inputPermissions } }
    var folderPermissions: Int? { lock.withLock { storage.folderPermissions } }

    func run(_ executable: URL, arguments: [String], stdin: Data?, timeout: Duration,
             outputLimit: Int) async throws -> ProcessOutput {
        let state = lock.withLock { () -> State in
            storage.calls.append(Call(executable: executable, arguments: arguments, timeout: timeout))
            return storage
        }
        func ok(_ stdout: String) -> ProcessOutput {
            ProcessOutput(stdout: stdout, stderr: "", exitCode: 0, timedOut: false, duration: .milliseconds(80))
        }
        if arguments.first == "list" {
            if arguments.contains("--folders") { return ok(state.foldersOutput) }
            if arguments.contains("--folder-name") { return ok(state.folderOutput) }
            return ok(state.listOutput)
        }
        if let index = arguments.firstIndex(of: "--input-path"), index + 1 < arguments.count {
            let path = arguments[index + 1]
            let text = try? String(contentsOfFile: path, encoding: .utf8)
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let folderAttributes = try? FileManager.default.attributesOfItem(
                atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
            lock.withLock {
                storage.inputSeen = text
                storage.inputPermissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue
                storage.folderPermissions = (folderAttributes?[.posixPermissions] as? NSNumber)?.intValue
            }
        }
        if let index = arguments.firstIndex(of: "--output-path"), index + 1 < arguments.count,
           let data = state.runOutputFile {
            try data.write(to: URL(fileURLWithPath: arguments[index + 1]))
        }
        return state.runResult
    }
}
