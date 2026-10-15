//
//  LiveSetappAIAccount.swift
//  Otto
//
//  The member's Setapp AI account in the Setapp build (SPEC §19, "Setapp AI"): the credit balance from
//  `SetappManager.shared.ai.credits` and the purchase page's address from `ai.links`. Settings → Models and the reply
//  footer see it as `SetappAIAccountModel`; tests and snapshots use `StaticSetappAIAccount`.
//

#if OTTO_SETAPP
import Foundation
import Observation
import os
import Setapp
import SetappAI

@MainActor @Observable final class LiveSetappAIAccount: SetappAIAccountModel {
    typealias BalanceFetcher = @Sendable (_ forceUpdate: Bool) async throws -> SetappAIAPI.Credits.Balances
    typealias PurchaseLinkFetcher = @Sendable () async throws -> URL?

    /// A forced refresh is a bare XPC round trip to Setapp with no bound of its own; a stalled handshake would
    /// otherwise leave the row loading for the rest of the session.
    nonisolated static let balanceTimeout: Duration = .seconds(15)
    /// `purchaseURL()` falls back to `SetappCreditFormatter.fallbackPurchaseURL` after this long.
    nonisolated static let purchaseLinkTimeout: Duration = .seconds(5)

    nonisolated static let loadFailedCopy = "Couldn't load your credits. Make sure Setapp is open."
    nonisolated static let unknownUnitCopy = "Setapp reported credits in a unit Otto doesn't know."

    let isConfigured: Bool
    private(set) var creditState: SetappCreditState = .idle

    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private let fetchBalances: BalanceFetcher
    @ObservationIgnored private let fetchPurchaseLink: PurchaseLinkFetcher
    @ObservationIgnored private let balanceTimeout: Duration
    @ObservationIgnored private let purchaseLinkTimeout: Duration

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "SetappAI")

    /// The live account: configures Setapp AI from Info.plist (J22) and talks to the Setapp Framework.
    convenience init() {
        self.init(
            isConfigured: SetappSDKTransport.configureIfNeeded(),
            fetchBalances: { try await SetappManager.shared.ai.credits.balances(forceUpdate: $0) },
            fetchPurchaseLink: { try await SetappManager.shared.ai.links.purchaseURL() }
        )
    }

    /// Tests: scripted SDK calls and short timeouts.
    init(
        isConfigured: Bool,
        fetchBalances: @escaping BalanceFetcher,
        fetchPurchaseLink: @escaping PurchaseLinkFetcher,
        balanceTimeout: Duration = LiveSetappAIAccount.balanceTimeout,
        purchaseLinkTimeout: Duration = LiveSetappAIAccount.purchaseLinkTimeout
    ) {
        self.isConfigured = isConfigured
        self.fetchBalances = fetchBalances
        self.fetchPurchaseLink = fetchPurchaseLink
        self.balanceTimeout = balanceTimeout
        self.purchaseLinkTimeout = purchaseLinkTimeout
    }

    // MARK: - SetappAIAccountModel

    /// Keeps a loaded balance on screen while it refreshes (`.loading` only from `.idle` or `.failed`), ignores a
    /// call while one is in flight, and does nothing in a build without an OAuth client: there is no balance to ask
    /// for, and Settings already says Setapp AI isn't set up.
    func refreshCredits(force: Bool) {
        guard isConfigured, !isRefreshing else { return }
        isRefreshing = true
        switch creditState {
        case .idle, .failed: creditState = .loading
        case .loading, .loaded: break
        }
        let fetch = fetchBalances
        let timeout = balanceTimeout
        Task { [weak self] in
            let result = await SetappCallTimeout.race(timeout: timeout) { try await fetch(force) }
            guard let self else { return }
            self.isRefreshing = false
            if case .failure(let error) = result {
                Self.logger.error("Couldn't load Setapp AI credits: \(LoggedError(error), privacy: .public)")
            }
            self.creditState = Self.state(for: result)
        }
    }

    /// Asks the SDK for the current purchase link (Setapp may change it); Setapp's AI page when the SDK has none,
    /// fails, hands over something other than an https page, or takes longer than `purchaseLinkTimeout`.
    func purchaseURL() async -> URL {
        let fetch = fetchPurchaseLink
        let result = await SetappCallTimeout.race(timeout: purchaseLinkTimeout) { try await fetch() }
        let link = (try? result.get()) ?? nil
        let url = Self.purchaseURL(link)
        if url != link { Self.logger.info("No usable purchase link from Setapp; using the fallback page") }
        return url
    }

    // MARK: - Pure mapping

    /// The state a finished fetch leaves. A real zero is `.loaded`; a grant in a unit Otto doesn't know reads as no
    /// grant, so the row shows the balance without a bar.
    nonisolated static func state(for result: Result<SetappAIAPI.Credits.Balances, Error>) -> SetappCreditState {
        guard case .success(let balances) = result else { return .failed(loadFailedCopy) }
        guard isCredits(balances.totalAvailable.currency) else { return .failed(unknownUnitCopy) }
        let granted = isCredits(balances.totalInitialAmount.currency) ? balances.totalInitialAmount.amount : 0
        return .loaded(SetappCreditBalance(available: balances.totalAvailable.amount, granted: granted))
    }

    /// The SDK's link when it is an https page, else the fallback. Plain http is refused: a purchase page has no
    /// business arriving unencrypted.
    nonisolated static func purchaseURL(_ link: URL?) -> URL {
        guard let link, link.scheme?.lowercased() == "https", link.host?.isEmpty == false else {
            return SetappCreditFormatter.fallbackPurchaseURL
        }
        return link
    }

    nonisolated private static func isCredits(_ currency: SetappAIAPI.Credits.Amount.Currency) -> Bool {
        if case .macpawCredits = currency { return true }
        return false
    }
}

/// Bounds a Setapp Framework call. A task group can't do it: the group waits for every child, and an XPC call into
/// Setapp doesn't stop when its task is cancelled. Here the caller resumes at the deadline and the call, if it ever
/// returns, is ignored.
enum SetappCallTimeout {
    struct TimedOut: Error, CustomStringConvertible {
        let limit: Duration
        var description: String { "timed out after \(limit)" }
    }

    static func race<T: Sendable>(timeout: Duration, _ operation: @escaping @Sendable () async throws -> T) async
        -> Result<T, Error> {
        let gate = Gate<T>()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            let work = Task.detached {
                do { gate.resume(.success(try await operation())) } catch { gate.resume(.failure(error)) }
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                if gate.resume(.failure(TimedOut(limit: timeout))) { work.cancel() }
            }
        }
    }

    /// Resumes the continuation once, with whichever result comes first. `install` runs before either task starts.
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<T, Error>, Never>?

        func install(_ continuation: CheckedContinuation<Result<T, Error>, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        /// True when this call delivered the result.
        @discardableResult
        func resume(_ result: Result<T, Error>) -> Bool {
            let continuation = lock.withLock { () -> CheckedContinuation<Result<T, Error>, Never>? in
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(returning: result)
            return continuation != nil
        }
    }
}
#endif
