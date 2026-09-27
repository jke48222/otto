//
//  NotchServices.swift
//  Otto
//
//  The subsystems the notch view model reads and drives, handed over in one value. AppComposition builds the
//  live set; `inert` builds one for tests, snapshots, promo and the self-test that keeps everything in memory
//  and never touches the system or the user's data.
//

import AppKit
import Foundation

@MainActor struct NotchServices {
    var permissions: PermissionsCenter
    var approvals: ApprovalStore
    var voice: VoiceController
    var history: HistoryController
    var recents: RecentsState
    var glance: GlanceController
    var ledger: UsageLedger
    var nowPlaying: NowPlayingMonitor
    var calendar: CalendarGlance
    var shelf: ShelfController
    var suggestions: ContextSuggestions
    var inserter: InsertCoordinator
    var notifications: NotificationPresenter?

    /// Tests, snapshots, promo: in-memory stores, monitors never started, never touches the user's data or the
    /// system. PermissionsCenter(probe: StaticPermissionProbe([:], default: .notDetermined), openURL: { _ in },
    /// relauncher: a no-op), ContextSuggestions with `InertSelectionReader()` + `InertWindowCapture()` (never offers a
    /// chip), NowPlayingMonitor(scripting: DemoMediaScripting()), CalendarGlance(store: InertCalendarSource()),
    /// VoiceController(settings:, makeEngine: { ScriptedSpeechEngine(script: []) }, interruptions:
    /// InertVoiceInterruptions(), holdProbe: { _ in nil }), in-memory History/Shelf/ledger
    /// (HistoryController.start() is never called, so the history notice never shows), no notifications.
    static func inert(settings: AppSettings, chat: ChatSession) -> NotchServices {
        let permissions = PermissionsCenter(probe: StaticPermissionProbe([:], default: .notDetermined),
                                            defaults: InertStorage.makeDefaults(),
                                            openURL: { _ in },
                                            relauncher: InertRelauncher())
        let history = HistoryController(settings: settings, chat: chat, store: ConversationStore(location: .inMemory))
        let environment = LiveInsertEnvironment(permissions: permissions)
        // A private pasteboard: nothing an inert graph does can reach the user's clipboard.
        let inserter = AnswerInserter(pasteboard: NSPasteboard.withUniqueName(), environment: environment)
        return NotchServices(
            permissions: permissions,
            approvals: ApprovalStore(defaults: InertStorage.makeDefaults()),
            voice: VoiceController(settings: settings,
                                   makeEngine: { ScriptedSpeechEngine(script: []) },
                                   interruptions: InertVoiceInterruptions(),
                                   holdProbe: { _ in nil }),
            history: history,
            recents: RecentsState(history: history),
            glance: GlanceController.inert(settings: settings, chat: chat),
            ledger: UsageLedger(fileURL: nil),
            nowPlaying: NowPlayingMonitor(settings: settings, scripting: DemoMediaScripting()),
            calendar: CalendarGlance(settings: settings, store: InertCalendarSource()),
            shelf: ShelfController(store: ShelfStore(directory: nil), settings: settings),
            suggestions: ContextSuggestions(settings: settings, permissions: permissions,
                                            reader: InertSelectionReader(), capture: InertWindowCapture()),
            inserter: InsertCoordinator(inserter: inserter, settings: settings),
            notifications: nil
        )
    }
}

/// "Quit & Reopen Otto" in an inert graph: nothing to relaunch.
private struct InertRelauncher: AppRelaunching {
    func relaunch() {}
}

/// Preferences an inert graph writes (permission prompt flags, consents) go to a throwaway domain, never to the
/// user's own `otto.*` keys.
private enum InertStorage {
    static func makeDefaults() -> UserDefaults {
        let suiteName = "com.jalenedusei.otto.inert.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return UserDefaults() }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
