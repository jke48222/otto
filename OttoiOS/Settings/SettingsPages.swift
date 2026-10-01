//
//  SettingsPages.swift
//  Otto
//
//  The pages Settings pushes: the API key, the model list with prices, custom instructions, the actions
//  activity log and usage totals.
//

import SwiftUI

// MARK: - API key

struct APIKeyPage: View {
    @Bindable var settings: AppSettings

    @State private var draftKey = ""
    @State private var feedback: Feedback?
    @FocusState private var isFieldFocused: Bool

    private enum Feedback: Equatable { case saved, removed, unusual }

    static let keysURL = URL(string: "https://console.anthropic.com/settings/keys")

    var body: some View {
        Form {
            Section {
                SecureField("API Key", text: $draftKey,
                            prompt: Text(settings.apiKey.isEmpty ? "sk-ant-…" : "Paste a new key to replace it"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .focused($isFieldFocused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .onChange(of: draftKey) { _, newValue in
                        if !newValue.isEmpty { feedback = nil }
                    }
                Button("Save Key", action: save)
                    .disabled(trimmedDraft.isEmpty)
                if !settings.apiKey.isEmpty {
                    Button("Remove Key", role: .destructive, action: remove)
                }
            } header: {
                Text("Anthropic API Key")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Label(status.text, systemImage: status.symbol)
                        .foregroundStyle(status.color)
                    Text("Stored in this iPhone's Keychain. Messages go directly to the Anthropic API.")
                }
            }
            if let url = Self.keysURL {
                Section {
                    Link(destination: url) {
                        Label("Get an API Key", systemImage: "arrow.up.forward.square")
                    }
                } footer: {
                    Text("Create a key in the Anthropic Console, copy it, and paste it above.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .navigationTitle("API Key")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var trimmedDraft: String {
        draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Status {
        var symbol: String
        var color: Color
        var text: String
    }

    private var status: Status {
        switch feedback {
        case .saved:
            return Status(symbol: "checkmark.circle.fill", color: .green, text: "Saved to your Keychain.")
        case .removed:
            return Status(symbol: "trash.circle", color: Theme.textTertiary, text: "Key removed.")
        case .unusual:
            return Status(symbol: "exclamationmark.circle.fill", color: .orange,
                          text: "Saved, but Anthropic keys usually start with “sk-ant-”.")
        case nil:
            break
        }
        if !settings.apiKey.isEmpty {
            return Status(symbol: "checkmark.circle.fill", color: .green,
                          text: "Using the key in your Keychain (\(Self.masked(settings.apiKey))).")
        }
        if let error = settings.lastSettingsError {
            return Status(symbol: "exclamationmark.triangle.fill", color: Theme.error, text: error)
        }
        return Status(symbol: "key.fill", color: .orange, text: "Otto needs an API key to chat.")
    }

    /// "sk-ant-…1234".
    static func masked(_ key: String) -> String {
        guard key.count > 12 else { return "••••" }
        return "\(key.prefix(7))…\(key.suffix(4))"
    }

    private func save() {
        let key = trimmedDraft
        guard !key.isEmpty else { return }
        settings.lastSettingsError = nil
        settings.apiKey = key
        guard settings.lastSettingsError == nil else {
            feedback = nil
            return
        }
        draftKey = ""
        isFieldFocused = false
        feedback = key.hasPrefix("sk-ant-") ? .saved : .unusual
    }

    private func remove() {
        settings.lastSettingsError = nil
        settings.apiKey = ""
        draftKey = ""
        feedback = settings.lastSettingsError == nil ? .removed : nil
    }
}

// MARK: - Model

struct ModelPickerPage: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ForEach(ModelOption.allCases) { option in
                    Button {
                        settings.model = option
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.displayName)
                                    .foregroundStyle(Theme.textPrimary)
                                Text(Self.subtitle(for: option))
                                    .font(.footnote)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer(minLength: 8)
                            if settings.model == option {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.orbLight)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(settings.model == option ? .isSelected : [])
                }
            } footer: {
                Text("Otto never switches to a cheaper model on its own.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "Most capable · $5 / $25 per million tokens".
    static func subtitle(for option: ModelOption) -> String {
        guard let price = ModelPricing.price(for: option.rawValue) else { return option.subtitle }
        return "\(option.subtitle) · \(perMillion(price.input)) / \(perMillion(price.output)) per million tokens"
    }

    /// Nano-dollars per token as dollars per million tokens: 5,000 → "$5", 2,500 → "$2.50".
    static func perMillion(_ nanosPerToken: Int64) -> String {
        let cents = nanosPerToken / 10
        if cents % 100 == 0 { return "$\(cents / 100)" }
        return String(format: "$%lld.%02lld", cents / 100, cents % 100)
    }
}

// MARK: - Custom instructions

struct CustomInstructionsPage: View {
    @Bindable var settings: AppSettings
    @FocusState private var isFocused: Bool

    static let placeholder = "e.g. Keep answers short. I write Swift and use British spelling."

    var body: some View {
        Form {
            Section {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $settings.customInstructions)
                        .font(Theme.font(16))
                        .frame(minHeight: 220)
                        .focused($isFocused)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Custom instructions")
                    if settings.customInstructions.isEmpty {
                        Text(Self.placeholder)
                            .font(Theme.font(16))
                            .foregroundStyle(Theme.placeholder)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            } footer: {
                Text("Added to every conversation.")
            }
            if !settings.customInstructions.isEmpty {
                Section {
                    Button("Clear", role: .destructive) {
                        settings.customInstructions = ""
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .navigationTitle("Custom Instructions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isFocused = false }
            }
        }
    }
}

// MARK: - Usage

struct UsagePage: View {
    let ledger: UsageLedger

    @State private var confirmsReset = false

    var body: some View {
        Form {
            Section {
                ForEach(periods, id: \.title) { period in
                    LabeledContent(period.title) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(CostFormatter.short(period.totals.costNanos))
                                .foregroundStyle(Theme.textPrimary)
                            Text(Self.replies(period.totals.replies))
                                .font(.footnote)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .monospacedDigit()
                    }
                }
            } header: {
                Text("Spending")
            }
            let byModel = monthByModel
            if !byModel.isEmpty {
                Section("This Month by Model") {
                    ForEach(byModel, id: \.model) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(CostFormatter.modelName(row.model))
                                Spacer()
                                Text(CostFormatter.dollars(row.totals.costNanos))
                                    .monospacedDigit()
                            }
                            Text("\(CostFormatter.tokens(row.totals.usage.input)) in · "
                                 + "\(CostFormatter.tokens(row.totals.usage.output)) out · "
                                 + "\(row.totals.usage.webSearches) searches")
                                .font(.footnote)
                                .foregroundStyle(Theme.textTertiary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            Section {
                Button("Reset Usage History…", role: .destructive) { confirmsReset = true }
            } footer: {
                Text("Estimates at list prices. Web search is $10 per 1,000 searches. Your invoice in the Anthropic "
                     + "Console is authoritative.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Reset usage history?", isPresented: $confirmsReset) {
            Button("Reset", role: .destructive) { ledger.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes Otto's local usage totals. It doesn't affect your Anthropic account.")
        }
    }

    private struct Period {
        let title: String
        let totals: UsageTotals
    }

    private var periods: [Period] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        return [
            Period(title: "Today", totals: ledger.totals(from: today, to: tomorrow)),
            Period(title: "Yesterday", totals: ledger.totals(from: yesterday, to: today)),
            Period(title: "Last 7 Days", totals: ledger.totals(from: weekStart, to: tomorrow)),
            Period(title: "This Month", totals: ledger.thisMonth),
            Period(title: "All Time", totals: ledger.totals(from: .distantPast, to: .distantFuture)),
        ]
    }

    private var monthByModel: [(model: String, totals: UsageTotals)] {
        guard let month = Calendar.current.dateInterval(of: .month, for: Date()) else { return [] }
        return ledger.totalsByModel(from: month.start, to: month.end)
    }

    static func replies(_ count: Int) -> String {
        count == 1 ? "1 reply" : "\(count.formatted()) replies"
    }
}

// MARK: - Activity log

/// What Otto's actions did, newest first: titles and outcomes only, never what was read or written.
struct ActivityLogPage: View {
    let services: ChatScreenServices

    @State private var entries: [ActionLogEntry] = []
    @State private var isLoaded = false
    @State private var confirmsClear = false

    static let limit = 200

    var body: some View {
        Form {
            if isLoaded, entries.isEmpty {
                Section {
                    EmptyStateView(symbol: "list.bullet.rectangle", title: "No actions yet",
                                   message: "Actions Otto runs, declines or skips show up here.")
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(entries, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(DisplayText.sanitized(entry.summary, maxLength: 160))
                                .foregroundStyle(Theme.textPrimary)
                            Text("\(Self.outcome(of: entry)) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.footnote)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } footer: {
                    Text("Kept as long as History keeps conversations, and cleared with it.")
                }
                if !entries.isEmpty {
                    Section {
                        Button("Clear Activity Log…", role: .destructive) { confirmsClear = true }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .navigationTitle("Activity Log")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            entries = await services.recentActions(Self.limit)
            isLoaded = true
        }
        .confirmationDialog("Clear the activity log?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                Task { @MainActor in
                    await services.clearActionLog()
                    entries = await services.recentActions(Self.limit)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// "Added", "You declined", "Blocked"…
    static func outcome(of entry: ActionLogEntry) -> String {
        switch entry.decision {
        case "declined": return "You declined"
        case "blocked", "blocked_synthetic_input": return "Blocked"
        case "limit": return "Over the limit"
        case "timed_out": return "No answer"
        case "cancelled": return "Stopped"
        default:
            if entry.outcome == "ok" { return entry.decision == "consent" ? "Read" : "Done" }
            if entry.outcome.hasPrefix("error:") { return "Didn't finish" }
            return "Not run"
        }
    }
}
