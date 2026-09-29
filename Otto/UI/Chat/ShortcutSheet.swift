//
//  ShortcutSheet.swift
//  Otto
//
//  What the ⌘/ sheet lists: every row of the notch's key map (SPEC-v2 §4.4) that applies to the current
//  settings and pages, grouped as Conversation · Notch · Actions · Glance. Pure data, so the rows can be
//  tested without drawing anything; ShortcutSheetView renders them.
//

import Foundation

enum ShortcutSheet {
    struct Row: Identifiable, Equatable, Sendable {
        /// Stable identifier ("conversation.send"), for tests and SwiftUI identity.
        let id: String
        let title: String
        /// Alternative chords, each a list of key caps; shown with "/" between them.
        let chords: [[String]]
        /// Shown as "Hold" before the caps (hold-to-talk on the global shortcut).
        var isHold = false
    }

    struct Section: Identifiable, Equatable, Sendable {
        enum Kind: String, CaseIterable, Sendable { case conversation, notch, actions, glance }

        let kind: Kind
        var id: Kind { kind }
        let title: String
        let rows: [Row]
        /// One line of explanation under the sheet's columns (the soft-focus note belongs to Notch).
        var note: String?
    }

    static let title = "Keyboard shortcuts"
    static let dismissHint = "Press ⌘/ or Esc to close"
    /// Shown while "Type after hovering" is on: soft focus accepts typing, but not the chords that send,
    /// spend tokens, approve, paste or discard (§4.4, §6.2).
    static let softFocusNote = "When you only hover over Otto, typing works right away. ⌘↩, ⌘R and ⌘N wait for a click or your first keystroke."

    /// The sections in display order. Rows that can't apply right now are left out: voice rows without Voice,
    /// hold-to-talk without the global shortcut, Recents and Shelf rows when those pages aren't available,
    /// approval rows while Actions are off, and media and meeting rows while their glances are off.
    @MainActor
    static func sections(settings: AppSettings, availableRoutes: [NotchRoute]) -> [Section] {
        let hasRecents = availableRoutes.contains(.history)
        let hasShelf = availableRoutes.contains(.shelf)
        return [
            conversation(settings: settings),
            notch(settings: settings, hasRecents: hasRecents, hasShelf: hasShelf),
            actions(settings: settings, hasShelf: hasShelf),
            glance(settings: settings),
        ]
    }

    /// The two columns of the sheet: Conversation and Actions on the left, Notch and Glance on the right.
    static func columns(_ sections: [Section]) -> (leading: [Section], trailing: [Section]) {
        var leading: [Section] = []
        var trailing: [Section] = []
        for (index, section) in sections.enumerated() {
            if index.isMultiple(of: 2) { leading.append(section) } else { trailing.append(section) }
        }
        return (leading, trailing)
    }

    // MARK: - Sections

    @MainActor
    private static func conversation(settings: AppSettings) -> Section {
        var rows: [Row] = [
            Row(id: "conversation.send", title: "Send", chords: [["↩"]]),
            Row(id: "conversation.newLine", title: "New line", chords: [["⇧", "↩"], ["⌥", "↩"]]),
            Row(id: "conversation.stop", title: "Stop the reply", chords: [["⌘", "."]]),
        ]
        if speaksReplies(settings) {
            rows.append(Row(id: "conversation.stopSpeaking", title: "Stop speaking", chords: [["⌘", "."], ["Esc"]]))
        }
        rows += [
            Row(id: "conversation.regenerate", title: "Regenerate", chords: [["⌘", "R"]]),
            Row(id: "conversation.editLast", title: "Edit your last message", chords: [["↑"]]),
            Row(id: "conversation.cancelEditing", title: "Cancel editing", chords: [["Esc"]]),
            Row(id: "conversation.copyLast", title: "Copy the last reply", chords: [["⌘", "⇧", "C"]]),
            Row(id: "conversation.newChat", title: "New chat", chords: [["⌘", "N"]]),
            Row(id: "conversation.pasteAttachment", title: "Paste a file or image", chords: [["⌘", "V"]]),
        ]
        if settings.voice.enabled {
            rows += [
                Row(id: "conversation.finishVoice", title: "Send what you said", chords: [["↩"]]),
                Row(id: "conversation.cancelVoice", title: "Discard what you said", chords: [["Esc"]]),
            ]
        }
        return Section(kind: .conversation, title: "Conversation", rows: rows)
    }

    @MainActor
    private static func notch(settings: AppSettings, hasRecents: Bool, hasShelf: Bool) -> Section {
        var rows: [Row] = []
        let combo = settings.shortcuts.hotKey.displayKeyCaps
        if settings.hotKeyEnabled {
            rows.append(Row(id: "notch.toggle", title: "Open or close Otto", chords: [combo]))
            if settings.voice.enabled && settings.voice.holdShortcutToTalk {
                rows.append(Row(id: "notch.holdToTalk", title: "Talk to Otto", chords: [combo], isHold: true))
            }
        }
        rows += [
            Row(id: "notch.close", title: "Close", chords: [["Esc"], ["⌘", "W"]]),
            Row(id: "notch.pin", title: "Pin open", chords: [["⌘", "P"]]),
            Row(id: "notch.tallMode", title: "Tall reading mode", chords: [["⌘", "⇧", "↑"]]),
            Row(id: "notch.normalHeight", title: "Normal height", chords: [["⌘", "⇧", "↓"]]),
            Row(id: "notch.switchModel", title: "Switch model", chords: [["⌘", "1–3"]]),
        ]
        if hasRecents {
            rows += [
                Row(id: "notch.recents", title: "Recents", chords: [["⌘", "Y"]]),
                Row(id: "notch.recentsSearch", title: "Search Recents", chords: [["⌘", "F"]]),
                Row(id: "notch.recentsDelete", title: "Delete a conversation", chords: [["⌘", "⌫"]]),
                Row(id: "notch.recentsUndo", title: "Undo the delete", chords: [["⌘", "Z"]]),
            ]
        }
        if hasShelf {
            rows.append(Row(id: "notch.shelf", title: "Shelf", chords: [["⌘", "D"]]))
        }
        if hasRecents || hasShelf {
            rows.append(Row(id: "notch.backToChat", title: "Back to Chat", chords: [["Esc"]]))
        }
        rows += [
            Row(id: "notch.settings", title: "Settings", chords: [["⌘", ","]]),
            Row(id: "notch.shortcuts", title: "Shortcuts", chords: [["⌘", "/"]]),
        ]
        return Section(
            kind: .notch,
            title: "Notch",
            rows: rows,
            note: settings.notch.typeAfterHover ? softFocusNote : nil
        )
    }

    @MainActor
    private static func actions(settings: AppSettings, hasShelf: Bool) -> Section {
        var rows: [Row] = [
            Row(id: "actions.insert", title: "Paste into your app", chords: [["⌘", "↩"]]),
            Row(id: "actions.insertPlain", title: "Paste as plain text", chords: [["⌥", "⌘", "↩"]]),
            Row(id: "actions.confirmInsert", title: "Confirm a paste", chords: [["↩"]]),
            Row(id: "actions.cardPrimary", title: "Choose a card's main button", chords: [["↩"]]),
            Row(id: "actions.cardDismiss", title: "Dismiss a card", chords: [["Esc"]]),
        ]
        if settings.actions.enabled {
            rows += [
                Row(id: "actions.approve", title: "Run an action you've checked", chords: [["⌘", "↩"]]),
                Row(id: "actions.decline", title: "Don't run it", chords: [["Esc"]]),
            ]
        }
        if hasShelf {
            rows += [
                Row(id: "actions.shelfAsk", title: "Ask about Shelf files", chords: [["⌘", "↩"]]),
                Row(id: "actions.shelfPaste", title: "Paste onto the Shelf", chords: [["⌘", "V"]]),
            ]
        }
        return Section(kind: .actions, title: "Actions", rows: rows)
    }

    @MainActor
    private static func glance(settings: AppSettings) -> Section {
        var rows: [Row] = []
        if settings.glance.nowPlayingEnabled {
            rows += [
                Row(id: "glance.playPause", title: "Play or pause", chords: [["⌥", "⌘", "P"]]),
                Row(id: "glance.nextTrack", title: "Next track", chords: [["⌥", "⌘", "]"]]),
                Row(id: "glance.previousTrack", title: "Previous track", chords: [["⌥", "⌘", "["]]),
            ]
        }
        if settings.glance.calendarChipEnabled {
            rows.append(Row(id: "glance.joinMeeting", title: "Join the next meeting", chords: [["⌥", "⌘", "J"]]))
        }
        rows.append(Row(id: "glance.usage", title: "Usage details", chords: [["⌥", "⌘", "U"]]))
        return Section(kind: .glance, title: "Glance", rows: rows)
    }

    /// Replies are read aloud always, or after a spoken question while Voice is on.
    @MainActor
    private static func speaksReplies(_ settings: AppSettings) -> Bool {
        switch settings.voice.spokenReplies {
        case .off: return false
        case .afterVoice: return settings.voice.enabled
        case .always: return true
        }
    }
}
