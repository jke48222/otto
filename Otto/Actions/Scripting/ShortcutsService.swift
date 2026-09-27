//
//  ShortcutsService.swift
//  Otto
//
//  Lists and runs the user's shortcuts through the `/usr/bin/shortcuts` command-line tool. Listings are
//  cached for a minute so a shortcut's name can be matched to its identifier without starting a process
//  (the "Always allow" scope is the identifier, never the name).
//

import Foundation
import os

/// One shortcut from `shortcuts list --show-identifiers`.
struct ScriptShortcut: Equatable, Hashable, Sendable {
    let name: String
    /// The UUID the Shortcuts app assigns; stable across renames.
    let identifier: String
}

/// What a shortcut run produced.
struct ScriptShortcutRunResult: Equatable, Sendable {
    /// Text output, nil when there was none.
    let output: String?
    /// The shortcut produced something other than text (a file or image), which Otto doesn't read.
    let outputWasNonText: Bool
    let duration: Duration
}

/// A name looked up against a listing.
enum ScriptShortcutLookup: Equatable, Sendable {
    /// No fresh listing to look in.
    case unknown
    case found(ScriptShortcut)
    /// Up to five close names, best first.
    case notFound(suggestions: [String])
    /// Several shortcuts match without case; their names.
    case ambiguous([String])
}

/// How the Shortcuts tools reach the Shortcuts app. Tests and demo mode inject fakes.
protocol ShortcutsProviding: Sendable {
    /// All shortcuts, or the ones in `folder` (exact name, else a unique case-insensitive match).
    /// Throws `ToolError` (`not_found` for a missing folder, `failed`, `timeout`).
    func list(folder: String?) async throws -> [ScriptShortcut]
    /// Exact name first, then a unique case-insensitive match. Throws `ToolError` `not_found` (with suggestions)
    /// or `ambiguous`.
    func resolve(_ name: String) async throws -> ScriptShortcut
    /// Runs a resolved shortcut with optional text input. Throws `ToolError` or CancellationError.
    func run(_ shortcut: ScriptShortcut, input: String?, timeout: Duration) async throws -> ScriptShortcutRunResult
    /// Looks `name` up in the last listing of all shortcuts while it is fresh, without starting a process.
    func cachedLookup(_ name: String) -> ScriptShortcutLookup
    /// Refreshes the listing of all shortcuts in the background when it is stale.
    func prefetch()
}

/// Pure name matching and parsing shared by the live and demo services.
enum ScriptShortcutMatching {
    /// "Name (UUID)" per line; names may contain parentheses. Lines that don't match are ignored.
    static func parseList(_ stdout: String) -> [ScriptShortcut] {
        let pattern = #"^(.*) \(([0-9A-Fa-f-]{36})\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return stdout.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let idRange = Range(match.range(at: 2), in: line) else { return nil }
            let name = String(line[nameRange])
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return ScriptShortcut(name: name, identifier: String(line[idRange]).uppercased())
        }
    }

    /// Exact match; else a unique case-insensitive match (trimmed); else ambiguous or not found.
    static func lookup(_ name: String, in shortcuts: [ScriptShortcut]) -> ScriptShortcutLookup {
        let exact = shortcuts.filter { $0.name == name }
        if exact.count == 1 { return .found(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact.map(\.name)) }

        let wanted = normalized(name)
        let loose = shortcuts.filter { normalized($0.name) == wanted }
        if loose.count == 1 { return .found(loose[0]) }
        if loose.count > 1 { return .ambiguous(loose.map(\.name)) }
        return .notFound(suggestions: suggestions(for: name, in: shortcuts))
    }

    /// Up to five names: case-insensitive prefix matches first, then substring matches, each alphabetical.
    static func suggestions(for name: String, in shortcuts: [ScriptShortcut], limit: Int = 5) -> [String] {
        let wanted = normalized(name)
        guard !wanted.isEmpty else { return [] }
        let sorted = sortedNames(shortcuts.map(\.name))
        let prefix = sorted.filter { normalized($0).hasPrefix(wanted) }
        let substring = sorted.filter { !normalized($0).hasPrefix(wanted) && normalized($0).contains(wanted) }
        var result: [String] = []
        for candidate in prefix + substring where !result.contains(candidate) {
            result.append(candidate)
            if result.count == limit { break }
        }
        return result
    }

    /// Case-insensitive alphabetical order; names equal without case keep a fixed order (uppercase first).
    static func sortedNames(_ names: [String]) -> [String] {
        names.sorted { lhs, rhs in
            let order = lhs.localizedCaseInsensitiveCompare(rhs)
            return order == .orderedSame ? lhs < rhs : order == .orderedAscending
        }
    }

    /// The typed error for a lookup that didn't find exactly one shortcut.
    static func error(for lookup: ScriptShortcutLookup, name: String) -> ToolError? {
        let quoted = "“\(DisplayText.sanitized(name, maxLength: 200))”"
        switch lookup {
        case .unknown, .found:
            return nil
        case .notFound(let suggestions):
            let hint = suggestions.isEmpty
                ? "Call list_shortcuts to see the exact names."
                : "Similar names: " + suggestions.map { "“\($0)”" }.joined(separator: ", ") + "."
            return ToolError(code: .notFound, modelMessage: "There's no shortcut named \(quoted). \(hint)",
                             userMessage: "No shortcut named \(quoted)")
        case .ambiguous(let names):
            let list = names.map { "“\($0)”" }.joined(separator: ", ")
            return ToolError(code: .ambiguous,
                             modelMessage: "More than one shortcut matches \(quoted): \(list). Ask the user which one "
                                 + "to run and pass its exact name.",
                             userMessage: "More than one shortcut matches \(quoted)")
        }
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

actor ShortcutsService: ShortcutsProviding {
    static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")
    static let listTimeout: Duration = .seconds(10)
    static let defaultRunTimeout: Duration = .seconds(60)
    /// Listings are reused for this long.
    static let cacheLifetime: TimeInterval = 60
    /// stdout/stderr per process, and the output file read back after a run.
    static let outputLimit = 1_048_576

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Actions")

    private let runner: any ProcessRunning
    private let now: @Sendable () -> Date
    private let toolIsInstalled: @Sendable () -> Bool
    private let temporaryDirectory: URL
    private nonisolated let cache: Cache

    /// `temporaryDirectory` holds each run's private input/output folder (created 0700, removed after the run).
    init(runner: any ProcessRunning,
         now: @escaping @Sendable () -> Date = { Date() },
         toolIsInstalled: @escaping @Sendable () -> Bool = {
             FileManager.default.isExecutableFile(atPath: ShortcutsService.executable.path)
         },
         temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.runner = runner
        self.now = now
        self.toolIsInstalled = toolIsInstalled
        self.temporaryDirectory = temporaryDirectory
        cache = Cache(now: now)
    }

    // MARK: - ShortcutsProviding

    func list(folder: String?) async throws -> [ScriptShortcut] {
        guard let folder else { return try await allShortcuts() }
        let folders = try await listing(key: Cache.foldersKey, arguments: ["list", "--folders", "--show-identifiers"])
        switch ScriptShortcutMatching.lookup(folder, in: folders) {
        case .found(let match):
            return try await listing(key: "folder:" + match.identifier,
                                     arguments: ["list", "--show-identifiers", "--folder-name", match.identifier])
        case .unknown, .notFound, .ambiguous:
            let quoted = "“\(DisplayText.sanitized(folder, maxLength: 200))”"
            throw ToolError(code: .notFound, modelMessage: "There's no Shortcuts folder named \(quoted).",
                            userMessage: "No folder named \(quoted)")
        }
    }

    func resolve(_ name: String) async throws -> ScriptShortcut {
        let lookup = ScriptShortcutMatching.lookup(name, in: try await allShortcuts())
        if case .found(let shortcut) = lookup { return shortcut }
        throw ScriptShortcutMatching.error(for: lookup, name: name)
            ?? ToolError(code: .failed, modelMessage: "Otto couldn't look up the shortcut.",
                         userMessage: "Couldn't look up the shortcut")
    }

    func run(_ shortcut: ScriptShortcut, input: String?, timeout: Duration) async throws -> ScriptShortcutRunResult {
        try requireTool()
        let folder = try makeRunFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let outputURL = folder.appendingPathComponent("output.txt")
        var arguments = ["run", shortcut.identifier]
        if let input {
            let inputURL = folder.appendingPathComponent("input.txt")
            try writePrivately(Data(input.utf8), to: inputURL)
            arguments += ["--input-path", inputURL.path]
        }
        arguments += ["--output-path", outputURL.path, "--output-type", "public.plain-text"]

        let output = try await start(arguments: arguments, timeout: timeout)
        if output.timedOut {
            let seconds = Int(timeout.timeInterval.rounded())
            throw ToolError(code: .timeout,
                            modelMessage: "The shortcut didn't finish within \(seconds) seconds and was stopped.",
                            userMessage: "Stopped after \(seconds) s")
        }
        guard output.exitCode == 0 else {
            Self.logger.info("Shortcut run exited \(output.exitCode, privacy: .public)")
            let message = Self.firstLine(of: output.stderr) ?? "The shortcut failed (exit status \(output.exitCode))."
            throw ToolError(code: .failed, modelMessage: message,
                            userMessage: "Shortcut failed: \(DisplayText.sanitized(message, maxLength: 120))")
        }
        let (text, nonText) = Self.readOutput(at: outputURL)
        return ScriptShortcutRunResult(output: text, outputWasNonText: nonText, duration: output.duration)
    }

    nonisolated func cachedLookup(_ name: String) -> ScriptShortcutLookup {
        guard let shortcuts = cache.fresh(Cache.allKey) else { return .unknown }
        return ScriptShortcutMatching.lookup(name, in: shortcuts)
    }

    nonisolated func prefetch() {
        guard cache.beginRefreshIfStale(Cache.allKey) else { return }
        Task {
            _ = try? await self.allShortcuts()
            self.cache.endRefresh(Cache.allKey)
        }
    }

    // MARK: - Listing

    private func allShortcuts() async throws -> [ScriptShortcut] {
        try await listing(key: Cache.allKey, arguments: ["list", "--show-identifiers"])
    }

    private func listing(key: String, arguments: [String]) async throws -> [ScriptShortcut] {
        if let cached = cache.fresh(key) { return cached }
        try requireTool()
        let output = try await start(arguments: arguments, timeout: Self.listTimeout)
        if output.timedOut {
            throw ToolError(code: .timeout, modelMessage: "The Shortcuts app didn't list shortcuts within 10 seconds.",
                            userMessage: "Shortcuts didn't answer")
        }
        guard output.exitCode == 0 else {
            let message = Self.firstLine(of: output.stderr) ?? "Listing shortcuts failed (exit status \(output.exitCode))."
            throw ToolError(code: .failed, modelMessage: message, userMessage: "Couldn't list your shortcuts")
        }
        let shortcuts = ScriptShortcutMatching.parseList(output.stdout)
        cache.store(shortcuts, for: key)
        Self.logger.info("Listed \(shortcuts.count, privacy: .public) shortcuts")
        return shortcuts
    }

    // MARK: - Processes and files

    private func start(arguments: [String], timeout: Duration) async throws -> ProcessOutput {
        do {
            return try await runner.run(Self.executable, arguments: arguments, stdin: nil, timeout: timeout,
                                        outputLimit: Self.outputLimit)
        } catch let error as CancellationError {
            throw error
        } catch let error as ToolError {
            throw error
        } catch {
            Self.logger.error("shortcuts didn't start: \(String(describing: error), privacy: .public)")
            throw Self.toolMissing
        }
    }

    private func requireTool() throws {
        guard toolIsInstalled() else { throw Self.toolMissing }
    }

    private static let toolMissing = ToolError(code: .failed,
                                               modelMessage: "The Shortcuts command-line tool isn't available.",
                                               userMessage: "The Shortcuts tool isn't available")

    /// <temporaryDirectory>/otto-actions/<uuid>/, mode 0700.
    private func makeRunFolder() throws -> URL {
        let parent = temporaryDirectory.appendingPathComponent("otto-actions", isDirectory: true)
        let folder = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            Self.logger.error("Couldn't create the shortcut run folder: \(String(describing: error), privacy: .public)")
            throw ToolError(code: .failed, modelMessage: "Otto couldn't prepare the shortcut's input.",
                            userMessage: "Couldn't prepare the shortcut")
        }
        return folder
    }

    private func writePrivately(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ToolError(code: .failed, modelMessage: "Otto couldn't prepare the shortcut's input.",
                            userMessage: "Couldn't prepare the shortcut")
        }
    }

    /// Up to 1 MB of the output file. Text that isn't UTF-8 (or holds NUL bytes) counts as non-text output.
    static func readOutput(at url: URL) -> (text: String?, nonText: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, false) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: outputLimit), !data.isEmpty else { return (nil, false) }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return (nil, true) }
        let trimmed = AppleScriptRunner.trimmingTrailingNewlines(text)
        return (trimmed.isEmpty ? nil : trimmed, false)
    }

    private static func firstLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    // MARK: - Cache

    /// Lock-protected so `cachedLookup` can answer synchronously from outside the actor.
    private final class Cache: @unchecked Sendable {
        static let allKey = "all"
        static let foldersKey = "folders"

        private let lock = NSLock()
        private let now: @Sendable () -> Date
        private var entries: [String: (date: Date, shortcuts: [ScriptShortcut])] = [:]
        private var refreshing: Set<String> = []

        init(now: @escaping @Sendable () -> Date) {
            self.now = now
        }

        func fresh(_ key: String) -> [ScriptShortcut]? {
            lock.withLock {
                guard let entry = entries[key],
                      now().timeIntervalSince(entry.date) < ShortcutsService.cacheLifetime else { return nil }
                return entry.shortcuts
            }
        }

        func store(_ shortcuts: [ScriptShortcut], for key: String) {
            lock.withLock { entries[key] = (now(), shortcuts) }
        }

        /// True when the caller should refresh (stale and nobody else is refreshing).
        func beginRefreshIfStale(_ key: String) -> Bool {
            lock.withLock {
                if let entry = entries[key], now().timeIntervalSince(entry.date) < ShortcutsService.cacheLifetime {
                    return false
                }
                guard !refreshing.contains(key) else { return false }
                refreshing.insert(key)
                return true
            }
        }

        func endRefresh(_ key: String) {
            lock.withLock { _ = refreshing.remove(key) }
        }
    }
}
