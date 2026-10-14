//
//  main.swift
//  Otto
//
//  Plain AppKit entry point. Otto is an accessory app (LSUIElement): no Dock icon, no app menu bar.
//

import AppKit

#if DEBUG && OTTO_SETAPP
// The offline Setapp AI adapter check (Otto/Debug/SetappAICheck.swift) runs before NSApplication does, so the
// Setapp Framework never starts and nothing appears on screen.
if let directory = SetappAICheck.directory(in: CommandLine.arguments) {
    SetappAICheck.runAndExit(reportingTo: directory)
}
#endif

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
