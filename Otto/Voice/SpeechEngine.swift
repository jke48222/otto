//
//  SpeechEngine.swift
//  Otto
//
//  Speech to text for voice mode. SFSpeechEngine runs the microphone through AVAudioEngine into Apple's
//  recognizer (on this Mac unless the user allowed Apple's service), only between start and finish or
//  cancel. ScriptedSpeechEngine plays a fixed script so tests, SelfTest and snapshots never touch the mic.
//

import AVFoundation
import Foundation
import os
import Speech

protocol SpeechEngine: AnyObject {
    var onTranscript: (@MainActor (_ text: String, _ isFinal: Bool) -> Void)? { get set }
    var onError: (@MainActor (VoiceError) -> Void)? { get set }
    var onInputDeviceChanged: (@MainActor () -> Void)? { get set }
    var meter: AudioLevelMeter { get }
    /// Main actor call; throws VoiceError.
    func start(locale: Locale, allowServer: Bool) throws
    /// Stops the audio and ends the request; the final transcript arrives through onTranscript(isFinal: true).
    func finish()
    /// Stops everything; no callback fires afterwards.
    func cancel()
}

/// Runs a callback on the main actor after everything already queued there, in the order it was scheduled.
private func voiceDeliverOnMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated(body)
    }
}

// MARK: - SFSpeechEngine

final class SFSpeechEngine: SpeechEngine, @unchecked Sendable {
    enum RouteChangeAction: Equatable { case restart, stop }

    var onTranscript: (@MainActor (_ text: String, _ isFinal: Bool) -> Void)?
    var onError: (@MainActor (VoiceError) -> Void)?
    var onInputDeviceChanged: (@MainActor () -> Void)?
    let meter = AudioLevelMeter()

    private enum State { case idle, listening, finishing, done }

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Voice")
    private static let tapBufferSize: AVAudioFrameCount = 1024

    /// Every property below is read and written only on this queue.
    private let queue = DispatchQueue(label: "com.jalenedusei.otto.voice.engine", qos: .userInitiated)
    private var state = State.idle
    private var audioEngine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var configurationObserver: NSObjectProtocol?
    private var isTapInstalled = false
    private var restarts = 0
    private var lastText = ""
    private var localeName = ""

    init() {}

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        task?.cancel()
        if let audioEngine {
            audioEngine.stop()
            if isTapInstalled { audioEngine.inputNode.removeTap(onBus: 0) }
        }
    }

    func start(locale: Locale, allowServer: Bool) throws {
        try queue.sync {
            if state != .idle { stopAudio(); tearDownRecognition() }
            try begin(locale: locale, allowServer: allowServer)
        }
    }

    func finish() {
        queue.sync {
            guard state == .listening else { return }
            state = .finishing
            stopAudio()
            request?.endAudio()
            removeConfigurationObserver()
            Self.logger.debug("Speech engine finishing after \(self.restarts, privacy: .public) restarts")
        }
    }

    func cancel() {
        queue.sync {
            guard state != .idle else { return }
            state = .done
            stopAudio()
            tearDownRecognition()
            meter.reset()
        }
    }

    /// Pure: Speech errors → VoiceError. Codes from SFSpeechRecognitionTask.h.
    static func voiceError(domain: String, code: Int, description: String, localeName: String) -> VoiceError? {
        switch (domain, code) {
        case ("kLSRErrorDomain", 201):
            return .dictationDisabled
        case ("kLSRErrorDomain", 102):
            return .onDeviceUnavailable(localeName: localeName)
        case ("kAFAssistantErrorDomain", 1700):
            return .speechDenied
        case ("kAFAssistantErrorDomain", 1110), ("kLSRErrorDomain", 301):
            return nil
        default:
            return .recognition(description)
        }
    }

    /// Pure: after AVAudioEngineConfigurationChange, restart while the input still has a format and the
    /// session has restarts left; otherwise stop.
    static func routeChangeAction(sampleRate: Double, channelCount: UInt32, restartsSoFar: Int) -> RouteChangeAction {
        let hasInput = sampleRate > 0 && channelCount > 0
        return hasInput && restartsSoFar < VoiceMetrics.maxEngineRestarts ? .restart : .stop
    }

    // MARK: - Session (on `queue`)

    private func begin(locale: Locale, allowServer: Bool) throws {
        let name = Self.displayName(of: locale)
        localeName = name
        lastText = ""
        restarts = 0
        meter.reset()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: throw VoiceError.microphoneDenied
        default: break
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted: throw VoiceError.speechDenied
        default: break
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw VoiceError.recognizerUnavailable(localeName: name)
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        } else if !allowServer {
            throw VoiceError.onDeviceUnavailable(localeName: name)
        }

        let audioEngine = AVAudioEngine()
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noInputDevice }

        self.audioEngine = audioEngine
        self.recognizer = recognizer
        self.request = request
        installTap(on: audioEngine, format: format, request: request)
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            let nsError = error as NSError
            Self.logger.error(
                "Audio engine failed to start: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
            stopAudio()
            tearDownRecognition()
            state = .idle
            throw VoiceError.audioEngine(nsError.localizedDescription)
        }

        state = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let nsError = error.map { $0 as NSError }
            self?.queue.async { self?.handleRecognition(text: text, isFinal: isFinal, error: nsError) }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: nil
        ) { [weak self] _ in
            // Never inside the notification callback: the engine posts it while reconfiguring itself.
            self?.queue.async { self?.handleConfigurationChange() }
        }
        Self.logger.info(
            "Speech engine listening (on device: \(request.requiresOnDeviceRecognition, privacy: .public))")
    }

    private func installTap(on audioEngine: AVAudioEngine, format: AVAudioFormat,
                            request: SFSpeechAudioBufferRecognitionRequest) {
        let meter = meter
        audioEngine.inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) { buffer, _ in
            request.append(buffer)
            meter.ingest(buffer)
        }
        isTapInstalled = true
    }

    private func handleConfigurationChange() {
        guard state == .listening, let audioEngine, let request else { return }
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        let action = Self.routeChangeAction(
            sampleRate: format.sampleRate, channelCount: format.channelCount, restartsSoFar: restarts)
        Self.logger.info("Audio route changed: \(String(describing: action), privacy: .public)")
        if action == .restart {
            restarts += 1
            if isTapInstalled {
                audioEngine.inputNode.removeTap(onBus: 0)
                isTapInstalled = false
            }
            installTap(on: audioEngine, format: format, request: request)
            meter.reset()
            audioEngine.prepare()
            do {
                try audioEngine.start()
                return
            } catch {
                let nsError = error as NSError
                Self.logger.error(
                    "Audio engine restart failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
            }
        }
        stopAudio()
        voiceDeliverOnMain { [weak self] in self?.onInputDeviceChanged?() }
    }

    private func handleRecognition(text: String?, isFinal: Bool, error: NSError?) {
        guard state == .listening || state == .finishing else { return }
        if let text {
            lastText = text
            if isFinal { finishRecognition() }
            voiceDeliverOnMain { [weak self] in self?.onTranscript?(text, isFinal) }
            return
        }
        guard let error else { return }
        let mapped = Self.voiceError(
            domain: error.domain, code: error.code, description: error.localizedDescription, localeName: localeName)
        Self.logger.notice(
            "Recognition ended with \(error.domain, privacy: .public) \(error.code, privacy: .public)")
        finishRecognition()
        if let mapped {
            voiceDeliverOnMain { [weak self] in self?.onError?(mapped) }
        } else {
            // No speech, or the request ended: whatever was heard is the final transcript.
            let text = lastText
            voiceDeliverOnMain { [weak self] in self?.onTranscript?(text, true) }
        }
    }

    /// The recognizer is done with this request: nothing more arrives, and the microphone is released.
    private func finishRecognition() {
        state = .done
        stopAudio()
        removeConfigurationObserver()
    }

    private func stopAudio() {
        guard let audioEngine else { return }
        audioEngine.stop()
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
    }

    private func tearDownRecognition() {
        removeConfigurationObserver()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        audioEngine = nil
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    private static func displayName(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

// MARK: - ScriptedSpeechEngine

/// Plays a fixed script instead of listening: each step waits its delay (after the previous step), shows
/// its level on the meter and reports its text as a partial result. finish() reports the last step's text as
/// the final transcript, the way the recognizer finalizes everything that was said. After a route change
/// without input, the final transcript is what was heard before the microphone went away.
final class ScriptedSpeechEngine: SpeechEngine {
    var onTranscript: (@MainActor (_ text: String, _ isFinal: Bool) -> Void)?
    var onError: (@MainActor (VoiceError) -> Void)?
    var onInputDeviceChanged: (@MainActor () -> Void)?
    let meter = AudioLevelMeter()

    /// True between start and finish or cancel while the (pretend) microphone is live.
    private(set) var isRunning = false
    /// How many times start was called.
    private(set) var startCount = 0

    private let script: [(delay: Duration, text: String, level: Float)]
    private var playback: Task<Void, Never>?
    private var generation = 0
    private var isSessionOpen = false
    private var lostInput = false
    private var heardText = ""

    init(script: [(delay: Duration, text: String, level: Float)]) {
        self.script = script
    }

    deinit {
        playback?.cancel()
    }

    func start(locale: Locale, allowServer: Bool) throws {
        playback?.cancel()
        generation += 1
        isRunning = true
        isSessionOpen = true
        lostInput = false
        heardText = ""
        startCount += 1
        meter.reset()
        let generation = generation
        let script = script
        playback = Task { @MainActor [weak self] in
            for step in script {
                if step.delay > .zero {
                    do { try await Task.sleep(for: step.delay) } catch { return }
                } else {
                    await Task.yield()
                }
                guard let self, self.isRunning, self.generation == generation else { return }
                self.meter.record(level: step.level)
                self.heardText = step.text
                self.onTranscript?(step.text, false)
            }
        }
    }

    func finish() {
        guard isSessionOpen else { return }
        isSessionOpen = false
        stopPlayback()
        let generation = generation
        let text = lostInput ? heardText : (script.last?.text ?? "")
        voiceDeliverOnMain { [weak self] in
            guard let self, self.generation == generation else { return }
            self.onTranscript?(text, true)
        }
    }

    func cancel() {
        isSessionOpen = false
        stopPlayback()
        generation += 1
        meter.reset()
    }

    /// Models SFSpeechEngine's route-change contract: hasInput → keeps listening (no callback);
    /// otherwise the microphone stops and onInputDeviceChanged fires.
    func simulateConfigurationChange(hasInput: Bool) {
        guard isRunning else { return }
        meter.reset()
        if hasInput { return }
        lostInput = true
        stopPlayback()
        let generation = generation
        voiceDeliverOnMain { [weak self] in
            guard let self, self.generation == generation else { return }
            self.onInputDeviceChanged?()
        }
    }

    /// Reports a recognition error the way SFSpeechEngine does, after the current main-actor work.
    func simulateError(_ error: VoiceError) {
        let generation = generation
        voiceDeliverOnMain { [weak self] in
            guard let self, self.generation == generation else { return }
            self.onError?(error)
        }
    }

    private func stopPlayback() {
        isRunning = false
        playback?.cancel()
        playback = nil
    }
}
