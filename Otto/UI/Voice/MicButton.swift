//
//  MicButton.swift
//  Otto
//
//  The composer's mic. A quick click toggles listening; holding it for 300 ms or more talks until release,
//  through the same HoldGestureMachine as the global shortcut. At rest it is a ghost button like the +;
//  while listening it becomes a warm disc with a ring that swells with the microphone level. Everything it
//  does goes out through closures, so the owner decides what a tap or a hold means in each state.
//

import SwiftUI

struct MicButton: View {
    /// Diameter of the button and of its active disc.
    static let size: CGFloat = 30
    static let accessibilityLabel = "Talk to Otto"
    static let voiceSettingsTitle = "Voice Settings…"

    /// How the button looks and answers in one `MicState` (pure, tested).
    struct Presentation: Equatable, Sendable {
        enum Look: Equatable, Sendable {
            /// A glyph on no surface (off, ready).
            case ghost
            /// The warm disc with the level ring (listening).
            case active
            /// The warm disc with a spinner (finishing).
            case finishing
            /// `mic.slash` in tertiary; a click shows why.
            case unavailable
        }

        let look: Look
        /// SF Symbol; nil while finishing (a spinner shows instead).
        let symbolName: String?
        let accessibilityValue: String
        let accessibilityHint: String
        let help: String
        /// A press may become a hold (only when listening can start right away). Otherwise a press is a tap
        /// the moment it lands.
        let allowsHold: Bool
        /// Presses and the accessibility action do anything at all.
        let acceptsPress: Bool

        init(state: MicState) {
            switch state {
            case .off:
                look = .ghost
                symbolName = "mic"
                accessibilityValue = "Voice is off"
                accessibilityHint = "Double-tap to set up voice"
                help = "Talk to Otto"
                allowsHold = false
                acceptsPress = true
            case .ready:
                look = .ghost
                symbolName = "mic"
                accessibilityValue = ""
                accessibilityHint = "Double-tap to start listening, again to send"
                help = "Talk to Otto: hold to talk, or click to start and click again to send"
                allowsHold = true
                acceptsPress = true
            case .listening:
                look = .active
                symbolName = "mic.fill"
                accessibilityValue = "Listening"
                accessibilityHint = "Double-tap to send"
                help = "Click to send what you said"
                allowsHold = false
                acceptsPress = true
            case .finishing:
                look = .finishing
                symbolName = nil
                accessibilityValue = "Finishing"
                accessibilityHint = ""
                help = "Finishing…"
                allowsHold = false
                acceptsPress = false
            case .unavailable(let reason):
                look = .unavailable
                symbolName = "mic.slash"
                accessibilityValue = Self.unavailableText(reason)
                accessibilityHint = "Double-tap to see how to fix it"
                help = Self.unavailableText(reason)
                allowsHold = false
                acceptsPress = true
            }
        }

        static func unavailableText(_ reason: VoiceUnavailableReason) -> String {
            switch reason {
            case .microphoneDenied: return "Otto isn't allowed to use the microphone"
            case .speechDenied: return "Otto isn't allowed to use Speech Recognition"
            case .noInputDevice: return "No microphone is connected"
            case .recognizerUnavailable(let localeName): return "Speech recognition for \(localeName) isn't available"
            case .dictationDisabled: return "Dictation is off"
            }
        }
    }

    let state: MicState
    /// The live level for the active ring; read directly on each frame, never observed.
    let meter: AudioLevelMeter
    /// A click (or a press that ended before 300 ms, or the accessibility action).
    let onTap: () -> Void
    /// A press held for 300 ms or more; only when `state == .ready`.
    let onHoldBegan: () -> Void
    /// The release that ends a hold (also sent if the button disappears mid-hold).
    let onHoldEnded: () -> Void
    /// "Voice Settings…" from the right-click menu or the accessibility action.
    let onOpenVoiceSettings: () -> Void

    init(state: MicState, meter: AudioLevelMeter, onTap: @escaping () -> Void,
         onHoldBegan: @escaping () -> Void, onHoldEnded: @escaping () -> Void,
         onOpenVoiceSettings: @escaping () -> Void) {
        self.state = state
        self.meter = meter
        self.onTap = onTap
        self.onHoldBegan = onHoldBegan
        self.onHoldEnded = onHoldEnded
        self.onOpenVoiceSettings = onOpenVoiceSettings
    }

    @State private var machine = HoldGestureMachine(holdEnabled: true, holdThreshold: VoiceMetrics.holdThreshold)
    @State private var holdCheckTask: Task<Void, Never>?
    /// The drag gesture reports every pointer move; only its first event is the press.
    @State private var isPointerDown = false
    @State private var isHovering = false

    private var presentation: Presentation { Presentation(state: state) }

    var body: some View {
        let presentation = self.presentation
        face(presentation)
            .frame(width: Self.size, height: Self.size)
            .contentShape(Circle())
            .scaleEffect(isPointerDown && presentation.acceptsPress ? 0.94 : 1)
            .animation(Theme.Motion.press, value: isPointerDown)
            .animation(Theme.Motion.press, value: presentation.look)
            .onHover { isHovering = $0 }
            .gesture(pressGesture)
            .contextMenu {
                Button(Self.voiceSettingsTitle, action: onOpenVoiceSettings)
            }
            .help(presentation.help)
            .onDisappear(perform: abandonPress)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Self.accessibilityLabel)
            .accessibilityValue(presentation.accessibilityValue)
            .accessibilityHint(presentation.accessibilityHint)
            .accessibilityAction {
                // VoiceOver and Switch Control can't hold, so their action is always the toggle.
                if presentation.acceptsPress { onTap() }
            }
            .accessibilityAction(named: Self.voiceSettingsTitle, onOpenVoiceSettings)
    }

    // MARK: - Faces

    @ViewBuilder
    private func face(_ presentation: Presentation) -> some View {
        switch presentation.look {
        case .ghost, .unavailable:
            glyph(presentation.symbolName, size: 13, weight: .regular,
                  color: presentation.look == .unavailable ? Theme.textTertiary : Color.white.opacity(0.78))
                .frame(width: Self.size, height: Self.size)
                .background {
                    Circle().fill(Color.white.opacity(isPointerDown ? 0.04 : (isHovering ? 0.07 : 0)))
                }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        case .active:
            glyph(presentation.symbolName, size: 12, weight: .medium, color: Theme.sendGlyph)
                .frame(width: Self.size, height: Self.size)
                .background { VoiceMicDisc() }
                .background { VoiceMicLevelRing(meter: meter) }
        case .finishing:
            ProgressView()
                .controlSize(.small)
                .frame(width: Self.size, height: Self.size)
                .background { VoiceMicDisc() }
        }
    }

    @ViewBuilder
    private func glyph(_ name: String?, size: CGFloat, weight: Font.Weight, color: Color) -> some View {
        if let name {
            Image(systemName: name)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(color)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    // MARK: - Press and hold

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPointerDown else { return }
                isPointerDown = true
                press()
            }
            .onEnded { _ in
                isPointerDown = false
                release()
            }
    }

    private func press() {
        let presentation = self.presentation
        guard presentation.acceptsPress else { return }
        // Decided per press: only a ready mic can start a hold; any other state acts at once.
        machine.holdEnabled = presentation.allowsHold
        perform(machine.press(at: Self.now()))
    }

    private func release() {
        holdCheckTask?.cancel()
        holdCheckTask = nil
        perform(machine.release(at: Self.now()))
    }

    /// The button went away mid-press (the composer was replaced): a hold ends as if released, a pending
    /// press is dropped.
    private func abandonPress() {
        holdCheckTask?.cancel()
        holdCheckTask = nil
        isPointerDown = false
        let wasHolding = machine.isHolding
        machine.reset()
        if wasHolding { onHoldEnded() }
    }

    private func perform(_ outputs: [HoldGestureMachine.Output]) {
        for output in outputs {
            switch output {
            case .tap: onTap()
            case .holdBegan: onHoldBegan()
            case .holdEnded: onHoldEnded()
            case .scheduleHoldCheck(let deadline): scheduleHoldCheck(at: deadline)
            }
        }
    }

    private func scheduleHoldCheck(at deadline: TimeInterval) {
        holdCheckTask?.cancel()
        let delay = max(0, deadline - Self.now())
        holdCheckTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            holdCheckTask = nil
            perform(machine.holdCheck(at: max(deadline, Self.now())))
        }
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// The warm send-button disc the mic becomes while listening.
private struct VoiceMicDisc: View {
    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Theme.sendTop, Theme.sendBottom], startPoint: .top, endPoint: .bottom))
            .overlay {
                Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
    }
}

/// The soft ring behind the disc, scaled 1 + 0.35 × the current level. Reads the meter on each frame.
private struct VoiceMicLevelRing: View {
    let meter: AudioLevelMeter

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            let level = CGFloat(meter.currentLevel)
            Circle()
                .fill(Theme.orbLight.opacity(0.25))
                .scaleEffect(1 + 0.35 * min(max(level, 0), 1))
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: level)
        }
        .allowsHitTesting(false)
    }
}
