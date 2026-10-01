//
//  AudioSessionCoordinator.swift
//  Otto
//
//  Otto's one audio session on iPhone: recording while it listens, spoken audio (ducking other apps) while it
//  reads a reply aloud, and inactive otherwise so music and podcasts come back at full volume.
//

import AVFoundation
import os

@MainActor final class AudioSessionCoordinator {
    enum Mode: Equatable, Sendable { case idle, listening, speaking }

    private(set) var mode: Mode = .idle

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Voice")

    /// nil in tests and snapshots: modes are tracked, the system session is never touched.
    private let session: AVAudioSession?

    init(session: AVAudioSession? = AVAudioSession.sharedInstance()) {
        self.session = session
    }

    /// Switches the session to `mode`. Returns false when the system refused it (another app holds the
    /// microphone, a call is in progress); the mode is then unchanged.
    @discardableResult func activate(_ mode: Mode) -> Bool {
        guard mode != self.mode else { return true }
        guard let session else {
            self.mode = mode
            return true
        }
        do {
            switch mode {
            case .idle:
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            case .listening:
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            case .speaking:
                try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            }
            self.mode = mode
            return true
        } catch {
            Self.logger.error("Audio session change to \(String(describing: mode), privacy: .public) failed: \(LoggedError(error), privacy: .public)")
            if mode == .idle { self.mode = .idle }
            return false
        }
    }
}
