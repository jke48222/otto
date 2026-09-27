//
//  SettingsVoicePane.swift
//  Otto
//
//  Settings → Voice: talking to Otto (microphone and speech permissions, hold to talk, auto-send, the
//  recognition language and whether Apple's speech service may help), reading replies aloud, and where
//  macOS Dictation is switched on.
//

import AVFoundation
import Speech
import SwiftUI

struct SettingsVoicePane: View {
    @Bindable var settings: AppSettings
    let services: SettingsServices

    @Environment(\.settingsOpenExternal) private var openExternal
    @State private var languages: [Language] = []

    /// One recognition language for the picker.
    struct Language: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let isOnDevice: Bool
    }

    var body: some View {
        SettingsPane(tab: .voice, settings: settings) {
            talkSection
            spokenRepliesSection
            dictationSection
        }
        .task { languages = await Self.loadLanguages() }
    }

    private var shortcut: String {
        settings.hotKeyEnabled ? settings.shortcuts.hotKey.displayString : "the shortcut"
    }

    // MARK: Talking

    private var talkSection: some View {
        Section("Voice") {
            FeatureToggleRow(
                title: "Talk to Otto",
                detail: "Hold \(shortcut) or the mic and speak.",
                isOn: talkToOtto,
                permissions: SettingsFeatureToggle.voice.displayedPermissions
            )
            recognitionRow
            Toggle("Hold \(shortcut) to talk", isOn: Bindable(settings.voice).holdShortcutToTalk)
                .disabled(!settings.voice.enabled || !settings.hotKeyEnabled)
            Toggle("Send when I let go", isOn: Bindable(settings.voice).autoSend)
                .disabled(!settings.voice.enabled)
            Picker("Language", selection: Bindable(settings.voice).localeIdentifier) {
                Text("Match System").tag("")
                if !languages.isEmpty {
                    Divider()
                }
                ForEach(languages) { language in
                    Text(language.isOnDevice ? "\(language.name) ✓" : language.name)
                        .tag(language.id)
                }
                if !settings.voice.localeIdentifier.isEmpty,
                   !languages.contains(where: { $0.id == settings.voice.localeIdentifier }) {
                    Text(Self.name(ofLocale: settings.voice.localeIdentifier)).tag(settings.voice.localeIdentifier)
                }
            }
            .pickerStyle(.menu)
            SettingsCaption("✓ Transcribed on this Mac.")
        }
    }

    /// The ★ row: turning it on runs the microphone and speech recognition requests without starting to listen.
    private var talkToOtto: Binding<Bool> {
        Binding(
            get: { settings.voice.enabled },
            set: { isOn in
                SettingsFeatureToggle.voice.store(isOn, in: settings)
                guard isOn else { return }
                let permissions = services.permissions
                Task { @MainActor in
                    await SettingsFeatureToggle.voice.set(true, settings: settings, permissions: permissions)
                }
            }
        )
    }

    @ViewBuilder private var recognitionRow: some View {
        let onDevice = isCurrentLanguageOnDevice
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(onDevice ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(onDevice ? "On-device" : "Uses Apple's speech service")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: Bindable(settings.voice).allowServerRecognition) {
                labeled("Allow Apple's speech service",
                        "Only for languages this Mac can't transcribe itself. Your audio then goes to Apple.")
            }
            .disabled(!settings.voice.enabled)
        }
    }

    private var isCurrentLanguageOnDevice: Bool {
        let identifier = settings.voice.locale.identifier
        if let match = languages.first(where: { $0.id == identifier }) { return match.isOnDevice }
        let language = settings.voice.locale.language.languageCode?.identifier
        return languages.contains { $0.isOnDevice && Locale(identifier: $0.id).language.languageCode?.identifier == language }
    }

    // MARK: Spoken replies

    private var spokenRepliesSection: some View {
        Section("Spoken Replies") {
            Picker("Read replies aloud", selection: Bindable(settings.voice).spokenReplies) {
                ForEach(SpokenReplies.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if settings.voice.spokenReplies != .off {
                HStack {
                    Picker("Voice", selection: Bindable(settings.voice).voiceIdentifier) {
                        Text("Best available").tag("")
                        ForEach(voices, id: \.identifier) { voice in
                            Text(Self.label(for: voice)).tag(voice.identifier)
                        }
                    }
                    .pickerStyle(.menu)
                    Button("Preview") { services.speaker?.preview() }
                        .disabled(services.speaker == nil)
                }
                LabeledContent("Speed") {
                    HStack(spacing: 8) {
                        Text("Slower")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: Bindable(settings.voice).speakingRate, in: VoiceSettings.speakingRateRange, step: 0.05)
                            .frame(maxWidth: 220)
                            .accessibilityLabel("Speaking speed")
                        Text("Faster")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                SettingsCaption("Stops when you click, press a key in Otto, or tap \(shortcut).")
                SettingsCaption("Want a better voice? Download Premium voices in System Settings → Accessibility → "
                                + "Spoken Content.")
            }
        }
    }

    private var voices: [AVSpeechSynthesisVoice] {
        ReplySpeaker.availableVoices(languageCode: settings.voice.locale.identifier)
    }

    private static func label(for voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "\(voice.name) (Premium)"
        case .enhanced: return "\(voice.name) (Enhanced)"
        default: return voice.name
        }
    }

    // MARK: Dictation

    private var dictationSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SettingsCaption("Otto uses macOS Dictation to turn speech into text. If Dictation is off, turn it "
                                + "on in Keyboard Settings.")
                Spacer(minLength: 8)
                if let url = SettingsLinks.keyboardSettings {
                    Button("Keyboard Settings…") { openExternal(url) }
                }
            }
        }
    }

    // MARK: Languages

    private static func name(ofLocale identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Every language Speech supports, by localized name, marking the ones this Mac transcribes itself.
    /// Creating a recognizer never asks for permission.
    static func loadLanguages() async -> [Language] {
        await Task.detached(priority: .utility) {
            SFSpeechRecognizer.supportedLocales()
                .map { locale in
                    Language(id: locale.identifier,
                             name: Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier,
                             isOnDevice: SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false)
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
    }
}
