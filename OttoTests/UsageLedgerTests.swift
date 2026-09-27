//
//  UsageLedgerTests.swift
//  OttoTests
//
//  The ledger on a fixed UTC calendar with an injected clock: answers and day buckets, reply counting,
//  range totals, the file round trip and its permissions, the debounced write, quarantine of damaged
//  files, the 400-day archive, demo replies, reset, and refusing an unsafe ledger file.
//

import XCTest
@testable import Otto

@MainActor final class UsageLedgerTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory
    private var clock = Date()
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageLedgerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        clock = date(2026, 9, 27, hour: 12)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Recording

    func testRecordFillsAnswersAndTheDayBucket() throws {
        let ledger = makeLedger(fileURL: nil)
        let id = UUID()
        ledger.record(usage: opusUsage, requestedModel: "claude-opus-5", servedModel: "claude-opus-5-20260901",
                      stopReason: "end_turn", isPartial: false, messageID: id, at: clock)

        let answer = try XCTUnwrap(ledger.answer(for: id))
        XCTAssertEqual(answer.requests, 1)
        XCTAssertEqual(answer.totalNanos, 17_500_000)
        XCTAssertEqual(answer.servedModel, "claude-opus-5-20260901")
        XCTAssertFalse(answer.fellBack)
        XCTAssertFalse(answer.isDemo)
        XCTAssertEqual(ledger.answers[id], answer)

        // Dated snapshots are stored under the pricing table's id; no reply is counted until the answer settles.
        XCTAssertEqual(ledger.days, ["2026-09-27": ["claude-opus-5": UsageTotals(
            usage: TokenUsage(input: 1_000, output: 500), costNanos: 17_500_000)]])

        ledger.finishAnswer(messageID: id)
        ledger.finishAnswer(messageID: id)
        XCTAssertEqual(ledger.days["2026-09-27"]?["claude-opus-5"]?.replies, 1)
        XCTAssertEqual(ledger.today, UsageTotals(usage: TokenUsage(input: 1_000, output: 500), costNanos: 17_500_000,
                                                 replies: 1))
    }

    func testPauseTurnRequestsSumIntoOneAnswer() throws {
        let ledger = makeLedger(fileURL: nil)
        let id = UUID()
        for _ in 0..<2 {
            ledger.record(usage: opusUsage, requestedModel: "claude-opus-5", servedModel: "claude-opus-5",
                          stopReason: "pause_turn", isPartial: false, messageID: id, at: clock)
        }
        ledger.finishAnswer(messageID: id)
        let answer = try XCTUnwrap(ledger.answer(for: id))
        XCTAssertEqual(answer.requests, 2)
        XCTAssertEqual(answer.lines.count, 1)
        XCTAssertEqual(answer.totalNanos, 35_000_000)
        XCTAssertEqual(ledger.today.replies, 1)
        XCTAssertEqual(ledger.today.costNanos, 35_000_000)
    }

    func testFallbackPartialAndMissingUsage() throws {
        let ledger = makeLedger(fileURL: nil)
        let fallback = UUID()
        ledger.record(usage: [
            "iterations": [
                ["type": "message", "model": "claude-opus-5", "input_tokens": 1_000, "output_tokens": 0],
                ["type": "fallback_message", "model": "claude-opus-4-8", "input_tokens": 1_000, "output_tokens": 240],
            ],
        ], requestedModel: "claude-opus-5", servedModel: "claude-opus-4-8", stopReason: "end_turn", isPartial: false,
           messageID: fallback, at: clock)
        let answer = try XCTUnwrap(ledger.answer(for: fallback))
        XCTAssertTrue(answer.fellBack)
        XCTAssertEqual(answer.servedModel, "claude-opus-4-8")
        XCTAssertEqual(answer.totalNanos, 11_000_000)
        // The declined attempt costs nothing and adds no empty model row.
        XCTAssertEqual(ledger.days["2026-09-27"]?.keys.sorted(), ["claude-opus-4-8"])

        // A served model other than the requested one counts as a fallback even without iterations.
        let served = UUID()
        ledger.record(usage: opusUsage, requestedModel: "claude-opus-5", servedModel: "claude-opus-4-7",
                      stopReason: "end_turn", isPartial: false, messageID: served, at: clock)
        XCTAssertEqual(ledger.answer(for: served)?.fellBack, true)

        let partial = UUID()
        ledger.record(usage: ["input_tokens": 800], requestedModel: "claude-opus-5", servedModel: nil, stopReason: nil,
                      isPartial: true, messageID: partial, at: clock)
        XCTAssertEqual(ledger.answer(for: partial)?.isPartial, true)

        let missing = UUID()
        ledger.record(usage: nil, requestedModel: "claude-opus-5", servedModel: "claude-opus-5", stopReason: "end_turn",
                      isPartial: false, messageID: missing, at: clock)
        ledger.finishAnswer(messageID: missing)
        XCTAssertNil(ledger.answer(for: missing))
    }

    func testUnpricedModelCountsTokensButNoCost() {
        let ledger = makeLedger(fileURL: nil)
        let id = UUID()
        ledger.record(usage: ["input_tokens": 300, "output_tokens": 20], requestedModel: "claude-opus-6",
                      servedModel: nil, stopReason: "end_turn", isPartial: false, messageID: id, at: clock)
        ledger.finishAnswer(messageID: id)
        XCTAssertNil(ledger.answer(for: id)?.totalNanos)
        XCTAssertEqual(ledger.today, UsageTotals(usage: TokenUsage(input: 300, output: 20), costNanos: 0,
                                                 unpricedTokens: 320, replies: 1))
    }

    func testRequestsBucketByRecordDayAndRepliesByFinishDay() {
        let ledger = makeLedger(fileURL: nil)
        let id = UUID()
        ledger.record(usage: opusUsage, requestedModel: "claude-opus-5", servedModel: nil, stopReason: "end_turn",
                      isPartial: false, messageID: id, at: date(2026, 9, 26, hour: 23, minute: 59))
        clock = date(2026, 9, 27, hour: 0, minute: 1)
        ledger.finishAnswer(messageID: id)
        XCTAssertEqual(ledger.days["2026-09-26"]?["claude-opus-5"]?.costNanos, 17_500_000)
        XCTAssertEqual(ledger.days["2026-09-27"]?["claude-opus-5"]?.replies, 1)
        XCTAssertEqual(ledger.today, UsageTotals(replies: 1))
    }

    // MARK: - Queries

    func testRangeTotals() {
        let ledger = makeLedger(fileURL: nil)
        ledger.debugSeed(answers: [], days: [
            "2026-08-31": ["claude-opus-5": UsageTotals(costNanos: 1, replies: 1)],
            "2026-09-01": ["claude-opus-5": UsageTotals(costNanos: 10, replies: 1)],
            "2026-09-20": ["claude-sonnet-5": UsageTotals(costNanos: 100, replies: 1)],
            "2026-09-21": ["claude-opus-5": UsageTotals(costNanos: 1_000, replies: 1)],
            "2026-09-26": ["claude-haiku-4-5": UsageTotals(costNanos: 10_000, replies: 1)],
            "2026-09-27": ["claude-opus-5": UsageTotals(costNanos: 100_000, replies: 2),
                           "claude-haiku-4-5": UsageTotals(costNanos: 1_000_000, replies: 1)],
            "2026-09-28": ["claude-opus-5": UsageTotals(costNanos: 10_000_000, replies: 1)],
        ])

        XCTAssertEqual(ledger.today, UsageTotals(costNanos: 1_100_000, replies: 3))
        XCTAssertEqual(ledger.thisMonth, UsageTotals(costNanos: 11_111_110, replies: 8))

        // Last 7 days: the six days before today plus today.
        let startOfToday = calendar.startOfDay(for: clock)
        let sevenDaysAgo = startOfToday.addingTimeInterval(-6 * 86_400)
        XCTAssertEqual(ledger.totals(from: sevenDaysAgo, to: clock), UsageTotals(costNanos: 1_111_000, replies: 5))

        let yesterday = startOfToday.addingTimeInterval(-86_400)
        XCTAssertEqual(ledger.totals(from: yesterday, to: startOfToday), UsageTotals(costNanos: 10_000, replies: 1))
        XCTAssertEqual(ledger.totals(from: .distantPast, to: .distantFuture).costNanos, 11_111_111)

        let byModel = ledger.totalsByModel(from: date(2026, 9, 1), to: date(2026, 10, 1))
        XCTAssertEqual(byModel.map(\.model), ["claude-opus-5", "claude-haiku-4-5", "claude-sonnet-5"])
        XCTAssertEqual(byModel.map(\.totals.costNanos), [10_101_010, 1_010_000, 100])
    }

    // MARK: - Persistence

    func testPersistenceRoundTripWritesOnlyNumbersWithPrivatePermissions() throws {
        let url = ledgerURL
        let ledger = makeLedger(fileURL: url)
        let id = UUID()
        ledger.record(usage: opusUsage, requestedModel: "claude-opus-5", servedModel: "claude-opus-5",
                      stopReason: "end_turn", isPartial: false, messageID: id, at: clock)
        ledger.finishAnswer(messageID: id)
        ledger.flush()

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("{\"days\":{\"2026-09-27\":{\"claude-opus-5\":{"), text)
        XCTAssertTrue(text.contains("\"version\":1"), text)
        XCTAssertFalse(text.contains(id.uuidString))

        let reloaded = makeLedger(fileURL: url)
        XCTAssertEqual(reloaded.days, ledger.days)
        XCTAssertTrue(reloaded.answers.isEmpty, "answers belong to one session")
        XCTAssertEqual(reloaded.today.replies, 1)
    }

    func testChangesAreWrittenAfterTheDebounce() async throws {
        let url = ledgerURL
        let ledger = makeLedger(fileURL: url)
        ledger.record(usage: opusUsage, requestedModel: "claude-opus-5", servedModel: nil, stopReason: "end_turn",
                      isPartial: false, messageID: UUID(), at: clock)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "writes wait for the debounce")

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        withExtendedLifetime(ledger) {}
    }

    func testCorruptFileIsQuarantined() throws {
        let url = ledgerURL
        try Data("{not json".utf8).write(to: url)

        let ledger = makeLedger(fileURL: url)
        XCTAssertTrue(ledger.days.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try quarantinedFiles(), ["usage-ledger.corrupt-20260927-120000.json"])

        // The ledger keeps working and saves a fresh file.
        ledger.record(usage: opusUsage, requestedModel: "claude-opus-5", servedModel: nil, stopReason: "end_turn",
                      isPartial: false, messageID: UUID(), at: clock)
        ledger.flush()
        XCTAssertEqual(makeLedger(fileURL: url).days, ledger.days)
    }

    func testUnknownVersionIsQuarantinedWithoutOverwritingEarlierCopies() throws {
        let url = ledgerURL
        try Data("{\"version\":2,\"days\":{}}".utf8).write(to: url)
        try Data("older".utf8).write(to: directory.appendingPathComponent("usage-ledger.corrupt-20260927-120000.json"))

        let ledger = makeLedger(fileURL: url)
        XCTAssertTrue(ledger.days.isEmpty)
        XCTAssertEqual(try quarantinedFiles(), ["usage-ledger.corrupt-20260927-120000-2.json",
                                                "usage-ledger.corrupt-20260927-120000.json"])
    }

    func testDemoRepliesAreNeverPersisted() throws {
        let url = ledgerURL
        let ledger = makeLedger(fileURL: url)
        let id = UUID()
        ledger.record(usage: opusUsage, requestedModel: "claude-opus-5", servedModel: MockLLMClient.demoModel,
                      stopReason: "end_turn", isPartial: false, messageID: id, at: clock)
        ledger.finishAnswer(messageID: id)
        ledger.flush()

        let answer = try XCTUnwrap(ledger.answer(for: id))
        XCTAssertTrue(answer.isDemo)
        XCTAssertEqual(answer.totalNanos, 0)
        XCTAssertFalse(answer.fellBack)
        XCTAssertEqual(CostFormatter.summary(answer), "Opus 5 · ≈1.8¢ (demo)")
        XCTAssertTrue(ledger.days.isEmpty)
        XCTAssertEqual(ledger.today, UsageTotals())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDaysPastRetentionFoldIntoTheArchive() throws {
        let url = ledgerURL
        let old = UsageTotals(usage: TokenUsage(input: 5), costNanos: 7, replies: 1)
        let file = """
        {"version":1,"days":{"2025-01-01":{"claude-opus-5":{"usage":{"input":5,"output":0,"cacheRead":0,\
        "cacheWrite5m":0,"cacheWrite1h":0,"webSearches":0},"costNanos":7,"unpricedTokens":0,"replies":1}},\
        "2025-08-24":{"claude-opus-5":{"usage":{"input":5,"output":0,"cacheRead":0,"cacheWrite5m":0,\
        "cacheWrite1h":0,"webSearches":0},"costNanos":7,"unpricedTokens":0,"replies":1}},\
        "2025-08-25":{"claude-opus-5":{"usage":{"input":5,"output":0,"cacheRead":0,"cacheWrite5m":0,\
        "cacheWrite1h":0,"webSearches":0},"costNanos":7,"unpricedTokens":0,"replies":1}},\
        "not-a-day":{}}}
        """
        try Data(file.utf8).write(to: url)

        // 2026-09-27 keeps 400 days: 2025-08-24 through today.
        let ledger = makeLedger(fileURL: url)
        XCTAssertEqual(ledger.days.keys.sorted(), ["2025-08-24", "2025-08-25"])
        XCTAssertEqual(ledger.totals(from: .distantPast, to: clock), UsageTotals(usage: TokenUsage(input: 15),
                                                                                  costNanos: 21, replies: 3))
        XCTAssertEqual(ledger.totals(from: date(2025, 8, 24), to: clock).costNanos, 14)
        XCTAssertEqual(ledger.thisMonth, UsageTotals())

        // A day later, 2025-08-24 folds too; the archive survives a reload.
        clock = date(2026, 9, 28, hour: 9)
        ledger.record(usage: ["input_tokens": 1], requestedModel: "claude-opus-5", servedModel: nil,
                      stopReason: "end_turn", isPartial: false, messageID: UUID(), at: clock)
        XCTAssertEqual(ledger.days.keys.sorted(), ["2025-08-25", "2026-09-28"])
        ledger.flush()

        let reloaded = makeLedger(fileURL: url)
        XCTAssertEqual(reloaded.totalsByModel(from: .distantPast, to: clock).map(\.totals),
                       [old + old + old + UsageTotals(usage: TokenUsage(input: 1), costNanos: 5_000)])
        XCTAssertEqual(reloaded.totals(from: date(2025, 8, 25), to: clock).costNanos, 5_007)
    }

    func testResetClearsTotalsButKeepsThisSessionsAnswers() throws {
        let url = ledgerURL
        let ledger = makeLedger(fileURL: url)
        let id = UUID()
        ledger.record(usage: opusUsage, requestedModel: "claude-opus-5", servedModel: nil, stopReason: "end_turn",
                      isPartial: false, messageID: id, at: clock)
        ledger.finishAnswer(messageID: id)
        ledger.flush()

        ledger.reset()
        XCTAssertTrue(ledger.days.isEmpty)
        XCTAssertEqual(ledger.today, UsageTotals())
        XCTAssertNotNil(ledger.answer(for: id))
        XCTAssertTrue(makeLedger(fileURL: url).days.isEmpty, "reset rewrites the file at once")
    }

    func testDebugSeedReplacesStateWithoutWriting() {
        let url = ledgerURL
        let ledger = makeLedger(fileURL: url)
        let answer = AnswerUsage(messageID: UUID(), requests: 1,
                                 lines: [PricedLine(model: "claude-opus-5", usage: TokenUsage(input: 1), costNanos: 5_000)],
                                 isPartial: false, isDemo: false, fellBack: false)
        ledger.debugSeed(answers: [answer], days: ["2026-09-27": ["claude-opus-5": UsageTotals(costNanos: 5, replies: 1)]])
        XCTAssertEqual(ledger.answer(for: answer.messageID), answer)
        XCTAssertEqual(ledger.today, UsageTotals(costNanos: 5, replies: 1))
        ledger.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSymlinkedLedgerIsRefusedAndNeverWrittenThrough() throws {
        let target = directory.appendingPathComponent("elsewhere.json")
        try Data("{\"version\":1,\"days\":{}}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: ledgerURL, withDestinationURL: target)

        let ledger = makeLedger(fileURL: ledgerURL)
        ledger.record(usage: opusUsage, requestedModel: "claude-opus-5", servedModel: nil, stopReason: "end_turn",
                      isPartial: false, messageID: UUID(), at: clock)
        ledger.flush()
        XCTAssertEqual(ledger.today.costNanos, 17_500_000, "the session still counts in memory")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "{\"version\":1,\"days\":{}}")
    }

    // MARK: - Helpers

    private let opusUsage: JSONValue = ["input_tokens": 1_000, "output_tokens": 500]

    private var ledgerURL: URL { directory.appendingPathComponent("usage-ledger.json") }

    private func makeLedger(fileURL: URL?) -> UsageLedger {
        UsageLedger(fileURL: fileURL, calendar: calendar, now: { [weak self] in self?.clock ?? Date() })
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date()
    }

    private func quarantinedFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("usage-ledger.corrupt-") }
            .sorted()
    }
}
