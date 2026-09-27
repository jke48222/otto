//
//  ScriptDemoServices.swift
//  Otto
//
//  Stand-ins for Shortcuts, osascript and the browser, used by --demo, --selftest and --snapshot. They
//  never start a process, send an Apple event or call NSWorkspace; they answer from fixed data and
//  remember what they were asked to do.
//

import Foundation

/// Five made-up shortcuts; running one returns a canned result after a short pause.
final class DemoShortcutsService: ShortcutsProviding, @unchecked Sendable {
    static let shortcuts: [ScriptShortcut] = [
        ScriptShortcut(name: "Log Water", identifier: "4F6B2C1E-8A3D-4B7E-9C21-5D0E6F7A8B91"),
        ScriptShortcut(name: "Morning Playlist", identifier: "7C2D9E4F-1B6A-4C8D-A3E5-0F9B2D7C6E14"),
        ScriptShortcut(name: "Open Roku Remote", identifier: "A1E3C5B7-9D2F-4A6C-8E0B-3D5F7A9C1E26"),
        ScriptShortcut(name: "Resize Images", identifier: "C8B4A2E6-3F1D-4E9A-B7C5-2A4E6C8B0D37"),
        ScriptShortcut(name: "Share ETA", identifier: "E5D3F1A9-7B2C-4D6E-9A8F-1C3E5B7D9F48"),
    ]

    static let folders = ["Home": ["Log Water", "Open Roku Remote"], "Photos": ["Resize Images"]]

    /// Output of each demo shortcut, by name.
    static let outputs: [String: String] = [
        "Resize Images": "Resized 12 images to 1600 px (saved to ~/Desktop/Screenshots/Resized).",
        "Log Water": "Logged 500 ml of water. Today: 1.5 l.",
        "Share ETA": "Sent your ETA (18 minutes) to Sam.",
    ]

    private let delay: Duration
    private let lock = NSLock()
    private var recordedRuns: [(shortcut: ScriptShortcut, input: String?)] = []

    init(delay: Duration = .milliseconds(400)) {
        self.delay = delay
    }

    /// Every run, in order.
    var runs: [(shortcut: ScriptShortcut, input: String?)] {
        lock.withLock { recordedRuns }
    }

    func list(folder: String?) async throws -> [ScriptShortcut] {
        guard let folder else { return Self.shortcuts }
        let names = Self.folders.first { $0.key.caseInsensitiveCompare(folder) == .orderedSame }?.value
        guard let names else {
            throw ToolError(code: .notFound,
                            modelMessage: "There's no Shortcuts folder named “\(DisplayText.sanitized(folder, maxLength: 200))”.",
                            userMessage: "No folder named “\(DisplayText.sanitized(folder, maxLength: 200))”")
        }
        return Self.shortcuts.filter { names.contains($0.name) }
    }

    func resolve(_ name: String) async throws -> ScriptShortcut {
        let lookup = ScriptShortcutMatching.lookup(name, in: Self.shortcuts)
        if case .found(let shortcut) = lookup { return shortcut }
        throw ScriptShortcutMatching.error(for: lookup, name: name)
            ?? ToolError(code: .failed, modelMessage: "Otto couldn't look up the shortcut.",
                         userMessage: "Couldn't look up the shortcut")
    }

    func run(_ shortcut: ScriptShortcut, input: String?, timeout: Duration) async throws -> ScriptShortcutRunResult {
        try await Task.sleep(for: delay)
        lock.withLock { recordedRuns.append((shortcut, input)) }
        let output = Self.outputs[shortcut.name]
        return ScriptShortcutRunResult(output: output, outputWasNonText: false, duration: delay)
    }

    func cachedLookup(_ name: String) -> ScriptShortcutLookup {
        ScriptShortcutMatching.lookup(name, in: Self.shortcuts)
    }

    func prefetch() {}
}

/// Answers the demo script (the names of your disks) and nothing else; no app ever counts as running.
final class DemoAppleScriptRunner: AppleScriptRunning, @unchecked Sendable {
    static let diskNames = "Macintosh HD, Backup"

    private let delay: Duration
    private let lock = NSLock()
    private var recordedSources: [String] = []

    init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }

    /// Every source it was asked to run, in order.
    var sources: [String] {
        lock.withLock { recordedSources }
    }

    func run(_ source: String, timeout: Duration) async throws -> ScriptRunResult {
        try await Task.sleep(for: delay)
        lock.withLock { recordedSources.append(source) }
        let output = source.range(of: "every disk", options: .caseInsensitive) != nil ? Self.diskNames : ""
        return ScriptRunResult(output: output, duration: delay)
    }

    func runningApp(for target: ScriptTarget) -> ScriptRunningApp? { nil }

    func automationConsentPending(bundleID: String) -> Bool { false }
}

/// Records the links it was asked to open and reports success.
final class DemoURLOpener: URLOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    init() {}

    /// Every URL it was asked to open, in order.
    var openedURLs: [URL] {
        lock.withLock { recorded }
    }

    func open(_ url: URL) async -> Bool {
        lock.withLock { recorded.append(url) }
        return true
    }
}
