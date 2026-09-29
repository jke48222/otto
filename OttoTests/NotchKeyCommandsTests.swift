//
//  NotchKeyCommandsTests.swift
//  Otto
//
//  Every row of SPEC-v2 §4.4, in table order, including precedence between rows that share a key.
//

import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Otto

final class NotchKeyCommandsTests: XCTestCase {
    private typealias Context = NotchKeyContext

    private let command: NSEvent.ModifierFlags = [.command]
    private let optionCommand: NSEvent.ModifierFlags = [.option, .command]
    private let commandShift: NSEvent.ModifierFlags = [.command, .shift]

    /// A key as the window controller sees it: key code plus `charactersIgnoringModifiers`.
    private struct Key {
        let keyCode: Int
        let characters: String?

        static let escape = Key(keyCode: kVK_Escape, characters: "\u{1B}")
        static let returnKey = Key(keyCode: kVK_Return, characters: "\r")
        static let enter = Key(keyCode: kVK_ANSI_KeypadEnter, characters: "\u{03}")
        static let up = Key(keyCode: kVK_UpArrow, characters: "\u{F700}")
        static let down = Key(keyCode: kVK_DownArrow, characters: "\u{F701}")
        static let delete = Key(keyCode: kVK_Delete, characters: "\u{7F}")

        static func us(_ keyCode: Int, _ character: String) -> Key { Key(keyCode: keyCode, characters: character) }
        static let a = us(kVK_ANSI_A, "a"), c = us(kVK_ANSI_C, "c"), d = us(kVK_ANSI_D, "d")
        static let f = us(kVK_ANSI_F, "f"), j = us(kVK_ANSI_J, "j"), k = us(kVK_ANSI_K, "k")
        static let n = us(kVK_ANSI_N, "n"), p = us(kVK_ANSI_P, "p"), r = us(kVK_ANSI_R, "r")
        static let u = us(kVK_ANSI_U, "u"), v = us(kVK_ANSI_V, "v"), w = us(kVK_ANSI_W, "w")
        static let y = us(kVK_ANSI_Y, "y"), z = us(kVK_ANSI_Z, "z")
        static let one = us(kVK_ANSI_1, "1"), two = us(kVK_ANSI_2, "2"), three = us(kVK_ANSI_3, "3")
        static let slash = us(kVK_ANSI_Slash, "/"), period = us(kVK_ANSI_Period, "."), comma = us(kVK_ANSI_Comma, ",")
        static let leftBracket = us(kVK_ANSI_LeftBracket, "["), rightBracket = us(kVK_ANSI_RightBracket, "]")
    }

    private func map(_ key: Key, _ flags: NSEvent.ModifierFlags = [], _ context: Context = Context()) -> NotchKeyCommand? {
        NotchKeyCommands.command(keyCode: UInt16(key.keyCode), characters: key.characters, flags: flags,
                                 context: context)
    }

    private func context(_ configure: (inout Context) -> Void) -> Context {
        var context = Context()
        configure(&context)
        return context
    }

    // MARK: - Row 1: soft focus is not engagement

    private var softFocusChords: [(String, Key, NSEvent.ModifierFlags)] {
        [("⌘↩", .returnKey, command), ("⌘⌅", .enter, command), ("⌥⌘↩", .returnKey, optionCommand),
         ("⌘R", .r, command), ("⌘N", .n, command), ("⌘1", .one, command), ("⌘2", .two, command),
         ("⌘3", .three, command), ("⌘⇧C", Key(keyCode: kVK_ANSI_C, characters: "C"), commandShift),
         ("⌘.", .period, command), ("⌘⇧. (AZERTY ⌘.)", azertyPeriod, commandShift),
         ("⌥⌘J", .j, optionCommand), ("⌘⌫", .delete, command)]
    }

    /// AZERTY types "." as ⇧ on the key a US keyboard calls ",".
    private var azertyPeriod: Key { Key(keyCode: kVK_ANSI_Comma, characters: ".") }

    func testConsequentialChordsOnlyReleaseSoftFocus() {
        let states: [Context] = [
            context { $0.isEngaged = false },
            context {
                $0.isEngaged = false; $0.prompt = .approval; $0.hasUserMessage = true; $0.canInsertLastAnswer = true
            },
            context { $0.isEngaged = false; $0.isSpeaking = true; $0.hasMeetingChip = true },
            context { $0.isEngaged = false; $0.route = .shelf },
            context { $0.isEngaged = false; $0.route = .history },
        ]
        for state in states {
            for (label, key, flags) in softFocusChords {
                XCTAssertEqual(map(key, flags, state), .releaseSoftFocus, "\(label) in \(state)")
            }
        }
    }

    func testSoftFocusedShelfKeysOnlyReleaseSoftFocus() {
        let shelf = context { $0.isEngaged = false; $0.route = .shelf }
        let forwardDelete = Key(keyCode: kVK_ForwardDelete, characters: "\u{F728}")
        let space = Key(keyCode: kVK_Space, characters: " ")
        let registered = Key(keyCode: kVK_ANSI_R, characters: "®")
        let keys: [(String, Key, NSEvent.ModifierFlags)] = [
            ("⌫", .delete, []), ("⌦", forwardDelete, []), ("Space", space, []), ("⌘C", .c, command),
            ("⌘V", .v, command), ("⌘A", .a, command), ("⌥⌘R", .r, optionCommand), ("⌥⌘R as ®", registered, optionCommand),
        ]
        for (label, key, flags) in keys {
            XCTAssertEqual(map(key, flags, shelf), .releaseSoftFocus, label)
            XCTAssertTrue(NotchKeyCommands.releasesShelfSoftFocus(keyCode: UInt16(key.keyCode),
                                                                  characters: key.characters, flags: flags,
                                                                  context: shelf), label)
            let engaged = context { $0.route = .shelf }
            XCTAssertNotEqual(map(key, flags, engaged), .releaseSoftFocus, "engaged: \(label)")
            XCTAssertFalse(NotchKeyCommands.releasesShelfSoftFocus(keyCode: UInt16(key.keyCode),
                                                                   characters: key.characters, flags: flags,
                                                                   context: engaged), "engaged: \(label)")
            let chat = context { $0.isEngaged = false }
            XCTAssertFalse(NotchKeyCommands.releasesShelfSoftFocus(keyCode: UInt16(key.keyCode),
                                                                   characters: key.characters, flags: flags,
                                                                   context: chat), "chat: \(label)")
        }
        // A plain letter still promotes soft focus on the Shelf (rule 2), so typing reaches Otto.
        XCTAssertFalse(NotchKeyCommands.releasesShelfSoftFocus(keyCode: UInt16(kVK_ANSI_K), characters: "k", flags: [],
                                                               context: shelf))
    }

    func testSoftFocusedApprovalIsNeverApprovedByCommandReturn() {
        let state = context { $0.isEngaged = false; $0.prompt = .approval }
        XCTAssertEqual(map(.returnKey, command, state), .releaseSoftFocus)
        XCTAssertNotEqual(map(.returnKey, command, state), .promptPrimary)
        XCTAssertEqual(map(.returnKey, command, context { $0.prompt = .approval }), .promptPrimary,
                       "engaged, the same chord reaches the prompt")
    }

    func testHarmlessChordsStillActWhileSoftFocused() {
        let soft = context { $0.isEngaged = false }
        XCTAssertEqual(map(.escape, [], soft), .close)
        XCTAssertEqual(map(.d, command, soft), .toggleShelf)
        XCTAssertEqual(map(.y, command, soft), .toggleHistory)
        XCTAssertEqual(map(.p, command, soft), .togglePin)
        XCTAssertEqual(map(.slash, command, soft), .toggleShortcutSheet)
        XCTAssertEqual(map(.w, command, soft), .close)
        XCTAssertEqual(map(.comma, command, soft), .openSettings)
    }

    func testSoftFocusedEscapeOnlyClosesOrStops() {
        // Esc meant for the user's own app must never deny an approval, drop an edit or cancel an insert.
        let discarding: [Context] = [
            context { $0.isEngaged = false; $0.prompt = .approval },
            context { $0.isEngaged = false; $0.prompt = .other },
            context { $0.isEngaged = false; $0.hasInsertConfirmation = true },
            context { $0.isEngaged = false; $0.isEditing = true },
            context { $0.isEngaged = false; $0.overlay = .shortcutSheet },
            context { $0.isEngaged = false; $0.route = .shelf },
            context { $0.isEngaged = false; $0.prompt = .approval; $0.isEditing = true; $0.hasInsertConfirmation = true },
        ]
        for state in discarding {
            XCTAssertEqual(map(.escape, [], state), .close, "\(state)")
        }
        XCTAssertEqual(map(.escape, [], context { $0.isEngaged = false; $0.isListening = true; $0.prompt = .approval }),
                       .cancelVoice)
        XCTAssertEqual(map(.escape, [], context { $0.isEngaged = false; $0.isSpeaking = true; $0.prompt = .approval }),
                       .stopSpeaking)
        XCTAssertNil(map(.escape, [], context { $0.isEngaged = false; $0.hasMarkedText = true; $0.prompt = .approval }),
                     "the input method still cancels its composition")
        XCTAssertEqual(map(.escape, [], context { $0.prompt = .approval }), .promptSecondary,
                       "engaged, Esc still declines")
    }

    // MARK: - Esc ladder

    func testEscapeLadderInTableOrder() {
        var state = context {
            $0.hasMarkedText = true; $0.isListening = true; $0.isSpeaking = true; $0.overlay = .shortcutSheet
            $0.prompt = .other; $0.hasInsertConfirmation = true; $0.isEditing = true; $0.route = .history
        }
        XCTAssertNil(map(.escape, [], state), "the input method cancels its composition")
        state.hasMarkedText = false
        XCTAssertEqual(map(.escape, [], state), .cancelVoice)
        state.isListening = false
        XCTAssertEqual(map(.escape, [], state), .stopSpeaking)
        state.isSpeaking = false
        XCTAssertEqual(map(.escape, [], state), .dismissOverlay)
        state.overlay = nil
        XCTAssertEqual(map(.escape, [], state), .promptSecondary)
        state.prompt = .none
        XCTAssertEqual(map(.escape, [], state), .cancelInsertConfirmation)
        state.hasInsertConfirmation = false
        XCTAssertEqual(map(.escape, [], state), .cancelEditing)
        state.isEditing = false
        XCTAssertEqual(map(.escape, [], state), .backToChat)
        state.route = .chat
        XCTAssertEqual(map(.escape, [], state), .close)
    }

    func testEscapeDeniesApprovals() {
        XCTAssertEqual(map(.escape, [], context { $0.prompt = .approval }), .promptSecondary)
    }

    func testEscapeFromShelfGoesBackToChat() {
        XCTAssertEqual(map(.escape, [], context { $0.route = .shelf }), .backToChat)
    }

    // MARK: - Return ladder

    func testReturnLadderInTableOrder() {
        var state = context {
            $0.hasMarkedText = true; $0.isListening = true; $0.route = .history
        }
        XCTAssertNil(map(.returnKey, [], state), "the input method commits its composition")
        state.hasMarkedText = false
        XCTAssertEqual(map(.returnKey, [], state), .finishVoice)
        state.isListening = false
        XCTAssertEqual(map(.returnKey, [], state), .historyOpenSelected)

        state = context { $0.prompt = .other; $0.hasInsertConfirmation = true }
        XCTAssertEqual(map(.returnKey, [], state), .promptPrimary)
        state.prompt = .none
        XCTAssertEqual(map(.returnKey, [], state), .confirmInsert)
        state.hasInsertConfirmation = false
        XCTAssertNil(map(.returnKey, [], state), "the composer's onSubmit sends")
    }

    func testKeypadEnterMatchesReturn() {
        XCTAssertEqual(map(.enter, [], context { $0.isListening = true }), .finishVoice)
        XCTAssertEqual(map(.enter, [], context { $0.route = .history }), .historyOpenSelected)
    }

    func testReturnNeverApproves() {
        XCTAssertNil(map(.returnKey, [], context { $0.prompt = .approval }))
    }

    func testReturnSkipsPrimariesThatRequireCommandReturn() {
        // "Quit & Reopen Otto" must be a deliberate ⌘↩.
        let quitAndReopen = context { $0.prompt = .other; $0.promptPrimaryRequiresCommand = true }
        XCTAssertNil(map(.returnKey, [], quitAndReopen))
        XCTAssertEqual(map(.returnKey, command, quitAndReopen), .promptPrimary)

        let withInsert = context {
            $0.prompt = .other; $0.promptPrimaryRequiresCommand = true; $0.hasInsertConfirmation = true
        }
        XCTAssertEqual(map(.returnKey, [], withInsert), .confirmInsert, "falls to the next row")
    }

    func testReturnWithComposerTextSends() {
        XCTAssertNil(map(.returnKey, [], context { $0.prompt = .other; $0.composerIsEmpty = false }))
        XCTAssertNil(map(.returnKey, [], context { $0.hasInsertConfirmation = true; $0.composerIsEmpty = false }))
    }

    // MARK: - ⌘↩ ladder and ⌥⌘↩

    func testCommandReturnLadder() {
        var state = context {
            $0.prompt = .approval; $0.route = .shelf; $0.canInsertLastAnswer = true
        }
        XCTAssertEqual(map(.returnKey, command, state), .promptPrimary)
        state.prompt = .none
        XCTAssertEqual(map(.returnKey, command, state), .shelfAskAboutSelection)
        state.route = .chat
        XCTAssertEqual(map(.returnKey, command, state), .insertLastAnswer(nil))
        state.composerIsEmpty = false
        XCTAssertNil(map(.returnKey, command, state))
        state.composerIsEmpty = true
        state.canInsertLastAnswer = false
        XCTAssertNil(map(.returnKey, command, state))
        XCTAssertNil(map(.returnKey, command, context { $0.route = .history; $0.canInsertLastAnswer = true }))
        XCTAssertEqual(map(.enter, command, context { $0.prompt = .other }), .promptPrimary)
    }

    func testOptionCommandReturnPastesPlainText() {
        let ready = context { $0.canInsertLastAnswer = true }
        XCTAssertEqual(map(.returnKey, optionCommand, ready), .insertLastAnswer(.pastePlain))
        XCTAssertNil(map(.returnKey, optionCommand, context { $0.canInsertLastAnswer = true; $0.prompt = .other }))
        XCTAssertNil(map(.returnKey, optionCommand, context { $0.canInsertLastAnswer = true; $0.composerIsEmpty = false }))
        XCTAssertNil(map(.returnKey, optionCommand, context { $0.canInsertLastAnswer = true; $0.route = .shelf }))
        XCTAssertNil(map(.returnKey, optionCommand, Context()))
    }

    // MARK: - Arrows

    func testUpArrow() {
        XCTAssertEqual(map(.up, [], context { $0.route = .history }), .historyMoveSelection(-1))

        let recall = context { $0.composerIsFirstResponder = true; $0.hasUserMessage = true }
        XCTAssertEqual(map(.up, [], recall), .recallLastMessage)
        XCTAssertNil(map(.up, [], context { $0.composerIsFirstResponder = false; $0.hasUserMessage = true }))
        XCTAssertNil(map(.up, [], context { $0.composerIsFirstResponder = true; $0.hasUserMessage = false }))
        XCTAssertNil(map(.up, [], context {
            $0.composerIsFirstResponder = true; $0.hasUserMessage = true; $0.composerIsEmpty = false
        }))
        XCTAssertNil(map(.up, [], context {
            $0.composerIsFirstResponder = true; $0.hasUserMessage = true; $0.isEditing = true
        }))
        XCTAssertNil(map(.up, [], context {
            $0.composerIsFirstResponder = true; $0.hasUserMessage = true; $0.route = .shelf
        }))
        XCTAssertNil(map(.up, [], context {
            $0.composerIsFirstResponder = true; $0.hasUserMessage = true; $0.hasMarkedText = true
        }), "candidate selection belongs to the input method")
    }

    func testDownArrow() {
        XCTAssertEqual(map(.down, [], context { $0.route = .history }), .historyMoveSelection(1))
        XCTAssertNil(map(.down, [], Context()))
        XCTAssertNil(map(.down, [], context { $0.route = .shelf }))
    }

    func testArrowsIgnoreNumericPadAndFunctionFlags() {
        XCTAssertEqual(map(.down, [.numericPad, .function], context { $0.route = .history }),
                       .historyMoveSelection(1))
        XCTAssertEqual(map(.up, [.command, .shift, .numericPad, .function]), .enterTallMode)
    }

    func testTallModeChords() {
        XCTAssertEqual(map(.up, commandShift), .enterTallMode)
        XCTAssertEqual(map(.down, commandShift), .exitTallMode)

        let typing = context { $0.composerIsFirstResponder = true; $0.composerHasText = true }
        XCTAssertNil(map(.up, commandShift, typing), "the composer keeps select-to-beginning")
        XCTAssertNil(map(.down, commandShift, typing), "the composer keeps select-to-end")

        XCTAssertEqual(map(.up, commandShift, context { $0.composerHasText = true }), .enterTallMode)
        XCTAssertEqual(map(.down, commandShift, context { $0.composerIsFirstResponder = true }), .exitTallMode)
    }

    // MARK: - Delete

    func testCommandDelete() {
        XCTAssertEqual(map(.delete, command, context { $0.route = .history }), .historyDeleteSelected)
        XCTAssertNil(map(.delete, command, Context()), "text editing keeps ⌘⌫ on Chat")
    }

    func testBareDelete() {
        XCTAssertEqual(map(.delete, [], context { $0.route = .history }), .historyDeleteSelected)
        XCTAssertNil(map(.delete, [], context { $0.route = .history; $0.historySearchIsEmpty = false }))
        XCTAssertNil(map(.delete, [], context { $0.route = .history; $0.hasMarkedText = true }))
        XCTAssertNil(map(.delete, [], Context()))
    }

    // MARK: - ⌘ chords

    func testCommandPeriod() {
        XCTAssertEqual(map(.period, command, context { $0.isSpeaking = true; $0.isStreaming = true }), .stopSpeaking,
                       "a spoken reply stops first; the stream keeps going")
        XCTAssertEqual(map(.period, command, context { $0.isStreaming = true }), .stop)
        XCTAssertEqual(map(.period, command, context { $0.isListening = true }), .stop)
        XCTAssertEqual(map(.period, command, Context()), .stop, "consumed even when nothing is running")
    }

    func testCommandPeriodOnLayoutsThatShiftThePeriod() {
        XCTAssertEqual(map(azertyPeriod, commandShift, context { $0.isStreaming = true }), .stop)
        XCTAssertEqual(map(azertyPeriod, commandShift, context { $0.isSpeaking = true }), .stopSpeaking)
        XCTAssertEqual(map(Key(keyCode: kVK_ANSI_Period, characters: ">"), commandShift), .stop, "US ⌘⇧. too")
        XCTAssertEqual(map(azertyPeriod, commandShift, context { $0.isEngaged = false }), .releaseSoftFocus)
    }

    func testRegenerate() {
        XCTAssertEqual(map(.r, command, context { $0.hasUserMessage = true }), .regenerate)
        XCTAssertNil(map(.r, command, Context()))
        XCTAssertNil(map(.r, command, context { $0.hasUserMessage = true; $0.route = .shelf }))
    }

    func testCopyLastReply() {
        XCTAssertEqual(map(Key(keyCode: kVK_ANSI_C, characters: "C"), commandShift), .copyLastReply)
        XCTAssertEqual(map(.c, commandShift, context { $0.route = .history }), .copyLastReply)
        XCTAssertNil(map(.c, command), "plain ⌘C copies text")
    }

    func testShortcutSheetWithAndWithoutShift() {
        XCTAssertEqual(map(.slash, command), .toggleShortcutSheet)
        XCTAssertEqual(map(Key(keyCode: kVK_ANSI_Slash, characters: "?"), commandShift), .toggleShortcutSheet)
        XCTAssertEqual(map(.slash, command, context { $0.overlay = .shortcutSheet }), .toggleShortcutSheet)
    }

    func testPinAndModels() {
        XCTAssertEqual(map(.p, command), .togglePin)
        XCTAssertEqual(map(.one, command), .selectModel(.opus5))
        XCTAssertEqual(map(.two, command), .selectModel(.sonnet5))
        XCTAssertEqual(map(.three, command), .selectModel(.haiku45))
        XCTAssertNil(map(us(kVK_ANSI_4, "4"), command))
    }

    func testHistoryAndShelfToggles() {
        XCTAssertEqual(map(.y, command), .toggleHistory)
        XCTAssertNil(map(.y, command, context { $0.isHistoryAvailable = false }))
        XCTAssertEqual(map(.d, command), .toggleShelf)
        XCTAssertNil(map(.d, command, context { $0.isShelfEnabled = false }))
    }

    func testHistoryScopedChords() {
        XCTAssertEqual(map(.f, command, context { $0.route = .history }), .historyFocusSearch)
        XCTAssertNil(map(.f, command))
        XCTAssertEqual(map(.z, command, context { $0.route = .history; $0.hasPendingHistoryDeletion = true }),
                       .historyUndoDelete)
        XCTAssertNil(map(.z, command, context { $0.route = .history }), "text undo")
        XCTAssertNil(map(.z, command, context { $0.hasPendingHistoryDeletion = true }))
    }

    func testNewChatSettingsAndClose() {
        XCTAssertEqual(map(.n, command), .newChat)
        XCTAssertEqual(map(.comma, command), .openSettings)
        XCTAssertEqual(map(.w, command), .close)
        XCTAssertEqual(map(.n, command, context { $0.route = .shelf }), .newChat)
    }

    func testCommandV() {
        XCTAssertEqual(map(.v, command, context { $0.route = .shelf }), .shelfPaste)
        XCTAssertEqual(map(.v, command, context { $0.clipboardWantsAttachmentPaste = true }), .pasteAsAttachment)
        XCTAssertNil(map(.v, command), "plain text pastes into the composer")
        XCTAssertNil(map(.v, command, context { $0.route = .history; $0.clipboardWantsAttachmentPaste = true }))
    }

    // MARK: - ⌥⌘ chords

    func testMediaKeys() {
        let playing = context { $0.hasNowPlaying = true }
        XCTAssertEqual(map(.p, optionCommand, playing), .media(.playPause))
        XCTAssertEqual(map(.rightBracket, optionCommand, playing), .media(.next))
        XCTAssertEqual(map(.leftBracket, optionCommand, playing), .media(.previous))
        XCTAssertNil(map(.p, optionCommand))
        XCTAssertNil(map(.rightBracket, optionCommand))
        XCTAssertNil(map(.leftBracket, optionCommand))
    }

    func testJoinMeetingAndUsage() {
        XCTAssertEqual(map(.j, optionCommand, context { $0.hasMeetingChip = true }), .joinMeeting)
        XCTAssertNil(map(.j, optionCommand))
        XCTAssertEqual(map(.u, optionCommand), .showUsage)
    }

    func testShelfRevealChordIsLeftToTheShelfView() {
        XCTAssertNil(map(.r, optionCommand, context { $0.route = .shelf }))
        XCTAssertNil(map(.a, command, context { $0.route = .shelf }))
    }

    // MARK: - Unmapped keys and exact modifiers

    func testUnmappedKeysPassThrough() {
        XCTAssertNil(map(.k, command))
        XCTAssertNil(map(.a, []))
        XCTAssertNil(map(.n, [.control]))
        XCTAssertNil(map(.n, [.command, .control]), "modifiers must match exactly")
        XCTAssertNil(map(.escape, [.shift]))
        XCTAssertNil(map(Key(keyCode: kVK_F5, characters: "\u{F708}"), []))
        XCTAssertNil(map(Key(keyCode: kVK_ANSI_1, characters: "!"), commandShift), "⌘⇧1 is not ⌘1")
    }

    func testCapsLockIsIgnored() {
        XCTAssertEqual(map(Key(keyCode: kVK_ANSI_N, characters: "N"), [.command, .capsLock]), .newChat)
    }

    // MARK: - Non-US layouts

    func testKeyCodeFallbackForNonLatinLayouts() {
        // Russian: the N key types "т", the P key "з".
        XCTAssertEqual(map(Key(keyCode: kVK_ANSI_N, characters: "т"), command), .newChat)
        XCTAssertEqual(map(Key(keyCode: kVK_ANSI_P, characters: "з"), command), .togglePin)
        XCTAssertEqual(map(Key(keyCode: kVK_ANSI_C, characters: "С"), commandShift), .copyLastReply)
        XCTAssertEqual(map(Key(keyCode: kVK_ANSI_J, characters: "о"), optionCommand, context { $0.hasMeetingChip = true }),
                       .joinMeeting)
    }

    func testKeyCodeFallbackForAZERTYDigits() {
        // AZERTY: the 1 2 3 keys type & é " without ⇧.
        XCTAssertEqual(map(Key(keyCode: kVK_ANSI_1, characters: "&"), command), .selectModel(.opus5))
        XCTAssertEqual(map(Key(keyCode: kVK_ANSI_2, characters: "é"), command), .selectModel(.sonnet5))
        XCTAssertEqual(map(Key(keyCode: kVK_ANSI_3, characters: "\""), command), .selectModel(.haiku45))
    }

    func testTypedLatinCharacterWinsOverKeyCode() {
        // Dvorak: the key at ANSI B types "n"; the key at ANSI N types "b".
        XCTAssertEqual(map(Key(keyCode: kVK_ANSI_B, characters: "n"), command), .newChat)
        XCTAssertNil(map(Key(keyCode: kVK_ANSI_N, characters: "b"), command))
    }

    func testMissingCharactersFallBackToKeyCode() {
        XCTAssertEqual(map(Key(keyCode: kVK_ANSI_N, characters: nil), command), .newChat)
        XCTAssertEqual(map(Key(keyCode: kVK_ANSI_Slash, characters: ""), command), .toggleShortcutSheet)
    }

    // MARK: - isTypingKey

    func testTypingKeys() {
        let typing: [(Int, NSEvent.ModifierFlags)] = [
            (kVK_ANSI_A, []), (kVK_ANSI_A, [.shift]), (kVK_ANSI_A, [.option]), (kVK_ANSI_1, []), (kVK_Space, []),
            (kVK_ANSI_Slash, [.shift]), (kVK_Return, []), (kVK_ANSI_KeypadEnter, []), (kVK_Delete, []),
            (kVK_ForwardDelete, []), (kVK_UpArrow, []), (kVK_DownArrow, [.shift]), (kVK_LeftArrow, [.option]),
            (kVK_RightArrow, []), (kVK_ANSI_Keypad5, []),
        ]
        for (keyCode, flags) in typing {
            XCTAssertTrue(NotchKeyCommands.isTypingKey(keyCode: UInt16(keyCode), flags: flags), "key code \(keyCode)")
        }
    }

    func testNonTypingKeys() {
        let notTyping: [(Int, NSEvent.ModifierFlags)] = [
            (kVK_ANSI_A, [.command]), (kVK_ANSI_C, [.command]), (kVK_ANSI_A, [.control]), (kVK_Return, [.command]),
            (kVK_UpArrow, [.command, .shift]), (kVK_Escape, []), (kVK_Tab, []), (kVK_F1, []), (kVK_F12, []),
            (kVK_Home, []), (kVK_PageDown, []), (kVK_Shift, [.shift]), (kVK_Command, [.command]), (kVK_Option, []),
            (kVK_VolumeUp, []),
        ]
        for (keyCode, flags) in notTyping {
            XCTAssertFalse(NotchKeyCommands.isTypingKey(keyCode: UInt16(keyCode), flags: flags), "key code \(keyCode)")
        }
    }

    // MARK: - softFocusPromotion

    func testSoftFocusPromotion() {
        func promotion(_ keyCode: Int, _ flags: NSEvent.ModifierFlags = [], soft: Bool = true,
                       engaged: Bool = false) -> NotchKeyCommands.SoftFocusPromotion {
            NotchKeyCommands.softFocusPromotion(keyCode: UInt16(keyCode), flags: flags, isSoftFocused: soft,
                                                isEngaged: engaged)
        }
        XCTAssertEqual(promotion(kVK_Return), .engageAndConsume, "the first Return only engages")
        XCTAssertEqual(promotion(kVK_ANSI_KeypadEnter), .engageAndConsume)
        XCTAssertEqual(promotion(kVK_Return, [.shift]), .engageAndConsume)
        XCTAssertEqual(promotion(kVK_ANSI_A), .engageAndPassThrough)
        XCTAssertEqual(promotion(kVK_ANSI_A, [.shift]), .engageAndPassThrough)
        XCTAssertEqual(promotion(kVK_Delete), .engageAndPassThrough)
        XCTAssertEqual(promotion(kVK_UpArrow), .engageAndPassThrough)
        XCTAssertEqual(promotion(kVK_ANSI_C, [.command]), .none, "⌘C is not typing")
        XCTAssertEqual(promotion(kVK_Escape), .none)
        XCTAssertEqual(promotion(kVK_ANSI_A, soft: false), .none, "not soft-focused")
        XCTAssertEqual(promotion(kVK_ANSI_A, engaged: true), .none, "already engaged")
        XCTAssertEqual(promotion(kVK_Return, engaged: true), .none, "an engaged Return reaches the composer")
    }

    // MARK: - Helpers

    private func us(_ keyCode: Int, _ character: String) -> Key { Key.us(keyCode, character) }
}
