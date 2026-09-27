//
//  ContextChipsView.swift
//  Otto
//
//  The context chips above the composer, seated on one clay tray that hugs them, in the order of §6.8: the
//  ghost chip offering the selected text, the attachments, the ghost chips offering the browser tab and the
//  window the user came from, and shimmering placeholders while files load.
//

import AppKit
import SwiftUI

// MARK: - FlowLayout

/// Lays subviews out left-to-right, wrapping onto new rows when the proposed width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat? = nil
    var alignment: HorizontalAlignment = .leading

    struct Cache {
        var sizes: [CGSize] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let rows = arrange(maxWidth: proposal.width ?? .infinity, sizes: cache.sizes)
        guard !rows.isEmpty else { return .zero }
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + CGFloat(rows.count - 1) * rowSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let rows = arrange(maxWidth: bounds.width, sizes: cache.sizes)
        var y = bounds.minY
        for row in rows {
            let leftover = max(0, bounds.width - row.width)
            var x: CGFloat
            switch alignment {
            case .trailing: x = bounds.minX + leftover
            case .center: x = bounds.minX + leftover / 2
            default: x = bounds.minX
            }
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private var rowSpacing: CGFloat { lineSpacing ?? spacing }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(maxWidth: CGFloat, sizes: [CGSize]) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, rawSize) in sizes.enumerated() {
            // A single item wider than the row is clamped (its label truncates).
            let size = CGSize(width: min(rawSize.width, maxWidth), height: rawSize.height)
            let proposedWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty && proposedWidth > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
            current.sizes.append(size)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Chips row

struct ContextChipsView: View {
    let viewModel: NotchViewModel

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
    }

    /// Chip height and wrapping limits (two rows, then the row scrolls).
    static let chipHeight: CGFloat = 28
    /// The selected (newest, removable) chip: a puffy clay pill of the same height (radius 14).
    static let selectedChipHeight: CGFloat = 28
    /// Horizontal padding inside the selected chip's clay pill.
    static let chipPadding: CGFloat = 10
    /// Unselected chips have no plate at rest (just icon + label on the foam), so they carry only
    /// enough padding for their hover plate.
    static let plainChipPadding: CGFloat = 6
    /// Icon size and the gap between icon and label.
    static let iconSize: CGFloat = 15
    static let iconGap: CGFloat = 6
    /// Labels longer than this truncate at the tail ("AI_Man_cea775f8…").
    static let labelMaxWidth: CGFloat = 132
    /// Between chips in a row (with the plain chips' padding, ≈14 pt from one label to the next
    /// icon), and between rows.
    static let spacing: CGFloat = 2
    static let rowSpacing: CGFloat = 6
    /// The clay tray the chips are seated on: it hugs the widest row, and its corners follow the
    /// chips' (row height / 2 + the 10 pt side padding).
    static let trayPadding = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
    static let trayCornerRadius: CGFloat = selectedChipHeight / 2 + trayPadding.leading
    static let maxVisibleRows = 2
    /// Breathing room so chip transitions, hover plates and the selected chip's shadow are not
    /// clipped by the scroll view.
    private static let scrollInset: CGFloat = 10
    /// How much of the third row peeks out (under a fade) to signal that the chips scroll.
    private static let overflowPeek: CGFloat = 12

    @State private var contentHeight: CGFloat = 0
    /// Width of the widest row of chips (laid out against the full available width).
    @State private var contentWidth: CGFloat = 0

    /// The tray hugs its content; until the chips have been measured it spans the row.
    private var trayWidth: CGFloat? {
        contentWidth > 0 ? contentWidth + Self.trayPadding.leading + Self.trayPadding.trailing : nil
    }

    private var twoRowHeight: CGFloat {
        Self.selectedChipHeight * CGFloat(Self.maxVisibleRows) + Self.rowSpacing * CGFloat(Self.maxVisibleRows - 1)
    }

    private var isScrollable: Bool { contentHeight > twoRowHeight + 1 }

    var body: some View {
        // The scroll view carries an inset on every side (then negative padding) so chip edges
        // are not clipped while the chips stay aligned inside their tray. Its height resolves in
        // the same layout pass: the content height, capped at two rows plus a peek of the third.
        ScrollViewReader { proxy in
            CappedHeightLayout(maxHeight: twoRowHeight + Self.overflowPeek + Self.scrollInset * 2) {
                ScrollView(.vertical) {
                    chips
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Self.scrollInset)
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
            }
            .mask {
                if isScrollable {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.06),
                            .init(color: .black, location: 0.8),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    Color.black
                }
            }
            .padding(-Self.scrollInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            // New chips are appended after the others, so once two rows are full they land below
            // the fold: bring whatever just arrived (attachment, loading placeholder, suggestion)
            // into view.
            .onChange(of: viewModel.attachments.map(\.id)) { old, new in
                guard let newest = new.last, !old.contains(newest) else { return }
                reveal(.attachment(newest), with: proxy)
            }
            .onChange(of: viewModel.pendingAttachmentLoads) { old, new in
                guard new > old else { return }
                reveal(.pending(new - 1), with: proxy)
            }
            .onChange(of: viewModel.suggestedTab?.id) { _, new in
                guard new != nil else { return }
                reveal(.suggestion, with: proxy)
            }
            .onChange(of: viewModel.suggestions.selection?.id) { _, new in
                guard new != nil else { return }
                reveal(.selection, with: proxy)
            }
            .onChange(of: viewModel.suggestions.window?.id) { _, new in
                guard new != nil else { return }
                reveal(.window, with: proxy)
            }
        }
        // Seat the chips on one sculpted clay shelf rather than making each chip its own slab. The
        // row keeps the full width (so the chips wrap against it); only the tray hugs them.
        .padding(Self.trayPadding)
        .background(alignment: .leading) {
            ClaySurface(
                shape: RoundedRectangle(cornerRadius: Self.trayCornerRadius, style: .continuous),
                style: .tray
            )
            .frame(width: trayWidth)
        }
    }

    private func reveal(_ anchor: ChipAnchor, with proxy: ScrollViewProxy) {
        // After the new chip has been laid out. Centred, so it sits clear of the edge fades; the
        // scroll view clamps at its ends.
        DispatchQueue.main.async {
            withAnimation(Theme.Motion.content) {
                proxy.scrollTo(anchor, anchor: .center)
            }
        }
    }

    private var chips: some View {
        let newestID = viewModel.attachments.last?.id
        return FlowLayout(spacing: Self.spacing, lineSpacing: Self.rowSpacing) {
            if let selection = viewModel.suggestions.selection {
                selectionChip(selection)
                    .id(ChipAnchor.selection)
                    .transition(.opacity)
            }
            ForEach(viewModel.attachments) { attachment in
                AttachmentChip(
                    attachment: attachment,
                    alwaysShowsRemove: attachment.id == newestID,
                    onRemove: { viewModel.removeAttachment(id: attachment.id) }
                )
                .id(ChipAnchor.attachment(attachment.id))
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            if let suggestion = viewModel.suggestedTab {
                GhostChip(
                    icon: .attachment(suggestion),
                    label: suggestion.displayName,
                    help: "Attach the page you're viewing so Otto can read it",
                    acceptLabel: "Attach current tab: \(GhostChip.displayLabel(suggestion.displayName))",
                    onAccept: { viewModel.acceptSuggestedTab() },
                    onDismiss: { viewModel.dismissSuggestedTab() }
                )
                .id(ChipAnchor.suggestion)
                .transition(.opacity)
            }
            if let window = viewModel.suggestions.window {
                GhostChip(
                    icon: .app(window.app),
                    label: window.label,
                    help: "Attach a picture of \(window.app.name)'s front window",
                    acceptLabel: "Attach a picture of \(window.app.name)'s front window",
                    onAccept: { viewModel.acceptSuggestedWindow() },
                    onDismiss: { viewModel.dismissSuggestedWindow() }
                )
                .id(ChipAnchor.window)
                .transition(.opacity)
            }
            ForEach(0..<max(0, viewModel.pendingAttachmentLoads), id: \.self) { index in
                PendingChip()
                    .id(ChipAnchor.pending(index))
                    .transition(.opacity)
            }
        }
        // The height decides whether the overflow fade is shown; the width sizes the tray.
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { size in
            contentHeight = size.height
            guard contentWidth != size.width else { return }
            if contentWidth > 0 {
                withAnimation(Theme.Motion.content) { contentWidth = size.width }
            } else {
                contentWidth = size.width
            }
        })
    }

    /// The offer of the text selected in the app the notch opened from: the app's icon with a quote badge,
    /// "Selection · 42 words", and the start of the text as its tooltip.
    private func selectionChip(_ selection: SelectionSuggestion) -> some View {
        let icon: GhostChip.Icon = selection.snapshot.app.map { .app($0, badgeSymbol: Self.selectionBadgeSymbol) }
            ?? .symbol("text.quote")
        let source = selection.snapshot.app.map { " from \($0.name)" } ?? ""
        return GhostChip(
            icon: icon,
            label: selection.label,
            help: Self.selectionHelp(selection.snapshot.text),
            acceptLabel: "Attach selection\(source): \(GhostChip.displayLabel(selection.label))",
            onAccept: { viewModel.acceptSuggestedSelection() },
            onDismiss: { viewModel.dismissSuggestedSelection() }
        )
    }

    /// The badge on a selection's app icon (ghost and attached chips alike).
    static let selectionBadgeSymbol = "quote.opening"
    /// How much of the selection the tooltip previews.
    static let selectionPreviewLength = 200

    /// The first 200 characters of the selection, cleaned for display, then what a click does.
    static func selectionHelp(_ text: String) -> String {
        let preview = DisplayText.sanitized(text, maxLength: selectionPreviewLength)
        let hint = "Click to attach · Nothing is sent until you press Send"
        return preview.isEmpty ? hint : preview + "\n\n" + hint
    }
}

/// Scroll targets inside the chip row.
private enum ChipAnchor: Hashable {
    case selection
    case attachment(UUID)
    case suggestion
    case window
    case pending(Int)
}

// MARK: - Chips

private extension Text {
    /// Chip label type: clearly smaller and softer than the composer's 15 pt text.
    func chipLabelStyle() -> some View {
        font(Theme.font(12.5))
            .tracking(0.1)
            .foregroundStyle(Theme.chipLabel)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// Leading glyph for an attachment: app icon for web pages, the source app's icon with a quote badge for a
/// selection, a thumbnail for images, else a type badge.
struct AttachmentIcon: View {
    let attachment: Attachment
    var size: CGFloat = 16

    /// Diameter of the quote badge on a selection's app icon.
    private static let selectionBadgeSize: CGFloat = 8

    /// Text from a selection (the chip or Services) whose app's icon can be shown.
    private var selectionAppIcon: NSImage? {
        guard attachment.kind == .text, attachment.sourceURL?.scheme == SelectionSnapshot.sourceScheme,
              let bundleID = attachment.appBundleID else { return nil }
        return AppIconCache.icon(forBundleID: bundleID)
    }

    var body: some View {
        if let appIcon = selectionAppIcon {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: ContextChipsView.selectionBadgeSymbol)
                        .font(.system(size: Self.selectionBadgeSize * 0.56, weight: .bold))
                        .foregroundStyle(Theme.badgeText)
                        .frame(width: Self.selectionBadgeSize, height: Self.selectionBadgeSize)
                        .background(Circle().fill(Theme.badgeFill))
                        .offset(x: 2, y: 2)
                        .accessibilityHidden(true)
                }
                .accessibilityHidden(true)
        } else {
            kindIcon
        }
    }

    @ViewBuilder
    private var kindIcon: some View {
        switch attachment.kind {
        case .webPage:
            if let bundleID = attachment.appBundleID, let icon = AppIconCache.icon(forBundleID: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.72, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: size, height: size)
            }
        case .image:
            if let thumbnail = attachment.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                    }
            } else {
                TypeBadge(text: attachment.badge, height: size * 0.75)
                    .frame(minWidth: size, minHeight: size)
            }
        case .pdf, .text:
            // Four-letter badges ("SWIF", "HEIC") may be wider than the icon slot; let them grow.
            TypeBadge(text: attachment.badge, height: size * 0.75)
                .frame(minWidth: size, minHeight: size)
        }
    }
}

/// Tiny off-white file-type badge with dark text ("TXT", "PDF", …).
struct TypeBadge: View {
    let text: String
    var height: CGFloat = 12

    private var label: String { String(text.prefix(4)).uppercased() }

    var body: some View {
        // At the chip size (12 pt tall) this is a 16 × 12 badge, r3, with 7 pt heavy text.
        Text(label)
            .font(.system(size: height * (label.count >= 4 ? 0.5 : 0.58), weight: .heavy, design: .rounded))
            .foregroundStyle(Theme.badgeText.opacity(0.8))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, height * 0.12)
            .frame(minWidth: height * 4 / 3, minHeight: height, maxHeight: height)
            .background(
                RoundedRectangle(cornerRadius: height * 0.25, style: .continuous)
                    .fill(Theme.badgeFill)
            )
            .shadow(color: .black.opacity(0.35), radius: 0.5, x: 0, y: 0.5)
            .accessibilityLabel(text)
    }
}

private struct AttachmentChip: View {
    let attachment: Attachment
    let alwaysShowsRemove: Bool
    let onRemove: () -> Void

    @State private var isHovering = false

    /// The hover ✕ of an older chip, shown over the end of its name.
    private var showsHoverRemove: Bool { !alwaysShowsRemove && isHovering }
    /// How much of the name fades out under the hover ✕.
    private static let hoverFadeWidth: CGFloat = 22

    private var removeLabel: String { "Remove \(attachment.displayName)" }

    // Hovering never changes the chip's size: that would re-flow the chips after it, or push a
    // chip at the end of a row onto the next one — out from under the pointer, so it would flicker
    // between rows. The newest chip always shows its ✕ in line; older chips overlay theirs on the
    // trailing edge while the end of the name fades out beneath it.
    // The newest chip (the one showing its ✕) is a raised clay capsule; a hovered chip sits on a
    // faint plate; the rest are just icon + label resting on the foam.

    var body: some View {
        HStack(spacing: ContextChipsView.iconGap) {
            AttachmentIcon(attachment: attachment, size: ContextChipsView.iconSize)
            Text(attachment.displayName)
                .chipLabelStyle()
                .frame(maxWidth: ContextChipsView.labelMaxWidth, alignment: .leading)
                .mask {
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(
                            colors: [.black, showsHoverRemove ? .clear : .black],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: Self.hoverFadeWidth)
                    }
                }
            if alwaysShowsRemove {
                ChipRemoveButton(label: removeLabel, action: onRemove)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    .padding(.leading, -2)
            }
        }
        .padding(.leading, alwaysShowsRemove ? ContextChipsView.chipPadding : ContextChipsView.plainChipPadding)
        // The ✕'s 16 pt hit area has ≈4 pt of air around the glyph, so 4 pt here puts the glyph
        // itself 8 pt from the capsule's end.
        .padding(.trailing, alwaysShowsRemove ? 4 : ContextChipsView.plainChipPadding)
        .overlay(alignment: .trailing) {
            if !alwaysShowsRemove {
                ChipRemoveButton(label: removeLabel, action: onRemove)
                    .padding(.trailing, 4)
                    .opacity(showsHoverRemove ? 1 : 0)
                    .scaleEffect(showsHoverRemove ? 1 : 0.6)
                    .allowsHitTesting(showsHoverRemove)
            }
        }
        .frame(height: alwaysShowsRemove ? ContextChipsView.selectedChipHeight : ContextChipsView.chipHeight)
        .background {
            if alwaysShowsRemove {
                // The newest chip is the one puffy clay pill on the tray.
                ClaySurface(shape: Capsule(), style: .chip)
            } else {
                Capsule().fill(isHovering ? Theme.chipLiftedFill : Theme.chipFill)
            }
        }
        .contentShape(Capsule())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { isHovering = hovering }
        }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(attachment.displayName), \(attachment.badge) attachment")
        .accessibilityAction(named: "Remove", onRemove)
    }

    private var helpText: String {
        switch attachment.payload {
        case .webPage(let title, let url):
            return "\(title)\n\(url.absoluteString)"
        default:
            let size = ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)
            return "\(attachment.displayName) — \(size)"
        }
    }
}

/// Placeholder shown while an attachment is loading.
private struct PendingChip: View {
    var body: some View {
        HStack(spacing: ContextChipsView.iconGap) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.12))
                .frame(width: ContextChipsView.iconSize, height: ContextChipsView.iconSize)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.white.opacity(0.1))
                .frame(width: 74, height: 9)
        }
        .shimmer()
        .padding(.horizontal, ContextChipsView.plainChipPadding)
        .frame(height: ContextChipsView.chipHeight)
        .background {
            Capsule().fill(Theme.chipFill)
        }
        .accessibilityLabel("Loading attachment")
    }
}
