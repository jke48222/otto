//
//  ScreenCapture.swift
//  Otto
//
//  Interactive region/window capture through the system `screencapture` tool,
//  awaited without blocking the main thread.
//

import AppKit
import Foundation
import os

enum ScreenCaptureError: LocalizedError, Equatable {
    case couldNotStart
    /// Otto lacks Screen Recording permission. `screencapture` would still "succeed" but replace every
    /// other app's windows with the desktop, so no capture is attempted.
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            return "Otto couldn't start a screen capture."
        case .permissionDenied:
            return "Otto needs Screen Recording permission to capture your screen. Turn on Otto in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Otto."
        }
    }
}

enum ScreenCapture {
    private static let executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "ScreenCapture")

    /// Runs `/usr/sbin/screencapture -i -x -t png <tmpfile>` (interactive region/window selection).
    /// Returns nil if the user cancelled (no file). Loads the PNG as an image attachment named
    /// "Screenshot <HH.mm.ss>.png", then deletes the temp file.
    /// Throws `ScreenCaptureError.permissionDenied` (after asking macOS to prompt for access) when Otto
    /// isn't allowed to record the screen — the child process's capture is attributed to Otto.
    static func captureInteractive() async throws -> Attachment? {
        try ensurePermission()

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("OttoCaptures", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger.error("Couldn't create the capture folder: \(error.localizedDescription, privacy: .public)")
            throw ScreenCaptureError.couldNotStart
        }
        let fileURL = directory.appendingPathComponent("capture-\(UUID().uuidString).png")
        defer { try? fileManager.removeItem(at: fileURL) }

        let status: Int32
        do {
            status = try await runScreencapture(writingTo: fileURL)
        } catch is CancellationError {
            return nil
        }
        if Task.isCancelled { return nil }

        // Pressing Esc makes screencapture exit without writing anything; the file is the source of truth.
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard fileSize > 0 else {
            logger.debug("Screen capture ended without an image (exit status \(status))")
            return nil
        }

        let capturedAt = Date()
        var attachment = try await AttachmentLoader.load(fileURL: fileURL)
        attachment.displayName = "Screenshot \(timestamp(for: capturedAt)).png"
        attachment.badge = "PNG"
        // The temporary file is deleted on return.
        attachment.sourceURL = nil
        return attachment
    }

    /// Checks Screen Recording access without prompting; when it is missing, asks macOS to show its prompt
    /// (first time) or register Otto in System Settings, and fails so nothing wallpaper-only is attached.
    private static func ensurePermission() throws {
        guard !CGPreflightScreenCaptureAccess() else { return }
        if CGRequestScreenCaptureAccess() { return }
        logger.info("Screen capture skipped: Screen Recording permission is not granted")
        throw ScreenCaptureError.permissionDenied
    }

    private static func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH.mm.ss"
        return formatter.string(from: date)
    }

    private static func runScreencapture(writingTo fileURL: URL) async throws -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-i", "-x", "-t", "png", fileURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let capture = CaptureProcess(process: process)
        return try await withTaskCancellationHandler {
            try await capture.run()
        } onCancel: {
            capture.cancel()
        }
    }
}

extension ScreenCapture {
    /// Launches a process once and reports its exit status; cancellation terminates it (or prevents the launch).
    private final class CaptureProcess: @unchecked Sendable {
        private let process: Process
        private let lock = NSLock()
        private var isLaunched = false
        private var isCancelled = false
        private let logger = Logger(subsystem: "com.jalenedusei.otto", category: "ScreenCapture")

        init(process: Process) {
            self.process = process
        }

        func run() async throws -> Int32 {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                lock.lock()
                defer { lock.unlock() }
                guard !isCancelled else {
                    process.terminationHandler = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try process.run()
                    isLaunched = true
                } catch {
                    logger.error("Couldn't launch screencapture: \(error.localizedDescription, privacy: .public)")
                    process.terminationHandler = nil
                    continuation.resume(throwing: ScreenCaptureError.couldNotStart)
                }
            }
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            isCancelled = true
            // Terminating a process that was never launched raises an Objective-C exception.
            if isLaunched, process.isRunning {
                process.terminate()
            }
        }
    }
}
