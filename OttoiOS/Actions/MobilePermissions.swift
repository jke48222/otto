//
//  MobilePermissions.swift
//  Otto
//
//  The iPhone's `PermissionProviding`: what iOS has granted Otto (Calendars, Reminders, the microphone, speech
//  recognition, notifications) and iOS's own prompts. iOS asks once; after a "no" the only way back is the
//  Settings app, which `openSystemSettings` opens at Otto's page. The Mac-only permissions (Accessibility, Screen
//  Recording, Automation) read as unavailable.
//

import AVFAudio
import EventKit
import Foundation
import Observation
import Speech
import UIKit
import UserNotifications
import os

/// The system behind `MobilePermissions`, so tests never touch TCC.
@MainActor protocol MobilePermissionProbing: AnyObject {
    func status(_ permission: Permission) -> PermissionStatus
    /// Shows iOS's prompt (only ever shown once per permission) and returns the status after it.
    func request(_ permission: Permission) async -> PermissionStatus
    /// Opens Otto's page in the Settings app.
    func openAppSettings()
}

@MainActor @Observable final class MobilePermissions: PermissionProviding {
    /// Non-nil while iOS's prompt is up, or while Otto waits for a switch in the Settings app.
    private(set) var awaiting: PermissionWait?

    var isAwaitingUser: Bool { awaiting != nil }

    /// How long a status stays cached.
    static let cacheLifetime: TimeInterval = 2
    /// How often `waitForGrant` looks again.
    static let pollInterval: Duration = .milliseconds(500)

    @ObservationIgnored private let probe: MobilePermissionProbing
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var cache: [Permission: (status: PermissionStatus, at: Date)] = [:]

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Permissions")

    init(probe: MobilePermissionProbing, now: @escaping () -> Date = Date.init) {
        self.probe = probe
        self.now = now
    }

    func status(_ permission: Permission) -> PermissionStatus {
        if let cached = cache[permission], now().timeIntervalSince(cached.at) < Self.cacheLifetime {
            return cached.status
        }
        return store(probe.status(permission), for: permission)
    }

    func refresh(_ permissions: [Permission]) async {
        for permission in permissions {
            store(probe.status(permission), for: permission)
        }
    }

    @discardableResult func request(_ permission: Permission) async -> PermissionStatus {
        let current = store(probe.status(permission), for: permission)
        // iOS shows its prompt only once; anything else needs the Settings app.
        guard current == .notDetermined else { return current }
        awaiting = .systemPrompt(permission)
        let status = await probe.request(permission)
        awaiting = nil
        store(status, for: permission)
        Self.logger.info("\(permission.displayName, privacy: .public) after the prompt: \(String(describing: status), privacy: .public)")
        if status == .granted {
            PermissionEvents.post(permission)
        }
        return status
    }

    func openSystemSettings(for permission: Permission) {
        awaiting = .systemSettings(permission)
        probe.openAppSettings()
    }

    func waitForGrant(_ permission: Permission, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        defer { awaiting = nil }
        while clock.now < deadline {
            if Task.isCancelled { return false }
            if store(probe.status(permission), for: permission) == .granted {
                PermissionEvents.post(permission)
                return true
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return false
    }

    func grantedPermissions() -> [Permission] {
        Permission.systemWide.filter { status($0) == .granted }
    }

    @discardableResult private func store(_ status: PermissionStatus, for permission: Permission) -> PermissionStatus {
        cache[permission] = (status, now())
        return status
    }

    // MARK: - Mapping

    static func status(fromEventKit status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .fullAccess: return .granted
        case .writeOnly: return .limited
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    static func status(fromRecord permission: AVAudioApplication.recordPermission) -> PermissionStatus {
        switch permission {
        case .granted: return .granted
        case .undetermined: return .notDetermined
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    static func status(fromSpeech status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    static func status(fromNotifications status: UNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized, .provisional, .ephemeral: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        @unknown default: return .denied
        }
    }
}

/// The real system: EventKit, AVAudioApplication, Speech and UserNotifications.
@MainActor final class MobilePermissionProbe: MobilePermissionProbing {
    /// Notifications can only be read asynchronously; this is the last answer.
    private var notificationStatus: PermissionStatus = .notDetermined

    nonisolated init() {}

    func status(_ permission: Permission) -> PermissionStatus {
        switch permission {
        case .calendars:
            return MobilePermissions.status(fromEventKit: EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return MobilePermissions.status(fromEventKit: EKEventStore.authorizationStatus(for: .reminder))
        case .microphone:
            return MobilePermissions.status(fromRecord: AVAudioApplication.shared.recordPermission)
        case .speechRecognition:
            return MobilePermissions.status(fromSpeech: SFSpeechRecognizer.authorizationStatus())
        case .notifications:
            Task { [weak self] in
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                self?.notificationStatus = MobilePermissions.status(fromNotifications: settings.authorizationStatus)
            }
            return notificationStatus
        case .accessibility, .screenRecording, .automation:
            return .unavailable
        }
    }

    func request(_ permission: Permission) async -> PermissionStatus {
        switch permission {
        case .calendars:
            _ = try? await EKEventStore().requestFullAccessToEvents()
        case .reminders:
            _ = try? await EKEventStore().requestFullAccessToReminders()
        case .microphone:
            _ = await AVAudioApplication.requestRecordPermission()
        case .speechRecognition:
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        case .notifications:
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]))
                ?? false
            notificationStatus = granted ? .granted : .denied
            return notificationStatus
        case .accessibility, .screenRecording, .automation:
            return .unavailable
        }
        return status(permission)
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Fixed answers (tests, snapshots, inert graphs). A prompt answers with `promptAnswer`.
@MainActor final class StaticPermissionProbe: MobilePermissionProbing {
    var statuses: [Permission: PermissionStatus]
    var promptAnswer: PermissionStatus
    private(set) var prompted: [Permission] = []
    private(set) var openedSettings = 0

    nonisolated init(statuses: [Permission: PermissionStatus] = [.calendars: .granted, .reminders: .granted],
                     promptAnswer: PermissionStatus = .granted) {
        self.statuses = statuses
        self.promptAnswer = promptAnswer
    }

    func status(_ permission: Permission) -> PermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    func request(_ permission: Permission) async -> PermissionStatus {
        prompted.append(permission)
        statuses[permission] = promptAnswer
        return promptAnswer
    }

    func openAppSettings() {
        openedSettings += 1
    }
}
