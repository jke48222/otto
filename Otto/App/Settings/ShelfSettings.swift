//
//  ShelfSettings.swift
//  Otto
//
//  The File Shelf: whether the drop zone exists, and whether a file stays on the Shelf after it is
//  dragged out.
//

import Foundation
import Observation

@MainActor @Observable final class ShelfSettings {
    enum Keys {
        static let enabled = "otto.shelf.enabled"
        static let keepAfterDragOut = "otto.shelf.keepAfterDragOut"
    }

    var enabled: Bool {
        didSet { store.set(enabled, Keys.enabled) }
    }

    var keepAfterDragOut: Bool {
        didSet { store.set(keepAfterDragOut, Keys.keepAfterDragOut) }
    }

    @ObservationIgnored private let store: PreferenceStore

    init(store: PreferenceStore) {
        self.store = store
        enabled = store.bool(Keys.enabled, true)
        keepAfterDragOut = store.bool(Keys.keepAfterDragOut, false)
    }
}
