//
//  SystemPermissionProbe.swift
//  Otto
//
//  The probes behind PermissionsCenter: the live one that reads and requests each permission through its
//  own framework, a fixed one for inert graphs, and a changeable one for tests and self-test.
//

import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import EventKit
import Foundation
import os
import Speech
import UserNotifications

/// The real APIs. Status reads never prompt. Apple event checks run off the main thread because
/// AEDeterminePermissionToAutomateTarget blocks, for as long as its consent dialog is up when it asks.
struct SystemPermissionProbe: PermissionProbe {
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Permissions")

    init() {}

    func status(of permission: Permission) async -> PermissionStatus {
        switch permission {
        case .accessibility:
            // "Not trusted" can't tell never-asked from denied; the center applies its prompted-once flag.
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .microphone:
            return Self.status(fromCapture: AVCaptureDevice.authorizationStatus(for: .audio))
        case .speechRecognition:
            return Self.status(fromSpeech: SFSpeechRecognizer.authorizationStatus())
        case .calendars:
            return PermissionsCenter.status(fromEventKit: EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return PermissionsCenter.status(fromEventKit: EKEventStore.authorizationStatus(for: .reminder))
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return Self.status(fromNotifications: settings.authorizationStatus)
        case .automation(let bundleID, _):
            return await Self.automationStatus(bundleID: bundleID, askUserIfNeeded: false)
        }
    }

    func request(_ permission: Permission) async -> PermissionStatus {
        switch permission {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .granted : .notDetermined
        case .screenRecording:
            return CGRequestScreenCaptureAccess() ? .granted : .notDetermined
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            return Self.status(fromCapture: AVCaptureDevice.authorizationStatus(for: .audio))
        case .speechRecognition:
            // The callback arrives on an arbitrary queue; resuming hands the result back to the caller's actor.
            let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            return Self.status(fromSpeech: status)
        case .calendars:
            do {
                _ = try await EKEventStore().requestFullAccessToEvents()
            } catch {
                Self.logger.error("Calendar access request failed: \(String(describing: error), privacy: .public)")
            }
            return PermissionsCenter.status(fromEventKit: EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            do {
                _ = try await EKEventStore().requestFullAccessToReminders()
            } catch {
                Self.logger.error("Reminders access request failed: \(String(describing: error), privacy: .public)")
            }
            return PermissionsCenter.status(fromEventKit: EKEventStore.authorizationStatus(for: .reminder))
        case .notifications:
            let center = UNUserNotificationCenter.current()
            do {
                _ = try await center.requestAuthorization(options: [.alert])
            } catch {
                Self.logger.error("Notification authorization failed: \(String(describing: error), privacy: .public)")
            }
            return Self.status(fromNotifications: await center.notificationSettings().authorizationStatus)
        case .automation(let bundleID, _):
            return await Self.automationStatus(bundleID: bundleID, askUserIfNeeded: true)
        }
    }

    // MARK: - Mapping

    private static func status(fromCapture status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unavailable
        }
    }

    private static func status(fromSpeech status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unavailable
        }
    }

    private static func status(fromNotifications status: UNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized, .provisional: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        @unknown default: return .unavailable
        }
    }

    // MARK: - Apple events

    /// Runs on a detached task: with askUserIfNeeded the call blocks until the consent dialog closes. A target that
    /// isn't running answers procNotFound (→ .unavailable); its first real Apple event will prompt instead.
    private static func automationStatus(bundleID: String, askUserIfNeeded: Bool) async -> PermissionStatus {
        let result = await Task.detached(priority: .userInitiated) { () -> OSStatus in
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            return withExtendedLifetime(target) {
                guard let address = target.aeDesc else { return OSStatus(procNotFound) }
                return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, askUserIfNeeded)
            }
        }.value
        if result != OSStatus(noErr) {
            logger.debug("Automation check for \(bundleID, privacy: .public) returned \(result, privacy: .public)")
        }
        return PermissionsCenter.status(fromAppleEventResult: result)
    }
}

/// Fixed answers: the inert graphs (tests, snapshots, promo). `request` returns the same status and never prompts.
struct StaticPermissionProbe: PermissionProbe {
    private let statuses: [Permission: PermissionStatus]
    private let defaultStatus: PermissionStatus

    init(_ statuses: [Permission: PermissionStatus], default defaultStatus: PermissionStatus) {
        self.statuses = statuses
        self.defaultStatus = defaultStatus
    }

    func status(of permission: Permission) async -> PermissionStatus {
        statuses[permission] ?? defaultStatus
    }

    func request(_ permission: Permission) async -> PermissionStatus {
        statuses[permission] ?? defaultStatus
    }
}

/// Tests / SelfTest: statuses change while a flow runs (grant arrives during `.waiting`). `request` returns the
/// current status without changing it; call `set` to play the user's answer.
final class MutablePermissionProbe: PermissionProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Permission: PermissionStatus]
    private let defaultStatus: PermissionStatus

    init(_ statuses: [Permission: PermissionStatus], default defaultStatus: PermissionStatus) {
        self.statuses = statuses
        self.defaultStatus = defaultStatus
    }

    func set(_ permission: Permission, _ status: PermissionStatus) {
        lock.withLock { statuses[permission] = status }
    }

    func status(of permission: Permission) async -> PermissionStatus {
        current(permission)
    }

    func request(_ permission: Permission) async -> PermissionStatus {
        current(permission)
    }

    private func current(_ permission: Permission) -> PermissionStatus {
        lock.withLock { statuses[permission] ?? defaultStatus }
    }
}
