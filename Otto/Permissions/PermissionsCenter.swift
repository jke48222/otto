//
//  PermissionsCenter.swift
//  Otto
//
//  The only code that asks macOS about Otto's privacy permissions (TCC). It caches statuses, shows the
//  system prompt when one can be shown, opens the right System Settings pane otherwise, waits for a grant,
//  and tells the rest of the app what it is waiting on so the open notch can move out of the way.
//

import AppKit
import EventKit
import Foundation
import Observation
import os

/// Reads and requests one permission. The live probe calls the system; tests and self-test inject fakes.
protocol PermissionProbe: Sendable {
    func status(of permission: Permission) async -> PermissionStatus
    func request(_ permission: Permission) async -> PermissionStatus
}

@MainActor @Observable final class PermissionsCenter: PermissionProviding {
    private(set) var statuses: [Permission: PermissionStatus]
    private(set) var awaiting: PermissionWait?
    /// Automation targets Otto has asked about (Privacy pane lists them). Key otto.permissions.automationTargets.
    private(set) var knownAutomationTargets: [Permission]

    var isAwaitingUser: Bool { awaiting != nil }

    // MARK: Keys and limits

    private static let didPromptAccessibilityKey = "otto.permissions.didPromptAccessibility"
    private static let didPromptScreenRecordingKey = "otto.permissions.didPromptScreenRecording"
    private static let automationTargetsKey = "otto.permissions.automationTargets"
    /// A cached status older than this is re-read in the background the next time someone asks for it.
    private static let cacheLifetime: Duration = .seconds(2)
    /// The longest `waitForGrant` runs, whatever the caller passes.
    private static func maximumWait(for permission: Permission) -> Duration {
        switch permission {
        case .accessibility, .screenRecording: return .seconds(180)
        default: return .seconds(120)
        }
    }

    // MARK: Private state

    @ObservationIgnored private let probe: PermissionProbe
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let relauncher: AppRelaunching
    @ObservationIgnored private let clock = ContinuousClock()

    @ObservationIgnored private var checkedAt: [Permission: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var scheduledRefreshes: Set<Permission> = []
    /// waitForGrant calls in flight, per permission.
    @ObservationIgnored private var activeWaiters: [Permission: Int] = [:]
    /// Wakes every running waitForGrant early (Otto became active, System Settings closed).
    @ObservationIgnored private var wakeups: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// Bumped whenever `awaiting` changes hands, so a stale cleanup never clears a newer wait.
    @ObservationIgnored private var waitGeneration = 0
    /// Clears a wait nobody is polling for (a Settings row's "Open", a prompt with no follow-up wait).
    @ObservationIgnored private var unattendedExpiry: Task<Void, Never>?
    /// The permission whose blocking system prompt is on screen right now (its request call hasn't returned).
    @ObservationIgnored private var promptInFlight: Permission?
    /// Screen Recording relaunch heuristic, this launch only: Otto asked (prompt or Settings) and the user came back.
    @ObservationIgnored private var askedForScreenRecording = false
    @ObservationIgnored private var returnedAfterScreenRecordingAsk = false
    @ObservationIgnored private var observers: ObserverBag?

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Permissions")
    private nonisolated static let systemSettingsBundleID = "com.apple.systempreferences"
    private static let ottoBundleID = "com.jalenedusei.otto"

    /// No `shared`: AppComposition.live() creates the one instance and injects it everywhere. Inert and test graphs
    /// build their own with StaticPermissionProbe and a no-op opener.
    init(probe: PermissionProbe = SystemPermissionProbe(),
         defaults: UserDefaults = .standard,
         openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
         pollInterval: Duration = .seconds(1),
         relauncher: AppRelaunching = AppRelauncher()) {
        self.probe = probe
        self.defaults = defaults
        self.openURL = openURL
        self.pollInterval = pollInterval > .zero ? pollInterval : .milliseconds(100)
        self.relauncher = relauncher
        self.statuses = [:]
        self.awaiting = nil
        self.knownAutomationTargets = Self.loadAutomationTargets(from: defaults)
        self.observers = ObserverBag(center: self)
    }

    // MARK: - PermissionProviding

    /// Cached; a missing or stale (older than 2 s) entry is re-read in the background. A permission that was never
    /// read reports `.notDetermined` until that read lands; `await refresh([p])` first when the answer must be fresh.
    func status(_ permission: Permission) -> PermissionStatus {
        if isStale(permission) { scheduleRefresh(of: permission) }
        return statuses[permission] ?? .notDetermined
    }

    func refresh(_ permissions: [Permission]) async {
        var unique: [Permission] = []
        for permission in permissions where !unique.contains(permission) { unique.append(permission) }
        guard !unique.isEmpty else { return }

        let probe = self.probe
        let results = await withTaskGroup(of: (Permission, PermissionStatus).self) { group in
            for permission in unique {
                group.addTask { (permission, await probe.status(of: permission)) }
            }
            var collected: [Permission: PermissionStatus] = [:]
            for await (permission, status) in group { collected[permission] = status }
            return collected
        }
        for permission in unique {
            guard let raw = results[permission] else { continue }
            apply(adjusted(raw, for: permission), to: permission)
        }
    }

    /// Shows the system prompt when one can be shown (else opens System Settings). Marks didPrompt flags.
    /// `awaiting == .systemPrompt(p)` for as long as the prompt is up. The Accessibility and Screen Recording prompts
    /// stay on screen after the call returns, so for those `awaiting` stays set until a `waitForGrant(p)` ends, the
    /// user comes back to Otto or System Settings closes, or the permission is granted.
    @discardableResult func request(_ permission: Permission) async -> PermissionStatus {
        if case .automation = permission { rememberAutomationTarget(permission) }
        await refresh([permission])
        let current = statuses[permission] ?? .notDetermined

        switch current {
        case .granted, .restricted, .unavailable, .needsRelaunch:
            Self.logger.info("Skipped a request for \(Self.logName(permission), privacy: .public): \(String(describing: current), privacy: .public)")
            return current
        case .notDetermined, .denied, .limited:
            break
        }

        guard Self.canPromptInApp(permission, status: current) else {
            openSystemSettings(for: permission)
            return current
        }

        markPrompted(permission)
        let generation = beginOutsideWait(.systemPrompt(permission))
        Self.logger.info("Showing the system prompt for \(Self.logName(permission), privacy: .public)")
        promptInFlight = permission
        let raw = await probe.request(permission)
        promptInFlight = nil
        let result = adjusted(raw, for: permission)
        apply(result, to: permission)

        if Self.promptOutlivesRequest(permission), result != .granted {
            leaveUnattendedIfNeeded(generation: generation, permission: permission)
        } else {
            endOutsideWait(generation: generation)
        }
        return result
    }

    func openSystemSettings(for permission: Permission) {
        if permission == .screenRecording {
            askedForScreenRecording = true
            returnedAfterScreenRecordingAsk = false
        }
        if case .automation = permission { rememberAutomationTarget(permission) }
        let generation = beginOutsideWait(.systemSettings(permission))
        leaveUnattendedIfNeeded(generation: generation, permission: permission)
        guard let url = permission.settingsURL else {
            Self.logger.error("No System Settings link for \(Self.logName(permission), privacy: .public)")
            return
        }
        Self.logger.info("Opening System Settings for \(Self.logName(permission), privacy: .public)")
        openURL(url)
    }

    /// Polls every `pollInterval` (and whenever Otto becomes active or System Settings closes) until granted, timeout
    /// (capped at `maximumWait(for:)`) or cancellation; then clears `awaiting` if it belongs to this permission.
    /// A Screen Recording wait also ends (false) when the relaunch heuristic fires: that grant can't show up until
    /// Otto reopens.
    func waitForGrant(_ permission: Permission, timeout: Duration) async -> Bool {
        let deadline = clock.now + min(timeout, Self.maximumWait(for: permission))
        activeWaiters[permission, default: 0] += 1
        if let awaiting, Self.permission(of: awaiting) == permission { cancelUnattendedExpiry() }

        let (ticks, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let wakeupID = UUID()
        wakeups[wakeupID] = continuation
        let interval = pollInterval
        let clock = self.clock
        let ticker = Task {
            while !Task.isCancelled {
                let remaining = deadline - clock.now
                guard remaining > .zero else {
                    continuation.yield()
                    return
                }
                try? await Task.sleep(for: min(interval, remaining))
                continuation.yield()
            }
        }
        defer {
            ticker.cancel()
            continuation.finish()
            wakeups[wakeupID] = nil
            finishWaiter(for: permission)
        }

        Self.logger.info("Waiting for \(Self.logName(permission), privacy: .public)")
        if let outcome = await checkWait(permission, deadline: deadline) { return outcome }
        for await _ in ticks {
            if let outcome = await checkWait(permission, deadline: deadline) { return outcome }
        }
        Self.logger.info("Stopped waiting for \(Self.logName(permission), privacy: .public): cancelled")
        return false
    }

    func grantedPermissions() -> [Permission] {
        (Permission.systemWide + knownAutomationTargets).filter { status($0) == .granted }
    }

    // MARK: - Center

    /// systemWide + knownAutomationTargets.
    func refreshAll() async {
        await refresh(Permission.systemWide + knownAutomationTargets)
    }

    func relaunch() {
        Self.logger.info("Relaunching Otto")
        relauncher.relaunch()
    }

    /// Resets TCC for Otto only: /usr/bin/tccutil reset All com.jalenedusei.otto (via injected ProcessRunning).
    /// On success the "prompted once" flags are cleared too, since macOS will show those prompts again.
    func resetSystemPermissions(using runner: ProcessRunning) async -> Bool {
        let executable = URL(fileURLWithPath: "/usr/bin/tccutil")
        do {
            let output = try await runner.run(executable, arguments: ["reset", "All", Self.ottoBundleID], stdin: nil,
                                              timeout: .seconds(10), outputLimit: 16_384)
            guard output.exitCode == 0, !output.timedOut else {
                Self.logger.error("tccutil reset failed with exit code \(output.exitCode, privacy: .public), timed out \(output.timedOut, privacy: .public)")
                return false
            }
        } catch {
            Self.logger.error("tccutil reset could not run: \(String(describing: error), privacy: .public)")
            return false
        }
        defaults.removeObject(forKey: Self.didPromptAccessibilityKey)
        defaults.removeObject(forKey: Self.didPromptScreenRecordingKey)
        askedForScreenRecording = false
        returnedAfterScreenRecordingAsk = false
        Self.logger.info("Reset Otto's macOS permissions")
        await refreshAll()
        return true
    }

    nonisolated static func status(fromEventKit status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .fullAccess: return .granted
        case .writeOnly: return .limited
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unavailable
        }
    }

    /// AEDeterminePermissionToAutomateTarget results: noErr → granted, −1744 (errAEEventWouldRequireUserConsent)
    /// → notDetermined, −1743 (errAEEventNotPermitted) → denied, −600 (procNotFound) → unavailable; anything
    /// else means the check failed → unavailable.
    nonisolated static func status(fromAppleEventResult status: OSStatus) -> PermissionStatus {
        switch status {
        case OSStatus(noErr): return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .unavailable
        default: return .unavailable
        }
    }

    // MARK: - Status bookkeeping

    private func isStale(_ permission: Permission) -> Bool {
        guard let checked = checkedAt[permission] else { return true }
        return clock.now - checked > Self.cacheLifetime
    }

    private func scheduleRefresh(of permission: Permission) {
        guard !scheduledRefreshes.contains(permission) else { return }
        scheduledRefreshes.insert(permission)
        Task { [weak self] in
            await self?.refresh([permission])
            self?.scheduledRefreshes.remove(permission)
        }
    }

    /// Applies what only the center knows: whether the one-time Accessibility / Screen Recording prompt was already
    /// used (then "not trusted" means denied), and the Screen Recording relaunch heuristic.
    private func adjusted(_ status: PermissionStatus, for permission: Permission) -> PermissionStatus {
        switch permission {
        case .accessibility:
            if status == .notDetermined, defaults.bool(forKey: Self.didPromptAccessibilityKey) { return .denied }
            return status
        case .screenRecording:
            switch status {
            case .granted, .restricted, .needsRelaunch:
                return status
            case .notDetermined, .denied, .limited, .unavailable:
                if askedForScreenRecording, returnedAfterScreenRecordingAsk { return .needsRelaunch }
                if status == .notDetermined, defaults.bool(forKey: Self.didPromptScreenRecordingKey) { return .denied }
                return status
            }
        default:
            return status
        }
    }

    private func apply(_ status: PermissionStatus, to permission: Permission) {
        let previous = statuses[permission]
        checkedAt[permission] = clock.now
        if previous != status { statuses[permission] = status }

        if case .automation = permission, status == .granted || status == .denied {
            rememberAutomationTarget(permission)
        }
        guard status == .granted else { return }
        if let previous, previous != .granted {
            Self.logger.info("\(Self.logName(permission), privacy: .public) is now granted")
            PermissionEvents.post(permission)
        }
        if let awaiting, Self.permission(of: awaiting) == permission, activeWaiters[permission, default: 0] == 0 {
            clearAwaiting()
        }
    }

    // MARK: - Prompting

    private static func canPromptInApp(_ permission: Permission, status: PermissionStatus) -> Bool {
        switch permission {
        case .accessibility, .screenRecording:
            // adjusted() already turned "not trusted" into .denied once the one-time prompt was used.
            return status == .notDetermined
        default:
            // A write-only calendar grant can still be upgraded to full access from the system prompt.
            return status == .notDetermined || status == .limited
        }
    }

    /// The Accessibility and Screen Recording APIs return at once while their alert stays on screen.
    private static func promptOutlivesRequest(_ permission: Permission) -> Bool {
        permission == .accessibility || permission == .screenRecording
    }

    private func markPrompted(_ permission: Permission) {
        switch permission {
        case .accessibility:
            defaults.set(true, forKey: Self.didPromptAccessibilityKey)
        case .screenRecording:
            defaults.set(true, forKey: Self.didPromptScreenRecordingKey)
            askedForScreenRecording = true
            returnedAfterScreenRecordingAsk = false
        default:
            break
        }
    }

    // MARK: - Waiting on system UI

    @discardableResult private func beginOutsideWait(_ wait: PermissionWait) -> Int {
        cancelUnattendedExpiry()
        waitGeneration += 1
        awaiting = wait
        return waitGeneration
    }

    private func endOutsideWait(generation: Int) {
        guard generation == waitGeneration else { return }
        clearAwaiting()
    }

    private func clearAwaiting() {
        cancelUnattendedExpiry()
        waitGeneration += 1
        if awaiting != nil { awaiting = nil }
    }

    private func cancelUnattendedExpiry() {
        unattendedExpiry?.cancel()
        unattendedExpiry = nil
    }

    /// When no waitForGrant is polling for `permission`, the wait still ends on its own after the longest wait.
    private func leaveUnattendedIfNeeded(generation: Int, permission: Permission) {
        guard activeWaiters[permission, default: 0] == 0 else { return }
        let limit = Self.maximumWait(for: permission)
        unattendedExpiry = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let self else { return }
            guard generation == self.waitGeneration, self.activeWaiters[permission, default: 0] == 0 else { return }
            Self.logger.info("Stopped waiting for \(Self.logName(permission), privacy: .public) after \(limit.timeInterval, privacy: .public) s")
            self.clearAwaiting()
        }
    }

    /// nil = keep waiting.
    private func checkWait(_ permission: Permission, deadline: ContinuousClock.Instant) async -> Bool? {
        guard !Task.isCancelled else { return false }
        await refresh([permission])
        switch statuses[permission] {
        case .granted?:
            Self.logger.info("Stopped waiting for \(Self.logName(permission), privacy: .public): granted")
            return true
        case .needsRelaunch?:
            Self.logger.info("Stopped waiting for \(Self.logName(permission), privacy: .public): needs a relaunch")
            return false
        default:
            break
        }
        if Task.isCancelled { return false }
        if clock.now >= deadline {
            Self.logger.info("Stopped waiting for \(Self.logName(permission), privacy: .public): timed out")
            return false
        }
        return nil
    }

    private func finishWaiter(for permission: Permission) {
        let remaining = max(activeWaiters[permission, default: 0] - 1, 0)
        activeWaiters[permission] = remaining == 0 ? nil : remaining
        guard remaining == 0, let awaiting, Self.permission(of: awaiting) == permission else { return }
        clearAwaiting()
    }

    // MARK: - System signals

    /// Otto became active, or System Settings went to the background or quit: the user is back.
    fileprivate func userReturned() {
        if askedForScreenRecording { returnedAfterScreenRecordingAsk = true }
        if let awaiting, activeWaiters[Self.permission(of: awaiting), default: 0] == 0,
           awaiting != promptInFlight.map(PermissionWait.systemPrompt) {
            clearAwaiting()
        }
        for continuation in wakeups.values { continuation.yield() }
        let cached = Array(statuses.keys)
        guard !cached.isEmpty else { return }
        Task { [weak self] in await self?.refresh(cached) }
    }

    /// The Accessibility / Screen Recording alert's "Open System Settings" button was used.
    fileprivate func systemSettingsActivated() {
        guard case .systemPrompt(let permission)? = awaiting, Self.promptOutlivesRequest(permission) else { return }
        awaiting = .systemSettings(permission)
    }

    // MARK: - Automation targets

    private func rememberAutomationTarget(_ permission: Permission) {
        guard case .automation(let bundleID, let appName) = permission else { return }
        var targets = knownAutomationTargets
        if let index = targets.firstIndex(where: { Self.bundleID(of: $0) == bundleID }) {
            guard targets[index] != permission else { return }
            targets[index] = permission
        } else {
            targets.append(permission)
        }
        knownAutomationTargets = targets
        do {
            defaults.set(try JSONEncoder().encode(targets), forKey: Self.automationTargetsKey)
            Self.logger.info("Remembered the automation target \(bundleID, privacy: .public) (\(appName, privacy: .public))")
        } catch {
            Self.logger.error("Could not save automation targets: \(String(describing: error), privacy: .public)")
        }
    }

    private static func loadAutomationTargets(from defaults: UserDefaults) -> [Permission] {
        guard let data = defaults.data(forKey: automationTargetsKey) else { return [] }
        do {
            return try JSONDecoder().decode([Permission].self, from: data).filter { bundleID(of: $0) != nil }
        } catch {
            logger.error("Ignored unreadable automation targets: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private static func bundleID(of permission: Permission) -> String? {
        if case .automation(let bundleID, _) = permission { return bundleID }
        return nil
    }

    private static func permission(of wait: PermissionWait) -> Permission {
        switch wait {
        case .systemPrompt(let permission), .systemSettings(let permission): return permission
        }
    }

    /// Names only (never user content): a bundle id for automation targets.
    private static func logName(_ permission: Permission) -> String {
        if case .automation(let bundleID, _) = permission { return "automation(\(bundleID))" }
        return permission.settingsPaneName
    }

    // MARK: - Observers

    /// Holds the notification observers and removes them when the center goes away.
    private final class ObserverBag {
        private var appTokens: [NSObjectProtocol] = []
        private var workspaceTokens: [NSObjectProtocol] = []

        @MainActor init(center: PermissionsCenter) {
            let app = NotificationCenter.default
            let workspace = NSWorkspace.shared.notificationCenter
            appTokens.append(app.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                             queue: nil) { [weak center] _ in
                Task { @MainActor in center?.userReturned() }
            })
            for name in [NSWorkspace.didDeactivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                workspaceTokens.append(workspace.addObserver(forName: name, object: nil, queue: nil) { [weak center] note in
                    guard Self.isSystemSettings(note) else { return }
                    Task { @MainActor in center?.userReturned() }
                })
            }
            workspaceTokens.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                         object: nil, queue: nil) { [weak center] note in
                guard Self.isSystemSettings(note) else { return }
                Task { @MainActor in center?.systemSettingsActivated() }
            })
        }

        deinit {
            for token in appTokens { NotificationCenter.default.removeObserver(token) }
            for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        }

        private static func isSystemSettings(_ notification: Notification) -> Bool {
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            return app?.bundleIdentifier == PermissionsCenter.systemSettingsBundleID
        }
    }
}
