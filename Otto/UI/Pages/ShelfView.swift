//
//  ShelfView.swift
//  Otto
//
//  The Shelf page of the open notch: a five-column grid of kept files, an action bar (Ask about, Share,
//  Reveal in Finder, Remove) and the empty state. SwiftUI draws the tiles; each tile's clicks, drags and
//  context menu go through ShelfController's AppKit hit area. Page keys (arrows, Space, Return, ⌫, ⌘A, ⌘C,
//  ⌥⌘R) are handled here while the grid has keyboard focus, and the grid takes focus only while the notch is
//  engaged: a pointer resting on the notch (soft focus, §4.4) or a Shelf drop (§4.7) never hands it the keyboard.
//

import AppKit
import SwiftUI

struct ShelfView: View {
    private let controller: ShelfController
    private let focusRequest: Int
    private let isEngaged: Bool
    private let onAskAbout: ((Set<UUID>) -> Void)?
    private let onFocusChange: (Bool) -> Void

    @FocusState private var isFocused: Bool
    @State private var focusTask: Task<Void, Never>?
    @State private var shareAnchor = ShareAnchor()

    /// - Parameters:
    ///   - focusRequest: bump it to give the grid keyboard focus (a Shelf drop never does). Ignored while
    ///     `isEngaged` is false.
    ///   - isEngaged: the user clicked into or typed into the notch (`vm.isEngaged`). Soft focus is not engagement:
    ///     until it is true the grid neither takes the keyboard nor acts on a key (⌫ would delete Otto's copies,
    ///     ⌘C would replace the user's clipboard).
    ///   - onAskAbout: Ask about (button and ⌘↩ are the owner's); nil asks `controller` directly.
    ///   - onFocusChange: the grid gained or lost keyboard focus.
    init(
        controller: ShelfController,
        focusRequest: Int = 0,
        isEngaged: Bool = true,
        onAskAbout: ((Set<UUID>) -> Void)? = nil,
        onFocusChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.controller = controller
        self.focusRequest = focusRequest
        self.isEngaged = isEngaged
        self.onAskAbout = onAskAbout
        self.onFocusChange = onFocusChange
    }

    private var items: [ShelfItem] { controller.store.items }

    var body: some View {
        VStack(spacing: 10) {
            if items.isEmpty {
                ShelfEmptyState()
            } else {
                grid
                actionBar
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: .down, action: handleKey)
        .onChange(of: focusRequest) {
            if ShelfPageFocus.takesFocus(onRequest: true, isEngaged: isEngaged) { requestFocus() }
        }
        .onChange(of: isEngaged) { _, engaged in
            if engaged {
                // A click or a typed key engaged the notch while the Shelf shows: the grid takes the keyboard.
                requestFocus()
            } else {
                // Disengaged (the panel lost key, or the pin hands the keyboard back): a later soft focus must not
                // find the grid still focused.
                focusTask?.cancel()
                isFocused = false
            }
        }
        .onChange(of: isFocused) { _, focused in onFocusChange(focused) }
        .onDisappear {
            focusTask?.cancel()
            if isFocused { onFocusChange(false) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shelf")
    }

    // MARK: - Grid

    private var grid: some View {
        let columns = Array(
            repeating: GridItem(.fixed(ShelfPageLayout.tileWidth), spacing: ShelfPageLayout.spacing),
            count: ShelfPageLayout.columns
        )
        let landingOrder = landingIndices
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: ShelfPageLayout.spacing) {
                    ForEach(items) { item in
                        ShelfTileView(
                            item: item,
                            // A picture shows only its own rendering (else a placeholder), never its type's icon.
                            thumbnail: ShelfPageText.isImage(item)
                                ? controller.store.renderedThumbnail(for: item.id)
                                : controller.store.thumbnail(for: item.id),
                            isSelected: controller.selection.contains(item.id),
                            landingIndex: landingOrder[item.id],
                            controller: controller
                        )
                        .id(item.id)
                    }
                }
                .frame(width: ShelfPageLayout.gridWidth)
                .animation(Theme.Motion.content, value: items.map(\.id))
                .frame(maxWidth: .infinity)
                .background {
                    // A click between tiles clears the selection and gives the grid the keyboard.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            controller.clearSelection()
                            isFocused = true
                        }
                }
            }
            .frame(height: ShelfPageLayout.gridHeight(itemCount: items.count))
            .frame(maxWidth: .infinity)
            .mask { gridMask }
            .onChange(of: controller.selection) { old, new in
                let added = new.subtracting(old)
                guard let target = items.last(where: { added.contains($0.id) }) else { return }
                withAnimation(Theme.Motion.content) {
                    proxy.scrollTo(target.id, anchor: nil)
                }
            }
        }
    }

    /// Order of the tiles that just landed from a Shelf drop (the landing pulse staggers them).
    private var landingIndices: [UUID: Int] {
        guard controller.isHoldingLanding else { return [:] }
        var indices: [UUID: Int] = [:]
        for item in items where controller.selection.contains(item.id) {
            indices[item.id] = indices.count
        }
        return indices
    }

    @ViewBuilder
    private var gridMask: some View {
        if ShelfPageLayout.scrolls(itemCount: items.count) {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: ShelfPageLayout.fadeLength)
                Rectangle().fill(Color.black)
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: ShelfPageLayout.fadeLength)
            }
        } else {
            Rectangle().fill(Color.black)
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        let selectedCount = controller.selection.count
        let target = ShelfPageText.targetCount(itemCount: items.count, selectedCount: selectedCount)
        return HStack(spacing: 4) {
            Text(ShelfPageText.summary(
                itemCount: items.count,
                selectedCount: selectedCount,
                totalBytes: controller.store.totalByteCount
            ))
            .font(Theme.font(12))
            .foregroundStyle(Theme.textTertiaryOnClay)
            .monospacedDigit()
            .lineLimit(1)
            Spacer(minLength: 8)
            ShelfBarButton(
                title: ShelfPageText.askLabel(targetCount: target),
                showsOrb: true,
                isProminent: true,
                help: ShelfPageText.askLabel(targetCount: target) + " (⌘↩)"
            ) {
                askAbout(controller.targetIDs)
            }
            ShelfBarButton(symbol: "square.and.arrow.up", help: ShelfPageText.shareHelp(targetCount: target)) {
                guard let anchor = shareAnchor.view else { return }
                controller.share(controller.targetIDs, from: anchor)
            }
            .background(ShareAnchorView(anchor: shareAnchor))
            ShelfBarButton(symbol: "folder", help: ShelfPageText.revealHelp) {
                controller.reveal(controller.targetIDs)
            }
            ShelfBarButton(symbol: "minus.circle", help: ShelfPageText.removeHelp(targetCount: target)) {
                withAnimation(Theme.Motion.content) {
                    controller.remove(controller.targetIDs)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: ShelfPageLayout.actionBarHeight)
        .clay(in: Capsule(style: .continuous), style: .tray)
    }

    private func askAbout(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if let onAskAbout {
            onAskAbout(ids)
        } else {
            controller.askAbout(ids)
        }
    }

    // MARK: - Keyboard

    /// Page keys; everything else (Esc, ⌘↩, ⌘V, ⌘D…) belongs to the panel's key map.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // The key that engages a soft-focused notch reaches the page too; it only engages.
        guard ShelfPageFocus.handlesKeys(isEngaged: isEngaged) else { return .ignored }
        let modifiers = press.modifiers.intersection([.command, .option, .shift, .control])
        let selection = controller.selection
        switch press.key {
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            guard modifiers.subtracting(.shift).isEmpty, !items.isEmpty else { return .ignored }
            controller.moveSelection(direction(for: press.key), extending: modifiers.contains(.shift))
            return .handled
        case .space:
            guard modifiers.isEmpty, !selection.isEmpty else { return .ignored }
            controller.toggleQuickLook(selection)
            return .handled
        case .return:
            guard modifiers.isEmpty, !selection.isEmpty else { return .ignored }
            controller.open(selection)
            return .handled
        case .delete, .deleteForward:
            guard modifiers.isEmpty, !selection.isEmpty else { return .ignored }
            withAnimation(Theme.Motion.content) {
                controller.remove(selection)
            }
            return .handled
        default:
            break
        }

        let character = press.characters.lowercased()
        if modifiers == .command, character == "a" {
            guard !items.isEmpty else { return .ignored }
            controller.selectAll()
            return .handled
        }
        if modifiers == .command, character == "c" {
            guard !selection.isEmpty else { return .ignored }
            controller.copy(selection)
            return .handled
        }
        // ⌥ turns R into "®" on most layouts.
        if modifiers == [.command, .option], character == "r" || character == "®" {
            guard !selection.isEmpty else { return .ignored }
            controller.reveal(selection)
            return .handled
        }
        return .ignored
    }

    private func direction(for key: KeyEquivalent) -> ShelfController.MoveDirection {
        switch key {
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .upArrow: return .up
        default: return .down
        }
    }

    private func requestFocus() {
        focusTask?.cancel()
        focusTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            isFocused = true
        }
    }
}

// MARK: - Tile

private struct ShelfTileView: View {
    let item: ShelfItem
    let thumbnail: NSImage?
    let isSelected: Bool
    /// Position in the landing pulse, nil when the tile didn't just land.
    let landingIndex: Int?
    let controller: ShelfController

    @State private var isHovering = false
    @State private var hasLanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(item: ShelfItem, thumbnail: NSImage?, isSelected: Bool, landingIndex: Int?, controller: ShelfController) {
        self.item = item
        self.thumbnail = thumbnail
        self.isSelected = isSelected
        self.landingIndex = landingIndex
        self.controller = controller
        _hasLanded = State(initialValue: landingIndex == nil)
    }

    private var isMissing: Bool { item.availability == .missing }

    var body: some View {
        ZStack {
            plate
            VStack(spacing: ShelfPageLayout.nameGap) {
                // A missing file dims only its thumbnail; the name and "Moved or deleted" stay readable (AA).
                ShelfThumbnailWell(item: item, thumbnail: thumbnail)
                    .opacity(isMissing ? 0.45 : 1)
                    .overlay {
                        if isMissing {
                            MissingBadge(corner: ShelfThumbnailWell.visibleSize(item: item, thumbnail: thumbnail))
                        }
                    }
                VStack(spacing: 1) {
                    name
                    if isMissing {
                        // A fixed caption, never truncated: it may use the tile's padding.
                        Text(ShelfPageText.missingSubtitle)
                            .font(Theme.font(10.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(width: ShelfPageLayout.nameMaxWidth)
                    }
                }
            }
            .padding(.horizontal, ShelfPageLayout.tilePadding)
            .padding(.vertical, ShelfPageLayout.tileVerticalPadding)
            // Top-aligned in the tile without a Spacer: a Spacer would take another `nameGap` of stack spacing,
            // push the stack past the 100 pt tile and let the grid's scroll view clip the selected plate's top.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            ShelfTileHitArea(id: item.id, interaction: controller)
        }
        .frame(width: ShelfPageLayout.tileWidth, height: ShelfPageLayout.tileHeight)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(Theme.Motion.hover, value: isSelected)
        .scaleEffect(hasLanded ? 1 : 0.9)
        .opacity(hasLanded ? 1 : 0)
        .onAppear(perform: land)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ShelfPageText.accessibilityLabel(for: item, isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { controller.select(item.id, modifiers: []) }
        .accessibilityAction(named: "Open") { controller.open([item.id]) }
        .accessibilityAction(named: "Reveal in Finder") { controller.reveal([item.id]) }
        .accessibilityAction(named: "Remove from Shelf") { controller.remove([item.id]) }
    }

    /// Up to two centered lines, truncated in the middle so the extension stays visible and never broken after a
    /// hyphen. A missing file keeps one line, leaving room for "Moved or deleted" under it.
    private var name: some View {
        let text = ShelfPageText.caption(item)
        let lines = isMissing ? 1 : 2
        return Text(text)
            .font(Theme.font(11.5))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(lines)
            .truncationMode(.middle)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            // A fixed slot, so a one-line name and a two-line name leave every thumbnail at the same height.
            .frame(width: ShelfPageLayout.nameMaxWidth, height: ShelfPageLayout.nameLineHeight * CGFloat(lines),
                   alignment: .top)
    }

    @ViewBuilder
    private var plate: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if isSelected {
            // The selected Recents row's plate.
            SelectionPlate(cornerRadius: 14)
        } else if isHovering {
            shape.fill(Color.white.opacity(0.04))
        }
    }

    private func land() {
        guard !hasLanded, let landingIndex else { return }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.15)) { hasLanded = true }
        } else {
            withAnimation(Theme.Motion.content.delay(Double(landingIndex) * ShelfPageLayout.landingStagger)) {
                hasLanded = true
            }
        }
    }
}

/// The amber mark on a missing file's thumbnail: a small dark disc centered on the top-trailing corner of what
/// the thumbnail visibly draws (a page icon is narrower than its well), so it reads as part of the file it marks.
private struct MissingBadge: View {
    static let side: CGFloat = 14
    /// How far the badge's center sits out from and above the corner.
    static let outset: CGFloat = 3

    /// The visible thumbnail's size; the badge is placed relative to its top-trailing corner.
    let corner: CGSize

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Theme.attention)
            .frame(width: Self.side, height: Self.side)
            .background {
                Circle()
                    .fill(Color.black.opacity(0.72))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            }
            .offset(x: corner.width / 2 + Self.outset, y: -(corner.height / 2 + Self.outset))
            .accessibilityHidden(true)
    }
}

private struct ShelfThumbnailWell: View {
    let item: ShelfItem
    let thumbnail: NSImage?

    private var side: CGFloat { ShelfPageLayout.thumbnailSide }

    /// The size of what the well visibly draws, centered in it: a filled image takes the whole well, a file
    /// icon its page (the shadow's footprint below), an image placeholder the same page, a placeholder symbol
    /// about its glyph.
    static func visibleSize(item: ShelfItem, thumbnail: NSImage?) -> CGSize {
        let side = ShelfPageLayout.thumbnailSide
        if thumbnail == nil, ShelfPageText.isImage(item) { return ShelfPageLayout.imagePlaceholderSize }
        guard thumbnail != nil else { return CGSize(width: 32, height: 32) }
        if ShelfPageText.isImage(item) { return CGSize(width: side, height: side) }
        return CGSize(width: side * 0.66, height: side * 0.8)
    }

    var body: some View {
        Group {
            if let thumbnail, ShelfPageText.isImage(item) {
                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(shape)
                    .overlay { shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5) }
            } else if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: side, height: side)
                    .background {
                        LayeredShadow(
                            shape: RoundedRectangle(cornerRadius: 6, style: .continuous),
                            opacity: 0.35,
                            radius: 4,
                            y: 2,
                            layers: 6
                        )
                        .frame(width: side * 0.66, height: side * 0.8)
                    }
            } else if ShelfPageText.isImage(item) {
                ImagePlaceholder()
                    .frame(width: side, height: side)
            } else {
                Image(systemName: ShelfPageText.placeholderSymbol(for: item))
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: side, height: side)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A picture whose rendering hasn't landed (or that Quick Look can't draw): a quiet clay page with a photo glyph,
/// at a document icon's footprint, so it never passes for a saturated app icon.
private struct ImagePlaceholder: View {
    static let fill = Theme.rgb(0x26272A)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ShelfPageLayout.imagePlaceholderRadius, style: .continuous)
        shape
            .fill(Self.fill)
            .overlay { shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1) }
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(width: ShelfPageLayout.imagePlaceholderSize.width,
                   height: ShelfPageLayout.imagePlaceholderSize.height)
    }
}

// MARK: - Action bar pieces

private struct ShelfBarButton: View {
    var title: String?
    var symbol: String?
    var showsOrb = false
    var isProminent = false
    let help: String
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(title: String? = nil, symbol: String? = nil, showsOrb: Bool = false, isProminent: Bool = false,
         help: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.showsOrb = showsOrb
        self.isProminent = isProminent
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if showsOrb {
                    OttoOrb(size: 9)
                }
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                }
                if let title {
                    Text(title)
                        .font(Theme.font(12, .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isProminent || isHovering ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, title == nil ? 0 : 9)
            .frame(minWidth: 26, minHeight: 26, maxHeight: 26)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.1 : (isProminent ? 0.06 : 0)))
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(title ?? help)
    }
}

/// Holds the AppKit view the share picker anchors on (behind the Share button).
private final class ShareAnchor {
    weak var view: NSView?
}

private struct ShareAnchorView: NSViewRepresentable {
    let anchor: ShareAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

// MARK: - Empty state

private struct ShelfEmptyState: View {
    var body: some View {
        PageEmptyState(symbol: "tray", title: ShelfPageText.emptyTitle, message: ShelfPageText.emptyBody,
                       height: ShelfPageLayout.emptyStateHeight)
            .accessibilityElement(children: .combine)
    }
}
