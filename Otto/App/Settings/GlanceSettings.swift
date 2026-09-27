//
//  GlanceSettings.swift
//  Otto
//
//  What the closed notch may show: reply previews, notifications, Now Playing and the next meeting.
//

import Foundation
import Observation

@MainActor @Observable final class GlanceSettings {
    enum Keys {
        static let replyPreviews = "otto.glance.replyPreviews"
        static let notificationPolicy = "otto.glance.notificationPolicy"
        static let notificationIncludesPreview = "otto.glance.notificationPreview"
        static let nowPlayingEnabled = "otto.glance.nowPlaying"
        static let nowPlayingInClosedNotch = "otto.glance.nowPlayingClosed"
        static let calendarChipEnabled = "otto.glance.calendarChip"
        static let calendarExcludedIDs = "otto.glance.calendarExcluded"
    }

    /// The first line of a finished reply drops below the closed notch.
    var replyPreviews: Bool {
        didSet { store.set(replyPreviews, Keys.replyPreviews) }
    }

    var notificationPolicy: ReplyNotificationPolicy {
        didSet { store.set(notificationPolicy.rawValue, Keys.notificationPolicy) }
    }

    /// Notifications show the reply's first line (never on the lock screen).
    var notificationIncludesPreview: Bool {
        didSet { store.set(notificationIncludesPreview, Keys.notificationIncludesPreview) }
    }

    var nowPlayingEnabled: Bool {
        didSet { store.set(nowPlayingEnabled, Keys.nowPlayingEnabled) }
    }

    var nowPlayingInClosedNotch: Bool {
        didSet { store.set(nowPlayingInClosedNotch, Keys.nowPlayingInClosedNotch) }
    }

    var calendarChipEnabled: Bool {
        didSet { store.set(calendarChipEnabled, Keys.calendarChipEnabled) }
    }

    /// Calendar identifiers the next-meeting chip ignores.
    var calendarExcludedIDs: [String] {
        didSet { store.set(calendarExcludedIDs, Keys.calendarExcludedIDs) }
    }

    @ObservationIgnored private let store: PreferenceStore

    init(store: PreferenceStore) {
        self.store = store
        replyPreviews = store.bool(Keys.replyPreviews, true)
        notificationPolicy = store.value(Keys.notificationPolicy, ReplyNotificationPolicy.off)
        notificationIncludesPreview = store.bool(Keys.notificationIncludesPreview, true)
        nowPlayingEnabled = store.bool(Keys.nowPlayingEnabled, false)
        nowPlayingInClosedNotch = store.bool(Keys.nowPlayingInClosedNotch, true)
        calendarChipEnabled = store.bool(Keys.calendarChipEnabled, false)
        calendarExcludedIDs = store.strings(Keys.calendarExcludedIDs, [])
    }
}
