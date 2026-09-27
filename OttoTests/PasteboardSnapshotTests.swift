//
//  PasteboardSnapshotTests.swift
//  OttoTests
//
//  Capturing and restoring a clipboard, password-manager items, limits and the nspasteboard.org markers,
//  all on private named pasteboards (never the user's clipboard).
//

import AppKit
import XCTest
@testable import Otto

final class PasteboardSnapshotTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("otto.tests.snapshot.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    private let custom = NSPasteboard.PasteboardType("com.example.custom")

    private func writeTwoItems() {
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setString("first", forType: .string)
        first.setData(Data([1, 2, 3]), forType: custom)
        let second = NSPasteboardItem()
        second.setString("<b>second</b>", forType: .html)
        second.setString("second", forType: .string)
        pasteboard.writeObjects([first, second])
    }

    func testCapturesAndRestoresEveryItemAndType() throws {
        writeTwoItems()
        guard case .captured(let snapshot) = PasteboardSnapshot.capture(pasteboard) else {
            return XCTFail("Expected a snapshot")
        }
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertEqual(snapshot.changeCount, pasteboard.changeCount)
        XCTAssertEqual(snapshot.totalBytes, snapshot.items.flatMap(\.values).reduce(0) { $0 + $1.count })

        ClipboardMarkers.write(PastePayload(plain: "answer"), to: pasteboard, transient: true)
        let restoredCount = snapshot.restore(to: pasteboard)
        XCTAssertEqual(restoredCount, pasteboard.changeCount)

        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].string(forType: .string), "first")
        XCTAssertEqual(items[0].data(forType: custom), Data([1, 2, 3]))
        XCTAssertEqual(items[1].string(forType: .html), "<b>second</b>")
        XCTAssertEqual(items[1].string(forType: .string), "second")

        guard case .captured(let again) = PasteboardSnapshot.capture(pasteboard) else {
            return XCTFail("Expected a snapshot")
        }
        let withoutMarker = again.items.map { $0.filter { $0.key != ClipboardMarkers.transient } }
        XCTAssertEqual(withoutMarker, snapshot.items)
    }

    func testRestoreWritesTheTransientMarker() {
        writeTwoItems()
        guard case .captured(let snapshot) = PasteboardSnapshot.capture(pasteboard) else {
            return XCTFail("Expected a snapshot")
        }
        snapshot.restore(to: pasteboard)
        XCTAssertTrue(pasteboard.types?.contains(ClipboardMarkers.transient) ?? false)
    }

    func testEmptyClipboardRestoresToEmpty() {
        pasteboard.clearContents()
        guard case .captured(let snapshot) = PasteboardSnapshot.capture(pasteboard) else {
            return XCTFail("Expected a snapshot")
        }
        XCTAssertTrue(snapshot.items.isEmpty)
        ClipboardMarkers.write(PastePayload(plain: "answer"), to: pasteboard, transient: true)
        snapshot.restore(to: pasteboard)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testByteLimitMakesItUnrestorable() {
        writeTwoItems()
        XCTAssertEqual(PasteboardSnapshot.capture(pasteboard, byteLimit: 4), .unrestorable)
        if case .captured = PasteboardSnapshot.capture(pasteboard, byteLimit: 1024) {} else {
            XCTFail("Expected a snapshot under the limit")
        }
    }

    func testFilePromisesAreUnrestorable() {
        for raw in ["com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-url"] {
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString("x", forType: NSPasteboard.PasteboardType(raw))
            pasteboard.writeObjects([item])
            XCTAssertEqual(PasteboardSnapshot.capture(pasteboard), .unrestorable, raw)
        }
    }

    func testConcealedItemsKeepNoBytes() {
        let concealedTypes = [
            ClipboardMarkers.concealed,
            NSPasteboard.PasteboardType("com.agilebits.onepassword"),
            NSPasteboard.PasteboardType("com.example.PasswordItem"),
        ]
        for type in concealedTypes {
            pasteboard.clearContents()
            let plain = NSPasteboardItem()
            plain.setString("not secret", forType: .string)
            let secret = NSPasteboardItem()
            secret.setString("hunter2", forType: .string)
            secret.setData(Data(), forType: type)
            pasteboard.writeObjects([plain, secret])
            XCTAssertEqual(PasteboardSnapshot.capture(pasteboard), .concealed, type.rawValue)
        }
        XCTAssertFalse(PasteboardSnapshot.isConcealed(.string))
    }

    // MARK: Markers

    func testWriteProducesOneItemWithEveryRepresentation() throws {
        let payload = PastePayload(plain: "plain", rtf: RichTextRenderer.rtf("**rich**"), html: "<p>html</p>")
        let changeCount = ClipboardMarkers.write(payload, to: pasteboard, transient: true)

        XCTAssertEqual(changeCount, pasteboard.changeCount)
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertNotNil(item.data(forType: .rtf))
        XCTAssertEqual(item.string(forType: .html), "<p>html</p>")
        XCTAssertEqual(item.string(forType: .string), "plain")
        XCTAssertEqual(item.string(forType: ClipboardMarkers.source), "com.jalenedusei.otto")
        XCTAssertTrue(item.types.contains(ClipboardMarkers.transient))
        XCTAssertTrue(item.types.contains(ClipboardMarkers.autoGenerated))
    }

    func testUnmarkedWriteLeavesOutTheTransientMarkers() throws {
        ClipboardMarkers.write(PastePayload(plain: "keep me"), to: pasteboard, transient: false)
        let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        XCTAssertEqual(item.string(forType: .string), "keep me")
        XCTAssertFalse(item.types.contains(ClipboardMarkers.transient))
        XCTAssertFalse(item.types.contains(ClipboardMarkers.autoGenerated))
        XCTAssertNil(item.data(forType: .rtf))
        XCTAssertNil(item.string(forType: .html))
    }
}
