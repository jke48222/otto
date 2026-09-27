//
//  AppRelauncher.swift
//  Otto
//
//  Quits Otto and starts it again only after this process has exited, so the new copy never overlaps the
//  old one's stores or hot key. Screen Recording needs this: macOS applies that grant on the next launch.
//

import AppKit
import Foundation
import os

/// Quits Otto and starts it again only after this process has exited.
@MainActor protocol AppRelaunching { func relaunch() }

/// Flushes nothing itself (NSApp.terminate → applicationWillTerminate → composition.terminate() flushes every store);
/// starts a detached waiter with Foundation `Process` (not ProcessRunner, which kills its process group):
///   /bin/sh -c 'while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done; exec /usr/bin/open "$2"' sh <pid> <bundlePath>
/// then calls NSApp.terminate(nil). `open` without -n: if Otto is already running again it is just activated.
struct AppRelauncher: AppRelaunching {
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Permissions")
    private nonisolated static let waiterScript =
        #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done; exec /usr/bin/open "$2""#

    /// Nonisolated so it can be the default argument of PermissionsCenter.init.
    nonisolated init() {}

    func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = Self.waiterArguments(pid: ProcessInfo.processInfo.processIdentifier, bundlePath: bundlePath)
        waiter.standardInput = FileHandle.nullDevice
        waiter.standardOutput = FileHandle.nullDevice
        waiter.standardError = FileHandle.nullDevice
        do {
            try waiter.run()
        } catch {
            // Without the waiter nothing would reopen Otto, so stay running rather than quit for good.
            Self.logger.error("Could not start the relaunch waiter: \(String(describing: error), privacy: .public)")
            return
        }
        Self.logger.info("Quitting so Otto can reopen (waiter pid \(waiter.processIdentifier, privacy: .public))")
        NSApp.terminate(nil)
    }

    /// Pure, tested: ["-c", "<the script above>", "sh", "\(pid)", bundlePath] for /bin/sh.
    nonisolated static func waiterArguments(pid: pid_t, bundlePath: String) -> [String] {
        ["-c", waiterScript, "sh", "\(pid)", bundlePath]
    }
}
