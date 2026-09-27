//
//  CostFormatter.swift
//  Otto
//
//  Turns nano-dollars and token counts into the short strings on a reply's footer, its tooltip, the
//  menu totals and Settings. Integer math throughout, so a boundary never depends on floating point.
//

import Foundation

enum CostFormatter {
    /// Nano-dollars per displayed unit.
    private static let nanosPerCent: Int64 = 10_000_000
    private static let nanosPerDollar: Int64 = 1_000_000_000

    /// "0¢"; below 0.01¢ "<0.01¢"; below 0.1¢ two decimals ("0.04¢"); below 10¢ one decimal ("1.8¢");
    /// below $1 whole cents ("12¢"); else dollars ("$3.40"). Prefixed "≥" when `atLeast`, else "≈" when
    /// `approximate`; "0¢" and "<0.01¢" never carry a prefix.
    static func short(_ nanos: Int64, approximate: Bool = true, atLeast: Bool = false) -> String {
        let nanos = max(nanos, 0)
        if nanos == 0 { return "0¢" }
        if nanos < 100_000 { return "<0.01¢" }
        let prefix = atLeast ? "≥" : (approximate ? "≈" : "")

        let hundredths = rounded(nanos, to: 100_000)
        if hundredths < 10 { return prefix + "0.0\(hundredths)¢" }
        let tenths = rounded(nanos, to: 1_000_000)
        if tenths < 100 { return prefix + "\(tenths / 10).\(tenths % 10)¢" }
        let cents = rounded(nanos, to: nanosPerCent)
        if cents < 100 { return prefix + "\(cents)¢" }
        return prefix + "$" + grouped(cents / 100) + "." + twoDigits(cents % 100)
    }

    /// Tooltip precision: 4 decimals below $1 ("$0.0406"), else 2 ("$3.40").
    static func dollars(_ nanos: Int64) -> String {
        let nanos = max(nanos, 0)
        let tenThousandths = rounded(nanos, to: 100_000)
        if tenThousandths < 10_000 {
            let digits = String(tenThousandths)
            return "$0." + String(repeating: "0", count: 4 - digits.count) + digits
        }
        let cents = rounded(nanos, to: nanosPerCent)
        return "$" + grouped(cents / 100) + "." + twoDigits(cents % 100)
    }

    /// "1,204" below 10,000; "12.4k" from 10,000; "1.2M" from a million.
    static func tokens(_ count: Int) -> String {
        let count = Int64(max(count, 0))
        if count < 10_000 { return grouped(count) }
        let tenthsOfThousands = rounded(count, to: 100)
        if tenthsOfThousands < 10_000 { return decimal(tenthsOfThousands) + "k" }
        return decimal(rounded(count, to: 100_000)) + "M"
    }

    /// The reply footer: "Opus 5 · ≈0.8¢ · 1 search · 92% cached". "(fallback)" after a server fallback, "≥" for an
    /// interrupted reply, tokens instead of a cost for a model with no list price, and "(demo)" after a demo cost.
    static func summary(_ answer: AnswerUsage) -> String {
        var pieces: [String] = []
        if let model = answer.servedModel {
            pieces.append(modelName(model) + (answer.fellBack ? " (fallback)" : ""))
        }
        let usage = answer.usage
        if let total = displayedTotal(answer) {
            let cost = short(total, atLeast: answer.isPartial)
            pieces.append(answer.isDemo ? cost + " (demo)" : cost)
        } else {
            pieces.append(tokens(usage.totalTokens) + " tokens")
        }
        if usage.webSearches > 0 {
            pieces.append(usage.webSearches == 1 ? "1 search" : "\(usage.webSearches) searches")
        }
        if let percent = cachedPercent(usage) {
            pieces.append("\(percent)% cached")
        }
        return pieces.joined(separator: " · ")
    }

    /// The reply footer's tooltip: a header, one row per kind of token with its cost, and the total.
    static func tooltip(_ answer: AnswerUsage) -> String {
        let usage = answer.usage
        var header = answer.servedModel.map { modelName($0) + (answer.fellBack ? " (fallback)" : "") } ?? "Usage"
        header += " · " + (answer.requests == 1 ? "1 request" : "\(answer.requests) requests")

        var rows: [(label: String, count: String, cost: Int64?)] = [
            ("Input", grouped(Int64(usage.input)) + " tok", rowCost(answer) { TokenUsage(input: $0.input) }),
        ]
        if usage.cacheRead > 0 {
            rows.append(("Cache read", grouped(Int64(usage.cacheRead)) + " tok",
                         rowCost(answer) { TokenUsage(cacheRead: $0.cacheRead) }))
        }
        let cacheWrites = UsageArithmetic.add(usage.cacheWrite5m, usage.cacheWrite1h)
        if cacheWrites > 0 {
            rows.append(("Cache write", grouped(Int64(cacheWrites)) + " tok",
                         rowCost(answer) { TokenUsage(cacheWrite5m: $0.cacheWrite5m, cacheWrite1h: $0.cacheWrite1h) }))
        }
        rows.append(("Output", grouped(Int64(usage.output)) + " tok", rowCost(answer) { TokenUsage(output: $0.output) }))
        if usage.webSearches > 0 {
            // Padded like " tok" so the count lines up with the token counts above it.
            rows.append(("Web search", grouped(Int64(usage.webSearches)) + "    ",
                         rowCost(answer) { TokenUsage(webSearches: $0.webSearches) }))
        }

        let labelWidth = rows.map(\.label.count).max() ?? 0
        let countWidth = rows.map(\.count.count).max() ?? 0
        var lines = [header]
        for row in rows {
            let label = row.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            let count = String(repeating: " ", count: countWidth - row.count.count) + row.count
            var line = "\(label)   \(count)" + (row.cost.map { "   " + dollars($0) } ?? "")
            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
        }

        if let total = displayedTotal(answer) {
            let mark = answer.isPartial ? "≥" : "≈"
            let note: String
            if answer.isDemo {
                note = "Demo replies aren't billed."
            } else if answer.isPartial {
                note = "The reply stopped early, so this counts only what was reported."
            } else {
                note = "Your Anthropic invoice is authoritative."
            }
            lines.append("\(mark) \(dollars(total)) at list prices. \(note)")
        } else {
            lines.append("Otto has no list price for this model, so it shows tokens only.")
        }
        return lines.joined(separator: "\n")
    }

    /// Short display name for a model id: "Opus 5", "Opus 4.8", "Haiku 4.5". Dated snapshots and the demo suffix
    /// are dropped; an id Otto doesn't recognize is shown cleaned but otherwise as reported.
    static func modelName(_ model: String) -> String {
        let id = ModelPricing.canonicalID(for: model) ?? ModelPricing.strippingDemoSuffix(model)
        if let option = ModelOption(rawValue: id) { return option.shortName }
        var parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude", let family = parts[1].first, family.isLetter else {
            return DisplayText.sanitized(id, maxLength: 40)
        }
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        let version = parts.dropFirst(2)
        guard !version.isEmpty, version.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            return DisplayText.sanitized(id, maxLength: 40)
        }
        let name = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        return DisplayText.sanitized(name + " " + version.joined(separator: "."), maxLength: 40)
    }

    // MARK: - Private

    /// The answer's cost; for a demo answer, what it would cost at list prices. nil when a model isn't priced.
    private static func displayedTotal(_ answer: AnswerUsage) -> Int64? {
        guard answer.isDemo else { return answer.totalNanos }
        var total: Int64 = 0
        for line in answer.lines {
            guard let price = ModelPricing.price(for: line.model) else { return nil }
            total = UsageArithmetic.add(total, price.cost(of: line.usage))
        }
        return total
    }

    /// One tooltip row's cost at list prices across the answer's lines (`part` keeps the row's tokens), or nil when a
    /// line with tokens in the row has no list price.
    private static func rowCost(_ answer: AnswerUsage, part: (TokenUsage) -> TokenUsage) -> Int64? {
        var total: Int64 = 0
        for line in answer.lines {
            let slice = part(line.usage)
            if slice.isEmpty { continue }
            guard let price = ModelPricing.price(for: line.model) else { return nil }
            total = UsageArithmetic.add(total, price.cost(of: slice))
        }
        return total
    }

    /// Whole percent of the prompt read from the cache, when reads are at least 1 %. Never rounds up to 100 %
    /// unless the whole prompt was cached.
    private static func cachedPercent(_ usage: TokenUsage) -> Int? {
        guard usage.cacheRead > 0, let share = usage.cachedShare, share >= 0.01 else { return nil }
        let percent = Int((share * 100).rounded())
        return usage.cacheRead < usage.promptTokens ? min(percent, 99) : percent
    }

    /// `value / unit`, rounded half up.
    private static func rounded(_ value: Int64, to unit: Int64) -> Int64 {
        value / unit + (value % unit >= (unit + 1) / 2 ? 1 : 0)
    }

    /// "12.4" from 124; "10" from 100.
    private static func decimal(_ tenths: Int64) -> String {
        tenths % 10 == 0 ? grouped(tenths / 10) : "\(grouped(tenths / 10)).\(tenths % 10)"
    }

    private static func twoDigits(_ value: Int64) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// Thousands separated by commas: "1,204".
    private static func grouped(_ value: Int64) -> String {
        let digits = Array(String(value))
        var result = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(digit)
        }
        return result
    }
}
