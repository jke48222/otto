//
//  HistoryRecentsModel.swift
//  Otto
//
//  Pure helpers behind the Recents page: the flat list the page draws (section titles as plain rows),
//  its height, which empty state or footer shows, and every string the page displays.
//

import Foundation

/// Sizes and the flat item list of the Recents page (history.md §2.2).
enum HistoryRecentsLayout {
    static let rowHeight: CGFloat = 50
    static let sectionTitleHeight: CGFloat = 26
    /// Top and bottom content inset of the list.
    static let listContentInset: CGFloat = 2
    static let searchHeight: CGFloat = 36
    static let footerHeight: CGFloat = 22
    static let emptyStateHeight: CGFloat = 132
    static let topPadding: CGFloat = 10
    static let bottomPadding: CGFloat = 16
    /// Gap under the search well and above the footer.
    static let searchGap: CGFloat = 10
    static let footerGap: CGFloat = 8
    /// Vertical space the page spends on everything but the list (and the first-run notice).
    static let chrome: CGFloat = topPadding + searchHeight + searchGap + footerGap + footerHeight + bottomPadding

    /// Room left for the list on a page `pageHeight` tall.
    static func availableListHeight(pageHeight: CGFloat) -> CGFloat {
        max(0, pageHeight - chrome)
    }

    /// The default page height: the open panel's cap minus the 40 pt header.
    static let defaultPageHeight: CGFloat = NotchMetrics.maxOpenHeight - 40

    /// One line of the list: a section title (not interactive, not sticky) or a conversation.
    enum Item: Identifiable, Equatable {
        case section(id: String, title: String)
        case row(RecentsRow)

        var id: String {
            switch self {
            case .section(let id, _): return "section:" + id
            case .row(let row): return "row:" + row.id.uuidString
            }
        }

        var height: CGFloat {
            switch self {
            case .section: return HistoryRecentsLayout.sectionTitleHeight
            case .row: return HistoryRecentsLayout.rowHeight
            }
        }
    }

    /// Date sections as title rows followed by their conversations; the plain ranked rows while a query shows
    /// (RecentsState leaves `sections` empty then).
    static func items(rows: [RecentsRow], sections: [RecentsSection]) -> [Item] {
        guard !sections.isEmpty else { return rows.map(Item.row) }
        var items: [Item] = []
        for section in sections where !section.rows.isEmpty {
            items.append(.section(id: section.id, title: section.title))
            items.append(contentsOf: section.rows.map(Item.row))
        }
        return items
    }

    /// Explicit list height: every item plus the content insets, capped at `available`.
    static func listHeight(for items: [Item], available: CGFloat) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let content = items.reduce(2 * listContentInset) { $0 + $1.height }
        return max(0, min(content, available))
    }

    /// What fills the list area when there is nothing to list.
    enum EmptyState: Equatable {
        /// The index hasn't been read yet.
        case loading
        case historyOff
        case noConversations
        case noMatches(query: String)
    }

    /// nil when there are rows to show. History off wins, then loading, then the query.
    static func emptyState(rowCount: Int, query: String, isSearching: Bool, isIndexLoaded: Bool,
                           historyEnabled: Bool) -> EmptyState? {
        guard rowCount == 0 else { return nil }
        if !historyEnabled { return .historyOff }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return isIndexLoaded ? .noConversations : .loading
        }
        return isSearching ? .loading : .noMatches(query: trimmed)
    }

    /// The bottom line of the page.
    enum Footer: Equatable {
        case undo(title: String)
        case streamingWarning
        case hints
    }

    /// The Undo bar wins while a delete can still be undone; a streaming reply replaces the key hints.
    static func footer(pendingDeletionTitle: String?, isStreaming: Bool) -> Footer {
        if let pendingDeletionTitle { return .undo(title: pendingDeletionTitle) }
        return isStreaming ? .streamingWarning : .hints
    }
}

/// Every string the Recents page shows (history.md §1.3, without em dashes).
enum HistoryRecentsText {
    static let searchPlaceholder = "Search conversations"
    static let clearSearch = "Clear search"
    static let deleteLabel = "Delete"
    static let openLabel = "Open"
    static let undoLabel = "Undo"
    static let undoShortcut = "⌘Z"
    static let streamingWarning = "Opening another conversation stops the current reply."
    static let hints: [(key: String, label: String)] = [("↩", "Open"), ("⌘⌫", "Delete"), ("esc", "Back")]

    static let noConversationsTitle = "No conversations yet"
    static let noConversationsBody = "Your chats with Otto will show up here."
    static let historyOffTitle = "History is off"
    static let historyOffBody = "Otto isn't saving conversations on this Mac."
    static let turnOnHistory = "Turn On History"
    static let noMatchesBody = "Try fewer words or a different spelling."

    static let noticeTitle = "Otto now remembers your chats"
    static let noticeAcknowledge = "Got It"
    static let noticeDecline = "Don't Save History"

    /// Longest title or detail the page draws; the row truncates to one line anyway.
    static let maxTitleLength = 120
    static let maxDetailLength = 200
    static let maxQueryLength = 60

    static func noMatchesTitle(query: String) -> String {
        "No matches for “\(DisplayText.sanitized(query, maxLength: maxQueryLength))”"
    }

    /// Section labels are drawn in small caps style: "TODAY", "PREVIOUS 7 DAYS", "AUGUST 2025".
    static func sectionTitle(_ title: String) -> String {
        title.uppercased()
    }

    static func dateLabel(for row: RecentsRow, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        RecentsDateLabel.label(for: row.updatedAt, now: now, calendar: calendar, locale: locale)
    }

    static func title(of row: RecentsRow) -> String {
        DisplayText.sanitized(row.title, maxLength: maxTitleLength)
    }

    static func detail(of row: RecentsRow) -> String {
        DisplayText.sanitized(row.detail, maxLength: maxDetailLength)
    }

    /// The title with its query matches in bold. A title carrying hidden, control or bidi characters, or one longer
    /// than the page ever draws, loses the bolding and is shown cleaned (the match ranges point into the raw text).
    static func styledTitle(of row: RecentsRow) -> AttributedString {
        let raw = row.title
        guard !row.titleMatches.isEmpty,
              !DisplayText.containsHiddenOrBidi(raw),
              !raw.contains(where: { $0.isNewline }),
              raw.count <= maxTitleLength
        else {
            return AttributedString(title(of: row))
        }
        var result = AttributedString()
        var cursor = raw.startIndex
        for match in row.titleMatches
        where match.lowerBound >= cursor && match.upperBound <= raw.endIndex && !match.isEmpty {
            if cursor < match.lowerBound {
                result += AttributedString(String(raw[cursor..<match.lowerBound]))
            }
            var bold = AttributedString(String(raw[match]))
            bold.inlinePresentationIntent = .stronglyEmphasized
            result += bold
            cursor = match.upperBound
        }
        if cursor < raw.endIndex {
            result += AttributedString(String(raw[cursor...]))
        }
        return result
    }

    /// The bold stretches of `styledTitle(of:)`, in order (tests).
    static func boldRuns(in text: AttributedString) -> [String] {
        text.runs.compactMap { run in
            run.inlinePresentationIntent == .stronglyEmphasized ? String(text[run.range].characters) : nil
        }
    }

    /// VoiceOver: "<title>, <detail>, <date>".
    static func accessibilityLabel(for row: RecentsRow, dateLabel: String) -> String {
        [title(of: row), detail(of: row), dateLabel].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Footer link: "Kept 30 days · Settings", "Kept forever · Settings"; just "Settings" while history is off.
    static func keptLabel(retention: HistoryRetention, historyEnabled: Bool) -> String {
        historyEnabled ? "Kept \(retention.shortLabel) · Settings" : "Settings"
    }

    static func undoMessage(title: String) -> String {
        "Deleted “\(DisplayText.sanitized(title, maxLength: maxTitleLength))”"
    }

    /// The first-run notice body for the current retention.
    static func noticeBody(retention: HistoryRetention) -> String {
        let intro = "Conversations are saved on this Mac only, so you can pick them up with ⌘Y."
        let kept: String
        if retention == .forever {
            kept = "They're kept until you delete them."
        } else {
            kept = "They're deleted after \(retention.shortLabel)."
        }
        return "\(intro) \(kept) You can change this in Settings."
    }
}
