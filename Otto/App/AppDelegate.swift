//
//  AppDelegate.swift
//  Otto
//
//  Builds the object graph (settings → chat session → notch view model → windows, status item,
//  hot key) and owns it for the lifetime of the app.
//

import AppKit
import Observation
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let onboardingDefaultsKey = "otto.didShowOnboarding"
    private static let hotKeyInUseMessage = "⌥Space is already used by another app. Quit or change the shortcut in that app, then turn Otto's shortcut off and on again."
    private static let hotKeyFailedMessage = "Couldn't register the ⌥Space shortcut."
    private let logger = Logger(subsystem: "com.jalenedusei.otto", category: "App")

    private var settings: AppSettings?
    private var chat: ChatSession?
    private var viewModel: NotchViewModel?
    private var notchWindowController: NotchWindowController?
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var hotKeyManager: HotKeyManager?
    private var hotKeyObservation: ObservationLoop<Bool>?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        if LaunchOptions.isRunningTests { return }

        #if DEBUG || OTTO_TOOLS
        // Developer tooling (Otto/Debug): not compiled into shipping Release builds.
        if let directory = LaunchOptions.snapshotDirectory {
            renderSnapshots(to: directory)
            return
        }

        if let directory = LaunchOptions.promoStillsDirectory {
            PromoStage.renderStills(to: directory)
            return
        }

        if let directory = LaunchOptions.promoDirectory {
            PromoStage.perform(scene: LaunchOptions.promoScene, handshakeDirectory: directory)
            return
        }

        if let directory = LaunchOptions.selfTestDirectory {
            installMainMenu()
            SelfTest.start(reportingTo: directory)
            return
        }
        #endif

        installMainMenu()
        startApp()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Launching Otto again (Finder, Spotlight, `open`) while it runs opens the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        viewModel?.open(reason: .programmatic, focus: true)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyObservation?.cancel()
        hotKeyManager?.unregister()
        chat?.cancel()
    }

    // MARK: - Startup

    private func startApp() {
        let settings = AppSettings.shared
        let chat = ChatSession(settings: settings, makeClient: {
            if LaunchOptions.demo { return MockLLMClient() }
            guard let apiKey = settings.resolvedAPIKey else { throw LLMError.missingAPIKey }
            return AnthropicClient(apiKey: apiKey)
        })
        let viewModel = NotchViewModel(settings: settings, chat: chat)
        let settingsWindowController = SettingsWindowController(settings: settings)
        let notchWindowController = NotchWindowController(viewModel: viewModel, settings: settings)

        // The window controller wires the presentation/key/capture hooks; Settings lives here.
        viewModel.onOpenSettings = { [weak settingsWindowController] in
            settingsWindowController?.show()
        }

        self.settings = settings
        self.chat = chat
        self.viewModel = viewModel
        self.settingsWindowController = settingsWindowController
        self.notchWindowController = notchWindowController

        notchWindowController.showWindow()
        statusItemController = StatusItemController(viewModel: viewModel, settings: settings)
        configureHotKey(settings: settings)

        if LaunchOptions.startOpen {
            Task { @MainActor [weak viewModel] in
                // Let the panel finish its first layout pass so the open animation starts from the notch.
                try? await Task.sleep(for: .milliseconds(350))
                viewModel?.open(reason: .programmatic, focus: true)
            }
        }

        showOnboardingIfNeeded(settings: settings)
        logger.info("Otto started (demo: \(LaunchOptions.demo, privacy: .public))")
    }

    private func configureHotKey(settings: AppSettings) {
        let manager = HotKeyManager { [weak self] in
            self?.handleHotKey()
        }
        hotKeyManager = manager
        applyHotKeyRegistration(enabled: settings.hotKeyEnabled)
        hotKeyObservation = ObservationLoop(read: { settings.hotKeyEnabled }) { [weak self] enabled in
            self?.applyHotKeyRegistration(enabled: enabled)
        }
    }

    private func applyHotKeyRegistration(enabled: Bool) {
        guard let hotKeyManager else { return }
        if enabled {
            guard hotKeyManager.register() else {
                // Exclusive registration makes conflicts with other exclusive owners detectable
                // (see HotKeyManager.register()).
                settings?.lastSettingsError = hotKeyManager.lastRegistrationError == .alreadyInUse
                    ? Self.hotKeyInUseMessage
                    : Self.hotKeyFailedMessage
                return
            }
        } else {
            hotKeyManager.unregister()
        }
        // Clear a stale registration error once the shortcut works (or is no longer wanted).
        if let error = settings?.lastSettingsError, error == Self.hotKeyInUseMessage || error == Self.hotKeyFailedMessage {
            settings?.lastSettingsError = nil
        }
    }

    /// ⌥Space: open the notch with keyboard focus; if it is already open and focused, close it.
    /// An open-but-unfocused notch (e.g. opened by hover) takes focus instead of closing.
    private func handleHotKey() {
        guard let viewModel else { return }
        if viewModel.isOpen && viewModel.isEngaged {
            viewModel.close()
        } else {
            viewModel.open(reason: .hotkey, focus: true)
        }
    }

    private func showOnboardingIfNeeded(settings: AppSettings) {
        guard !LaunchOptions.demo, !settings.hasAPIKey else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.onboardingDefaultsKey) else { return }
        defaults.set(true, forKey: Self.onboardingDefaultsKey)
        settingsWindowController?.show()
    }

    // MARK: - Snapshots

    #if DEBUG || OTTO_TOOLS
    private func renderSnapshots(to directory: URL) {
        logger.info("Rendering snapshots to \(directory.path, privacy: .public)")
        // Watchdog on a background queue: if rendering wedges the main thread, still exit non-zero.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 180) {
            FileHandle.standardError.write(Data("Snapshot rendering timed out.\n".utf8))
            exit(1)
        }
        Task { @MainActor in
            await SnapshotRenderer.renderAll(to: directory)
            exit(0)
        }
    }
    #endif

    // MARK: - Main menu

    /// Accessory apps show no menu bar, but key equivalents are still routed through the main menu.
    /// Without an Edit menu, ⌘C / ⌘V / ⌘A / ⌘Z would not work in the composer or in Settings.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: "Otto")
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Otto", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        mainMenu.addItem(submenuItem(appMenu))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        let pastePlain = NSMenuItem(title: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        editMenu.addItem(pastePlain)
        editMenu.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        mainMenu.addItem(submenuItem(editMenu))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        mainMenu.addItem(submenuItem(windowMenu))

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        if let viewModel {
            viewModel.openSettings()
        } else {
            settingsWindowController?.show()
        }
    }
}
