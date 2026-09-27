//
//  UsageContracts.swift
//  Otto
//
//  How ChatSession reports token usage: one call per Messages API response (or a partial one), then
//  one call when the reply settles.
//

import Foundation

@MainActor protocol UsageRecording: AnyObject {
    /// One Messages API response (or a partial one). `usage` is the raw `usage` object (may carry `iterations`).
    func record(usage: JSONValue?, requestedModel: String, servedModel: String?, stopReason: String?,
                isPartial: Bool, messageID: UUID, at date: Date)
    /// The turn settled (counts one reply).
    func finishAnswer(messageID: UUID)
}
