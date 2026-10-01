//
//  MobileComposition.swift
//  Otto
//
//  Builds the iPhone app's object graph and owns it, like the Mac's AppComposition: settings, the chat session on
//  the Anthropic client (or the scripted mock in demo mode), history, usage, voice, the chat screen's model, the
//  reply's Live Activity, notifications and the background time that keeps a reply running after you leave.
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

    /// The system behind the graph (recording stand-ins in an inert graph, which tests read).
    let activities: ReplyActivityHosting
    let notificationCenter: ReplyNotificationCentering
    let backgroundTime: BackgroundTimeProviding

    private(set) var isStarted = false
    private(set) var isTerminated = false

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
        // Demo usage is made up, so it never reaches the real totals.
        let ledgerFile = isDemo ? nil : historyRoot?.appendingPathComponent(UsageLedger.fileName, isDirectory: false)
        return MobileComposition(
            kind: .live,
            settings: settings,
            throwawaySuiteName: nil,
            isDemo: isDemo,
            historyRoot: historyRoot,
            ledgerFile: ledgerFile,
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
    static func inert(latencyScale: Double = 0, isDemo: Bool = true) -> MobileComposition {
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
            throwawaySuiteName: suiteName,
            isDemo: isDemo,
            historyRoot: nil,
            ledgerFile: nil,
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

    private init(kind: Kind, settings: AppSettings, throwawaySuiteName: String?, isDemo: Bool,
                 historyRoot: URL?, ledgerFile: URL?,
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

        // The conversation, its usage and its history.
        let chat = ChatSession(settings: settings, makeClient: makeClient, isDemo: isDemo)
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
                                     ledger: ledger, voice: voice, audio: audio, services: services, isDemo: isDemo)

        // While you're away: the Live Activity and background time.
        self.replyActivity = ReplyActivityController(settings: settings, chat: chat, host: activities)
        self.backgroundKeeper = BackgroundReplyKeeper(time: backgroundTime)

        wireGraph()
    }

    private func wireGraph() {
        chat.onReplyFinished = { [weak self] in
            self?.replyFinished()
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
