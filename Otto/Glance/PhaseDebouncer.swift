//
//  PhaseDebouncer.swift
//  Otto
//
//  Keeps the closed notch's phase glyph from flickering: a displayed phase stays up for at least
//  `minimumDwell` before a non-urgent phase replaces it. Idle and awaiting-approval always show at once.
//

import Foundation

struct PhaseDebouncer: Equatable {
    var minimumDwell: TimeInterval = 0.4

    /// The phase currently shown and when it went up (−∞ before the first change, so the first
    /// non-idle phase shows immediately).
    private var displayed: ReplyPhase = .idle
    private var displayedSince: TimeInterval = -.infinity

    init(minimumDwell: TimeInterval = 0.4) {
        self.minimumDwell = minimumDwell
    }

    /// Feeds the latest derived phase. Returns what to display now and, when `phase` had to wait, the
    /// time at which the caller should call `update` again with the then-current phase.
    mutating func update(_ phase: ReplyPhase, now: TimeInterval) -> (display: ReplyPhase, recheckAt: TimeInterval?) {
        guard phase != displayed else { return (displayed, nil) }

        let readyAt = displayedSince + max(0, minimumDwell)
        if phase.isUrgent || now >= readyAt {
            displayed = phase
            displayedSince = now
            return (phase, nil)
        }
        return (displayed, readyAt)
    }
}
