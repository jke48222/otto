//
//  ClosedNotchView.swift
//  Otto
//
//  The closed notch (§4.2). The view model's resolver decides the one thing it shows and
//  `ClosedNotchLayout` decides its size, which this view fills exactly, so what is drawn and what the
//  window controller hit-tests are the same shape. Three forms: the listening pill, ears beside the
//  camera housing, and ears plus the drop line under it. Clicks follow the §4.2 table.
//

import SwiftUI

struct ClosedNotchView: View {
    let viewModel: NotchViewModel
    /// `viewModel.closedGlance` and `viewModel.closedLayout`, read once by the root for this frame.
    let glance: ClosedGlance
    let layout: ClosedNotchLayout.Result

    @State private var isDropHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width of one ear's glyph box: the ear minus the concave top corner that flares into the bezel.
    static let earWidth: CGFloat = NotchMetrics.activityEarWidth - NotchMetrics.closedTopRadius

    // MARK: - Pure

    /// What a click on the closed notch does (§4.2 "Click" column).
    enum ClickAction: Equatable {
        /// Listening: the gesture that started it keeps going.
        case none
        /// A reply preview: open at the start of that answer.
        case openToReply(UUID)
        /// Speaking after the reply finished: stop the speech, then open.
        case stopSpeakingAndOpen
        /// Everything else opens focused (an unread reply lands at its start through the view model).
        case open
    }

    static func clickAction(for glance: ClosedGlance, isListening: Bool) -> ClickAction {
        if isListening { return .none }
        if case .preview(let preview)? = glance.drop { return .openToReply(preview.id) }
        if glance.drop == nil, glance.left == .orb(active: false), glance.right == .speaking {
            return .stopSpeakingAndOpen
        }
        return .open
    }

    /// The gap between the ears: the camera housing, plus the hover grow while the pointer rests on it.
    static func earGap(notchWidth: CGFloat, isHovering: Bool) -> CGFloat {
        notchWidth + (isHovering ? ClosedNotchLayout.hoverGrowth.width : 0)
    }

    /// Height of the ear row: the shape minus the drop line under it.
    static func earRowHeight(layout: ClosedNotchLayout.Result, hasDrop: Bool) -> CGFloat {
        max(0, layout.size.height - (hasDrop ? ReplyPreviewMetrics.dropHeight : 0))
    }

    /// VoiceOver: what the notch shows, then what a click does.
    static func accessibilityLabel(for glance: ClosedGlance) -> String {
        guard glance.hasEars || glance.drop != nil else { return "Open Otto" }
        return "\(glance.accessibilityLabel). Open Otto"
    }

    // MARK: - Body

    var body: some View {
        let isListening = layout.showsPill
        ZStack(alignment: .top) {
            if isListening {
                VoiceListeningPill(
                    notchSize: viewModel.closedNotchSize,
                    meter: viewModel.voice.meter,
                    finalizedText: viewModel.voice.finalizedText,
                    volatileText: viewModel.voice.volatileText,
                    isFinishing: viewModel.voice.phase == .finishing
                )
                .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    earRow
                        .frame(height: Self.earRowHeight(layout: layout, hasDrop: glance.drop != nil))
                    if let drop = glance.drop {
                        ReplyPreviewDrop(content: drop, isHovered: dropHoverBinding(for: drop))
                            .transition(ReplyPreviewDrop.transition(reduceMotion: reduceMotion))
                    }
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { perform(Self.clickAction(for: glance, isListening: isListening)) }
        .accessibilityElement(children: isListening ? .contain : .ignore)
        .modifier(ClosedAccessibility(isListening: isListening, label: Self.accessibilityLabel(for: glance)) {
            perform(Self.clickAction(for: glance, isListening: isListening))
        })
    }

    /// Ears flank the camera housing; with a wider drop under it they stay beside the camera.
    private var earRow: some View {
        HStack(spacing: 0) {
            ear(glance.left)
            Color.clear
                .frame(width: Self.earGap(notchWidth: viewModel.closedNotchSize.width, isHovering: viewModel.isHovering))
            ear(glance.right)
        }
        .frame(maxWidth: .infinity)
    }

    private func ear(_ glyph: EarGlyph) -> some View {
        ZStack {
            if glyph != .none {
                EarGlyphView(glyph: glyph, nowPlaying: viewModel.nowPlaying, isVisible: !viewModel.isOpen)
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.6)))
            }
        }
        .frame(width: Self.earWidth)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.2), value: glyph)
    }

    /// A reply preview pauses its countdown while hovered; the other drops only brighten.
    private func dropHoverBinding(for drop: DropContent) -> Binding<Bool> {
        let glance = viewModel.glance
        guard case .preview = drop else { return $isDropHovered }
        return Binding(get: { glance.isPreviewHovered }, set: { glance.isPreviewHovered = $0 })
    }

    private func perform(_ action: ClickAction) {
        switch action {
        case .none:
            return
        case .openToReply(let messageID):
            viewModel.openToReply(messageID)
        case .stopSpeakingAndOpen:
            viewModel.stopSpeaking()
            viewModel.open(reason: .click, focus: true)
        case .open:
            viewModel.open(reason: .click, focus: true)
        }
    }
}

/// The listening pill describes itself; every other form is one button that opens Otto.
private struct ClosedAccessibility: ViewModifier {
    let isListening: Bool
    let label: String
    let action: () -> Void

    func body(content: Content) -> some View {
        if isListening {
            content
        } else {
            content
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, action)
        }
    }
}
