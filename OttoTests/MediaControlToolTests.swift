//
//  MediaControlToolTests.swift
//  OttoTests
//
//  The media_control tool: its contract with the executor (group, ordering, no card, 5 s, rate limits, strict
//  wire schema), which player it targets and when it may launch one, the Automation permission it declares, the
//  JSON it returns, and the not_running and consent paths. Everything runs through DemoMediaScripting or a
//  private fake; no test sends an Apple Event.
//

import AppKit
import XCTest
@testable import Otto

@MainActor
final class MediaControlToolTests: XCTestCase {
    // MARK: - Contract

    func testToolContract() throws {
        let tool = MediaControlTool(monitor: makeMonitor(ControlFakeScripting()))
        XCTAssertEqual(tool.name, "media_control")
        XCTAssertEqual(tool.group, .media)
        XCTAssertFalse(tool.isConcurrencySafe, "commands apply in model order")
        XCTAssertEqual(tool.timeout, .seconds(5))
        XCTAssertEqual(tool.rateLimit, ToolRateLimit(perTurn: 6, perHour: 60))
        XCTAssertEqual(tool.approvalRequirement(for: tool.sampleInput), .none)
        XCTAssertFalse(tool.producesUntrustedOutput)
        XCTAssertNil(tool.privateDataSource)
        XCTAssertFalse(tool.mayPresentUI)
        XCTAssertFalse(tool.inheritsOttoPermissions)
        XCTAssertTrue(tool.isStrict)
        XCTAssertNil(tool.validate(tool.sampleInput))
        XCTAssertTrue(tool.egressStrings(in: tool.sampleInput).isEmpty)

        let definition = tool.definition()
        XCTAssertEqual(definition["name"], "media_control")
        XCTAssertEqual(definition["strict"], true)
        XCTAssertEqual(definition["eager_input_streaming"], true)
        let wire = try XCTUnwrap(definition["input_schema"])
        XCTAssertTrue(ToolSchema.isStrictSafe(wire))
        XCTAssertEqual(wire["properties"]?["action"]?["enum"], ["play", "pause", "next", "previous"])
        XCTAssertEqual(wire["properties"]?["app"]?["enum"], ["Music", "Spotify"])
        XCTAssertEqual(wire["required"], ["action"])
        XCTAssertNotNil(tool.name.range(of: ToolSchema.namePattern, options: .regularExpression))
        XCTAssertFalse(ToolSchema.reservedNames.contains(tool.name))
    }

    func testAvailabilityFollowsTheMediaGroup() {
        let tool = MediaControlTool(monitor: makeMonitor(ControlFakeScripting()))
        let settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        XCTAssertFalse(tool.isAvailable(in: environment(settings, demo: false)), "Actions are off by default")
        settings.actions.enabled = true
        XCTAssertTrue(tool.isAvailable(in: environment(settings, demo: false)))
        settings.actions.groups.remove(.media)
        XCTAssertFalse(tool.isAvailable(in: environment(settings, demo: false)))
        XCTAssertTrue(tool.isAvailable(in: environment(settings, demo: true)), "demo counts every group but AppleScript as on")
    }

    func testRequestParsing() {
        XCTAssertEqual(MediaControlTool.request(from: ["action": "pause"]),
                       MediaControlTool.Request(action: .pause, app: nil))
        XCTAssertEqual(MediaControlTool.request(from: ["action": "next", "app": "Spotify"]),
                       MediaControlTool.Request(action: .next, app: .spotify))
        XCTAssertNil(MediaControlTool.request(from: ["action": "stop"]))
        XCTAssertNil(MediaControlTool.request(from: ["action": "play", "app": "iTunes"]))
        XCTAssertNil(MediaControlTool.request(from: ["action": "play", "app": "com.apple.Music"]))
        XCTAssertNil(MediaControlTool.request(from: ["action": "play", "app": .null]))
        XCTAssertNil(MediaControlTool.request(from: ["action": "play", "volume": 10]))
        XCTAssertNil(MediaControlTool.request(from: ["app": "Music"]))
        XCTAssertNil(MediaControlTool.request(from: "pause"))
        let tool = MediaControlTool(monitor: makeMonitor(ControlFakeScripting()))
        XCTAssertEqual(tool.validate(["action": "rewind"])?.code, .invalidInput)
    }

    func testPresentationAndBodyShowTheRequest() async {
        let tool = MediaControlTool(monitor: makeMonitor(ControlFakeScripting()))
        let pause = tool.describe(tool.sampleInput)
        XCTAssertEqual(pause.symbol, "pause.fill")
        XCTAssertEqual(pause.title, "Pause Music")
        XCTAssertEqual(pause.activeTitle, "Pausing Music…")
        XCTAssertEqual(pause.doneTitle, "Paused Music")
        XCTAssertEqual(tool.describe(["action": "next"]).title, "Skip to the next track")
        XCTAssertEqual(tool.describe(["action": "play"]).title, "Play music")
        XCTAssertEqual(tool.describe(["action": "previous", "app": "Spotify"]).title, "Go back a track in Spotify")
        XCTAssertEqual(tool.describe(["action": "bogus"]), .generic(toolName: "media_control"))

        let body = await tool.approvalBody(for: tool.sampleInput)
        let shown = body.displayedStrings.joined(separator: "\n")
        for value in ["pause", "Music"] {
            XCTAssertTrue(shown.contains(value), "the body shows “\(value)” verbatim")
        }
    }

    // MARK: - Permissions

    func testAutomationIsRequiredOnlyForARunningTarget() {
        let fake = ControlFakeScripting(running: [.spotify])
        let tool = MediaControlTool(monitor: makeMonitor(fake))
        let spotify = Permission.automation(bundleID: "com.spotify.client", appName: "Spotify")
        XCTAssertEqual(tool.requiredPermissions(for: ["action": "pause", "app": "Spotify"]), [spotify])
        XCTAssertEqual(tool.requiredPermissions(for: ["action": "pause"]), [spotify], "the running player is the target")
        XCTAssertEqual(tool.requiredPermissions(for: ["action": "play", "app": "Music"]), [],
                       "a player that isn't running can't be asked yet")
        fake.setRunning([])
        XCTAssertEqual(tool.requiredPermissions(for: ["action": "play"]), [])
        XCTAssertEqual(tool.requiredPermissions(for: ["action": "wrong"]), [])
    }

    // MARK: - Running

    func testNothingRunningReturnsNotRunning() async {
        let fake = ControlFakeScripting()
        let tool = MediaControlTool(monitor: makeMonitor(fake))
        for action in ["pause", "next", "previous"] {
            await assertToolError(tool, ["action": .string(action)], code: .notRunning,
                                  text: "not_running: Neither Music nor Spotify is running.")
        }
        await assertToolError(tool, ["action": "next", "app": "Spotify"], code: .notRunning,
                              text: "not_running: Spotify isn't running. Only play can open it.")
        XCTAssertTrue(fake.runs.isEmpty, "nothing but play may launch a player")
    }

    func testOnlyPlayMayLaunchAPlayer() async throws {
        let fake = ControlFakeScripting()
        fake.setRunState(.playing)
        let tool = MediaControlTool(monitor: makeMonitor(fake))

        let result = try await tool.run(["action": "play"], context: context())
        XCTAssertEqual(fake.runs, [ControlFakeScripting.Run(command: .play, player: .music, allowLaunch: true)],
                       "play with nothing running opens Music")
        XCTAssertEqual(try json(result), ["app": "Music", "state": "playing", "status": "ok"])
        XCTAssertEqual(result.doneTitle, "Playing Music")

        _ = try await tool.run(["action": "play", "app": "Spotify"], context: context())
        XCTAssertEqual(fake.runs.last, ControlFakeScripting.Run(command: .play, player: .spotify, allowLaunch: true),
                       "play with an explicit app may open it")

        _ = try await tool.run(["action": "pause"], context: context())
        _ = try await tool.run(["action": "next", "app": "Music"], context: context())
        _ = try await tool.run(["action": "play"], context: context())
        XCTAssertEqual(fake.runs.suffix(3).map(\.allowLaunch), [false, false, false],
                       "pause, next and play without app while a player runs never launch")
    }

    func testSuccessReportsTrackAndArtistAsJSON() async throws {
        let fake = ControlFakeScripting(running: [.spotify])
        fake.setRunState(.paused)
        fake.setTrack(NowPlayingItem(id: "com.spotify.client|x", player: .spotify, title: "Nights\u{202E}",
                                     artist: "Frank Ocean", album: "Blonde", duration: 307, position: 12,
                                     positionDate: Date(), state: .paused, artworkURL: nil))
        let tool = MediaControlTool(monitor: makeMonitor(fake))
        let result = try await tool.run(["action": "pause"], context: context())
        XCTAssertFalse(result.output.isError)
        guard case .text(let text) = result.output.parts.first else { return XCTFail("text result expected") }
        XCTAssertEqual(text, #"{"app":"Spotify","artist":"Frank Ocean","state":"paused","status":"ok","track":"Nights"}"#)
        XCTAssertEqual(result.doneTitle, "Paused Spotify")

        fake.setRunState(.playing)
        var playing = try XCTUnwrap(fake.track(.spotify))
        playing.state = .playing
        fake.setTrack(playing)
        let next = try await tool.run(["action": "next"], context: context())
        XCTAssertEqual(next.doneTitle, "Playing “Nights” by Frank Ocean")
    }

    func testConsentAskedDuringTheRunWhenThePlayerWasntRunning() async throws {
        let fake = ControlFakeScripting()
        fake.setConsentAfterLaunch(.wouldPrompt)
        fake.setAnswerWhenAsked(.authorized)
        fake.setRunState(.playing)
        let dialogs = DialogRecorder()
        let tool = MediaControlTool(monitor: makeMonitor(fake))

        XCTAssertEqual(tool.requiredPermissions(for: ["action": "play", "app": "Spotify"]), [],
                       "not running at the pre-check, so no permission card")
        let result = try await tool.run(["action": "play", "app": "Spotify"], context: context(dialogs))
        XCTAssertEqual(dialogs.values, ["Spotify", nil], "the row waits for macOS while the dialog is up")
        XCTAssertEqual(fake.consentChecks.filter(\.askUser).map(\.player), [.spotify])
        XCTAssertEqual(fake.runs.map(\.player), [.spotify], "retried once after the user allowed it")
        XCTAssertEqual(try json(result)["state"], "playing")
    }

    func testConsentRefusedDuringTheRunIsPermissionDenied() async {
        let fake = ControlFakeScripting()
        fake.setConsentAfterLaunch(.wouldPrompt)
        fake.setAnswerWhenAsked(.denied)
        let tool = MediaControlTool(monitor: makeMonitor(fake))
        let error = await assertToolError(
            tool, ["action": "play", "app": "Music"], code: .permissionDenied,
            text: "permission_denied: Otto doesn't have Automation (Music) access. The user can allow it in System Settings → Privacy & Security → Automation."
        )
        XCTAssertEqual(error?.recovery, .openSystemSettings(.automation(bundleID: "com.apple.Music", appName: "Music")))
        XCTAssertEqual(error?.userMessage, "Otto isn't allowed to control Music")
        XCTAssertTrue(fake.runs.isEmpty)
    }

    func testDeniedPlayerIsPermissionDeniedWithoutAsking() async {
        let fake = ControlFakeScripting(running: [.music])
        fake.setConsent(.denied, for: .music)
        let tool = MediaControlTool(monitor: makeMonitor(fake))
        await assertToolError(tool, ["action": "pause"], code: .permissionDenied,
                              text: "permission_denied: Otto doesn't have Automation (Music) access. The user can allow it in System Settings → Privacy & Security → Automation.")
        XCTAssertFalse(fake.consentChecks.contains { $0.askUser }, "a denied player is never asked again")
        XCTAssertTrue(fake.runs.isEmpty)
    }

    func testFailuresAreTypedErrors() async {
        let fake = ControlFakeScripting(running: [.music])
        fake.setRunError(.timedOut)
        let tool = MediaControlTool(monitor: makeMonitor(fake))
        let error = await assertToolError(tool, ["action": "next"], code: .failed, text: "failed: Music didn't respond.")
        XCTAssertEqual(error?.userMessage, "Music didn't respond")
        await assertToolError(tool, ["action": "stop"], code: .invalidInput, text: nil)
    }

    func testDemoScriptingEndToEnd() async throws {
        let seeded = NowPlayingItem(id: "com.spotify.client|demo", player: .spotify, title: "Demo Song", artist: "Demo Artist",
                                    album: "Demo", duration: 180, position: 20, positionDate: Date(), state: .paused,
                                    artworkURL: nil)
        let tool = MediaControlTool(monitor: makeMonitor(DemoMediaScripting(item: seeded)))
        let play = try await tool.run(["action": "play"], context: context())
        XCTAssertEqual(try json(play), ["app": "Spotify", "artist": "Demo Artist", "state": "playing", "status": "ok",
                                        "track": "Demo Song"])
        let pause = try await tool.run(["action": "pause", "app": "Spotify"], context: context())
        XCTAssertEqual(try json(pause)["state"], "paused")
        await assertToolError(tool, ["action": "pause", "app": "Music"], code: .notRunning,
                              text: "not_running: Music isn't running. Only play can open it.")
    }

    // MARK: - Helpers

    private func makeMonitor(_ scripting: MediaScripting) -> NowPlayingMonitor {
        NowPlayingMonitor(settings: AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false),
                          scripting: scripting)
    }

    private func environment(_ settings: AppSettings, demo: Bool) -> ToolEnvironment {
        ToolEnvironment(settings: settings, permissions: nil, model: .opus5, isDemo: demo)
    }

    private func context(_ dialogs: DialogRecorder = DialogRecorder()) -> ToolRunContext {
        ToolRunContext(callID: "toolu_media", model: .opus5, options: ApprovalOptions(), reportProgress: { _ in },
                       reportSystemDialog: { dialogs.append($0) })
    }

    private func json(_ result: ToolRunResult) throws -> [String: String] {
        guard case .text(let text) = result.output.parts.first else {
            XCTFail("text result expected")
            return [:]
        }
        let object = try XCTUnwrap(JSONValue.decode(text).objectValue)
        return object.compactMapValues(\.stringValue)
    }

    @discardableResult
    private func assertToolError(_ tool: MediaControlTool, _ input: JSONValue, code: ToolError.Code, text: String?,
                                 file: StaticString = #filePath, line: UInt = #line) async -> ToolError? {
        do {
            _ = try await tool.run(input, context: context())
            XCTFail("expected \(code.rawValue)", file: file, line: line)
            return nil
        } catch let error as ToolError {
            XCTAssertEqual(error.code, code, file: file, line: line)
            if let text { XCTAssertEqual(error.toolResultText, text, file: file, line: line) }
            return error
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
            return nil
        }
    }
}

/// Collects `reportSystemDialog` calls from the tool (called off the main actor).
private final class DialogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String?] = []

    var values: [String?] { lock.withLock { recorded } }

    func append(_ value: String?) {
        lock.withLock { recorded.append(value) }
    }
}

/// Settable players for the tool: records consent checks and commands; a command throws `.needsConsent` while
/// consent would prompt, like the live scripting. `consentAfterLaunch` is what a player launched by `play` reports;
/// `answerWhenAsked` is the user's answer to the macOS dialog.
private final class ControlFakeScripting: MediaScripting, @unchecked Sendable {
    struct Run: Equatable { let command: MediaCommand; let player: MediaPlayer; let allowLaunch: Bool }

    private let lock = NSLock()
    private var running: Set<MediaPlayer>
    private var consents: [MediaPlayer: BrowserContext.AutomationConsent] = [:]
    private var consentAfterLaunch: BrowserContext.AutomationConsent = .authorized
    private var answerWhenAsked: BrowserContext.AutomationConsent?
    private var tracks: [MediaPlayer: NowPlayingItem] = [:]
    private var runError: MediaScriptingError?
    private var runState: PlaybackState? = .playing
    private var recordedRuns: [Run] = []
    private var recordedChecks: [(player: MediaPlayer, askUser: Bool)] = []

    init(running: Set<MediaPlayer> = []) {
        self.running = running
    }

    var runs: [Run] { lock.withLock { recordedRuns } }
    var consentChecks: [(player: MediaPlayer, askUser: Bool)] { lock.withLock { recordedChecks } }
    func track(_ player: MediaPlayer) -> NowPlayingItem? { lock.withLock { tracks[player] } }

    func setRunning(_ players: Set<MediaPlayer>) { lock.withLock { running = players } }
    func setConsent(_ consent: BrowserContext.AutomationConsent, for player: MediaPlayer) { lock.withLock { consents[player] = consent } }
    func setConsentAfterLaunch(_ consent: BrowserContext.AutomationConsent) { lock.withLock { consentAfterLaunch = consent } }
    func setAnswerWhenAsked(_ consent: BrowserContext.AutomationConsent) { lock.withLock { answerWhenAsked = consent } }
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
            let current = consents[player] ?? .authorized
            if askUser, current == .wouldPrompt, let answerWhenAsked {
                consents[player] = answerWhenAsked
                return answerWhenAsked
            }
            return current
        }
    }

    func run(_ command: MediaCommand, on player: MediaPlayer, allowLaunch: Bool) async throws -> PlaybackState? {
        try lock.withLock {
            if !running.contains(player) {
                guard allowLaunch else { throw MediaScriptingError.notRunning }
                running.insert(player)
                if consents[player] == nil { consents[player] = consentAfterLaunch }
            }
            if (consents[player] ?? .authorized) == .wouldPrompt { throw MediaScriptingError.needsConsent }
            recordedRuns.append(Run(command: command, player: player, allowLaunch: allowLaunch))
            if let runError { throw runError }
            return runState
        }
    }

    func nowPlaying(_ player: MediaPlayer) async -> NowPlayingItem? {
        lock.withLock { running.contains(player) ? tracks[player] : nil }
    }
}
