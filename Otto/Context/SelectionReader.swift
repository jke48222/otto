//
//  SelectionReader.swift
//  Otto
//
//  Reads the text selected in another app through the Accessibility API, off the main thread on one
//  serial queue with short timeouts, and never in a password field, under secure input or in a
//  password manager. Also the seam (`SelectionReading`) that tests, snapshots and promo use instead.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CryptoKit
import Foundation
import os

// MARK: - Values

/// Opaque, main-actor-agnostic wrapper so an AXUIElement can ride along in Sendable values.
final class AXElementRef: @unchecked Sendable, Equatable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    static func == (l: AXElementRef, r: AXElementRef) -> Bool { CFEqual(l.element, r.element) }
}

struct SelectionSnapshot: Equatable, Sendable {
    enum Source: Equatable, Sendable { case accessibility, service }

    let text: String
    let app: AppRef?
    /// AXFocusedWindow → AXTitle (display only, never sent).
    let windowTitle: String?
    /// UTF-16 range from AXSelectedTextRange, when reported.
    let range: CFRange?
    let element: AXElementRef?
    let source: Source
    let capturedAt: Date
    /// First 16 hex chars of SHA-256(text) (CryptoKit) — dedupe, dismissal, change detection.
    let fingerprint: String

    /// Longest window title kept for display.
    private static let maxWindowTitleLength = 120
    /// A short selection is quoted on the ghost chip when it has at most this many words…
    private static let quotedMaxWords = 3
    /// …and at most this many characters.
    private static let quotedMaxCharacters = 24
    /// Attachments made from a selection carry `otto-selection:<fingerprint>` as their source.
    static let sourceScheme = "otto-selection"

    /// NUL characters are removed from `text`; the fingerprint is taken over what is kept.
    init(text: String, app: AppRef?, windowTitle: String?, range: CFRange?, element: AXElementRef?,
         source: Source, capturedAt: Date = Date()) {
        let cleaned = text.contains("\0") ? text.replacingOccurrences(of: "\0", with: "") : text
        self.text = cleaned
        self.app = app
        self.windowTitle = windowTitle
            .map { DisplayText.sanitized($0, maxLength: Self.maxWindowTitleLength) }
            .flatMap { $0.isEmpty ? nil : $0 }
        self.range = range
        self.element = element
        self.source = source
        self.capturedAt = capturedAt
        self.fingerprint = Self.digest(of: cleaned)
    }

    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }

    /// "Selection · 42 words" / "Selection · “Fix typo”" (≤ 3 words, ≤ 24 chars) for the ghost chip.
    var ghostLabel: String {
        let words = text.split(whereSeparator: \.isWhitespace)
        let joined = words.joined(separator: " ")
        if !words.isEmpty, words.count <= Self.quotedMaxWords, joined.count <= Self.quotedMaxCharacters {
            let quoted = DisplayText.sanitized(joined, maxLength: Self.quotedMaxCharacters)
            if !quoted.isEmpty { return "Selection · “\(quoted)”" }
        }
        return words.count == 1 ? "Selection · 1 word" : "Selection · \(words.count) words"
    }

    /// `.text` attachment: displayName "Selection from {App}" (or "Selection"), badge "SEL",
    /// appBundleID = app?.bundleID, sourceURL = otto-selection:<fingerprint>. Throws AttachmentError.
    /// The payload is never written to History (the chip is).
    func makeAttachment() throws -> Attachment {
        let name = app.map { "Selection from \($0.name)" } ?? "Selection"
        var attachment = try AttachmentLoader.makeTextAttachment(text, name: name)
        attachment.badge = "SEL"
        attachment.appBundleID = app?.bundleID
        attachment.sourceURL = URL(string: "\(Self.sourceScheme):\(fingerprint)")
        attachment.retainsPayloadInHistory = false
        return attachment
    }

    /// First 16 hex characters of SHA-256(text).
    static func digest(of text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func == (lhs: SelectionSnapshot, rhs: SelectionSnapshot) -> Bool {
        lhs.text == rhs.text && lhs.app == rhs.app && lhs.windowTitle == rhs.windowTitle
            && lhs.range?.location == rhs.range?.location && lhs.range?.length == rhs.range?.length
            && lhs.element == rhs.element && lhs.source == rhs.source && lhs.capturedAt == rhs.capturedAt
            && lhs.fingerprint == rhs.fingerprint
    }
}

enum SelectionState: Equatable, Sendable {
    /// The element's current selection == snapshot text.
    case unchanged
    /// The selection moved, but the text at snapshot.range still equals the snapshot text.
    case restorable
    /// The text at the range differs, or the element is gone.
    case changed
    /// No AX, no element or range (Services path).
    case unknown
}

/// What a focused text element held, to tell whether a paste landed.
struct ValueFingerprint: Equatable, Sendable { let characterCount: Int?; let valueHash: String? }

// MARK: - Seams

/// Seams so tests, snapshots and promo never read real selections or windows.
protocol SelectionReading: Sendable {
    func read(from app: AppRef) async -> SelectionSnapshot?                       // context-io.md §2.3 + §6.8 guards
    func snapshot(serviceText: String, app: AppRef?) async -> SelectionSnapshot
}

/// Wraps `SelectionReader`'s statics (real Accessibility reads).
struct LiveSelectionReader: SelectionReading {
    init() {}

    func read(from app: AppRef) async -> SelectionSnapshot? {
        await SelectionReader.read(from: app)
    }

    func snapshot(serviceText: String, app: AppRef?) async -> SelectionSnapshot {
        await SelectionReader.snapshot(serviceText: serviceText, app: app)
    }
}

/// Never reads a selection; a Services snapshot is the plain text alone.
struct InertSelectionReader: SelectionReading {
    init() {}

    func read(from app: AppRef) async -> SelectionSnapshot? { nil }

    func snapshot(serviceText: String, app: AppRef?) async -> SelectionSnapshot {
        SelectionSnapshot(text: serviceText, app: app, windowTitle: nil, range: nil, element: nil, source: .service)
    }
}

// MARK: - Reader

enum SelectionReader {
    static let messagingTimeout: Float = 0.25
    static let overallDeadline: Duration = .milliseconds(600)
    /// Password managers and Keychain Access (the shared list).
    static let excludedBundleIDs: Set<String> = SensitiveApps.bundleIDs
    /// Values longer than this are not hashed for paste verification.
    static let maxFingerprintedValueLength = 200_000

    /// Every Accessibility call Otto makes runs here, never on the main thread.
    static let axQueue = DispatchQueue(label: "com.jalenedusei.otto.accessibility", qos: .userInitiated)

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Context")
    /// Chromium's DOM class list for the focused element (not in the public headers).
    private static let domClassListAttribute = "AXDOMClassList"
    private static let passwordMarker = "password"

    /// What the read decision needs from the focused element, gathered on `axQueue`.
    struct FocusedElement: Sendable {
        var role: String?
        var subrole: String?
        var domClassList: [String] = []
        var elementDescription: String?
        var selectedText: String?
        var selectedRange: CFRange?
        var windowTitle: String?
        var element: AXElementRef?
    }

    /// The system calls behind `read`; tests pass a fake so nothing touches Accessibility.
    struct Probe: Sendable {
        var isSecureInputEnabled: @Sendable () -> Bool
        var focusedElement: @Sendable (AppRef) async -> FocusedElement?

        static let live = Probe(
            isSecureInputEnabled: { IsSecureEventInputEnabled() },
            focusedElement: { app in await SelectionReader.liveFocusedElement(in: app, includeSelection: true) }
        )
    }

    /// nil when: secure input is on, the app is a sensitive app, Accessibility isn't available, the focused
    /// field is a password field, nothing is selected / whitespace-only, over maxTextCharacters, timeout or error.
    static func read(from app: AppRef) async -> SelectionSnapshot? {
        await read(from: app, probe: .live)
    }

    static func read(from app: AppRef, probe: Probe, now: Date = Date()) async -> SelectionSnapshot? {
        // Checked before any Accessibility call.
        if probe.isSecureInputEnabled() {
            logger.debug("Selection read skipped: secure input is on")
            return nil
        }
        if SensitiveApps.contains(app) {
            logger.debug("Selection read skipped for a sensitive app")
            return nil
        }
        guard let focused = await probe.focusedElement(app) else { return nil }
        if isPasswordField(focused, in: app) {
            logger.debug("Selection read skipped: a password field is focused")
            return nil
        }
        guard let raw = focused.selectedText else { return nil }
        let snapshot = SelectionSnapshot(text: raw, app: app, windowTitle: focused.windowTitle,
                                         range: focused.selectedRange, element: focused.element,
                                         source: .accessibility, capturedAt: now)
        guard isOfferable(snapshot.text) else { return nil }
        logger.info("Read a selection of \(snapshot.text.count, privacy: .public) characters")
        return snapshot
    }

    /// Services path: wraps pasteboard text; if Accessibility can read the app, also reads its selection and,
    /// when the AX selection text equals `text`, adopts its element + range (enables precise Replace).
    static func snapshot(serviceText text: String, app: AppRef?) async -> SelectionSnapshot {
        await snapshot(serviceText: text, app: app, probe: .live)
    }

    static func snapshot(serviceText text: String, app: AppRef?, probe: Probe) async -> SelectionSnapshot {
        let plain = SelectionSnapshot(text: text, app: app, windowTitle: nil, range: nil, element: nil, source: .service)
        guard let app, let read = await read(from: app, probe: probe), read.text == plain.text else { return plain }
        return SelectionSnapshot(text: plain.text, app: app, windowTitle: read.windowTitle, range: read.range,
                                 element: read.element, source: .service, capturedAt: plain.capturedAt)
    }

    static func state(of snapshot: SelectionSnapshot) async -> SelectionState {
        guard let element = snapshot.element else { return .unknown }
        let expected = snapshot.text
        let range = snapshot.range
        return await onAXQueue(orAfterDeadline: .unknown) {
            AXUIElementSetMessagingTimeout(element.element, messagingTimeout)
            if let current = copyString(element.element, kAXSelectedTextAttribute),
               stripNUL(current) == expected {
                return .unchanged
            }
            guard var range else { return .changed }
            guard let rangeValue = AXValueCreate(.cfRange, &range) else { return .changed }
            var value: CFTypeRef?
            let error = AXUIElementCopyParameterizedAttributeValue(
                element.element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &value)
            guard error == .success, let value, CFGetTypeID(value) == CFStringGetTypeID(),
                  let text = value as? String else { return .changed }
            return stripNUL(text) == expected ? .restorable : .changed
        }
    }

    /// Sets AXSelectedTextRange back to snapshot.range. true on success.
    static func restoreSelection(_ snapshot: SelectionSnapshot) async -> Bool {
        guard let element = snapshot.element, let target = snapshot.range else { return false }
        return await onAXQueue(orAfterDeadline: false) {
            AXUIElementSetMessagingTimeout(element.element, messagingTimeout)
            var range = target
            guard let value = AXValueCreate(.cfRange, &range) else { return false }
            return AXUIElementSetAttributeValue(element.element, kAXSelectedTextRangeAttribute as CFString, value)
                == .success
        }
    }

    /// Secure subrole, or the Chromium password heuristic. false when the element can't be read.
    static func focusedElementIsSecure(in app: AppRef) async -> Bool {
        guard let focused = await liveFocusedElement(in: app, includeSelection: false) else { return false }
        return isPasswordField(focused, in: app)
    }

    /// kAXNumberOfCharactersAttribute + SHA-256 prefix of kAXValueAttribute when its length ≤ 200 000.
    /// nil when the focused element exposes neither.
    static func focusedValueFingerprint(in app: AppRef) async -> ValueFingerprint? {
        let pid = app.pid
        return await onAXQueue(orAfterDeadline: nil) {
            guard let focused = focusedUIElement(pid: pid) else { return nil }
            var count: Int?
            if let number = copyAttribute(focused, kAXNumberOfCharactersAttribute),
               CFGetTypeID(number) == CFNumberGetTypeID() {
                count = (number as? NSNumber)?.intValue
            }
            var hash: String?
            if let value = copyString(focused, kAXValueAttribute), value.utf16.count <= maxFingerprintedValueLength {
                hash = SelectionSnapshot.digest(of: value)
            }
            guard count != nil || hash != nil else { return nil }
            return ValueFingerprint(characterCount: count, valueHash: hash)
        }
    }

    // MARK: Pure rules

    /// `AXSecureTextField`, or (Chromium doesn't always expose that subrole) an `AXTextField` without a subrole in
    /// a Chromium-family app whose DOM class list or description mentions "password".
    static func isPasswordField(_ focused: FocusedElement, in app: AppRef) -> Bool {
        if focused.subrole == kAXSecureTextFieldSubrole as String { return true }
        guard focused.role == kAXTextFieldRole as String,
              focused.subrole?.isEmpty ?? true,
              isChromiumFamily(app) else { return false }
        if focused.domClassList.contains(where: { $0.lowercased().contains(passwordMarker) }) { return true }
        return focused.elementDescription?.lowercased().contains(passwordMarker) ?? false
    }

    /// Chromium-based browsers (Chrome, Brave, Edge, Vivaldi, Opera, Arc…) and Electron apps.
    static func isChromiumFamily(_ app: AppRef) -> Bool {
        if BrowserContext.isSupportedBrowser(bundleID: app.bundleID),
           !(app.bundleID?.lowercased().hasPrefix("com.apple.safari") ?? false) {
            return true
        }
        return isElectron(app)
    }

    /// The app bundle embeds Electron Framework.framework.
    static func isElectron(_ app: AppRef) -> Bool {
        guard let bundleURL = app.bundleURL else { return false }
        let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    /// Visible characters and within `AttachmentLoader.maxTextCharacters`.
    static func isOfferable(_ text: String) -> Bool {
        guard text.contains(where: { !$0.isWhitespace }) else { return false }
        // utf8.count is O(1) and bounds the character count from above.
        return text.utf8.count <= AttachmentLoader.maxTextCharacters || text.count <= AttachmentLoader.maxTextCharacters
    }

    // MARK: Accessibility (all on axQueue)

    static func liveFocusedElement(in app: AppRef, includeSelection: Bool) async -> FocusedElement? {
        let pid = app.pid
        return await onAXQueue(orAfterDeadline: nil) {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
            guard let focused = copyElement(appElement, kAXFocusedUIElementAttribute) else { return nil }
            AXUIElementSetMessagingTimeout(focused, messagingTimeout)
            var info = FocusedElement()
            info.role = copyString(focused, kAXRoleAttribute)
            info.subrole = copyString(focused, kAXSubroleAttribute)
            info.elementDescription = copyString(focused, kAXDescriptionAttribute)
            if let classes = copyAttribute(focused, domClassListAttribute), CFGetTypeID(classes) == CFArrayGetTypeID() {
                info.domClassList = (classes as? [Any])?.compactMap { $0 as? String } ?? []
            }
            // A password field is never read further.
            guard includeSelection, !isPasswordField(info, in: app) else { return info }
            info.selectedText = copyString(focused, kAXSelectedTextAttribute)
            info.selectedRange = copyRange(focused, kAXSelectedTextRangeAttribute)
            info.windowTitle = copyElement(appElement, kAXFocusedWindowAttribute).flatMap { copyString($0, kAXTitleAttribute) }
            info.element = AXElementRef(focused)
            return info
        }
    }

    private static func focusedUIElement(pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        guard let focused = copyElement(appElement, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)
        return focused
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyAttribute(element, attribute), CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return value as? String
    }

    private static func copyRange(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        guard let value = copyAttribute(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func stripNUL(_ text: String) -> String {
        text.contains("\0") ? text.replacingOccurrences(of: "\0", with: "") : text
    }

    /// Runs `work` on `axQueue`; returns `fallback` if it hasn't finished within `overallDeadline` (a hung app
    /// never holds up the caller; the late result is dropped).
    private static func onAXQueue<Value: Sendable>(orAfterDeadline fallback: Value,
                                                   _ work: @escaping @Sendable () -> Value) async -> Value {
        await ContextDeadline.race(fallback: fallback, deadline: overallDeadline) { resolve in
            axQueue.async { resolve(work()) }
        }
    }
}

// MARK: - Deadline race

/// Resolves an async call with whichever comes first: the work's result or a fallback at the deadline.
enum ContextDeadline {
    /// `start` receives a resolver it (or work it schedules) calls once with the result; later calls are ignored.
    static func race<Value: Sendable>(fallback: Value, deadline: Duration,
                                      start: (@escaping @Sendable (Value) -> Void) -> Void) async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            let gate = ContextResumeOnce(continuation)
            start { gate.resume($0) }
            let seconds = Double(deadline.components.seconds) + Double(deadline.components.attoseconds) / 1e18
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                gate.resume(fallback)
            }
        }
    }
}

/// A continuation that is resumed at most once, from any thread.
final class ContextResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        let pending: CheckedContinuation<Value, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
