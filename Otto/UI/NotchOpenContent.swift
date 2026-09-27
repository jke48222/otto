//
//  NotchOpenContent.swift
//  Otto
//
//  Everything inside the open notch (§4.1): the header, the attention capsule while a prompt waits on
//  another page, and the page. Chat stacks the glance row, the conversation (or the ⌘/ sheet), the dock,
//  the Continue chip, the edit banner, the chips, the composer and one line for errors, notices and the
//  voice hint. Recents and the Shelf replace all of that. Drop overlays cover the page on every route.
//  The height arithmetic lives in `NotchLayout`, a pure helper the layout tests drive.
//

import AppKit
import SwiftUI

// MARK: - Height budget

/// The open panel's height budget (§4.1). Pure, so the rules are unit-tested.
enum NotchLayout {
    /// The conversation never gets shorter than this, even when the lower section is tall.
    static let minimumConversationHeight: CGFloat = 110
    /// Outside tall mode the conversation hugs its content up to this.
    static let preferredConversationHeight: CGFloat = 340
    /// The dock never grows past this on its own; its body scrolls inside.
    static let maximumDockHeight: CGFloat = 300

    /// Page padding and gaps (points).
    static let horizontalPadding: CGFloat = 16
    /// Under the header (to the conversation, or to the glance row when it shows).
    static let topGap: CGFloat = 10
    /// Under the glance row, above the conversation.
    static let glanceRowGap: CGFloat = 12
    static let bottomPadding: CGFloat = 16
    /// Between the conversation and the lower section.
    static let sectionSpacing: CGFloat = 12
    /// Between the rows of the lower section (dock, chip, banner, chips, composer, line).
    static let lowerSpacing: CGFloat = 10

    /// The header sits beside the camera housing (the closed notch's height), but never shorter than the
    /// ⋮ pebble plus its clearance above and below.
    static func headerHeight(closedNotchHeight: CGFloat) -> CGFloat {
        max(closedNotchHeight, NotchHeaderView.minimumHeight)
    }

    /// Everything on the Chat page that is not the conversation: header, attention capsule and glance
    /// row (`topSectionHeight`, their gaps included), the page paddings, and the measured lower section.
    static func chatChrome(headerHeight: CGFloat, topSectionHeight: CGFloat, lowerSectionHeight: CGFloat,
                           hasGlanceRow: Bool) -> CGFloat {
        let gapAboveConversation = hasGlanceRow ? glanceRowGap : topGap
        return headerHeight + topSectionHeight + gapAboveConversation + sectionSpacing + bottomPadding
            + lowerSectionHeight
    }

    /// `max(110, min(340 (tall: openHeightLimit − chrome), openHeightLimit − chrome))`. In tall mode the
    /// conversation fills the space (its minimum equals this maximum).
    static func conversationMaxHeight(openHeightLimit: CGFloat, chrome: CGFloat, isTall: Bool) -> CGFloat {
        let available = openHeightLimit - chrome
        let preferred = isTall ? available : preferredConversationHeight
        return max(minimumConversationHeight, min(preferred, available))
    }

    /// `min(300, openHeightLimit − chromeWithoutDock − 110)`: the dock leaves the conversation its minimum.
    /// Never negative.
    static func dockMaxHeight(openHeightLimit: CGFloat, chromeWithoutDock: CGFloat) -> CGFloat {
        max(0, min(maximumDockHeight, openHeightLimit - chromeWithoutDock - minimumConversationHeight))
    }

    /// The open shape's height for content `contentHeight` tall: at least the closed notch, at most the limit.
    static func openShapeHeight(contentHeight: CGFloat, closedHeight: CGFloat, openHeightLimit: CGFloat) -> CGFloat {
        min(max(contentHeight, closedHeight), openHeightLimit)
    }

    /// The room a full-page route (Recents, the Shelf) gets under the header and the capsule.
    static func pageHeight(openHeightLimit: CGFloat, headerHeight: CGFloat, topSectionHeight: CGFloat) -> CGFloat {
        max(0, openHeightLimit - headerHeight - topSectionHeight)
    }

    /// The glance row's height rounded to a bucket, so the panel springs only when the row appears,
    /// disappears or changes shape (the strip's caption adds a few points).
    static func glanceRowHeightBucket(_ height: CGFloat) -> Int {
        Int((height / 4).rounded())
    }
}

// MARK: - Open content

struct NotchOpenContent: View {
    let viewModel: NotchViewModel

    /// Capsule (and its gap) above the page, measured.
    @State private var capsuleSectionHeight: CGFloat = 0
    /// Glance row (and its gap) at the top of the Chat page, measured.
    @State private var glanceSectionHeight: CGFloat = 0
    /// Dock, Continue chip, banner, chips, composer and line, measured.
    @State private var lowerSectionHeight: CGFloat = 0
    /// The dock alone (its share of the lower section), measured.
    @State private var dockHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var headerHeight: CGFloat {
        NotchLayout.headerHeight(closedNotchHeight: viewModel.closedNotchSize.height)
    }

    // MARK: - Pure

    /// The dock renders the current prompt on Chat only (§4.3).
    static func dockPrompt(route: NotchRoute, currentPrompt: NotchPrompt?) -> NotchPrompt? {
        route == .chat ? currentPrompt : nil
    }

    /// On any other page a waiting prompt shows as the attention capsule under the header instead.
    static func capsulePrompt(route: NotchRoute, currentPrompt: NotchPrompt?) -> NotchPrompt? {
        route == .chat ? nil : currentPrompt
    }

    private var capsulePrompt: NotchPrompt? {
        Self.capsulePrompt(route: viewModel.route, currentPrompt: viewModel.currentPrompt)
    }

    var body: some View {
        VStack(spacing: 0) {
            NotchHeaderView(viewModel: viewModel)
                .frame(height: headerHeight)
                .padding(.horizontal, NotchHeaderView.horizontalPadding)

            VStack(spacing: 0) {
                if let prompt = capsulePrompt {
                    AttentionCapsule(prompt: prompt) { viewModel.navigate(to: .chat) }
                        .padding(.top, NotchLayout.topGap)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { capsuleSectionHeight = $0 }

            page
                .overlay { dropOverlay }
        }
        .padding(.horizontal, NotchMetrics.openTopRadius)
        .frame(width: NotchMetrics.openWidth)
    }

    // MARK: - Pages

    @ViewBuilder
    private var page: some View {
        ZStack(alignment: .top) {
            switch viewModel.route {
            case .chat:
                chatPage
                    .transition(pageTransition)
            case .history:
                recentsPage
                    .transition(pageTransition)
            case .shelf:
                ShelfView(
                    controller: viewModel.shelf,
                    focusRequest: viewModel.focusRequest,
                    onAskAbout: { viewModel.askAboutShelfItems($0) }
                )
                .transition(pageTransition)
            }
        }
        .animation(Theme.Motion.content, value: viewModel.route)
    }

    /// Pages slide in from the trailing edge and out to the leading one; Reduce Motion fades them.
    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private var recentsPage: some View {
        let viewModel = self.viewModel
        let history = viewModel.history
        return RecentsView(
            recents: viewModel.recents,
            history: history,
            settings: viewModel.settings.history,
            isStreaming: viewModel.chat.isStreaming,
            pageHeight: NotchLayout.pageHeight(openHeightLimit: viewModel.openHeightLimit,
                                               headerHeight: headerHeight, topSectionHeight: capsuleSectionHeight),
            actions: RecentsView.Actions(
                open: { viewModel.openConversation(id: $0) },
                delete: { history.delete($0) },
                undoDelete: { viewModel.undoRecentDeletion() },
                openSettings: { viewModel.openSettings(tab: .privacy) },
                turnOnHistory: { Task { await history.setEnabled(true) } },
                acknowledgeNotice: { viewModel.acknowledgeHistoryNotice() },
                declineHistory: { viewModel.declineHistory() }
            )
        )
    }

    // MARK: - Chat page

    private var showsGlanceRow: Bool {
        let settings = viewModel.settings.glance
        let hasMedia = settings.nowPlayingEnabled && viewModel.nowPlaying.item != nil
        let hasEvent = settings.calendarChipEnabled && viewModel.calendar.next != nil
        return GlanceRow.isShown(hasMedia: hasMedia, hasEvent: hasEvent)
    }

    private var chatPage: some View {
        let hasGlanceRow = showsGlanceRow
        let chrome = NotchLayout.chatChrome(
            headerHeight: headerHeight,
            topSectionHeight: capsuleSectionHeight + (hasGlanceRow ? glanceSectionHeight : 0),
            lowerSectionHeight: lowerSectionHeight,
            hasGlanceRow: hasGlanceRow
        )
        let limit = viewModel.openHeightLimit
        let fillsHeight = viewModel.isTallMode && viewModel.systemUIWait == nil
        let conversationMaxHeight = NotchLayout.conversationMaxHeight(openHeightLimit: limit, chrome: chrome,
                                                                      isTall: fillsHeight)
        let dockMaxHeight = NotchLayout.dockMaxHeight(openHeightLimit: limit, chromeWithoutDock: chrome - dockHeight)
        let gapAboveConversation = hasGlanceRow ? NotchLayout.glanceRowGap : NotchLayout.topGap

        return VStack(spacing: 0) {
            if hasGlanceRow {
                glanceRow
                    .padding(.horizontal, NotchLayout.horizontalPadding)
                    .padding(.top, NotchLayout.topGap)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { glanceSectionHeight = $0 }
                    .transition(.opacity)
            }

            VStack(spacing: NotchLayout.sectionSpacing) {
                conversationArea(maxHeight: conversationMaxHeight, gap: gapAboveConversation, fillsHeight: fillsHeight)
                lowerSection(dockMaxHeight: dockMaxHeight)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { lowerSectionHeight = $0 }
            }
            .padding(.horizontal, NotchLayout.horizontalPadding)
            .padding(.top, gapAboveConversation)
            .padding(.bottom, NotchLayout.bottomPadding)
        }
    }

    private var glanceRow: some View {
        let viewModel = self.viewModel
        let player = viewModel.nowPlaying.item?.player
        return GlanceRow(
            nowPlaying: viewModel.nowPlaying,
            calendar: viewModel.calendar,
            onMediaCommand: { viewModel.performMedia($0) },
            onJoinMeeting: { viewModel.joinNextMeeting() },
            onOpenAutomationSettings: {
                guard let player else { return }
                viewModel.openSystemSettingsFromNotch(
                    for: .automation(bundleID: player.rawValue, appName: player.displayName))
            },
            isAwaitingMediaConsent: Self.isAwaitingConsent(from: player, wait: viewModel.systemUIWait),
            isVisible: viewModel.isOpen
        )
    }

    /// The macOS Automation dialog for the playing app is up.
    private static func isAwaitingConsent(from player: MediaPlayer?, wait: SystemUIWait?) -> Bool {
        guard let player, case .systemPrompt(.automation(let bundleID, _))? = wait else { return false }
        return bundleID == player.rawValue
    }

    /// The conversation, or the ⌘/ sheet in its place (the panel grows to fit it even with no messages).
    @ViewBuilder
    private func conversationArea(maxHeight: CGFloat, gap: CGFloat, fillsHeight: Bool) -> some View {
        if viewModel.overlay == .shortcutSheet {
            ShortcutSheetView(
                settings: viewModel.settings,
                availableRoutes: viewModel.availableRoutes,
                maxHeight: maxHeight,
                onDismiss: { viewModel.dismissOverlay() }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.98)).animation(.easeOut(duration: 0.2)))
        } else {
            ConversationSection(viewModel: viewModel, maxHeight: maxHeight, headerGap: gap, fillsHeight: fillsHeight)
        }
    }

    private func lowerSection(dockMaxHeight: CGFloat) -> some View {
        VStack(spacing: NotchLayout.lowerSpacing) {
            if let prompt = Self.dockPrompt(route: viewModel.route, currentPrompt: viewModel.currentPrompt) {
                NotchDockHost(viewModel: viewModel, prompt: prompt, maxHeight: dockMaxHeight)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { dockHeight = $0 }
                    .onDisappear { dockHeight = 0 }
                    .transition(dockTransition)
            }
            ContinuationRow(viewModel: viewModel)
            if viewModel.isEditing {
                EditBanner { viewModel.cancelEditing() }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if showsChips {
                ContextChipsView(viewModel: viewModel)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
            }
            ComposerView(viewModel: viewModel)
            StatusLineSlot(viewModel: viewModel)
        }
        .animation(Theme.Motion.dock, value: viewModel.currentPrompt?.id)
    }

    /// The dock rises from the composer (§4.3); Reduce Motion fades it.
    private var dockTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.97, anchor: .bottom)),
            removal: .opacity.animation(.easeOut(duration: 0.14))
        )
    }

    private var showsChips: Bool {
        !viewModel.attachments.isEmpty || viewModel.suggestedTab != nil || viewModel.pendingAttachmentLoads > 0
            || viewModel.suggestions.selection != nil || viewModel.suggestions.window != nil
    }

    // MARK: - Drop overlays

    @ViewBuilder
    private var dropOverlay: some View {
        if viewModel.isDropTargeted {
            Group {
                if let session = viewModel.dropSession, session.acceptsShelf {
                    DropZonesOverlay(session: session, shelfCount: viewModel.shelf.store.items.count,
                                     remainingAttachmentCapacity: viewModel.remainingCapacity)
                } else {
                    DropTargetOverlay()
                }
            }
            .padding(EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8))
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }
}

// MARK: - Conversation

/// The transcript, once there is one. It reads `chat.messages` here rather than in `NotchOpenContent`,
/// so a streamed delta re-evaluates this small view and the conversation, not the header, dock, chips and
/// composer around them. With no messages it contributes no view (and so no stack spacing) at all.
private struct ConversationSection: View {
    let viewModel: NotchViewModel
    let maxHeight: CGFloat
    /// The gap the container leaves above the conversation. The transcript reaches up through it, so its
    /// top fade starts right at the header's (or the glance row's) bottom edge, and insets its first
    /// message by as much.
    let headerGap: CGFloat
    /// Tall reading mode: the conversation takes the whole budget, not just what its content needs.
    let fillsHeight: Bool

    var body: some View {
        if !viewModel.chat.messages.isEmpty {
            let height = maxHeight + headerGap
            ConversationView(viewModel: viewModel, maxHeight: height, topInset: headerGap)
                .modifier(FillsHeight(height: fillsHeight ? height : nil))
                .padding(.top, -headerGap)
                .transition(.opacity)
        }
    }
}

/// Tall mode: the transcript's frame takes the whole budget even when its messages are shorter.
private struct FillsHeight: ViewModifier {
    let height: CGFloat?

    func body(content: Content) -> some View {
        if let height {
            content.frame(minHeight: height, maxHeight: height, alignment: .top)
        } else {
            content
        }
    }
}

// MARK: - Dock

/// The one prompt in the dock (§4.3, §5.7): an approval, a permission flow or a card. Approval decisions
/// carry the input that made them, so the view model can tell the user's own key press or click from
/// anything synthetic.
private struct NotchDockHost: View {
    @Bindable var viewModel: NotchViewModel
    let prompt: NotchPrompt
    let maxHeight: CGFloat

    var body: some View {
        DockHeightCap(maxHeight: maxHeight) {
            content
        }
        .id(prompt.id)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)),
            removal: .opacity.animation(.easeOut(duration: 0.14))
        ))
        .animation(Theme.Motion.content, value: prompt.id)
    }

    @ViewBuilder
    private var content: some View {
        switch prompt {
        case .approval(let approval):
            if let permission = viewModel.toolPermissionCardContent(for: approval) {
                toolPermissionCard(permission, approval: approval)
            } else {
                ApprovalCard(
                    approval: approval,
                    options: $viewModel.approvalOptions,
                    visibleSince: visibleSince(for: approval),
                    onReviewed: { viewModel.noteApprovalReviewed(callID: approval.callID) },
                    onDecision: { decision in
                        viewModel.resolveApproval(decision, input: currentInput())
                    }
                )
            }
        case .permission:
            if let content = viewModel.permissionCardContent {
                PermissionCard(
                    content: content,
                    onPrimary: {
                        if let action = content.primaryAction { viewModel.permissionPromptAction(action) }
                    },
                    onSecondary: { viewModel.permissionPromptAction(content.secondaryAction) }
                )
            }
        case .card(let card):
            NotchCardView(card: card) { viewModel.performCardAction($0) }
        }
    }

    /// An approval that needs macOS access first: the permission card, whose primary approves with the
    /// click's evidence (then the access steps run) and whose "Quit & Reopen Otto" relaunches. Its body
    /// always fits, so it counts as reviewed as soon as it shows.
    private func toolPermissionCard(_ content: PermissionCardContent, approval: PendingApproval) -> some View {
        PermissionCard(
            content: content,
            onPrimary: {
                if content.primaryAction == .relaunch {
                    viewModel.permissionPromptAction(.relaunch)
                } else if content.primaryAction != nil {
                    viewModel.resolveApproval(.run(viewModel.approvalOptions), input: currentInput())
                }
            },
            onSecondary: { viewModel.permissionPromptAction(content.secondaryAction) }
        )
        .onAppear { viewModel.noteApprovalReviewed(callID: approval.callID) }
        .onChange(of: approval.callID) { _, callID in viewModel.noteApprovalReviewed(callID: callID) }
    }

    /// Arming counts only from the moment this approval was on screen and reviewed.
    private func visibleSince(for approval: PendingApproval) -> Date? {
        guard let visibility = viewModel.approvalVisibility, visibility.callID == approval.callID else { return nil }
        return visibility.since
    }

    /// The key press or click being handled right now (the window controller recorded the panel's last
    /// mouse-down, since a button's action runs on mouse-up).
    private func currentInput() -> InputEvidence {
        InputProvenance.evidence(for: NSApp.currentEvent, mouseDown: viewModel.lastPanelMouseDown)
    }
}

/// Sizes the dock to its ideal height up to `maxHeight` and then offers it exactly that, so a card's
/// scrolling body shrinks to fit instead of being clipped.
private struct DockHeightCap: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let height = min(ideal.height, max(0, maxHeight))
        let fitted = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: height))
        return CGSize(width: proposal.width ?? fitted.width, height: min(fitted.height, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for child in subviews {
            child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

// MARK: - Continue chip

/// "Continue: ‹title›" over an empty chat after a fresh start set the last conversation aside.
private struct ContinuationRow: View {
    let viewModel: NotchViewModel

    var body: some View {
        if viewModel.chat.messageCount == 0, let continuation = viewModel.history.continuation {
            ContinueChip(
                title: continuation.title,
                onContinue: { viewModel.continuePreviousConversation() },
                onDismiss: { viewModel.dismissContinuation() }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomLeading)))
        }
    }
}

// MARK: - Status line

/// The one line under the composer: an error wins; while listening it shows the voice hint; otherwise a
/// neutral notice.
private struct StatusLineSlot: View {
    let viewModel: NotchViewModel

    static let holdHint = "Release to send · Esc to cancel"
    static let toggleHint = "Click the mic or press Return to send · Esc to cancel"

    enum Content: Equatable {
        case error(String)
        case voiceHint(String)
        case notice(TransientNotice)
    }

    static func content(error: String?, isListening: Bool, voiceMode: VoiceMode?,
                        notice: TransientNotice?) -> Content? {
        if let error { return .error(error) }
        if isListening {
            if case .hold? = voiceMode { return .voiceHint(holdHint) }
            return .voiceHint(toggleHint)
        }
        if let notice { return .notice(notice) }
        return nil
    }

    var body: some View {
        let content = Self.content(error: viewModel.transientError, isListening: viewModel.voice.isListening,
                                   voiceMode: viewModel.voice.mode, notice: viewModel.transientNotice)
        // No view at all when there is nothing to say, so the stack adds no spacing under the composer.
        if let content {
            line(content)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private func line(_ content: Content) -> some View {
        switch content {
        case .error(let message):
            TransientErrorLine(message: message)
        case .voiceHint(let hint):
            NoticeLine(text: hint, symbol: "mic")
        case .notice(let notice):
            NoticeLine(text: notice.text, symbol: notice.symbol)
        }
    }
}
