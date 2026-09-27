//
//  GlanceContracts.swift
//  Otto
//
//  What the closed notch can say about a reply: its phase (derived from the streaming message), the
//  notification policy, and the brief flash after Otto pastes an answer.
//

import Foundation

enum ReplyPhase: Equatable, Sendable {
    case idle, connecting, thinking
    case searching(label: String)
    case writing
    case runningAction(label: String)
    case awaitingApproval(label: String)

    var isActive: Bool { self != .idle }

    /// .awaitingApproval and .idle bypass the debouncer.
    var isUrgent: Bool {
        switch self {
        case .idle, .awaitingApproval: return true
        case .connecting, .thinking, .searching, .writing, .runningAction: return false
        }
    }

    /// Pure. Rules, first match: nil or state != .streaming → .idle; a toolCall .awaitingApproval /
    /// .needsPermission / .waitingForSystem → .awaitingApproval(label: that call's presentation.title);
    /// a toolCall .running → .runningAction(label: activeTitle); a ToolActivity !isDone → .searching(label);
    /// isThinking → .thinking; a toolCall .preparing → .writing; !text.isEmpty → .writing;
    /// model == nil → .connecting; else .thinking.
    static func derive(from message: ChatMessage?) -> ReplyPhase {
        guard let message, message.state == .streaming else { return .idle }

        let waiting = message.toolCalls.first { call in
            switch call.status {
            case .awaitingApproval, .needsPermission, .waitingForSystem: return true
            default: return false
            }
        }
        if let waiting { return .awaitingApproval(label: waiting.presentation.title) }

        if let running = message.toolCalls.first(where: { $0.status == .running }) {
            return .runningAction(label: running.presentation.activeTitle)
        }
        if let activity = message.activities.first(where: { !$0.isDone }) {
            return .searching(label: activity.label)
        }
        if message.isThinking { return .thinking }
        if message.toolCalls.contains(where: { $0.status == .preparing }) { return .writing }
        if !message.text.isEmpty { return .writing }
        if message.model == nil { return .connecting }
        return .thinking
    }
}

enum ReplyNotificationPolicy: String, CaseIterable, Codable, Identifiable, Sendable {
    case off, whenOutOfSight, always

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Never"
        case .whenOutOfSight: return "When Otto's out of sight"
        case .always: return "Whenever the notch is closed"
        }
    }
}

/// A brief ✓ in the closed notch after Otto pasted an answer (set by InsertCoordinator).
enum ClosedFlash: Equatable, Sendable { case pasted(appName: String) }
