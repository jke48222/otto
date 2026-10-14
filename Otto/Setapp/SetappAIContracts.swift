//
//  SetappAIContracts.swift
//  Otto
//
//  The account side of Setapp AI (SPEC §19, "Setapp AI"): the member's AI credit balance and the way to buy more.
//  Compiled into every Mac flavor so Settings, the reply footer, snapshots and tests can use it; only
//  `LiveSetappAIAccount` (Setapp build) calls the Setapp Framework. Change these only in coordination with every
//  caller.
//

import Foundation
import Observation

/// A credit balance as Setapp reports it (`SetappManager.shared.ai.credits.balances()`): what's left across every
/// bucket, and the plan's full grant.
struct SetappCreditBalance: Equatable, Sendable {
    var available: Decimal
    var granted: Decimal

    /// `available / granted` clamped to 0...1, or nil when there is no grant to divide by (no AI plan, or a
    /// currency Otto doesn't know). A bonus grant can leave `available` above `granted`; that reads as full.
    var fraction: Double? {
        guard granted > 0 else { return nil }
        let ratio = NSDecimalNumber(decimal: available / granted).doubleValue
        guard ratio.isFinite else { return nil }
        return min(1, max(0, ratio))
    }
}

/// Where the balance stands. A real zero is `.loaded` with `available == 0`, never `.failed`.
enum SetappCreditState: Equatable, Sendable {
    case idle
    case loading
    case loaded(SetappCreditBalance)
    /// User-facing copy ("Couldn't load your credits. Make sure Setapp is open.").
    case failed(String)
}

/// The member's Setapp AI account, as Settings → Models and the reply footer see it.
@MainActor protocol SetappAIAccountModel: AnyObject, Observable {
    /// False when the build has no OAuth client (J22): Settings says so and offers the user's own key instead.
    var isConfigured: Bool { get }
    var creditState: SetappCreditState { get }
    /// Loads the balance. `force` skips the SDK's cache (after a reply, or "Try Again"). The live model bounds
    /// the call at 15 s, since a stalled Setapp handshake would otherwise never return.
    func refreshCredits(force: Bool)
    /// Setapp's page for buying AI credits: the SDK's `links.purchaseURL()`, asked for each time because Setapp may
    /// change it, when that is an https link; else `SetappCreditFormatter.fallbackPurchaseURL`. Never throws. The
    /// caller opens it the way its window opens links (Settings drops its floating panel first; the notch closes).
    func purchaseURL() async -> URL
}

/// Tests, previews and snapshots. Records calls ("refresh", "refresh(force)", "purchaseURL") and changes nothing
/// else.
@MainActor @Observable final class StaticSetappAIAccount: SetappAIAccountModel {
    var isConfigured: Bool
    var creditState: SetappCreditState
    /// What `purchaseURL()` returns.
    var purchaseLink: URL
    private(set) var calls: [String] = []

    init(isConfigured: Bool = true, creditState: SetappCreditState = .idle,
         purchaseLink: URL = SetappCreditFormatter.fallbackPurchaseURL) {
        self.isConfigured = isConfigured
        self.creditState = creditState
        self.purchaseLink = purchaseLink
    }

    func refreshCredits(force: Bool) { calls.append(force ? "refresh(force)" : "refresh") }

    func purchaseURL() async -> URL {
        calls.append("purchaseURL")
        return purchaseLink
    }
}

enum SetappCreditFormatter {
    /// Setapp's page about AI plans, for when the SDK can't hand over its purchase link.
    static let fallbackPurchaseURL = URL(string: "https://setapp.com/ai")!

    /// "1,999" for 1999.6: credits round down, so Otto never shows credits the member doesn't have.
    static func credits(_ amount: Decimal) -> String {
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .down)
        return rounded.formatted(.number.grouping(.automatic).precision(.fractionLength(0)))
    }

    /// "1,234 of 6,000 credits left", or "1,234 credits left" with no grant to compare against.
    static func summary(_ balance: SetappCreditBalance) -> String {
        let left = credits(balance.available)
        guard balance.granted > 0 else { return "\(left) credits left" }
        return "\(left) of \(credits(balance.granted)) credits left"
    }
}
