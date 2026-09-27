//
//  ShelfControllerTests.swift
//  OttoTests
//
//  The Shelf page's behavior on an in-memory store: selection (click, ⌘-click, ⇧-click ranges, arrow
//  moves over the 5-column grid), drag plans and the drag-end removal rules, the holds that keep the
//  notch open, and every action through seams (no Finder, no general pasteboard, no Quick Look panel).
//

import AppKit
import XCTest
@testable import Otto

@MainActor
final class ShelfControllerTests: XCTestCase {
    private var files: URL!
    private var settings: AppSettings!
    private var store: ShelfStore!
    private var controller: ShelfController!
    private var pasteboard: NSPasteboard!
    private var opened: [URL] = []
    private var revealed: [[URL]] = []
    private var errors: [String] = []
    private var holdChanges = 0

    override func setUp() async throws {
        files = FileManager.default.temporaryDirectory
            .appendingPathComponent("OttoShelfControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        store = ShelfStore(directory: nil, thumbnailer: ShelfStoreTestThumbnailer())
        await store.load()
        controller = ShelfController(store: store, settings: settings)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("otto.tests.shelf.\(UUID().uuidString)"))
        opened = []
        revealed = []
        errors = []
        holdChanges = 0
        controller.pasteboard = pasteboard
        controller.openFile = { [unowned self] in opened.append($0) }
        controller.revealFiles = { [unowned self] in revealed.append($0) }
        controller.onError = { [unowned self] in errors.append($0) }
        controller.onHoldsChanged = { [unowned self] in holdChanges += 1 }
        controller.quickLook.panelProvider = { nil }
        controller.quickLook.panelExists = { false }
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: files)
    }

    /// Adds `count` files named 0.txt, 1.txt… and returns their ids in grid order.
    @discardableResult
    private func addFiles(_ count: Int) throws -> [UUID] {
        let urls = try (0..<count).map { index -> URL in
            let url = files.appendingPathComponent("\(index).txt")
            try Data("file \(index)".utf8).write(to: url)
            return url
        }
        return controller.add(fileURLs: urls).added
    }

    private func resolved(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Selection

    func testClickCommandClickAndShiftClickRanges() throws {
        let ids = try addFiles(8)

        controller.select(ids[2], modifiers: [])
        XCTAssertEqual(controller.selection, [ids[2]])

        controller.select(ids[5], modifiers: .shift)
        XCTAssertEqual(controller.selection, Set(ids[2...5]))

        controller.select(ids[0], modifiers: .shift)
        XCTAssertEqual(controller.selection, Set(ids[0...2]), "⇧-click ranges from the anchor, not the last shift-click")

        controller.select(ids[7], modifiers: .command)
        XCTAssertEqual(controller.selection, Set(ids[0...2]).union([ids[7]]))

        controller.select(ids[1], modifiers: .command)
        XCTAssertEqual(controller.selection, [ids[0], ids[2], ids[7]])

        controller.select(ids[4], modifiers: .shift)
        XCTAssertEqual(controller.selection, Set(ids[1...4]), "⌘-click moves the anchor")

        controller.select(ids[6], modifiers: [])
        XCTAssertEqual(controller.selection, [ids[6]])
    }

    func testShiftClickWithoutAnAnchorSelectsJustThatItem() throws {
        let ids = try addFiles(3)
        controller.select(ids[1], modifiers: .shift)
        XCTAssertEqual(controller.selection, [ids[1]])
    }

    func testArrowMovesOverTheFiveColumnGrid() throws {
        let ids = try addFiles(12) // rows: 0–4, 5–9, 10–11

        controller.moveSelection(.right, extending: false)
        XCTAssertEqual(controller.selection, [ids[0]], "Without a selection any arrow selects the first item")

        controller.moveSelection(.down, extending: false)
        XCTAssertEqual(controller.selection, [ids[5]])
        controller.moveSelection(.down, extending: false)
        XCTAssertEqual(controller.selection, [ids[10]])
        controller.moveSelection(.down, extending: false)
        XCTAssertEqual(controller.selection, [ids[11]], "Down from a short last row stops at the last item")
        controller.moveSelection(.right, extending: false)
        XCTAssertEqual(controller.selection, [ids[11]])
        controller.moveSelection(.up, extending: false)
        XCTAssertEqual(controller.selection, [ids[6]])
        controller.moveSelection(.left, extending: false)
        XCTAssertEqual(controller.selection, [ids[5]])
        controller.moveSelection(.up, extending: false)
        XCTAssertEqual(controller.selection, [ids[0]])
        controller.moveSelection(.up, extending: false)
        XCTAssertEqual(controller.selection, [ids[0]], "Up from the first row stays put")
        controller.moveSelection(.left, extending: false)
        XCTAssertEqual(controller.selection, [ids[0]])
    }

    func testShiftArrowsExtendFromTheAnchor() throws {
        let ids = try addFiles(12)
        controller.select(ids[6], modifiers: [])

        controller.moveSelection(.right, extending: true)
        XCTAssertEqual(controller.selection, Set(ids[6...7]))
        controller.moveSelection(.down, extending: true)
        XCTAssertEqual(controller.selection, Set(ids[6...11]))
        controller.moveSelection(.up, extending: true)
        controller.moveSelection(.up, extending: true)
        XCTAssertEqual(controller.selection, Set(ids[1...6]), "Extending past the anchor flips the range")
        controller.moveSelection(.left, extending: false)
        XCTAssertEqual(controller.selection, [ids[0]])
    }

    func testSelectAllClearAndTargets() throws {
        let ids = try addFiles(4)
        XCTAssertEqual(controller.targetIDs, Set(ids), "Nothing selected → every item")

        controller.select(ids[1], modifiers: [])
        XCTAssertEqual(controller.targetIDs, [ids[1]])

        controller.selectAll()
        XCTAssertEqual(controller.selection, Set(ids))

        controller.clearSelection()
        XCTAssertTrue(controller.selection.isEmpty)
        XCTAssertEqual(controller.targetIDs, Set(ids))
    }

    func testRemovedItemsLeaveTheSelection() throws {
        let ids = try addFiles(3)
        controller.selectAll()
        controller.remove([ids[0]])
        XCTAssertEqual(controller.selection, Set(ids[1...2]))

        store.remove(ids: [ids[1]])
        XCTAssertEqual(controller.selection, [ids[2]], "Removal through the store is seen too")
    }

    // MARK: - Tile clicks

    func testDoubleClickOpensTheSelectionOrTheTile() throws {
        let ids = try addFiles(3)
        controller.select(ids[0], modifiers: [])
        controller.select(ids[1], modifiers: .command)

        controller.tileClicked(ids[1], modifiers: [], clickCount: 2)
        XCTAssertEqual(opened.map(resolved), [0, 1].map { resolved(files.appendingPathComponent("\($0).txt")) })

        opened = []
        controller.tileClicked(ids[2], modifiers: [], clickCount: 2)
        XCTAssertEqual(opened.map(resolved), [resolved(files.appendingPathComponent("2.txt"))])
        XCTAssertEqual(controller.selection, [ids[2]])
    }

    func testHitViewSelectsOnMouseUpAndOpensOnDoubleClick() throws {
        let ids = try addFiles(2)
        let view = ShelfTileHitView(itemID: ids[1], interaction: controller)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))

        view.mouseDown(with: try mouseEvent(.leftMouseDown, clickCount: 1))
        XCTAssertTrue(controller.selection.isEmpty, "A press alone doesn't change the selection")
        view.mouseUp(with: try mouseEvent(.leftMouseUp, clickCount: 1))
        XCTAssertEqual(controller.selection, [ids[1]])

        view.mouseDown(with: try mouseEvent(.leftMouseDown, clickCount: 2))
        XCTAssertEqual(opened.map(resolved), [resolved(files.appendingPathComponent("1.txt"))])

        view.itemID = ids[0]
        view.mouseDown(with: try mouseEvent(.leftMouseDown, clickCount: 1, modifiers: .command))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, clickCount: 1))
        XCTAssertEqual(controller.selection, Set(ids), "⌘ is read from the press")
    }

    func testHitAreaBuildsFromTheFrozenInitializer() throws {
        let ids = try addFiles(1)
        let area = ShelfTileHitArea(id: ids[0], interaction: controller)
        _ = area
    }

    // MARK: - Drags

    func testDragOfAnUnselectedTileDragsOnlyThatTile() throws {
        let ids = try addFiles(4)
        controller.select(ids[0], modifiers: [])
        controller.select(ids[1], modifiers: .command)

        let plan = controller.dragPlan(startingAt: ids[3])

        XCTAssertEqual(plan.ids, [ids[3]])
        XCTAssertEqual(controller.selection, [ids[3]])
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertNotNil(plan.items.first?.image)
        XCTAssertEqual(plan.outsideOperations, [.copy, .link])
    }

    func testDragOfASelectedTileDragsTheSelectionInGridOrderSkippingMissing() throws {
        let ids = try addFiles(5)
        controller.select(ids[4], modifiers: [])
        controller.select(ids[1], modifiers: .command)
        controller.select(ids[2], modifiers: .command)
        try FileManager.default.removeItem(at: files.appendingPathComponent("2.txt"))

        let plan = controller.dragPlan(startingAt: ids[4])

        XCTAssertEqual(plan.ids, [ids[1], ids[4]])
        XCTAssertEqual(plan.items.map { resolved($0.url) }, [1, 4].map { resolved(files.appendingPathComponent("\($0).txt")) })
        XCTAssertEqual(controller.dragItems(startingAt: ids[4]).count, 2)
    }

    func testReferencesNeverOfferMoveAndOwnedCopiesDo() async throws {
        let reference = try XCTUnwrap(try addFiles(1).first)
        let owned = try await store.addOwned(data: Data([1]), suggestedName: "a.png", type: .png)
        let secondOwned = try await store.addOwned(data: Data([2]), suggestedName: "b.png", type: .png)

        XCTAssertEqual(controller.dragPlan(startingAt: reference).outsideOperations, [.copy, .link])
        XCTAssertEqual(controller.dragPlan(startingAt: owned.id).outsideOperations, [.copy, .move, .generic])

        controller.select(secondOwned.id, modifiers: .command)
        XCTAssertEqual(controller.dragPlan(startingAt: owned.id).outsideOperations, [.copy, .move, .generic])

        controller.select(reference, modifiers: .command)
        XCTAssertEqual(controller.dragPlan(startingAt: owned.id).outsideOperations, [.copy, .link],
                       "One of the user's files in the drag rules out Move for all of it")
    }

    func testDragEndRemovesDraggedItemsAfterADrop() throws {
        let ids = try addFiles(3)

        controller.dragWillBegin()
        XCTAssertTrue(controller.isDraggingOut)
        XCTAssertEqual(holdChanges, 1)

        controller.dragDidEnd(ids: [ids[0], ids[2]], operation: .copy)
        XCTAssertFalse(controller.isDraggingOut)
        XCTAssertEqual(holdChanges, 2)
        XCTAssertEqual(store.items.map(\.id), [ids[1]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.appendingPathComponent("0.txt").path),
                      "The user's file stays where it is")
    }

    func testCancelledDragKeepsItems() throws {
        let ids = try addFiles(2)
        controller.dragWillBegin()
        controller.dragDidEnd(ids: Set(ids), operation: [])
        XCTAssertEqual(store.count, 2)
        XCTAssertFalse(controller.isDraggingOut)
    }

    func testKeepAfterDragOutSettingKeepsItems() throws {
        let ids = try addFiles(2)
        settings.shelf.keepAfterDragOut = true
        controller.dragWillBegin()
        controller.dragDidEnd(ids: Set(ids), operation: .link)
        XCTAssertEqual(store.count, 2)
    }

    func testDraggedOutOwnedCopyOutlivesItsTileForTheReceiver() async throws {
        let owned = try await store.addOwned(data: Data([5]), suggestedName: "c.png", type: .png)
        let url = try XCTUnwrap(store.url(for: owned.id))
        controller.dragWillBegin()
        controller.dragDidEnd(ids: [owned.id], operation: .copy)
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Holds

    func testLandingHoldSelectsNewTilesThenReleases() async throws {
        let ids = try addFiles(4)
        controller.landingHoldDuration = .milliseconds(50)

        controller.beginLandingHold(selecting: [ids[2], ids[3]])
        XCTAssertTrue(controller.isHoldingLanding)
        XCTAssertEqual(controller.selection, Set(ids[2...3]))
        XCTAssertEqual(holdChanges, 1)

        let deadline = Date().addingTimeInterval(3)
        while controller.isHoldingLanding, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isHoldingLanding)
        XCTAssertEqual(holdChanges, 2)
        XCTAssertEqual(ShelfController.landingHoldDuration, .milliseconds(1500))
    }

    func testQuickLookTogglesItsHold() throws {
        let ids = try addFiles(2)
        controller.toggleQuickLook(Set(ids))
        XCTAssertTrue(controller.isShowingQuickLook)
        XCTAssertEqual(controller.quickLook.urls.map(resolved), [0, 1].map { resolved(files.appendingPathComponent("\($0).txt")) })
        XCTAssertEqual(holdChanges, 1)

        controller.toggleQuickLook(Set(ids))
        XCTAssertFalse(controller.isShowingQuickLook)
        XCTAssertEqual(holdChanges, 2)

        controller.toggleQuickLook([])
        XCTAssertFalse(controller.isShowingQuickLook, "Nothing to preview → nothing opens")
    }

    func testQuickLookDataSourceServesTheURLs() throws {
        let ids = try addFiles(2)
        controller.toggleQuickLook(Set(ids))
        let quickLook = controller.quickLook
        XCTAssertEqual(quickLook.numberOfPreviewItems(in: nil), 2)
        XCTAssertEqual((quickLook.previewPanel(nil, previewItemAt: 1) as? NSURL).map { resolved($0 as URL) },
                       resolved(files.appendingPathComponent("1.txt")))
        XCTAssertNil(quickLook.previewPanel(nil, previewItemAt: 5))
        XCTAssertEqual(ShelfQuickLookController.panelLevel, NotchPanel.auxiliaryWindowLevel)
    }

    func testContextMenuTrackingIsAHold() throws {
        let ids = try addFiles(1)
        let menu = try XCTUnwrap(controller.contextMenu(for: ids[0]))
        menu.delegate?.menuWillOpen?(menu)
        XCTAssertTrue(controller.isShowingContextMenu)
        menu.delegate?.menuDidClose?(menu)
        XCTAssertFalse(controller.isShowingContextMenu)
        XCTAssertEqual(holdChanges, 2)
    }

    // MARK: - Actions

    func testContextMenuSelectsTheTileAndListsTheActions() throws {
        let ids = try addFiles(3)
        controller.select(ids[0], modifiers: [])

        let menu = try XCTUnwrap(controller.contextMenu(for: ids[2]))
        XCTAssertEqual(controller.selection, [ids[2]])
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Open", "Quick Look", "Reveal in Finder", "Copy", "Ask Otto", "Remove from Shelf"])

        let anchored = try XCTUnwrap(controller.contextMenu(for: ids[2], anchor: NSView()))
        XCTAssertTrue(anchored.items.contains { $0.title == "Share…" })

        controller.selectAll()
        let plural = try XCTUnwrap(controller.contextMenu(for: ids[1]))
        XCTAssertTrue(plural.items.contains { $0.title == "Ask Otto about 3" })

        let remove = try XCTUnwrap(plural.items.first { $0.title == "Remove from Shelf" })
        let target = try XCTUnwrap(remove.target as? NSObject)
        target.perform(try XCTUnwrap(remove.action))
        XCTAssertEqual(store.count, 0)
    }

    func testRevealAndOpenUseTheResolvedFiles() throws {
        let ids = try addFiles(2)
        controller.reveal(Set(ids))
        XCTAssertEqual(revealed.first?.map(resolved), [0, 1].map { resolved(files.appendingPathComponent("\($0).txt")) })
        controller.open([ids[1]])
        XCTAssertEqual(opened.map(resolved), [resolved(files.appendingPathComponent("1.txt"))])
    }

    func testMissingItemsAreSkippedAndReported() throws {
        let ids = try addFiles(3)
        try FileManager.default.removeItem(at: files.appendingPathComponent("0.txt"))

        controller.open(Set(ids))
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(errors, ["0.txt was moved or deleted."])
        XCTAssertEqual(controller.urls(for: Set(ids)).count, 2)

        try FileManager.default.removeItem(at: files.appendingPathComponent("1.txt"))
        errors = []
        controller.reveal(Set(ids))
        XCTAssertEqual(errors, ["2 items were moved or deleted."])
    }

    func testCopyWritesFileURLsAndPasteAddsThem() throws {
        let ids = try addFiles(2)
        controller.copy(Set(ids))
        let copied = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(copied?.map(resolved), [0, 1].map { resolved(files.appendingPathComponent("\($0).txt")) })

        store.removeAll()
        let result = controller.pasteFromClipboard()
        XCTAssertEqual(result.added.count, 2)
        XCTAssertEqual(store.items.map(\.name), ["0.txt", "1.txt"])

        let again = controller.pasteFromClipboard()
        XCTAssertEqual(again.duplicates, 2)
    }

    func testPasteWithoutFilesSaysSo() {
        pasteboard.clearContents()
        pasteboard.setString("text", forType: .string)
        let result = controller.pasteFromClipboard()
        XCTAssertEqual(result, ShelfAddResult(added: [], duplicates: 0, rejectedForLimit: 0))
        XCTAssertEqual(errors, [ShelfController.noFilesToPasteMessage])
    }

    func testAddingPastTheLimitReportsTheExactCopy() throws {
        try addFiles(ShelfStore.maxItems)
        let extra = files.appendingPathComponent("extra.txt")
        try Data("x".utf8).write(to: extra)

        let result = controller.add(fileURLs: [extra])

        XCTAssertEqual(result.rejectedForLimit, 1)
        XCTAssertEqual(errors, ["The shelf holds up to 50 items. Remove some to add more."])
    }

    func testAddProvidersIngestsAndReports() async throws {
        let url = files.appendingPathComponent("dropped.txt")
        try Data("drop".utf8).write(to: url)
        let providers = [
            try XCTUnwrap(NSItemProvider(contentsOf: url)),
            NSItemProvider(item: Data([1, 2]) as NSData, typeIdentifier: "public.png"),
        ]

        let result = await controller.add(providers: providers)

        XCTAssertEqual(result.added.count, 2)
        XCTAssertEqual(store.items.map(\.origin), [.reference, .owned])
        XCTAssertTrue(errors.isEmpty)
    }

    func testAskAboutHandsTheURLsToTheViewModel() throws {
        let ids = try addFiles(2)
        var asked: [URL] = []
        controller.onAskAbout = { asked = $0 }
        controller.askAbout(Set(ids))
        XCTAssertEqual(asked.map(resolved), [0, 1].map { resolved(files.appendingPathComponent("\($0).txt")) })
        XCTAssertEqual(store.count, 2, "Items stay on the shelf")
    }

    func testSharingFailureIsReportedAndCancelIsNot() {
        let sharing = ShelfSharingController()
        var messages: [String] = []
        sharing.onError = { messages.append($0) }
        sharing.didFail(cancelled: true, description: "Cancelled")
        sharing.didFail(cancelled: false, description: "The network is offline.")
        XCTAssertEqual(messages, ["Couldn't share: The network is offline."])
        XCTAssertFalse(sharing.isSharing)
    }

    func testSharingGivesFocusBackAfterAChosenServiceFinishes() {
        let sharing = ShelfSharingController()
        let previous = NSRunningApplication.current
        var reactivated: [NSRunningApplication] = []
        sharing.activateOtto = { previous }
        sharing.reactivate = { reactivated.append($0) }

        sharing.didChoose(anyService: true)
        XCTAssertTrue(reactivated.isEmpty)
        sharing.didShare(count: 1)
        XCTAssertEqual(reactivated.count, NSApp.isActive ? 0 : 1)
    }

    // MARK: - Helpers

    private func mouseEvent(
        _ type: NSEvent.EventType,
        clickCount: Int,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: 5, y: 5), modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        ))
    }
}
