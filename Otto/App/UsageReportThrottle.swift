//
//  UsageReportThrottle.swift
//  Otto
//
//  Spaces out usage reports so at most one goes out per five minutes. The Setapp build uses it for Setapp's
//  required usage events (§14.11.2); it is pure and flavor-neutral, so every flavor compiles and tests it.
//

import Foundation

struct UsageReportThrottle: Equatable, Sendable {
    static let minimumInterval: TimeInterval = 300

    private(set) var lastReportAt: Date? = nil

    /// true (and records `now`) when nothing was reported yet or the last report is ≥ minimumInterval old.
    /// A last report dated in the future (the clock was set back since) counts by its distance from `now`, so a
    /// clock change can delay reporting by at most one interval.
    mutating func shouldReport(now: Date) -> Bool {
        if let lastReportAt, abs(now.timeIntervalSince(lastReportAt)) < Self.minimumInterval {
            return false
        }
        lastReportAt = now
        return true
    }
}
