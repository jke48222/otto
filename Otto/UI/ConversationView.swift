//
//  ConversationView.swift
//  Otto
//
//  The scrolling transcript inside the expanded notch. It hugs its content up to `maxHeight`,
//  then scrolls, and follows the bottom while a reply streams — unless the user has scrolled up
//  to read something, in which case it stays put until they scroll back down or a new turn starts.
//

import SwiftUI

struct ConversationView: View {
    let viewModel: NotchViewModel
    var maxHeight: CGFloat = 340
    /// Space above the first message, so at scroll-top it rests clear of the top fade.
    var topInset: CGFloat = 8

    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// Whether new output scrolls the transcript. Cleared when the user scrolls away from the bottom,
    /// set again when they scroll back to it, send a message or a reply starts.
    @State private var isPinnedToBottom = true
    /// Content height and viewport height at the last geometry callback (see `contentMoved`).
    @State private var lastLayout: TranscriptLayout?
    /// Pin changes are ignored until then, while our own animated scroll is still moving.
    @State private var programmaticScrollEnd: Date = .distantPast
    /// Which ends have content scrolled out of view (and so carry a fade).
    @State private var clippedEdges = ClippedEdges()

    private static let bottomAnchorID = "conversation-bottom"
    private static let scrollSpace = "conversation-scroll"
    /// The top fade runs from the header's bottom edge; the bottom one sits above the composer.
    private static let topFade: CGFloat = 22
    private static let bottomFade: CGFloat = 18
    /// Eased rather than linear: a linear ramp leaves glyphs at the very edge at ~10 % and they
    /// still read as cut; easing in keeps the first few points nearly clear.
    private static let fadeStops: [Gradient.Stop] = [
        .init(color: .clear, location: 0),
        .init(color: .black.opacity(0.08), location: 0.25),
        .init(color: .black.opacity(0.35), location: 0.5),
        .init(color: .black.opacity(0.75), location: 0.75),
        .init(color: .black, location: 1),
    ]
    /// How close to the bottom still counts as "at the bottom".
    private static let pinTolerance: CGFloat = 24

    private var messages: [ChatMessage] { viewModel.chat.messages }

    /// Changes whenever the visible tail of the transcript grows (new turn, text, activity, …).
    /// Thinking text is left out: it is hidden while it streams.
    private var tailSignature: TailSignature {
        let last = messages.last
        return TailSignature(
            count: messages.count,
            textLength: last?.text.utf8.count ?? 0,
            activities: last?.activities.count ?? 0,
            finishedActivities: last?.activities.filter(\.isDone).count ?? 0,
            sources: last?.sources.count ?? 0,
            isThinking: last?.isThinking ?? false
        )
    }

    private var isScrollable: Bool { contentHeight > maxHeight + 0.5 }

    var body: some View {
        ScrollViewReader { proxy in
            CappedHeightLayout(maxHeight: maxHeight) {
                transcript
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { _ in
                        viewportMoved(proxy)
                    }
            }
            .mask { fadeMask }
            .onAppear {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: messages.count) {
                // A new turn (sent, retried or cleared): follow it again.
                followBottom(proxy, animated: true)
            }
            .onChange(of: viewModel.chat.isStreaming) { _, isStreaming in
                if isStreaming { followBottom(proxy, animated: true) }
            }
            .onChange(of: tailSignature) {
                guard viewModel.chat.isStreaming, isPinnedToBottom else { return }
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: maxHeight) {
                guard isPinnedToBottom else { return }
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private var transcript: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(messages) { message in
                        MessageView(message: message, viewModel: viewModel, isLast: message.id == messages.last?.id)
                            .equatable()
                            .id(message.id)
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                }
                .padding(.bottom, 2)
                // Last, below the padding: scrolling it to the bottom leaves nothing beyond the
                // viewport, so the bottom edge reads as unclipped and carries no fade.
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomAnchorID)
            }
            .padding(.top, topInset)
            // Drives the edge fades and the pin state; the height itself is resolved in-pass by the layout.
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.scrollSpace)) }, action: contentMoved)
        }
        .coordinateSpace(.named(Self.scrollSpace))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height in
            if viewportHeight != height { viewportHeight = height }
        })
        .scrollIndicators(.never)
        .defaultScrollAnchor(.bottom)
    }

    /// Re-pins and scrolls to the bottom.
    private func followBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if !isPinnedToBottom { isPinnedToBottom = true }
        guard animated else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            return
        }
        programmaticScrollEnd = Date().addingTimeInterval(0.6)
        withAnimation(Theme.Motion.content) {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    /// The viewport moved or scaled in the window, as it does all through the panel's open
    /// transition. AppKit nudges the scroll offset on every frame of that, and the nudges add up to a
    /// few points short of the bottom: enough to leave the last row under the bottom fade. So while
    /// pinned, go back to the bottom each time; a user scroll never moves the viewport itself.
    private func viewportMoved(_ proxy: ScrollViewProxy) {
        guard isPinnedToBottom, Date() >= programmaticScrollEnd else { return }
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
    }

    /// The content moved inside the scroll view. When neither the content nor the viewport changed
    /// size, the move is a scroll — by the user, or ours to the bottom — so it decides the pin:
    /// pinned exactly when the bottom is (nearly) in view. Growth and resizes also move the content
    /// relative to the viewport but say nothing about what the user wants, so they keep the pin.
    private func contentMoved(_ frame: CGRect) {
        if contentHeight != frame.height { contentHeight = frame.height }
        let edges = ClippedEdges(
            top: frame.minY < -0.5,
            bottom: frame.maxY > viewportHeight + 0.5 && viewportHeight > 0
        )
        if clippedEdges != edges { clippedEdges = edges }
        let layout = TranscriptLayout(contentHeight: frame.height, viewportHeight: viewportHeight)
        defer {
            if lastLayout != layout { lastLayout = layout }
        }
        guard lastLayout == layout, Date() >= programmaticScrollEnd else { return }
        let pinned = frame.maxY - viewportHeight <= Self.pinTolerance
        if isPinnedToBottom != pinned { isPinnedToBottom = pinned }
    }

    /// Soft fades on whichever edge has content scrolled past it, so text slides under the
    /// header and the composer instead of being cut; an edge with nothing beyond it stays crisp.
    private var fadeMask: some View {
        let top = isScrollable && clippedEdges.top ? Self.topFade : 0
        let bottom = isScrollable && clippedEdges.bottom ? Self.bottomFade : 0
        return VStack(spacing: 0) {
            LinearGradient(stops: Self.fadeStops, startPoint: .top, endPoint: .bottom)
                .frame(height: top)
            Rectangle().fill(Color.black)
            LinearGradient(stops: Self.fadeStops, startPoint: .bottom, endPoint: .top)
                .frame(height: bottom)
        }
        .animation(.easeOut(duration: 0.18), value: clippedEdges)
    }
}

private struct ClippedEdges: Equatable {
    var top = false
    var bottom = false
}

private struct TailSignature: Equatable {
    var count: Int
    var textLength: Int
    var activities: Int
    var finishedActivities: Int
    var sources: Int
    var isThinking: Bool
}

private struct TranscriptLayout: Equatable {
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
}

/// Sizes its single child (a scroll view) to the child's ideal height, capped at `maxHeight`, in the
/// same layout pass — so the panel resizes in one smooth step instead of after a measurement.
struct CappedHeightLayout: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, max(0, maxHeight)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for child in subviews {
            child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}
