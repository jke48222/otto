//
//  ScriptedLLMClient.swift
//  Otto
//
//  A test LLMClient that replays scripted responses and records the requests it was sent.
//

import Foundation
@testable import Otto

/// An LLMClient that replays one scripted response per request and records every request.
final class ScriptedLLMClient: LLMClient, @unchecked Sendable {
    enum Response {
        /// Yields the events, then finishes.
        case events([StreamEvent])
        /// Yields `prefix`, then throws `error`.
        case failure(Error, after: [StreamEvent])
        /// Yields the events and then never finishes; only cancellation ends it.
        case stall([StreamEvent])
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var recordedRequests: [MessagesRequest] = []
    private var recordedCancellations = 0

    init(_ responses: [Response]) {
        self.responses = responses
    }

    var requests: [MessagesRequest] { lock.withLock { recordedRequests } }
    var cancellations: Int { lock.withLock { recordedCancellations } }

    func stream(_ request: MessagesRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let response: Response? = lock.withLock {
            recordedRequests.append(request)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination, let self else { return }
                self.lock.withLock { self.recordedCancellations += 1 }
            }
            switch response {
            case .events(let events):
                events.forEach { continuation.yield($0) }
                continuation.finish()
            case .failure(let error, let prefix):
                prefix.forEach { continuation.yield($0) }
                continuation.finish(throwing: error)
            case .stall(let events):
                events.forEach { continuation.yield($0) }
            case nil:
                continuation.finish(throwing: LLMError.network("No scripted response left."))
            }
        }
    }
}
