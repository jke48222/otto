//
//  ShelfController.swift
//  Otto
//
//  Everything the Shelf page does with its items: selection (click, ⌘-click, ⇧-click ranges, arrow keys
//  over the 5-column grid), open, reveal, copy, remove, share, Quick Look, paste, Ask Otto, and drags out
//  to other apps. It also owns the states that keep the notch open (a drag in flight, the share picker,
//  Quick Look, the 1.5 s after a Shelf drop); the view model reads them through `onHoldsChanged`.
//

import AppKit
import Foundation
import Observation
import os

@MainActor @Observable final class ShelfController: ShelfTileInteraction, ShelfTileHosting {
    enum MoveDirection: Sendable { case left, right, up, down }

    /// The Shelf grid's column count; ↑ and ↓ move by one row.
    static let columns = 5
    /// How long the notch stays open after a Shelf drop.
    static let landingHoldDuration: Duration = .milliseconds(1500)

    let store: ShelfStore
    private(set) var selection: Set<UUID> = []
    private(set) var isDraggingOut = false
    private(set) var isSharing = false
    private(set) var isShowingQuickLook = false
    private(set) var isHoldingLanding = false
    /// A tile's context menu is open (outside clicks shouldn't close the notch under it).
    private(set) var isShowingContextMenu = false
    let quickLook: ShelfQuickLookController

    // Callbacks the VM sets:
    @ObservationIgnored var onAskAbout: (([URL]) -> Void)?
    @ObservationIgnored var onHoldsChanged: (() -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?

    /// Seams for tests: opening and revealing files, the pasteboard for Copy and Paste, and the landing hold.
    @ObservationIgnored var openFile: (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }
    @ObservationIgnored var revealFiles: ([URL]) -> Void = { urls in
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
    @ObservationIgnored var pasteboard: NSPasteboard = .general
    @ObservationIgnored var landingHoldDuration: Duration = ShelfController.landingHoldDuration

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let sharing = ShelfSharingController()
    /// The end of the last ⇧ range, which ⇧-arrows move.
    @ObservationIgnored private var cursor: UUID?
    /// The fixed end of ⇧ ranges: the last item clicked or moved to without ⇧.
    @ObservationIgnored private var anchor: UUID?
    @ObservationIgnored private var landingTask: Task<Void, Never>?
    @ObservationIgnored private let menuTracker = MenuTracker()

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Shelf")

    init(store: ShelfStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        quickLook = ShelfQuickLookController()

        sharing.onSharingChange = { [weak self] sharing in
            self?.setHold(\.isSharing, sharing)
        }
        sharing.onError = { [weak self] message in
            self?.onError?(message)
        }
        quickLook.onVisibilityChange = { [weak self] showing in
            self?.setHold(\.isShowingQuickLook, showing)
        }
        store.onItemsRemoved = { [weak self] ids in
            self?.forget(ids)
        }
        menuTracker.onChange = { [weak self] open in
            self?.setHold(\.isShowingContextMenu, open)
        }
    }

    // MARK: - Adding

    /// A Shelf drop: files by reference, image data as owned copies. Reports what couldn't be added
    /// through `onError`. The caller routes to the Shelf and calls `beginLandingHold(selecting:)`.
    func add(providers: [NSItemProvider]) async -> ShelfAddResult {
        let loaded = await ShelfIngest.load(providers)
        let outcome = await store.ingestReporting(loaded.inputs)
        let loadErrors = loaded.errors.map { ($0 as? ShelfError) ?? .unreadable(name: "The dropped item") }
        report(outcome.result, errors: loadErrors + outcome.errors)
        return outcome.result
    }

    /// Services "Add to Otto Shelf" and ⌘V: references to the user's files and folders.
    func add(fileURLs: [URL]) -> ShelfAddResult {
        let outcome = store.addReferences(fileURLs)
        report(outcome.result, errors: outcome.errors)
        return outcome.result
    }

    /// ⌘V on the Shelf page: the files on the clipboard (Finder's Copy). Anything else on the clipboard
    /// is left alone.
    func pasteFromClipboard() -> ShelfAddResult {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
        guard !urls.isEmpty else {
            onError?(Self.noFilesToPasteMessage)
            return ShelfAddResult(added: [], duplicates: 0, rejectedForLimit: 0)
        }
        return add(fileURLs: urls)
    }

    /// After a Shelf drop: selects the new tiles and keeps the notch open for 1.5 s.
    func beginLandingHold(selecting ids: [UUID]) {
        let present = ids.filter { store.item(for: $0) != nil }
        if !present.isEmpty {
            selection = Set(present)
            anchor = present.first
            cursor = present.last
        }
        landingTask?.cancel()
        setHold(\.isHoldingLanding, true)
        let duration = landingHoldDuration
        landingTask = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.landingTask = nil
            self?.setHold(\.isHoldingLanding, false)
        }
    }

    // MARK: - Selection

    /// Click selects only `id`; ⌘-click toggles it; ⇧-click selects the range from the anchor to `id`.
    func select(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        guard store.item(for: id) != nil else { return }
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.shift) {
            let start = anchor.flatMap { store.item(for: $0) != nil ? $0 : nil } ?? id
            selection = range(from: start, to: id)
            anchor = start
            cursor = id
        } else if modifiers.contains(.command) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            anchor = id
            cursor = id
        } else {
            selection = [id]
            anchor = id
            cursor = id
        }
    }

    /// Arrow keys over the 5-column grid. Without a selection, any arrow selects the first item. With
    /// `extending` (⇧), the selection becomes the range from the anchor to the new position.
    func moveSelection(_ direction: MoveDirection, extending: Bool) {
        let ids = store.items.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = cursor.flatMap({ ids.firstIndex(of: $0) }) else {
            let first = ids[0]
            selection = [first]
            anchor = first
            cursor = first
            return
        }
        let target: Int
        switch direction {
        case .left: target = max(0, current - 1)
        case .right: target = min(ids.count - 1, current + 1)
        case .up: target = current - Self.columns >= 0 ? current - Self.columns : current
        case .down: target = min(ids.count - 1, current + Self.columns)
        }
        let id = ids[target]
        if extending {
            let start = anchor.flatMap { ids.contains($0) ? $0 : nil } ?? ids[current]
            selection = range(from: start, to: id)
            anchor = start
        } else {
            selection = [id]
            anchor = id
        }
        cursor = id
    }

    func selectAll() {
        let ids = store.items.map(\.id)
        selection = Set(ids)
        anchor = ids.first
        cursor = ids.last
    }

    func clearSelection() {
        selection = []
        anchor = nil
        cursor = nil
    }

    /// The selection, or every item when nothing is selected (the action bar's targets).
    var targetIDs: Set<UUID> {
        let all = Set(store.items.map(\.id))
        let selected = selection.intersection(all)
        return selected.isEmpty ? all : selected
    }

    // MARK: - Actions

    /// Resolved URLs in shelf order; items whose files were moved to the Trash or deleted are skipped.
    func urls(for ids: Set<UUID>) -> [URL] {
        store.items.filter { ids.contains($0.id) }.compactMap { store.url(for: $0.id) }
    }

    func open(_ ids: Set<UUID>) {
        let urls = resolvedURLs(for: ids)
        urls.forEach(openFile)
    }

    /// ⌥⌘R: selects the files in Finder.
    func reveal(_ ids: Set<UUID>) {
        let urls = resolvedURLs(for: ids)
        guard !urls.isEmpty else { return }
        revealFiles(urls)
    }

    /// ⌘C: the files themselves (Finder can paste them), unmarked.
    func copy(_ ids: Set<UUID>) {
        let urls = resolvedURLs(for: ids)
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        if !pasteboard.writeObjects(urls.map { $0 as NSURL }) {
            onError?(Self.copyFailedMessage)
        }
    }

    /// Removes the items from the shelf. Otto's own copies are deleted; the user's files are untouched.
    func remove(_ ids: Set<UUID>) {
        store.remove(ids: ids)
    }

    func share(_ ids: Set<UUID>, from anchor: NSView) {
        let urls = resolvedURLs(for: ids)
        guard !urls.isEmpty else { return }
        sharing.show(urls: urls, relativeTo: anchor.bounds, of: anchor)
    }

    /// Space: previews the items, or closes the preview when it is showing.
    func toggleQuickLook(_ ids: Set<UUID>) {
        if quickLook.isShowing {
            quickLook.hide()
            return
        }
        let urls = resolvedURLs(for: ids)
        guard !urls.isEmpty else { return }
        quickLook.show(urls: urls)
    }

    /// ⌘↩ / "Ask Otto": hands the resolved URLs to the view model (which skips folders and attaches files).
    func askAbout(_ ids: Set<UUID>) {
        let urls = resolvedURLs(for: ids)
        guard !urls.isEmpty else { return }
        onAskAbout?(urls)
    }

    // MARK: - ShelfTileInteraction

    func tileClicked(_ id: UUID, modifiers: NSEvent.ModifierFlags, clickCount: Int) {
        guard clickCount >= 2 else {
            select(id, modifiers: modifiers)
            return
        }
        if selection.contains(id) {
            open(selection)
        } else {
            select(id, modifiers: [])
            open([id])
        }
    }

    func contextMenu(for id: UUID) -> NSMenu? {
        makeContextMenu(for: id, anchor: nil)
    }

    func dragItems(startingAt id: UUID) -> [(url: URL, image: NSImage?)] {
        dragPlan(startingAt: id).items
    }

    func dragWillBegin() {
        setHold(\.isDraggingOut, true)
    }

    /// The dragged items leave the shelf once they landed somewhere (operation != []), unless Settings →
    /// "Keep items after dragging them out" is on. Owned bytes stay a while so the receiver can finish
    /// copying them.
    func dragDidEnd(ids: Set<UUID>, operation: NSDragOperation) {
        setHold(\.isDraggingOut, false)
        guard !operation.isEmpty, !settings.shelf.keepAfterDragOut, !ids.isEmpty else { return }
        Self.logger.info("Dragged \(ids.count, privacy: .public) shelf items out")
        store.remove(ids: ids, keepingOwnedBytesFor: ShelfStore.dragOutPurgeDelay)
    }

    // MARK: - ShelfTileHosting

    /// Drags the whole selection when `id` is part of it, otherwise just `id` (which becomes the
    /// selection). Missing items are skipped. Move is offered only when every item is Otto's own copy.
    func dragPlan(startingAt id: UUID) -> ShelfDragPlan {
        if !selection.contains(id) {
            select(id, modifiers: [])
        }
        var ids: [UUID] = []
        var items: [(url: URL, image: NSImage?)] = []
        var allOwned = true
        for item in store.items where selection.contains(item.id) {
            guard let url = store.url(for: item.id) else { continue }
            ids.append(item.id)
            items.append((url: url, image: store.thumbnail(for: item.id)))
            if !store.isOwnedCopy(item.id, at: url) {
                allOwned = false
            }
        }
        let operations = allOwned && !items.isEmpty ? ShelfDragPlan.ownedOperations : ShelfDragPlan.referenceOperations
        return ShelfDragPlan(ids: ids, items: items, outsideOperations: operations)
    }

    func contextMenu(for id: UUID, anchor: NSView) -> NSMenu? {
        makeContextMenu(for: id, anchor: anchor)
    }

    // MARK: - Messages

    static let noFilesToPasteMessage = "There are no files on the clipboard. Copy them in Finder first."
    static let copyFailedMessage = "Couldn't copy the files to the clipboard."

    static func missingMessage(for name: String) -> String {
        "\(name) was moved or deleted."
    }

    static func missingMessage(count: Int) -> String {
        "\(count) items were moved or deleted."
    }

    // MARK: - Private

    /// URLs for an action; tells the user when some items can't be found.
    private func resolvedURLs(for ids: Set<UUID>) -> [URL] {
        let targets = store.items.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return [] }
        var urls: [URL] = []
        var missing: [ShelfItem] = []
        for item in targets {
            if let url = store.url(for: item.id) {
                urls.append(url)
            } else {
                missing.append(item)
            }
        }
        if let first = missing.first {
            onError?(missing.count == 1 ? Self.missingMessage(for: first.name) : Self.missingMessage(count: missing.count))
        }
        return urls
    }

    private func report(_ result: ShelfAddResult, errors: [ShelfError]) {
        if result.rejectedForLimit > 0 {
            onError?(ShelfError.full.errorDescription ?? "")
        } else if let error = errors.first, let message = error.errorDescription {
            onError?(message)
        }
        Self.logger.info("Shelf add: \(result.added.count, privacy: .public) added, \(result.duplicates, privacy: .public) duplicates, \(result.rejectedForLimit, privacy: .public) over the limit, \(errors.count, privacy: .public) failed")
    }

    /// Items between `start` and `end` in grid order, both included.
    private func range(from start: UUID, to end: UUID) -> Set<UUID> {
        let ids = store.items.map(\.id)
        guard let first = ids.firstIndex(of: start), let last = ids.firstIndex(of: end) else { return [end] }
        return Set(ids[min(first, last)...max(first, last)])
    }

    private func forget(_ ids: Set<UUID>) {
        selection.subtract(ids)
        if let anchor, ids.contains(anchor) { self.anchor = nil }
        if let cursor, ids.contains(cursor) { self.cursor = nil }
    }

    private func setHold(_ keyPath: ReferenceWritableKeyPath<ShelfController, Bool>, _ value: Bool) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
        onHoldsChanged?()
    }

    private func makeContextMenu(for id: UUID, anchor: NSView?) -> NSMenu? {
        guard store.item(for: id) != nil else { return nil }
        if !selection.contains(id) {
            select(id, modifiers: [])
        }
        let targets = targetIDs
        let count = targets.count
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = menuTracker

        menu.addItem(action("Open") { [weak self] in self?.open(targets) })
        menu.addItem(action("Quick Look", key: " ") { [weak self] in self?.toggleQuickLook(targets) })
        menu.addItem(action("Reveal in Finder", key: "r", modifiers: [.command, .option]) { [weak self] in
            self?.reveal(targets)
        })
        menu.addItem(action("Copy", key: "c", modifiers: [.command]) { [weak self] in self?.copy(targets) })
        if let anchor {
            menu.addItem(action("Share…") { [weak self, weak anchor] in
                guard let anchor else { return }
                self?.share(targets, from: anchor)
            })
        }
        menu.addItem(.separator())
        let askTitle = count > 1 ? "Ask Otto about \(count)" : "Ask Otto"
        menu.addItem(action(askTitle, key: "\r", modifiers: [.command]) { [weak self] in self?.askAbout(targets) })
        menu.addItem(.separator())
        menu.addItem(action("Remove from Shelf", key: "\u{8}", modifiers: []) { [weak self] in
            self?.remove(targets)
        })
        return menu
    }

    private func action(
        _ title: String,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [],
        perform: @escaping () -> Void
    ) -> NSMenuItem {
        let handler = MenuAction(perform)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = handler
        item.representedObject = handler
        return item
    }

    /// Target of one context-menu item; the item keeps it alive through `representedObject`.
    private final class MenuAction: NSObject {
        private let perform: () -> Void

        init(_ perform: @escaping () -> Void) {
            self.perform = perform
        }

        @objc func invoke() {
            perform()
        }
    }

    /// Reports when a tile's context menu opens and closes.
    private final class MenuTracker: NSObject, NSMenuDelegate {
        var onChange: ((Bool) -> Void)?

        func menuWillOpen(_ menu: NSMenu) {
            onChange?(true)
        }

        func menuDidClose(_ menu: NSMenu) {
            onChange?(false)
        }
    }
}
