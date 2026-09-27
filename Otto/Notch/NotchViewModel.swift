//
//  NotchViewModel.swift
//  Otto
//
//  State of the notch panel: presentation, focus and holds, the fold for system UI, routes and the dock's
//  prompts, the composer and its context chips, notices, editing and the reading position. This file owns every
//  stored property and every state transition; NotchViewModel+Prompts orchestrates the dock (approvals,
//  permission flows, cards) and NotchViewModel+Interaction answers the window controller's and the views'
//  questions (key context, placeholder, height limit). The feature files (voice, context, shelf, history,
//  glance, actions, commands) build on the same stored properties.
//

import AppKit
import Observation
import UniformTypeIdentifiers
import os

/// A neutral confirmation under the composer ("Copied the last reply").
struct TransientNotice: Equatable, Sendable { let text: String; let symbol: String }

/// ↑ recalled the last question into the composer; sending replaces that turn.
struct EditingTurn: Equatable, Sendable { let userMessageID: UUID }

/// Snapshots and SelfTest only: feature state set in one call (`NotchViewModel.debugSeed(features:)`).
struct NotchDebugSeed {
    var route: NotchRoute = .chat
    var overlay: NotchOverlay? = nil
    var isPinned = false
    var isTallMode = false
    var editingTurnMessageID: UUID? = nil
    var card: NotchCard? = nil
    var permissionPrompt: PermissionPrompt? = nil
    var notice: TransientNotice? = nil
    var dropSession: DropSession? = nil
    var readingAnchorMessageID: UUID? = nil
    var isSoftFocused = false
    /// closed-waiting.png (also sets isFolded).
    var systemUIWait: SystemUIWait? = nil
    /// Approval shots: a date at least armingDelay ago renders the armed state.
    var approvalVisibleSince: Date? = nil
}

@MainActor @Observable final class NotchViewModel {
    enum Presentation: Equatable { case closed, open }
    enum OpenReason: Equatable { case hover, click, hotkey, drag, programmatic, voice }

    /// When the current approval became visible and reviewed (§4.5); arming counts from here.
    struct ApprovalVisibility: Equatable, Sendable { let callID: String; let since: Date; let sinceUptime: TimeInterval }

    /// A card waiting in the dock queue, with the open it was queued in (the neighbor card shows on the next open).
    struct QueuedCard: Equatable, Sendable {
        var card: NotchCard
        let queuedAtOpen: Int
    }

    /// The phase of the permission card a tool approval of kind `.permission` shows.
    struct ToolPermissionState: Equatable, Sendable {
        let callID: String
        var phase: PermissionPrompt.Phase
    }

    static let maxAttachments = 10
    static let attachmentLimitMessage = "You can attach up to \(maxAttachments) items."

    let settings: AppSettings
    let chat: ChatSession

    // MARK: Services (read by views)

    let permissions: PermissionsCenter
    let approvals: ApprovalStore
    let voice: VoiceController
    let history: HistoryController
    let recents: RecentsState
    let glance: GlanceController
    let ledger: UsageLedger
    let nowPlaying: NowPlayingMonitor
    let calendar: CalendarGlance
    let shelf: ShelfController
    let suggestions: ContextSuggestions
    let inserter: InsertCoordinator
    /// nil in inert graphs (tests, snapshots, promo).
    let notifications: NotificationPresenter?

    // MARK: Presentation and composer

    private(set) var presentation: Presentation = .closed
    private(set) var openReason: OpenReason?
    var isOpen: Bool { presentation == .open }

    /// The panel is key and the user is interacting with the keyboard — hover-exit must not close it.
    var isEngaged = false
    /// Pointer is over the closed notch (window controller sets it) — UI shows a subtle grow.
    var isHovering = false
    var composerText = ""
    private(set) var attachments: [Attachment] = []
    /// Ghost chip for the current browser tab.
    private(set) var suggestedTab: Attachment?
    var isDropTargeted = false
    private(set) var pendingAttachmentLoads = 0

    /// Short user-facing error under the composer; clears itself after `transientErrorLifetime`.
    var transientError: String? {
        didSet { scheduleTransientErrorClear() }
    }

    /// Increments whenever the composer (or the active route's first responder) should take keyboard focus.
    private(set) var focusRequest = 0
    var hasUnreadReply = false

    /// Outside clicks don't close the notch while true: a +/⋮ menu, the file picker, a screen capture, or a sheet
    /// or preview of Otto's own above the notch. Waiting on system UI is not part of it: the notch folds instead.
    var isMenuPresented: Bool {
        get { menuFlag || isPickingFiles || isCapturingScreen || !modalHolds.isEmpty }
        set { menuFlag = newValue }
    }

    /// Hardware (or virtual) notch size; set by the window controller.
    var closedNotchSize: CGSize = NotchMetrics.virtualNotchSize
    var hasPhysicalNotch = false
    /// Size of the shape as currently rendered (the UI reports it; the controller hit-tests with it).
    var renderedShapeSize: CGSize = NotchMetrics.virtualNotchSize

    var canSend: Bool {
        guard pendingAttachmentLoads == 0 else { return false }
        // Editing replaces the last turn, which stops a reply that is still streaming.
        guard isEditing || !chat.isStreaming else { return false }
        return !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// Hover-exit and the drop-settle fold-up never close while true.
    var shouldStayOpen: Bool {
        isEngaged || isMenuPresented || isDropTargeted || pendingAttachmentLoads > 0 || isPinned
            || !stayOpenHolds.isEmpty
    }

    /// The closed notch grows "ears" while a reply streams or an unread reply waits.
    var showsClosedActivity: Bool { chat.isStreaming || hasUnreadReply }

    // MARK: Focus, holds, pin, tall mode

    private(set) var stayOpenHolds: Set<StayOpenHold> = []
    private(set) var modalHolds: Set<ModalHold> = []
    /// The panel holds the keyboard because the pointer rests on it, not because the user committed (§6.2).
    private(set) var isSoftFocused = false
    /// Mirrors `panel.isKeyWindow`; the window controller writes it.
    var isPanelKey = false
    private(set) var isPinned = false
    private(set) var isTallMode = false
    /// Set by the window controller from the screen geometry.
    var tallOpenHeight: CGFloat = NotchMetrics.maxOpenHeight
    @ObservationIgnored var onWillChangeOpenHeightLimit: ((CGFloat) -> Void)?
    /// Preferred over onOpenSettings when set. The anchor scrolls the tab to a section.
    @ObservationIgnored var onOpenSettingsTab: ((SettingsTab?, SettingsAnchor?) -> Void)?

    // MARK: Fold for system UI (§4.5)

    /// permissions.awaiting (only for a flow started in the notch) ?? chat.systemUIToolWait ?? the browser-tab /
    /// media Automation prompt in flight. Drives the fold and closed-notch row 2.
    private(set) var systemUIWait: SystemUIWait?
    /// The VM folded an open notch for `systemUIWait` and will reopen it (unfocused) when the wait ends, unless the
    /// user opened or closed it in between.
    private(set) var isFolded = false

    // MARK: Routes, overlays, prompts

    private(set) var route: NotchRoute = .chat
    private(set) var overlay: NotchOverlay?
    private(set) var permissionPrompt: PermissionPrompt?
    /// FIFO, one card per kind. `card` is the first one that may show now.
    private(set) var cardQueue: [QueuedCard] = []
    /// The card of a tool approval that needs macOS access: which step it is on.
    private(set) var toolPermission: ToolPermissionState?

    // MARK: Approvals

    private(set) var approvalVisibility: ApprovalVisibility?
    @ObservationIgnored private(set) var lastPanelMouseDown: (uptime: TimeInterval, isHardware: Bool)?
    /// The choices on the approval card (always-allow checkbox, calendar or list picker). ⌘↩ approves with them;
    /// the card binds to them. Reset for every new approval.
    var approvalOptions = ApprovalOptions()

    // MARK: Notices, editing, reading position

    /// An error (`transientError`) always wins the slot under the composer.
    private(set) var transientNotice: TransientNotice?
    private(set) var editingTurn: EditingTurn?
    private(set) var unreadReplyID: UUID?
    private(set) var readingAnchor: ReadingAnchor?

    // MARK: Feature state (the voice, context, shelf and history files use it)

    /// A voice question keeps the notch open until its reply has been read (§6.7).
    private(set) var voiceReplyHold = false
    /// The app the user was in when the notch opened (never Otto): the paste target and the chip names.
    @ObservationIgnored private(set) var openContextApp: AppRef?
    private(set) var dropSession: DropSession?
    /// User messages that were asked by voice ("When I ask by voice" spoken replies).
    @ObservationIgnored var voiceTurnUserMessageIDs: Set<UUID> = []
    /// Set by the voice flow right before it calls `send()`; `send()` records the new user message and clears it.
    @ObservationIgnored var isSendingVoiceTurn = false
    /// Accepted selection chips → the selection they came from (Replace mode), keyed by attachment id.
    @ObservationIgnored var selectionSnapshots: [UUID: SelectionSnapshot] = [:]
    /// Permissions the notch asked for outside a PermissionPrompt (voice, card actions). While macOS shows their
    /// dialog or System Settings the notch folds; each entry goes once that wait ends.
    private(set) var notchPermissionRequests: Set<Permission> = []
    /// An Automation consent dialog Otto triggered itself (the browser-tab lookup, Now Playing controls).
    var automationPromptInFlight: Permission?
    /// How the last permission flow ended without a grant ("Just Copy" on the paste card); nil after a grant.
    @ObservationIgnored private(set) var lastPermissionDeclineAction: PermissionCardAction?

    // MARK: Window-controller hooks

    @ObservationIgnored var onPresentationChange: ((Presentation) -> Void)?
    /// true: make the panel key (focus); false: give focus back to the user's app.
    @ObservationIgnored var onRequestKey: ((Bool) -> Void)?
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    /// The controller hides the panel while the user picks a screen region.
    @ObservationIgnored var onBeginScreenCapture: (() -> Void)?
    @ObservationIgnored var onEndScreenCapture: (() -> Void)?

    // MARK: Seams (tests shorten or fake them)

    /// How long `transientError` stays visible.
    @ObservationIgnored var transientErrorLifetime: Duration = .seconds(4)
    /// How long "You're all set" shows before a permission flow continues.
    @ObservationIgnored var grantedCardLifetime: Duration = .milliseconds(900)
    /// The longest a permission flow waits for a switch in System Settings (the center caps it too).
    @ObservationIgnored var permissionWaitTimeout: Duration = .seconds(180)
    @ObservationIgnored var now: () -> Date = { Date() }
    /// System uptime, the clock `NSEvent.timestamp` uses (approval arming vs. the approving key press).
    @ObservationIgnored var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// VoiceOver announcements (the fold).
    @ObservationIgnored var announce: (String) -> Void = { GlanceController.postAccessibilityAnnouncement($0) }
    /// Opens a URL outside Otto (Dictation settings). Inert graphs never open anything.
    @ObservationIgnored var openExternalURL: (URL) -> Void
    /// The interactive region capture behind "Take Screenshot" (tests replace it).
    @ObservationIgnored var captureInteractive: @MainActor () async throws -> Attachment? = {
        try await ScreenCapture.captureInteractive()
    }

    // MARK: Private state

    private var menuFlag = false
    private var isPickingFiles = false
    private var isCapturingScreen = false
    /// Holds set through `setHold`/`setModalHold`; the rest come from subsystem state (`refreshHolds`).
    private var manualStayOpenHolds: Set<StayOpenHold> = []
    private var manualModalHolds: Set<ModalHold> = []

    @ObservationIgnored private var transientErrorTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// The subsystem observations (hold sources, the fold, approvals, the history notice).
    @ObservationIgnored private var observations: [AnyObject] = []
    /// `open()` calls so far; cards remember the open they were queued in.
    @ObservationIgnored private(set) var openSerial = 0
    @ObservationIgnored private var readingAnchorSerial = 0
    /// The user clicked into or typed in the panel since it opened (History counts that as activity).
    @ObservationIgnored private var engagedThisOpen = false
    /// A notification or preview asked to open at this reply.
    @ObservationIgnored private var replyToRevealOnOpen: UUID?
    @ObservationIgnored private var hasShownPinNotice = false
    /// The Shelf's landing hold was cleared by a close; it counts again once the Shelf starts a new one.
    @ObservationIgnored private var landingHoldReleased = false
    /// Snapshots froze `systemUIWait` through `debugSeed(features:)`; live sources no longer move it.
    @ObservationIgnored private var systemUIWaitIsSeeded = false
    @ObservationIgnored private var reviewedApprovalCallID: String?
    @ObservationIgnored private var observedApprovalCallID: String?
    @ObservationIgnored private var notchRequestsInFlight: [Permission: Int] = [:]

    // Permission flows (driven by NotchViewModel+Prompts).
    @ObservationIgnored private var permissionContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var toolPermissionTask: Task<Void, Never>?
    @ObservationIgnored private var cardWaiters: [NotchCard.Kind: CheckedContinuation<NotchCard.Action, Never>] = [:]

    /// File URLs currently loading, so the same file dropped twice is loaded once.
    @ObservationIgnored private var loadingFileURLs: Set<URL> = []

    /// The last app other than Otto that was frontmost (the one the user is working in).
    @ObservationIgnored private var lastExternalApp: NSRunningApplication?
    @ObservationIgnored private var activationObserver: NotificationObservation?
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?
    /// Bumped on every suggestion refresh and on close; a lookup only lands if it still matches.
    @ObservationIgnored private var suggestionGeneration = 0
    /// A tab the user dismissed (or removed) is not suggested again until they move to another page.
    @ObservationIgnored private var dismissedTabURL: URL?
    /// The app that was active before Otto activated itself for the file picker; it gets focus
    /// back when the notch closes.
    @ObservationIgnored var appToReactivate: NSRunningApplication?
    /// The open file picker, so asking for it again brings it back instead of doing nothing.
    @ObservationIgnored private weak var filePanel: NSOpenPanel?
    /// The chip `autoAttachBrowserTab` added for the current tab. It stands for "the page I'm on
    /// now", so it is replaced on the next lookup and removed when the notch closes; once sent (or
    /// removed by the user) it is no longer tracked.
    @ObservationIgnored private var autoAttachedTabID: UUID?
    /// Whether the latest tab lookup was allowed to ask for Automation permission.
    @ObservationIgnored private var lastLookupAllowedPrompt = false
    /// `automationPromptInFlight` belongs to the tab lookup (not to a feature that set it).
    @ObservationIgnored private var tabLookupOwnsAutomationPrompt = false

    /// One level above the notch panel (`NotchPanel.auxiliaryWindowLevel`), so the open notch never
    /// covers the picker, and so it stays visible (and reachable) when another app is activated while
    /// it is up — Otto is an accessory app, so ⌘Tab can't bring it back.
    static let filePickerLevel = NotchPanel.auxiliaryWindowLevel

    static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Notch")

    /// `services == nil` ⇒ `.inert(settings:chat:)` (keeps every existing call site compiling).
    init(settings: AppSettings, chat: ChatSession, services: NotchServices? = nil) {
        let isInert = services == nil
        let services = services ?? .inert(settings: settings, chat: chat)
        self.settings = settings
        self.chat = chat
        permissions = services.permissions
        approvals = services.approvals
        voice = services.voice
        history = services.history
        recents = services.recents
        glance = services.glance
        ledger = services.ledger
        nowPlaying = services.nowPlaying
        calendar = services.calendar
        shelf = services.shelf
        suggestions = services.suggestions
        inserter = services.inserter
        notifications = services.notifications
        openExternalURL = isInert ? { _ in } : { NSWorkspace.shared.open($0) }

        chat.onReplyFinished = { [weak self] in
            self?.noteReplyFinished()
        }
        shelf.onHoldsChanged = { [weak self] in
            self?.refreshHolds()
        }
        shelf.onError = { [weak self] message in
            self?.transientError = message
        }
        voice.onNotice = { [weak self] message in
            self?.showNotice(message, symbol: "info.circle", lifetime: .seconds(4))
        }
        startTrackingFrontmostApp()
        startObservingSubsystems()
        installFeatures()
    }

    // MARK: - Presentation

    func open(reason: OpenReason, focus: Bool) {
        let wasOpen = isOpen
        if !wasOpen {
            let hasDraft = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty || pendingAttachmentLoads > 0
            history.startFreshIfIdle(hasUnreadReply: hasUnreadReply, hasDraft: hasDraft)
            openContextApp = currentExternalApp.flatMap(AppRef.init)
            openSerial += 1
            engagedThisOpen = false
        }
        let hadUnread = hasUnreadReply

        presentation = .open
        openReason = reason
        isFolded = false
        if !wasOpen {
            onPresentationChange?(.open)
        }

        if !wasOpen || replyToRevealOnOpen != nil {
            restoreReadingOnOpen(hadUnread: hadUnread)
        }
        hasUnreadReply = false
        unreadReplyID = nil

        refreshSuggestedTab(allowPrompt: reason == .click || reason == .hotkey)
        if !wasOpen {
            suggestions.refresh(for: openContextApp, allowSelection: reason != .drag)
            glance.notchDidOpen()
            calendar.panelDidOpen()
        }

        if focus {
            isSoftFocused = false
            isEngaged = true
            engagedThisOpen = true
            onRequestKey?(true)
            focusRequest += 1
        }
        refreshHolds()
        refreshApprovalVisibility()
    }

    func close(_ reason: CloseReason = .programmatic) {
        let wasOpen = isOpen
        let isFold = reason == .systemUI
        presentation = .closed
        openReason = nil
        isEngaged = false
        isSoftFocused = false
        isMenuPresented = false
        overlay = nil
        dropSession = nil

        if !isFold {
            // The user (or Otto on their behalf) closed it: a fold in progress is theirs now.
            isFolded = false
            isPinned = false
            leaveRoute()
            route = .chat
            clearContextSuggestions()
            history.commitPendingDeletion()
        }
        if systemUIWait == nil, let prompt = permissionPrompt {
            // A flow already on "You're all set" still resumes its action.
            finishPermissionFlow(granted: prompt.phase == .granted)
        }
        if shelf.isShowingQuickLook {
            shelf.quickLook.hide()
        }
        calendar.panelDidClose()
        if engagedThisOpen {
            history.noteActivity()
        }
        engagedThisOpen = false
        if reason.isUserInitiated {
            voice.stopSpeaking()
            if voice.isActive { voice.cancel() }
        }
        manualStayOpenHolds.subtract([.voiceReplyHold, .shelfLanding])
        voiceReplyHold = false
        landingHoldReleased = shelf.isHoldingLanding

        onRequestKey?(false)
        if wasOpen {
            onPresentationChange?(.closed)
        }
        if !isPickingFiles, let app = appToReactivate {
            appToReactivate = nil
            if NSApp.isActive, !app.isTerminated {
                app.activate(options: [])
            }
        }
        refreshHolds()
        refreshApprovalVisibility()
    }

    func toggle(reason: OpenReason) {
        if isOpen {
            close(.user)
        } else {
            open(reason: reason, focus: reason != .hover && reason != .drag)
        }
    }

    /// The user clicked into the panel.
    func engage() {
        isSoftFocused = false
        isEngaged = true
        engagedThisOpen = true
        setVoiceReplyHold(false)
        onRequestKey?(true)
        // A hover (or drag) open looks the tab up without asking for Automation permission, and with
        // a 90 ms dwell it always wins the race against a click. Clicking in is a deliberate act, so
        // look again, this time allowed to show the consent prompt.
        if isOpen, !lastLookupAllowedPrompt, suggestedTab == nil, autoAttachedTabID == nil {
            refreshSuggestedTab(allowPrompt: true)
        }
    }

    /// The pointer rested on the open panel: take the keyboard without engaging (§6.2). Never asks for Automation.
    func softFocus() {
        guard isOpen, !isEngaged, !isSoftFocused else { return }
        isSoftFocused = true
        onRequestKey?(true)
        focusRequest += 1
    }

    /// Hands the keyboard back to the user's app unless they engaged in the meantime.
    func releaseSoftFocus() {
        guard isSoftFocused else { return }
        isSoftFocused = false
        guard !isEngaged else { return }
        onRequestKey?(false)
    }

    /// The panel resigned key (the window controller calls it; key is already gone).
    func panelDidLoseKey() {
        isSoftFocused = false
        if isEngaged && !isMenuPresented {
            isEngaged = false
        }
    }

    /// Pinned: the global shortcut hands the keyboard back without closing.
    func disengage() {
        isSoftFocused = false
        isEngaged = false
        onRequestKey?(false)
    }

    /// The pointer entered the open shape: a new enter/exit cycle ends the voice reply hold.
    func pointerEnteredPanel() {
        setVoiceReplyHold(false)
    }

    func togglePin() {
        isPinned.toggle()
        if isPinned, !hasShownPinNotice {
            hasShownPinNotice = true
            showNotice("Pinned. Otto stays open while you work", symbol: "pin")
        }
    }

    /// Tall reading mode needs a conversation. The window grows (`onWillChangeOpenHeightLimit`) before the flag flips.
    func setTallMode(_ on: Bool) {
        guard on != isTallMode else { return }
        if on, chat.messages.isEmpty {
            showNotice("Tall mode is for reading. Start a conversation first.", symbol: "info.circle")
            return
        }
        let limit = on && systemUIWait == nil ? tallOpenHeight : NotchMetrics.maxOpenHeight
        if limit != openHeightLimit {
            onWillChangeOpenHeightLimit?(limit)
        }
        isTallMode = on
    }

    func toggleTallMode() {
        setTallMode(!isTallMode)
    }

    // MARK: - Holds

    func setHold(_ hold: StayOpenHold, _ active: Bool) {
        if active {
            manualStayOpenHolds.insert(hold)
        } else {
            manualStayOpenHolds.remove(hold)
        }
        if hold == .voiceReplyHold, voiceReplyHold != active {
            voiceReplyHold = active
        }
        refreshHolds()
    }

    func setModalHold(_ hold: ModalHold, _ active: Bool) {
        if active {
            manualModalHolds.insert(hold)
        } else {
            manualModalHolds.remove(hold)
        }
        refreshHolds()
    }

    /// The voice flow's hold after a spoken question (cleared by engage, close, a new pointer enter).
    func setVoiceReplyHold(_ active: Bool) {
        guard voiceReplyHold != active || manualStayOpenHolds.contains(.voiceReplyHold) != active else { return }
        setHold(.voiceReplyHold, active)
    }

    /// Re-derives the holds that follow subsystem state (§4.5 table) and adds the ones set by hand.
    func refreshHolds() {
        if !shelf.isHoldingLanding {
            landingHoldReleased = false
        }
        var holds = manualStayOpenHolds
        if voice.isActive { holds.insert(.voiceSession) }
        if shelf.isDraggingOut { holds.insert(.shelfDragOut) }
        if shelf.isHoldingLanding, !landingHoldReleased { holds.insert(.shelfLanding) }
        if inserter.activity != nil { holds.insert(.insertInProgress) }
        if promptRequiresDecision { holds.insert(.promptDecision) }
        if holds != stayOpenHolds {
            stayOpenHolds = holds
        }

        var modal = manualModalHolds
        if shelf.isSharing { modal.insert(.sharing) }
        if shelf.isShowingQuickLook { modal.insert(.quickLook) }
        if modal != modalHolds {
            modalHolds = modal
        }
    }

    // MARK: - Fold for system UI

    /// Keeps `systemUIWait` current and folds or unfolds the notch around it (§4.5).
    func updateSystemUIWait(_ wait: SystemUIWait?) {
        pruneNotchPermissionRequests()
        guard !systemUIWaitIsSeeded, wait != systemUIWait else { return }
        let previous = systemUIWait
        let limit = isTallMode && wait == nil ? tallOpenHeight : NotchMetrics.maxOpenHeight
        if limit != openHeightLimit {
            onWillChangeOpenHeightLimit?(limit)
        }
        systemUIWait = wait

        if previous == nil, let wait, isOpen {
            Self.logger.info("Folding the notch while macOS shows its own UI")
            isFolded = true
            close(.systemUI)
            announce("Otto moved out of the way. \(wait.dropText)")
        } else if wait == nil, isFolded {
            isFolded = false
            if !isOpen {
                Self.logger.info("Reopening the notch after the system UI closed")
                open(reason: .programmatic, focus: false)
            }
        }
        refreshApprovalVisibility()
    }

    /// Drops notch-started requests whose macOS UI is gone.
    private func pruneNotchPermissionRequests() {
        guard !notchPermissionRequests.isEmpty else { return }
        let awaited = permissions.awaiting.map(Self.permission(of:))
        let kept = notchPermissionRequests.filter { $0 == awaited || notchRequestsInFlight[$0, default: 0] > 0 }
        if kept != notchPermissionRequests {
            notchPermissionRequests = kept
        }
    }

    /// Marks `permission` as asked for by the notch for as long as `body` runs and its macOS UI stays up.
    func trackNotchPermissionRequest<T>(_ permission: Permission, _ body: () async -> T) async -> T {
        notchRequestsInFlight[permission, default: 0] += 1
        notchPermissionRequests.insert(permission)
        let result = await body()
        let remaining = notchRequestsInFlight[permission, default: 1] - 1
        notchRequestsInFlight[permission] = remaining > 0 ? remaining : nil
        updateSystemUIWait(derivedSystemUIWait)
        return result
    }

    /// Opens System Settings for `permission` as part of a notch flow (the notch folds while it is up).
    func openSystemSettingsFromNotch(for permission: Permission) {
        notchPermissionRequests.insert(permission)
        permissions.openSystemSettings(for: permission)
    }

    static func permission(of wait: PermissionWait) -> Permission {
        switch wait {
        case .systemPrompt(let permission), .systemSettings(let permission): return permission
        }
    }

    // MARK: - Routes and overlay

    /// Ignores unavailable routes; bumps `focusRequest` so the page's first responder takes the keyboard.
    func navigate(to route: NotchRoute) {
        guard availableRoutes.contains(route) else { return }
        if route != self.route {
            leaveRoute()
            self.route = route
            if route == .history {
                recents.activate(preferred: history.continuation?.id)
            }
        }
        focusRequest += 1
        refreshApprovalVisibility()
    }

    /// Opens (focused) when closed; the active route toggles back to Chat.
    func toggle(route: NotchRoute) {
        guard availableRoutes.contains(route) else { return }
        if !isOpen {
            open(reason: .programmatic, focus: true)
            navigate(to: route)
            return
        }
        navigate(to: self.route == route ? .chat : route)
    }

    func toggleShortcutSheet() {
        if overlay == nil {
            if route != .chat { navigate(to: .chat) }
            overlay = .shortcutSheet
        } else {
            overlay = nil
        }
    }

    func dismissOverlay() {
        overlay = nil
    }

    private func leaveRoute() {
        guard route == .history else { return }
        recents.deactivate()
        history.commitPendingDeletion()
    }

    // MARK: - Cards

    /// Queues a card (de-duplicated by kind: a card already queued is updated in place).
    func present(card: NotchCard) {
        if let index = cardQueue.firstIndex(where: { $0.card.kind == card.kind }) {
            cardQueue[index].card = card
        } else {
            cardQueue.append(QueuedCard(card: card, queuedAtOpen: openSerial))
        }
        refreshHolds()
        refreshApprovalVisibility()
    }

    /// Presents `card` and returns the action the user picks on it (the default action is then left to the caller).
    func awaitCardDecision(_ card: NotchCard) async -> NotchCard.Action {
        if let earlier = cardWaiters.removeValue(forKey: card.kind) {
            earlier.resume(returning: .dismiss)
        }
        present(card: card)
        return await withCheckedContinuation { continuation in
            cardWaiters[card.kind] = continuation
        }
    }

    /// Takes the card of `kind` out of the queue. Returns the waiter that asked for its decision, if any.
    @discardableResult func removeCard(kind: NotchCard.Kind) -> CheckedContinuation<NotchCard.Action, Never>? {
        cardQueue.removeAll { $0.card.kind == kind }
        refreshHolds()
        refreshApprovalVisibility()
        return cardWaiters.removeValue(forKey: kind)
    }

    /// The history notice is queued once History has read its index (never in inert graphs) and leaves the queue
    /// when it was answered anywhere (the dock or Recents).
    private func syncHistoryNotice(_ wanted: Bool) {
        let queued = cardQueue.contains { $0.card.kind == .historyNotice }
        if wanted, !queued {
            present(card: Self.historyNoticeCard(retention: settings.history.retention))
        } else if !wanted, queued {
            removeCard(kind: .historyNotice)?.resume(returning: .dismiss)
        }
    }

    // MARK: - Permission prompt state

    /// Shows the explain step of a feature permission flow; `requestPermission` awaits the returned continuation.
    func beginPermissionPrompt(_ prompt: PermissionPrompt, continuation: CheckedContinuation<Bool, Never>) {
        finishPermissionFlow(granted: false)
        lastPermissionDeclineAction = nil
        permissionPrompt = prompt
        permissionContinuation = continuation
        refreshHolds()
        refreshApprovalVisibility()
    }

    /// Moves the current flow to `phase` (ignored when `id` is no longer the current prompt).
    func setPermissionPhase(_ phase: PermissionPrompt.Phase, for id: UUID) {
        guard var prompt = permissionPrompt, prompt.id == id, prompt.phase != phase else { return }
        prompt.phase = phase
        permissionPrompt = prompt
        refreshHolds()
    }

    /// Runs one step of the current flow; a new step cancels the previous one.
    func runPermissionStep(_ step: @escaping @MainActor () async -> Void) {
        permissionTask?.cancel()
        permissionTask = Task { @MainActor in
            await step()
        }
    }

    /// Ends the current flow once: clears the prompt and resumes `requestPermission`.
    func finishPermissionFlow(granted: Bool, declinedWith action: PermissionCardAction? = nil) {
        permissionTask?.cancel()
        permissionTask = nil
        let continuation = permissionContinuation
        permissionContinuation = nil
        if permissionPrompt != nil {
            permissionPrompt = nil
        }
        if !granted, let action {
            lastPermissionDeclineAction = action
        }
        continuation?.resume(returning: granted)
        refreshHolds()
        refreshApprovalVisibility()
    }

    /// The step a tool approval's permission card is on (nil when `callID` isn't the pending approval).
    func setToolPermissionPhase(_ phase: PermissionPrompt.Phase?, callID: String) {
        guard let phase else {
            if toolPermission?.callID == callID { toolPermission = nil }
            return
        }
        let state = ToolPermissionState(callID: callID, phase: phase)
        if toolPermission != state {
            toolPermission = state
        }
    }

    /// The approval was declined (or went away): stop asking macOS on its behalf.
    func endToolPermissionFlow(callID: String) {
        toolPermissionTask?.cancel()
        toolPermissionTask = nil
        setToolPermissionPhase(nil, callID: callID)
    }

    func runToolPermissionStep(_ step: @escaping @MainActor () async -> Void) {
        toolPermissionTask?.cancel()
        toolPermissionTask = Task { @MainActor in
            await step()
        }
    }

    // MARK: - Approval visibility (§4.5)

    /// Stamps `approvalVisibility` the moment the pending approval is on screen and reviewed, and clears it the
    /// moment any condition stops holding (a later stamp restarts arming from zero).
    func refreshApprovalVisibility() {
        guard let approval = chat.pendingApproval else {
            reviewedApprovalCallID = nil
            if approvalVisibility != nil { approvalVisibility = nil }
            return
        }
        let onScreen = isOpen && !isFolded && route == .chat && !isCapturingScreen
            && currentPrompt == .approval(approval)
        guard onScreen else {
            // Off screen: the card reports its review again when it reappears.
            reviewedApprovalCallID = nil
            if approvalVisibility != nil { approvalVisibility = nil }
            return
        }
        guard reviewedApprovalCallID == approval.callID else {
            if approvalVisibility != nil { approvalVisibility = nil }
            return
        }
        if approvalVisibility?.callID != approval.callID {
            approvalVisibility = ApprovalVisibility(callID: approval.callID, since: now(), sinceUptime: uptime())
        }
    }

    /// The card's body fits, or the user scrolled a long script to its end (§5.7).
    func noteApprovalReviewed(callID: String) {
        guard chat.pendingApproval?.callID == callID else { return }
        reviewedApprovalCallID = callID
        refreshApprovalVisibility()
    }

    /// Window controller's local mouse-down monitor, for clicks on the panel (InputProvenance.evidence).
    func notePanelMouseDown(uptime: TimeInterval, isHardware: Bool) {
        lastPanelMouseDown = (uptime: uptime, isHardware: isHardware)
    }

    /// A new approval starts with fresh card options (the picker's preselected calendar or list).
    private func approvalDidChange() {
        let approval = chat.pendingApproval
        if approval?.callID != observedApprovalCallID {
            observedApprovalCallID = approval?.callID
            approvalOptions = Self.defaultOptions(for: approval)
            toolPermissionTask?.cancel()
            toolPermissionTask = nil
            if let previous = toolPermission, previous.callID != approval?.callID {
                toolPermission = nil
            }
        }
        refreshHolds()
        refreshApprovalVisibility()
    }

    private static func defaultOptions(for approval: PendingApproval?) -> ApprovalOptions {
        switch approval?.body {
        case .event(let preview)?: return ApprovalOptions(calendarIdentifier: preview.selectedCalendarID)
        case .reminder(let preview)?: return ApprovalOptions(calendarIdentifier: preview.selectedListID)
        default: return ApprovalOptions()
        }
    }

    // MARK: - Notices

    /// A neutral line under the composer; re-arms its timer even when the text is the same.
    func showNotice(_ text: String, symbol: String = "checkmark.circle", lifetime: Duration = .milliseconds(2400)) {
        let notice = TransientNotice(text: text, symbol: symbol)
        transientNotice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, let self, self.transientNotice == notice else { return }
            self.transientNotice = nil
        }
    }

    // MARK: - Editing (↑ recall and resend)

    /// Recalls the last question into an empty composer for editing. False (and nothing happens) otherwise.
    @discardableResult func recallLastMessage() -> Bool {
        guard !isEditing,
              composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty,
              let message = chat.lastUserMessage else { return false }
        composerText = message.text
        attachments = message.attachments
        editingTurn = EditingTurn(userMessageID: message.id)
        focusRequest += 1
        return true
    }

    /// Esc while editing: the composer was empty before the recall, so clearing it loses nothing.
    func cancelEditing() {
        guard isEditing else { return }
        editingTurn = nil
        composerText = ""
        attachments = []
    }

    // MARK: - Reading position (§6.6)

    func consumeReadingAnchor() -> ReadingAnchor? {
        let anchor = readingAnchor
        readingAnchor = nil
        return anchor
    }

    /// One-shot scroll request to the top of `messageID`.
    func setReadingAnchor(_ messageID: UUID) {
        readingAnchorSerial += 1
        readingAnchor = ReadingAnchor(messageID: messageID, serial: readingAnchorSerial)
    }

    /// A notification or the reply preview: open at the start of that answer (or where the user left off).
    func openToReply(_ messageID: UUID?) {
        if let messageID, chat.messages.contains(where: { $0.id == messageID }) {
            replyToRevealOnOpen = messageID
        }
        if isOpen {
            if route != .chat { navigate(to: .chat) }
            if let messageID = replyToRevealOnOpen {
                replyToRevealOnOpen = nil
                setReadingAnchor(messageID)
            }
            engage()
            focusRequest += 1
        } else {
            open(reason: .programmatic, focus: true)
        }
    }

    private func restoreReadingOnOpen(hadUnread: Bool) {
        let unread = hadUnread ? (unreadReplyID ?? chat.lastFinishedAssistantID) : nil
        let reveal = replyToRevealOnOpen ?? unread
        replyToRevealOnOpen = nil
        let target = ReadingRestore.target(unreadReplyID: reveal, saved: history.currentReadingPosition,
                                           messages: chat.messages)
        if case .messageTop(let messageID) = target {
            setReadingAnchor(messageID)
        }
    }

    /// The reply finished while the notch was closed: it is unread. A feature that wraps `chat.onReplyFinished`
    /// calls this first.
    func noteReplyFinished() {
        guard !isOpen else { return }
        hasUnreadReply = true
        unreadReplyID = chat.lastFinishedAssistantID
    }

    // MARK: - Drop

    func setDropSession(_ session: DropSession?) {
        if dropSession != session {
            dropSession = session
        }
    }

    /// Services and other entry points that know the app the request came from (nil: none, never Otto).
    func setOpenContextApp(_ app: AppRef?) {
        openContextApp = app
    }

    /// The composer (or the active route's first responder) takes the keyboard.
    func requestFocus() {
        focusRequest += 1
    }

    // MARK: - Chat

    func send() {
        guard canSend else { return }
        // Checked again here (not only when each chip was added): the model may have changed since,
        // and a PDF within Opus's page limit can be over Haiku's. Such a message could never be answered.
        if let problem = AttachmentBudget.problem(with: attachments, model: settings.model) {
            transientError = problem.localizedDescription
            return
        }
        let text = composerText
        let sent = attachments
        let selection = sent.lazy.compactMap { self.selectionSnapshots[$0.id] }.first
        let previousUserID = chat.lastUserMessage?.id

        voice.stopSpeaking()
        if let editing = editingTurn {
            editingTurn = nil
            if editing.userMessageID == chat.lastUserMessage?.id {
                chat.replaceLastTurn(text: text, attachments: sent)
            } else {
                chat.send(text: text, attachments: sent)
            }
        } else {
            chat.send(text: text, attachments: sent)
        }
        composerText = ""
        attachments = []
        autoAttachedTabID = nil
        for attachment in sent {
            selectionSnapshots[attachment.id] = nil
        }

        if let userID = chat.lastUserMessage?.id, userID != previousUserID {
            if let app = openContextApp {
                inserter.recordTarget(userMessageID: userID, target: InsertTarget(app: app, selection: selection))
            }
            if isSendingVoiceTurn {
                voiceTurnUserMessageIDs.insert(userID)
            }
        }
        isSendingVoiceTurn = false
        history.dismissContinuation()
        history.noteActivity()
        if isOpen {
            isEngaged = true
            engagedThisOpen = true
        }
    }

    func stop() {
        chat.cancel()
    }

    /// ⌘N: History saves the conversation and offers it as the continuation.
    func newChat() {
        voice.stopSpeaking()
        editingTurn = nil
        history.startNewConversation()
        composerText = ""
        attachments = []
        autoAttachedTabID = nil
        selectionSnapshots = [:]
        voiceTurnUserMessageIDs = []
        hasUnreadReply = false
        unreadReplyID = nil
        transientError = nil
        readingAnchor = nil
        if route != .chat {
            leaveRoute()
            route = .chat
        }
        setTallMode(false)
        inserter.reset()
        notifications?.clearDelivered()
        if isEngaged {
            focusRequest += 1
        }
        refreshApprovalVisibility()
    }

    func copyLastResponse() {
        guard let text = chat.lastAssistantText else {
            transientError = "There's no reply to copy yet."
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) {
            showNotice("Copied the last reply")
        } else {
            transientError = "Couldn't copy the reply to the clipboard."
        }
    }

    func openSettings() {
        openSettings(tab: nil)
    }

    /// Closes the notch, then opens Settings on `tab`, scrolled to `anchor`.
    func openSettings(tab: SettingsTab?, anchor: SettingsAnchor? = nil) {
        close(.programmatic)
        if let onOpenSettingsTab {
            onOpenSettingsTab(tab ?? anchor?.tab, anchor)
        } else {
            onOpenSettings?()
        }
    }

    // MARK: - Attachments

    func addFiles(_ urls: [URL]) {
        var accepted: [URL] = []
        var hitLimit = false
        for url in urls where url.isFileURL {
            let fileURL = url.standardizedFileURL
            let isDuplicate = accepted.contains(fileURL)
                || loadingFileURLs.contains(fileURL)
                || attachments.contains { Self.isSameSource($0.sourceURL, fileURL) }
            if isDuplicate { continue }
            guard attachments.count + pendingAttachmentLoads + accepted.count < Self.maxAttachments else {
                hitLimit = true
                break
            }
            accepted.append(fileURL)
        }
        if hitLimit {
            transientError = Self.attachmentLimitMessage
        }
        guard !accepted.isEmpty else { return }

        pendingAttachmentLoads += accepted.count
        loadingFileURLs.formUnion(accepted)

        // Load concurrently (AttachmentLoader works off the main actor), but commit in the order the
        // user picked so the chips appear in that order.
        let loads = accepted.map { url in
            (url, Task { try await AttachmentLoader.load(fileURL: url) })
        }
        Task { [weak self] in
            var failures: [Error] = []
            for (url, load) in loads {
                let result = await load.result
                guard let self else { continue }
                self.pendingAttachmentLoads = max(0, self.pendingAttachmentLoads - 1)
                self.loadingFileURLs.remove(url)
                switch result {
                case .success(let attachment):
                    self.addAttachment(attachment)
                case .failure(let error):
                    failures.append(error)
                }
            }
            self?.report(failures)
        }
    }

    /// Adds an attachment unless one with the same source URL is already attached; at most
    /// `maxAttachments` (reports `transientError` when full).
    func addAttachment(_ attachment: Attachment) {
        insert(attachment)
    }

    func removeAttachment(id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let removed = attachments.remove(at: index)
        selectionSnapshots[id] = nil
        if removed.id == autoAttachedTabID {
            autoAttachedTabID = nil
        }
        if removed.kind == .webPage, let url = removed.sourceURL {
            dismissedTabURL = url
        }
    }

    func acceptSuggestedTab() {
        guard let tab = suggestedTab else { return }
        switch insert(tab) {
        case .added, .duplicate:
            suggestedTab = nil
        case .full, .rejected:
            break
        }
    }

    func dismissSuggestedTab() {
        guard let tab = suggestedTab else { return }
        dismissedTabURL = tab.sourceURL
        suggestedTab = nil
    }

    /// Shows an NSOpenPanel (multi-select). The notch stays open while it is up.
    func pickFiles() {
        if isPickingFiles {
            // Already up (perhaps behind another app's window): bring it back to the front.
            NSApp.activate()
            filePanel?.makeKeyAndOrderFront(nil)
            return
        }
        guard remainingCapacity > 0 else {
            transientError = Self.attachmentLimitMessage
            return
        }
        isPickingFiles = true

        let panel = NSOpenPanel()
        panel.title = "Attach Files"
        panel.prompt = "Attach"
        panel.message = "Choose files for Otto to look at."
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        // The notch stays open (and above normal windows) while picking, so the picker must sit above
        // it; otherwise the conversation covers its toolbar and file list and takes its clicks.
        panel.level = Self.filePickerLevel
        filePanel = panel

        // Otto is an accessory app behind a non-activating panel; activate so the open panel
        // comes to the front and takes keyboard focus.
        if !NSApp.isActive {
            appToReactivate = currentExternalApp
        }
        NSApp.activate()
        panel.begin { [weak self] response in
            let urls = response == .OK ? panel.urls : []
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPickingFiles = false
                self.filePanel = nil
                self.open(reason: .programmatic, focus: true)
                if !urls.isEmpty {
                    self.addFiles(urls)
                }
            }
        }
    }

    /// Hides the panel, lets the user pick a region, attaches it and reopens focused.
    func captureScreenshot() {
        guard !isCapturingScreen else { return }
        guard remainingCapacity > 0 else {
            transientError = Self.attachmentLimitMessage
            return
        }
        isCapturingScreen = true
        refreshApprovalVisibility()
        onBeginScreenCapture?()

        Task { [weak self] in
            guard let capture = self?.captureInteractive else { return }
            let result: Result<Attachment?, Error>
            do {
                result = .success(try await capture())
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.isCapturingScreen = false
            self.onEndScreenCapture?()
            switch result {
            case .success(let attachment?):
                self.addAttachment(attachment)
            case .success(nil):
                break // The user cancelled the selection.
            case .failure(let error):
                Self.logger.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
                self.transientError = error.localizedDescription
            }
            self.open(reason: .programmatic, focus: true)
        }
    }

    /// Attaches files/images/links from the general pasteboard; short text goes into the composer.
    func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        // Copied files go through `addFiles`, which only loads as many as there is room for (plus
        // per-file placeholders and duplicate checks), instead of reading every one and dropping the
        // extras afterwards.
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if !fileURLs.isEmpty {
            guard remainingCapacity > 0 else {
                transientError = Self.attachmentLimitMessage
                return
            }
            addFiles(fileURLs)
            return
        }
        // Only image reads can take a moment; plain text is instant, and a placeholder chip flashing
        // for it would make the layout jump.
        let reservesPlaceholder = Self.mayContainFilesOrImages(pasteboard)
        // Pasted images are each read and encoded, so only load as many as there is room for (at
        // least one, so a full notch still says why nothing was added).
        let limit = max(1, remainingCapacity)
        if reservesPlaceholder {
            pendingAttachmentLoads += 1
        }
        Task { [weak self] in
            let (content, errors) = await AttachmentLoader.load(pasteboard: pasteboard, limit: limit)
            guard let self else { return }
            if reservesPlaceholder {
                self.pendingAttachmentLoads = max(0, self.pendingAttachmentLoads - 1)
            }
            let receivedAnything = !content.attachments.isEmpty
                || !(content.inlineText ?? "").isEmpty || !errors.isEmpty
            if receivedAnything {
                self.integrate(content, errors: errors)
            } else {
                self.transientError = "There's nothing on the clipboard to attach."
            }
        }
    }

    /// Accepts a drop onto the open notch. Returns true if any provider carries something loadable.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let candidates = providers.filter(Self.isLoadable)
        guard !candidates.isEmpty else { return false }
        guard remainingCapacity > 0 else {
            transientError = Self.attachmentLimitMessage
            return false
        }
        // Load only what can still be attached: every item is read and encoded in full (up to tens of
        // MB each), so loading 40 dropped PDFs to keep 10 would hold all of them in memory at once.
        let loadable = Array(candidates.prefix(remainingCapacity))
        if loadable.count < candidates.count {
            transientError = Self.attachmentLimitMessage
        }

        if isOpen {
            engage()
            focusRequest += 1
        } else {
            open(reason: .drag, focus: true)
        }

        let placeholders = loadable.count
        pendingAttachmentLoads += placeholders
        Task { [weak self] in
            let (content, errors) = await AttachmentLoader.load(providers: loadable)
            guard let self else { return }
            self.pendingAttachmentLoads = max(0, self.pendingAttachmentLoads - placeholders)
            self.integrate(content, errors: errors)
        }
        return true
    }

    // MARK: - Snapshots

    /// Snapshots only: sets visible state directly, without callbacks or lookups.
    func debugSeed(
        presentation: Presentation,
        composerText: String,
        attachments: [Attachment],
        suggestedTab: Attachment?,
        hasUnreadReply: Bool
    ) {
        self.presentation = presentation
        self.openReason = presentation == .open ? .programmatic : nil
        self.composerText = composerText
        self.attachments = attachments
        self.suggestedTab = suggestedTab
        self.hasUnreadReply = hasUnreadReply
    }

    /// Snapshots and SelfTest only: the feature state a scene needs, set directly (no fold, no timers).
    func debugSeed(features: NotchDebugSeed) {
        route = features.route
        overlay = features.overlay
        isPinned = features.isPinned
        isTallMode = features.isTallMode
        editingTurn = features.editingTurnMessageID.map(EditingTurn.init(userMessageID:))
        cardQueue = features.card.map { [QueuedCard(card: $0, queuedAtOpen: openSerial - 1)] } ?? []
        permissionPrompt = features.permissionPrompt
        transientNotice = features.notice
        dropSession = features.dropSession
        readingAnchor = nil
        if let messageID = features.readingAnchorMessageID {
            setReadingAnchor(messageID)
        }
        isSoftFocused = features.isSoftFocused
        systemUIWaitIsSeeded = features.systemUIWait != nil
        systemUIWait = features.systemUIWait
        isFolded = features.systemUIWait != nil
        if let since = features.approvalVisibleSince, let approval = chat.pendingApproval {
            let age = max(0, now().timeIntervalSince(since))
            reviewedApprovalCallID = approval.callID
            approvalVisibility = ApprovalVisibility(callID: approval.callID, since: since, sinceUptime: uptime() - age)
        } else {
            approvalVisibility = nil
        }
        refreshHolds()
    }

    // MARK: - Attachment helpers (internal for the feature files)

    enum AttachmentInsertOutcome { case added, duplicate, full, rejected }

    var remainingCapacity: Int {
        max(0, Self.maxAttachments - attachments.count - pendingAttachmentLoads)
    }

    @discardableResult
    func insert(_ attachment: Attachment) -> AttachmentInsertOutcome {
        if let url = attachment.sourceURL, attachments.contains(where: { Self.isSameSource($0.sourceURL, url) }) {
            return .duplicate
        }
        guard attachments.count < Self.maxAttachments else {
            transientError = Self.attachmentLimitMessage
            return .full
        }
        // Keep the message sendable: a PDF over the model's page limit, or one attachment too many for
        // the request size limit, is refused here with the reason rather than failing at the API.
        if let problem = AttachmentBudget.problem(with: attachments + [attachment], model: settings.model) {
            transientError = problem.localizedDescription
            return .rejected
        }
        attachments.append(attachment)
        if let suggestion = suggestedTab, Self.isSameSource(suggestion.sourceURL, attachment.sourceURL) {
            suggestedTab = nil
        }
        return .added
    }

    func report(_ errors: [Error]) {
        guard let first = errors.first else { return }
        let message = first.localizedDescription
        transientError = errors.count == 1
            ? message
            : "\(message) (and \(errors.count - 1) more couldn't be attached)"
    }

    static func isSameSource(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        if lhs.isFileURL && rhs.isFileURL {
            return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
        }
        return lhs.absoluteString == rhs.absoluteString
    }

    private func integrate(_ content: PasteboardContent, errors: [Error]) {
        for attachment in content.attachments {
            insert(attachment)
        }
        if let text = content.inlineText, !text.isEmpty {
            appendToComposer(text)
            focusRequest += 1
        }
        report(errors)
    }

    private func appendToComposer(_ text: String) {
        if composerText.isEmpty || composerText.last?.isWhitespace == true {
            composerText += text
        } else {
            composerText += " " + text
        }
    }

    private func scheduleTransientErrorClear() {
        transientErrorTask?.cancel()
        transientErrorTask = nil
        guard let message = transientError else { return }
        let lifetime = transientErrorLifetime
        transientErrorTask = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, let self, self.transientError == message else { return }
            self.transientError = nil
        }
    }

    private static func isLoadable(_ provider: NSItemProvider) -> Bool {
        [UTType.fileURL, .image, .url, .plainText].contains { type in
            provider.hasItemConformingToTypeIdentifier(type.identifier)
        }
    }

    private static func mayContainFilesOrImages(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        return pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier])
    }

    // MARK: - Subsystem observation

    /// What the holds follow (§4.5 table).
    private struct HoldSources: Equatable {
        var voiceActive = false
        var draggingOut = false
        var landing = false
        var inserting = false
        var promptDecision = false
        var sharing = false
        var quickLook = false
    }

    private var holdSources: HoldSources {
        HoldSources(voiceActive: voice.isActive, draggingOut: shelf.isDraggingOut, landing: shelf.isHoldingLanding,
                    inserting: inserter.activity != nil, promptDecision: promptRequiresDecision,
                    sharing: shelf.isSharing, quickLook: shelf.isShowingQuickLook)
    }

    private var wantsHistoryNotice: Bool {
        history.isIndexLoaded && settings.history.enabled && !settings.history.noticeAcknowledged
    }

    private func startObservingSubsystems() {
        systemUIWait = derivedSystemUIWait
        observedApprovalCallID = chat.pendingApproval?.callID
        approvalOptions = Self.defaultOptions(for: chat.pendingApproval)
        observations = [
            ObservationLoop(read: { [weak self] in self?.derivedSystemUIWait }, onChange: { [weak self] wait in
                self?.updateSystemUIWait(wait ?? nil)
            }),
            ObservationLoop(read: { [weak self] in self?.holdSources ?? HoldSources() }, onChange: { [weak self] _ in
                self?.refreshHolds()
            }),
            ObservationLoop(read: { [weak self] in self?.chat.pendingApproval?.callID }, onChange: { [weak self] _ in
                self?.approvalDidChange()
            }),
            ObservationLoop(read: { [weak self] in self?.wantsHistoryNotice ?? false }, onChange: { [weak self] wanted in
                self?.syncHistoryNotice(wanted)
            }),
        ]
        syncHistoryNotice(wantsHistoryNotice)
        refreshHolds()
    }

    // MARK: - Suggested browser tab

    private func startTrackingFrontmostApp() {
        let workspace = NSWorkspace.shared
        if let app = workspace.frontmostApplication, !Self.isOtto(app) {
            lastExternalApp = app
        }
        let center = workspace.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  !Self.isOtto(app) else { return }
            MainActor.assumeIsolated {
                self?.lastExternalApp = app
            }
        }
        activationObserver = NotificationObservation(center: center, token: token)
    }

    /// The app the user is working in: the frontmost app unless that is Otto itself (e.g. while
    /// the file picker is up), in which case the last other app that was frontmost.
    var currentExternalApp: NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication, !Self.isOtto(front), !front.isTerminated {
            return front
        }
        guard let last = lastExternalApp, !last.isTerminated else { return nil }
        return last
    }

    /// Close (not the fold): the chips described the app the user was in when the notch opened.
    private func clearContextSuggestions() {
        suggestedTab = nil
        removeAutoAttachedTab(keepingDraftContext: true)
        suggestionGeneration += 1
        suggestionTask?.cancel()
        suggestionTask = nil
        releaseTabAutomationPrompt()
        suggestions.clear()
    }

    private func releaseTabAutomationPrompt() {
        guard tabLookupOwnsAutomationPrompt else { return }
        tabLookupOwnsAutomationPrompt = false
        automationPromptInFlight = nil
    }

    private func refreshSuggestedTab(allowPrompt: Bool) {
        suggestionGeneration += 1
        lastLookupAllowedPrompt = allowPrompt
        suggestionTask?.cancel()
        suggestionTask = nil
        releaseTabAutomationPrompt()

        guard settings.suggestBrowserTab,
              let app = currentExternalApp,
              BrowserContext.isSupportedBrowser(bundleID: app.bundleIdentifier) else {
            suggestedTab = nil
            return
        }

        let generation = suggestionGeneration
        suggestionTask = Task { [weak self] in
            // A prompt-allowed lookup of a browser Otto hasn't been allowed to automate yet shows the system
            // consent dialog. The notch folds out of its way (systemUIWait) and comes back once it's answered.
            var consentWasPending = false
            if allowPrompt, await BrowserContext.automationConsentStatus(of: app) == .wouldPrompt {
                guard !Task.isCancelled, let self, self.isOpen, self.suggestionGeneration == generation else { return }
                self.tabLookupOwnsAutomationPrompt = true
                self.automationPromptInFlight = .automation(bundleID: app.bundleIdentifier ?? "",
                                                            appName: app.localizedName ?? "your browser")
                consentWasPending = true
            }
            var tab = await BrowserContext.currentTab(of: app, allowPrompt: allowPrompt)
            if tab == nil, consentWasPending {
                // The lookup gives up after ~1.5 s while the dialog may still be up; once the user
                // decides, look again (without prompting).
                tab = await self?.lookUpAfterConsent(app: app, generation: generation)
            }
            // Drop results that arrive after the notch closed or after a newer refresh started.
            guard !Task.isCancelled, let self, self.suggestionGeneration == generation else { return }
            self.releaseTabAutomationPrompt()
            guard self.isOpen || self.isFolded else { return }
            self.suggestionTask = nil
            self.applySuggestion(tab)
        }
    }

    /// Polls the Automation consent (never prompting) until the user answers the dialog, then reads
    /// the tab if they allowed it. Gives up when the notch closes, a newer lookup starts, or after a
    /// minute.
    private func lookUpAfterConsent(app: NSRunningApplication, generation: Int) async -> BrowserTab? {
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled, isOpen || isFolded, suggestionGeneration == generation else { return nil }
            switch await BrowserContext.automationConsentStatus(of: app) {
            case .authorized:
                return await BrowserContext.currentTab(of: app, allowPrompt: false)
            case .denied, .unavailable:
                return nil
            case .wouldPrompt:
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        return nil
    }

    /// Internal for tests.
    func applySuggestion(_ tab: BrowserTab?) {
        guard let tab else {
            suggestedTab = nil
            return
        }
        if let dismissed = dismissedTabURL {
            if Self.isSameSource(dismissed, tab.url) {
                suggestedTab = nil
                return
            }
            dismissedTabURL = nil
        }
        if attachments.contains(where: { Self.isSameSource($0.sourceURL, tab.url) }) {
            suggestedTab = nil
            return
        }

        let attachment = AttachmentLoader.makeWebPage(url: tab.url, title: tab.title, appBundleID: tab.bundleID)
        // Only a tab the browser confirmed is not in a private window is attached (and so sent)
        // without asking; Safari tabs and unverified windows are offered as the ghost chip instead.
        if settings.autoAttachBrowserTab && tab.isKnownNonPrivate {
            suggestedTab = nil
            // The user moved to another page since the last lookup: that page's chip goes.
            removeAutoAttachedTab()
            if remainingCapacity > 0, insert(attachment) == .added {
                autoAttachedTabID = attachment.id
            }
        } else {
            // The auto-attached chip stood for the page the user was on before; it goes either way.
            removeAutoAttachedTab()
            suggestedTab = attachment
        }
    }

    /// Takes the auto-attached tab chip back out, so tabs from earlier opens (a hover in passing
    /// counts) don't pile up and ride along with an unrelated message. Once the user has started a
    /// draft it is theirs: when the notch closes with text in the composer the chip stays attached.
    private func removeAutoAttachedTab(keepingDraftContext: Bool = false) {
        guard let id = autoAttachedTabID else { return }
        autoAttachedTabID = nil
        if keepingDraftContext, !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        attachments.removeAll { $0.id == id }
    }

    nonisolated private static func isOtto(_ app: NSRunningApplication) -> Bool {
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        guard let bundleID = app.bundleIdentifier, let ownID = Bundle.main.bundleIdentifier else { return false }
        return bundleID == ownID
    }
}

/// Removes a block-based NotificationCenter observer when released.
private final class NotificationObservation {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit {
        center.removeObserver(token)
    }
}
