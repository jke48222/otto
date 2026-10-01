//
//  SettingsScreen.swift
//  Otto
//
//  Settings on iPhone: the API key and demo mode, how Otto replies (model, response style, web search, custom
//  instructions, cost), what happens while you're away (Live Activity, notifications), voice, history, usage,
//  haptics and about. Same preferences and copy as the Mac where they mean the same thing.
//

import SwiftUI

struct SettingsScreen: View {
    let model: ChatScreenModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsForm(model: model, settings: model.settings)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .toolbarBackground(Theme.panel, for: .navigationBar)
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.panel)
    }
}

private struct SettingsForm: View {
    let model: ChatScreenModel
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            ClaudeSection(model: model, settings: settings)
            RepliesSection(model: model, settings: settings)
            AwaySection(model: model, settings: settings, mobile: settings.mobile)
            VoiceSection(model: model, settings: settings, voice: settings.voice)
            HistorySection(model: model, settings: settings)
            UsageSection(ledger: model.ledger)
            Section {
                Toggle("Haptics", isOn: Bindable(settings.mobile).haptics)
            } footer: {
                Text("A light tap when a question goes and when a reply arrives.")
            }
            AboutSection()
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .tint(Theme.orbLight)
    }
}

// MARK: - Claude

private struct ClaudeSection: View {
    let model: ChatScreenModel
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            NavigationLink {
                APIKeyPage(settings: settings)
            } label: {
                LabeledContent {
                    Text(keySummary)
                        .foregroundStyle(Theme.textTertiary)
                } label: {
                    Label("API Key", systemImage: "key")
                }
            }
            Toggle(isOn: Bindable(settings.mobile).demoMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Demo Mode")
                    Text("Scripted replies, no key needed. Demo chats are kept apart from yours.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        } header: {
            Text("Claude")
        } footer: {
            if model.isDemo, !settings.mobile.demoMode {
                Text("Otto was opened in demo mode, so it stays in demo mode until it's opened again.")
            }
        }
    }

    private var keySummary: String {
        if !settings.apiKey.isEmpty { return APIKeyPage.masked(settings.apiKey) }
        if settings.resolvedAPIKey != nil { return "From the environment" }
        return "Not set"
    }
}

// MARK: - Replies

private struct RepliesSection: View {
    let model: ChatScreenModel
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            NavigationLink {
                ModelPickerPage(settings: settings)
            } label: {
                LabeledContent("Model") {
                    Text(settings.model.shortName)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Picker("Response Style", selection: $settings.effort) {
                ForEach(EffortLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .disabled(!settings.model.supportsEffort)
            Toggle(isOn: $settings.webAccess) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Web Search & Fetch")
                    Text("Let Claude look things up and read pages.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            NavigationLink {
                CustomInstructionsPage(settings: settings)
            } label: {
                LabeledContent("Custom Instructions") {
                    Text(settings.customInstructions.isEmpty ? "None" : "On")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Toggle(isOn: Bindable(settings.usage).showCost) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Cost on Replies")
                    Text("An estimate at list prices appears under each reply.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        } header: {
            Text("Replies")
        } footer: {
            Text(effortCaption)
        }
    }

    private var effortCaption: String {
        guard settings.model.supportsEffort else {
            return "\(settings.model.shortName) always answers quickly."
        }
        switch settings.effort {
        case .low: return "Quick: fast, lighter answers."
        case .medium: return "Balanced: a good balance of speed and depth."
        case .high: return "Thorough: takes longer and thinks harder."
        }
    }
}

// MARK: - While you're away

private struct AwaySection: View {
    let model: ChatScreenModel
    let settings: AppSettings
    @Bindable var mobile: MobileSettings

    @State private var notificationsRefused = false

    var body: some View {
        Section {
            Toggle(isOn: $mobile.liveActivities) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live Activity")
                    Text("Follow a reply in the Dynamic Island and on the Lock Screen.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Toggle(isOn: notifyBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notify When a Reply Finishes")
                    Text("When there's no Live Activity to show it.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Toggle("Show Reply Text", isOn: $mobile.notificationPreview)
                .disabled(!mobile.notifyWhenAway && !mobile.liveActivities)
        } header: {
            Text("While You're Away")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        var lines = ["A reply keeps going for a little while after you leave Otto. If iOS pauses it first, Retry picks "
                     + "it up where it stopped."]
        if mobile.liveActivities, !model.services.liveActivitiesAllowed() {
            lines.append("Live Activities are off for Otto in the Settings app.")
        }
        if notificationsRefused {
            lines.append("Notifications are off for Otto. Allow them in the Settings app to be notified.")
        }
        if !mobile.notificationPreview {
            lines.append("The Lock Screen says only that Otto replied.")
        }
        return lines.joined(separator: "\n\n")
    }

    private var notifyBinding: Binding<Bool> {
        Binding(
            get: { mobile.notifyWhenAway },
            set: { isOn in
                guard isOn else {
                    mobile.notifyWhenAway = false
                    return
                }
                let request = model.services.requestNotificationPermission
                Task { @MainActor in
                    let allowed = await request()
                    notificationsRefused = !allowed
                    mobile.notifyWhenAway = allowed
                }
            }
        )
    }
}

// MARK: - Voice

private struct VoiceSection: View {
    let model: ChatScreenModel
    let settings: AppSettings
    @Bindable var voice: VoiceSettings

    var body: some View {
        Section {
            Toggle(isOn: $voice.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Talk to Otto")
                    Text("Hold the mic to talk, or tap it to start and tap again to send.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Toggle("Send When I Finish", isOn: $voice.autoSend)
                .disabled(!voice.enabled)
            Toggle(isOn: $voice.allowServerRecognition) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use Apple's Speech Service")
                    Text("Only when your language can't be recognized on this iPhone.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .disabled(!voice.enabled)
            Picker("Read Replies Aloud", selection: $voice.spokenReplies) {
                ForEach(SpokenReplies.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Speaking Rate")
                    Spacer()
                    Button("Preview") {
                        model.audio.activate(.speaking)
                        model.voice.speaker.preview()
                    }
                    .buttonStyle(.borderless)
                }
                Slider(value: $voice.speakingRate, in: VoiceSettings.speakingRateRange) {
                    Text("Speaking Rate")
                } minimumValueLabel: {
                    Image(systemName: "tortoise")
                } maximumValueLabel: {
                    Image(systemName: "hare")
                }
            }
            .disabled(voice.spokenReplies == .off)
        } header: {
            Text("Voice")
        } footer: {
            Text("Otto listens only while the mic is on. Speech is turned into text on this iPhone unless you allow "
                 + "Apple's speech service; replies are read by your iPhone's own voices.")
        }
    }
}

// MARK: - History

private struct HistorySection: View {
    let model: ChatScreenModel
    @Bindable var settings: AppSettings

    @State private var confirmsTurnOff = false
    @State private var confirmsDeleteAll = false
    @State private var pendingRetention: HistoryRetention?
    @State private var pendingRetentionCount = 0
    @State private var isBusy = false

    private var history: HistoryController { model.history }

    var body: some View {
        Section {
            Toggle(isOn: historyEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save Chat History")
                    Text("Keep conversations on this iPhone so you can continue them later.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Picker("Keep Conversations", selection: retention) {
                ForEach(HistoryRetention.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .disabled(!settings.history.enabled)
            Picker("Start a New Chat", selection: Bindable(settings.history).idleReset) {
                ForEach(IdleResetInterval.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .disabled(!settings.history.enabled)
            LabeledContent("Saved") {
                Text(statusLine)
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
            Button("Delete All History…", role: .destructive) {
                confirmsDeleteAll = true
            }
            .disabled(isBusy || !settings.history.enabled)
            if let error = history.lastSaveError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Theme.error)
            }
        } header: {
            Text("History")
        } footer: {
            Text("Stored only on this iPhone, protected by its passcode. Never uploaded, synced or used for anything "
                 + "else, and left out of iCloud backups. Attached files are kept for up to 30 days so a continued "
                 + "chat can send them again; after that Otto keeps only their names and previews.")
        }
        .task {
            await history.refreshUsage()
        }
        .confirmationDialog("Turn off history?", isPresented: $confirmsTurnOff, titleVisibility: .visible) {
            Button("Turn Off and Delete", role: .destructive) { setHistory(enabled: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Otto will stop saving conversations and delete the \(savedCount) it has saved.")
        }
        .confirmationDialog("Delete all history?", isPresented: $confirmsDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive, action: deleteAll)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete all conversations from this iPhone? This can't be undone.")
        }
        .confirmationDialog("Delete older conversations?", isPresented: retentionConfirmation,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: applyPendingRetention)
            Button("Cancel", role: .cancel) { pendingRetention = nil }
        } message: {
            Text(retentionMessage)
        }
    }

    private var savedCount: Int {
        history.storageUsage?.conversationCount ?? history.summaries.count
    }

    /// "12 conversations · 48.3 MB" / "None".
    private var statusLine: String {
        guard let usage = history.storageUsage, usage.conversationCount > 0 else { return "None" }
        let count = usage.conversationCount == 1 ? "1 conversation" : "\(usage.conversationCount) conversations"
        return "\(count) · \(ByteCountFormatter.string(fromByteCount: usage.totalBytes, countStyle: .file))"
    }

    private var historyEnabled: Binding<Bool> {
        Binding(
            get: { settings.history.enabled },
            set: { isOn in
                if isOn {
                    setHistory(enabled: true)
                } else if savedCount > 0 {
                    confirmsTurnOff = true
                } else {
                    setHistory(enabled: false)
                }
            }
        )
    }

    private var retention: Binding<HistoryRetention> {
        Binding(
            get: { settings.history.retention },
            set: { newValue in
                guard newValue != settings.history.retention else { return }
                let affected = history.countConversations(olderThan: newValue)
                if affected > 0 {
                    pendingRetention = newValue
                    pendingRetentionCount = affected
                } else {
                    settings.history.retention = newValue
                }
            }
        )
    }

    private var retentionConfirmation: Binding<Bool> {
        Binding(
            get: { pendingRetention != nil },
            set: { isPresented in if !isPresented { pendingRetention = nil } }
        )
    }

    private var retentionMessage: String {
        guard let pendingRetention else { return "" }
        let count = pendingRetentionCount == 1 ? "1 conversation is" : "\(pendingRetentionCount) conversations are"
        return "\(count) older than \(pendingRetention.displayName.lowercased()) and will be deleted now."
    }

    private func setHistory(enabled: Bool) {
        isBusy = true
        let history = self.history
        Task { @MainActor in
            await history.setEnabled(enabled)
            await history.refreshUsage()
            isBusy = false
        }
    }

    private func applyPendingRetention() {
        guard let retention = pendingRetention else { return }
        pendingRetention = nil
        settings.history.retention = retention
        let history = self.history
        Task { @MainActor in await history.applyRetention() }
    }

    private func deleteAll() {
        isBusy = true
        let history = self.history
        Task { @MainActor in
            await history.deleteAll()
            await history.refreshUsage()
            isBusy = false
        }
    }
}

// MARK: - Usage

private struct UsageSection: View {
    let ledger: UsageLedger

    var body: some View {
        Section {
            NavigationLink {
                UsagePage(ledger: ledger)
            } label: {
                LabeledContent("This Month") {
                    Text("\(CostFormatter.short(ledger.thisMonth.costNanos)) · \(UsagePage.replies(ledger.thisMonth.replies))")
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Usage")
        } footer: {
            Text("Estimates at list prices, kept on this iPhone. Your invoice in the Anthropic Console is authoritative.")
        }
    }
}

// MARK: - About

private struct AboutSection: View {
    var body: some View {
        Section {
            if let url = URL(string: "https://console.anthropic.com") {
                Link(destination: url) {
                    Label("Anthropic Console", systemImage: "arrow.up.forward.square")
                }
            }
            if let url = URL(string: "https://www.anthropic.com/legal/privacy") {
                Link(destination: url) {
                    Label("Anthropic Privacy Policy", systemImage: "hand.raised")
                }
            }
        } header: {
            Text("About")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Otto sends your messages and attachments straight to the Anthropic API with your key. Nothing "
                     + "goes anywhere else.")
                Text(Self.versionLine)
                    .monospacedDigit()
            }
        }
    }

    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Otto for iPhone \(version) (\(build))"
    }
}
