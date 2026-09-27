//
//  ShortcutSheetView.swift
//  Otto
//
//  The ⌘/ overlay: every shortcut that applies right now, in two columns of key-capped rows, over the
//  Chat page's conversation area. A click anywhere on it (or ⌘/, or Esc through the key map) dismisses it.
//

import SwiftUI

struct ShortcutSheetView: View {
    let sections: [ShortcutSheet.Section]
    /// The tallest the sheet may be; the rows scroll inside it when they don't fit.
    var maxHeight: CGFloat = 340
    let onDismiss: () -> Void

    init(sections: [ShortcutSheet.Section], maxHeight: CGFloat = 340, onDismiss: @escaping () -> Void) {
        self.sections = sections
        self.maxHeight = maxHeight
        self.onDismiss = onDismiss
    }

    @MainActor
    init(settings: AppSettings, availableRoutes: [NotchRoute], maxHeight: CGFloat = 340,
         onDismiss: @escaping () -> Void) {
        self.init(
            sections: ShortcutSheet.sections(settings: settings, availableRoutes: availableRoutes),
            maxHeight: maxHeight,
            onDismiss: onDismiss
        )
    }

    static let titleHeight: CGFloat = 22
    static let hintHeight: CGFloat = 14
    static let blockSpacing: CGFloat = 12
    static let columnSpacing: CGFloat = 16
    static let rowHeight: CGFloat = 22
    /// Title row, hint and the gaps around the scrolling rows.
    static var chromeHeight: CGFloat { titleHeight + hintHeight + blockSpacing * 2 }

    private var columns: (leading: [ShortcutSheet.Section], trailing: [ShortcutSheet.Section]) {
        ShortcutSheet.columns(sections)
    }

    private var notes: [String] { sections.compactMap(\.note) }

    /// The rows' frame in the scroll view and the scroll view's height: together they say which ends of the
    /// rows are scrolled out of view (and so fade).
    @State private var contentFrame: CGRect = .zero
    @State private var viewportHeight: CGFloat = 0

    private var clipsTop: Bool { contentFrame.minY < -0.5 }
    private var clipsBottom: Bool { viewportHeight > 0 && contentFrame.maxY > viewportHeight + 0.5 }

    private static let scrollSpace = "shortcut-sheet-scroll"
    private static let fadeDepth: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: Self.blockSpacing) {
            titleRow
            CappedHeightLayout(maxHeight: max(0, maxHeight - Self.chromeHeight)) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Self.blockSpacing) {
                        HStack(alignment: .top, spacing: Self.columnSpacing) {
                            column(columns.leading)
                            column(columns.trailing)
                        }
                        ForEach(notes, id: \.self) { note in
                            Text(note)
                                .font(Theme.font(11))
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // Room for the caps' shadows at the scroll view's edges.
                    .padding(.vertical, 4)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.scrollSpace)) }) { frame in
                        if contentFrame != frame { contentFrame = frame }
                    }
                }
                .coordinateSpace(.named(Self.scrollSpace))
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                    if viewportHeight != height { viewportHeight = height }
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
            }
            .mask { fadeMask }
            Text(ShortcutSheet.dismissHint)
                .font(Theme.font(11))
                .foregroundStyle(Theme.textTertiary)
                .frame(height: Self.hintHeight)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ShortcutSheet.title)
        .accessibilityAction(.escape, onDismiss)
        .accessibilityAction(named: "Close", onDismiss)
    }

    /// Rows slide under a soft edge instead of being cut where they scroll out of view.
    private var fadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: clipsTop ? Self.fadeDepth : 0)
            Rectangle().fill(Color.black)
            LinearGradient(colors: [.clear, .black], startPoint: .bottom, endPoint: .top)
                .frame(height: clipsBottom ? Self.fadeDepth : 0)
        }
        .animation(.easeOut(duration: 0.18), value: clipsTop)
        .animation(.easeOut(duration: 0.18), value: clipsBottom)
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(ShortcutSheet.title)
                .font(Theme.font(13, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            KeyCap.Chord(caps: ["⌘", "/"])
        }
        .frame(height: Self.titleHeight)
    }

    private func column(_ sections: [ShortcutSheet.Section]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sections) { section in
                SectionView(section: section)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private struct SectionView: View {
        let section: ShortcutSheet.Section

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title.uppercased())
                    .font(Theme.font(11, .medium))
                    .tracking(0.4)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(section.rows) { row in
                    RowView(row: row)
                }
            }
        }
    }

    private struct RowView: View {
        let row: ShortcutSheet.Row

        var body: some View {
            HStack(spacing: 8) {
                Text(row.title)
                    .font(Theme.font(12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    ForEach(Array(row.chords.enumerated()), id: \.offset) { index, chord in
                        if index > 0 {
                            Text("/")
                                .font(Theme.font(11))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        KeyCap.Chord(caps: chord, isHold: row.isHold)
                    }
                }
                .fixedSize()
            }
            .frame(minHeight: ShortcutSheetView.rowHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.title)
            .accessibilityValue(row.chords.map { KeyCap.spokenChord($0, isHold: row.isHold) }.joined(separator: ", or "))
        }
    }
}
