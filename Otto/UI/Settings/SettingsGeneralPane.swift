//
//  SettingsGeneralPane.swift
//  Otto
//
//  Settings → General: the global shortcut, login item, menu bar icon, custom instructions, the notch's
//  keyboard shortcuts, and the version.
//

import SwiftUI

struct SettingsGeneralPane: View {
    @Bindable var settings: AppSettings
    let services: SettingsServices

    @State private var showsNotchShortcuts = false

    var body: some View {
        SettingsPane(tab: .general, settings: settings) {
            Section {
                ShortcutRecorder(settings: settings)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Menu bar icon", isOn: $settings.showMenuBarIcon)
            }

            Section {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $settings.customInstructions)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(height: 76)
                        .accessibilityLabel("Custom instructions")
                    if settings.customInstructions.isEmpty {
                        Text("e.g. Keep answers short. I write Swift and use British spelling.")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            } header: {
                Text("Custom Instructions")
            } footer: {
                SettingsCaption("Added to every conversation.")
            }

            Section {
                DisclosureGroup("Keyboard shortcuts in the notch", isExpanded: $showsNotchShortcuts) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        ForEach(Self.notchShortcuts, id: \.keys) { row in
                            GridRow {
                                Text(row.keys)
                                    .font(.body.monospaced())
                                    .gridColumnAlignment(.trailing)
                                Text(row.action)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                footer
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.versionString)
                .font(.callout)
                .foregroundStyle(.secondary)
            if LaunchOptions.demo {
                Text("Demo mode: replies are simulated and no API key is needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty {
            return "Otto \(version) (\(build))"
        }
        return "Otto \(version)"
    }

    // MARK: Notch shortcuts

    struct NotchShortcut {
        let keys: String
        let action: String
    }

    /// The keys of the open notch (SPEC-v2 §4.4), as the user reads them.
    static let notchShortcuts: [NotchShortcut] = [
        NotchShortcut(keys: "⌘N", action: "New chat"),
        NotchShortcut(keys: "⌘R", action: "Regenerate the last reply"),
        NotchShortcut(keys: "↑", action: "Edit and resend your last message"),
        NotchShortcut(keys: "⌘.", action: "Stop the reply, listening or speech"),
        NotchShortcut(keys: "⌘⇧C", action: "Copy the last reply"),
        NotchShortcut(keys: "⌘1  ⌘2  ⌘3", action: "Opus 5, Sonnet 5, Haiku 4.5"),
        NotchShortcut(keys: "⌘↩", action: "Approve, or paste the last reply into your app"),
        NotchShortcut(keys: "⌥⌘↩", action: "Paste the last reply as plain text"),
        NotchShortcut(keys: "⌘Y", action: "Recent conversations"),
        NotchShortcut(keys: "⌘D", action: "Shelf"),
        NotchShortcut(keys: "⌘P", action: "Pin the notch open"),
        NotchShortcut(keys: "⌘⇧↑  ⌘⇧↓", action: "Tall reading mode on and off"),
        NotchShortcut(keys: "⌥⌘P  ⌥⌘]  ⌥⌘[", action: "Play or pause, next, previous"),
        NotchShortcut(keys: "⌥⌘J", action: "Join your next meeting"),
        NotchShortcut(keys: "⌥⌘U", action: "Usage details"),
        NotchShortcut(keys: "⌘/", action: "Every shortcut"),
        NotchShortcut(keys: "⌘,", action: "Settings"),
        NotchShortcut(keys: "Esc  ⌘W", action: "Go back or close"),
    ]
}
