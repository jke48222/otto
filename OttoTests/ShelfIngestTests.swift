//
//  ShelfIngestTests.swift
//  OttoTests
//
//  What a drop on the Shelf becomes: a file provider is a reference to the user's file, image data is a
//  private temporary copy that outlives the provider's completion handler, text and web links alone are
//  not Shelf material, and the store turns owned inputs into quarantined copies and removes the temps.
//

import UniformTypeIdentifiers
import XCTest
@testable import Otto

@MainActor
final class ShelfIngestTests: XCTestCase {
    private var files: URL!

    override func setUp() async throws {
        files = FileManager.default.temporaryDirectory
            .appendingPathComponent("OttoShelfIngestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: files)
    }

    private func makeFile(_ name: String, contents: String = "hello") throws -> URL {
        let url = files.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func imageProvider(_ data: Data, type: UTType = .png, name: String? = nil) -> NSItemProvider {
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: type.identifier)
        provider.suggestedName = name
        return provider
    }

    private func resolved(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - acceptsShelf

    func testAcceptsFilesAndImagesButNotTextOrLinks() throws {
        let file = try XCTUnwrap(NSItemProvider(contentsOf: try makeFile("a.txt")))
        let image = imageProvider(Data([1, 2, 3]))
        let text = NSItemProvider(object: "just words" as NSString)
        let link = NSItemProvider(object: try XCTUnwrap(URL(string: "https://example.com")) as NSURL)

        XCTAssertTrue(ShelfIngest.acceptsShelf([file]))
        XCTAssertTrue(ShelfIngest.acceptsShelf([image]))
        XCTAssertFalse(ShelfIngest.acceptsShelf([text]))
        XCTAssertFalse(ShelfIngest.acceptsShelf([link]))
        XCTAssertFalse(ShelfIngest.acceptsShelf([text, link]))
        XCTAssertTrue(ShelfIngest.acceptsShelf([text, file]))
        XCTAssertFalse(ShelfIngest.acceptsShelf([]))
        XCTAssertEqual(ShelfIngest.dropTypes, [.fileURL, .image])
    }

    // MARK: - load

    func testFileProviderBecomesAReference() async throws {
        let url = try makeFile("notes.md")
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: url))

        let (inputs, errors) = await ShelfIngest.load([provider])

        XCTAssertTrue(errors.isEmpty)
        guard case .reference(let loaded)? = inputs.first, inputs.count == 1 else {
            return XCTFail("Expected one reference, got \(inputs)")
        }
        XCTAssertEqual(resolved(loaded), resolved(url))
    }

    func testImageDataBecomesAnOwnedTemporaryCopyThatOutlivesTheHandler() async throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let provider = imageProvider(bytes, name: "Chart")

        let (inputs, errors) = await ShelfIngest.load([provider])

        XCTAssertTrue(errors.isEmpty)
        guard case .owned(let temporaryURL, let name)? = inputs.first, inputs.count == 1 else {
            return XCTFail("Expected one owned input, got \(inputs)")
        }
        XCTAssertEqual(name, "Chart.png")
        XCTAssertEqual(try Data(contentsOf: temporaryURL), bytes, "The copy survives after the handler returned")
        XCTAssertTrue(resolved(temporaryURL).hasPrefix(resolved(ShelfIngest.temporaryRoot) + "/"))
        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        ShelfIngest.discard(inputs[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.deletingLastPathComponent().path))
    }

    func testUnnamedImageGetsAFallbackName() async throws {
        let (inputs, _) = await ShelfIngest.load([imageProvider(Data([1]), type: .jpeg)])
        guard case .owned(let temporaryURL, let name)? = inputs.first else { return XCTFail("No owned input") }
        XCTAssertEqual(name, "Dropped Image.jpeg")
        ShelfIngest.discard(.owned(temporaryURL: temporaryURL, name: name))
    }

    func testMixedDropKeepsOrderAndSkipsText() async throws {
        let first = try makeFile("one.txt")
        let second = try makeFile("two.txt")
        let providers = [
            try XCTUnwrap(NSItemProvider(contentsOf: first)),
            NSItemProvider(object: "ignored" as NSString),
            imageProvider(Data([7]), name: "pic.png"),
            try XCTUnwrap(NSItemProvider(contentsOf: second)),
        ]

        let (inputs, errors) = await ShelfIngest.load(providers)

        XCTAssertTrue(errors.isEmpty)
        guard inputs.count == 3 else { return XCTFail("Expected 3 inputs, got \(inputs)") }
        guard case .reference(let a) = inputs[0], case .owned(_, let name) = inputs[1], case .reference(let b) = inputs[2] else {
            return XCTFail("Unexpected inputs \(inputs)")
        }
        XCTAssertEqual(resolved(a), resolved(first))
        XCTAssertEqual(name, "pic.png")
        XCTAssertEqual(resolved(b), resolved(second))
        inputs.forEach(ShelfIngest.discard)
    }

    func testDiscardNeverTouchesReferences() async throws {
        let url = try makeFile("mine.txt")
        ShelfIngest.discard(.reference(url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Store ingest

    func testStoreIngestCopiesOwnedInputsAndRemovesTheTemps() async throws {
        let store = ShelfStore(directory: nil, thumbnailer: ShelfStoreTestThumbnailer())
        await store.load()
        let file = try makeFile("keep.txt")
        let (inputs, _) = await ShelfIngest.load([
            try XCTUnwrap(NSItemProvider(contentsOf: file)),
            imageProvider(Data([9, 9]), name: "shot.png"),
            try XCTUnwrap(NSItemProvider(contentsOf: file)),
        ])
        guard inputs.count == 3, case .owned(let temporaryURL, _) = inputs[1] else { return XCTFail("No owned input") }

        let result = await store.ingest(inputs)

        XCTAssertEqual(result.added.count, 2)
        XCTAssertEqual(result.duplicates, 1)
        XCTAssertEqual(store.items.map(\.origin), [.reference, .owned])
        XCTAssertEqual(store.items.map(\.name), ["keep.txt", "shot.png"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path), "The temporary copy is removed")
        let ownedID = try XCTUnwrap(result.added.last)
        let ownedURL = try XCTUnwrap(store.url(for: ownedID))
        XCTAssertEqual(try Data(contentsOf: ownedURL), Data([9, 9]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
