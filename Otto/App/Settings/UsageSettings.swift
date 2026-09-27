//
//  UsageSettings.swift
//  Otto
//
//  Whether replies show what they cost.
//

import Foundation
import Observation

@MainActor @Observable final class UsageSettings {
    enum Keys {
        static let showCost = "otto.usage.showCost"
    }

    /// The cost label on reply hover.
    var showCost: Bool {
        didSet { store.set(showCost, Keys.showCost) }
    }

    @ObservationIgnored private let store: PreferenceStore

    init(store: PreferenceStore) {
        self.store = store
        showCost = store.bool(Keys.showCost, true)
    }
}
