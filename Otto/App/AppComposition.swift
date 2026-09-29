//
//  AppComposition.swift
//  Otto
//
//  Builds Otto's whole object graph (SPEC-v2 §2.2) and owns it: one PermissionsCenter shared by every
//  consumer, the tool catalog and executor, the chat session, history, glance, media, calendar, shelf,
//  context and voice subsystems, the notch view model, its windows, the status item, the global shortcut
//  with its tap/hold routing, the Services provider and the notch-neighbor monitor. Three recipes:
//  `live()` for the app, `selfTest(directory:)` for --selftest, and `inert()` for tests, which touches
//  neither the system nor the user's data. The paid and Setapp builds add their own parts here (SPEC-v2
//  §14.10, §14.11): the license engine behind the composer gate, the updater, the status menu's extra items
//  and Setapp's usage events. The source build compiles none of them.
//

import AppKit
import Carbon.HIToolbox
import Foundation
import Observation
import os
#if OTTO_LICENSING
import Security
#endif

@MainActor
final class AppComposition {
    enum Kind: Equatable, Sendable {
        /// The app (with `--demo`: MockLLMClient, demo action services, demo media, in-memory side stores).
        case live
        /// `--selftest`: the live stack on MockLLMClient, demo services, a mutable permission probe, temp stores.
        case selfTest
        /// Tests: in-memory stores, nothing started, no windows, no hot key, no notifications, no Services.
        case inert
    }

    /// Where the graph keeps its files; nil = in memory.
    struct Storage: Equatable, Sendable {
        /// The folder that holds Conversations.noindex and Attachments.noindex.
        var historyRoot: URL?
        var shelfDirectory: URL?
        var ledgerFile: URL?
        var actionLogDirectory: URL?

        static let inMemory = Storage(historyRoot: nil, shelfDirectory: nil, ledgerFile: nil, actionLogDirectory: nil)
    }

    // MARK: Hot key routing (§6.5)

    /// What the global shortcut sees when it is tapped.
    struct HotKeyState: Equatable, Sendable {
        var isSpeaking: Bool
        /// A toggle-mode voice session is starting or listening.
        var isListeningInToggleMode: Bool
        var isPinned: Bool
        var isOpen: Bool
        var isEngaged: Bool
        /// `vm.systemUIWait != nil` (§4.5): pin is suspended so the shortcut never keeps the notch over the dialog.
        var isWaitingOnSystemUI = false
    }

    /// What one tap of the global shortcut does, first match wins.
    enum HotKeyTapAction: Equatable, Sendable {
        /// Speaking → stop the speech only.
        case stopSpeaking
        /// Listening in toggle mode → finish and send.
        case finishVoiceAndSend
        /// Pinned and engaged → hand the keyboard back without closing.
        case disengage
        /// Pinned and not engaged → take the keyboard.
        case focus
        /// Open and engaged → close (a user close).
        case close
        /// Pinned, open and engaged while macOS shows its own UI → fold out of its way (`close(.systemUI)`): the
        /// pin stays and the notch comes back when the wait ends.
        case fold
        /// Otherwise → open with focus.
        case open
    }

    /// What the global shortcut drives: the notch view model in the app, a fake in tests.
    @MainActor protocol HotKeyTarget: AnyObject {
        var hotKeyState: HotKeyState { get }
        func open(reason: NotchViewModel.OpenReason, focus: Bool)
        func close(_ reason: CloseReason)
        func disengage()
        func stopSpeaking()
        func beginVoice(_ mode: VoiceMode)
        func finishVoice(send: Bool)
    }

    // MARK: Graph

    let kind: Kind
    let storage: Storage
    let settings: AppSettings
    /// The one permissions center: every consumer gets this instance (there is no `PermissionsCenter.shared`).
    let permissions: PermissionsCenter
    /// Self-test only: the probe behind `permissions`, so a step can change a status while a flow runs. Every
    /// status starts `.granted`; a step that needs a refusal sets it first.
    let permissionProbe: MutablePermissionProbe?
    let approvals: ApprovalStore
    let actionLog: ActionLog
    let actionServices: ActionServices
    let tools: ToolRegistry
    let executor: ToolExecutor
    let chat: ChatSession
    let ledger: UsageLedger
    let history: HistoryController
    let recents: RecentsState
    /// nil in the self-test and inert graphs.
    let notifications: NotificationPresenter?
    /// nil in the self-test and inert graphs.
    let attention: AttentionMonitor?
    let glance: GlanceController
    let nowPlaying: NowPlayingMonitor
    let calendar: CalendarGlance
    let shelf: ShelfController
    let suggestions: ContextSuggestions
    let inserter: InsertCoordinator
    let voice: VoiceController
    let viewModel: NotchViewModel
    let settingsWindowController: SettingsWindowController
    /// nil in the inert graph (no windows).
    let notchWindowController: NotchWindowController?
    /// Live only.
    let neighbors: NotchNeighborMonitor?
    let hotKey: HotKeyManager
    let shortcutRouter: GlobalShortcutRouter
    /// Created by `start()` in the live app.
    private(set) var statusItemController: StatusItemController?
    /// Live only; installed as `NSApp.servicesProvider` by `start()`.
    let servicesProvider: ServicesProvider?
    #if OTTO_LICENSING
    /// Settings → License and the composer gate (§14.10.4): the live paid graph's LicenseController, a
    /// StaticLicenseModel (licensed) in the self-test, nil for demo, inert and snapshot graphs.
    let license: LicenseControlling?
    #endif
    #if OTTO_SPARKLE || OTTO_SETAPP
    /// Sparkle (paid) or Setapp's pending-update API; nil for demo, inert, snapshot and self-test graphs.
    let updater: UpdaterControlling?
    #endif

    private(set) var isStarted = false
    private(set) var isTerminated = false

    /// URLs the self-test and inert graphs were asked to open (System Settings deep links, Dictation settings,
    /// Settings links), in order. Always empty in the live app, which opens them.
    var openedExternalURLs: [URL] { externalURLs.urls }

    /// The transcript the self-test's scripted speech engine produces.
    static let selfTestVoiceTranscript = "What's the weather in Lisbon"

    private let hotKeyTarget: HotKeyTarget
    private let externalURLs: ExternalURLRecorder
    /// The flavor's license engine and updater, as the recipe built them.
    private let flavor: FlavorServices
    #if OTTO_LICENSING
    /// The live engine behind `license`, which `start()` starts and `terminate()` stops. nil unless live.
    private let licenseController: LicenseController?
    #endif
    /// The throwaway UserDefaults suite of a self-test or inert graph, removed by `terminate()`.
    private let throwawaySuiteName: String?
    private var cancellations: [() -> Void] = []
    /// The last hot-key error this composition put in `settings.lastSettingsError`, so it clears only its own.
    private var hotKeyErrorMessage: String?

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "App")

    // MARK: - Recipes

    /// The app. `LaunchOptions.demo` swaps in MockLLMClient, `ActionServices.demo` and `DemoMediaScripting`, and
    /// keeps the Shelf, the usage ledger and the activity log in memory (History uses the separate Demo folder).
    /// Nothing is registered or started until `start()`.
    static func live() -> AppComposition {
        let settings = AppSettings.shared
        let isDemo = LaunchOptions.demo
        return AppComposition(
            kind: .live,
            settings: settings,
            defaults: .standard,
            throwawaySuiteName: nil,
            probe: SystemPermissionProbe(),
            permissionProbe: nil,
            storage: liveStorage(isDemo: isDemo),
            isDemo: isDemo,
            // --demo (every flavor): no license engine and no updater, so the gate never shows (§14.10.4).
            flavor: isDemo ? FlavorServices() : liveFlavorServices(),
            makeClient: {
                if LaunchOptions.demo { return MockLLMClient() }
                guard let apiKey = settings.resolvedAPIKey else { throw LLMError.missingAPIKey }
                return AnthropicClient(apiKey: apiKey)
            }
        )
    }

    /// `--selftest`: the live stack on `MockLLMClient(latencyScale: 0.2)`, demo action and media services, a
    /// `MutablePermissionProbe` (every status `.granted` until a step changes it), History under
    /// `<directory>/History`, everything else in memory, preferences in a throwaway suite, and nothing opened
    /// outside Otto (see `openedExternalURLs`). No status item, hot key, notifications or Services.
    static func selfTest(directory: URL) -> AppComposition {
        let (defaults, suiteName) = makeThrowawayDefaults()
        let settings = AppSettings(defaults: defaults, usesKeychain: false)
        prepareIsolatedSettings(settings)
        // The self-test checks History on its own files; the first-run card would cover its dock checks.
        settings.history.noticeAcknowledged = true
        let probe = MutablePermissionProbe([:], default: .granted)
        var storage = Storage.inMemory
        storage.historyRoot = directory.appendingPathComponent("History", isDirectory: true)
        return AppComposition(
            kind: .selfTest,
            settings: settings,
            defaults: defaults,
            throwawaySuiteName: suiteName,
            probe: probe,
            permissionProbe: probe,
            storage: storage,
            isDemo: true,
            flavor: selfTestFlavorServices(),
            makeClient: { MockLLMClient(latencyScale: 0.2) }
        )
    }

    /// Tests: the whole graph with in-memory stores and throwaway preferences. Builds no windows, registers no
    /// hot key, installs no Services provider, never creates a notification center, writes no file outside the
    /// temporary directory, and never starts a monitor (`start()` does nothing for it).
    static func inert(settings: AppSettings? = nil) -> AppComposition {
        let resolved: AppSettings
        let defaults: UserDefaults
        let suiteName: String?
        if let settings {
            resolved = settings
            (defaults, suiteName) = makeThrowawayDefaults()
        } else {
            let (throwaway, name) = makeThrowawayDefaults()
            resolved = AppSettings(defaults: throwaway, usesKeychain: false)
            prepareIsolatedSettings(resolved)
            defaults = throwaway
            suiteName = name
        }
        return AppComposition(
            kind: .inert,
            settings: resolved,
            defaults: defaults,
            throwawaySuiteName: suiteName,
            probe: StaticPermissionProbe([:], default: .notDetermined),
            permissionProbe: nil,
            storage: .inMemory,
            isDemo: true,
            flavor: FlavorServices(),
            makeClient: { MockLLMClient(latencyScale: 0) }
        )
    }

    private init(kind: Kind, settings: AppSettings, defaults: UserDefaults, throwawaySuiteName: String?,
                 probe: PermissionProbe, permissionProbe: MutablePermissionProbe?, storage: Storage, isDemo: Bool,
                 flavor: FlavorServices, makeClient: @escaping @MainActor () throws -> LLMClient) {
        self.kind = kind
        self.storage = storage
        self.settings = settings
        self.permissionProbe = permissionProbe
        self.throwawaySuiteName = throwawaySuiteName
        self.flavor = flavor
        #if OTTO_LICENSING
        self.license = flavor.license
        self.licenseController = flavor.license as? LicenseController
        #endif
        #if OTTO_SPARKLE || OTTO_SETAPP
        self.updater = flavor.updater
        #endif
        let isLive = kind == .live
        let externalURLs = ExternalURLRecorder()
        self.externalURLs = externalURLs

        // Permissions, approvals and the activity log.
        let openURL: @MainActor (URL) -> Void
        let relauncher: AppRelaunching
        if isLive {
            openURL = { url in NSWorkspace.shared.open(url) }
            relauncher = AppRelauncher()
        } else {
            openURL = { url in externalURLs.record(url) }
            relauncher = DetachedRelauncher()
        }
        let permissions = PermissionsCenter(probe: probe, defaults: defaults, openURL: openURL, relauncher: relauncher)
        self.permissions = permissions
        let approvals = ApprovalStore(defaults: defaults)
        self.approvals = approvals
        let actionLog = ActionLog(directory: storage.actionLogDirectory,
                                  maxAge: Self.actionLogMaxAge(for: settings.history.retention))
        self.actionLog = actionLog

        // Tools: the eight action tools on live or demo services, plus media control on the Now Playing monitor.
        let mediaScripting: MediaScripting = isDemo ? DemoMediaScripting() : LiveMediaScripting()
        let nowPlaying = NowPlayingMonitor(settings: settings, scripting: mediaScripting)
        self.nowPlaying = nowPlaying
        let actionServices = isDemo ? ActionServices.demo : ActionServices.live(processRunner: ProcessRunner())
        self.actionServices = actionServices
        let tools = ToolCatalog.makeRegistry(settings: settings, services: actionServices,
                                             extraTools: [MediaControlTool(monitor: nowPlaying)])
        self.tools = tools
        let executor = ToolExecutor(permissions: permissions, approvals: approvals, log: actionLog,
                                    logFullScripts: { [settings] in settings.actions.logFullScripts })
        // The executor's two hooks (§5): the Settings → Actions safety mode, read at every decision, and the
        // environment behind the availability pre-check and the re-check right before a call runs (a group or
        // Actions itself may be turned off while its card waits).
        executor.safetyMode = { [settings] in settings.actionSafetyMode }
        executor.makeEnvironment = { [settings, permissions] model in
            ToolEnvironment(settings: settings, permissions: permissions, model: model, isDemo: isDemo)
        }
        self.executor = executor

        // The conversation, its usage and its history. A request that starts while sending is paused fails on its
        // own turn (the makeClient backstop, §14.10.1); nothing else checks the license.
        let chat = ChatSession(settings: settings, makeClient: Self.backstopped(makeClient, by: flavor.sendGate),
                               tools: tools, executor: executor, permissions: permissions, isDemo: isDemo)
        self.chat = chat
        let ledger = UsageLedger(fileURL: storage.ledgerFile)
        self.ledger = ledger
        chat.usageRecorder = ledger
        let conversationStore = ConversationStore(location: storage.historyRoot.map { .directory($0) } ?? .inMemory)
        let history = HistoryController(settings: settings, chat: chat, store: conversationStore)
        self.history = history
        let recents = RecentsState(history: history)
        self.recents = recents

        // Glance, media and calendar.
        let notifications = isLive ? NotificationPresenter() : nil
        self.notifications = notifications
        let attention = isLive ? AttentionMonitor() : nil
        self.attention = attention
        let glance = kind == .inert
            ? GlanceController.inert(settings: settings, chat: chat)
            : GlanceController(settings: settings, chat: chat, notifications: notifications, attention: attention)
        self.glance = glance
        let calendarSource: CalendarEventSource = isLive ? EventKitCalendarSource() : InertCalendarSource()
        let calendar = CalendarGlance(settings: settings, store: calendarSource)
        self.calendar = calendar

        // Shelf, context in and out.
        let shelf = ShelfController(store: ShelfStore(directory: storage.shelfDirectory), settings: settings)
        self.shelf = shelf
        let suggestions = isLive
            ? ContextSuggestions(settings: settings, permissions: permissions)
            : ContextSuggestions(settings: settings, permissions: permissions,
                                 reader: InertSelectionReader(), capture: InertWindowCapture())
        self.suggestions = suggestions
        let insertEnvironment = LiveInsertEnvironment(permissions: permissions)
        let answerInserter = isLive
            ? AnswerInserter(environment: insertEnvironment)
            // A private pasteboard and a key sender that never posts: nothing reaches the user's clipboard or apps.
            : AnswerInserter(pasteboard: NSPasteboard.withUniqueName(), keys: DetachedKeySender(),
                             environment: insertEnvironment)
        let inserter = InsertCoordinator(inserter: answerInserter, settings: settings)
        self.inserter = inserter

        // Voice.
        let voice: VoiceController
        switch kind {
        case .live:
            voice = VoiceController(settings: settings)
        case .selfTest:
            voice = VoiceController(settings: settings,
                                    makeEngine: { ScriptedSpeechEngine(script: Self.selfTestVoiceScript) },
                                    speaker: ReplySpeaker(settings: settings, volume: 0),
                                    interruptions: InertVoiceInterruptions(),
                                    holdProbe: { _ in nil })
        case .inert:
            voice = VoiceController(settings: settings,
                                    makeEngine: { ScriptedSpeechEngine(script: []) },
                                    interruptions: InertVoiceInterruptions(),
                                    holdProbe: { _ in nil })
        }
        self.voice = voice

        // The notch.
        let services = NotchServices(permissions: permissions, approvals: approvals, voice: voice, history: history,
                                     recents: recents, glance: glance, ledger: ledger, nowPlaying: nowPlaying,
                                     calendar: calendar, shelf: shelf, suggestions: suggestions, inserter: inserter,
                                     notifications: notifications, sendGate: flavor.sendGate)
        let viewModel = NotchViewModel(settings: settings, chat: chat, services: services)
        self.viewModel = viewModel
        if !isLive {
            viewModel.openExternalURL = { externalURLs.record($0) }
        }

        // Coexistence with other notch apps (live only: the card must not appear in tests or the self-test).
        let neighbors = isLive
            ? NotchNeighborMonitor(onChange: { [weak viewModel] running in
                viewModel?.presentNeighborCardIfNeeded(running)
            })
            : nil
        self.neighbors = neighbors

        // Settings.
        var settingsServices = SettingsServices(
            permissions: permissions,
            approvals: approvals,
            actionLog: actionLog,
            ledger: ledger,
            history: history,
            shelf: shelf,
            calendar: calendar,
            nowPlaying: nowPlaying,
            neighbors: neighbors,
            speaker: voice.speaker,
            processRunner: isLive ? ProcessRunner() : nil
        )
        #if OTTO_LICENSING
        settingsServices.license = flavor.license
        #endif
        #if OTTO_SPARKLE || OTTO_SETAPP
        settingsServices.updater = flavor.updater
        #endif
        let settingsWindowController = SettingsWindowController(settings: settings, services: settingsServices)
        if !isLive {
            settingsWindowController.externalOpener = { externalURLs.record($0) }
        }
        self.settingsWindowController = settingsWindowController

        self.notchWindowController = kind == .inert ? nil : NotchWindowController(viewModel: viewModel, settings: settings)
        self.servicesProvider = isLive ? ServicesProvider(handler: viewModel) : nil

        // The global shortcut: Carbon only in the live app; the other graphs never register anything.
        let hotKeyTarget = ViewModelHotKeyTarget(viewModel: viewModel)
        self.hotKeyTarget = hotKeyTarget
        let router = Self.makeShortcutRouter(target: hotKeyTarget)
        self.shortcutRouter = router
        self.hotKey = HotKeyManager(
            combo: settings.shortcuts.hotKey,
            onPress: { [weak router] in router?.pressed() },
            onRelease: { [weak router] in router?.released() },
            registrar: isLive ? CarbonHotKeyRegistrar() : DetachedHotKeyRegistrar()
        )

        wireGraph()
    }

    /// Hooks every graph gets (none of them touches the system).
    private func wireGraph() {
        let settings = settings
        let router = shortcutRouter
        router.holdEnabled = Self.holdEnabled(settings)
        let holdLoop = ObservationLoop(read: { Self.holdEnabled(settings) }) { [weak router] enabled in
            router?.holdEnabled = enabled
        }
        cancellations.append { holdLoop.cancel() }

        let actionLog = actionLog
        let retentionLoop = ObservationLoop(read: { settings.history.retention }) { retention in
            Task { await actionLog.setMaxAge(Self.actionLogMaxAge(for: retention)) }
        }
        cancellations.append { retentionLoop.cancel() }

        // While History is off, logged actions stay in memory and never reach Logs.noindex/actions.jsonl.
        let historyEnabled = settings.history.enabled
        Task { await actionLog.setPersisting(historyEnabled) }
        let persistingLoop = ObservationLoop(read: { settings.history.enabled }) { enabled in
            Task { await actionLog.setPersisting(enabled) }
        }
        cancellations.append { persistingLoop.cancel() }

        Self.wireDataRemoval(history: history, notifications: notifications, actionLog: actionLog)

        guard kind != .inert else { return }
        let settingsWindowController = settingsWindowController
        viewModel.onOpenSettingsTab = { [weak settingsWindowController] tab, anchor in
            settingsWindowController?.show(tab: tab, anchor: anchor)
        }
        viewModel.onOpenSettings = { [weak settingsWindowController] in
            settingsWindowController?.show()
        }
    }

    // MARK: - Lifecycle

    /// Shows the notch and starts what the graph runs. Live: the status item (with the flavor's extra items), the
    /// global shortcut (unless `registeringHotKey` is false — a second `--demo` instance), the Services provider,
    /// notifications and the attention monitor (through the glance controller), Now Playing, the calendar chip,
    /// History, the Shelf, the activity log's launch prune, and, once the window shows, the license engine, the
    /// updater and Setapp's usage events. Self-test: the window, the glance phases and History on its temp folder.
    /// Inert graphs never start. Idempotent.
    func start(registeringHotKey: Bool = true) {
        guard kind != .inert, !isStarted, !isTerminated else { return }
        isStarted = true
        notchWindowController?.showWindow()
        glance.start()
        let history = history
        Task { await history.start() }
        guard kind == .live else { return }

        startFlavorServices()
        let statusItemController = StatusItemController(viewModel: viewModel, settings: settings)
        installExtraMenuItems(on: statusItemController)
        self.statusItemController = statusItemController
        if registeringHotKey {
            installHotKeyRegistration()
        }
        if let servicesProvider {
            NSApp.servicesProvider = servicesProvider
            NSUpdateDynamicServices()
        }
        nowPlaying.start()
        calendar.start()
        let store = shelf.store
        Task { await store.load() }
        let actionLog = actionLog
        Task { await actionLog.prune(now: Date()) }
        Self.logger.info("Otto started (demo: \(LaunchOptions.demo, privacy: .public))")
    }

    /// applicationWillTerminate: stops the license engine (its last clock write), stops listening and speaking,
    /// cancels the reply (and its tool calls), flushes History, the Shelf and the usage ledger, stops the monitors
    /// and unregisters the global shortcut. A self-test or inert graph also removes its throwaway preferences.
    /// Idempotent.
    func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        cancellations.forEach { $0() }
        cancellations.removeAll()
        #if OTTO_LICENSING
        // One last move of the trial's clock high-water mark, then no more scheduled checks.
        licenseController?.stop()
        #endif
        settings.shortcuts.registrar = nil
        hotKey.unregister()
        voice.cancel()
        voice.stopSpeaking()
        chat.cancel()
        history.flush()
        shelf.store.flush()
        ledger.flush()
        nowPlaying.stop()
        calendar.stop()
        if let throwawaySuiteName {
            UserDefaults.standard.removePersistentDomain(forName: throwawaySuiteName)
        }
    }

    /// What a tap of the global shortcut sees right now (§6.5).
    var hotKeyState: HotKeyState { hotKeyTarget.hotKeyState }

    /// One tap of the global shortcut (§6.5).
    func handleHotKeyTap() {
        Self.performTap(on: hotKeyTarget)
    }

    // MARK: - Hot key (§6.5)

    /// Pure: the §6.5 tap table. While macOS shows its own UI (§4.5) pin is suspended: an open, engaged notch folds
    /// (keeping the pin) so the next click lands on the dialog, and a closed one opens like a click on it would.
    static func tapAction(for state: HotKeyState) -> HotKeyTapAction {
        if state.isSpeaking { return .stopSpeaking }
        if state.isListeningInToggleMode { return .finishVoiceAndSend }
        if state.isPinned, !state.isWaitingOnSystemUI { return state.isEngaged ? .disengage : .focus }
        if state.isOpen && state.isEngaged { return state.isPinned ? .fold : .close }
        return .open
    }

    static func performTap(on target: HotKeyTarget) {
        switch tapAction(for: target.hotKeyState) {
        case .stopSpeaking: target.stopSpeaking()
        case .finishVoiceAndSend: target.finishVoice(send: true)
        case .disengage: target.disengage()
        case .focus, .open: target.open(reason: .hotkey, focus: true)
        case .close: target.close(.user)
        case .fold: target.close(.systemUI)
        }
    }

    /// A tap runs the table above; a hold (≥ 300 ms, only while `holdEnabled`) talks: it starts listening in hold
    /// mode and its release finishes and sends. With hold disabled every press is a tap at once.
    static func makeShortcutRouter(target: HotKeyTarget) -> GlobalShortcutRouter {
        GlobalShortcutRouter(
            onTap: { [weak target] in
                guard let target else { return }
                performTap(on: target)
            },
            onHoldBegan: { [weak target] in target?.beginVoice(.hold(.shortcut)) },
            onHoldEnded: { [weak target] in target?.finishVoice(send: true) }
        )
    }

    /// Holding the shortcut talks only while voice is on and "hold to talk" is chosen; otherwise a hold is a tap.
    static func holdEnabled(_ settings: AppSettings) -> Bool {
        settings.voice.enabled && settings.voice.holdShortcutToTalk
    }

    static func hotKeyInUseMessage(_ combo: HotKeyCombo) -> String {
        "\(combo.displayString) is already used by another app. Quit that app or change its shortcut, or pick a different one in Settings → General."
    }

    static func hotKeyFailedMessage(_ combo: HotKeyCombo) -> String {
        "Couldn't register the \(combo.displayString) shortcut."
    }

    /// Registers per `hotKeyEnabled`, unregisters while the recorder records, and lets Settings swap the combo.
    private func installHotKeyRegistration() {
        let settings = settings
        let hotKey = hotKey
        settings.shortcuts.registrar = { [weak self] combo in
            switch hotKey.update(to: combo) {
            case .success:
                settings.shortcuts.status = .registered
                self?.clearHotKeyError()
                return .applied
            case .failure(.alreadyInUse):
                return .rejected(HotKeyProblem.inUse(combo.displayString).errorDescription ?? Self.hotKeyInUseMessage(combo))
            case .failure(.failed(let status)):
                return .rejected(HotKeyProblem.failed(status).errorDescription ?? Self.hotKeyFailedMessage(combo))
            }
        }
        applyHotKeyRegistration()
        let enabledLoop = ObservationLoop(read: { settings.hotKeyEnabled }) { [weak self] _ in
            self?.applyHotKeyRegistration()
        }
        let recordingLoop = ObservationLoop(read: { settings.shortcuts.isRecording }) { [weak self] _ in
            self?.applyHotKeyRegistration()
        }
        cancellations.append { enabledLoop.cancel() }
        cancellations.append { recordingLoop.cancel() }
    }

    private func applyHotKeyRegistration() {
        guard !isTerminated else { return }
        if settings.shortcuts.isRecording {
            // Pressing the current combo while recording must record it, not toggle the notch.
            hotKey.unregister()
            return
        }
        guard settings.hotKeyEnabled else {
            hotKey.unregister()
            settings.shortcuts.status = .disabled
            clearHotKeyError()
            return
        }
        let combo = settings.shortcuts.hotKey
        let outcome: Result<Void, HotKeyManager.RegistrationError>
        if hotKey.combo != combo {
            // Set without the registrar (it keeps them equal): swap to the stored combo.
            outcome = hotKey.update(to: combo)
        } else if hotKey.register() {
            outcome = .success(())
        } else {
            outcome = .failure(hotKey.lastRegistrationError ?? .failed(OSStatus(eventInternalErr)))
        }
        let message: String
        switch outcome {
        case .success:
            settings.shortcuts.status = .registered
            clearHotKeyError()
            return
        case .failure(.alreadyInUse):
            settings.shortcuts.status = .inUse
            message = Self.hotKeyInUseMessage(combo)
        case .failure(.failed(let status)):
            settings.shortcuts.status = .failed(status)
            message = Self.hotKeyFailedMessage(combo)
        }
        hotKeyErrorMessage = message
        settings.lastSettingsError = message
    }

    /// Clears a stale registration error once the shortcut works or is no longer wanted.
    private func clearHotKeyError() {
        guard let hotKeyErrorMessage else { return }
        if settings.lastSettingsError == hotKeyErrorMessage {
            settings.lastSettingsError = nil
        }
        self.hotKeyErrorMessage = nil
    }

    // MARK: - Flavor (§14.10, §14.11)

    /// What a flavor adds to the graph: the license engine (paid and licensing-check builds) and the updater (paid
    /// and Setapp builds). Empty in the source build and in every demo, inert and snapshot graph.
    struct FlavorServices {
        #if OTTO_LICENSING
        var license: LicenseControlling? = nil
        #endif
        #if OTTO_SPARKLE || OTTO_SETAPP
        var updater: UpdaterControlling? = nil
        #endif

        /// What pauses sending (`NotchServices.sendGate`): the license engine, and nothing in the other builds.
        var sendGate: ComposerGating? {
            #if OTTO_LICENSING
            return license
            #else
            return nil
            #endif
        }
    }

    /// The makeClient backstop (§14.10.1): while `gate` has a gate up, a request that starts throws
    /// `ComposerGateError` with the gate's message, which ChatSession's error path shows on that turn. Without a
    /// gate it is `makeClient` itself.
    static func backstopped(_ makeClient: @escaping @MainActor () throws -> LLMClient,
                            by gate: ComposerGating?) -> @MainActor () throws -> LLMClient {
        guard let gate else { return makeClient }
        return { [weak gate] in
            if let paused = gate?.composerGate {
                throw ComposerGateError(message: paused.message)
            }
            return try makeClient()
        }
    }

    /// The status menu's items for this flavor, after "Settings…" (§14.10.3). Paid: "Install Otto {version}…" first
    /// while an update waits, then "License…" ("Enter License…", which goes to the key field, while sending needs a
    /// license) and "Check for Updates…" (enabled while the updater can check). Setapp: only "Install Otto
    /// {version}…" while Setapp has one ready. The source build, and a graph without a license engine or updater:
    /// none.
    static func extraMenuItems(for flavor: FlavorServices,
                               openSettings: @escaping @MainActor (SettingsTab, SettingsAnchor?) -> Void)
        -> [NSMenuItem] {
        #if OTTO_SPARKLE || OTTO_SETAPP
        let install = flavor.updater.flatMap { updater in
            updater.pendingUpdate.map { pending in
                MenuItemAction.item("Install Otto \(pending.version)…") { updater.installPendingUpdate() }
            }
        }
        #else
        let install: NSMenuItem? = nil
        #endif
        #if OTTO_LICENSING
        let license = flavor.license.map { license in
            license.status.allowsSending
                ? MenuItemAction.item("License…") { openSettings(.license, nil) }
                : MenuItemAction.item("Enter License…") { openSettings(.license, .licenseKey) }
        }
        #else
        let license: NSMenuItem? = nil
        #endif
        #if OTTO_SPARKLE
        let check = flavor.updater.map { updater in
            let item = MenuItemAction.item("Check for Updates…") { updater.checkNow() }
            item.isEnabled = updater.canCheckNow
            return item
        }
        #else
        let check: NSMenuItem? = nil
        #endif
        return [install, license, check].compactMap { $0 }
    }

    /// Starts what the flavor runs, once the window shows (live graphs only): the license engine, the updater and,
    /// in the Setapp build, the usage events Setapp asks menu bar apps to report.
    private func startFlavorServices() {
        #if OTTO_LICENSING
        licenseController?.start()
        #endif
        #if OTTO_SPARKLE || OTTO_SETAPP
        updater?.start()
        #endif
        #if OTTO_SETAPP
        installSetappUsageReports()
        #endif
    }

    /// Gives the status menu this flavor's items, rebuilt each time it opens. The source build sets nothing.
    private func installExtraMenuItems(on controller: StatusItemController) {
        #if OTTO_LICENSING || OTTO_SETAPP
        let flavor = flavor
        let viewModel = viewModel
        controller.extraMenuItems = { [weak viewModel] in
            Self.extraMenuItems(for: flavor) { tab, anchor in
                viewModel?.openSettings(tab: tab, anchor: anchor)
            }
        }
        #endif
    }

    #if OTTO_SETAPP
    /// Setapp's usage event (§14.11.2) when the notch becomes engaged and when a message is sent; SetappBridge keeps
    /// the reports at least five minutes apart.
    private func installSetappUsageReports() {
        let viewModel = viewModel
        let chat = chat
        let engagedLoop = ObservationLoop(read: { viewModel.isEngaged }) { isEngaged in
            if isEngaged { SetappBridge.reportInteraction(now: Date()) }
        }
        var lastMessageCount = chat.messageCount
        let sentLoop = ObservationLoop(read: { chat.messageCount }) { count in
            defer { lastMessageCount = count }
            if count > lastMessageCount { SetappBridge.reportInteraction(now: Date()) }
        }
        cancellations.append { engagedLoop.cancel() }
        cancellations.append { sentLoop.cancel() }
    }
    #endif

    /// The live graph's flavor parts (never in demo mode): the license engine and the flavor's updater. Nothing
    /// starts until `start()`.
    private static func liveFlavorServices() -> FlavorServices {
        var flavor = FlavorServices()
        #if OTTO_LICENSING
        flavor.license = makeLiveLicenseController()
        #endif
        #if OTTO_SPARKLE
        flavor.updater = SparkleUpdater()
        #elseif OTTO_SETAPP
        flavor.updater = SetappUpdater()
        #endif
        return flavor
    }

    /// The self-test's parts: a licensed StaticLicenseModel, so every step sends as before until step 22 changes
    /// its status. No updater.
    private static func selfTestFlavorServices() -> FlavorServices {
        var flavor = FlavorServices()
        #if OTTO_LICENSING
        let now = Date()
        let record = sampleLicenseRecord(configuration: .preview, activatedAt: now.addingTimeInterval(-30 * 86_400),
                                         validatedAt: now)
        flavor.license = StaticLicenseModel(status: .licensed(LicenseSummary(record: record)))
        #endif
        return flavor
    }

    #if OTTO_LICENSING
    /// The live graph's store, and its only way to build one: the Keychain under the configuration's account names
    /// (§14.9). A Debug build on the Polar sandbox, the licensing-check build and any misconfigured build get the
    /// `.sandbox` items, so they never read, validate, delete or advance the production license and trial.
    static func makeLicenseStore(for configuration: LicenseConfiguration) -> KeychainLicenseStore {
        KeychainLicenseStore(accounts: configuration.keychainAccounts)
    }

    /// The paid build's engine on this build's configuration and its live backends (the Polar sandbox in Debug).
    /// In a Debug build, `--license-state` swaps the Keychain for a seeded in-memory store and
    /// `--license-clock-offset` shifts the engine's clock (§14.10.4).
    private static func makeLiveLicenseController() -> LicenseController {
        let configuration = LicenseConfiguration.load(bundle: .main)
        let store: LicenseStoring
        #if DEBUG
        if let state = LaunchOptions.licenseState {
            store = seededLicenseStore(state, configuration: configuration, now: Date())
            logger.notice("License engine on an in-memory store seeded for \(state.rawValue, privacy: .public)")
        } else {
            store = makeLicenseStore(for: configuration)
        }
        #else
        store = makeLicenseStore(for: configuration)
        #endif
        let backends = LicenseBackends.make(configuration: configuration, transport: URLSessionLicenseTransport(),
                                            store: store, userAgent: LicenseBackends.userAgent())
        let controller = LicenseController(configuration: configuration, store: store, backends: backends,
                                           scheduler: TaskLicenseScheduler())
        #if DEBUG
        if let offset = LaunchOptions.licenseClockOffset {
            controller.clockOffset = offset
            logger.notice("License clock shifted by \(offset / 3_600, privacy: .public) h")
        }
        #endif
        return controller
    }

    /// A made-up Polar license under `configuration`'s host and IDs, for the self-test's static model and the Debug
    /// `--license-state` stores. It is never written to the Keychain.
    nonisolated static func sampleLicenseRecord(configuration: LicenseConfiguration, activatedAt: Date,
                                                validatedAt: Date) -> LicenseRecord {
        let key = "OTTO-00000000-0000-4000-8000-000000000000"
        return LicenseRecord(
            schema: LicenseRecord.currentSchema,
            backend: .polar,
            apiHost: configuration.polar?.apiHost ?? LicenseConfiguration.polarSandboxHost,
            organizationID: configuration.polar?.organizationID,
            benefitID: configuration.polar?.benefitID,
            gumroadProductID: nil,
            key: key,
            licenseKeyID: "00000000-0000-4000-8000-000000000001",
            activationID: "00000000-0000-4000-8000-000000000002",
            label: "Mac 7F3A",
            displayKey: LicenseKeyRouter.displayKey(for: key),
            seatLimit: LicensePolicy.seatsPerLicense,
            activatedAt: activatedAt,
            lastValidatedAt: validatedAt,
            lastAttemptAt: validatedAt,
            pendingRevocation: nil
        )
    }

    #if DEBUG
    /// `--license-state` (§14.10.4): an in-memory store seeded for `state` relative to `now`. License states carry
    /// `sampleLicenseRecord` (last attempt an hour ago, so nothing checks before Check Now); `keychain-error` fails
    /// every read like a locked Keychain.
    static func seededLicenseStore(_ state: LaunchOptions.LicenseState, configuration: LicenseConfiguration,
                                   now: Date) -> InMemoryLicenseStore {
        let day: TimeInterval = 86_400
        func trial(startedDaysAgo days: Double, removal: LicenseRemoval? = nil) -> TrialRecord {
            TrialRecord(schema: TrialRecord.currentSchema, startedAt: now.addingTimeInterval(-days * day),
                        lastSeenAt: now, lastLicenseRemoval: removal)
        }
        func license(validatedDaysAgo days: Double) -> LicenseRecord {
            var record = sampleLicenseRecord(configuration: configuration,
                                             activatedAt: now.addingTimeInterval(-60 * day),
                                             validatedAt: now.addingTimeInterval(-days * day))
            record.lastAttemptAt = now.addingTimeInterval(-3_600)
            return record
        }
        switch state {
        case .trial:
            return InMemoryLicenseStore(trial: trial(startedDaysAgo: 3))
        case .trialLastDay:
            return InMemoryLicenseStore(trial: trial(startedDaysAgo: 13.5))
        case .ended:
            return InMemoryLicenseStore(trial: trial(startedDaysAgo: 20))
        case .removed:
            let removal = LicenseRemoval(at: now.addingTimeInterval(-day), reason: .revoked)
            return InMemoryLicenseStore(trial: trial(startedDaysAgo: 20, removal: removal))
        case .licensed:
            return InMemoryLicenseStore(license: license(validatedDaysAgo: 0.1), trial: trial(startedDaysAgo: 60))
        case .overdue:
            return InMemoryLicenseStore(license: license(validatedDaysAgo: 35), trial: trial(startedDaysAgo: 60))
        case .required:
            return InMemoryLicenseStore(license: license(validatedDaysAgo: 50), trial: trial(startedDaysAgo: 60))
        case .keychainError:
            return InMemoryLicenseStore(failure: .keychain(errSecInteractionNotAllowed))
        }
    }
    #endif
    #endif

    // MARK: - History removals (§6.12)

    /// Every removal clears Otto's delivered and pending notifications (they may name a deleted conversation);
    /// Delete All History and turning History off also clear the actions activity log, and any other removal
    /// prunes the log's expired entries.
    static func wireDataRemoval(history: HistoryController, notifications: NotificationPresenter?,
                                actionLog: ActionLog?) {
        history.onDataRemoved = { [weak notifications] removal in
            notifications?.clearDelivered()
            guard let actionLog else { return }
            guard removal == .all else {
                // Retention's maintenance tick (and single deletions): expired action titles leave the disk on the
                // same schedule as the conversations they belong to, even when nothing else touches the log.
                Task { await actionLog.prune(now: Date()) }
                return
            }
            Task {
                do {
                    try await actionLog.clear()
                    logger.info("Cleared the actions activity log with History")
                } catch {
                    logger.error("Couldn't clear the actions activity log: \(String(describing: error), privacy: .private)")
                }
            }
        }
    }

    /// The activity log keeps entries as long as History keeps conversations; "Forever" caps it at 90 days.
    static func actionLogMaxAge(for retention: HistoryRetention) -> TimeInterval {
        retention.interval ?? 90 * 86_400
    }

    // MARK: - Recipe helpers

    /// Otto's data folders, or memory for any that can't be used safely. `--demo` keeps the Shelf, the ledger and
    /// the activity log in memory; History uses the Demo root.
    private static func liveStorage(isDemo: Bool) -> Storage {
        var storage = Storage.inMemory
        do {
            storage.historyRoot = try AppSupport.rootURL()
        } catch {
            logger.fault("History stays in memory: \(String(describing: error), privacy: .private)")
        }
        guard !isDemo else { return storage }
        do {
            storage.shelfDirectory = try AppSupport.directory(.shelf)
        } catch {
            logger.fault("The Shelf stays in memory: \(String(describing: error), privacy: .private)")
        }
        storage.ledgerFile = UsageLedger.defaultFileURL()
        do {
            storage.actionLogDirectory = try AppSupport.directory(.logs)
        } catch {
            logger.fault("The activity log stays in memory: \(String(describing: error), privacy: .private)")
        }
        return storage
    }

    /// A UserDefaults suite of its own. UserDefaults refuses only the app's own domain and the global domain as a
    /// suite name, so a fresh UUID-based name always works.
    private static func makeThrowawayDefaults() -> (UserDefaults, String) {
        let suiteName = "com.jalenedusei.otto.composition.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults refused the suite \(suiteName)")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    /// No browser-tab lookups (and so no Automation prompt) in graphs that must not touch other apps.
    private static func prepareIsolatedSettings(_ settings: AppSettings) {
        settings.suggestBrowserTab = false
        settings.autoAttachBrowserTab = false
    }

    private static let selfTestVoiceScript: [(delay: Duration, text: String, level: Float)] = [
        (.milliseconds(150), "What's the", 0.35),
        (.milliseconds(150), "What's the weather", 0.6),
        (.milliseconds(150), selfTestVoiceTranscript, 0.45),
    ]
}

// MARK: - Private helpers

/// The notch view model as the global shortcut's target.
@MainActor private final class ViewModelHotKeyTarget: AppComposition.HotKeyTarget {
    private weak var viewModel: NotchViewModel?

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
    }

    var hotKeyState: AppComposition.HotKeyState {
        guard let viewModel else {
            return AppComposition.HotKeyState(isSpeaking: false, isListeningInToggleMode: false, isPinned: false,
                                              isOpen: false, isEngaged: false)
        }
        let voice = viewModel.voice
        var isToggleSession = false
        if case .toggle? = voice.mode { isToggleSession = true }
        let isListening = voice.phase == .preparing || voice.phase == .listening
        return AppComposition.HotKeyState(isSpeaking: voice.isSpeaking,
                                          isListeningInToggleMode: isToggleSession && isListening,
                                          isPinned: viewModel.isPinned,
                                          isOpen: viewModel.isOpen,
                                          isEngaged: viewModel.isEngaged,
                                          isWaitingOnSystemUI: viewModel.systemUIWait != nil)
    }

    func open(reason: NotchViewModel.OpenReason, focus: Bool) { viewModel?.open(reason: reason, focus: focus) }
    func close(_ reason: CloseReason) { viewModel?.close(reason) }
    func disengage() { viewModel?.disengage() }
    func stopSpeaking() { viewModel?.stopSpeaking() }
    func beginVoice(_ mode: VoiceMode) { viewModel?.beginVoice(mode) }
    func finishVoice(send: Bool) { viewModel?.finishVoice(send: send) }
}

/// Records the URLs a self-test or inert graph was asked to open instead of opening them.
@MainActor private final class ExternalURLRecorder {
    private(set) var urls: [URL] = []

    func record(_ url: URL) {
        urls.append(url)
    }
}

/// The hot-key registrar of graphs that must never own a system-wide shortcut: registration always "succeeds"
/// and nothing reaches Carbon, so presses arrive only through `HotKeyManager.handle(_:)`.
@MainActor private final class DetachedHotKeyRegistrar: HotKeyRegistering {
    func register(_ combo: HotKeyCombo, handler: @escaping @MainActor (HotKeyEventKind) -> Void) -> OSStatus {
        noErr
    }

    func unregister() {}
}

/// "Quit & Reopen Otto" in a self-test or inert graph: nothing to relaunch.
private struct DetachedRelauncher: AppRelaunching {
    func relaunch() {}
}

/// A key sender that never posts an event (self-test and inert graphs paste nowhere).
private final class DetachedKeySender: KeySending {
    var isSecureInputEnabled: Bool { false }

    func areModifiersDown() -> Bool { false }

    func postPaste() throws {}
}

/// The target of a status-menu item that runs a closure. NSMenuItem holds its target weakly, so the item keeps
/// this object alive as its `representedObject`.
@MainActor private final class MenuItemAction: NSObject {
    private let handler: @MainActor () -> Void

    private init(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    static func item(_ title: String, _ handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let action = MenuItemAction(handler)
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        handler()
    }
}
