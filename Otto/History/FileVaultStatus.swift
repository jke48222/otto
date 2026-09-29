//
//  FileVaultStatus.swift
//  Otto
//
//  Whether the startup volume is encrypted, for the History settings note. Asks `fdesetup status`
//  (no privileges needed) off the main thread and gives up after 2 seconds.
//

import Foundation
import os

enum FileVaultStatus: Equatable, Sendable {
    case on, off, unknown

    static let timeout: TimeInterval = 2

    /// Runs `/usr/bin/fdesetup status`: "FileVault is On." → `.on`, "FileVault is Off." → `.off`; anything else,
    /// a failure to launch or the timeout → `.unknown`.
    static func current() async -> FileVaultStatus {
        await withCheckedContinuation { continuation in
            let once = FileVaultResumeOnce(continuation)
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
            process.arguments = ["status"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                guard finished.terminationReason == .exit, finished.terminationStatus == 0 else {
                    once.resume(.unknown)
                    return
                }
                once.resume(parse(String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                logger.notice("Couldn't run fdesetup: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
                once.resume(.unknown)
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard !once.hasResumed else { return }
                if process.isRunning { process.terminate() }
                once.resume(.unknown)
            }
        }
    }

    /// Maps `fdesetup status` output. Only the first line counts ("FileVault is On." can be followed by
    /// progress lines while encryption runs).
    static func parse(_ output: String) -> FileVaultStatus {
        let firstLine = output.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        switch firstLine {
        case "FileVault is On.": return .on
        case "FileVault is Off.": return .off
        default: return .unknown
        }
    }

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "History")
}

/// Resumes a continuation exactly once, from whichever of the process exit and the timeout comes first.
private final class FileVaultResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<FileVaultStatus, Never>?

    init(_ continuation: CheckedContinuation<FileVaultStatus, Never>) {
        self.continuation = continuation
    }

    var hasResumed: Bool { lock.withLock { continuation == nil } }

    func resume(_ status: FileVaultStatus) {
        let pending: CheckedContinuation<FileVaultStatus, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: status)
    }
}
