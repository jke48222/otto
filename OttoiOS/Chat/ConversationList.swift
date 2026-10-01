//
//  ConversationList.swift
//  Otto
//
//  The transcript. It follows a streaming reply while you are at the bottom, stays put when you scroll up to
//  read (a "jump to latest" button brings you back), lands on a reply you opened from the Live Activity or a
//  notification, and keeps the last line above the keyboard.
//

import SwiftUI

struct ConversationList: View {
    let model: ChatScreenModel

    @State private var position = ScrollPosition(edge: .bottom)
    /// The view follows new content: you are at (or were sent to) the bottom.
    @State private var isPinned = true
    @State private var isUserScrolling = false
    @State private var distanceFromBottom: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Closer than this to the bottom counts as at the bottom.
    static let pinThreshold: CGFloat = 72
    static let sidePadding: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            let chat = model.chat
            let messages = chat.messages
            let lastID = messages.last?.id
            let lastUserID = chat.lastUserMessage?.id
            let versions = chat.lastTurnVersions
            let isStreaming = chat.isStreaming
            let showsCost = model.settings.usage.showCost
            let unavailable = chat.unavailableAttachmentIDs
            let bubbleWidth = max(200, (proxy.size.width - Self.sidePadding * 2) * 0.82)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(messages) { message in
                        MessageRow(
                            message: message,
                            model: model,
                            isLast: message.id == lastID,
                            isEditable: message.id == lastUserID && !isStreaming,
                            unavailableAttachmentIDs: message.role == .user
                                ? unavailable.intersection(message.attachments.map(\.id)) : [],
                            versionInfo: message.id == lastID ? Self.versionInfo(of: message, versions: versions,
                                                                                    lastUserID: lastUserID) : nil,
                            isChatStreaming: isStreaming,
                            showsCost: showsCost,
                            maxBubbleWidth: bubbleWidth
                        )
                        .equatable()
                        .id(message.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            // Margins rather than padding, and leading anchors: the content is never wider than the view, and a
            // first layout at another size can't leave it scrolled sideways.
            .contentMargins(.horizontal, Self.sidePadding, for: .scrollContent)
            .scrollPosition($position)
            .defaultScrollAnchor(.bottomLeading, for: .initialOffset)
            .defaultScrollAnchor(.topLeading, for: .alignment)
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                position.scrollTo(edge: .bottom)
            }
            .onScrollPhaseChange { old, new in
                let wasDragging = Self.isUserDriven(old)
                isUserScrolling = Self.isUserDriven(new)
                if wasDragging, !isUserScrolling {
                    // The user's scroll came to rest: following resumes only at the bottom.
                    isPinned = distanceFromBottom < Self.pinThreshold
                }
            }
            .onScrollGeometryChange(for: ScrollMetrics.self, of: { ScrollMetrics($0) }) { old, new in
                geometryChanged(from: old, to: new)
            }
            .onChange(of: model.scrollRequest) { _, request in
                guard let request else { return }
                handle(request)
            }
            .overlay(alignment: .bottom) {
                if !isPinned, !messages.isEmpty, distanceFromBottom > Self.pinThreshold {
                    JumpToLatestButton(isStreaming: isStreaming) {
                        scrollToBottom(animated: true)
                    }
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: isPinned)
        }
    }

    /// The pager for the last reply, when it answers the turn that was regenerated.
    static func versionInfo(of message: ChatMessage, versions: ChatSession.ReplyVersions?,
                            lastUserID: UUID?) -> VersionPager.Position? {
        guard message.role == .assistant, let versions, lastUserID == versions.userMessageID else { return nil }
        return VersionPager.position(for: versions)
    }

    // MARK: - Following

    /// Only the user's own scrolling unpins the transcript (a programmatic jump to a reply unpins it explicitly).
    private func geometryChanged(from old: ScrollMetrics, to new: ScrollMetrics) {
        distanceFromBottom = new.distanceFromBottom
        if isUserScrolling {
            isPinned = new.distanceFromBottom < Self.pinThreshold
            return
        }
        let resized = new.contentHeight != old.contentHeight || new.containerHeight != old.containerHeight
            || new.bottomInset != old.bottomInset
        if resized, isPinned {
            // A streaming reply grew, the keyboard came up or the composer got taller: stay at the bottom.
            position.scrollTo(edge: .bottom)
        } else if new.distanceFromBottom < 1 {
            isPinned = true
        }
    }

    private static func isUserDriven(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating: return true
        case .idle, .animating: return false
        @unknown default: return false
        }
    }

    private func handle(_ request: ChatScreenModel.ScrollRequest) {
        switch request.target {
        case .bottom:
            scrollToBottom(animated: true)
        case .message(let id):
            isPinned = false
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                position.scrollTo(id: id, anchor: .top)
            }
        }
    }

    private func scrollToBottom(animated: Bool) {
        isPinned = true
        withAnimation(animated && !reduceMotion ? .smooth(duration: 0.3) : nil) {
            position.scrollTo(edge: .bottom)
        }
    }
}

/// What the follow logic reads from the scroll view.
struct ScrollMetrics: Equatable {
    var offset: CGFloat
    var contentHeight: CGFloat
    var containerHeight: CGFloat
    /// Only compared: a change means the keyboard or the composer moved.
    var bottomInset: CGFloat

    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y
        contentHeight = geometry.contentSize.height
        containerHeight = geometry.containerSize.height
        bottomInset = geometry.contentInsets.bottom
    }

    init(offset: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat, bottomInset: CGFloat = 0) {
        self.offset = offset
        self.contentHeight = contentHeight
        self.containerHeight = containerHeight
        self.bottomInset = bottomInset
    }

    /// How far the bottom of the content is below the visible area (0 at the bottom, or when it all fits).
    /// SwiftUI reports the container without the composer's inset (the content's visible height), so the inset
    /// isn't added again; were it reported the UIKit way, this would only under-report by the inset, which delays
    /// the jump button and never shows it at the bottom.
    var distanceFromBottom: CGFloat {
        max(0, contentHeight - containerHeight - offset)
    }
}

/// Brings the transcript back to the newest line.
private struct JumpToLatestButton: View {
    let isStreaming: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isStreaming {
                    OttoOrb(size: 8, isActive: true)
                }
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                Text(isStreaming ? "Otto is replying" : "Latest")
                    .font(Theme.font(13.5, .medium))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .clay(cornerRadius: 18, style: .pebble)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
        .accessibilityLabel(isStreaming ? "Jump to the reply" : "Jump to the latest message")
    }
}
