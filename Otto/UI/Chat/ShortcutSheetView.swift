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
    static let contentSpace = "shortcut-sheet-content"
    /// The soft edge where rows scroll out of view: short, so it hides no more than most of one row.
    static let fadeDepth: CGFloat = 16

    /// Where each section header and row sits in the scrolling content, so the viewport can end between rows.
    @State private var marks: [Mark] = []

    /// A section header or a row in one of the two columns, in the scrolling content's coordinates.
    struct Mark: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case header, row }
        let kind: Kind
        let section: ShortcutSheet.Section.Kind
        /// Position within the section: 0 for the header and for the first row.
        let index: Int
        let minY: CGFloat
        let maxY: CGFloat
    }

    /// Pure. The rows' viewport: everything when it fits in `available`, else the tallest height that ends in the
    /// gap between two rows and leaves no section header in view without its first row (a header needs more than
    /// a sliver of itself showing to count as seen). Falls back to `available` when no gap qualifies.
    static func viewportHeight(available: CGFloat, contentHeight: CGFloat, marks: [Mark]) -> CGFloat {
        guard contentHeight > available + 0.5, !marks.isEmpty else { return available }
        let headers = marks.filter { $0.kind == .header }
        let firstRows = Dictionary(marks.filter { $0.kind == .row && $0.index == 0 }.map { ($0.section, $0) },
                                   uniquingKeysWith: { first, _ in first })
        let cuts = marks.filter { $0.kind == .row }.map { $0.maxY + 1 }.filter { $0 <= available }.sorted(by: >)
        for cut in cuts {
            let orphansAHeader = headers.contains { header in
                guard header.minY + 6 < cut, let first = firstRows[header.section] else { return false }
                return first.maxY > cut + 4
            }
            if !orphansAHeader { return cut }
        }
        return available
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.blockSpacing) {
            titleRow
            CappedHeightLayout(maxHeight: Self.viewportHeight(available: max(0, maxHeight - Self.chromeHeight),
                                                              contentHeight: contentFrame.height, marks: marks)) {
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
                    .coordinateSpace(.named(Self.contentSpace))
                    .onPreferenceChange(MarksKey.self) { value in
                        if marks != value { marks = value }
                    }
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
                    .reportsMark(.header, section: section.kind, index: 0)
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    RowView(row: row)
                        .reportsMark(.row, section: section.kind, index: index)
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

private struct MarksKey: PreferenceKey {
    static let defaultValue: [ShortcutSheetView.Mark] = []

    static func reduce(value: inout [ShortcutSheetView.Mark], nextValue: () -> [ShortcutSheetView.Mark]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    /// Reports this header's or row's frame in the sheet's scrolling content (`ShortcutSheetView.Mark`).
    func reportsMark(_ kind: ShortcutSheetView.Mark.Kind, section: ShortcutSheet.Section.Kind, index: Int) -> some View {
        background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(ShortcutSheetView.contentSpace))
                Color.clear.preference(
                    key: MarksKey.self,
                    value: [ShortcutSheetView.Mark(kind: kind, section: section, index: index,
                                                   minY: frame.minY, maxY: frame.maxY)]
                )
            }
        }
    }
}
