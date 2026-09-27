//
//  PermissionContracts.swift
//  Otto
//
//  The macOS permissions Otto can ask for, their statuses, why Otto asks, what it waits on outside its
//  own UI, and the protocol every feature and tool uses instead of calling TCC directly.
//

import Foundation

enum Permission: Hashable, Sendable, Codable {
    case accessibility, screenRecording, microphone, speechRecognition, calendars, reminders, notifications
    case automation(bundleID: String, appName: String)

    static let systemWide: [Permission] = [.accessibility, .screenRecording, .microphone, .speechRecognition,
                                           .calendars, .reminders, .notifications]

    var displayName: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen & System Audio Recording"
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .calendars: return "Calendars"
        case .reminders: return "Reminders"
        case .notifications: return "Notifications"
        case .automation(_, let appName): return "Automation (\(appName))"
        }
    }

    /// The row name in System Settings → Privacy & Security (Notifications has its own pane).
    var settingsPaneName: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen & System Audio Recording"
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .calendars: return "Calendars"
        case .reminders: return "Reminders"
        case .notifications: return "Notifications"
        case .automation: return "Automation"
        }
    }

    /// x-apple.systempreferences deep link to the pane that controls this permission.
    var settingsURL: URL? {
        let privacy = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .accessibility: return URL(string: privacy + "Privacy_Accessibility")
        case .screenRecording: return URL(string: privacy + "Privacy_ScreenCapture")
        case .microphone: return URL(string: privacy + "Privacy_Microphone")
        case .speechRecognition: return URL(string: privacy + "Privacy_SpeechRecognition")
        case .calendars: return URL(string: privacy + "Privacy_Calendars")
        case .reminders: return URL(string: privacy + "Privacy_Reminders")
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.jalenedusei.otto")
        case .automation: return URL(string: privacy + "Privacy_Automation")
        }
    }
}

enum PermissionStatus: Equatable, Sendable {
    case granted
    /// A system prompt can still be shown (Accessibility and Screen Recording: never asked in this install).
    case notDetermined
    /// Off in System Settings, or the user said no.
    case denied
    /// Managed by the organization.
    case restricted
    /// Calendars write-only: not enough for reading.
    case limited
    /// Screen Recording switched on but not effective until Otto reopens (heuristic).
    case needsRelaunch
    /// Automation target not installed or running, or the check failed.
    case unavailable
}

/// Why Otto is asking; selects the card copy.
enum PermissionPurpose: Equatable, Sendable {
    case paste(appName: String)
    case selection(appName: String)
    case windowCapture(appName: String)
    case voice
    case nowPlayingControl(appName: String)
    case notifications
    case calendarGlance
    /// Tool loop: `title` = presentation.title ("Add “Dentist” to Calendar"); `dataFlow` e.g.
    /// "Event details are sent to Claude to answer." (the consent sentence, when the call is a read).
    case tool(title: String, dataFlow: String?)
}

/// A feature (non-tool) permission flow shown in the dock.
struct PermissionPrompt: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable { case explain, waiting, needsRelaunch, granted }
    let id: UUID
    let permission: Permission
    let purpose: PermissionPurpose
    var phase: Phase
}

/// What Otto is waiting on outside its own UI (PermissionsCenter.awaiting).
enum PermissionWait: Equatable, Sendable {
    /// A macOS permission dialog Otto triggered is on screen.
    case systemPrompt(Permission)
    /// Otto opened System Settings and is waiting for the switch (waitForGrant).
    case systemSettings(Permission)
}

/// Why the open notch is folded. Computed by the view model; shown by the closed notch.
enum SystemUIWait: Equatable, Sendable {
    case systemSettings(Permission)
    case systemPrompt(Permission)
    /// A tool call is .waitingForSystem(appName) (Automation consent during a run).
    case toolDialog(appName: String)
    /// A mayPresentUI call has been running ≥ ToolLimits.uiFoldDelay; title = the call's activeTitle.
    case toolRun(title: String)

    /// "Waiting for System Settings…" · "Answer the macOS prompt to continue" ·
    /// "Answer the macOS prompt about ‹App›" · ‹title› ("Running “Resize Images”…").
    var dropText: String {
        switch self {
        case .systemSettings:
            return "Waiting for System Settings…"
        case .systemPrompt:
            return "Answer the macOS prompt to continue"
        case .toolDialog(let appName):
            return "Answer the macOS prompt about \(DisplayText.sanitized(appName, maxLength: 60))"
        case .toolRun(let title):
            return DisplayText.sanitized(title, maxLength: 120)
        }
    }

    /// systemSettings / systemPrompt.
    var isPermission: Bool {
        switch self {
        case .systemSettings, .systemPrompt: return true
        case .toolDialog, .toolRun: return false
        }
    }
}

/// Posted on NotificationCenter.default whenever a permission's status becomes .granted (EventKit stores reset on it).
enum PermissionEvents {
    static let didGrant = Notification.Name("com.jalenedusei.otto.permissionDidGrant")

    private static let permissionKey = "permission"

    static func post(_ permission: Permission, center: NotificationCenter = .default) {
        center.post(name: didGrant, object: nil, userInfo: [permissionKey: permission])
    }

    static func permission(from notification: Notification) -> Permission? {
        guard notification.name == didGrant else { return nil }
        return notification.userInfo?[permissionKey] as? Permission
    }
}

/// What features and tools depend on; PermissionsCenter implements it, tests inject fakes.
@MainActor protocol PermissionProviding: AnyObject {
    /// Cached; refreshes if older than 2 s.
    func status(_ permission: Permission) -> PermissionStatus
    func refresh(_ permissions: [Permission]) async
    /// Shows the system prompt when one can be shown (else opens System Settings). Marks didPrompt flags.
    /// `awaiting == .systemPrompt(p)` for exactly as long as the prompt is up.
    @discardableResult func request(_ permission: Permission) async -> PermissionStatus
    /// awaiting = .systemSettings(p) until the wait ends.
    func openSystemSettings(for permission: Permission)
    /// Polls every `pollInterval` (and on didBecomeActive) until granted, timeout or cancellation; clears `awaiting`.
    func waitForGrant(_ permission: Permission, timeout: Duration) async -> Bool
    /// Non-nil while Otto waits on system UI it opened (the view model folds the notch).
    var awaiting: PermissionWait? { get }
    /// awaiting != nil.
    var isAwaitingUser: Bool { get }
    /// System-wide permissions and known automation targets currently .granted (AppleScript cards).
    func grantedPermissions() -> [Permission]
}
