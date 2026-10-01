//
//  MobileSettings.swift
//  Otto
//
//  The iPhone app's own preferences: the Live Activity in the Dynamic Island, notifications for replies that
//  finish while Otto is in the background, haptics, demo mode and the first-run screen.
//  Reached as `settings.mobile`; the shared groups (voice, usage, history, actions) cover everything else.
//

import Foundation
import Observation

@MainActor @Observable final class MobileSettings {
    enum Keys {
        static let liveActivities = "otto.ios.liveActivities"
        static let notifyWhenAway = "otto.ios.notifyWhenAway"
        static let notificationPreview = "otto.ios.notificationPreview"
        static let haptics = "otto.ios.haptics"
        static let demoMode = "otto.ios.demoMode"
        static let didFinishOnboarding = "otto.ios.didFinishOnboarding"
    }

    /// A reply in progress shows in the Dynamic Island and on the Lock Screen while Otto is in the background.
    var liveActivities: Bool {
        didSet { store.set(liveActivities, Keys.liveActivities) }
    }

    /// Post "Otto replied" when a reply finishes while Otto is in the background.
    var notifyWhenAway: Bool {
        didSet { store.set(notifyWhenAway, Keys.notifyWhenAway) }
    }

    /// Notifications and the Live Activity may show the reply's first line (marked privacy-sensitive).
    var notificationPreview: Bool {
        didSet { store.set(notificationPreview, Keys.notificationPreview) }
    }

    /// A light tap when a question goes and when a reply arrives on screen.
    var haptics: Bool {
        didSet { store.set(haptics, Keys.haptics) }
    }

    /// Scripted replies from the built-in mock client, with no API key and no network; data lives apart.
    var demoMode: Bool {
        didSet { store.set(demoMode, Keys.demoMode) }
    }

    /// The first-run screen was answered (a key saved, or the demo chosen).
    var didFinishOnboarding: Bool {
        didSet { store.set(didFinishOnboarding, Keys.didFinishOnboarding) }
    }

    @ObservationIgnored private let store: PreferenceStore

    init(store: PreferenceStore) {
        self.store = store
        liveActivities = store.bool(Keys.liveActivities, true)
        notifyWhenAway = store.bool(Keys.notifyWhenAway, false)
        notificationPreview = store.bool(Keys.notificationPreview, true)
        haptics = store.bool(Keys.haptics, true)
        demoMode = store.bool(Keys.demoMode, false)
        didFinishOnboarding = store.bool(Keys.didFinishOnboarding, false)
    }
}
