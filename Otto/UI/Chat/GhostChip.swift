//
//  GhostChip.swift
//  Otto
//
//  A dashed "offer" chip in the tray: the browser tab, the selected text or the window the user came from.
//  Click to attach, ✕ to dismiss. The look is the original tab suggestion's: 28 pt, a dashed 1 pt border,
//  a leading "+", 55 % opacity that rises to 80 % on hover.
//

import AppKit
import SwiftUI

struct GhostChip: View {
    enum Icon: Equatable {
        /// The attachment's own glyph (a browser tab shows its browser's icon).
        case attachment(Attachment)
        /// An app's icon, with an optional 8 pt badge symbol at the bottom-trailing corner
        /// ("quote.opening" for a selection).
        case app(AppRef, badgeSymbol: String? = nil)
        case symbol(String)
    }

    let icon: Icon
    let label: String
    /// Tooltip ("Attach the page you're viewing so Otto can read it").
    let help: String
    /// VoiceOver label for the accept action ("Attach current tab: Otto docs").
    let acceptLabel: String
    let onAccept: () -> Void
    let onDismiss: () -> Void

    init(icon: Icon, label: String, help: String, acceptLabel: String,
         onAccept: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.help = help
        self.acceptLabel = acceptLabel
        self.onAccept = onAccept
        self.onDismiss = onDismiss
    }

    static let height: CGFloat = ContextChipsView.chipHeight
    static let restingOpacity: Double = 0.55
    static let hoverOpacity: Double = 0.8
    /// Labels come from outside Otto (page titles, app names, selected text).
    static let maxLabelLength = 120

    /// The label as shown: hidden and bidi characters removed, whitespace collapsed, capped.
    static func displayLabel(_ label: String) -> String {
        DisplayText.sanitized(label, maxLength: maxLabelLength)
    }

    @State private var isHovering = false

    private var shownLabel: String { Self.displayLabel(label) }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onAccept) {
                HStack(spacing: ContextChipsView.iconGap) {
                    Image(systemName: "plus")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                    iconView
                    Text(shownLabel)
                        .font(Theme.font(12.5))
                        .tracking(0.1)
                        .foregroundStyle(Theme.chipLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: ContextChipsView.labelMaxWidth, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.97))
            .accessibilityLabel(acceptLabel)

            ChipRemoveButton(label: "Dismiss suggestion: \(shownLabel)", action: onDismiss)
                .opacity(isHovering ? 1 : 0.7)
                .padding(.leading, -2)
        }
        .padding(.leading, ContextChipsView.chipPadding)
        .padding(.trailing, 4)
        .frame(height: Self.height)
        .background {
            Capsule()
                .fill(Color.white.opacity(isHovering ? 0.05 : 0.02))
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    Theme.textSecondary,
                    style: StrokeStyle(lineWidth: 1, dash: [3.5, 3])
                )
        }
        .opacity(isHovering ? Self.hoverOpacity : Self.restingOpacity)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { isHovering = hovering }
        }
        .help(help)
    }

    @ViewBuilder
    private var iconView: some View {
        let size = ContextChipsView.iconSize
        switch icon {
        case .attachment(let attachment):
            AttachmentIcon(attachment: attachment, size: size)
        case .app(let app, let badgeSymbol):
            AppGlyph(app: app, size: size)
                .overlay(alignment: .bottomTrailing) {
                    if let badgeSymbol {
                        Image(systemName: badgeSymbol)
                            .font(.system(size: 4.5, weight: .bold))
                            .foregroundStyle(Theme.badgeText)
                            .frame(width: 8, height: 8)
                            .background(Circle().fill(Theme.badgeFill))
                            .offset(x: 2, y: 2)
                            .accessibilityHidden(true)
                    }
                }
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.72, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: size, height: size)
        }
    }

    private struct AppGlyph: View {
        let app: AppRef
        let size: CGFloat

        var body: some View {
            if let image = app.icon {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "app")
                    .font(.system(size: size * 0.72, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: size, height: size)
            }
        }
    }
}
