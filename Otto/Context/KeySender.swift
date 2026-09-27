//
//  KeySender.swift
//  Otto
//
//  The one keystroke Otto ever types into another app: ⌘V, as tagged synthetic events, with the V key
//  found in the current keyboard layout (so Dvorak and AZERTY paste too). Also secure-input and
//  held-modifier checks the paste waits on.
//

import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

enum KeySendError: Error, Equatable {
    case cannotCreateEvent
}

protocol KeySending: AnyObject {
    /// IsSecureEventInputEnabled().
    var isSecureInputEnabled: Bool { get }
    /// CGEventSource.flagsState(.hidSystemState) ∩ [cmd, shift, alt, ctrl].
    func areModifiersDown() -> Bool
    /// KeySendError.cannotCreateEvent.
    func postPaste() throws
}

final class CGKeySender: KeySending {
    /// Stamped into kCGEventSourceUserData on every synthetic event (ASCII "OTTO").
    static let eventTag: Int64 = 0x4F54_544F

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Context")
    private static let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    init() {}

    var isSecureInputEnabled: Bool { IsSecureEventInputEnabled() }

    func areModifiersDown() -> Bool {
        !CGEventSource.flagsState(.hidSystemState).intersection(Self.modifiers).isEmpty
    }

    /// ⌘ down → V down → V up → ⌘ up, from a combined-session source, each tagged and posted to the HID tap.
    /// The explicit ⌘ pair is what makes Java/VM/Citrix-style apps see the shortcut. All four events are
    /// created before any is posted, so a failure never leaves ⌘ held down.
    func postPaste() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { throw KeySendError.cannotCreateEvent }
        let command = CGKeyCode(kVK_Command)
        let v = KeyboardLayout.commandKeyCode(for: "v")
        let steps: [(key: CGKeyCode, down: Bool, flags: CGEventFlags)] = [
            (command, true, .maskCommand),
            (v, true, .maskCommand),
            (v, false, .maskCommand),
            (command, false, []),
        ]
        let events = try steps.map { step -> CGEvent in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: step.key, keyDown: step.down) else {
                throw KeySendError.cannotCreateEvent
            }
            event.flags = step.flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
            return event
        }
        for event in events { event.post(tap: .cghidEventTap) }
        Self.logger.info("Posted ⌘V")
    }
}

enum KeyboardLayout {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [Character: CGKeyCode]] = [:]
    nonisolated(unsafe) private static var isObserving = false

    /// Virtual key that types `character` while ⌘ is held in the current input source (UCKeyTranslate over
    /// keycodes 0…127 with modifierKeyState = cmdKey >> 8, via TISCopyCurrentKeyboardLayoutInputSource /
    /// kTISPropertyUnicodeKeyLayoutData). Cached per input-source ID; invalidated on the distributed
    /// notification kTISNotifySelectedKeyboardInputSourceChanged. Falls back to kVK_ANSI_V.
    static func commandKeyCode(for character: Character) -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        let wanted = Character(character.lowercased())
        startObservingIfNeeded()
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return fallback }
        let sourceID = stringProperty(source, kTISPropertyInputSourceID) ?? "unknown"
        if let cached = lock.withLock({ cache[sourceID]?[wanted] }) { return cached }
        guard let keyCode = translate(wanted, in: source) else { return fallback }
        lock.withLock { cache[sourceID, default: [:]][wanted] = keyCode }
        return keyCode
    }

    private static func translate(_ character: Character, in source: TISInputSource) -> CGKeyCode? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let modifierState = UInt32((cmdKey >> 8) & 0xFF)
        let keyboardType = UInt32(LMGetKbdType())
        // The usual position first, so a layout that types the character there keeps it.
        let order = [CGKeyCode(kVK_ANSI_V)] + (0..<128).map { CGKeyCode($0) }.filter { $0 != CGKeyCode(kVK_ANSI_V) }
        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for keyCode in order {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), modifierState, keyboardType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                                            characters.count, &length, &characters)
                guard status == noErr, length > 0 else { continue }
                let typed = String(utf16CodeUnits: characters, count: length).lowercased()
                if typed == String(character) { return keyCode }
            }
            return nil
        }
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func startObservingIfNeeded() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !isObserving else { return false }
            isObserving = true
            return true
        }
        guard shouldStart else { return }
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: nil) { _ in
            lock.withLock { cache.removeAll() }
        }
    }
}
