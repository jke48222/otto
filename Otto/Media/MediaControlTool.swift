//
//  MediaControlTool.swift
//  Otto
//
//  The media_control tool: Claude can play, pause and skip in Music or Spotify. It runs without a card (low
//  impact, easy to undo, sends nothing anywhere) through the same NowPlayingMonitor and scripting seam as the
//  Now Playing strip, so commands and the strip agree on which player is meant.
//

import Foundation
import os

struct MediaControlTool: OttoTool {
    /// What the model may ask for.
    enum Action: String, CaseIterable, Sendable {
        case play, pause, next, previous

        var command: MediaCommand {
            switch self {
            case .play: return .play
            case .pause: return .pause
            case .next: return .next
            case .previous: return .previous
            }
        }
    }

    /// A validated input.
    struct Request: Equatable, Sendable {
        let action: Action
        /// nil = whichever player is playing (or the one that is running).
        let app: MediaPlayer?
    }

    /// Wait before reading the track after a command that can change it, so the player has moved on.
    static let settleDelay: Duration = .milliseconds(250)
    /// No track read after a command that already took this long (the tool times out at 5 s).
    static let trackReadBudget: Duration = .seconds(3)

    let name = "media_control"
    let group: ToolGroup? = .media
    let description = "Play, pause, or skip tracks in Music or Spotify. Without `app`, controls whichever of the two is currently playing (or the one that is running)."
    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["play", "pause", "next", "previous"]],
            "app": ["type": "string", "enum": ["Music", "Spotify"]],
        ],
        "required": ["action"],
        "additionalProperties": false,
    ]
    /// Commands apply in the order the model sent them.
    let isConcurrencySafe = false
    let timeout: Duration = .seconds(5)
    let rateLimit = ToolRateLimit(perTurn: 6, perHour: 60)
    let sampleInput: JSONValue = ["action": "pause", "app": "Music"]

    private let monitor: NowPlayingMonitor

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Actions")

    init(monitor: NowPlayingMonitor) {
        self.monitor = monitor
    }

    @MainActor func isAvailable(in environment: ToolEnvironment) -> Bool {
        environment.isDemo || environment.settings.actions.isEnabled(.media)
    }

    /// Automation for the target player, only while it runs. A player that isn't running can't be asked yet; when
    /// `play` launches it, macOS may ask during the run instead (reported through `reportSystemDialog`).
    func requiredPermissions(for input: JSONValue) -> [Permission] {
        guard let request = Self.request(from: input),
              let player = monitor.targetPlayer(for: request.app),
              monitor.scripting.isRunning(player)
        else { return [] }
        return [Self.automation(player)]
    }

    func approvalRequirement(for input: JSONValue) -> ApprovalRequirement { .none }

    func validate(_ input: JSONValue) -> ToolError? {
        Self.request(from: input) == nil ? Self.invalidInput : nil
    }

    func describe(_ input: JSONValue) -> ToolCallPresentation {
        guard let request = Self.request(from: input) else { return .generic(toolName: name) }
        let target = request.app?.displayName
        let symbol: String
        let title: String
        let activeTitle: String
        let doneTitle: String
        switch request.action {
        case .play:
            symbol = "play.fill"
            title = target.map { "Play \($0)" } ?? "Play music"
            activeTitle = target.map { "Starting \($0)…" } ?? "Starting music…"
            doneTitle = target.map { "Playing \($0)" } ?? "Playing music"
        case .pause:
            symbol = "pause.fill"
            title = target.map { "Pause \($0)" } ?? "Pause the music"
            activeTitle = target.map { "Pausing \($0)…" } ?? "Pausing the music…"
            doneTitle = target.map { "Paused \($0)" } ?? "Paused the music"
        case .next:
            symbol = "forward.fill"
            title = target.map { "Skip to the next track in \($0)" } ?? "Skip to the next track"
            activeTitle = "Skipping…"
            doneTitle = "Skipped to the next track"
        case .previous:
            symbol = "backward.fill"
            title = target.map { "Go back a track in \($0)" } ?? "Go back a track"
            activeTitle = "Going back…"
            doneTitle = "Went back a track"
        }
        return ToolCallPresentation(symbol: symbol, title: title, activeTitle: activeTitle, doneTitle: doneTitle,
                                    detail: nil, disclosure: nil)
    }

    /// Never shown (the tool needs no card); spells out the raw request so it stays what-you-see-is-what-runs.
    func approvalBody(for input: JSONValue) async -> ApprovalBody {
        let action = input["action"]?.stringValue ?? ""
        let target = input["app"]?.stringValue ?? "the player that's playing"
        return .text(TextPreview(label: ToolGroup.media.displayName, text: "Send “\(action)” to \(target)", language: nil))
    }

    func run(_ input: JSONValue, context: ToolRunContext) async throws -> ToolRunResult {
        guard let request = Self.request(from: input) else { throw Self.invalidInput }
        let clock = ContinuousClock()
        let started = clock.now
        let scripting = monitor.scripting
        let anyRunning = MediaPlayer.allCases.contains { scripting.isRunning($0) }
        // The user asked for music: `play` may open a named player, or Music when nothing is running.
        let allowLaunch = request.action == .play && (request.app != nil || !anyRunning)
        guard let target = monitor.targetPlayer(for: request.app) ?? (allowLaunch ? .music : nil) else {
            throw Self.notRunning(nil)
        }

        var outcome = await monitor.perform(request.action.command, on: target, allowLaunch: allowLaunch)
        if case .needsConsent(let player) = outcome {
            // Only reached when the player wasn't running at the pre-check (or started meanwhile): macOS asks now.
            context.reportSystemDialog(player.displayName)
            let consent = await scripting.consent(for: player, askUser: true)
            context.reportSystemDialog(nil)
            try Task.checkCancellation()
            switch consent {
            case .authorized:
                outcome = await monitor.perform(request.action.command, on: player, allowLaunch: allowLaunch)
            case .denied:
                outcome = .denied(player)
            case .wouldPrompt, .unavailable:
                break
            }
        }
        try Task.checkCancellation()

        switch outcome {
        case .done(let state):
            var track: NowPlayingItem?
            if clock.now - started < Self.trackReadBudget {
                if request.action != .pause { try await Task.sleep(for: Self.settleDelay) }
                track = await scripting.nowPlaying(target)
            }
            Self.logger.info("media_control \(request.action.rawValue, privacy: .public) ran in \(target.displayName, privacy: .public)")
            return Self.result(for: request.action, player: target, commandState: state, track: track)
        case .notRunning:
            throw Self.notRunning(request.app)
        case .needsConsent(let player), .denied(let player):
            throw Self.permissionDenied(player)
        case .failed(let message):
            throw ToolError(code: .failed, modelMessage: message, userMessage: Self.rowReason(message))
        }
    }

    // MARK: - Internal for tests

    /// The validated request, or nil when `action` or `app` is missing, not a string, or not one of the enums.
    static func request(from input: JSONValue) -> Request? {
        guard let object = input.objectValue,
              object.keys.allSatisfy({ $0 == "action" || $0 == "app" }),
              let action = object["action"]?.stringValue.flatMap(Action.init(rawValue:))
        else { return nil }
        guard let appValue = object["app"] else { return Request(action: action, app: nil) }
        guard let appName = appValue.stringValue, let app = MediaPlayer(displayName: appName) else { return nil }
        return Request(action: action, app: app)
    }

    /// `{"app","artist","state","status":"ok","track"}`, compact with sorted keys; unknown fields are left out.
    static func result(for action: Action, player: MediaPlayer, commandState: PlaybackState?,
                       track: NowPlayingItem?) -> ToolRunResult {
        let state = track?.state ?? commandState
        var object: [String: JSONValue] = ["status": "ok", "app": .string(player.displayName)]
        if let state { object["state"] = .string(state.rawValue) }
        let title = track.map { DisplayText.sanitized($0.title, maxLength: NowPlayingItem.maxTextLength) } ?? ""
        let artist = track.map { DisplayText.sanitized($0.artist, maxLength: NowPlayingItem.maxTextLength) } ?? ""
        if !title.isEmpty { object["track"] = .string(title) }
        if !artist.isEmpty { object["artist"] = .string(artist) }

        let doneTitle: String
        switch action {
        case .pause:
            doneTitle = "Paused \(player.displayName)"
        case .play, .next, .previous:
            if !title.isEmpty, state != .paused {
                let shortTitle = DisplayText.sanitized(title, maxLength: 80)
                let shortArtist = DisplayText.sanitized(artist, maxLength: 60)
                doneTitle = shortArtist.isEmpty ? "Playing “\(shortTitle)”" : "Playing “\(shortTitle)” by \(shortArtist)"
            } else if action == .play {
                doneTitle = "Playing \(player.displayName)"
            } else if action == .next {
                doneTitle = "Skipped to the next track in \(player.displayName)"
            } else {
                doneTitle = "Went back a track in \(player.displayName)"
            }
        }
        return ToolRunResult(output: .text(JSONValue.object(object).encodedString()), doneTitle: doneTitle)
    }

    // MARK: - Private

    private static let invalidInput = ToolError(
        code: .invalidInput,
        modelMessage: "$.action must be one of play, pause, next or previous, and $.app, when given, must be Music or Spotify. Fix the input and call the tool again.",
        userMessage: "Invalid request"
    )

    private static func automation(_ player: MediaPlayer) -> Permission {
        .automation(bundleID: player.rawValue, appName: player.displayName)
    }

    private static func notRunning(_ app: MediaPlayer?) -> ToolError {
        guard let app else {
            return ToolError(code: .notRunning, modelMessage: "Neither Music nor Spotify is running.",
                             userMessage: "Neither Music nor Spotify is running")
        }
        return ToolError(code: .notRunning,
                         modelMessage: "\(app.displayName) isn't running. Only play can open it.",
                         userMessage: "\(app.displayName) isn't running")
    }

    private static func permissionDenied(_ player: MediaPlayer) -> ToolError {
        let permission = automation(player)
        return ToolError(
            code: .permissionDenied,
            modelMessage: "Otto doesn't have \(permission.displayName) access. The user can allow it in System Settings → Privacy & Security → \(permission.settingsPaneName).",
            userMessage: "Otto isn't allowed to control \(player.displayName)",
            recovery: .openSystemSettings(permission)
        )
    }

    /// Row copy is a short reason without the closing period ("Spotify didn't respond").
    private static func rowReason(_ message: String) -> String {
        message.hasSuffix(".") ? String(message.dropLast()) : message
    }
}
