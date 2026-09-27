//
//  HotKeyManager.swift
//  Otto
//
//  Global ⌥Space shortcut via the Carbon hot-key API. Unlike a global NSEvent key monitor this
//  needs no Accessibility permission, and the key press is consumed instead of reaching the
//  frontmost app.
//

import Carbon.HIToolbox
import os

@MainActor
final class HotKeyManager {
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "HotKey")
    /// Four-character signature identifying Otto's hot keys ("OTTO").
    private static let signature: OSType = 0x4F54_544F
    private static let hotKeyIdentifier: UInt32 = 1

    private let handler: @MainActor () -> Void
    private let keyCode: UInt32
    private let modifiers: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// Whether the shortcut is currently registered with the system.
    var isRegistered: Bool { hotKeyRef != nil }

    /// Why the most recent `register()` failed; nil after a successful registration or `unregister()`.
    private(set) var lastRegistrationError: RegistrationError?

    enum RegistrationError: Equatable {
        /// Another process registered the same combination exclusively (`eventHotKeyExistsErr`).
        case alreadyInUse
        /// Any other Carbon failure (status code attached).
        case failed(OSStatus)
    }

    /// Defaults to ⌥Space.
    init(
        keyCode: UInt32 = UInt32(kVK_Space),
        modifiers: UInt32 = UInt32(optionKey),
        handler: @escaping @MainActor () -> Void
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler
    }

    deinit {
        // Mirrors unregister(); deinit cannot hop to the main actor, and the Carbon calls are thread-safe.
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    /// Registers the shortcut. Idempotent. Returns false (and logs, and sets `lastRegistrationError`)
    /// if the system refused it.
    ///
    /// The registration is *exclusive*: a non-exclusive `RegisterEventHotKey` succeeds silently even
    /// while another process owns the same combination, so a conflict would never be reported. With
    /// `kEventHotKeyExclusive`, a clash with another exclusive owner returns `eventHotKeyExistsErr`,
    /// and later non-exclusive registrants of ⌥Space cannot take it from Otto. Apps that registered
    /// the combination non-exclusively *before* Otto still cannot be detected — Carbon reports
    /// success in that case (documented in the README).
    @discardableResult
    func register() -> Bool {
        if hotKeyRef != nil { return true }
        guard installEventHandlerIfNeeded() else {
            lastRegistrationError = .failed(OSStatus(eventInternalErr))
            return false
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyIdentifier)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &ref
        )
        guard status == noErr, let ref else {
            Self.logger.error("RegisterEventHotKey failed with status \(status, privacy: .public)")
            lastRegistrationError = status == OSStatus(eventHotKeyExistsErr) ? .alreadyInUse : .failed(status)
            removeEventHandler()
            return false
        }
        hotKeyRef = ref
        lastRegistrationError = nil
        return true
    }

    /// Unregisters the shortcut and removes the Carbon event handler. Idempotent.
    func unregister() {
        if let hotKeyRef {
            let status = UnregisterEventHotKey(hotKeyRef)
            if status != noErr {
                Self.logger.error("UnregisterEventHotKey failed with status \(status, privacy: .public)")
            }
            self.hotKeyRef = nil
        }
        lastRegistrationError = nil
        removeEventHandler()
    }

    // MARK: - Carbon plumbing

    private func installEventHandlerIfNeeded() -> Bool {
        if eventHandlerRef != nil { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The handler is removed in unregister()/deinit before `self` goes away, so an unretained
        // pointer is sufficient and avoids a retain cycle through the Carbon event system.
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyEventCallback, 1, &eventType, userData, &ref)
        guard status == noErr, let ref else {
            Self.logger.error("InstallEventHandler failed with status \(status, privacy: .public)")
            return false
        }
        eventHandlerRef = ref
        return true
    }

    private func removeEventHandler() {
        guard let eventHandlerRef else { return }
        RemoveEventHandler(eventHandlerRef)
        self.eventHandlerRef = nil
    }

    /// Called from the C callback. Returns true when the event was Otto's hot key.
    fileprivate func handleHotKeyEvent(_ event: EventRef) -> Bool {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr,
              hotKeyID.signature == Self.signature,
              hotKeyID.id == Self.hotKeyIdentifier
        else { return false }
        handler()
        return true
    }
}

/// C-compatible Carbon event handler (EventHandlerUPP). Cannot capture context: the manager arrives
/// through `userData` as an unretained pointer.
private let hotKeyEventCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    // Carbon dispatches application-target events on the main thread.
    let handled = MainActor.assumeIsolated { manager.handleHotKeyEvent(event) }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
