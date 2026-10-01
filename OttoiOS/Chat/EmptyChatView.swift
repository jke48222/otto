//
//  EmptyChatView.swift
//  Otto
//
//  What an empty chat shows: the orb and a greeting, the conversation you can pick back up (Continue), and,
//  without a key, how to get one or try the demo.
//

import SwiftUI

struct EmptyChatView: View {
    let model: ChatScreenModel

    var body: some View {
        let history = model.history
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 14) {
                OttoOrb(size: 34, isActive: false)
                    .padding(.bottom, 4)
                Text(Self.greeting)
                    .font(.system(size: 26, weight: .regular, design: .serif))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .accessibilityElement(children: .combine)

            if model.needsAPIKey {
                KeyNeededCard(model: model)
                    .padding(.top, 28)
                    .padding(.horizontal, 24)
            }
            Spacer(minLength: 24)
            if let continuation = history.continuation {
                ContinueChip(title: continuation.title) {
                    model.continueConversation()
                } onDismiss: {
                    model.dismissContinuation()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: history.continuation?.id)
    }

    static let greeting = "What's on your mind?"

    private var subtitle: String {
        if model.isDemo {
            return "Demo mode: replies are scripted, so you can try Otto without a key."
        }
        return "Ask anything, attach a photo or a file, or hold the mic to talk."
    }
}

/// Without a key the chat can't answer: add one, or try the demo.
private struct KeyNeededCard: View {
    let model: ChatScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.attention)
                Text("Add your Anthropic API key")
                    .font(Theme.font(15.5, .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text("Otto talks to Claude with your own key. It stays in this iPhone's Keychain.")
                .font(Theme.font(14))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ReplyActionButton(title: "Add Key", symbol: "key", isProminent: true) {
                    model.showSettings()
                }
                ReplyActionButton(title: "Try the Demo", symbol: "sparkles") {
                    model.settings.mobile.demoMode = true
                }
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: 420, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
                }
        }
    }
}

/// The last conversation, offered back after a fresh start.
struct ContinueChip: View {
    let title: String
    let onContinue: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onContinue) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Continue")
                            .font(Theme.font(12.5, .medium))
                            .foregroundStyle(Theme.textTertiary)
                        Text(DisplayText.sanitized(title, maxLength: 120))
                            .font(Theme.font(15))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.98))
            .accessibilityLabel("Continue \(DisplayText.sanitized(title, maxLength: 120))")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 44, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.9))
            .accessibilityLabel("Dismiss")
        }
        .clay(cornerRadius: 16, style: .tray)
    }
}
