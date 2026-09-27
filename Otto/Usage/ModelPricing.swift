//
//  ModelPricing.swift
//  Otto
//
//  List prices for the models Otto can be served by, in integer nano-dollars per token
//  (1 n$ = 10⁻⁹ $), so every sum is exact. Prices change rarely: bump `table` and `asOf` together;
//  totals already in the ledger keep the cost they were recorded with.
//

import Foundation

/// One model's list prices, in nano-dollars per token.
struct ModelPrice: Equatable, Sendable {
    let input, output, cacheWrite5m, cacheWrite1h, cacheRead: Int64

    /// Tokens × prices + web searches × `ModelPricing.webSearchNanosPerRequest`. Saturates instead of
    /// trapping, so a nonsense usage object can never crash the app.
    func cost(of usage: TokenUsage) -> Int64 {
        let parts: [(Int, Int64)] = [
            (usage.input, input),
            (usage.output, output),
            (usage.cacheRead, cacheRead),
            (usage.cacheWrite5m, cacheWrite5m),
            (usage.cacheWrite1h, cacheWrite1h),
            (usage.webSearches, ModelPricing.webSearchNanosPerRequest),
        ]
        return parts.reduce(Int64(0)) { total, part in
            let (product, overflow) = Int64(max(part.0, 0)).multipliedReportingOverflow(by: part.1)
            if overflow { return .max }
            let (sum, sumOverflow) = total.addingReportingOverflow(product)
            return sumOverflow ? .max : sum
        }
    }
}

enum ModelPricing {
    static let asOf = "2026-09"
    /// Web search: $10 per 1,000 requests. Web fetch is tokens only.
    static let webSearchNanosPerRequest: Int64 = 10_000_000

    /// Cache writes cost 1.25× input (5-minute TTL) or 2× input (1-hour TTL); cache reads 0.1× input.
    static let table: [String: ModelPrice] = [
        "claude-opus-5": opus,
        "claude-sonnet-5": ModelPrice(input: 2_000, output: 10_000, cacheWrite5m: 2_500, cacheWrite1h: 4_000,
                                      cacheRead: 200),
        "claude-haiku-4-5": ModelPrice(input: 1_000, output: 5_000, cacheWrite5m: 1_250, cacheWrite1h: 2_000,
                                       cacheRead: 100),
        // Server fallback targets for Opus 5.
        "claude-opus-4-8": opus,
        "claude-opus-4-7": opus,
    ]

    /// The suffix `MockLLMClient` puts on its model id.
    static let demoSuffix = " (demo)"

    /// The exact id, else the longest table key that `model` starts with followed by "-" (dated snapshots such
    /// as `claude-opus-5-20260901`), else nil. Strips a " (demo)" suffix first. Never guesses across families.
    static func price(for model: String) -> ModelPrice? {
        canonicalID(for: model).flatMap { table[$0] }
    }

    /// The table key `price(for:)` resolves `model` to, or nil when the model isn't priced.
    static func canonicalID(for model: String) -> String? {
        let id = strippingDemoSuffix(model)
        if table[id] != nil { return id }
        return table.keys
            .filter { id.hasPrefix($0 + "-") }
            .max { $0.count < $1.count }
    }

    /// True for the ids of Otto's demo client.
    static func isDemo(_ model: String) -> Bool {
        model.hasSuffix(demoSuffix)
    }

    static func strippingDemoSuffix(_ model: String) -> String {
        isDemo(model) ? String(model.dropLast(demoSuffix.count)) : model
    }

    // MARK: - Private

    private static let opus = ModelPrice(input: 5_000, output: 25_000, cacheWrite5m: 6_250, cacheWrite1h: 10_000,
                                         cacheRead: 500)
}
