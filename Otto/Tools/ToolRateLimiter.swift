//
//  ToolRateLimiter.swift
//  Otto
//
//  Per-tool call limits: how often each tool may run in one reply and in a rolling hour. The hourly
//  windows live in memory, so they reset when Otto quits (an accepted residual risk).
//

import Foundation

@MainActor final class ToolRateLimiter {
    /// Length of the rolling window behind `ToolRateLimit.perHour`.
    static let hourWindow: TimeInterval = 3_600

    /// Set once by the nonisolated init and only read on the main actor.
    nonisolated(unsafe) private let clock: () -> Date
    private var turnCounts: [String: Int] = [:]
    private var hourlyRuns: [String: [Date]] = [:]

    /// Nonisolated so it can be the default argument of `ToolExecutor.init`; it only stores the clock.
    nonisolated init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// Resets the per-reply counters (the hourly windows keep running).
    func beginTurn() {
        turnCounts = [:]
    }

    /// nil = allowed (and counted). Counts per tool name per turn and per rolling hour. (The 25-calls-per-reply
    /// cap, `ToolLimits.maxCallsPerTurn`, is enforced by the loop.) A refused call isn't counted.
    func check(_ tool: any OttoTool) -> ToolError? {
        let limit = tool.rateLimit
        let now = clock()
        let windowStart = now.addingTimeInterval(-Self.hourWindow)
        let recent = (hourlyRuns[tool.name] ?? []).filter { $0 > windowStart }
        hourlyRuns[tool.name] = recent

        let usedThisTurn = turnCounts[tool.name] ?? 0
        let overTurn = usedThisTurn >= limit.perTurn
        let overHour = limit.perHour.map { recent.count >= $0 } ?? false
        guard !overTurn, !overHour else { return Self.limitError(toolName: tool.name, limit: limit) }

        turnCounts[tool.name] = usedThisTurn + 1
        hourlyRuns[tool.name] = recent + [now]
        return nil
    }

    /// `limit: ‹tool› can run at most ‹n› times per reply‹ (‹m› per hour)›. Ask the user before trying again.`
    static func limitError(toolName: String, limit: ToolRateLimit) -> ToolError {
        let perHour = limit.perHour.map { " (\($0) per hour)" } ?? ""
        return ToolError(code: .limit,
                         modelMessage: "\(toolName) can run at most \(limit.perTurn) times per reply\(perHour). Ask the user before trying again.",
                         userMessage: "Limit reached")
    }
}
