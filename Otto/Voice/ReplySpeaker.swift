//
//  ReplySpeaker.swift
//  Otto
//
//  Reads a reply aloud sentence by sentence while it streams, with the best installed system voice for the
//  voice language (novelty and personal voices excluded). Everything stays on this Mac.
//

import AVFoundation
import Foundation
import os

@MainActor final class ReplySpeaker: NSObject, AVSpeechSynthesizerDelegate {
    /// What the Settings preview says.
    static let previewText = "Hi, I'm Otto."
    static let postUtteranceDelay: TimeInterval = 0.04

    private(set) var speakingAssistantID: UUID?

    var isSpeaking: Bool { !pendingUtterances.isEmpty }

    var onSpeakingChange: ((Bool) -> Void)?

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Voice")

    private let settings: AppSettings
    private let volume: Float
    private let synthesizer = AVSpeechSynthesizer()
    private var chunker = SpeechChunker()
    /// The reply the chunker is reading. Stays set after the queue drains, so later progress keeps reading
    /// the same reply from where it left off.
    private var chunkerAssistantID: UUID?
    /// A reply the user stopped: later progress for it stays silent.
    private var silencedAssistantID: UUID?
    private var pendingUtterances: Set<ObjectIdentifier> = []
    private var reportedSpeaking = false
    private let catalog: VoiceCatalog
    private var resolvedVoice: (key: ResolvedVoiceKey, voice: AVSpeechSynthesisVoice?)?

    private struct ResolvedVoiceKey: Equatable {
        let language: String
        let preferredIdentifier: String
        let catalogGeneration: Int
    }

    /// `volume` scales every utterance (0 mutes it, for self-tests that exercise the pipeline silently).
    /// The voice list is warmed off the main thread so the first spoken sentence doesn't wait for it.
    init(settings: AppSettings, volume: Float = 1, catalog: VoiceCatalog = .shared) {
        self.settings = settings
        self.volume = min(max(volume, 0), 1)
        self.catalog = catalog
        super.init()
        synthesizer.delegate = self
        catalog.warm(languageCode: settings.voice.locale.identifier(.bcp47))
    }

    /// Feed the whole reply so far. Complete sentences are queued as they appear; `isFinal` reads the rest.
    func progress(assistantID: UUID, text: String, isFinal: Bool) {
        guard assistantID != silencedAssistantID else { return }
        if assistantID != chunkerAssistantID {
            if isSpeaking { stopSynthesizer() }
            chunker = SpeechChunker()
            chunkerAssistantID = assistantID
            silencedAssistantID = nil
        }
        let sentences = chunker.consume(text, isFinal: isFinal)
        guard !sentences.isEmpty else { return }
        let voice = currentVoice()
        speakingAssistantID = assistantID
        for sentence in sentences {
            enqueue(sentence, voice: voice)
        }
        Self.logger.debug("Queued \(sentences.count, privacy: .public) sentences to read aloud")
    }

    /// Reads a whole reply from the start (the iPhone's Read Aloud), even one that was stopped before.
    func read(assistantID: UUID, text: String) {
        if isSpeaking { stopSynthesizer() }
        chunker = SpeechChunker()
        chunkerAssistantID = assistantID
        silencedAssistantID = nil
        progress(assistantID: assistantID, text: text, isFinal: true)
    }

    /// Stops right away and stays quiet for the rest of the current reply.
    func stop() {
        silencedAssistantID = chunkerAssistantID
        chunker = SpeechChunker()
        stopSynthesizer()
    }

    func preview() {
        stop()
        chunkerAssistantID = nil
        silencedAssistantID = nil
        enqueue(Self.previewText, voice: currentVoice())
    }

    /// The preferred voice when it is installed; otherwise the best voice for the language by quality
    /// (premium, enhanced, default), preferring the system's own pick for the language on a tie.
    static func bestVoice(languageCode: String, preferredIdentifier: String?) -> AVSpeechSynthesisVoice? {
        VoiceCatalog.shared.bestVoice(languageCode: languageCode, preferredIdentifier: preferredIdentifier)
    }

    /// Voices for the picker: the language's installed voices without novelty or personal voices, best first.
    /// Cached for the process; the first call for a language after launch or a voice install enumerates every
    /// system voice, so views should load it with `loadAvailableVoices` instead of reading it in `body`.
    static func availableVoices(languageCode: String) -> [AVSpeechSynthesisVoice] {
        VoiceCatalog.shared.voices(languageCode: languageCode)
    }

    /// `availableVoices` off the main thread, for the Settings picker.
    nonisolated static func loadAvailableVoices(languageCode: String) async -> [AVSpeechSynthesisVoice] {
        await VoiceCatalog.shared.load(languageCode: languageCode)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.utteranceEnded(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.utteranceEnded(id) }
    }

    // MARK: - Private

    private func enqueue(_ text: String, voice: AVSpeechSynthesisVoice?) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = Float(settings.voice.speakingRate)
        utterance.volume = volume
        utterance.postUtteranceDelay = Self.postUtteranceDelay
        utterance.prefersAssistiveTechnologySettings = false
        pendingUtterances.insert(ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
        reportSpeakingChange()
    }

    private func utteranceEnded(_ id: ObjectIdentifier) {
        guard pendingUtterances.remove(id) != nil else { return }
        if pendingUtterances.isEmpty { speakingAssistantID = nil }
        reportSpeakingChange()
    }

    private func stopSynthesizer() {
        pendingUtterances.removeAll()
        speakingAssistantID = nil
        synthesizer.stopSpeaking(at: .immediate)
        reportSpeakingChange()
    }

    private func reportSpeakingChange() {
        let speaking = isSpeaking
        guard speaking != reportedSpeaking else { return }
        reportedSpeaking = speaking
        onSpeakingChange?(speaking)
    }

    /// The voice for the current settings, resolved once per (language, chosen voice, installed voices) and
    /// reused for every sentence after that.
    func currentVoice() -> AVSpeechSynthesisVoice? {
        let key = ResolvedVoiceKey(language: settings.voice.locale.identifier(.bcp47),
                                   preferredIdentifier: settings.voice.voiceIdentifier,
                                   catalogGeneration: catalog.generation)
        if let resolvedVoice, resolvedVoice.key == key { return resolvedVoice.voice }
        let voice = catalog.bestVoice(languageCode: key.language, preferredIdentifier: key.preferredIdentifier)
        resolvedVoice = (key, voice)
        return voice
    }
}

/// The installed system voices, ranked per language and cached for the process. Enumerating them costs tens of
/// milliseconds a call (`speechVoices()` isn't cached by the system), far too slow for every streamed sentence
/// or every Settings redraw. The cache empties when macOS reports that the installed voices changed.
/// Thread-safe; the first lookup can run on any thread. Off the main thread, lookups go through one serial
/// dispatch queue: `speechVoices()` waits synchronously on the speech service (seconds after a cold boot), which
/// must not hold Swift concurrency's few threads, and lookups queued behind the first one read its cache.
final class VoiceCatalog: @unchecked Sendable {
    static let shared = VoiceCatalog()

    typealias Enumerate = @Sendable () -> [AVSpeechSynthesisVoice]
    /// The system's own voice identifier for a BCP 47 language code.
    typealias SystemPick = @Sendable (String) -> String?

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.jalenedusei.otto.voice-catalog", qos: .utility)
    private let enumerate: Enumerate
    private let systemPick: SystemPick
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?
    private var allVoices: [AVSpeechSynthesisVoice]?
    private var ranked: [String: [AVSpeechSynthesisVoice]] = [:]
    private var generationValue = 0

    init(notificationCenter: NotificationCenter = .default,
         enumerate: @escaping Enumerate = { AVSpeechSynthesisVoice.speechVoices() },
         systemPick: @escaping SystemPick = { AVSpeechSynthesisVoice(language: $0)?.identifier }) {
        self.notificationCenter = notificationCenter
        self.enumerate = enumerate
        self.systemPick = systemPick
        observer = notificationCenter.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.invalidate()
        }
    }

    deinit {
        if let observer { notificationCenter.removeObserver(observer) }
    }

    /// Bumps whenever the cache empties, so callers holding a resolved voice know to resolve it again.
    var generation: Int { lock.withLock { generationValue } }

    func invalidate() {
        lock.withLock {
            allVoices = nil
            ranked = [:]
            generationValue += 1
        }
    }

    /// Fills the cache for the language in the background, so the first spoken sentence doesn't wait for it.
    func warm(languageCode: String) {
        queue.async { [self] in _ = voices(languageCode: languageCode) }
    }

    /// `voices` off the calling thread.
    func load(languageCode: String) async -> [AVSpeechSynthesisVoice] {
        await withCheckedContinuation { continuation in
            queue.async(qos: .userInitiated, flags: .enforceQoS) { [self] in
                continuation.resume(returning: voices(languageCode: languageCode))
            }
        }
    }

    /// The language's installed voices without novelty or personal voices, best first.
    func voices(languageCode: String) -> [AVSpeechSynthesisVoice] {
        let wanted = Self.normalizedLanguage(languageCode)
        let (cached, known, generation) = lock.withLock { (ranked[wanted], allVoices, generationValue) }
        if let cached { return cached }
        let all = known ?? enumerate()
        let result = Self.rank(all, wanted: wanted,
                               systemPick: systemPick(languageCode.replacingOccurrences(of: "_", with: "-")))
        lock.withLock {
            // Dropped if the voices changed while this ran; the next lookup enumerates again.
            guard generationValue == generation else { return }
            allVoices = all
            ranked[wanted] = result
        }
        return result
    }

    /// The preferred voice when it is installed and offered; otherwise the language's best voice.
    func bestVoice(languageCode: String, preferredIdentifier: String?) -> AVSpeechSynthesisVoice? {
        let ranked = voices(languageCode: languageCode)
        if let preferredIdentifier, !preferredIdentifier.isEmpty {
            let installed = lock.withLock { allVoices } ?? []
            if let preferred = installed.first(where: { $0.identifier == preferredIdentifier }),
               Self.isOffered(preferred) {
                return preferred
            }
        }
        return ranked.first
    }

    private static func rank(_ all: [AVSpeechSynthesisVoice], wanted: String,
                             systemPick: String?) -> [AVSpeechSynthesisVoice] {
        guard let primary = wanted.split(separator: "-").first.map(String.init), !primary.isEmpty else { return [] }
        let candidates = all.filter { voice in
            let language = normalizedLanguage(voice.language)
            let voicePrimary = language.split(separator: "-").first.map(String.init) ?? language
            return voicePrimary == primary && isOffered(voice)
        }
        return candidates.sorted { lhs, rhs in
            let lhsRank = qualityRank(lhs.quality), rhsRank = qualityRank(rhs.quality)
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            let lhsPick = lhs.identifier == systemPick, rhsPick = rhs.identifier == systemPick
            if lhsPick != rhsPick { return lhsPick }
            let lhsExact = normalizedLanguage(lhs.language) == wanted
            let rhsExact = normalizedLanguage(rhs.language) == wanted
            if lhsExact != rhsExact { return lhsExact }
            if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.identifier < rhs.identifier
        }
    }

    private static func isOffered(_ voice: AVSpeechSynthesisVoice) -> Bool {
        !voice.voiceTraits.contains(.isNoveltyVoice) && !voice.voiceTraits.contains(.isPersonalVoice)
    }

    private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        case .default: return 1
        @unknown default: return 0
        }
    }

    /// "en_US" and "en-us" → "en-us" (lowercased, hyphenated), the cache and comparison key.
    private static func normalizedLanguage(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
