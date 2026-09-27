//
//  ShelfView.swift
//  Otto
//
//  The Shelf page of the open notch: a five-column grid of kept files, an action bar (Ask Otto, Share,
//  Reveal in Finder, Remove) and the empty state. SwiftUI draws the tiles; each tile's clicks, drags and
//  context menu go through ShelfController's AppKit hit area. Page keys (arrows, Space, Return, ⌫, ⌘A, ⌘C,
//  ⌥⌘R) are handled here while the grid has keyboard focus.
//

import AppKit
import SwiftUI

struct ShelfView: View {
    private let controller: ShelfController
    private let focusRequest: Int
    private let onAskAbout: ((Set<UUID>) -> Void)?
    private let onFocusChange: (Bool) -> Void

    @FocusState private var isFocused: Bool
    @State private var focusTask: Task<Void, Never>?
    @State private var shareAnchor = ShareAnchor()

    /// - Parameters:
    ///   - focusRequest: bump it to give the grid keyboard focus (a Shelf drop never does).
    ///   - onAskAbout: Ask Otto (button and ⌘↩ are the owner's); nil asks `controller` directly.
    ///   - onFocusChange: the grid gained or lost keyboard focus.
    init(
        controller: ShelfController,
        focusRequest: Int = 0,
        onAskAbout: ((Set<UUID>) -> Void)? = nil,
        onFocusChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.controller = controller
        self.focusRequest = focusRequest
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
        .onChange(of: focusRequest) { requestFocus() }
        .onChange(of: isFocused) { _, focused in onFocusChange(focused) }
        .onDisappear {
            focusTask?.cancel()
            if isFocused { onFocusChange(false) }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
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
                            thumbnail: controller.store.thumbnail(for: item.id),
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
            .foregroundStyle(Theme.textTertiary)
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
            VStack(spacing: 4) {
                ShelfThumbnailWell(item: item, thumbnail: thumbnail)
                    .overlay(alignment: .topTrailing) {
                        if isMissing {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.attention)
                                .offset(x: 4, y: -4)
                                .accessibilityHidden(true)
                        }
                    }
                VStack(spacing: 1) {
                    name
                    if isMissing {
                        Text(ShelfPageText.missingSubtitle)
                            .font(Theme.font(10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .opacity(isMissing ? 0.45 : 1)

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

    /// Up to two wrapped lines when the whole name fits in them; otherwise one line truncated in the middle,
    /// so the extension stays visible. (SwiftUI only truncates in the middle on a single line.)
    private var name: some View {
        let text = ShelfPageText.displayName(item)
        let lines = isMissing ? 1 : 2
        return ViewThatFits(in: .vertical) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(Theme.font(11.5))
        .foregroundStyle(Theme.chipLabel)
        .frame(width: ShelfPageLayout.nameMaxWidth)
        .frame(maxHeight: ShelfPageLayout.nameLineHeight * CGFloat(lines), alignment: .top)
    }

    @ViewBuilder
    private var plate: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if isSelected {
            ClaySurface(shape: shape, style: .chip)
                .overlay { shape.strokeBorder(Theme.sendFill.opacity(0.35), lineWidth: 1) }
        } else if isHovering {
            shape.fill(Theme.chipLiftedFill)
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

private struct ShelfThumbnailWell: View {
    let item: ShelfItem
    let thumbnail: NSImage?

    private var side: CGFloat { ShelfPageLayout.thumbnailSide }

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
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Text(ShelfPageText.emptyTitle)
                .font(Theme.font(13.5, .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(ShelfPageText.emptyBody)
                .font(Theme.font(12))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .frame(height: ShelfPageLayout.emptyStateHeight)
        .accessibilityElement(children: .combine)
    }
}
