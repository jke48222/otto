//
//  ReplyActivityController.swift
//  Otto
//
//  Follows each reply with a Live Activity, the iPhone's take on the closed notch's ears: started when a turn
//  starts (iOS only lets the app start one while it is on screen, and shows it once Otto is in the background),
//  updated as the reply moves from thinking to searching to writing, and settled when it lands: the island then
//  shows a check and the expanded view the reply's first line. It goes away when you come back to Otto, the way
//  the unread dot clears when you open the notch.
//

import ActivityKit
import Foundation
import os

/// ActivityKit behind a seam, so tests drive the controller without starting system activities.
@MainActor protocol ReplyActivityHosting: AnyObject {
    var areActivitiesEnabled: Bool { get }
    /// Starts an activity for `messageID`; nil when the system refused (Live Activities off, too many running).
    func request(messageID: UUID, state: ReplyActivityAttributes.ContentState) -> String?
    /// `alert`: light the screen and show the expanded island briefly, with a sound.
    func update(_ id: String, state: ReplyActivityAttributes.ContentState, alert: ReplyActivityAlert?)
    func end(_ id: String, state: ReplyActivityAttributes.ContentState?)
    /// Ends every Otto activity, including ones a previous launch left behind.
    func endAll()
}

struct ReplyActivityAlert: Equatable, Sendable {
    let title: String
    let body: String
}

@MainActor final class ReplyActivityController {
    typealias State = ReplyActivityAttributes.ContentState

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Glance")

    private let settings: AppSettings
    private let chat: ChatSession
    private let host: ReplyActivityHosting
    private let now: () -> Date

    /// The activity following the in-flight (or just finished) reply.
    private(set) var current: (id: String, messageID: UUID, state: State)?
    /// Otto is on screen: a finished reply needs no island, and the next one starts fresh.
    var isAppActive = true
    /// Set just before the reply is stopped for running out of background time: it settles as Paused.
    private var isPausing = false
    private var phaseLoop: ObservationLoop<ReplyPhase>?

    init(settings: AppSettings, chat: ChatSession, host: ReplyActivityHosting,
         now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.chat = chat
        self.host = host
        self.now = now
    }

    /// Ends activities a previous launch left behind and starts following the chat. Idempotent.
    func start() {
        guard phaseLoop == nil else { return }
        host.endAll()
        let chat = chat
        phaseLoop = ObservationLoop(read: { chat.phase }) { [weak self] phase in
            self?.phaseChanged(phase)
        }
    }

    func stop() {
        phaseLoop?.cancel()
        phaseLoop = nil
    }

    /// Otto came back on screen: whatever the island showed is in front of you now.
    func dismiss() {
        guard let current, current.state.isFinished || !chat.isStreaming else { return }
        host.end(current.id, state: nil)
        self.current = nil
    }

    /// Background time is about to run out: the reply that is stopped next settles as Paused instead of ending.
    func prepareForPause() {
        isPausing = true
    }

    // MARK: - Phase

    func phaseChanged(_ phase: ReplyPhase) {
        if phase.isActive {
            guard let message = chat.messages.last(where: { $0.role == .assistant && $0.state == .streaming }) else {
                return
            }
            if current?.messageID != message.id {
                begin(for: message, phase: phase)
            } else if let current, let state = Self.workingState(for: phase, model: current.state.model,
                                                                  startedAt: current.state.startedAt),
                      state != current.state {
                host.update(current.id, state: state, alert: Self.approvalAlert(from: current.state, to: state,
                                                                                isAppActive: isAppActive))
                self.current?.state = state
            }
        } else {
            settle()
        }
    }

    private func begin(for message: ChatMessage, phase: ReplyPhase) {
        if let previous = current {
            host.end(previous.id, state: nil)
            current = nil
        }
        isPausing = false
        guard settings.mobile.liveActivities, host.areActivitiesEnabled,
              let state = Self.workingState(for: phase, model: settings.model.shortName, startedAt: now()),
              let id = host.request(messageID: message.id, state: state) else { return }
        current = (id, message.id, state)
        Self.logger.info("Started the reply's Live Activity")
    }

    private func settle() {
        guard let current else {
            isPausing = false
            return
        }
        let message = chat.messages.last { $0.id == current.messageID }
        if isPausing {
            isPausing = false
            let paused = Self.pausedState(from: current.state, at: now())
            host.update(current.id, state: paused, alert: nil)
            self.current?.state = paused
            return
        }
        guard !isAppActive, let message,
              let finished = Self.finishedState(for: message, from: current.state,
                                                 showsText: settings.mobile.notificationPreview, at: now()) else {
            // Stopped, or finished while you watched: nothing for the island to say.
            host.end(current.id, state: nil)
            self.current = nil
            return
        }
        let alert = settings.mobile.notifyWhenAway
            ? ReplyActivityAlert(title: finished.title, body: finished.detail.isEmpty ? "Tap to open Otto." : finished.detail)
            : nil
        host.update(current.id, state: finished, alert: alert)
        self.current?.state = finished
    }

    // MARK: - Pure state

    /// What the island shows while a reply runs; nil for `.idle`.
    static func workingState(for phase: ReplyPhase, model: String, startedAt: Date) -> State? {
        let stage: State.Stage
        var detail = ""
        switch phase {
        case .idle:
            return nil
        case .connecting:
            stage = .connecting
        case .thinking:
            stage = .thinking
        case .searching(let label):
            stage = .searching
            detail = label
        case .writing:
            stage = .writing
        case .runningAction(let label):
            stage = .acting
            detail = label
        case .awaitingApproval(let label):
            stage = .waitingForApproval
            detail = label
        }
        return State(stage: stage, detail: DisplayText.sanitized(detail, maxLength: 120), model: model,
                     startedAt: startedAt, finishedAt: nil)
    }

    /// A finished reply: its first line (when previews are allowed), or the failure. nil for a stopped reply.
    static func finishedState(for message: ChatMessage, from working: State, showsText: Bool, at date: Date) -> State? {
        guard let preview = ReplyPreview.make(from: message) else { return nil }
        let stage: State.Stage = preview.outcome == .answered ? .replied : .failed
        let model = message.model.map(CostFormatter.modelName) ?? working.model
        return State(stage: stage, detail: showsText ? preview.text : "", model: model.isEmpty ? working.model : model,
                     startedAt: working.startedAt, finishedAt: date)
    }

    /// Lights the screen once when an action starts waiting for the user's OK while Otto is away.
    static func approvalAlert(from previous: State, to next: State, isAppActive: Bool) -> ReplyActivityAlert? {
        guard !isAppActive, next.stage == .waitingForApproval, previous.stage != .waitingForApproval else { return nil }
        return ReplyActivityAlert(title: next.title, body: next.detail.isEmpty ? "Open Otto to answer." : next.detail)
    }

    static func pausedState(from working: State, at date: Date) -> State {
        State(stage: .paused, detail: "Open Otto to finish this reply.", model: working.model,
              startedAt: working.startedAt, finishedAt: date)
    }
}

/// The real ActivityKit.
@MainActor final class SystemReplyActivities: ReplyActivityHosting {
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Glance")

    private var activities: [String: Activity<ReplyActivityAttributes>] = [:]

    nonisolated init() {}

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func request(messageID: UUID, state: ReplyActivityAttributes.ContentState) -> String? {
        do {
            let activity = try Activity.request(
                attributes: ReplyActivityAttributes(messageID: messageID),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            activities[activity.id] = activity
            return activity.id
        } catch {
            Self.logger.notice("Live Activity not started: \(LoggedError(error), privacy: .public)")
            return nil
        }
    }

    func update(_ id: String, state: ReplyActivityAttributes.ContentState, alert: ReplyActivityAlert?) {
        guard let activity = activities[id] else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        let configuration = alert.map {
            AlertConfiguration(title: "\($0.title)", body: "\($0.body)", sound: .default)
        }
        Task {
            await activity.update(content, alertConfiguration: configuration)
        }
    }

    func end(_ id: String, state: ReplyActivityAttributes.ContentState?) {
        guard let activity = activities.removeValue(forKey: id) else { return }
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        Task {
            await activity.end(content, dismissalPolicy: .immediate)
        }
    }

    func endAll() {
        activities.removeAll()
        let running = Activity<ReplyActivityAttributes>.activities
        guard !running.isEmpty else { return }
        Task {
            for activity in running {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}

/// Never starts anything (tests, snapshots, demo graphs that must not touch the system).
@MainActor final class InertReplyActivities: ReplyActivityHosting {
    private(set) var log: [String] = []
    var areActivitiesEnabled = true
    private var serial = 0

    nonisolated init() {}

    func request(messageID: UUID, state: ReplyActivityAttributes.ContentState) -> String? {
        serial += 1
        log.append("request \(state.stage.rawValue)")
        return "activity-\(serial)"
    }

    func update(_ id: String, state: ReplyActivityAttributes.ContentState, alert: ReplyActivityAlert?) {
        log.append("update \(id) \(state.stage.rawValue)\(alert == nil ? "" : " alert")")
    }

    func end(_ id: String, state: ReplyActivityAttributes.ContentState?) {
        log.append("end \(id)")
    }

    func endAll() {
        log.append("endAll")
    }
}
