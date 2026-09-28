//
//  UpdateContracts.swift
//  Otto
//
//  The updater seam shared by the paid build (Sparkle) and the Setapp build (Setapp's pending-update API), and a
//  settable model for tests and snapshots (§14.11.3). The whole file is inside its flags, so the source build
//  compiles it to nothing.
//

#if OTTO_SPARKLE || OTTO_SETAPP
import Foundation
import Observation

enum UpdateSource: String, Sendable { case sparkle, setapp }

struct PendingUpdate: Equatable, Sendable {
    let version: String            // display version, "1.2.0"
    let releaseNotes: String?      // Setapp's Markdown notes; nil for Sparkle (its own window shows them)
}

@MainActor protocol UpdaterControlling: AnyObject {
    var source: UpdateSource { get }
    var automaticallyChecks: Bool { get set }      // Sparkle: automaticallyChecksForUpdates; Setapp: true, setter ignored
    var automaticallyDownloads: Bool { get set }   // Sparkle: automaticallyDownloadsUpdates; Setapp: false, ignored
    var allowsUserSettings: Bool { get }           // Sparkle true; Setapp false (the toggles are hidden)
    var canCheckNow: Bool { get }
    var lastCheck: Date? { get }
    var pendingUpdate: PendingUpdate? { get }
    var canShowReleaseNotes: Bool { get }          // Setapp true; Sparkle false
    func start()                                   // live graphs only
    func checkNow()                                // user-initiated
    func installPendingUpdate()                    // Sparkle: its window in focus; Setapp: confirm, then applyPendingUpdate
    func showReleaseNotes()
}

/// Tests and snapshots: settable properties; methods record calls ("start", "checkNow", "install", "releaseNotes").
@MainActor @Observable final class StaticUpdaterModel: UpdaterControlling {
    var source: UpdateSource
    var automaticallyChecks: Bool
    var automaticallyDownloads: Bool
    /// Starts as `source == .sparkle`.
    var allowsUserSettings: Bool
    var canCheckNow: Bool
    var lastCheck: Date?
    var pendingUpdate: PendingUpdate?
    /// Starts as `source == .setapp`.
    var canShowReleaseNotes: Bool
    private(set) var calls: [String]

    init(source: UpdateSource, pendingUpdate: PendingUpdate? = nil, lastCheck: Date? = nil,
         automaticallyChecks: Bool = true, automaticallyDownloads: Bool = true) {
        self.source = source
        self.pendingUpdate = pendingUpdate
        self.lastCheck = lastCheck
        self.automaticallyChecks = automaticallyChecks
        self.automaticallyDownloads = automaticallyDownloads
        self.allowsUserSettings = source == .sparkle
        self.canCheckNow = true
        self.canShowReleaseNotes = source == .setapp
        self.calls = []
    }

    func start() {
        calls.append("start")
    }

    func checkNow() {
        calls.append("checkNow")
    }

    func installPendingUpdate() {
        calls.append("install")
    }

    func showReleaseNotes() {
        calls.append("releaseNotes")
    }
}
#endif
