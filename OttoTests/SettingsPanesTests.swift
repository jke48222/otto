//
//  SettingsPanesTests.swift
//  OttoTests
//
//  The Settings window: every pane builds and lays out with inert services, the shortcut recorder's commit,
//  reject, clear and reset paths, the panel's Space and level behavior (openExternal lowers it until it is key
//  again; show never activates Otto), deep links to a tab and section, and that only the ★ rows ask macOS
//  for a permission.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import Otto

@MainActor
final class SettingsPanesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var controllers: [SettingsWindowController] = []

    override func setUp() async throws {
        defaults = TestDefaults.make(for: self)
        settings = AppSettings(defaults: defaults, usesKeychain: false)
    }

    override func tearDown() async throws {
        for controller in controllers {
            controller.panel?.orderOut(nil)
        }
        controllers = []
    }

    // MARK: - Panes

    func testEveryPaneBuildsWithInertServicesAndLaysOut() async throws {
        let services = SettingsServices.inert(settings: settings)
        for tab in SettingsTab.allCases {
            try await layOut(SettingsView(settings: settings, tab: tab, services: services), tab: tab)
        }
        try await layOut(SettingsView(settings: settings), tab: .general)
    }

    func testEveryPaneLaysOutWithEverythingRevealed() async throws {
        settings.actions.enabled = true
        settings.voice.enabled = true
        settings.voice.spokenReplies = .always
        settings.glance.calendarChipEnabled = true
        settings.glance.notificationPolicy = .always
        settings.lastSettingsError = "Couldn't save your API key to the Keychain."

        var services = SettingsServices.inert(settings: settings)
        let approvals = ApprovalStore(defaults: defaults)
        approvals.remember(ApprovalScope(toolName: "run_shortcut", key: "shortcut:1", label: "“Log water”"))
        approvals.grantConsent(ConsentKey(rawValue: "calendar.read", label: "Read your calendar"))
        services.approvals = approvals
        let today = Self.dayKey(for: Date())
        services.ledger.debugSeed(answers: [], days: [today: [
            "claude-opus-5": UsageTotals(usage: TokenUsage(input: 1_204, output: 612, cacheRead: 14_880, webSearches: 1),
                                         costNanos: 40_600_000, replies: 3),
        ]])
        services.actionLog = ActionLog(directory: nil)

        for tab in SettingsTab.allCases {
            try await layOut(SettingsView(settings: settings, tab: tab, services: services), tab: tab)
        }
    }

    // MARK: - Shortcut recorder

    func testRecorderCommitsAValidCombo() {
        let combo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(controlKey | optionKey))
        var registered: [HotKeyCombo] = []
        settings.shortcuts.registrar = { registered.append($0); return .applied }

        XCTAssertEqual(ShortcutRecorder.commit(combo, settings: settings, systemShortcuts: []), .applied)
        XCTAssertEqual(registered, [combo])
        XCTAssertEqual(settings.shortcuts.hotKey, combo)
        XCTAssertTrue(settings.hotKeyEnabled)
        XCTAssertEqual(AppSettings(defaults: defaults, usesKeychain: false).shortcuts.hotKey, combo, "persisted")
        XCTAssertFalse(ShortcutRecorder.isDefault(settings))
    }

    func testRecorderCommitTurnsANoneShortcutBackOn() {
        ShortcutRecorder.clear(settings: settings)
        XCTAssertFalse(settings.hotKeyEnabled)

        let combo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_O), carbonModifiers: UInt32(controlKey | optionKey))
        XCTAssertEqual(ShortcutRecorder.commit(combo, settings: settings, systemShortcuts: []), .applied)
        XCTAssertTrue(settings.hotKeyEnabled)
        XCTAssertEqual(settings.shortcuts.hotKey, combo)
    }

    func testRecorderRejectsOttosOwnNotchChords() {
        var registered: [HotKeyCombo] = []
        settings.shortcuts.registrar = { registered.append($0); return .applied }
        let newChat = HotKeyCombo(keyCode: UInt32(kVK_ANSI_N), carbonModifiers: UInt32(cmdKey))

        let result = ShortcutRecorder.commit(newChat, settings: settings, systemShortcuts: [])

        XCTAssertEqual(result, .rejected("⌘N is one of Otto's own shortcuts in the notch. Pick another."))
        XCTAssertEqual(result, .rejected(HotKeyProblem.conflictsWithOtto("⌘N").errorDescription ?? ""))
        XCTAssertTrue(registered.isEmpty, "a refused combo is never registered")
        XCTAssertEqual(settings.shortcuts.hotKey, .optionSpace, "the old combo stays")
        XCTAssertNil(defaults.object(forKey: "otto.shortcuts.hotKey"))
    }

    func testRecorderRejectsTypingKeysReservedAndSystemChords() {
        let plainK = HotKeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: 0)
        XCTAssertEqual(ShortcutRecorder.commit(plainK, settings: settings, systemShortcuts: []),
                       .rejected(HotKeyProblem.needsModifier.errorDescription ?? ""))

        let quit = HotKeyCombo(keyCode: UInt32(kVK_ANSI_Q), carbonModifiers: UInt32(cmdKey))
        XCTAssertEqual(ShortcutRecorder.commit(quit, settings: settings, systemShortcuts: []),
                       .rejected(HotKeyProblem.reserved("⌘Q").errorDescription ?? ""))

        let spotlight = HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey))
        let system = [SystemShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey))]
        XCTAssertEqual(ShortcutRecorder.commit(spotlight, settings: settings, systemShortcuts: system),
                       .rejected(HotKeyProblem.system.errorDescription ?? ""))

        XCTAssertEqual(settings.shortcuts.hotKey, .optionSpace)
        XCTAssertTrue(settings.hotKeyEnabled)
    }

    func testRecorderShowsTheRegistrarsRefusal() {
        let combo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_O), carbonModifiers: UInt32(controlKey | optionKey))
        settings.shortcuts.registrar = { _ in .rejected("Another app is already using ⌃⌥O.") }

        XCTAssertEqual(ShortcutRecorder.commit(combo, settings: settings, systemShortcuts: []),
                       .rejected("Another app is already using ⌃⌥O."))
        XCTAssertEqual(settings.shortcuts.hotKey, .optionSpace)
    }

    func testClearMeansNoneAndKeepsTheStoredCombo() {
        let combo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_O), carbonModifiers: UInt32(controlKey | optionKey))
        ShortcutRecorder.commit(combo, settings: settings, systemShortcuts: [])

        ShortcutRecorder.clear(settings: settings)

        XCTAssertFalse(settings.hotKeyEnabled)
        XCTAssertEqual(settings.shortcuts.hotKey, combo)
        XCTAssertFalse(ShortcutRecorder.isDefault(settings))
    }

    func testResetGoesBackToOptionSpaceAndOn() {
        let combo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_O), carbonModifiers: UInt32(controlKey | optionKey))
        ShortcutRecorder.commit(combo, settings: settings, systemShortcuts: [])
        ShortcutRecorder.clear(settings: settings)

        XCTAssertEqual(ShortcutRecorder.reset(settings: settings, systemShortcuts: []), .applied)

        XCTAssertEqual(settings.shortcuts.hotKey, .optionSpace)
        XCTAssertTrue(settings.hotKeyEnabled)
        XCTAssertTrue(ShortcutRecorder.isDefault(settings))
    }

    // MARK: - Panel

    func testPanelFloatsOnTheActiveSpaceWithoutActivating() {
        let controller = makeController()
        controller.show()
        let panel = try? XCTUnwrap(controller.panel)

        XCTAssertEqual(panel?.styleMask.contains(.nonactivatingPanel), true)
        XCTAssertEqual(panel?.collectionBehavior.contains(.moveToActiveSpace), true)
        XCTAssertEqual(panel?.collectionBehavior.contains(.fullScreenAuxiliary), true)
        XCTAssertEqual(panel?.isFloatingPanel, true)
        XCTAssertEqual(panel?.level, .floating)
        XCTAssertEqual(panel?.hidesOnDeactivate, false)
        XCTAssertEqual(panel?.contentRect(forFrameRect: panel?.frame ?? .zero).width, SettingsWindowController.contentWidth)
        XCTAssertTrue(controller.isVisible)
    }

    func testShowNeverActivatesOtto() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Otto/App/SettingsWindowController.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(text.contains("NSApp.activate"), "Settings must become key without activating Otto")
        XCTAssertFalse(text.contains("activate(ignoringOtherApps"))
        XCTAssertFalse(text.contains("orderFrontRegardless"))
    }

    func testOpenExternalLowersThePanelUntilItIsKeyAgain() throws {
        let controller = makeController()
        var opened: [URL] = []
        controller.externalOpener = { opened.append($0) }
        controller.show(tab: .privacy)
        let panel = try XCTUnwrap(controller.panel)
        let url = try XCTUnwrap(Permission.accessibility.settingsURL)

        controller.openExternal(url)

        XCTAssertEqual(opened, [url])
        XCTAssertFalse(panel.isFloatingPanel)
        XCTAssertEqual(panel.level, .normal)

        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: panel))

        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertEqual(panel.level, .floating)
    }

    func testShowSelectsTheTabAndRequestsTheAnchor() throws {
        let controller = makeController()

        controller.show(anchor: .usage)

        XCTAssertEqual(controller.selectedTab, .models)
        XCTAssertEqual(controller.navigation.pendingAnchor, .usage)
        XCTAssertEqual(controller.navigation.requestCount, 1)
        XCTAssertEqual(controller.panel?.title, "Models")
        XCTAssertEqual(defaults.string(forKey: SettingsWindowController.lastTabKey), "models")
        let contentHeight = controller.panel.map { $0.contentRect(forFrameRect: $0.frame).height }
        XCTAssertEqual(contentHeight, SettingsWindowController.height(for: .models))

        controller.show(tab: .privacy, anchor: .permissions)

        XCTAssertEqual(controller.selectedTab, .privacy)
        XCTAssertEqual(controller.navigation.pendingAnchor, .permissions)
        XCTAssertEqual(controller.navigation.requestCount, 2)
        XCTAssertEqual(controller.panel?.title, "Privacy")

        controller.show(tab: .voice)
        XCTAssertEqual(controller.selectedTab, .voice)
        XCTAssertEqual(controller.navigation.requestCount, 2, "no anchor, no new request")
    }

    func testThePaneScrollsToTheRequestedAnchorAndConsumesIt() async throws {
        let controller = makeController()
        controller.show(anchor: .approvals)
        XCTAssertEqual(controller.navigation.pendingAnchor, .approvals)

        let deadline = Date().addingTimeInterval(3)
        while controller.navigation.pendingAnchor != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(controller.navigation.pendingAnchor, "the Actions pane scrolled to Approvals")
    }

    func testShowWithoutATabReopensTheLastOne() {
        defaults.set(SettingsTab.voice.rawValue, forKey: SettingsWindowController.lastTabKey)
        let controller = makeController()

        controller.show()

        XCTAssertEqual(controller.selectedTab, .voice)
        XCTAssertEqual(controller.panel?.title, "Voice")
    }

    func testClosingStopsRecording() throws {
        let controller = makeController()
        controller.show()
        settings.shortcuts.isRecording = true

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.panel))

        XCTAssertFalse(settings.shortcuts.isRecording)
    }

    func testPanelPlacementStaysOnTheVisibleFrame() {
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let origin = SettingsWindowController.origin(for: NSSize(width: 560, height: 760), on: visible)
        XCTAssertEqual(origin.x, 440)
        XCTAssertGreaterThanOrEqual(origin.y, visible.minY)
        XCTAssertLessThanOrEqual(origin.y + 760, visible.maxY)

        for tab in SettingsTab.allCases {
            XCTAssertTrue(SettingsWindowController.heightRange.contains(SettingsWindowController.height(for: tab)))
        }
    }

    // MARK: - Permissions from feature toggles

    func testTurningOnANonStarToggleNeverAsksForAPermission() async {
        let probe = RecordingPermissionProbe()
        let permissions = makePermissions(probe)

        for toggle in SettingsFeatureToggle.allCases where toggle.permissionsRequestedWhenTurnedOn.isEmpty {
            toggle.store(false, in: settings)
            let results = await toggle.set(true, settings: settings, permissions: permissions)
            XCTAssertTrue(results.isEmpty, "\(toggle)")
            XCTAssertTrue(toggle.isOn(in: settings), "\(toggle) is stored")
            await toggle.set(false, settings: settings, permissions: permissions)
            XCTAssertFalse(toggle.isOn(in: settings), "\(toggle) turns off")
        }

        XCTAssertEqual(probe.requests, [], "no system prompt from a plain feature switch")
    }

    func testStarTogglesAskForTheirPermissionsInOrder() async {
        let probe = RecordingPermissionProbe(answers: [.microphone: .granted, .speechRecognition: .granted,
                                                       .accessibility: .notDetermined, .calendars: .granted])
        let permissions = makePermissions(probe)

        let voice = await SettingsFeatureToggle.voice.set(true, settings: settings, permissions: permissions)
        XCTAssertEqual(voice, [.microphone: .granted, .speechRecognition: .granted])
        XCTAssertTrue(settings.voice.enabled)

        await SettingsFeatureToggle.offerSelection.set(true, settings: settings, permissions: permissions)
        XCTAssertTrue(settings.context.offerSelection, "stays on while Accessibility is switched on in System Settings")

        await SettingsFeatureToggle.calendarChip.set(true, settings: settings, permissions: permissions)
        XCTAssertTrue(settings.glance.calendarChipEnabled)

        XCTAssertEqual(probe.requests, [.microphone, .speechRecognition, .accessibility, .calendars])
    }

    func testVoiceStopsAskingOnceTheMicrophoneIsRefused() async {
        let probe = RecordingPermissionProbe(answers: [.microphone: .denied])
        let permissions = makePermissions(probe)

        let results = await SettingsFeatureToggle.voice.set(true, settings: settings, permissions: permissions)

        XCTAssertEqual(results, [.microphone: .denied])
        XCTAssertEqual(probe.requests, [.microphone])
        XCTAssertTrue(settings.voice.enabled, "the Voice rows show the denied state instead of turning it off")
    }

    func testCalendarChipTurnsBackOffWithoutAccess() async {
        let probe = RecordingPermissionProbe(answers: [.calendars: .denied])
        let permissions = makePermissions(probe)

        let results = await SettingsFeatureToggle.calendarChip.set(true, settings: settings, permissions: permissions)

        XCTAssertEqual(results, [.calendars: .denied])
        XCTAssertFalse(settings.glance.calendarChipEnabled)
    }

    func testNotificationPolicyAsksOnlyForAPolicyOtherThanNever() async {
        let granted = RecordingPermissionProbe(answers: [.notifications: .granted])
        var outcome = await SettingsFeatureToggle.setNotificationPolicy(.off, settings: settings,
                                                                        permissions: makePermissions(granted))
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(granted.requests, [])

        outcome = await SettingsFeatureToggle.setNotificationPolicy(.whenOutOfSight, settings: settings,
                                                                    permissions: makePermissions(granted))
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(granted.requests, [.notifications])
        XCTAssertEqual(settings.glance.notificationPolicy, .whenOutOfSight)

        let denied = RecordingPermissionProbe(answers: [.notifications: .denied])
        outcome = await SettingsFeatureToggle.setNotificationPolicy(.always, settings: settings,
                                                                    permissions: makePermissions(denied))
        XCTAssertEqual(outcome, .deniedInSystemSettings)
        XCTAssertEqual(settings.glance.notificationPolicy, .always, "kept; the footer points to System Settings")

        let unavailable = RecordingPermissionProbe(answers: [.notifications: .notDetermined])
        outcome = await SettingsFeatureToggle.setNotificationPolicy(.always, settings: settings,
                                                                    permissions: makePermissions(unavailable))
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(settings.glance.notificationPolicy, .off, "an unsupported build goes back to Never")
    }

    func testInertServicesNeverTouchTheSystem() async {
        let services = SettingsServices.inert(settings: settings)
        XCTAssertNil(services.actionLog)
        XCTAssertNil(services.history)
        XCTAssertNil(services.shelf)
        XCTAssertNil(services.calendar)
        XCTAssertNil(services.nowPlaying)
        XCTAssertNil(services.neighbors)
        XCTAssertNil(services.speaker)
        XCTAssertNil(services.processRunner)
        XCTAssertTrue(services.approvals.remembered.isEmpty)
        XCTAssertTrue(services.approvals.consents.isEmpty)
        await services.permissions.refreshAll()
        for permission in Permission.systemWide {
            XCTAssertEqual(services.permissions.status(permission), .notDetermined)
        }
    }

    func testPermissionStatesReadAsSpecified() {
        XCTAssertEqual(SettingsPermissionState(.granted).text, "Allowed")
        XCTAssertEqual(SettingsPermissionState(.notDetermined).text, "Asks when needed")
        XCTAssertEqual(SettingsPermissionState(.denied).text, "Off in System Settings")
        XCTAssertTrue(SettingsPermissionState(.denied).offersOpen)
        XCTAssertEqual(SettingsPermissionState(.needsRelaunch).text, "Reopen Otto to finish")
        XCTAssertFalse(SettingsPermissionState(.granted).offersOpen)
    }

    func testModelPricesReadPerMillionTokens() {
        XCTAssertEqual(SettingsModelsPane.subtitle(for: .opus5), "Most capable · $5 / $25 per million tokens")
        XCTAssertEqual(SettingsModelsPane.perMillion(2_500), "$2.50")
        XCTAssertEqual(SettingsModelsPane.perMillion(1_000), "$1")
    }

    // MARK: - Helpers

    private func makeController() -> SettingsWindowController {
        let controller = SettingsWindowController(settings: settings)
        controller.preferences = defaults
        controller.externalOpener = { _ in }
        controllers.append(controller)
        return controller
    }

    private func makePermissions(_ probe: PermissionProbe) -> PermissionsCenter {
        PermissionsCenter(probe: probe, defaults: defaults, openURL: { _ in }, pollInterval: .milliseconds(10),
                          relauncher: NoRelaunch())
    }

    private func layOut<V: View>(_ view: V, tab: SettingsTab) async throws {
        let size = NSSize(width: SettingsWindowController.contentWidth, height: SettingsWindowController.height(for: tab))
        let host = NSHostingView(rootView: view.environment(SettingsNavigation()))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0, "\(tab)")
        XCTAssertEqual(host.frame.size, size, "\(tab)")
    }

    private static func dayKey(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

// MARK: - Fakes

/// Answers status reads from `current` and requests from `answers`, recording every request.
private final class RecordingPermissionProbe: PermissionProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var current: [Permission: PermissionStatus] = [:]
    private let answers: [Permission: PermissionStatus]
    private var recorded: [Permission] = []

    init(answers: [Permission: PermissionStatus] = [:]) {
        self.answers = answers
    }

    var requests: [Permission] { lock.withLock { recorded } }

    func status(of permission: Permission) async -> PermissionStatus {
        lock.withLock { current[permission] ?? .notDetermined }
    }

    func request(_ permission: Permission) async -> PermissionStatus {
        lock.withLock {
            recorded.append(permission)
            let answer = answers[permission] ?? .notDetermined
            current[permission] = answer
            return answer
        }
    }
}

@MainActor private struct NoRelaunch: AppRelaunching {
    func relaunch() {}
}
