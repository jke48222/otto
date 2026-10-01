//
//  MobileComposition.swift
//  Otto
//
//  Builds the iPhone app's object graph and owns it, like the Mac's AppComposition: settings, the chat session on
//  the Anthropic client (or the scripted mock in demo mode) with the calendar and reminder actions, history,
//  usage, voice, the chat screen's model, the reply's Live Activity, notifications and the background time that
//  keeps a reply running after you leave.
//  `live()` is the app; `inert()` builds the same graph for tests and snapshots, touching neither the system
//  nor your data.
//

import Foundation
import os
import UIKit
import UserNotifications

@MainActor
final class MobileComposition {
    enum Kind: Equatable, Sendable {
        /// The app. Demo mode (Settings, or `--demo`) swaps in MockLLMClient and keeps data in Otto/Demo.
        case live
        /// Tests and snapshots: throwaway preferences, in-memory stores, scripted voice, nothing started.
        case inert
    }

    let kind: Kind
    let isDemo: Bool
    let settings: AppSettings
    let chat: ChatSession
    let ledger: UsageLedger
    let history: HistoryController
    let recents: RecentsState
    let voice: VoiceController
    let audio: AudioSessionCoordinator
    let model: ChatScreenModel
    let replyActivity: ReplyActivityController
    let notifier: ReplyNotifier
    let backgroundKeeper: BackgroundReplyKeeper

    // Actions.
    let permissions: MobilePermissions
    let approvals: ApprovalStore
    let actionLog: ActionLog
    let executor: ToolExecutor
    let tools: ToolRegistry

    /// The system behind the graph (recording stand-ins in an inert graph, which tests read).
    let activities: ReplyActivityHosting
    let notificationCenter: ReplyNotificationCentering
    let backgroundTime: BackgroundTimeProviding
    let permissionProbe: MobilePermissionProbing
    let eventKit: any EventKitProviding

    private(set) var isStarted = false
    private(set) var isTerminated = false
    /// Stops the loops `start()` set up.
    private var cancellations: [() -> Void] = []

    private let throwawaySuiteName: String?
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "App")

    // MARK: - Recipes

    /// The app, on `AppSettings.shared`. Nothing is started until `start()`.
    static func live(settings: AppSettings = .shared) -> MobileComposition {
        let isDemo = LaunchOptions.demo || settings.mobile.demoMode
        var historyRoot: URL?
        do {
            historyRoot = try AppSupport.rootURL(demo: isDemo)
        } catch {
            logger.fault("History stays in memory: \(String(describing: error), privacy: .private)")
        }
        // Demo usage is made up, so it never reaches the real totals; demo actions stay out of the activity log file.
        let ledgerFile = isDemo ? nil : historyRoot?.appendingPathComponent(UsageLedger.fileName, isDirectory: false)
        var actionLogDirectory: URL?
        if !isDemo {
            do {
                actionLogDirectory = try AppSupport.directory(.logs, demo: false)
            } catch {
                logger.fault("The activity log stays in memory: \(String(describing: error), privacy: .private)")
            }
        }
        return MobileComposition(
            kind: .live,
            settings: settings,
            defaults: .standard,
            throwawaySuiteName: nil,
            isDemo: isDemo,
            historyRoot: historyRoot,
            ledgerFile: ledgerFile,
            actionLogDirectory: actionLogDirectory,
            eventKit: isDemo ? DemoEventKitService() : EventKitService(),
            // The demo's calendar is made up, so it needs no access to the real one.
            permissionProbe: isDemo ? StaticPermissionProbe() : MobilePermissionProbe(),
            makeClient: {
                if isDemo { return MockLLMClient() }
                guard let apiKey = settings.resolvedAPIKey else { throw LLMError.missingAPIKey }
                return AnthropicClient(apiKey: apiKey)
            },
            makeEngine: { SFSpeechEngine() },
            interruptions: SystemVoiceInterruptions(),
            voicePermissions: SystemVoicePermissions(),
            audio: AudioSessionCoordinator(),
            activities: SystemReplyActivities(),
            notificationCenter: SystemReplyNotificationCenter(),
            backgroundTime: SystemBackgroundTime()
        )
    }

    /// Tests and snapshots: the whole graph with throwaway preferences, in-memory stores, the mock client
    /// (no delays), a scripted speech engine and recording stand-ins for ActivityKit, notifications and
    /// background time. `isDemo: false` draws the screens as they look with a key (snapshots).
    static func inert(latencyScale: Double = 0, isDemo: Bool = true,
                      permissionProbe: MobilePermissionProbing = StaticPermissionProbe(),
                      eventKit: any EventKitProviding = DemoEventKitService()) -> MobileComposition {
        let suiteName = "com.jalenedusei.otto.ios-composition.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults refused the suite \(suiteName)")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults, usesKeychain: false)
        settings.history.noticeAcknowledged = true
        return MobileComposition(
            kind: .inert,
            settings: settings,
            defaults: defaults,
            throwawaySuiteName: suiteName,
            isDemo: isDemo,
            historyRoot: nil,
            ledgerFile: nil,
            actionLogDirectory: nil,
            eventKit: eventKit,
            permissionProbe: permissionProbe,
            makeClient: { MockLLMClient(latencyScale: latencyScale) },
            makeEngine: { ScriptedSpeechEngine(script: []) },
            interruptions: InertVoiceInterruptions(),
            voicePermissions: StaticVoicePermissions(),
            audio: AudioSessionCoordinator(session: nil),
            activities: InertReplyActivities(),
            notificationCenter: InertReplyNotificationCenter(),
            backgroundTime: InertBackgroundTime()
        )
    }

    private init(kind: Kind, settings: AppSettings, defaults: UserDefaults, throwawaySuiteName: String?,
                 isDemo: Bool, historyRoot: URL?, ledgerFile: URL?, actionLogDirectory: URL?,
                 eventKit: any EventKitProviding, permissionProbe: MobilePermissionProbing,
                 makeClient: @escaping @MainActor () throws -> LLMClient,
                 makeEngine: @escaping @MainActor () -> SpeechEngine,
                 interruptions: VoiceInterruptionSource,
                 voicePermissions: VoicePermissionChecking,
                 audio: AudioSessionCoordinator,
                 activities: ReplyActivityHosting,
                 notificationCenter: ReplyNotificationCentering,
                 backgroundTime: BackgroundTimeProviding) {
        self.kind = kind
        self.isDemo = isDemo
        self.settings = settings
        self.throwawaySuiteName = throwawaySuiteName
        self.audio = audio
        self.activities = activities
        self.notificationCenter = notificationCenter
        self.backgroundTime = backgroundTime
        self.permissionProbe = permissionProbe
        self.eventKit = eventKit

        // Actions: permissions, approvals, the activity log, the calendar and reminder tools and their executor.
        let permissions = MobilePermissions(probe: permissionProbe)
        self.permissions = permissions
        let approvals = ApprovalStore(defaults: defaults)
        self.approvals = approvals
        let actionLog = ActionLog(directory: actionLogDirectory,
                                  maxAge: MobileToolCatalog.actionLogMaxAge(for: settings.history.retention))
        self.actionLog = actionLog
        let tools = MobileToolCatalog.makeRegistry(settings: settings, eventKit: eventKit)
        self.tools = tools
        let executor = ToolExecutor(permissions: permissions, approvals: approvals, log: actionLog,
                                    logFullScripts: { [settings] in settings.actions.logFullScripts })
        // Read at every decision: the safety mode, and the environment behind the availability checks (a group or
        // Actions itself may be turned off while its card waits).
        executor.safetyMode = { [settings] in settings.actionSafetyMode }
        executor.makeEnvironment = { [settings, permissions] model in
            ToolEnvironment(settings: settings, permissions: permissions, model: model, isDemo: isDemo)
        }
        self.executor = executor

        // The conversation, its usage and its history.
        let chat = ChatSession(settings: settings, makeClient: makeClient, tools: tools, executor: executor,
                               permissions: permissions, isDemo: isDemo)
        self.chat = chat
        let ledger = UsageLedger(fileURL: ledgerFile)
        self.ledger = ledger
        chat.usageRecorder = ledger
        let store = ConversationStore(location: historyRoot.map { .directory($0) } ?? .inMemory)
        let history = HistoryController(settings: settings, chat: chat, store: store)
        self.history = history
        self.recents = RecentsState(history: history)

        // Voice: the shared controller on Apple's recognizer, with the iPhone's interruptions.
        let voice = VoiceController(settings: settings, makeEngine: makeEngine,
                                    speaker: ReplySpeaker(settings: settings, volume: kind == .inert ? 0 : 1),
                                    interruptions: interruptions, holdProbe: { _ in nil })
        self.voice = voice

        // While you're away: notifications (made first, so Settings can ask for permission through the screen).
        let notifier = ReplyNotifier(center: notificationCenter)
        self.notifier = notifier

        // The screen.
        var services = ChatScreenServices()
        services.voicePermissions = voicePermissions
        services.requestNotificationPermission = { await notifier.requestPermission() }
        services.liveActivitiesAllowed = { activities.areActivitiesEnabled }
        services.recentActions = { limit in await actionLog.recent(limit: limit) }
        services.clearActionLog = {
            do {
                try await actionLog.clear()
            } catch {
                Self.logger.error("Couldn't clear the activity log: \(LoggedError(error), privacy: .public)")
            }
        }
        if kind == .live {
            services.clipboardProviders = { UIPasteboard.general.itemProviders }
            services.copyText = { UIPasteboard.general.string = $0 }
            services.openAppSettings = {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
        self.model = ChatScreenModel(settings: settings, chat: chat, history: history, recents: recents,
                                     ledger: ledger, voice: voice, audio: audio, services: services,
                                     permissions: permissions, isDemo: isDemo)

        // While you're away: the Live Activity and background time.
        self.replyActivity = ReplyActivityController(settings: settings, chat: chat, host: activities)
        self.backgroundKeeper = BackgroundReplyKeeper(time: backgroundTime)

        wireGraph()
    }

    private func wireGraph() {
        chat.onReplyFinished = { [weak self] in
            self?.replyFinished()
        }
        chat.onAttentionNeeded = { [weak self] approval in
            self?.approvalNeeded(approval)
        }
        // Delete All History and turning History off clear the activity log too; other removals prune it.
        let actionLog = actionLog
        history.onDataRemoved = { removal in
            guard removal == .all else {
                Task { await actionLog.prune(now: Date()) }
                return
            }
            Task {
                do {
                    try await actionLog.clear()
                } catch {
                    Self.logger.error("Couldn't clear the activity log: \(LoggedError(error), privacy: .public)")
                }
            }
        }
        backgroundKeeper.onExpiration = { [weak self] in
            self?.backgroundTimeRanOut()
        }
        notifier.onOpenReply = { [weak self] messageID in
            self?.model.revealReply(messageID)
        }
    }

    // MARK: - Lifecycle

    /// Starts what the graph runs: History (restoring the latest conversation), the Live Activity follower and
    /// the notification delegate. Inert graphs never start. Idempotent.
    func start() {
        guard kind == .live, !isStarted, !isTerminated else { return }
        isStarted = true
        let history = history
        Task { await history.start() }
        replyActivity.start()
        UNUserNotificationCenterBridge.install(notifier)
        startActionLogUpkeep()
        Self.logger.info("Otto for iPhone started (demo: \(self.isDemo, privacy: .public))")
    }

    /// Before the graph is replaced (demo mode switched) or the app goes away: stops listening and speaking,
    /// stops the reply, and saves History and the usage totals. Idempotent.
    func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        if voice.isActive { voice.cancel() }
        voice.stopSpeaking()
        audio.activate(.idle)
        if chat.isStreaming { chat.cancel() }
        replyActivity.stop()
        cancellations.forEach { $0() }
        cancellations = []
        history.flush()
        ledger.flush()
        backgroundKeeper.end()
        if let throwawaySuiteName {
            UserDefaults.standard.removePersistentDomain(forName: throwawaySuiteName)
        }
    }

    /// The scene came to the foreground.
    func sceneBecameActive() {
        backgroundKeeper.end()
        replyActivity.isAppActive = true
        replyActivity.dismiss()
        notifier.clearDelivered()
        model.sceneBecameActive()
    }

    /// The scene went to the background: a running reply keeps going on background time, and what's on disk is
    /// brought up to date in case iOS ends Otto while it's away.
    func sceneEnteredBackground() {
        replyActivity.isAppActive = false
        model.sceneEnteredBackground()
        if chat.isStreaming {
            backgroundKeeper.begin()
        }
        history.flush()
        ledger.flush()
    }

    private func replyFinished() {
        model.replyFinished()
        guard !model.isAppActive else { return }
        // No Live Activity followed this reply (off, or iOS declined one): a notification, if asked for.
        if replyActivity.current == nil, settings.mobile.notifyWhenAway,
           let id = chat.lastFinishedAssistantID, let message = chat.messages.last(where: { $0.id == id }),
           let preview = ReplyPreview.make(from: message) {
            notifier.postReply(preview, includeText: settings.mobile.notificationPreview)
        }
        // The transcript and the totals reach the disk before iOS suspends Otto.
        history.flush()
        ledger.flush()
        if !chat.isStreaming {
            backgroundKeeper.end()
        }
    }

    /// An action waits for an answer while Otto is away and no Live Activity can say so: a notification, if asked
    /// for. (The Live Activity itself alerts when its stage turns to "Needs your OK".)
    private func approvalNeeded(_ approval: PendingApproval) {
        guard !model.isAppActive, replyActivity.current == nil, settings.mobile.notifyWhenAway else { return }
        notifier.postApprovalNeeded(approval, includeText: settings.mobile.notificationPreview)
    }

    /// The activity log follows History: its retention, and staying in memory while History is off.
    private func startActionLogUpkeep() {
        let settings = settings
        let actionLog = actionLog
        Task { await actionLog.prune(now: Date()) }
        let retentionLoop = ObservationLoop(read: { settings.history.retention }) { retention in
            Task { await actionLog.setMaxAge(MobileToolCatalog.actionLogMaxAge(for: retention)) }
        }
        let historyEnabled = settings.history.enabled
        Task { await actionLog.setPersisting(historyEnabled) }
        let persistingLoop = ObservationLoop(read: { settings.history.enabled }) { enabled in
            Task { await actionLog.setPersisting(enabled) }
        }
        cancellations += [{ retentionLoop.cancel() }, { persistingLoop.cancel() }]
    }

    /// iOS is about to suspend Otto with the reply still running: it stops where it is (Retry continues it), and
    /// the island says it paused.
    private func backgroundTimeRanOut() {
        guard chat.isStreaming else { return }
        replyActivity.prepareForPause()
        chat.cancel()
        history.flush()
        ledger.flush()
    }

    // MARK: - Links and intents

    func handle(_ url: URL) {
        guard let link = OttoDeepLink(url: url) else { return }
        model.handle(link)
    }
}

/// Becomes the notification center's delegate once, so taps reach the notifier.
@MainActor enum UNUserNotificationCenterBridge {
    static func install(_ notifier: ReplyNotifier) {
        UNUserNotificationCenter.current().delegate = notifier
    }
}

/// Background time that is never granted (tests, snapshots).
@MainActor final class InertBackgroundTime: BackgroundTimeProviding {
    private(set) var begun = 0
    private(set) var ended: [Int] = []
    private var expirations: [Int: @MainActor () -> Void] = [:]

    nonisolated init() {}

    func beginBackgroundTask(named name: String, expiration: @escaping @MainActor () -> Void) -> Int? {
        begun += 1
        expirations[begun] = expiration
        return begun
    }

    func endBackgroundTask(_ token: Int) {
        ended.append(token)
        expirations[token] = nil
    }

    /// Runs the expiration handler of the task that is still open, as iOS would.
    func expire() {
        for (_, expiration) in expirations {
            expiration()
        }
    }
}
