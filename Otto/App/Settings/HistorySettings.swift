//
//  HistorySettings.swift
//  Otto
//
//  Local conversation history: on or off, how long conversations are kept, when an idle notch starts a
//  fresh chat, and whether the first-run notice was answered.
//

import Foundation
import Observation

@MainActor @Observable final class HistorySettings {
    enum Keys {
        static let enabled = "otto.history.enabled"
        static let retention = "otto.history.retention"
        static let idleReset = "otto.history.idleReset"
        static let noticeAcknowledged = "otto.history.noticeAcknowledged"
    }

    var enabled: Bool {
        didSet { store.set(enabled, Keys.enabled) }
    }

    var retention: HistoryRetention {
        didSet { store.set(retention.rawValue, Keys.retention) }
    }

    var idleReset: IdleResetInterval {
        didSet { store.set(idleReset.rawValue, Keys.idleReset) }
    }

    var noticeAcknowledged: Bool {
        didSet { store.set(noticeAcknowledged, Keys.noticeAcknowledged) }
    }

    @ObservationIgnored private let store: PreferenceStore

    init(store: PreferenceStore) {
        self.store = store
        enabled = store.bool(Keys.enabled, true)
        retention = store.value(Keys.retention, HistoryRetention.month)
        idleReset = store.value(Keys.idleReset, IdleResetInterval.fifteenMinutes)
        noticeAcknowledged = store.bool(Keys.noticeAcknowledged, false)
    }
}
