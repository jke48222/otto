//
//  ContextSettings.swift
//  Otto
//
//  What Otto offers from the app you came from (the selected text, the window) and whether it puts
//  your clipboard back after pasting an answer.
//

import Foundation
import Observation

@MainActor @Observable final class ContextSettings {
    enum Keys {
        static let offerSelection = "otto.context.offerSelection"
        static let offerWindow = "otto.context.offerWindow"
        static let restoreClipboard = "otto.context.restoreClipboard"
    }

    /// Offer the text selected in the previous app as a chip (needs Accessibility).
    var offerSelection: Bool {
        didSet { store.set(offerSelection, Keys.offerSelection) }
    }

    /// Offer a "Window: ‹App›" chip (no pixels are read until it is tapped).
    var offerWindow: Bool {
        didSet { store.set(offerWindow, Keys.offerWindow) }
    }

    /// Put the clipboard back after Otto pastes an answer.
    var restoreClipboard: Bool {
        didSet { store.set(restoreClipboard, Keys.restoreClipboard) }
    }

    @ObservationIgnored private let store: PreferenceStore

    init(store: PreferenceStore) {
        self.store = store
        offerSelection = store.bool(Keys.offerSelection, false)
        offerWindow = store.bool(Keys.offerWindow, true)
        restoreClipboard = store.bool(Keys.restoreClipboard, true)
    }
}
