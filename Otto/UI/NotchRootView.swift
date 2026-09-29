//
//  NotchRootView.swift
//  Otto
//
//  Root of the notch window. Draws the notch shape top-centred in the fixed-size window and morphs it
//  between the closed notch (ClosedNotchView: pure black, sized by the view model's ClosedNotchLayout)
//  and the expanded clay panel (NotchOpenContent, up to the view model's open height limit). It also
//  routes drops over the shape through NotchDropDelegate, tracks open menus so an outside click can't
//  close the notch under one, and reports the rendered shape size the window controller hit-tests.
//

import AppKit
import SwiftUI

struct NotchRootView: View {
    @Bindable var viewModel: NotchViewModel

    /// Menus currently tracking (⋮ / + / model / context menus) — keeps the notch open while shown.
    @State private var trackingMenus: Set<ObjectIdentifier> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Subtle grow of the closed notch while the pointer rests on it.
    static let hoverGrowth = ClosedNotchLayout.hoverGrowth

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
    }

    /// Structural changes that resize the open panel and deserve a spring (streamed text does not).
    /// Only O(1) reads of `chat.messages` (count, last state), so re-evaluating it per delta is cheap.
    private var contentSignature: NotchContentSignature {
        let glance = viewModel.settings.glance
        let hasMedia = glance.nowPlayingEnabled && viewModel.nowPlaying.item != nil
        let hasEvent = glance.calendarChipEnabled && viewModel.calendar.next != nil
        let rowHeight = viewModel.route == .chat ? GlanceRow.height(hasMedia: hasMedia, hasEvent: hasEvent) : 0
        let suggestions = viewModel.suggestions
        return NotchContentSignature(
            messageCount: viewModel.chat.messageCount,
            lastMessageState: viewModel.chat.lastMessageState,
            attachmentIDs: viewModel.attachments.map(\.id),
            suggestionID: viewModel.suggestedTab?.id,
            pendingLoads: viewModel.pendingAttachmentLoads,
            hasError: viewModel.transientError != nil,
            isDropTargeted: viewModel.isDropTargeted,
            route: viewModel.route,
            overlay: viewModel.overlay,
            promptID: viewModel.currentPrompt?.id,
            glanceRowHeightBucket: NotchLayout.glanceRowHeightBucket(rowHeight),
            continuationID: viewModel.chat.messageCount == 0 ? viewModel.history.continuation?.id : nil,
            isEditing: viewModel.isEditing,
            hasNotice: viewModel.transientNotice != nil,
            isTallMode: viewModel.isTallMode,
            voicePhase: viewModel.voice.phase,
            dropZone: viewModel.dropSession?.zone,
            insertActivity: viewModel.inserter.activity,
            suggestionIDs: [suggestions.selection?.id, suggestions.window?.id].compactMap { $0 },
            composerGateID: viewModel.route == .chat ? viewModel.composerGate?.id : nil
        )
    }

    var body: some View {
        let isOpen = viewModel.isOpen
        let glance = viewModel.closedGlance
        let closedLayout = viewModel.closedLayout
        let shape = NotchShape(
            topRadius: isOpen ? NotchMetrics.openTopRadius : NotchMetrics.closedTopRadius,
            bottomRadius: isOpen ? NotchMetrics.openBottomRadius : closedLayout.bottomRadius
        )

        NotchContainerLayout(isOpen: isOpen, closedSize: closedLayout.size, maxHeight: viewModel.openHeightLimit) {
            if isOpen {
                NotchOpenContent(viewModel: viewModel)
                    .layoutValue(key: NotchLayerKey.self, value: .open)
                    .transition(openTransition)
            } else {
                ClosedNotchView(viewModel: viewModel, glance: glance, layout: closedLayout)
                    .layoutValue(key: NotchLayerKey.self, value: .closed)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .clipShape(shape)
        .background {
            NotchBackground(isOpen: isOpen, shape: shape)
        }
        .contentShape(shape)
        .onDrop(of: NotchDropDelegate.acceptedTypes, delegate: NotchDropDelegate(viewModel: viewModel))
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: reportShapeSize)
        .animation(isOpen ? Theme.Motion.open : Theme.Motion.close, value: isOpen)
        .animation(closedAnimation(for: closedLayout, glance: glance), value: closedLayout)
        .animation(Theme.Motion.content, value: contentSignature)
        .animation(Theme.Motion.content, value: viewModel.openHeightLimit)
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

    /// Open content un-blurs down out of the notch; Reduce Motion fades it (no blur, scale or offset).
    private var openTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .asymmetric(
            insertion: .notchReveal.animation(Theme.Motion.open.delay(0.05)),
            removal: .notchConceal.animation(.easeOut(duration: 0.14))
        )
    }

    /// The listening pill springs in; a drop line grows with the open spring (glance.md §1.3); the hover
    /// grow keeps its own spring. Reduce Motion: 0.15 s fades.
    private func closedAnimation(for layout: ClosedNotchLayout.Result, glance: ClosedGlance) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        if layout.showsPill { return VoiceListeningPill.appearAnimation }
        if glance.drop != nil { return Theme.Motion.open }
        return Theme.Motion.hover
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

/// Structural facts about the open panel; when one changes, the panel's height springs (§4.3).
private struct NotchContentSignature: Equatable {
    var messageCount: Int
    var lastMessageState: MessageState?
    var attachmentIDs: [UUID]
    var suggestionID: UUID?
    var pendingLoads: Int
    var hasError: Bool
    var isDropTargeted: Bool
    var route: NotchRoute
    var overlay: NotchOverlay?
    var promptID: String?
    var glanceRowHeightBucket: Int
    var continuationID: UUID?
    var isEditing: Bool
    var hasNotice: Bool
    var isTallMode: Bool
    var voicePhase: VoicePhase
    var dropZone: DropZone?
    var insertActivity: InsertActivity?
    var suggestionIDs: [UUID]
    /// The composer gate line (§14.10.1): the panel re-measures when it appears, changes or goes.
    var composerGateID: String?
}

// MARK: - Container layout

private enum NotchLayer {
    case closed
    case open
}

private struct NotchLayerKey: LayoutValueKey {
    static let defaultValue: NotchLayer = .closed
}

/// Sizes the notch from its *current* layer rather than the union of its children, so the shape can
/// shrink immediately on close while the open content fades out inside it, and grow to the open
/// content's exact height (capped at `maxHeight`, the view model's open height limit) in the same pass
/// that inserts it (no measurement round-trip).
private struct NotchContainerLayout: Layout {
    var isOpen: Bool
    var closedSize: CGSize
    var maxHeight: CGFloat

    private static let openProposal = ProposedViewSize(width: NotchMetrics.openWidth, height: nil)

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard isOpen else { return closedSize }
        guard let content = subviews.last(where: { $0[NotchLayerKey.self] == .open }) else { return closedSize }
        let contentHeight = content.sizeThatFits(Self.openProposal).height
        let height = NotchLayout.openShapeHeight(contentHeight: contentHeight, closedHeight: closedSize.height,
                                                 openHeightLimit: maxHeight)
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

// MARK: - Transitions

/// Open content arrives from the notch: fades in while un-blurring and settling down from the top.
/// Internal so the transcript's scroll tests can put it through the same frames.
struct NotchRevealModifier: ViewModifier {
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
