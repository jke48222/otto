//
//  RecentsScreen.swift
//  Otto
//
//  Recents on iPhone: saved conversations by date (Today, Yesterday, Previous 7 Days…), a search across every
//  message, swipe to delete with Undo, and the first-run note that History is on. Tapping a row opens it in the
//  chat. The rows, sections, empty states and strings are the Mac's (RecentsState, HistoryRecentsText).
//

import SwiftUI

struct RecentsScreen: View {
    let model: ChatScreenModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RecentsList(model: model, recents: model.recents, history: model.history, settings: model.settings)
                .navigationTitle("Recents")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.sheet = nil
                            model.newChat()
                        } label: {
                            Label("New Chat", systemImage: "square.and.pencil")
                        }
                    }
                }
                .toolbarBackground(Theme.panel, for: .navigationBar)
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.panel)
        .onDisappear {
            model.recents.deactivate()
            model.history.commitPendingDeletion()
        }
    }
}

private struct RecentsList: View {
    let model: ChatScreenModel
    @Bindable var recents: RecentsState
    let history: HistoryController
    let settings: AppSettings

    var body: some View {
        let empty = HistoryRecentsLayout.emptyState(
            rowCount: recents.rows.count,
            query: recents.query,
            isSearching: recents.isSearching,
            isIndexLoaded: history.isIndexLoaded,
            historyEnabled: settings.history.enabled
        )
        List {
            if !settings.history.noticeAcknowledged, settings.history.enabled {
                Section {
                    HistoryNoticeCard(settings: settings, history: history)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            if let empty {
                emptyView(empty)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if recents.sections.isEmpty {
                // A query: one ranked list.
                ForEach(recents.rows) { row in
                    rowView(row)
                }
            } else {
                ForEach(recents.sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            rowView(row)
                        }
                    } header: {
                        Text(section.title)
                            .font(Theme.font(13, .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .searchable(text: $recents.query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: HistoryRecentsText.searchPlaceholder)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let pending = history.pendingDeletion {
                UndoBar(title: pending.title) { history.undoDelete() }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: history.pendingDeletion?.id)
    }

    private func rowView(_ row: RecentsRow) -> some View {
        Button {
            model.openConversation(row.id)
        } label: {
            RecentsRowView(row: row, query: recents.query)
        }
        .buttonStyle(.plain)
        .listRowBackground(row.isCurrent ? Color.white.opacity(0.06) : Color.clear)
        .listRowSeparatorTint(Theme.hairline)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                history.delete(row.id)
            } label: {
                Label(HistoryRecentsText.deleteLabel, systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                model.openConversation(row.id)
            } label: {
                Label(HistoryRecentsText.openLabel, systemImage: "arrow.up.forward.app")
            }
            Button(role: .destructive) {
                history.delete(row.id)
            } label: {
                Label(HistoryRecentsText.deleteLabel, systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func emptyView(_ state: HistoryRecentsLayout.EmptyState) -> some View {
        switch state {
        case .loading:
            HStack {
                Spacer()
                ProgressView()
                    .tint(Theme.textSecondary)
                Spacer()
            }
            .padding(.vertical, 48)
        case .historyOff:
            VStack(spacing: 4) {
                EmptyStateView(symbol: "clock.badge.xmark", title: HistoryRecentsText.historyOffTitle,
                               message: HistoryRecentsText.historyOffBody)
                Button(HistoryRecentsText.turnOnHistory) {
                    Task { await history.setEnabled(true) }
                }
                .font(Theme.font(15, .semibold))
                .buttonStyle(.bordered)
                .tint(Theme.orbLight)
            }
        case .noConversations:
            EmptyStateView(symbol: "bubble.left.and.bubble.right", title: HistoryRecentsText.noConversationsTitle,
                           message: HistoryRecentsText.noConversationsBody)
        case .noMatches(let query):
            EmptyStateView(symbol: "magnifyingglass", title: HistoryRecentsText.noMatchesTitle(query: query),
                           message: HistoryRecentsText.noMatchesBody)
        }
    }
}

/// One conversation: its title and the preview (or the matching snippet), with when it was last touched.
private struct RecentsRowView: View {
    let row: RecentsRow
    let query: String

    var body: some View {
        let date = HistoryRecentsText.dateLabel(for: row, now: Date(), calendar: .current)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(HistoryRecentsText.styledTitle(of: row))
                    .font(Theme.font(16, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(date)
                    .font(Theme.font(12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
                    .layoutPriority(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if row.hasAttachments {
                    Image(systemName: "paperclip")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(HistoryRecentsText.styledDetail(of: row, query: query))
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HistoryRecentsText.accessibilityLabel(for: row, dateLabel: date))
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(row.isCurrent ? "Open now" : "")
    }
}

/// "Deleted “Title”" with Undo, while a delete can still be taken back.
private struct UndoBar: View {
    let title: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(HistoryRecentsText.undoMessage(title: title))
                .font(Theme.font(14))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button(HistoryRecentsText.undoLabel, action: onUndo)
                .font(Theme.font(14.5, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(minHeight: 36)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .clay(cornerRadius: 16, style: .tray)
    }
}

/// The first-run note: History is on, conversations stay on this iPhone, and how long they are kept.
private struct HistoryNoticeCard: View {
    let settings: AppSettings
    let history: HistoryController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(HistoryRecentsText.noticeTitle)
                .font(Theme.font(15.5, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(HistoryRecentsText.noticeBody(retention: settings.history.retention))
                .font(Theme.font(14))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(HistoryRecentsText.noticeAcknowledge) {
                    settings.history.noticeAcknowledged = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.sendFill)
                .foregroundStyle(Theme.sendGlyph)
                Button(HistoryRecentsText.noticeDecline) {
                    settings.history.noticeAcknowledged = true
                    Task { await history.setEnabled(false) }
                }
                .buttonStyle(.bordered)
                .tint(Theme.textSecondary)
            }
            .font(Theme.font(14, .semibold))
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
                }
        }
    }
}
