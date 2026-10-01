//
//  RootView.swift
//  Otto
//
//  The window's content: the chat, with Recents and Settings as sheets, the first-run welcome over it until
//  there is a key (or the demo), and the question the mic asks before its first use.
//

import SwiftUI

struct RootView: View {
    let composition: MobileComposition

    var body: some View {
        RootContent(model: composition.model, settings: composition.settings, isDemo: composition.isDemo)
    }
}

private struct RootContent: View {
    @Bindable var model: ChatScreenModel
    let settings: AppSettings
    let isDemo: Bool

    /// The welcome shows on first launch until it is finished, unless a key (or the demo) is already there.
    private var showsOnboarding: Binding<Bool> {
        Binding(
            get: { !settings.mobile.didFinishOnboarding && !settings.hasAPIKey && !isDemo },
            set: { presented in
                if !presented { settings.mobile.didFinishOnboarding = true }
            }
        )
    }

    var body: some View {
        ChatScreen(model: model)
            .sheet(item: $model.sheet) { sheet in
                switch sheet {
                case .recents:
                    RecentsScreen(model: model)
                case .settings:
                    SettingsScreen(model: model)
                }
            }
            .fullScreenCover(isPresented: showsOnboarding) {
                OnboardingView(settings: settings) {
                    settings.mobile.didFinishOnboarding = true
                }
            }
            .alert("Talk to Otto?", isPresented: voiceConsentShown) {
                Button("Turn On Voice") { model.acceptVoiceConsent() }
                Button("Not Now", role: .cancel) { model.declineVoiceConsent() }
            } message: {
                Text(Self.voiceConsentMessage)
            }
            .preferredColorScheme(.dark)
            .tint(Theme.orbLight)
    }

    static let voiceConsentMessage = "Otto listens only while you hold or tap the mic. Your words are turned into "
        + "text on your iPhone, then sent to Claude like a typed question. You can turn voice off in Settings."

    private var voiceConsentShown: Binding<Bool> {
        Binding(
            get: { model.voiceConsent != nil },
            set: { shown in
                if !shown, model.voiceConsent != nil { model.declineVoiceConsent() }
            }
        )
    }
}
