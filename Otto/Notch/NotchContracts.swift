//
//  NotchContracts.swift
//  Otto
//
//  Value types shared by the notch's view model, window controller, key mapper and views: routes,
//  Settings tabs and anchors, dock cards and prompts, holds, close reasons and keyboard commands.
//

import Foundation

enum NotchRoute: String, Hashable, CaseIterable, Sendable {
    case chat, history, shelf

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .history: return "Recents"
        case .shelf: return "Shelf"
        }
    }

    var symbol: String {
        switch self {
        case .chat: return "bubble.left"
        case .history: return "clock.arrow.circlepath"
        case .shelf: return "tray.full"
        }
    }
}

enum NotchOverlay: String, Hashable, Sendable { case shortcutSheet }

enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, notch, models, context, actions, voice, privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .notch: return "Notch"
        case .models: return "Models"
        case .context: return "Context"
        case .actions: return "Actions"
        case .voice: return "Voice"
        case .privacy: return "Privacy"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .notch: return "rectangle.topthird.inset.filled"
        case .models: return "sparkles"
        case .context: return "square.on.square"
        case .actions: return "bolt"
        case .voice: return "waveform"
        case .privacy: return "lock.shield"
        }
    }
}

/// A section a deep link scrolls to (ScrollViewReader id) after selecting its tab.
enum SettingsAnchor: String, Hashable, Sendable {
    /// Models → Usage (⌥⌘U, "Usage Details…").
    case usage
    /// Privacy → Permissions (permission cards' "Open Settings").
    case permissions
    /// Actions → Approvals ("Stop allowing", disabled-tool recovery).
    case approvals

    var tab: SettingsTab {
        switch self {
        case .usage: return .models
        case .permissions: return .privacy
        case .approvals: return .actions
        }
    }
}

/// One-time and consent cards shown in the dock (not tool approvals, not permission flows).
struct NotchCard: Identifiable, Equatable, Sendable {
    enum Kind: Hashable, Sendable {
        case voiceConsent(pendingMode: VoiceMode)
        case voiceUnavailable(VoiceUnavailableReason)
        case onDeviceSpeechUnavailable(localeName: String, pendingMode: VoiceMode)
        case notchNeighbor(name: String)
        case historyNotice
    }

    enum Action: Equatable, Sendable {
        case enableVoice(VoiceMode), useServerSpeech(VoiceMode), openSystemSettings(Permission),
             openSettings(SettingsTab), useClickToOpen, keepHover(neighbor: String),
             acknowledgeHistory, declineHistory, dismiss
        /// x-apple.systempreferences:com.apple.Keyboard-Settings.extension (Dictation lives there).
        case openDictationSettings
    }

    struct ActionButton: Equatable, Sendable { var title: String; var action: Action }

    let kind: Kind
    var id: Kind { kind }
    var symbol: String; var title: String; var message: String; var footnote: String?
    var primary: ActionButton; var secondary: ActionButton?
    /// Esc: always the safe choice. Voice cards `.dismiss`, neighbor `.keepHover(name)`, history notice
    /// `.acknowledgeHistory` (never "Don't Save History").
    var escapeAction: Action
    /// Needs an answer: the notch stays open while it shows (voice cards true; neighbor and history notice false).
    var requiresDecision: Bool
}

/// The dock shows at most one prompt; priority approval > permission > card.
enum NotchPrompt: Identifiable, Equatable, Sendable {
    case approval(PendingApproval)
    case permission(PermissionPrompt)
    case card(NotchCard)

    /// "approval:<callID>" | "permission:<uuid>" | "card:<kind>".
    var id: String {
        switch self {
        case .approval(let approval): return "approval:\(approval.callID)"
        case .permission(let prompt): return "permission:\(prompt.id.uuidString)"
        case .card(let card): return "card:\(card.kind)"
        }
    }

    var isApproval: Bool {
        if case .approval = self { return true }
        return false
    }
}

/// Hover-exit must not close the notch while any of these is active.
enum StayOpenHold: Hashable, Sendable {
    case voiceSession, voiceReplyHold, shelfDragOut, shelfLanding, insertInProgress, promptDecision
}

/// Outside clicks must not close it either (a sheet or preview that belongs to Otto and sits above the notch).
/// System dialogs and System Settings are NOT holds: the notch folds out of their way.
enum ModalHold: Hashable, Sendable {
    case sharing, quickLook
}

enum CloseReason: Equatable, Sendable {
    case pointerExit, outsideClick, user, programmatic
    /// The notch folded for system UI: keeps the permission prompt, route, tall mode and pin; may reopen
    /// itself (unfocused) when the wait ends.
    case systemUI

    /// Esc, ⌘W, the hotkey tap → stop speaking too; exits keep a reply being read aloud.
    var isUserInitiated: Bool { self == .user }
}

/// One-shot scroll request consumed by ConversationView.
struct ReadingAnchor: Equatable, Sendable {
    let messageID: UUID
    let serial: Int

    /// "anchor-<uuid>".
    static func markerID(_ messageID: UUID) -> String { "anchor-\(messageID.uuidString)" }
}

enum TranscriptRestoreTarget: Equatable, Sendable { case bottom, messageTop(UUID) }

/// Keyboard commands (mapped by NotchKeyCommands, dispatched by NotchViewModel.perform).
enum NotchKeyCommand: Equatable, Sendable {
    case close, newChat, openSettings, pasteAsAttachment
    case stop, regenerate, recallLastMessage, cancelEditing, copyLastReply
    case toggleShortcutSheet, dismissOverlay
    case selectModel(ModelOption)
    case togglePin, enterTallMode, exitTallMode
    case cancelVoice, finishVoice, stopSpeaking
    case promptPrimary, promptSecondary
    /// A consequential chord arrived while the panel was only soft-focused: hand the keyboard back, do nothing else.
    case releaseSoftFocus
    case insertLastAnswer(InsertMode?), confirmInsert, cancelInsertConfirmation
    case toggleHistory, toggleShelf, backToChat
    case historyMoveSelection(Int), historyOpenSelected, historyDeleteSelected, historyUndoDelete, historyFocusSearch
    case shelfAskAboutSelection, shelfPaste
    case media(MediaCommand), joinMeeting, showUsage
}

/// Snapshot the window controller builds (via NotchViewModel.keyContext) for every key event.
struct NotchKeyContext: Equatable, Sendable {
    enum PromptKind: Equatable, Sendable { case none, approval, other }

    var route: NotchRoute = .chat
    /// false while the panel is key only through soft focus. Consequential chords then map to .releaseSoftFocus.
    var isEngaged = true
    var hasMarkedText = false
    var composerIsFirstResponder = false
    /// Trimmed text empty AND no attachments.
    var composerIsEmpty = true
    /// Trimmed text non-empty (text selection chords).
    var composerHasText = false
    /// The visible prompt's primary must not run from a bare Return (PermissionCardContent.primaryRequiresCommand).
    var promptPrimaryRequiresCommand = false
    var clipboardWantsAttachmentPaste = false
    var hasUserMessage = false
    var isStreaming = false
    var isEditing = false
    var overlay: NotchOverlay? = nil
    /// The *visible* dock prompt: always .none unless route == .chat (prompts are only rendered on Chat).
    var prompt: PromptKind = .none
    /// Likewise only on .chat.
    var hasInsertConfirmation = false
    var canInsertLastAnswer = false
    var historySearchIsEmpty = true
    var hasPendingHistoryDeletion = false
    var isListening = false
    var isSpeaking = false
    var hasNowPlaying = false
    var hasMeetingChip = false
    var isHistoryAvailable = true
    var isShelfEnabled = true
}
