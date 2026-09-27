//
//  ShelfQuickLook.swift
//  Otto
//
//  Quick Look for Shelf items. The notch panel is the responder that takes control of the shared
//  preview panel (`NotchPanel.quickLookController`); this controller is its data source and delegate,
//  lifts the preview above the notch, and reports when the preview opens and closes so the notch
//  stays open under it.
//

import AppKit
import Foundation
import os
import QuickLookUI

@MainActor final class ShelfQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// The URLs being previewed, in shelf order.
    private(set) var urls: [URL] = []
    /// True from `show(urls:)` until the preview panel closes (by Otto, Space, Esc or its close button).
    private(set) var isShowing = false
    /// Called whenever `isShowing` changes.
    var onVisibilityChange: ((Bool) -> Void)?

    /// Where the preview panel sits: one level above the notch panel, so the open notch never covers it.
    static let panelLevel = NotchPanel.auxiliaryWindowLevel

    /// Seams for tests: the shared panel's presence, visibility and ordering (the real panel needs a window
    /// server and a responder that accepts control).
    var panelProvider: () -> QLPreviewPanel? = {
        QLPreviewPanel.shared()
    }
    var panelExists: () -> Bool = {
        QLPreviewPanel.sharedPreviewPanelExists()
    }

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Shelf")

    /// Opens (or refreshes) the preview for `urls`. Does nothing for an empty list.
    func show(urls: [URL]) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        setShowing(true)
        guard let panel = panelProvider() else { return }
        if panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = 0
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        Self.logger.info("Quick Look opened for \(urls.count, privacy: .public) shelf items")
    }

    /// Orders the preview out (the notch closed, or Space pressed again).
    func hide() {
        if panelExists(), let panel = panelProvider(), panel.isVisible {
            panel.orderOut(nil)
        }
        urls = []
        setShowing(false)
    }

    func toggle(urls: [URL]) {
        if isShowing {
            hide()
        } else {
            show(urls: urls)
        }
    }

    /// `NotchPanel.beginPreviewPanelControl(_:)` calls this: become the panel's data source and delegate and
    /// lift it above the notch.
    func beginControl(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.level = Self.panelLevel
    }

    /// `NotchPanel.endPreviewPanelControl(_:)` calls this: the preview panel closed.
    func endControl(_ panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
        urls = []
        setShowing(false)
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            guard urls.indices.contains(index) else { return nil }
            return urls[index] as NSURL
        }
    }

    // MARK: - QLPreviewPanelDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            urls = []
            setShowing(false)
        }
    }

    // MARK: - Private

    private func setShowing(_ showing: Bool) {
        guard isShowing != showing else { return }
        isShowing = showing
        onVisibilityChange?(showing)
    }
}
