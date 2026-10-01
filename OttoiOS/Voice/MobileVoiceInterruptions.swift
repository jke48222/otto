//
//  MobileVoiceInterruptions.swift
//  Otto
//
//  What ends a voice session early on iPhone, so the microphone never stays on unattended: Otto leaving the
//  screen (the Home gesture, a call, Control Center) and the iPhone locking. The Mac's sources live in
//  Otto/Voice/VoiceInterruptions.swift; the inert source is shared.
//

import AVFoundation
import UIKit
import os

@MainActor final class SystemVoiceInterruptions: VoiceInterruptionSource {
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Voice")

    private var observers: [NSObjectProtocol] = []

    /// Nonisolated so it can be a default argument; it observes nothing until start.
    nonisolated init() {}

    func start(_ handler: @escaping @MainActor (VoiceInterruption) -> Void) {
        stop()
        let deliver: @Sendable (VoiceInterruption) -> Void = { interruption in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Self.logger.info("Voice interrupted: \(String(describing: interruption), privacy: .public)")
                    handler(interruption)
                }
            }
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { _ in
                deliver(.sessionResignedActive)
            },
            center.addObserver(
                forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: nil
            ) { _ in
                deliver(.screenLocked)
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                deliver(.sessionResignedActive)
            },
        ]
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
}

enum VoiceHoldProbes {
    /// iPhone has no global key to poll: the mic button's own touch tracking reports the release.
    @MainActor static func live(settings: AppSettings) -> VoiceHoldProbe {
        { _ in nil }
    }
}
