//
//  AppDelegate.swift
//  Otto
//
//  The app's entry point. Picks the launch mode (tests, snapshots, promo, self-test or the app), makes sure
//  only one Otto owns the global shortcut and the data folder, then builds the object graph with
//  `AppComposition.live()` and owns it for the lifetime of the app.
//

import AppKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let onboardingDefaultsKey = "otto.didShowOnboarding"
    /// SPEC-v2 §3.5: the launch guard looks for other processes with Otto's bundle identifier.
    private static let fallbackBundleIdentifier = "com.jalenedusei.otto"
    /// How long a second Otto waits for the first one to quit (a relaunch after "Quit & Reopen").
    private static let launchGuardTimeout: Duration = .seconds(3)
    private static let launchGuardPollInterval: Duration = .milliseconds(100)
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "App")

    /// The live object graph; nil until the launch guard has finished (and in every non-app mode).
    private var composition: AppComposition?

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

    /// Launching Otto again (Finder, Spotlight, `open`, a second copy's launch guard) while it runs opens the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        composition?.viewModel.open(reason: .programmatic, focus: true)
        return false
    }

    /// Stops listening and speaking, cancels the reply, flushes History, the Shelf and the usage ledger, stops the
    /// monitors and unregisters the global shortcut.
    func applicationWillTerminate(_ notification: Notification) {
        composition?.terminate()
    }

    // MARK: - Startup

    /// Live and `--demo` only. Nothing registers the global shortcut or opens a store until the launch guard is done.
    private func startApp() {
        Task { @MainActor [weak self] in
            let other = await Self.waitForOtherInstanceToQuit()
            guard let self else { return }
            guard let other else {
                self.compose(registeringHotKey: true)
                return
            }
            if LaunchOptions.demo {
                // The demo keeps its own stores; only the global shortcut belongs to the other Otto.
                Self.logger.notice("Another Otto is running; the demo starts without the global shortcut")
                self.compose(registeringHotKey: false)
            } else {
                Self.handOff(to: other)
            }
        }
    }

    private func compose(registeringHotKey: Bool) {
        let composition = AppComposition.live()
        self.composition = composition
        composition.start(registeringHotKey: registeringHotKey)

        if LaunchOptions.startOpen {
            let viewModel = composition.viewModel
            Task { @MainActor [weak viewModel] in
                // Let the panel finish its first layout pass so the open animation starts from the notch.
                try? await Task.sleep(for: .milliseconds(350))
                viewModel?.open(reason: .programmatic, focus: true)
            }
        }

        showOnboardingIfNeeded(composition)
    }

    /// Another Otto kept running past the guard: it opens its notch (a reopen, without activating it) and this copy
    /// quits, so exactly one Otto owns the shortcut and the data folder.
    private static func handOff(to other: NSRunningApplication) {
        logger.notice("Another Otto is running (pid \(other.processIdentifier, privacy: .public)); handing over to it")
        guard let bundleURL = other.bundleURL else {
            NSApp.terminate(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                if let message {
                    logger.error("Couldn't reopen the running Otto: \(message, privacy: .public)")
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// Polls every 100 ms for up to 3 s while another process with Otto's bundle identifier runs. Returns it when it
    /// is still running at the end, nil as soon as there is none.
    private static func waitForOtherInstanceToQuit() async -> NSRunningApplication? {
        let clock = ContinuousClock()
        let deadline = clock.now + launchGuardTimeout
        while let other = otherInstance() {
            guard clock.now < deadline else { return other }
            try? await Task.sleep(for: launchGuardPollInterval)
        }
        return nil
    }

    private static func otherInstance() -> NSRunningApplication? {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? fallbackBundleIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != ownPID && !$0.isTerminated }
    }

    /// First launch without an API key: Settings opens on Models, where the key goes.
    private func showOnboardingIfNeeded(_ composition: AppComposition) {
        guard !LaunchOptions.demo, !composition.settings.hasAPIKey else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.onboardingDefaultsKey) else { return }
        defaults.set(true, forKey: Self.onboardingDefaultsKey)
        composition.settingsWindowController.show(tab: .models)
    }

    // MARK: - Snapshots

    #if DEBUG || OTTO_TOOLS
    private func renderSnapshots(to directory: URL) {
        Self.logger.info("Rendering snapshots to \(directory.path, privacy: .public)")
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

    /// ⌘, while Settings or another Otto window is key (the notch maps its own ⌘,). Nothing to open before the graph
    /// exists.
    @objc private func openSettingsFromMenu(_ sender: Any?) {
        composition?.viewModel.openSettings()
    }
}
