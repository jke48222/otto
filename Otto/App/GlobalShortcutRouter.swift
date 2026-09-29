//
//  GlobalShortcutRouter.swift
//  Otto
//
//  Turns the global shortcut's press and release into a tap or a hold. With hold-to-talk off a tap acts on
//  press (no added latency); with it on, a press held for 300 ms or more begins a hold and its release ends
//  it, and any other press is a tap on release (a release that beats a late hold check included).
//

import Foundation

/// The pure core: feed it press/holdCheck/release with a timestamp, perform what it returns.
struct HoldGestureMachine: Equatable {
    enum Output: Equatable { case tap, holdBegan, holdEnded, scheduleHoldCheck(at: TimeInterval) }

    var holdThreshold: TimeInterval
    var holdEnabled: Bool
    /// When the key went down; nil while it is up.
    private(set) var pressedAt: TimeInterval?
    private(set) var isHolding = false
    /// The press already produced its tap (hold disabled at press time), so its release does nothing.
    private var tappedOnPress = false

    init(holdEnabled: Bool = false, holdThreshold: TimeInterval = 0.3) {
        self.holdEnabled = holdEnabled
        self.holdThreshold = holdThreshold
    }

    /// Hold enabled: `[.scheduleHoldCheck(now + threshold)]`; disabled: `[.tap]` at once. A press while already
    /// down is ignored.
    mutating func press(at now: TimeInterval) -> [Output] {
        guard pressedAt == nil else { return [] }
        pressedAt = now
        isHolding = false
        guard holdEnabled else {
            tappedOnPress = true
            return [.tap]
        }
        tappedOnPress = false
        return [.scheduleHoldCheck(at: now + holdThreshold)]
    }

    /// Still down and held for at least the threshold → `[.holdBegan]`.
    mutating func holdCheck(at now: TimeInterval) -> [Output] {
        guard let pressedAt, !tappedOnPress, !isHolding, now - pressedAt >= holdThreshold else { return [] }
        isHolding = true
        return [.holdBegan]
    }

    /// Holding → `[.holdEnded]`; the press already tapped → nothing; otherwise `[.tap]`.
    ///
    /// A release that comes at or past the threshold before the hold check was delivered (the check's task ran
    /// late because the main actor was busy, or the release was handled first) is still a tap: no voice session
    /// began, so the press must not vanish. The user gets the open they asked for instead of nothing.
    mutating func release(at _: TimeInterval) -> [Output] {
        guard pressedAt != nil else { return [] }
        let wasHolding = isHolding
        let tapped = tappedOnPress
        reset()
        if wasHolding { return [.holdEnded] }
        if tapped { return [] }
        return [.tap]
    }

    mutating func reset() {
        pressedAt = nil
        isHolding = false
        tappedOnPress = false
    }
}

@MainActor
final class GlobalShortcutRouter {
    private let onTap: () -> Void
    private let onHoldBegan: () -> Void
    private let onHoldEnded: () -> Void
    private var machine = HoldGestureMachine()
    private var holdCheckTask: Task<Void, Never>?

    /// `voice.enabled && voice.holdShortcutToTalk`.
    var holdEnabled: Bool {
        get { machine.holdEnabled }
        set { machine.holdEnabled = newValue }
    }

    init(onTap: @escaping () -> Void, onHoldBegan: @escaping () -> Void, onHoldEnded: @escaping () -> Void) {
        self.onTap = onTap
        self.onHoldBegan = onHoldBegan
        self.onHoldEnded = onHoldEnded
    }

    deinit {
        holdCheckTask?.cancel()
    }

    func pressed() {
        perform(machine.press(at: Self.now()))
    }

    /// A hold check still pending is cancelled: listening never started, so the release is a tap (see
    /// `HoldGestureMachine.release`) rather than nothing, or a voice session that would begin and end at once.
    func released() {
        holdCheckTask?.cancel()
        holdCheckTask = nil
        perform(machine.release(at: Self.now()))
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
        holdCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.holdCheckTask = nil
            self.perform(self.machine.holdCheck(at: max(deadline, Self.now())))
        }
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

}
