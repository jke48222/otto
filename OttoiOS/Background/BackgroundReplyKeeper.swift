//
//  BackgroundReplyKeeper.swift
//  Otto
//
//  Keeps a reply streaming after you leave Otto, the iPhone's version of closing the notch mid-answer. iOS gives
//  an app that asks a short stretch of background time (usually about half a minute); the keeper holds it while a
//  reply runs and hands it back as soon as the reply settles. If time runs out first, `onExpiration` stops the
//  reply where it is, so it can be continued with Retry.
//

import UIKit
import os

/// The system's background-time API, behind a seam so tests never touch UIApplication.
@MainActor protocol BackgroundTimeProviding: AnyObject {
    func beginBackgroundTask(named name: String, expiration: @escaping @MainActor () -> Void) -> Int?
    func endBackgroundTask(_ token: Int)
}

@MainActor final class SystemBackgroundTime: BackgroundTimeProviding {
    nonisolated init() {}

    func beginBackgroundTask(named name: String, expiration: @escaping @MainActor () -> Void) -> Int? {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            // UIKit calls this on the main thread and expects the task ended before it returns.
            MainActor.assumeIsolated { expiration() }
        }
        return identifier == .invalid ? nil : identifier.rawValue
    }

    func endBackgroundTask(_ token: Int) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
    }
}

@MainActor final class BackgroundReplyKeeper {
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Chat")
    static let taskName = "Otto reply"

    /// Called when the time ran out with the reply still running; it must leave the reply settled.
    var onExpiration: (() -> Void)?

    private let time: BackgroundTimeProviding
    private var token: Int?

    init(time: BackgroundTimeProviding = SystemBackgroundTime()) {
        self.time = time
    }

    var isHolding: Bool { token != nil }

    /// Otto left the foreground with a reply running. Idempotent.
    func begin() {
        guard token == nil else { return }
        token = time.beginBackgroundTask(named: Self.taskName) { [weak self] in
            self?.expire()
        }
        if token != nil {
            Self.logger.info("Holding background time for the reply")
        }
    }

    /// The reply settled, or Otto came back to the foreground. Idempotent.
    func end() {
        guard let token else { return }
        self.token = nil
        time.endBackgroundTask(token)
        Self.logger.info("Released background time")
    }

    private func expire() {
        guard token != nil else { return }
        Self.logger.notice("Background time ran out with the reply still running")
        onExpiration?()
        end()
    }
}
