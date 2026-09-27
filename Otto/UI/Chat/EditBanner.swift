//
//  EditBanner.swift
//  Otto
//
//  The line above the chips while the last message is being edited (↑ in an empty composer): sending
//  replaces that turn, Esc puts everything back.
//

import SwiftUI

struct EditBanner: View {
    /// Esc through the key map; VoiceOver gets it as an action.
    let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    static let height: CGFloat = 28
    static let text = "Editing your last message · Esc to cancel"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .semibold))
            Text(Self.text)
                .font(Theme.font(12))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Editing your last message")
        .accessibilityHint("Press Escape to cancel")
        .accessibilityAction(named: "Cancel editing", onCancel)
    }
}
