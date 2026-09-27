//
//  AnswerInserter.swift
//  Otto
//
//  Pastes a finished answer into the app the question came from: writes it to the clipboard, hands focus
//  back, brings the app forward if needed, presses ⌘V once, checks it landed, and puts the user's
//  clipboard back only if nothing else changed it. Every system call goes through `InsertEnvironment`,
//  so tests run the whole sequence without real apps, Accessibility or key events.
//

import AppKit
import ApplicationServices
import Foundation
import os

struct InsertTarget: Equatable, Sendable {
    let app: AppRef
    /// The selection the question was about (Services or AX chip), for Replace.
    let selection: SelectionSnapshot?
}

struct InsertRequest: Equatable {
    var markdown: String
    var target: InsertTarget
    var mode: InsertMode
    var restoreClipboard: Bool
    /// Set once the user confirmed a multi-line terminal paste / a changed selection.
    var confirmedMultiline = false
    var allowPasteAtCursor = false
}

enum InsertPreflight: Equatable {
    case ready
    case needsAccessibility
    case targetGone
    case confirmMultiline(lines: Int)
    case selectionChanged
}

enum InsertOutcome: Equatable {
    /// What happened to the clipboard the user had before the paste.
    enum Clipboard: Equatable {
        /// Put back.
        case restored
        /// "Put my clipboard back" is off: the answer stays on the clipboard.
        case keptAnswer
        /// Something else was copied after Otto's write, so the clipboard was left alone.
        case changedMeanwhile
        /// Too large to keep (over 64 MB or file promises): the answer replaced it.
        case tooLargeToKeep
        /// It held a password manager's item: cleared instead of put back.
        case clearedConcealed
    }

    enum CopyReason: Equatable {
        case noAccessibility, userChoseCopy, targetGone, couldNotActivate, secureInput, pasteNotObserved
    }

    /// verified: nil = couldn't observe.
    case pasted(verified: Bool?, clipboard: Clipboard = .restored)
    case copiedOnly(CopyReason)
    /// Another paste was still running; nothing was done.
    case busy
}

@MainActor protocol InsertEnvironment {
    var isAccessibilityTrusted: Bool { get }
    func frontmostPID() -> pid_t?
    func isRunning(_ app: AppRef) -> Bool
    /// NSApp.activate(); NSApp.yieldActivation(to:); app.activate(from: .current, options: []);
    /// falls back to app.activate(options: []). Returns immediately; caller polls frontmostPID.
    func requestActivation(of app: AppRef)
    /// BrowserContext.isSupportedBrowser || Electron Framework.framework in bundle.
    func isChromiumOrElectron(_ app: AppRef) -> Bool
    func focusedElementIsSecure(in app: AppRef) async -> Bool
    func focusedValueFingerprint(in app: AppRef) async -> ValueFingerprint?
    func selectionState(of snapshot: SelectionSnapshot) async -> SelectionState
    func restoreSelection(_ snapshot: SelectionSnapshot) async -> Bool
    /// Tests: instant.
    func sleep(for duration: Duration) async
}

/// The real system. Accessibility trust comes from `PermissionProviding` (the app's one PermissionsCenter);
/// Accessibility reads go through `SelectionReader` on its serial queue.
@MainActor final class LiveInsertEnvironment: InsertEnvironment {
    private let permissions: PermissionProviding

    init(permissions: PermissionProviding) {
        self.permissions = permissions
    }

    var isAccessibilityTrusted: Bool { permissions.status(.accessibility) == .granted }

    func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func isRunning(_ app: AppRef) -> Bool { app.isRunning }

    func requestActivation(of app: AppRef) {
        guard let running = app.runningApplication else { return }
        NSApp.activate()
        NSApp.yieldActivation(to: running)
        if !running.activate(from: NSRunningApplication.current, options: []) {
            _ = running.activate(options: [])
        }
    }

    func isChromiumOrElectron(_ app: AppRef) -> Bool {
        BrowserContext.isSupportedBrowser(bundleID: app.bundleID) || SelectionReader.isElectron(app)
    }

    func focusedElementIsSecure(in app: AppRef) async -> Bool {
        await SelectionReader.focusedElementIsSecure(in: app)
    }

    func focusedValueFingerprint(in app: AppRef) async -> ValueFingerprint? {
        await SelectionReader.focusedValueFingerprint(in: app)
    }

    func selectionState(of snapshot: SelectionSnapshot) async -> SelectionState {
        await SelectionReader.state(of: snapshot)
    }

    func restoreSelection(_ snapshot: SelectionSnapshot) async -> Bool {
        await SelectionReader.restoreSelection(snapshot)
    }

    func sleep(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

@MainActor final class AnswerInserter {
    enum Timing {
        static let activationTimeout: Duration = .milliseconds(700)
        static let activationPoll: Duration = .milliseconds(15)
        static let modifierTimeout: Duration = .milliseconds(600)
        static let modifierPoll: Duration = .milliseconds(10)
        static let settle: Duration = .milliseconds(60)
    }

    let pasteboard: NSPasteboard
    let keys: KeySending
    let environment: InsertEnvironment
    private(set) var isInserting = false

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Context")

    init(pasteboard: NSPasteboard = .general,
         keys: KeySending = CGKeySender(),
         environment: InsertEnvironment) {
        self.pasteboard = pasteboard
        self.keys = keys
        self.environment = environment
    }

    func preflight(_ request: InsertRequest) async -> InsertPreflight {
        let target = request.target
        guard environment.isRunning(target.app) else { return .targetGone }
        guard environment.isAccessibilityTrusted else { return .needsAccessibility }
        let category = Self.category(of: target.app)
        let payload = InsertPolicy.payload(for: request.markdown, category: category, mode: request.mode)
        if !request.confirmedMultiline, InsertPolicy.needsMultilineConfirmation(payload, category: category) {
            return .confirmMultiline(lines: payload.lineCount)
        }
        if request.mode == .replaceSelection, !request.allowPasteAtCursor,
           let selection = target.selection, selection.element != nil,
           await environment.selectionState(of: selection) == .changed {
            return .selectionChanged
        }
        return .ready
    }

    /// `relinquishFocus` closes the notch and returns once the panel is no longer key (≤ 200 ms).
    func perform(_ request: InsertRequest, relinquishFocus: @MainActor () async -> Void) async -> InsertOutcome {
        guard !isInserting else { return .busy }
        isInserting = true
        defer { isInserting = false }

        let target = request.target
        let app = target.app
        let category = Self.category(of: app)
        let payload = InsertPolicy.payload(for: request.markdown, category: category, mode: request.mode)

        // 1–2.
        guard environment.isRunning(app) else {
            ClipboardMarkers.write(payload, to: pasteboard, transient: false)
            return log(.copiedOnly(.targetGone))
        }
        guard environment.isAccessibilityTrusted else {
            ClipboardMarkers.write(payload, to: pasteboard, transient: false)
            return log(.copiedOnly(.noAccessibility))
        }

        // 3–4.
        let previous = request.restoreClipboard ? PasteboardSnapshot.capture(pasteboard) : nil
        let written = ClipboardMarkers.write(payload, to: pasteboard, transient: request.restoreClipboard)

        // 5.
        await relinquishFocus()

        // 6.
        if environment.frontmostPID() != app.pid {
            environment.requestActivation(of: app)
            guard await waitUntil(timeout: Timing.activationTimeout, every: Timing.activationPoll,
                                  { self.environment.frontmostPID() == app.pid }) else {
                return copyFallback(payload, .couldNotActivate)
            }
        }

        // 7.
        if request.mode == .replaceSelection, let selection = target.selection, selection.element != nil,
           await environment.selectionState(of: selection) == .restorable {
            _ = await environment.restoreSelection(selection)
        }

        // 8.
        _ = await waitUntil(timeout: Timing.modifierTimeout, every: Timing.modifierPoll) { !self.keys.areModifiersDown() }
        await environment.sleep(for: Timing.settle)

        // 9.
        if keys.isSecureInputEnabled {
            return copyFallback(payload, .secureInput)
        }
        if await environment.focusedElementIsSecure(in: app) {
            return copyFallback(payload, .secureInput)
        }

        // 10. The target must still be frontmost right before ⌘V (another app may have come forward).
        let before = await environment.focusedValueFingerprint(in: app)
        guard environment.frontmostPID() == app.pid else {
            return copyFallback(payload, .couldNotActivate)
        }
        do {
            try keys.postPaste()
        } catch {
            Self.logger.error("Couldn't create the ⌘V events")
            return copyFallback(payload, .pasteNotObserved)
        }

        // 11.
        let isChromium = environment.isChromiumOrElectron(app)
        let verifyDelay = InsertPolicy.verifyDelay(isChromiumOrElectron: isChromium)
        await environment.sleep(for: verifyDelay)
        let after = await environment.focusedValueFingerprint(in: app)
        let verified: Bool? = if let before, let after { before != after } else { nil }

        // 12.
        if verified == false {
            return copyFallback(payload, .pasteNotObserved)
        }

        // 13.
        let clipboard: InsertOutcome.Clipboard
        switch previous {
        case nil:
            clipboard = .keptAnswer
        case .unrestorable:
            clipboard = .tooLargeToKeep
        case .captured(let snapshot):
            await environment.sleep(for: InsertPolicy.restoreDelay(isChromiumOrElectron: isChromium) - verifyDelay)
            if pasteboard.changeCount == written {
                snapshot.restore(to: pasteboard)
                clipboard = .restored
            } else {
                clipboard = .changedMeanwhile
            }
        case .concealed:
            // Restoring would defeat the password manager's own auto-clear, which only fires while its write is
            // still the latest; clear once the target has read the paste.
            await environment.sleep(for: InsertPolicy.restoreDelay(isChromiumOrElectron: isChromium) - verifyDelay)
            if pasteboard.changeCount == written {
                pasteboard.clearContents()
                clipboard = .clearedConcealed
            } else {
                clipboard = .changedMeanwhile
            }
        }

        // 14.
        return log(.pasted(verified: verified, clipboard: clipboard))
    }

    /// "Just Copy"/"Copy" path: unmarked write of the plain+rich payload.
    func copy(_ markdown: String, category: TargetCategory) {
        let payload = InsertPolicy.payload(for: markdown, category: category, mode: .paste)
        ClipboardMarkers.write(payload, to: pasteboard, transient: false)
    }

    static func category(of app: AppRef) -> TargetCategory {
        TargetCategory.of(bundleID: app.bundleID, appName: app.name)
    }

    // MARK: Private

    /// Re-writes the answer unmarked (so ⌘V by hand works and clipboard history keeps it); never restores.
    private func copyFallback(_ payload: PastePayload, _ reason: InsertOutcome.CopyReason) -> InsertOutcome {
        ClipboardMarkers.write(payload, to: pasteboard, transient: false)
        return log(.copiedOnly(reason))
    }

    /// Polls `condition` (checked first, then after each `interval`) for at most `timeout`.
    private func waitUntil(timeout: Duration, every interval: Duration,
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let attempts = max(Int(timeout / interval), 1)
        for _ in 0..<attempts {
            if condition() { return true }
            await environment.sleep(for: interval)
        }
        return condition()
    }

    private func log(_ outcome: InsertOutcome) -> InsertOutcome {
        Self.logger.info("Insert finished: \(String(describing: outcome), privacy: .public)")
        return outcome
    }
}
