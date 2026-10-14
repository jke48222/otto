//
//  ScriptedResponsesTransport.swift
//  Otto
//
//  A test ResponsesTransport that replays one scripted attempt per request and records every request body.
//

import Foundation
@testable import Otto

/// A ResponsesTransport that replays one scripted attempt per call and records each body it was sent.
final class ScriptedResponsesTransport: ResponsesTransport, @unchecked Sendable {
    enum Attempt {
        /// Yields the events, then finishes.
        case events([JSONValue])
        /// Yields `prefix`, then throws `error` (a `ResponsesTransportError`, or anything else).
        case failure(Error, after: [JSONValue])
        /// Yields the events and then never finishes; only cancellation ends it.
        case stall([JSONValue])

        /// Yields a `ResponsesFixtures` scenario (one JSON event per line), then finishes.
        static func lines(_ lines: [String]) -> Attempt {
            .events(lines.map(ScriptedResponsesTransport.decode))
        }

        /// Yields the first `count` events of a scenario, then never finishes.
        static func stall(lines: [String], count: Int) -> Attempt {
            .stall(lines.prefix(count).map(ScriptedResponsesTransport.decode))
        }
    }

    private let lock = NSLock()
    private var attempts: [Attempt]
    private var recordedBodies: [JSONValue] = []
    private var recordedCancellations = 0
    private var cancellationHandler: (@Sendable () -> Void)?

    init(_ attempts: [Attempt]) {
        self.attempts = attempts
    }

    /// Every request body, in order.
    var bodies: [JSONValue] { lock.withLock { recordedBodies } }
    /// How many of the streams were cancelled by their consumer.
    var cancellations: Int { lock.withLock { recordedCancellations } }

    /// Called each time a consumer cancels a stream.
    func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { cancellationHandler = handler }
    }

    func events(for body: JSONValue) -> AsyncThrowingStream<JSONValue, Error> {
        let attempt: Attempt? = lock.withLock {
            recordedBodies.append(body)
            return attempts.isEmpty ? nil : attempts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination, let self else { return }
                let handler = self.lock.withLock { () -> (@Sendable () -> Void)? in
                    self.recordedCancellations += 1
                    return self.cancellationHandler
                }
                handler?()
            }
            switch attempt {
            case .events(let events):
                events.forEach { continuation.yield($0) }
                continuation.finish()
            case .failure(let error, let prefix):
                prefix.forEach { continuation.yield($0) }
                continuation.finish(throwing: error)
            case .stall(let events):
                events.forEach { continuation.yield($0) }
            case nil:
                continuation.finish(throwing: ResponsesTransportError.network("No scripted attempt left."))
            }
        }
    }

    static func decode(_ line: String) -> JSONValue {
        do {
            return try JSONValue.decode(line)
        } catch {
            preconditionFailure("Fixture line is not JSON: \(line)")
        }
    }
}
