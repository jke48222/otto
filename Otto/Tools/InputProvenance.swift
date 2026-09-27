//
//  InputProvenance.swift
//  Otto
//
//  Decides whether the input behind an approval came from this Mac's own keyboard or trackpad.
//  Hardware events carry source process id 0; events posted by another process (System Events,
//  remote control, scripts) carry that process's id and can never approve an action.
//

import AppKit
import Foundation
import os

/// What the input behind an approval looked like (captured at the event, judged by `mayApprove`).
struct InputEvidence: Equatable, Sendable {
    enum Source: Equatable, Sendable { case keyboard, pointer, accessibility, programmatic }

    var source: Source
    /// keyboard/pointer: `cgEvent.eventSourceUnixProcessID == 0` (real hardware). accessibility (no CGEvent): VoiceOver
    /// or Switch Control is running. programmatic: always false.
    var isHardware: Bool
    /// NSEvent.isARepeat on a keyDown.
    var isRepeat: Bool
    /// `event.timestamp` (system uptime) of the keyDown, or of the mouseDown that began the click; nil for AX presses.
    var uptime: TimeInterval?

    static let programmatic = InputEvidence(source: .programmatic, isHardware: false, isRepeat: false, uptime: nil)

    /// Tests/SelfTest: trusted input with no timestamp (the executor's clock still enforces arming).
    static func trusted(_ source: Source = .keyboard) -> InputEvidence {
        InputEvidence(source: source, isHardware: true, isRepeat: false, uptime: nil)
    }
}

enum InputProvenance {
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Input")

    /// Evidence for `event` (normally `NSApp.currentEvent`). SwiftUI button actions run on mouseUp, so for a mouseUp the
    /// caller passes the mouseDown the window controller recorded for the panel (`vm.lastPanelMouseDown`); a mouseUp
    /// without a recorded hardware mouseDown is not hardware. Events without a CGEvent (accessibility presses) are
    /// hardware only while `NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled`.
    @MainActor static func evidence(for event: NSEvent?, mouseDown: (uptime: TimeInterval, isHardware: Bool)?) -> InputEvidence {
        guard let event, let cgEvent = event.cgEvent else {
            let workspace = NSWorkspace.shared
            let assistive = workspace.isVoiceOverEnabled || workspace.isSwitchControlEnabled
            return InputEvidence(source: .accessibility, isHardware: assistive, isRepeat: false, uptime: nil)
        }
        let fromHardware = cgEvent.getIntegerValueField(.eventSourceUnixProcessID) == 0

        switch event.type {
        case .keyDown:
            return InputEvidence(source: .keyboard, isHardware: fromHardware, isRepeat: event.isARepeat,
                                 uptime: event.timestamp)
        case .keyUp:
            return InputEvidence(source: .keyboard, isHardware: fromHardware, isRepeat: false, uptime: event.timestamp)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return InputEvidence(source: .pointer, isHardware: fromHardware, isRepeat: false, uptime: event.timestamp)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let mouseDown else {
                return InputEvidence(source: .pointer, isHardware: false, isRepeat: false, uptime: nil)
            }
            return InputEvidence(source: .pointer, isHardware: fromHardware && mouseDown.isHardware, isRepeat: false,
                                 uptime: mouseDown.uptime)
        default:
            return .programmatic
        }
    }

    /// Pure: `isHardware && !isRepeat && armedAtUptime != nil && (uptime == nil || uptime >= armedAtUptime!)`.
    /// A held ⌘↩ (auto-repeat) or a press that began before the card was armed never approves.
    static func mayApprove(_ evidence: InputEvidence, armedAtUptime: TimeInterval?) -> Bool {
        guard evidence.isHardware, !evidence.isRepeat, let armedAtUptime else { return false }
        guard let uptime = evidence.uptime else { return true }
        return uptime >= armedAtUptime
    }

    /// `evidence(for: event, mouseDown: nil)` is hardware and not a repeat. Logged when false (`blocked_synthetic_input`).
    @MainActor static func isTrustedUserEvent(_ event: NSEvent?) -> Bool {
        let evidence = evidence(for: event, mouseDown: nil)
        let trusted = evidence.isHardware && !evidence.isRepeat
        if !trusted {
            logger.notice("blocked_synthetic_input source=\(String(describing: evidence.source), privacy: .public) repeat=\(evidence.isRepeat, privacy: .public)")
        }
        return trusted
    }
}
