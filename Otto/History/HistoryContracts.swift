//
//  HistoryContracts.swift
//  Otto
//
//  What ChatSession tells History about the transcript, what History hands back when it restores a
//  conversation, and the retention and idle-reset choices shown in Settings.
//

import Foundation

enum TranscriptChange: Equatable, Sendable { case userMessageAdded, turnFinished, messagesRemoved, willReset, loaded }

struct TranscriptSnapshot: @unchecked Sendable {
    let conversationID: UUID; let createdAt: Date; let messages: [ChatMessage]; let unavailableAttachmentIDs: Set<UUID>
}

struct ReadingPosition: Codable, Equatable, Sendable {
    var anchorMessageID: UUID
    /// Informational (restore is message-granular).
    var fractionScrolledPast: Double
    var isAtBottom: Bool
    /// Transcript tail when saved; a different tail means restore to the bottom.
    var lastMessageID: UUID?
    var savedAt: Date
}

struct LoadedConversation: @unchecked Sendable {
    let id: UUID; let title: String; let createdAt: Date; let updatedAt: Date
    var messages: [ChatMessage]
    var unavailableAttachmentIDs: Set<UUID>
    /// Assistant turns whose server-tool payload is gone.
    var textOnlyContextMessageIDs: Set<UUID>
    var readingPosition: ReadingPosition?
}

enum HistoryRetention: String, CaseIterable, Codable, Identifiable, Sendable {
    case week = "7d", month = "30d", quarter = "90d", forever

    var id: String { rawValue }

    /// "7 days", "30 days", "90 days", "Forever".
    var displayName: String {
        switch self {
        case .week: return "7 days"
        case .month: return "30 days"
        case .quarter: return "90 days"
        case .forever: return "Forever"
        }
    }

    /// For running text: "Kept 30 days" / "Kept forever".
    var shortLabel: String {
        switch self {
        case .week: return "7 days"
        case .month: return "30 days"
        case .quarter: return "90 days"
        case .forever: return "forever"
        }
    }

    /// nil keeps conversations forever.
    var interval: TimeInterval? {
        switch self {
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        case .quarter: return 90 * 86_400
        case .forever: return nil
        }
    }
}

enum IdleResetInterval: String, CaseIterable, Codable, Identifiable, Sendable {
    case fifteenMinutes = "15m", oneHour = "1h", never

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fifteenMinutes: return "After 15 minutes idle"
        case .oneHour: return "After 1 hour idle"
        case .never: return "Never"
        }
    }

    /// nil never starts a fresh chat on its own.
    var interval: TimeInterval? {
        switch self {
        case .fifteenMinutes: return 900
        case .oneHour: return 3_600
        case .never: return nil
        }
    }
}

/// What HistoryController removed from disk (AppComposition clears notifications and, for .all, the activity log).
enum HistoryRemoval: Equatable, Sendable { case conversations(Set<UUID>), all }
