//
//  AppCompositionTests.swift
//  OttoTests
//
//  The app's object graph on its inert recipe: built whole without side effects, one PermissionsCenter shared
//  by every consumer, the global shortcut's tap/hold routing table (a fake target and the real view model),
//  History removals reaching notifications and the activity log, the log's age following History retention,
//  and the status item's menu.
//

import AppKit
import Carbon.HIToolbox
import UserNotifications
import XCTest
@testable import Otto

@MainActor
final class AppCompositionTests: XCTestCase {
    private var composition: AppComposition!

    override func setUp() async throws {
        composition = AppComposition.inert()
    }

    override func tearDown() async throws {
        composition.terminate()
        composition = nil
    }

    // MARK: - Inert graph

    func testInertBuildsTheWholeGraphWithoutSideEffects() {
        let servicesProviderBefore = NSApp.servicesProvider.map { ObjectIdentifier($0 as AnyObject) }
        let graph = composition!

        XCTAssertEqual(graph.kind, .inert)
        XCTAssertFalse(graph.settings === AppSettings.shared, "throwaway preferences, never the user's")
        XCTAssertEqual(graph.storage, .inMemory, "no file is written outside the temporary directory")
        XCTAssertNil(graph.history.store.rootURL)
        XCTAssertNil(graph.notifications, "no notification center")
        XCTAssertNil(graph.attention)
        XCTAssertNil(graph.notchWindowController, "no windows")
        XCTAssertNil(graph.neighbors)
        XCTAssertNil(graph.servicesProvider, "no Services provider")
        XCTAssertNil(graph.statusItemController, "no status item")
        XCTAssertFalse(graph.hotKey.isRegistered, "no hot key registration")
        XCTAssertNil(graph.settings.shortcuts.registrar)

        graph.start()
        XCTAssertFalse(graph.isStarted, "an inert graph never starts")
        XCTAssertFalse(graph.hotKey.isRegistered)
        XCTAssertNil(graph.statusItemController)
        XCTAssertEqual(NSApp.servicesProvider.map { ObjectIdentifier($0 as AnyObject) }, servicesProviderBefore)

        // Everything the notch reads is the graph's own instance.
        XCTAssertTrue(graph.viewModel.chat === graph.chat)
        XCTAssertTrue(graph.viewModel.history === graph.history)
        XCTAssertTrue(graph.viewModel.recents === graph.recents)
        XCTAssertTrue(graph.viewModel.glance === graph.glance)
        XCTAssertTrue(graph.viewModel.ledger === graph.ledger)
        XCTAssertTrue(graph.viewModel.nowPlaying === graph.nowPlaying)
        XCTAssertTrue(graph.viewModel.calendar === graph.calendar)
        XCTAssertTrue(graph.viewModel.shelf === graph.shelf)
        XCTAssertTrue(graph.viewModel.suggestions === graph.suggestions)
        XCTAssertTrue(graph.viewModel.inserter === graph.inserter)
        XCTAssertTrue(graph.viewModel.voice === graph.voice)
        XCTAssertTrue(graph.viewModel.approvals === graph.approvals)
        XCTAssertTrue(graph.chat.usageRecorder === graph.ledger, "usage is recorded in the graph's ledger")

        let services = graph.settingsWindowController.services
        XCTAssertTrue(services.approvals === graph.approvals)
        XCTAssertTrue(services.ledger === graph.ledger)
        XCTAssertTrue(services.history === graph.history)
        XCTAssertTrue(services.shelf === graph.shelf)
        XCTAssertTrue(services.calendar === graph.calendar)
        XCTAssertTrue(services.nowPlaying === graph.nowPlaying)
        XCTAssertTrue(services.speaker === graph.voice.speaker)
        XCTAssertTrue(services.actionLog === graph.actionLog)
        XCTAssertNil(services.processRunner, "Reset macOS permissions can't run tccutil from an inert graph")
    }

    func testInertGraphOffersTheActionToolsOnDemoServices() {
        let names = composition.tools.allTools.map(\.name)
        XCTAssertEqual(names.count, 9)
        XCTAssertTrue(names.contains("media_control"))
        XCTAssertTrue(composition.actionServices.eventKit is DemoEventKitService)
        XCTAssertTrue(composition.actionServices.urlOpener is DemoURLOpener)
    }

    func testInertGraphRecordsLinksInsteadOfOpeningThem() throws {
        let url = try XCTUnwrap(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"))
        composition.viewModel.openExternalURL(url)
        composition.settingsWindowController.externalOpener(url)

        XCTAssertEqual(composition.openedExternalURLs, [url, url])
    }

    func testExactlyOnePermissionsCenterIsSharedByEveryConsumer() {
        let found = PermissionsCenterSearch(root: composition!)

        XCTAssertEqual(found.centers.count, 1, "one PermissionsCenter in the whole graph")
        XCTAssertEqual(found.centers.first, ObjectIdentifier(composition.permissions))
        for owner in ["NotchViewModel", "ChatSession", "ToolExecutor", "ContextSuggestions", "LiveInsertEnvironment",
                      "SettingsServices"] {
            XCTAssertTrue(found.owners.contains(owner), "\(owner) holds the shared center")
        }
        XCTAssertTrue(composition.viewModel.permissions === composition.permissions)
        XCTAssertTrue(composition.settingsWindowController.services.permissions === composition.permissions)
    }

    // MARK: - Self-test graph

    func testSelfTestGraphRunsOnDemoServicesAndTempStores() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OttoCompositionSelfTest-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let graph = AppComposition.selfTest(directory: directory)
        defer { graph.terminate() }

        XCTAssertEqual(graph.kind, .selfTest)
        XCTAssertFalse(graph.settings === AppSettings.shared)
        XCTAssertEqual(graph.storage.historyRoot, directory.appendingPathComponent("History", isDirectory: true))
        XCTAssertNil(graph.storage.shelfDirectory)
        XCTAssertNil(graph.storage.ledgerFile)
        XCTAssertNil(graph.storage.actionLogDirectory)
        XCTAssertNil(graph.notifications)
        XCTAssertNil(graph.servicesProvider)
        XCTAssertNil(graph.neighbors)
        XCTAssertNotNil(graph.notchWindowController)
        XCTAssertFalse(graph.hotKey.isRegistered)
        XCTAssertTrue(graph.actionServices.eventKit is DemoEventKitService)
        XCTAssertTrue(graph.actionServices.shortcuts is DemoShortcutsService)

        // The mutable probe: granted until a step says otherwise.
        let probe = try XCTUnwrap(graph.permissionProbe)
        await graph.permissions.refresh([.calendars])
        XCTAssertEqual(graph.permissions.status(.calendars), .granted)
        probe.set(.calendars, .denied)
        await graph.permissions.refresh([.calendars])
        XCTAssertEqual(graph.permissions.status(.calendars), .denied)

        // Voice runs on the scripted engine: the spoken question is sent as typed text.
        await graph.permissions.refresh([.microphone, .speechRecognition])
        graph.settings.voice.enabled = true
        graph.viewModel.beginVoice(.toggle(.micButton))
        let listening = await waitUntil { graph.voice.isListening }
        XCTAssertTrue(listening, "the scripted engine starts listening")
        try? await Task.sleep(for: .milliseconds(500))
        graph.viewModel.finishVoice(send: true)
        let sent = await waitUntil {
            graph.chat.messages.first { $0.role == .user }?.text == AppComposition.selfTestVoiceTranscript
        }
        XCTAssertTrue(sent, "the transcript is sent: \(graph.chat.messages.map(\.text))")
    }

    // MARK: - Hot key: tap table (§6.5)

    func testTapTableFirstMatchWins() {
        func state(speaking: Bool = false, toggleListening: Bool = false, pinned: Bool = false,
                   open: Bool = false, engaged: Bool = false) -> AppComposition.HotKeyState {
            AppComposition.HotKeyState(isSpeaking: speaking, isListeningInToggleMode: toggleListening,
                                       isPinned: pinned, isOpen: open, isEngaged: engaged)
        }

        XCTAssertEqual(AppComposition.tapAction(for: state(speaking: true, toggleListening: true, pinned: true,
                                                           open: true, engaged: true)), .stopSpeaking)
        XCTAssertEqual(AppComposition.tapAction(for: state(toggleListening: true, pinned: true, open: true,
                                                           engaged: true)), .finishVoiceAndSend)
        XCTAssertEqual(AppComposition.tapAction(for: state(pinned: true, open: true, engaged: true)), .disengage)
        XCTAssertEqual(AppComposition.tapAction(for: state(pinned: true, open: true)), .focus)
        XCTAssertEqual(AppComposition.tapAction(for: state(open: true, engaged: true)), .close)
        XCTAssertEqual(AppComposition.tapAction(for: state(open: true)), .open)
        XCTAssertEqual(AppComposition.tapAction(for: state()), .open)
    }

    func testPinIsSuspendedForTheTapWhileSystemUIWaits() {
        func waiting(open: Bool, engaged: Bool) -> AppComposition.HotKeyState {
            AppComposition.HotKeyState(isSpeaking: false, isListeningInToggleMode: false, isPinned: true,
                                       isOpen: open, isEngaged: engaged, isWaitingOnSystemUI: true)
        }
        // Open and engaged over System Settings: the tap folds it (keeping the pin) so the next click lands on the
        // dialog, and it comes back when the wait ends.
        XCTAssertEqual(AppComposition.tapAction(for: waiting(open: true, engaged: true)), .fold)
        // Folded (closed but still pinned): it opens as a click on the closed notch would.
        XCTAssertEqual(AppComposition.tapAction(for: waiting(open: false, engaged: false)), .open)
        XCTAssertEqual(AppComposition.tapAction(for: waiting(open: true, engaged: false)), .open)
    }

    func testFoldTapFoldsInsteadOfClosing() {
        let target = HotKeyTargetFake()
        target.hotKeyState = AppComposition.HotKeyState(isSpeaking: false, isListeningInToggleMode: false,
                                                        isPinned: true, isOpen: true, isEngaged: true,
                                                        isWaitingOnSystemUI: true)
        AppComposition.performTap(on: target)
        XCTAssertEqual(target.calls, [.close(.systemUI)], "a fold keeps the pin; a user close would drop it")

        target.calls = []
        target.hotKeyState.isPinned = false
        AppComposition.performTap(on: target)
        XCTAssertEqual(target.calls, [.close(.user)])
    }

    func testHotKeyStateReportsTheSystemUIWait() async {
        let vm = composition.viewModel
        vm.open(reason: .click, focus: true)
        vm.togglePin()
        XCTAssertTrue(vm.isPinned)
        vm.automationPromptInFlight = .automation(bundleID: "com.apple.Music", appName: "Music")
        let folded = await waitUntil { vm.systemUIWait != nil }
        XCTAssertTrue(folded)
        let state = composition.hotKeyState
        XCTAssertTrue(state.isWaitingOnSystemUI)
        XCTAssertTrue(state.isPinned, "the fold keeps the pin")
        vm.automationPromptInFlight = nil
    }

    // MARK: - Tool executor hooks

    func testExecutorSafetyModeFollowsSettings() {
        let graph = composition!
        graph.settings.actionSafetyMode = .safer
        XCTAssertEqual(graph.executor.safetyMode(), .safer)
        graph.settings.actionSafetyMode = .fewerPrompts
        XCTAssertEqual(graph.executor.safetyMode(), .fewerPrompts, "Fewer prompts reaches the executor")
        graph.settings.actionSafetyMode = .safer
        XCTAssertEqual(graph.executor.safetyMode(), .safer)
    }

    func testExecutorEnvironmentFollowsSettings() throws {
        let graph = composition!
        let makeEnvironment = try XCTUnwrap(graph.executor.makeEnvironment,
                                            "the availability pre-check and pre-run re-check need it")
        let environment = makeEnvironment(.sonnet5)
        XCTAssertTrue(environment.settings === graph.settings)
        XCTAssertTrue((environment.permissions as? PermissionsCenter) === graph.permissions)
        XCTAssertEqual(environment.model, .sonnet5)
        XCTAssertTrue(environment.isDemo, "the inert graph runs on demo services")

        // AppleScript follows Settings even in demo graphs: a switch turned off while its card waits is seen by
        // the re-check right before the call runs.
        let script = try XCTUnwrap(graph.tools.allTools.first { $0.group == .appleScript })
        graph.settings.actions.enabled = true
        graph.settings.actions.groups.insert(.appleScript)
        XCTAssertTrue(script.isAvailable(in: makeEnvironment(.opus5)))
        graph.settings.actions.enabled = false
        XCTAssertFalse(script.isAvailable(in: makeEnvironment(.opus5)))
    }

    func testTapPerformsTheTableOnTheTarget() {
        let target = HotKeyTargetFake()
        let cases: [(AppComposition.HotKeyState, HotKeyTargetFake.Call)] = [
            (.init(isSpeaking: true, isListeningInToggleMode: false, isPinned: false, isOpen: true, isEngaged: true),
             .stopSpeaking),
            (.init(isSpeaking: false, isListeningInToggleMode: true, isPinned: false, isOpen: false, isEngaged: false),
             .finishVoice(send: true)),
            (.init(isSpeaking: false, isListeningInToggleMode: false, isPinned: true, isOpen: true, isEngaged: true),
             .disengage),
            (.init(isSpeaking: false, isListeningInToggleMode: false, isPinned: true, isOpen: true, isEngaged: false),
             .open(.hotkey, focus: true)),
            (.init(isSpeaking: false, isListeningInToggleMode: false, isPinned: false, isOpen: true, isEngaged: true),
             .close(.user)),
            (.init(isSpeaking: false, isListeningInToggleMode: false, isPinned: false, isOpen: true, isEngaged: false),
             .open(.hotkey, focus: true)),
            (.init(isSpeaking: false, isListeningInToggleMode: false, isPinned: false, isOpen: false, isEngaged: false),
             .open(.hotkey, focus: true)),
        ]
        for (state, expected) in cases {
            target.calls = []
            target.hotKeyState = state
            AppComposition.performTap(on: target)
            XCTAssertEqual(target.calls, [expected], "\(state)")
        }
    }

    // MARK: - Hot key: tap and hold through the router

    func testHoldWithVoiceOffIsATap() async {
        let target = HotKeyTargetFake()
        let router = AppComposition.makeShortcutRouter(target: target)
        router.holdEnabled = false

        router.pressed()
        XCTAssertEqual(target.calls, [.open(.hotkey, focus: true)], "the press is a tap at once, no 300 ms wait")
        try? await Task.sleep(for: .milliseconds(450))
        router.released()
        XCTAssertEqual(target.calls, [.open(.hotkey, focus: true)], "holding and releasing adds nothing")
    }

    func testHoldWithVoiceOnTalksAndReleaseSends() async {
        let target = HotKeyTargetFake()
        let router = AppComposition.makeShortcutRouter(target: target)
        router.holdEnabled = true

        router.pressed()
        XCTAssertEqual(target.calls, [], "a hold-enabled press waits for the threshold")
        let began = await waitUntil { target.calls == [.beginVoice(.hold(.shortcut))] }
        XCTAssertTrue(began, "a 300 ms hold starts listening in hold mode: \(target.calls)")
        router.released()
        XCTAssertEqual(target.calls, [.beginVoice(.hold(.shortcut)), .finishVoice(send: true)])
    }

    func testShortPressWithVoiceOnIsStillATap() async {
        let target = HotKeyTargetFake()
        let router = AppComposition.makeShortcutRouter(target: target)
        router.holdEnabled = true

        router.pressed()
        router.released()
        XCTAssertEqual(target.calls, [.open(.hotkey, focus: true)])
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(target.calls, [.open(.hotkey, focus: true)], "the cancelled hold check never fires")
    }

    func testRouterHoldFollowsVoiceAndHoldToTalk() async {
        let settings = composition.settings
        let router = composition.shortcutRouter
        XCTAssertFalse(settings.voice.enabled)
        XCTAssertFalse(router.holdEnabled, "voice is off by default, so a held shortcut is a tap")

        settings.voice.enabled = true
        settings.voice.holdShortcutToTalk = true
        let enabled = await waitUntil { router.holdEnabled }
        XCTAssertTrue(enabled)

        settings.voice.holdShortcutToTalk = false
        let disabled = await waitUntil { !router.holdEnabled }
        XCTAssertTrue(disabled, "hold to talk off: a hold is a tap again")
    }

    func testShortcutDrivesTheNotchWithVoiceOff() {
        let viewModel = composition.viewModel
        XCTAssertFalse(composition.shortcutRouter.holdEnabled)

        composition.hotKey.handle(.pressed)
        XCTAssertTrue(viewModel.isOpen, "a press opens at once")
        XCTAssertTrue(viewModel.isEngaged)
        composition.hotKey.handle(.released)
        XCTAssertTrue(viewModel.isOpen)

        composition.hotKey.handle(.pressed)
        composition.hotKey.handle(.released)
        XCTAssertFalse(viewModel.isOpen, "open and engaged: the tap closes it")
    }

    func testTapOnAPinnedNotchTogglesFocusWithoutClosing() {
        let viewModel = composition.viewModel
        viewModel.open(reason: .hotkey, focus: true)
        viewModel.togglePin()
        XCTAssertTrue(viewModel.isPinned)

        composition.handleHotKeyTap()
        XCTAssertTrue(viewModel.isOpen)
        XCTAssertFalse(viewModel.isEngaged, "pinned and engaged: the keyboard goes back")

        composition.handleHotKeyTap()
        XCTAssertTrue(viewModel.isOpen)
        XCTAssertTrue(viewModel.isEngaged, "pinned and not engaged: it takes the keyboard")
    }

    // MARK: - History removals (§6.12)

    func testDeleteAllClearsNotificationsAndTheActivityLog() async {
        let center = NotificationCenterSpy()
        let presenter = NotificationPresenter(center: { center })
        let actionLog = composition.actionLog
        AppComposition.wireDataRemoval(history: composition.history, notifications: presenter, actionLog: actionLog)
        await actionLog.append(Self.logEntry(daysAgo: 0))

        await composition.history.deleteAll()

        XCTAssertEqual(center.removedDelivered, [[NotificationPresenter.replyIdentifier,
                                                  NotificationPresenter.approvalIdentifier]])
        XCTAssertEqual(center.removedPending, [[NotificationPresenter.replyIdentifier,
                                                NotificationPresenter.approvalIdentifier]])
        let cleared = await waitUntilAsync { await actionLog.recent(limit: 10).isEmpty }
        XCTAssertTrue(cleared, "Delete All History also clears the activity log")
    }

    func testConversationRemovalClearsNotificationsButKeepsTheLog() async {
        let center = NotificationCenterSpy()
        let presenter = NotificationPresenter(center: { center })
        let actionLog = composition.actionLog
        AppComposition.wireDataRemoval(history: composition.history, notifications: presenter, actionLog: actionLog)
        await actionLog.append(Self.logEntry(daysAgo: 0))

        composition.history.onDataRemoved?(.conversations([UUID()]))
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(center.removedDelivered.count, 1)
        let remaining = await actionLog.recent(limit: 10)
        XCTAssertEqual(remaining.count, 1, "only Delete All and History off clear the log")
    }

    func testInertWiringClearsTheLogWithoutANotificationCenter() async {
        let actionLog = composition.actionLog
        await actionLog.append(Self.logEntry(daysAgo: 0))

        composition.history.onDataRemoved?(.all)

        let cleared = await waitUntilAsync { await actionLog.recent(limit: 10).isEmpty }
        XCTAssertTrue(cleared)
    }

    func testActivityLogAgeFollowsHistoryRetention() async {
        XCTAssertEqual(AppComposition.actionLogMaxAge(for: .week), 7 * 86_400)
        XCTAssertEqual(AppComposition.actionLogMaxAge(for: .month), 30 * 86_400)
        XCTAssertEqual(AppComposition.actionLogMaxAge(for: .quarter), 90 * 86_400)
        XCTAssertEqual(AppComposition.actionLogMaxAge(for: .forever), 90 * 86_400, "Forever still caps the log")

        let actionLog = composition.actionLog
        let settings = composition.settings
        XCTAssertEqual(settings.history.retention, .month)
        await actionLog.append(Self.logEntry(daysAgo: 10))
        await actionLog.prune(now: Date())
        var kept = await actionLog.recent(limit: 10)
        XCTAssertEqual(kept.count, 1, "30 days keeps a 10-day-old entry")

        settings.history.retention = .week
        let pruned = await waitUntilAsync {
            await actionLog.prune(now: Date())
            return await actionLog.recent(limit: 10).isEmpty
        }
        XCTAssertTrue(pruned, "a week drops it once the retention change reaches the log")

        settings.history.retention = .forever
        // Until the change reaches the log, a week's limit drops the entry again; then 90 days keeps it.
        let keptLonger = await waitUntilAsync {
            if await actionLog.recent(limit: 10).isEmpty {
                await actionLog.append(Self.logEntry(daysAgo: 60))
            }
            await actionLog.prune(now: Date())
            return await actionLog.recent(limit: 10).count == 1
        }
        XCTAssertTrue(keptLonger, "Forever keeps 90 days")
        await actionLog.append(Self.logEntry(daysAgo: 120))
        await actionLog.prune(now: Date())
        kept = await actionLog.recent(limit: 10)
        XCTAssertEqual(kept.count, 1, "…and no more")
    }

    // MARK: - Status item menu (§11.6)

    func testStatusMenuListsRecentsShelfAndTheLiveShortcut() throws {
        let settings = composition.settings
        settings.showMenuBarIcon = false
        let controller = StatusItemController(viewModel: composition.viewModel, settings: settings)
        let menu = controller.menu
        controller.menuNeedsUpdate(menu)

        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Open Otto", "New Chat", "Recent Conversations…", "Shelf…", "Settings…", "Quit Otto"])
        let open = try XCTUnwrap(menu.item(withTitle: "Open Otto"))
        let shelf = try XCTUnwrap(menu.item(withTitle: "Shelf…"))
        XCTAssertTrue(shelf.isHidden, "an empty Shelf isn't listed")

        // The default ⌥Space.
        XCTAssertEqual(open.keyEquivalent, " ")
        XCTAssertEqual(open.keyEquivalentModifierMask, .option)

        // Whatever combo is set.
        settings.shortcuts.hotKey = HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey | shiftKey))
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(open.keyEquivalent, " ")
        XCTAssertEqual(open.keyEquivalentModifierMask, [.command, .shift])

        settings.hotKeyEnabled = false
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(open.keyEquivalent, "", "no shortcut, no key equivalent")
        XCTAssertEqual(open.keyEquivalentModifierMask, [])

        // A Shelf that holds something is listed.
        let file = try makeTemporaryFile()
        XCTAssertEqual(composition.shelf.add(fileURLs: [file]).added.count, 1)
        controller.menuNeedsUpdate(menu)
        XCTAssertFalse(shelf.isHidden)

        settings.shelf.enabled = false
        controller.menuNeedsUpdate(menu)
        XCTAssertTrue(shelf.isHidden, "the Shelf turned off isn't listed")
    }

    func testStatusMenuOpensRecentsAndShelf() throws {
        let settings = composition.settings
        settings.showMenuBarIcon = false
        let controller = StatusItemController(viewModel: composition.viewModel, settings: settings)
        let menu = controller.menu
        let viewModel = composition.viewModel

        let recentsIndex = menu.indexOfItem(withTitle: "Recent Conversations…")
        XCTAssertGreaterThanOrEqual(recentsIndex, 0)
        menu.performActionForItem(at: recentsIndex)
        XCTAssertTrue(viewModel.isOpen)
        XCTAssertTrue(viewModel.isEngaged)
        XCTAssertEqual(viewModel.route, .history)

        viewModel.close(.user)
        XCTAssertEqual(composition.shelf.add(fileURLs: [try makeTemporaryFile()]).added.count, 1)
        controller.menuNeedsUpdate(menu)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Shelf…"))
        XCTAssertTrue(viewModel.isOpen)
        XCTAssertEqual(viewModel.route, .shelf)
    }

    // MARK: - Helpers

    private static func logEntry(daysAgo: Double) -> ActionLogEntry {
        ActionLogEntry(id: UUID(), date: Date().addingTimeInterval(-daysAgo * 86_400), tool: "open_url",
                       decision: "approved", outcome: "ok", summary: "Open example.com", provenance: nil,
                       caution: false, durationMs: 12, scriptSHA256: nil, script: nil, target: "example.com")
    }

    private func makeTemporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OttoCompositionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("Otto".utf8).write(to: file)
        return file
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func waitUntilAsync(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }
}

// MARK: - Fakes

/// Records what the global shortcut asked of it; its state is set by the test.
@MainActor private final class HotKeyTargetFake: AppComposition.HotKeyTarget {
    enum Call: Equatable {
        case open(NotchViewModel.OpenReason, focus: Bool)
        case close(CloseReason)
        case disengage
        case stopSpeaking
        case beginVoice(VoiceMode)
        case finishVoice(send: Bool)
    }

    var hotKeyState = AppComposition.HotKeyState(isSpeaking: false, isListeningInToggleMode: false, isPinned: false,
                                                 isOpen: false, isEngaged: false)
    var calls: [Call] = []

    func open(reason: NotchViewModel.OpenReason, focus: Bool) { calls.append(.open(reason, focus: focus)) }
    func close(_ reason: CloseReason) { calls.append(.close(reason)) }
    func disengage() { calls.append(.disengage) }
    func stopSpeaking() { calls.append(.stopSpeaking) }
    func beginVoice(_ mode: VoiceMode) { calls.append(.beginVoice(mode)) }
    func finishVoice(send: Bool) { calls.append(.finishVoice(send: send)) }
}

/// A notification center that only records removals (nothing is ever posted).
private final class NotificationCenterSpy: GlanceNotificationCenter {
    weak var delegate: UNUserNotificationCenterDelegate?
    private(set) var removedDelivered: [[String]] = []
    private(set) var removedPending: [[String]] = []

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
        completionHandler?(nil)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDelivered.append(identifiers)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPending.append(identifiers)
    }
}

/// Walks the graph's stored properties (Swift reflection) and collects every PermissionsCenter it reaches and
/// the types that hold one. Actors are skipped (their state isn't read from outside), and the walk is bounded.
@MainActor private struct PermissionsCenterSearch {
    private(set) var centers: Set<ObjectIdentifier> = []
    private(set) var owners: Set<String> = []
    private var visited: Set<ObjectIdentifier> = []

    init(root: AnyObject, depthLimit: Int = 8) {
        visit(root, owner: nil, depth: depthLimit)
    }

    private mutating func visit(_ value: Any, owner: String?, depth: Int) {
        guard depth > 0, !(value is any Actor) else { return }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .class {
            let object = value as AnyObject
            if let center = object as? PermissionsCenter {
                centers.insert(ObjectIdentifier(center))
                if let owner { owners.insert(owner) }
                return
            }
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
        }
        let typeName = String(describing: type(of: value))
        let childOwner = mirror.displayStyle == .optional || mirror.displayStyle == .collection
            || mirror.displayStyle == .dictionary || mirror.displayStyle == .set || mirror.displayStyle == .tuple
            ? owner : typeName
        var current: Mirror? = mirror
        while let level = current {
            for child in level.children {
                visit(child.value, owner: childOwner, depth: depth - 1)
            }
            current = level.superclassMirror
        }
    }
}
