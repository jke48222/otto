//
//  SettingsPanesTests.swift
//  OttoTests
//
//  The Settings window: every pane builds and lays out with inert services, the shortcut recorder's commit,
//  reject, clear and reset paths, the panel's Space and level behavior (openExternal lowers it until it is key
//  again; show never activates Otto), deep links to a tab and section, that only the ★ rows ask macOS
//  for a permission, and Models with a Setapp AI account (provider choice, credits, captions).
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

    /// The non-activating Settings panel resigns key without resigning its first responder when the user clicks
    /// another app: recording must stop then (and on close), or the global shortcut stays unregistered.
    func testRecorderStopsWhenItsWindowResignsKeyOrCloses() {
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 40),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let recorder = RecorderNSView(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
            var cancels = 0
            recorder.onCancel = { cancels += 1 }
            window.contentView?.addSubview(recorder)
            XCTAssertTrue(recorder.accessibilityPerformPress())
            XCTAssertTrue(recorder.isRecording)

            NotificationCenter.default.post(name: name, object: window)

            XCTAssertFalse(recorder.isRecording, "\(name.rawValue)")
            XCTAssertEqual(cancels, 1, "\(name.rawValue)")
            // Another window's notification doesn't touch it.
            XCTAssertTrue(recorder.accessibilityPerformPress())
            NotificationCenter.default.post(name: name, object: NSWindow())
            XCTAssertTrue(recorder.isRecording)
            recorder.cancelRecording()
            XCTAssertEqual(cancels, 2)
            recorder.removeFromSuperview()
            window.close()
        }
    }

    func testVoiceRecognitionStatusFollowsTheServiceSwitch() {
        XCTAssertEqual(SettingsVoicePane.recognitionStatus(isOnDevice: true, allowsServer: false), .onDevice)
        XCTAssertEqual(SettingsVoicePane.recognitionStatus(isOnDevice: true, allowsServer: true), .onDevice)
        XCTAssertEqual(SettingsVoicePane.recognitionStatus(isOnDevice: false, allowsServer: true), .server)
        XCTAssertEqual(SettingsVoicePane.recognitionStatus(isOnDevice: false, allowsServer: false), .asksFirst)
        XCTAssertEqual(SettingsVoicePane.RecognitionStatus.server.text, "Uses Apple's speech service")
        XCTAssertEqual(SettingsVoicePane.RecognitionStatus.asksFirst.text,
                       "Not available on this Mac. Otto will ask before using Apple's speech service.")
    }

    /// "Transcribed on this Mac" only ever shows under the on-device status, and nothing is claimed before the
    /// Mac's languages have loaded.
    func testVoiceRecognitionCaptionNeverContradictsTheStatus() {
        XCTAssertEqual(SettingsVoicePane.recognitionStatus(isOnDevice: nil, allowsServer: true), .checking)
        XCTAssertEqual(SettingsVoicePane.recognitionStatus(isOnDevice: nil, allowsServer: false), .checking)
        XCTAssertEqual(SettingsVoicePane.RecognitionStatus.onDevice.caption, "✓ Transcribed on this Mac.")
        for status in [SettingsVoicePane.RecognitionStatus.server, .asksFirst, .checking] {
            XCTAssertFalse(status.caption?.contains("on this Mac") ?? false, "\(status)")
        }
        XCTAssertNil(SettingsVoicePane.RecognitionStatus.checking.caption)
    }

    /// Warning, error and success text in Settings passes WCAG AA (4.5:1) in both appearances, on the window and on
    /// the grouped rows (the system orange, red and green fail on a light window).
    func testSettingsToneTextPassesAAInBothAppearances() throws {
        let tones: [(String, NSColor)] = [("warning", SettingsTone.warningColor), ("error", SettingsTone.errorColor),
                                          ("success", SettingsTone.successColor),
                                          ("secondary text", SettingsTone.secondaryTextColor)]
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let groupedDarkRow = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1)
        for (name, color) in tones {
            for background in [NSColor.windowBackgroundColor, .controlBackgroundColor, .white] {
                XCTAssertGreaterThanOrEqual(SettingsTone.contrastRatio(color, on: background, in: light), 4.5,
                                            "\(name) on \(background) in light")
            }
            for background in [NSColor.windowBackgroundColor, .controlBackgroundColor, groupedDarkRow] {
                XCTAssertGreaterThanOrEqual(SettingsTone.contrastRatio(color, on: background, in: dark), 4.5,
                                            "\(name) on \(background) in dark")
            }
        }
        XCTAssertLessThan(SettingsTone.contrastRatio(.systemOrange, on: .white, in: light), 4.5,
                          "the system orange is what this replaces")
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

    // MARK: - Setapp AI

    func testProviderRowsReadAsSpecified() {
        XCTAssertEqual(Set(SettingsProviderSection.providers), Set(AIProvider.allCases))
        XCTAssertEqual(SettingsProviderSection.providers.first, .setappAI, "Setapp AI is listed first")
        XCTAssertEqual(SettingsProviderSection.subtitle(for: .setappAI, isConfigured: true),
                       "Uses your Setapp AI credits. No API key needed.")
        XCTAssertEqual(SettingsProviderSection.subtitle(for: .anthropic, isConfigured: true),
                       "Billed to your Anthropic account, per token.")
        XCTAssertEqual(SettingsProviderSection.subtitle(for: .setappAI, isConfigured: false), "Not set up in this build.")
        XCTAssertEqual(SettingsProviderSection.subtitle(for: .anthropic, isConfigured: false),
                       "Billed to your Anthropic account, per token.")
        XCTAssertFalse(SettingsProviderSection.isSelectable(.setappAI, isConfigured: false))
        XCTAssertTrue(SettingsProviderSection.isSelectable(.setappAI, isConfigured: true))
        XCTAssertTrue(SettingsProviderSection.isSelectable(.anthropic, isConfigured: false))
    }

    func testSetappAICopyIsTheSpecifiedCopy() {
        XCTAssertEqual(SettingsProviderSection.gatewayCaption, "Your messages go to Setapp's AI gateway, run by MacPaw, "
                       + "which passes them to Anthropic. Setapp counts credits for each reply.")
        XCTAssertEqual(SettingsProviderSection.webSearchCaption, "Web search and reading pages work with Opus 5 and "
                       + "Sonnet 5. Otto opens each page on your Mac, without your cookies, so Claude can read an attached "
                       + "browser tab.")
        XCTAssertEqual(SettingsModelsPane.setappAIUsageNote, "Setapp AI replies use credits and aren't counted here.")
        XCTAssertEqual(SetappAICreditsRow.loadingText, "Loading your credits…")
        XCTAssertEqual(SettingsModelsPane.showCostSubtitle(usesSetappAI: true),
                       "Replies on your own key show an estimate when you point at them.")
        XCTAssertEqual(SettingsModelsPane.showCostSubtitle(usesSetappAI: false),
                       "An estimate appears next to a reply when you point at it.")
    }

    func testTheWebToggleSaysHaikuDoesntSearchOrReadPagesOnSetappAI() {
        XCTAssertEqual(SettingsModelsPane.setappAIWebSearchSubtitle(for: .haiku45),
                       "No web search on Haiku 4.5 with Setapp AI")
        XCTAssertEqual(SettingsModelsPane.setappAIWebSearchSubtitle(for: .haiku45),
                       HeaderModelMenu.webSearchCaption(model: .haiku45, provider: .setappAI),
                       "Settings and the header menu say the same")
        for model in [ModelOption.opus5, .sonnet5] {
            XCTAssertEqual(SettingsModelsPane.setappAIWebSearchSubtitle(for: model), "Let Claude look things up and read pages.")
            XCTAssertEqual(SettingsModelsPane.setappAIWebSearchSubtitle(for: model), SettingsModelsPane.webAccessSubtitle,
                           "on Setapp AI the toggle says what it says on the user's own key")
            // The caption's claim: Otto offers its web fetch on these models through Setapp AI, and not on Haiku.
            let request = MessagesRequest(model: model, system: "", messages: [], maxTokens: 1, effort: .low, webAccess: true)
            XCTAssertTrue(SetappWebFetch.isOffered(request, options: .standard), model.rawValue)
        }
        let haiku = MessagesRequest(model: .haiku45, system: "", messages: [], maxTokens: 1, effort: .low, webAccess: true)
        XCTAssertFalse(SetappWebFetch.isOffered(haiku, options: .standard))
        // "without your cookies": the session Otto reads pages with stores and sends none.
        let configuration = WebPageReader.makeConfiguration(timeout: WebPageReader.timeout, protocolClasses: nil)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
    }

    func testTheAnthropicInvoiceShowsOnlyWithOwnKeyUsage() {
        XCTAssertTrue(SettingsModelsPane.showsAnthropicBilling(usesSetappAI: false, hasOwnKeyUsage: false),
                      "on the user's own key, always")
        XCTAssertTrue(SettingsModelsPane.showsAnthropicBilling(usesSetappAI: false, hasOwnKeyUsage: true))
        XCTAssertFalse(SettingsModelsPane.showsAnthropicBilling(usesSetappAI: true, hasOwnKeyUsage: false),
                       "on Setapp AI with nothing billed to a key, there is no invoice to point at")
        XCTAssertTrue(SettingsModelsPane.showsAnthropicBilling(usesSetappAI: true, hasOwnKeyUsage: true))

        let ledger = UsageLedger(fileURL: nil)
        XCTAssertFalse(SettingsModelsPane.hasOwnKeyUsage(ledger))
        ledger.debugSeed(answers: [], days: ["2025-01-02": [
            "claude-haiku-4-5": UsageTotals(usage: TokenUsage(input: 10, output: 5), costNanos: 35_000, replies: 1),
        ]])
        XCTAssertTrue(SettingsModelsPane.hasOwnKeyUsage(ledger), "any day counts, however long ago")
    }

    func testTheModelsPaneDecidesFromTheAccountNotTheBuild() {
        let account = StaticSetappAIAccount()
        settings.aiProvider = .setappAI
        XCTAssertTrue(SettingsModelsPane.usesSetappAI(settings: settings, account: account))
        XCTAssertFalse(SettingsModelsPane.usesSetappAI(settings: settings, account: nil),
                       "no account: the pane as today, whatever is stored")
        XCTAssertFalse(SettingsModelsPane.usesSetappAI(settings: settings, account: StaticSetappAIAccount(isConfigured: false)),
                       "not set up in this build: the user's own key answers, so its field shows")
        settings.aiProvider = .anthropic
        XCTAssertFalse(SettingsModelsPane.usesSetappAI(settings: settings, account: account))

        // The balance and the gateway captions show only while Setapp AI is chosen and set up.
        XCTAssertTrue(SettingsProviderSection.showsCredits(provider: .setappAI, isConfigured: true))
        XCTAssertFalse(SettingsProviderSection.showsCredits(provider: .setappAI, isConfigured: false))
        XCTAssertFalse(SettingsProviderSection.showsCredits(provider: .anthropic, isConfigured: true))

        // Not set up: the radio group checks the user's own key, which is what answers.
        XCTAssertEqual(SettingsProviderSection.shownProvider(stored: .setappAI, isConfigured: false), .anthropic)
        XCTAssertEqual(SettingsProviderSection.shownProvider(stored: .setappAI, isConfigured: true), .setappAI)
        XCTAssertEqual(SettingsProviderSection.shownProvider(stored: .anthropic, isConfigured: false), .anthropic)
    }

    func testTheCreditsRowOffersGetCreditsWhenLoadedOrFailed() {
        XCTAssertEqual(SetappAICreditsRow.controls(for: .idle), [])
        XCTAssertEqual(SetappAICreditsRow.controls(for: .loading), [])
        XCTAssertEqual(SetappAICreditsRow.controls(for: .loaded(SetappCreditBalance(available: 1, granted: 6_000))),
                       [.getCredits])
        XCTAssertEqual(SetappAICreditsRow.controls(for: .failed("Couldn't load your credits.")), [.tryAgain, .getCredits],
                       "a member who can't see the balance may still know they're out")
    }

    func testGetCreditsOpensSetappsPageThroughSettingsOwnOpener() async {
        let link = URL(string: "https://store.setapp.com/ai/credits?app=otto")!
        let account = StaticSetappAIAccount(creditState: .loaded(SetappCreditBalance(available: 0, granted: 6_000)),
                                            purchaseLink: link)
        var opened: [URL] = []
        await SetappAICreditsRow.openPurchasePage(of: account, with: SettingsExternalOpener { opened.append($0) })
        XCTAssertEqual(opened, [link])
        XCTAssertEqual(account.calls, ["purchaseURL"])
        let fallback = await StaticSetappAIAccount().purchaseURL()
        XCTAssertEqual(fallback, SetappCreditFormatter.fallbackPurchaseURL,
                       "the static account hands over Setapp's AI page unless told otherwise")
    }

    func testSettingsBecomingKeyRefreshesTheBalanceOnSetappAI() {
        for (provider, isConfigured, expected) in [(AIProvider.setappAI, true, ["refresh(force)"]),
                                                    (.anthropic, true, []), (.setappAI, false, [])] {
            let account = StaticSetappAIAccount(isConfigured: isConfigured)
            settings.aiProvider = provider
            var services = SettingsServices.inert(settings: settings)
            services.setappAI = account
            let controller = SettingsWindowController(settings: settings, services: services)
            controller.preferences = defaults
            controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            XCTAssertEqual(account.calls, expected, "\(provider) configured: \(isConfigured)")
        }
    }

    func testModelRowsDropTheirListPricesOnSetappAI() {
        XCTAssertEqual(SettingsModelsPane.subtitle(for: .opus5, showsPrice: false), "Most capable")
        XCTAssertEqual(SettingsModelsPane.subtitle(for: .haiku45, showsPrice: false), "Fastest")
        XCTAssertEqual(SettingsModelsPane.subtitle(for: .sonnet5, showsPrice: true),
                       "Fast and capable · $2 / $10 per million tokens")
    }

    func testTheModelsPaneLaysOutWithASetappAIAccountInEveryState() async throws {
        let states: [SetappCreditState] = [
            .idle, .loading,
            .loaded(SetappCreditBalance(available: 1_234, granted: 6_000)),
            .loaded(SetappCreditBalance(available: 0, granted: 0)),
            .failed("Couldn't load your credits. Make sure Setapp is open."),
        ]
        for provider in AIProvider.allCases {
            for state in states {
                settings.aiProvider = provider
                var services = SettingsServices.inert(settings: settings)
                services.setappAI = StaticSetappAIAccount(creditState: state)
                try await layOut(SettingsView(settings: settings, tab: .models, services: services), tab: .models)
            }
        }
        settings.aiProvider = .setappAI
        var services = SettingsServices.inert(settings: settings)
        services.setappAI = StaticSetappAIAccount(isConfigured: false)
        try await layOut(SettingsView(settings: settings, tab: .models, services: services), tab: .models)
    }

    func testTheBalanceLoadsWhenTheSetappAIPaneAppears() async throws {
        let account = StaticSetappAIAccount()
        settings.aiProvider = .setappAI
        var services = SettingsServices.inert(settings: settings)
        services.setappAI = account
        try await layOut(SettingsView(settings: settings, tab: .models, services: services), tab: .models)
        XCTAssertEqual(account.calls.first, "refresh(force)", "past the SDK's cache: credits may have moved since")
        XCTAssertFalse(account.calls.contains("refresh"))
        XCTAssertFalse(account.calls.contains("purchaseURL"))

        // Nothing to load on the user's own key, or in a build where Setapp AI isn't set up.
        for (provider, isConfigured) in [(AIProvider.anthropic, true), (.setappAI, false)] {
            let idle = StaticSetappAIAccount(isConfigured: isConfigured)
            settings.aiProvider = provider
            var services = SettingsServices.inert(settings: settings)
            services.setappAI = idle
            try await layOut(SettingsView(settings: settings, tab: .models, services: services), tab: .models)
            XCTAssertEqual(idle.calls, [], "\(provider) configured: \(isConfigured)")
        }
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
