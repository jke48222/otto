//
//  NotchViewModel+Shelf.swift
//  Otto
//
//  Drop routing over the open notch (§4.7) and the Shelf page's hand-offs (§6.11): the left well keeps files on
//  the Shelf without taking focus, the right well attaches them to the message, and "Ask Otto" on Shelf items
//  moves them into the composer.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

extension NotchViewModel {
    // MARK: - Drop routing (§4.7)

    /// The drop delegate reports the drag over the shape (nil when it leaves).
    func updateDropSession(_ session: DropSession?) {
        setDropSession(session)
    }

    /// `.shelf` keeps the items on the Shelf (Shelf page, new tiles selected, the landing hold, no focus); `.ask`
    /// attaches them to the message on Chat (focused). Returns false when nothing in the drop can be used.
    func performDrop(_ providers: [NSItemProvider], zone: DropZone) -> Bool {
        setDropSession(nil)
        isDropTargeted = false
        let toShelf = zone == .shelf && settings.shelf.enabled
        guard toShelf else {
            if route != .chat { navigate(to: .chat) }
            return handleDrop(providers)
        }
        guard providers.contains(where: Self.isShelfLoadable) else { return false }
        if !isOpen {
            open(reason: .drag, focus: false)
        }
        navigate(to: .shelf)
        // Loading can outlast the drag-open's drop settle (a Photos export, a promised file from a browser): the
        // landing hold covers the load too, so a drag-opened notch never folds up before its tiles land. The hold
        // belongs to this drop and is let go when it lands, fails or times out; one stalled drop never keeps the
        // notch held after later drops have landed.
        let dropID = UUID()
        shelfDropsInFlight.insert(dropID)
        setHold(.shelfLanding, true)
        let shelf = self.shelf
        nonisolated(unsafe) let items = providers
        let timeout = attachmentLoadTimeout
        let name = Self.shelfDropName(providers)
        Task { [weak self] in
            let result = await Self.race({ await shelf.add(providers: items) }, timeout: timeout)
            if let result {
                shelf.beginLandingHold(selecting: result.added)
            } else {
                self?.transientError = AttachmentError.unreadable(name: name).localizedDescription
            }
            self?.shelfDropDidSettle(dropID)
        }
        return true
    }

    /// The Shelf's own landing hold has taken over (or the load failed or timed out): the drop lets go of its hold,
    /// and the last one in flight releases `.shelfLanding`. A drop a close already let go of changes nothing.
    private func shelfDropDidSettle(_ dropID: UUID) {
        guard shelfDropsInFlight.remove(dropID) != nil else { return }
        if shelfDropsInFlight.isEmpty {
            setHold(.shelfLanding, false)
        }
    }

    private static func shelfDropName(_ providers: [NSItemProvider]) -> String {
        guard providers.count == 1, let name = providers.first?.suggestedName, !name.isEmpty else {
            return "the dropped items"
        }
        return name
    }

    // MARK: - Shelf page

    /// ⌘↩ / "Ask Otto" on the Shelf: the items' files go into the composer (through `shelf.onAskAbout`).
    func askAboutShelfItems(_ ids: Set<UUID>) {
        shelf.askAbout(ids)
    }

    /// ⌘V on the Shelf page: the files on the clipboard become tiles, selected.
    func pasteToShelf() {
        let result = shelf.pasteFromClipboard()
        if !result.added.isEmpty {
            shelf.beginLandingHold(selecting: result.added)
        }
    }

    // MARK: - Wiring

    func installShelfFeatures() {
        shelf.onAskAbout = { [weak self] urls in
            self?.askAboutShelfFiles(urls)
        }
    }

    static let foldersNotSupportedMessage = "Otto can read files, not folders."

    /// Folders are skipped with a note; the files are attached on Chat, focused.
    private func askAboutShelfFiles(_ urls: [URL]) {
        let files = urls.filter { !Self.isDirectory($0) }
        if files.count < urls.count {
            transientError = Self.foldersNotSupportedMessage
        }
        guard !files.isEmpty else { return }
        if isOpen {
            navigate(to: .chat)
            engage()
            requestFocus()
        } else {
            open(reason: .programmatic, focus: true)
        }
        addFiles(files)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// The Shelf keeps files and images (links and plain text go to the Ask well instead).
    private static func isShelfLoadable(_ provider: NSItemProvider) -> Bool {
        [UTType.fileURL, .image].contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
    }
}
