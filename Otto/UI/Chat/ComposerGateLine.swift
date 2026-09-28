//
//  ComposerGateLine.swift
//  Otto
//
//  The one line above the composer that says why sending is paused and offers up to two ways forward
//  (§14.10.1). It is driven only by a ComposerGate value and an attention counter, so it compiles in every
//  flavor; only the paid build ever has a gate to show.
//

import SwiftUI

struct ComposerGateLine: View {
    let gate: ComposerGate
    /// Bumped by every blocked send, regenerate or voice send; each bump pulses the message once.
    let attention: Int
    let onChoice: (ComposerGate.Choice) -> Void

    init(gate: ComposerGate, attention: Int, onChoice: @escaping (ComposerGate.Choice) -> Void) {
        self.gate = gate
        self.attention = attention
        self.onChoice = onChoice
    }

    static let height: CGFloat = 30
    static let horizontalPadding: CGFloat = 16
    /// The primary choice: the permission card's off-white capsule at its small size.
    static let primaryHeight: CGFloat = 22
    /// Out to `Theme.textPrimary` and back, 0.6 s in all.
    static let pulseDuration: Duration = .milliseconds(600)

    enum ChoiceStyle: Equatable {
        /// The send gradient capsule with dark text.
        case primaryCapsule
        /// A plain text button.
        case text
    }

    /// The gate's choices as the line draws them, left to right: the primary first, at most two in all.
    static func orderedChoices(_ gate: ComposerGate) -> [ComposerGate.Choice] {
        let primary = gate.choices.filter(\.isPrimary).prefix(1)
        let others = gate.choices.filter { !$0.isPrimary }
        return Array((primary + others).prefix(2))
    }

    static func style(for choice: ComposerGate.Choice) -> ChoiceStyle {
        choice.isPrimary ? .primaryCapsule : .text
    }

    /// What VoiceOver reads for the line and announces on every blocked attempt.
    static func accessibilityLabel(for gate: ComposerGate) -> String {
        gate.message
    }

    /// The animation of one pulse, or nil when Reduce Motion is on (the message then stays still).
    static func pulseAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : Theme.Motion.content
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false
    @State private var pulseTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: gate.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text(gate.message)
                    .font(Theme.font(12))
                    .foregroundStyle(isPulsing ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(for: gate))

            ForEach(Array(Self.orderedChoices(gate).enumerated()), id: \.offset) { _, choice in
                choiceButton(choice)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .onChange(of: attention) { old, new in
            guard new > old else { return }
            DockCardChrome.announce(Self.accessibilityLabel(for: gate))
            pulse()
        }
        .onChange(of: gate.id) { _, _ in
            DockCardChrome.announce(Self.accessibilityLabel(for: gate))
        }
        .onDisappear {
            pulseTask?.cancel()
            pulseTask = nil
            isPulsing = false
        }
    }

    @ViewBuilder private func choiceButton(_ choice: ComposerGate.Choice) -> some View {
        switch Self.style(for: choice) {
        case .primaryCapsule:
            PrimaryCapsule(title: choice.title) { onChoice(choice) }
        case .text:
            DockCardChrome.TextButton(title: choice.title) { onChoice(choice) }
                .fixedSize()
                .accessibilityLabel(choice.title)
        }
    }

    /// Out to the primary text color and back once. Nothing moves with Reduce Motion.
    private func pulse() {
        guard let animation = Self.pulseAnimation(reduceMotion: reduceMotion) else { return }
        pulseTask?.cancel()
        withAnimation(animation) { isPulsing = true }
        pulseTask = Task { @MainActor in
            try? await Task.sleep(for: Self.pulseDuration / 2)
            guard !Task.isCancelled else { return }
            withAnimation(animation) { isPulsing = false }
        }
    }

    /// The permission card's primary button (the send gradient) at the line's 22 pt size.
    private struct PrimaryCapsule: View {
        let title: String
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(Theme.font(12, .semibold))
                    .foregroundStyle(Theme.sendGlyph)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .frame(height: ComposerGateLine.primaryHeight)
                    .background {
                        Capsule(style: .continuous)
                            .fill(LinearGradient(colors: [Theme.sendTop, Theme.sendBottom],
                                                 startPoint: .top, endPoint: .bottom))
                    }
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.96))
            .accessibilityLabel(title)
        }
    }
}
