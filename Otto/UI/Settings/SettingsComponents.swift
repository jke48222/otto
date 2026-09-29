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
                        .foregroundStyle(SettingsTone.warning)
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
            .foregroundStyle(SettingsTone.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Text colors for warnings, errors and success in Settings, which follows the system appearance (only the notch is
/// always dark). The system orange, red and green are too light for text on a light window (2.3:1, 3.6:1 and 2.2:1),
/// so the light variants are darker shades that pass WCAG AA (4.5:1) for caption and callout text; the dark variants
/// are the system colors (red a little lighter, to pass on the grouped rows).
enum SettingsTone {
    static let warning = Color(nsColor: warningColor)
    static let error = Color(nsColor: errorColor)
    static let success = Color(nsColor: successColor)

    static let warningColor = dynamic(light: 0xA84B00, dark: .systemOrange)
    static let errorColor = dynamic(light: 0xC4281C, dark: srgb(0xFF6B61))
    static let successColor = dynamic(light: 0x1B6E30, dark: .systemGreen)

    /// Secondary text that has to read as text, not as a hint: captions and footers that carry a status or an
    /// instruction. The system's secondary label color is 50 % black, 4.0:1 on the white light window; these are
    /// opaque and pass AA: #636366 on white (5.9:1), #9A9A9F on the dark window (6.0:1) and grouped row (5.2:1).
    static let secondaryText = Color(nsColor: secondaryTextColor)
    static let secondaryTextColor = dynamic(light: 0x636366, dark: srgb(0x9A9A9F))

    /// Placeholder text in a field or text editor. The system's tertiary and placeholder colors fall to about
    /// 2.3:1 on a grouped row; these pass AA: #6B6B70 on white (5.3:1), #9A9A9F on the dark #252525 row (5.6:1).
    static let placeholder = Color(nsColor: placeholderColor)
    static let placeholderColor = dynamic(light: 0x6B6B70, dark: srgb(0x9A9A9F))

    private static func dynamic(light: UInt32, dark: NSColor) -> NSColor {
        let lightColor = srgb(light)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : lightColor
        }
    }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// WCAG contrast ratio of `foreground` on `background` as drawn in `appearance` (tests).
    static func contrastRatio(_ foreground: NSColor, on background: NSColor, in appearance: NSAppearance) -> CGFloat {
        var ratio: CGFloat = 1
        appearance.performAsCurrentDrawingAppearance {
            guard let text = foreground.usingColorSpace(.sRGB), let fill = background.usingColorSpace(.sRGB) else {
                return
            }
            let lighter = max(luminance(text), luminance(fill))
            let darker = min(luminance(text), luminance(fill))
            ratio = (lighter + 0.05) / (darker + 0.05)
        }
        return ratio
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }
}

/// A caption line under a row or at the end of a section, in `SettingsTone.secondaryText` (AA in both appearances).
struct SettingsCaption: View {
    let text: String
    var color: Color = SettingsTone.secondaryText

    init(_ text: String, color: Color = SettingsTone.secondaryText) {
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
                .foregroundStyle(SettingsTone.secondaryText)
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
                .labelStyle(SettingsIconLabelStyle())
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

/// A settings row's leading symbol in a fixed 22 pt column, 10 pt before the title, so every icon row's title
/// starts at the same x in every pane whatever the symbol's own width.
struct SettingsRowIcon: View {
    let systemName: String

    static let columnWidth: CGFloat = 22
    static let spacing: CGFloat = 10

    var body: some View {
        Image(systemName: systemName)
            .foregroundStyle(SettingsTone.secondaryText)
            .frame(width: Self.columnWidth, alignment: .center)
            .accessibilityHidden(true)
    }
}

/// `Label` with its icon in the `SettingsRowIcon` column.
struct SettingsIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SettingsRowIcon.spacing) {
            configuration.icon
                .foregroundStyle(SettingsTone.secondaryText)
                .frame(width: SettingsRowIcon.columnWidth, alignment: .center)
            configuration.title
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
