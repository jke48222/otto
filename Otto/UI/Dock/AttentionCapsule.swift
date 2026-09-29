//
//  AttentionCapsule.swift
//  Otto
//
//  The small capsule under the header while a dock prompt waits and another page (Recents, Shelf) is up:
//  "Otto needs your OK · View". Clicking it goes back to Chat, where the dock shows the prompt.
//

import SwiftUI

struct AttentionCapsule: View {
    let prompt: NotchPrompt
    let onView: () -> Void

    init(prompt: NotchPrompt, onView: @escaping () -> Void) {
        self.prompt = prompt
        self.onView = onView
    }

    @State private var isHovering = false
    @State private var isBright = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let actionTitle = "View"

    /// "Otto needs your OK" for approvals, otherwise a question is waiting.
    static func text(for prompt: NotchPrompt) -> String {
        switch prompt {
        case .approval: return "Otto needs your OK"
        case .permission: return "Otto needs a permission"
        case .card: return "Otto has a question"
        }
    }

    var body: some View {
        Button(action: onView) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Theme.attention)
                    .frame(width: 6, height: 6)
                    .opacity(reduceMotion ? 1 : (isBright ? 1 : 0.55))
                    .accessibilityHidden(true)
                Text(Self.text(for: prompt))
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("·")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.textTertiaryOnClay)
                    .accessibilityHidden(true)
                Text(Self.actionTitle)
                    .font(Theme.font(12, .semibold))
                    .foregroundStyle(isHovering ? Theme.orbLight : Theme.link)
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .clay(in: Capsule(style: .continuous), style: .pebble, isHighlighted: isHovering)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.96))
        .fixedSize()
        .onHover { isHovering = $0 }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { isBright = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.text(for: prompt)). \(Self.actionTitle)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onView() }
    }
}
