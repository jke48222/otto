//
//  ShortcutSettings.swift
//  Otto
//
//  The global shortcut: the stored combo, plus the transient recorder and registration state the
//  Settings pane shows. Registering goes through a closure the app composition installs, so this type
//  never talks to Carbon itself.
//

import Foundation
import Observation

@MainActor @Observable final class ShortcutSettings {
    enum Keys {
        static let hotKey = "otto.shortcuts.hotKey"
    }

    /// The combo that toggles the notch (and, held, starts voice). Stored as JSON data.
    var hotKey: HotKeyCombo {
        didSet { store.setEncoded(hotKey, Keys.hotKey) }
    }

    // Transient (not persisted):

    /// Recorder active → the router unregisters the hot key.
    var isRecording = false
    var status: HotKeyStatus = .disabled
    /// Set by AppComposition: registers a combo and reports whether it took.
    @ObservationIgnored var registrar: ((HotKeyCombo) -> HotKeyApplyResult)?

    @ObservationIgnored private let store: PreferenceStore

    init(store: PreferenceStore) {
        self.store = store
        hotKey = store.decoded(Keys.hotKey, as: HotKeyCombo.self) ?? .optionSpace
    }

    /// Validates (the caller passes `validationMessage` from HotKeyCombo's validation), registers through
    /// `registrar`, persists on success. Without a registrar (tests, inert graphs) there is nothing to register,
    /// so a valid combo is simply stored.
    func apply(_ combo: HotKeyCombo, validationMessage: String?) -> HotKeyApplyResult {
        if let validationMessage { return .rejected(validationMessage) }
        let result = registrar?(combo) ?? .applied
        if result == .applied, hotKey != combo {
            hotKey = combo
        }
        return result
    }
}
