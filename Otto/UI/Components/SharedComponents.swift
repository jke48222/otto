//
//  SharedComponents.swift
//  Otto
//
//  Small views used across the notch: the reply footer buttons and status line, the chip remove
//  button, the transient error line and the drop target overlay.
//

import SwiftUI

struct StatusLine: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(Theme.font(13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .foregroundStyle(color)
    }
}

struct FooterButton: View {
    let title: String
    let symbol: String
    var isProminent: Bool = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(Theme.font(11.5, .medium))
            }
            .foregroundStyle(isProminent || isHovering ? Theme.textPrimary : Theme.textTertiary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.08 : (isProminent ? 0.05 : 0)))
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
    }
}

struct ChipRemoveButton: View {
    /// VoiceOver label naming what the ✕ affects, e.g. "Remove cat-meme.txt".
    let label: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(isHovering ? 0.9 : 0.7))
                .frame(width: 16, height: 16)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.85))
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

struct TransientErrorLine: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(message)
                .font(Theme.font(12))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.error)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }
}

struct DropTargetOverlay: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        shape
            .fill(Theme.panel.opacity(0.88))
            .overlay {
                shape.strokeBorder(
                    Theme.sendFill.opacity(0.75),
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                )
            }
            .overlay {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 14, weight: .medium))
                    Text("Drop to attach")
                        .font(Theme.font(14, .medium))
                }
                .foregroundStyle(Theme.sendFill)
            }
            .allowsHitTesting(false)
            .accessibilityLabel("Drop to attach")
    }
}
