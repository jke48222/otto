//
//  SettingsGeneralPane.swift
//  Otto
//
//  Settings → General: the global shortcut, login item, menu bar icon, custom instructions, the notch's
//  keyboard shortcuts, then (Setapp build) the Updates section, and the build footer: version, build and
//  which kind of build this is (§14.10.3).
//

import SwiftUI

struct SettingsGeneralPane: View {
    @Bindable var settings: AppSettings
    let services: SettingsServices

    @State private var showsNotchShortcuts = false
    #if OTTO_SETAPP
    @Environment(\.settingsOpenExternal) private var openExternal
    #endif

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

            #if OTTO_SETAPP
            if let updater = services.updater {
                let opener = openExternal
                UpdatesSection(updater: updater, siteHost: nil, openExternal: { opener($0) })
                    // Setapp is asked whether an update waits each time General appears (§14.11.2).
                    .onAppear { updater.checkNow() }
            }
            #endif

            Section {
                footer
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            BuildInfoFooter(version: Self.bundleValue("CFBundleShortVersionString") ?? "1.0",
                            build: Self.bundleValue("CFBundleVersion") ?? "",
                            flavor: OttoBuild.flavor,
                            isDemo: LaunchOptions.demo)
            if LaunchOptions.demo {
                Text("Demo mode: replies are simulated and no API key is needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func bundleValue(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
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
