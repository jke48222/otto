//
//  SettingsWindowController.swift
//  Otto
//
//  Owns the Settings panel: one tab per SettingsTab in a toolbar-style NSTabViewController, created once and
//  reused. Showing it never activates Otto (no Space switch), puts it on the screen under the pointer and
//  scrolls to a requested section. Every control that opens another app's window goes through
//  openExternal, which drops the panel to the normal level until it is key again.
//

import AppKit
import SwiftUI
import os

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let contentWidth: CGFloat = 560
    /// Panes are sized per tab inside this range; longer content scrolls.
    static let heightRange: ClosedRange<CGFloat> = 420...720
    static let lastTabKey = "otto.settings.lastTab"

    let services: SettingsServices
    /// The selected tab and the section a deep link asked for; the panes read it from the environment.
    let navigation: SettingsNavigation

    /// Where `otto.settings.lastTab` is kept. Tests point it at a throwaway suite before the first `show`.
    var preferences: UserDefaults = .standard
    /// Opens a URL in another app (a file URL is revealed in Finder). Tests replace it.
    var externalOpener: @MainActor (URL) -> Void = SettingsExternalOpener.workspace.open

    private let settings: AppSettings
    private(set) var panel: SettingsPanel?
    private var tabController: TabController?

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Settings")

    init(settings: AppSettings, services: SettingsServices) {
        self.settings = settings
        self.services = services
        self.navigation = SettingsNavigation()
        super.init()
    }

    /// Inert services: the Settings window of a graph that has no live subsystems yet.
    convenience init(settings: AppSettings) {
        self.init(settings: settings, services: .inert(settings: settings))
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// The tab showing now.
    var selectedTab: SettingsTab { navigation.tab }

    /// Selects `tab` (else the anchor's tab, else the last tab used), brings the panel to the current Space on
    /// the screen under the pointer, makes it key without activating Otto, and asks the pane to scroll to `anchor`.
    func show(tab: SettingsTab? = nil, anchor: SettingsAnchor? = nil) {
        let panel = self.panel ?? makePanel()
        select(tab ?? anchor?.tab ?? storedLastTab())

        // Left open on another Space: take it out first, so ordering it in moves it here (.moveToActiveSpace)
        // instead of the window server switching to that Space.
        if panel.isVisible && !panel.isOnActiveSpace {
            panel.orderOut(nil)
        }
        if !panel.isVisible, let screen = Self.screenUnderPointer() ?? NSScreen.main {
            panel.setFrameOrigin(Self.origin(for: panel.frame.size, on: screen.visibleFrame))
        }
        // Non-activating key: the user's app stays active and typing goes to Settings.
        panel.makeKeyAndOrderFront(nil)

        if let anchor {
            navigation.request(anchor)
        }
    }

    /// The one way Settings opens another app's window (System Settings, Finder, the browser). The panel floats,
    /// so it drops to the normal level first and floats again once it is key.
    func openExternal(_ url: URL) {
        panel?.isFloatingPanel = false
        Self.logger.info("Opening \(url.isFileURL ? "a folder" : url.scheme ?? "a link", privacy: .public) from Settings")
        externalOpener(url)
    }

    // MARK: - Panel

    private func makePanel() -> SettingsPanel {
        let initialTab = storedLastTab()
        let panel = SettingsPanel(contentSize: NSSize(width: Self.contentWidth, height: Self.height(for: initialTab)))
        panel.delegate = self

        let tabController = TabController()
        tabController.tabStyle = .toolbar
        tabController.transitionOptions = [.crossfade, .allowUserInteraction]
        let opener = SettingsExternalOpener { [weak self] url in self?.openExternal(url) }
        for tab in SettingsTab.allCases {
            let root = SettingsView(settings: settings, tab: tab, services: services)
                .environment(navigation)
                .environment(\.settingsOpenExternal, opener)
                .frame(width: Self.contentWidth, height: Self.height(for: tab))
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = .preferredContentSize
            hosting.title = tab.title
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabController.addTabViewItem(item)
        }
        tabController.onSelect = { [weak self] index in self?.tabDidChange(to: index) }

        panel.contentViewController = tabController
        panel.setContentSize(NSSize(width: Self.contentWidth, height: Self.height(for: initialTab)))

        self.panel = panel
        self.tabController = tabController
        select(initialTab)
        return panel
    }

    private func select(_ tab: SettingsTab) {
        guard let tabController, let index = SettingsTab.allCases.firstIndex(of: tab) else { return }
        if tabController.selectedTabViewItemIndex != index {
            tabController.selectedTabViewItemIndex = index
        }
        // Selecting the tab that is already selected calls no delegate; keep the state in step anyway.
        tabDidChange(to: index)
    }

    private func tabDidChange(to index: Int) {
        guard SettingsTab.allCases.indices.contains(index) else { return }
        let tab = SettingsTab.allCases[index]
        if navigation.tab != tab { navigation.tab = tab }
        preferences.set(tab.rawValue, forKey: Self.lastTabKey)
        guard let panel else { return }
        panel.title = tab.title
        resize(panel, toContentHeight: Self.height(for: tab))
    }

    /// Keeps the title bar where it is and grows or shrinks the panel downwards.
    private func resize(_ panel: NSPanel, toContentHeight height: CGFloat) {
        let current = panel.frame
        let content = panel.contentRect(forFrameRect: current)
        let target = panel.frameRect(forContentRect: NSRect(x: content.minX, y: content.minY,
                                                            width: Self.contentWidth, height: height))
        guard abs(target.height - current.height) > 0.5 || abs(target.width - current.width) > 0.5 else { return }
        let frame = NSRect(x: current.minX, y: current.maxY - target.height, width: target.width, height: target.height)
        panel.setFrame(frame, display: true, animate: panel.isVisible)
    }

    private func storedLastTab() -> SettingsTab {
        preferences.string(forKey: Self.lastTabKey).flatMap(SettingsTab.init(rawValue:)) ?? .general
    }

    /// Content height of each tab, inside `heightRange`.
    static func height(for tab: SettingsTab) -> CGFloat {
        let height: CGFloat
        switch tab {
        case .general: height = 480
        case .notch: height = 660
        case .models: height = 720
        case .context: height = 700
        case .actions: height = 720
        case .voice: height = 680
        case .privacy: height = 700
        }
        return min(max(height, heightRange.lowerBound), heightRange.upperBound)
    }

    /// Centered on the visible frame, slightly above the middle, and never off it.
    static func origin(for size: NSSize, on visibleFrame: NSRect) -> NSPoint {
        var x = visibleFrame.midX - size.width / 2
        var y = visibleFrame.midY - size.height / 2 + visibleFrame.height * 0.06
        x = min(max(x, visibleFrame.minX), max(visibleFrame.maxX - size.width, visibleFrame.minX))
        y = min(max(y, visibleFrame.minY), max(visibleFrame.maxY - size.height, visibleFrame.minY))
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    private static func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        // Back from System Settings, Finder or the browser: float again, and re-read the permission rows
        // (the user may have just flipped a switch).
        panel?.isFloatingPanel = true
        let permissions = services.permissions
        Task { await permissions.refreshAll() }
    }

    func windowWillClose(_ notification: Notification) {
        settings.shortcuts.isRecording = false
        // A non-activating panel hands key back to the active app by itself. Otto is only active here when
        // something else (a file picker) activated it; then give focus back unless another Otto window needs it.
        guard NSApp.isActive else { return }
        let otherVisibleWindows = NSApp.windows.filter { candidate in
            candidate !== panel && candidate.isVisible && !(candidate is NotchPanel) && candidate.canBecomeMain
        }
        if otherVisibleWindows.isEmpty {
            NSApp.deactivate()
        }
    }

    // MARK: - Tabs

    /// Reports every selection change, from the toolbar or from code.
    private final class TabController: NSTabViewController {
        var onSelect: ((Int) -> Void)?

        override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
            super.tabView(tabView, didSelect: tabViewItem)
            guard let tabViewItem else { return }
            onSelect?(tabView.indexOfTabViewItem(tabViewItem))
        }
    }
}
