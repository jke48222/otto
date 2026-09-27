//
//  VoiceSettings.swift
//  Otto
//
//  Voice mode preferences: on or off, hold-to-talk, auto-send, recognition language, whether Apple's
//  server recognition may be used, and how replies are read aloud.
//

import Foundation
import Observation

@MainActor @Observable final class VoiceSettings {
    enum Keys {
        static let enabled = "otto.voice.enabled"
        static let holdShortcutToTalk = "otto.voice.holdShortcutToTalk"
        static let autoSend = "otto.voice.autoSend"
        static let localeIdentifier = "otto.voice.locale"
        static let allowServerRecognition = "otto.voice.allowServerRecognition"
        static let spokenReplies = "otto.voice.spokenReplies"
        static let voiceIdentifier = "otto.voice.voiceIdentifier"
        static let speakingRate = "otto.voice.speakingRate"
    }

    /// AVSpeechUtterance rates Otto offers.
    static let speakingRateRange: ClosedRange<Double> = 0.35...0.65

    var enabled: Bool {
        didSet { store.set(enabled, Keys.enabled) }
    }

    /// Holding the global shortcut talks; a tap still toggles the notch.
    var holdShortcutToTalk: Bool {
        didSet { store.set(holdShortcutToTalk, Keys.holdShortcutToTalk) }
    }

    var autoSend: Bool {
        didSet { store.set(autoSend, Keys.autoSend) }
    }

    /// "" follows the system language.
    var localeIdentifier: String {
        didSet { store.set(localeIdentifier, Keys.localeIdentifier) }
    }

    /// Lets Apple's speech service transcribe when on-device recognition isn't available.
    var allowServerRecognition: Bool {
        didSet { store.set(allowServerRecognition, Keys.allowServerRecognition) }
    }

    var spokenReplies: SpokenReplies {
        didSet { store.set(spokenReplies.rawValue, Keys.spokenReplies) }
    }

    /// "" picks the best installed voice for the language.
    var voiceIdentifier: String {
        didSet { store.set(voiceIdentifier, Keys.voiceIdentifier) }
    }

    /// Clamped to `speakingRateRange` on read and write.
    var speakingRate: Double {
        didSet {
            let clamped = PreferenceStore.clamp(speakingRate.isFinite ? speakingRate : 0.5, to: Self.speakingRateRange)
            if clamped != speakingRate { speakingRate = clamped }
            store.set(clamped, Keys.speakingRate)
        }
    }

    /// "" → Locale.current.
    var locale: Locale {
        localeIdentifier.isEmpty ? Locale.current : Locale(identifier: localeIdentifier)
    }

    @ObservationIgnored private let store: PreferenceStore

    init(store: PreferenceStore) {
        self.store = store
        enabled = store.bool(Keys.enabled, false)
        holdShortcutToTalk = store.bool(Keys.holdShortcutToTalk, true)
        autoSend = store.bool(Keys.autoSend, true)
        localeIdentifier = store.string(Keys.localeIdentifier, "")
        allowServerRecognition = store.bool(Keys.allowServerRecognition, false)
        spokenReplies = store.value(Keys.spokenReplies, SpokenReplies.off)
        voiceIdentifier = store.string(Keys.voiceIdentifier, "")
        speakingRate = store.double(Keys.speakingRate, 0.5, in: Self.speakingRateRange)
    }
}
