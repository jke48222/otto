//
//  ContinueChip.swift
//  Otto
//
//  "↩ Continue: ‹title›" on an empty chat page: brings back the conversation Otto set aside after an idle
//  fresh start or ⌘N. Clicking it continues; the hover ✕ dismisses it.
//

import SwiftUI

struct ContinueChip: View {
    static let height: CGFloat = 30
    static let cornerRadius: CGFloat = 11
    static let maxTitleWidth: CGFloat = 420
    static let maxTitleLength = 120

    private let title: String
    private let onContinue: () -> Void
    private let onDismiss: () -> Void

    @State private var isHovering = false

    /// `title` is the saved conversation's title (cleaned here before it is drawn).
    init(title: String, onContinue: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.title = title
        self.onContinue = onContinue
        self.onDismiss = onDismiss
    }

    /// The title as drawn.
    static func displayTitle(_ title: String) -> String {
        DisplayText.sanitized(title, maxLength: maxTitleLength)
    }

    static func helpText(title: String) -> String {
        "Continue “\(displayTitle(title))” (⌘Y, ↩)"
    }

    static func accessibilityLabel(title: String) -> String {
        "Continue previous conversation: \(displayTitle(title))"
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onContinue) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 0) {
                        Text("Continue: ")
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize()
                        Text(Self.displayTitle(title))
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.chipLabel)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: Self.maxTitleWidth, alignment: .leading)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, isHovering ? 2 : 11)
                .frame(height: Self.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.97))
            .help(Self.helpText(title: title))
            .accessibilityLabel(Self.accessibilityLabel(title: title))

            if isHovering {
                ChipRemoveButton(label: "Dismiss", action: onDismiss)
                    .padding(.trailing, 6)
                    .transition(.opacity)
            }
        }
        .frame(height: Self.height)
        .clay(cornerRadius: Self.cornerRadius, style: .chip, isHighlighted: isHovering)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Dismiss", onDismiss)
    }
}
