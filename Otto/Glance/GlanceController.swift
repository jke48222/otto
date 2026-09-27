//
//  GlanceController.swift
//  Otto
//
//  Drives the closed notch's reply glance: the debounced phase from the chat session, the 4-second
//  reply preview (paused while hovered), and the reply/approval notifications with the lock-screen rule.
//

import AppKit
import Foundation
import Observation
import os

@MainActor @Observable final class GlanceController {
    private(set) var displayedPhase: ReplyPhase
    private(set) var preview: ReplyPreview?
    /// The pointer rests on the preview drop: the countdown pauses, and resumes with at least
    /// `ReplyPreviewMetrics.resumeMinimum` left.
    var isPreviewHovered: Bool {
        didSet {
            guard isPreviewHovered != oldValue else { return }
            isPreviewHovered ? pauseCountdown() : resumeCountdown()
        }
    }

    /// Wall clock and sleeping, replaceable so tests run the countdown and the debouncer without waiting.
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Speaks a new preview through VoiceOver; the inert controller and tests replace it.
    @ObservationIgnored var announce: @MainActor (String) -> Void = GlanceController.postAccessibilityAnnouncement

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let chat: ChatSession
    @ObservationIgnored private(set) var notifications: NotificationPresenter?
    @ObservationIgnored private(set) var attention: AttentionMonitor?

    @ObservationIgnored private var debouncer = PhaseDebouncer()
    @ObservationIgnored private var phaseLoop: ObservationLoop<ReplyPhase>?
    @ObservationIgnored private var conversationLoop: ObservationLoop<UUID>?
    @ObservationIgnored private var recheckTask: Task<Void, Never>?
    @ObservationIgnored private var isStarted = false

    /// When the tracked turn left idle; the last finished turn's length.
    @ObservationIgnored private var turnStartedAt: Date?
    @ObservationIgnored private var lastTurnDuration: TimeInterval?

    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewRemaining: Duration = .zero
    @ObservationIgnored private var countdownStartedAt: Date?

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Glance")

    init(settings: AppSettings, chat: ChatSession, notifications: NotificationPresenter?, attention: AttentionMonitor?) {
        self.settings = settings
        self.chat = chat
        self.notifications = notifications
        self.attention = attention
        displayedPhase = .idle
        preview = nil
        isPreviewHovered = false
    }

    /// No notification center, no monitors: previews and phases work in memory only.
    static func inert(settings: AppSettings, chat: ChatSession) -> GlanceController {
        let controller = GlanceController(settings: settings, chat: chat, notifications: nil, attention: nil)
        controller.announce = { _ in }
        return controller
    }

    /// Live app only: follows `chat.phase` through the debouncer, installs notifications and starts the
    /// attention monitor. Idempotent.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        notifications?.install()
        attention?.start()
        phaseLoop = ObservationLoop(read: { [chat] in chat.phase }) { [weak self] phase in
            self?.phaseDidChange(phase)
        }
        // New Chat or a loaded conversation: a preview of a message that is gone goes too.
        conversationLoop = ObservationLoop(read: { [chat] in chat.conversationID }) { [weak self] _ in
            self?.dropPreviewIfMessageIsGone()
        }
        phaseDidChange(chat.phase)
    }

    /// A reply settled. Shows the preview drop when the notch is closed, previews are on and the screen is
    /// awake and unlocked (otherwise the unread dot and the notification cover it), and posts a
    /// notification when the policy asks for one. Turn duration comes from the controller's own phase
    /// tracking (0 when never started).
    func replyDidFinish(messageID: UUID, notchIsOpen: Bool) {
        let duration = finishedTurnDuration()
        guard let message = chat.messages.last(where: { $0.id == messageID }),
              let finished = ReplyPreview.make(from: message) else { return }

        let snapshot = attentionSnapshot()
        let screenIsDark = snapshot.isScreenLocked || snapshot.areDisplaysAsleep
        if !notchIsOpen && settings.glance.replyPreviews && !screenIsDark {
            showPreview(finished)
            announce(Self.announcement(for: finished))
        }

        guard let notifications else { return }
        let policy = settings.glance.notificationPolicy
        guard ReplyNotificationDecider.shouldNotify(policy: policy, notchIsOpen: notchIsOpen, attention: snapshot,
                                                    turnDuration: duration, isApproval: false) else { return }
        notifications.postReply(finished, includeText: includeText(snapshot))
        Self.logger.info("Posted a reply notification (\(String(describing: finished.outcome), privacy: .public))")
    }

    func approvalDidAppear(title: String, notchIsOpen: Bool) {
        guard let notifications else { return }
        let snapshot = attentionSnapshot()
        guard ReplyNotificationDecider.shouldNotify(policy: settings.glance.notificationPolicy, notchIsOpen: notchIsOpen,
                                                    attention: snapshot, turnDuration: currentTurnDuration(),
                                                    isApproval: true) else { return }
        notifications.postApproval(title: title, includeText: includeText(snapshot))
        Self.logger.info("Posted an approval notification")
    }

    func approvalDidResolve() {
        notifications?.withdrawApproval()
    }

    /// preview = nil, clear delivered notifications.
    func notchDidOpen() {
        clearPreview()
        notifications?.clearDelivered()
    }

    /// Snapshots and promo: a fixed phase and preview, no countdown.
    func debugSeed(phase: ReplyPhase, preview: ReplyPreview?) {
        recheckTask?.cancel()
        recheckTask = nil
        previewTask?.cancel()
        previewTask = nil
        countdownStartedAt = nil
        displayedPhase = phase
        self.preview = preview
    }

    // MARK: - Phase

    private func phaseDidChange(_ phase: ReplyPhase) {
        trackTurn(phase)
        applyDebounced(phase)
    }

    private func applyDebounced(_ phase: ReplyPhase) {
        let result = debouncer.update(phase, now: monotonicNow())
        if displayedPhase != result.display { displayedPhase = result.display }
        recheckTask?.cancel()
        recheckTask = nil
        guard let recheckAt = result.recheckAt else { return }
        let delay = max(0, recheckAt - monotonicNow())
        recheckTask = Task { [weak self, sleep] in
            do { try await sleep(.milliseconds(Int((delay * 1000).rounded(.up)))) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.recheckTask = nil
            self.applyDebounced(self.chat.phase)
        }
    }

    private func trackTurn(_ phase: ReplyPhase) {
        if phase.isActive {
            if turnStartedAt == nil {
                turnStartedAt = now()
                lastTurnDuration = nil
            }
        } else if let started = turnStartedAt {
            lastTurnDuration = now().timeIntervalSince(started)
            turnStartedAt = nil
        }
    }

    /// Length of the turn that just finished (the idle phase may not have been observed yet); consumed,
    /// so a later reply never reuses it.
    private func finishedTurnDuration() -> TimeInterval {
        defer {
            turnStartedAt = nil
            lastTurnDuration = nil
        }
        if let started = turnStartedAt { return max(0, now().timeIntervalSince(started)) }
        return max(0, lastTurnDuration ?? 0)
    }

    private func currentTurnDuration() -> TimeInterval {
        turnStartedAt.map { max(0, now().timeIntervalSince($0)) } ?? 0
    }

    private func monotonicNow() -> TimeInterval {
        now().timeIntervalSinceReferenceDate
    }

    /// "Otto replied: ‹first line›" (or "Otto couldn't finish: …" / "Otto declined: …").
    static func announcement(for preview: ReplyPreview) -> String {
        switch preview.outcome {
        case .answered: return "Otto replied: \(preview.text)"
        case .failed: return "Otto couldn't finish: \(preview.text)"
        case .refused: return "Otto declined: \(preview.text)"
        }
    }

    /// Posts an announcement VoiceOver reads at medium priority (a no-op without VoiceOver).
    static func postAccessibilityAnnouncement(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    private func dropPreviewIfMessageIsGone() {
        guard let shown = preview, !chat.messages.contains(where: { $0.id == shown.id }) else { return }
        clearPreview()
    }

    // MARK: - Notifications

    private func attentionSnapshot() -> AttentionSnapshot {
        attention?.snapshot() ?? AttentionSnapshot()
    }

    /// The lock screen never shows content, whatever macOS's "Show previews" setting is.
    private func includeText(_ snapshot: AttentionSnapshot) -> Bool {
        ReplyNotificationDecider.includesText(previewsEnabled: settings.glance.notificationIncludesPreview,
                                              attention: snapshot)
    }

    // MARK: - Preview countdown

    private func showPreview(_ newPreview: ReplyPreview) {
        previewTask?.cancel()
        previewTask = nil
        preview = newPreview
        previewRemaining = ReplyPreviewMetrics.visibleDuration
        countdownStartedAt = nil
        if !isPreviewHovered { runCountdown() }
    }

    private func clearPreview() {
        previewTask?.cancel()
        previewTask = nil
        countdownStartedAt = nil
        if preview != nil { preview = nil }
    }

    private func pauseCountdown() {
        guard preview != nil, let started = countdownStartedAt else { return }
        previewTask?.cancel()
        previewTask = nil
        countdownStartedAt = nil
        let elapsed = max(0, now().timeIntervalSince(started))
        let remainingSeconds = max(0, previewRemaining.timeInterval - elapsed)
        previewRemaining = .milliseconds(Int((remainingSeconds * 1000).rounded()))
    }

    private func resumeCountdown() {
        guard preview != nil, previewTask == nil else { return }
        previewRemaining = max(previewRemaining, ReplyPreviewMetrics.resumeMinimum)
        runCountdown()
    }

    private func runCountdown() {
        countdownStartedAt = now()
        let remaining = previewRemaining
        let shownID = preview?.id
        previewTask = Task { [weak self, sleep] in
            do { try await sleep(remaining) } catch { return }
            guard let self, !Task.isCancelled, self.preview?.id == shownID else { return }
            self.previewTask = nil
            self.countdownStartedAt = nil
            self.preview = nil
        }
    }
}
