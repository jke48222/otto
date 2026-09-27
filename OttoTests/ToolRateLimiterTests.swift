//
//  ToolRateLimiterTests.swift
//  OttoTests
//
//  Per-reply and rolling-hour limits with an injected clock, the exact limit copy, and that refused
//  calls aren't counted.
//

import XCTest
@testable import Otto

@MainActor
final class ToolRateLimiterTests: XCTestCase {
    private struct LimitedTool: OttoTool {
        var name = "limited"
        var group: ToolGroup? = .shortcuts
        var description = "A tool with a small rate limit."
        var inputSchema: JSONValue { ["type": "object", "properties": [:], "required": [], "additionalProperties": false] }
        var isConcurrencySafe: Bool { false }
        var sampleInput: JSONValue { [:] }
        var rateLimit: ToolRateLimit

        @MainActor func isAvailable(in environment: ToolEnvironment) -> Bool { true }
        func approvalRequirement(for input: JSONValue) -> ApprovalRequirement { .none }
        func describe(_ input: JSONValue) -> ToolCallPresentation { .generic(toolName: name) }
        func approvalBody(for input: JSONValue) async -> ApprovalBody {
            .text(TextPreview(label: "Input", text: "", language: nil))
        }
        func run(_ input: JSONValue, context: ToolRunContext) async throws -> ToolRunResult {
            ToolRunResult(output: .text("ok"))
        }
    }

    private var clockNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func makeLimiter() -> ToolRateLimiter {
        ToolRateLimiter { [unowned self] in self.clockNow }
    }

    func testPerTurnLimitAndReset() {
        let limiter = makeLimiter()
        let tool = LimitedTool(rateLimit: ToolRateLimit(perTurn: 2, perHour: nil))
        XCTAssertNil(limiter.check(tool))
        XCTAssertNil(limiter.check(tool))
        let error = limiter.check(tool)
        XCTAssertEqual(error?.code, .limit)
        XCTAssertEqual(error?.toolResultText,
                       "limit: limited can run at most 2 times per reply. Ask the user before trying again.")
        XCTAssertEqual(error?.userMessage, "Limit reached")

        limiter.beginTurn()
        XCTAssertNil(limiter.check(tool), "a new reply starts a new count")
    }

    func testLimitsAreCountedPerToolName() {
        let limiter = makeLimiter()
        let first = LimitedTool(name: "first", rateLimit: ToolRateLimit(perTurn: 1, perHour: nil))
        let second = LimitedTool(name: "second", rateLimit: ToolRateLimit(perTurn: 1, perHour: nil))
        XCTAssertNil(limiter.check(first))
        XCTAssertNil(limiter.check(second))
        XCTAssertNotNil(limiter.check(first))
    }

    func testRollingHourWindowWithInjectedClock() {
        let limiter = makeLimiter()
        let tool = LimitedTool(rateLimit: ToolRateLimit(perTurn: 10, perHour: 3))
        for _ in 0..<3 {
            XCTAssertNil(limiter.check(tool))
            limiter.beginTurn()
            clockNow += 60
        }
        let error = limiter.check(tool)
        XCTAssertEqual(error?.toolResultText,
                       "limit: limited can run at most 10 times per reply (3 per hour). Ask the user before trying again.")

        // The first run was at t = 0; the window rolls past it an hour later.
        clockNow = Date(timeIntervalSinceReferenceDate: 800_000_000 + 3_600 + 1)
        XCTAssertNil(limiter.check(tool))
        XCTAssertNotNil(limiter.check(tool), "the runs at t = 60 and t = 120 are still inside the window")
    }

    func testRefusedCallsAreNotCounted() {
        let limiter = makeLimiter()
        let tool = LimitedTool(rateLimit: ToolRateLimit(perTurn: 5, perHour: 1))
        XCTAssertNil(limiter.check(tool))
        for _ in 0..<5 { XCTAssertNotNil(limiter.check(tool)) }
        clockNow += 3_601
        XCTAssertNil(limiter.check(tool), "refusals didn't extend the hourly window")
    }
}
