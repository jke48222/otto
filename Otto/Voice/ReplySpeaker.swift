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

    /// `volume` scales every utterance (0 mutes it, for self-tests that exercise the pipeline silently).
    init(settings: AppSettings, volume: Float = 1) {
        self.settings = settings
        self.volume = min(max(volume, 0), 1)
        super.init()
        synthesizer.delegate = self
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
        if let preferredIdentifier, !preferredIdentifier.isEmpty,
           let preferred = AVSpeechSynthesisVoice(identifier: preferredIdentifier), isOffered(preferred) {
            return preferred
        }
        return availableVoices(languageCode: languageCode).first
    }

    /// Voices for the picker: the language's installed voices without novelty or personal voices, best first.
    static func availableVoices(languageCode: String) -> [AVSpeechSynthesisVoice] {
        let wanted = normalizedLanguage(languageCode)
        guard let primary = wanted.split(separator: "-").first.map(String.init), !primary.isEmpty else { return [] }
        let systemPick = AVSpeechSynthesisVoice(language: languageCode.replacingOccurrences(of: "_", with: "-"))?.identifier
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { voice in
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

    private func currentVoice() -> AVSpeechSynthesisVoice? {
        let language = settings.voice.locale.identifier(.bcp47)
        return Self.bestVoice(languageCode: language, preferredIdentifier: settings.voice.voiceIdentifier)
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

    /// "en_US" and "en-us" → "en-US"-style comparison key (lowercased, hyphenated).
    private static func normalizedLanguage(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
