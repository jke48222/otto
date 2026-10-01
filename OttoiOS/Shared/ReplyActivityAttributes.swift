//
//  ReplyActivityAttributes.swift
//  Otto
//
//  The Live Activity of one reply, Otto's notch on iPhone: while Otto works in the background the Dynamic
//  Island shows what it is doing, and when the reply lands, its first line. The app starts and updates it
//  (ReplyActivityController); the widget extension draws it. The copy and glyphs live here so both agree.
//

import ActivityKit
import Foundation

struct ReplyActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Stage: String, Codable, Hashable, Sendable {
            case connecting, thinking, searching, writing, acting, waitingForApproval
            case replied, failed, paused
        }

        var stage: Stage
        /// What Otto is doing ("Searching “tide times”", "Add “Dentist” to Calendar"), or once it finished, the
        /// reply's first line. Empty when there is nothing to add, or previews are off.
        var detail: String
        /// The answering model's short name ("Opus 5").
        var model: String
        /// When the reply started; the elapsed time counts from here.
        var startedAt: Date
        /// When it finished, failed or paused.
        var finishedAt: Date?

        var isFinished: Bool { finishedAt != nil }

        /// The activity's headline.
        var title: String {
            switch stage {
            case .connecting: return "Connecting…"
            case .thinking: return "Thinking…"
            case .searching: return "Searching the web…"
            case .writing: return "Writing…"
            case .acting: return "Working on it…"
            case .waitingForApproval: return "Needs your OK"
            case .replied: return "Otto replied"
            case .failed: return "Otto couldn't finish"
            case .paused: return "Paused"
            }
        }

        /// SF Symbol for the stage (the compact trailing glyph).
        var symbol: String {
            switch stage {
            case .connecting, .thinking: return "sparkle"
            case .searching: return "magnifyingglass"
            case .writing: return "text.cursor"
            case .acting: return "bolt.fill"
            case .waitingForApproval: return "hand.raised.fill"
            case .replied: return "checkmark"
            case .failed: return "exclamationmark.triangle.fill"
            case .paused: return "pause.fill"
            }
        }

        /// Whether the orb breathes (Otto is still working).
        var isWorking: Bool { !isFinished && stage != .waitingForApproval }
    }

    /// The assistant message the activity follows; tapping the activity opens that reply.
    let messageID: UUID
}
