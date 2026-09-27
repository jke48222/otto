//
//  PinIndicator.swift
//  Otto
//
//  The filled pin in the header's right group while the notch is pinned open. Clicking it unpins; the
//  header shows it only while pinned (⌘P and the ⋮ menu pin it).
//

import SwiftUI

struct PinIndicator: View {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    static let size: CGFloat = 22

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "pin.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.orbLight.opacity(isHovering ? 1 : 0.9))
                .frame(width: Self.size, height: Self.size)
                .background {
                    Circle().fill(Color.white.opacity(isHovering ? 0.07 : 0))
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.9))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .help("Unpin (⌘P)")
        .accessibilityLabel("Unpin Otto")
        .accessibilityValue("pinned")
    }
}
