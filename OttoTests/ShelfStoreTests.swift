//
//  ShelfStoreTests.swift
//  OttoTests
//
//  The Shelf's store against a throwaway folder: adding and deduplicating references, the 50-item and
//  owned-size limits with their exact copy, persistence (0600 files in a 0700 `Shelf.noindex`), moved and
//  deleted files, removal that never touches the user's originals, quarantine on owned copies, thumbnail
//  caching, and the damaged-index and orphan rules. A fake thumbnailer keeps Quick Look out of it.
//

import CoreServices
import Darwin
import UniformTypeIdentifiers
import XCTest
@testable import Otto

@MainActor
final class ShelfStoreTests: XCTestCase {
    private var base: URL!
    private var files: URL!
    private var shelfDirectory: URL!
    private var thumbnailer: ShelfStoreTestThumbnailer!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OttoShelfStoreTests-\(UUID().uuidString)", isDirectory: true)
        files = base.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        shelfDirectory = try AppSupport.directory(.shelf, in: base, demo: false)
        thumbnailer = ShelfStoreTestThumbnailer()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeStore(directory: URL? = nil, inMemory: Bool = false) -> ShelfStore {
        ShelfStore(directory: inMemory ? nil : (directory ?? shelfDirectory), thumbnailer: thumbnailer)
    }

    private func makeLoadedStore() async -> ShelfStore {
        let store = makeStore()
        await store.load()
        return store
    }

    @discardableResult
    private func makeFile(_ name: String, contents: String = "hello", in folder: URL? = nil) throws -> URL {
        let url = (folder ?? files).appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func resolved(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Location

    func testDefaultLocationIsShelfNoindexInsideOttosFolder() throws {
        XCTAssertEqual(shelfDirectory.lastPathComponent, "Shelf.noindex")
        XCTAssertEqual(shelfDirectory.deletingLastPathComponent().lastPathComponent, "Otto")
        XCTAssertEqual(try mode(of: shelfDirectory), 0o700)
    }

    // MARK: - Adding

    func testAddKeepsReferencesAndDedupesByResolvedPath() async throws {
        let store = await makeLoadedStore()
        let file = try makeFile("notes.md")
        let folder = files.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sameFileAnotherWay = folder.appendingPathComponent("../notes.md")
        let link = files.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        let result = store.add(fileURLs: [file, folder, sameFileAnotherWay, link])

        XCTAssertEqual(result.added.count, 2)
        XCTAssertEqual(result.duplicates, 2)
        XCTAssertEqual(result.rejectedForLimit, 0)
        XCTAssertEqual(store.items.map(\.name), ["notes.md", "Assets"])
        XCTAssertEqual(store.items.map(\.origin), [.reference, .reference])
        XCTAssertEqual(store.items[0].byteCount, 5)
        XCTAssertEqual(store.items[0].contentTypeIdentifier, UTType("net.daringfireball.markdown")?.identifier)
        XCTAssertTrue(store.items[1].isDirectory)
        XCTAssertNil(store.items[1].byteCount)
        XCTAssertEqual(store.totalByteCount, 5)

        let again = store.add(fileURLs: [file])
        XCTAssertEqual(again, ShelfAddResult(added: [], duplicates: 1, rejectedForLimit: 0))
    }

    func testFiftyItemLimitRejectsTheRest() async throws {
        let store = await makeLoadedStore()
        let urls = try (0..<52).map { try makeFile("file-\($0).txt") }

        let result = store.add(fileURLs: urls)

        XCTAssertEqual(result.added.count, 50)
        XCTAssertEqual(result.rejectedForLimit, 2)
        XCTAssertEqual(store.count, ShelfStore.maxItems)
        do {
            _ = try await store.addOwned(data: Data([1]), suggestedName: "one", type: .png)
            XCTFail("A 51st item was added")
        } catch let error as ShelfError {
            XCTAssertEqual(error, .full)
        }
    }

    func testUnreadableFileIsReportedNotAdded() async throws {
        let store = await makeLoadedStore()
        let outcome = store.addReferences([files.appendingPathComponent("gone.txt")])
        XCTAssertEqual(outcome.result.added, [])
        XCTAssertEqual(outcome.errors, [.unreadable(name: "gone.txt")])
        XCTAssertEqual(store.count, 0)
    }

    func testErrorCopyIsExact() {
        XCTAssertEqual(ShelfError.full.errorDescription, "The shelf holds up to 50 items. Remove some to add more.")
        XCTAssertEqual(ShelfError.tooLarge(name: "movie.mov").errorDescription,
                       "movie.mov is too big for the shelf (512 MB max).")
        XCTAssertEqual(ShelfError.storageFull.errorDescription,
                       "Otto's shelf storage is full (2 GB). Remove some items first.")
        XCTAssertEqual(ShelfError.unreadable(name: "a.pdf").errorDescription, "Otto couldn't read a.pdf.")
        XCTAssertEqual(ShelfStore.maxOwnedItemBytes, 536_870_912)
        XCTAssertEqual(ShelfStore.maxOwnedTotalBytes, 2_147_483_648)
    }

    // MARK: - Owned copies

    func testOwnedCopyIsPrivateAndQuarantined() async throws {
        let store = await makeLoadedStore()
        let item = try await store.addOwned(data: Data([0x89, 0x50, 0x4E, 0x47]), suggestedName: "Screenshot", type: .png)

        XCTAssertEqual(item.origin, .owned)
        XCTAssertEqual(item.name, "Screenshot.png")
        XCTAssertEqual(item.byteCount, 4)
        let url = try XCTUnwrap(store.url(for: item.id))
        XCTAssertTrue(resolved(url).hasPrefix(resolved(shelfDirectory.appendingPathComponent("Owned/\(item.id.uuidString)")) + "/"))
        XCTAssertEqual(try mode(of: url), 0o600)
        XCTAssertEqual(try mode(of: url.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try mode(of: shelfDirectory.appendingPathComponent("Owned")), 0o700)

        let quarantine = try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        XCTAssertEqual(quarantine?[kLSQuarantineAgentNameKey as String] as? String, "Otto")
        XCTAssertEqual(quarantine?[kLSQuarantineTypeKey as String] as? String, kLSQuarantineTypeOtherDownload as String)
        XCTAssertTrue(store.isOwnedCopy(item.id, at: url))
    }

    func testOwnedCopyFromTemporaryFileLeavesTheSourceAlone() async throws {
        let store = await makeLoadedStore()
        let source = try makeFile("photo.heic", contents: "bytes")
        let item = try await store.addOwned(copying: source, suggestedName: "photo.heic")

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let url = try XCTUnwrap(store.url(for: item.id))
        XCTAssertEqual(try Data(contentsOf: url), Data("bytes".utf8))
        XCTAssertNotEqual(resolved(url), resolved(source))
    }

    func testOwnedItemLargerThan512MBIsRefused() async throws {
        let store = await makeLoadedStore()
        let big = files.appendingPathComponent("big.mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
        XCTAssertEqual(truncate(big.path, off_t(ShelfStore.maxOwnedItemBytes + 1)), 0)

        do {
            _ = try await store.addOwned(copying: big, suggestedName: "big.mov")
            XCTFail("A 512 MB + 1 byte copy was accepted")
        } catch let error as ShelfError {
            XCTAssertEqual(error, .tooLarge(name: "big.mov"))
            XCTAssertEqual(error.errorDescription, "big.mov is too big for the shelf (512 MB max).")
        }
        XCTAssertEqual(store.count, 0)
    }

    func testOwnedCopiesStopAtTwoGigabytesInTotal() async throws {
        // Three saved owned items claiming 600 MB each (1.8 GB); a 300 MB copy would pass 2 GB.
        let ownedRoot = try AppSupport.secureDirectory(shelfDirectory.appendingPathComponent("Owned", isDirectory: true))
        var seeded: [ShelfItem] = []
        for index in 0..<3 {
            let id = UUID()
            let folder = try AppSupport.secureDirectory(ownedRoot.appendingPathComponent(id.uuidString, isDirectory: true))
            let file = try makeFile("part\(index).bin", in: folder)
            seeded.append(ShelfItem(
                id: id, origin: .owned, bookmark: try file.bookmarkData(), lastKnownPath: file.path,
                name: "part\(index).bin", contentTypeIdentifier: nil, byteCount: 600 * 1024 * 1024,
                isDirectory: false, addedAt: Date()
            ))
        }
        try writeIndex(seeded)
        let store = await makeLoadedStore()
        XCTAssertEqual(store.items.map(\.origin), [.owned, .owned, .owned])

        let big = files.appendingPathComponent("more.mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
        XCTAssertEqual(truncate(big.path, off_t(300 * 1024 * 1024)), 0)
        do {
            _ = try await store.addOwned(copying: big, suggestedName: "more.mov")
            XCTFail("The 2 GB owned total was exceeded")
        } catch let error as ShelfError {
            XCTAssertEqual(error, .storageFull)
        }

        // References have no size limit: they are pointers.
        XCTAssertEqual(store.add(fileURLs: [big]).added.count, 1)
    }

    // MARK: - Persistence

    func testPersistenceRoundTripWithPrivateFiles() async throws {
        let store = await makeLoadedStore()
        let file = try makeFile("report.pdf")
        let result = store.add(fileURLs: [file])
        let owned = try await store.addOwned(data: Data("img".utf8), suggestedName: "Dropped Image.png", type: .png)
        store.flush()

        let index = shelfDirectory.appendingPathComponent("shelf.json")
        XCTAssertEqual(try mode(of: index), 0o600)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, 1)
        XCTAssertEqual((json?["items"] as? [Any])?.count, 2)

        let reloaded = await makeLoadedStore()
        XCTAssertTrue(reloaded.isLoaded)
        XCTAssertEqual(reloaded.items.map(\.id), result.added + [owned.id])
        XCTAssertEqual(reloaded.items.map(\.name), ["report.pdf", "Dropped Image.png"])
        XCTAssertEqual(reloaded.items.map(\.origin), [.reference, .owned])
        XCTAssertEqual(reloaded.items.map(\.availability), [.available, .available])
        XCTAssertEqual(reloaded.totalByteCount, 8)
    }

    func testSaveIsDebounced() async throws {
        let store = await makeLoadedStore()
        _ = store.add(fileURLs: [try makeFile("a.txt")])
        let index = shelfDirectory.appendingPathComponent("shelf.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.path))

        await waitUntil { FileManager.default.fileExists(atPath: index.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.path))
        XCTAssertEqual(try mode(of: index), 0o600)
    }

    func testAddsBeforeLoadAreKeptAfterTheSavedItems() async throws {
        let first = await makeLoadedStore()
        _ = first.add(fileURLs: [try makeFile("saved.txt")])
        first.flush()

        let second = makeStore()
        _ = second.add(fileURLs: [try makeFile("early.txt")])
        second.flush() // Not loaded yet: must not overwrite the saved index.
        await second.load()
        XCTAssertEqual(second.items.map(\.name), ["saved.txt", "early.txt"])
        second.flush()

        let third = await makeLoadedStore()
        XCTAssertEqual(third.items.map(\.name), ["saved.txt", "early.txt"])
    }

    func testInMemoryStoreWritesNothingToDisk() async throws {
        let store = makeStore(inMemory: true)
        await store.load()
        XCTAssertTrue(store.isLoaded)
        _ = store.add(fileURLs: [try makeFile("a.txt")])
        let owned = try await store.addOwned(data: Data([1, 2]), suggestedName: "x", type: .png)
        store.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: shelfDirectory.appendingPathComponent("shelf.json").path))
        let ownedURL = try XCTUnwrap(store.url(for: owned.id))
        XCTAssertFalse(resolved(ownedURL).hasPrefix(resolved(base)))
        XCTAssertEqual(try mode(of: ownedURL), 0o600)

        store.remove(ids: [owned.id])
        await waitUntil { !FileManager.default.fileExists(atPath: ownedURL.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedURL.path))
    }

    func testDamagedIndexIsSetAsideAndTheShelfStartsEmpty() async throws {
        try Data("{ not json".utf8).write(to: shelfDirectory.appendingPathComponent("shelf.json"))
        let store = await makeLoadedStore()
        XCTAssertTrue(store.isLoaded)
        XCTAssertEqual(store.count, 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: shelfDirectory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("shelf.damaged-") })
    }

    func testIndexFromANewerOttoIsSetAside() async throws {
        let json = #"{"version":2,"items":[]}"#
        try Data(json.utf8).write(to: shelfDirectory.appendingPathComponent("shelf.json"))
        let store = await makeLoadedStore()
        XCTAssertEqual(store.count, 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: shelfDirectory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("shelf.damaged-") })
    }

    func testOneDamagedEntryDoesNotCostTheRest() async throws {
        let file = try makeFile("kept.txt")
        let good = ShelfItem(id: UUID(), origin: .reference, bookmark: try file.bookmarkData(), lastKnownPath: file.path,
                             name: "kept.txt", contentTypeIdentifier: nil, byteCount: 5, isDirectory: false, addedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let goodJSON = try XCTUnwrap(String(data: encoder.encode(good), encoding: .utf8))
        let json = #"{"version":1,"items":[{"id":"not a uuid"},"# + goodJSON + "]}"
        try Data(json.utf8).write(to: shelfDirectory.appendingPathComponent("shelf.json"))

        let store = await makeLoadedStore()
        XCTAssertEqual(store.items.map(\.id), [good.id])
    }

    func testOrphanedOwnedFoldersAndThumbnailsAreRemovedOnLoad() async throws {
        let ownedRoot = try AppSupport.secureDirectory(shelfDirectory.appendingPathComponent("Owned", isDirectory: true))
        let thumbnails = try AppSupport.secureDirectory(shelfDirectory.appendingPathComponent("Thumbnails", isDirectory: true))
        let orphan = try AppSupport.secureDirectory(ownedRoot.appendingPathComponent(UUID().uuidString, isDirectory: true))
        try makeFile("left.bin", in: orphan)
        let orphanThumbnail = try makeFile("\(UUID().uuidString).png", in: thumbnails)
        let unrelated = try makeFile("keep-me.txt", in: ownedRoot)

        _ = await makeLoadedStore()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanThumbnail.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "Names that aren't UUIDs are ignored")
    }

    func testOwnedEntryPointingOutsideItsFolderIsTreatedAsTheUsersFile() async throws {
        let usersFile = try makeFile("important.txt")
        let forged = ShelfItem(id: UUID(), origin: .owned, bookmark: try usersFile.bookmarkData(),
                               lastKnownPath: usersFile.path, name: "important.txt", contentTypeIdentifier: nil,
                               byteCount: 5, isDirectory: false, addedAt: Date())
        try writeIndex([forged])

        let store = await makeLoadedStore()
        XCTAssertEqual(store.items.first?.origin, .reference)
        let url = try XCTUnwrap(store.url(for: forged.id))
        XCTAssertFalse(store.isOwnedCopy(forged.id, at: url))

        store.remove(ids: [forged.id])
        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: usersFile.path))
    }

    // MARK: - Moved and deleted files

    func testMovedFileReResolvesAndUpdatesItsPath() async throws {
        let store = await makeLoadedStore()
        let file = try makeFile("draft.txt")
        let id = try XCTUnwrap(store.add(fileURLs: [file]).added.first)
        store.flush()

        let moved = files.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let destination = moved.appendingPathComponent("draft.txt")
        try FileManager.default.moveItem(at: file, to: destination)

        let reloaded = await makeLoadedStore()
        XCTAssertEqual(reloaded.item(for: id)?.availability, .available)
        XCTAssertEqual(reloaded.item(for: id).map { resolved(URL(fileURLWithPath: $0.lastKnownPath)) }, resolved(destination))
        XCTAssertEqual(reloaded.url(for: id).map(resolved), resolved(destination))
        reloaded.flush()

        let third = await makeLoadedStore()
        XCTAssertEqual(third.item(for: id).map { resolved(URL(fileURLWithPath: $0.lastKnownPath)) }, resolved(destination))
    }

    func testDeletedFileBecomesMissing() async throws {
        let store = await makeLoadedStore()
        let file = try makeFile("temp.txt")
        let id = try XCTUnwrap(store.add(fileURLs: [file]).added.first)
        try FileManager.default.removeItem(at: file)

        await store.refreshAvailability()
        XCTAssertEqual(store.item(for: id)?.availability, .missing)
        XCTAssertNil(store.url(for: id))

        try makeFile("temp.txt")
        await store.refreshAvailability()
        XCTAssertEqual(store.item(for: id)?.availability, .available)
    }

    // MARK: - Removing

    func testRemoveDeletesOwnedBytesAndThumbnailsButNeverReferences() async throws {
        let store = await makeLoadedStore()
        let original = try makeFile("keep.txt")
        let reference = try XCTUnwrap(store.add(fileURLs: [original]).added.first)
        let owned = try await store.addOwned(data: Data([1, 2, 3]), suggestedName: "pic.png", type: .png)
        let ownedFolder = shelfDirectory.appendingPathComponent("Owned/\(owned.id.uuidString)")
        let thumbnails = shelfDirectory.appendingPathComponent("Thumbnails")
        let referenceThumbnail = thumbnails.appendingPathComponent("\(reference.uuidString).png")
        let ownedThumbnail = thumbnails.appendingPathComponent("\(owned.id.uuidString).png")
        await waitUntil {
            FileManager.default.fileExists(atPath: referenceThumbnail.path)
                && FileManager.default.fileExists(atPath: ownedThumbnail.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedThumbnail.path))
        XCTAssertEqual(try mode(of: ownedThumbnail), 0o600)

        var removed: Set<UUID> = []
        store.onItemsRemoved = { removed = $0 }
        store.remove(ids: [reference, owned.id])
        store.flush()

        XCTAssertEqual(removed, [reference, owned.id])
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "Removing never deletes the user's file")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "hello")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedFolder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: referenceThumbnail.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedThumbnail.path))
    }

    func testDragOutRemovalKeepsOwnedBytesForTheReceiver() async throws {
        let store = await makeLoadedStore()
        let owned = try await store.addOwned(data: Data([1]), suggestedName: "a.png", type: .png)
        let url = try XCTUnwrap(store.url(for: owned.id))

        store.remove(ids: [owned.id], keepingOwnedBytesFor: .milliseconds(200))
        store.flush()
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        await waitUntil { !FileManager.default.fileExists(atPath: url.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRemoveAllEmptiesTheShelf() async throws {
        let store = await makeLoadedStore()
        _ = store.add(fileURLs: [try makeFile("a.txt"), try makeFile("b.txt")])
        store.removeAll()
        XCTAssertEqual(store.count, 0)
        store.flush()
        let reloaded = await makeLoadedStore()
        XCTAssertEqual(reloaded.count, 0)
    }

    // MARK: - Thumbnails

    func testThumbnailIsGeneratedOnceAndCachedOnDisk() async throws {
        let store = await makeLoadedStore()
        let id = try XCTUnwrap(store.add(fileURLs: [try makeFile("pic.png")]).added.first)
        XCTAssertNotNil(store.thumbnail(for: id), "The type's icon stands in until the thumbnail lands")
        let cached = shelfDirectory.appendingPathComponent("Thumbnails/\(id.uuidString).png")
        await waitUntil { FileManager.default.fileExists(atPath: cached.path) }
        XCTAssertEqual(thumbnailer.calls, 1)
        store.flush()

        let relaunchThumbnailer = ShelfStoreTestThumbnailer()
        let reloaded = ShelfStore(directory: shelfDirectory, thumbnailer: relaunchThumbnailer)
        await reloaded.load()
        _ = reloaded.thumbnail(for: id)
        await waitUntil { reloaded.thumbnail(for: id)?.size == ShelfStore.thumbnailSize }
        XCTAssertEqual(reloaded.thumbnail(for: id)?.size, ShelfStore.thumbnailSize)
        XCTAssertEqual(relaunchThumbnailer.calls, 0, "A relaunch reads the cache instead of the file")
    }

    func testThumbnailForUnknownIDIsNil() async {
        let store = makeStore(inMemory: true)
        XCTAssertNil(store.thumbnail(for: UUID()))
    }

    // MARK: - Helpers

    private func writeIndex(_ items: [ShelfItem]) throws {
        struct Index: Encodable { var version: Int; var items: [ShelfItem] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try SecureFile.write(encoder.encode(Index(version: 1, items: items)),
                             to: shelfDirectory.appendingPathComponent("shelf.json"))
    }
}

/// Returns a 4 × 4 image for any file and counts the calls; never runs Quick Look.
final class ShelfStoreTestThumbnailer: ShelfThumbnailing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int { lock.withLock { count } }

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> CGImage? {
        lock.withLock { count += 1 }
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context?.makeImage()
    }
}
