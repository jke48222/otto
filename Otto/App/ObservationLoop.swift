//
//  ObservationLoop.swift
//  Otto
//
//  Watches an `@Observable`-derived value and reports each change on the main actor.
//

import Observation

/// Keeps watching an `@Observable`-derived value and calls `onChange` (on the main actor) whenever it
/// changes. `withObservationTracking` fires only once and before the mutation lands, so each change
/// schedules a main-actor hop that reads the new value and re-arms tracking.
@MainActor
final class ObservationLoop<Value: Equatable> {
    private let read: @MainActor () -> Value
    private let onChange: @MainActor (Value) -> Void
    private var current: Value
    private var isActive = true

    init(read: @escaping @MainActor () -> Value, onChange: @escaping @MainActor (Value) -> Void) {
        self.read = read
        self.onChange = onChange
        current = read()
        arm()
    }

    /// Stops delivering changes. Idempotent.
    func cancel() {
        isActive = false
    }

    private func arm() {
        guard isActive else { return }
        current = withObservationTracking {
            read()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.fire()
            }
        }
    }

    private func fire() {
        guard isActive else { return }
        let previous = current
        arm()
        if current != previous {
            onChange(current)
        }
    }
}
