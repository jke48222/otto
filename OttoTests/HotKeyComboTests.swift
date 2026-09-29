//
//  HotKeyComboTests.swift
//  Otto
//

import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Otto

final class HotKeyComboTests: XCTestCase {
    private let command = UInt32(cmdKey)
    private let option = UInt32(optionKey)
    private let control = UInt32(controlKey)
    private let shift = UInt32(shiftKey)

    private func combo(_ keyCode: Int, _ modifiers: UInt32) -> HotKeyCombo {
        HotKeyCombo(keyCode: UInt32(keyCode), carbonModifiers: modifiers)
    }

    // MARK: - Storage core

    func testCodableRoundTrip() throws {
        let original = combo(kVK_ANSI_K, control | option | shift | command)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(HotKeyCombo.self, from: data), original)
        XCTAssertEqual(try JSONDecoder().decode(HotKeyCombo.self, from: JSONEncoder().encode(HotKeyCombo.optionSpace)),
                       .optionSpace)
    }

    func testModifierConversionsRoundTrip() {
        let flags: [NSEvent.ModifierFlags] = [[], [.command], [.option], [.control], [.shift],
                                              [.command, .shift], [.control, .option, .shift, .command]]
        for flag in flags {
            let carbon = HotKeyCombo.carbonModifiers(from: flag)
            XCTAssertEqual(HotKeyCombo(keyCode: 0, carbonModifiers: carbon).modifierFlags, flag)
        }
        XCTAssertEqual(HotKeyCombo.carbonModifiers(from: [.command, .option]), command | option)
        XCTAssertEqual(HotKeyCombo.carbonModifiers(from: [.capsLock, .function, .numericPad]), 0,
                       "only ⌘ ⌥ ⌃ ⇧ count")
        XCTAssertEqual(HotKeyCombo.optionSpace.modifierFlags, [.option])
    }

    // MARK: - Event parsing

    func testInitFromKeyDownEvent() throws {
        let event = try XCTUnwrap(keyEvent(.keyDown, keyCode: kVK_Space, flags: [.option, .capsLock], characters: " "))
        XCTAssertEqual(HotKeyCombo(event: event), .optionSpace)

        let letter = try XCTUnwrap(keyEvent(.keyDown, keyCode: kVK_ANSI_K, flags: [.control, .command], characters: "k"))
        XCTAssertEqual(HotKeyCombo(event: letter), combo(kVK_ANSI_K, control | command))
    }

    func testInitFromEventRejectsModifierOnlyKeysAndKeyUp() throws {
        for keyCode in [kVK_Command, kVK_Shift, kVK_Option, kVK_Control, kVK_RightOption, kVK_CapsLock, kVK_Function] {
            let event = try XCTUnwrap(keyEvent(.keyDown, keyCode: keyCode, flags: [.option], characters: ""))
            XCTAssertNil(HotKeyCombo(event: event), "key code \(keyCode)")
        }
        let keyUp = try XCTUnwrap(keyEvent(.keyUp, keyCode: kVK_Space, flags: [.option], characters: " "))
        XCTAssertNil(HotKeyCombo(event: keyUp))
    }

    // MARK: - Display

    func testDisplayOrderIsControlOptionShiftCommand() {
        let all = combo(kVK_ANSI_K, command | shift | option | control)
        let key = KeyNames.name(for: UInt32(kVK_ANSI_K))
        XCTAssertEqual(all.displayKeyCaps, ["⌃", "⌥", "⇧", "⌘", key])
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘" + key)
        XCTAssertEqual(combo(kVK_ANSI_K, command | option).displayString, "⌥⌘" + key)
        XCTAssertEqual(combo(kVK_ANSI_K, shift | control).displayString, "⌃⇧" + key)
    }

    func testOptionSpaceDisplay() {
        XCTAssertEqual(HotKeyCombo.optionSpace.displayString, "⌥Space")
        XCTAssertEqual(HotKeyCombo.optionSpace.displayKeyCaps, ["⌥", "Space"])
    }

    func testDisplayIgnoresNonChordModifierBits() {
        let withCapsLock = combo(kVK_Space, option | UInt32(alphaLock))
        XCTAssertEqual(withCapsLock.displayString, "⌥Space")
    }

    func testKeyNamesForSpecialKeys() {
        let expected: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌅", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞",
            kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F5: "F5", kVK_F12: "F12", kVK_F13: "F13", kVK_F20: "F20",
        ]
        for (keyCode, name) in expected {
            XCTAssertEqual(KeyNames.name(for: UInt32(keyCode)), name, "key code \(keyCode)")
        }
    }

    func testKeyNamesForCharacterKeysAreSingleUppercaseCharacters() {
        for keyCode in [kVK_ANSI_A, kVK_ANSI_K, kVK_ANSI_Z] {
            let name = KeyNames.name(for: UInt32(keyCode))
            XCTAssertEqual(name.count, 1, "key code \(keyCode)")
            XCTAssertEqual(name, name.uppercased())
        }
    }

    // MARK: - Menu key equivalent

    func testMenuKeyEquivalentForSpace() throws {
        let equivalent = try XCTUnwrap(HotKeyCombo.optionSpace.menuKeyEquivalent)
        XCTAssertEqual(equivalent.key, " ")
        XCTAssertEqual(equivalent.modifiers, [.option])
    }

    func testMenuKeyEquivalentForLetterIsLowercaseWithShiftInModifiers() throws {
        let equivalent = try XCTUnwrap(combo(kVK_ANSI_K, command | shift).menuKeyEquivalent)
        XCTAssertEqual(equivalent.key, KeyNames.name(for: UInt32(kVK_ANSI_K)).lowercased())
        XCTAssertEqual(equivalent.modifiers, [.command, .shift])
    }

    func testMenuKeyEquivalentForFunctionAndArrowKeys() throws {
        let f5 = try XCTUnwrap(combo(kVK_F5, 0).menuKeyEquivalent)
        XCTAssertEqual(f5.key.unicodeScalars.first?.value, UInt32(NSF5FunctionKey))
        XCTAssertEqual(f5.modifiers, [])

        let up = try XCTUnwrap(combo(kVK_UpArrow, control | option).menuKeyEquivalent)
        XCTAssertEqual(up.key.unicodeScalars.first?.value, UInt32(NSUpArrowFunctionKey))
        XCTAssertEqual(up.modifiers, [.control, .option])

        XCTAssertEqual(combo(kVK_Return, command | option).menuKeyEquivalent?.key, "\r")
    }

    // MARK: - Validation

    func testDefaultIsValid() {
        XCTAssertNil(HotKeyCombo.optionSpace.validationProblem(systemShortcuts: []))
        XCTAssertNil(combo(kVK_ANSI_K, control | option).validationProblem(systemShortcuts: []))
    }

    func testBareKeyNeedsModifier() {
        XCTAssertEqual(combo(kVK_ANSI_K, 0).validationProblem(systemShortcuts: []), .needsModifier)
        XCTAssertEqual(combo(kVK_Space, 0).validationProblem(systemShortcuts: []), .needsModifier)
        XCTAssertEqual(combo(kVK_ANSI_K, UInt32(alphaLock)).validationProblem(systemShortcuts: []), .needsModifier,
                       "caps lock is not a modifier")
    }

    func testShiftOnlyIsRejected() {
        XCTAssertEqual(combo(kVK_ANSI_K, shift).validationProblem(systemShortcuts: []), .shiftOnly)
    }

    func testFunctionKeysNeedNoModifier() {
        XCTAssertNil(combo(kVK_F5, 0).validationProblem(systemShortcuts: []))
        XCTAssertNil(combo(kVK_F13, shift).validationProblem(systemShortcuts: []))
        XCTAssertNil(combo(kVK_F20, 0).validationProblem(systemShortcuts: []))
    }

    func testReservedChords() {
        let reserved = [
            combo(kVK_ANSI_Q, command), combo(kVK_ANSI_W, command), combo(kVK_ANSI_H, command),
            combo(kVK_ANSI_M, command), combo(kVK_Tab, command), combo(kVK_ANSI_Grave, command),
            combo(kVK_Escape, command | option),
        ]
        for chord in reserved {
            XCTAssertEqual(chord.validationProblem(systemShortcuts: []), .reserved(chord.displayString))
        }
        XCTAssertEqual(HotKeyProblem.reserved("⌘Q").errorDescription, "⌘Q is reserved by macOS.")
        XCTAssertNil(combo(kVK_ANSI_Q, command | option).validationProblem(systemShortcuts: []),
                     "only the exact reserved chord is rejected")
    }

    /// Every chord of the notch's key table (SPEC-v2 §4.4) plus the Shelf's ⌘A ⌘C ⌥⌘R.
    func testEveryOttoChordConflicts() {
        let commandShift = command | shift
        let optionCommand = option | command
        let chords: [(String, HotKeyCombo)] = [
            ("⌘N", combo(kVK_ANSI_N, command)), ("⌘Y", combo(kVK_ANSI_Y, command)),
            ("⌘D", combo(kVK_ANSI_D, command)), ("⌘P", combo(kVK_ANSI_P, command)),
            ("⌘R", combo(kVK_ANSI_R, command)), ("⌘1", combo(kVK_ANSI_1, command)),
            ("⌘2", combo(kVK_ANSI_2, command)), ("⌘3", combo(kVK_ANSI_3, command)),
            ("⌘/", combo(kVK_ANSI_Slash, command)), ("⌘⇧/", combo(kVK_ANSI_Slash, commandShift)),
            ("⌘.", combo(kVK_ANSI_Period, command)), ("⌘⇧.", combo(kVK_ANSI_Period, commandShift)),
            ("⌘,", combo(kVK_ANSI_Comma, command)),
            ("⌘F", combo(kVK_ANSI_F, command)), ("⌘Z", combo(kVK_ANSI_Z, command)),
            ("⌘V", combo(kVK_ANSI_V, command)), ("⌘A", combo(kVK_ANSI_A, command)),
            ("⌘C", combo(kVK_ANSI_C, command)), ("⌘⇧C", combo(kVK_ANSI_C, commandShift)),
            ("⌘⇧↑", combo(kVK_UpArrow, commandShift)), ("⌘⇧↓", combo(kVK_DownArrow, commandShift)),
            ("⌘↩", combo(kVK_Return, command)), ("⌘⌅", combo(kVK_ANSI_KeypadEnter, command)),
            ("⌥⌘↩", combo(kVK_Return, optionCommand)), ("⌥⌘⌅", combo(kVK_ANSI_KeypadEnter, optionCommand)),
            ("⌘⌫", combo(kVK_Delete, command)),
            ("⌥⌘P", combo(kVK_ANSI_P, optionCommand)), ("⌥⌘]", combo(kVK_ANSI_RightBracket, optionCommand)),
            ("⌥⌘[", combo(kVK_ANSI_LeftBracket, optionCommand)), ("⌥⌘J", combo(kVK_ANSI_J, optionCommand)),
            ("⌥⌘U", combo(kVK_ANSI_U, optionCommand)), ("⌥⌘R", combo(kVK_ANSI_R, optionCommand)),
        ]
        for (label, chord) in chords {
            XCTAssertEqual(chord.validationProblem(systemShortcuts: []), .conflictsWithOtto(chord.displayString),
                           label)
        }
        // ⌘W is in the table too, but macOS reserves it first.
        XCTAssertEqual(combo(kVK_ANSI_W, command).validationProblem(systemShortcuts: []),
                       .reserved(combo(kVK_ANSI_W, command).displayString))
        // Neighbors of Otto's chords stay available.
        XCTAssertNil(combo(kVK_ANSI_N, command | control).validationProblem(systemShortcuts: []))
        XCTAssertNil(combo(kVK_ANSI_J, command).validationProblem(systemShortcuts: []))
        XCTAssertNil(combo(kVK_UpArrow, command | option).validationProblem(systemShortcuts: []))
    }

    func testConflictsWithOttoCopy() {
        XCTAssertEqual(HotKeyProblem.conflictsWithOtto("⌘N").errorDescription,
                       "⌘N is one of Otto's own shortcuts in the notch. Pick another.")
    }

    // MARK: - System shortcuts

    /// The shape `CopySymbolicHotKeys` returns: Spotlight ⌘Space, input sources ⌃Space (with the caps-lock bit set),
    /// a disabled ⌃⌥Space, an unassigned entry, and a malformed one.
    private var symbolicHotKeysFixture: [[String: Any]] {
        [
            ["kHISymbolicHotKeyCode": NSNumber(value: kVK_Space), "kHISymbolicHotKeyModifiers": NSNumber(value: cmdKey),
             "kHISymbolicHotKeyEnabled": true],
            ["kHISymbolicHotKeyCode": NSNumber(value: kVK_Space),
             "kHISymbolicHotKeyModifiers": NSNumber(value: controlKey | alphaLock), "kHISymbolicHotKeyEnabled": true],
            ["kHISymbolicHotKeyCode": NSNumber(value: kVK_Space),
             "kHISymbolicHotKeyModifiers": NSNumber(value: controlKey | optionKey), "kHISymbolicHotKeyEnabled": false],
            ["kHISymbolicHotKeyCode": NSNumber(value: 0xFFFF), "kHISymbolicHotKeyModifiers": NSNumber(value: cmdKey),
             "kHISymbolicHotKeyEnabled": true],
            ["kHISymbolicHotKeyCode": "not a number", "kHISymbolicHotKeyEnabled": true],
        ]
    }

    func testParseKeepsEnabledAssignedEntriesWithMaskedModifiers() {
        XCTAssertEqual(SystemShortcuts.parse(symbolicHotKeysFixture), [
            SystemShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: command),
            SystemShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: control),
        ])
        XCTAssertEqual(SystemShortcuts.parse([]), [])
    }

    func testSymbolicHotKeyConflictIsRejected() {
        let system = SystemShortcuts.parse(symbolicHotKeysFixture)
        XCTAssertEqual(combo(kVK_Space, command).validationProblem(systemShortcuts: system), .system)
        XCTAssertEqual(combo(kVK_Space, control).validationProblem(systemShortcuts: system), .system)
        XCTAssertNil(combo(kVK_Space, control | option).validationProblem(systemShortcuts: system),
                     "a disabled system shortcut is free")
        XCTAssertNil(HotKeyCombo.optionSpace.validationProblem(systemShortcuts: system))
    }

    func testEveryProblemHasCopy() {
        let problems: [HotKeyProblem] = [.needsModifier, .shiftOnly, .reserved("⌘Q"), .system, .inUse("⌃⌥K"),
                                         .failed(-9868), .conflictsWithOtto("⌘N")]
        for problem in problems {
            XCTAssertFalse(problem.errorDescription?.isEmpty ?? true, "\(problem)")
        }
        XCTAssertEqual(HotKeyProblem.inUse("⌃⌥K").errorDescription, "Another app is already using ⌃⌥K.")
        XCTAssertEqual(HotKeyProblem.failed(-9868).errorDescription, "Couldn't register this shortcut (error -9868).")
    }

    // MARK: - Helpers

    private func keyEvent(_ type: NSEvent.EventType, keyCode: Int, flags: NSEvent.ModifierFlags,
                          characters: String) -> NSEvent? {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: UInt16(keyCode))
    }
}
