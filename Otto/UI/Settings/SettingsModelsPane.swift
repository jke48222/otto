//
//  SettingsModelsPane.swift
//  Otto
//
//  Settings → Models: the Anthropic API key, the model and response style, web access, the cost label on
//  replies, and what Otto's replies have cost so far (local estimates at list prices).
//

import SwiftUI

struct SettingsModelsPane: View {
    @Bindable var settings: AppSettings
    let services: SettingsServices

    var body: some View {
        SettingsPane(tab: .models, settings: settings) {
            SettingsAPIKeySection(settings: settings)
            modelSection
            Section {
                Toggle(isOn: $settings.webAccess) {
                    labeled("Web search & fetch", "Let Claude look things up and read pages.")
                }
                Toggle(isOn: Bindable(settings.usage).showCost) {
                    labeled("Show cost on replies", "An estimate appears next to a reply when you point at it.")
                }
            }
            SettingsUsageSection(ledger: services.ledger)
                .id(SettingsAnchor.usage.rawValue)
        }
    }

    // MARK: Model

    private var modelSection: some View {
        Section("Model") {
            Picker("Model", selection: $settings.model) {
                ForEach(ModelOption.allCases) { option in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.displayName)
                        Text(Self.subtitle(for: option))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            SettingsCaption("Otto never switches to a cheaper model on its own.")

            VStack(alignment: .leading, spacing: 6) {
                Picker("Response style", selection: $settings.effort) {
                    ForEach(EffortLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.model.supportsEffort)

                SettingsCaption(effortCaption)
            }
        }
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
}

// MARK: - API key

/// The API key field, moved from the single-page Settings without changes to its behavior.
private struct SettingsAPIKeySection: View {
    @Bindable var settings: AppSettings

    @Environment(\.settingsOpenExternal) private var openExternal
    @State private var draftKey = ""
    @State private var keyFeedback: KeyFeedback?
    @FocusState private var isKeyFieldFocused: Bool

    var body: some View {
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
                if let url = SettingsLinks.apiKeys {
                    Button("Get an API key") { openExternal(url) }
                        .buttonStyle(.link)
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
                text: "Saved, but Anthropic keys usually start with “sk-ant-”."
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
}

// MARK: - Usage

/// Totals from the local usage ledger: by period, and by model for this month.
private struct SettingsUsageSection: View {
    let ledger: UsageLedger

    @Environment(\.settingsOpenExternal) private var openExternal
    @State private var confirmsReset = false

    var body: some View {
        Section("Usage") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(periods, id: \.title) { period in
                    GridRow {
                        Text(period.title)
                        Text(CostFormatter.short(period.totals.costNanos))
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                        Text(Self.replies(period.totals.replies))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            let byModel = monthByModel
            if !byModel.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This month by model")
                    Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("Model").gridColumnAlignment(.leading)
                            Text("Input")
                            Text("Output")
                            Text("Cache")
                            Text("Searches")
                            Text("Cost")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ForEach(byModel, id: \.model) { row in
                            GridRow {
                                Text(CostFormatter.modelName(row.model))
                                    .lineLimit(1)
                                    .gridColumnAlignment(.leading)
                                Text(CostFormatter.tokens(row.totals.usage.input))
                                Text(CostFormatter.tokens(row.totals.usage.output))
                                Text(CostFormatter.tokens(Self.cacheTokens(row.totals.usage)))
                                Text("\(row.totals.usage.webSearches)")
                                Text(CostFormatter.dollars(row.totals.costNanos))
                            }
                            .font(.caption)
                            .monospacedDigit()
                        }
                    }
                }
            }

            SettingsCaption("Estimates at list prices (updated \(Self.pricesMonth)). Web search is $10 per 1,000 "
                            + "searches. Your invoice in the Anthropic Console is authoritative.")
            HStack {
                if let url = SettingsLinks.anthropicConsole {
                    Button("Open Anthropic Console") { openExternal(url) }
                }
                Spacer()
                Button("Reset Usage History…") { confirmsReset = true }
            }
        }
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
            Period(title: "Last 7 days", totals: ledger.totals(from: weekStart, to: tomorrow)),
            Period(title: "This month", totals: ledger.thisMonth),
            Period(title: "All time", totals: ledger.totals(from: .distantPast, to: .distantFuture)),
        ]
    }

    private var monthByModel: [(model: String, totals: UsageTotals)] {
        guard let month = Calendar.current.dateInterval(of: .month, for: Date()) else { return [] }
        return ledger.totalsByModel(from: month.start, to: month.end)
    }

    private static func replies(_ count: Int) -> String {
        count == 1 ? "1 reply" : "\(count.formatted()) replies"
    }

    private static func cacheTokens(_ usage: TokenUsage) -> Int {
        UsageArithmetic.add(usage.cacheRead, UsageArithmetic.add(usage.cacheWrite5m, usage.cacheWrite1h))
    }

    /// ModelPricing.asOf ("2026-09") as "September 2026".
    private static var pricesMonth: String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM"
        guard let date = parser.date(from: ModelPricing.asOf) else { return ModelPricing.asOf }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return formatter.string(from: date)
    }
}
