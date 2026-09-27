//
//  StatusItemController.swift
//  Otto
//
//  Menu bar icon with quick actions. Visibility follows `settings.showMenuBarIcon`.
//

import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let viewModel: NotchViewModel
    private let settings: AppSettings
    private let menu = NSMenu()
    private let openItem = NSMenuItem()
    private var statusItem: NSStatusItem?
    private var visibilityObservation: ObservationLoop<Bool>?

    init(viewModel: NotchViewModel, settings: AppSettings) {
        self.viewModel = viewModel
        self.settings = settings
        super.init()
        buildMenu()
        setVisible(settings.showMenuBarIcon)
        visibilityObservation = ObservationLoop(read: { settings.showMenuBarIcon }) { [weak self] visible in
            self?.setVisible(visible)
        }
    }

    // MARK: - Status item

    private func setVisible(_ visible: Bool) {
        if visible {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "com.jalenedusei.otto.status-item"
            if let button = item.button {
                button.image = Self.makeTemplateImage()
                button.imagePosition = .imageOnly
                button.toolTip = "Otto"
                button.setAccessibilityLabel("Otto")
            }
            item.menu = menu
            statusItem = item
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        openItem.title = "Open Otto"
        openItem.action = #selector(openOtto(_:))
        openItem.target = self
        menu.addItem(openItem)

        let newChatItem = NSMenuItem(title: "New Chat", action: #selector(newChat(_:)), keyEquivalent: "")
        newChatItem.target = self
        menu.addItem(newChatItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Otto", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)

        updateOpenItemShortcut()
    }

    /// Shows ⌥Space next to "Open Otto" only while the global shortcut is enabled. The Carbon hot key
    /// swallows the keystroke system-wide, so this key equivalent is informational and never double-fires.
    private func updateOpenItemShortcut() {
        if settings.hotKeyEnabled {
            openItem.keyEquivalent = " "
            openItem.keyEquivalentModifierMask = .option
        } else {
            openItem.keyEquivalent = ""
            openItem.keyEquivalentModifierMask = []
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateOpenItemShortcut()
    }

    @objc private func openOtto(_ sender: Any?) {
        viewModel.open(reason: .click, focus: true)
    }

    @objc private func newChat(_ sender: Any?) {
        viewModel.newChat()
        viewModel.open(reason: .click, focus: true)
    }

    @objc private func openSettings(_ sender: Any?) {
        viewModel.openSettings()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    // MARK: - Icon

    /// 18×14 pt template glyph: the top of a display with the notch and Otto's orb beneath it.
    static func makeTemplateImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { _ in
            NSColor.black.set()

            let screen = NSBezierPath(roundedRect: NSRect(x: 1.25, y: 1.25, width: 15.5, height: 11.5), xRadius: 2.75, yRadius: 2.75)
            screen.lineWidth = 1.3
            screen.stroke()

            // Notch hanging from the top edge, rounded only at the bottom.
            let minX: CGFloat = 5.75, maxX: CGFloat = 12.25, top: CGFloat = 12.75, bottom: CGFloat = 8.75, radius: CGFloat = 1.6
            let notch = NSBezierPath()
            notch.move(to: NSPoint(x: minX, y: top))
            notch.line(to: NSPoint(x: minX, y: bottom + radius))
            notch.appendArc(withCenter: NSPoint(x: minX + radius, y: bottom + radius), radius: radius, startAngle: 180, endAngle: 270)
            notch.line(to: NSPoint(x: maxX - radius, y: bottom))
            notch.appendArc(withCenter: NSPoint(x: maxX - radius, y: bottom + radius), radius: radius, startAngle: 270, endAngle: 360)
            notch.line(to: NSPoint(x: maxX, y: top))
            notch.close()
            notch.fill()

            NSBezierPath(ovalIn: NSRect(x: 7.6, y: 3.9, width: 2.8, height: 2.8)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Otto"
        return image
    }
}
