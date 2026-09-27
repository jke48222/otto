//
//  SettingsActionsPane.swift
//  Otto
//
//  Settings → Actions: the master switch for Claude's tools, one row per tool group, how many steps one
//  reply may take, how strictly Otto asks, what is always allowed, and the local activity log.
//

import SwiftUI

struct SettingsActionsPane: View {
    @Bindable var settings: AppSettings
    let services: SettingsServices

    @State private var confirmsAppleScript = false
    @State private var confirmsFewerPrompts = false
    @State private var showsActivityLog = false

    var body: some View {
        SettingsPane(tab: .actions, settings: settings) {
            masterSection
            if settings.actions.enabled {
                safetySection
            }
            approvalsSection
                .id(SettingsAnchor.approvals.rawValue)
        }
        .alert("Let Otto write and run AppleScript?", isPresented: $confirmsAppleScript) {
            Button("Turn On") { SettingsFeatureToggle.toolGroup(.appleScript).store(true, in: settings) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("AppleScript can control almost any app on your Mac: read files, send messages, change settings. "
                 + "Otto shows you every script and waits for you to run it. Only approve scripts you understand. "
                 + "Scripts run with the access you've given Otto (for example Accessibility), so macOS won't ask again.")
        }
        .alert("Ask less often?", isPresented: $confirmsFewerPrompts) {
            Button("Use Fewer Prompts", role: .destructive) { settings.actionSafetyMode = .fewerPrompts }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A web page Otto reads can hide instructions written to trick it. With fewer prompts, a shortcut "
                 + "you always allow can run after Otto reads one, and Otto no longer pauses on web content. "
                 + "AppleScript still asks every time.")
        }
        .sheet(isPresented: $showsActivityLog) {
            SettingsActivityLogSheet(log: services.actionLog, isPresented: $showsActivityLog)
        }
    }

    // MARK: Master switch and groups

    private var masterSection: some View {
        Section {
            Toggle(isOn: Bindable(settings.actions).enabled.animation(.spring(duration: 0.3))) {
                labeled("Let Otto take actions",
                        "Check your calendar, add reminders, run shortcuts and more. You approve anything that changes something.")
            }
            if settings.actions.enabled {
                ForEach(ToolGroup.allCases, id: \.self) { group in
                    groupRow(group)
                }
                Stepper(value: Bindable(settings.actions).maxToolRounds, in: ActionSettings.maxToolRoundsRange) {
                    Text("Stop after \(settings.actions.maxToolRounds) steps in one reply")
                        .monospacedDigit()
                }
            }
        }
    }

    private func groupRow(_ group: ToolGroup) -> some View {
        Toggle(isOn: groupBinding(group)) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: group.symbol)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    labeled(group.displayName, Self.detail(for: group))
                    let permissions = groupPermissions(group)
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

    private func groupBinding(_ group: ToolGroup) -> Binding<Bool> {
        let toggle = SettingsFeatureToggle.toolGroup(group)
        return Binding(
            get: { toggle.isOn(in: settings) },
            set: { isOn in
                if group == .appleScript, isOn {
                    confirmsAppleScript = true
                } else {
                    toggle.store(isOn, in: settings)
                }
            }
        )
    }

    /// Calendar and Reminders show their privacy permission; Music & media shows the players Otto has asked about.
    private func groupPermissions(_ group: ToolGroup) -> [Permission] {
        guard group == .media else { return SettingsFeatureToggle.toolGroup(group).displayedPermissions }
        let players = Set(MediaPlayer.allCases.map(\.rawValue))
        return services.permissions.knownAutomationTargets.filter { permission in
            if case .automation(let bundleID, _) = permission { return players.contains(bundleID) }
            return false
        }
    }

    static func detail(for group: ToolGroup) -> String {
        switch group {
        case .calendar: return "Read and add events"
        case .reminders: return "Read and add reminders"
        case .shortcuts: return "Run your shortcuts"
        case .media: return "Play, pause and skip in Music and Spotify"
        case .links: return "Open web pages in your browser"
        case .appleScript: return "Advanced. Every script needs your approval."
        }
    }

    // MARK: Safety

    private var safetySection: some View {
        Section("How Otto Asks") {
            Picker("How Otto asks", selection: safetyMode) {
                ForEach(ActionSafetyMode.allCases, id: \.self) { mode in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.title(for: mode))
                        Text(Self.consequence(for: mode))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private var safetyMode: Binding<ActionSafetyMode> {
        Binding(
            get: { settings.actionSafetyMode },
            set: { mode in
                if mode == .fewerPrompts, settings.actionSafetyMode != .fewerPrompts {
                    confirmsFewerPrompts = true
                } else {
                    settings.actionSafetyMode = mode
                }
            }
        )
    }

    static func title(for mode: ActionSafetyMode) -> String {
        switch mode {
        case .safer: return "Safer"
        case .fewerPrompts: return "Fewer prompts"
        }
    }

    static func consequence(for mode: ActionSafetyMode) -> String {
        switch mode {
        case .safer:
            return "Otto asks again once it has read a web page in the chat, and pauses before acting on web content."
        case .fewerPrompts:
            return "Shortcuts you always allow run even after Otto reads a web page. AppleScript still asks every time."
        }
    }

    // MARK: Approvals

    private var approvalsSection: some View {
        Section("Approvals") {
            if services.approvals.remembered.isEmpty {
                SettingsCaption("No shortcuts are always allowed.")
            } else {
                ForEach(services.approvals.remembered) { approval in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DisplayText.sanitized(approval.scope.label, maxLength: 80))
                            Text("Allowed \(approval.grantedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Remove") { services.approvals.revoke(approval.id) }
                    }
                }
            }
            SettingsCaption("Runs without asking only when the shortcut's input comes from your own message, and "
                            + "never in a chat where Otto read a web page.")

            ForEach(services.approvals.consents, id: \.rawValue) { consent in
                HStack {
                    Text(consent.label)
                    Spacer(minLength: 8)
                    Button("Revoke") { services.approvals.revokeConsent(consent) }
                }
            }

            Button("Activity Log…") { showsActivityLog = true }

            Toggle(isOn: Bindable(settings.actions).logFullScripts) {
                labeled("Keep full scripts in the activity log",
                        "Otherwise the log keeps the first 200 characters and a fingerprint.")
            }
        }
    }
}

// MARK: - Activity log

/// The local activity log, newest first, with Reveal in Finder and Clear Log.
private struct SettingsActivityLogSheet: View {
    let log: ActionLog?
    @Binding var isPresented: Bool

    @Environment(\.settingsOpenExternal) private var openExternal
    @State private var entries: [ActionLogEntry] = []
    @State private var isLoaded = false
    @State private var confirmsClear = false
    @State private var clearError: String?

    private static let limit = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity Log")
                .font(.headline)
            Group {
                if log == nil {
                    placeholder("The activity log isn't kept in this mode.")
                } else if !isLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    placeholder("Nothing yet. Every action Otto takes or asks about is listed here.")
                } else {
                    List(entries, id: \.id) { entry in
                        entryRow(entry)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minHeight: 280)

            if let clearError {
                SettingsCaption(clearError, color: .red)
            }
            SettingsCaption("The log keeps what ran and how it ended, never your messages or the results.")
            HStack {
                Button("Reveal in Finder", action: reveal)
                    .disabled(log == nil)
                Button("Clear Log…") { confirmsClear = true }
                    .disabled(log == nil || entries.isEmpty)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
        .task { await load() }
        .alert("Clear the activity log?", isPresented: $confirmsClear) {
            Button("Clear Log", role: .destructive) { Task { await clear() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the record of every action on this Mac.")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func entryRow(_ entry: ActionLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(DisplayText.sanitized(entry.summary, maxLength: 120))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(Self.details(for: entry))
                .font(.caption)
                .foregroundStyle(entry.outcome == "ok" ? Color.secondary : Color.orange)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    /// "run_shortcut · approved · ok · from your message".
    private static func details(for entry: ActionLogEntry) -> String {
        var parts = [entry.tool, entry.decision.replacingOccurrences(of: "_", with: " "), entry.outcome]
        if let provenance = entry.provenance, !provenance.isEmpty {
            parts.append(DisplayText.sanitized(provenance, maxLength: 60))
        }
        if entry.caution { parts.append("caution") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let log else { return }
        entries = await log.recent(limit: Self.limit)
        isLoaded = true
    }

    private func clear() async {
        guard let log else { return }
        do {
            try await log.clear()
            clearError = nil
            entries = []
        } catch {
            clearError = "Couldn't clear the log: \(error.localizedDescription)"
        }
    }

    private func reveal() {
        guard log != nil, let folder = try? AppSupport.directory(.logs) else { return }
        let file = folder.appendingPathComponent(ActionLog.fileName)
        openExternal(FileManager.default.fileExists(atPath: file.path) ? file : folder)
    }
}
