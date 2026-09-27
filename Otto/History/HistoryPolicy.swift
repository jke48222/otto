//
//  HistoryPolicy.swift
//  Otto
//
//  The pure rules behind local history: when an idle notch opens onto a fresh chat, which conversations
//  retention removes, and which attachment payloads stay on disk so a continued chat can send them again.
//

import Foundation

struct HistoryPolicy: Sendable, Equatable {
    /// Payloads of conversations updated within this window stay re-sendable.
    var payloadWindow: TimeInterval = 30 * 86_400
    var payloadBudgetBytes: Int64 = 1_000_000_000
    /// Budget used instead when the volume is short on space.
    var lowDiskPayloadBudgetBytes: Int64 = 250_000_000
    /// Free space below which the low-disk budget applies.
    var lowDiskThresholdBytes: Int64 = 5_000_000_000
    /// `source.data` strings at least this long (UTF-8 bytes) move into content-addressed blobs.
    var externalizeThresholdBytes = 16 * 1024
    /// Conversation files larger than this are never loaded (memory bomb guard).
    var maxConversationFileBytes = 256 * 1024 * 1024
    var maxThumbnailBytes = 32 * 1024
    /// Cap on a summary's `searchText` (UTF-8 bytes).
    var searchTextLimit = 16 * 1024
    var undoWindow: Duration = .seconds(5)
    var maintenanceInterval: Duration = .seconds(6 * 3600)

    static let standard = HistoryPolicy()

    struct IdleContext: Equatable, Sendable {
        var now: Date
        var lastActivity: Date?
        var interval: IdleResetInterval
        var hasMessages: Bool
        var isStreaming: Bool
        var hasUnreadReply: Bool
        /// Composer text that isn't blank, any attachment chip, or an attachment still loading.
        var hasDraft: Bool
    }

    /// True when the notch should open onto a fresh conversation. A clock set back (negative idle time) is
    /// never idle.
    static func shouldStartFresh(_ context: IdleContext) -> Bool {
        guard context.hasMessages, !context.isStreaming, !context.hasUnreadReply, !context.hasDraft,
              let interval = context.interval.interval, let lastActivity = context.lastActivity else { return false }
        return context.now.timeIntervalSince(lastActivity) >= interval
    }

    /// Conversations whose `updatedAt` is before the cutoff are deleted; nil keeps everything.
    static func retentionCutoff(_ retention: HistoryRetention, now: Date) -> Date? {
        retention.interval.map { now.addingTimeInterval(-$0) }
    }

    struct BlobUsage: Equatable, Sendable {
        var sha256: String
        var bytes: Int64
        /// `updatedAt` of the newest conversation that references the blob.
        var lastUsed: Date
    }

    /// The payload budget for a volume with `availableBytes` free (nil when unknown).
    func payloadBudget(availableBytes: Int64?) -> Int64 {
        guard let availableBytes, availableBytes < lowDiskThresholdBytes else { return payloadBudgetBytes }
        return lowDiskPayloadBudgetBytes
    }

    /// Which blobs survive garbage collection. `protected` blobs are always kept and count toward the budget
    /// first; the rest are kept newest first while they were used within `window` and the running total stays
    /// within `budget` (the first blob that doesn't fit ends the run, so an older blob never outlives a newer one).
    static func blobsToKeep(_ usage: [BlobUsage], protected: Set<String>, now: Date,
                            window: TimeInterval, budget: Int64) -> Set<String> {
        var merged: [String: BlobUsage] = [:]
        for entry in usage {
            if let existing = merged[entry.sha256] {
                merged[entry.sha256] = BlobUsage(sha256: entry.sha256, bytes: max(existing.bytes, entry.bytes),
                                                 lastUsed: max(existing.lastUsed, entry.lastUsed))
            } else {
                merged[entry.sha256] = entry
            }
        }

        var kept = protected
        var total: Int64 = protected.reduce(0) { $0 + (merged[$1]?.bytes ?? 0) }
        let candidates = merged.values
            .filter { !protected.contains($0.sha256) && now.timeIntervalSince($0.lastUsed) <= window }
            .sorted { lhs, rhs in
                lhs.lastUsed != rhs.lastUsed ? lhs.lastUsed > rhs.lastUsed : lhs.sha256 < rhs.sha256
            }
        for candidate in candidates {
            guard total + candidate.bytes <= budget else { break }
            total += candidate.bytes
            kept.insert(candidate.sha256)
        }
        return kept
    }
}
