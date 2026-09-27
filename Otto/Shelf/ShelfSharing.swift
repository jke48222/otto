//
//  ShelfSharing.swift
//  Otto
//
//  Share… for Shelf items: the system share picker (AirDrop, Mail, Messages, Notes…) anchored on the
//  Share button or the tile that was right-clicked. Choosing a service activates Otto so the service's
//  window comes forward, and the notch stays open until the service finishes or fails; then the app the
//  user was in gets focus back.
//

import AppKit
import Foundation
import os
import SwiftUI

@MainActor final class ShelfSharingController: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    /// True from `show` until the picker is dismissed without a choice, or the chosen service finishes or fails.
    private(set) var isSharing = false
    /// Called whenever `isSharing` changes.
    var onSharingChange: ((Bool) -> Void)?
    /// A user-facing message when a service fails ("Couldn't share: …"). Cancelling is not an error.
    var onError: ((String) -> Void)?

    /// Seams for tests: activating Otto (so the chosen service's window comes forward) and giving focus back
    /// to the app that was frontmost before.
    var activateOtto: () -> NSRunningApplication? = {
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        return previous
    }
    var reactivate: (NSRunningApplication) -> Void = { app in
        if NSApp.isActive, !app.isTerminated {
            app.activate(options: [])
        }
    }

    /// The window the service's sheet attaches to (the anchor's window, which is the notch panel).
    private weak var sourceWindow: NSWindow?
    private var picker: NSSharingServicePicker?
    private var appToReactivate: NSRunningApplication?

    nonisolated private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Shelf")

    /// Shows the share picker for `urls` next to `rect` in `view`. Does nothing for an empty list.
    func show(urls: [URL], relativeTo rect: NSRect, of view: NSView) {
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls.map { $0 as NSURL })
        picker.delegate = self
        self.picker = picker
        sourceWindow = view.window
        setSharing(true)
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        Self.logger.info("Share picker shown for \(urls.count, privacy: .public) shelf items")
    }

    // MARK: - NSSharingServicePickerDelegate (AppKit calls these on the main thread)

    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        delegateFor sharingService: NSSharingService
    ) -> NSSharingServiceDelegate? {
        self
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        let chose = service != nil
        MainActor.assumeIsolated { didChoose(anyService: chose) }
    }

    // MARK: - NSSharingServiceDelegate

    nonisolated func sharingService(
        _ sharingService: NSSharingService,
        sourceWindowForShareItems items: [Any],
        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>
    ) -> NSWindow? {
        MainActor.assumeIsolated { sourceWindow }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let count = items.count
        MainActor.assumeIsolated { didShare(count: count) }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let nsError = error as NSError
        let cancelled = nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
        let description = error.localizedDescription
        MainActor.assumeIsolated { didFail(cancelled: cancelled, description: description) }
    }

    // MARK: - Delegate outcomes

    /// The picker closed: with a service chosen, Otto activates so its window comes forward and sharing
    /// continues until the service reports back; without one, sharing is over.
    func didChoose(anyService: Bool) {
        picker = nil
        guard anyService else {
            finish()
            return
        }
        if !NSApp.isActive, appToReactivate == nil {
            appToReactivate = activateOtto()
        }
    }

    func didShare(count: Int) {
        Self.logger.info("Shared \(count, privacy: .public) shelf items")
        finish()
    }

    func didFail(cancelled: Bool, description: String) {
        if !cancelled {
            Self.logger.error("Sharing failed: \(description, privacy: .public)")
            onError?("Couldn't share: \(description)")
        }
        finish()
    }

    // MARK: - Private

    private func finish() {
        setSharing(false)
        if let app = appToReactivate {
            appToReactivate = nil
            reactivate(app)
        }
    }

    private func setSharing(_ sharing: Bool) {
        guard isSharing != sharing else { return }
        isSharing = sharing
        onSharingChange?(sharing)
    }
}

/// Holds the AppKit view behind a SwiftUI control (the Shelf's Share button), so the share picker can be
/// anchored on it.
@MainActor final class ShelfAnchor {
    fileprivate(set) weak var view: NSView?

    init() {}
}

/// A transparent view placed behind a SwiftUI control (`.background(ShelfAnchorView(anchor: anchor))`); it
/// records itself in `anchor` so `ShelfController.share(_:from:)` has an NSView to point at.
struct ShelfAnchorView: NSViewRepresentable {
    let anchor: ShelfAnchor

    init(anchor: ShelfAnchor) {
        self.anchor = anchor
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassiveView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    /// Never takes a click: the SwiftUI control in front of it does.
    private final class PassiveView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
