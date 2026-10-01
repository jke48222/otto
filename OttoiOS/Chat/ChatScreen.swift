//
//  ChatScreen.swift
//  Otto
//
//  The iPhone chat: a header (Recents, the orb and the model, new chat and ⋮), the transcript or the empty
//  page, and the composer, on the Mac's felt.
//

import SwiftUI
import UIKit

struct ChatScreen: View {
    let model: ChatScreenModel

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(model: model, settings: model.settings)
            Group {
                if model.chat.messages.isEmpty {
                    EmptyChatView(model: model)
                        .contentShape(Rectangle())
                        .onTapGesture { Keyboard.dismiss() }
                } else {
                    ConversationList(model: model)
                        .overlay(alignment: .top) {
                            // The transcript slides under the header softly.
                            LinearGradient(colors: [Theme.panel, Theme.panel.opacity(0)], startPoint: .top,
                                           endPoint: .bottom)
                                .frame(height: 14)
                                .allowsHitTesting(false)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerArea(model: model)
            }
        }
        .background { OttoBackground() }
        .sensoryFeedback(.impact(weight: .light), trigger: model.sendSerial) { _, _ in
            model.settings.mobile.haptics
        }
        .sensoryFeedback(.success, trigger: model.replySerial) { _, _ in
            model.settings.mobile.haptics
        }
    }
}

/// Recents on the left; Otto, its model and the reply's breathing orb in the middle; new chat and ⋮ on the right.
private struct ChatHeader: View {
    let model: ChatScreenModel
    @Bindable var settings: AppSettings

    var body: some View {
        ZStack {
            HStack(spacing: 2) {
                RoundIconButton(symbol: "clock.arrow.circlepath", label: "Recents", diameter: 34, glyphSize: 16) {
                    model.showRecents()
                }
                Spacer(minLength: 0)
                RoundIconButton(symbol: "square.and.pencil", label: "New chat", diameter: 34, glyphSize: 16) {
                    model.newChat()
                }
                moreMenu
            }
            modelMenu
        }
        .padding(.horizontal, 6)
        .frame(height: 52)
    }

    private var modelMenu: some View {
        Menu {
            Picker("Model", selection: $settings.model) {
                ForEach(ModelOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.inline)
            if settings.model.supportsEffort {
                Picker("Effort", selection: $settings.effort) {
                    ForEach(EffortLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.inline)
            }
            Toggle(isOn: $settings.webAccess) {
                Label("Web Search", systemImage: "globe")
            }
        } label: {
            HStack(spacing: 8) {
                OttoOrb(size: 13, isActive: model.chat.isStreaming)
                Text("Otto")
                    .font(.system(size: 19, weight: .medium, design: .serif))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 3) {
                    Text(settings.model.shortName)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(Theme.font(13.5, .medium))
                .foregroundStyle(Theme.textTertiary)
                if model.isDemo {
                    Text("DEMO")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.badgeText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.attention))
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Otto, \(settings.model.displayName)\(model.isDemo ? ", demo mode" : "")")
        .accessibilityHint("Choose the model, effort and web search")
    }

    private var moreMenu: some View {
        Menu {
            Button {
                model.copyLastReply()
            } label: {
                Label("Copy Last Reply", systemImage: "doc.on.doc")
            }
            Button {
                model.regenerate()
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
            .disabled(model.chat.isStreaming || model.chat.lastUserMessage == nil)
            Divider()
            Button {
                model.showSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            VerticalDots(dotSize: 3, spacing: 2)
                .frame(width: 34, height: 34)
                .background(ClaySurface(shape: Circle(), style: .pebble))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }
}

/// Puts the keyboard away from anywhere.
enum Keyboard {
    @MainActor static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
