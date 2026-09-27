//
//  ConversationView.swift
//  Otto
//
//  The scrolling transcript inside the expanded notch. It hugs its content up to `maxHeight` (or fills it in
//  tall mode), then scrolls, and follows the bottom while a reply streams — unless the user has scrolled up to
//  read something, in which case it stays put and offers "Latest ↓". It reports where the user is reading, and
//  lands on the start of a reply (or where the user left off) when the view model asks through a reading anchor.
//

import SwiftUI

struct ConversationView: View {
    let viewModel: NotchViewModel
    let maxHeight: CGFloat
    /// Space above the first message, so at scroll-top it rests clear of the top fade.
    let topInset: CGFloat
    /// Tall reading mode: the transcript takes all of `maxHeight` even when its content is shorter.
    let fillsHeight: Bool

    init(viewModel: NotchViewModel, maxHeight: CGFloat = 340, topInset: CGFloat = 8, fillsHeight: Bool = false) {
        self.viewModel = viewModel
        self.maxHeight = maxHeight
        self.topInset = topInset
        self.fillsHeight = fillsHeight
    }

    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// Whether new output scrolls the transcript. Cleared when the user scrolls away from the bottom or a reading
    /// anchor is restored, set again when they scroll back to it, send a message or a reply starts.
    @State private var isPinnedToBottom = true
    /// Content height and viewport height at the last geometry callback (see `contentMoved`).
    @State private var lastLayout: TranscriptLayout?
    /// Pin changes are ignored until then, while our own scroll is still moving.
    @State private var programmaticScrollEnd: Date = .distantPast
    /// Which ends have content scrolled out of view (and so carry a fade).
    @State private var clippedEdges = ClippedEdges()
    /// Row frames and the report/restore tasks. A reference that is never observed: several handlers of one
    /// update read what another just wrote, and none of it needs a re-render.
    @State private var scroll = ScrollBookkeeping()

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
    /// The invisible marker above each message: scrolling it to the top leaves the start of the turn
    /// just under the top fade.
    private static let anchorMarkerHeight: CGFloat = 22
    /// How long after the last user scroll the reading position is reported.
    private static let reportDelay: Duration = .milliseconds(400)
    /// How long our own scroll may keep moving the content before pin changes count again.
    private static let programmaticScrollWindow: TimeInterval = 0.6

    private var messages: [ChatMessage] { viewModel.chat.messages }

    /// Changes whenever the visible tail of the transcript grows (new turn, text, activity, action rows, …).
    /// Thinking text is left out: it is hidden while it streams.
    private var tailSignature: TailSignature {
        let last = messages.last
        return TailSignature(
            count: messages.count,
            textLength: last?.text.utf8.count ?? 0,
            activities: last?.activities.count ?? 0,
            finishedActivities: last?.activities.filter(\.isDone).count ?? 0,
            sources: last?.sources.count ?? 0,
            toolCalls: last?.toolCalls.count ?? 0,
            settledToolCalls: last?.toolCalls.filter(\.status.isTerminal).count ?? 0,
            isThinking: last?.isThinking ?? false
        )
    }

    /// Which conversation is shown and how many turns it has: a new conversation is a swap (restored, not
    /// followed); a new turn in the same one is followed.
    private var transcriptKey: TranscriptKey {
        TranscriptKey(conversationID: viewModel.chat.conversationID, count: messages.count)
    }

    private var isScrollable: Bool { contentHeight > maxHeight + 0.5 }

    private var showsJumpToLatest: Bool { !isPinnedToBottom && clippedEdges.bottom && isScrollable }

    var body: some View {
        ScrollViewReader { proxy in
            CappedHeightLayout(maxHeight: maxHeight, minHeight: fillsHeight ? maxHeight : 0) {
                transcript
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { _ in
                        viewportMoved(proxy)
                    }
            }
            .mask { fadeMask }
            .overlay(alignment: .bottom) {
                ZStack {
                    if showsJumpToLatest {
                        JumpToLatestPill { followBottom(proxy, animated: true) }
                            .padding(.bottom, 4)
                            .transition(JumpToLatestPill.transition)
                    }
                }
                .animation(Theme.Motion.content, value: showsJumpToLatest)
            }
            .onAppear {
                if let anchor = viewModel.consumeReadingAnchor() {
                    restore(anchor, proxy: proxy)
                } else {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            .onDisappear {
                scroll.cancelAll()
            }
            .onChange(of: transcriptKey) { old, new in
                if old.conversationID != new.conversationID {
                    conversationSwapped(proxy)
                } else if let anchor = viewModel.consumeReadingAnchor() {
                    restore(anchor, proxy: proxy)
                } else {
                    // A new turn (sent, retried, regenerated or cleared): follow it again.
                    followBottom(proxy, animated: true)
                }
            }
            .onChange(of: viewModel.readingAnchor) { _, anchor in
                guard anchor != nil, let anchor = viewModel.consumeReadingAnchor() else { return }
                restore(anchor, proxy: proxy)
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
            .onChange(of: isPinnedToBottom) {
                // A restore reports once it has landed; mid-restore the frames are still the old ones.
                guard !scroll.isRestoring else { return }
                reportReadingPosition()
            }
        }
    }

    private var transcript: some View {
        let versions = viewModel.chat.lastTurnVersions
        let lastID = messages.last?.id
        return ScrollView(.vertical) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(messages) { message in
                        MessageView(
                            message: message,
                            viewModel: viewModel,
                            isLast: message.id == lastID,
                            unavailableAttachmentIDs: unavailableAttachmentIDs(of: message),
                            versionInfo: message.id == lastID ? versionInfo(of: message, versions: versions) : nil,
                            insertTarget: insertTarget(of: message)
                        )
                        .equatable()
                        // Every turn gets a marker, not only replies: a saved reading position may name the
                        // question the user was reading.
                        .overlay(alignment: .top) { anchorMarker(for: message.id) }
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.scrollSpace)) }) { frame in
                            scroll.rowFrames[message.id] = frame
                        }
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

    /// Sits `anchorMarkerHeight` above the message (placed by an alignment guide, so its layout frame really is
    /// there and `scrollTo` lands on it).
    private func anchorMarker(for messageID: UUID) -> some View {
        Color.clear
            .frame(height: Self.anchorMarkerHeight)
            .alignmentGuide(.top) { dimensions in dimensions[.bottom] }
            .id(ReadingAnchor.markerID(messageID))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - Message inputs

    /// Only user turns with attachments carry any, so equality stays cheap for the rest.
    private func unavailableAttachmentIDs(of message: ChatMessage) -> Set<UUID> {
        guard message.role == .user, !message.attachments.isEmpty else { return [] }
        let unavailable = viewModel.chat.unavailableAttachmentIDs
        guard !unavailable.isEmpty else { return [] }
        return unavailable.intersection(message.attachments.map(\.id))
    }

    /// The pager for the last reply, when it answers the turn that was regenerated.
    private func versionInfo(of message: ChatMessage, versions: ChatSession.ReplyVersions?) -> VersionPager.Position? {
        guard message.role == .assistant, let versions,
              messages.last(where: { $0.role == .user })?.id == versions.userMessageID else { return nil }
        return VersionPager.position(for: versions)
    }

    private func insertTarget(of message: ChatMessage) -> InsertTarget? {
        guard message.role == .assistant, message.state == .complete, !message.text.isEmpty else { return nil }
        return viewModel.insertTarget(forAssistant: message.id)
    }

    // MARK: - Following and restoring

    /// Re-pins and scrolls to the bottom (and abandons a restore still in progress).
    private func followBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        scroll.cancelRestore()
        if !isPinnedToBottom { isPinnedToBottom = true }
        guard animated else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            return
        }
        programmaticScrollEnd = Date().addingTimeInterval(Self.programmaticScrollWindow)
        withAnimation(Theme.Motion.content) {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    /// Another conversation was opened or continued: it lands where the view model's anchor says (the view model
    /// sets one after restoring a saved position), else at the bottom — never with the new-turn animation.
    private func conversationSwapped(_ proxy: ScrollViewProxy) {
        if let anchor = viewModel.consumeReadingAnchor() {
            restore(anchor, proxy: proxy)
        } else if !scroll.isRestoring {
            // The anchor's own handler may already have started the restore in this update.
            followBottom(proxy, animated: false)
        }
    }

    /// Puts the top of the anchored reply at the top of the viewport, without animation, and stops following the
    /// bottom. The scroll repeats after the next layout pass; a transcript that fits goes to the bottom instead.
    /// Runs after the handlers of the current update, so a swap or new-turn scroll in the same update can't
    /// override it.
    private func restore(_ anchor: ReadingAnchor, proxy: ScrollViewProxy) {
        guard messages.contains(where: { $0.id == anchor.messageID }) else {
            followBottom(proxy, animated: false)
            return
        }
        let markerID = ReadingAnchor.markerID(anchor.messageID)
        scroll.cancelRestore()
        scroll.isRestoring = true
        isPinnedToBottom = false
        programmaticScrollEnd = Date().addingTimeInterval(Self.programmaticScrollWindow)
        scroll.restoreTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            isPinnedToBottom = false
            programmaticScrollEnd = Date().addingTimeInterval(Self.programmaticScrollWindow)
            proxy.scrollTo(markerID, anchor: .top)
            await Task.yield()
            guard !Task.isCancelled else { return }
            if contentHeight <= viewportHeight + 0.5 {
                isPinnedToBottom = true
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            } else {
                proxy.scrollTo(markerID, anchor: .top)
            }
            scroll.isRestoring = false
            scheduleReadingReport()
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
        scheduleReadingReport()
    }

    // MARK: - Reading position (§6.6)

    /// A user scroll: report once the scrolling has stopped for 400 ms.
    private func scheduleReadingReport() {
        scroll.reportTask?.cancel()
        scroll.reportTask = Task { @MainActor in
            try? await Task.sleep(for: Self.reportDelay)
            guard !Task.isCancelled else { return }
            reportReadingPosition()
        }
    }

    /// The first message whose bottom shows below the top fade is the one being read. (Measured from the fade
    /// rather than the very edge, so a restored reply reports itself, not the question whose last line peeks out
    /// above its marker.)
    private func reportReadingPosition() {
        let frames = scroll.rowFrames
        guard let anchor = messages.first(where: { (frames[$0.id]?.maxY ?? 0) > Self.topFade }),
              let frame = frames[anchor.id] else { return }
        let fraction = frame.height > 0 ? min(max(-frame.minY / frame.height, 0), 1) : 0
        viewModel.noteReadingPosition(ReadingPosition(
            anchorMessageID: anchor.id,
            fractionScrolledPast: Double(fraction),
            isAtBottom: isPinnedToBottom,
            lastMessageID: messages.last?.id,
            savedAt: Date()
        ))
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
    var toolCalls: Int
    var settledToolCalls: Int
    var isThinking: Bool
}

private struct TranscriptLayout: Equatable {
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
}

private struct TranscriptKey: Equatable {
    var conversationID: UUID
    var count: Int
}

/// What the transcript remembers between callbacks without re-rendering: each message's frame in the scroll
/// view's space, the pending reading-position report and the reading-anchor restore in flight.
@MainActor
private final class ScrollBookkeeping {
    var rowFrames: [UUID: CGRect] = [:]
    var reportTask: Task<Void, Never>?
    var restoreTask: Task<Void, Never>?
    /// A restore started and hasn't landed yet: a swap in the same update leaves the scroll to it.
    var isRestoring = false

    func cancelRestore() {
        restoreTask?.cancel()
        restoreTask = nil
        isRestoring = false
    }

    func cancelAll() {
        cancelRestore()
        reportTask?.cancel()
        reportTask = nil
    }
}

/// Sizes its single child (a scroll view) to the child's ideal height, capped at `maxHeight` and at least
/// `minHeight`, in the same layout pass — so the panel resizes in one smooth step instead of after a measurement.
struct CappedHeightLayout: Layout {
    var maxHeight: CGFloat
    /// Tall mode fills the space it is given (`minHeight == maxHeight`); 0 hugs the content.
    var minHeight: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let cap = max(0, maxHeight)
        let height = max(min(ideal.height, cap), min(max(0, minHeight), cap))
        return CGSize(width: proposal.width ?? ideal.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for child in subviews {
            child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}
