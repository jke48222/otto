//
//  RecentsView.swift
//  Otto
//
//  The Recents page of the open notch: a search well, saved conversations grouped by date, swipe or hover
//  to delete, the key-hint footer that turns into an Undo bar after a delete, and the empty states. It
//  draws RecentsState and HistoryController and reports every user action through closures.
//

import SwiftUI

struct RecentsView: View {
    /// What the page asks its owner to do. The keyboard (↑ ↓ ↩ ⌘⌫ ⌘Z esc) is handled by the panel's key
    /// map, not here.
    struct Actions {
        var open: (UUID) -> Void
        var delete: (UUID) -> Void
        var undoDelete: () -> Void
        var openSettings: () -> Void
        var turnOnHistory: () -> Void
        var acknowledgeNotice: () -> Void
        var declineHistory: () -> Void
        /// The search field gained or lost keyboard focus.
        var searchFocusChanged: (Bool) -> Void

        init(
            open: @escaping (UUID) -> Void,
            delete: @escaping (UUID) -> Void,
            undoDelete: @escaping () -> Void,
            openSettings: @escaping () -> Void,
            turnOnHistory: @escaping () -> Void,
            acknowledgeNotice: @escaping () -> Void,
            declineHistory: @escaping () -> Void,
            searchFocusChanged: @escaping (Bool) -> Void = { _ in }
        ) {
            self.open = open
            self.delete = delete
            self.undoDelete = undoDelete
            self.openSettings = openSettings
            self.turnOnHistory = turnOnHistory
            self.acknowledgeNotice = acknowledgeNotice
            self.declineHistory = declineHistory
            self.searchFocusChanged = searchFocusChanged
        }
    }

    private let recents: RecentsState
    private let history: HistoryController
    private let settings: HistorySettings
    private let isStreaming: Bool
    private let pageHeight: CGFloat
    private let actions: Actions

    @State private var noticeHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `pageHeight` is the room the page gets under the header; the list scrolls inside what is left.
    init(
        recents: RecentsState,
        history: HistoryController,
        settings: HistorySettings,
        isStreaming: Bool,
        pageHeight: CGFloat = HistoryRecentsLayout.defaultPageHeight,
        actions: Actions
    ) {
        self.recents = recents
        self.history = history
        self.settings = settings
        self.isStreaming = isStreaming
        self.pageHeight = pageHeight
        self.actions = actions
    }

    private var showsNotice: Bool {
        history.isIndexLoaded && settings.enabled && !settings.noticeAcknowledged
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsNotice {
                RecentsNoticeCard(
                    message: HistoryRecentsText.noticeBody(retention: settings.retention),
                    acknowledge: actions.acknowledgeNotice,
                    decline: actions.declineHistory
                )
                .padding(.bottom, 10)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: RecentsNoticeHeightKey.self, value: proxy.size.height)
                    }
                }
                .transition(.reducible(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)), reduceMotion: reduceMotion))
            }

            RecentsSearchField(
                recents: recents,
                focusChanged: actions.searchFocusChanged
            )

            content
                .padding(.top, HistoryRecentsLayout.searchGap)

            footer
                .padding(.top, HistoryRecentsLayout.footerGap)
        }
        .padding(.horizontal, 16)
        .padding(.top, HistoryRecentsLayout.topPadding)
        .padding(.bottom, HistoryRecentsLayout.bottomPadding)
        .onPreferenceChange(RecentsNoticeHeightKey.self) { noticeHeight = $0 }
        .animation(Theme.Motion.content, value: showsNotice)
    }

    // MARK: - List or empty state

    private var emptyState: HistoryRecentsLayout.EmptyState? {
        HistoryRecentsLayout.emptyState(
            rowCount: recents.rows.count,
            query: recents.query,
            isSearching: recents.isSearching,
            isIndexLoaded: history.isIndexLoaded,
            historyEnabled: settings.enabled
        )
    }

    @ViewBuilder
    private var content: some View {
        if let emptyState {
            RecentsEmptyState(state: emptyState, turnOnHistory: actions.turnOnHistory)
        } else {
            let items = HistoryRecentsLayout.items(rows: recents.rows, sections: recents.sections)
            let available = HistoryRecentsLayout.availableListHeight(
                pageHeight: pageHeight - (showsNotice ? noticeHeight : 0)
            )
            RecentsList(
                items: items,
                recents: recents,
                isOpening: history.isOpeningConversation,
                now: history.now(),
                actions: actions
            )
            .frame(height: HistoryRecentsLayout.listHeight(for: items, available: available))
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        let mode = HistoryRecentsLayout.footer(
            pendingDeletionTitle: history.pendingDeletion?.title,
            isStreaming: isStreaming,
            hasSelectableRow: !recents.rows.isEmpty && emptyState == nil
        )
        Group {
            switch mode {
            case .undo(let title):
                RecentsUndoBar(title: title, undo: actions.undoDelete)
                    .transition(.reducible(.opacity.combined(with: .move(edge: .bottom)), reduceMotion: reduceMotion))
            case .streamingWarning, .hints, .backHint:
                RecentsFooter(
                    showsStreamingWarning: mode == .streamingWarning,
                    hints: mode == .backHint ? HistoryRecentsText.backHints : HistoryRecentsText.hints,
                    keptLabel: HistoryRecentsText.keptLabel(
                        retention: settings.retention,
                        historyEnabled: settings.enabled
                    ),
                    openSettings: actions.openSettings
                )
                .transition(.opacity)
            }
        }
        .frame(height: HistoryRecentsLayout.footerHeight)
        .animation(Theme.Motion.content, value: mode)
    }
}

// MARK: - Search

private struct RecentsSearchField: View {
    @Bindable var recents: RecentsState
    let focusChanged: (Bool) -> Void

    @FocusState private var isFocused: Bool
    @State private var focusTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            TextField(HistoryRecentsText.searchPlaceholder, text: $recents.query)
                .textFieldStyle(.plain)
                .font(Theme.font(13.5))
                .foregroundStyle(Theme.textPrimary)
                .focused($isFocused)
                .accessibilityLabel(HistoryRecentsText.searchPlaceholder)
            if recents.isSearching {
                MiniSpinner(size: 11, color: Theme.textTertiary)
            }
            if !recents.query.isEmpty {
                Button {
                    recents.query = ""
                    recents.focusSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.85))
                .help(HistoryRecentsText.clearSearch)
                .accessibilityLabel(HistoryRecentsText.clearSearch)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: HistoryRecentsLayout.searchHeight)
        .clay(in: Capsule(style: .continuous), style: .tray)
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { isFocused = true }
        .onChange(of: recents.searchFocusRequest) { requestFocus() }
        .onChange(of: isFocused) { _, focused in focusChanged(focused) }
        .onAppear { requestFocus() }
        .onDisappear {
            focusTask?.cancel()
            if isFocused { focusChanged(false) }
        }
    }

    /// The panel may only just be turning key when Recents shows, so focus on the next run-loop turns (the
    /// composer's technique).
    private func requestFocus() {
        focusTask?.cancel()
        focusTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            isFocused = true
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, !isFocused else { return }
            isFocused = true
        }
    }
}

// MARK: - List

private struct RecentsList: View {
    let items: [HistoryRecentsLayout.Item]
    let recents: RecentsState
    let isOpening: Bool
    let now: Date
    let actions: RecentsView.Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(items) { item in
                    Group {
                        switch item {
                        case .section(_, let title):
                            RecentsSectionTitle(title: title)
                        case .row(let row):
                            RecentsRowView(
                                row: row,
                                query: recents.query,
                                dateLabel: HistoryRecentsText.dateLabel(
                                    for: row,
                                    now: now,
                                    calendar: recents.calendar
                                ),
                                isSelected: recents.selectedID == row.id,
                                isOpening: isOpening && recents.selectedID == row.id,
                                open: {
                                    recents.selectedID = row.id
                                    actions.open(row.id)
                                },
                                delete: { actions.delete(row.id) }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    actions.delete(row.id)
                                } label: {
                                    Label(HistoryRecentsText.deleteLabel, systemImage: "trash")
                                }
                            }
                            .transition(.reducible(.opacity.combined(with: .move(edge: .trailing)), reduceMotion: reduceMotion))
                        }
                    }
                    .id(item.id)
                    // The macOS table keeps 8 pt of its own inset on each side; negative row insets cancel it so
                    // the selected row's plate spans the search well's width, 16 pt from each panel edge.
                    .listRowInsets(EdgeInsets(top: 0, leading: -HistoryRecentsLayout.listSideInset,
                                              bottom: 0, trailing: -HistoryRecentsLayout.listSideInset))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .contentMargins(.vertical, HistoryRecentsLayout.listContentInset, for: .scrollContent)
            .animation(Theme.Motion.content, value: items)
            .onChange(of: recents.selectedID) { _, selected in
                guard let selected else { return }
                proxy.scrollTo(HistoryRecentsLayout.Item.rowID(selected), anchor: nil)
            }
        }
    }
}

private extension HistoryRecentsLayout.Item {
    static func rowID(_ id: UUID) -> String { "row:" + id.uuidString }
}

private struct RecentsSectionTitle: View {
    let title: String

    var body: some View {
        // Sentence case like the rest of the notch ("Thought process"), not a tracked all-caps register.
        Text(title)
            .font(Theme.font(12, .semibold))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Lines up with the row titles: the row's 12 pt padding, its 6 pt unread dot and the 10 pt gap.
            .padding(.leading, 28)
            .padding(.trailing, 12)
            .padding(.top, 8)
            .frame(height: HistoryRecentsLayout.sectionTitleHeight, alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct RecentsRowView: View {
    let row: RecentsRow
    /// The search field's text: its words are bold in the snippet as well as the title.
    let query: String
    let dateLabel: String
    let isSelected: Bool
    let isOpening: Bool
    let open: () -> Void
    let delete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(row.isCurrent ? Theme.orbLight : Color.clear)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(styledTitle)
                    .font(Theme.font(13.5, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(styledDetail)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 10)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: HistoryRecentsLayout.rowHeight)
        .background { plate }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            Button(HistoryRecentsText.openLabel, action: open)
            Button(HistoryRecentsText.deleteLabel, role: .destructive, action: delete)
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(HistoryRecentsText.accessibilityLabel(for: row, dateLabel: dateLabel))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: HistoryRecentsText.deleteLabel, delete)
    }

    /// The title with its query matches drawn in the bold weight of the title font.
    private var styledTitle: AttributedString {
        var text = HistoryRecentsText.styledTitle(of: row)
        let bold = text.runs
            .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map(\.range)
        for range in bold {
            text[range].font = Theme.font(13.5, .bold)
        }
        return text
    }

    /// The snippet with its query matches in the semibold weight of the detail font, a step brighter.
    private var styledDetail: AttributedString {
        var text = HistoryRecentsText.styledDetail(of: row, query: query)
        let bold = text.runs
            .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map(\.range)
        for range in bold {
            text[range].font = Theme.font(12, .semibold)
            text[range].foregroundColor = Theme.textPrimary
        }
        return text
    }

    @ViewBuilder
    private var plate: some View {
        if isSelected {
            SelectionPlate(cornerRadius: 14)
        } else if isHovering {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isOpening {
            MiniSpinner(size: 12, color: Theme.textTertiary)
        } else if isHovering {
            RecentsDeleteButton(action: delete)
        } else {
            // Tertiary passes AA on the panel but not on the selected row's lighter chip plate.
            let color = isSelected ? Theme.textSecondary : Theme.textTertiary
            VStack(alignment: .trailing, spacing: 3) {
                Text(dateLabel)
                    .font(Theme.font(11.5))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                if row.hasAttachments {
                    Image(systemName: "paperclip")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(color)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

private struct RecentsDeleteButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 22, height: 22)
                .background {
                    Circle().fill(Color.white.opacity(isHovering ? 0.1 : 0.05))
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.88))
        .onHover { isHovering = $0 }
        .help(HistoryRecentsText.deleteLabel)
        .accessibilityLabel(HistoryRecentsText.deleteLabel)
    }
}

// MARK: - Empty states

private struct RecentsEmptyState: View {
    let state: HistoryRecentsLayout.EmptyState
    let turnOnHistory: () -> Void

    var body: some View {
        if state == .loading {
            MiniSpinner(size: 14, color: Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .frame(height: HistoryRecentsLayout.emptyStateHeight)
        } else {
            PageEmptyState(symbol: symbol, title: title, message: message,
                           height: HistoryRecentsLayout.emptyStateHeight) {
                if state == .historyOff {
                    RecentsCapsuleButton(title: HistoryRecentsText.turnOnHistory, action: turnOnHistory)
                }
            }
        }
    }

    private var symbol: String {
        switch state {
        case .noMatches: return "magnifyingglass"
        default: return "clock"
        }
    }

    private var title: String {
        switch state {
        case .loading, .noConversations: return HistoryRecentsText.noConversationsTitle
        case .historyOff: return HistoryRecentsText.historyOffTitle
        case .noMatches(let query): return HistoryRecentsText.noMatchesTitle(query: query)
        }
    }

    private var message: String {
        switch state {
        case .loading, .noConversations: return HistoryRecentsText.noConversationsBody
        case .historyOff: return HistoryRecentsText.historyOffBody
        case .noMatches: return HistoryRecentsText.noMatchesBody
        }
    }
}

/// Small off-white capsule button (empty-state action, the notice's primary).
private struct RecentsCapsuleButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(12.5, .medium))
                .foregroundStyle(Theme.sendGlyph)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule(style: .continuous).fill(Theme.sendFill))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - First-run notice (compact)

private struct RecentsNoticeCard: View {
    let message: String
    let acknowledge: () -> Void
    let decline: () -> Void

    @State private var isHoveringDecline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(HistoryRecentsText.noticeTitle)
                .font(Theme.font(13, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.font(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                RecentsCapsuleButton(title: HistoryRecentsText.noticeAcknowledge, action: acknowledge)
                Button(action: decline) {
                    Text(HistoryRecentsText.noticeDecline)
                        .font(Theme.font(12.5))
                        .foregroundStyle(isHoveringDecline ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.96))
                .onHover { isHoveringDecline = $0 }
            }
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .clay(cornerRadius: 18, style: .tray)
        .accessibilityElement(children: .contain)
    }
}

private struct RecentsNoticeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Footer and Undo bar

private struct RecentsFooter: View {
    let showsStreamingWarning: Bool
    let hints: [(key: String, label: String)]
    let keptLabel: String
    let openSettings: () -> Void

    @State private var isHoveringLink = false

    /// No side padding: the first hint's pill and the trailing link end flush with the search capsule's edges.
    var body: some View {
        HStack(spacing: 6) {
            if showsStreamingWarning {
                Text(HistoryRecentsText.streamingWarning)
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            } else {
                ForEach(hints, id: \.key) { hint in
                    RecentsKeyHint(key: hint.key, label: hint.label)
                }
            }
            Spacer(minLength: 8)
            Button(action: openSettings) {
                Text(keptLabel)
                    .font(Theme.font(11))
                    .foregroundStyle(isHoveringLink ? Theme.textSecondary : Theme.textTertiary)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringLink = $0 }
        }
    }
}

private struct RecentsKeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(Theme.font(10.5, .medium))
            Text(label)
                .font(Theme.font(11))
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }
}

private struct RecentsUndoBar: View {
    let title: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(HistoryRecentsText.undoMessage(title: title))
                .font(Theme.font(12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button(action: undo) {
                Text(HistoryRecentsText.undoLabel)
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.sendFill)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
            .accessibilityLabel(HistoryRecentsText.undoLabel)
            Text(HistoryRecentsText.undoShortcut)
                .font(Theme.font(10.5, .medium))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
    }
}
