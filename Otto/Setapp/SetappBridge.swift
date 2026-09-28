//
//  SetappBridge.swift
//  Otto
//
//  The Setapp build's two calls into the Setapp Framework outside updates (§14.11.2): the usage event Setapp requires
//  of menu bar apps, spaced at least five minutes apart, and Setapp's release notes window.
//

#if OTTO_SETAPP
import AppKit
import Foundation
import os
import Setapp

enum SetappBridge {
    @MainActor private static var throttle = UsageReportThrottle()
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Setapp")

    /// Reports a user interaction to Setapp when the throttle allows it (the first call, then ≥ 5 minutes apart).
    /// AppComposition calls it when the notch becomes engaged and when a message is sent.
    @MainActor static func reportInteraction(now: Date) {
        guard throttle.shouldReport(now: now) else { return }
        SetappManager.shared.reportUsageEvent(.userInteraction)
        logger.debug("Reported a user interaction to Setapp")
    }

    /// Brings Otto forward and opens Setapp's "What's New" window for this version.
    @MainActor static func showReleaseNotes() {
        NSApp.activate()
        SetappManager.shared.showReleaseNotesWindow()
    }
}
#endif
