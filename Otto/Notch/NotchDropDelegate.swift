//
//  NotchDropDelegate.swift
//  Otto
//
//  Drop routing over the notch shape (§4.7). While a drag is over the shape it keeps the view model's
//  drop session current: how many items, whether they can go on the Shelf, and which well the pointer is
//  over (left "Keep on Shelf", right "Ask Otto"). The drop itself goes to `NotchViewModel.performDrop`.
//  Otto's own drags out of the Shelf are refused so a tile can't land back on the notch it came from.
//

import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct NotchDropDelegate: DropDelegate {
    let viewModel: NotchViewModel

    /// Everything the notch accepts: files, images, links and text.
    static let acceptedTypes: [UTType] = [.fileURL, .image, .url, .plainText]
    /// What the Shelf keeps (links and plain text always go to the Ask well).
    static let shelfTypes: [UTType] = [.fileURL, .image]

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Pure

    /// The session for a drag of `itemCount` items at `x` (shape coordinates) over a shape `width` wide.
    static func session(x: CGFloat, width: CGFloat, itemCount: Int, hasShelfItems: Bool,
                        shelfEnabled: Bool) -> DropSession {
        let acceptsShelf = shelfEnabled && hasShelfItems
        return DropSession(zone: DropZone.zone(forX: x, width: width, acceptsShelf: acceptsShelf),
                           itemCount: itemCount, acceptsShelf: acceptsShelf)
    }

    // MARK: - DropDelegate

    func validateDrop(info: DropInfo) -> Bool {
        !viewModel.shelf.isDraggingOut && info.hasItemsConforming(to: Self.acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        viewModel.updateDropSession(makeSession(info))
        if !viewModel.isDropTargeted {
            viewModel.isDropTargeted = true
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        if let session = viewModel.dropSession {
            let zone = DropZone.zone(forX: info.location.x, width: shapeWidth, acceptsShelf: session.acceptsShelf)
            if zone != session.zone {
                var updated = session
                updated.zone = zone
                viewModel.updateDropSession(updated)
            }
        } else {
            viewModel.updateDropSession(makeSession(info))
        }
        if !viewModel.isDropTargeted {
            viewModel.isDropTargeted = true
        }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        viewModel.updateDropSession(nil)
        if viewModel.isDropTargeted {
            viewModel.isDropTargeted = false
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else {
            dropExited(info: info)
            return false
        }
        let zone = viewModel.dropSession?.zone
            ?? DropZone.zone(forX: info.location.x, width: shapeWidth,
                             acceptsShelf: viewModel.settings.shelf.enabled && info.hasItemsConforming(to: Self.shelfTypes))
        let providers = info.itemProviders(for: Self.acceptedTypes)
        return viewModel.performDrop(providers, zone: zone)
    }

    // MARK: - Private

    /// The shape as rendered right now (the drag may have opened it a moment ago).
    private var shapeWidth: CGFloat {
        viewModel.renderedShapeSize.width
    }

    private func makeSession(_ info: DropInfo) -> DropSession {
        Self.session(
            x: info.location.x,
            width: shapeWidth,
            itemCount: info.itemProviders(for: Self.acceptedTypes).count,
            hasShelfItems: info.hasItemsConforming(to: Self.shelfTypes),
            shelfEnabled: viewModel.settings.shelf.enabled
        )
    }
}
