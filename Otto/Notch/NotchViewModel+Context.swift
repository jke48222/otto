//
//  NotchViewModel+Context.swift
//  Otto
//
//  Context in and answers out (§6.8–§6.10): the selection and window chips from the app the user came from,
//  the "+" menu's attach items, the macOS Services entry points, and pasting an answer back into that app with
//  its permission step, confirmations and clipboard fallbacks.
//

import AppKit
import Foundation
import os

extension NotchViewModel: ServicesHandling {
    // MARK: - Services (§6.8, §4.7)

    /// "Ask Otto": opens focused on Chat with a "Selection from ‹App›" chip; Replace can put the answer back over
    /// that selection. Empty text never reaches here (the service reports it); text over the limit is refused.
    func askAbout(serviceText: String, app: AppRef?) async {
        guard serviceText.contains(where: { !$0.isWhitespace && $0 != "\0" }) else { return }
        openForServices(app: app, route: .chat, focus: true)
        let snapshot = await serviceSnapshot(serviceText, app: app)
        attachSelection(snapshot)
        Self.contextLogger.info("Ask Otto attached \(snapshot.wordCount, privacy: .public) words")
    }

    /// "Ask Otto About Files": opens focused on Chat and attaches the files (the picker's limits apply).
    func askAbout(fileURLs: [URL], app: AppRef?) {
        guard !fileURLs.isEmpty else { return }
        openForServices(app: app, route: .chat, focus: true)
        addFiles(fileURLs)
    }

    /// "Add to Otto Shelf": keeps the files on the Shelf; with `openShelf` the notch opens unfocused on the Shelf
    /// page like a Shelf drop, with the new tiles selected.
    func addToShelf(fileURLs: [URL], openShelf: Bool) {
        guard !fileURLs.isEmpty else { return }
        guard settings.shelf.enabled else {
            openForServices(app: nil, route: .chat, focus: true)
            transientError = Self.shelfOffMessage
            return
        }
        let result = shelf.add(fileURLs: fileURLs)
        guard openShelf else { return }
        if !isOpen {
            open(reason: .programmatic, focus: false)
        }
        navigate(to: .shelf)
        shelf.beginLandingHold(selecting: result.added)
    }

    static let shelfOffMessage = "The Shelf is off. Turn it on in Settings → Context."

    /// Services open the notch for the app that asked (nil when Otto itself was frontmost).
    private func openForServices(app: AppRef?, route: NotchRoute, focus: Bool) {
        if isOpen {
            if focus { engage() }
        } else {
            open(reason: .programmatic, focus: focus)
        }
        setOpenContextApp(app)
        navigate(to: route)
    }

    /// Adopts the app's own selection (element and range, for a precise Replace) only when Accessibility is
    /// already allowed; otherwise the text alone.
    private func serviceSnapshot(_ text: String, app: AppRef?) async -> SelectionSnapshot {
        guard let app, !SensitiveApps.contains(app), permissions.status(.accessibility) == .granted else {
            return SelectionSnapshot(text: text, app: app, windowTitle: nil, range: nil, element: nil,
                                     source: .service)
        }
        return await SelectionReader.snapshot(serviceText: text, app: app)
    }

    // MARK: - Selection chip and "+" menu (§6.8)

    /// "Attach Selection from Notes" for the "+" menu (nil without an app to read from).
    var selectionMenuTitle: String? {
        openContextApp.map { "Attach Selection from \($0.name)" }
    }

    /// "Attach Xcode Window" for the "+" menu.
    var windowMenuTitle: String? {
        openContextApp.map { "Attach \($0.name) Window" }
    }

    func acceptSuggestedSelection() {
        do {
            guard let accepted = try suggestions.acceptSelection() else { return }
            attach(accepted.attachment, snapshot: accepted.snapshot)
        } catch {
            transientError = error.localizedDescription
        }
    }

    func dismissSuggestedSelection() {
        suggestions.dismissSelection()
    }

    /// Reads the selection now, whatever "Offer selected text" says; asks for Accessibility first when needed.
    func attachSelectionFromMenu() {
        guard let app = openContextApp else { return }
        guard !SensitiveApps.contains(app) else {
            transientError = Self.passwordManagerSelectionMessage
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard await self.requestPermission(.accessibility, for: .selection(appName: app.name)) else { return }
            guard let snapshot = await self.suggestions.readSelectionNow(from: app) else {
                self.transientError = "Nothing is selected in \(app.name)."
                return
            }
            self.attachSelection(snapshot)
        }
    }

    static let passwordManagerSelectionMessage = "Otto doesn't read selections in password managers."

    /// The chip for `snapshot`, remembered for Replace.
    private func attachSelection(_ snapshot: SelectionSnapshot) {
        do {
            attach(try snapshot.makeAttachment(), snapshot: snapshot)
        } catch {
            transientError = error.localizedDescription
        }
    }

    private func attach(_ attachment: Attachment, snapshot: SelectionSnapshot) {
        if insert(attachment) == .added {
            selectionSnapshots[attachment.id] = snapshot
        }
    }

    // MARK: - Window chip (§6.10)

    func acceptSuggestedWindow() {
        guard let window = suggestions.window else { return }
        captureWindow(of: window.app)
    }

    func dismissSuggestedWindow() {
        suggestions.dismissWindow()
    }

    func attachWindowFromMenu() {
        guard let app = openContextApp else { return }
        captureWindow(of: app)
    }

    /// Screen Recording first (explain → macOS → maybe Quit & Reopen), then one picture of the front window.
    private func captureWindow(of app: AppRef) {
        guard !SensitiveApps.contains(app) else {
            transientError = WindowCaptureError.passwordManager(appName: app.name).localizedDescription
            return
        }
        guard remainingCapacity > 0 else {
            transientError = Self.attachmentLimitMessage
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard await self.requestPermission(.screenRecording, for: .windowCapture(appName: app.name)) else { return }
            do {
                let attachment = try await self.suggestions.captureWindow(of: app)
                self.insert(attachment)
            } catch {
                self.transientError = error.localizedDescription
            }
        }
    }

    // MARK: - Insert (§6.9)

    /// The last reply is complete, its app is still running and no paste is running or waiting.
    var canInsertLastAnswer: Bool {
        lastAnswerIsInsertable && inserter.activity == nil
    }

    func insertTarget(forAssistant id: UUID) -> InsertTarget? {
        inserter.target(forAssistant: id, in: chat.messages)
    }

    /// ⌘↩ (nil: Replace when the question carried a selection, else Paste) and ⌥⌘↩ (`.pastePlain`).
    func insertLastAnswer(mode: InsertMode?) {
        guard let last = chat.messages.last, last.role == .assistant else { return }
        insertAnswer(messageID: last.id, mode: mode ?? inserter.preferredMode(forAssistant: last.id, in: chat.messages))
    }

    /// Preflight, then paste; or the Accessibility card, a confirmation row, or a copy with a notice.
    func insertAnswer(messageID: UUID, mode: InsertMode) {
        guard let message = chat.messages.first(where: { $0.id == messageID }), message.role == .assistant,
              message.state == .complete,
              !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if case .inserting? = inserter.activity { return }
        guard let target = insertTarget(forAssistant: messageID) else {
            copyForGoneTarget(message)
            return
        }
        inserter.setConfirmation(nil)
        Task { [weak self] in
            await self?.runInsert(markdown: message.text, target: target, mode: mode, messageID: messageID,
                                  askedForAccess: false)
        }
    }

    /// [Paste] under a multi-line terminal paste, [Paste at Cursor] after the selection changed.
    func confirmPendingInsert() {
        let pending: (messageID: UUID, mode: InsertMode)
        switch inserter.activity {
        case .confirmMultiline(let messageID, let mode, _, _)?:
            pending = (messageID, mode)
        case .selectionChanged(let messageID, _)?:
            pending = (messageID, .replaceSelection)
        case .inserting?, nil:
            return
        }
        inserter.setConfirmation(nil)
        guard let message = chat.messages.first(where: { $0.id == pending.messageID }),
              let target = insertTarget(forAssistant: pending.messageID) else {
            if let message = chat.messages.first(where: { $0.id == pending.messageID }) {
                copyForGoneTarget(message)
            }
            return
        }
        Task { [weak self] in
            await self?.performInsert(markdown: message.text, target: target, mode: pending.mode,
                                      messageID: pending.messageID, confirmed: true)
        }
    }

    /// Cancel under a multi-line paste; Copy after the selection changed (the answer goes to the clipboard).
    func cancelPendingInsert() {
        switch inserter.activity {
        case .confirmMultiline?:
            inserter.setConfirmation(nil)
        case .selectionChanged(let messageID, let appName)?:
            inserter.setConfirmation(nil)
            guard let message = chat.messages.first(where: { $0.id == messageID }) else { return }
            inserter.copyOnly(markdown: message.text, target: insertTarget(forAssistant: messageID))
            showInsertNotice(Self.copiedNotice(appName: appName))
        case .inserting?, nil:
            break
        }
    }

    private func runInsert(markdown: String, target: InsertTarget, mode: InsertMode, messageID: UUID,
                           askedForAccess: Bool) async {
        let appName = target.app.name
        switch await inserter.preflight(markdown: markdown, target: target, mode: mode) {
        case .ready:
            await performInsert(markdown: markdown, target: target, mode: mode, messageID: messageID, confirmed: false)
        case .needsAccessibility:
            guard !askedForAccess else {
                copyAndStepAside(markdown: markdown, target: target)
                return
            }
            if await requestPermission(.accessibility, for: .paste(appName: appName)) {
                await runInsert(markdown: markdown, target: target, mode: mode, messageID: messageID,
                                askedForAccess: true)
            } else {
                copyAndStepAside(markdown: markdown, target: target)
            }
        case .targetGone:
            inserter.copyOnly(markdown: markdown, target: target)
            showInsertNotice(Self.targetGoneNotice(appName: appName))
        case .confirmMultiline(let lines):
            inserter.setConfirmation(.confirmMultiline(messageID: messageID, mode: mode, lines: lines,
                                                       appName: appName))
        case .selectionChanged:
            inserter.setConfirmation(.selectionChanged(messageID: messageID, appName: appName))
        }
    }

    private func performInsert(markdown: String, target: InsertTarget, mode: InsertMode, messageID: UUID,
                               confirmed: Bool) async {
        let outcome = await inserter.perform(markdown: markdown, target: target, mode: mode, messageID: messageID,
                                             confirmed: confirmed) { [weak self] in
            await self?.relinquishFocusForInsert()
        }
        reportInsert(outcome, appName: target.app.name)
    }

    /// Closes the notch and waits (≤ 200 ms) until the panel is no longer key, so ⌘V reaches the target app.
    private func relinquishFocusForInsert() async {
        close(.programmatic)
        for _ in 0..<Self.relinquishPolls where isPanelKey {
            try? await Task.sleep(for: Self.relinquishPollInterval)
        }
    }

    private static let relinquishPolls = 20
    private static let relinquishPollInterval: Duration = .milliseconds(10)

    /// "Just Copy", or the permission card was dismissed: the answer goes to the clipboard, the notch stays open
    /// and hands the keyboard back so the user can click in the app and paste.
    private func copyAndStepAside(markdown: String, target: InsertTarget) {
        inserter.copyOnly(markdown: markdown, target: target)
        showInsertNotice(Self.copiedNotice(appName: target.app.name))
        disengage()
    }

    /// The question's app quit: copy, and say so.
    private func copyForGoneTarget(_ message: ChatMessage) {
        let app = recordedInsertApp(forAssistant: message.id)
        inserter.copyOnly(markdown: message.text, target: nil)
        if let app {
            showInsertNotice(Self.targetGoneNotice(appName: app.name))
        } else {
            showNotice("Copied the reply")
        }
    }

    /// The app the question was asked from, even when it no longer runs.
    private func recordedInsertApp(forAssistant id: UUID) -> AppRef? {
        guard let index = chat.messages.firstIndex(where: { $0.id == id }),
              let question = chat.messages[..<index].last(where: { $0.role == .user }) else { return nil }
        return inserter.targets[question.id]?.app
    }

    private func reportInsert(_ outcome: InsertOutcome, appName: String) {
        switch outcome {
        case .pasted(_, let clipboard):
            announce("Pasted into \(appName)")
            switch clipboard {
            case .clearedConcealed:
                showInsertNotice(Self.concealedClipboardNotice)
            case .tooLargeToKeep:
                showInsertNotice(Self.clipboardTooLargeNotice)
            case .restored, .keptAnswer, .changedMeanwhile:
                break
            }
        case .copiedOnly(let reason):
            showInsertNotice(Self.copyNotice(for: reason, appName: appName))
        case .busy:
            break
        }
    }

    private func showInsertNotice(_ text: String) {
        showNotice(text, symbol: "info.circle", lifetime: .seconds(4))
    }

    // MARK: - Insert copy (context-io.md §3.1)

    static let concealedClipboardNotice =
        "Your clipboard held a password, so Otto cleared it instead of putting it back."
    static let clipboardTooLargeNotice = "Your previous clipboard was too large to keep, so it's been replaced."

    static func copiedNotice(appName: String) -> String {
        "Copied. Click in \(appName) and press ⌘V."
    }

    static func targetGoneNotice(appName: String) -> String {
        "\(appName) isn't open anymore. The answer is on your clipboard."
    }

    static func copyNotice(for reason: InsertOutcome.CopyReason, appName: String) -> String {
        switch reason {
        case .noAccessibility, .userChoseCopy:
            return copiedNotice(appName: appName)
        case .targetGone:
            return targetGoneNotice(appName: appName)
        case .couldNotActivate:
            return "Couldn't switch to \(appName). The answer is on your clipboard, so press ⌘V there."
        case .secureInput:
            return "A password field is active in \(appName), so Otto won't type there. The answer is on your clipboard."
        case .pasteNotObserved:
            return "If nothing appeared in \(appName), press ⌘V. The answer is on your clipboard."
        }
    }

    static let contextLogger = Logger(subsystem: "com.jalenedusei.otto", category: "Context")
}
