//
//  ShelfStore.swift
//  Otto
//
//  The File Shelf's items and where they live. A file the user drops is kept as a bookmark (Otto never
//  moves, copies or deletes the original); bytes with no file of their own (a dragged browser image)
//  are copied into `Owned/<id>/` and quarantined. The index is a 0600 JSON file in `Shelf.noindex`,
//  written through `SecureFile` 250 ms after the last change on a serial utility queue. With no
//  directory the store lives in memory (tests, snapshots, SelfTest, the demo).
//

import AppKit
import CoreServices
import Darwin
import Foundation
import Observation
import os
import UniformTypeIdentifiers

struct ShelfAddResult: Equatable, Sendable {
    var added: [UUID]
    var duplicates: Int
    var rejectedForLimit: Int
}

enum ShelfError: LocalizedError, Equatable {
    case full
    case tooLarge(name: String)
    case storageFull
    case unreadable(name: String)

    var errorDescription: String? {
        switch self {
        case .full:
            return "The shelf holds up to 50 items. Remove some to add more."
        case .tooLarge(let name):
            return "\(name) is too big for the shelf (512 MB max)."
        case .storageFull:
            return "Otto's shelf storage is full (2 GB). Remove some items first."
        case .unreadable(let name):
            return "Otto couldn't read \(name)."
        }
    }
}

@MainActor @Observable final class ShelfStore {
    nonisolated static let maxItems = 50
    static let maxOwnedItemBytes: Int64 = 512 * 1024 * 1024
    static let maxOwnedTotalBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// Thumbnails are 64 × 64 pt at 2x: 128 × 128 px PNGs.
    static let thumbnailSize = CGSize(width: 64, height: 64)
    static let thumbnailScale: CGFloat = 2
    /// The index is written this long after the last change.
    static let saveDelay: Duration = .milliseconds(250)
    /// Owned bytes of an item that was dragged out stay this long, so the app it was dropped on can
    /// finish copying them.
    static let dragOutPurgeDelay: Duration = .seconds(120)

    nonisolated static let indexFileName = "shelf.json"
    nonisolated static let ownedFolderName = "Owned"
    nonisolated static let thumbnailsFolderName = "Thumbnails"
    nonisolated static let indexVersion = 1
    /// A bigger index isn't Otto's (50 items of metadata is a few tens of KB); it is set aside unread.
    nonisolated static let maxIndexBytes = 4 * 1024 * 1024
    nonisolated static let maxThumbnailFileBytes = 2 * 1024 * 1024
    nonisolated static let maxNameLength = 255

    /// `~/Library/Application Support/Otto/Shelf.noindex` (…/Otto/Demo/… with `--demo`), or nil when the
    /// folder is unsafe or can't be created.
    static var defaultDirectory: URL? {
        do {
            return try AppSupport.directory(.shelf)
        } catch {
            logger.error("The shelf folder is unavailable: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// Current items, oldest first (the grid's order).
    private(set) var items: [ShelfItem] = []
    private(set) var isLoaded = false
    var count: Int { items.count }
    /// Sum of the known sizes (folders count as zero; Otto never walks them).
    var totalByteCount: Int64 { items.reduce(0) { $0 + ($1.byteCount ?? 0) } }

    /// Bumped when a thumbnail lands; `thumbnail(for:)` reads it so views redraw.
    private var thumbnailRevision = 0

    /// Called with the ids that left the shelf (by any path), after `items` changed.
    @ObservationIgnored var onItemsRemoved: ((Set<UUID>) -> Void)?

    /// nil → in-memory only.
    @ObservationIgnored let directory: URL?
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let thumbnailer: ShelfThumbnailing
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "com.jalenedusei.otto.shelf", qos: .utility)
    /// Where an in-memory store keeps owned bytes: a private temporary folder, removed on deinit.
    @ObservationIgnored private let scratchDirectory: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var hasUnsavedChanges = false
    @ObservationIgnored private let thumbnailCache = NSCache<NSUUID, NSImage>()
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored private var thumbnailTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var thumbnailAttempted: Set<UUID> = []
    @ObservationIgnored private var purgeTasks: [UUID: Task<Void, Never>] = [:]
    /// Slots and bytes promised to owned copies that are still being written.
    @ObservationIgnored private var reservedSlots = 0
    @ObservationIgnored private var reservedOwnedBytes: Int64 = 0

    nonisolated private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Shelf")

    /// directory == nil → in-memory only (tests, snapshots, SelfTest, the NotchViewModel default).
    init(directory: URL?, fileManager: FileManager = .default, thumbnailer: ShelfThumbnailing = QuickLookShelfThumbnailer()) {
        self.directory = directory
        self.fileManager = fileManager
        self.thumbnailer = thumbnailer
        scratchDirectory = directory == nil
            ? fileManager.temporaryDirectory.appendingPathComponent("OttoShelf-\(UUID().uuidString)", isDirectory: true)
            : nil
        thumbnailCache.countLimit = Self.maxItems * 2
    }

    deinit {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
    }

    // MARK: - Loading

    /// Reads `shelf.json` off the main actor, resolves every bookmark (availability, moved files) and
    /// removes owned copies and thumbnails no item refers to. Items added before the load finished are
    /// kept after the loaded ones. Runs once; later calls return at once.
    func load() async {
        if let loadTask {
            await loadTask.value
            return
        }
        guard !isLoaded else { return }
        let task = Task { await self.readAndMerge() }
        loadTask = task
        await task.value
    }

    private func readAndMerge() async {
        guard let directory else {
            isLoaded = true
            return
        }
        let loaded = await perform { Self.readIndex(in: directory) } ?? []
        let resolutions = await perform { loaded.map { Self.resolve(bookmark: $0.bookmark, lastKnownPath: $0.lastKnownPath) } } ?? []

        var merged: [ShelfItem] = []
        var seenIDs = Set<UUID>()
        var changedOnLoad = false
        for (index, original) in loaded.enumerated() where seenIDs.insert(original.id).inserted {
            var item = original
            if index < resolutions.count {
                item = applied(resolutions[index], to: item)
            }
            if item.bookmark != original.bookmark || item.lastKnownPath != original.lastKnownPath
                || item.origin != original.origin {
                changedOnLoad = true
            }
            merged.append(item)
        }
        let addedEarly = items.filter { seenIDs.insert($0.id).inserted }
        changedOnLoad = changedOnLoad || merged.count != loaded.count || !addedEarly.isEmpty
        items = Array((merged + addedEarly).prefix(Self.maxItems))
        isLoaded = true
        Self.logger.info("Shelf loaded with \(self.items.count, privacy: .public) items")

        let keep = Set(items.map(\.id))
        let ownedRoot = ownedRootURL
        await perform {
            Self.removeOrphans(in: directory.appendingPathComponent(Self.thumbnailsFolderName), keeping: keep)
            if let ownedRoot {
                Self.removeOrphans(in: ownedRoot, keeping: keep)
            }
        }
        if changedOnLoad || hasUnsavedChanges {
            scheduleSave()
        }
    }

    /// Re-resolves every bookmark (the Shelf page calls it on appear): moved files get their new path,
    /// deleted ones turn `.missing`, ones that came back turn `.available` again.
    func refreshAvailability() async {
        let snapshot = items.map { (id: $0.id, bookmark: $0.bookmark, path: $0.lastKnownPath) }
        guard !snapshot.isEmpty else { return }
        guard let resolutions = await perform({ snapshot.map { Self.resolve(bookmark: $0.bookmark, lastKnownPath: $0.path) } }) else {
            return
        }
        var changed = false
        for (entry, resolution) in zip(snapshot, resolutions) {
            guard let index = items.firstIndex(where: { $0.id == entry.id }) else { continue }
            let updated = applied(resolution, to: items[index])
            if updated != items[index] {
                if updated.bookmark != items[index].bookmark || updated.lastKnownPath != items[index].lastKnownPath {
                    changed = true
                }
                items[index] = updated
            }
        }
        if changed {
            scheduleSave()
        }
    }

    // MARK: - Adding

    /// Adds references to the user's files and folders, skipping ones already on the shelf and any past
    /// the 50-item limit. Files that can't be read are skipped (`addReferences` reports them).
    func add(fileURLs: [URL]) -> ShelfAddResult {
        addReferences(fileURLs).result
    }

    /// `add(fileURLs:)` plus the files that couldn't be added and why.
    func addReferences(_ fileURLs: [URL]) -> (result: ShelfAddResult, errors: [ShelfError]) {
        var result = ShelfAddResult(added: [], duplicates: 0, rejectedForLimit: 0)
        var errors: [ShelfError] = []
        var known = Set(items.map { Self.dedupeKey(forPath: $0.lastKnownPath) })
        for url in fileURLs {
            guard url.isFileURL else { continue }
            let standardized = url.standardizedFileURL
            let key = Self.dedupeKey(forPath: standardized.path)
            if known.contains(key) {
                result.duplicates += 1
                continue
            }
            guard items.count + reservedSlots < Self.maxItems else {
                result.rejectedForLimit += 1
                continue
            }
            do {
                let item = try makeReference(to: standardized)
                items.append(item)
                known.insert(key)
                result.added.append(item.id)
                startThumbnail(for: item.id)
            } catch {
                let name = Self.displayName(standardized.lastPathComponent)
                Self.logger.error("Couldn't add \(standardized.path, privacy: .private) to the shelf: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
                errors.append(.unreadable(name: name))
            }
        }
        if !result.added.isEmpty {
            scheduleSave()
        }
        return (result, errors)
    }

    /// Copies a temporary file into `Owned/<id>/`, quarantines the copy and adds it. The caller still owns
    /// (and removes) the temporary file. Throws `ShelfError`.
    func addOwned(copying temporaryURL: URL, suggestedName: String) async throws -> ShelfItem {
        let name = Self.displayName(suggestedName)
        let size: Int64
        do {
            let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw ShelfError.unreadable(name: name) }
            size = Int64(values.fileSize ?? 0)
        } catch {
            throw ShelfError.unreadable(name: name)
        }
        return try await addOwned(name: name, byteCount: size) { destination in
            try Self.copyFileContents(from: temporaryURL, to: destination)
        }
    }

    /// Writes bytes (a pasted or dropped image) into `Owned/<id>/`, quarantines them and adds them. The
    /// file name gets the type's extension when it has none. Throws `ShelfError`.
    func addOwned(data: Data, suggestedName: String, type: UTType) async throws -> ShelfItem {
        var name = Self.displayName(suggestedName)
        if (name as NSString).pathExtension.isEmpty, let fileExtension = type.preferredFilenameExtension {
            name += ".\(fileExtension)"
        }
        return try await addOwned(name: name, byteCount: Int64(data.count)) { destination in
            try SecureFile.write(data, to: destination)
        }
    }

    /// Adds what `ShelfIngest.load` produced, in order: references first-come, owned copies moved into
    /// `Owned/` (their temporary copies are removed either way).
    func ingest(_ inputs: [ShelfInput]) async -> ShelfAddResult {
        await ingestReporting(inputs).result
    }

    /// `ingest(_:)` plus the inputs that couldn't be added and why.
    func ingestReporting(_ inputs: [ShelfInput]) async -> (result: ShelfAddResult, errors: [ShelfError]) {
        var result = ShelfAddResult(added: [], duplicates: 0, rejectedForLimit: 0)
        var errors: [ShelfError] = []
        for input in inputs {
            switch input {
            case .reference(let url):
                let outcome = addReferences([url])
                result.added += outcome.result.added
                result.duplicates += outcome.result.duplicates
                result.rejectedForLimit += outcome.result.rejectedForLimit
                errors += outcome.errors
            case .owned(let temporaryURL, let name):
                do {
                    let item = try await addOwned(copying: temporaryURL, suggestedName: name)
                    result.added.append(item.id)
                } catch ShelfError.full {
                    result.rejectedForLimit += 1
                } catch let error as ShelfError {
                    errors.append(error)
                } catch {
                    errors.append(.unreadable(name: Self.displayName(name)))
                }
                ShelfIngest.discard(input)
            }
        }
        return (result, errors)
    }

    // MARK: - Removing

    /// Owned bytes and thumbnails are deleted; references only leave the shelf (the user's files are never
    /// touched).
    func remove(ids: Set<UUID>) {
        remove(ids: ids, keepingOwnedBytesFor: nil)
    }

    func removeAll() {
        remove(ids: Set(items.map(\.id)))
    }

    /// `remove(ids:)`, but owned bytes are deleted only after `delay` (a drag-out's receiver may still be
    /// copying them). If Otto quits first, the next `load()` removes them as orphans.
    func remove(ids: Set<UUID>, keepingOwnedBytesFor delay: Duration?) {
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        for item in removed {
            thumbnailTasks[item.id]?.cancel()
            thumbnailTasks[item.id] = nil
            thumbnailAttempted.remove(item.id)
            thumbnailCache.removeObject(forKey: item.id as NSUUID)
        }
        let removedIDs = Set(removed.map(\.id))
        let ownedIDs = removed.filter { $0.origin == .owned }.map(\.id)
        let thumbnailsRoot = directory?.appendingPathComponent(Self.thumbnailsFolderName)
        let ownedRoot = ownedRootURL
        ioQueue.async {
            if let thumbnailsRoot {
                for id in removedIDs {
                    Self.removeEntry(named: "\(id.uuidString).png", in: thumbnailsRoot)
                }
            }
        }
        if let ownedRoot, !ownedIDs.isEmpty {
            if let delay {
                for id in ownedIDs {
                    purgeTasks[id] = Task { [weak self] in
                        do { try await Task.sleep(for: delay) } catch { return }
                        self?.purgeTasks[id] = nil
                        self?.ioQueue.async { Self.removeEntry(named: id.uuidString, in: ownedRoot) }
                    }
                }
            } else {
                ioQueue.async {
                    for id in ownedIDs {
                        Self.removeEntry(named: id.uuidString, in: ownedRoot)
                    }
                }
            }
        }
        Self.logger.info("Removed \(removed.count, privacy: .public) shelf items")
        scheduleSave()
        onItemsRemoved?(removedIDs)
    }

    // MARK: - Reading

    func item(for id: UUID) -> ShelfItem? {
        items.first { $0.id == id }
    }

    /// Current URL (re-resolves the bookmark; refreshes stale bookmarks + lastKnownPath). nil when the
    /// item is gone or its file was moved to the Trash or deleted. A `.needsAccess` item still returns its
    /// URL: acting on it is what shows the macOS prompt for Desktop, Documents or Downloads.
    func url(for id: UUID) -> URL? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let current = items[index]
        let resolution = Self.resolve(bookmark: current.bookmark, lastKnownPath: current.lastKnownPath)
        let updated = applied(resolution, to: current)
        if updated != current {
            items[index] = updated
            if updated.bookmark != current.bookmark || updated.lastKnownPath != current.lastKnownPath {
                scheduleSave()
            }
        }
        return resolution.url
    }

    /// True only when `url` is this item's own copy inside `Owned/<id>/`: the one case where a drag may
    /// offer Move. A reference, or an index entry edited to point elsewhere, never qualifies.
    func isOwnedCopy(_ id: UUID, at url: URL) -> Bool {
        guard item(for: id)?.origin == .owned, let ownedRoot = ownedRootURL else { return false }
        let folder = ownedRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let folderPath = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(folderPath)
    }

    /// Memory cache → `Thumbnails/<id>.png` → generated (async; the view redraws when it lands). Until then,
    /// and for files Quick Look can't render, the file type's icon.
    func thumbnail(for id: UUID) -> NSImage? {
        _ = thumbnailRevision
        if let cached = thumbnailCache.object(forKey: id as NSUUID) { return cached }
        guard let item = item(for: id) else { return nil }
        startThumbnail(for: id)
        return icon(for: item)
    }

    // MARK: - Saving

    /// Synchronous final save (applicationWillTerminate). Waits for any write already queued.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        if hasUnsavedChanges, isLoaded {
            writeIndex(synchronously: true)
        } else {
            ioQueue.sync {}
        }
    }

    // MARK: - Private: items

    private var ownedRootURL: URL? {
        (directory ?? scratchDirectory)?.appendingPathComponent(Self.ownedFolderName, isDirectory: true)
    }

    private var ownedByteCount: Int64 {
        items.filter { $0.origin == .owned }.reduce(0) { $0 + ($1.byteCount ?? 0) }
    }

    private func makeReference(to url: URL) throws -> ShelfItem {
        let values = try url.resourceValues(forKeys: [.nameKey, .isDirectoryKey, .fileSizeKey, .contentTypeKey])
        let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.nameKey, .fileSizeKey, .contentTypeKey],
            relativeTo: nil
        )
        let isDirectory = values.isDirectory ?? false
        return ShelfItem(
            id: UUID(),
            origin: .reference,
            bookmark: bookmark,
            lastKnownPath: url.path,
            name: Self.displayName(values.name ?? url.lastPathComponent),
            contentTypeIdentifier: values.contentType?.identifier,
            byteCount: isDirectory ? nil : values.fileSize.map(Int64.init),
            isDirectory: isDirectory,
            addedAt: Date()
        )
    }

    /// Checks the limits, reserves the slot and bytes, writes the copy off the main actor, quarantines it
    /// and appends the item.
    private func addOwned(
        name: String,
        byteCount: Int64,
        write: @escaping @Sendable (URL) throws -> Void
    ) async throws -> ShelfItem {
        guard items.count + reservedSlots < Self.maxItems else { throw ShelfError.full }
        guard byteCount <= Self.maxOwnedItemBytes else { throw ShelfError.tooLarge(name: name) }
        guard ownedByteCount + reservedOwnedBytes + byteCount <= Self.maxOwnedTotalBytes else {
            throw ShelfError.storageFull
        }
        guard let ownedRoot = ownedRootURL else { throw ShelfError.unreadable(name: name) }

        reservedSlots += 1
        reservedOwnedBytes += byteCount
        defer {
            reservedSlots -= 1
            reservedOwnedBytes -= byteCount
        }

        let id = UUID()
        let fileName = Self.safeFileName(name)
        let placed: Result<(URL, Data), Error> = await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: Result {
                    try Self.placeOwnedCopy(id: id, fileName: fileName, in: ownedRoot, write: write)
                })
            }
        }
        let destination: URL
        let bookmark: Data
        switch placed {
        case .success(let value):
            (destination, bookmark) = value
        case .failure(let error):
            Self.logger.error("Couldn't keep a shelf copy: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            if let posix = error as? POSIXError, posix.code == .ENOSPC { throw ShelfError.storageFull }
            throw ShelfError.unreadable(name: name)
        }

        let item = ShelfItem(
            id: id,
            origin: .owned,
            bookmark: bookmark,
            lastKnownPath: destination.path,
            name: name,
            contentTypeIdentifier: UTType(filenameExtension: destination.pathExtension)?.identifier,
            byteCount: byteCount,
            isDirectory: false,
            addedAt: Date()
        )
        items.append(item)
        startThumbnail(for: id)
        scheduleSave()
        return item
    }

    private func applied(_ resolution: Resolution, to item: ShelfItem) -> ShelfItem {
        var item = item
        item.availability = resolution.availability
        if let path = resolution.path {
            item.lastKnownPath = path
        }
        if let bookmark = resolution.refreshedBookmark {
            item.bookmark = bookmark
        }
        // An owned item must live in its own Owned/<id>/ folder; anything else is treated as the user's file.
        if item.origin == .owned, let url = resolution.url, !isOwnedPath(url, id: item.id) {
            item.origin = .reference
        }
        return item
    }

    private func isOwnedPath(_ url: URL, id: UUID) -> Bool {
        guard let ownedRoot = ownedRootURL else { return false }
        let folder = ownedRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let folderPath = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(folderPath)
    }

    // MARK: - Private: thumbnails

    private func icon(for item: ShelfItem) -> NSImage {
        let type = item.contentTypeIdentifier.flatMap(UTType.init) ?? (item.isDirectory ? .folder : .data)
        if let cached = iconCache[type.identifier] { return cached }
        let icon = NSWorkspace.shared.icon(for: type)
        iconCache[type.identifier] = icon
        return icon
    }

    /// Loads the cached PNG, or renders one with the thumbnailer and caches it. One attempt per item per
    /// launch: files Quick Look can't render keep their icon.
    private func startThumbnail(for id: UUID) {
        guard thumbnailTasks[id] == nil, !thumbnailAttempted.contains(id) else { return }
        thumbnailAttempted.insert(id)
        let cacheFile = directory?
            .appendingPathComponent(Self.thumbnailsFolderName, isDirectory: true)
            .appendingPathComponent("\(id.uuidString).png")
        thumbnailTasks[id] = Task { [weak self] in
            defer { self?.thumbnailTasks[id] = nil }
            if let cacheFile, let data = await self?.perform({ Self.readThumbnail(at: cacheFile) }) ?? nil,
               let image = NSImage(data: data) {
                image.size = Self.thumbnailSize
                self?.publishThumbnail(image, for: id)
                return
            }
            guard let self, let url = self.url(for: id) else { return }
            guard let cgImage = await self.thumbnailer.thumbnail(for: url, size: Self.thumbnailSize, scale: Self.thumbnailScale),
                  !Task.isCancelled, self.item(for: id) != nil else { return }
            self.publishThumbnail(NSImage(cgImage: cgImage, size: Self.thumbnailSize), for: id)
            if let cacheFile {
                self.ioQueue.async { Self.writeThumbnail(cgImage, to: cacheFile) }
            }
        }
    }

    private func publishThumbnail(_ image: NSImage, for id: UUID) {
        guard item(for: id) != nil else { return }
        thumbnailCache.setObject(image, forKey: id as NSUUID)
        thumbnailRevision += 1
    }

    // MARK: - Private: persistence

    private func scheduleSave() {
        hasUnsavedChanges = true
        guard directory != nil, isLoaded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.saveDelay) } catch { return }
            self?.saveTask = nil
            self?.writeIndex(synchronously: false)
        }
    }

    private func writeIndex(synchronously: Bool) {
        guard let directory else { return }
        let data: Data
        do {
            data = try Self.encoder.encode(Index(version: Self.indexVersion, items: items))
        } catch {
            Self.logger.error("Couldn't encode the shelf: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            return
        }
        hasUnsavedChanges = false
        let work: @Sendable () -> Void = {
            do {
                let folder = try AppSupport.secureDirectory(directory)
                try SecureFile.write(data, to: folder.appendingPathComponent(Self.indexFileName))
            } catch {
                Self.logger.error("Couldn't save the shelf: \(LoggedError(error), privacy: .public) \(String(describing: error), privacy: .private)")
            }
        }
        if synchronously {
            ioQueue.sync(execute: work)
        } else {
            ioQueue.async(execute: work)
        }
    }

    /// Runs `work` on the shelf's serial queue; nil when it throws.
    private func perform<T>(_ work: @escaping @Sendable () throws -> T) async -> T? {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    Self.logger.error("Shelf storage failed: \(LoggedError(error), privacy: .public) \(String(describing: error), privacy: .private)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private struct Index: Codable {
        var version: Int
        var items: [ShelfItem]
    }

    /// Decodes each item on its own, so one damaged entry doesn't cost the rest.
    private struct LenientIndex: Decodable {
        var version: Int
        var items: [ShelfItem]

        private enum CodingKeys: String, CodingKey { case version, items }
        /// Consumes one entry of any shape.
        private struct Skipped: Decodable {
            init(from decoder: Decoder) throws {}
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            var list = try container.nestedUnkeyedContainer(forKey: .items)
            var decoded: [ShelfItem] = []
            while !list.isAtEnd {
                if let item = try? list.decode(ShelfItem.self) {
                    decoded.append(item)
                } else {
                    _ = try list.decode(Skipped.self)
                }
            }
            items = decoded
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    nonisolated private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Private: disk (serial queue)

    /// The saved items, or [] when there is no index. A symlink, an oversize file, undecodable JSON or a
    /// newer version is renamed aside (`shelf.damaged-<time>.json`) and the shelf starts empty.
    nonisolated private static func readIndex(in directory: URL) -> [ShelfItem] {
        let folder: URL
        do {
            folder = try AppSupport.secureDirectory(directory)
        } catch {
            logger.error("The shelf folder is unsafe: \(LoggedError(error), privacy: .public) \(String(describing: error), privacy: .private)")
            return []
        }
        let url = folder.appendingPathComponent(indexFileName)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return [] }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maxIndexBytes else {
            setAside(url, reason: "not a regular file of a sane size")
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let index = try makeDecoder().decode(LenientIndex.self, from: data)
            guard index.version <= indexVersion else {
                setAside(url, reason: "written by a newer Otto")
                return []
            }
            return index.items.prefix(maxItems).map { item in
                var item = item
                item.name = displayName(item.name)
                return item
            }
        } catch {
            setAside(url, reason: "unreadable")
            return []
        }
    }

    nonisolated private static func setAside(_ url: URL, reason: String) {
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingLastPathComponent().appendingPathComponent("shelf.damaged-\(stamp).json")
        logger.error("Set the shelf index aside: \(reason, privacy: .public)")
        if rename(url.path, aside.path) != 0 {
            unlink(url.path)
        }
    }

    nonisolated private static func placeOwnedCopy(
        id: UUID,
        fileName: String,
        in ownedRoot: URL,
        write: (URL) throws -> Void
    ) throws -> (URL, Data) {
        // The shelf folder itself (or an in-memory store's private temporary folder) first: it may not
        // exist yet, and mkdir doesn't create parents.
        _ = try AppSupport.secureDirectory(ownedRoot.deletingLastPathComponent())
        let root = try AppSupport.secureDirectory(ownedRoot)
        let folder = try AppSupport.secureDirectory(root.appendingPathComponent(id.uuidString, isDirectory: true))
        let destination = folder.appendingPathComponent(fileName)
        do {
            try write(destination)
            try quarantine(destination)
            let bookmark = try destination.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            return (destination, bookmark)
        } catch {
            removeEntry(named: id.uuidString, in: root)
            throw error
        }
    }

    /// Gatekeeper then checks the copy before it opens: its origin (browser image data, mail attachments)
    /// is unknown.
    nonisolated private static func quarantine(_ url: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Otto",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        var target = url
        try target.setResourceValues(values)
    }

    /// Streams `source` into a new 0600 file at `destination` (never overwriting one). Data only: the
    /// source's extended attributes and mode are not carried over.
    nonisolated static func copyFileContents(from source: URL, to destination: URL) throws {
        let input = open(source.path, O_RDONLY | O_CLOEXEC)
        guard input >= 0 else { throw posixError() }
        defer { close(input) }
        let output = open(destination.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw posixError() }
        var failure: Error?
        if fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) != 0 { failure = posixError() }
        if failure == nil, fsync(output) != 0 { failure = posixError() }
        if close(output) != 0, failure == nil { failure = posixError() }
        if let failure {
            unlink(destination.path)
            throw failure
        }
    }

    /// A file name that can't escape its folder: no "/" or ":", no leading dot, at most 200 characters
    /// (the extension kept), never empty.
    nonisolated static func safeFileName(_ name: String) -> String {
        var cleaned = DisplayText.sanitized(name, maxLength: 400)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return "Item" }
        guard cleaned.count > 200 else { return cleaned }
        let fileExtension = (cleaned as NSString).pathExtension
        let keep = fileExtension.isEmpty || fileExtension.count > 20 ? "" : ".\(fileExtension)"
        let stem = ((keep.isEmpty ? cleaned : (cleaned as NSString).deletingPathExtension) as String).prefix(200 - keep.count)
        return String(stem) + keep
    }

    /// Display names come from outside Otto (file names, a browser's suggested name).
    nonisolated static func displayName(_ name: String) -> String {
        let cleaned = DisplayText.sanitized(name, maxLength: maxNameLength)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// References are deduplicated by their resolved, standardized path.
    nonisolated static func dedupeKey(forPath path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    nonisolated private static func readThumbnail(at url: URL) -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= maxThumbnailFileBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    nonisolated private static func writeThumbnail(_ image: CGImage, to url: URL) {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        do {
            let folder = try AppSupport.secureDirectory(url.deletingLastPathComponent())
            try SecureFile.write(data, to: folder.appendingPathComponent(url.lastPathComponent))
        } catch {
            logger.error("Couldn't cache a shelf thumbnail: \(LoggedError(error), privacy: .public) \(String(describing: error), privacy: .private)")
        }
    }

    /// Removes `name` inside `folder` without following a symlink out of it.
    nonisolated private static func removeEntry(named name: String, in folder: URL) {
        let url = folder.appendingPathComponent(name)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.error("Couldn't remove shelf storage: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Deletes `<uuid>` / `<uuid>.png` entries no item refers to. Anything not named by a UUID is ignored.
    nonisolated private static func removeOrphans(in folder: URL, keeping ids: Set<UUID>) {
        var info = stat()
        guard lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            return
        }
        for name in names {
            let stem = name.hasSuffix(".png") ? String(name.dropLast(4)) : name
            guard let id = UUID(uuidString: stem), !ids.contains(id) else { continue }
            removeEntry(named: name, in: folder)
        }
    }

    nonisolated private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    // MARK: - Bookmark resolution

    struct Resolution: Sendable {
        var url: URL?
        var availability: ShelfItem.Availability
        /// The resolved path when it is known (also for `.needsAccess`).
        var path: String?
        /// A fresh bookmark when the old one was stale or the file moved.
        var refreshedBookmark: Data?
    }

    /// Resolves without UI or mounting. A file in the Trash counts as deleted; a bookmark that no longer
    /// resolves falls back to the last known path when a file is still there.
    nonisolated static func resolve(bookmark: Data, lastKnownPath: String) -> Resolution {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ).standardizedFileURL
            if url.pathComponents.contains(".Trash") {
                return Resolution(url: nil, availability: .missing, path: nil, refreshedBookmark: nil)
            }
            switch pathState(url.path) {
            case .missing:
                return Resolution(url: nil, availability: .missing, path: nil, refreshedBookmark: nil)
            case .noPermission:
                return Resolution(url: url, availability: .needsAccess, path: url.path, refreshedBookmark: nil)
            case .present:
                var refreshed: Data?
                if isStale || url.path != lastKnownPath {
                    refreshed = try? url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: [.nameKey, .fileSizeKey, .contentTypeKey],
                        relativeTo: nil
                    )
                }
                return Resolution(url: url, availability: .available, path: url.path, refreshedBookmark: refreshed)
            }
        } catch {
            let nsError = error as NSError
            if isPermissionError(nsError) {
                return Resolution(url: URL(fileURLWithPath: lastKnownPath), availability: .needsAccess,
                                  path: nil, refreshedBookmark: nil)
            }
            let fallback = URL(fileURLWithPath: lastKnownPath)
            if pathState(fallback.path) == .present {
                let refreshed = try? fallback.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: [.nameKey, .fileSizeKey, .contentTypeKey],
                    relativeTo: nil
                )
                return Resolution(url: fallback, availability: .available, path: fallback.path, refreshedBookmark: refreshed)
            }
            return Resolution(url: nil, availability: .missing, path: nil, refreshedBookmark: nil)
        }
    }

    private enum PathState { case present, missing, noPermission }

    nonisolated private static func pathState(_ path: String) -> PathState {
        var info = stat()
        if stat(path, &info) == 0 { return .present }
        return errno == EPERM || errno == EACCES ? .noPermission : .missing
    }

    nonisolated private static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) || error.code == Int(EACCES) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
        return false
    }
}
