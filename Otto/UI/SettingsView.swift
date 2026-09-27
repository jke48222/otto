//
//  SettingsView.swift
//  Otto
//

import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings

    @State private var draftKey = ""
    @State private var keyFeedback: KeyFeedback?
    @FocusState private var isKeyFieldFocused: Bool

    private static let consoleURL = URL(string: "https://console.anthropic.com/settings/keys")

    init(settings: AppSettings) {
        self.settings = settings
    }

    var body: some View {
        Form {
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

            apiKeySection
            modelSection

            Section("Context") {
                Toggle(isOn: $settings.webAccess) {
                    labeled("Web search & fetch", "Let Claude look things up and read pages.")
                }
                Toggle(isOn: $settings.suggestBrowserTab) {
                    labeled("Suggest current browser tab", "Offers the page you're viewing as a chip.")
                }
                Toggle(isOn: $settings.autoAttachBrowserTab) {
                    labeled("Attach tab automatically", "Adds the page right away instead of suggesting it.")
                }
                .disabled(!settings.suggestBrowserTab)
            }

            Section("General") {
                Toggle(isOn: $settings.hotKeyEnabled) {
                    labeled("⌥Space shortcut", "Open Otto from anywhere.")
                }
                Toggle("Menu bar icon", isOn: $settings.showMenuBarIcon)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }

            Section {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $settings.customInstructions)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(height: 76)
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
                Text("Added to every conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                footer
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 480, minHeight: 560, idealHeight: 560)
    }

    // MARK: API key

    private var apiKeySection: some View {
        Section {
            HStack(spacing: 8) {
                SecureField(
                    "API key",
                    text: $draftKey,
                    prompt: Text(settings.apiKey.isEmpty ? "sk-ant-…" : "Paste a new key to replace it")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($isKeyFieldFocused)
                .onSubmit(saveKey)
                // Typing clears the last save/remove feedback. Save and Remove empty the field
                // themselves right before setting that feedback, and this handler runs after them —
                // so an emptied field must not clear it, or "Saved" / the "sk-ant-" warning would
                // never be seen.
                .onChange(of: draftKey) { _, newValue in
                    if !newValue.isEmpty { keyFeedback = nil }
                }

                Button("Save", action: saveKey)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedDraft.isEmpty)
                if !settings.apiKey.isEmpty {
                    Button("Remove", role: .destructive, action: removeKey)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: keyStatus.symbol)
                    .foregroundStyle(keyStatus.color)
                Text(keyStatus.text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let url = Self.consoleURL {
                    Link("Get an API key", destination: url)
                }
            }
            .font(.callout)
        } header: {
            Text("Anthropic API Key")
        } footer: {
            Text("Stored in your Mac's Keychain. Messages go directly to the Anthropic API.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var trimmedDraft: String {
        draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct KeyStatus {
        var symbol: String
        var color: Color
        var text: String
    }

    private enum KeyFeedback: Equatable {
        case saved
        case removed
        case unusual
    }

    private var keyStatus: KeyStatus {
        switch keyFeedback {
        case .saved:
            return KeyStatus(symbol: "checkmark.circle.fill", color: .green, text: "Saved to your Keychain.")
        case .removed:
            return KeyStatus(symbol: "trash.circle", color: .secondary, text: "Key removed.")
        case .unusual:
            return KeyStatus(
                symbol: "exclamationmark.circle.fill",
                color: .orange,
                text: "Saved — but Anthropic keys usually start with “sk-ant-”."
            )
        case nil:
            break
        }
        if !settings.apiKey.isEmpty {
            return KeyStatus(
                symbol: "checkmark.circle.fill",
                color: .green,
                text: "Using the key in your Keychain (\(Self.masked(settings.apiKey)))."
            )
        }
        if settings.resolvedAPIKey != nil {
            return KeyStatus(
                symbol: "terminal",
                color: .secondary,
                text: "Using ANTHROPIC_API_KEY from your environment."
            )
        }
        if LaunchOptions.demo {
            return KeyStatus(symbol: "sparkles", color: .secondary, text: "Not needed in demo mode.")
        }
        return KeyStatus(
            symbol: "key.fill",
            color: .orange,
            text: "Otto needs an API key to chat."
        )
    }

    private static func masked(_ key: String) -> String {
        guard key.count > 12 else { return "••••" }
        return "\(key.prefix(7))…\(key.suffix(4))"
    }

    private func saveKey() {
        let key = trimmedDraft
        guard !key.isEmpty else { return }
        settings.lastSettingsError = nil
        settings.apiKey = key
        guard settings.lastSettingsError == nil else {
            keyFeedback = nil
            return
        }
        draftKey = ""
        isKeyFieldFocused = false
        keyFeedback = key.hasPrefix("sk-ant-") ? .saved : .unusual
    }

    private func removeKey() {
        settings.lastSettingsError = nil
        settings.apiKey = ""
        draftKey = ""
        keyFeedback = settings.lastSettingsError == nil ? .removed : nil
    }

    // MARK: Model

    private var modelSection: some View {
        Section("Model") {
            Picker("Model", selection: $settings.model) {
                ForEach(ModelOption.allCases) { option in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.displayName)
                        Text(option.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 6) {
                Picker("Response style", selection: $settings.effort) {
                    ForEach(EffortLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.model.supportsEffort)

                Text(effortCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var effortCaption: String {
        guard settings.model.supportsEffort else {
            return "\(settings.model.shortName) always answers quickly."
        }
        switch settings.effort {
        case .low: return "Fast, lighter answers."
        case .medium: return "A good balance of speed and depth."
        case .high: return "Takes longer and thinks harder."
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(versionString)
                .font(.callout)
                .foregroundStyle(.secondary)
            if LaunchOptions.demo {
                Text("Demo mode — replies are simulated and no API key is needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty {
            return "Otto \(version) (\(build))"
        }
        return "Otto \(version)"
    }

    private func labeled(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
