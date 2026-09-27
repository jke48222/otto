//
//  SettingsFeatureToggles.swift
//  Otto
//
//  Every on/off feature switch in Settings, where it is stored, and which permissions turning it on asks for.
//  Only the rows whose purpose is the permission itself ask macOS anything (the Calendar chip, selected text,
//  Voice, and a notification policy other than Never); every other switch just stores its value, and its
//  permission is explained in the notch at the moment of need.
//

import Foundation

enum SettingsFeatureToggle: Hashable {
    case hoverToOpen, typeAfterHover
    case replyPreviews, notificationPreview
    case nowPlaying, nowPlayingInClosedNotch
    case calendarChip
    case suggestBrowserTab, autoAttachBrowserTab
    case offerSelection, offerWindow, restoreClipboard
    case shelf, keepShelfItemsAfterDragOut
    case webAccess, showCost
    case actions, toolGroup(ToolGroup), logFullScripts
    case voice, holdToTalk, autoSend, serverRecognition
    case menuBarIcon

    static var allCases: [SettingsFeatureToggle] {
        [.hoverToOpen, .typeAfterHover, .replyPreviews, .notificationPreview, .nowPlaying, .nowPlayingInClosedNotch,
         .calendarChip, .suggestBrowserTab, .autoAttachBrowserTab, .offerSelection, .offerWindow, .restoreClipboard,
         .shelf, .keepShelfItemsAfterDragOut, .webAccess, .showCost, .actions]
            + ToolGroup.allCases.map { SettingsFeatureToggle.toolGroup($0) }
            + [.logFullScripts, .voice, .holdToTalk, .autoSend, .serverRecognition, .menuBarIcon]
    }

    /// The ★ rows: turning one on asks macOS for these, in order, each only once the previous one is granted.
    var permissionsRequestedWhenTurnedOn: [Permission] {
        switch self {
        case .calendarChip: return [.calendars]
        case .offerSelection: return [.accessibility]
        case .voice: return [.microphone, .speechRecognition]
        default: return []
        }
    }

    /// The permissions the row shows a status badge for.
    var displayedPermissions: [Permission] {
        switch self {
        case .calendarChip, .toolGroup(.calendar): return [.calendars]
        case .toolGroup(.reminders): return [.reminders]
        case .offerSelection: return [.accessibility]
        case .offerWindow: return [.screenRecording]
        case .voice: return [.microphone, .speechRecognition]
        default: return []
        }
    }

    @MainActor func isOn(in settings: AppSettings) -> Bool {
        switch self {
        case .hoverToOpen: return settings.notch.hoverToOpen
        case .typeAfterHover: return settings.notch.typeAfterHover
        case .replyPreviews: return settings.glance.replyPreviews
        case .notificationPreview: return settings.glance.notificationIncludesPreview
        case .nowPlaying: return settings.glance.nowPlayingEnabled
        case .nowPlayingInClosedNotch: return settings.glance.nowPlayingInClosedNotch
        case .calendarChip: return settings.glance.calendarChipEnabled
        case .suggestBrowserTab: return settings.suggestBrowserTab
        case .autoAttachBrowserTab: return settings.autoAttachBrowserTab
        case .offerSelection: return settings.context.offerSelection
        case .offerWindow: return settings.context.offerWindow
        case .restoreClipboard: return settings.context.restoreClipboard
        case .shelf: return settings.shelf.enabled
        case .keepShelfItemsAfterDragOut: return settings.shelf.keepAfterDragOut
        case .webAccess: return settings.webAccess
        case .showCost: return settings.usage.showCost
        case .actions: return settings.actions.enabled
        case .toolGroup(let group): return settings.actions.groups.contains(group)
        case .logFullScripts: return settings.actions.logFullScripts
        case .voice: return settings.voice.enabled
        case .holdToTalk: return settings.voice.holdShortcutToTalk
        case .autoSend: return settings.voice.autoSend
        case .serverRecognition: return settings.voice.allowServerRecognition
        case .menuBarIcon: return settings.showMenuBarIcon
        }
    }

    /// Stores the value without asking for anything.
    @MainActor func store(_ isOn: Bool, in settings: AppSettings) {
        switch self {
        case .hoverToOpen: settings.notch.hoverToOpen = isOn
        case .typeAfterHover: settings.notch.typeAfterHover = isOn
        case .replyPreviews: settings.glance.replyPreviews = isOn
        case .notificationPreview: settings.glance.notificationIncludesPreview = isOn
        case .nowPlaying: settings.glance.nowPlayingEnabled = isOn
        case .nowPlayingInClosedNotch: settings.glance.nowPlayingInClosedNotch = isOn
        case .calendarChip: settings.glance.calendarChipEnabled = isOn
        case .suggestBrowserTab: settings.suggestBrowserTab = isOn
        case .autoAttachBrowserTab: settings.autoAttachBrowserTab = isOn
        case .offerSelection: settings.context.offerSelection = isOn
        case .offerWindow: settings.context.offerWindow = isOn
        case .restoreClipboard: settings.context.restoreClipboard = isOn
        case .shelf: settings.shelf.enabled = isOn
        case .keepShelfItemsAfterDragOut: settings.shelf.keepAfterDragOut = isOn
        case .webAccess: settings.webAccess = isOn
        case .showCost: settings.usage.showCost = isOn
        case .actions: settings.actions.enabled = isOn
        case .toolGroup(let group):
            if isOn { settings.actions.groups.insert(group) } else { settings.actions.groups.remove(group) }
        case .logFullScripts: settings.actions.logFullScripts = isOn
        case .voice: settings.voice.enabled = isOn
        case .holdToTalk: settings.voice.holdShortcutToTalk = isOn
        case .autoSend: settings.voice.autoSend = isOn
        case .serverRecognition: settings.voice.allowServerRecognition = isOn
        case .menuBarIcon: settings.showMenuBarIcon = isOn
        }
    }

    /// Stores the value. Turning a ★ row on then asks for its permissions (Voice runs the microphone and speech
    /// requests without starting to listen). The Calendar chip turns itself back off unless Calendars is granted.
    /// Returns the status of every permission it asked for.
    @MainActor @discardableResult
    func set(_ isOn: Bool, settings: AppSettings, permissions: PermissionsCenter) async -> [Permission: PermissionStatus] {
        store(isOn, in: settings)
        guard isOn else { return [:] }
        var results: [Permission: PermissionStatus] = [:]
        for permission in permissionsRequestedWhenTurnedOn {
            let status = await permissions.request(permission)
            results[permission] = status
            guard status == .granted else { break }
        }
        if self == .calendarChip, results[.calendars] != .granted {
            store(false, in: settings)
        }
        return results
    }

    /// What happened when the user picked a notification policy.
    enum NotificationOutcome: Equatable {
        /// Stored ("Never", or macOS allowed notifications).
        case applied
        /// Stored, but notifications are off for Otto in System Settings.
        case deniedInSystemSettings
        /// macOS didn't allow notifications for this build; the policy went back to Never.
        case unavailable
    }

    /// Stores the policy; anything other than Never asks for notification permission first.
    @MainActor
    static func setNotificationPolicy(_ policy: ReplyNotificationPolicy, settings: AppSettings,
                                      permissions: PermissionsCenter) async -> NotificationOutcome {
        settings.glance.notificationPolicy = policy
        guard policy != .off else { return .applied }
        switch await permissions.request(.notifications) {
        case .granted:
            return .applied
        case .denied:
            return .deniedInSystemSettings
        case .notDetermined, .limited, .restricted, .needsRelaunch, .unavailable:
            settings.glance.notificationPolicy = .off
            return .unavailable
        }
    }
}
