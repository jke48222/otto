//
//  SharedComponents.swift
//  Otto
//
//  Small views used across the notch: the reply footer buttons and status line, the chip remove
//  button, the transient error line, the drop target overlay and the pages' shared empty state.
//

import AppKit
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
    /// VoiceOver label naming what the ✕ affects, e.g. "Remove meeting-notes.txt".
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

/// The empty state every notch page shares (Recents, Shelf): a 20 pt tertiary glyph, a 14 pt medium title and
/// a 12.5 pt secondary body, centred with 6 pt between them in an area `height` tall. `accessory` goes under
/// the body (an action button), 4 pt further down.
struct PageEmptyState<Accessory: View>: View {
    let symbol: String
    let title: String
    let message: String
    var height: CGFloat = PageEmptyState.defaultHeight
    @ViewBuilder var accessory: () -> Accessory

    static var defaultHeight: CGFloat { 132 }
    static var messageMaxWidth: CGFloat { 360 }

    var body: some View {
        VStack(spacing: 6) {
            glyph
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.font(14, .medium))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(message)
                .font(Theme.font(12.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.messageMaxWidth)
            if Accessory.self != EmptyView.self {
                accessory()
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityElement(children: .contain)
    }
}

extension PageEmptyState {
    /// The symbol drawn from an AppKit image already colored `Theme.textTertiary`: some symbols ("clock") ignore
    /// SwiftUI's foreground style in layer snapshots and came out white.
    @ViewBuilder var glyph: some View {
        let configuration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(Theme.textTertiary)]))
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            Image(nsImage: image)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

extension PageEmptyState where Accessory == EmptyView {
    init(symbol: String, title: String, message: String, height: CGFloat = PageEmptyState.defaultHeight) {
        self.init(symbol: symbol, title: title, message: message, height: height) { EmptyView() }
    }
}

// MARK: - Selection plate

/// The selected Recents row and Shelf tile: the chip clay without its drop shadow, lifted by a white 0.06 wash
/// and edged with the dock cards' top-lit 1 pt ring, so selection reads as the same material as the cards rather
/// than a heavier slab whose shadow bleeds onto the next row.
struct SelectionPlate: View {
    var cornerRadius: CGFloat = 14

    /// Chip clay with no drop or contact shadow.
    static let clay = ClayStyle(
        gradient: Theme.chipGradient,
        grain: 0.8,
        shadowOpacity: 0,
        shadowRadius: 0,
        shadowY: 0,
        contactOpacity: 0
    )

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ClaySurface(shape: shape, style: Self.clay)
            .overlay { shape.fill(Color.white.opacity(0.06)) }
            .overlay {
                shape
                    .inset(by: 0.5)
                    .strokeBorder(DockCardChrome.ringGradient, lineWidth: 1)
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Inline action row buttons

/// The two controls of an inline action row (the composer gate line, a paste confirmation under a reply): one
/// pattern, one pair of controls. The primary is the permission card's small send-gradient capsule (22 pt, SPEC
/// §14.10.1); the secondary is a plain text button.
enum InlineAction {
    static let primaryHeight: CGFloat = 22
    static let primaryPadding: CGFloat = 10
    static let fontSize: CGFloat = 12

    struct PrimaryCapsule: View {
        let title: String
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(Theme.font(InlineAction.fontSize, .semibold))
                    .foregroundStyle(Theme.sendGlyph)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, InlineAction.primaryPadding)
                    .frame(height: InlineAction.primaryHeight)
                    .background {
                        Capsule(style: .continuous)
                            .fill(LinearGradient(colors: [Theme.sendTop, Theme.sendBottom],
                                                 startPoint: .top, endPoint: .bottom))
                            .brightness(isHovering ? 0.03 : 0)
                    }
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.96))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .accessibilityLabel(title)
        }
    }

    /// Secondary text, primary on hover.
    struct TextButton: View {
        let title: String
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(Theme.font(InlineAction.fontSize, .medium))
                    .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .frame(height: InlineAction.primaryHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.96))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .accessibilityLabel(title)
        }
    }
}
