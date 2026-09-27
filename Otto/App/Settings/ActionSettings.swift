//
//  ActionSettings.swift
//  Otto
//
//  Actions (Claude tools): the master switch, which tool groups are on, how many tool rounds one reply
//  may take, whether the activity log keeps whole AppleScript sources, and the approval safety policy.
//

import Foundation
import Observation

/// How strictly Otto asks before running actions. AppleScript is never approved automatically in either mode.
enum ActionSafetyMode: String, Codable, CaseIterable {
    /// "Always allow" only for your own words with no web content in the chat; web pause; tool runs fold the notch.
    case safer
    /// "Always allow" also after web content; no web pause; tool runs don't fold the notch.
    case fewerPrompts
}

@MainActor @Observable final class ActionSettings {
    enum Keys {
        static let enabled = "otto.actions.enabled"
        static let groups = "otto.actions.groups"
        static let maxToolRounds = "otto.actions.maxToolRounds"
        static let logFullScripts = "otto.actions.logFullScripts"
    }

    static let maxToolRoundsRange: ClosedRange<Int> = 3...25

    /// Master switch; off by default.
    var enabled: Bool {
        didSet { store.set(enabled, Keys.enabled) }
    }

    /// Stored as the sorted raw values.
    var groups: Set<ToolGroup> {
        didSet { store.set(groups.map(\.rawValue).sorted(), Keys.groups) }
    }

    /// Clamped to `maxToolRoundsRange` on read and write.
    var maxToolRounds: Int {
        didSet {
            let clamped = PreferenceStore.clamp(maxToolRounds, to: Self.maxToolRoundsRange)
            if clamped != maxToolRounds { maxToolRounds = clamped }
            store.set(clamped, Keys.maxToolRounds)
        }
    }

    /// Activity log keeps full AppleScript sources (default off: a SHA-256 and the first 200 characters).
    var logFullScripts: Bool {
        didSet { store.set(logFullScripts, Keys.logFullScripts) }
    }

    /// enabled && groups.contains(group).
    func isEnabled(_ group: ToolGroup) -> Bool {
        enabled && groups.contains(group)
    }

    @ObservationIgnored private let store: PreferenceStore

    init(store: PreferenceStore) {
        self.store = store
        enabled = store.bool(Keys.enabled, false)
        let storedGroups = store.strings(Keys.groups, ToolGroup.defaultEnabled.map(\.rawValue).sorted())
        groups = Set(storedGroups.compactMap(ToolGroup.init(rawValue:)))
        maxToolRounds = store.int(Keys.maxToolRounds, 10, in: Self.maxToolRoundsRange)
        logFullScripts = store.bool(Keys.logFullScripts, false)
    }
}
