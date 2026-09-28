//
//  SetappUpdater.swift
//  Otto
//
//  The Setapp build's updater (§14.11.2). Setapp installs updates; Otto only asks the framework whether one is
//  waiting (30 s after launch, every 6 hours and when Settings → General appears) so an app that never quits can
//  offer it. The question reads Setapp's local state and sends no request of Otto's own.
//

#if OTTO_SETAPP
import AppKit
import Foundation
import Observation
import os
import Setapp

@MainActor @Observable final class SetappUpdater: UpdaterControlling {
    static let firstCheckDelay: Duration = .seconds(30)
    static let checkInterval: Duration = .seconds(6 * 60 * 60)

    let source: UpdateSource = .setapp
    let allowsUserSettings = false
    let canShowReleaseNotes = true

    /// Setapp decides when to check; the setter is ignored.
    var automaticallyChecks: Bool {
        get { true }
        set { }
    }

    /// Setapp decides when to download; the setter is ignored.
    var automaticallyDownloads: Bool {
        get { false }
        set { }
    }

    /// false while a pending-update question is in flight.
    private(set) var canCheckNow: Bool
    /// When Setapp last answered the pending-update question.
    private(set) var lastCheck: Date?
    private(set) var pendingUpdate: PendingUpdate?

    @ObservationIgnored private var schedule: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Updates")

    init() {
        self.canCheckNow = true
        self.lastCheck = nil
        self.pendingUpdate = nil
    }

    // MARK: UpdaterControlling

    /// Live graphs only: asks Setapp 30 s after launch and then every 6 hours. Calling it again does nothing.
    func start() {
        guard schedule == nil else { return }
        schedule = Task { @MainActor [weak self] in
            var delay = SetappUpdater.firstCheckDelay
            while true {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let self else { return }
                self.requestPendingUpdate()
                delay = SetappUpdater.checkInterval
            }
        }
        Self.logger.info("Setapp update checks scheduled")
    }

    /// Asks Setapp now (Settings → General appearing).
    func checkNow() {
        requestPendingUpdate()
    }

    /// Confirms, then lets Setapp quit Otto, install the update and reopen it.
    func installPendingUpdate() {
        guard let pendingUpdate else {
            Self.logger.info("Install ignored: Setapp has no pending update")
            return
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Setapp has Otto \(pendingUpdate.version) ready."
        alert.informativeText = "Otto will quit, update and reopen."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Self.logger.info("Applying Setapp update \(pendingUpdate.version, privacy: .public)")
        SetappManager.shared.applyPendingUpdate { [weak self] result in
            guard case .failure(let error) = result else { return }
            let domain = (error as NSError).domain
            let code = (error as NSError).code
            Task { @MainActor [weak self] in
                SetappUpdater.logger.error(
                    "Setapp couldn't apply the update: \(domain, privacy: .public) \(code, privacy: .public)")
                self?.requestPendingUpdate()
            }
        }
    }

    /// Setapp's "What's New" window.
    func showReleaseNotes() {
        SetappBridge.showReleaseNotes()
    }

    // MARK: Private

    private func requestPendingUpdate() {
        guard canCheckNow else { return }
        canCheckNow = false
        SetappManager.shared.requestPendingUpdate { [weak self] result in
            let outcome: Result<PendingUpdate?, NSError> = result
                .map { update in update.map { PendingUpdate(version: $0.version, releaseNotes: $0.releaseNotes) } }
                .mapError { $0 as NSError }
            Task { @MainActor [weak self] in
                self?.finishRequest(outcome)
            }
        }
    }

    private func finishRequest(_ outcome: Result<PendingUpdate?, NSError>) {
        canCheckNow = true
        switch outcome {
        case .failure(let error):
            let domain = error.domain
            let code = error.code
            Self.logger.error(
                "Setapp couldn't report a pending update: \(domain, privacy: .public) \(code, privacy: .public)")
        case .success(let update):
            lastCheck = Date()
            guard pendingUpdate != update else { return }
            pendingUpdate = update
            if let update {
                Self.logger.info("Setapp has update \(update.version, privacy: .public) ready")
            }
        }
    }
}
#endif
