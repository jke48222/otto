//
//  RecentsState.swift
//  Otto
//
//  State of the Recents page: the search query (debounced, newest query wins), the rows and date
//  sections it shows, and the keyboard selection.
//

import Foundation
import Observation

@MainActor @Observable final class RecentsState {
    static let searchDebounce: Duration = .milliseconds(120)

    init(history: HistoryController) {
        self.history = history
        query = ""
        rows = []
        sections = []
        isSearching = false
        searchFocusRequest = 0
        history.onSummariesChanged = { [weak self] in
            self?.refresh()
        }
    }

    /// Typing searches after a short pause; a newer query cancels the one in flight.
    var query: String {
        didSet {
            guard query != oldValue, !isResettingQuery else { return }
            runSearch(debounced: true)
        }
    }
    private(set) var rows: [RecentsRow]
    /// Date groups of `rows`; empty while a query is showing (results are one ranked list).
    private(set) var sections: [RecentsSection]
    private(set) var isSearching: Bool
    var selectedID: UUID?
    private(set) var searchFocusRequest: Int

    /// Calendar for the date sections (tests pin it).
    @ObservationIgnored var calendar: Calendar = .current

    /// NotchViewModel.showRecents: clears the query, refreshes the rows, selects `preferred` (the continuation), else
    /// the first row that isn't the current conversation, else the first row, and focuses search.
    func activate(preferred: UUID?) {
        cancelSearch()
        isResettingQuery = true
        query = ""
        isResettingQuery = false
        apply(allRows(), forQuery: "")
        if let preferred, rows.contains(where: { $0.id == preferred }) {
            selectedID = preferred
        } else {
            selectedID = (rows.first { !$0.isCurrent } ?? rows.first)?.id
        }
        focusSearch()
    }

    func deactivate() {
        cancelSearch()
    }

    /// Moves the selection by `delta` rows, stopping at either end.
    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else {
            selectedID = nil
            return
        }
        let current = selectedID.flatMap { id in rows.firstIndex { $0.id == id } }
        let start = current ?? (delta > 0 ? -1 : rows.count)
        let next = min(max(start + delta, 0), rows.count - 1)
        selectedID = rows[next].id
    }

    /// Re-runs the current query (after a save, delete or undo).
    func refresh() {
        if HistorySearch.tokens(query).isEmpty {
            cancelSearch()
            apply(allRows(), forQuery: "")
        } else {
            runSearch(debounced: false)
        }
    }

    func focusSearch() {
        searchFocusRequest += 1
    }

    var selectedRow: RecentsRow? {
        guard let selectedID else { return nil }
        return rows.first { $0.id == selectedID }
    }

    // MARK: - Private

    @ObservationIgnored private let history: HistoryController
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var isResettingQuery = false

    private func allRows() -> [RecentsRow] {
        HistorySearch.run("", in: history.summaries, currentID: history.currentConversationID)
    }

    private func runSearch(debounced: Bool) {
        cancelSearch()
        let text = query
        guard !HistorySearch.tokens(text).isEmpty else {
            apply(allRows(), forQuery: "")
            return
        }
        isSearching = true
        let generation = searchGeneration
        searchTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(for: Self.searchDebounce)
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            let results = await self.history.search(text)
            guard !Task.isCancelled, generation == self.searchGeneration else { return }
            self.apply(results, forQuery: text)
            self.isSearching = false
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration += 1
        isSearching = false
    }

    /// Keeps the selection when its row is still there; otherwise selects the row now at its old position (the
    /// neighbour of a deleted row), or the first row.
    private func apply(_ newRows: [RecentsRow], forQuery text: String) {
        let previousIndex = selectedID.flatMap { id in rows.firstIndex { $0.id == id } }
        rows = newRows
        sections = HistorySearch.tokens(text).isEmpty
            ? RecentsSection.group(newRows, now: history.now(), calendar: calendar)
            : []
        if let selectedID, newRows.contains(where: { $0.id == selectedID }) { return }
        if newRows.isEmpty {
            selectedID = nil
        } else if let previousIndex {
            selectedID = newRows[min(previousIndex, newRows.count - 1)].id
        } else {
            selectedID = newRows.first?.id
        }
    }
}
