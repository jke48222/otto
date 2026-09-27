//
//  VoiceController.swift
//  Otto
//
//  One voice session at a time: starts a speech engine for a hold or a toggle, keeps the live transcript,
//  and ends the session exactly once. Only a release, the mic button, Return or trailing silence can send;
//  the 2-minute cap, the no-speech timeout, a lost microphone and the Mac locking or sleeping never do.
//  It also owns the reply speaker so listening and reading aloud never overlap.
//

import Foundation
import Observation
import os

@MainActor @Observable final class VoiceController {
    /// Notices this controller raises through `onNotice`.
    enum Notice {
        static let noMicrophone = "No microphone is connected. Stopped listening."
        static let heardNothing = "Didn't hear anything, so Otto stopped listening."
        static let timeLimit = "Stopped after 2 minutes. Your words are in the message box."
        static let timeLimitNothingHeard = "Stopped listening after 2 minutes."
        static let screenLocked = "Your screen locked, so Otto stopped listening."
        static let asleep = "Your Mac went to sleep, so Otto stopped listening."
        static let userSwitched = "You switched users, so Otto stopped listening."

        static func text(for interruption: VoiceInterruption) -> String {
            switch interruption {
            case .screenLocked: return screenLocked
            case .willSleep, .screensDidSleep: return asleep
            case .sessionResignedActive: return userSwitched
            }
        }
    }

    /// Toggle mode: the level counts as silence below this (0…1 meter scale).
    static let silenceLevel: Float = 0.08
    /// How long a hold probe gets to read "down" before it is ignored for the session (the hold threshold).
    static let holdProbeGrace: Duration = .milliseconds(Int((VoiceMetrics.holdThreshold * 1000).rounded()))

    private(set) var phase: VoicePhase
    private(set) var mode: VoiceMode?
    /// Confirmed words.
    private(set) var finalizedText: String
    /// The latest partial tail (the last word the recognizer may still revise).
    private(set) var volatileText: String

    /// Finalized + volatile, trimmed.
    var transcript: String {
        [finalizedText, volatileText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var isActive: Bool { phase != .idle }
    var isListening: Bool { phase == .listening }
    private(set) var isSpeaking: Bool
    /// The running session's meter (read directly by the waveform, not through Observation).
    @ObservationIgnored private(set) var meter: AudioLevelMeter
    @ObservationIgnored let speaker: ReplySpeaker

    /// Exactly once per session: nil transcript = cancelled. `send` is always false for a session ended by the
    /// watchdog, the no-speech timeout or an interruption (those never auto-send).
    @ObservationIgnored var onFinished: ((_ transcript: String?, _ send: Bool) -> Void)?
    /// A line for the notice slot, after onFinished, when a session ended on its own.
    @ObservationIgnored var onNotice: ((String) -> Void)?
    /// A recognition error that ended the session (for example `.dictationDisabled`), after onFinished.
    /// While nil, the error's description goes to onNotice instead.
    @ObservationIgnored var onError: ((VoiceError) -> Void)?

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Voice")

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let makeEngine: @MainActor () -> SpeechEngine
    @ObservationIgnored private let interruptions: VoiceInterruptionSource
    @ObservationIgnored private let holdProbe: VoiceHoldProbe
    @ObservationIgnored private let clock: any Clock<Duration>

    @ObservationIgnored private var engine: SpeechEngine?
    /// Bumped whenever a session starts or ends, so callbacks and ticks from an old session do nothing.
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var pendingSend = false
    @ObservationIgnored private var pendingNotice: String?
    @ObservationIgnored private var finishingSinceTick = 0
    @ObservationIgnored private var quietTicks = 0
    @ObservationIgnored private var holdProbeTrusted = false
    @ObservationIgnored private var holdProbeIgnored = false
    @ObservationIgnored private var endedByTimeLimit = false

    init(settings: AppSettings, makeEngine: @escaping @MainActor () -> SpeechEngine = { SFSpeechEngine() },
         speaker: ReplySpeaker? = nil,
         interruptions: VoiceInterruptionSource = SystemVoiceInterruptions(),
         holdProbe: VoiceHoldProbe? = nil,
         clock: any Clock<Duration> = ContinuousClock()) {
        self.settings = settings
        self.makeEngine = makeEngine
        self.interruptions = interruptions
        self.holdProbe = holdProbe ?? VoiceHoldProbes.live(settings: settings)
        self.clock = clock
        let speaker = speaker ?? ReplySpeaker(settings: settings)
        self.speaker = speaker
        phase = .idle
        mode = nil
        finalizedText = ""
        volatileText = ""
        isSpeaking = speaker.isSpeaking
        meter = AudioLevelMeter()
        speaker.onSpeakingChange = { [weak self] speaking in
            self?.isSpeaking = speaking
        }
    }

    // MARK: - Session

    /// Permissions must already be granted (the VM checks). Throws VoiceError. Does nothing while a session runs.
    func start(_ mode: VoiceMode) throws {
        guard phase == .idle else { return }
        speaker.stop()

        let engine = makeEngine()
        session += 1
        let session = session
        engine.onTranscript = { [weak self] text, isFinal in
            self?.engineTranscript(text, isFinal: isFinal, session: session)
        }
        engine.onError = { [weak self] error in
            self?.engineError(error, session: session)
        }
        engine.onInputDeviceChanged = { [weak self] in
            self?.engineLostInput(session: session)
        }
        self.engine = engine
        meter = engine.meter
        self.mode = mode
        finalizedText = ""
        volatileText = ""
        pendingSend = false
        pendingNotice = nil
        tick = 0
        finishingSinceTick = 0
        quietTicks = 0
        holdProbeTrusted = false
        holdProbeIgnored = false
        endedByTimeLimit = false
        phase = .preparing

        do {
            try engine.start(locale: settings.voice.locale, allowServer: settings.voice.allowServerRecognition)
        } catch {
            let voiceError = (error as? VoiceError) ?? .audioEngine(error.localizedDescription)
            Self.logger.error("Voice session didn't start: \(String(describing: voiceError), privacy: .public)")
            detachEngine()
            resetState()
            throw voiceError
        }

        phase = .listening
        interruptions.start { [weak self] interruption in
            self?.interrupted(by: interruption, session: session)
        }
        ticker = makeTicker(session: session)
        Self.logger.info("Voice session started (\(Self.describe(mode), privacy: .public))")
    }

    /// Ends listening and waits up to VoiceMetrics.finishTimeout for the final transcript, then delivers it.
    func finish(send: Bool) {
        guard phase == .listening || phase == .preparing else { return }
        pendingSend = send
        phase = .finishing
        finishingSinceTick = tick
        engine?.finish()
    }

    /// Discards the session: onFinished(nil, false).
    func cancel() {
        guard phase != .idle else { return }
        end(transcript: nil, send: false)
    }

    func stopSpeaking() {
        speaker.stop()
    }

    /// Shows a session without running one (snapshots, promo, previews). `.idle` clears it.
    func debugSeed(phase: VoicePhase, finalized: String, volatile: String, levels: [Float]) {
        if self.phase != .idle {
            session += 1
            detachEngine()
        }
        let meter = AudioLevelMeter()
        for level in levels {
            meter.record(level: level)
        }
        self.meter = meter
        self.phase = phase
        mode = phase == .idle ? nil : (mode ?? .hold(.shortcut))
        finalizedText = finalized
        volatileText = volatile
    }

    // MARK: - Engine callbacks

    private func engineTranscript(_ text: String, isFinal: Bool, session: Int) {
        guard session == self.session, phase != .idle else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            // The best text we have: an empty final never erases words already heard.
            if !trimmed.isEmpty {
                finalizedText = trimmed
                volatileText = ""
            } else {
                finalizedText = transcript
                volatileText = ""
            }
            if phase == .listening {
                // The recognizer ended the request on its own; nothing more can be heard.
                pendingSend = false
            }
            complete()
            return
        }
        guard phase == .listening || phase == .finishing else { return }
        let (confirmed, tail) = Self.split(trimmed)
        if confirmed != finalizedText || tail != volatileText {
            finalizedText = confirmed
            volatileText = tail
            quietTicks = 0
        }
    }

    private func engineError(_ error: VoiceError, session: Int) {
        guard session == self.session, phase != .idle else { return }
        Self.logger.error("Voice session failed: \(String(describing: error), privacy: .public)")
        let heard = transcript
        end(transcript: heard.isEmpty ? nil : heard, send: false)
        if let onError {
            onError(error)
        } else if let description = error.errorDescription {
            onNotice?(description)
        }
    }

    private func engineLostInput(session: Int) {
        guard session == self.session, phase == .listening else { return }
        Self.logger.notice("Voice input device went away")
        pendingNotice = Notice.noMicrophone
        finish(send: false)
    }

    private func interrupted(by interruption: VoiceInterruption, session: Int) {
        guard session == self.session, phase != .idle else { return }
        pendingNotice = Notice.text(for: interruption)
        cancel()
    }

    // MARK: - Ticks (hold probe, trailing silence, timeouts)

    private func makeTicker(session: Int) -> Task<Void, Never> {
        let wait = clock.voicePeriodicSleep(every: VoiceMetrics.holdPollInterval)
        return Task { @MainActor [weak self] in
            var count = 0
            while !Task.isCancelled {
                count += 1
                do { try await wait(count) } catch { return }
                guard let self, self.session == session else { return }
                self.tick = count
                self.handleTick()
            }
        }
    }

    private func handleTick() {
        let interval = VoiceMetrics.holdPollInterval
        switch phase {
        case .finishing:
            if interval * (tick - finishingSinceTick) >= VoiceMetrics.finishTimeout {
                Self.logger.notice("Final transcript didn't arrive in time; using the partial one")
                complete()
            }
        case .listening:
            let elapsed = interval * tick
            if elapsed >= VoiceMetrics.maxUtterance {
                Self.logger.notice("Voice session reached the 2-minute limit")
                endedByTimeLimit = true
                finish(send: false)
                return
            }
            switch mode {
            case .hold(let source):
                pollHoldProbe(source: source, elapsed: elapsed)
            case .toggle:
                if transcript.isEmpty {
                    if elapsed >= VoiceMetrics.toggleNoSpeechTimeout {
                        Self.logger.notice("No speech in toggle mode; cancelling")
                        pendingNotice = Notice.heardNothing
                        cancel()
                    }
                } else {
                    quietTicks = meter.currentLevel < Self.silenceLevel ? quietTicks + 1 : 0
                    if interval * quietTicks >= VoiceMetrics.trailingSilence {
                        finish(send: settings.voice.autoSend)
                    }
                }
            case nil:
                break
            }
        case .idle, .preparing:
            break
        }
    }

    /// Once the probe has read "down", reading "up" ends the session like the release event. A probe that never
    /// reads "down" in the first 300 ms is ignored for the session (it may be gated by Secure Input).
    private func pollHoldProbe(source: VoiceSource, elapsed: Duration) {
        guard !holdProbeIgnored else { return }
        switch holdProbe(source) {
        case true?:
            holdProbeTrusted = true
        case false? where holdProbeTrusted:
            Self.logger.info("Held control is up; finishing like a release")
            finish(send: true)
        default:
            if !holdProbeTrusted, elapsed >= Self.holdProbeGrace {
                holdProbeIgnored = true
            }
        }
    }

    // MARK: - Ending

    private func complete() {
        guard phase != .idle else { return }
        let heard = transcript
        if endedByTimeLimit {
            pendingNotice = heard.isEmpty ? Notice.timeLimitNothingHeard : Notice.timeLimit
        }
        end(transcript: heard, send: pendingSend)
    }

    /// Tears the session down, then reports it: onFinished, then the pending notice.
    private func end(transcript: String?, send: Bool) {
        let notice = pendingNotice
        session += 1
        detachEngine()
        resetState()
        Self.logger.info(
            "Voice session ended (cancelled: \(transcript == nil, privacy: .public), send: \(send, privacy: .public))")
        onFinished?(transcript, send)
        if let notice {
            onNotice?(notice)
        }
    }

    private func detachEngine() {
        ticker?.cancel()
        ticker = nil
        interruptions.stop()
        if let engine {
            engine.onTranscript = nil
            engine.onError = nil
            engine.onInputDeviceChanged = nil
            engine.cancel()
        }
        engine = nil
        meter.reset()
    }

    private func resetState() {
        phase = .idle
        mode = nil
        finalizedText = ""
        volatileText = ""
        pendingSend = false
        pendingNotice = nil
        endedByTimeLimit = false
    }

    // MARK: - Helpers

    /// A partial result → (confirmed words, last word). The recognizer mostly revises the word it is on.
    private static func split(_ text: String) -> (String, String) {
        guard let lastSpace = text.lastIndex(where: \.isWhitespace) else { return ("", text) }
        let confirmed = text[..<lastSpace].trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = text[text.index(after: lastSpace)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (confirmed, tail)
    }

    private static func describe(_ mode: VoiceMode) -> String {
        switch mode {
        case .hold(let source): return "hold, \(source)"
        case .toggle(let source): return "toggle, \(source)"
        }
    }
}

fileprivate extension Clock where Duration == Swift.Duration {
    /// Sleeps until `start + interval × n`, with `start` read now, so ticks don't drift and a clock that jumps
    /// ahead (tests) runs every due tick in order.
    func voicePeriodicSleep(every interval: Swift.Duration) -> @Sendable (Int) async throws -> Void {
        let start = now
        return { count in
            try await self.sleep(until: start.advanced(by: interval * count), tolerance: nil)
        }
    }
}
