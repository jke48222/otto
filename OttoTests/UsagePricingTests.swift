//
//  UsagePricingTests.swift
//  OttoTests
//
//  The price table lookups, exact nano-dollar cost math, and how one Messages API usage object becomes
//  billable lines: cache write splits, web searches, iterations with declines and server fallbacks,
//  refusals, demo replies and overflow safety.
//

import XCTest
@testable import Otto

final class UsagePricingTests: XCTestCase {
    private let opus = ModelPrice(input: 5_000, output: 25_000, cacheWrite5m: 6_250, cacheWrite1h: 10_000,
                                  cacheRead: 500)

    // MARK: - Table and lookup

    func testTableMatchesListPrices() {
        XCTAssertEqual(ModelPricing.asOf, "2026-09")
        XCTAssertEqual(ModelPricing.webSearchNanosPerRequest, 10_000_000)
        XCTAssertEqual(ModelPricing.table["claude-opus-5"], opus)
        XCTAssertEqual(ModelPricing.table["claude-sonnet-5"],
                       ModelPrice(input: 2_000, output: 10_000, cacheWrite5m: 2_500, cacheWrite1h: 4_000, cacheRead: 200))
        XCTAssertEqual(ModelPricing.table["claude-haiku-4-5"],
                       ModelPrice(input: 1_000, output: 5_000, cacheWrite5m: 1_250, cacheWrite1h: 2_000, cacheRead: 100))
        XCTAssertEqual(ModelPricing.table["claude-opus-4-8"], opus)
        XCTAssertEqual(ModelPricing.table["claude-opus-4-7"], opus)
        XCTAssertEqual(ModelPricing.table.count, 5)
        // Cache multipliers hold for every model: 1.25× and 2× writes, 0.1× reads.
        for (model, price) in ModelPricing.table {
            XCTAssertEqual(price.cacheWrite5m * 4, price.input * 5, model)
            XCTAssertEqual(price.cacheWrite1h, price.input * 2, model)
            XCTAssertEqual(price.cacheRead * 10, price.input, model)
        }
        // Every model Otto offers is priced.
        for option in ModelOption.allCases {
            XCTAssertNotNil(ModelPricing.price(for: option.rawValue), option.rawValue)
        }
    }

    func testPriceLookupExactDatedDemoAndUnknown() {
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-5"), opus)
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-5-20260901"), opus)
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-5 (demo)"), opus)
        XCTAssertEqual(ModelPricing.price(for: "claude-haiku-4-5-20251001"), ModelPricing.table["claude-haiku-4-5"])
        XCTAssertEqual(ModelPricing.canonicalID(for: "claude-sonnet-5-20260801 (demo)"), "claude-sonnet-5")

        // Never guesses across families or versions.
        XCTAssertNil(ModelPricing.price(for: "claude-opus-6"))
        XCTAssertNil(ModelPricing.price(for: "claude-opus-50"))
        XCTAssertNil(ModelPricing.price(for: "claude-opus-4"))
        XCTAssertNil(ModelPricing.price(for: "claude-haiku-4"))
        XCTAssertNil(ModelPricing.price(for: "gpt-5"))
        XCTAssertNil(ModelPricing.price(for: ""))
        XCTAssertNil(ModelPricing.price(for: "claude-opus-5(demo)"))
    }

    // MARK: - Cost math

    func testOpusThousandInFiveHundredOutIsExact() throws {
        XCTAssertEqual(opus.cost(of: TokenUsage(input: 1_000, output: 500)), 17_500_000)

        let request = try XCTUnwrap(RequestUsage.parse(
            usage: ["input_tokens": 1_000, "output_tokens": 500],
            requestedModel: "claude-opus-5", servedModel: "claude-opus-5", stopReason: "end_turn",
            isPartial: false, isDemo: false))
        XCTAssertEqual(request.lines, [PricedLine(model: "claude-opus-5", usage: TokenUsage(input: 1_000, output: 500),
                                                  costNanos: 17_500_000)])
        XCTAssertFalse(request.isPartial)
        XCTAssertEqual(CostFormatter.short(17_500_000), "≈1.8¢")
    }

    func testCacheWriteSplitsIntoFiveMinuteAndOneHour() {
        let split = TokenUsage(json: [
            "input_tokens": 100,
            "cache_creation_input_tokens": 300,
            "cache_creation": ["ephemeral_5m_input_tokens": 100, "ephemeral_1h_input_tokens": 200],
            "cache_read_input_tokens": 1_000,
            "output_tokens": 10,
        ])
        XCTAssertEqual(split, TokenUsage(input: 100, output: 10, cacheRead: 1_000, cacheWrite5m: 100, cacheWrite1h: 200))
        // 100 × 5,000 + 10 × 25,000 + 1,000 × 500 + 100 × 6,250 + 200 × 10,000
        XCTAssertEqual(opus.cost(of: split), 3_875_000)

        // Without the split every creation token is a 5-minute write.
        let unsplit = TokenUsage(json: ["cache_creation_input_tokens": 300])
        XCTAssertEqual(unsplit, TokenUsage(cacheWrite5m: 300))
        XCTAssertEqual(opus.cost(of: unsplit), 1_875_000)

        // Creation tokens the split doesn't cover still count, as 5-minute writes.
        let partialSplit = TokenUsage(json: ["cache_creation_input_tokens": 500,
                                             "cache_creation": ["ephemeral_1h_input_tokens": 200]])
        XCTAssertEqual(partialSplit, TokenUsage(cacheWrite5m: 300, cacheWrite1h: 200))
    }

    func testOneWebSearchAddsTenMillionNanos() throws {
        let base: JSONValue = ["input_tokens": 1_000, "output_tokens": 500]
        let withSearch: JSONValue = ["input_tokens": 1_000, "output_tokens": 500,
                                     "server_tool_use": ["web_search_requests": 1, "web_fetch_requests": 2]]
        let plain = try XCTUnwrap(parse(base))
        let searched = try XCTUnwrap(parse(withSearch))
        XCTAssertEqual(searched.lines.first?.usage.webSearches, 1)
        XCTAssertEqual(searched.lines.first?.costNanos, (plain.lines.first?.costNanos ?? 0) + 10_000_000)
    }

    func testTokenUsageDerivedValuesAndSum() {
        let usage = TokenUsage(input: 100, output: 50, cacheRead: 800, cacheWrite5m: 60, cacheWrite1h: 40, webSearches: 1)
        XCTAssertEqual(usage.promptTokens, 1_000)
        XCTAssertEqual(usage.cachedShare, 0.8)
        XCTAssertEqual(usage.totalTokens, 1_050)
        XCTAssertNil(TokenUsage().cachedShare)
        XCTAssertEqual(usage + usage, TokenUsage(input: 200, output: 100, cacheRead: 1_600, cacheWrite5m: 120,
                                                 cacheWrite1h: 80, webSearches: 2))
        XCTAssertEqual(usage + TokenUsage(), usage)
    }

    func testMalformedCountsAreZeroAndHugeCountsNeverTrap() {
        let odd = TokenUsage(json: ["input_tokens": -5, "output_tokens": "12", "cache_read_input_tokens": 2.0,
                                    "server_tool_use": "none"])
        XCTAssertEqual(odd, TokenUsage(cacheRead: 2))
        XCTAssertEqual(TokenUsage(json: "not an object"), TokenUsage())

        let huge = TokenUsage(json: ["input_tokens": .int(.max), "output_tokens": .int(.max)])
        XCTAssertEqual(huge.input, TokenUsage.maximumCount)
        XCTAssertGreaterThan(opus.cost(of: huge), 0)

        let maxed = TokenUsage(input: .max, output: .max, webSearches: .max)
        XCTAssertEqual(opus.cost(of: maxed), .max)
        XCTAssertEqual((maxed + maxed).input, .max)
        XCTAssertEqual(UsageTotals(costNanos: .max) + UsageTotals(costNanos: 1), UsageTotals(costNanos: .max))
    }

    // MARK: - Parse rules

    func testMissingOrNonObjectUsageParsesToNil() {
        XCTAssertNil(parse(nil))
        XCTAssertNil(parse(.null))
        XCTAssertNil(parse([1, 2]))
        XCTAssertNil(parse("usage"))
    }

    func testSingleLineUsesServedModelElseRequested() throws {
        let served = try XCTUnwrap(RequestUsage.parse(
            usage: ["input_tokens": 10], requestedModel: "claude-opus-5", servedModel: "claude-opus-5-20260901",
            stopReason: nil, isPartial: true, isDemo: false))
        XCTAssertEqual(served.lines.map(\.model), ["claude-opus-5-20260901"])
        XCTAssertTrue(served.isPartial)

        let requested = try XCTUnwrap(RequestUsage.parse(
            usage: ["input_tokens": 10], requestedModel: "claude-sonnet-5", servedModel: nil,
            stopReason: nil, isPartial: false, isDemo: false))
        XCTAssertEqual(requested.lines.map(\.model), ["claude-sonnet-5"])
        XCTAssertEqual(requested.lines.first?.costNanos, 20_000)
    }

    func testPreOutputRefusalCostsNothing() throws {
        let request = try XCTUnwrap(parse(["input_tokens": 1_000, "output_tokens": 0], stopReason: "refusal"))
        XCTAssertEqual(request.lines, [PricedLine(model: "claude-opus-5", usage: TokenUsage(), costNanos: 0)])

        // A refusal after some output is billed.
        let late = try XCTUnwrap(parse(["input_tokens": 1_000, "output_tokens": 20], stopReason: "refusal"))
        XCTAssertEqual(late.lines.first?.costNanos, 5_500_000)
    }

    func testIterationsPreOutputDeclineThenFallbackPricesOnlyTheFallback() throws {
        let usage: JSONValue = [
            // Top-level counts cover the serving attempt only; they must not be added again.
            "input_tokens": 1_000, "output_tokens": 200,
            "iterations": [
                ["type": "message", "model": "claude-opus-5", "input_tokens": 1_000, "output_tokens": 0],
                ["type": "fallback_message", "model": "claude-opus-4-8", "input_tokens": 1_000, "output_tokens": 200],
            ],
        ]
        let request = try XCTUnwrap(RequestUsage.parse(
            usage: usage, requestedModel: "claude-opus-5", servedModel: "claude-opus-4-8", stopReason: "end_turn",
            isPartial: false, isDemo: false))
        XCTAssertEqual(request.lines, [
            PricedLine(model: "claude-opus-5", usage: TokenUsage(), costNanos: 0),
            PricedLine(model: "claude-opus-4-8", usage: TokenUsage(input: 1_000, output: 200), costNanos: 10_000_000),
        ])
        XCTAssertTrue(RequestUsage.containsFallback(usage))
        XCTAssertFalse(RequestUsage.containsFallback(["input_tokens": 1]))
    }

    func testFallbackEntryWithoutModelUsesServedModel() throws {
        let usage: JSONValue = ["iterations": [
            ["type": "message", "input_tokens": 500, "output_tokens": 0],
            ["type": "fallback_message", "input_tokens": 500, "output_tokens": 40],
        ]]
        let request = try XCTUnwrap(RequestUsage.parse(
            usage: usage, requestedModel: "claude-opus-5", servedModel: "claude-opus-4-7", stopReason: "end_turn",
            isPartial: false, isDemo: false))
        XCTAssertEqual(request.lines.map(\.model), ["claude-opus-5", "claude-opus-4-7"])
        XCTAssertEqual(request.lines.map(\.costNanos), [0, 3_500_000])
    }

    func testMidStreamDeclineIsBilled() throws {
        let usage: JSONValue = ["iterations": [
            ["type": "message", "model": "claude-opus-5", "input_tokens": 1_000, "output_tokens": 50],
            ["type": "fallback_message", "model": "claude-opus-4-8", "input_tokens": 1_100, "output_tokens": 300],
        ]]
        let request = try XCTUnwrap(RequestUsage.parse(
            usage: usage, requestedModel: "claude-opus-5", servedModel: "claude-opus-4-8", stopReason: "end_turn",
            isPartial: false, isDemo: false))
        // 1,000 × 5,000 + 50 × 25,000 and 1,100 × 5,000 + 300 × 25,000
        XCTAssertEqual(request.lines.map(\.costNanos), [6_250_000, 13_000_000])
        XCTAssertEqual(request.lines.first?.usage, TokenUsage(input: 1_000, output: 50))
    }

    func testFinalPreOutputRefusalInIterationsCostsNothing() throws {
        let usage: JSONValue = ["iterations": [
            ["type": "message", "model": "claude-opus-5", "input_tokens": 1_000, "output_tokens": 0],
        ]]
        let refused = try XCTUnwrap(parse(usage, stopReason: "refusal"))
        XCTAssertEqual(refused.lines.map(\.costNanos), [0])

        // The same entry without a refusal is an ordinary (if empty) reply and is billed.
        let ended = try XCTUnwrap(parse(usage, stopReason: "end_turn"))
        XCTAssertEqual(ended.lines.map(\.costNanos), [5_000_000])
    }

    func testIterationsAreNotDoubleCountedWithTopLevel() throws {
        let usage: JSONValue = [
            "input_tokens": 700, "output_tokens": 70, "cache_read_input_tokens": 5_000,
            "server_tool_use": ["web_search_requests": 2],
            "iterations": [
                ["type": "message", "input_tokens": 300, "output_tokens": 30,
                 "server_tool_use": ["web_search_requests": 9]],
                ["type": "message", "input_tokens": 700, "output_tokens": 70, "cache_read_input_tokens": 5_000],
            ],
        ]
        let request = try XCTUnwrap(parse(usage, stopReason: "end_turn"))
        let total = request.lines.reduce(TokenUsage()) { $0 + $1.usage }
        XCTAssertEqual(total, TokenUsage(input: 1_000, output: 100, cacheRead: 5_000, webSearches: 2))
        // Searches come from the top level and land on the serving (last) line only.
        XCTAssertEqual(request.lines.map(\.usage.webSearches), [0, 2])
    }

    func testEmptyIterationsFallBackToTopLevel() throws {
        let request = try XCTUnwrap(parse(["input_tokens": 10, "output_tokens": 5, "iterations": []]))
        XCTAssertEqual(request.lines.map(\.usage), [TokenUsage(input: 10, output: 5)])
    }

    func testDemoLinesCostNothingButKeepTokens() throws {
        let request = try XCTUnwrap(RequestUsage.parse(
            usage: ["input_tokens": 1_000, "output_tokens": 500], requestedModel: "claude-opus-5",
            servedModel: "claude-opus-5 (demo)", stopReason: "end_turn", isPartial: false, isDemo: true))
        XCTAssertEqual(request.lines, [PricedLine(model: "claude-opus-5 (demo)",
                                                  usage: TokenUsage(input: 1_000, output: 500), costNanos: 0)])
    }

    func testUnknownModelIsUnpriced() throws {
        let request = try XCTUnwrap(RequestUsage.parse(
            usage: ["input_tokens": 1_000], requestedModel: "claude-opus-6", servedModel: nil, stopReason: nil,
            isPartial: false, isDemo: false))
        XCTAssertNil(request.lines.first?.costNanos)
        XCTAssertEqual(UsageTotals(line: try XCTUnwrap(request.lines.first)),
                       UsageTotals(usage: TokenUsage(input: 1_000), costNanos: 0, unpricedTokens: 1_000))
    }

    // MARK: - Answers

    func testAnswerMergesRequestsByModelAndTracksTheServingModel() {
        var answer = AnswerUsage(messageID: UUID())
        answer.add(RequestUsage(lines: [PricedLine(model: "claude-opus-5", usage: TokenUsage(input: 10), costNanos: 50_000)],
                                isPartial: false))
        answer.add(RequestUsage(lines: [
            PricedLine(model: "claude-opus-5", usage: TokenUsage(), costNanos: 0),
            PricedLine(model: "claude-opus-4-8", usage: TokenUsage(output: 4), costNanos: 100_000),
        ], isPartial: false))
        XCTAssertEqual(answer.requests, 2)
        XCTAssertEqual(answer.servedModel, "claude-opus-4-8")
        XCTAssertEqual(answer.totalNanos, 150_000)

        answer.add(RequestUsage(lines: [PricedLine(model: "claude-opus-5", usage: TokenUsage(input: 5), costNanos: 25_000)],
                                isPartial: true))
        XCTAssertEqual(answer.requests, 3)
        XCTAssertEqual(answer.lines.map(\.model), ["claude-opus-4-8", "claude-opus-5"])
        XCTAssertEqual(answer.servedModel, "claude-opus-5")
        XCTAssertEqual(answer.lines.last?.usage, TokenUsage(input: 15))
        XCTAssertEqual(answer.totalNanos, 175_000)
        XCTAssertTrue(answer.isPartial)

        answer.add(RequestUsage(lines: [PricedLine(model: "claude-next", usage: TokenUsage(input: 5), costNanos: nil)],
                                isPartial: false))
        XCTAssertNil(answer.totalNanos)
    }

    // MARK: - Helpers

    private func parse(_ usage: JSONValue?, stopReason: String? = "end_turn") -> RequestUsage? {
        RequestUsage.parse(usage: usage, requestedModel: "claude-opus-5", servedModel: nil, stopReason: stopReason,
                           isPartial: false, isDemo: false)
    }
}
