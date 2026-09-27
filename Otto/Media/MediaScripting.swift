//
//  MediaScripting.swift
//  Otto
//
//  The only code that talks to Music and Spotify. The live version runs constant AppleScripts through
//  NSAppleScript on one private serial queue, each guarded so it can never launch a player and bounded by
//  a 2 s script timeout plus a 2.5 s caller-side deadline. The demo version is an in-memory player that
//  sends no Apple Events, for --demo, --selftest, snapshots and tests.
//

import AppKit
import Foundation
import os

/// The only code that talks to Music/Spotify. Live: constant AppleScripts via NSAppleScript on a private serial queue
/// (2 s script timeout, 2.5 s deadline). Demo: an in-memory player (no Apple Events) for --demo/--selftest/snapshots.
protocol MediaScripting: Sendable {
    func isRunning(_ player: MediaPlayer) -> Bool
    func consent(for player: MediaPlayer, askUser: Bool) async -> BrowserContext.AutomationConsent
    /// Runs one command (never launches unless allowLaunch); returns the resulting playback state when known.
    func run(_ command: MediaCommand, on player: MediaPlayer, allowLaunch: Bool) async throws -> PlaybackState?
    /// Position/track resync (only called when consent is .authorized).
    func nowPlaying(_ player: MediaPlayer) async -> NowPlayingItem?
}

/// Artwork that only a player's scripting dictionary can hand over (Music keeps it inside the track). An optional
/// extra on top of MediaScripting; the monitor asks for it only when Automation is already authorized.
protocol MediaArtworkScripting: Sendable {
    /// The current track's artwork bytes, or nil (not running, not authorized, no artwork, or unsupported player).
    func artworkData(_ player: MediaPlayer) async -> Data?
}

/// Why a player command didn't run.
enum MediaScriptingError: Error, Equatable, Sendable {
    /// The player isn't running (or quit while the script ran).
    case notRunning
    /// Automation for the player isn't decided yet; running the script would show the macOS dialog.
    case needsConsent
    /// The user turned Automation for the player off.
    case notPermitted
    /// The player isn't installed, so it can't be launched.
    case notInstalled
    /// The player didn't answer within the deadline.
    case timedOut
    /// Any other AppleScript or launch failure (the AppleScript error number when there is one).
    case failed(code: Int)
}

// MARK: - Live

struct LiveMediaScripting: MediaScripting, MediaArtworkScripting {
    /// `with timeout of 2 seconds` inside every script.
    static let scriptTimeoutSeconds = 2
    /// How long a caller waits for the script queue before giving up.
    static let deadline: TimeInterval = 2.5
    /// How long `play` with allowLaunch waits for a launched player to finish launching.
    static let launchWait: TimeInterval = 2
    /// What a guarded script returns when its player isn't running.
    static let notRunningResult = "otto:not-running"
    /// Largest artwork Otto accepts from Music's scripting dictionary.
    static let maxArtworkBytes = 16 * 1024 * 1024

    /// errOSAScriptError: the generic "the script failed" number.
    private static let scriptErrorCode = -1753
    private static let queue = DispatchQueue(label: "com.jalenedusei.otto.media-scripting", qos: .userInitiated)
    private static let scriptCache = ScriptCache()
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "NowPlaying")

    init() {}

    func isRunning(_ player: MediaPlayer) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue).contains { !$0.isTerminated }
    }

    /// With askUser, this may show the macOS Automation dialog and waits for the answer, off the script queue so a
    /// pending dialog never holds up other scripts. Without it, it never prompts.
    func consent(for player: MediaPlayer, askUser: Bool) async -> BrowserContext.AutomationConsent {
        guard isRunning(player) else { return .unavailable }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let status = Self.automationStatus(of: player, askUser: askUser)
                continuation.resume(returning: Self.consent(forStatus: status))
            }
        }
    }

    func run(_ command: MediaCommand, on player: MediaPlayer, allowLaunch: Bool) async throws -> PlaybackState? {
        if !isRunning(player) {
            guard allowLaunch else { throw MediaScriptingError.notRunning }
            try await launch(player)
        }
        let source = Self.commandScript(command, player: player)
        return try await Self.onScriptQueue {
            try Self.requireAuthorization(of: player)
            let descriptor = try Self.execute(source)
            return try Self.commandResult(from: descriptor)
        }
    }

    func nowPlaying(_ player: MediaPlayer) async -> NowPlayingItem? {
        guard isRunning(player) else { return nil }
        let source = Self.nowPlayingScript(player)
        do {
            return try await Self.onScriptQueue {
                try Self.requireAuthorization(of: player)
                let descriptor = try Self.execute(source)
                return Self.parseNowPlaying(descriptor, player: player, now: Date())
            }
        } catch {
            Self.logger.debug("Now Playing resync of \(player.displayName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func artworkData(_ player: MediaPlayer) async -> Data? {
        guard let source = Self.artworkScript(player), isRunning(player) else { return nil }
        do {
            return try await Self.onScriptQueue {
                try Self.requireAuthorization(of: player)
                let descriptor = try Self.execute(source)
                guard descriptor.descriptorType != typeNull, descriptor.descriptorType != typeType else { return nil }
                let data = descriptor.data
                guard !data.isEmpty, data.count <= Self.maxArtworkBytes else { return nil }
                return data
            }
        } catch {
            Self.logger.debug("Artwork lookup in \(player.displayName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Scripts (constant; internal for tests)

    /// The script for one command. Constant per player and command; the only interpolated value is a seek
    /// position, clamped and formatted with `formattedSeconds`.
    static func commandScript(_ command: MediaCommand, player: MediaPlayer) -> String {
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .playPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        case .seek(let seconds): verb = "set player position to \(formattedSeconds(seconds))"
        }
        return guarded(player, body: [verb, "return player state as text"])
    }

    /// Returns `{state, name, artist, album, duration (s), position (s), track id, artwork url}`, or `{state}` when
    /// nothing is loaded. Spotify reports durations in milliseconds; the script converts them to seconds.
    static func nowPlayingScript(_ player: MediaPlayer) -> String {
        let duration: String
        let trackID: String
        let artwork: String
        switch player {
        case .music:
            duration = "duration of trackRef"
            trackID = "persistent ID of trackRef"
            artwork = "\"\""
        case .spotify:
            duration = "(duration of trackRef) / 1000"
            trackID = "id of trackRef"
            artwork = "artwork url of trackRef"
        }
        return guarded(player, body: [
            "set playerState to player state as text",
            "if playerState is \"stopped\" then return {playerState}",
            "try",
            "    set trackRef to current track",
            "    return {playerState, name of trackRef, artist of trackRef, album of trackRef, \(duration), player position, \(trackID), \(artwork)}",
            "on error",
            "    return {playerState}",
            "end try",
        ])
    }

    /// Music only: the current track's first artwork as raw image data. nil for Spotify (its artwork is an address).
    static func artworkScript(_ player: MediaPlayer) -> String? {
        guard player == .music else { return nil }
        return guarded(player, body: [
            "if player state is stopped then return missing value",
            "try",
            "    return raw data of artwork 1 of current track",
            "on error",
            "    return missing value",
            "end try",
        ])
    }

    /// Seconds for a seek script: clamped to 0…NowPlayingItem.maxPlausibleSeconds (non-finite becomes 0), two
    /// decimals, always a "." separator (en_US_POSIX), whatever the user's locale.
    static func formattedSeconds(_ seconds: TimeInterval) -> String {
        let clamped = seconds.isFinite ? min(max(seconds, 0), NowPlayingItem.maxPlausibleSeconds) : 0
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), clamped)
    }

    /// Every script starts with `if application id … is running`, so `tell` can never launch a quit player, and
    /// bounds the Apple Event with `with timeout`.
    private static func guarded(_ player: MediaPlayer, body: [String]) -> String {
        let lines = body.map { "            " + $0 }.joined(separator: "\n")
        return """
        if application id "\(player.rawValue)" is running then
            with timeout of \(scriptTimeoutSeconds) seconds
                tell application id "\(player.rawValue)"
        \(lines)
                end tell
            end timeout
        end if
        return "\(notRunningResult)"
        """
    }

    // MARK: - Results (internal for tests)

    /// A command script's result: the player's state word, or the not-running marker.
    static func commandResult(from descriptor: NSAppleEventDescriptor) throws -> PlaybackState? {
        guard let word = string(from: descriptor) else { return nil }
        if word == notRunningResult { throw MediaScriptingError.notRunning }
        return PlaybackState(playerWord: word)
    }

    /// Parses `nowPlayingScript`'s list. Strings are sanitized like notification payloads; Spotify's artwork
    /// address is kept only when ArtworkPolicy allows it. nil when stopped, not running or unusable.
    static func parseNowPlaying(_ descriptor: NSAppleEventDescriptor, player: MediaPlayer, now: Date) -> NowPlayingItem? {
        guard descriptor.descriptorType == typeAEList, descriptor.numberOfItems >= 8,
              let stateWord = string(from: descriptor.atIndex(1)),
              let state = PlaybackState(playerWord: stateWord), state != .stopped
        else { return nil }
        let title = NowPlayingItem.text(string(from: descriptor.atIndex(2)))
        guard !title.isEmpty else { return nil }
        let artist = NowPlayingItem.text(string(from: descriptor.atIndex(3)))
        let album = NowPlayingItem.text(string(from: descriptor.atIndex(4)))
        let duration = NowPlayingItem.plausibleSeconds(number(from: descriptor.atIndex(5))).flatMap { $0 > 0 ? $0 : nil }
        var position = NowPlayingItem.plausibleSeconds(number(from: descriptor.atIndex(6)))
        if let known = position, let duration { position = min(known, duration) }
        let rawID = NowPlayingItem.text(string(from: descriptor.atIndex(7)))
        let trackID = rawID.isEmpty ? nil : rawID
        let artworkURL = string(from: descriptor.atIndex(8))
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { ArtworkPolicy.isAllowedSpotifyArtworkURL($0) ? $0 : nil }

        return NowPlayingItem(
            id: NowPlayingItem.makeID(player: player, trackID: trackID, title: title, artist: artist),
            player: player,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            position: position,
            positionDate: now,
            state: state,
            artworkURL: player == .spotify ? artworkURL : nil
        )
    }

    /// Maps an AppleScript or Apple Event error number.
    static func error(forCode code: Int) -> MediaScriptingError {
        switch code {
        case errAEEventNotPermitted: return .notPermitted
        case errAEEventWouldRequireUserConsent: return .needsConsent
        case errAETimeout: return .timedOut
        case procNotFound, connectionInvalid: return .notRunning
        default: return .failed(code: code)
        }
    }

    /// Maps an AEDeterminePermissionToAutomateTarget status.
    static func consent(forStatus status: OSStatus) -> BrowserContext.AutomationConsent {
        switch Int(status) {
        case Int(noErr): return .authorized
        case errAEEventWouldRequireUserConsent: return .wouldPrompt
        case errAEEventNotPermitted: return .denied
        default: return .unavailable
        }
    }

    // MARK: - Private

    /// Launches a player that isn't running, without bringing it forward, and waits (up to `launchWait`) for it to
    /// finish launching. Only `run(_:on:allowLaunch: true)` gets here.
    private func launch(_ player: MediaPlayer) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.rawValue) else {
            throw MediaScriptingError.notInstalled
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        let application: NSRunningApplication
        do {
            application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            Self.logger.error("Couldn't launch \(player.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw MediaScriptingError.failed(code: (error as NSError).code)
        }
        Self.logger.info("Launched \(player.displayName, privacy: .public) for a play command")
        let deadline = Date().addingTimeInterval(Self.launchWait)
        while !application.isFinishedLaunching, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Throws unless Apple Events to the player are already allowed, so a script never shows the macOS dialog
    /// (which would hold the script queue until the user answers). Script queue only.
    private static func requireAuthorization(of player: MediaPlayer) throws {
        let status = automationStatus(of: player, askUser: false)
        switch consent(forStatus: status) {
        case .authorized: return
        case .wouldPrompt: throw MediaScriptingError.needsConsent
        case .denied: throw MediaScriptingError.notPermitted
        case .unavailable:
            if Int(status) == procNotFound { throw MediaScriptingError.notRunning }
            throw MediaScriptingError.failed(code: Int(status))
        }
    }

    private static func automationStatus(of player: MediaPlayer, askUser: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: player.rawValue)
        return withExtendedLifetime(target) {
            guard let address = target.aeDesc else { return OSStatus(procNotFound) }
            return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, askUser)
        }
    }

    /// Runs `work` on the script queue; the caller stops waiting after `deadline` (timedOut) or on cancellation.
    /// Work whose caller already gave up is skipped when its turn on the queue comes.
    private static func onScriptQueue<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        let pending = PendingResult<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.install(continuation)
                queue.async {
                    guard !pending.isResolved else { return }
                    let result = autoreleasepool { Result(catching: work) }
                    pending.resolve(result)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) {
                    if pending.resolve(.failure(MediaScriptingError.timedOut)) {
                        logger.info("A player script missed its deadline")
                    }
                }
            }
        } onCancel: {
            pending.resolve(.failure(CancellationError()))
        }
    }

    /// Script queue only.
    private static func execute(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = scriptCache.script(for: source) else { throw MediaScriptingError.failed(code: scriptErrorCode) }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        // On failure the (nonnull-annotated) result is nil, so check the error before touching it.
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? scriptErrorCode
            throw error(forCode: code)
        }
        return descriptor
    }

    private static func string(from descriptor: NSAppleEventDescriptor?) -> String? {
        guard let descriptor else { return nil }
        switch descriptor.descriptorType {
        case typeNull, typeType:  // `missing value` comes back as a type descriptor
            return nil
        default:
            return descriptor.stringValue
        }
    }

    private static func number(from descriptor: NSAppleEventDescriptor?) -> Double? {
        guard let descriptor, descriptor.descriptorType != typeNull, descriptor.descriptorType != typeType,
              let coerced = descriptor.coerce(toDescriptorType: typeIEEE64BitFloatingPoint)
        else { return nil }
        return coerced.doubleValue
    }
}

extension LiveMediaScripting {
    /// Compiled scripts keyed by their (constant) source. Only touched on the script queue.
    private final class ScriptCache: @unchecked Sendable {
        private var scripts: [String: NSAppleScript] = [:]

        func script(for source: String) -> NSAppleScript? {
            if let cached = scripts[source] { return cached }
            guard let script = NSAppleScript(source: source) else { return nil }
            var errorInfo: NSDictionary?
            guard script.compileAndReturnError(&errorInfo) else {
                let code = (errorInfo?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
                LiveMediaScripting.logger.error("Couldn't compile a player script: error \(code, privacy: .public)")
                return nil
            }
            // Seek scripts differ by position; don't let them pile up.
            if scripts.count >= 64 { scripts.removeAll() }
            scripts[source] = script
            return script
        }
    }

    /// Delivers exactly one result to a continuation: whichever of the script, the deadline or cancellation wins.
    private final class PendingResult<Value: Sendable>: @unchecked Sendable {
        private enum State {
            case idle
            case waiting(CheckedContinuation<Value, Error>)
            case resolved(Result<Value, Error>)
        }

        private let lock = NSLock()
        private var state = State.idle

        var isResolved: Bool {
            lock.withLock {
                if case .resolved = state { return true }
                return false
            }
        }

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            lock.lock()
            if case .resolved(let result) = state {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            state = .waiting(continuation)
            lock.unlock()
        }

        /// True if this call delivered the result (false if something else won the race).
        @discardableResult
        func resolve(_ result: Result<Value, Error>) -> Bool {
            lock.lock()
            switch state {
            case .resolved:
                lock.unlock()
                return false
            case .idle:
                state = .resolved(result)
                lock.unlock()
                return true
            case .waiting(let continuation):
                state = .resolved(result)
                lock.unlock()
                continuation.resume(with: result)
                return true
            }
        }
    }
}

// MARK: - Demo

/// An in-memory player for --demo, --selftest, snapshots and tests. Sends no Apple Events, launches nothing and
/// never returns an artwork address, so nothing reaches the network. The seeded item's player counts as running.
struct DemoMediaScripting: MediaScripting {
    private let player: DemoPlayer

    init(item: NowPlayingItem? = nil) {
        player = DemoPlayer(item: item)
    }

    func isRunning(_ player: MediaPlayer) -> Bool {
        self.player.isRunning(player)
    }

    func consent(for player: MediaPlayer, askUser: Bool) async -> BrowserContext.AutomationConsent {
        self.player.isRunning(player) ? .authorized : .unavailable
    }

    func run(_ command: MediaCommand, on player: MediaPlayer, allowLaunch: Bool) async throws -> PlaybackState? {
        try self.player.run(command, on: player, allowLaunch: allowLaunch, now: Date())
    }

    func nowPlaying(_ player: MediaPlayer) async -> NowPlayingItem? {
        self.player.item(for: player, now: Date())
    }
}

extension DemoMediaScripting {
    /// The demo player's state, shared by copies of the struct.
    private final class DemoPlayer: @unchecked Sendable {
        private static let tracks: [(title: String, artist: String, album: String, duration: TimeInterval)] = [
            ("Low Tide", "Marlow Vey", "Demo Tapes", 214),
            ("Glass Hours", "Marlow Vey", "Demo Tapes", 187),
            ("Northbound", "Marlow Vey", "Demo Tapes", 243),
        ]

        private let lock = NSLock()
        private var running: Set<MediaPlayer>
        private var current: NowPlayingItem?
        private var trackIndex = 0

        init(item: NowPlayingItem?) {
            var seeded = item
            seeded?.artworkURL = nil
            current = seeded
            running = item.map { [$0.player] } ?? []
        }

        func isRunning(_ player: MediaPlayer) -> Bool {
            lock.withLock { running.contains(player) }
        }

        func item(for player: MediaPlayer, now: Date) -> NowPlayingItem? {
            lock.withLock {
                guard running.contains(player), var item = current, item.player == player else { return nil }
                item.position = item.elapsed(at: now)
                item.positionDate = now
                return item
            }
        }

        func run(_ command: MediaCommand, on player: MediaPlayer, allowLaunch: Bool, now: Date) throws -> PlaybackState? {
            try lock.withLock {
                if !running.contains(player) {
                    guard allowLaunch else { throw MediaScriptingError.notRunning }
                    running.insert(player)
                }
                if current?.player != player {
                    trackIndex = 0
                    current = Self.track(at: trackIndex, player: player, state: .paused, now: now)
                }
                guard var item = current else { return nil }
                item.position = item.elapsed(at: now)
                item.positionDate = now
                switch command {
                case .play:
                    item.state = .playing
                case .pause:
                    item.state = .paused
                case .playPause:
                    item.state = item.state == .playing ? .paused : .playing
                case .next, .previous:
                    let step = command == .next ? 1 : Self.tracks.count - 1
                    trackIndex = (trackIndex + step) % Self.tracks.count
                    item = Self.track(at: trackIndex, player: player, state: item.state == .stopped ? .playing : item.state,
                                      now: now)
                case .seek(let seconds):
                    let upper = item.duration ?? NowPlayingItem.maxPlausibleSeconds
                    item.position = seconds.isFinite ? min(max(seconds, 0), upper) : 0
                }
                current = item
                return item.state
            }
        }

        private static func track(at index: Int, player: MediaPlayer, state: PlaybackState, now: Date) -> NowPlayingItem {
            let track = tracks[index % tracks.count]
            return NowPlayingItem(
                id: NowPlayingItem.makeID(player: player, trackID: "demo-\(index)", title: track.title, artist: track.artist),
                player: player, title: track.title, artist: track.artist, album: track.album,
                duration: track.duration, position: 0, positionDate: now, state: state, artworkURL: nil
            )
        }
    }
}
