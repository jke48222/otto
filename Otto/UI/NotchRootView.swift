//
//  NotchRootView.swift
//  Otto
//
//  Root of the notch window. Draws the notch shape top-centred in the fixed-size window and
//  morphs it between the closed silhouette (hidden inside the camera housing, optionally with
//  activity "ears") and the expanded clay panel.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    @Bindable var viewModel: NotchViewModel

    /// Menus currently tracking (⋮ / + / context menus) — keeps the notch open while shown.
    @State private var trackingMenus: Set<ObjectIdentifier> = []

    /// Subtle grow of the closed notch while the pointer rests on it.
    static let hoverGrowth = CGSize(width: 8, height: 3)

    private static let dropTypes: [UTType] = [.fileURL, .image, .url, .plainText]

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
    }

    private var closedShapeSize: CGSize {
        var size = viewModel.closedNotchSize
        if viewModel.showsClosedActivity {
            size.width += NotchMetrics.activityEarWidth * 2
        }
        if viewModel.isHovering {
            size.width += Self.hoverGrowth.width
            size.height += Self.hoverGrowth.height
        }
        return size
    }

    /// Structural changes that resize the open panel and deserve a spring (streamed text does not).
    /// Only O(1) reads of `chat.messages` (count, last state), so re-evaluating it per delta is cheap.
    private var contentSignature: NotchContentSignature {
        NotchContentSignature(
            messageCount: viewModel.chat.messageCount,
            lastMessageState: viewModel.chat.lastMessageState,
            attachmentIDs: viewModel.attachments.map(\.id),
            suggestionID: viewModel.suggestedTab?.id,
            pendingLoads: viewModel.pendingAttachmentLoads,
            hasError: viewModel.transientError != nil,
            isDropTargeted: viewModel.isDropTargeted
        )
    }

    var body: some View {
        let isOpen = viewModel.isOpen
        let closedSize = closedShapeSize
        let shape = NotchShape(
            topRadius: isOpen ? NotchMetrics.openTopRadius : NotchMetrics.closedTopRadius,
            bottomRadius: isOpen ? NotchMetrics.openBottomRadius : NotchMetrics.closedBottomRadius
        )

        NotchContainerLayout(isOpen: isOpen, closedSize: closedSize) {
            if isOpen {
                NotchOpenContent(viewModel: viewModel)
                    .layoutValue(key: NotchLayerKey.self, value: .open)
                    .transition(
                        .asymmetric(
                            insertion: .notchReveal.animation(Theme.Motion.open.delay(0.05)),
                            removal: .notchConceal.animation(.easeOut(duration: 0.14))
                        )
                    )
            } else {
                ClosedNotchContent(viewModel: viewModel, size: closedSize)
                    .layoutValue(key: NotchLayerKey.self, value: .closed)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .clipShape(shape)
        .background {
            NotchBackground(isOpen: isOpen, shape: shape)
        }
        .contentShape(shape)
        .onDrop(of: Self.dropTypes, isTargeted: $viewModel.isDropTargeted) { providers in
            viewModel.handleDrop(providers)
        }
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: reportShapeSize)
        .animation(isOpen ? Theme.Motion.open : Theme.Motion.close, value: isOpen)
        .animation(Theme.Motion.hover, value: closedSize)
        .animation(Theme.Motion.content, value: contentSignature)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { note in
            guard let menu = note.object as? NSMenu else { return }
            trackingMenus.insert(ObjectIdentifier(menu))
            syncMenuPresentation()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { note in
            guard let menu = note.object as? NSMenu else { return }
            trackingMenus.remove(ObjectIdentifier(menu))
            syncMenuPresentation()
        }
    }

    private func reportShapeSize(_ size: CGSize) {
        guard viewModel.renderedShapeSize != size else { return }
        viewModel.renderedShapeSize = size
    }

    private func syncMenuPresentation() {
        let presented = !trackingMenus.isEmpty
        if viewModel.isMenuPresented != presented {
            viewModel.isMenuPresented = presented
        }
    }
}

private struct NotchContentSignature: Equatable {
    var messageCount: Int
    var lastMessageState: MessageState?
    var attachmentIDs: [UUID]
    var suggestionID: UUID?
    var pendingLoads: Int
    var hasError: Bool
    var isDropTargeted: Bool
}

// MARK: - Container layout

private enum NotchLayer {
    case closed
    case open
}

private struct NotchLayerKey: LayoutValueKey {
    static let defaultValue: NotchLayer = .closed
}

/// Sizes the notch from its *current* layer rather than the union of its children, so the shape
/// can shrink immediately on close while the open content fades out inside it, and grow to the
/// open content's exact height in the same pass that inserts it (no measurement round-trip).
private struct NotchContainerLayout: Layout {
    var isOpen: Bool
    var closedSize: CGSize

    private static let openProposal = ProposedViewSize(width: NotchMetrics.openWidth, height: nil)

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard isOpen else { return closedSize }
        guard let content = subviews.last(where: { $0[NotchLayerKey.self] == .open }) else { return closedSize }
        let contentHeight = content.sizeThatFits(Self.openProposal).height
        let height = min(max(contentHeight, closedSize.height), NotchMetrics.maxOpenHeight)
        return CGSize(width: NotchMetrics.openWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let topCenter = CGPoint(x: bounds.midX, y: bounds.minY)
        for subview in subviews {
            switch subview[NotchLayerKey.self] {
            case .open:
                let height = subview.sizeThatFits(Self.openProposal).height
                subview.place(
                    at: topCenter,
                    anchor: .top,
                    proposal: ProposedViewSize(width: NotchMetrics.openWidth, height: height)
                )
            case .closed:
                subview.place(at: topCenter, anchor: .top, proposal: ProposedViewSize(closedSize))
            }
        }
    }
}

// MARK: - Surface

private struct NotchBackground: View {
    let isOpen: Bool
    let shape: NotchShape

    /// Strength of the panel's foam relative to the composer's: the base is a smooth matte
    /// near-black, and the texture belongs to the raised forms.
    private static let grainIntensity: Double = 0.3
    /// No grain in the band beside the (pure black) camera housing, so it stays as dark as the
    /// housing itself; below it the grain fades in over `grainTopFade`.
    private static let grainTopClear: CGFloat = 36
    private static let grainTopFade: CGFloat = 20

    var body: some View {
        shape
            .fill(isOpen ? Theme.panel : Color.black)
            .overlay {
                // The same foam as the clay, much fainter, so the raised forms and the base read as
                // one material. No light falls in from the top edge: the band beside the camera
                // housing must match its black. The grain fades out there and whenever the panel
                // is closed or collapsing, so the closed notch stays pure black.
                ClayGrain(intensity: Self.grainIntensity)
                    .clipShape(shape)
                    .mask(alignment: .top) {
                        VStack(spacing: 0) {
                            Color.clear
                                .frame(height: Self.grainTopClear)
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: Self.grainTopFade)
                            Color.black
                        }
                    }
                    .opacity(isOpen ? 1 : 0)
                    .animation(isOpen ? .easeIn(duration: 0.3).delay(0.08) : .easeOut(duration: 0.08), value: isOpen)
            }
            .overlay {
                // A faint rim catching light along the bottom curve only: it fades out up the
                // rounded corners, so the vertical sides carry none.
                shape
                    .stroke(Color.white.opacity(0.05), lineWidth: 2)
                    .clipShape(shape)
                    .mask(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: NotchMetrics.openBottomRadius)
                    }
                    .opacity(isOpen ? 1 : 0)
            }
            .compositingGroup()
            .shadow(color: Color.black.opacity(isOpen ? 0.50 : 0), radius: 24, x: 0, y: 10)
            .shadow(color: Color.black.opacity(isOpen ? 0.30 : 0), radius: 4, x: 0, y: 2)
            .allowsHitTesting(false)
    }
}

// MARK: - Closed

private struct ClosedNotchContent: View {
    let viewModel: NotchViewModel
    let size: CGSize

    private var earWidth: CGFloat { NotchMetrics.activityEarWidth - NotchMetrics.closedTopRadius }

    var body: some View {
        ZStack {
            if viewModel.showsClosedActivity {
                HStack(spacing: 0) {
                    OttoOrb(size: 12, isActive: viewModel.chat.isStreaming)
                        .frame(width: earWidth)
                    Spacer(minLength: 0)
                    rightEar
                        .frame(width: earWidth)
                }
                .padding(.horizontal, NotchMetrics.closedTopRadius)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.open(reason: .click, focus: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { viewModel.open(reason: .click, focus: true) }
    }

    @ViewBuilder
    private var rightEar: some View {
        if viewModel.chat.isStreaming {
            ActivityEqualizer()
        } else if viewModel.hasUnreadReply {
            Circle()
                .fill(Theme.orbLight)
                .frame(width: 6, height: 6)
                .shadow(color: Theme.orbLight.opacity(0.7), radius: 4)
        }
    }

    private var accessibilityLabel: String {
        if viewModel.chat.isStreaming { return "Otto is replying. Open Otto" }
        if viewModel.hasUnreadReply { return "Otto has a new reply. Open Otto" }
        return "Open Otto"
    }
}

// MARK: - Open

private struct NotchOpenContent: View {
    let viewModel: NotchViewModel
    @State private var lowerSectionHeight: CGFloat = 0

    private static let horizontalPadding: CGFloat = 16
    /// One rhythm: header → tray (or composer) and tray → composer are both 10 pt.
    private static let topGap: CGFloat = 10
    private static let bottomPadding: CGFloat = 16
    private static let sectionSpacing: CGFloat = 12
    private static let preferredConversationHeight: CGFloat = 340
    private static let minimumConversationHeight: CGFloat = 110

    /// The header sits beside the camera housing (the closed notch's height), but never shorter
    /// than the ⋮ pebble plus its clearance above and below.
    private var headerHeight: CGFloat { max(viewModel.closedNotchSize.height, NotchHeaderView.minimumHeight) }

    private var showsChips: Bool {
        !viewModel.attachments.isEmpty || viewModel.suggestedTab != nil || viewModel.pendingAttachmentLoads > 0
    }

    /// Keeps the whole panel within `NotchMetrics.maxOpenHeight` when the composer grows or chips wrap.
    private var conversationMaxHeight: CGFloat {
        let chrome = headerHeight + Self.topGap + Self.bottomPadding + Self.sectionSpacing + lowerSectionHeight
        let available = NotchMetrics.maxOpenHeight - chrome
        return max(Self.minimumConversationHeight, min(Self.preferredConversationHeight, available))
    }

    var body: some View {
        VStack(spacing: 0) {
            NotchHeaderView(viewModel: viewModel)
                .frame(height: headerHeight)
                .padding(.horizontal, NotchHeaderView.horizontalPadding)

            VStack(spacing: Self.sectionSpacing) {
                ConversationSection(viewModel: viewModel, maxHeight: conversationMaxHeight, headerGap: Self.topGap)
                VStack(spacing: Self.topGap) {
                    if showsChips {
                        ContextChipsView(viewModel: viewModel)
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
                    }
                    ComposerView(viewModel: viewModel)
                    if let error = viewModel.transientError {
                        TransientErrorLine(message: error)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { lowerSectionHeight = $0 })
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.top, Self.topGap)
            .padding(.bottom, Self.bottomPadding)
            .overlay {
                if viewModel.isDropTargeted {
                    DropTargetOverlay()
                        .padding(EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8))
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
        }
        .padding(.horizontal, NotchMetrics.openTopRadius)
        .frame(width: NotchMetrics.openWidth)
    }
}

/// The transcript, once there is one. It reads `chat.messages` here rather than in
/// `NotchOpenContent`, so a streamed delta re-evaluates this small view and the conversation, not
/// the header, chips and composer around them. With no messages it contributes no view (and so no
/// stack spacing) at all.
private struct ConversationSection: View {
    let viewModel: NotchViewModel
    let maxHeight: CGFloat
    /// The gap the container leaves under the header. The transcript reaches up through it, so its
    /// top fade starts right at the header's bottom edge, and insets its first message by as much.
    let headerGap: CGFloat

    var body: some View {
        if !viewModel.chat.messages.isEmpty {
            ConversationView(viewModel: viewModel, maxHeight: maxHeight + headerGap, topInset: headerGap)
                .padding(.top, -headerGap)
                .transition(.opacity)
        }
    }
}

private struct TransientErrorLine: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(message)
                .font(Theme.font(12))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.error)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct DropTargetOverlay: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        shape
            .fill(Theme.panel.opacity(0.88))
            .overlay {
                shape.strokeBorder(
                    Theme.sendFill.opacity(0.75),
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                )
            }
            .overlay {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 14, weight: .medium))
                    Text("Drop to attach")
                        .font(Theme.font(14, .medium))
                }
                .foregroundStyle(Theme.sendFill)
            }
            .allowsHitTesting(false)
            .accessibilityLabel("Drop to attach")
    }
}

// MARK: - Transitions

/// Open content arrives from the notch: fades in while un-blurring and settling down from the top.
private struct NotchRevealModifier: ViewModifier {
    var progress: Double

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 8)
            .scaleEffect(0.96 + 0.04 * progress, anchor: .top)
            .offset(y: (1 - progress) * -14)
    }
}

private extension AnyTransition {
    static var notchReveal: AnyTransition {
        .modifier(active: NotchRevealModifier(progress: 0), identity: NotchRevealModifier(progress: 1))
    }

    static var notchConceal: AnyTransition {
        .modifier(active: NotchRevealModifier(progress: 0.2), identity: NotchRevealModifier(progress: 1))
            .combined(with: .opacity)
    }
}
