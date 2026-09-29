//
//  SettingsPrivacyPane.swift
//  Otto
//
//  Settings → Privacy: local chat history (on or off, how long it is kept, when a new chat starts, where it
//  lives, deleting it), every macOS permission Otto uses with its live status, and the two resets.
//

import SwiftUI

struct SettingsPrivacyPane: View {
    @Bindable var settings: AppSettings
    let services: SettingsServices

    var body: some View {
        SettingsPane(tab: .privacy, settings: settings) {
            SettingsHistorySection(settings: settings, services: services)
            SettingsPermissionsSection(services: services)
                .id(SettingsAnchor.permissions.rawValue)
        }
    }
}

// MARK: - History

private struct SettingsHistorySection: View {
    @Bindable var settings: AppSettings
    let services: SettingsServices

    @Environment(\.settingsOpenExternal) private var openExternal
    @State private var confirmsTurnOff = false
    @State private var confirmsDeleteAll = false
    @State private var pendingRetention: HistoryRetention?
    @State private var pendingRetentionCount = 0
    @State private var fileVault: FileVaultStatus = .unknown
    @State private var isBusy = false

    private var history: HistoryController? { services.history }

    var body: some View {
        Section {
            Toggle(isOn: historyEnabled) {
                labeled("Save chat history", "Keep conversations on this Mac so you can continue them later.")
            }
            Picker("Keep conversations", selection: retention) {
                ForEach(HistoryRetention.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)
            .disabled(!settings.history.enabled)
            Picker("Start a new chat", selection: Bindable(settings.history).idleReset) {
                ForEach(IdleResetInterval.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)
            .disabled(!settings.history.enabled)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(statusLine)
                    .foregroundStyle(SettingsTone.secondaryText)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Button("Show in Finder", action: showInFinder)
                    .disabled(history?.store.rootURL == nil || !settings.history.enabled)
                Button("Delete All History…") { confirmsDeleteAll = true }
                    .disabled(isBusy || !settings.history.enabled || (history == nil && services.actionLog == nil))
            }
            if let newer = history?.storageUsage?.newerVersionCount, newer > 0 {
                SettingsCaption(newer == 1
                    ? "1 conversation was saved by a newer version of Otto and is hidden."
                    : "\(newer) conversations were saved by a newer version of Otto and are hidden.")
            }
            if let error = history?.lastSaveError {
                SettingsCaption(error, color: SettingsTone.error)
            }
            if fileVault == .off {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("FileVault is off, so your history isn't encrypted on disk.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(SettingsTone.warning)
                    Spacer(minLength: 8)
                    if let url = SettingsLinks.fileVault {
                        Button("Open FileVault Settings…") { openExternal(url) }
                            .font(.caption)
                    }
                }
            }
        } header: {
            Text("History")
        } footer: {
            SettingsCaption("Stored only on this Mac in ~/Library/Application Support/Otto. Never uploaded, synced, or "
                            + "used for anything else. Attached files are kept for up to 30 days (1 GB) so a continued "
                            + "chat can send them again; after that Otto keeps only their names and previews. History "
                            + "is excluded from Time Machine and Spotlight.")
        }
        .task {
            guard let history else { return }
            await history.refreshUsage()
            fileVault = await FileVaultStatus.current()
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
            Text("Delete all conversations and the actions activity log from this Mac? This can't be undone.")
        }
        .confirmationDialog("Delete older conversations?", isPresented: retentionConfirmation,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: applyPendingRetention)
            Button("Cancel", role: .cancel) { pendingRetention = nil }
        } message: {
            Text(retentionMessage)
        }
    }

    // MARK: State

    private var savedCount: Int {
        history?.storageUsage?.conversationCount ?? history?.summaries.count ?? 0
    }

    /// "12 conversations · 48.3 MB" / "No saved conversations".
    private var statusLine: String {
        guard let usage = history?.storageUsage, usage.conversationCount > 0 else { return "No saved conversations" }
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
                let affected = history?.countConversations(olderThan: newValue) ?? 0
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

    // MARK: Actions

    private func setHistory(enabled: Bool) {
        guard let history else {
            settings.history.enabled = enabled
            return
        }
        isBusy = true
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
        guard let history else { return }
        Task { @MainActor in await history.applyRetention() }
    }

    private func deleteAll() {
        isBusy = true
        let history = self.history
        let log = services.actionLog
        Task { @MainActor in
            if let history {
                // Deleting history reports `.all`, which clears the activity log and delivered notifications.
                await history.deleteAll()
                await history.refreshUsage()
            } else if let log {
                do {
                    try await log.clear()
                } catch {
                    settings.lastSettingsError = "Couldn't clear the activity log: \(error.localizedDescription)"
                }
            }
            isBusy = false
        }
    }

    private func showInFinder() {
        guard let root = history?.store.rootURL else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            settings.lastSettingsError = "Couldn't open the history folder: \(error.localizedDescription)"
            return
        }
        openExternal(root)
    }
}

// MARK: - Permissions

private struct SettingsPermissionsSection: View {
    let services: SettingsServices

    @State private var confirmsResetApprovals = false
    @State private var confirmsResetSystem = false
    @State private var isResettingSystem = false
    @State private var resetFailed = false

    var body: some View {
        Section {
            ForEach(Permission.systemWide + services.permissions.knownAutomationTargets, id: \.self) { permission in
                PermissionRow(permission: permission)
            }
            HStack {
                Button("Reset Otto's Approvals…") { confirmsResetApprovals = true }
                Spacer()
                Button("Reset macOS Permissions for Otto…") { confirmsResetSystem = true }
                    .disabled(services.processRunner == nil || isResettingSystem)
            }
            if resetFailed {
                SettingsCaption("macOS didn't reset Otto's permissions. You can switch them off in System Settings → "
                                + "Privacy & Security.", color: SettingsTone.error)
            }
        } header: {
            Text("Permissions")
        } footer: {
            SettingsCaption("Otto asks for a permission the first time a feature needs it and explains why first.")
        }
        .task { await services.permissions.refreshAll() }
        .alert("Reset Otto's approvals?", isPresented: $confirmsResetApprovals) {
            Button("Reset", role: .destructive) { services.approvals.revokeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Otto forgets the shortcuts you always allowed and what you let it read, and asks again next time. "
                 + "macOS permissions stay as they are.")
        }
        .alert("Reset macOS permissions for Otto?", isPresented: $confirmsResetSystem) {
            Button("Reset Permissions", role: .destructive, action: resetSystemPermissions)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS forgets every permission it gave Otto, from Accessibility to the microphone. Otto asks again "
                 + "when a feature needs one.")
        }
    }

    private func resetSystemPermissions() {
        guard let runner = services.processRunner else { return }
        isResettingSystem = true
        resetFailed = false
        let permissions = services.permissions
        Task { @MainActor in
            let succeeded = await permissions.resetSystemPermissions(using: runner)
            resetFailed = !succeeded
            isResettingSystem = false
        }
    }
}
