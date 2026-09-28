//
//  SparkleUpdater.swift
//  Otto
//
//  The paid build's updater (§14.11.1): Sparkle 2's standard controller, created stopped and started only by the live
//  graph, with gentle reminders so a scheduled update waits in Settings and the status menu instead of taking focus
//  from an accessory app. Sparkle keeps its own SU* preferences; this class mirrors them for SwiftUI.
//

#if OTTO_SPARKLE
import AppKit
import Foundation
import Observation
import os
import Sparkle

@MainActor @Observable final class SparkleUpdater: UpdaterControlling {
    /// The headers of every appcast, release-notes and download request. Pinning the language keeps the Mac's
    /// language list out of the request (§14.11.1, "What it sends").
    static let httpHeaders: [String: String] = ["Accept-Language": "en"]

    let source: UpdateSource = .sparkle
    let allowsUserSettings = true
    let canShowReleaseNotes = false

    /// Sparkle's automaticallyChecksForUpdates. Sparkle persists it under its own SU* defaults.
    var automaticallyChecks: Bool {
        didSet {
            guard engine.automaticallyChecksForUpdates != automaticallyChecks else { return }
            engine.automaticallyChecksForUpdates = automaticallyChecks
            refreshFromEngine()
        }
    }

    /// Sparkle's automaticallyDownloadsUpdates. Sparkle persists it under its own SU* defaults.
    var automaticallyDownloads: Bool {
        didSet {
            guard engine.automaticallyDownloadsUpdates != automaticallyDownloads else { return }
            engine.automaticallyDownloadsUpdates = automaticallyDownloads
            refreshFromEngine()
        }
    }

    /// Mirrors SPUUpdater.canCheckForUpdates (false until the updater starts and while a check runs).
    private(set) var canCheckNow: Bool
    /// Mirrors SPUUpdater.lastUpdateCheckDate.
    private(set) var lastCheck: Date?
    /// Set when Sparkle leaves a scheduled update to Otto (a gentle reminder); cleared once the user has seen it.
    private(set) var pendingUpdate: PendingUpdate?

    @ObservationIgnored let engine: any Engine
    @ObservationIgnored private let delegateProxy: DelegateProxy
    @ObservationIgnored private let activateApp: @MainActor () -> Void
    @ObservationIgnored private let infoDictionary: [String: Any]
    @ObservationIgnored private(set) var hasStarted = false

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Updates")

    /// The live updater: Sparkle's standard controller for the main bundle, not started.
    convenience init() {
        let proxy = DelegateProxy()
        self.init(engine: LiveEngine(delegate: proxy), delegateProxy: proxy, activateApp: { NSApp.activate() },
                  infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    /// Test seam: an engine standing in for SPUUpdater, an activation hook and the Info.plist values start() checks.
    convenience init(engine: any Engine, activateApp: @escaping @MainActor () -> Void,
                     infoDictionary: [String: Any]) {
        self.init(engine: engine, delegateProxy: DelegateProxy(), activateApp: activateApp,
                  infoDictionary: infoDictionary)
    }

    private init(engine: any Engine, delegateProxy: DelegateProxy, activateApp: @escaping @MainActor () -> Void,
                 infoDictionary: [String: Any]) {
        self.engine = engine
        self.delegateProxy = delegateProxy
        self.activateApp = activateApp
        self.infoDictionary = infoDictionary
        self.automaticallyChecks = engine.automaticallyChecksForUpdates
        self.automaticallyDownloads = engine.automaticallyDownloadsUpdates
        self.canCheckNow = engine.canCheckForUpdates
        self.lastCheck = engine.lastUpdateCheckDate
        self.pendingUpdate = nil
        delegateProxy.owner = self
        engine.observeChanges { [weak self] in
            self?.refreshFromEngine()
        }
    }

    /// The object Sparkle calls back: the updater and user-driver delegate (weakly held by Sparkle, owned here).
    var sparkleDelegate: any SPUUpdaterDelegate & SPUStandardUserDriverDelegate { delegateProxy }

    // MARK: UpdaterControlling

    /// Live graphs only. Pins the request headers, then starts Sparkle, which schedules its daily check. A Debug
    /// build whose feed or key is still a placeholder (§14.3) never starts, so Sparkle can't show its
    /// "failed to start" alert over a build that is already warning about it.
    func start() {
        guard !hasStarted else { return }
        if let problem = Self.configurationProblem(infoDictionary: infoDictionary) {
            Self.logger.error("Sparkle not started: \(problem, privacy: .public)")
            return
        }
        hasStarted = true
        engine.httpHeaders = Self.httpHeaders
        engine.startUpdater()
        refreshFromEngine()
        Self.logger.info("Sparkle started")
    }

    /// Brings Otto forward, then runs a user-initiated check in Sparkle's own window.
    func checkNow() {
        guard canCheckNow else {
            Self.logger.info("Check for updates ignored: Sparkle can't check right now")
            return
        }
        activateApp()
        engine.checkForUpdates()
    }

    /// A user-initiated check brings a gently deferred update back in Sparkle's window, in focus.
    func installPendingUpdate() {
        guard hasStarted else {
            Self.logger.info("Install ignored: Sparkle isn't running")
            return
        }
        activateApp()
        engine.checkForUpdates()
    }

    /// Sparkle shows release notes in its own update window; Otto has no separate view of them.
    func showReleaseNotes() {
        Self.logger.info("Release notes requested from the Sparkle build, which shows them in its update window")
    }

    // MARK: Gentle reminders (§14.11.1)

    /// Sparkle shows a scheduled update itself only when it can do so in immediate focus.
    func shouldSparkleShowScheduledUpdate(immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    /// Sparkle is about to show an update, or (handledBySparkle == false) leaves it to Otto.
    func sparkleWillHandleShowingUpdate(_ handledBySparkle: Bool, version: String) {
        guard !handledBySparkle else { return }
        pendingUpdate = PendingUpdate(version: version, releaseNotes: nil)
        Self.logger.info("Update \(version, privacy: .public) is waiting for the user")
    }

    /// The user looked at the update in Sparkle's window.
    func sparkleDidReceiveUserAttention() {
        pendingUpdate = nil
    }

    /// The update session is over (installed, skipped, dismissed or failed).
    func sparkleWillFinishUpdateSession() {
        pendingUpdate = nil
        refreshFromEngine()
    }

    // MARK: Configuration

    /// Why Sparkle must not start with these Info.plist values: SUFeedURL isn't an https URL, or it or
    /// SUPublicEDKey is missing, unexpanded or still a JALEN_MUST_SET placeholder. nil when both look configured
    /// (Sparkle validates the key itself).
    nonisolated static func configurationProblem(infoDictionary: [String: Any]) -> String? {
        func unusable(_ value: String) -> Bool {
            value.isEmpty || value.contains("JALEN_MUST_SET") || value.contains("$(")
        }
        guard let feed = infoDictionary["SUFeedURL"] as? String, !unusable(feed) else {
            return "SUFeedURL is missing or still a placeholder"
        }
        guard let url = URL(string: feed), url.scheme == "https", url.host?.isEmpty == false else {
            return "SUFeedURL is not an https URL"
        }
        guard let key = infoDictionary["SUPublicEDKey"] as? String, !unusable(key) else {
            return "SUPublicEDKey is missing or still a placeholder"
        }
        return nil
    }

    // MARK: Private

    private func refreshFromEngine() {
        let checks = engine.automaticallyChecksForUpdates
        if automaticallyChecks != checks { automaticallyChecks = checks }
        let downloads = engine.automaticallyDownloadsUpdates
        if automaticallyDownloads != downloads { automaticallyDownloads = downloads }
        let canCheck = engine.canCheckForUpdates
        if canCheckNow != canCheck { canCheckNow = canCheck }
        let checkedAt = engine.lastUpdateCheckDate
        if lastCheck != checkedAt { lastCheck = checkedAt }
    }
}

// MARK: - Engine

extension SparkleUpdater {
    /// The part of SPUUpdater that SparkleUpdater drives. LiveEngine is Sparkle; tests pass a recording fake, so no
    /// test starts Sparkle or writes its SU* preferences into the test host's defaults.
    @MainActor protocol Engine: AnyObject {
        var automaticallyChecksForUpdates: Bool { get set }
        var automaticallyDownloadsUpdates: Bool { get set }
        var canCheckForUpdates: Bool { get }
        var lastUpdateCheckDate: Date? { get }
        var httpHeaders: [String: String]? { get set }
        func startUpdater()
        func checkForUpdates()
        /// Calls `onChange` on the main actor after any of the four observed values changes.
        func observeChanges(_ onChange: @escaping @MainActor () -> Void)
    }

    /// Sparkle's standard controller, created with startingUpdater false. KVO on the updater feeds observeChanges.
    final class LiveEngine: Engine {
        let controller: SPUStandardUpdaterController
        private var observations: [NSKeyValueObservation] = []

        init(delegate: any SPUUpdaterDelegate & SPUStandardUserDriverDelegate) {
            controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate,
                                                      userDriverDelegate: delegate)
        }

        var automaticallyChecksForUpdates: Bool {
            get { controller.updater.automaticallyChecksForUpdates }
            set { controller.updater.automaticallyChecksForUpdates = newValue }
        }

        var automaticallyDownloadsUpdates: Bool {
            get { controller.updater.automaticallyDownloadsUpdates }
            set { controller.updater.automaticallyDownloadsUpdates = newValue }
        }

        var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

        var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

        var httpHeaders: [String: String]? {
            get { controller.updater.httpHeaders }
            set { controller.updater.httpHeaders = newValue }
        }

        func startUpdater() {
            controller.startUpdater()
        }

        func checkForUpdates() {
            controller.checkForUpdates(nil)
        }

        func observeChanges(_ onChange: @escaping @MainActor () -> Void) {
            let updater = controller.updater
            let notify: () -> Void = {
                Task { @MainActor in onChange() }
            }
            observations = [
                updater.observe(\.canCheckForUpdates) { _, _ in notify() },
                updater.observe(\.lastUpdateCheckDate) { _, _ in notify() },
                updater.observe(\.automaticallyChecksForUpdates) { _, _ in notify() },
                updater.observe(\.automaticallyDownloadsUpdates) { _, _ in notify() },
            ]
        }
    }
}

// MARK: - Delegate proxy

extension SparkleUpdater {
    /// Sparkle's updater and user-driver delegate. Sparkle holds it weakly; SparkleUpdater owns it, and it forwards
    /// to its owner on the main thread, where Sparkle calls it.
    fileprivate final class DelegateProxy: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
        weak var owner: SparkleUpdater?

        nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

        nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
            _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
        ) -> Bool {
            MainActor.assumeIsolated {
                owner?.shouldSparkleShowScheduledUpdate(immediateFocus: immediateFocus) ?? immediateFocus
            }
        }

        nonisolated func standardUserDriverWillHandleShowingUpdate(
            _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
        ) {
            let version = update.displayVersionString
            MainActor.assumeIsolated {
                owner?.sparkleWillHandleShowingUpdate(handleShowingUpdate, version: version)
            }
        }

        nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
            MainActor.assumeIsolated {
                owner?.sparkleDidReceiveUserAttention()
            }
        }

        nonisolated func standardUserDriverWillFinishUpdateSession() {
            MainActor.assumeIsolated {
                owner?.sparkleWillFinishUpdateSession()
            }
        }

        func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
            let error = error as NSError
            SparkleUpdater.logger.error(
                "Sparkle stopped an update: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
        }
    }
}
#endif
