//
//  HistorySearchTests.swift
//  Otto
//
//  Recents search (AND semantics, ranking, snippets, highlight ranges), date sections and date labels.
//

import XCTest
@testable import Otto

private func summary(
    _ title: String,
    preview: String = "",
    searchText: String = "",
    updatedAt: Date,
    attachments: Int = 0
) -> ConversationSummary {
    ConversationSummary(id: UUID(), title: title, preview: preview, searchText: searchText, createdAt: updatedAt,
                        updatedAt: updatedAt, messageCount: 2, attachmentCount: attachments, model: nil, blobs: [:],
                        fileBytes: 0, fileModifiedAt: updatedAt)
}

private func row(_ id: UUID = UUID(), updatedAt: Date) -> RecentsRow {
    RecentsRow(id: id, title: "t", titleMatches: [], detail: "", updatedAt: updatedAt, hasAttachments: false, isCurrent: false)
}

final class HistorySearchTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_500_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    // MARK: Search

    func testTokensSplitOnWhitespaceAndCapAtEight() {
        XCTAssertEqual(HistorySearch.tokens("  swift   actor\treentrancy "), ["swift", "actor", "reentrancy"])
        XCTAssertEqual(HistorySearch.tokens((1...12).map(String.init).joined(separator: " ")).count, 8)
        XCTAssertEqual(HistorySearch.tokens("   "), [])
    }

    func testEmptyQueryListsEverythingNewestFirst() {
        let old = summary("Old", preview: "old preview", updatedAt: base)
        let new = summary("New", preview: "new preview", updatedAt: base.addingTimeInterval(60), attachments: 1)
        let rows = HistorySearch.run("", in: [old, new], currentID: old.id)
        XCTAssertEqual(rows.map(\.id), [new.id, old.id])
        XCTAssertEqual(rows.map(\.detail), ["new preview", "old preview"])
        XCTAssertEqual(rows.map(\.isCurrent), [false, true])
        XCTAssertEqual(rows.map(\.hasAttachments), [true, false])
        XCTAssertTrue(rows.allSatisfy { $0.titleMatches.isEmpty })
    }

    func testEveryWordMustMatchAcrossFields() {
        let a = summary("Swift actors", searchText: "reentrancy explained", updatedAt: base)
        let b = summary("Swift macros", searchText: "expansion", updatedAt: base)
        let c = summary("Cooking", preview: "about swift recipes", updatedAt: base)
        let rows = HistorySearch.run("swift reentrancy", in: [a, b, c], currentID: nil)
        XCTAssertEqual(rows.map(\.id), [a.id])
        XCTAssertEqual(Set(HistorySearch.run("swift", in: [a, b, c], currentID: nil).map(\.id)), [a.id, b.id, c.id])
    }

    func testMatchingIgnoresCaseAndDiacritics() {
        let cafe = summary("Café opening hours", updatedAt: base)
        XCTAssertEqual(HistorySearch.run("cafe", in: [cafe], currentID: nil).map(\.id), [cafe.id])
        XCTAssertEqual(HistorySearch.run("CAFÉ", in: [cafe], currentID: nil).map(\.id), [cafe.id])
    }

    func testTitleMatchesRankFirstThenNewestFirst() {
        let bodyNew = summary("Weekend plans", searchText: "remember the actor meeting", updatedAt: base.addingTimeInterval(300))
        let titleOld = summary("Actor isolation", updatedAt: base)
        let titleNew = summary("Actors and tasks", updatedAt: base.addingTimeInterval(100))
        let rows = HistorySearch.run("actor", in: [bodyNew, titleOld, titleNew], currentID: nil)
        XCTAssertEqual(rows.map(\.id), [titleNew.id, titleOld.id, bodyNew.id])
        XCTAssertEqual(HistorySearch.run("actor", in: [bodyNew, titleOld, titleNew], currentID: nil, limit: 2).count, 2)
    }

    func testBodyMatchShowsASnippetAndTitleRangesAreExact() throws {
        let body = String(repeating: "filler ", count: 20) + "the actor hops back after every await so keep state consistent"
        let item = summary("Await and actors", preview: "preview", searchText: body, updatedAt: base)
        let rows = HistorySearch.run("await", in: [item], currentID: nil)
        let result = try XCTUnwrap(rows.first)
        XCTAssertTrue(result.detail.hasPrefix("…"))
        XCTAssertTrue(result.detail.contains("every await so"))
        XCTAssertEqual(result.titleMatches.map { String(result.title[$0]) }, ["Await"])

        let multi = HistorySearch.titleRanges(of: ["act", "actor"], in: result.title)
        XCTAssertEqual(multi.map { String(result.title[$0]) }, ["actor"], "overlapping ranges merge")
    }

    func testTitleOnlyMatchKeepsThePreview() throws {
        let item = summary("Actor basics", preview: "An actor protects its state.", searchText: "", updatedAt: base)
        let result = try XCTUnwrap(HistorySearch.run("basics", in: [item], currentID: nil).first)
        XCTAssertEqual(result.detail, "An actor protects its state.")
    }

    // MARK: Sections

    func testSectionBoundaries() {
        let now = date(2026, 9, 27, 10)
        let rows = [
            row(updatedAt: date(2026, 9, 27, 0, 0)),     // midnight today
            row(updatedAt: date(2026, 9, 26, 23, 59)),   // yesterday
            row(updatedAt: date(2026, 9, 20, 0, 0)),     // 7 days before today's midnight
            row(updatedAt: date(2026, 9, 19, 23, 59)),   // just outside 7 days
            row(updatedAt: date(2026, 8, 28, 0, 0)),     // 30 days
            row(updatedAt: date(2026, 8, 27, 23, 0)),    // older, this year
            row(updatedAt: date(2025, 8, 3)),            // older, last year
        ]
        let sections = RecentsSection.group(rows, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.id), ["today", "yesterday", "7d", "30d", "2026-08", "2025-08"])
        XCTAssertEqual(sections.map(\.title), ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "August", "August 2025"])
        XCTAssertEqual(sections.map(\.rows.count), [1, 1, 1, 2, 1, 1])
    }

    func testFutureDatesCountAsToday() {
        let now = date(2026, 9, 27, 10)
        let sections = RecentsSection.group([row(updatedAt: now.addingTimeInterval(86_400))], now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.id), ["today"])
    }

    // MARK: Date labels

    func testDateLabelsForEachBucket() {
        let now = date(2026, 9, 27, 18)
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(RecentsDateLabel.label(for: date(2026, 9, 27, 14, 14), now: now, calendar: calendar, locale: locale), "2:14 PM")
        XCTAssertEqual(RecentsDateLabel.label(for: date(2026, 9, 26, 9), now: now, calendar: calendar, locale: locale), "Yesterday")
        XCTAssertEqual(RecentsDateLabel.label(for: date(2026, 9, 22, 9), now: now, calendar: calendar, locale: locale), "Tue")
        XCTAssertEqual(RecentsDateLabel.label(for: date(2026, 3, 3, 9), now: now, calendar: calendar, locale: locale), "Mar 3")
        XCTAssertEqual(RecentsDateLabel.label(for: date(2025, 3, 3, 9), now: now, calendar: calendar, locale: locale), "Mar 3, 2025")
    }
}
