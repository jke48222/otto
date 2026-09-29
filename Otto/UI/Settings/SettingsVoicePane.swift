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
    /// `languages` has loaded; until then the recognition row says it is checking instead of guessing.
    @State private var languagesLoaded = false
    /// The reply voices for the current language, loaded off the main thread (listing the system's voices can take
    /// a few hundred milliseconds the first time), and again whenever voices are installed or removed.
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var voicesGeneration = 0

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
        .task {
            languages = await Self.loadLanguages()
            languagesLoaded = true
        }
        .task(id: VoicesKey(language: settings.voice.locale.identifier, generation: voicesGeneration)) {
            voices = await ReplySpeaker.loadAvailableVoices(languageCode: settings.voice.locale.identifier)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            voicesGeneration += 1
        }
    }

    private struct VoicesKey: Equatable {
        let language: String
        let generation: Int
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
            recognitionRow
        }
    }

    /// Where the chosen language's audio goes, under the picker it describes.
    enum RecognitionStatus: Equatable {
        /// Transcribed on this Mac.
        case onDevice
        /// Not on this Mac, and Apple's speech service is allowed: audio goes to Apple.
        case server
        /// Not on this Mac and the service isn't allowed: Otto asks (the on-device card) before any audio leaves.
        case asksFirst
        /// The Mac's recognition languages are still loading; nothing is claimed yet.
        case checking

        var text: String {
            switch self {
            case .onDevice: return "On-device"
            case .server: return "Uses Apple's speech service"
            case .asksFirst: return "Not available on this Mac. Otto will ask before using Apple's speech service."
            case .checking: return "Checking this Mac's languages…"
            }
        }

        /// The line under the status, only where it holds: audio stays on this Mac only when it is on-device.
        var caption: String? {
            switch self {
            case .onDevice: return "✓ Transcribed on this Mac."
            case .server: return "Your audio goes to Apple to be transcribed."
            case .asksFirst, .checking: return nil
            }
        }

        var dotColor: Color {
            switch self {
            case .onDevice: return .green
            case .server: return .orange
            case .asksFirst, .checking: return .secondary
            }
        }
    }

    /// `isOnDevice` nil: the languages haven't loaded yet.
    static func recognitionStatus(isOnDevice: Bool?, allowsServer: Bool) -> RecognitionStatus {
        guard let isOnDevice else { return .checking }
        if isOnDevice { return .onDevice }
        return allowsServer ? .server : .asksFirst
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
        let status = Self.recognitionStatus(isOnDevice: languagesLoaded ? isCurrentLanguageOnDevice : nil,
                                            allowsServer: settings.voice.allowServerRecognition)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(status.dotColor)
                    .frame(width: 7, height: 7)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caption = status.caption {
                SettingsCaption(caption)
            }
        }
        VStack(alignment: .leading, spacing: 4) {
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
