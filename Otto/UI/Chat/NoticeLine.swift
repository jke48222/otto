//
//  NoticeLine.swift
//  Otto
//
//  The neutral line under the composer ("Copied the last reply", "Switched to Sonnet 5"). Same slot and
//  layout as TransientErrorLine, which always wins the slot; VoiceOver hears each notice as it appears.
//

import SwiftUI

struct NoticeLine: View {
    let text: String
    var symbol: String = "checkmark.circle"

    init(text: String, symbol: String = "checkmark.circle") {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(Theme.font(12))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.notice)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .onAppear { announce(text) }
        .onChange(of: text) { _, newText in announce(newText) }
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}
