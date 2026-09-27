//
//  NotchKeyCommands.swift
//  Otto
//
//  The notch's keyboard map (SPEC-v2 §4.4) as a pure function: a key event plus a snapshot of the notch's
//  state in, at most one command out. The window controller reads AppKit state and dispatches; this file only
//  decides. The first matching row wins.
//

import AppKit
import Carbon.HIToolbox

enum NotchKeyCommands {
    /// `flags` = deviceIndependentFlagsMask minus capsLock/numericPad/function. nil = let the event through.
    static func command(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags,
                        context: NotchKeyContext) -> NotchKeyCommand? {
        let modifiers = flags.intersection(chordModifiers)
        guard let key = Key(keyCode: keyCode, characters: characters, shifted: modifiers.contains(.shift)) else {
            return nil
        }
        let chord = Chord(key, modifiers)

        // Soft focus is not engagement: anything that sends, spends tokens, approves, pastes, changes the model or
        // discards only hands the keyboard back.
        if !context.isEngaged, softFocusReleaseChords.contains(chord) { return .releaseSoftFocus }

        // While an input method is composing, bare editing keys belong to it.
        if context.hasMarkedText, modifiers.isEmpty, key.isEditingKey { return nil }

        switch chord {
        case Chord(.escape):
            return escapeCommand(context)
        case Chord(.returnKey):
            return returnCommand(context)
        case Chord(.returnKey, .command):
            return commandReturnCommand(context)
        case Chord(.returnKey, [.option, .command]):
            let canPastePlain = context.route == .chat && context.prompt == .none && context.composerIsEmpty
                && context.canInsertLastAnswer
            return canPastePlain ? .insertLastAnswer(.pastePlain) : nil
        case Chord(.upArrow):
            if context.route == .history { return .historyMoveSelection(-1) }
            let canRecall = context.route == .chat && context.composerIsFirstResponder && context.composerIsEmpty
                && !context.isEditing && context.hasUserMessage
            return canRecall ? .recallLastMessage : nil
        case Chord(.downArrow):
            return context.route == .history ? .historyMoveSelection(1) : nil
        case Chord(.upArrow, [.command, .shift]):
            return composerOwnsSelectionChords(context) ? nil : .enterTallMode
        case Chord(.downArrow, [.command, .shift]):
            return composerOwnsSelectionChords(context) ? nil : .exitTallMode
        case Chord(.delete, .command):
            return context.route == .history ? .historyDeleteSelected : nil
        case Chord(.delete):
            return context.route == .history && context.historySearchIsEmpty ? .historyDeleteSelected : nil
        case Chord(.character("."), .command):
            return context.isSpeaking ? .stopSpeaking : .stop
        case Chord(.character("r"), .command):
            return context.route == .chat && context.hasUserMessage ? .regenerate : nil
        case Chord(.character("c"), [.command, .shift]):
            return .copyLastReply
        case Chord(.character("/"), .command), Chord(.character("/"), [.command, .shift]):
            return .toggleShortcutSheet
        case Chord(.character("p"), .command):
            return .togglePin
        case Chord(.character("1"), .command):
            return .selectModel(.opus5)
        case Chord(.character("2"), .command):
            return .selectModel(.sonnet5)
        case Chord(.character("3"), .command):
            return .selectModel(.haiku45)
        case Chord(.character("y"), .command):
            return context.isHistoryAvailable ? .toggleHistory : nil
        case Chord(.character("d"), .command):
            return context.isShelfEnabled ? .toggleShelf : nil
        case Chord(.character("f"), .command):
            return context.route == .history ? .historyFocusSearch : nil
        case Chord(.character("z"), .command):
            return context.route == .history && context.hasPendingHistoryDeletion ? .historyUndoDelete : nil
        case Chord(.character("n"), .command):
            return .newChat
        case Chord(.character(","), .command):
            return .openSettings
        case Chord(.character("w"), .command):
            return .close
        case Chord(.character("v"), .command):
            if context.route == .shelf { return .shelfPaste }
            return context.route == .chat && context.clipboardWantsAttachmentPaste ? .pasteAsAttachment : nil
        case Chord(.character("p"), [.option, .command]):
            return context.hasNowPlaying ? .media(.playPause) : nil
        case Chord(.character("]"), [.option, .command]):
            return context.hasNowPlaying ? .media(.next) : nil
        case Chord(.character("["), [.option, .command]):
            return context.hasNowPlaying ? .media(.previous) : nil
        case Chord(.character("j"), [.option, .command]):
            return context.hasMeetingChip ? .joinMeeting : nil
        case Chord(.character("u"), [.option, .command]):
            return .showUsage
        default:
            return nil
        }
    }

    /// Characters, arrows, Delete and Return; never ⌘/⌃ combinations, Esc, Tab or F-keys (soft-focus promotion,
    /// voice typing).
    static func isTypingKey(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.intersection([.command, .control]).isEmpty else { return false }
        return !nonTypingKeyCodes.contains(Int(keyCode))
    }

    enum SoftFocusPromotion: Equatable, Sendable { case none, engageAndPassThrough, engageAndConsume }

    /// Rule 2 of §4.4 (pure; the window controller applies it): a typing key while soft-focused and not engaged
    /// engages; Return/⌅ is consumed (never sends), every other typing key passes through.
    static func softFocusPromotion(keyCode: UInt16, flags: NSEvent.ModifierFlags, isSoftFocused: Bool,
                                   isEngaged: Bool) -> SoftFocusPromotion {
        guard isSoftFocused, !isEngaged, isTypingKey(keyCode: keyCode, flags: flags) else { return .none }
        let isReturn = Int(keyCode) == kVK_Return || Int(keyCode) == kVK_ANSI_KeypadEnter
        return isReturn ? .engageAndConsume : .engageAndPassThrough
    }

    // MARK: - Ladders (rows that share a key, in table order)

    private static func escapeCommand(_ context: NotchKeyContext) -> NotchKeyCommand {
        if context.isListening { return .cancelVoice }
        if context.isSpeaking { return .stopSpeaking }
        if context.overlay != nil { return .dismissOverlay }
        if context.prompt != .none { return .promptSecondary }
        if context.hasInsertConfirmation { return .cancelInsertConfirmation }
        if context.isEditing { return .cancelEditing }
        if context.route != .chat { return .backToChat }
        return .close
    }

    /// A bare Return never approves and never runs a primary that needs a deliberate ⌘↩ ("Quit & Reopen Otto");
    /// with no row it falls through to the composer, which sends.
    private static func returnCommand(_ context: NotchKeyContext) -> NotchKeyCommand? {
        if context.isListening { return .finishVoice }
        if context.route == .history { return .historyOpenSelected }
        if context.prompt == .other, context.composerIsEmpty, !context.promptPrimaryRequiresCommand {
            return .promptPrimary
        }
        if context.hasInsertConfirmation, context.composerIsEmpty { return .confirmInsert }
        return nil
    }

    /// Prompt first, then the Shelf, then Insert.
    private static func commandReturnCommand(_ context: NotchKeyContext) -> NotchKeyCommand? {
        if context.prompt != .none { return .promptPrimary }
        if context.route == .shelf { return .shelfAskAboutSelection }
        if context.route == .chat, context.composerIsEmpty, context.canInsertLastAnswer { return .insertLastAnswer(nil) }
        return nil
    }

    /// ⌘⇧↑/↓ select to the beginning/end of the composer's text while it has focus and text.
    private static func composerOwnsSelectionChords(_ context: NotchKeyContext) -> Bool {
        context.composerIsFirstResponder && context.composerHasText
    }

    // MARK: - Keys and chords

    private static let chordModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// ⌘↩ ⌥⌘↩ ⌘R ⌘N ⌘1 ⌘2 ⌘3 ⌘⇧C ⌘. ⌥⌘J ⌘⌫.
    private static let softFocusReleaseChords: Set<Chord> = [
        Chord(.returnKey, .command), Chord(.returnKey, [.option, .command]),
        Chord(.character("r"), .command), Chord(.character("n"), .command),
        Chord(.character("1"), .command), Chord(.character("2"), .command), Chord(.character("3"), .command),
        Chord(.character("c"), [.command, .shift]), Chord(.character("."), .command),
        Chord(.character("j"), [.option, .command]), Chord(.delete, .command),
    ]

    private static let nonTypingKeyCodes: Set<Int> = [
        kVK_Escape, kVK_Tab, kVK_Help, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ANSI_KeypadClear,
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
        kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function,
        kVK_VolumeUp, kVK_VolumeDown, kVK_Mute, kVK_JIS_Eisu, kVK_JIS_Kana,
    ]

    private enum Key: Hashable {
        case escape, returnKey, upArrow, downArrow, delete
        /// The US-layout character of the key, unshifted and lowercased ("c", "1", "/").
        case character(String)

        /// Keys an input method uses while composing.
        var isEditingKey: Bool {
            switch self {
            case .escape, .returnKey, .upArrow, .downArrow, .delete: return true
            case .character: return false
            }
        }

        /// Special keys by key code. Characters come from `charactersIgnoringModifiers` when it is a character a US
        /// keyboard types (shifted forms only with ⇧ held, so ⇧/ reads as "/"); any other character, such as "т" on
        /// a Russian layout or "&" on the AZERTY 1 key, falls back to the key code's US character.
        init?(keyCode: UInt16, characters: String?, shifted: Bool) {
            switch Int(keyCode) {
            case kVK_Escape: self = .escape
            case kVK_Return, kVK_ANSI_KeypadEnter: self = .returnKey
            case kVK_UpArrow: self = .upArrow
            case kVK_DownArrow: self = .downArrow
            case kVK_Delete: self = .delete
            default:
                if let typed = characters?.lowercased(), typed.count == 1,
                   let base = Key.usUnshifted.contains(typed) ? typed : (shifted ? Key.usShiftedToBase[typed] : nil) {
                    self = .character(base)
                } else if let fallback = Key.usCharacterByKeyCode[Int(keyCode)] {
                    self = .character(fallback)
                } else {
                    return nil
                }
            }
        }

        private static let usCharacterByKeyCode: [Int: String] = [
            kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e", kVK_ANSI_F: "f",
            kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l",
            kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r",
            kVK_ANSI_S: "s", kVK_ANSI_T: "t", kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x",
            kVK_ANSI_Y: "y", kVK_ANSI_Z: "z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
            kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        ]

        private static let usUnshifted: Set<String> = Set(usCharacterByKeyCode.values)

        private static let usShiftedToBase: [String: String] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
            "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".",
            "?": "/", "~": "`",
        ]
    }

    private struct Chord: Hashable {
        let key: Key
        let modifiers: UInt

        init(_ key: Key, _ modifiers: NSEvent.ModifierFlags = []) {
            self.key = key
            self.modifiers = modifiers.intersection(NotchKeyCommands.chordModifiers).rawValue
        }
    }
}
