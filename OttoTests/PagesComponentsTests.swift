//
//  PagesComponentsTests.swift
//  OttoTests
//
//  The page components' pure helpers: Recents list items, heights, section and date display, bolded
//  matches, empty states and footer; the Shelf grid, action bar summary and pluralized labels; which drop
//  well lights up and its capacity copy; the Continue chip's text. Plus render checks that host each page
//  on inert controllers.
//

import AppKit
import SwiftUI
import XCTest
@testable import Otto

// MARK: - Fixtures

private struct PagesTestThumbnailer: ShelfThumbnailing {
    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> CGImage? { nil }
}

private enum PagesFixtures {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    static let locale = Locale(identifier: "en_US")

    /// Sunday 27 September 2026, 16:00 UTC.
    static var now: Date {
        date(2026, 9, 27, 16, 0)
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return calendar.date(from: components) ?? .distantPast
    }

    static func row(
        _ title: String,
        detail: String = "Short answer: yes.",
        updatedAt: Date = now,
        matches: [Range<String.Index>] = [],
        hasAttachments: Bool = false,
        isCurrent: Bool = false
    ) -> RecentsRow {
        RecentsRow(id: UUID(), title: title, titleMatches: matches, detail: detail, updatedAt: updatedAt,
                   hasAttachments: hasAttachments, isCurrent: isCurrent)
    }

    static func summary(_ title: String, preview: String = "A preview", updatedAt: Date = now) -> ConversationSummary {
        ConversationSummary(id: UUID(), title: title, preview: preview, searchText: title + " " + preview,
                            createdAt: updatedAt, updatedAt: updatedAt, messageCount: 2, attachmentCount: 0,
                            model: nil, blobs: [:], fileBytes: 0, fileModifiedAt: updatedAt)
    }

    static func shelfItem(
        _ name: String,
        type: String? = "public.plain-text",
        isDirectory: Bool = false,
        availability: ShelfItem.Availability = .available
    ) -> ShelfItem {
        ShelfItem(id: UUID(), origin: .reference, bookmark: Data(), lastKnownPath: "/tmp/" + name, name: name,
                  contentTypeIdentifier: type, byteCount: 1_000, isDirectory: isDirectory,
                  addedAt: now, availability: availability)
    }
}

@MainActor
final class PagesComponentsTests: XCTestCase {
    // MARK: - Recents list

    func testItemsPutEachSectionTitleBeforeItsRows() {
        let today = PagesFixtures.row("Swift actor reentrancy")
        let older = PagesFixtures.row("Summarize this PDF", updatedAt: PagesFixtures.date(2026, 9, 26, 9, 0))
        let sections = RecentsSection.group([today, older], now: PagesFixtures.now, calendar: PagesFixtures.calendar)

        let items = HistoryRecentsLayout.items(rows: [today, older], sections: sections)

        XCTAssertEqual(items, [
            .section(id: "today", title: "Today"),
            .row(today),
            .section(id: "yesterday", title: "Yesterday"),
            .row(older),
        ])
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "item ids must be unique for List and scrollTo")
    }

    func testItemsAreTheRankedRowsWhileSearching() {
        let first = PagesFixtures.row("Actor isolation")
        let second = PagesFixtures.row("Reentrancy notes")

        let items = HistoryRecentsLayout.items(rows: [first, second], sections: [])

        XCTAssertEqual(items, [.row(first), .row(second)])
    }

    func testItemsSkipEmptySections() {
        let row = PagesFixtures.row("Only one")
        let sections = [
            RecentsSection(id: "today", title: "Today", rows: []),
            RecentsSection(id: "7d", title: "Previous 7 Days", rows: [row]),
        ]

        XCTAssertEqual(HistoryRecentsLayout.items(rows: [row], sections: sections), [
            .section(id: "7d", title: "Previous 7 Days"),
            .row(row),
        ])
    }

    func testListHeightAddsRowsTitlesAndInsetsUpToTheAvailableHeight() {
        let items: [HistoryRecentsLayout.Item] = [
            .section(id: "today", title: "Today"),
            .row(PagesFixtures.row("One")),
            .row(PagesFixtures.row("Two")),
        ]

        XCTAssertEqual(HistoryRecentsLayout.listHeight(for: items, available: 1_000), 26 + 50 + 50 + 4)
        XCTAssertEqual(HistoryRecentsLayout.listHeight(for: items, available: 100), 100)
        XCTAssertEqual(HistoryRecentsLayout.listHeight(for: [], available: 400), 0)
    }

    func testAvailableListHeightLeavesRoomForSearchFooterAndPadding() {
        // history.md §2.2: 560 − header 40 − 10 − 36 − 10 − 8 − 22 − 16 = 418.
        XCTAssertEqual(HistoryRecentsLayout.availableListHeight(pageHeight: HistoryRecentsLayout.defaultPageHeight), 418)
        XCTAssertEqual(HistoryRecentsLayout.availableListHeight(pageHeight: 50), 0)
    }

    // MARK: - Sections and dates as displayed

    func testSectionTitlesDisplayInCapitals() {
        let rows = [
            PagesFixtures.row("Today", updatedAt: PagesFixtures.date(2026, 9, 27, 9, 0)),
            PagesFixtures.row("Yesterday", updatedAt: PagesFixtures.date(2026, 9, 26, 22, 0)),
            PagesFixtures.row("This week", updatedAt: PagesFixtures.date(2026, 9, 23, 12, 0)),
            PagesFixtures.row("This month", updatedAt: PagesFixtures.date(2026, 9, 5, 12, 0)),
            PagesFixtures.row("August", updatedAt: PagesFixtures.date(2026, 8, 12, 12, 0)),
            PagesFixtures.row("Last year", updatedAt: PagesFixtures.date(2025, 8, 12, 12, 0)),
        ]
        let sections = RecentsSection.group(rows, now: PagesFixtures.now, calendar: PagesFixtures.calendar)

        XCTAssertEqual(sections.map { HistoryRecentsText.sectionTitle($0.title) }, [
            "TODAY", "YESTERDAY", "PREVIOUS 7 DAYS", "PREVIOUS 30 DAYS", "AUGUST", "AUGUST 2025",
        ])
    }

    func testRowDateLabels() {
        let calendar = PagesFixtures.calendar
        let now = PagesFixtures.now
        func label(_ date: Date) -> String {
            HistoryRecentsText.dateLabel(for: PagesFixtures.row("t", updatedAt: date), now: now, calendar: calendar,
                                         locale: PagesFixtures.locale)
        }

        XCTAssertEqual(label(PagesFixtures.date(2026, 9, 27, 14, 14)), "2:14 PM")
        XCTAssertEqual(label(PagesFixtures.date(2026, 9, 26, 8, 0)), "Yesterday")
        XCTAssertEqual(label(PagesFixtures.date(2026, 9, 24, 8, 0)), "Thu")
        XCTAssertEqual(label(PagesFixtures.date(2026, 3, 3, 8, 0)), "Mar 3")
        XCTAssertEqual(label(PagesFixtures.date(2025, 3, 3, 8, 0)), "Mar 3, 2025")
    }

    func testRowAccessibilityLabelReadsTitleDetailAndDate() {
        let row = PagesFixtures.row("Swift actor reentrancy", detail: "Every await is a suspension point.")

        XCTAssertEqual(
            HistoryRecentsText.accessibilityLabel(for: row, dateLabel: "2:14 PM"),
            "Swift actor reentrancy, Every await is a suspension point., 2:14 PM"
        )
        XCTAssertEqual(
            HistoryRecentsText.accessibilityLabel(for: PagesFixtures.row("Untitled", detail: ""), dateLabel: "Mon"),
            "Untitled, Mon"
        )
    }

    func testStyledTitleBoldsEveryQueryMatch() throws {
        let summary = PagesFixtures.summary("Swift actor reentrancy and actor hops")
        let row = try XCTUnwrap(HistorySearch.run("actor", in: [summary], currentID: nil).first)

        let styled = HistoryRecentsText.styledTitle(of: row)

        XCTAssertEqual(String(styled.characters), "Swift actor reentrancy and actor hops")
        XCTAssertEqual(HistoryRecentsText.boldRuns(in: styled), ["actor", "actor"])
    }

    func testStyledTitleWithoutAQueryHasNoBold() {
        let styled = HistoryRecentsText.styledTitle(of: PagesFixtures.row("Plain title"))

        XCTAssertEqual(String(styled.characters), "Plain title")
        XCTAssertTrue(HistoryRecentsText.boldRuns(in: styled).isEmpty)
    }

    func testStyledTitleWithHiddenCharactersIsCleanedAndNotBolded() throws {
        let title = "Invoice \u{202E}fdp.exe"
        let summary = PagesFixtures.summary(title)
        let row = try XCTUnwrap(HistorySearch.run("invoice", in: [summary], currentID: nil).first)
        XCTAssertFalse(row.titleMatches.isEmpty)

        let styled = HistoryRecentsText.styledTitle(of: row)

        XCTAssertEqual(String(styled.characters), "Invoice fdp.exe")
        XCTAssertTrue(HistoryRecentsText.boldRuns(in: styled).isEmpty)
        XCTAssertFalse(DisplayText.containsHiddenOrBidi(HistoryRecentsText.detail(of: row)))
    }

    /// history.md §3: a body-only match shows the snippet around it with the match in bold.
    func testStyledDetailBoldsTheQueryInTheSnippet() throws {
        let preview = "The compiler checks isolation, and the actor hops back after every await, so state can change."
        let summary = PagesFixtures.summary("Swift concurrency notes", preview: preview)
        let row = try XCTUnwrap(HistorySearch.run("AWAIT", in: [summary], currentID: nil).first)
        XCTAssertTrue(row.titleMatches.isEmpty, "the title doesn't hold the word")

        let styled = HistoryRecentsText.styledDetail(of: row, query: "AWAIT")

        XCTAssertEqual(String(styled.characters), HistoryRecentsText.detail(of: row))
        XCTAssertEqual(HistoryRecentsText.boldRuns(in: styled), ["await"])
    }

    func testStyledDetailWithoutAQueryHasNoBold() {
        let row = PagesFixtures.row("Plain title", detail: "Every await is a suspension point.")
        XCTAssertTrue(HistoryRecentsText.boldRuns(in: HistoryRecentsText.styledDetail(of: row, query: "")).isEmpty)
        XCTAssertTrue(HistoryRecentsText.boldRuns(in: HistoryRecentsText.styledDetail(of: row, query: "  ")).isEmpty)
        XCTAssertEqual(HistoryRecentsText.boldRuns(in: HistoryRecentsText.styledDetail(of: row, query: "await point")),
                       ["await", "point"])
    }

    func testStyledDetailWithHiddenCharactersIsCleanedAndNotBolded() {
        let row = PagesFixtures.row("Invoice", detail: "Open the invoice \u{202E}fdp.exe")
        let styled = HistoryRecentsText.styledDetail(of: row, query: "invoice")
        XCTAssertEqual(String(styled.characters), HistoryRecentsText.detail(of: row))
        XCTAssertTrue(HistoryRecentsText.boldRuns(in: styled).isEmpty)
    }

    // MARK: - Empty states and footer

    func testEmptyStates() {
        func state(rows: Int = 0, query: String = "", searching: Bool = false, loaded: Bool = true,
                   enabled: Bool = true) -> HistoryRecentsLayout.EmptyState? {
            HistoryRecentsLayout.emptyState(rowCount: rows, query: query, isSearching: searching,
                                            isIndexLoaded: loaded, historyEnabled: enabled)
        }

        XCTAssertNil(state(rows: 3))
        XCTAssertEqual(state(), .noConversations)
        XCTAssertEqual(state(loaded: false), .loading)
        XCTAssertEqual(state(enabled: false), .historyOff)
        XCTAssertEqual(state(query: "tokio", enabled: false), .historyOff)
        XCTAssertEqual(state(query: "  tokio "), .noMatches(query: "tokio"))
        XCTAssertEqual(state(query: "tokio", searching: true), .loading)
        XCTAssertEqual(state(query: "   "), .noConversations)
    }

    func testEmptyStateCopy() {
        XCTAssertEqual(HistoryRecentsText.noMatchesTitle(query: "tokio"), "No matches for “tokio”")
        XCTAssertEqual(HistoryRecentsText.noMatchesTitle(query: "a\u{200B}b"), "No matches for “ab”")
    }

    func testFooterShowsUndoFirstThenTheStreamingWarning() {
        XCTAssertEqual(HistoryRecentsLayout.footer(pendingDeletionTitle: "Q3 plan", isStreaming: true),
                       .undo(title: "Q3 plan"))
        XCTAssertEqual(HistoryRecentsLayout.footer(pendingDeletionTitle: nil, isStreaming: true), .streamingWarning)
        XCTAssertEqual(HistoryRecentsLayout.footer(pendingDeletionTitle: nil, isStreaming: false), .hints)
    }

    /// "↩ Open" and "⌘⌫ Delete" only show when there is a row they act on; an empty list offers only Back, but a
    /// delete that can still be undone keeps its Undo bar.
    func testFooterOffersOnlyBackWithoutARow() {
        XCTAssertEqual(HistoryRecentsLayout.footer(pendingDeletionTitle: nil, isStreaming: false,
                                                   hasSelectableRow: false), .backHint)
        XCTAssertEqual(HistoryRecentsLayout.footer(pendingDeletionTitle: nil, isStreaming: true,
                                                   hasSelectableRow: false), .backHint)
        XCTAssertEqual(HistoryRecentsLayout.footer(pendingDeletionTitle: "Q3 plan", isStreaming: false,
                                                   hasSelectableRow: false), .undo(title: "Q3 plan"))
        XCTAssertEqual(HistoryRecentsText.backHints.map(\.key), ["esc"])
    }

    func testFooterAndUndoCopy() {
        XCTAssertEqual(HistoryRecentsText.keptLabel(retention: .month, historyEnabled: true), "Kept 30 days · Settings")
        XCTAssertEqual(HistoryRecentsText.keptLabel(retention: .forever, historyEnabled: true), "Kept forever · Settings")
        XCTAssertEqual(HistoryRecentsText.keptLabel(retention: .week, historyEnabled: false), "Settings")
        XCTAssertEqual(HistoryRecentsText.undoMessage(title: "Swift actor reentrancy"), "Deleted “Swift actor reentrancy”")
        XCTAssertEqual(HistoryRecentsText.hints.map(\.key), ["↩", "⌘⌫", "esc"])
    }

    func testNoticeBodyFollowsRetention() {
        XCTAssertEqual(
            HistoryRecentsText.noticeBody(retention: .month),
            "Conversations are saved on this Mac only, so you can pick them up with ⌘Y. They're deleted after "
                + "30 days. You can change this in Settings."
        )
        XCTAssertEqual(
            HistoryRecentsText.noticeBody(retention: .forever),
            "Conversations are saved on this Mac only, so you can pick them up with ⌘Y. They're kept until you "
                + "delete them. You can change this in Settings."
        )
        for retention in HistoryRetention.allCases {
            XCTAssertFalse(HistoryRecentsText.noticeBody(retention: retention).contains("—"))
        }
    }

    // MARK: - Continue chip

    func testContinueChipText() {
        XCTAssertEqual(ContinueChip.displayTitle("Swift  actor\nreentrancy"), "Swift actor reentrancy")
        XCTAssertEqual(ContinueChip.displayTitle("Evil \u{202E}txt.exe"), "Evil txt.exe")
        XCTAssertEqual(ContinueChip.helpText(title: "Q3 plan"), "Continue “Q3 plan” (⌘Y, ↩)")
        XCTAssertEqual(ContinueChip.accessibilityLabel(title: "Q3 plan"), "Continue previous conversation: Q3 plan")
        XCTAssertEqual(ContinueChip.displayTitle(String(repeating: "a", count: 300)).count, ContinueChip.maxTitleLength)
    }

    // MARK: - Shelf grid and action bar

    func testGridMatchesTheControllersColumns() {
        XCTAssertEqual(ShelfPageLayout.columns, ShelfController.columns)
        XCTAssertEqual(ShelfPageLayout.gridWidth, 492)
    }

    func testGridHeightGrowsByRowsUpToTwoRowsAndAPeek() {
        XCTAssertEqual(ShelfPageLayout.gridHeight(itemCount: 0), 0)
        XCTAssertEqual(ShelfPageLayout.gridHeight(itemCount: 1), 100)
        XCTAssertEqual(ShelfPageLayout.gridHeight(itemCount: 5), 100)
        XCTAssertEqual(ShelfPageLayout.gridHeight(itemCount: 6), 208)
        XCTAssertEqual(ShelfPageLayout.gridHeight(itemCount: 11), 232)
        XCTAssertEqual(ShelfPageLayout.gridHeight(itemCount: 50), 232)
        XCTAssertFalse(ShelfPageLayout.scrolls(itemCount: 10))
        XCTAssertTrue(ShelfPageLayout.scrolls(itemCount: 11))
    }

    func testActionBarSummary() {
        let locale = PagesFixtures.locale
        XCTAssertEqual(ShelfPageText.summary(itemCount: 5, selectedCount: 0, totalBytes: 12_400_000, locale: locale),
                       "5 items · 12.4 MB")
        XCTAssertEqual(ShelfPageText.summary(itemCount: 1, selectedCount: 0, totalBytes: 2_000_000, locale: locale),
                       "1 item · 2 MB")
        XCTAssertEqual(ShelfPageText.summary(itemCount: 3, selectedCount: 0, totalBytes: 0, locale: locale), "3 items")
        XCTAssertEqual(ShelfPageText.summary(itemCount: 5, selectedCount: 2, totalBytes: 12_400_000, locale: locale),
                       "2 of 5 selected")
    }

    func testActionBarLabelsPluralizeOverTheSelectionOrEveryItem() {
        XCTAssertEqual(ShelfPageText.targetCount(itemCount: 5, selectedCount: 0), 5)
        XCTAssertEqual(ShelfPageText.targetCount(itemCount: 5, selectedCount: 3), 3)

        XCTAssertEqual(ShelfPageText.askLabel(targetCount: 1), "Ask Otto")
        XCTAssertEqual(ShelfPageText.askLabel(targetCount: 3), "Ask Otto about 3")
        XCTAssertEqual(ShelfPageText.shareHelp(targetCount: 1), "Share")
        XCTAssertEqual(ShelfPageText.shareHelp(targetCount: 4), "Share 4 items")
        XCTAssertEqual(ShelfPageText.removeHelp(targetCount: 1), "Remove from Shelf")
        XCTAssertEqual(ShelfPageText.removeHelp(targetCount: 2), "Remove 2 items from Shelf")
    }

    func testTileCaptionsAndSymbols() {
        let image = PagesFixtures.shelfItem("IMG_2041.heic", type: "public.heic")
        let pdf = PagesFixtures.shelfItem("Report.pdf", type: "com.adobe.pdf")
        let folder = PagesFixtures.shelfItem("Assets", type: "public.folder", isDirectory: true)
        let missing = PagesFixtures.shelfItem("notes\u{200B}.md", type: nil, availability: .missing)

        XCTAssertTrue(ShelfPageText.isImage(image))
        XCTAssertFalse(ShelfPageText.isImage(pdf))
        XCTAssertFalse(ShelfPageText.isImage(folder))
        XCTAssertEqual(ShelfPageText.placeholderSymbol(for: image), "photo")
        XCTAssertEqual(ShelfPageText.placeholderSymbol(for: pdf), "doc.richtext")
        XCTAssertEqual(ShelfPageText.placeholderSymbol(for: folder), "folder")
        XCTAssertEqual(ShelfPageText.placeholderSymbol(for: missing), "doc")
        XCTAssertEqual(ShelfPageText.displayName(missing), "notes.md")
        XCTAssertEqual(ShelfPageText.accessibilityLabel(for: missing, isSelected: false), "notes.md, moved or deleted")
        XCTAssertEqual(ShelfPageText.accessibilityLabel(for: folder, isSelected: true), "Assets, folder, selected")
    }

    // MARK: - Drop wells

    /// Tile captions never break right after a hyphen: hyphens are non-breaking, and a name without a space may
    /// break before its extension instead.
    func testShelfCaptionsNeverBreakAtAHyphen() {
        let hyphenated = ShelfPageText.caption(PagesFixtures.shelfItem("meeting-notes.txt"))
        XCTAssertFalse(hyphenated.contains("-"))
        XCTAssertEqual(hyphenated, "meeting\u{2011}notes\u{200B}.txt")
        XCTAssertEqual(ShelfPageText.caption(PagesFixtures.shelfItem("Q3 roadmap.pdf")), "Q3 roadmap.pdf",
                       "a name with a space breaks there")
        XCTAssertEqual(ShelfPageText.caption(PagesFixtures.shelfItem("Assets.v2", isDirectory: true)), "Assets.v2")
        XCTAssertEqual(ShelfPageText.caption(PagesFixtures.shelfItem(".env")), ".env")
        XCTAssertEqual(ShelfPageLayout.imagePlaceholderSize, CGSize(width: 37, height: 45))
    }

    func testTheWellUnderThePointerIsLit() {
        let overShelf = DropSession(zone: .shelf, itemCount: 2, acceptsShelf: true)
        let overAsk = DropSession(zone: .ask, itemCount: 2, acceptsShelf: true)

        XCTAssertEqual(ShelfDropWell.appearance(of: .shelf, in: overShelf), ShelfDropWell.active)
        XCTAssertEqual(ShelfDropWell.appearance(of: .ask, in: overShelf), ShelfDropWell.inactive)
        XCTAssertEqual(ShelfDropWell.appearance(of: .shelf, in: overAsk), ShelfDropWell.inactive)
        XCTAssertEqual(ShelfDropWell.appearance(of: .ask, in: overAsk), ShelfDropWell.active)

        XCTAssertEqual(ShelfDropWell.active.scale, 1.02)
        XCTAssertFalse(ShelfDropWell.active.isDashed)
        XCTAssertEqual(ShelfDropWell.active.strokeWidth, 1, "the dock cards' top-lit 1 pt ring")
        XCTAssertEqual(ShelfDropWell.inactive.opacity, 0.55)
        XCTAssertTrue(ShelfDropWell.inactive.isDashed)
    }

    func testTheZoneRuleLightsTheMatchingWell() {
        let width: CGFloat = 548
        for x in stride(from: CGFloat(0), through: width, by: 20) {
            let zone = DropZone.zone(forX: x, width: width, acceptsShelf: true)
            let session = DropSession(zone: zone, itemCount: 1, acceptsShelf: true)
            let lit = [DropZone.shelf, .ask].filter { ShelfDropWell.appearance(of: $0, in: session).isActive }
            XCTAssertEqual(lit, [x < width / 2 ? .shelf : .ask], "x = \(x)")
        }
    }

    func testShelfWellCapacityCopy() {
        XCTAssertEqual(ShelfDropWell.shelfSubtitle(itemCount: 1, shelfCount: 0), "1 file · drag out anytime")
        XCTAssertEqual(ShelfDropWell.shelfSubtitle(itemCount: 3, shelfCount: 10), "3 files · drag out anytime")
        XCTAssertEqual(ShelfDropWell.shelfSubtitle(itemCount: 2, shelfCount: 48), "2 files · drag out anytime")
        XCTAssertEqual(ShelfDropWell.shelfSubtitle(itemCount: 3, shelfCount: 48), "Shelf is full")
        XCTAssertFalse(ShelfDropWell.shelfIsOverLimit(itemCount: 2, shelfCount: 48))
        XCTAssertTrue(ShelfDropWell.shelfIsOverLimit(itemCount: 3, shelfCount: 48))
    }

    func testAskWellCapacityCopy() {
        XCTAssertEqual(ShelfDropWell.askSubtitle(itemCount: 3, remainingCapacity: 10), "Attach to your message")
        XCTAssertEqual(ShelfDropWell.askSubtitle(itemCount: 12, remainingCapacity: 10), "Up to 10 items")
        XCTAssertEqual(ShelfDropWell.askSubtitle(itemCount: 2, remainingCapacity: 1), "Up to 1 item")
        XCTAssertEqual(ShelfDropWell.askSubtitle(itemCount: 1, remainingCapacity: 0), "No room for more attachments")
        XCTAssertFalse(ShelfDropWell.askIsOverCapacity(itemCount: 10, remainingCapacity: 10))
        XCTAssertTrue(ShelfDropWell.askIsOverCapacity(itemCount: 11, remainingCapacity: 10))
    }

    // MARK: - Rendering on inert controllers

    private func host<V: View>(_ view: V, width: CGFloat = NotchMetrics.openWidth) -> NSHostingView<some View> {
        let hosting = NSHostingView(rootView: view.frame(width: width).environment(\.colorScheme, .dark))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    func testRecentsViewRendersSeededConversations() throws {
        let settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        let chat = ChatSession(settings: settings, makeClient: { MockLLMClient(latencyScale: 0) })
        let history = HistoryController(settings: settings, chat: chat, store: ConversationStore(location: .inMemory),
                                        now: { PagesFixtures.now })
        let recents = RecentsState(history: history)
        recents.calendar = PagesFixtures.calendar
        history.debugSeed(summaries: [
            PagesFixtures.summary("Swift actor reentrancy"),
            PagesFixtures.summary("Summarize this PDF", updatedAt: PagesFixtures.date(2026, 9, 20, 10, 0)),
        ], continuation: nil)
        recents.activate(preferred: nil)
        XCTAssertEqual(recents.rows.count, 2)

        var opened: [UUID] = []
        let view = RecentsView(
            recents: recents,
            history: history,
            settings: settings.history,
            isStreaming: false,
            actions: RecentsView.Actions(
                open: { opened.append($0) }, delete: { _ in }, undoDelete: {}, openSettings: {},
                turnOnHistory: {}, acknowledgeNotice: {}, declineHistory: {}
            )
        )
        let hosting = host(view)

        XCTAssertGreaterThan(hosting.fittingSize.height, HistoryRecentsLayout.chrome)
        XCTAssertLessThanOrEqual(hosting.fittingSize.height, HistoryRecentsLayout.defaultPageHeight + 1)
        XCTAssertTrue(opened.isEmpty)
    }

    func testShelfViewRendersItemsAndTheEmptyState() throws {
        let settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        let store = ShelfStore(directory: nil, thumbnailer: PagesTestThumbnailer())
        let controller = ShelfController(store: store, settings: settings)

        let empty = host(ShelfView(controller: controller))
        XCTAssertEqual(empty.fittingSize.height, 10 + ShelfPageLayout.emptyStateHeight + 16, accuracy: 1)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OttoPagesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let urls = try (1...6).map { index -> URL in
            let url = folder.appendingPathComponent("note-\(index).txt")
            try Data("note \(index)".utf8).write(to: url)
            return url
        }
        XCTAssertEqual(controller.add(fileURLs: urls).added.count, 6)

        let filled = host(ShelfView(controller: controller))
        let expected = 10 + ShelfPageLayout.gridHeight(itemCount: 6) + 10 + ShelfPageLayout.actionBarHeight + 16
        XCTAssertEqual(filled.fittingSize.height, expected, accuracy: 1)
    }

    /// Soft focus and a Shelf drop never give the grid the keyboard (SPEC-v2 §4.4, §4.7): a ⌫, ⌘C or Space typed
    /// for the user's own app must not remove tiles, replace the clipboard or open Quick Look.
    func testShelfGridTakesTheKeyboardOnlyWhileEngaged() {
        XCTAssertFalse(ShelfPageFocus.takesFocus(onRequest: true, isEngaged: false), "soft focus bumps focusRequest")
        XCTAssertTrue(ShelfPageFocus.takesFocus(onRequest: true, isEngaged: true))
        XCTAssertFalse(ShelfPageFocus.takesFocus(onRequest: false, isEngaged: true))
        XCTAssertFalse(ShelfPageFocus.handlesKeys(isEngaged: false), "the key that engages only engages")
        XCTAssertTrue(ShelfPageFocus.handlesKeys(isEngaged: true))
    }

    func testContinueChipIsThirtyPointsTall() {
        let hosting = NSHostingView(rootView: ContinueChip(title: "Swift actor reentrancy", onContinue: {}, onDismiss: {}))
        hosting.layoutSubtreeIfNeeded()

        XCTAssertEqual(hosting.fittingSize.height, ContinueChip.height, accuracy: 0.5)
        XCTAssertLessThanOrEqual(hosting.fittingSize.width, ContinueChip.maxTitleWidth + 120)
    }

    func testDropZonesOverlayRendersBothWells() {
        let overlay = DropZonesOverlay(
            session: DropSession(zone: .shelf, itemCount: 3, acceptsShelf: true),
            shelfCount: 4,
            remainingAttachmentCapacity: 10
        )
        let hosting = NSHostingView(rootView: overlay.frame(width: 548, height: 120))
        hosting.frame = NSRect(x: 0, y: 0, width: 548, height: 120)
        hosting.layoutSubtreeIfNeeded()

        XCTAssertEqual(hosting.fittingSize, CGSize(width: 548, height: 120))
    }
}
