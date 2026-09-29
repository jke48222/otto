//
//  DropZonesOverlay.swift
//  Otto
//
//  Split drop wells over the open notch while files or images are dragged in: "Keep on Shelf" on the left,
//  "Ask Otto" on the right. The well under the pointer brightens and the other dims; each subtitle says how
//  the drop will land, in the error color when the shelf or the attachments are full. Drawing only: the
//  drop delegate on the notch shape decides the zone and performs the drop.
//

import SwiftUI

struct DropZonesOverlay: View {
    private let session: DropSession
    private let shelfCount: Int
    private let remainingAttachmentCapacity: Int

    /// - Parameters:
    ///   - session: the drag in progress (zone under the pointer, item count).
    ///   - shelfCount: items already on the shelf.
    ///   - remainingAttachmentCapacity: how many more items the composer can attach.
    init(session: DropSession, shelfCount: Int, remainingAttachmentCapacity: Int) {
        self.session = session
        self.shelfCount = shelfCount
        self.remainingAttachmentCapacity = remainingAttachmentCapacity
    }

    var body: some View {
        let backdrop = RoundedRectangle(cornerRadius: 22, style: .continuous)
        HStack(spacing: 10) {
            DropWellView(
                title: ShelfDropWell.shelfTitle,
                subtitle: ShelfDropWell.shelfSubtitle(itemCount: session.itemCount, shelfCount: shelfCount),
                isWarning: ShelfDropWell.shelfIsOverLimit(itemCount: session.itemCount, shelfCount: shelfCount),
                appearance: ShelfDropWell.appearance(of: .shelf, in: session)
            ) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            DropWellView(
                title: ShelfDropWell.askTitle,
                subtitle: ShelfDropWell.askSubtitle(
                    itemCount: session.itemCount,
                    remainingCapacity: remainingAttachmentCapacity
                ),
                isWarning: ShelfDropWell.askIsOverCapacity(
                    itemCount: session.itemCount,
                    remainingCapacity: remainingAttachmentCapacity
                ),
                appearance: ShelfDropWell.appearance(of: .ask, in: session)
            ) {
                OttoOrb(size: 13, isActive: session.zone == .ask)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque: the inactive well has no fill and is dimmed, so a see-through backdrop let the composer's
        // placeholder or reply text show under the wells' titles.
        .background(backdrop.fill(Theme.panel))
        .animation(Theme.Motion.hover, value: session.zone)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
    }
}

private struct DropWellView<Icon: View>: View {
    let title: String
    let subtitle: String
    let isWarning: Bool
    let appearance: ShelfDropWell.Appearance
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        HStack(spacing: 10) {
            icon()
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.font(13.5, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.font(12))
                    .foregroundStyle(isWarning ? Theme.error : Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if appearance.isActive {
                ClaySurface(shape: shape, style: .tray)
            }
        }
        .overlay {
            shape.strokeBorder(
                Theme.sendFill.opacity(appearance.strokeOpacity),
                style: StrokeStyle(
                    lineWidth: appearance.strokeWidth,
                    dash: appearance.isDashed ? [6, 5] : []
                )
            )
        }
        .scaleEffect(appearance.scale)
        .opacity(appearance.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(appearance.isActive ? .isSelected : [])
    }
}
