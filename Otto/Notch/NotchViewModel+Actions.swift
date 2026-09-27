//
//  NotchViewModel+Actions.swift
//  Otto
//
//  The controls on action rows (§6.1): Undo, Stop, Stop allowing and the Settings recovery link; and the one-time
//  card for another notch app that also opens on hover (§6.5), whose copy names the live shortcut.
//

import Foundation

extension NotchViewModel {
    // MARK: - Action rows (§6.1, §5.8)

    /// [Undo] on a created event or reminder. The row turns into "Removed …"; a failure says why.
    func undoToolCall(_ callID: String, in messageID: UUID) {
        Task { [weak self] in
            guard let self, let reason = await self.chat.undoToolCall(callID, in: messageID) else { return }
            self.transientError = "Couldn't undo: \(reason)."
        }
    }

    /// [Stop] on a running action.
    func stopToolCall(_ callID: String) {
        chat.stopToolCall(callID)
    }

    /// [Stop allowing] on an always-allowed shortcut: the next run asks again.
    func stopAllowing(_ scope: ApprovalScope) {
        guard let remembered = approvals.remembered.first(where: { $0.scope == scope }) else { return }
        approvals.revoke(remembered.id)
        let label = DisplayText.sanitized(scope.label, maxLength: Self.scopeLabelLength)
        showNotice("Otto will ask before running \(label) again.", symbol: "hand.raised")
    }

    private static let scopeLabelLength = 80

    /// [Open Settings] on a row whose action group is off.
    func openActionsSettings() {
        openSettings(tab: .actions, anchor: .approvals)
    }

    // MARK: - Coexistence (§6.5)

    /// Queues the card for the first running notch app the user hasn't answered about, while hover-to-open is on.
    /// One card at a time; it shows on the next open.
    func presentNeighborCardIfNeeded(_ running: [NotchNeighbor]) {
        guard settings.notch.hoverToOpen else { return }
        let alreadyQueued = cardQueue.contains { queued in
            if case .notchNeighbor = queued.card.kind { return true }
            return false
        }
        guard !alreadyQueued else { return }
        let acknowledged = settings.notch.acknowledgedNeighbors
        guard let neighbor = running.first(where: { !acknowledged.contains($0.name) }) else { return }
        present(card: Self.neighborCard(name: neighbor.name, settings: settings))
    }

    /// Copy built from the live shortcut (or the click-only wording when the shortcut is off).
    static func neighborCard(name: String, settings: AppSettings) -> NotchCard {
        let howToOpen = settings.hotKeyEnabled
            ? "Otto can open only when you click the notch or press \(settings.shortcuts.hotKey.displayString)."
            : "Otto can open only when you click the notch."
        return NotchCard(
            kind: .notchNeighbor(name: name),
            symbol: "rectangle.2.swap",
            title: "\(name) is also in your notch",
            message: "When you hover, both apps can open at once. " + howToOpen,
            footnote: "You can change this anytime in Settings → Notch.",
            primary: NotchCard.ActionButton(title: "Open on Click", action: .useClickToOpen),
            secondary: NotchCard.ActionButton(title: "Keep Hover", action: .keepHover(neighbor: name)),
            escapeAction: .keepHover(neighbor: name),
            requiresDecision: false
        )
    }
}
