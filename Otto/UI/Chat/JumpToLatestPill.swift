//
//  JumpToLatestPill.swift
//  Otto
//
//  "Latest ↓": a small clay pill at the bottom of the transcript while the reader is scrolled up and newer
//  content sits below the fold. Clicking it scrolls to the bottom and follows the reply again.
//

import SwiftUI

struct JumpToLatestPill: View {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    static let height: CGFloat = 24
    static let title = "Latest"
    static let transition: AnyTransition = .opacity.combined(with: .offset(y: 6))

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(Self.title)
                    .font(Theme.font(12, .medium))
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(isHovering ? Theme.textPrimary : Theme.chipLabel)
            .padding(.horizontal, 10)
            .frame(height: Self.height)
            .clay(in: Capsule(), style: .chip, isHighlighted: isHovering)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { isHovering = hovering }
        }
        .help("Jump to the latest message")
        .accessibilityLabel("Jump to the latest message")
    }
}
