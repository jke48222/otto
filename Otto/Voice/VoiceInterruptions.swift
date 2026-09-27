//
//  VoiceInterruptions.swift
//  Otto
//
//  What ends a voice session early so the microphone never stays on unattended: the screen locking, the Mac
//  or its displays going to sleep, and switching users. Also the probes that tell whether the key or mouse
//  button that started a hold is still physically down.
//

import AppKit
import CoreGraphics
import os

/// Distributed "com.apple.screenIsLocked"; NSWorkspace willSleep / screensDidSleep / sessionDidResignActive.
@MainActor final class SystemVoiceInterruptions: VoiceInterruptionSource {
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Voice")
    private static let screenLocked = Notification.Name("com.apple.screenIsLocked")

    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

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
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            (distributed, distributed.addObserver(forName: Self.screenLocked, object: nil, queue: nil) { _ in
                deliver(.screenLocked)
            }),
            (workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
                deliver(.willSleep)
            }),
            (workspace, workspace.addObserver(
                forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil
            ) { _ in
                deliver(.screensDidSleep)
            }),
            (workspace, workspace.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: nil
            ) { _ in
                deliver(.sessionResignedActive)
            }),
        ]
    }

    func stop() {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers.removeAll()
    }
}

/// Never observes the system. `fire(_:)` delivers an interruption while started (tests, SelfTest, demos).
@MainActor final class InertVoiceInterruptions: VoiceInterruptionSource {
    private var handler: (@MainActor (VoiceInterruption) -> Void)?

    nonisolated init() {}

    var isStarted: Bool { handler != nil }

    func start(_ handler: @escaping @MainActor (VoiceInterruption) -> Void) {
        self.handler = handler
    }

    func stop() {
        handler = nil
    }

    func fire(_ interruption: VoiceInterruption) {
        handler?(interruption)
    }
}

enum VoiceHoldProbes {
    /// .shortcut → CGEventSource.keyState(.combinedSessionState, key: settings.shortcuts.hotKey.keyCode);
    /// .micButton → NSEvent.pressedMouseButtons & 1 != 0.
    @MainActor static func live(settings: AppSettings) -> VoiceHoldProbe {
        { [weak settings] source in
            switch source {
            case .shortcut:
                guard let settings, let keyCode = CGKeyCode(exactly: settings.shortcuts.hotKey.keyCode) else {
                    return nil
                }
                return CGEventSource.keyState(.combinedSessionState, key: keyCode)
            case .micButton:
                return NSEvent.pressedMouseButtons & 1 != 0
            }
        }
    }
}
