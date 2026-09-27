//
//  BrowserContext.swift
//  Otto
//
//  Reads the title and address of the frontmost tab of a supported browser via
//  AppleScript. Scripts run on one dedicated serial queue (NSAppleScript is not
//  thread-safe), never on the main thread, and callers stop waiting after a
//  short timeout so a busy or hung browser can't stall the notch.
//

import AppKit
import Foundation
import os

struct BrowserTab: Equatable, Sendable {
    let title: String
    let url: URL
    let bundleID: String
    /// True only when the browser confirmed the tab is not in a private/incognito window. Safari exposes no
    /// way to tell (its private windows are scriptable like any other), and some Chromium browsers lack the
    /// property, so those tabs are `false`: they may be offered as a suggestion the user taps, but must never
    /// be attached (and sent) automatically.
    var isKnownNonPrivate: Bool = false
}

enum BrowserContext {
    /// How long a caller waits for the browser before giving up.
    static let timeout: TimeInterval = 1.5

    private enum Family {
        /// Chrome's dictionary: `mode` of a window is "normal" or "incognito".
        case chromium
        /// Arc's dictionary: windows have an `incognito` boolean and no `mode`.
        case arc
        case safari
    }

    /// Keys are lowercased: bundle identifiers compare case-insensitively.
    private static let families: [String: Family] = [
        "com.google.chrome": .chromium,
        "com.google.chrome.beta": .chromium,
        "com.google.chrome.dev": .chromium,
        "com.google.chrome.canary": .chromium,
        "org.chromium.chromium": .chromium,
        "com.brave.browser": .chromium,
        "com.brave.browser.beta": .chromium,
        "com.brave.browser.nightly": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.microsoft.edgemac.beta": .chromium,
        "com.microsoft.edgemac.dev": .chromium,
        "com.microsoft.edgemac.canary": .chromium,
        "com.vivaldi.vivaldi": .chromium,
        "com.operasoftware.opera": .chromium,
        "com.operasoftware.operagx": .chromium,
        "company.thebrowser.browser": .arc,
        "com.apple.safari": .safari,
        "com.apple.safaritechnologypreview": .safari,
    ]

    private static let queue = DispatchQueue(label: "com.jalenedusei.otto.browser-context", qos: .userInitiated)
    private static let scriptCache = ScriptCache()
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "BrowserContext")

    /// Chromium family (Chrome, Chrome Canary, Chromium, Brave, Edge, Vivaldi, Opera, Arc) + Safari (+ Tech Preview).
    static func isSupportedBrowser(bundleID: String?) -> Bool {
        family(for: bundleID) != nil
    }

    /// Front window's active tab via AppleScript on a dedicated serial queue (never the main thread).
    /// When `allowPrompt` is false, first checks AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)
    /// and returns nil unless automation is already authorized. Returns nil for non-http(s) URLs,
    /// errors, or unsupported apps. Must time out (≈1.5 s) instead of hanging.
    static func currentTab(of app: NSRunningApplication, allowPrompt: Bool) async -> BrowserTab? {
        guard !app.isTerminated,
              let bundleID = app.bundleIdentifier,
              let family = family(for: bundleID)
        else { return nil }

        let pending = PendingResult<BrowserTab?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.install(continuation)
                queue.async {
                    // An earlier script may have held the queue past this caller's deadline; skip the work then.
                    guard !pending.isResolved else { return }
                    let tab = autoreleasepool {
                        fetchTab(bundleID: bundleID, family: family, allowPrompt: allowPrompt)
                    }
                    pending.resolve(tab)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    if pending.resolve(nil) {
                        logger.info("Timed out reading the current tab of \(bundleID, privacy: .public)")
                    }
                }
            }
        } onCancel: {
            pending.resolve(nil)
        }
    }

    /// Whether Otto may send Apple events to a browser, as far as the system has decided.
    enum AutomationConsent: Equatable, Sendable {
        /// Already allowed: a lookup runs without any prompt.
        case authorized
        /// Not decided yet: a prompt-allowed lookup will show the system consent dialog.
        case wouldPrompt
        /// The user turned it off in System Settings → Privacy & Security → Automation.
        case denied
        /// Not a supported browser, not running, or the check itself failed.
        case unavailable
    }

    /// The current Automation consent for `app`, without ever prompting. Runs off the main thread (and
    /// off the script queue, which a lookup waiting on the consent dialog may be holding).
    static func automationConsentStatus(of app: NSRunningApplication) async -> AutomationConsent {
        guard !app.isTerminated, let bundleID = app.bundleIdentifier, family(for: bundleID) != nil else {
            return .unavailable
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let status = automationPermissionStatus(for: bundleID)
                let consent: AutomationConsent
                switch Int(status) {
                case Int(noErr): consent = .authorized
                case errAEEventWouldRequireUserConsent: consent = .wouldPrompt
                case errAEEventNotPermitted: consent = .denied
                default: consent = .unavailable
                }
                continuation.resume(returning: consent)
            }
        }
    }

    // MARK: - Script execution (script queue only)

    private static func family(for bundleID: String?) -> Family? {
        guard let bundleID else { return nil }
        return families[bundleID.lowercased()]
    }

    private static func fetchTab(bundleID: String, family: Family, allowPrompt: Bool) -> BrowserTab? {
        if !allowPrompt {
            let status = automationPermissionStatus(for: bundleID)
            guard status == OSStatus(noErr) else {
                switch Int(status) {
                case errAEEventWouldRequireUserConsent:
                    logger.debug("Automation of \(bundleID, privacy: .public) not yet authorized")
                case errAEEventNotPermitted:
                    logger.debug("Automation of \(bundleID, privacy: .public) was denied")
                default:
                    logger.debug("Automation check for \(bundleID, privacy: .public) returned \(status)")
                }
                return nil
            }
        }

        guard let script = scriptCache.script(for: bundleID, makeSource: { scriptSource(bundleID: bundleID, family: family) }) else {
            return nil
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        // On failure the (nonnull-annotated) result is nil, so check the error before touching it.
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            logger.debug("Tab lookup in \(bundleID, privacy: .public) failed with AppleScript error \(code)")
            return nil
        }
        return parseTab(descriptor, bundleID: bundleID)
    }

    /// Whether this process may already send Apple events to the app, without ever prompting.
    private static func automationPermissionStatus(for bundleID: String) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return withExtendedLifetime(target) {
            guard let address = target.aeDesc else { return OSStatus(procNotFound) }
            return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, false)
        }
    }

    /// `is running` keeps the script from relaunching a browser that quit in the meantime, and
    /// `with timeout` bounds how long a hung browser can hold the script queue.
    ///
    /// Scripts return `{title, URL, knownNonPrivate}` (Safari: `{title, URL}`), or `missing value` for a
    /// private window. A window is only reported as non-private when the browser positively says so; if the
    /// property can't be read (it raises inside the `try`) the tab comes back unverified.
    private static func scriptSource(bundleID: String, family: Family) -> String {
        switch family {
        case .chromium:
            return """
            if application id "\(bundleID)" is running then
                with timeout of 2 seconds
                    tell application id "\(bundleID)"
                        set frontWindow to front window
                        set knownNonPrivate to false
                        try
                            set windowMode to mode of frontWindow
                            if windowMode is "incognito" then return missing value
                            if windowMode is "normal" then set knownNonPrivate to true
                        end try
                        set activeTab to active tab of frontWindow
                        return {title of activeTab, URL of activeTab, knownNonPrivate}
                    end tell
                end timeout
            end if
            """
        case .arc:
            return """
            if application id "\(bundleID)" is running then
                with timeout of 2 seconds
                    tell application id "\(bundleID)"
                        set frontWindow to front window
                        set knownNonPrivate to false
                        try
                            set isIncognito to incognito of frontWindow
                            if isIncognito is true then return missing value
                            if isIncognito is false then set knownNonPrivate to true
                        end try
                        set activeTab to active tab of frontWindow
                        return {title of activeTab, URL of activeTab, knownNonPrivate}
                    end tell
                end timeout
            end if
            """
        case .safari:
            // Safari's dictionary has no private-browsing property and private windows answer like normal
            // ones, so Safari tabs are always returned unverified (suggest only, never auto-attach).
            return """
            if application id "\(bundleID)" is running then
                with timeout of 2 seconds
                    tell application id "\(bundleID)" to return {name, URL} of current tab of front window
                end timeout
            end if
            """
        }
    }

    /// Script source for a supported bundle identifier (nil otherwise). Internal for tests.
    static func scriptSource(bundleID: String) -> String? {
        family(for: bundleID).map { scriptSource(bundleID: bundleID, family: $0) }
    }

    /// Internal for tests.
    static func parseTab(_ descriptor: NSAppleEventDescriptor, bundleID: String) -> BrowserTab? {
        guard descriptor.descriptorType == typeAEList, descriptor.numberOfItems >= 2,
              let urlString = string(from: descriptor.atIndex(2)),
              let url = AttachmentLoader.webURL(from: urlString)
        else { return nil }
        let rawTitle = string(from: descriptor.atIndex(1)) ?? ""
        let title = rawTitle.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // Only an explicit AppleScript `true` counts; a missing third item (Safari) or anything else doesn't.
        let knownNonPrivate = descriptor.numberOfItems >= 3
            && descriptor.atIndex(3).map { $0.descriptorType == typeTrue || ($0.descriptorType == typeBoolean && $0.booleanValue) } == true
        return BrowserTab(
            title: title.isEmpty ? (url.host ?? url.absoluteString) : title,
            url: url,
            bundleID: bundleID,
            isKnownNonPrivate: knownNonPrivate
        )
    }

    private static func string(from descriptor: NSAppleEventDescriptor?) -> String? {
        guard let descriptor else { return nil }
        switch descriptor.descriptorType {
        case typeNull, typeType:  // `missing value` comes back as a type descriptor
            return nil
        default:
            return descriptor.stringValue
        }
    }
}

// MARK: - Support types

extension BrowserContext {
    /// Compiled scripts keyed by bundle identifier. Only touched on BrowserContext's serial queue.
    private final class ScriptCache: @unchecked Sendable {
        private var scripts: [String: NSAppleScript] = [:]
        private let logger = Logger(subsystem: "com.jalenedusei.otto", category: "BrowserContext")

        func script(for bundleID: String, makeSource: () -> String) -> NSAppleScript? {
            if let cached = scripts[bundleID] { return cached }
            guard let script = NSAppleScript(source: makeSource()) else { return nil }
            var errorInfo: NSDictionary?
            guard script.compileAndReturnError(&errorInfo) else {
                let code = (errorInfo?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
                logger.error("Couldn't compile the tab script for \(bundleID, privacy: .public): error \(code)")
                return nil
            }
            scripts[bundleID] = script
            return script
        }
    }

    /// Delivers exactly one value to a continuation — whichever of result, timeout or cancellation comes first.
    private final class PendingResult<Value>: @unchecked Sendable {
        private enum State {
            case idle
            case waiting(CheckedContinuation<Value, Never>)
            case resolved(Value)
        }

        private let lock = NSLock()
        private var state = State.idle

        var isResolved: Bool {
            lock.lock()
            defer { lock.unlock() }
            if case .resolved = state { return true }
            return false
        }

        func install(_ continuation: CheckedContinuation<Value, Never>) {
            lock.lock()
            if case .resolved(let value) = state {
                lock.unlock()
                continuation.resume(returning: value)
                return
            }
            state = .waiting(continuation)
            lock.unlock()
        }

        /// Returns true if this call delivered the value (false if something else won the race).
        @discardableResult
        func resolve(_ value: Value) -> Bool {
            lock.lock()
            switch state {
            case .resolved:
                lock.unlock()
                return false
            case .idle:
                state = .resolved(value)
                lock.unlock()
                return true
            case .waiting(let continuation):
                state = .resolved(value)
                lock.unlock()
                continuation.resume(returning: value)
                return true
            }
        }
    }
}
