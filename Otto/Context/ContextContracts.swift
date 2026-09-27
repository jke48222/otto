//
//  ContextContracts.swift
//  Otto
//
//  A value snapshot of another running app (where a selection, a window or a paste belongs), the ways an
//  answer can be put back into it, and the entry points the macOS Services menu calls.
//

import AppKit
import Foundation

/// Value snapshot of a running app (never Otto itself).
struct AppRef: Hashable, Sendable {
    let pid: pid_t; let bundleID: String?; let name: String; let bundleURL: URL?

    /// Longest app name kept for display.
    private static let maxNameLength = 80

    /// nil for Otto itself and for an app with no name, bundle identifier or bundle URL to show.
    init?(_ app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let fallbackName = app.bundleURL?.deletingPathExtension().lastPathComponent ?? app.bundleIdentifier
        guard let rawName = app.localizedName ?? fallbackName else { return nil }
        let name = DisplayText.sanitized(rawName, maxLength: Self.maxNameLength)
        guard !name.isEmpty else { return nil }
        self.init(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: name, bundleURL: app.bundleURL)
    }

    init(pid: pid_t, bundleID: String?, name: String, bundleURL: URL? = nil) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.bundleURL = bundleURL
    }

    /// The live app, when this process is still the same app (a reused pid with another bundle id is not).
    @MainActor var runningApplication: NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        if let bundleID, app.bundleIdentifier != bundleID { return nil }
        return app
    }

    @MainActor var isRunning: Bool {
        guard let app = runningApplication else { return false }
        return !app.isTerminated
    }

    @MainActor var icon: NSImage? {
        if let icon = runningApplication?.icon { return icon }
        guard let bundleURL else { return nil }
        return NSWorkspace.shared.icon(forFile: bundleURL.path)
    }
}

enum InsertMode: String, Equatable, Sendable { case paste, replaceSelection, pastePlain }

/// NotchViewModel conforms; ServicesProvider calls it.
@MainActor protocol ServicesHandling: AnyObject {
    func askAbout(serviceText: String, app: AppRef?) async
    func askAbout(fileURLs: [URL], app: AppRef?)
    func addToShelf(fileURLs: [URL], openShelf: Bool)
}
