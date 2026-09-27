//
//  NowPlayingTests.swift
//  OttoTests
//
//  Parsing and sanitizing of Music and Spotify notification payloads, ArtworkPolicy, elapsed time, and the
//  monitor's rules (which item wins, paused expiry, consent outcomes, polling that never prompts) through
//  DemoMediaScripting or a private fake. No Apple Events, no network, no real distributed notifications.
//

import AppKit
import XCTest
@testable import Otto

// MARK: - Payload parsing

final class NowPlayingParsingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testMusicPayloadUsesMillisecondsAndPersistentID() throws {
        let userInfo: [AnyHashable: Any] = [
            "Player State": "Playing", "Name": "Nights", "Artist": "Frank Ocean", "Album": "Blonde",
            "Total Time": NSNumber(value: 307_000), "PersistentID": NSNumber(value: Int64(-2)),
        ]
        let item = try XCTUnwrap(NowPlayingItem.parse(player: .music, userInfo: userInfo, now: now))
        XCTAssertEqual(item.player, .music)
        XCTAssertEqual(item.state, .playing)
        XCTAssertEqual(item.title, "Nights")
        XCTAssertEqual(item.artist, "Frank Ocean")
        XCTAssertEqual(item.album, "Blonde")
        XCTAssertEqual(item.duration, 307, "Total Time is in milliseconds")
        XCTAssertNil(item.position, "Music's notification carries no position")
        XCTAssertEqual(item.positionDate, now)
        XCTAssertNil(item.artworkURL)
        XCTAssertEqual(item.id, "com.apple.Music|FFFFFFFFFFFFFFFE", "written like Music's scripting persistent ID")
    }

    func testSpotifyPayloadUsesMillisecondsForDurationAndSecondsForPosition() throws {
        let userInfo: [AnyHashable: Any] = [
            "Player State": "Paused", "Name": "Espresso", "Artist": "Sabrina Carpenter", "Album": "Short n' Sweet",
            "Track ID": "spotify:track:2qSkIjg1o9h3YT9RAgYN75", "Duration": NSNumber(value: 175_459),
            "Playback Position": NSNumber(value: 42.5),
        ]
        let item = try XCTUnwrap(NowPlayingItem.parse(player: .spotify, userInfo: userInfo, now: now))
        XCTAssertEqual(item.state, .paused)
        XCTAssertEqual(try XCTUnwrap(item.duration), 175.459, accuracy: 0.0001)
        XCTAssertEqual(item.position, 42.5, "Playback Position is already in seconds")
        XCTAssertEqual(item.id, "com.spotify.client|spotify:track:2qSkIjg1o9h3YT9RAgYN75")
        XCTAssertNil(item.artworkURL, "payloads never supply an address")
    }

    func testStoppedMissingAndGarbagePayloads() {
        XCTAssertNil(NowPlayingItem.parse(player: .music, userInfo: ["Player State": "Stopped", "Name": "X"], now: now))
        XCTAssertEqual(NowPlayingItem.playbackState(in: ["Player State": "Stopped"]), .stopped)
        XCTAssertNil(NowPlayingItem.parse(player: .music, userInfo: ["Name": "No state"], now: now))
        XCTAssertNil(NowPlayingItem.parse(player: .music, userInfo: ["Player State": "Dancing", "Name": "X"], now: now))
        XCTAssertNil(NowPlayingItem.parse(player: .spotify, userInfo: ["Player State": "Playing"], now: now), "no title")
        XCTAssertNil(NowPlayingItem.parse(player: .spotify, userInfo: ["Player State": "Playing", "Name": NSNumber(value: 3)],
                                          now: now), "a non-string title")
        XCTAssertNil(NowPlayingItem.parse(player: .spotify, userInfo: ["Player State": "Playing", "Name": "\u{202E}\u{200B}"],
                                          now: now), "nothing left after sanitizing")
    }

    func testIdentifierFallsBackToTitleAndArtist() throws {
        let item = try XCTUnwrap(NowPlayingItem.parse(player: .music,
                                                      userInfo: ["Player State": "Playing", "Name": "Song", "Artist": "Band"],
                                                      now: now))
        XCTAssertEqual(item.id, "com.apple.Music|Song|Band")
    }

    func testSanitizingStripsControlAndBidiCharactersAndCapsLength() throws {
        let userInfo: [AnyHashable: Any] = [
            "Player State": "Playing",
            "Name": "Good\u{202E}gnos\u{202C} \u{0007}Song\u{2066}\n\tTitle",
            "Artist": String(repeating: "A", count: 500),
            "Album": "Album\u{200B}\u{FEFF}",
            "Track ID": "spotify:track:\u{202E}abc",
        ]
        let item = try XCTUnwrap(NowPlayingItem.parse(player: .spotify, userInfo: userInfo, now: now))
        XCTAssertEqual(item.title, "Goodgnos Song Title")
        XCTAssertFalse(DisplayText.containsHiddenOrBidi(item.title))
        XCTAssertEqual(item.artist.count, 200)
        XCTAssertTrue(item.artist.hasSuffix("…"))
        XCTAssertEqual(item.album, "Album")
        XCTAssertEqual(item.id, "com.spotify.client|spotify:track:abc")
    }

    func testImplausibleNumbersAreIgnored() throws {
        let base: [AnyHashable: Any] = ["Player State": "Playing", "Name": "Song"]
        func parse(_ extra: [AnyHashable: Any]) throws -> NowPlayingItem {
            try XCTUnwrap(NowPlayingItem.parse(player: .spotify, userInfo: base.merging(extra) { $1 }, now: now))
        }
        XCTAssertNil(try parse(["Duration": NSNumber(value: -5_000)]).duration)
        XCTAssertNil(try parse(["Duration": NSNumber(value: Double.nan)]).duration)
        XCTAssertNil(try parse(["Duration": NSNumber(value: 1e15)]).duration)
        XCTAssertNil(try parse(["Duration": kCFBooleanTrue as Any]).duration, "booleans aren't numbers")
        XCTAssertEqual(try parse(["Duration": "90000"]).duration, 90, "numeric strings are accepted")
        XCTAssertNil(try parse(["Playback Position": NSNumber(value: -1)]).position)
        XCTAssertEqual(try parse(["Duration": NSNumber(value: 60_000), "Playback Position": NSNumber(value: 75)]).position, 60,
                       "position never passes the duration")
    }

    func testPlayerWordsAndNames() {
        XCTAssertEqual(PlaybackState(playerWord: "Playing"), .playing)
        XCTAssertEqual(PlaybackState(playerWord: "rewinding"), .playing)
        XCTAssertEqual(PlaybackState(playerWord: " paused "), .paused)
        XCTAssertNil(PlaybackState(playerWord: "kPSP"))
        XCTAssertEqual(MediaPlayer(displayName: "Spotify"), .spotify)
        XCTAssertEqual(MediaPlayer(displayName: "Music"), .music)
        XCTAssertNil(MediaPlayer(displayName: "music"))
        XCTAssertNil(MediaPlayer(displayName: "com.apple.Music"))
    }

    func testElapsedExtrapolation() {
        let start = Date(timeIntervalSince1970: 1_000)
        var item = NowPlayingItem(id: "a", player: .spotify, title: "T", artist: "A", album: "", duration: 100,
                                  position: 90, positionDate: start, state: .playing, artworkURL: nil)
        XCTAssertEqual(item.elapsed(at: start.addingTimeInterval(5)), 95)
        XCTAssertEqual(item.elapsed(at: start.addingTimeInterval(60)), 100)
        XCTAssertEqual(item.elapsed(at: start.addingTimeInterval(-500)), 0, "never below zero")
        item.duration = nil
        XCTAssertEqual(item.elapsed(at: start.addingTimeInterval(60)), 150)
        item.state = .paused
        XCTAssertEqual(item.elapsed(at: start.addingTimeInterval(60)), 90)
    }
}

// MARK: - Artwork policy

final class NowPlayingArtworkPolicyTests: XCTestCase {
    func testAllowedAddresses() throws {
        for address in ["https://i.scdn.co/image/ab67616d0000b273", "https://mosaic.scdn.co/640/abc",
                        "https://image-cdn-ak.spotifycdn.com/image/abc", "https://I.SCDN.CO/image/x",
                        "https://i.scdn.co:443/image/x"] {
            XCTAssertTrue(ArtworkPolicy.isAllowedSpotifyArtworkURL(try XCTUnwrap(URL(string: address))), address)
        }
    }

    func testRefusedAddresses() throws {
        for address in ["http://i.scdn.co/image/x", "https://example.com/i.scdn.co/x", "https://i.scdn.co.evil.com/x",
                        "https://evilscdn.co/x", "https://scdn.co/x", "https://spotifycdn.com/x",
                        "https://user@i.scdn.co/x", "https://user:pw@i.scdn.co/x", "https://i.scdn.co:8443/x",
                        "https://i.scdn.co/x#frag", "https://i.scdn.co./x", "https://151.101.2.248/x",
                        "https://-.scdn.co/x", "file:///i.scdn.co/x", "ftp://i.scdn.co/x", "https://i%2escdn.co/x"] {
            let url = try XCTUnwrap(URL(string: address), address)
            XCTAssertFalse(ArtworkPolicy.isAllowedSpotifyArtworkURL(url), address)
        }
        XCTAssertEqual(ArtworkPolicy.maxBytes, 2 * 1024 * 1024)
    }

    func testResponseChecks() throws {
        let url = try XCTUnwrap(URL(string: "https://i.scdn.co/image/x"))
        func response(_ status: Int, _ type: String?, url: URL = url) -> HTTPURLResponse? {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                            headerFields: type.map { ["Content-Type": $0] } ?? [:])
        }
        XCTAssertTrue(ArtworkPolicy.accepts(try XCTUnwrap(response(200, "image/jpeg")), byteCount: 50_000))
        XCTAssertFalse(ArtworkPolicy.accepts(try XCTUnwrap(response(404, "image/jpeg")), byteCount: 50_000))
        XCTAssertFalse(ArtworkPolicy.accepts(try XCTUnwrap(response(200, "text/html")), byteCount: 50_000))
        XCTAssertFalse(ArtworkPolicy.accepts(try XCTUnwrap(response(200, nil)), byteCount: 50_000))
        XCTAssertFalse(ArtworkPolicy.accepts(try XCTUnwrap(response(200, "image/png")), byteCount: ArtworkPolicy.maxBytes + 1))
        XCTAssertFalse(ArtworkPolicy.accepts(try XCTUnwrap(response(200, "image/png")), byteCount: 0))
        let redirected = try XCTUnwrap(URL(string: "https://example.com/x.jpg"))
        XCTAssertFalse(ArtworkPolicy.accepts(try XCTUnwrap(response(200, "image/jpeg", url: redirected)), byteCount: 10),
                       "the final address must be allowed too")
        let plain = URLResponse(url: url, mimeType: "image/jpeg", expectedContentLength: 10, textEncodingName: nil)
        XCTAssertFalse(ArtworkPolicy.accepts(plain, byteCount: 10))
    }

    func testThumbnailShrinksToTheMaximumSide() throws {
        let data = try pngData(width: 300, height: 150)
        let image = try XCTUnwrap(ArtworkPolicy.thumbnail(from: data))
        XCTAssertEqual(image.size.width, CGFloat(ArtworkPolicy.maxPixelSize))
        XCTAssertEqual(image.size.height, CGFloat(ArtworkPolicy.maxPixelSize / 2))
        XCTAssertNil(ArtworkPolicy.thumbnail(from: Data("not an image".utf8)))
        XCTAssertNil(ArtworkPolicy.thumbnail(from: Data()))
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}

// MARK: - Monitor

@MainActor
final class NowPlayingMonitorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 50_000)

    func testClosedNotchItemFollowsSettings() {
        let settings = makeSettings(enabled: true)
        let monitor = NowPlayingMonitor(settings: settings, scripting: DemoMediaScripting())
        let playing = item(.spotify, "Song", state: .playing)
        monitor.debugSeed(item: playing, artwork: NSImage(size: NSSize(width: 16, height: 16)))
        XCTAssertEqual(monitor.item, playing)
        XCTAssertNotNil(monitor.artwork)
        XCTAssertEqual(monitor.closedNotchItem, playing)

        settings.glance.nowPlayingInClosedNotch = false
        XCTAssertNil(monitor.closedNotchItem)
        settings.glance.nowPlayingInClosedNotch = true
        settings.glance.nowPlayingEnabled = false
        XCTAssertNil(monitor.closedNotchItem)
        settings.glance.nowPlayingEnabled = true
        monitor.debugSeed(item: item(.spotify, "Song", state: .paused), artwork: nil)
        XCTAssertNil(monitor.closedNotchItem, "only a playing item shows in the closed notch")
    }

    func testPausedItemExpiresAfterTenMinutes() {
        let monitor = NowPlayingMonitor(settings: makeSettings(enabled: true), scripting: DemoMediaScripting())
        monitor.debugSeed(item: item(.music, "Song", state: .paused), artwork: nil)
        monitor.expirePausedItem(now: start.addingTimeInterval(599))
        XCTAssertNotNil(monitor.item)
        monitor.expirePausedItem(now: start.addingTimeInterval(600))
        XCTAssertNil(monitor.item)

        monitor.debugSeed(item: item(.music, "Song", state: .playing), artwork: nil)
        monitor.expirePausedItem(now: start.addingTimeInterval(10_000))
        XCTAssertNotNil(monitor.item, "a playing item never expires")
    }

    func testNotificationsUpdateTheItemWithPlayingWinning() async {
        let fake = MonitorFakeScripting(running: [.music, .spotify], consent: .wouldPrompt)
        let monitor = NowPlayingMonitor(settings: makeSettings(enabled: true), scripting: fake)
        monitor.startWithoutSystemObservers()
        defer { monitor.stop() }

        let spotify = item(.spotify, "Espresso", state: .playing)
        monitor.receive(spotify, state: .playing, from: .spotify, now: start)
        XCTAssertEqual(monitor.item, spotify)

        monitor.receive(item(.music, "Nights", state: .paused), state: .paused, from: .music, now: start.addingTimeInterval(5))
        XCTAssertEqual(monitor.item?.player, .spotify, "a paused item never replaces another player's playing one")

        let music = item(.music, "Nights", state: .playing)
        monitor.receive(music, state: .playing, from: .music, now: start.addingTimeInterval(10))
        XCTAssertEqual(monitor.item, music, "the most recent playing item wins")

        monitor.receive(nil, state: .stopped, from: .spotify, now: start.addingTimeInterval(15))
        XCTAssertEqual(monitor.item, music, "another player stopping changes nothing")
        monitor.receive(nil, state: .stopped, from: .music, now: start.addingTimeInterval(20))
        XCTAssertNil(monitor.item)

        await waitUntil { fake.consentChecks.count >= 4 }
        XCTAssertFalse(fake.consentChecks.contains { $0.askUser }, "watching never prompts for Automation")
        XCTAssertEqual(fake.nowPlayingReads, [], "no resync without consent")
        XCTAssertEqual(monitor.consent[.music], .wouldPrompt)
    }

    func testSameTrackKeepsItsPositionAcrossPlayAndPause() {
        let monitor = NowPlayingMonitor(settings: makeSettings(enabled: true),
                                        scripting: MonitorFakeScripting(running: [.music], consent: .wouldPrompt))
        monitor.startWithoutSystemObservers()
        defer { monitor.stop() }
        var playing = item(.music, "Nights", state: .playing)
        playing.position = 30
        monitor.receive(playing, state: .playing, from: .music, now: start)
        var paused = item(.music, "Nights", state: .paused)
        paused.position = nil
        paused.positionDate = start.addingTimeInterval(20)
        monitor.receive(paused, state: .paused, from: .music, now: start.addingTimeInterval(20))
        XCTAssertEqual(monitor.item?.state, .paused)
        XCTAssertEqual(monitor.item?.position, 50, "Music's notification has no position; the old one carries forward")
    }

    func testDisabledMonitorKeepsNoTrackButRemembersThePlayer() async {
        let fake = MonitorFakeScripting(running: [.music, .spotify], consent: .authorized)
        let settings = makeSettings(enabled: false)
        let monitor = NowPlayingMonitor(settings: settings, scripting: fake)
        monitor.startWithoutSystemObservers()
        defer { monitor.stop() }

        monitor.receive(item(.music, "A", state: .paused), state: .paused, from: .music, now: start)
        monitor.receive(item(.spotify, "B", state: .playing), state: .playing, from: .spotify, now: start.addingTimeInterval(1))
        XCTAssertNil(monitor.item, "no track details while Show what's playing is off")
        XCTAssertEqual(monitor.mostRecentPlayer, .spotify)

        monitor.receive(item(.spotify, "B", state: .paused), state: .paused, from: .spotify, now: start.addingTimeInterval(2))
        monitor.receive(item(.music, "A", state: .playing), state: .playing, from: .music, now: start.addingTimeInterval(3))
        XCTAssertEqual(monitor.mostRecentPlayer, .music)
        monitor.receive(item(.music, "A", state: .paused), state: .paused, from: .music, now: start.addingTimeInterval(4))
        XCTAssertEqual(monitor.mostRecentPlayer, .music, "neither plays: the one active most recently")

        fake.setRunning([.spotify])
        XCTAssertEqual(monitor.mostRecentPlayer, .spotify, "only running players count")
        fake.setRunning([])
        XCTAssertNil(monitor.mostRecentPlayer)
        XCTAssertEqual(fake.nowPlayingReads, [], "nothing is read while Now Playing is off")
    }

    func testEnablingSeedsFromAuthorizedPlayersOnly() async {
        let fake = MonitorFakeScripting(running: [.music, .spotify], consent: .authorized)
        fake.setConsent(.wouldPrompt, for: .music)
        fake.setTrack(item(.spotify, "Seeded", state: .playing))
        let settings = makeSettings(enabled: false)
        let monitor = NowPlayingMonitor(settings: settings, scripting: fake)
        monitor.startWithoutSystemObservers()
        defer { monitor.stop() }

        settings.glance.nowPlayingEnabled = true
        await waitUntil { monitor.item != nil }
        XCTAssertEqual(monitor.item?.title, "Seeded")
        XCTAssertEqual(fake.nowPlayingReads, [.spotify], "Music would prompt, so it isn't read")
        XCTAssertEqual(monitor.consent[.music], .wouldPrompt)
        XCTAssertEqual(monitor.consent[.spotify], .authorized)
        XCTAssertFalse(fake.consentChecks.contains { $0.askUser })

        settings.glance.nowPlayingEnabled = false
        await waitUntil { monitor.item == nil }
        XCTAssertNil(monitor.item)
    }

    func testPerformOutcomes() async {
        let fake = MonitorFakeScripting(running: [], consent: .authorized)
        let monitor = NowPlayingMonitor(settings: makeSettings(enabled: true), scripting: fake)

        var outcome = await monitor.perform(.pause, on: nil, allowLaunch: false)
        XCTAssertEqual(outcome, .notRunning)
        outcome = await monitor.perform(.next, on: .spotify, allowLaunch: false)
        XCTAssertEqual(outcome, .notRunning)
        XCTAssertTrue(fake.runs.isEmpty, "never launches without allowLaunch")

        fake.setRunning([.spotify])
        fake.setConsent(.wouldPrompt, for: .spotify)
        outcome = await monitor.perform(.playPause, on: .spotify, allowLaunch: false)
        XCTAssertEqual(outcome, .needsConsent(.spotify))
        XCTAssertTrue(fake.runs.isEmpty, "no script runs while consent would prompt")
        XCTAssertFalse(fake.consentChecks.contains { $0.askUser }, "perform never prompts; the view model explains first")

        fake.setConsent(.denied, for: .spotify)
        outcome = await monitor.perform(.playPause, on: .spotify, allowLaunch: false)
        XCTAssertEqual(outcome, .denied(.spotify))
        XCTAssertEqual(monitor.lastControlError, "Otto isn't allowed to control Spotify.")
        XCTAssertEqual(monitor.consent[.spotify], .denied)

        fake.setConsent(.authorized, for: .spotify)
        fake.setRunError(.timedOut)
        outcome = await monitor.perform(.next, on: .spotify, allowLaunch: false)
        XCTAssertEqual(outcome, .failed("Spotify didn't respond."))
        XCTAssertEqual(monitor.lastControlError, "Spotify didn't respond.")

        fake.setRunError(.notPermitted)
        outcome = await monitor.perform(.next, on: .spotify, allowLaunch: false)
        XCTAssertEqual(outcome, .denied(.spotify))

        fake.setRunError(nil)
        fake.setRunState(.paused)
        monitor.debugSeed(item: item(.spotify, "Song", state: .playing), artwork: nil)
        outcome = await monitor.perform(.pause, on: nil, allowLaunch: false)
        XCTAssertEqual(outcome, .done(.paused))
        XCTAssertNil(monitor.lastControlError)
        XCTAssertEqual(monitor.item?.state, .paused)
        XCTAssertEqual(fake.runs.last?.player, .spotify)
        XCTAssertEqual(fake.runs.last?.allowLaunch, false)
    }

    func testPerformLaunchesMusicOnlyWhenAllowed() async {
        let fake = MonitorFakeScripting(running: [], consent: .authorized)
        fake.setRunState(.playing)
        let monitor = NowPlayingMonitor(settings: makeSettings(enabled: true), scripting: fake)
        let outcome = await monitor.perform(.play, on: nil, allowLaunch: true)
        XCTAssertEqual(outcome, .done(.playing))
        XCTAssertEqual(fake.runs.map(\.player), [.music])
        XCTAssertEqual(fake.runs.map(\.allowLaunch), [true])
    }

    func testDemoScriptingDrivesTheMonitorWithoutAppleEvents() async {
        let seeded = item(.spotify, "Demo", state: .playing)
        let monitor = NowPlayingMonitor(settings: makeSettings(enabled: true), scripting: DemoMediaScripting(item: seeded))
        monitor.startWithoutSystemObservers()
        defer { monitor.stop() }
        await waitUntil { monitor.item != nil }
        XCTAssertEqual(monitor.item?.title, "Demo")
        XCTAssertEqual(monitor.mostRecentPlayer, .spotify)

        let outcome = await monitor.perform(.pause, on: nil, allowLaunch: false)
        XCTAssertEqual(outcome, .done(.paused))
        XCTAssertEqual(monitor.item?.state, .paused)
        XCTAssertEqual(monitor.consent[.spotify], .authorized)

        monitor.stop()
        XCTAssertNil(monitor.item)
        XCTAssertNil(monitor.artwork)
    }

    func testStartAndStopAreIdempotent() {
        let monitor = NowPlayingMonitor(settings: makeSettings(enabled: false), scripting: DemoMediaScripting())
        monitor.start()
        monitor.start()
        monitor.debugSeed(item: item(.music, "Song", state: .playing), artwork: nil)
        monitor.stop()
        monitor.stop()
        XCTAssertNil(monitor.item)
    }

    // MARK: - Helpers

    private func makeSettings(enabled: Bool) -> AppSettings {
        let settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        settings.glance.nowPlayingEnabled = enabled
        return settings
    }

    private func item(_ player: MediaPlayer, _ title: String, state: PlaybackState) -> NowPlayingItem {
        NowPlayingItem(id: NowPlayingItem.makeID(player: player, trackID: nil, title: title, artist: "Artist"),
                       player: player, title: title, artist: "Artist", album: "Album", duration: 200, position: 10,
                       positionDate: start, state: state, artworkURL: nil)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Settable players for monitor tests: records every consent check, read and command. Mirrors the live rule that a
/// command throws `.needsConsent` instead of prompting. Never conforms to MediaArtworkScripting and never returns
/// an artwork address, so nothing reaches the network.
private final class MonitorFakeScripting: MediaScripting, @unchecked Sendable {
    struct Run: Equatable { let command: MediaCommand; let player: MediaPlayer; let allowLaunch: Bool }

    private let lock = NSLock()
    private var running: Set<MediaPlayer>
    private var consents: [MediaPlayer: BrowserContext.AutomationConsent] = [:]
    private let defaultConsent: BrowserContext.AutomationConsent
    private var tracks: [MediaPlayer: NowPlayingItem] = [:]
    private var runError: MediaScriptingError?
    private var runState: PlaybackState? = .playing
    private var recordedRuns: [Run] = []
    private var recordedChecks: [(player: MediaPlayer, askUser: Bool)] = []
    private var recordedReads: [MediaPlayer] = []

    init(running: Set<MediaPlayer>, consent: BrowserContext.AutomationConsent) {
        self.running = running
        defaultConsent = consent
    }

    var runs: [Run] { lock.withLock { recordedRuns } }
    var consentChecks: [(player: MediaPlayer, askUser: Bool)] { lock.withLock { recordedChecks } }
    var nowPlayingReads: [MediaPlayer] { lock.withLock { recordedReads } }

    func setRunning(_ players: Set<MediaPlayer>) { lock.withLock { running = players } }
    func setConsent(_ consent: BrowserContext.AutomationConsent, for player: MediaPlayer) { lock.withLock { consents[player] = consent } }
    func setTrack(_ item: NowPlayingItem) { lock.withLock { tracks[item.player] = item } }
    func setRunError(_ error: MediaScriptingError?) { lock.withLock { runError = error } }
    func setRunState(_ state: PlaybackState?) { lock.withLock { runState = state } }

    func isRunning(_ player: MediaPlayer) -> Bool {
        lock.withLock { running.contains(player) }
    }

    func consent(for player: MediaPlayer, askUser: Bool) async -> BrowserContext.AutomationConsent {
        lock.withLock {
            recordedChecks.append((player, askUser))
            guard running.contains(player) else { return .unavailable }
            return consents[player] ?? defaultConsent
        }
    }

    func run(_ command: MediaCommand, on player: MediaPlayer, allowLaunch: Bool) async throws -> PlaybackState? {
        try lock.withLock {
            if !running.contains(player) {
                guard allowLaunch else { throw MediaScriptingError.notRunning }
                running.insert(player)
            }
            if (consents[player] ?? defaultConsent) == .wouldPrompt { throw MediaScriptingError.needsConsent }
            recordedRuns.append(Run(command: command, player: player, allowLaunch: allowLaunch))
            if let runError { throw runError }
            return runState
        }
    }

    func nowPlaying(_ player: MediaPlayer) async -> NowPlayingItem? {
        lock.withLock {
            recordedReads.append(player)
            return tracks[player]
        }
    }
}
