//
//  SettingsVoicePane.swift
//  Otto
//
//  Settings → Voice: talking to Otto (microphone and speech permissions, hold to talk, auto-send, the
//  recognition language and whether Apple's speech service may help), reading replies aloud, and where
//  macOS Dictation is switched on.
//

import AppKit
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
        Section {
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
            Picker(selection: Bindable(settings.voice).localeIdentifier) {
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
            } label: {
                languageLabel
            }
            .pickerStyle(.menu)
            Toggle(isOn: Bindable(settings.voice).allowServerRecognition) {
                labeled("Allow Apple's speech service",
                        "Only for languages this Mac can't transcribe itself. Your audio then goes to Apple.")
            }
            .disabled(!settings.voice.enabled)
            // Where Dictation is switched on: a plain row with its button, explained by the section's footer.
            if let url = SettingsLinks.keyboardSettings {
                LabeledContent("macOS Dictation") {
                    Button("Keyboard Settings…") { openExternal(url) }
                }
            }
        } header: {
            Text("Voice")
        } footer: {
            SettingsCaption(Self.dictationNote)
        }
    }

    static let dictationNote = "Otto uses macOS Dictation to turn speech into text. If Dictation is off, turn it on "
        + "in Keyboard Settings."

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

    private static let statusDotSize: CGFloat = 6
    private static let statusDotSpacing: CGFloat = 5

    /// The status and its explanation as one caption line: "On-device · ✓ Transcribed on this Mac."
    static func recognitionCaption(_ status: RecognitionStatus) -> String {
        guard let caption = status.caption else { return status.text }
        return "\(status.text) · \(caption)"
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

    /// "Language" with where the chosen language's audio goes as its caption, the way a toggle row carries its
    /// detail: a status dot on the caption's first line, then the status and what it means.
    private var languageLabel: some View {
        let status = Self.recognitionStatus(isOnDevice: languagesLoaded ? isCurrentLanguageOnDevice : nil,
                                            allowsServer: settings.voice.allowServerRecognition)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Language")
            HStack(alignment: .firstTextBaseline, spacing: Self.statusDotSpacing) {
                Circle()
                    .fill(status.dotColor)
                    .frame(width: Self.statusDotSize, height: Self.statusDotSize)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    .accessibilityHidden(true)
                Text(Self.recognitionCaption(status))
                    .font(.caption)
                    .foregroundStyle(SettingsTone.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            // The title on its own line, the segments under it on the row's leading edge.
            VStack(alignment: .leading, spacing: 8) {
                Text("Read replies aloud")
                    .accessibilityHidden(true)
                // Spans the group's content width like every other row's controls (a SwiftUI segmented picker
                // keeps its intrinsic width on macOS).
                FillingSegmentedPicker(
                    label: "Read replies aloud",
                    options: SpokenReplies.allCases.map { ($0.displayName, $0) },
                    selection: Bindable(settings.voice).spokenReplies
                )
            }

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
                            .foregroundStyle(SettingsTone.secondaryText)
                        Slider(value: Bindable(settings.voice).speakingRate, in: VoiceSettings.speakingRateRange, step: 0.05)
                            .frame(maxWidth: 220)
                            .accessibilityLabel("Speaking speed")
                        Text("Faster")
                            .font(.caption)
                            .foregroundStyle(SettingsTone.secondaryText)
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

// MARK: - Filling segmented picker

/// A system segmented control whose segments share the full width it is offered, so it lines up with the trailing
/// edge of the group's other controls. VoiceOver reads it as `label` with the selected segment.
private struct FillingSegmentedPicker<Value: Hashable>: NSViewRepresentable {
    let label: String
    let options: [(title: String, value: Value)]
    @Binding var selection: Value

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: options.map(\.title), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel(label)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = options.firstIndex { $0.value == selection } ?? -1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: NSSegmentedControl, context: Context) -> CGSize? {
        let intrinsic = control.intrinsicContentSize
        guard let width = proposal.width, width.isFinite else { return intrinsic }
        return CGSize(width: max(width, intrinsic.width), height: intrinsic.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: FillingSegmentedPicker

        init(parent: FillingSegmentedPicker) { self.parent = parent }

        @MainActor @objc func changed(_ control: NSSegmentedControl) {
            let index = control.selectedSegment
            guard parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index].value
        }
    }
}
