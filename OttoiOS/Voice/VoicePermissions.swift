//
//  VoicePermissions.swift
//  Otto
//
//  The Microphone and Speech Recognition permissions voice mode needs, asked for the first time the mic is used.
//

import AVFoundation
import Speech

@MainActor protocol VoicePermissionChecking: AnyObject {
    var microphone: PermissionStatus { get }
    var speechRecognition: PermissionStatus { get }
    /// Shows the system prompt when it can; returns the status afterwards.
    func requestMicrophone() async -> PermissionStatus
    func requestSpeechRecognition() async -> PermissionStatus
}

@MainActor final class SystemVoicePermissions: VoicePermissionChecking {
    nonisolated init() {}

    var microphone: PermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    var speechRecognition: PermissionStatus {
        Self.status(SFSpeechRecognizer.authorizationStatus())
    }

    func requestMicrophone() async -> PermissionStatus {
        guard microphone == .notDetermined else { return microphone }
        return await AVAudioApplication.requestRecordPermission() ? .granted : .denied
    }

    func requestSpeechRecognition() async -> PermissionStatus {
        guard speechRecognition == .notDetermined else { return speechRecognition }
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return Self.status(status)
    }

    private static func status(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}

/// Fixed answers (tests, snapshots, the demo graph's scripted voice).
@MainActor final class StaticVoicePermissions: VoicePermissionChecking {
    var microphone: PermissionStatus
    var speechRecognition: PermissionStatus

    /// Nonisolated so it can be a default value.
    nonisolated init(microphone: PermissionStatus = .granted, speechRecognition: PermissionStatus = .granted) {
        self.microphone = microphone
        self.speechRecognition = speechRecognition
    }

    func requestMicrophone() async -> PermissionStatus { microphone }
    func requestSpeechRecognition() async -> PermissionStatus { speechRecognition }
}
