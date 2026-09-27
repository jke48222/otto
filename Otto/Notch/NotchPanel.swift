//
//  NotchPanel.swift
//  Otto
//
//  Borderless, non-activating panel that floats above the menu bar. It can become key (so the
//  composer receives typing) without activating Otto, which leaves the user's app frontmost. It also
//  answers the Quick Look panel's search for a controller, so Shelf previews open above the notch.
//

import AppKit
import QuickLookUI

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

    /// The Shelf's preview controller (`vm.shelf.quickLook`), set by the window controller. While the
    /// notch panel is key, the Quick Look panel finds it through this responder.
    weak var quickLookController: ShelfQuickLookController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit pushes windows out from under the menu bar; the notch panel must stay flush with the
    /// top edge of the screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // MARK: - Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        quickLookController != nil
    }

    /// The controller becomes the preview's data source and delegate and lifts it to
    /// `auxiliaryWindowLevel`, one above the notch.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard let panel else { return }
        quickLookController?.beginControl(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard let panel else { return }
        quickLookController?.endControl(panel)
    }
}
