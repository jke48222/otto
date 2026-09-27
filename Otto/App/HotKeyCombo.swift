//
//  HotKeyCombo.swift
//  Otto
//
//  The global shortcut as it is stored: a Carbon key code plus Carbon modifier bits, with conversions
//  to and from Cocoa modifier flags. Display, validation and event parsing live in HotKeyCombo+Keys.
//

import AppKit
import Carbon.HIToolbox

struct HotKeyCombo: Codable, Equatable, Hashable, Sendable {
    /// kVK_*.
    var keyCode: UInt32
    /// cmdKey | optionKey | controlKey | shiftKey.
    var carbonModifiers: UInt32

    static let optionSpace = HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))

    /// Carbon modifier bits as Cocoa flags.
    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    /// Cocoa flags as Carbon modifier bits (only ⌘ ⌥ ⌃ ⇧ count).
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }
}

enum HotKeyStatus: Equatable, Sendable { case registered, disabled, inUse, failed(Int32) }

/// `rejected` carries the user-facing message.
enum HotKeyApplyResult: Equatable, Sendable { case applied, rejected(String) }
