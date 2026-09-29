//
//  NotchCardView.swift
//  Otto
//
//  One-time cards in the dock (voice consent, speech that can't run on this Mac, another notch app, the
//  history notice), drawn in the same chrome as approvals. Each button reports its action; Esc performs the
//  card's safe `escapeAction`, and the button that matches it carries the "esc" hint.
//

import SwiftUI

struct NotchCardView: View {
    let card: NotchCard
    let onAction: (NotchCard.Action) -> Void

    init(card: NotchCard, onAction: @escaping (NotchCard.Action) -> Void) {
        self.card = card
        self.onAction = onAction
    }

    /// Key hints: the primary answers Return; the secondary shows "esc" when Esc performs it.
    static func hints(for card: NotchCard) -> (primary: String?, secondary: String?) {
        ("↩", card.secondary?.action == card.escapeAction ? "esc" : nil)
    }

    var body: some View {
        let hints = Self.hints(for: card)
        VStack(alignment: .leading, spacing: DockCardChrome.spacing) {
            DockCardChrome.Header(symbol: card.symbol, title: card.title)
            if !card.message.isEmpty {
                Text(card.message)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let footnote = card.footnote, !footnote.isEmpty {
                Text(footnote)
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.textTertiaryOnClay)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 8)
                if let secondary = card.secondary {
                    DockCardChrome.SecondaryButton(title: secondary.title, hint: hints.secondary) {
                        onAction(secondary.action)
                    }
                }
                DockCardChrome.PrimaryButton(title: card.primary.title, hint: hints.primary) {
                    onAction(card.primary.action)
                }
                .accessibilityLabel(card.primary.title)
            }
            .frame(height: DockCardChrome.footerHeight)
        }
        .dockCardChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.title)
        .onAppear { DockCardChrome.announce(card.title) }
    }
}
