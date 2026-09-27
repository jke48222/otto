//
//  ShortcutSheetTests.swift
//  OttoTests
//
//  The ⌘/ sheet lists every key-map row that applies to the current settings and pages (voice, the global
//  shortcut, Recents and Shelf, Actions, Now Playing, the meeting chip, the soft-focus note), and the pure
//  helpers of the other chat components: version pager positions, paste-control copy, confirm rows, route
//  pebble badges, the model menu's labels and ghost chip label cleaning.
//

import Carbon.HIToolbox
import XCTest
@testable import Otto

@MainActor
final class ShortcutSheetTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = TestDefaults.make(for: self)
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults, usesKeychain: false)
    }

    private let allRoutes: [NotchRoute] = [.chat, .history, .shelf]

    private func rowIDs(_ sections: [ShortcutSheet.Section]) -> Set<String> {
        Set(sections.flatMap(\.rows).map(\.id))
    }

    private func row(_ id: String, in sections: [ShortcutSheet.Section]) -> ShortcutSheet.Row? {
        sections.flatMap(\.rows).first { $0.id == id }
    }

    private func section(_ kind: ShortcutSheet.Section.Kind, in sections: [ShortcutSheet.Section]) -> ShortcutSheet.Section? {
        sections.first { $0.kind == kind }
    }

    // MARK: Structure

    func testSectionsComeInDisplayOrderWithTitles() {
        let sections = ShortcutSheet.sections(settings: makeSettings(), availableRoutes: allRoutes)
        XCTAssertEqual(sections.map(\.kind), [.conversation, .notch, .actions, .glance])
        XCTAssertEqual(sections.map(\.title), ["Conversation", "Notch", "Actions", "Glance"])
        XCTAssertTrue(sections.allSatisfy { !$0.rows.isEmpty })
    }

    func testRowIDsAreUniqueAndEveryRowHasKeys() {
        let settings = makeSettings()
        settings.voice.enabled = true
        settings.voice.spokenReplies = .always
        settings.actions.enabled = true
        settings.glance.nowPlayingEnabled = true
        settings.glance.calendarChipEnabled = true
        let rows = ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes).flatMap(\.rows)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        for row in rows {
            XCTAssertFalse(row.title.isEmpty, row.id)
            XCTAssertFalse(row.chords.isEmpty, row.id)
            XCTAssertTrue(row.chords.allSatisfy { !$0.isEmpty && $0.allSatisfy { !$0.isEmpty } }, row.id)
        }
    }

    /// With every feature on, the sheet covers each user-facing command of the §4.4 key map.
    func testEveryKeyMapCommandIsListedWhenEverythingIsOn() {
        let settings = makeSettings()
        settings.voice.enabled = true
        settings.voice.spokenReplies = .always
        settings.actions.enabled = true
        settings.glance.nowPlayingEnabled = true
        settings.glance.calendarChipEnabled = true
        let ids = rowIDs(ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes))
        let expected: Set<String> = [
            // Conversation: send, stop (⌘.), stopSpeaking, regenerate, recallLastMessage, cancelEditing,
            // copyLastReply, newChat, pasteAsAttachment, finishVoice, cancelVoice.
            "conversation.send", "conversation.newLine", "conversation.stop", "conversation.stopSpeaking",
            "conversation.regenerate", "conversation.editLast", "conversation.cancelEditing",
            "conversation.copyLast", "conversation.newChat", "conversation.pasteAttachment",
            "conversation.finishVoice", "conversation.cancelVoice",
            // Notch: the global shortcut (tap and hold), close, togglePin, enter/exitTallMode, selectModel,
            // toggleHistory and the Recents keys, toggleShelf, backToChat, openSettings, toggleShortcutSheet.
            "notch.toggle", "notch.holdToTalk", "notch.close", "notch.pin", "notch.tallMode", "notch.normalHeight",
            "notch.switchModel",
            "notch.recents", "notch.recentsSearch", "notch.recentsDelete", "notch.recentsUndo", "notch.shelf",
            "notch.backToChat", "notch.settings", "notch.shortcuts",
            // Actions: insertLastAnswer (nil / .pastePlain), confirmInsert, promptPrimary / promptSecondary for
            // cards and approvals, shelfAskAboutSelection, shelfPaste.
            "actions.insert", "actions.insertPlain", "actions.confirmInsert", "actions.cardPrimary",
            "actions.cardDismiss", "actions.approve", "actions.decline", "actions.shelfAsk", "actions.shelfPaste",
            // Glance: media(.playPause / .next / .previous), joinMeeting, showUsage.
            "glance.playPause", "glance.nextTrack", "glance.previousTrack", "glance.joinMeeting", "glance.usage",
        ]
        XCTAssertEqual(ids, expected)
    }

    func testFreshInstallLeavesOutOptInRows() {
        let ids = rowIDs(ShortcutSheet.sections(settings: makeSettings(), availableRoutes: allRoutes))
        for id in ["notch.holdToTalk", "conversation.finishVoice", "conversation.cancelVoice",
                   "conversation.stopSpeaking", "actions.approve", "actions.decline", "glance.playPause",
                   "glance.nextTrack", "glance.previousTrack", "glance.joinMeeting"] {
            XCTAssertFalse(ids.contains(id), id)
        }
        XCTAssertTrue(ids.contains("notch.toggle"))
        XCTAssertTrue(ids.contains("glance.usage"))
    }

    func testChordsMatchTheKeyMap() {
        let sections = ShortcutSheet.sections(settings: makeSettings(), availableRoutes: allRoutes)
        XCTAssertEqual(row("conversation.stop", in: sections)?.chords, [["⌘", "."]])
        XCTAssertEqual(row("conversation.regenerate", in: sections)?.chords, [["⌘", "R"]])
        XCTAssertEqual(row("conversation.copyLast", in: sections)?.chords, [["⌘", "⇧", "C"]])
        XCTAssertEqual(row("notch.tallMode", in: sections)?.chords, [["⌘", "⇧", "↑"]])
        XCTAssertEqual(row("notch.normalHeight", in: sections)?.chords, [["⌘", "⇧", "↓"]])
        XCTAssertEqual(row("notch.switchModel", in: sections)?.chords, [["⌘", "1–3"]])
        XCTAssertEqual(row("notch.recents", in: sections)?.chords, [["⌘", "Y"]])
        XCTAssertEqual(row("notch.shelf", in: sections)?.chords, [["⌘", "D"]])
        XCTAssertEqual(row("notch.shortcuts", in: sections)?.chords, [["⌘", "/"]])
        XCTAssertEqual(row("actions.insert", in: sections)?.chords, [["⌘", "↩"]])
        XCTAssertEqual(row("actions.insertPlain", in: sections)?.chords, [["⌥", "⌘", "↩"]])
        XCTAssertEqual(row("glance.usage", in: sections)?.chords, [["⌥", "⌘", "U"]])
    }

    // MARK: Global shortcut and voice hold

    func testGlobalShortcutRowShowsTheLiveCombo() {
        let settings = makeSettings()
        XCTAssertEqual(row("notch.toggle", in: ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes))?.chords,
                       [["⌥", "Space"]])

        settings.shortcuts.hotKey = HotKeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(controlKey | optionKey))
        let toggle = row("notch.toggle", in: ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes))
        XCTAssertEqual(toggle?.chords, [["⌃", "⌥", "K"]])
        XCTAssertEqual(toggle?.isHold, false)
    }

    func testHoldToTalkNeedsVoiceHoldAndTheShortcut() {
        let settings = makeSettings()
        settings.voice.enabled = true
        let hold = row("notch.holdToTalk", in: ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes))
        XCTAssertEqual(hold?.chords, [["⌥", "Space"]])
        XCTAssertEqual(hold?.isHold, true)

        settings.voice.holdShortcutToTalk = false
        XCTAssertNil(row("notch.holdToTalk", in: ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes)))

        settings.voice.holdShortcutToTalk = true
        settings.hotKeyEnabled = false
        let sections = ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes)
        XCTAssertNil(row("notch.holdToTalk", in: sections))
        XCTAssertNil(row("notch.toggle", in: sections))

        settings.hotKeyEnabled = true
        settings.voice.enabled = false
        XCTAssertNil(row("notch.holdToTalk", in: ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes)))
    }

    func testVoiceRowsFollowVoiceMode() {
        let settings = makeSettings()
        var ids = rowIDs(ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes))
        XCTAssertFalse(ids.contains("conversation.finishVoice"))

        settings.voice.enabled = true
        let sections = ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes)
        ids = rowIDs(sections)
        XCTAssertTrue(ids.contains("conversation.finishVoice"))
        XCTAssertTrue(ids.contains("conversation.cancelVoice"))
        XCTAssertEqual(row("conversation.finishVoice", in: sections)?.chords, [["↩"]])
        XCTAssertEqual(row("conversation.cancelVoice", in: sections)?.chords, [["Esc"]])
    }

    /// ⌘. while Otto is speaking stops the speech (and Esc does too); the row shows only when replies can be read aloud.
    func testStopSpeakingRowFollowsSpokenReplies() {
        let settings = makeSettings()
        settings.voice.spokenReplies = .always
        let row = row("conversation.stopSpeaking", in: ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes))
        XCTAssertEqual(row?.chords, [["⌘", "."], ["Esc"]])

        settings.voice.spokenReplies = .afterVoice
        XCTAssertFalse(rowIDs(ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes)).contains("conversation.stopSpeaking"))
        settings.voice.enabled = true
        XCTAssertTrue(rowIDs(ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes)).contains("conversation.stopSpeaking"))

        settings.voice.spokenReplies = .off
        XCTAssertFalse(rowIDs(ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes)).contains("conversation.stopSpeaking"))
    }

    // MARK: Routes

    func testRecentsAndShelfRowsFollowAvailableRoutes() {
        let settings = makeSettings()
        let recentsRows = ["notch.recents", "notch.recentsSearch", "notch.recentsDelete", "notch.recentsUndo"]
        let shelfRows = ["notch.shelf", "actions.shelfAsk", "actions.shelfPaste"]

        var ids = rowIDs(ShortcutSheet.sections(settings: settings, availableRoutes: [.chat]))
        for id in recentsRows + shelfRows + ["notch.backToChat"] { XCTAssertFalse(ids.contains(id), id) }

        ids = rowIDs(ShortcutSheet.sections(settings: settings, availableRoutes: [.chat, .history]))
        for id in recentsRows + ["notch.backToChat"] { XCTAssertTrue(ids.contains(id), id) }
        for id in shelfRows { XCTAssertFalse(ids.contains(id), id) }

        ids = rowIDs(ShortcutSheet.sections(settings: settings, availableRoutes: [.chat, .shelf]))
        for id in shelfRows + ["notch.backToChat"] { XCTAssertTrue(ids.contains(id), id) }
        for id in recentsRows { XCTAssertFalse(ids.contains(id), id) }
    }

    // MARK: Actions and glances

    func testApprovalRowsNeedActions() {
        let settings = makeSettings()
        XCTAssertNil(row("actions.approve", in: ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes)))
        settings.actions.enabled = true
        let sections = ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes)
        XCTAssertEqual(row("actions.approve", in: sections)?.chords, [["⌘", "↩"]])
        XCTAssertEqual(row("actions.decline", in: sections)?.chords, [["Esc"]])
    }

    func testNowPlayingRowsFollowTheSetting() {
        let settings = makeSettings()
        XCTAssertEqual(section(.glance, in: ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes))?.rows.map(\.id),
                       ["glance.usage"])
        settings.glance.nowPlayingEnabled = true
        let sections = ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes)
        XCTAssertEqual(row("glance.playPause", in: sections)?.chords, [["⌥", "⌘", "P"]])
        XCTAssertEqual(row("glance.nextTrack", in: sections)?.chords, [["⌥", "⌘", "]"]])
        XCTAssertEqual(row("glance.previousTrack", in: sections)?.chords, [["⌥", "⌘", "["]])
        XCTAssertNil(row("glance.joinMeeting", in: sections))
    }

    func testMeetingRowFollowsTheCalendarChip() {
        let settings = makeSettings()
        settings.glance.calendarChipEnabled = true
        let sections = ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes)
        XCTAssertEqual(row("glance.joinMeeting", in: sections)?.chords, [["⌥", "⌘", "J"]])
        XCTAssertNil(row("glance.playPause", in: sections))
    }

    // MARK: Soft-focus note

    func testSoftFocusNoteShowsWhileTypeAfterHoverIsOn() {
        let settings = makeSettings()
        let notch = section(.notch, in: ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes))
        XCTAssertEqual(notch?.note, ShortcutSheet.softFocusNote)
        XCTAssertEqual(ShortcutSheet.softFocusNote.split(separator: "\n").count, 1)
        XCTAssertTrue(ShortcutSheet.softFocusNote.contains("⌘↩"))

        settings.notch.typeAfterHover = false
        let sections = ShortcutSheet.sections(settings: settings, availableRoutes: allRoutes)
        XCTAssertTrue(sections.allSatisfy { $0.note == nil })
    }

    // MARK: Columns and key caps

    func testColumnsPairConversationWithActionsAndNotchWithGlance() {
        let sections = ShortcutSheet.sections(settings: makeSettings(), availableRoutes: allRoutes)
        let columns = ShortcutSheet.columns(sections)
        XCTAssertEqual(columns.leading.map(\.kind), [.conversation, .actions])
        XCTAssertEqual(columns.trailing.map(\.kind), [.notch, .glance])
    }

    func testKeyCapsReadAsWords() {
        XCTAssertEqual(KeyCap.spokenChord(["⌘", "⇧", "C"]), "Command Shift C")
        XCTAssertEqual(KeyCap.spokenChord(["⌥", "Space"], isHold: true), "Hold Option Space")
        XCTAssertEqual(KeyCap.spokenChord(["⌘", "1–3"]), "Command 1 to 3")
        XCTAssertEqual(KeyCap.spokenName("Esc"), "Escape")
        XCTAssertEqual(KeyCap.spokenName("↩"), "Return")
    }

    // MARK: Version pager

    func testVersionPagerPositions() {
        XCTAssertNil(VersionPager.position(for: nil))
        XCTAssertNil(VersionPager.position(currentIndex: 0, storedCount: 0))
        // One stored reply that is the one shown: nothing to page through.
        XCTAssertNil(VersionPager.position(currentIndex: 0, storedCount: 1))

        // One stored reply, then a regenerate that failed: 2/2, back goes to the stored one.
        let afterFailure = VersionPager.position(currentIndex: 1, storedCount: 1)
        XCTAssertEqual(afterFailure?.label, "2/2")
        XCTAssertEqual(afterFailure?.previousIndex, 0)
        XCTAssertNil(afterFailure?.nextIndex)

        let middle = VersionPager.position(currentIndex: 1, storedCount: 3)
        XCTAssertEqual(middle?.label, "2/3")
        XCTAssertEqual(middle?.previousIndex, 0)
        XCTAssertEqual(middle?.nextIndex, 2)

        let first = VersionPager.position(currentIndex: 0, storedCount: 2)
        XCTAssertEqual(first?.label, "1/2")
        XCTAssertNil(first?.previousIndex)
        XCTAssertEqual(first?.nextIndex, 1)

        let last = VersionPager.position(currentIndex: 2, storedCount: 3)
        XCTAssertEqual(last?.label, "3/3")
        XCTAssertNil(last?.nextIndex)

        let versions = ChatSession.ReplyVersions(userMessageID: UUID(), replies: [
            ChatMessage(role: .assistant, text: "One"), ChatMessage(role: .assistant, text: "Two"),
        ], currentIndex: 2)
        XCTAssertEqual(VersionPager.position(for: versions)?.label, "3/3")
    }

    // MARK: Insert control and confirm row

    func testInsertControlLabelsForPaste() {
        let labels = InsertAnswerControl.Labels.make(appName: "Notes", primaryMode: .paste)
        XCTAssertEqual(labels.primaryTitle, "Paste into Notes")
        XCTAssertEqual(labels.help, "Paste this answer into Notes (⌘↩)")
        XCTAssertEqual(labels.accessibilityLabel, "Paste answer into Notes")
        XCTAssertEqual(labels.menuItems.map(\.action), [.insert(.pastePlain), .copy])
    }

    func testInsertControlLabelsForReplace() {
        let labels = InsertAnswerControl.Labels.make(appName: "Pages", primaryMode: .replaceSelection)
        XCTAssertEqual(labels.primaryTitle, "Replace selection")
        XCTAssertEqual(labels.menuItems.map(\.title), ["Paste into Pages", "Paste as Plain Text (⌥⌘↩)", "Copy"])
        XCTAssertEqual(labels.menuItems.map(\.action), [.insert(.paste), .insert(.pastePlain), .copy])
    }

    func testInsertControlCleansTheAppName() {
        let labels = InsertAnswerControl.Labels.make(appName: "Evil\u{202E}txt.app\u{200B}", primaryMode: .paste)
        XCTAssertEqual(labels.appName, "Eviltxt.app")
        XCTAssertEqual(InsertAnswerControl.Labels.make(appName: "\u{200B}", primaryMode: .paste).primaryTitle,
                       "Paste into the app")
    }

    func testConfirmRowCopy() {
        let id = UUID()
        XCTAssertNil(InsertConfirmRow.Content.make(for: .inserting(messageID: id)))

        let multiline = InsertConfirmRow.Content.make(for: .confirmMultiline(messageID: id, mode: .paste, lines: 6, appName: "Terminal"))
        XCTAssertEqual(multiline?.message, "Paste 6 lines into Terminal? Each line may run as a command.")
        XCTAssertEqual(multiline?.confirmTitle, "Paste")
        XCTAssertEqual(multiline?.cancelTitle, "Cancel")

        let changed = InsertConfirmRow.Content.make(for: .selectionChanged(messageID: id, appName: "Notes"))
        XCTAssertEqual(changed?.message, "Your selection in Notes changed.")
        XCTAssertEqual(changed?.confirmTitle, "Paste at Cursor")
        XCTAssertEqual(changed?.cancelTitle, "Copy")
    }

    // MARK: Header pieces

    func testRoutePebbleBadgeAndHelp() {
        XCTAssertNil(RoutePebble.badgeText(for: nil))
        XCTAssertNil(RoutePebble.badgeText(for: 0))
        XCTAssertEqual(RoutePebble.badgeText(for: 3), "3")
        XCTAssertEqual(RoutePebble.badgeText(for: 99), "99")
        XCTAssertEqual(RoutePebble.badgeText(for: 100), "99+")
        XCTAssertEqual(RoutePebble.help(for: .history, isActive: false), "Recents (⌘Y)")
        XCTAssertEqual(RoutePebble.help(for: .shelf, isActive: false), "Shelf (⌘D)")
        XCTAssertEqual(RoutePebble.help(for: .shelf, isActive: true), "Back to Chat")
    }

    func testHeaderModelMenuLabels() {
        XCTAssertEqual(HeaderModelMenu.label(for: .opus5, isDemo: false), "Opus 5")
        XCTAssertEqual(HeaderModelMenu.label(for: .opus5, isDemo: true), "Opus 5 · demo")
        XCTAssertEqual(HeaderModelMenu.itemTitle(for: .sonnet5), "Sonnet 5 · Fast and capable")
        XCTAssertEqual(ModelOption.allCases.compactMap(HeaderModelMenu.shortcutDigit(for:)), ["1", "2", "3"])
        XCTAssertEqual(HeaderModelMenu.shortcutDigit(for: .haiku45), "3")
        XCTAssertNil(HeaderModelMenu.effortCaption(for: .opus5))
        XCTAssertEqual(HeaderModelMenu.effortCaption(for: .haiku45), "Haiku 4.5 always answers quickly")
        XCTAssertEqual(HeaderModelMenu.accessibilityLabel(for: .opus5),
                       "Model: Opus 5. Change model, response style and web search.")
    }

    func testGhostChipLabelIsCleaned() {
        XCTAssertEqual(GhostChip.displayLabel("Window:\u{2066} Xcode\u{2069}"), "Window: Xcode")
        XCTAssertEqual(GhostChip.displayLabel("a\n\nb"), "a b")
        XCTAssertLessThanOrEqual(GhostChip.displayLabel(String(repeating: "x", count: 500)).count,
                                 GhostChip.maxLabelLength)
    }
}
