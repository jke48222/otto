//
//  OttoShortcuts.swift
//  Otto
//
//  The phrases Siri and Spotlight offer for Otto's intents, with no setup in the Shortcuts app.
//

import AppIntents

struct OttoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskOttoIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
            ],
            shortTitle: "Ask Otto",
            systemImageName: "sparkle"
        )
        AppShortcut(
            intent: NewOttoChatIntent(),
            phrases: [
                "New chat in \(.applicationName)",
                "Start a new \(.applicationName) chat",
            ],
            shortTitle: "New Chat",
            systemImageName: "square.and.pencil"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .grayBlue
}
