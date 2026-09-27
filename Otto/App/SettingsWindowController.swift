//
//  SettingsWindowController.swift
//  Otto
//
//  Hosts SettingsView in a regular titled window, created once and reused.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private static let contentSize = NSSize(width: 480, height: 560)

    private let settings: AppSettings
    private var window: NSWindow?

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = self.window ?? makeWindow()
        if !window.isVisible {
            window.center()
        }
        // Otto is an accessory app: activate it so the window comes forward and takes keyboard focus.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Activation is cooperative since macOS 14 and can be declined; still put the window on top.
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Otto Settings"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.tabbingMode = .disallowed
        window.delegate = self

        let hostingView = NSHostingView(rootView: SettingsView(settings: settings))
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: Self.contentSize)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.setContentSize(Self.contentSize)

        self.window = window
        return window
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Drop focus from the (now windowless) accessory app so the user's previous app becomes
        // active again, unless another Otto window still needs it.
        let otherVisibleWindows = NSApp.windows.filter { candidate in
            candidate !== window && candidate.isVisible && !(candidate is NotchPanel) && candidate.canBecomeMain
        }
        if otherVisibleWindows.isEmpty {
            NSApp.deactivate()
        }
    }
}
