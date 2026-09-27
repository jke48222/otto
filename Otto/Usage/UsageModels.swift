//
//  UsageModels.swift
//  Otto
//
//  Token usage as the Messages API reports it, priced per billable attempt. One response can carry
//  several attempts in `usage.iterations` (a model declined before writing, then the server fell back
//  to another model); those entries are the source of truth and the top-level counts are never added
//  on top of them.
//

import Foundation

// MARK: - Token usage

struct TokenUsage: Equatable, Codable, Sendable {
    var input = 0, output = 0, cacheRead = 0, cacheWrite5m = 0, cacheWrite1h = 0, webSearches = 0

    static func + (l: TokenUsage, r: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: UsageArithmetic.add(l.input, r.input),
            output: UsageArithmetic.add(l.output, r.output),
            cacheRead: UsageArithmetic.add(l.cacheRead, r.cacheRead),
            cacheWrite5m: UsageArithmetic.add(l.cacheWrite5m, r.cacheWrite5m),
            cacheWrite1h: UsageArithmetic.add(l.cacheWrite1h, r.cacheWrite1h),
            webSearches: UsageArithmetic.add(l.webSearches, r.webSearches)
        )
    }

    /// Every input-side token: uncached input, cache reads and cache writes.
    var promptTokens: Int {
        [cacheRead, cacheWrite5m, cacheWrite1h].reduce(input, UsageArithmetic.add)
    }

    /// Share of the prompt served from the cache, or nil without prompt tokens.
    var cachedShare: Double? {
        promptTokens > 0 ? Double(cacheRead) / Double(promptTokens) : nil
    }

    /// Prompt plus output tokens.
    var totalTokens: Int { UsageArithmetic.add(promptTokens, output) }

    /// True when nothing was counted.
    var isEmpty: Bool { self == TokenUsage() }
}

extension TokenUsage {
    /// Largest count accepted for one field of one usage object; anything above is treated as this value.
    static let maximumCount = 1_000_000_000

    /// One usage object (top-level or an `iterations` entry): `input_tokens`, `output_tokens`,
    /// `cache_read_input_tokens`, `cache_creation_input_tokens` (split by `cache_creation.ephemeral_5m_input_tokens`
    /// / `ephemeral_1h_input_tokens` when present, otherwise all creation counts as 5-minute writes) and
    /// `server_tool_use.web_search_requests`. Missing, negative or non-numeric fields count as 0.
    init(json: JSONValue) {
        func count(_ value: JSONValue?) -> Int {
            guard let value = value?.intValue else { return 0 }
            return min(max(value, 0), Self.maximumCount)
        }
        self.init()
        input = count(json["input_tokens"])
        output = count(json["output_tokens"])
        cacheRead = count(json["cache_read_input_tokens"])
        webSearches = count(json["server_tool_use"]?["web_search_requests"])

        let creation = count(json["cache_creation_input_tokens"])
        if let split = json["cache_creation"], split.objectValue != nil {
            let fiveMinutes = count(split["ephemeral_5m_input_tokens"])
            let oneHour = count(split["ephemeral_1h_input_tokens"])
            cacheWrite1h = oneHour
            // Creation tokens the split doesn't account for are billed like 5-minute writes.
            cacheWrite5m = max(fiveMinutes, creation - oneHour)
        } else {
            cacheWrite5m = creation
        }
    }
}

// MARK: - Priced lines

/// Tokens of one model and what they cost. `costNanos` is nil when the model isn't in `ModelPricing.table`.
struct PricedLine: Equatable, Codable, Sendable {
    var model: String
    var usage: TokenUsage
    var costNanos: Int64?
}

/// The billable attempts of one Messages API response.
struct RequestUsage: Equatable, Sendable {
    var lines: [PricedLine]
    /// From a stream that never completed: the input side is exact, the output is what was reported so far.
    var isPartial: Bool

    /// Rules (glance.md §2.3):
    /// - `usage` nil or not an object → nil.
    /// - A non-empty `usage.iterations` array is the per-attempt source of truth; top-level counts cover only the
    ///   serving attempt and are ignored. Each entry's model is `entry.model`, else `servedModel` for
    ///   `fallback_message`, else `requestedModel`. A `message` entry with no output is unbilled when a later entry
    ///   exists (it declined before writing, then the server fell back) or when it is the last entry and the
    ///   response stopped with `refusal`. Top-level web searches belong to the last (serving) line.
    /// - Otherwise one line at `servedModel ?? requestedModel`, unbilled on a pre-output refusal.
    /// - Cost is tokens × list price + searches × $0.01. Demo lines cost 0 and are kept for display.
    /// Unbilled lines keep their model with zero tokens and zero cost.
    static func parse(usage: JSONValue?, requestedModel: String, servedModel: String?, stopReason: String?,
                      isPartial: Bool, isDemo: Bool) -> RequestUsage? {
        guard let usage, usage.objectValue != nil else { return nil }
        let isRefusal = stopReason == "refusal"

        let entries = (usage["iterations"]?.arrayValue ?? []).filter { $0.objectValue != nil }
        var lines: [PricedLine] = []
        if entries.isEmpty {
            let tokens = TokenUsage(json: usage)
            let unbilled = isRefusal && tokens.output == 0
            lines.append(priced(model: servedModel ?? requestedModel, usage: tokens, unbilled: unbilled,
                                isDemo: isDemo))
        } else {
            let searches = TokenUsage(json: usage).webSearches
            for (index, entry) in entries.enumerated() {
                let type = entry.typeName
                let isLast = index == entries.count - 1
                let model = entry["model"]?.stringValue
                    ?? (type == "fallback_message" ? servedModel : nil)
                    ?? requestedModel
                var tokens = TokenUsage(json: entry)
                tokens.webSearches = isLast ? searches : 0
                let unbilled = type == "message" && tokens.output == 0 && (!isLast || isRefusal)
                lines.append(priced(model: model, usage: tokens, unbilled: unbilled, isDemo: isDemo))
            }
        }
        return RequestUsage(lines: lines, isPartial: isPartial)
    }

    /// True when `usage.iterations` records a server fallback to another model.
    static func containsFallback(_ usage: JSONValue?) -> Bool {
        (usage?["iterations"]?.arrayValue ?? []).contains { $0.typeName == "fallback_message" }
    }

    private static func priced(model: String, usage: TokenUsage, unbilled: Bool, isDemo: Bool) -> PricedLine {
        if unbilled { return PricedLine(model: model, usage: TokenUsage(), costNanos: 0) }
        if isDemo { return PricedLine(model: model, usage: usage, costNanos: 0) }
        return PricedLine(model: model, usage: usage, costNanos: ModelPricing.price(for: model)?.cost(of: usage))
    }
}

// MARK: - Answers

/// Everything one reply cost, summed over its requests (`pause_turn` continuations and tool rounds).
struct AnswerUsage: Equatable, Sendable {
    let messageID: UUID
    var requests = 0
    /// Merged by model; the last line is the model that served the latest request.
    var lines: [PricedLine] = []
    var isPartial = false
    var isDemo = false
    /// A server fallback was seen.
    var fellBack = false

    /// Total cost, or nil when any line's model isn't priced.
    var totalNanos: Int64? {
        var total: Int64 = 0
        for line in lines {
            guard let cost = line.costNanos else { return nil }
            total = UsageArithmetic.add(total, cost)
        }
        return total
    }

    /// Model of the last line.
    var servedModel: String? { lines.last?.model }

    /// All lines' tokens added up.
    var usage: TokenUsage { lines.reduce(TokenUsage()) { $0 + $1.usage } }

    /// Adds one request. Lines of a model already present are summed; the request's serving (last) line moves to
    /// the end so `servedModel` follows the latest request.
    mutating func add(_ request: RequestUsage) {
        requests = UsageArithmetic.add(requests, 1)
        isPartial = isPartial || request.isPartial
        for line in request.lines {
            if let index = lines.firstIndex(where: { $0.model == line.model }) {
                lines[index].usage = lines[index].usage + line.usage
                lines[index].costNanos = UsageArithmetic.add(lines[index].costNanos, line.costNanos)
            } else {
                lines.append(line)
            }
        }
        if let serving = request.lines.last?.model,
           let index = lines.firstIndex(where: { $0.model == serving }), index != lines.count - 1 {
            lines.append(lines.remove(at: index))
        }
    }
}

// MARK: - Totals

struct UsageTotals: Equatable, Codable, Sendable {
    var usage = TokenUsage()
    /// Cost of the priced tokens.
    var costNanos: Int64 = 0
    /// Tokens of models with no list price (also counted in `usage`, never in `costNanos`).
    var unpricedTokens = 0
    var replies = 0

    static func + (l: UsageTotals, r: UsageTotals) -> UsageTotals {
        UsageTotals(
            usage: l.usage + r.usage,
            costNanos: UsageArithmetic.add(l.costNanos, r.costNanos),
            unpricedTokens: UsageArithmetic.add(l.unpricedTokens, r.unpricedTokens),
            replies: UsageArithmetic.add(l.replies, r.replies)
        )
    }

    /// The totals of one priced line (no reply counted).
    init(line: PricedLine) {
        self.init(usage: line.usage, costNanos: line.costNanos ?? 0,
                  unpricedTokens: line.costNanos == nil ? line.usage.totalTokens : 0)
    }

    init(usage: TokenUsage = TokenUsage(), costNanos: Int64 = 0, unpricedTokens: Int = 0, replies: Int = 0) {
        self.usage = usage
        self.costNanos = costNanos
        self.unpricedTokens = unpricedTokens
        self.replies = replies
    }
}

// MARK: - Arithmetic

/// Saturating sums: usage numbers come from the network, and an absurd value must never trap.
enum UsageArithmetic {
    static func add(_ l: Int, _ r: Int) -> Int {
        let (sum, overflow) = l.addingReportingOverflow(r)
        return overflow ? (r > 0 ? .max : .min) : sum
    }

    static func add(_ l: Int64, _ r: Int64) -> Int64 {
        let (sum, overflow) = l.addingReportingOverflow(r)
        return overflow ? (r > 0 ? .max : .min) : sum
    }

    /// nil when either side is unknown.
    static func add(_ l: Int64?, _ r: Int64?) -> Int64? {
        guard let l, let r else { return nil }
        return add(l, r)
    }
}
