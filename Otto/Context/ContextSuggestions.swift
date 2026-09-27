//
//  ContextSuggestions.swift
//  Otto
//
//  The two ghost chips the open notch can offer from the app you came from: the text you had selected
//  (opt-in, Accessibility) and a picture of its front window (no pixels read until tapped). Reads are
//  generation-checked so a late answer never lands after the notch closed or reopened.
//

import Foundation
import Observation
import os

struct SelectionSuggestion: Equatable, Sendable { let id: UUID; let snapshot: SelectionSnapshot; var label: String }
struct WindowSuggestion: Equatable, Sendable { let id: UUID; let app: AppRef; var label: String }   // "Window: Xcode"

@MainActor @Observable final class ContextSuggestions {
    private(set) var selection: SelectionSuggestion?
    private(set) var window: WindowSuggestion?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let permissions: PermissionProviding
    @ObservationIgnored private let reader: SelectionReading
    @ObservationIgnored private let capture: WindowCapturing
    /// Bumped on every refresh and on clear; a read only lands if it still matches.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var windowTask: Task<Void, Never>?
    /// A dismissed selection (by fingerprint) isn't offered again until the selection changes.
    @ObservationIgnored private var dismissedSelectionFingerprint: String?
    /// A dismissed window chip isn't offered again for that app until the next open.
    @ObservationIgnored private var dismissedWindowPID: pid_t?

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Context")

    init(settings: AppSettings, permissions: PermissionProviding,
         reader: SelectionReading = LiveSelectionReader(), capture: WindowCapturing = LiveWindowCapture()) {
        self.settings = settings
        self.permissions = permissions
        self.reader = reader
        self.capture = capture
        selection = nil
        window = nil
    }

    /// On open (not for .drag): reads the AX selection when settings.context.offerSelection && trusted; offers the
    /// window chip when settings.context.offerWindow, the app isn't a supported browser and has a capturable window.
    func refresh(for app: AppRef?, allowSelection: Bool) {
        cancelReads()
        selection = nil
        window = nil
        guard let app else { return }
        let generation = generation

        if allowSelection, settings.context.offerSelection, permissions.status(.accessibility) == .granted,
           !SensitiveApps.contains(app) {
            selectionTask = Task { [weak self, reader] in
                let snapshot = await reader.read(from: app)
                self?.landSelection(snapshot, generation: generation)
            }
        }

        if settings.context.offerWindow, !BrowserContext.isSupportedBrowser(bundleID: app.bundleID),
           !SensitiveApps.contains(app), dismissedWindowPID != app.pid {
            windowTask = Task { [weak self, capture] in
                let hasWindow = await capture.hasCapturableWindow(app)
                self?.landWindow(hasWindow ? app : nil, generation: generation)
            }
        }
    }

    /// On close (bumps the generation).
    func clear() {
        cancelReads()
        selection = nil
        window = nil
        dismissedWindowPID = nil
    }

    func dismissSelection() {
        guard let selection else { return }
        dismissedSelectionFingerprint = selection.snapshot.fingerprint
        self.selection = nil
    }

    func dismissWindow() {
        guard let window else { return }
        dismissedWindowPID = window.app.pid
        self.window = nil
    }

    /// Attachment for an accepted selection (records its snapshot for Replace). nil when nothing is offered.
    func acceptSelection() throws -> (attachment: Attachment, snapshot: SelectionSnapshot)? {
        guard let selection else { return nil }
        self.selection = nil
        let attachment = try selection.snapshot.makeAttachment()
        return (attachment, selection.snapshot)
    }

    /// "+" menu path: reads now whatever the setting says; nil without Accessibility.
    func readSelectionNow(from app: AppRef) async -> SelectionSnapshot? {
        guard permissions.status(.accessibility) == .granted, !SensitiveApps.contains(app) else { return nil }
        return await reader.read(from: app)
    }

    /// Throws WindowCaptureError: `.permissionNeeded` without Screen Recording, `.passwordManager` for
    /// SensitiveApps; the capture itself re-checks secure input. The picture is never kept in History.
    func captureWindow(of app: AppRef) async throws -> Attachment {
        if SensitiveApps.contains(app) { throw WindowCaptureError.passwordManager(appName: app.name) }
        guard permissions.status(.screenRecording) == .granted else { throw WindowCaptureError.permissionNeeded }
        var attachment = try await capture.capture(app)
        attachment.retainsPayloadInHistory = false
        if window?.app == app { window = nil }
        Self.logger.info("Attached a window capture")
        return attachment
    }

    func hasCapturableWindow(_ app: AppRef) async -> Bool {
        guard !SensitiveApps.contains(app) else { return false }
        return await capture.hasCapturableWindow(app)
    }

    /// Waits for the reads started by the last `refresh` (SelfTest and tests).
    func waitForRefresh() async {
        await selectionTask?.value
        await windowTask?.value
    }

    // MARK: Private

    private func cancelReads() {
        generation += 1
        selectionTask?.cancel()
        windowTask?.cancel()
        selectionTask = nil
        windowTask = nil
    }

    private func landSelection(_ snapshot: SelectionSnapshot?, generation: Int) {
        guard generation == self.generation else { return }
        guard let snapshot else {
            // Nothing selected any more: a later selection of the same text is new again.
            dismissedSelectionFingerprint = nil
            return
        }
        if snapshot.fingerprint == dismissedSelectionFingerprint { return }
        dismissedSelectionFingerprint = nil
        selection = SelectionSuggestion(id: UUID(), snapshot: snapshot, label: snapshot.ghostLabel)
        Self.logger.info("Offered a selection of \(snapshot.wordCount, privacy: .public) words")
    }

    private func landWindow(_ app: AppRef?, generation: Int) {
        guard generation == self.generation, let app, dismissedWindowPID != app.pid else { return }
        window = WindowSuggestion(id: UUID(), app: app, label: "Window: \(app.name)")
    }
}
