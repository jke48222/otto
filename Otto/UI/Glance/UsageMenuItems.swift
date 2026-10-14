//
//  UsageMenuItems.swift
//  Otto
//
//  The Usage section of the ⋮ menu: today's and this month's estimated cost as two informational
//  rows, and "Usage Details…", which opens Settings on the Models tab's Usage section. On Setapp AI
//  (§19), which bills in credits, one row with the credit balance replaces the dollar rows.
//

import SwiftUI

struct UsageMenuItems: View {
    let ledger: UsageLedger
    /// The member's credits while Setapp AI answers (`NotchViewModel.setappAICredits`); nil shows the dollar rows.
    var setappAICredits: SetappCreditState? = nil
    /// The view model's `openUsageDetails()`.
    let onOpenDetails: () -> Void

    static let sectionTitle = "Usage"
    static let detailsTitle = "Usage Details…"
    static let setappAINote = "Setapp AI uses credits, not dollars"

    /// Pure. "1,234 of 6,000 credits left" once the balance has loaded, else what Setapp AI bills in.
    static func setappAITitle(_ state: SetappCreditState) -> String {
        guard case .loaded(let balance) = state else { return setappAINote }
        return SetappCreditFormatter.summary(balance)
    }

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
            if let setappAICredits {
                Text(Self.setappAITitle(setappAICredits))
            } else {
                Text(Self.todayTitle(ledger.today))
                Text(Self.monthTitle(ledger.thisMonth))
            }
            Button(Self.detailsTitle, systemImage: "chart.bar", action: onOpenDetails)
                .keyboardShortcut("u", modifiers: [.command, .option])
        }
    }
}
