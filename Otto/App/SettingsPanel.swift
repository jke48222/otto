//
//  SettingsPanel.swift
//  Otto
//
//  The Settings window: a floating panel that becomes key without activating Otto, so opening Settings
//  from a full-screen app or another Space never switches Spaces and the keyboard works right away.
//

import AppKit

final class SettingsPanel: NSPanel {
    init(contentSize: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: contentSize),
                   styleMask: [.titled, .closable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Otto Settings"
        // .floating level: stays reachable over full-screen apps. openExternal lowers it while another app's
        // window (System Settings, Finder, the browser) needs to be on top.
        isFloatingPanel = true
        // NSPanel defaults to hiding when its app deactivates; Otto is almost never the active app.
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        animationBehavior = .documentWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Esc closes Settings. The shortcut recorder handles Esc itself while it is recording.
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
