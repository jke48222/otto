//
//  PermissionsTests.swift
//  OttoTests
//
//  PermissionsCenter against fake probes, a recording URL opener and a short poll interval: status mappers,
//  deep links, prompts, waits, the relaunch heuristic and command line, and the didGrant events. Nothing here
//  shows a macOS prompt, opens System Settings or quits the test host.
//

import AppKit
import EventKit
import XCTest
@testable import Otto

@MainActor final class PermissionsTests: XCTestCase {
    private let music = Permission.automation(bundleID: "com.apple.Music", appName: "Music")

    // MARK: - Mappers

    func testEventKitStatusMapping() {
        XCTAssertEqual(PermissionsCenter.status(fromEventKit: .fullAccess), .granted)
        XCTAssertEqual(PermissionsCenter.status(fromEventKit: .writeOnly), .limited)
        XCTAssertEqual(PermissionsCenter.status(fromEventKit: .notDetermined), .notDetermined)
        XCTAssertEqual(PermissionsCenter.status(fromEventKit: .denied), .denied)
        XCTAssertEqual(PermissionsCenter.status(fromEventKit: .restricted), .restricted)
    }

    func testAppleEventStatusMapping() {
        XCTAssertEqual(PermissionsCenter.status(fromAppleEventResult: 0), .granted)
        XCTAssertEqual(PermissionsCenter.status(fromAppleEventResult: -1744), .notDetermined)
        XCTAssertEqual(PermissionsCenter.status(fromAppleEventResult: -1743), .denied)
        XCTAssertEqual(PermissionsCenter.status(fromAppleEventResult: -600), .unavailable)
        // Any other failure means the check itself failed.
        XCTAssertEqual(PermissionsCenter.status(fromAppleEventResult: -1708), .unavailable)
        XCTAssertEqual(PermissionsCenter.status(fromAppleEventResult: -1712), .unavailable)
    }

    // MARK: - Deep links

    func testEveryPermissionOpensItsOwnPaneThroughTheInjectedOpener() {
        let expected: [(Permission, String)] = [
            (.accessibility, "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
            (.screenRecording, "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
            (.microphone, "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"),
            (.speechRecognition, "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"),
            (.calendars, "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"),
            (.reminders, "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"),
            (.notifications, "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.jalenedusei.otto"),
            (music, "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
        ]
        XCTAssertEqual(Set(expected.map(\.0)), Set(Permission.systemWide + [music]))

        let harness = makeHarness(ScriptedProbe(default: .denied))
        for (permission, link) in expected {
            XCTAssertEqual(permission.settingsURL?.absoluteString, link)
            harness.center.openSystemSettings(for: permission)
            XCTAssertEqual(harness.center.awaiting, .systemSettings(permission))
            XCTAssertTrue(harness.center.isAwaitingUser)
        }
        XCTAssertEqual(harness.opener.urls.map(\.absoluteString), expected.map(\.1))
    }

    // MARK: - Requests

    func testRequestKeepsSystemPromptAwaitingWhileThePromptIsUp() async {
        let probe = ScriptedProbe(default: .notDetermined, gated: true)
        let harness = makeHarness(probe)
        let request = Task { await harness.center.request(.microphone) }

        let prompted = await eventually { probe.requested == [.microphone] }
        XCTAssertTrue(prompted)
        XCTAssertEqual(harness.center.awaiting, .systemPrompt(.microphone))
        XCTAssertTrue(harness.center.isAwaitingUser)

        // Otto becoming active doesn't end a wait whose prompt is still on screen.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(harness.center.awaiting, .systemPrompt(.microphone))

        probe.answer(.microphone, .granted)
        let result = await request.value
        XCTAssertEqual(result, .granted)
        XCTAssertNil(harness.center.awaiting)
        XCTAssertFalse(harness.center.isAwaitingUser)
        XCTAssertEqual(harness.center.status(.microphone), .granted)
        XCTAssertEqual(harness.grants.permissions, [.microphone])
        XCTAssertTrue(harness.opener.urls.isEmpty)
    }

    func testDeniedRequestOpensSystemSettingsInsteadOfPrompting() async {
        let probe = ScriptedProbe(default: .denied)
        let harness = makeHarness(probe)

        let result = await harness.center.request(.microphone)

        XCTAssertEqual(result, .denied)
        XCTAssertTrue(probe.requested.isEmpty)
        XCTAssertEqual(harness.opener.urls, [Permission.microphone.settingsURL].compactMap { $0 })
        XCTAssertEqual(harness.center.awaiting, .systemSettings(.microphone))
    }

    func testGrantedRestrictedAndUnavailableRequestsNeverPromptOrOpenSettings() async {
        let probe = ScriptedProbe([.calendars: .granted, .reminders: .restricted, music: .unavailable], default: .denied)
        let harness = makeHarness(probe)

        let calendars = await harness.center.request(.calendars)
        let reminders = await harness.center.request(.reminders)
        let automation = await harness.center.request(music)

        XCTAssertEqual(calendars, .granted)
        XCTAssertEqual(reminders, .restricted)
        XCTAssertEqual(automation, .unavailable)
        XCTAssertTrue(probe.requested.isEmpty)
        XCTAssertTrue(harness.opener.urls.isEmpty)
        XCTAssertNil(harness.center.awaiting)
    }

    func testWriteOnlyCalendarsCanStillBeUpgradedFromThePrompt() async {
        let probe = ScriptedProbe([.calendars: .limited], default: .denied, requestResults: [.calendars: .granted])
        let harness = makeHarness(probe)

        let result = await harness.center.request(.calendars)

        XCTAssertEqual(result, .granted)
        XCTAssertEqual(probe.requested, [.calendars])
        XCTAssertEqual(harness.grants.permissions, [.calendars])
    }

    // MARK: - One-time prompts (didPrompt flags)

    func testAccessibilityPromptsOnceThenUsesSystemSettings() async {
        let probe = ScriptedProbe(default: .notDetermined)
        let harness = makeHarness(probe)
        XCTAssertFalse(harness.defaults.bool(forKey: "otto.permissions.didPromptAccessibility"))

        let first = await harness.center.request(.accessibility)

        XCTAssertEqual(probe.requested, [.accessibility])
        XCTAssertTrue(harness.defaults.bool(forKey: "otto.permissions.didPromptAccessibility"))
        XCTAssertEqual(first, .denied, "Not trusted after the one-time prompt reads as denied")
        // The alert stays on screen after AXIsProcessTrustedWithOptions returns.
        XCTAssertEqual(harness.center.awaiting, .systemPrompt(.accessibility))
        XCTAssertTrue(harness.opener.urls.isEmpty)

        let second = await harness.center.request(.accessibility)

        XCTAssertEqual(second, .denied)
        XCTAssertEqual(probe.requested, [.accessibility], "The system prompt is shown only once")
        XCTAssertEqual(harness.opener.urls, [Permission.accessibility.settingsURL].compactMap { $0 })
        XCTAssertEqual(harness.center.awaiting, .systemSettings(.accessibility))
    }

    func testScreenRecordingPromptsOnceThenUsesSystemSettings() async {
        let probe = ScriptedProbe(default: .notDetermined)
        let harness = makeHarness(probe)

        let first = await harness.center.request(.screenRecording)
        let second = await harness.center.request(.screenRecording)

        XCTAssertEqual(first, .denied)
        XCTAssertEqual(second, .denied)
        XCTAssertEqual(probe.requested, [.screenRecording])
        XCTAssertTrue(harness.defaults.bool(forKey: "otto.permissions.didPromptScreenRecording"))
        XCTAssertEqual(harness.opener.urls, [Permission.screenRecording.settingsURL].compactMap { $0 })
    }

    func testPromptFlagsFromAnEarlierLaunchMakeNotTrustedReadAsDenied() async {
        let probe = ScriptedProbe(default: .notDetermined)
        let fresh = makeHarness(probe)
        await fresh.center.refresh([.accessibility, .screenRecording])
        XCTAssertEqual(fresh.center.statuses[.accessibility], .notDetermined)
        XCTAssertEqual(fresh.center.statuses[.screenRecording], .notDetermined)

        let prompted = makeHarness(probe)
        prompted.defaults.set(true, forKey: "otto.permissions.didPromptAccessibility")
        prompted.defaults.set(true, forKey: "otto.permissions.didPromptScreenRecording")
        await prompted.center.refresh([.accessibility, .screenRecording])
        XCTAssertEqual(prompted.center.statuses[.accessibility], .denied)
        XCTAssertEqual(prompted.center.statuses[.screenRecording], .denied)
    }

    // MARK: - waitForGrant

    func testWaitForGrantReturnsTrueWhenTheGrantArrives() async {
        let probe = MutablePermissionProbe([:], default: .denied)
        let harness = makeHarness(probe)
        harness.center.openSystemSettings(for: .calendars)
        let wait = Task { await harness.center.waitForGrant(.calendars, timeout: .seconds(10)) }

        let checked = await eventually { harness.center.statuses[.calendars] == .denied }
        XCTAssertTrue(checked)
        XCTAssertEqual(harness.center.awaiting, .systemSettings(.calendars))

        probe.set(.calendars, .granted)
        let granted = await wait.value

        XCTAssertTrue(granted)
        XCTAssertNil(harness.center.awaiting)
        XCTAssertEqual(harness.center.status(.calendars), .granted)
        XCTAssertEqual(harness.grants.permissions, [.calendars])
    }

    func testWaitForGrantTimesOut() async {
        let probe = MutablePermissionProbe([:], default: .denied)
        let harness = makeHarness(probe)
        harness.center.openSystemSettings(for: .reminders)
        let clock = ContinuousClock()
        let start = clock.now

        let granted = await harness.center.waitForGrant(.reminders, timeout: .milliseconds(150))

        XCTAssertFalse(granted)
        XCTAssertGreaterThanOrEqual(clock.now - start, .milliseconds(150))
        XCTAssertLessThan(clock.now - start, .seconds(3))
        XCTAssertNil(harness.center.awaiting)
        XCTAssertTrue(harness.grants.permissions.isEmpty)
    }

    func testWaitForGrantStopsWhenCancelled() async {
        let probe = MutablePermissionProbe([:], default: .denied)
        let harness = makeHarness(probe, pollInterval: .seconds(30))
        harness.center.openSystemSettings(for: .microphone)
        let wait = Task { await harness.center.waitForGrant(.microphone, timeout: .seconds(60)) }

        let checked = await eventually { harness.center.statuses[.microphone] == .denied }
        XCTAssertTrue(checked)
        wait.cancel()
        let granted = await wait.value

        XCTAssertFalse(granted)
        XCTAssertNil(harness.center.awaiting)
    }

    func testWaitForGrantChecksAgainWhenOttoBecomesActive() async {
        let probe = MutablePermissionProbe([:], default: .denied)
        let harness = makeHarness(probe, pollInterval: .seconds(30))
        harness.center.openSystemSettings(for: .speechRecognition)
        let outcome = Outcome()
        let wait = Task {
            outcome.value = await harness.center.waitForGrant(.speechRecognition, timeout: .seconds(60))
        }
        defer { wait.cancel() }

        let checked = await eventually { harness.center.statuses[.speechRecognition] == .denied }
        XCTAssertTrue(checked)
        probe.set(.speechRecognition, .granted)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        let finished = await eventually(within: .seconds(3)) { outcome.value != nil }
        XCTAssertTrue(finished, "didBecomeActive should wake the wait long before the 30 s poll")
        XCTAssertEqual(outcome.value, true)
        XCTAssertNil(harness.center.awaiting)
    }

    func testSystemPromptAwaitingHandsOverToWaitForGrant() async {
        let probe = MutablePermissionProbe([:], default: .notDetermined)
        let harness = makeHarness(probe)
        _ = await harness.center.request(.accessibility)
        XCTAssertEqual(harness.center.awaiting, .systemPrompt(.accessibility))

        let wait = Task { await harness.center.waitForGrant(.accessibility, timeout: .seconds(10)) }
        let checked = await eventually { harness.center.statuses[.accessibility] == .denied }
        XCTAssertTrue(checked)
        XCTAssertEqual(harness.center.awaiting, .systemPrompt(.accessibility))

        probe.set(.accessibility, .granted)
        let granted = await wait.value
        XCTAssertTrue(granted)
        XCTAssertNil(harness.center.awaiting)
        XCTAssertEqual(harness.grants.permissions, [.accessibility])
    }

    func testUnattendedSettingsWaitEndsWhenTheUserComesBack() async {
        let harness = makeHarness(MutablePermissionProbe([:], default: .denied))
        harness.center.openSystemSettings(for: .notifications)
        XCTAssertEqual(harness.center.awaiting, .systemSettings(.notifications))

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        let cleared = await eventually { harness.center.awaiting == nil }
        XCTAssertTrue(cleared)
    }

    func testUnattendedSettingsWaitEndsWhenThePermissionIsGranted() async {
        let probe = MutablePermissionProbe([.calendars: .denied], default: .denied)
        let harness = makeHarness(probe)
        await harness.center.refresh([.calendars])
        harness.center.openSystemSettings(for: .calendars)

        probe.set(.calendars, .granted)
        await harness.center.refresh([.calendars])

        XCTAssertNil(harness.center.awaiting)
        XCTAssertEqual(harness.grants.permissions, [.calendars])
    }

    // MARK: - Screen Recording relaunch heuristic

    func testScreenRecordingNeedsRelaunchAfterTheUserReturnsFromSystemSettings() async {
        let probe = MutablePermissionProbe([:], default: .notDetermined)
        let harness = makeHarness(probe, pollInterval: .seconds(30))
        await harness.center.refresh([.screenRecording])
        XCTAssertEqual(harness.center.statuses[.screenRecording], .notDetermined)

        harness.center.openSystemSettings(for: .screenRecording)
        let outcome = Outcome()
        let wait = Task {
            outcome.value = await harness.center.waitForGrant(.screenRecording, timeout: .seconds(60))
        }
        defer { wait.cancel() }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(harness.center.awaiting, .systemSettings(.screenRecording))
        XCTAssertNotEqual(harness.center.statuses[.screenRecording], .needsRelaunch,
                          "Still in System Settings: nothing to relaunch for yet")

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        let finished = await eventually(within: .seconds(3)) { outcome.value != nil }
        XCTAssertTrue(finished)
        XCTAssertEqual(outcome.value, false)
        XCTAssertEqual(harness.center.statuses[.screenRecording], .needsRelaunch)
        XCTAssertNil(harness.center.awaiting)
        XCTAssertTrue(harness.grants.permissions.isEmpty)

        // Opening System Settings again starts a fresh visit.
        harness.center.openSystemSettings(for: .screenRecording)
        await harness.center.refresh([.screenRecording])
        XCTAssertNotEqual(harness.center.statuses[.screenRecording], .needsRelaunch)
    }

    func testOtherPermissionsNeverNeedARelaunch() async {
        let probe = MutablePermissionProbe([:], default: .denied)
        let harness = makeHarness(probe)
        harness.center.openSystemSettings(for: .microphone)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        _ = await eventually { harness.center.awaiting == nil }
        await harness.center.refresh([.microphone, .screenRecording])
        XCTAssertEqual(harness.center.statuses[.microphone], .denied)
        XCTAssertEqual(harness.center.statuses[.screenRecording], .denied)
    }

    // MARK: - didGrant

    func testDidGrantIsPostedOnEveryTransitionToGranted() async {
        let probe = MutablePermissionProbe([.reminders: .denied, .calendars: .granted], default: .denied)
        let harness = makeHarness(probe)

        // The first read is not a transition.
        await harness.center.refresh([.reminders, .calendars])
        XCTAssertTrue(harness.grants.permissions.isEmpty)

        probe.set(.reminders, .granted)
        await harness.center.refresh([.reminders])
        await harness.center.refresh([.reminders])
        XCTAssertEqual(harness.grants.permissions, [.reminders], "granted → granted posts nothing")

        probe.set(.reminders, .denied)
        await harness.center.refresh([.reminders])
        probe.set(.reminders, .granted)
        await harness.center.refresh([.reminders])
        XCTAssertEqual(harness.grants.permissions, [.reminders, .reminders])
    }

    // MARK: - Cache

    func testStatusServesTheCacheAndRefreshesItAfterTwoSeconds() async throws {
        let probe = MutablePermissionProbe([.calendars: .granted], default: .denied)
        let harness = makeHarness(probe)

        XCTAssertEqual(harness.center.status(.calendars), .notDetermined, "Never read: unknown until the read lands")
        let loaded = await eventually { harness.center.statuses[.calendars] == .granted }
        XCTAssertTrue(loaded)

        probe.set(.calendars, .denied)
        XCTAssertEqual(harness.center.status(.calendars), .granted)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(harness.center.status(.calendars), .granted, "Fresh entries are served from the cache")

        try await Task.sleep(for: .milliseconds(2_000))
        XCTAssertEqual(harness.center.status(.calendars), .granted, "A stale entry is returned, then re-read")
        let refreshed = await eventually { harness.center.statuses[.calendars] == .denied }
        XCTAssertTrue(refreshed)
    }

    // MARK: - Automation targets and grantedPermissions

    func testGrantedPermissionsListsSystemWideAndKnownAutomationTargets() async {
        let probe = MutablePermissionProbe([.accessibility: .granted, .calendars: .granted, music: .granted],
                                           default: .denied)
        let harness = makeHarness(probe)
        _ = await harness.center.request(music)
        await harness.center.refreshAll()

        XCTAssertEqual(harness.center.grantedPermissions(), [.accessibility, .calendars, music])
    }

    func testAutomationTargetsAreRememberedAcrossLaunches() async {
        let probe = MutablePermissionProbe([:], default: .notDetermined)
        let harness = makeHarness(probe)
        XCTAssertTrue(harness.center.knownAutomationTargets.isEmpty)

        _ = await harness.center.request(music)
        _ = await harness.center.request(.automation(bundleID: "com.apple.Music", appName: "Apple Music"))
        let spotify = Permission.automation(bundleID: "com.spotify.client", appName: "Spotify")
        _ = await harness.center.request(spotify)

        let renamedMusic = Permission.automation(bundleID: "com.apple.Music", appName: "Apple Music")
        XCTAssertEqual(harness.center.knownAutomationTargets, [renamedMusic, spotify])

        let relaunched = PermissionsCenter(probe: probe, defaults: harness.defaults, openURL: { _ in },
                                           pollInterval: .milliseconds(20), relauncher: RecordingRelauncher())
        XCTAssertEqual(relaunched.knownAutomationTargets, [renamedMusic, spotify])
        await relaunched.refreshAll()
        XCTAssertEqual(relaunched.statuses[spotify], .notDetermined)
    }

    func testUnreadableAutomationTargetsAreIgnored() {
        let defaults = TestDefaults.make(for: self)
        defaults.set(Data("not json".utf8), forKey: "otto.permissions.automationTargets")
        let center = PermissionsCenter(probe: StaticPermissionProbe([:], default: .denied), defaults: defaults,
                                       openURL: { _ in }, relauncher: RecordingRelauncher())
        XCTAssertTrue(center.knownAutomationTargets.isEmpty)
    }

    // MARK: - Relaunch

    func testRelaunchCallsTheInjectedRelauncher() {
        let relauncher = RecordingRelauncher()
        let harness = makeHarness(StaticPermissionProbe([:], default: .denied), relauncher: relauncher)

        harness.center.relaunch()

        XCTAssertEqual(relauncher.count, 1)
    }

    func testRelauncherWaitsForThisProcessThenOpensTheBundle() {
        let arguments = AppRelauncher.waiterArguments(pid: 4321, bundlePath: "/Applications/Otto Beta.app")

        XCTAssertEqual(arguments, [
            "-c",
            #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done; exec /usr/bin/open "$2""#,
            "sh",
            "4321",
            "/Applications/Otto Beta.app",
        ])
        XCTAssertFalse(arguments[1].contains("open -n"), "An Otto that is already running is only activated")
    }

    // MARK: - Reset

    func testResetSystemPermissionsRunsTccutilForOttoOnly() async {
        let harness = makeHarness(MutablePermissionProbe([:], default: .notDetermined))
        _ = await harness.center.request(.accessibility)
        XCTAssertTrue(harness.defaults.bool(forKey: "otto.permissions.didPromptAccessibility"))
        let runner = FakeProcessRunner()

        let reset = await harness.center.resetSystemPermissions(using: runner)

        XCTAssertTrue(reset)
        XCTAssertEqual(runner.invocations.map(\.executable.path), ["/usr/bin/tccutil"])
        XCTAssertEqual(runner.invocations.first?.arguments, ["reset", "All", "com.jalenedusei.otto"])
        XCTAssertFalse(harness.defaults.bool(forKey: "otto.permissions.didPromptAccessibility"))
        XCTAssertEqual(harness.center.statuses[.accessibility], .notDetermined, "The one-time prompt is available again")
    }

    func testResetSystemPermissionsReportsFailure() async {
        let harness = makeHarness(StaticPermissionProbe([:], default: .denied))
        let failing = FakeProcessRunner(defaultOutput: ProcessOutput(stdout: "", stderr: "tccutil: No such bundle",
                                                                     exitCode: 1, timedOut: false,
                                                                     duration: .milliseconds(3)))
        let timedOut = FakeProcessRunner(defaultOutput: ProcessOutput(stdout: "", stderr: "", exitCode: 0,
                                                                      timedOut: true, duration: .seconds(10)))
        let throwing = FakeProcessRunner(error: CocoaError(.executableNotLoadable))

        let failed = await harness.center.resetSystemPermissions(using: failing)
        let hung = await harness.center.resetSystemPermissions(using: timedOut)
        let broken = await harness.center.resetSystemPermissions(using: throwing)

        XCTAssertFalse(failed)
        XCTAssertFalse(hung)
        XCTAssertFalse(broken)
    }

    // MARK: - Probes

    func testStaticAndMutableProbes() async {
        let fixed = StaticPermissionProbe([.microphone: .granted], default: .restricted)
        let fixedMicrophone = await fixed.status(of: .microphone)
        let fixedCalendars = await fixed.request(.calendars)
        XCTAssertEqual(fixedMicrophone, .granted)
        XCTAssertEqual(fixedCalendars, .restricted)

        let mutable = MutablePermissionProbe([.microphone: .denied], default: .notDetermined)
        let before = await mutable.request(.microphone)
        mutable.set(.microphone, .granted)
        let after = await mutable.status(of: .microphone)
        let other = await mutable.status(of: .reminders)
        XCTAssertEqual(before, .denied)
        XCTAssertEqual(after, .granted)
        XCTAssertEqual(other, .notDetermined)
    }

    // MARK: - Harness

    private struct Harness {
        let center: PermissionsCenter
        let defaults: UserDefaults
        let opener: URLRecorder
        let grants: GrantRecorder
    }

    private func makeHarness(_ probe: PermissionProbe, pollInterval: Duration = .milliseconds(20),
                             relauncher: AppRelaunching = RecordingRelauncher()) -> Harness {
        let defaults = TestDefaults.make(for: self)
        let opener = URLRecorder()
        let grants = GrantRecorder()
        addTeardownBlock { grants.stop() }
        let center = PermissionsCenter(probe: probe, defaults: defaults, openURL: { opener.urls.append($0) },
                                       pollInterval: pollInterval, relauncher: relauncher)
        return Harness(center: center, defaults: defaults, opener: opener, grants: grants)
    }

    private func eventually(within timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

// MARK: - Fakes

@MainActor private final class URLRecorder {
    var urls: [URL] = []
}

@MainActor private final class Outcome {
    var value: Bool?
}

@MainActor private final class RecordingRelauncher: AppRelaunching {
    private(set) var count = 0
    nonisolated init() {}
    func relaunch() { count += 1 }
}

/// Collects PermissionEvents.didGrant from NotificationCenter.default until stopped.
private final class GrantRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [Permission] = []
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(forName: PermissionEvents.didGrant, object: nil,
                                                       queue: nil) { [weak self] note in
            guard let permission = PermissionEvents.permission(from: note) else { return }
            self?.lock.withLock { self?.received.append(permission) }
        }
    }

    var permissions: [Permission] { lock.withLock { received } }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

/// Statuses by permission; `request` records the call and either answers at once (from `requestResults`, else the
/// current status) or, when gated, suspends until `answer(_:_:)` plays the user's choice.
private final class ScriptedProbe: PermissionProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Permission: PermissionStatus]
    private let defaultStatus: PermissionStatus
    private let requestResults: [Permission: PermissionStatus]
    private let gated: Bool
    private var pending: [(Permission, CheckedContinuation<PermissionStatus, Never>)] = []
    private var recorded: [Permission] = []

    init(_ statuses: [Permission: PermissionStatus] = [:], default defaultStatus: PermissionStatus,
         requestResults: [Permission: PermissionStatus] = [:], gated: Bool = false) {
        self.statuses = statuses
        self.defaultStatus = defaultStatus
        self.requestResults = requestResults
        self.gated = gated
    }

    var requested: [Permission] { lock.withLock { recorded } }

    func status(of permission: Permission) async -> PermissionStatus {
        lock.withLock { statuses[permission] ?? defaultStatus }
    }

    func request(_ permission: Permission) async -> PermissionStatus {
        if gated {
            return await withCheckedContinuation { continuation in
                lock.withLock {
                    recorded.append(permission)
                    pending.append((permission, continuation))
                }
            }
        }
        return lock.withLock {
            recorded.append(permission)
            let result = requestResults[permission] ?? statuses[permission] ?? defaultStatus
            statuses[permission] = result
            return result
        }
    }

    func answer(_ permission: Permission, _ status: PermissionStatus) {
        let continuation: CheckedContinuation<PermissionStatus, Never>? = lock.withLock {
            statuses[permission] = status
            guard let index = pending.firstIndex(where: { $0.0 == permission }) else { return nil }
            return pending.remove(at: index).1
        }
        continuation?.resume(returning: status)
    }
}
