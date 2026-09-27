//
//  NotchSettings.swift
//  Otto
//
//  How the notch opens: hover to open, type after hovering, and the notch apps the user already said
//  Otto may share the notch with.
//

import Foundation
import Observation

@MainActor @Observable final class NotchSettings {
    enum Keys {
        static let hoverToOpen = "otto.notch.hoverToOpen"
        static let typeAfterHover = "otto.notch.typeAfterHover"
        static let acknowledgedNeighbors = "otto.notch.acknowledgedNeighbors"
    }

    /// Resting the pointer on the notch opens it.
    var hoverToOpen: Bool {
        didSet { store.set(hoverToOpen, Keys.hoverToOpen) }
    }

    /// Typing right after a hover-open goes into Otto's composer (soft focus).
    var typeAfterHover: Bool {
        didSet { store.set(typeAfterHover, Keys.typeAfterHover) }
    }

    /// Names of other notch apps whose coexistence card the user has answered.
    var acknowledgedNeighbors: [String] {
        didSet { store.set(acknowledgedNeighbors, Keys.acknowledgedNeighbors) }
    }

    @ObservationIgnored private let store: PreferenceStore

    init(store: PreferenceStore) {
        self.store = store
        hoverToOpen = store.bool(Keys.hoverToOpen, true)
        typeAfterHover = store.bool(Keys.typeAfterHover, true)
        acknowledgedNeighbors = store.strings(Keys.acknowledgedNeighbors, [])
    }
}
