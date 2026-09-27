//
//  SettingsComponents.swift
//  Otto
//
//  Building blocks every Settings pane shares: the pane scaffold (grouped Form, error banner, scrolling to a
//  requested section), a title-and-caption label, permission status rows and badges, and feature toggles that
//  show the permission they depend on without asking for it.
//

import AppKit
import SwiftUI

// MARK: - Navigation and external windows

/// Which tab is showing and which section a deep link asked for. The window controller owns it; panes read it
/// from the environment and scroll their ScrollViewReader to the requested anchor.
@MainActor @Observable final class SettingsNavigation {
    var tab: SettingsTab = .general
    /// The section to scroll to once its tab is showing; cleared by the pane that scrolled.
    private(set) var pendingAnchor: SettingsAnchor?
    /// Bumped on every request, so asking for the same section twice scrolls twice.
    private(set) var requestCount = 0

    func request(_ anchor: SettingsAnchor) {
        pendingAnchor = anchor
        requestCount += 1
    }

    func consume(_ anchor: SettingsAnchor) {
        if pendingAnchor == anchor { pendingAnchor = nil }
    }
}

/// Opens another app's window from Settings. Inside the Settings panel this is the window controller's
/// `openExternal(_:)`; anywhere else (snapshots) it opens the URL directly.
struct SettingsExternalOpener {
    let open: @MainActor (URL) -> Void

    init(_ open: @escaping @MainActor (URL) -> Void) {
        self.open = open
    }

    @MainActor func callAsFunction(_ url: URL) {
        open(url)
    }

    /// A file URL is revealed in Finder; anything else opens in its app.
    static let workspace = SettingsExternalOpener { url in
        if url.isFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct SettingsExternalOpenerKey: EnvironmentKey {
    static let defaultValue = SettingsExternalOpener.workspace
}

extension EnvironmentValues {
    var settingsOpenExternal: SettingsExternalOpener {
        get { self[SettingsExternalOpenerKey.self] }
        set { self[SettingsExternalOpenerKey.self] = newValue }
    }
}

/// Deep links into System Settings and the web that several panes use.
enum SettingsLinks {
    static let keyboardSettings = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    static let notificationSettings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    static let fileVault = URL(string: "x-apple.systempreferences:com.apple.preference.security?FileVault")
    static let anthropicConsole = URL(string: "https://console.anthropic.com")
    static let apiKeys = URL(string: "https://console.anthropic.com/settings/keys")
}

// MARK: - Pane scaffold

/// A grouped Form with the error banner on top, wrapped in a ScrollViewReader that scrolls to this tab's
/// requested anchor. Sections that can be scrolled to carry `.id(anchor.rawValue)`.
struct SettingsPane<Content: View>: View {
    let tab: SettingsTab
    let settings: AppSettings
    @ViewBuilder var content: Content

    @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                SettingsErrorBanner(settings: settings)
                content
            }
            .formStyle(.grouped)
            .onAppear { scrollToPendingAnchor(proxy) }
            .onChange(of: navigation?.requestCount) { _, _ in scrollToPendingAnchor(proxy) }
            .onChange(of: navigation?.tab) { _, _ in scrollToPendingAnchor(proxy) }
        }
    }

    private func scrollToPendingAnchor(_ proxy: ScrollViewProxy) {
        guard let navigation, let anchor = navigation.pendingAnchor, anchor.tab == tab, navigation.tab == tab else {
            return
        }
        // Let the tab switch and the Form's first layout land before scrolling.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(anchor.rawValue, anchor: .top)
            }
            navigation.consume(anchor)
        }
    }
}

/// The last settings operation that failed (Keychain, login item), at the top of every pane.
struct SettingsErrorBanner: View {
    @Bindable var settings: AppSettings

    var body: some View {
        if let error = settings.lastSettingsError {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("Dismiss") { settings.lastSettingsError = nil }
                        .buttonStyle(.borderless)
                }
            }
        }
    }
}

/// A row title with a secondary caption under it.
func labeled(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A caption line under a row or at the end of a section.
struct SettingsCaption: View {
    let text: String
    var color: Color = .secondary

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Permissions

/// How one permission's status reads in Settings.
struct SettingsPermissionState: Equatable {
    enum Tone: Equatable { case allowed, neutral, attention }

    let text: String
    let tone: Tone
    /// Shows an "Open" button that opens the permission's System Settings pane.
    let offersOpen: Bool

    init(_ status: PermissionStatus) {
        switch status {
        case .granted:
            self.init(text: "Allowed", tone: .allowed, offersOpen: false)
        case .notDetermined:
            self.init(text: "Asks when needed", tone: .neutral, offersOpen: false)
        case .denied:
            self.init(text: "Off in System Settings", tone: .attention, offersOpen: true)
        case .limited:
            self.init(text: "Add-only access", tone: .attention, offersOpen: true)
        case .restricted:
            self.init(text: "Managed by your organization", tone: .neutral, offersOpen: false)
        case .needsRelaunch:
            self.init(text: "Reopen Otto to finish", tone: .attention, offersOpen: false)
        case .unavailable:
            self.init(text: "Not available", tone: .neutral, offersOpen: false)
        }
    }

    private init(text: String, tone: Tone, offersOpen: Bool) {
        self.text = text
        self.tone = tone
        self.offersOpen = offersOpen
    }

    var color: Color {
        switch tone {
        case .allowed: return .green
        case .neutral: return .secondary
        case .attention: return .orange
        }
    }
}

/// A small status dot and label for one permission, with "Open" when it is off in System Settings.
/// Reading the status never prompts.
struct SettingsPermissionBadge: View {
    let permission: Permission
    /// "Microphone: Allowed" instead of "Allowed", for rows that depend on more than one permission.
    var showsName = false

    @Environment(PermissionsCenter.self) private var permissions: PermissionsCenter?
    @Environment(\.settingsOpenExternal) private var openExternal

    var body: some View {
        let state = SettingsPermissionState(permissions?.status(permission) ?? .notDetermined)
        HStack(spacing: 5) {
            Circle()
                .fill(state.color)
                .frame(width: 7, height: 7)
            Text(showsName ? "\(permission.displayName): \(state.text)" : state.text)
                .foregroundStyle(.secondary)
            if state.offersOpen, let url = permission.settingsURL {
                Button("Open") { openExternal(url) }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

/// One permission with its live status (Privacy → Permissions, Context).
struct PermissionRow: View {
    let permission: Permission

    init(permission: Permission) {
        self.permission = permission
    }

    var body: some View {
        LabeledContent {
            SettingsPermissionBadge(permission: permission)
        } label: {
            Label(permission.displayName, systemImage: Self.symbol(for: permission))
        }
    }

    static func symbol(for permission: Permission) -> String {
        switch permission {
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .microphone: return "mic"
        case .speechRecognition: return "waveform"
        case .calendars: return "calendar"
        case .reminders: return "checklist"
        case .notifications: return "bell"
        case .automation: return "applescript"
        }
    }
}

/// A feature switch with the status of the permissions it depends on. Turning it on only stores the setting;
/// the explain-first request happens in the notch when the feature is used. The few rows whose only purpose is
/// the permission (Calendar chip, notifications, Voice, selected text) ask through `SettingsFeatureToggle.set`.
struct FeatureToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    let permissions: [Permission]

    init(title: String, detail: String, isOn: Binding<Bool>, permissions: [Permission]) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
        self.permissions = permissions
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                labeled(title, detail)
                if !permissions.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(permissions, id: \.self) { permission in
                            SettingsPermissionBadge(permission: permission, showsName: permissions.count > 1)
                        }
                    }
                }
            }
        }
    }
}
