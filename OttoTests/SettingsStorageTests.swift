//
//  SettingsStorageTests.swift
//  OttoTests
//
//  Every preference in the settings groups (and the existing AppSettings keys): its default on a fresh
//  install, that a change persists under the documented key, that a new AppSettings reads it back, and
//  that ranged values are clamped on read and on write.
//

import XCTest
@testable import Otto

@MainActor
final class SettingsStorageTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = TestDefaults.make(for: self)
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults, usesKeychain: false)
    }

    // MARK: Defaults

    func testFreshInstallDefaults() {
        let settings = makeSettings()

        XCTAssertEqual(settings.model, .opus5)
        XCTAssertEqual(settings.effort, .medium)
        XCTAssertTrue(settings.webAccess)
        XCTAssertTrue(settings.suggestBrowserTab)
        XCTAssertFalse(settings.autoAttachBrowserTab)
        XCTAssertTrue(settings.hotKeyEnabled)
        XCTAssertTrue(settings.showMenuBarIcon)
        XCTAssertEqual(settings.customInstructions, "")
        XCTAssertEqual(settings.actionSafetyMode, .safer)

        XCTAssertTrue(settings.notch.hoverToOpen)
        XCTAssertTrue(settings.notch.typeAfterHover)
        XCTAssertEqual(settings.notch.acknowledgedNeighbors, [])

        XCTAssertEqual(settings.shortcuts.hotKey, .optionSpace)
        XCTAssertFalse(settings.shortcuts.isRecording)
        XCTAssertEqual(settings.shortcuts.status, .disabled)

        XCTAssertFalse(settings.voice.enabled)
        XCTAssertTrue(settings.voice.holdShortcutToTalk)
        XCTAssertTrue(settings.voice.autoSend)
        XCTAssertEqual(settings.voice.localeIdentifier, "")
        XCTAssertEqual(settings.voice.locale, Locale.current)
        XCTAssertFalse(settings.voice.allowServerRecognition)
        XCTAssertEqual(settings.voice.spokenReplies, .off)
        XCTAssertEqual(settings.voice.voiceIdentifier, "")
        XCTAssertEqual(settings.voice.speakingRate, 0.5)

        XCTAssertFalse(settings.context.offerSelection)
        XCTAssertTrue(settings.context.offerWindow)
        XCTAssertTrue(settings.context.restoreClipboard)

        XCTAssertTrue(settings.shelf.enabled)
        XCTAssertFalse(settings.shelf.keepAfterDragOut)

        XCTAssertFalse(settings.actions.enabled)
        XCTAssertEqual(settings.actions.groups, ToolGroup.defaultEnabled)
        XCTAssertEqual(settings.actions.maxToolRounds, 10)
        XCTAssertFalse(settings.actions.logFullScripts)

        XCTAssertTrue(settings.glance.replyPreviews)
        XCTAssertEqual(settings.glance.notificationPolicy, .off)
        XCTAssertTrue(settings.glance.notificationIncludesPreview)
        XCTAssertFalse(settings.glance.nowPlayingEnabled)
        XCTAssertTrue(settings.glance.nowPlayingInClosedNotch)
        XCTAssertFalse(settings.glance.calendarChipEnabled)
        XCTAssertEqual(settings.glance.calendarExcludedIDs, [])

        XCTAssertTrue(settings.usage.showCost)

        XCTAssertTrue(settings.history.enabled)
        XCTAssertEqual(settings.history.retention, .month)
        XCTAssertEqual(settings.history.idleReset, .fifteenMinutes)
        XCTAssertFalse(settings.history.noticeAcknowledged)
    }

    func testReadingDefaultsWritesNothing() {
        _ = makeSettings()
        let written = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("otto.") && $0 != "otto.launchAtLogin" }
        XCTAssertEqual(written, [], "init must not write every default back")
    }

    // MARK: Persist and reload

    func testEveryGroupPreferencePersistsUnderItsKeyAndReloads() throws {
        let settings = makeSettings()
        settings.notch.hoverToOpen = false
        settings.notch.typeAfterHover = false
        settings.notch.acknowledgedNeighbors = ["NotchNook"]
        let combo = HotKeyCombo(keyCode: 31, carbonModifiers: HotKeyCombo.carbonModifiers(from: [.control, .option]))
        settings.shortcuts.hotKey = combo
        settings.voice.enabled = true
        settings.voice.holdShortcutToTalk = false
        settings.voice.autoSend = false
        settings.voice.localeIdentifier = "en_IN"
        settings.voice.allowServerRecognition = true
        settings.voice.spokenReplies = .afterVoice
        settings.voice.voiceIdentifier = "com.apple.voice.premium.en-US.Zoe"
        settings.voice.speakingRate = 0.6
        settings.context.offerSelection = true
        settings.context.offerWindow = false
        settings.context.restoreClipboard = false
        settings.shelf.enabled = false
        settings.shelf.keepAfterDragOut = true
        settings.actions.enabled = true
        settings.actions.groups = [.appleScript, .calendar]
        settings.actions.maxToolRounds = 4
        settings.actions.logFullScripts = true
        settings.glance.replyPreviews = false
        settings.glance.notificationPolicy = .whenOutOfSight
        settings.glance.notificationIncludesPreview = false
        settings.glance.nowPlayingEnabled = true
        settings.glance.nowPlayingInClosedNotch = false
        settings.glance.calendarChipEnabled = true
        settings.glance.calendarExcludedIDs = ["cal-1", "cal-2"]
        settings.usage.showCost = false
        settings.history.enabled = false
        settings.history.retention = .forever
        settings.history.idleReset = .never
        settings.history.noticeAcknowledged = true
        settings.actionSafetyMode = .fewerPrompts

        // The documented keys and encodings (SPEC-v2 §3.19).
        let expected: [String: Any] = [
            "otto.notch.hoverToOpen": false,
            "otto.notch.typeAfterHover": false,
            "otto.notch.acknowledgedNeighbors": ["NotchNook"],
            "otto.voice.enabled": true,
            "otto.voice.holdShortcutToTalk": false,
            "otto.voice.autoSend": false,
            "otto.voice.locale": "en_IN",
            "otto.voice.allowServerRecognition": true,
            "otto.voice.spokenReplies": "afterVoice",
            "otto.voice.voiceIdentifier": "com.apple.voice.premium.en-US.Zoe",
            "otto.voice.speakingRate": 0.6,
            "otto.context.offerSelection": true,
            "otto.context.offerWindow": false,
            "otto.context.restoreClipboard": false,
            "otto.shelf.enabled": false,
            "otto.shelf.keepAfterDragOut": true,
            "otto.actions.enabled": true,
            "otto.actions.groups": ["appleScript", "calendar"],
            "otto.actions.maxToolRounds": 4,
            "otto.actions.logFullScripts": true,
            "otto.actions.safetyMode": "fewerPrompts",
            "otto.glance.replyPreviews": false,
            "otto.glance.notificationPolicy": "whenOutOfSight",
            "otto.glance.notificationPreview": false,
            "otto.glance.nowPlaying": true,
            "otto.glance.nowPlayingClosed": false,
            "otto.glance.calendarChip": true,
            "otto.glance.calendarExcluded": ["cal-1", "cal-2"],
            "otto.usage.showCost": false,
            "otto.history.enabled": false,
            "otto.history.retention": "forever",
            "otto.history.idleReset": "never",
            "otto.history.noticeAcknowledged": true,
        ]
        for (key, value) in expected {
            let stored = try XCTUnwrap(defaults.object(forKey: key), "\(key) was not written")
            XCTAssertEqual(stored as? NSObject, value as? NSObject, key)
        }
        let hotKeyData = try XCTUnwrap(defaults.data(forKey: "otto.shortcuts.hotKey"))
        XCTAssertEqual(try JSONDecoder().decode(HotKeyCombo.self, from: hotKeyData), combo)
        XCTAssertEqual(String(decoding: hotKeyData, as: UTF8.self), #"{"carbonModifiers":6144,"keyCode":31}"#,
                       "JSON with sorted keys")

        let reloaded = makeSettings()
        XCTAssertFalse(reloaded.notch.hoverToOpen)
        XCTAssertFalse(reloaded.notch.typeAfterHover)
        XCTAssertEqual(reloaded.notch.acknowledgedNeighbors, ["NotchNook"])
        XCTAssertEqual(reloaded.shortcuts.hotKey, combo)
        XCTAssertTrue(reloaded.voice.enabled)
        XCTAssertFalse(reloaded.voice.holdShortcutToTalk)
        XCTAssertFalse(reloaded.voice.autoSend)
        XCTAssertEqual(reloaded.voice.localeIdentifier, "en_IN")
        XCTAssertEqual(reloaded.voice.locale.identifier, "en_IN")
        XCTAssertTrue(reloaded.voice.allowServerRecognition)
        XCTAssertEqual(reloaded.voice.spokenReplies, .afterVoice)
        XCTAssertEqual(reloaded.voice.voiceIdentifier, "com.apple.voice.premium.en-US.Zoe")
        XCTAssertEqual(reloaded.voice.speakingRate, 0.6)
        XCTAssertTrue(reloaded.context.offerSelection)
        XCTAssertFalse(reloaded.context.offerWindow)
        XCTAssertFalse(reloaded.context.restoreClipboard)
        XCTAssertFalse(reloaded.shelf.enabled)
        XCTAssertTrue(reloaded.shelf.keepAfterDragOut)
        XCTAssertTrue(reloaded.actions.enabled)
        XCTAssertEqual(reloaded.actions.groups, [.appleScript, .calendar])
        XCTAssertEqual(reloaded.actions.maxToolRounds, 4)
        XCTAssertTrue(reloaded.actions.logFullScripts)
        XCTAssertEqual(reloaded.actionSafetyMode, .fewerPrompts)
        XCTAssertFalse(reloaded.glance.replyPreviews)
        XCTAssertEqual(reloaded.glance.notificationPolicy, .whenOutOfSight)
        XCTAssertFalse(reloaded.glance.notificationIncludesPreview)
        XCTAssertTrue(reloaded.glance.nowPlayingEnabled)
        XCTAssertFalse(reloaded.glance.nowPlayingInClosedNotch)
        XCTAssertTrue(reloaded.glance.calendarChipEnabled)
        XCTAssertEqual(reloaded.glance.calendarExcludedIDs, ["cal-1", "cal-2"])
        XCTAssertFalse(reloaded.usage.showCost)
        XCTAssertFalse(reloaded.history.enabled)
        XCTAssertEqual(reloaded.history.retention, .forever)
        XCTAssertEqual(reloaded.history.idleReset, .never)
        XCTAssertTrue(reloaded.history.noticeAcknowledged)
    }

    func testExistingKeysKeepTheirNames() throws {
        let settings = makeSettings()
        settings.model = .haiku45
        settings.effort = .high
        settings.webAccess = false
        settings.suggestBrowserTab = false
        settings.autoAttachBrowserTab = true
        settings.hotKeyEnabled = false
        settings.showMenuBarIcon = false
        settings.customInstructions = "Be brief."

        XCTAssertEqual(defaults.string(forKey: "otto.model"), "claude-haiku-4-5")
        XCTAssertEqual(defaults.string(forKey: "otto.effort"), "high")
        XCTAssertEqual(defaults.object(forKey: "otto.webAccess") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "otto.suggestBrowserTab") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "otto.autoAttachBrowserTab") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "otto.hotKeyEnabled") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "otto.showMenuBarIcon") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "otto.customInstructions"), "Be brief.")

        let reloaded = makeSettings()
        XCTAssertEqual(reloaded.model, .haiku45)
        XCTAssertEqual(reloaded.effort, .high)
        XCTAssertFalse(reloaded.webAccess)
        XCTAssertFalse(reloaded.suggestBrowserTab)
        XCTAssertTrue(reloaded.autoAttachBrowserTab)
        XCTAssertFalse(reloaded.hotKeyEnabled)
        XCTAssertFalse(reloaded.showMenuBarIcon)
        XCTAssertEqual(reloaded.customInstructions, "Be brief.")
    }

    // MARK: Clamping and bad values

    func testSpeakingRateClampsOnReadAndWrite() {
        defaults.set(0.9, forKey: "otto.voice.speakingRate")
        XCTAssertEqual(makeSettings().voice.speakingRate, 0.65)
        defaults.set(0.1, forKey: "otto.voice.speakingRate")
        XCTAssertEqual(makeSettings().voice.speakingRate, 0.35)

        let settings = makeSettings()
        settings.voice.speakingRate = 2
        XCTAssertEqual(settings.voice.speakingRate, 0.65)
        XCTAssertEqual(defaults.double(forKey: "otto.voice.speakingRate"), 0.65)
        settings.voice.speakingRate = -1
        XCTAssertEqual(settings.voice.speakingRate, 0.35)
        XCTAssertEqual(defaults.double(forKey: "otto.voice.speakingRate"), 0.35)
        settings.voice.speakingRate = .nan
        XCTAssertEqual(settings.voice.speakingRate, 0.5)
        XCTAssertEqual(VoiceSettings.speakingRateRange, 0.35...0.65)
    }

    func testMaxToolRoundsClampsOnReadAndWrite() {
        defaults.set(99, forKey: "otto.actions.maxToolRounds")
        XCTAssertEqual(makeSettings().actions.maxToolRounds, 25)
        defaults.set(1, forKey: "otto.actions.maxToolRounds")
        XCTAssertEqual(makeSettings().actions.maxToolRounds, 3)

        let settings = makeSettings()
        settings.actions.maxToolRounds = 40
        XCTAssertEqual(settings.actions.maxToolRounds, 25)
        XCTAssertEqual(defaults.integer(forKey: "otto.actions.maxToolRounds"), 25)
        settings.actions.maxToolRounds = 0
        XCTAssertEqual(settings.actions.maxToolRounds, 3)
        XCTAssertEqual(defaults.integer(forKey: "otto.actions.maxToolRounds"), 3)
        XCTAssertEqual(ActionSettings.maxToolRoundsRange, 3...25)
    }

    func testUnknownOrMistypedValuesFallBackToDefaults() {
        defaults.set("loud", forKey: "otto.voice.spokenReplies")
        defaults.set("1y", forKey: "otto.history.retention")
        defaults.set(42, forKey: "otto.glance.notificationPolicy")
        defaults.set("yes", forKey: "otto.notch.hoverToOpen")
        defaults.set(Data("not json".utf8), forKey: "otto.shortcuts.hotKey")
        defaults.set(["calendar", "teleport", "links"], forKey: "otto.actions.groups")
        defaults.set("reckless", forKey: "otto.actions.safetyMode")
        defaults.set("fast", forKey: "otto.actions.maxToolRounds")

        let settings = makeSettings()
        XCTAssertEqual(settings.voice.spokenReplies, .off)
        XCTAssertEqual(settings.history.retention, .month)
        XCTAssertEqual(settings.glance.notificationPolicy, .off)
        XCTAssertTrue(settings.notch.hoverToOpen)
        XCTAssertEqual(settings.shortcuts.hotKey, .optionSpace)
        XCTAssertEqual(settings.actions.groups, [.calendar, .links], "unknown groups are dropped")
        XCTAssertEqual(settings.actionSafetyMode, .safer)
        XCTAssertEqual(settings.actions.maxToolRounds, 10)
    }

    func testEmptyGroupSelectionIsKept() {
        let settings = makeSettings()
        settings.actions.groups = []
        XCTAssertEqual(defaults.stringArray(forKey: "otto.actions.groups"), [])
        XCTAssertEqual(makeSettings().actions.groups, [], "an explicit empty selection is not the default")
    }

    func testActionGroupSwitch() {
        let settings = makeSettings()
        XCTAssertFalse(settings.actions.isEnabled(.calendar), "the master switch is off by default")
        settings.actions.enabled = true
        XCTAssertTrue(settings.actions.isEnabled(.calendar))
        XCTAssertFalse(settings.actions.isEnabled(.appleScript), "AppleScript is opt-in")
        settings.actions.groups.insert(.appleScript)
        XCTAssertTrue(settings.actions.isEnabled(.appleScript))
    }

    // MARK: Shortcut apply

    func testShortcutApply() {
        let settings = makeSettings()
        let combo = HotKeyCombo(keyCode: 31, carbonModifiers: HotKeyCombo.carbonModifiers(from: [.control, .option]))

        XCTAssertEqual(settings.shortcuts.apply(combo, validationMessage: "Pick another."), .rejected("Pick another."))
        XCTAssertEqual(settings.shortcuts.hotKey, .optionSpace)
        XCTAssertNil(defaults.object(forKey: "otto.shortcuts.hotKey"))

        var registered: [HotKeyCombo] = []
        settings.shortcuts.registrar = { candidate in
            registered.append(candidate)
            return candidate == combo ? .rejected("⌃⌥O is in use by another app.") : .applied
        }
        XCTAssertEqual(settings.shortcuts.apply(combo, validationMessage: nil), .rejected("⌃⌥O is in use by another app."))
        XCTAssertEqual(settings.shortcuts.hotKey, .optionSpace, "a failed registration keeps the old combo")

        let other = HotKeyCombo(keyCode: 49, carbonModifiers: HotKeyCombo.carbonModifiers(from: [.control]))
        XCTAssertEqual(settings.shortcuts.apply(other, validationMessage: nil), .applied)
        XCTAssertEqual(settings.shortcuts.hotKey, other)
        XCTAssertEqual(registered, [combo, other])
        XCTAssertEqual(makeSettings().shortcuts.hotKey, other)

        settings.shortcuts.registrar = nil
        XCTAssertEqual(settings.shortcuts.apply(combo, validationMessage: nil), .applied, "no registrar: just store it")
        XCTAssertEqual(makeSettings().shortcuts.hotKey, combo)
    }

    // MARK: PreferenceStore

    func testPreferenceStore() {
        let store = PreferenceStore(defaults: defaults)
        XCTAssertEqual(store.int("otto.test.int", 7), 7)
        XCTAssertEqual(store.int("otto.test.int", 7, in: 10...20), 10, "the fallback is clamped too")
        store.set(15, "otto.test.int")
        XCTAssertEqual(store.int("otto.test.int", 7, in: 10...20), 15)
        store.set(nil, "otto.test.int")
        XCTAssertNil(defaults.object(forKey: "otto.test.int"))

        XCTAssertEqual(store.double("otto.test.double", 1.5), 1.5)
        store.set(Double.infinity, "otto.test.double")
        XCTAssertEqual(store.double("otto.test.double", 1.5), 1.5)

        XCTAssertEqual(store.strings("otto.test.strings", ["a"]), ["a"])
        store.setEncoded(HistoryRetention.quarter, "otto.test.encoded")
        XCTAssertEqual(store.decoded("otto.test.encoded", as: HistoryRetention.self), .quarter)
        XCTAssertNil(store.decoded("otto.test.missing", as: HistoryRetention.self))
        store.setEncoded(Optional<HistoryRetention>.none, "otto.test.encoded")
        XCTAssertNil(defaults.object(forKey: "otto.test.encoded"))
        XCTAssertEqual(store.value("otto.test.missing", SpokenReplies.always), .always)
    }
}
