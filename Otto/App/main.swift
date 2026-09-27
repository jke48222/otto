//
//  main.swift
//  Otto
//
//  Plain AppKit entry point. Otto is an accessory app (LSUIElement): no Dock icon, no app menu bar.
//

import AppKit

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    // NSApplication.delegate is weak; keep the delegate alive for the lifetime of the run loop.
    withExtendedLifetime(delegate) {
        application.run()
    }
}
