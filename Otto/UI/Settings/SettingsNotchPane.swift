//
//  SettingsNotchPane.swift
//  Otto
//
//  Settings → Notch: how the notch opens, what the closed notch shows (reply previews, notifications), Now
//  Playing, and the next-meeting chip with the calendars it reads.
//

import SwiftUI

struct SettingsNotchPane: View {
    @Bindable var settings: AppSettings
    let services: SettingsServices

    @Environment(\.settingsOpenExternal) private var openExternal
    @State private var notificationOutcome: SettingsFeatureToggle.NotificationOutcome = .applied
    @State private var calendarWasRefused = false

    var body: some View {
        SettingsPane(tab: .notch, settings: settings) {
            openingSection
            glanceSection
            nowPlayingSection
            calendarSection
        }
        .onAppear { services.calendar?.refresh() }
    }

    // MARK: Opening

    private var openingSection: some View {
        Section {
            Toggle(isOn: Bindable(settings.notch).hoverToOpen) {
                labeled("Open on hover", hoverCaption)
            }
            Toggle(isOn: Bindable(settings.notch).typeAfterHover) {
                labeled("Type after hovering",
                        "When the pointer rests on the open notch, typing goes to Otto. Move away to hand the keyboard back.")
            }
            if let neighbors = services.neighbors?.running, !neighbors.isEmpty {
                ForEach(neighbors, id: \.self) { neighbor in
                    Label {
                        SettingsCaption("\(neighbor.name) is running. Otto and \(neighbor.name) both react to the notch.")
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var hoverCaption: String {
        guard settings.hotKeyEnabled else { return "Otherwise click the notch." }
        return "Otherwise click the notch or press \(settings.shortcuts.hotKey.displayString)."
    }

    // MARK: Glance

    private var glanceSection: some View {
        Section("Glance") {
            Toggle(isOn: Bindable(settings.glance).replyPreviews) {
                labeled("Show reply previews", "The first line of a finished reply drops below the closed notch.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Picker("Notify me", selection: notificationPolicy) {
                    ForEach(ReplyNotificationPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .pickerStyle(.menu)
                notificationStatus
            }
            Toggle(isOn: Bindable(settings.glance).notificationIncludesPreview) {
                labeled("Include a preview of the reply",
                        "The lock screen never shows reply text, whatever this is set to.")
            }
            .disabled(settings.glance.notificationPolicy == .off)
        }
    }

    private var notificationPolicy: Binding<ReplyNotificationPolicy> {
        Binding(
            get: { settings.glance.notificationPolicy },
            set: { policy in
                settings.glance.notificationPolicy = policy
                notificationOutcome = .applied
                guard policy != .off else { return }
                let permissions = services.permissions
                Task { @MainActor in
                    notificationOutcome = await SettingsFeatureToggle.setNotificationPolicy(
                        policy, settings: settings, permissions: permissions)
                }
            }
        )
    }

    @ViewBuilder private var notificationStatus: some View {
        switch notificationOutcome {
        case .unavailable:
            SettingsCaption("macOS didn't allow notifications for this build of Otto.", color: SettingsTone.warning)
        case .deniedInSystemSettings:
            deniedNotificationsRow
        case .applied:
            if settings.glance.notificationPolicy != .off, services.permissions.status(.notifications) == .denied {
                deniedNotificationsRow
            }
        }
    }

    private var deniedNotificationsRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SettingsCaption("Notifications are off for Otto in System Settings → Notifications.", color: SettingsTone.warning)
            Spacer(minLength: 8)
            if let url = Permission.notifications.settingsURL ?? SettingsLinks.notificationSettings {
                Button("Open Notification Settings") { openExternal(url) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    // MARK: Now Playing

    private var nowPlayingSection: some View {
        Section("Now Playing") {
            Toggle(isOn: Bindable(settings.glance).nowPlayingEnabled) {
                labeled("Show what's playing", "Shows the song playing in Music or Spotify. Otto doesn't send it to Claude.")
            }
            Toggle(isOn: Bindable(settings.glance).nowPlayingInClosedNotch) {
                labeled("In the closed notch", "Artwork and a small equalizer while music plays and Otto is idle.")
            }
            .disabled(!settings.glance.nowPlayingEnabled)
            if let monitor = services.nowPlaying {
                ForEach(MediaPlayer.allCases, id: \.self) { player in
                    if let consent = monitor.consent[player] {
                        playerStatus(player, consent: consent)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func playerStatus(_ player: MediaPlayer, consent: BrowserContext.AutomationConsent) -> some View {
        switch consent {
        case .authorized:
            SettingsCaption("\(player.displayName): controls allowed.")
        case .wouldPrompt:
            SettingsCaption("\(player.displayName): Otto asks the first time you press a button.")
        case .denied:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SettingsCaption("\(player.displayName): not allowed.", color: SettingsTone.warning)
                Spacer(minLength: 8)
                if let url = Permission.automation(bundleID: player.rawValue, appName: player.displayName).settingsURL {
                    Button("Open System Settings…") { openExternal(url) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        case .unavailable:
            EmptyView()
        }
    }

    // MARK: Calendar

    private var calendarSection: some View {
        Section("Calendar") {
            FeatureToggleRow(
                title: "Show my next event",
                detail: "Shows your next meeting in the open notch, with a one-click Join. Read-only. Nothing is sent to Claude.",
                isOn: calendarChip,
                permissions: SettingsFeatureToggle.calendarChip.displayedPermissions
            )
            if calendarWasRefused || (settings.glance.calendarChipEnabled && calendarAccessDenied) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SettingsCaption("Otto can't see your calendars. Allow it in System Settings → Privacy & Security → Calendars.",
                                    color: SettingsTone.warning)
                    Spacer(minLength: 8)
                    if let url = Permission.calendars.settingsURL {
                        Button("Open System Settings…") { openExternal(url) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            if settings.glance.calendarChipEnabled, let calendar = services.calendar, calendar.access == .granted,
               !calendar.calendars.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Calendars to include")
                    ForEach(calendar.calendars) { choice in
                        Toggle(isOn: included(choice.id)) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Self.color(choice.colorRGBA))
                                    .frame(width: 8, height: 8)
                                Text(choice.title)
                                if !choice.source.isEmpty {
                                    Text(choice.source)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
    }

    private var calendarAccessDenied: Bool {
        switch services.permissions.status(.calendars) {
        case .denied, .restricted, .limited: return true
        default: return false
        }
    }

    private var calendarChip: Binding<Bool> {
        Binding(
            get: { settings.glance.calendarChipEnabled },
            set: { isOn in
                calendarWasRefused = false
                SettingsFeatureToggle.calendarChip.store(isOn, in: settings)
                guard isOn else {
                    services.calendar?.refresh()
                    return
                }
                let permissions = services.permissions
                let calendar = services.calendar
                Task { @MainActor in
                    let results = await SettingsFeatureToggle.calendarChip.set(true, settings: settings,
                                                                               permissions: permissions)
                    calendarWasRefused = results[.calendars] != .granted
                    calendar?.refresh()
                }
            }
        )
    }

    /// Stored as excluded ids, so a calendar added later shows up.
    private func included(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !settings.glance.calendarExcludedIDs.contains(id) },
            set: { isIncluded in
                var excluded = settings.glance.calendarExcludedIDs.filter { $0 != id }
                if !isIncluded { excluded.append(id) }
                settings.glance.calendarExcludedIDs = excluded.sorted()
                services.calendar?.refresh()
            }
        )
    }

    private static func color(_ rgba: [Double]?) -> Color {
        guard let rgba, rgba.count == 4 else { return .secondary }
        return Color(.sRGB, red: rgba[0], green: rgba[1], blue: rgba[2], opacity: rgba[3])
    }
}
