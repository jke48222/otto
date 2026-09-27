//
//  CostFormatterTests.swift
//  OttoTests
//
//  Cost and token strings at every boundary, model display names, and the reply footer's summary
//  and tooltip for ordinary, fallback, interrupted, unpriced and demo replies.
//

import XCTest
@testable import Otto

final class CostFormatterTests: XCTestCase {
    // MARK: - Short costs

    func testShortCostBoundaries() {
        XCTAssertEqual(CostFormatter.short(0), "0¢")
        XCTAssertEqual(CostFormatter.short(50_000), "<0.01¢")
        XCTAssertEqual(CostFormatter.short(400_000), "≈0.04¢")
        XCTAssertEqual(CostFormatter.short(4_000_000), "≈0.4¢")
        XCTAssertEqual(CostFormatter.short(17_500_000), "≈1.8¢")
        XCTAssertEqual(CostFormatter.short(123_000_000), "≈12¢")
        XCTAssertEqual(CostFormatter.short(3_400_000_000), "≈$3.40")
    }

    func testShortCostEdgesRollIntoTheNextTier() {
        XCTAssertEqual(CostFormatter.short(99_999), "<0.01¢")
        XCTAssertEqual(CostFormatter.short(100_000), "≈0.01¢")
        XCTAssertEqual(CostFormatter.short(949_999), "≈0.09¢")
        XCTAssertEqual(CostFormatter.short(999_999), "≈0.1¢")
        XCTAssertEqual(CostFormatter.short(10_000_000), "≈1.0¢")
        XCTAssertEqual(CostFormatter.short(99_999_999), "≈10¢")
        XCTAssertEqual(CostFormatter.short(999_999_999), "≈$1.00")
        XCTAssertEqual(CostFormatter.short(1_234_567_000_000), "≈$1,234.57")
        XCTAssertEqual(CostFormatter.short(-5), "0¢")
    }

    func testShortCostPrefixes() {
        XCTAssertEqual(CostFormatter.short(4_000_000, atLeast: true), "≥0.4¢")
        XCTAssertEqual(CostFormatter.short(4_000_000, approximate: false), "0.4¢")
        XCTAssertEqual(CostFormatter.short(4_000_000, approximate: false, atLeast: true), "≥0.4¢")
        XCTAssertEqual(CostFormatter.short(0, atLeast: true), "0¢")
        XCTAssertEqual(CostFormatter.short(50_000, atLeast: true), "<0.01¢")
    }

    // MARK: - Dollars and tokens

    func testDollars() {
        XCTAssertEqual(CostFormatter.dollars(0), "$0.0000")
        XCTAssertEqual(CostFormatter.dollars(40_600_000), "$0.0406")
        XCTAssertEqual(CostFormatter.dollars(6_020_000), "$0.0060")
        XCTAssertEqual(CostFormatter.dollars(10_000_000), "$0.0100")
        XCTAssertEqual(CostFormatter.dollars(999_949_999), "$0.9999")
        XCTAssertEqual(CostFormatter.dollars(999_950_000), "$1.00")
        XCTAssertEqual(CostFormatter.dollars(3_400_000_000), "$3.40")
        XCTAssertEqual(CostFormatter.dollars(12_345_670_000_000), "$12,345.67")
    }

    func testTokens() {
        XCTAssertEqual(CostFormatter.tokens(0), "0")
        XCTAssertEqual(CostFormatter.tokens(612), "612")
        XCTAssertEqual(CostFormatter.tokens(1_204), "1,204")
        XCTAssertEqual(CostFormatter.tokens(9_999), "9,999")
        XCTAssertEqual(CostFormatter.tokens(10_000), "10k")
        XCTAssertEqual(CostFormatter.tokens(12_400), "12.4k")
        XCTAssertEqual(CostFormatter.tokens(12_449), "12.4k")
        XCTAssertEqual(CostFormatter.tokens(999_999), "1M")
        XCTAssertEqual(CostFormatter.tokens(1_250_000), "1.3M")
        XCTAssertEqual(CostFormatter.tokens(-3), "0")
    }

    func testModelNames() {
        XCTAssertEqual(CostFormatter.modelName("claude-opus-5"), "Opus 5")
        XCTAssertEqual(CostFormatter.modelName("claude-opus-5-20260901"), "Opus 5")
        XCTAssertEqual(CostFormatter.modelName("claude-opus-5 (demo)"), "Opus 5")
        XCTAssertEqual(CostFormatter.modelName("claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(CostFormatter.modelName("claude-haiku-4-5"), "Haiku 4.5")
        XCTAssertEqual(CostFormatter.modelName("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(CostFormatter.modelName("claude-opus-4-7"), "Opus 4.7")
        XCTAssertEqual(CostFormatter.modelName("claude-opus-6-20270101"), "Opus 6")
        XCTAssertEqual(CostFormatter.modelName("gpt-5"), "gpt-5")
        XCTAssertEqual(CostFormatter.modelName("claude-\u{202E}evil"), "claude-evil")
    }

    // MARK: - Summary

    func testSummaryOfAnOrdinaryReply() {
        XCTAssertEqual(CostFormatter.summary(exampleAnswer()), "Opus 5 · ≈4.1¢ · 1 search · 91% cached")

        let plain = answer(lines: [line("claude-opus-5", TokenUsage(input: 1_000, output: 500))])
        XCTAssertEqual(CostFormatter.summary(plain), "Opus 5 · ≈1.8¢")

        var searches = plain
        searches.lines[0].usage.webSearches = 3
        XCTAssertEqual(CostFormatter.summary(searches), "Opus 5 · ≈1.8¢ · 3 searches")
    }

    func testSummaryOmitsTinyCacheShares() {
        let tiny = answer(lines: [line("claude-opus-5", TokenUsage(input: 10_000, output: 10, cacheRead: 50))])
        XCTAssertFalse(CostFormatter.summary(tiny).contains("cached"))

        let almostAll = answer(lines: [line("claude-opus-5", TokenUsage(input: 1, output: 10, cacheRead: 999))])
        XCTAssertTrue(CostFormatter.summary(almostAll).hasSuffix("99% cached"))
    }

    func testSummaryAfterFallbackInterruptionAndRefusal() {
        var fallback = answer(lines: [
            PricedLine(model: "claude-opus-5", usage: TokenUsage(), costNanos: 0),
            line("claude-opus-4-8", TokenUsage(input: 1_000, output: 240)),
        ])
        fallback.fellBack = true
        XCTAssertEqual(CostFormatter.summary(fallback), "Opus 4.8 (fallback) · ≈1.1¢")

        var partial = answer(lines: [line("claude-opus-5", TokenUsage(input: 800))])
        partial.isPartial = true
        XCTAssertEqual(CostFormatter.summary(partial), "Opus 5 · ≥0.4¢")

        let refused = answer(lines: [PricedLine(model: "claude-opus-5", usage: TokenUsage(), costNanos: 0)])
        XCTAssertEqual(CostFormatter.summary(refused), "Opus 5 · 0¢")
    }

    func testSummaryOfUnpricedAndDemoReplies() {
        let unknown = answer(lines: [PricedLine(model: "claude-opus-6", usage: TokenUsage(input: 12_000, output: 400),
                                                costNanos: nil)])
        XCTAssertEqual(CostFormatter.summary(unknown), "Opus 6 · 12.4k tokens")

        var demo = answer(lines: [PricedLine(model: "claude-opus-5 (demo)", usage: TokenUsage(input: 1_000, output: 500),
                                             costNanos: 0)])
        demo.isDemo = true
        XCTAssertEqual(CostFormatter.summary(demo), "Opus 5 · ≈1.8¢ (demo)")
    }

    // MARK: - Tooltip

    func testTooltipRowsAndTotal() {
        let lines = CostFormatter.tooltip(exampleAnswer()).components(separatedBy: "\n")
        XCTAssertEqual(lines, [
            "Opus 5 · 2 requests",
            "Input          1,204 tok   $0.0060",
            "Cache read    14,880 tok   $0.0074",
            "Cache write      310 tok   $0.0019",
            "Output           612 tok   $0.0153",
            "Web search         1       $0.0100",
            "≈ $0.0407 at list prices. Your Anthropic invoice is authoritative.",
        ])
    }

    func testTooltipForFallbackPartialUnpricedAndDemo() {
        var fallback = answer(lines: [
            PricedLine(model: "claude-opus-5", usage: TokenUsage(), costNanos: 0),
            line("claude-opus-4-8", TokenUsage(input: 1_000, output: 240)),
        ], requests: 1)
        fallback.fellBack = true
        XCTAssertEqual(CostFormatter.tooltip(fallback).components(separatedBy: "\n"), [
            "Opus 4.8 (fallback) · 1 request",
            "Input    1,000 tok   $0.0050",
            "Output     240 tok   $0.0060",
            "≈ $0.0110 at list prices. Your Anthropic invoice is authoritative.",
        ])

        var partial = answer(lines: [line("claude-opus-5", TokenUsage(input: 800))], requests: 1)
        partial.isPartial = true
        XCTAssertTrue(CostFormatter.tooltip(partial).hasSuffix(
            "≥ $0.0040 at list prices. The reply stopped early, so this counts only what was reported."))

        let unknown = answer(lines: [PricedLine(model: "claude-opus-6", usage: TokenUsage(input: 12_000, output: 400),
                                                costNanos: nil)], requests: 1)
        XCTAssertEqual(CostFormatter.tooltip(unknown).components(separatedBy: "\n"), [
            "Opus 6 · 1 request",
            "Input    12,000 tok",
            "Output      400 tok",
            "Otto has no list price for this model, so it shows tokens only.",
        ])

        var demo = answer(lines: [PricedLine(model: "claude-opus-5 (demo)", usage: TokenUsage(input: 1_000, output: 500),
                                             costNanos: 0)], requests: 1)
        demo.isDemo = true
        XCTAssertTrue(CostFormatter.tooltip(demo).hasSuffix("≈ $0.0175 at list prices. Demo replies aren't billed."))
    }

    // MARK: - Helpers

    /// glance.md §2.1's tooltip example: Opus 5, two requests, one search.
    private func exampleAnswer() -> AnswerUsage {
        answer(lines: [line("claude-opus-5", TokenUsage(input: 1_204, output: 612, cacheRead: 14_880, cacheWrite5m: 310,
                                                        webSearches: 1))], requests: 2)
    }

    private func line(_ model: String, _ usage: TokenUsage) -> PricedLine {
        PricedLine(model: model, usage: usage, costNanos: ModelPricing.price(for: model)?.cost(of: usage))
    }

    private func answer(lines: [PricedLine], requests: Int = 1) -> AnswerUsage {
        AnswerUsage(messageID: UUID(), requests: requests, lines: lines, isPartial: false, isDemo: false,
                    fellBack: false)
    }
}
