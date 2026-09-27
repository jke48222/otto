//
//  HistorySearch.swift
//  Otto
//
//  Recents rows: filtering saved conversations by every word of a query, ranking title matches first,
//  grouping by date and the short date labels. Pure, so it can run off the main actor.
//

import Foundation

struct RecentsRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    /// Ranges in `title` to draw bold; empty without a query.
    let titleMatches: [Range<String.Index>]
    /// The preview, or the snippet around the first body match.
    let detail: String
    let updatedAt: Date
    let hasAttachments: Bool
    let isCurrent: Bool
}

enum HistorySearch {
    static let maxTokens = 8
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Whitespace-separated words, empty ones dropped, at most `maxTokens`.
    static func tokens(_ query: String) -> [String] {
        Array(query.split(whereSeparator: { $0.isWhitespace }).map(String.init).prefix(maxTokens))
    }

    /// Empty query: every summary, newest first. Otherwise every token must appear (case and accent
    /// insensitive) in the title, preview or search text; rows whose title holds every token come first, then
    /// the rest, each group newest first. At most `limit` rows.
    static func run(_ query: String, in summaries: [ConversationSummary], currentID: UUID?,
                    limit: Int = 300) -> [RecentsRow] {
        let words = tokens(query)
        let newestFirst = summaries.sorted { lhs, rhs in
            lhs.updatedAt != rhs.updatedAt ? lhs.updatedAt > rhs.updatedAt : lhs.id.uuidString < rhs.id.uuidString
        }
        guard !words.isEmpty else {
            return newestFirst.prefix(max(0, limit)).map { summary in
                row(summary, matches: [], detail: summary.preview, currentID: currentID)
            }
        }

        var titleRows: [RecentsRow] = []
        var bodyRows: [RecentsRow] = []
        for summary in newestFirst {
            let fields = [summary.title, summary.preview, summary.searchText]
            guard words.allSatisfy({ word in fields.contains { $0.range(of: word, options: options) != nil } }) else {
                continue
            }
            let matches = titleRanges(of: words, in: summary.title)
            let titleHoldsAll = words.allSatisfy { summary.title.range(of: $0, options: options) != nil }
            let detail = bodySnippet(for: words, in: summary.searchText) ?? summary.preview
            let result = row(summary, matches: matches, detail: detail, currentID: currentID)
            if titleHoldsAll { titleRows.append(result) } else { bodyRows.append(result) }
        }
        return Array((titleRows + bodyRows).prefix(max(0, limit)))
    }

    /// Every occurrence of every word in `title`, sorted, overlapping ranges merged.
    static func titleRanges(of words: [String], in title: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for word in words {
            var searchStart = title.startIndex
            while searchStart < title.endIndex,
                  let found = title.range(of: word, options: options, range: searchStart..<title.endIndex) {
                ranges.append(found)
                searchStart = found.upperBound
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    // MARK: - Private

    /// Snippet around the earliest occurrence of any word in the body text.
    private static func bodySnippet(for words: [String], in text: String) -> String? {
        let earliest = words.compactMap { text.range(of: $0, options: options) }.min { $0.lowerBound < $1.lowerBound }
        return earliest.map { ConversationTitler.snippet(in: text, around: $0) }
    }

    private static func row(_ summary: ConversationSummary, matches: [Range<String.Index>], detail: String,
                            currentID: UUID?) -> RecentsRow {
        RecentsRow(id: summary.id, title: summary.title, titleMatches: matches, detail: detail,
                   updatedAt: summary.updatedAt, hasAttachments: summary.attachmentCount > 0,
                   isCurrent: summary.id == currentID)
    }
}

struct RecentsSection: Identifiable, Equatable, Sendable {
    /// "today", "yesterday", "7d", "30d", or "yyyy-MM" for older months.
    let id: String
    let title: String
    let rows: [RecentsRow]

    /// Today / Yesterday / Previous 7 Days / Previous 30 Days / "August" (this year) / "August 2025", keeping the
    /// rows' order. Dates in the future (clock changes) count as today.
    static func group(_ rows: [RecentsRow], now: Date, calendar: Calendar) -> [RecentsSection] {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        let startOfMonth = calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday
        let currentYear = calendar.component(.year, from: now)

        var order: [String] = []
        var titles: [String: String] = [:]
        var buckets: [String: [RecentsRow]] = [:]
        for row in rows {
            let key: String
            let title: String
            if row.updatedAt >= startOfToday {
                (key, title) = ("today", "Today")
            } else if row.updatedAt >= startOfYesterday {
                (key, title) = ("yesterday", "Yesterday")
            } else if row.updatedAt >= startOfWeek {
                (key, title) = ("7d", "Previous 7 Days")
            } else if row.updatedAt >= startOfMonth {
                (key, title) = ("30d", "Previous 30 Days")
            } else {
                let parts = calendar.dateComponents([.year, .month], from: row.updatedAt)
                let year = parts.year ?? currentYear
                let month = parts.month ?? 1
                let symbols = calendar.standaloneMonthSymbols
                let name = symbols.indices.contains(month - 1) ? symbols[month - 1] : String(month)
                key = String(format: "%04d-%02d", year, month)
                title = year == currentYear ? name : "\(name) \(year)"
            }
            if buckets[key] == nil {
                order.append(key)
                titles[key] = title
            }
            buckets[key, default: []].append(row)
        }
        return order.map { RecentsSection(id: $0, title: titles[$0] ?? $0, rows: buckets[$0] ?? []) }
    }
}

enum RecentsDateLabel {
    /// Today: the time ("2:14 PM"); yesterday: "Yesterday"; within 7 days: the weekday ("Mon"); this year:
    /// "Mar 3"; older: "Mar 3, 2025".
    static func label(for date: Date, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfWeek = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)

        let text: String
        if date >= startOfToday {
            text = date.formatted(style.hour().minute())
        } else if date >= startOfYesterday {
            return "Yesterday"
        } else if date >= startOfWeek {
            text = date.formatted(style.weekday(.abbreviated))
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            style = style.month(.abbreviated).day()
            text = date.formatted(style)
        } else {
            style = style.month(.abbreviated).day().year()
            text = date.formatted(style)
        }
        // Formatters put narrow and non-breaking spaces before "PM"; a plain space keeps labels predictable.
        return text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
