//
//  HotKeyManager.swift
//  Otto
//
//  The global shortcut through the Carbon hot-key API: press and release, a swappable combo, and a
//  registrar seam so tests never register a real hot key. Unlike a global NSEvent key monitor this needs
//  no Accessibility permission, and the key press is consumed instead of reaching the frontmost app.
//

import Carbon.HIToolbox
import os

enum HotKeyEventKind: Equatable, Sendable { case pressed, released }

/// The Carbon layer (RegisterEventHotKey with kEventHotKeyExclusive, one handler for kEventHotKeyPressed and
/// kEventHotKeyReleased). Tests inject a fake, so nothing is registered system-wide.
@MainActor protocol HotKeyRegistering: AnyObject {
    /// Registers `combo` exclusively; noErr, or the OSStatus (eventHotKeyExistsErr → RegistrationError.alreadyInUse).
    func register(_ combo: HotKeyCombo, handler: @escaping @MainActor (HotKeyEventKind) -> Void) -> OSStatus
    func unregister()
}

@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistering {
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Input")
    /// Four-character signature identifying Otto's hot keys ("OTTO").
    private static let signature: OSType = 0x4F54_544F
    private static let hotKeyIdentifier: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (@MainActor (HotKeyEventKind) -> Void)?

    /// Nonisolated so it can be `HotKeyManager.init`'s default argument; it only sets empty state.
    nonisolated init() {}

    deinit {
        // Mirrors unregister(); deinit cannot hop to the main actor, and the Carbon calls are thread-safe.
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    /// The registration is *exclusive*: a non-exclusive `RegisterEventHotKey` succeeds silently even while
    /// another process owns the same combination, so a conflict would never be reported. With
    /// `kEventHotKeyExclusive`, a clash with another exclusive owner returns `eventHotKeyExistsErr`, and later
    /// non-exclusive registrants cannot take the combo from Otto. Apps that registered it non-exclusively
    /// *before* Otto still cannot be detected: Carbon reports success in that case.
    func register(_ combo: HotKeyCombo, handler: @escaping @MainActor (HotKeyEventKind) -> Void) -> OSStatus {
        unregister()
        let installStatus = installEventHandler()
        guard installStatus == noErr else { return installStatus }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyIdentifier)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &ref
        )
        guard status == noErr, let ref else {
            removeEventHandler()
            return status == noErr ? OSStatus(eventInternalErr) : status
        }
        hotKeyRef = ref
        self.handler = handler
        return noErr
    }

    /// Unregisters the hot key and removes the Carbon event handler. Idempotent.
    func unregister() {
        if let hotKeyRef {
            let status = UnregisterEventHotKey(hotKeyRef)
            if status != noErr {
                Self.logger.error("UnregisterEventHotKey failed with status \(status, privacy: .public)")
            }
            self.hotKeyRef = nil
        }
        handler = nil
        removeEventHandler()
    }

    // MARK: - Carbon plumbing

    private func installEventHandler() -> OSStatus {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        // The handler is removed in unregister()/deinit before `self` goes away, so an unretained pointer is
        // sufficient and avoids a retain cycle through the Carbon event system.
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyEventCallback,
            eventTypes.count,
            &eventTypes,
            userData,
            &ref
        )
        guard status == noErr, let ref else {
            Self.logger.error("InstallEventHandler failed with status \(status, privacy: .public)")
            return status == noErr ? OSStatus(eventInternalErr) : status
        }
        eventHandlerRef = ref
        return noErr
    }

    private func removeEventHandler() {
        guard let eventHandlerRef else { return }
        RemoveEventHandler(eventHandlerRef)
        self.eventHandlerRef = nil
    }

    /// Called from the C callback. Returns true when the event was Otto's hot key.
    fileprivate func handleCarbonEvent(_ event: EventRef) -> Bool {
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

        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed): handler?(.pressed)
        case UInt32(kEventHotKeyReleased): handler?(.released)
        default: return false
        }
        return true
    }
}

/// C-compatible Carbon event handler (EventHandlerUPP). Cannot capture context: the registrar arrives through
/// `userData` as an unretained pointer.
private let carbonHotKeyEventCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    // Carbon dispatches application-target events on the main thread.
    let handled = MainActor.assumeIsolated { registrar.handleCarbonEvent(event) }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}

@MainActor
final class HotKeyManager {
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Input")

    enum RegistrationError: Error, Equatable {
        /// Another process registered the same combination exclusively (`eventHotKeyExistsErr`).
        case alreadyInUse
        /// Any other Carbon failure (status code attached).
        case failed(OSStatus)
    }

    private(set) var combo: HotKeyCombo

    /// Whether the shortcut is currently registered with the system.
    var isRegistered: Bool { hasRegistration }

    /// Why the most recent `register()` failed; nil after a successful registration or `unregister()`.
    private(set) var lastRegistrationError: RegistrationError?

    private let onPress: @MainActor () -> Void
    private let onRelease: @MainActor () -> Void
    private let registrar: HotKeyRegistering
    private var hasRegistration = false
    /// Between a dispatched press and its release. Carbon doesn't repeat hot keys, but a second press is ignored.
    private var isDown = false

    /// Replaces init(keyCode:modifiers:handler:). The existing call `HotKeyManager { … }` in AppDelegate keeps
    /// compiling: its trailing closure binds to `onPress` (forward-scan matching skips the defaulted non-closure
    /// `combo`; `onRelease` and `registrar` are defaulted). No second initializer (it would make that call ambiguous).
    init(combo: HotKeyCombo = .optionSpace, onPress: @escaping @MainActor () -> Void,
         onRelease: @escaping @MainActor () -> Void = {},
         registrar: HotKeyRegistering = CarbonHotKeyRegistrar()) {
        self.combo = combo
        self.onPress = onPress
        self.onRelease = onRelease
        self.registrar = registrar
    }

    /// Internal: what the registrar's handler calls (tests drive it directly).
    func handle(_ kind: HotKeyEventKind) {
        switch kind {
        case .pressed:
            guard !isDown else { return }
            isDown = true
            onPress()
        case .released:
            guard isDown else { return }
            isDown = false
            onRelease()
        }
    }

    /// Registers the current combo. Idempotent. Returns false (and logs, and sets `lastRegistrationError`) if the
    /// system refused it.
    @discardableResult
    func register() -> Bool {
        if isRegistered { return true }
        let status = registrar.register(combo) { [weak self] kind in
            self?.handle(kind)
        }
        guard status == noErr else {
            Self.logger.error("Registering the global shortcut failed with status \(status, privacy: .public)")
            lastRegistrationError = status == OSStatus(eventHotKeyExistsErr) ? .alreadyInUse : .failed(status)
            return false
        }
        hasRegistration = true
        lastRegistrationError = nil
        return true
    }

    /// Unregisters the shortcut. Idempotent. A press still held is closed with its release, so a hold gesture
    /// never outlives the registration that would have reported its end.
    func unregister() {
        if isRegistered {
            registrar.unregister()
            hasRegistration = false
        }
        lastRegistrationError = nil
        if isDown { handle(.released) }
    }

    /// Swaps to `newCombo`; on failure re-registers the previous one (if it was registered) and returns the error.
    /// The new combo is registered even when the shortcut was off: choosing a shortcut turns it on.
    func update(to newCombo: HotKeyCombo) -> Result<Void, RegistrationError> {
        if newCombo == combo, isRegistered { return .success(()) }
        let previous = combo
        let wasRegistered = isRegistered
        unregister()
        combo = newCombo
        if register() { return .success(()) }

        let error = lastRegistrationError ?? .failed(OSStatus(eventInternalErr))
        combo = previous
        if wasRegistered, !register() {
            Self.logger.error("Restoring the previous global shortcut failed")
        }
        return .failure(error)
    }
}
