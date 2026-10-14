//
//  SetappAISection.swift
//  Otto
//
//  Settings → Models → Provider (§19 Setapp AI), shown when the build has a Setapp AI account: Setapp AI or the
//  user's own Anthropic key, and with Setapp AI the member's credit balance, where messages go and what the
//  gateway can do. The pane decides from the account, not from `AIProvider.available`, so snapshots draw it in
//  every build.
//

import SwiftUI

struct SettingsProviderSection: View {
    @Bindable var settings: AppSettings
    let account: any SetappAIAccountModel

    /// Setapp AI first, as `AIProvider.available` lists them in the Setapp build.
    static let providers: [AIProvider] = [.setappAI, .anthropic]

    static let gatewayCaption = "Your messages go to Setapp's AI gateway, run by MacPaw, which passes them to "
        + "Anthropic. Setapp counts credits for each reply."
    static let webSearchCaption = "Web search works with Opus 5 and Sonnet 5."

    var body: some View {
        Section {
            Picker("Provider", selection: providerSelection) {
                ForEach(Self.providers) { provider in
                    let isSelectable = Self.isSelectable(provider, isConfigured: account.isConfigured)
                    VStack(alignment: .leading, spacing: 1) {
                        // A radio row SwiftUI disables dims only its button; the title dims with it, as AppKit's
                        // would. The caption keeps its readable color: it says why.
                        Text(provider.displayName)
                            .foregroundStyle(isSelectable ? Color.primary : Color(nsColor: .disabledControlTextColor))
                        Text(Self.subtitle(for: provider, isConfigured: account.isConfigured))
                            .font(.caption)
                            .foregroundStyle(SettingsTone.secondaryText)
                    }
                    .tag(provider)
                    .selectionDisabled(!isSelectable)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if Self.showsCredits(provider: settings.aiProvider, isConfigured: account.isConfigured) {
                SetappAICreditsRow(account: account)
            }
        } header: {
            Text("Provider")
        } footer: {
            // Where messages go, while they actually go there.
            if Self.showsCredits(provider: settings.aiProvider, isConfigured: account.isConfigured) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.gatewayCaption)
                    Text(Self.webSearchCaption)
                }
                .font(.caption)
                .foregroundStyle(SettingsTone.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: refreshCredits)
        .onChange(of: settings.aiProvider) { _, _ in refreshCredits() }
    }

    /// The radio choice: what answers. A build where Setapp AI isn't set up answers on the user's own key whatever
    /// is stored (`AppSettings.effectiveProvider`), so that row is the one checked.
    private var providerSelection: Binding<AIProvider> {
        Binding(
            get: { Self.shownProvider(stored: settings.aiProvider, isConfigured: account.isConfigured) },
            set: { settings.aiProvider = $0 }
        )
    }

    /// Pure. The provider the radio group checks.
    static func shownProvider(stored: AIProvider, isConfigured: Bool) -> AIProvider {
        isSelectable(stored, isConfigured: isConfigured) ? stored : .anthropic
    }

    /// Pure. The row's caption: what the provider costs, or why Setapp AI can't be picked.
    static func subtitle(for provider: AIProvider, isConfigured: Bool) -> String {
        switch provider {
        case .setappAI:
            return isConfigured ? "Uses your Setapp AI credits. No API key needed." : "Not set up in this build."
        case .anthropic:
            return "Billed to your Anthropic account, per token."
        }
    }

    /// Pure. Setapp AI needs the build's OAuth client (J22); the user's own key can always be picked.
    static func isSelectable(_ provider: AIProvider, isConfigured: Bool) -> Bool {
        provider != .setappAI || isConfigured
    }

    /// Pure. The balance and the gateway captions show while Setapp AI is the provider and can actually be reached.
    static func showsCredits(provider: AIProvider, isConfigured: Bool) -> Bool {
        provider == .setappAI && isConfigured
    }

    /// Loads the balance whenever it is about to show, past the SDK's cache: the member may have spent or bought
    /// credits since Settings last asked.
    private func refreshCredits() {
        guard Self.showsCredits(provider: settings.aiProvider, isConfigured: account.isConfigured) else { return }
        account.refreshCredits(force: true)
    }
}

/// The member's balance under the provider choice: what's left with a quiet bar and Get Credits, a loading line,
/// or why it couldn't load with Try Again and Get Credits.
struct SetappAICreditsRow: View {
    let account: any SetappAIAccountModel

    @Environment(\.settingsOpenExternal) private var openExternal

    static let loadingText = "Loading your credits…"

    /// The row's buttons, in order.
    enum Control: Equatable {
        case tryAgain
        case getCredits
    }

    /// Pure. Get Credits whenever the balance has loaded or failed to (a member who can't see the balance may
    /// still know they're out), with Try Again first after a failure; nothing while it loads.
    static func controls(for state: SetappCreditState) -> [Control] {
        switch state {
        case .idle, .loading: return []
        case .loaded: return [.getCredits]
        case .failed: return [.tryAgain, .getCredits]
        }
    }

    var body: some View {
        switch account.creditState {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(Self.loadingText)
                    .foregroundStyle(SettingsTone.secondaryText)
            }
            .font(.callout)
        case .loaded(let balance):
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(SetappCreditFormatter.summary(balance))
                        .monospacedDigit()
                    if let fraction = balance.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .frame(maxWidth: 260)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                buttons
            }
        case .failed(let copy):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(SettingsTone.warning)
                Text(copy)
                    .foregroundStyle(SettingsTone.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                buttons
            }
            .font(.callout)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            ForEach(Self.controls(for: account.creditState), id: \.self) { control in
                switch control {
                case .tryAgain:
                    Button("Try Again") { account.refreshCredits(force: true) }
                case .getCredits:
                    Button("Get Credits", action: getCredits)
                }
            }
        }
    }

    private func getCredits() {
        let account = account
        let openExternal = openExternal
        Task { await Self.openPurchasePage(of: account, with: openExternal) }
    }

    /// "Get Credits": Setapp's page through Settings' own opener, which drops the floating panel first so the page
    /// doesn't open behind it.
    static func openPurchasePage(of account: any SetappAIAccountModel, with openExternal: SettingsExternalOpener) async {
        openExternal(await account.purchaseURL())
    }
}
