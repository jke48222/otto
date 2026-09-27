//
//  VoiceContracts.swift
//  Otto
//
//  Voice mode's shared vocabulary: how a session starts (hold or toggle, from the shortcut or the mic
//  button), its phases, why it can't run, the timing constants, and the seams that end a session early.
//

import CoreGraphics
import Foundation

enum VoiceSource: Equatable, Hashable, Sendable { case shortcut, micButton }

enum VoiceMode: Equatable, Hashable, Sendable { case hold(VoiceSource), toggle(VoiceSource) }

enum VoicePhase: Equatable, Sendable { case idle, preparing, listening, finishing }

enum SpokenReplies: String, CaseIterable, Codable, Identifiable, Sendable {
    case off, afterVoice, always

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .afterVoice: return "When I ask by voice"
        case .always: return "Always"
        }
    }
}

enum VoiceUnavailableReason: Hashable, Sendable {
    case microphoneDenied, speechDenied, noInputDevice, recognizerUnavailable(localeName: String)
    /// Siri & Dictation is off in System Settings (Speech fails with kLSRErrorDomain 201 even when isAvailable).
    case dictationDisabled
}

enum MicState: Equatable, Sendable { case off, ready, listening, finishing, unavailable(VoiceUnavailableReason) }

enum VoiceError: LocalizedError, Equatable {
    case microphoneDenied, speechDenied, noInputDevice, recognizerUnavailable(localeName: String)
    case onDeviceUnavailable(localeName: String), audioEngine(String), recognition(String)
    case dictationDisabled

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Otto can't hear you yet. Allow Microphone for Otto in System Settings → Privacy & Security."
        case .speechDenied:
            return "Otto can't turn speech into text yet. Allow Speech Recognition for Otto in System Settings → "
                + "Privacy & Security."
        case .noInputDevice:
            return "Otto can't find a microphone."
        case .recognizerUnavailable(let localeName):
            return "Speech recognition for \(localeName) isn't available right now."
        case .onDeviceUnavailable(let localeName):
            return "On-device speech recognition isn't available for \(localeName)."
        case .audioEngine(let detail):
            return detail.isEmpty ? "Otto couldn't start the microphone." : "Otto couldn't start the microphone: \(detail)"
        case .recognition(let detail):
            return detail.isEmpty ? "Otto couldn't understand that." : "Otto couldn't understand that: \(detail)"
        case .dictationDisabled:
            return "Dictation is off. Turn on Dictation in System Settings → Keyboard to talk to Otto."
        }
    }
}

enum VoiceMetrics {
    static let earWidth: CGFloat = 56, pillMinWidth: CGFloat = 360, captionHeight: CGFloat = 26, pillBottomRadius: CGFloat = 14
    static let holdThreshold: TimeInterval = 0.3, maxUtterance: Duration = .seconds(120)
    static let finishTimeout: Duration = .milliseconds(1500), trailingSilence: Duration = .seconds(2)
    static let replyHold: Duration = .seconds(8)
    /// Toggle mode with no transcript yet: cancel (never send) after this long.
    static let toggleNoSpeechTimeout: Duration = .seconds(8)
    /// Hold mode: poll the physical key or mouse button this often (covers a lost release event).
    static let holdPollInterval: Duration = .milliseconds(100)
    /// Audio route changes the engine absorbs per session before giving up.
    static let maxEngineRestarts = 3
}

/// Why a session must end right away. Every case cancels (discards), never sends.
enum VoiceInterruption: Equatable, Sendable { case screenLocked, willSleep, screensDidSleep, sessionResignedActive }

@MainActor protocol VoiceInterruptionSource: AnyObject {
    func start(_ handler: @escaping @MainActor (VoiceInterruption) -> Void)
    func stop()
}

/// Is the control that started a hold still physically down? nil = can't tell (then only the release event counts).
typealias VoiceHoldProbe = @MainActor (VoiceSource) -> Bool?
