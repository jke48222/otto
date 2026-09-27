//
//  MediaScriptingTests.swift
//  OttoTests
//
//  The player scripts are constant, guarded and bounded; seek positions are clamped and formatted the same
//  way in every locale; script results and error numbers map as documented; the demo player behaves like a
//  player without sending a single Apple Event. Nothing here executes an AppleScript.
//

import AppKit
import XCTest
@testable import Otto

final class MediaScriptingTests: XCTestCase {
    private let everyCommand: [MediaCommand] = [.play, .pause, .playPause, .next, .previous, .seek(42)]

    // MARK: - Constant scripts

    func testEveryCommandScriptIsGuardedAndBounded() {
        for player in MediaPlayer.allCases {
            for command in everyCommand {
                let script = LiveMediaScripting.commandScript(command, player: player)
                XCTAssertTrue(script.hasPrefix("if application id \"\(player.rawValue)\" is running then\n"),
                              "\(command) for \(player) must check the player is running first")
                XCTAssertTrue(script.contains("with timeout of 2 seconds"))
                XCTAssertTrue(script.contains("tell application id \"\(player.rawValue)\""))
                XCTAssertTrue(script.hasSuffix("end if\nreturn \"\(LiveMediaScripting.notRunningResult)\""))
                XCTAssertTrue(script.contains("return player state as text"))
                for launching in ["activate", "launch", "run script", "open "] {
                    XCTAssertFalse(script.contains(launching), "\(command) for \(player) contains \(launching)")
                }
                XCTAssertEqual(script, LiveMediaScripting.commandScript(command, player: player), "scripts are constant")
            }
        }
    }

    func testCommandVerbs() {
        let expected: [(MediaCommand, String)] = [
            (.play, "play"), (.pause, "pause"), (.playPause, "playpause"), (.next, "next track"),
            (.previous, "previous track"), (.seek(12.5), "set player position to 12.50"),
        ]
        for (command, verb) in expected {
            let lines = LiveMediaScripting.commandScript(command, player: .spotify)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertTrue(lines.contains(verb), "\(command) should send “\(verb)”")
        }
    }

    func testSeekScriptsDifferOnlyInTheFormattedPosition() {
        let first = LiveMediaScripting.commandScript(.seek(1), player: .music)
        let second = LiveMediaScripting.commandScript(.seek(2.5), player: .music)
        XCTAssertEqual(first.replacingOccurrences(of: "1.00", with: "2.50"), second)
        XCTAssertTrue(LiveMediaScripting.commandScript(.seek(-.infinity), player: .music).contains("to 0.00\n"))
    }

    func testSecondsFormattingIsLocaleIndependentAndClamped() {
        XCTAssertEqual(LiveMediaScripting.formattedSeconds(12.5), "12.50")
        XCTAssertEqual(LiveMediaScripting.formattedSeconds(1234.567), "1234.57")
        XCTAssertEqual(LiveMediaScripting.formattedSeconds(0), "0.00")
        XCTAssertEqual(LiveMediaScripting.formattedSeconds(-3), "0.00")
        XCTAssertEqual(LiveMediaScripting.formattedSeconds(.nan), "0.00")
        XCTAssertEqual(LiveMediaScripting.formattedSeconds(.infinity), "0.00")
        XCTAssertEqual(LiveMediaScripting.formattedSeconds(1e12), "604800.00", "capped at a week")
        // A comma-decimal locale would write "1234,50"; the script must never see that.
        XCTAssertFalse(LiveMediaScripting.formattedSeconds(1234.5).contains(","))
    }

    func testNowPlayingAndArtworkScriptsAreGuarded() {
        for player in MediaPlayer.allCases {
            let script = LiveMediaScripting.nowPlayingScript(player)
            XCTAssertTrue(script.hasPrefix("if application id \"\(player.rawValue)\" is running then\n"))
            XCTAssertTrue(script.contains("with timeout of 2 seconds"))
            XCTAssertTrue(script.contains("player position"))
        }
        XCTAssertTrue(LiveMediaScripting.nowPlayingScript(.spotify).contains("(duration of trackRef) / 1000"),
                      "Spotify reports milliseconds")
        XCTAssertTrue(LiveMediaScripting.nowPlayingScript(.spotify).contains("artwork url of trackRef"))
        XCTAssertFalse(LiveMediaScripting.nowPlayingScript(.music).contains("artwork url"))

        let artwork = LiveMediaScripting.artworkScript(.music)
        XCTAssertEqual(artwork?.hasPrefix("if application id \"com.apple.Music\" is running then\n"), true)
        XCTAssertEqual(artwork?.contains("raw data of artwork 1 of current track"), true)
        XCTAssertNil(LiveMediaScripting.artworkScript(.spotify), "Spotify artwork is an address, not script data")
    }

    // MARK: - Results and errors

    func testCommandResultParsing() throws {
        XCTAssertEqual(try LiveMediaScripting.commandResult(from: NSAppleEventDescriptor(string: "playing")), .playing)
        XCTAssertEqual(try LiveMediaScripting.commandResult(from: NSAppleEventDescriptor(string: "paused")), .paused)
        XCTAssertEqual(try LiveMediaScripting.commandResult(from: NSAppleEventDescriptor(string: "fast forwarding")), .playing)
        XCTAssertNil(try LiveMediaScripting.commandResult(from: NSAppleEventDescriptor(string: "buffering")))
        XCTAssertNil(try LiveMediaScripting.commandResult(from: NSAppleEventDescriptor.null()))
        XCTAssertThrowsError(try LiveMediaScripting.commandResult(
            from: NSAppleEventDescriptor(string: LiveMediaScripting.notRunningResult))) { error in
            XCTAssertEqual(error as? MediaScriptingError, .notRunning)
        }
    }

    func testNowPlayingParsing() throws {
        let now = Date(timeIntervalSince1970: 5_000)
        let spotify = list(["playing", "Espresso", "Sabrina Carpenter", "Short n' Sweet", 175.5, 12.25,
                            "spotify:track:2qSkIjg1o9h3YT9RAgYN75", "https://i.scdn.co/image/ab67616d0000b273"])
        let item = try XCTUnwrap(LiveMediaScripting.parseNowPlaying(spotify, player: .spotify, now: now))
        XCTAssertEqual(item.id, "com.spotify.client|spotify:track:2qSkIjg1o9h3YT9RAgYN75")
        XCTAssertEqual(item.title, "Espresso")
        XCTAssertEqual(item.artist, "Sabrina Carpenter")
        XCTAssertEqual(item.duration, 175.5)
        XCTAssertEqual(item.position, 12.25)
        XCTAssertEqual(item.positionDate, now)
        XCTAssertEqual(item.state, .playing)
        XCTAssertEqual(item.artworkURL?.absoluteString, "https://i.scdn.co/image/ab67616d0000b273")

        let unsafeArtwork = list(["paused", "Song\u{202E}", "Artist", "Album", 100, 400, "spotify:track:x",
                                  "https://i.scdn.co.evil.com/a.jpg"])
        let paused = try XCTUnwrap(LiveMediaScripting.parseNowPlaying(unsafeArtwork, player: .spotify, now: now))
        XCTAssertNil(paused.artworkURL, "ArtworkPolicy rejects other hosts")
        XCTAssertEqual(paused.title, "Song", "bidi controls are stripped")
        XCTAssertEqual(paused.position, 100, "position never passes the duration")
        XCTAssertEqual(paused.state, .paused)

        let music = list(["playing", "Nights", "Frank Ocean", "Blonde", 307.0, 30.0, "5F1D3A0D2E8C4B7A", ""])
        let musicItem = try XCTUnwrap(LiveMediaScripting.parseNowPlaying(music, player: .music, now: now))
        XCTAssertEqual(musicItem.id, "com.apple.Music|5F1D3A0D2E8C4B7A")
        XCTAssertNil(musicItem.artworkURL)

        XCTAssertNil(LiveMediaScripting.parseNowPlaying(list(["stopped"]), player: .music, now: now))
        XCTAssertNil(LiveMediaScripting.parseNowPlaying(list(["playing"]), player: .music, now: now), "no track loaded")
        XCTAssertNil(LiveMediaScripting.parseNowPlaying(NSAppleEventDescriptor(string: "otto:not-running"),
                                                        player: .music, now: now))
    }

    func testErrorNumbersMap() {
        XCTAssertEqual(LiveMediaScripting.error(forCode: -1743), .notPermitted)
        XCTAssertEqual(LiveMediaScripting.error(forCode: -1744), .needsConsent)
        XCTAssertEqual(LiveMediaScripting.error(forCode: -1712), .timedOut)
        XCTAssertEqual(LiveMediaScripting.error(forCode: -600), .notRunning)
        XCTAssertEqual(LiveMediaScripting.error(forCode: -609), .notRunning)
        XCTAssertEqual(LiveMediaScripting.error(forCode: -1728), .failed(code: -1728))

        XCTAssertEqual(LiveMediaScripting.consent(forStatus: 0), .authorized)
        XCTAssertEqual(LiveMediaScripting.consent(forStatus: -1744), .wouldPrompt)
        XCTAssertEqual(LiveMediaScripting.consent(forStatus: -1743), .denied)
        XCTAssertEqual(LiveMediaScripting.consent(forStatus: -600), .unavailable)
    }

    func testDeadlineOutlastsTheScriptTimeout() {
        XCTAssertEqual(LiveMediaScripting.scriptTimeoutSeconds, 2)
        XCTAssertEqual(LiveMediaScripting.deadline, 2.5)
    }

    // MARK: - Demo player

    func testDemoWithoutItemRunsNothingUntilLaunched() async throws {
        let demo = DemoMediaScripting()
        for player in MediaPlayer.allCases {
            XCTAssertFalse(demo.isRunning(player))
            let consent = await demo.consent(for: player, askUser: true)
            XCTAssertEqual(consent, .unavailable)
            let item = await demo.nowPlaying(player)
            XCTAssertNil(item)
        }
        do {
            _ = try await demo.run(.pause, on: .music, allowLaunch: false)
            XCTFail("a player that isn't running can't be paused")
        } catch {
            XCTAssertEqual(error as? MediaScriptingError, .notRunning)
        }

        let state = try await demo.run(.play, on: .music, allowLaunch: true)
        XCTAssertEqual(state, .playing)
        XCTAssertTrue(demo.isRunning(.music))
        XCTAssertFalse(demo.isRunning(.spotify))
        let consent = await demo.consent(for: .music, askUser: false)
        XCTAssertEqual(consent, .authorized)
        let item = await demo.nowPlaying(.music)
        XCTAssertEqual(item?.state, .playing)
        XCTAssertEqual(item?.player, .music)
    }

    func testDemoTransportAndSeek() async throws {
        let seeded = NowPlayingItem(id: "com.spotify.client|seed", player: .spotify, title: "Seed", artist: "Artist",
                                    album: "Album", duration: 200, position: 10, positionDate: Date(), state: .paused,
                                    artworkURL: URL(string: "https://i.scdn.co/image/seed"))
        let demo = DemoMediaScripting(item: seeded)
        XCTAssertTrue(demo.isRunning(.spotify))
        let first = await demo.nowPlaying(.spotify)
        XCTAssertEqual(first?.title, "Seed")
        XCTAssertNil(first?.artworkURL, "the demo player never hands out a network address")

        var state = try await demo.run(.playPause, on: .spotify, allowLaunch: false)
        XCTAssertEqual(state, .playing)
        state = try await demo.run(.playPause, on: .spotify, allowLaunch: false)
        XCTAssertEqual(state, .paused)

        state = try await demo.run(.seek(500), on: .spotify, allowLaunch: false)
        XCTAssertEqual(state, .paused)
        let sought = await demo.nowPlaying(.spotify)
        XCTAssertEqual(sought?.position, 200, "seeks clamp to the duration")

        _ = try await demo.run(.next, on: .spotify, allowLaunch: false)
        let next = await demo.nowPlaying(.spotify)
        XCTAssertNotEqual(next?.title, "Seed")
        XCTAssertEqual(next?.position, 0)
        _ = try await demo.run(.previous, on: .spotify, allowLaunch: false)
        let previous = await demo.nowPlaying(.spotify)
        XCTAssertNotEqual(previous?.id, next?.id)
    }

    // MARK: - Helpers

    private func list(_ values: [Any]) -> NSAppleEventDescriptor {
        let descriptor = NSAppleEventDescriptor.list()
        for (index, value) in values.enumerated() {
            let item: NSAppleEventDescriptor
            switch value {
            case let string as String: item = NSAppleEventDescriptor(string: string)
            case let double as Double: item = NSAppleEventDescriptor(double: double)
            case let int as Int: item = NSAppleEventDescriptor(int32: Int32(int))
            default: item = NSAppleEventDescriptor.null()
            }
            descriptor.insert(item, at: index + 1)
        }
        return descriptor
    }
}
