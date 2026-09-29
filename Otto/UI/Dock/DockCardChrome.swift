//
//  DockCardChrome.swift
//  Otto
//
//  The shared surface of every card in the dock (approvals, permission cards, one-time cards): a clay tray
//  with a faint top-lit inner ring that says "this needs you", plus the pieces the cards share: the header, the
//  footer buttons with their key hints, the checkbox, chips, the copy button and the character-wrapped
//  mono box.
//

import AppKit
import os
import SwiftUI

struct DockCardChrome: ViewModifier {
    static let cornerRadius: CGFloat = 20
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 12
    static let spacing: CGFloat = 10
    static let footerHeight: CGFloat = 30

    static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Tools")

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clay(cornerRadius: Self.cornerRadius, style: .tray)
            .overlay {
                // A top-lit bevel rather than an even outline: the edge catches light across the top and
                // fades down the sides, so the card reads as the same soft clay as the composer.
                RoundedRectangle(cornerRadius: Self.cornerRadius - 1, style: .continuous)
                    .strokeBorder(Self.ringGradient, lineWidth: 1)
                    .padding(1)
                    .allowsHitTesting(false)
            }
    }

    /// The inner ring: white 0.16 at the top fading to 0.04 at the bottom.
    static let ringGradient = LinearGradient(
        colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Posts a VoiceOver announcement (prompt titles, the arming delay, why an approval press did nothing).
    @MainActor
    static func announce(_ text: String) {
        guard !text.isEmpty else { return }
        let element: Any = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp as Any
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    // MARK: - Header

    /// A 26 pt pebble with the symbol, the title (up to two lines) and an optional trailing counter.
    struct Header: View {
        let symbol: String
        let title: String
        var counter: String? = nil
        var symbolColor: Color = Theme.textPrimary
        var showsSpinner = false

        var body: some View {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    if showsSpinner {
                        MiniSpinner(size: 12, lineWidth: 1.6, color: Theme.textPrimary)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(symbolColor)
                    }
                }
                .frame(width: 26, height: 26)
                .clay(in: Circle(), style: .pebble)
                .accessibilityHidden(true)

                Text(title)
                    .font(Theme.font(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)

                if let counter {
                    Text(counter)
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.textTertiaryOnClay)
                        .fixedSize()
                }
            }
        }
    }

    // MARK: - Buttons

    /// The small key hint inside a footer button ("esc", "⌘↩").
    struct KeyHint: View {
        let text: String
        var color: Color

        var body: some View {
            Text(text)
                .font(Theme.font(10.5, .medium))
                .foregroundStyle(color)
                .accessibilityHidden(true)
        }
    }

    /// The secondary footer button: a clay capsule with an optional key hint.
    struct SecondaryButton: View {
        let title: String
        var hint: String? = nil
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Theme.font(13, .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let hint {
                        // Secondary, not tertiary: the chip clay is lighter than the panel (AA, 10.5 pt).
                        KeyHint(text: hint, color: Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 28)
                .clay(in: Capsule(style: .continuous), style: .chip, isHighlighted: isHovering)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.96))
            .onHover { isHovering = $0 }
            .accessibilityLabel(title)
        }
    }

    /// The primary footer button: the send gradient once it is armed and enabled. Until then it sits in a recessed
    /// clay well (`waitingFill` with a 1 pt white 0.10 inner ring) with its label and key hint in `textSecondary`
    /// (6.7:1 on the well), so it reads as waiting without dimming any text; a 1.5 pt ring traces the capsule while
    /// it arms (SPEC §5.7). Arming crossfades the well into the gradient over 0.2 s: a fade only, so Reduce Motion
    /// needs no special case. `isEnabled` false keeps it in the well and inert either way.
    struct PrimaryButton: View {
        let title: String
        var hint: String? = nil
        /// nil: no arming (permission and one-time cards).
        var armingProgress: Double? = nil
        var isEnabled = true
        let action: () -> Void

        private var isArmed: Bool { (armingProgress ?? 1) >= 1 }
        private var isReady: Bool { isArmed && isEnabled }

        /// The waiting well: a shade under the card's lit clay, so the button reads as pressed in, not greyed out.
        static let waitingFill = Theme.rgb(0x1C1D20)
        static let waitingRing = Color.white.opacity(0.10)
        static let waitingLabel = Theme.textSecondary

        var body: some View {
            let shape = Capsule(style: .continuous)
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Theme.font(13, .semibold))
                        .foregroundStyle(isReady ? Theme.sendGlyph : Self.waitingLabel)
                        .lineLimit(1)
                    if let hint {
                        KeyHint(text: hint, color: isReady ? Theme.sendHint : Self.waitingLabel)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background {
                    ZStack {
                        shape
                            .fill(Self.waitingFill)
                            .overlay { shape.strokeBorder(Self.waitingRing, lineWidth: 1) }
                            .opacity(isReady ? 0 : 1)
                        shape
                            .fill(LinearGradient(colors: [Theme.sendTop, Theme.sendBottom],
                                                 startPoint: .top, endPoint: .bottom))
                            .opacity(isReady ? 1 : 0)
                    }
                }
                // Opacity and color only, so it stays a crossfade under Reduce Motion.
                .animation(.easeOut(duration: 0.2), value: isReady)
                .overlay {
                    if let armingProgress, armingProgress < 1 {
                        shape
                            .inset(by: -2)
                            .trim(from: 0, to: max(0, armingProgress))
                            .stroke(Theme.sendFill.opacity(0.9),
                                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(shape)
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.96))
            .disabled(!isEnabled || !isArmed)
        }
    }

    /// A plain text button in the footer ("Decline All").
    struct TextButton: View {
        let title: String
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(isHovering ? Theme.textSecondary : Theme.textTertiaryOnClay)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.96))
            .onHover { isHovering = $0 }
        }
    }

    // MARK: - Checkbox

    /// A small clay toggle with a label ("Always allow “Log water”"): a 16 pt rounded square that is a faint
    /// well with the card's top-lit ring when off and the send gradient with a check when on. The two states
    /// crossfade; nothing scales or moves, so Reduce Motion needs no special case.
    struct Checkbox: View {
        @Binding var isOn: Bool
        let label: String

        static let boxSide: CGFloat = 16
        static let boxRadius: CGFloat = 5

        var body: some View {
            Button {
                isOn.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    box
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                    Text(label)
                        .font(Theme.font(12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(CheckboxButtonStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isOn.toggle() }
        }

        private var box: some View {
            let shape = RoundedRectangle(cornerRadius: Self.boxRadius, style: .continuous)
            return ZStack {
                shape
                    .fill(Color.white.opacity(0.06))
                    .overlay { shape.strokeBorder(DockCardChrome.ringGradient, lineWidth: 1) }
                    .opacity(isOn ? 0 : 1)
                shape
                    .fill(LinearGradient(colors: [Theme.sendTop, Theme.sendBottom],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.sendGlyph)
                    }
                    .opacity(isOn ? 1 : 0)
            }
            .frame(width: Self.boxSide, height: Self.boxSide)
            .animation(.easeOut(duration: 0.15), value: isOn)
        }
    }

    /// No pressed look: the box's crossfade is the feedback, and the label is never dimmed or scaled.
    private struct CheckboxButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
        }
    }

    // MARK: - Chips

    /// A small flat chip: an optional app icon or symbol and a label. Neutral chips are a faint white fill;
    /// danger chips (and tinted warning chips) wash that fill with their color and draw the label in it.
    /// No stroke and no shadow, like the context chips: the card is the raised form, not its chips.
    struct Chip: View {
        let label: String
        var symbol: String? = nil
        var bundleID: String? = nil
        var isDanger = false
        /// Overrides the label color (warning chips use `Theme.attention`); danger wins over it.
        var tint: Color? = nil
        var fontSize: CGFloat = 12

        static let height: CGFloat = 24
        static let horizontalPadding: CGFloat = 10

        private var accent: Color? { isDanger ? Theme.error : tint }
        private var labelColor: Color { accent ?? Theme.textPrimary }

        var body: some View {
            let shape = Capsule(style: .continuous)
            HStack(spacing: 5) {
                if let bundleID, let icon = AppIconCache.icon(forBundleID: bundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(label)
                    // Regular even when tinted: the tint and its wash already mark it, and a heavier weight
                    // made a run of danger chips the loudest block on the card.
                    .font(Theme.font(fontSize))
                    .fixedSize(horizontal: false, vertical: true)
                    .dockRecordsText(label)
            }
            .foregroundStyle(labelColor)
            .padding(.horizontal, Self.horizontalPadding)
            .frame(minHeight: Self.height)
            .background {
                shape
                    .fill(accent == nil ? Theme.chipLiftedFill : Color.white.opacity(0.04))
                    .overlay {
                        if let accent {
                            shape.fill(accent.opacity(0.14))
                        }
                    }
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Copy

    /// A ghost "Copy" button (no surface at rest, a faint capsule on hover, the reply code block's metrics)
    /// that puts `text` on the general pasteboard and says "Copied" for a moment.
    struct CopyButton: View {
        let text: String
        var accessibilityName = "Copy"
        @State private var didCopy = false
        @State private var resetTask: Task<Void, Never>?
        @State private var isHovering = false

        var body: some View {
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                DockCardChrome.logger.debug("Copied dock text, \(text.count, privacy: .public) characters")
                didCopy = true
                resetTask?.cancel()
                resetTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.4))
                    guard !Task.isCancelled else { return }
                    didCopy = false
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                    Text(didCopy ? "Copied" : "Copy")
                        .font(Theme.font(11.5, .medium))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(GhostCapsuleButtonStyle(isHovering: isHovering))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .accessibilityLabel(didCopy ? "Copied" : accessibilityName)
            .onDisappear { resetTask?.cancel() }
        }
    }

    /// No surface at rest; white 0.06 on hover, 0.04 and 85 % opacity while pressed.
    private struct GhostCapsuleButtonStyle: ButtonStyle {
        let isHovering: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(configuration.isPressed ? 0.04 : (isHovering ? 0.06 : 0)))
                }
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(Theme.Motion.press, value: configuration.isPressed)
        }
    }

    // MARK: - Scroll cap

    /// Sizes its single child (a scroll view) to the child's ideal height, capped at `maxHeight` and at the
    /// height it is offered, so short content takes only its own height and long content scrolls.
    struct ScrollCap: Layout {
        var maxHeight: CGFloat = .infinity
        /// The cap when the container offers no finite height (sized to its ideal).
        var idealCap: CGFloat = .infinity

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let child = subviews.first else { return .zero }
            let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            let offered = proposal.height ?? .infinity
            let cap = min(maxHeight, offered.isFinite ? offered : idealCap)
            return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, max(0, cap)))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            for child in subviews {
                child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
            }
        }
    }

    // MARK: - Mono box

    /// Sizes its single child (a scroll view of `rowHeight` rows) like `ScrollCap`, inside `inset` at the top and
    /// bottom, and snaps a viewport that can't show every row down to whole rows, so the last row in view is never
    /// cut in half. The inset stays outside the scroller: rows clip at its edges while scrolling, and the box keeps
    /// the same margin above the first row and below the last one in view.
    struct RowSnappedCap: Layout {
        var maxHeight: CGFloat
        var rowHeight: CGFloat
        var inset: CGFloat

        /// The scroller's height: all of it when the rows fit in `available`, else as many whole rows as fit.
        static func viewportHeight(contentHeight: CGFloat, available: CGFloat, rowHeight: CGFloat) -> CGFloat {
            guard contentHeight > available + 0.5 else { return contentHeight }
            guard rowHeight > 0, available.isFinite else { return max(0, available) }
            return max(0, (available / rowHeight + 0.001).rounded(.down) * rowHeight)
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let child = subviews.first else { return .zero }
            let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            let offered = proposal.height ?? .infinity
            let available = min(maxHeight, offered) - inset * 2
            let height = Self.viewportHeight(contentHeight: ideal.height, available: available, rowHeight: rowHeight)
            return CGSize(width: proposal.width ?? ideal.width, height: height + inset * 2)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            for child in subviews {
                child.place(at: CGPoint(x: bounds.minX, y: bounds.minY + inset), anchor: .topLeading,
                            proposal: ProposedViewSize(width: bounds.width, height: max(0, bounds.height - inset * 2)))
            }
        }
    }

    /// Monospaced text wrapped by character (`AppleScriptCodeLayout.wrap`, which prefers a space or separator), so
    /// nothing can hide off to the right. Scrolls vertically only inside `maxHeight`, in whole rows
    /// (`RowSnappedCap`); optionally numbers its lines in a gutter, where continuation rows show "↪".
    /// `onLastRowShown` fires once the last row has been inside the viewport.
    struct MonoBox: View {
        /// The exact text (what the accessibility value reads and the copy button copies).
        let text: String
        /// Styled characters equal to `text`; nil draws `text` in `color`.
        var attributed: AttributedString? = nil
        var fontSize: CGFloat = 12
        var color: Color = Theme.codeText
        var lineSpacingFactor: CGFloat = 1.35
        var showsLineNumbers = false
        var maxHeight: CGFloat = 148
        var accessibilityName: String
        var onOverflowChange: ((Bool) -> Void)? = nil
        var onLastRowShown: (() -> Void)? = nil

        @State private var width: CGFloat?
        @State private var viewportHeight: CGFloat = 0
        @State private var lastRowMaxY: CGFloat = .infinity
        @State private var contentHeight: CGFloat = 0
        @State private var reportedLastRow = false

        static let padding: CGFloat = 8
        private static let spaceName = "dock-mono-box"

        private var rowHeight: CGFloat { (fontSize * lineSpacingFactor).rounded(.up) }

        private var gutterWidth: CGFloat {
            guard showsLineNumbers else { return 0 }
            let digits = String(max(1, AppleScriptCodeLayout.lineCount(of: text))).count
            return max(28, CGFloat(digits) * 7 + 10)
        }

        private var columns: Int {
            let available = (width ?? 480) - Self.padding * 2 - gutterWidth - 2
            return AppleScriptCodeLayout.columns(forWidth: available, fontSize: fontSize)
        }

        var body: some View {
            let rows = AppleScriptCodeLayout.wrap(text, columns: columns)
            let styled = AppleScriptCodeLayout.attributedRows(attributed ?? plainAttributed, rows: rows)
            let overflows = contentHeight > 0 && viewportHeight > 0
                ? contentHeight > viewportHeight + 0.5
                : AppleScriptCodeLayout.needsScrollToReview(rowCount: rows.count, rowHeight: rowHeight,
                                                            verticalPadding: Self.padding * 2, maxHeight: maxHeight)

            RowSnappedCap(maxHeight: maxHeight, rowHeight: rowHeight, inset: Self.padding) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row, styled: styled[row.index])
                                .onGeometryChange(for: CGFloat.self, of: { proxy in
                                    row.index == rows.count - 1 ? proxy.frame(in: .named(Self.spaceName)).maxY : 0
                                }) { maxY in
                                    guard row.index == rows.count - 1 else { return }
                                    lastRowMaxY = maxY
                                    reportIfLastRowShown()
                                }
                        }
                    }
                    .padding(.horizontal, Self.padding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
                }
                .scrollIndicators(overflows ? .automatic : .never)
                .coordinateSpace(name: Self.spaceName)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                    viewportHeight = height
                    reportIfLastRowShown()
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            .onAppear {
                onOverflowChange?(overflows)
                if rows.isEmpty, !reportedLastRow {
                    reportedLastRow = true
                    onLastRowShown?()
                }
            }
            .onChange(of: overflows) { _, value in onOverflowChange?(value) }
            .background(Theme.codeFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(text)
            .dockRecordsText(text)
        }

        private func rowView(_ row: AppleScriptCodeLayout.CodeLine, styled: AttributedString) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if showsLineNumbers {
                    Text(row.lineNumber.map(String.init) ?? "↪")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: gutterWidth - 8, alignment: .trailing)
                        .padding(.trailing, 8)
                }
                Text(styled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: rowHeight)
        }

        private func reportIfLastRowShown() {
            guard !reportedLastRow, viewportHeight > 0, lastRowMaxY.isFinite,
                  AppleScriptCodeLayout.isLastRowVisible(lastRowMaxY: lastRowMaxY, viewportHeight: viewportHeight)
            else { return }
            reportedLastRow = true
            onLastRowShown?()
        }

        private var plainAttributed: AttributedString {
            var container = AttributeContainer()
            container.swiftUI.font = Theme.mono(fontSize)
            container.swiftUI.foregroundColor = color
            return AttributedString(text, attributes: container)
        }
    }
}

extension View {
    /// The dock card surface (`DockCardChrome`).
    func dockCardChrome() -> some View {
        modifier(DockCardChrome())
    }
}
