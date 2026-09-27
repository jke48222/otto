//
//  AttentionMonitor.swift
//  Otto
//
//  Whether the person can see the notch right now: screen lock, display sleep, the pointer on another
//  display, a full-screen app over the notch's display, and how long the Mac has been idle. Feeds the
//  notification decider and the lock-screen rule (notifications never carry text while locked).
//

import AppKit
import CoreGraphics
import Foundation
import os

/// glance.md §1.4.
struct AttentionSnapshot: Equatable, Sendable {
    /// Idle time after which the person counts as away from the Mac.
    static let awayAfter: TimeInterval = 60

    var isScreenLocked: Bool = false
    var areDisplaysAsleep: Bool = false
    var isPointerOnOtherDisplay: Bool = false
    var isFullScreenAppOnNotchDisplay: Bool = false
    /// Seconds since the last keyboard, mouse or trackpad input.
    var idleSeconds: TimeInterval = 0

    var canSeeNotch: Bool {
        !(isScreenLocked || areDisplaysAsleep || isPointerOnOtherDisplay
          || isFullScreenAppOnNotchDisplay || idleSeconds >= Self.awayAfter)
    }
}

@MainActor final class AttentionMonitor {
    /// The screen the notch is on (the window controller's `notchScreen`, wired at composition).
    var notchScreen: () -> NSScreen?

    private var isScreenLocked = false
    private var areDisplaysAsleep = false
    private var isStarted = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    private let workspaceCenter: NotificationCenter
    private let distributedCenter: NotificationCenter
    private let idleSeconds: () -> TimeInterval
    private let initialLockState: () -> Bool
    private let initialDisplaysAsleep: () -> Bool
    private let pointerProbe: @MainActor (NSScreen?) -> Bool
    private let fullScreenProbe: @MainActor (NSScreen?) -> Bool

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Glance")

    // Posted by loginwindow (distributed notifications).
    static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    /// The defaults read the live system; tests pass their own centers and probes.
    /// `notchScreen` nil → the screen with a camera housing, else the main screen (until composition
    /// wires the window controller's own `notchScreen`).
    init(notchScreen: (() -> NSScreen?)? = nil,
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
         idleSeconds: @escaping () -> TimeInterval = AttentionMonitor.systemIdleSeconds,
         initialLockState: @escaping () -> Bool = AttentionMonitor.sessionIsLocked,
         initialDisplaysAsleep: @escaping () -> Bool = AttentionMonitor.mainDisplayIsAsleep,
         pointerOnOtherDisplay: @escaping @MainActor (NSScreen?) -> Bool = AttentionMonitor.pointerIsOnOtherDisplay(notchScreen:),
         fullScreenAppOnDisplay: @escaping @MainActor (NSScreen?) -> Bool = AttentionMonitor.fullScreenAppOwnsDisplay(notchScreen:)) {
        self.notchScreen = notchScreen ?? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main }
        self.workspaceCenter = workspaceCenter
        self.distributedCenter = distributedCenter
        self.idleSeconds = idleSeconds
        self.initialLockState = initialLockState
        self.initialDisplaysAsleep = initialDisplaysAsleep
        pointerProbe = pointerOnOtherDisplay
        fullScreenProbe = fullScreenAppOnDisplay
    }

    /// Reads the current lock and display state, then follows changes. Idempotent.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        isScreenLocked = initialLockState()
        areDisplaysAsleep = initialDisplaysAsleep()

        observe(distributedCenter, Self.screenLockedNotification) { $0.isScreenLocked = true }
        observe(distributedCenter, Self.screenUnlockedNotification) { $0.isScreenLocked = false }
        observe(workspaceCenter, NSWorkspace.screensDidSleepNotification) { $0.areDisplaysAsleep = true }
        observe(workspaceCenter, NSWorkspace.screensDidWakeNotification) { $0.areDisplaysAsleep = false }
        // Fast user switching away counts as locked: nobody at this session can see the notch.
        observe(workspaceCenter, NSWorkspace.sessionDidResignActiveNotification) { $0.isScreenLocked = true }
        observe(workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification) { monitor in
            monitor.isScreenLocked = monitor.initialLockState()
        }
        Self.logger.debug("Attention monitor started (locked: \(self.isScreenLocked, privacy: .public))")
    }

    func snapshot() -> AttentionSnapshot {
        let screen = notchScreen()
        return AttentionSnapshot(isScreenLocked: isScreenLocked, areDisplaysAsleep: areDisplaysAsleep,
                                 isPointerOnOtherDisplay: pointerProbe(screen),
                                 isFullScreenAppOnNotchDisplay: fullScreenProbe(screen),
                                 idleSeconds: idleSeconds())
    }

    deinit {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
    }

    // MARK: - System probes

    /// Seconds since the last HID input of any kind (0 when the "any event" type can't be formed).
    nonisolated static func systemIdleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: UInt32.max) else { return 0 }
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    /// The login session's lock flag (for a launch while the screen is already locked).
    nonisolated static func sessionIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    nonisolated static func mainDisplayIsAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// With more than one screen: the screen under the pointer is not the notch's screen.
    static func pointerIsOnOtherDisplay(notchScreen: NSScreen?) -> Bool {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return false }
        let location = NSEvent.mouseLocation
        let pointerScreen = screens.first { NotchHitTest.contains($0.frame, location) }
        return pointerScreen != notchScreen
    }

    /// The frontmost app has an on-screen, layer-0 window exactly covering the notch's screen. Reads only
    /// bounds, layer and owner pid (available without Screen Recording); never window names.
    static func fullScreenAppOwnsDisplay(notchScreen: NSScreen?) -> Bool {
        guard let notchScreen,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let displayBounds = cgBounds(of: notchScreen),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        return windowsCoverDisplay(list, ownerPID: pid, displayBounds: displayBounds)
    }

    /// Pure core of `fullScreenAppOwnsDisplay`: a layer-0 window owned by `ownerPID` whose bounds equal
    /// `displayBounds` (CG global coordinates: origin at the primary display's top-left, y down).
    nonisolated static func windowsCoverDisplay(_ windows: [[String: Any]], ownerPID: pid_t,
                                                displayBounds: CGRect) -> Bool {
        windows.contains { window in
            guard let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner == ownerPID,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { return false }
            return bounds.size == displayBounds.size && bounds.origin == displayBounds.origin
        }
    }

    // MARK: - Private

    /// The screen's rect in CG global space (origin at the primary display's top-left, y down).
    private static func cgBounds(of screen: NSScreen) -> CGRect? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        }
        guard let primary = NSScreen.screens.first else { return nil }
        let frame = screen.frame
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ apply: @escaping @MainActor (AttentionMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                apply(self)
            }
        }
        observers.append((center, token))
    }
}
