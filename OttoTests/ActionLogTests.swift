//
//  ActionLogTests.swift
//  OttoTests
//
//  The activity log: in-memory and file modes, 0600 files in a 0700 folder, rotation at 1 MB, pruning
//  by maxAge, clearing, a refused folder, the script fingerprint rule, and that entries written by the
//  executor never hold inputs, notes or outputs.
//

import CryptoKit
import XCTest
@testable import Otto

final class ActionLogTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                                         isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func entry(_ tool: String = "run_shortcut", daysAgo: Double = 0, summary: String = "Run “Log water”",
                       from now: Date = Date()) -> ActionLogEntry {
        ActionLogEntry(id: UUID(), date: now.addingTimeInterval(-daysAgo * 86_400), tool: tool, decision: "approved",
                       outcome: "ok", summary: summary, provenance: nil, caution: false, durationMs: 12,
                       scriptSHA256: nil, script: nil, target: "Log water")
    }

    private var logsFolder: URL { folder.appendingPathComponent("Logs.noindex", isDirectory: true) }

    // MARK: - Modes

    func testInMemoryLogKeepsEntriesNewestFirst() async throws {
        let log = ActionLog(directory: nil)
        let first = entry("calendar_create_event")
        let second = entry("open_url")
        await log.append(first)
        await log.append(second)
        let recent = await log.recent(limit: 10)
        XCTAssertEqual(recent, [second, first])
        let limited = await log.recent(limit: 1)
        XCTAssertEqual(limited, [second])
        try await log.clear()
        let cleared = await log.recent(limit: 10)
        XCTAssertEqual(cleared, [])
    }

    func testFileLogWritesPrivateFilesAndReloads() async throws {
        let log = ActionLog(directory: logsFolder)
        let first = entry(from: Date(timeIntervalSinceReferenceDate: 810_000_000))
        await log.append(first)
        await log.append(entry("open_url", from: Date(timeIntervalSinceReferenceDate: 810_000_060)))

        let file = logsFolder.appendingPathComponent(ActionLog.fileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: logsFolder.path)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"tool\":\"run_shortcut\""))

        let reloaded = ActionLog(directory: logsFolder)
        let recent = await reloaded.recent(limit: 5)
        XCTAssertEqual(recent.map(\.tool), ["open_url", "run_shortcut"])
        XCTAssertEqual(recent.last, first)
    }

    func testRotatesAtOneMegabyteKeepingTwoFiles() async throws {
        let log = ActionLog(directory: logsFolder, maxAge: nil)
        let big = String(repeating: "x", count: 20_000)
        for _ in 0..<110 { await log.append(entry(summary: big)) }

        let current = logsFolder.appendingPathComponent(ActionLog.fileName)
        let rotated = logsFolder.appendingPathComponent(ActionLog.rotatedFileName)
        let currentSize = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: current.path)[.size] as? NSNumber)
        let rotatedSize = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: rotated.path)[.size] as? NSNumber)
        XCTAssertLessThanOrEqual(currentSize.intValue, ActionLog.rotationBytes)
        XCTAssertLessThanOrEqual(rotatedSize.intValue, ActionLog.rotationBytes)
        XCTAssertGreaterThan(rotatedSize.intValue, ActionLog.rotationBytes - 30_000)
        let names = try FileManager.default.contentsOfDirectory(atPath: logsFolder.path).filter { $0.hasSuffix(".jsonl") }
        XCTAssertEqual(Set(names), [ActionLog.fileName, ActionLog.rotatedFileName])
        let recent = await log.recent(limit: 100)
        XCTAssertGreaterThan(recent.count, 50, "both files are read")
        XCTAssertLessThan(recent.count, 110, "the oldest file was dropped at the second rotation")
    }

    // MARK: - Pruning

    func testPruneDropsEntriesOlderThanMaxAge() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 810_000_000)
        let log = ActionLog(directory: logsFolder, maxAge: 30 * 86_400, now: { now })
        let old = entry("open_url", daysAgo: 45, from: now)
        let recentEntry = entry("run_shortcut", daysAgo: 2, from: now)
        await log.append(old)
        await log.append(recentEntry)

        await log.prune(now: now)
        let kept = await log.recent(limit: 10)
        XCTAssertEqual(kept, [recentEntry])

        // A shorter retention (History set to 1 day) drops more on the next prune.
        await log.setMaxAge(86_400)
        await log.prune(now: now)
        let afterShorter = await log.recent(limit: 10)
        XCTAssertEqual(afterShorter, [])
        let text = try String(contentsOf: logsFolder.appendingPathComponent(ActionLog.fileName), encoding: .utf8)
        XCTAssertEqual(text, "")
    }

    func testAShorterRetentionPrunesRightAway() async throws {
        let log = ActionLog(directory: logsFolder, maxAge: 30 * 86_400)
        let older = entry("calendar_create_event", daysAgo: 3, summary: "Add “Therapy with Dr. Lee” to Calendar")
        let fresh = entry("open_url", daysAgo: 0.1)
        await log.append(older)
        await log.append(fresh)

        // History set to Keep conversations for 1 day, with no rotation or relaunch after it.
        await log.setMaxAge(86_400)
        let text = try String(contentsOf: logsFolder.appendingPathComponent(ActionLog.fileName), encoding: .utf8)
        XCTAssertFalse(text.contains("Therapy"), "the expired title left the disk at once")
        let kept = await log.recent(limit: 10)
        XCTAssertEqual(kept.map(\.id), [fresh.id])
    }

    func testExpiredEntriesGoAtTheNextAppendOrRead() async throws {
        let seeding = ActionLog(directory: logsFolder, maxAge: nil)
        await seeding.append(entry("calendar_create_event", daysAgo: 40, summary: "Add “Therapy” to Calendar"))

        // A long-running session: the entry expired since the last prune, and nothing rotated.
        let log = ActionLog(directory: logsFolder, maxAge: 30 * 86_400)
        let listed = await log.recent(limit: 10)
        XCTAssertEqual(listed, [], "a read never shows an expired entry")
        let fresh = entry("open_url")
        await log.append(fresh)
        let text = try String(contentsOf: logsFolder.appendingPathComponent(ActionLog.fileName), encoding: .utf8)
        XCTAssertFalse(text.contains("Therapy"))
        let kept = await log.recent(limit: 10)
        XCTAssertEqual(kept.map(\.id), [fresh.id])
    }

    func testWithHistoryOffEntriesStayInMemory() async throws {
        let log = ActionLog(directory: logsFolder)
        let saved = entry("open_url")
        await log.append(saved)
        await log.setPersisting(false)
        let unsaved = entry("run_applescript", summary: "Run a script")
        await log.append(unsaved)

        let file = logsFolder.appendingPathComponent(ActionLog.fileName)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 1, "nothing new reached the disk")
        XCTAssertFalse(text.contains("run_applescript"))
        let listed = await log.recent(limit: 10)
        XCTAssertEqual(listed.map(\.id), [unsaved.id, saved.id], "this session still lists it")

        let reloaded = ActionLog(directory: logsFolder)
        let afterRelaunch = await reloaded.recent(limit: 10)
        XCTAssertEqual(afterRelaunch.map(\.id), [saved.id])

        await log.setPersisting(true)
        let later = entry("media_control")
        await log.append(later)
        let resumed = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(resumed.contains("media_control"))
        XCTAssertFalse(resumed.contains("run_applescript"), "entries made while off are never written later")
    }

    func testPruneInMemoryAndWithoutTimeLimit() async {
        let now = Date(timeIntervalSinceReferenceDate: 810_000_000)
        let log = ActionLog(directory: nil, maxAge: 7 * 86_400)
        let old = entry(daysAgo: 8, from: now)
        let fresh = entry(daysAgo: 1, from: now)
        await log.append(old)
        await log.append(fresh)
        await log.prune(now: now)
        let kept = await log.recent(limit: 10)
        XCTAssertEqual(kept, [fresh])

        let forever = ActionLog(directory: nil, maxAge: nil)
        await forever.append(old)
        await forever.prune(now: now)
        let unlimited = await forever.recent(limit: 10)
        XCTAssertEqual(unlimited, [old])
    }

    func testClearRemovesBothFiles() async throws {
        let log = ActionLog(directory: logsFolder, maxAge: nil)
        let big = String(repeating: "y", count: 40_000)
        for _ in 0..<30 { await log.append(entry(summary: big)) }
        try await log.clear()
        let names = try FileManager.default.contentsOfDirectory(atPath: logsFolder.path).filter { $0.hasSuffix(".jsonl") }
        XCTAssertEqual(names, [])
        let recent = await log.recent(limit: 5)
        XCTAssertEqual(recent, [])
        await log.append(entry())
        let afterClear = await log.recent(limit: 5)
        XCTAssertEqual(afterClear.count, 1)
    }

    func testSymlinkedFolderIsRefusedAndTheLogStaysInMemory() async throws {
        let target = folder.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("Logs.noindex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let log = ActionLog(directory: link)
        let written = entry()
        await log.append(written)
        let recent = await log.recent(limit: 5)
        XCTAssertEqual(recent, [written])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    // MARK: - Content rules

    func testScriptRecordKeepsA200CharacterPrefixAndTheHash() {
        let source = String(repeating: "tell application \"Finder\" to get name of every disk\n", count: 10)
        let expectedHash = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()

        let record = ActionLogEntry.scriptRecord(source, keepFull: false)
        XCTAssertEqual(record.sha256, expectedHash)
        XCTAssertEqual(record.script.count, 200)
        XCTAssertEqual(record.script, String(source.prefix(200)))

        let full = ActionLogEntry.scriptRecord(source, keepFull: true)
        XCTAssertEqual(full.script, source)
        XCTAssertEqual(full.sha256, expectedHash)
    }

    @MainActor
    func testExecutorEntriesNeverHoldInputsNotesOrOutputs() async throws {
        let log = ActionLog(directory: logsFolder)
        let store = ActionLogTestStore()
        let executor = ToolExecutor(permissions: FakePermissionProvider(default: .granted),
                                    approvals: ApprovalStore(defaults: TestDefaults.make(for: self)), log: log)
        let tool = ActionLogNoteTool()
        let messageID = UUID()
        store.add(ToolCall(id: "call_1", name: tool.name, input: ["title": "Dentist", "notes": "SECRET-NOTE-4471"],
                           presentation: .generic(toolName: tool.name), status: .queued), to: messageID)
        let round = ToolRound(messageID: messageID, callIDs: ["call_1"], roundIndex: 0, transcript: [],
                              tools: [tool.name: tool], model: .opus5)
        executor.beginTurn()
        _ = try await executor.execute(round, store: store)

        XCTAssertEqual(store.call("call_1", messageID)?.status, .succeeded)
        let text = try String(contentsOf: logsFolder.appendingPathComponent(ActionLog.fileName), encoding: .utf8)
        XCTAssertTrue(text.contains("\"summary\":\"Save “Dentist”\""))
        XCTAssertTrue(text.contains("\"decision\":\"auto\""))
        XCTAssertTrue(text.contains("\"outcome\":\"ok\""))
        XCTAssertFalse(text.contains("SECRET-NOTE-4471"), "inputs and notes stay out of the log")
        XCTAssertFalse(text.contains("OUTPUT-8812"), "outputs stay out of the log")
    }

    @MainActor
    func testExecutorLogsAScriptAsPrefixAndHashUnlessFullScriptsAreOn() async throws {
        let script = "-- " + String(repeating: "a", count: 300) + "\nreturn 1"
        for keepFull in [false, true] {
            let log = ActionLog(directory: nil)
            let store = ActionLogTestStore()
            let executor = ToolExecutor(permissions: FakePermissionProvider(default: .granted),
                                        approvals: ApprovalStore(defaults: TestDefaults.make(for: self)), log: log,
                                        logFullScripts: { keepFull })
            let tool = ActionLogScriptTool()
            let messageID = UUID()
            store.add(ToolCall(id: "s1", name: tool.name, input: ["script": .string(script)],
                               presentation: .generic(toolName: tool.name), status: .queued), to: messageID)
            executor.beginTurn()
            _ = try await executor.execute(ToolRound(messageID: messageID, callIDs: ["s1"], roundIndex: 0,
                                                     transcript: [], tools: [tool.name: tool], model: .opus5),
                                           store: store)
            let recent = await log.recent(limit: 1)
            let logged = try XCTUnwrap(recent.first)
            XCTAssertEqual(logged.scriptSHA256, ActionLogEntry.scriptRecord(script, keepFull: false).sha256)
            XCTAssertEqual(logged.script, keepFull ? script : String(script.prefix(200)))
        }
    }
}

// MARK: - Private fakes

@MainActor private final class ActionLogTestStore: ToolCallStore {
    private var calls: [UUID: [ToolCall]] = [:]

    func add(_ call: ToolCall, to messageID: UUID) { calls[messageID, default: []].append(call) }
    func call(_ id: String, _ messageID: UUID) -> ToolCall? { toolCall(id, in: messageID) }

    func toolCall(_ id: String, in messageID: UUID) -> ToolCall? {
        calls[messageID]?.first { $0.id == id }
    }

    func updateToolCall(_ id: String, in messageID: UUID, _ mutate: (inout ToolCall) -> Void) {
        guard var list = calls[messageID], let index = list.firstIndex(where: { $0.id == id }) else { return }
        mutate(&list[index])
        calls[messageID] = list
    }
}

/// Saves a note somewhere (no card): its input carries a note and its output a marker.
private struct ActionLogNoteTool: OttoTool {
    var name = "save_note"
    var group: ToolGroup? = nil
    var description = "Saves a note."
    var inputSchema: JSONValue {
        [
            "type": "object",
            "properties": ["title": ["type": "string"], "notes": ["type": "string"]],
            "required": ["title", "notes"],
            "additionalProperties": false,
        ]
    }
    var isConcurrencySafe: Bool { true }
    var sampleInput: JSONValue { ["title": "a", "notes": "b"] }

    @MainActor func isAvailable(in environment: ToolEnvironment) -> Bool { true }
    func approvalRequirement(for input: JSONValue) -> ApprovalRequirement { .none }
    func describe(_ input: JSONValue) -> ToolCallPresentation {
        ToolCallPresentation(symbol: "note", title: "Save “\(input["title"]?.stringValue ?? "")”", activeTitle: "Saving…",
                             doneTitle: "Saved", detail: input["notes"]?.stringValue, disclosure: nil)
    }
    func approvalBody(for input: JSONValue) async -> ApprovalBody {
        .text(TextPreview(label: "Note", text: input["notes"]?.stringValue ?? "", language: nil))
    }
    func run(_ input: JSONValue, context: ToolRunContext) async throws -> ToolRunResult {
        ToolRunResult(output: .text("{\"status\":\"saved\",\"echo\":\"OUTPUT-8812\"}"))
    }
}

/// Stands in for run_applescript (no card, so the test needs no approval).
private struct ActionLogScriptTool: OttoTool {
    var name = "run_applescript"
    var group: ToolGroup? = .appleScript
    var description = "Runs a script."
    var inputSchema: JSONValue {
        ["type": "object", "properties": ["script": ["type": "string"]], "required": ["script"],
         "additionalProperties": false]
    }
    var isConcurrencySafe: Bool { true }
    var sampleInput: JSONValue { ["script": "return 1"] }

    @MainActor func isAvailable(in environment: ToolEnvironment) -> Bool { true }
    func approvalRequirement(for input: JSONValue) -> ApprovalRequirement { .none }
    func describe(_ input: JSONValue) -> ToolCallPresentation { .generic(toolName: name) }
    func approvalBody(for input: JSONValue) async -> ApprovalBody {
        .text(TextPreview(label: "Script", text: input["script"]?.stringValue ?? "", language: "AppleScript"))
    }
    func run(_ input: JSONValue, context: ToolRunContext) async throws -> ToolRunResult {
        ToolRunResult(output: .text("1"))
    }
}
