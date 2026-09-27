//
//  ShelfDragSource.swift
//  Otto
//
//  The AppKit surface over each Shelf tile. SwiftUI only draws the tile; this transparent view owns every
//  mouse interaction on it, so clicks, double-clicks, right-clicks and multi-item drags to Finder, Mail or
//  any other app behave like AppKit's. A drag of the user's own files offers Copy and Link only, so the
//  receiver can never move an original; only Otto's own copies may be moved.
//

import AppKit
import Foundation
import SwiftUI

@MainActor protocol ShelfTileInteraction: AnyObject {        // implemented by ShelfController
    func tileClicked(_ id: UUID, modifiers: NSEvent.ModifierFlags, clickCount: Int)
    func contextMenu(for id: UUID) -> NSMenu?
    func dragItems(startingAt id: UUID) -> [(url: URL, image: NSImage?)]
    func dragWillBegin()
    func dragDidEnd(ids: Set<UUID>, operation: NSDragOperation)
}

/// What one drag out of the Shelf carries.
struct ShelfDragPlan {
    /// The dragged items' ids, in the same order as `items`.
    var ids: [UUID]
    var items: [(url: URL, image: NSImage?)]
    /// What a receiver outside Otto may do: [.copy, .link] when any item is the user's own file,
    /// [.copy, .move, .generic] when every item is an Otto-owned copy.
    var outsideOperations: NSDragOperation

    /// Operations for a drag of the user's files: never Move.
    static let referenceOperations: NSDragOperation = [.copy, .link]
    /// Operations for a drag of Otto's own copies only.
    static let ownedOperations: NSDragOperation = [.copy, .move, .generic]
}

/// The richer surface `ShelfController` gives a tile beyond `ShelfTileInteraction`: which items a drag
/// carries (ids and allowed operations), and a context menu that can anchor Share… on the tile.
@MainActor protocol ShelfTileHosting: ShelfTileInteraction {
    func dragPlan(startingAt id: UUID) -> ShelfDragPlan
    func contextMenu(for id: UUID, anchor: NSView) -> NSMenu?
}

/// AppKit hit/drag surface laid over each tile by ShelfView (W2-UI-PAGES consumes it; W1-SHELF builds it). Frozen.
struct ShelfTileHitArea: NSViewRepresentable {
    private let id: UUID
    private let interaction: ShelfTileInteraction

    init(id: UUID, interaction: ShelfTileInteraction) {
        self.id = id
        self.interaction = interaction
    }

    func makeNSView(context: Context) -> ShelfTileHitView {
        ShelfTileHitView(itemID: id, interaction: interaction)
    }

    func updateNSView(_ nsView: ShelfTileHitView, context: Context) {
        nsView.itemID = id
        nsView.interaction = interaction
    }
}

/// Transparent NSView laid over each tile. Selection happens on mouse-up (so a plain drag of an item
/// that is already part of a multi-selection drags the whole selection), opening on the second click's
/// mouse-down, a drag once the pointer moved more than 3 pt.
final class ShelfTileHitView: NSView, NSDraggingSource {
    var itemID: UUID
    weak var interaction: ShelfTileInteraction?

    /// Distance the pointer must travel with the button down before a drag starts.
    static let dragThreshold: CGFloat = 3
    /// Each extra dragged item is offset by this much (at most `maxVisibleDragImages` are drawn).
    static let dragImageOffset: CGFloat = 4
    static let maxVisibleDragImages = 4

    private var mouseDownEvent: NSEvent?
    private var didStartDrag = false
    private var activeDragIDs: [UUID] = []
    private var activeOutsideOperations: NSDragOperation = []

    init(itemID: UUID, interaction: ShelfTileInteraction?) {
        self.itemID = itemID
        self.interaction = interaction
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        didStartDrag = false
        if event.clickCount >= 2 {
            mouseDownEvent = nil
            interaction?.tileClicked(itemID, modifiers: event.modifierFlags, clickCount: event.clickCount)
            return
        }
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let start = mouseDownEvent else { return }
        let origin = start.locationInWindow
        let current = event.locationInWindow
        guard hypot(current.x - origin.x, current.y - origin.y) > Self.dragThreshold else { return }
        didStartDrag = true
        beginDrag(with: start)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard let start = mouseDownEvent, !didStartDrag else { return }
        interaction?.tileClicked(itemID, modifiers: start.modifierFlags, clickCount: 1)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu: NSMenu?
        if let host = interaction as? ShelfTileHosting {
            menu = host.contextMenu(for: itemID, anchor: self)
        } else {
            menu = interaction?.contextMenu(for: itemID)
        }
        guard let menu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .withinApplication:
            return []
        case .outsideApplication:
            return activeOutsideOperations
        @unknown default:
            return []
        }
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        interaction?.dragWillBegin()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let ids = Set(activeDragIDs)
        activeDragIDs = []
        activeOutsideOperations = []
        interaction?.dragDidEnd(ids: ids, operation: operation)
    }

    // MARK: - Private

    private func beginDrag(with event: NSEvent) {
        guard let interaction else { return }
        let plan: ShelfDragPlan
        if let host = interaction as? ShelfTileHosting {
            plan = host.dragPlan(startingAt: itemID)
        } else {
            // Without the controller's plan only this tile's id is known, and nothing may be moved.
            let items = interaction.dragItems(startingAt: itemID)
            plan = ShelfDragPlan(ids: [itemID], items: items, outsideOperations: ShelfDragPlan.referenceOperations)
        }
        guard !plan.items.isEmpty else { return }
        activeDragIDs = plan.ids
        activeOutsideOperations = plan.outsideOperations

        let draggingItems = plan.items.enumerated().map { index, entry in
            let item = NSDraggingItem(pasteboardWriter: entry.url as NSURL)
            let visibleIndex = CGFloat(min(index, Self.maxVisibleDragImages - 1))
            let frame = bounds.offsetBy(dx: visibleIndex * Self.dragImageOffset, dy: -visibleIndex * Self.dragImageOffset)
            let image = index < Self.maxVisibleDragImages ? Self.dragImage(entry.image, url: entry.url) : nil
            item.draggingFrame = frame
            item.imageComponentsProvider = {
                guard let image else { return [] }
                let component = NSDraggingImageComponent(key: .icon)
                component.contents = image
                component.frame = Self.fittedRect(for: image.size, in: NSRect(origin: .zero, size: frame.size))
                return [component]
            }
            return item
        }
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    private static func dragImage(_ image: NSImage?, url: URL) -> NSImage {
        image ?? NSWorkspace.shared.icon(forFile: url.path)
    }

    /// The image scaled to fit the tile's frame, centered, never upscaled past its own size.
    private static func fittedRect(for size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(1, min(rect.width / size.width, rect.height / size.height))
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(
            x: rect.midX - fitted.width / 2,
            y: rect.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}
