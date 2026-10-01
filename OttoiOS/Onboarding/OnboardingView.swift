//
//  OnboardingView.swift
//  Otto
//
//  The first launch: what Otto does on iPhone, the API key (kept in the Keychain), and a way to try the demo
//  first. Leaving with neither is fine too; the empty chat says how to add a key later.
//

import SwiftUI

struct OnboardingView: View {
    @Bindable var settings: AppSettings
    let onFinish: () -> Void

    @State private var draftKey = ""
    @State private var error: String?
    @FocusState private var isKeyFocused: Bool

    private var trimmedKey: String { draftKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.top, 56)
                features
                    .padding(.top, 36)
                keyCard
                    .padding(.top, 32)
                secondaryActions
                    .padding(.top, 18)
                    .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { OttoBackground() }
        .preferredColorScheme(.dark)
        .tint(Theme.orbLight)
        .interactiveDismissDisabled()
    }

    private var header: some View {
        VStack(spacing: 14) {
            OttoOrb(size: 52, isActive: true)
                .padding(.bottom, 6)
            Text("Otto")
                .font(.system(size: 42, weight: .regular, design: .serif))
                .foregroundStyle(Theme.textPrimary)
            Text("Claude, one tap away on your iPhone.")
                .font(Theme.font(17))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 18) {
            FeatureRow(symbol: "text.bubble", title: "Ask anything",
                       detail: "Type, or attach photos, a camera shot or files.")
            FeatureRow(symbol: "mic", title: "Talk to it",
                       detail: "Hold the mic to ask out loud, and have replies read back.")
            FeatureRow(symbol: "iphone.gen3", title: "Keeps going when you leave",
                       detail: "Follow a reply in the Dynamic Island and on the Lock Screen.")
            FeatureRow(symbol: "lock", title: "Yours alone",
                       detail: "Your key stays in the Keychain and chats stay on this iPhone.")
        }
    }

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add your Anthropic API key")
                .font(Theme.font(16, .semibold))
                .foregroundStyle(Theme.textPrimary)
            SecureField("API Key", text: $draftKey, prompt: Text("sk-ant-…").foregroundStyle(Theme.placeholder))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                .font(Theme.font(16))
                .focused($isKeyFocused)
                .submitLabel(.done)
                .onSubmit(saveKey)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        }
                }
                .onChange(of: draftKey) { _, _ in error = nil }
            if let error {
                Text(error)
                    .font(Theme.font(13.5))
                    .foregroundStyle(Theme.error)
            }
            Button(action: saveKey) {
                Text("Continue")
                    .font(Theme.font(16, .semibold))
                    .foregroundStyle(trimmedKey.isEmpty ? Theme.sendDisabledGlyph : Theme.sendGlyph)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(trimmedKey.isEmpty
                                  ? AnyShapeStyle(Color.white.opacity(0.08))
                                  : AnyShapeStyle(LinearGradient(colors: [Theme.sendTop, Theme.sendBottom],
                                                                 startPoint: .top, endPoint: .bottom)))
                    }
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.98))
            .disabled(trimmedKey.isEmpty)
            if let url = APIKeyPage.keysURL {
                Link(destination: url) {
                    HStack(spacing: 5) {
                        Text("Get a key in the Anthropic Console")
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(Theme.font(14, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minHeight: 36)
                }
            }
        }
        .padding(18)
        .clay(cornerRadius: 22, style: .tray)
    }

    private var secondaryActions: some View {
        VStack(spacing: 6) {
            Button {
                settings.mobile.demoMode = true
                onFinish()
            } label: {
                Text("Try the Demo First")
                    .font(Theme.font(15.5, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            Button("Not Now") {
                onFinish()
            }
            .font(Theme.font(14.5))
            .foregroundStyle(Theme.textTertiary)
            .frame(minHeight: 44)
        }
    }

    private func saveKey() {
        let key = trimmedKey
        guard !key.isEmpty else { return }
        settings.lastSettingsError = nil
        settings.apiKey = key
        if let failure = settings.lastSettingsError {
            error = failure
            return
        }
        isKeyFocused = false
        onFinish()
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Theme.orbLight)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.font(16, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.font(14.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
