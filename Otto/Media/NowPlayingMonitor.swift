//
//  NowPlayingMonitor.swift
//  Otto
//
//  What Music or Spotify is playing, for the Now Playing strip, the closed-notch media ears, the media keys
//  and the media_control tool. Track changes arrive as distributed notifications, which need no permission;
//  AppleScript fills in position and artwork only once Automation is already allowed, so watching never
//  prompts. Commands report `.needsConsent` instead of prompting, so the view model can explain first.
//

import AppKit
import Foundation
import Observation
import os

/// What happened to one transport command.
enum MediaCommandOutcome: Equatable, Sendable {
    /// Ran; the player's resulting state when it reported one.
    case done(PlaybackState?)
    /// Automation for the player isn't decided yet: explain, then ask macOS, then retry.
    case needsConsent(MediaPlayer)
    /// No player is running (and launching wasn't allowed).
    case notRunning
    /// The user turned Automation for the player off.
    case denied(MediaPlayer)
    /// Any other failure; the text is user-facing ("Spotify didn't respond.").
    case failed(String)
}

@MainActor @Observable final class NowPlayingMonitor {
    /// A paused item stays on screen this long after the pause.
    static let pausedLifetime: TimeInterval = 600
    /// How often a playing item's position is resynced while Automation is allowed.
    static let resyncInterval: Duration = .seconds(15)

    /// The most recent playing item wins; a paused one is kept for `pausedLifetime`. nil while "Show what's
    /// playing" is off.
    private(set) var item: NowPlayingItem?
    /// Artwork for `item`, at most ArtworkPolicy.maxPixelSize on its longest side.
    private(set) var artwork: NSImage?
    /// Last known Automation consent per player (never obtained by prompting).
    private(set) var consent: [MediaPlayer: BrowserContext.AutomationConsent]
    /// Caption for the strip after a failed control ("Otto isn't allowed to control Spotify."); nil after a success.
    private(set) var lastControlError: String?

    /// enabled && inClosedNotch && .playing.
    var closedNotchItem: NowPlayingItem? {
        guard settings.glance.nowPlayingEnabled, settings.glance.nowPlayingInClosedNotch,
              let item, item.state == .playing
        else { return nil }
        return item
    }

    /// For media_control without `app`: the running player that is playing (the most recent one when both are),
    /// else the running player that was active most recently, else nil.
    var mostRecentPlayer: MediaPlayer? { targetPlayer(for: nil) }

    /// The scripting seam, shared with MediaControlTool.
    @ObservationIgnored nonisolated let scripting: MediaScripting

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let activity = MediaActivity()
    @ObservationIgnored private var isStarted = false
    /// Bumped by start() and stop() so results of work begun earlier are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var relay: NotificationRelay?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var enabledLoop: ObservationLoop<Bool>?
    @ObservationIgnored private var resyncTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    /// The track `artwork` belongs to.
    @ObservationIgnored private var artworkTrackID: String?
    /// "<item id>|<artwork address>" of the last artwork load started.
    @ObservationIgnored private var artworkKey: String?
    /// When `item` became paused (a resync of a paused item doesn't restart the clock).
    @ObservationIgnored private var pausedSince: Date?

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "NowPlaying")

    init(settings: AppSettings, scripting: MediaScripting = LiveMediaScripting()) {
        self.settings = settings
        self.scripting = scripting
        consent = [:]
    }

    /// Starts watching both players (distributed notifications, launches and quits) and, when "Show what's
    /// playing" is on, seeds the current state from players that already allow Automation. Idempotent.
    func start() {
        start(observingSystem: true)
    }

    /// Tests: `start()` without the distributed-notification and workspace observers, so only what the test feeds
    /// in through `receive` reaches the monitor (a real track change on the Mac running the tests can't).
    func startWithoutSystemObservers() {
        start(observingSystem: false)
    }

    private func start(observingSystem: Bool) {
        guard !isStarted else { return }
        isStarted = true
        generation += 1
        if observingSystem { observeSystem() }

        enabledLoop = ObservationLoop(read: { [weak self] in
            self?.settings.glance.nowPlayingEnabled ?? false
        }, onChange: { [weak self] enabled in
            self?.enabledDidChange(enabled)
        })

        resyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.resyncInterval)
                guard !Task.isCancelled, let self else { return }
                await self.periodicResync()
            }
        }

        if settings.glance.nowPlayingEnabled { seed() }
    }

    private func observeSystem() {
        let relay = NotificationRelay(monitor: self)
        let center = DistributedNotificationCenter.default()
        for player in MediaPlayer.allCases {
            center.addObserver(relay, selector: #selector(NotificationRelay.playerInfoChanged(_:)),
                               name: player.notificationName, object: nil, suspensionBehavior: .deliverImmediately)
        }
        self.relay = relay

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let player = Self.player(in: note) else { return }
                MainActor.assumeIsolated { self?.playerDidLaunch(player) }
            },
            workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let player = Self.player(in: note) else { return }
                MainActor.assumeIsolated { self?.playerDidQuit(player) }
            },
        ]
    }

    /// Stops watching and forgets everything it knew. Idempotent.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        generation += 1
        if let relay {
            DistributedNotificationCenter.default().removeObserver(relay)
        }
        relay = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        enabledLoop?.cancel()
        enabledLoop = nil
        resyncTask?.cancel()
        resyncTask = nil
        activity.removeAll()
        clearItem()
        lastControlError = nil
    }

    /// Runs the command; returns .needsConsent(player) when Automation would prompt (the VM explains first).
    /// `player` nil means `mostRecentPlayer`; with nothing running, `allowLaunch` falls back to Music.
    func perform(_ command: MediaCommand, on player: MediaPlayer?, allowLaunch: Bool) async -> MediaCommandOutcome {
        guard let target = targetPlayer(for: player) ?? (allowLaunch ? .music : nil) else { return .notRunning }
        let wasRunning = scripting.isRunning(target)
        guard wasRunning || allowLaunch else { return .notRunning }

        if wasRunning {
            let status = await scripting.consent(for: target, askUser: false)
            consent[target] = status
            switch status {
            case .wouldPrompt:
                return .needsConsent(target)
            case .denied:
                lastControlError = Self.deniedMessage(target)
                return .denied(target)
            case .authorized, .unavailable:
                break
            }
        }

        do {
            let state = try await scripting.run(command, on: target, allowLaunch: allowLaunch)
            lastControlError = nil
            consent[target] = .authorized
            noteCommand(command, on: target, resultingState: state, now: Date())
            Self.logger.info("Sent \(Self.logName(command), privacy: .public) to \(target.displayName, privacy: .public)")
            return .done(state)
        } catch let error as MediaScriptingError {
            Self.logger.notice("\(Self.logName(command), privacy: .public) for \(target.displayName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            switch error {
            case .notRunning:
                return .notRunning
            case .needsConsent:
                consent[target] = .wouldPrompt
                return .needsConsent(target)
            case .notPermitted:
                consent[target] = .denied
                lastControlError = Self.deniedMessage(target)
                return .denied(target)
            case .notInstalled:
                return fail("\(target.displayName) isn't installed on this Mac.")
            case .timedOut:
                return fail("\(target.displayName) didn't respond.")
            case .failed:
                return fail("Otto couldn't control \(target.displayName).")
            }
        } catch {
            return fail("Otto couldn't control \(target.displayName).")
        }
    }

    /// Snapshots and SelfTest: shows exactly this item and artwork (no expiry, no scripting).
    func debugSeed(item: NowPlayingItem?, artwork: NSImage?) {
        expiryTask?.cancel()
        artworkTask?.cancel()
        self.item = item
        self.artwork = artwork
        artworkKey = item.map { Self.artworkKey(for: $0) }
        artworkTrackID = item?.id
        pausedSince = item?.state == .paused ? item?.positionDate : nil
        if let item { activity.record(item.player, state: item.state, at: item.positionDate) }
    }

    /// The player a command for `requested` goes to: `requested` itself when given (running or not), else the
    /// playing running player (the most recent one when both play), else the running player active most
    /// recently, else the first running one. nil when nothing is running. Safe from any thread.
    nonisolated func targetPlayer(for requested: MediaPlayer?) -> MediaPlayer? {
        if let requested { return requested }
        let running = MediaPlayer.allCases.filter { scripting.isRunning($0) }
        guard !running.isEmpty else { return nil }
        let entries = activity.snapshot()
        let playing = running.filter { entries[$0]?.state == .playing }
        let pool = playing.isEmpty ? running : playing
        return pool.max { lhs, rhs in
            (entries[lhs]?.date ?? .distantPast) < (entries[rhs]?.date ?? .distantPast)
        } ?? running.first
    }

    /// Handles one player notification (the relay parses the untrusted payload before it gets here).
    func receive(_ parsed: NowPlayingItem?, state: PlaybackState?, from player: MediaPlayer, now: Date) {
        guard isStarted else { return }
        if let state { activity.record(player, state: state, at: now) }
        guard settings.glance.nowPlayingEnabled else { return }
        apply(parsed, state: state, from: player, now: now)
        let generation = self.generation
        Task { [weak self] in await self?.resync(player, generation: generation) }
    }

    /// Clears a paused item once it has been paused for `pausedLifetime` at `now`.
    func expirePausedItem(now: Date) {
        guard let item, item.state == .paused else { return }
        let since = pausedSince ?? item.positionDate
        guard now.timeIntervalSince(since) >= Self.pausedLifetime else { return }
        Self.logger.debug("Dropped the paused item after \(Int(Self.pausedLifetime), privacy: .public) s")
        clearItem()
    }

    // MARK: - Private

    private func fail(_ message: String) -> MediaCommandOutcome {
        lastControlError = message
        return .failed(message)
    }

    private static func deniedMessage(_ player: MediaPlayer) -> String {
        "Otto isn't allowed to control \(player.displayName)."
    }

    private static func logName(_ command: MediaCommand) -> String {
        switch command {
        case .play: return "play"
        case .pause: return "pause"
        case .playPause: return "playpause"
        case .next: return "next"
        case .previous: return "previous"
        case .seek: return "seek"
        }
    }

    private nonisolated static func player(in notification: Notification) -> MediaPlayer? {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return application?.bundleIdentifier.flatMap(MediaPlayer.init(rawValue:))
    }

    private static func artworkKey(for item: NowPlayingItem) -> String {
        "\(item.id)|\(item.artworkURL?.absoluteString ?? "")"
    }

    /// Merges a notification or resync into `item`: a paused item never replaces another player's playing one; the
    /// same track keeps its known position (Music's notifications carry none) and artwork address.
    private func apply(_ parsed: NowPlayingItem?, state: PlaybackState?, from player: MediaPlayer, now: Date) {
        guard var next = parsed else {
            if state == .stopped, item?.player == player { clearItem() }
            return
        }
        if let current = item {
            if next.state == .paused, current.player != player, current.state == .playing { return }
            if current.id == next.id {
                if next.position == nil { next.position = current.elapsed(at: now) }
                if next.duration == nil { next.duration = current.duration }
                if next.artworkURL == nil { next.artworkURL = current.artworkURL }
            }
        }
        setItem(next, now: now)
    }

    private func setItem(_ next: NowPlayingItem, now: Date) {
        let previous = item
        if next.state == .paused {
            if previous?.id != next.id || previous?.state != .paused || pausedSince == nil { pausedSince = now }
        } else {
            pausedSince = nil
        }
        if previous != next {
            item = next
            if previous?.id != next.id {
                Self.logger.debug("Now playing in \(next.player.displayName, privacy: .public): \(next.title, privacy: .private)")
            }
        }
        scheduleExpiry()
        refreshArtwork()
    }

    private func clearItem() {
        expiryTask?.cancel()
        expiryTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        artworkKey = nil
        artworkTrackID = nil
        pausedSince = nil
        if item != nil { item = nil }
        if artwork != nil { artwork = nil }
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let item, item.state == .paused else { return }
        let deadline = (pausedSince ?? item.positionDate).addingTimeInterval(Self.pausedLifetime)
        expiryTask = Task { [weak self] in
            let delay = deadline.timeIntervalSinceNow
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
            self?.expirePausedItem(now: Date())
        }
    }

    private func noteCommand(_ command: MediaCommand, on player: MediaPlayer, resultingState state: PlaybackState?, now: Date) {
        activity.record(player, state: state, at: now)
        guard var current = item, current.player == player else { return }
        switch command {
        case .seek(let seconds):
            let upper = current.duration ?? NowPlayingItem.maxPlausibleSeconds
            current.position = seconds.isFinite ? min(max(seconds, 0), upper) : current.position
        case .next, .previous:
            // The player announces the new track itself.
            return
        case .play, .pause, .playPause:
            current.position = current.elapsed(at: now)
        }
        current.positionDate = now
        if let state {
            if state == .stopped {
                clearItem()
                return
            }
            current.state = state
        }
        setItem(current, now: now)
    }

    private func playerDidLaunch(_ player: MediaPlayer) {
        guard isStarted else { return }
        activity.record(player, state: nil, at: Date())
    }

    private func playerDidQuit(_ player: MediaPlayer) {
        guard isStarted else { return }
        activity.remove(player)
        if item?.player == player { clearItem() }
    }

    private func enabledDidChange(_ enabled: Bool) {
        guard isStarted else { return }
        if enabled {
            seed()
        } else {
            clearItem()
        }
    }

    /// Initial state from each running player that already allows Automation (never prompts).
    private func seed() {
        let generation = self.generation
        for player in MediaPlayer.allCases where scripting.isRunning(player) {
            Task { [weak self] in await self?.resync(player, generation: generation) }
        }
    }

    private func periodicResync() async {
        guard isStarted, settings.glance.nowPlayingEnabled,
              let item, item.state == .playing, consent[item.player] == .authorized
        else { return }
        await resync(item.player, generation: generation)
    }

    /// Refreshes consent without prompting; when authorized, reads position, track and artwork address.
    private func resync(_ player: MediaPlayer, generation: Int) async {
        let status = await scripting.consent(for: player, askUser: false)
        guard isStarted, generation == self.generation else { return }
        consent[player] = status
        guard status == .authorized, settings.glance.nowPlayingEnabled else { return }
        let fresh = await scripting.nowPlaying(player)
        guard isStarted, generation == self.generation, settings.glance.nowPlayingEnabled else { return }
        let now = Date()
        guard let fresh else {
            if item?.player == player, !scripting.isRunning(player) { clearItem() }
            return
        }
        activity.record(player, state: fresh.state, at: now)
        apply(fresh, state: fresh.state, from: player, now: now)
    }

    /// Loads artwork for the current item once per track and address: Spotify from its (policy-checked) address,
    /// Music through scripting once Automation is already allowed (tried again after consent arrives). Only while
    /// "Show what's playing" is on.
    private func refreshArtwork() {
        guard let item, settings.glance.nowPlayingEnabled else { return }
        if artworkTrackID != item.id {
            artworkTask?.cancel()
            artworkTask = nil
            artworkKey = nil
            artworkTrackID = item.id
            if artwork != nil { artwork = nil }
        }
        let key = Self.artworkKey(for: item)
        guard key != artworkKey else { return }

        let itemID = item.id
        let generation = self.generation
        switch item.player {
        case .spotify:
            guard let url = item.artworkURL, ArtworkPolicy.isAllowedSpotifyArtworkURL(url) else { return }
            artworkTask?.cancel()
            artworkKey = key
            artworkTask = Task { [weak self] in
                let image = await MediaArtworkLoader.image(from: url)
                self?.showArtwork(image, itemID: itemID, generation: generation)
            }
        case .music:
            guard consent[.music] == .authorized, let source = scripting as? MediaArtworkScripting else { return }
            artworkTask?.cancel()
            artworkKey = key
            artworkTask = Task { [weak self] in
                let image = await MediaArtworkLoader.image(from: source)
                self?.showArtwork(image, itemID: itemID, generation: generation)
            }
        }
    }

    private func showArtwork(_ image: NSImage?, itemID: String, generation: Int) {
        guard !Task.isCancelled, generation == self.generation, item?.id == itemID, let image else { return }
        artwork = image
    }
}

// MARK: - Support types

extension NowPlayingMonitor {
    /// Each player's last known state and when it was last active. Read from any thread (MediaControlTool
    /// resolves its target off the main actor), written on the main actor.
    private final class MediaActivity: @unchecked Sendable {
        struct Entry: Equatable { var state: PlaybackState?; var date: Date }

        private let lock = NSLock()
        private var entries: [MediaPlayer: Entry] = [:]

        func record(_ player: MediaPlayer, state: PlaybackState?, at date: Date) {
            lock.withLock {
                let known = state ?? entries[player]?.state
                entries[player] = Entry(state: known, date: date)
            }
        }

        func remove(_ player: MediaPlayer) {
            _ = lock.withLock { entries.removeValue(forKey: player) }
        }

        func removeAll() {
            lock.withLock { entries.removeAll() }
        }

        func snapshot() -> [MediaPlayer: Entry] {
            lock.withLock { entries }
        }
    }

    /// Receives distributed notifications (selector-based, so they can be delivered immediately even while Otto
    /// isn't the active app), parses the untrusted payload into Sendable values, and hands them to the monitor.
    private final class NotificationRelay: NSObject {
        private weak var monitor: NowPlayingMonitor?

        init(monitor: NowPlayingMonitor) {
            self.monitor = monitor
        }

        @objc func playerInfoChanged(_ notification: Notification) {
            guard let player = MediaPlayer.allCases.first(where: { $0.notificationName == notification.name }) else { return }
            let userInfo = notification.userInfo ?? [:]
            let now = Date()
            let state = NowPlayingItem.playbackState(in: userInfo)
            let parsed = NowPlayingItem.parse(player: player, userInfo: userInfo, now: now)
            let monitor = self.monitor
            if Thread.isMainThread {
                MainActor.assumeIsolated { monitor?.receive(parsed, state: state, from: player, now: now) }
            } else {
                Task { @MainActor in monitor?.receive(parsed, state: state, from: player, now: now) }
            }
        }
    }
}

/// Artwork loading off the main actor: an ephemeral session with no cookies or cache, a 5 s timeout, redirects
/// only to allowed hosts, at most ArtworkPolicy.maxBytes read, then an ImageIO thumbnail.
private enum MediaArtworkLoader {
    static let timeout: TimeInterval = 5

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "NowPlaying")

    static func image(from url: URL) async -> NSImage? {
        guard ArtworkPolicy.isAllowedSpotifyArtworkURL(url) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RedirectGuard())
            guard response.expectedContentLength <= Int64(ArtworkPolicy.maxBytes) else { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > ArtworkPolicy.maxBytes { return nil }
            }
            guard ArtworkPolicy.accepts(response, byteCount: data.count) else {
                logger.notice("Refused a Spotify artwork response")
                return nil
            }
            return ArtworkPolicy.thumbnail(from: data)
        } catch {
            logger.debug("Spotify artwork didn't load: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func image(from source: MediaArtworkScripting) async -> NSImage? {
        guard let data = await source.artworkData(.music) else { return nil }
        return ArtworkPolicy.thumbnail(from: data)
    }

    /// Follows a redirect only to another address ArtworkPolicy allows.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, ArtworkPolicy.isAllowedSpotifyArtworkURL(url) else { return nil }
            return request
        }
    }
}
