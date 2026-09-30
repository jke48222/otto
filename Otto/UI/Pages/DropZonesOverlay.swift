//
//  DropZonesOverlay.swift
//  Otto
//
//  Split drop wells over the open notch while files or images are dragged in: "Keep on Shelf" on the left,
//  "Ask about it" on the right. The well under the pointer lifts to the dock cards' clay and top-lit ring; the other
//  sits back as a recessed well of the same clay, edged with the dimmed dashed ring of context-io.md §5.1. The two
//  crossfade (text never dims with opacity); each subtitle says how the drop will land, in the error color when
//  the shelf or the attachments are full. Drawing only: the drop delegate on the notch shape decides the zone and
//  performs the drop.
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
                appearance: ShelfDropWell.appearance(of: .shelf, in: session),
                outerEdge: .leading
            ) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(session.zone == .shelf ? Theme.textPrimary : Theme.textTertiary)
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
                appearance: ShelfDropWell.appearance(of: .ask, in: session),
                outerEdge: .trailing
            ) {
                OttoOrb(size: 13, isActive: session.zone == .ask)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque, so the composer's placeholder or reply text never shows around or under the wells.
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
    /// The well's outer side: the lift grows from here toward the gap between the wells, so the
    /// active well never leaves the panel's 16 pt gutter.
    let outerEdge: HorizontalEdge
    @ViewBuilder let icon: () -> Icon

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var cornerRadius: CGFloat { 18 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        HStack(spacing: 10) {
            icon()
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.font(13.5, .medium))
                    .foregroundStyle(appearance.isActive ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.font(12))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                // Idle: pressed into the panel rather than drawn on it. The idle dimming lands on the dashed ring,
                // never on text.
                RecessedWell(shape: shape)
                    .overlay {
                        shape.strokeBorder(
                            Theme.sendFill.opacity(ShelfDropWell.inactive.strokeOpacity * appearance.opacity),
                            style: StrokeStyle(lineWidth: ShelfDropWell.inactive.strokeWidth, dash: [5, 4])
                        )
                    }
                    .opacity(appearance.isDashed ? 1 : 0)
                // Active: the dock cards' clay tray with their top-lit 1 pt ring.
                ClaySurface(shape: shape, style: .tray)
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.cornerRadius - 1, style: .continuous)
                            .strokeBorder(DockCardChrome.ringGradient, lineWidth: ShelfDropWell.active.strokeWidth)
                            .opacity(ShelfDropWell.active.strokeOpacity)
                            .padding(1)
                    }
                    .opacity(appearance.isActive ? 1 : 0)
            }
        }
        // A small lift toward the other well; Reduce Motion keeps the crossfade only.
        .scaleEffect(reduceMotion ? 1 : appearance.scale, anchor: outerEdge == .leading ? .leading : .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(appearance.isActive ? .isSelected : [])
    }

    private var subtitleColor: Color {
        if isWarning { return Theme.error }
        return appearance.isActive ? Theme.textSecondary : Theme.textTertiary
    }
}

/// The idle drop well: the tray's clay turned inside out. Its gradient runs dark at the top to a touch lighter at
/// the bottom, with the foam grain and a soft shade under the top edge, and it casts no shadow, so it reads as a
/// hollow in the panel that the lifted well rises out of.
private struct RecessedWell<S: InsettableShape>: View {
    let shape: S

    /// Flat clay: no rim, glow, shade or shadow of its own (strength 0), just the fill and the grain.
    private static var clay: ClayStyle {
        ClayStyle(
            gradient: [
                .init(color: Theme.rgb(0x0A0B0C), location: 0),
                .init(color: Theme.rgb(0x131416), location: 1),
            ],
            grain: 0.8,
            strength: 0,
            shadowOpacity: 0,
            shadowRadius: 0,
            shadowY: 0,
            contactOpacity: 0
        )
    }

    var body: some View {
        ClaySurface(shape: shape, style: Self.clay)
            .overlay {
                // The inner shadow of a hollow: dark under the top edge, gone 12 pt down.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.35), location: 0),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 12)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipShape(shape)
            }
            .allowsHitTesting(false)
    }
}
