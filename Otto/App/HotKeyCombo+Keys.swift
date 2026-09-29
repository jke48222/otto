//
//  HotKeyCombo+Keys.swift
//  Otto
//
//  Everything about the global shortcut that goes beyond storage: reading a combo from a key event,
//  showing it ("⌃⌥⇧⌘K"), turning it into a menu key equivalent, and deciding whether it may be used at
//  all (typing keys, macOS reserved chords, enabled system shortcuts, and Otto's own notch chords).
//

import AppKit
import Carbon.HIToolbox

extension HotKeyCombo {
    /// A keyDown event as a combo; nil for other event types and for modifier-only keys.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let keyCode = UInt32(event.keyCode)
        guard !Self.modifierKeyCodes.contains(keyCode) else { return nil }
        self.init(keyCode: keyCode, carbonModifiers: Self.carbonModifiers(from: event.modifierFlags))
    }

    /// Modifier glyphs in Apple's order (⌃⌥⇧⌘) followed by the key name: "⌥Space", "⌃⌥⇧⌘K".
    var displayString: String { displayKeyCaps.joined() }

    /// One entry per key cap, for the shortcut sheet and menus: ["⌥", "Space"].
    var displayKeyCaps: [String] {
        let modifiers = maskedModifiers
        var caps: [String] = []
        if modifiers & UInt32(controlKey) != 0 { caps.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { caps.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { caps.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { caps.append("⌘") }
        caps.append(KeyNames.name(for: keyCode))
        return caps
    }

    /// The key equivalent for an NSMenuItem (status item "Open Otto"); nil when the key has no single-character
    /// equivalent (for example a key the current layout can't name).
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        let key: String
        if let special = Self.menuSpecialKeys[keyCode] {
            key = special
        } else if let functionKey = Self.functionKeyNumbers[keyCode],
                  let scalar = UnicodeScalar(UInt32(NSF1FunctionKey + functionKey - 1)) {
            key = String(Character(scalar))
        } else {
            let name = KeyNames.name(for: keyCode)
            guard name.count == 1 else { return nil }
            key = name.lowercased()
        }
        return (key, modifierFlags)
    }

    /// Why this combo can't be the global shortcut, or nil when it can. Registration failures (`inUse`,
    /// `failed`) come later, from the registrar.
    func validationProblem(systemShortcuts: [SystemShortcut]) -> HotKeyProblem? {
        let modifiers = maskedModifiers
        let isFunctionKey = Self.functionKeyNumbers[keyCode] != nil
        if modifiers == 0, !isFunctionKey { return .needsModifier }
        if modifiers == UInt32(shiftKey), !isFunctionKey { return .shiftOnly }
        let normalized = HotKeyCombo(keyCode: keyCode, carbonModifiers: modifiers)
        if Self.reservedChords.contains(normalized) { return .reserved(displayString) }
        if Self.ottoChords.contains(normalized) { return .conflictsWithOtto(displayString) }
        let clashesWithSystem = systemShortcuts.contains {
            $0.keyCode == keyCode && $0.carbonModifiers & Self.modifierMask == modifiers
        }
        if clashesWithSystem { return .system }
        return nil
    }

    // MARK: - Tables

    /// ⌘ ⌥ ⌃ ⇧ only; Carbon also carries caps lock and right-side bits.
    fileprivate static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    fileprivate var maskedModifiers: UInt32 { carbonModifiers & Self.modifierMask }

    private static let modifierKeyCodes: Set<UInt32> = Set([
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
        kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function,
    ].map(UInt32.init))

    /// kVK_F1…kVK_F20 → 1…20 (the key codes are not contiguous).
    fileprivate static let functionKeyNumbers: [UInt32: Int] = {
        let codes = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        var numbers: [UInt32: Int] = [:]
        for (index, code) in codes.enumerated() { numbers[UInt32(code)] = index + 1 }
        return numbers
    }()

    private static let menuSpecialKeys: [UInt32: String] = {
        func functionKey(_ value: Int) -> String {
            UnicodeScalar(UInt32(value)).map { String(Character($0)) } ?? ""
        }
        let keys: [Int: String] = [
            kVK_Space: " ",
            kVK_Return: "\r",
            kVK_ANSI_KeypadEnter: "\u{03}",
            kVK_Tab: "\t",
            kVK_Delete: "\u{08}",
            kVK_Escape: "\u{1B}",
            kVK_ForwardDelete: functionKey(NSDeleteFunctionKey),
            kVK_LeftArrow: functionKey(NSLeftArrowFunctionKey),
            kVK_RightArrow: functionKey(NSRightArrowFunctionKey),
            kVK_UpArrow: functionKey(NSUpArrowFunctionKey),
            kVK_DownArrow: functionKey(NSDownArrowFunctionKey),
            kVK_Home: functionKey(NSHomeFunctionKey),
            kVK_End: functionKey(NSEndFunctionKey),
            kVK_PageUp: functionKey(NSPageUpFunctionKey),
            kVK_PageDown: functionKey(NSPageDownFunctionKey),
        ]
        var result: [UInt32: String] = [:]
        for (code, key) in keys where !key.isEmpty { result[UInt32(code)] = key }
        return result
    }()

    /// Chords macOS keeps for itself: ⌘Q ⌘W ⌘H ⌘M ⌘⇥ ⌘` ⌥⌘⎋.
    private static let reservedChords: Set<HotKeyCombo> = {
        let command = UInt32(cmdKey)
        return [
            HotKeyCombo(keyCode: UInt32(kVK_ANSI_Q), carbonModifiers: command),
            HotKeyCombo(keyCode: UInt32(kVK_ANSI_W), carbonModifiers: command),
            HotKeyCombo(keyCode: UInt32(kVK_ANSI_H), carbonModifiers: command),
            HotKeyCombo(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: command),
            HotKeyCombo(keyCode: UInt32(kVK_Tab), carbonModifiers: command),
            HotKeyCombo(keyCode: UInt32(kVK_ANSI_Grave), carbonModifiers: command),
            HotKeyCombo(keyCode: UInt32(kVK_Escape), carbonModifiers: command | UInt32(optionKey)),
        ]
    }()

    /// Every chord of the notch's key table (SPEC-v2 §4.4 plus the Shelf's ⌘A ⌘C ⌥⌘R). A global hot key on one
    /// of them would swallow it in every app, so the notch command could never run.
    fileprivate static let ottoChords: Set<HotKeyCombo> = {
        let command = UInt32(cmdKey)
        let commandShift = command | UInt32(shiftKey)
        let optionCommand = command | UInt32(optionKey)
        let chords: [(Int, UInt32)] = [
            (kVK_ANSI_N, command), (kVK_ANSI_Y, command), (kVK_ANSI_D, command), (kVK_ANSI_P, command),
            (kVK_ANSI_R, command), (kVK_ANSI_1, command), (kVK_ANSI_2, command), (kVK_ANSI_3, command),
            (kVK_ANSI_Slash, command), (kVK_ANSI_Slash, commandShift), (kVK_ANSI_Period, command),
            (kVK_ANSI_Period, commandShift),
            (kVK_ANSI_Comma, command), (kVK_ANSI_F, command), (kVK_ANSI_Z, command), (kVK_ANSI_V, command),
            (kVK_ANSI_A, command), (kVK_ANSI_C, command), (kVK_ANSI_C, commandShift),
            (kVK_UpArrow, commandShift), (kVK_DownArrow, commandShift),
            (kVK_Return, command), (kVK_ANSI_KeypadEnter, command),
            (kVK_Return, optionCommand), (kVK_ANSI_KeypadEnter, optionCommand),
            (kVK_Delete, command),
            (kVK_ANSI_P, optionCommand), (kVK_ANSI_RightBracket, optionCommand),
            (kVK_ANSI_LeftBracket, optionCommand), (kVK_ANSI_J, optionCommand), (kVK_ANSI_U, optionCommand),
            (kVK_ANSI_R, optionCommand),
        ]
        return Set(chords.map { HotKeyCombo(keyCode: UInt32($0.0), carbonModifiers: $0.1) })
    }()
}

enum HotKeyProblem: Equatable, LocalizedError {
    case needsModifier, shiftOnly, reserved(String), system, inUse(String), failed(Int32)
    /// Any chord of the §4.4 table (⌘N ⌘Y ⌘D ⌘P ⌘R ⌘1–⌘3 ⌘/ ⌘. ⌘, ⌘F ⌘Z ⌘V ⌘A ⌘C ⌘⇧C ⌘⇧↑ ⌘⇧↓ ⌘↩ ⌥⌘↩ ⌥⌘P ⌥⌘] ⌥⌘[
    /// ⌥⌘J ⌥⌘U ⌥⌘R): rejected, because a global hot key would also swallow that chord in every app and silence the
    /// notch command. Copy: "⌘N is one of Otto's own shortcuts in the notch. Pick another."
    case conflictsWithOtto(String)

    var errorDescription: String? {
        switch self {
        case .needsModifier:
            return "Add ⌘, ⌥ or ⌃ so the shortcut doesn't get in the way of typing."
        case .shiftOnly:
            return "⇧ alone isn't enough. Add ⌘, ⌥ or ⌃."
        case .reserved(let combo):
            return "\(combo) is reserved by macOS."
        case .system:
            return "macOS already uses this shortcut. Change it in System Settings → Keyboard → Keyboard Shortcuts, or pick another."
        case .inUse(let combo):
            return "Another app is already using \(combo)."
        case .failed(let status):
            return "Couldn't register this shortcut (error \(status))."
        case .conflictsWithOtto(let combo):
            return "\(combo) is one of Otto's own shortcuts in the notch. Pick another."
        }
    }
}

struct SystemShortcut: Equatable { var keyCode: UInt32; var carbonModifiers: UInt32 }

enum SystemShortcuts {
    /// Dictionary keys of a `CopySymbolicHotKeys` entry. The CFSTR macros don't import into Swift.
    private static let codeKey = "kHISymbolicHotKeyCode"
    private static let modifiersKey = "kHISymbolicHotKeyModifiers"
    private static let enabledKey = "kHISymbolicHotKeyEnabled"
    /// Symbolic hot keys with no key assigned report this code.
    private static let unassignedKeyCode = 0xFFFF

    /// The enabled symbolic hot keys (Spotlight ⌘Space, input sources ⌃Space, Mission Control, …).
    static func current() -> [SystemShortcut] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let array = unmanaged?.takeRetainedValue() else { return [] }
        guard let entries = array as? [[String: Any]] else { return [] }
        return parse(entries)
    }

    /// Pure parser for `CopySymbolicHotKeys` entries: enabled entries with an assigned key, modifiers reduced to
    /// ⌘ ⌥ ⌃ ⇧.
    static func parse(_ entries: [[String: Any]]) -> [SystemShortcut] {
        entries.compactMap { entry in
            guard let enabled = entry[enabledKey] as? Bool, enabled,
                  let code = (entry[codeKey] as? NSNumber)?.intValue,
                  code >= 0, code < unassignedKeyCode,
                  let modifiers = (entry[modifiersKey] as? NSNumber)?.intValue,
                  modifiers >= 0
            else { return nil }
            return SystemShortcut(
                keyCode: UInt32(code),
                carbonModifiers: UInt32(truncatingIfNeeded: modifiers) & HotKeyCombo.modifierMask
            )
        }
    }
}

enum KeyNames {
    /// Special keys by symbol or name (Space, ↩, ⇥, ⌫, ⌦, ⎋, arrows, F1–F20, ↖ ↘ ⇞ ⇟); every other key is the
    /// character the current keyboard layout prints on it, uppercased. The layout is read on the main thread only
    /// (Text Input Sources require it); elsewhere, and when the layout can't name a key, US names are used.
    static func name(for keyCode: UInt32) -> String {
        if let special = specialNames[keyCode] { return special }
        if let number = HotKeyCombo.functionKeyNumbers[keyCode] { return "F\(number)" }
        if Thread.isMainThread, let character = layoutCharacter(for: keyCode) { return character }
        if let fallback = usNames[keyCode] { return fallback }
        return "Key \(keyCode)"
    }

    private static let specialNames: [UInt32: String] = {
        let names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌅", kVK_Tab: "⇥",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Help: "Help",
        ]
        var result: [UInt32: String] = [:]
        for (code, name) in names { result[UInt32(code)] = name }
        return result
    }()

    /// What the key prints on a US layout, for when the current layout can't say.
    private static let usNames: [UInt32: String] = {
        let names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
            kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        ]
        var result: [UInt32: String] = [:]
        for (code, name) in names { result[UInt32(code)] = name }
        return result
    }()

    /// UCKeyTranslate against the current layout, then the current ASCII-capable layout (a Japanese or Chinese
    /// input method has no Unicode key layout of its own).
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
        for unmanagedSource in sources {
            guard let source = unmanagedSource?.takeRetainedValue(),
                  let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { continue }
            let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(layoutData) else { continue }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            if let character = translate(keyCode, layout: layout) { return character }
        }
        return nil
    }

    private static func translate(_ keyCode: UInt32, layout: UnsafePointer<UCKeyboardLayout>) -> String? {
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            layout,
            UInt16(truncatingIfNeeded: keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
        return text.isEmpty ? nil : text.uppercased()
    }
}
