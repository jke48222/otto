//
//  DockCardChrome.swift
//  Otto
//
//  The shared surface of every card in the dock (approvals, permission cards, one-time cards): a clay tray
//  with a faint inner ring that says "this needs you", plus the pieces the cards share: the header, the
//  footer buttons with their key hints, the checkbox, chips, the copy pebble and the character-wrapped
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
                RoundedRectangle(cornerRadius: Self.cornerRadius - 1, style: .continuous)
                    .strokeBorder(Theme.sendFill.opacity(0.28), lineWidth: 1)
                    .padding(1)
                    .allowsHitTesting(false)
            }
    }

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
                        .foregroundStyle(Theme.textTertiary)
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
                        KeyHint(text: hint, color: Theme.textTertiary)
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

    /// The primary footer button: the send gradient. While `armingProgress` is below 1 it sits at 45 %
    /// with a 1.5 pt ring tracing the capsule; `isEnabled` false keeps it inert either way.
    struct PrimaryButton: View {
        let title: String
        var hint: String? = nil
        /// nil: no arming (permission and one-time cards).
        var armingProgress: Double? = nil
        var isEnabled = true
        let action: () -> Void

        private var isArmed: Bool { (armingProgress ?? 1) >= 1 }

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Theme.font(13, .semibold))
                        .foregroundStyle(Theme.sendGlyph)
                        .lineLimit(1)
                    if let hint {
                        KeyHint(text: hint, color: Theme.sendGlyph.opacity(0.55))
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [Theme.sendTop, Theme.sendBottom],
                                             startPoint: .top, endPoint: .bottom))
                }
                .opacity(isArmed && isEnabled ? 1 : 0.45)
                .overlay {
                    if let armingProgress, armingProgress < 1 {
                        Capsule(style: .continuous)
                            .inset(by: -2)
                            .trim(from: 0, to: max(0, armingProgress))
                            .stroke(Theme.sendFill.opacity(0.9),
                                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Capsule(style: .continuous))
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
                    .foregroundStyle(isHovering ? Theme.textSecondary : Theme.textTertiary)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.96))
            .onHover { isHovering = $0 }
        }
    }

    // MARK: - Checkbox

    /// A small rounded-square toggle with a label ("Always allow “Log water”").
    struct Checkbox: View {
        @Binding var isOn: Bool
        let label: String

        var body: some View {
            Button {
                isOn.toggle()
            } label: {
                HStack(spacing: 7) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(isOn ? Theme.sendFill : Color.white.opacity(0.04))
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .strokeBorder(isOn ? Color.clear : Color.white.opacity(0.28), lineWidth: 1)
                        if isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.sendGlyph)
                        }
                    }
                    .frame(width: 13, height: 13)
                    Text(label)
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.98))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isOn.toggle() }
        }
    }

    // MARK: - Chips

    /// A small clay chip: an optional app icon or symbol and a label; danger chips carry an error tint.
    struct Chip: View {
        let label: String
        var symbol: String? = nil
        var bundleID: String? = nil
        var isDanger = false
        /// Overrides the label color (warning chips use `Theme.attention`); danger wins over it.
        var tint: Color? = nil
        var fontSize: CGFloat = 11.5

        private var labelColor: Color { isDanger ? Theme.error : (tint ?? Theme.chipLabel) }

        var body: some View {
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
                    .font(Theme.font(fontSize, isDanger ? .medium : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                    .dockRecordsText(label)
            }
            .foregroundStyle(labelColor)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .clay(in: Capsule(style: .continuous), style: .chip)
            .overlay {
                if isDanger || tint != nil {
                    Capsule(style: .continuous)
                        .strokeBorder(labelColor.opacity(0.45), lineWidth: 1)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Copy

    /// A "Copy" pebble that puts `text` on the general pasteboard and says "Copied" for a moment.
    struct CopyButton: View {
        let text: String
        var accessibilityName = "Copy"
        @State private var didCopy = false
        @State private var resetTask: Task<Void, Never>?

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
                        .font(.system(size: 9, weight: .semibold))
                    Text(didCopy ? "Copied" : "Copy")
                        .font(Theme.font(10.5, .medium))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .clay(in: Capsule(style: .continuous), style: .pebble)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.94))
            .accessibilityLabel(didCopy ? "Copied" : accessibilityName)
            .onDisappear { resetTask?.cancel() }
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

    /// Monospaced text wrapped by character (`AppleScriptCodeLayout.wrap`), so nothing can hide off to the
    /// right. Scrolls vertically only inside `maxHeight`; optionally numbers its lines in a gutter, where
    /// continuation rows show "↪". `onLastRowShown` fires once the last row has been inside the viewport.
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

            ScrollCap(maxHeight: maxHeight) {
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
                    .padding(Self.padding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
                }
                .scrollIndicators(overflows ? .automatic : .never)
                .coordinateSpace(name: Self.spaceName)
            }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                width = size.width
                viewportHeight = size.height
                reportIfLastRowShown()
            }
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
