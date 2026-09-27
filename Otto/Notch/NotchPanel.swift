//
//  NotchPanel.swift
//  Otto
//
//  Borderless, non-activating panel that floats above the menu bar. It can become key (so the
//  composer receives typing) without activating Otto, which leaves the user's app frontmost.
//

import AppKit

final class NotchPanel: NSPanel {
    /// Where the notch floats: above the menu bar (and the menu bar's own windows).
    static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
    /// Windows Otto shows while the notch stays open (the file picker) go one level above it, so the
    /// open notch never covers them or takes their clicks.
    static let auxiliaryWindowLevel = NSWindow.Level(rawValue: windowLevel.rawValue + 1)

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isFloatingPanel = true
        level = Self.windowLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        canHide = false
        animationBehavior = .none
        // Clicking a control in the panel should make it key right away (typing follows clicks).
        becomesKeyOnlyIfNeeded = false
        title = "Otto"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit pushes windows out from under the menu bar; the notch panel must stay flush with the
    /// top edge of the screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
