//
//  HistoryPolicyTests.swift
//  Otto
//
//  The pure History rules: idle fresh start, retention cutoffs, which payload blobs survive, the
//  FileVault status parser and the stored message states.
//

import XCTest
@testable import Otto

final class HistoryPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_500_000)

    private func context(
        lastActivity: Date? = Date(timeIntervalSince1970: 1_790_500_000 - 1_000),
        interval: IdleResetInterval = .fifteenMinutes,
        hasMessages: Bool = true,
        isStreaming: Bool = false,
        hasUnreadReply: Bool = false,
        hasDraft: Bool = false
    ) -> HistoryPolicy.IdleContext {
        HistoryPolicy.IdleContext(now: now, lastActivity: lastActivity, interval: interval, hasMessages: hasMessages,
                                  isStreaming: isStreaming, hasUnreadReply: hasUnreadReply, hasDraft: hasDraft)
    }

    // MARK: Idle fresh start

    func testStartsFreshAfterTheIdleInterval() {
        XCTAssertTrue(HistoryPolicy.shouldStartFresh(context()))
        XCTAssertTrue(HistoryPolicy.shouldStartFresh(context(lastActivity: now.addingTimeInterval(-3_601), interval: .oneHour)))
    }

    func testStartsFreshExactlyAtTheThreshold() {
        XCTAssertTrue(HistoryPolicy.shouldStartFresh(context(lastActivity: now.addingTimeInterval(-900))))
        XCTAssertFalse(HistoryPolicy.shouldStartFresh(context(lastActivity: now.addingTimeInterval(-899.9))))
    }

    func testEachBlockingConditionKeepsTheConversation() {
        XCTAssertFalse(HistoryPolicy.shouldStartFresh(context(hasMessages: false)), "empty chat")
        XCTAssertFalse(HistoryPolicy.shouldStartFresh(context(isStreaming: true)), "streaming")
        XCTAssertFalse(HistoryPolicy.shouldStartFresh(context(hasUnreadReply: true)), "unread reply")
        XCTAssertFalse(HistoryPolicy.shouldStartFresh(context(hasDraft: true)), "draft")
        XCTAssertFalse(HistoryPolicy.shouldStartFresh(context(interval: .never)), "never")
        XCTAssertFalse(HistoryPolicy.shouldStartFresh(context(lastActivity: nil)), "no activity yet")
        XCTAssertFalse(HistoryPolicy.shouldStartFresh(context(lastActivity: now.addingTimeInterval(-60))), "not reached")
        XCTAssertFalse(HistoryPolicy.shouldStartFresh(context(lastActivity: now.addingTimeInterval(3_600))), "clock set back")
    }

    // MARK: Retention

    func testRetentionCutoffForEachChoice() {
        XCTAssertEqual(HistoryPolicy.retentionCutoff(.week, now: now), now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(HistoryPolicy.retentionCutoff(.month, now: now), now.addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(HistoryPolicy.retentionCutoff(.quarter, now: now), now.addingTimeInterval(-90 * 86_400))
        XCTAssertNil(HistoryPolicy.retentionCutoff(.forever, now: now))
    }

    func testRetentionAndIdleLabels() {
        XCTAssertEqual(HistoryRetention.allCases.map(\.displayName), ["7 days", "30 days", "90 days", "Forever"])
        XCTAssertEqual(HistoryRetention.forever.shortLabel, "forever")
        XCTAssertEqual(IdleResetInterval.allCases.map(\.interval), [900, 3_600, nil])
    }

    // MARK: Blobs

    private func blob(_ name: Character, bytes: Int64, daysAgo: Double) -> HistoryPolicy.BlobUsage {
        HistoryPolicy.BlobUsage(sha256: String(repeating: name, count: 64), bytes: bytes,
                                lastUsed: now.addingTimeInterval(-daysAgo * 86_400))
    }

    func testBlobsOutsideTheWindowAreDropped() {
        let usage = [blob("a", bytes: 10, daysAgo: 1), blob("b", bytes: 10, daysAgo: 31)]
        let kept = HistoryPolicy.blobsToKeep(usage, protected: [], now: now, window: 30 * 86_400, budget: 1_000)
        XCTAssertEqual(kept, [usage[0].sha256])
    }

    func testBudgetKeepsNewestFirstAndStopsAtTheFirstMisfit() {
        let usage = [
            blob("a", bytes: 40, daysAgo: 3),
            blob("b", bytes: 50, daysAgo: 1),
            blob("c", bytes: 5, daysAgo: 5),
        ]
        let kept = HistoryPolicy.blobsToKeep(usage, protected: [], now: now, window: 30 * 86_400, budget: 60)
        XCTAssertEqual(kept, [usage[1].sha256], "b fits, a would exceed the budget, so older c goes too")
    }

    func testProtectedBlobsAreKeptEvenOverBudgetAndCountFirst() {
        let usage = [blob("a", bytes: 100, daysAgo: 90), blob("b", bytes: 10, daysAgo: 1)]
        let kept = HistoryPolicy.blobsToKeep(usage, protected: [usage[0].sha256], now: now,
                                             window: 30 * 86_400, budget: 50)
        XCTAssertEqual(kept, [usage[0].sha256])
    }

    func testDuplicateUsesMergeToTheNewest() {
        let old = blob("a", bytes: 10, daysAgo: 60)
        let recent = blob("a", bytes: 10, daysAgo: 2)
        let kept = HistoryPolicy.blobsToKeep([old, recent], protected: [], now: now, window: 30 * 86_400, budget: 100)
        XCTAssertEqual(kept, [old.sha256])
    }

    func testLowDiskBudgetSelection() {
        let policy = HistoryPolicy.standard
        XCTAssertEqual(policy.payloadBudget(availableBytes: nil), 1_000_000_000)
        XCTAssertEqual(policy.payloadBudget(availableBytes: 50_000_000_000), 1_000_000_000)
        XCTAssertEqual(policy.payloadBudget(availableBytes: 4_999_999_999), 250_000_000)
    }

    // MARK: FileVault

    func testFileVaultStatusParsing() {
        XCTAssertEqual(FileVaultStatus.parse("FileVault is On.\n"), .on)
        XCTAssertEqual(FileVaultStatus.parse("FileVault is Off.\n"), .off)
        XCTAssertEqual(FileVaultStatus.parse("FileVault is On.\nEncryption in progress: Percent completed = 12.3\n"), .on)
        XCTAssertEqual(FileVaultStatus.parse("Error: something went wrong"), .unknown)
        XCTAssertEqual(FileVaultStatus.parse(""), .unknown)
    }

    // MARK: Stored states

    func testStoredMessageStateMapping() throws {
        XCTAssertEqual(StoredMessageState(.streaming), .interrupted)
        XCTAssertEqual(StoredMessageState.interrupted.runtime, .cancelled)
        XCTAssertEqual(StoredMessageState(.refused("No")).runtime, .refused("No"))

        let decoded = try JSONDecoder().decode(StoredMessageState.self, from: Data(#"{"kind":"somethingNew"}"#.utf8))
        XCTAssertEqual(decoded, .cancelled)
        let failed = try JSONEncoder().encode(StoredMessageState.failed("Timed out"))
        XCTAssertEqual(try JSONDecoder().decode(StoredMessageState.self, from: failed), .failed("Timed out"))
    }
}
