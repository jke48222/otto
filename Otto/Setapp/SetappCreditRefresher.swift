//
//  SetappCreditRefresher.swift
//  Otto
//
//  Keeps the Setapp AI balance current while Setapp AI answers (SPEC §19, "Setapp AI"): Setapp counts credits for
//  each reply, so a balance read before the reply is stale after it. Compiled into every Mac flavor so tests can
//  drive it with a StaticSetappAIAccount; only the Setapp build's composition installs it.
//

import Foundation

@MainActor final class SetappCreditRefresher {
    /// How long a finished reply waits before the balance is fetched. Another reply that finishes inside it (a quick
    /// Retry, a regenerate) restarts the wait, so a burst costs one SDK call.
    nonisolated static let settleDelay: Duration = .seconds(2)

    private let account: any SetappAIAccountModel
    private let delay: Duration
    private var loop: ObservationLoop<Bool>?
    private var pending: Task<Void, Never>?

    /// Watches `chat` and refreshes `account` (past the SDK's cache) once each reply has finished, while
    /// `isUsingSetappAI` says Setapp AI answers. A reply that ran out of credits refreshes at once, whatever the
    /// provider is by then, since that failure only comes from Setapp AI.
    init(account: any SetappAIAccountModel, chat: ChatSession, isUsingSetappAI: @escaping @MainActor () -> Bool,
         settleDelay: Duration = SetappCreditRefresher.settleDelay) {
        self.account = account
        self.delay = settleDelay
        // A turn streams from send to its end, every tool round and approval included, so this changes once a
        // reply, not once a request.
        loop = ObservationLoop(read: { chat.isStreaming }) { [weak self] isStreaming in
            guard !isStreaming, let self else { return }
            if chat.lastMessageState == .failed(SetappAIFailure.insufficientCredits.copy) {
                self.refreshNow()
            } else if isUsingSetappAI() {
                self.refreshSoon()
            }
        }
    }

    /// Stops watching and drops a refresh that hasn't run. Idempotent.
    func cancel() {
        loop?.cancel()
        loop = nil
        pending?.cancel()
        pending = nil
    }

    private func refreshNow() {
        pending?.cancel()
        pending = nil
        account.refreshCredits(force: true)
    }

    private func refreshSoon() {
        pending?.cancel()
        let delay = delay
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.account.refreshCredits(force: true)
        }
    }
}
