//
//  VoiceControllerTests.swift
//  OttoTests
//
//  VoiceController on a manual clock with the scripted engine and a spy: phases, the microphone running only
//  inside a session, finish and its timeout, cancel, the 2-minute watchdog that never sends, trailing silence,
//  the toggle no-speech timeout, interruptions, the hold probe, route changes and recognition errors.
//  Also the reply speaker's voice choice. Nothing here touches the microphone, TCC or the speaker.
//

import AVFoundation
import XCTest
@testable import Otto

// MARK: - Test doubles

/// A clock that only moves when the test advances it.
private final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration

        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Swift.Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumeNow: Bool = lock.withLock {
                    if Task.isCancelled || deadline <= current { return true }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return false
                }
                if resumeNow {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// True once something sleeps past the current time: a ticker that has run every due tick and waits again.
    var hasSleeperAfterNow: Bool {
        lock.withLock { sleepers.values.contains { $0.deadline > current } }
    }

    func advance(by duration: Swift.Duration) {
        let due: [Sleeper] = lock.withLock {
            current = current.advanced(by: duration)
            let dueIDs = sleepers.filter { $0.value.deadline <= current }.map(\.key)
            return dueIDs.compactMap { sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}

/// Records what the controller asks of the engine and lets the test play the recognizer.
private final class SpyEngine: SpeechEngine {
    var onTranscript: (@MainActor (_ text: String, _ isFinal: Bool) -> Void)?
    var onError: (@MainActor (VoiceError) -> Void)?
    var onInputDeviceChanged: (@MainActor () -> Void)?
    let meter = AudioLevelMeter()

    var startError: VoiceError?
    private(set) var isRunning = false
    private(set) var calls: [String] = []
    private(set) var startLocale: Locale?
    private(set) var startAllowServer: Bool?

    func start(locale: Locale, allowServer: Bool) throws {
        calls.append("start")
        startLocale = locale
        startAllowServer = allowServer
        if let startError { throw startError }
        isRunning = true
    }

    func finish() {
        calls.append("finish")
        isRunning = false
    }

    func cancel() {
        calls.append("cancel")
        isRunning = false
    }

    @MainActor func emit(_ text: String, isFinal: Bool) {
        onTranscript?(text, isFinal)
    }
}

@MainActor
private final class Recorder {
    var finished: [(transcript: String?, send: Bool)] = []
    var notices: [String] = []
    var errors: [VoiceError] = []

    func attach(to controller: VoiceController, errors captureErrors: Bool = false) {
        controller.onFinished = { [weak self] transcript, send in self?.finished.append((transcript, send)) }
        controller.onNotice = { [weak self] notice in self?.notices.append(notice) }
        if captureErrors {
            controller.onError = { [weak self] error in self?.errors.append(error) }
        }
    }
}

// MARK: - Tests

@MainActor
final class VoiceControllerTests: XCTestCase {
    private var clock: ManualClock!
    private var interruptions: InertVoiceInterruptions!
    private var recorder: Recorder!
    private var settings: AppSettings!

    override func setUp() async throws {
        clock = ManualClock()
        interruptions = InertVoiceInterruptions()
        recorder = Recorder()
        settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
    }

    private func makeController(engine: @escaping @MainActor () -> SpeechEngine,
                                holdProbe: @escaping VoiceHoldProbe = { _ in nil },
                                captureErrors: Bool = false) -> VoiceController {
        let controller = VoiceController(
            settings: settings, makeEngine: engine, speaker: ReplySpeaker(settings: settings, volume: 0),
            interruptions: interruptions, holdProbe: holdProbe, clock: clock)
        recorder.attach(to: controller, errors: captureErrors)
        return controller
    }

    /// Waits (real time) until the condition holds; main-actor work queued by the engine or the ticker runs meanwhile.
    private func waitUntil(_ description: String, timeout: TimeInterval = 3,
                           _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for \(description)")
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Moves the manual clock, then waits (real time) until the controller's ticker has run every tick that became
    /// due and sleeps again, or the session is over.
    private func advance(_ duration: Duration, _ controller: VoiceController) async {
        clock.advance(by: duration)
        let deadline = Date().addingTimeInterval(3)
        repeat {
            try? await Task.sleep(for: .milliseconds(2))
        } while !(clock.hasSleeperAfterNow || controller.phase == .idle) && Date() < deadline
        await Task.yield()
    }

    // MARK: Phases and the microphone

    func testEngineRunsOnlyBetweenStartAndFinish() async throws {
        var engines: [ScriptedSpeechEngine] = []
        let controller = makeController(engine: {
            let engine = ScriptedSpeechEngine(script: [(.zero, "what's on my calendar", 0.5)])
            engines.append(engine)
            return engine
        })
        XCTAssertTrue(engines.isEmpty, "no engine exists before a session")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.isActive)

        try controller.start(.hold(.micButton))
        let engine = try XCTUnwrap(engines.first)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertTrue(controller.isListening)
        XCTAssertEqual(controller.mode, .hold(.micButton))
        XCTAssertTrue(interruptions.isStarted)
        XCTAssertTrue(controller.meter === engine.meter)
        await waitUntil("the partial transcript") { controller.transcript == "what's on my calendar" }
        XCTAssertEqual(controller.finalizedText, "what's on my")
        XCTAssertEqual(controller.volatileText, "calendar")

        controller.finish(send: true)
        XCTAssertEqual(controller.phase, .finishing)
        XCTAssertFalse(engine.isRunning, "finish stops the microphone right away")
        await waitUntil("the final transcript") { controller.phase == .idle }

        XCTAssertEqual(recorder.finished.count, 1)
        XCTAssertEqual(recorder.finished.first?.transcript, "what's on my calendar")
        XCTAssertEqual(recorder.finished.first?.send, true)
        XCTAssertFalse(engine.isRunning)
        XCTAssertFalse(interruptions.isStarted)
        XCTAssertNil(controller.mode)
        XCTAssertEqual(controller.transcript, "")
        XCTAssertEqual(engines.count, 1)
        XCTAssertTrue(recorder.notices.isEmpty)
    }

    func testSpyEngineIsStartedWithTheVoiceSettingsAndReleasedAtTheEnd() throws {
        settings.voice.localeIdentifier = "en_IN"
        settings.voice.allowServerRecognition = true
        let spy = SpyEngine()
        let controller = makeController(engine: { spy })
        XCTAssertEqual(spy.calls, [])

        try controller.start(.toggle(.shortcut))
        XCTAssertEqual(spy.startLocale?.identifier, "en_IN")
        XCTAssertEqual(spy.startAllowServer, true)
        XCTAssertTrue(spy.isRunning)

        controller.cancel()
        XCTAssertFalse(spy.isRunning)
        XCTAssertEqual(spy.calls, ["start", "cancel"])
        XCTAssertNil(spy.onTranscript, "callbacks are detached so a late result can't reach a new session")
    }

    func testStartErrorIsThrownAndLeavesTheControllerIdle() {
        let spy = SpyEngine()
        spy.startError = .noInputDevice
        let controller = makeController(engine: { spy })
        XCTAssertThrowsError(try controller.start(.hold(.shortcut))) { error in
            XCTAssertEqual(error as? VoiceError, .noInputDevice)
        }
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(spy.isRunning)
        XCTAssertFalse(interruptions.isStarted)
        XCTAssertTrue(recorder.finished.isEmpty, "a session that never started doesn't finish")
    }

    func testStartWhileActiveIsIgnored() throws {
        var count = 0
        let controller = makeController(engine: {
            count += 1
            return SpyEngine()
        })
        try controller.start(.toggle(.micButton))
        try controller.start(.hold(.shortcut))
        XCTAssertEqual(count, 1)
        XCTAssertEqual(controller.mode, .toggle(.micButton))
    }

    // MARK: Finish and cancel

    func testFinishTimeoutUsesThePartialTranscript() async throws {
        let spy = SpyEngine()
        let controller = makeController(engine: { spy })
        try controller.start(.hold(.micButton))
        spy.emit("remind me to water the", isFinal: false)
        controller.finish(send: true)
        XCTAssertEqual(spy.calls, ["start", "finish"])

        await advance(.milliseconds(1400), controller)
        XCTAssertEqual(controller.phase, .finishing)
        XCTAssertTrue(recorder.finished.isEmpty)

        await advance(.milliseconds(200), controller)
        await waitUntil("the finish timeout") { controller.phase == .idle }
        XCTAssertEqual(recorder.finished.count, 1)
        XCTAssertEqual(recorder.finished.first?.transcript, "remind me to water the")
        XCTAssertEqual(recorder.finished.first?.send, true)
        XCTAssertEqual(spy.calls, ["start", "finish", "cancel"])
    }

    func testEmptyFinalKeepsTheWordsAlreadyHeard() throws {
        let spy = SpyEngine()
        let controller = makeController(engine: { spy })
        try controller.start(.hold(.shortcut))
        spy.emit("call Sam", isFinal: false)
        controller.finish(send: true)
        spy.emit("", isFinal: true)
        XCTAssertEqual(recorder.finished.first?.transcript, "call Sam")
    }

    func testCancelDeliversNilExactlyOnce() async throws {
        let engine = ScriptedSpeechEngine(script: [(.zero, "never mind", 0.4)])
        let controller = makeController(engine: { engine })
        try controller.start(.toggle(.micButton))
        await waitUntil("the partial transcript") { controller.transcript == "never mind" }

        controller.cancel()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(engine.isRunning)
        controller.cancel()
        controller.finish(send: true)
        await advance(.seconds(3), controller)

        XCTAssertEqual(recorder.finished.count, 1)
        XCTAssertNil(recorder.finished.first?.transcript)
        XCTAssertEqual(recorder.finished.first?.send, false)
        XCTAssertTrue(recorder.notices.isEmpty)
    }

    func testFinalResultWhileListeningEndsTheSessionWithoutSending() throws {
        let spy = SpyEngine()
        let controller = makeController(engine: { spy })
        try controller.start(.hold(.shortcut))
        spy.emit("", isFinal: true)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(recorder.finished.first?.transcript, "")
        XCTAssertEqual(recorder.finished.first?.send, false)
    }

    // MARK: Watchdog and timeouts

    func testWatchdogFinishesWithoutSending() async throws {
        let engine = ScriptedSpeechEngine(script: [(.zero, "draft a note about the offsite", 0.6)])
        let controller = makeController(engine: { engine })
        try controller.start(.hold(.shortcut))
        await waitUntil("the partial transcript") { !controller.transcript.isEmpty }

        await advance(.milliseconds(119_900), controller)
        XCTAssertEqual(controller.phase, .listening)

        await advance(.milliseconds(100), controller)
        await waitUntil("the watchdog") { controller.phase == .idle }
        XCTAssertEqual(recorder.finished.count, 1)
        XCTAssertEqual(recorder.finished.first?.transcript, "draft a note about the offsite")
        XCTAssertEqual(recorder.finished.first?.send, false)
        XCTAssertEqual(recorder.notices, [VoiceController.Notice.timeLimit])
        XCTAssertFalse(engine.isRunning)
    }

    func testToggleWithNoSpeechCancelsAfterEightSeconds() async throws {
        let engine = ScriptedSpeechEngine(script: [])
        let controller = makeController(engine: { engine })
        try controller.start(.toggle(.micButton))

        await advance(.milliseconds(7900), controller)
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertTrue(recorder.finished.isEmpty)

        await advance(.milliseconds(100), controller)
        await waitUntil("the no-speech timeout") { controller.phase == .idle }
        XCTAssertEqual(recorder.finished.count, 1)
        XCTAssertNil(recorder.finished.first?.transcript)
        XCTAssertEqual(recorder.finished.first?.send, false)
        XCTAssertEqual(recorder.notices, [VoiceController.Notice.heardNothing])
        XCTAssertFalse(engine.isRunning)
    }

    func testHoldWithNoSpeechKeepsListening() async throws {
        let controller = makeController(engine: { ScriptedSpeechEngine(script: []) })
        try controller.start(.hold(.shortcut))
        await advance(.seconds(10), controller)
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertTrue(recorder.finished.isEmpty)
    }

    func testTrailingSilenceFinishesATogglePerAutoSend() async throws {
        let engine = ScriptedSpeechEngine(script: [
            (.zero, "turn on the", 0.7),
            (.zero, "turn on the lights", 0.02),
        ])
        let controller = makeController(engine: { engine })
        try controller.start(.toggle(.micButton))
        await waitUntil("the quiet partial") {
            controller.transcript == "turn on the lights" && controller.meter.currentLevel < 0.08
        }

        await advance(.milliseconds(1900), controller)
        XCTAssertEqual(controller.phase, .listening)

        await advance(.milliseconds(200), controller)
        await waitUntil("trailing silence") { controller.phase == .idle }
        XCTAssertEqual(recorder.finished.count, 1)
        XCTAssertEqual(recorder.finished.first?.transcript, "turn on the lights")
        XCTAssertEqual(recorder.finished.first?.send, true)
    }

    func testTrailingSilenceKeepsWordsInTheComposerWhenAutoSendIsOff() async throws {
        settings.voice.autoSend = false
        let controller = makeController(engine: {
            ScriptedSpeechEngine(script: [(.zero, "set a timer", 0)])
        })
        try controller.start(.toggle(.shortcut))
        await waitUntil("the partial transcript") { controller.transcript == "set a timer" }
        await advance(.seconds(3), controller)
        await waitUntil("trailing silence") { controller.phase == .idle }
        XCTAssertEqual(recorder.finished.first?.send, false)
    }

    func testLoudTogglePausesTheSilenceTimer() async throws {
        let controller = makeController(engine: {
            ScriptedSpeechEngine(script: [(.zero, "still talking", 0.9)])
        })
        try controller.start(.toggle(.micButton))
        await waitUntil("the partial transcript") { controller.transcript == "still talking" }
        await advance(.seconds(5), controller)
        XCTAssertEqual(controller.phase, .listening)
    }

    // MARK: Interruptions

    func testInterruptionCancelsWithoutSending() async throws {
        let engine = ScriptedSpeechEngine(script: [(.zero, "send the report to", 0.5)])
        let controller = makeController(engine: { engine })
        try controller.start(.hold(.shortcut))
        await waitUntil("the partial transcript") { !controller.transcript.isEmpty }

        interruptions.fire(.screenLocked)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(engine.isRunning)
        XCTAssertFalse(interruptions.isStarted)
        XCTAssertEqual(recorder.finished.count, 1)
        XCTAssertNil(recorder.finished.first?.transcript)
        XCTAssertEqual(recorder.finished.first?.send, false)
        XCTAssertEqual(recorder.notices, [VoiceController.Notice.screenLocked])

        interruptions.fire(.willSleep)
        XCTAssertEqual(recorder.finished.count, 1, "an idle controller ignores interruptions")
    }

    func testInterruptionWhileFinishingStillCancels() throws {
        let spy = SpyEngine()
        let controller = makeController(engine: { spy })
        try controller.start(.hold(.micButton))
        spy.emit("almost done", isFinal: false)
        controller.finish(send: true)
        interruptions.fire(.sessionResignedActive)
        XCTAssertEqual(recorder.finished.count, 1)
        XCTAssertNil(recorder.finished.first?.transcript)
        XCTAssertEqual(recorder.notices, [VoiceController.Notice.userSwitched])
        spy.emit("almost done", isFinal: true)
        XCTAssertEqual(recorder.finished.count, 1)
    }

    // MARK: Hold probe

    func testHoldProbeReadingUpFinishesLikeARelease() async throws {
        var isDown = true
        let engine = ScriptedSpeechEngine(script: [(.zero, "what time is it in Tokyo", 0.5)])
        let controller = makeController(engine: { engine }, holdProbe: { source in
            XCTAssertEqual(source, .shortcut)
            return isDown
        })
        try controller.start(.hold(.shortcut))
        await waitUntil("the partial transcript") { !controller.transcript.isEmpty }

        for _ in 0..<5 {
            await advance(.milliseconds(100), controller)
        }
        XCTAssertEqual(controller.phase, .listening)

        isDown = false
        await advance(.milliseconds(100), controller)
        await waitUntil("the probe release") { controller.phase == .idle }
        XCTAssertEqual(recorder.finished.count, 1)
        XCTAssertEqual(recorder.finished.first?.transcript, "what time is it in Tokyo")
        XCTAssertEqual(recorder.finished.first?.send, true)
    }

    func testHoldProbeThatNeverReadsDownIsIgnored() async throws {
        var reads = 0
        let controller = makeController(engine: { ScriptedSpeechEngine(script: []) }, holdProbe: { _ in
            reads += 1
            return false
        })
        try controller.start(.hold(.micButton))
        for _ in 0..<10 {
            await advance(.milliseconds(100), controller)
        }
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertEqual(reads, 3, "polled for the first 300 ms, then trusted no more")
    }

    func testUnknownHoldProbeReadingsAreIgnoredOnceTrusted() async throws {
        var reading: Bool? = true
        let controller = makeController(engine: { ScriptedSpeechEngine(script: []) }, holdProbe: { _ in reading })
        try controller.start(.hold(.shortcut))
        await advance(.milliseconds(100), controller)
        reading = nil
        for _ in 0..<5 {
            await advance(.milliseconds(100), controller)
        }
        XCTAssertEqual(controller.phase, .listening)
    }

    func testToggleNeverPollsTheHoldProbe() async throws {
        var reads = 0
        let controller = makeController(engine: { ScriptedSpeechEngine(script: []) }, holdProbe: { _ in
            reads += 1
            return false
        })
        try controller.start(.toggle(.shortcut))
        await advance(.seconds(1), controller)
        XCTAssertEqual(reads, 0)
    }

    // MARK: Route changes

    func testRouteChangeWithInputKeepsListening() async throws {
        let engine = ScriptedSpeechEngine(script: [(.zero, "play something calm", 0.5)])
        let controller = makeController(engine: { engine })
        try controller.start(.hold(.shortcut))
        await waitUntil("the partial transcript") { !controller.transcript.isEmpty }

        await advance(.milliseconds(300), controller)
        engine.simulateConfigurationChange(hasInput: true)
        await advance(.milliseconds(500), controller)
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertTrue(engine.isRunning)
        XCTAssertTrue(recorder.finished.isEmpty)
        XCTAssertTrue(recorder.notices.isEmpty)
    }

    func testRouteChangeWithoutInputFinishesWithTheNotice() async throws {
        let engine = ScriptedSpeechEngine(script: [
            (.zero, "play something", 0.5),
            (.seconds(3600), "play something calm", 0.5),
        ])
        let controller = makeController(engine: { engine })
        try controller.start(.hold(.shortcut))
        await waitUntil("the partial transcript") { controller.transcript == "play something" }

        await advance(.milliseconds(300), controller)
        engine.simulateConfigurationChange(hasInput: false)
        await waitUntil("the lost microphone") { controller.phase == .idle }
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(recorder.finished.count, 1)
        XCTAssertEqual(recorder.finished.first?.transcript, "play something")
        XCTAssertEqual(recorder.finished.first?.send, false)
        XCTAssertEqual(recorder.notices, [VoiceController.Notice.noMicrophone])
    }

    // MARK: Errors

    func testRecognitionErrorEndsTheSessionAndReportsIt() async throws {
        let engine = ScriptedSpeechEngine(script: [])
        let controller = makeController(engine: { engine }, captureErrors: true)
        try controller.start(.toggle(.micButton))
        engine.simulateError(.dictationDisabled)
        await waitUntil("the error") { controller.phase == .idle }
        XCTAssertEqual(recorder.finished.count, 1)
        XCTAssertNil(recorder.finished.first?.transcript)
        XCTAssertEqual(recorder.errors, [.dictationDisabled])
        XCTAssertTrue(recorder.notices.isEmpty)
        XCTAssertFalse(engine.isRunning)
    }

    func testRecognitionErrorKeepsHeardWordsAndFallsBackToANotice() async throws {
        let spy = SpyEngine()
        let controller = makeController(engine: { spy })
        try controller.start(.hold(.shortcut))
        spy.emit("book a table for", isFinal: false)
        spy.onError?(.recognition("Connection lost"))
        XCTAssertEqual(recorder.finished.first?.transcript, "book a table for")
        XCTAssertEqual(recorder.finished.first?.send, false)
        XCTAssertEqual(recorder.notices, [VoiceError.recognition("Connection lost").errorDescription ?? ""])
    }

    // MARK: Debug seed and speech

    func testDebugSeedShowsASessionWithoutAnEngine() {
        var made = 0
        let controller = makeController(engine: {
            made += 1
            return SpyEngine()
        })
        controller.debugSeed(phase: .listening, finalized: "What's the weather", volatile: "like", levels: [0.2, 0.9])
        XCTAssertEqual(made, 0)
        XCTAssertTrue(controller.isListening)
        XCTAssertEqual(controller.transcript, "What's the weather like")
        XCTAssertEqual(controller.meter.recentLevels(count: 3), [0, 0.2, 0.9])

        controller.debugSeed(phase: .idle, finalized: "", volatile: "", levels: [])
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.mode)
        XCTAssertTrue(recorder.finished.isEmpty)
    }

    func testStartingToListenStopsSpeaking() throws {
        let controller = makeController(engine: { SpyEngine() })
        XCTAssertFalse(controller.isSpeaking)
        try controller.start(.toggle(.micButton))
        XCTAssertFalse(controller.speaker.isSpeaking)
        controller.stopSpeaking()
        XCTAssertFalse(controller.isSpeaking)
    }

    func testBestVoiceSkipsNoveltyAndPersonalVoices() {
        let voices = ReplySpeaker.availableVoices(languageCode: "en-US")
        for voice in voices {
            XCTAssertFalse(voice.voiceTraits.contains(.isNoveltyVoice), voice.identifier)
            XCTAssertFalse(voice.voiceTraits.contains(.isPersonalVoice), voice.identifier)
            XCTAssertTrue(voice.language.lowercased().hasPrefix("en"), voice.identifier)
        }
        let ranks = voices.map(\.quality.rawValue)
        XCTAssertEqual(ranks, ranks.sorted(by: >), "best quality first")
        XCTAssertEqual(
            ReplySpeaker.bestVoice(languageCode: "en-US", preferredIdentifier: nil)?.identifier,
            voices.first?.identifier)
        XCTAssertEqual(
            ReplySpeaker.bestVoice(languageCode: "en-US", preferredIdentifier: "com.example.not-installed")?.identifier,
            voices.first?.identifier)
        if let last = voices.last {
            XCTAssertEqual(
                ReplySpeaker.bestVoice(languageCode: "en-US", preferredIdentifier: last.identifier)?.identifier,
                last.identifier)
        }
    }
}
