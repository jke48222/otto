//
//  NotchViewModel+History.swift
//  Otto
//
//  History and continuity in the notch (§6.12): the Recents page (⌘Y), opening and deleting conversations from
//  it, the Continue chip after a fresh start, and the first-run history notice.
//

import Foundation

extension NotchViewModel {
    // MARK: - Recents

    /// ⌘Y: opens Recents (focused when the notch was closed); on Recents it goes back to Chat.
    func toggleHistory() {
        toggle(route: .history)
    }

    /// Loads the conversation into the chat and lands where the user left off.
    func openConversation(id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            let opened = await self.history.open(id)
            self.didSwitchConversation(opened: opened)
        }
    }

    /// Return on Recents.
    func openSelectedRecent() {
        guard let row = recents.selectedRow else { return }
        openConversation(id: row.id)
    }

    /// ⌫ / ⌘⌫ on Recents: the row goes now and is deleted after the Undo window.
    func deleteSelectedRecent() {
        guard let row = recents.selectedRow else { return }
        history.delete(row.id)
    }

    /// ⌘Z on Recents while a deletion can still be undone.
    func undoRecentDeletion() {
        history.undoDelete()
    }

    // MARK: - Continuity

    /// The Continue chip: brings back the conversation that a fresh start (idle time or ⌘N) set aside.
    func continuePreviousConversation() {
        Task { [weak self] in
            guard let self else { return }
            let opened = await self.history.continueConversation()
            self.didSwitchConversation(opened: opened)
        }
    }

    func dismissContinuation() {
        history.dismissContinuation()
    }

    // MARK: - First-run notice

    /// "Got It" (the dock card or the note on Recents).
    func acknowledgeHistoryNotice() {
        settings.history.noticeAcknowledged = true
        removeCard(kind: .historyNotice)?.resume(returning: .acknowledgeHistory)
    }

    /// "Don't Save History": History turns off and nothing is saved.
    func declineHistory() {
        settings.history.noticeAcknowledged = true
        removeCard(kind: .historyNotice)?.resume(returning: .declineHistory)
        let history = self.history
        Task { await history.setEnabled(false) }
        transientError = Self.historyOffMessage
    }

    static let historyOffMessage = "History is off. Nothing is saved."

    // MARK: - Private

    /// After a conversation was opened or continued: Chat, the reading position, focus. An edit in progress
    /// belonged to the conversation that was left.
    private func didSwitchConversation(opened: Bool) {
        guard opened else {
            if let message = history.lastOpenError {
                transientError = message
            }
            return
        }
        if isEditing {
            cancelEditing()
        }
        if isOpen {
            navigate(to: .chat)
        } else {
            open(reason: .programmatic, focus: true)
        }
        applyReadingRestore(saved: history.takeReadingPositionToRestore())
        requestFocus()
    }
}
