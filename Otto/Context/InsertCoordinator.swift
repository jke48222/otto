//
//  InsertCoordinator.swift
//  Otto
//
//  The paste-an-answer state the notch shows: which app each question came from (keyed by the user
//  message, so Retry keeps it), whether a paste is running or waiting for confirmation, and the brief
//  ✓ the closed notch flashes after a paste. Wraps AnswerInserter and InsertPolicy for the view model.
//

import Foundation
import Observation
import os

enum InsertActivity: Equatable, Sendable {
    case inserting(messageID: UUID)
    case confirmMultiline(messageID: UUID, mode: InsertMode, lines: Int, appName: String)
    case selectionChanged(messageID: UUID, appName: String)
}

@MainActor @Observable final class InsertCoordinator {
    /// How long the closed notch shows the ✓ after a paste.
    static let flashLifetime: Duration = .milliseconds(1400)

    private(set) var targets: [UUID: InsertTarget]          // keyed by USER message id
    private(set) var activity: InsertActivity?
    private(set) var closedFlash: ClosedFlash?              // auto-clears after 1.4 s

    @ObservationIgnored let inserter: AnswerInserter
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var flashTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Context")

    init(inserter: AnswerInserter, settings: AppSettings) {
        self.inserter = inserter
        self.settings = settings
        targets = [:]
        activity = nil
        closedFlash = nil
    }

    func recordTarget(userMessageID: UUID, target: InsertTarget) {
        targets[userMessageID] = target
    }

    /// The target of the user message this answer replies to; nil when there is none or the app quit.
    func target(forAssistant id: UUID, in messages: [ChatMessage]) -> InsertTarget? {
        guard let target = recordedTarget(forAssistant: id, in: messages),
              inserter.environment.isRunning(target.app) else { return nil }
        return target
    }

    /// `.replaceSelection` when the question carried a selection, else `.paste`.
    func preferredMode(forAssistant id: UUID, in messages: [ChatMessage]) -> InsertMode {
        recordedTarget(forAssistant: id, in: messages)?.selection != nil ? .replaceSelection : .paste
    }

    func preflight(markdown: String, target: InsertTarget, mode: InsertMode) async -> InsertPreflight {
        await inserter.preflight(request(markdown: markdown, target: target, mode: mode, confirmed: false))
    }

    /// `confirmed` covers both confirmations (a multi-line terminal paste, pasting at the cursor after the
    /// selection changed). A paste already running returns `.busy`.
    func perform(markdown: String, target: InsertTarget, mode: InsertMode, messageID: UUID,
                 confirmed: Bool, relinquishFocus: @MainActor () async -> Void) async -> InsertOutcome {
        if case .inserting = activity { return .busy }
        activity = .inserting(messageID: messageID)
        let outcome = await inserter.perform(
            request(markdown: markdown, target: target, mode: mode, confirmed: confirmed),
            relinquishFocus: relinquishFocus
        )
        if activity == .inserting(messageID: messageID) { activity = nil }
        if case .pasted = outcome { flash(.pasted(appName: target.app.name)) }
        return outcome
    }

    func setConfirmation(_ activity: InsertActivity?) {
        self.activity = activity
    }

    /// Unmarked clipboard write (the user keeps it in their clipboard history).
    func copyOnly(markdown: String, target: InsertTarget?) {
        let category = target.map { AnswerInserter.category(of: $0.app) } ?? .standard
        inserter.copy(markdown, category: category)
    }

    /// New chat.
    func reset() {
        targets = [:]
        activity = nil
    }

    // MARK: Private

    private func recordedTarget(forAssistant id: UUID, in messages: [ChatMessage]) -> InsertTarget? {
        guard let index = messages.firstIndex(where: { $0.id == id && $0.role == .assistant }) else { return nil }
        guard let question = messages[..<index].last(where: { $0.role == .user }) else { return nil }
        return targets[question.id]
    }

    private func request(markdown: String, target: InsertTarget, mode: InsertMode, confirmed: Bool) -> InsertRequest {
        InsertRequest(markdown: markdown, target: target, mode: mode,
                      restoreClipboard: settings.context.restoreClipboard,
                      confirmedMultiline: confirmed, allowPasteAtCursor: confirmed)
    }

    private func flash(_ flash: ClosedFlash) {
        flashTask?.cancel()
        closedFlash = flash
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flashLifetime)
            guard !Task.isCancelled, let self else { return }
            self.closedFlash = nil
            self.flashTask = nil
        }
    }
}
