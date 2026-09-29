//
//  ComposerGateLine.swift
//  Otto
//
//  The line above the composer that says why sending is paused and offers up to two ways forward
//  (§14.10.1). A message too long for one line beside its choices wraps to a second line rather than losing
//  its end (the part that usually says what is paused); the symbol and the choices then stay on the first line's
//  baseline. It is driven only by a ComposerGate value and an attention counter, so it compiles in every flavor;
//  only the paid build ever has a gate to show.
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

    /// The height of a one-line gate; a message that wraps grows the line to `maxHeight`.
    static let height: CGFloat = 30
    /// Two lines of the 12 pt message plus its 4 pt margins, with room to spare (a bound, not a size: the line is
    /// as tall as its message). Beyond two lines the message truncates.
    static let maxHeight: CGFloat = 44
    static let messageLineLimit = 2
    static let horizontalPadding: CGFloat = 16
    /// The primary choice: the permission card's off-white capsule at its small size (`InlineAction`).
    static let primaryHeight: CGFloat = InlineAction.primaryHeight
    /// Between the two choices. The text button carries 4 pt of padding inside its hit area, so the capsule and the
    /// secondary title sit 8 pt apart.
    static let choiceSpacing: CGFloat = 4
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
        // Everything hangs on the message's first baseline: one line reads as one axis, and a wrapped message keeps
        // its symbol and its choices level with its first line instead of centered on the pair.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: gate.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text(gate.message)
                    .font(Theme.font(12))
                    .foregroundStyle(isPulsing ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(Self.messageLineLimit)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(for: gate))

            HStack(alignment: .firstTextBaseline, spacing: Self.choiceSpacing) {
                ForEach(Array(Self.orderedChoices(gate).enumerated()), id: \.offset) { _, choice in
                    choiceButton(choice)
                }
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        // 4 pt: a wrapped line's capsule, level with the first line, keeps clear of the hairline above.
        .padding(.vertical, 4)
        // At least one line's height, else just what the (at most two-line) message needs: never more, even when
        // the stack around it offers more.
        .frame(maxWidth: .infinity, minHeight: Self.height)
        .fixedSize(horizontal: false, vertical: true)
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
            InlineAction.PrimaryCapsule(title: choice.title) { onChoice(choice) }
        case .text:
            InlineAction.TextButton(title: choice.title) { onChoice(choice) }
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
}
