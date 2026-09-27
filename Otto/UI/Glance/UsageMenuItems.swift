//
//  UsageMenuItems.swift
//  Otto
//
//  The Usage section of the ⋮ menu: today's and this month's estimated cost as two informational
//  rows, and "Usage Details…", which opens Settings on the Models tab's Usage section.
//

import SwiftUI

struct UsageMenuItems: View {
    let ledger: UsageLedger
    /// The view model's `openUsageDetails()`.
    let onOpenDetails: () -> Void

    static let sectionTitle = "Usage"
    static let detailsTitle = "Usage Details…"

    /// Pure. "≈12¢" at list prices, "12.4k tokens" when only unpriced models were used, "0¢" when
    /// nothing was.
    static func amount(_ totals: UsageTotals) -> String {
        if totals.costNanos == 0, totals.unpricedTokens > 0 {
            return CostFormatter.tokens(totals.unpricedTokens) + " tokens"
        }
        return CostFormatter.short(totals.costNanos)
    }

    /// Pure. "Today  ≈12¢ · 8 replies".
    static func todayTitle(_ totals: UsageTotals) -> String {
        "Today  \(amount(totals)) · \(replies(totals.replies))"
    }

    /// Pure. "This month  ≈$3.40".
    static func monthTitle(_ totals: UsageTotals) -> String {
        "This month  \(amount(totals))"
    }

    /// Pure. "1 reply", "8 replies".
    static func replies(_ count: Int) -> String {
        count == 1 ? "1 reply" : "\(max(count, 0)) replies"
    }

    var body: some View {
        Section(Self.sectionTitle) {
            // Plain text in a menu is an inert, dimmed row: these read as values, not commands.
            Text(Self.todayTitle(ledger.today))
            Text(Self.monthTitle(ledger.thisMonth))
            Button(Self.detailsTitle, systemImage: "chart.bar", action: onOpenDetails)
                .keyboardShortcut("u", modifiers: [.command, .option])
        }
    }
}
