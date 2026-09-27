//
//  NotchWindowController.swift
//  Otto
//
//  Owns the notch panel and all pointer/keyboard plumbing around it:
//  - pointer: event monitors gather a snapshot for every mouse event and feed it to
//    `NotchPointerMachine`, which decides click-through (the panel only accepts mouse events over
//    the drawn shape or the closed notch's hot zone), hover-open (the pointer resting on the notch),
//    exit-close and drag-open; this class applies the machine's effects and runs its timers;
//  - keyboard focus: the non-activating panel takes key status without activating Otto and hands
//    focus back to the user's app when it closes.
//

import AppKit
import Carbon.HIToolbox
import os
import SwiftUI

@MainActor
final class NotchWindowController {
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "NotchWindow")

    private let viewModel: NotchViewModel
    private let settings: AppSettings
    private let panel: NotchPanel
    private let hostingView: NotchHostingView<NotchRootView>
    private var geometry: NotchGeometry
    /// Display hosting the notch; kept across reconfigurations while it is still a valid choice.
    private var displayID: CGDirectDisplayID?

    private var mouseMonitors: [Any] = []
    private var keyMonitor: Any?
    private var notificationTokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var stateObservation: ObservationLoop<ObservedState>?
    private var isInstalled = false

    private var pointerMachine = NotchPointerMachine()
    private var timerTasks: [NotchPointerMachine.Timer: Task<Void, Never>] = [:]
    /// The panel is ordered out while the user picks a screen region.
    private var isHiddenForCapture = false

    init(viewModel: NotchViewModel, settings: AppSettings) {
        self.viewModel = viewModel
        self.settings = settings

        let screen = NotchGeometry.preferredScreen(previous: nil)
        let geometry = screen.map(NotchGeometry.make(for:)) ?? Self.fallbackGeometry
        self.geometry = geometry
        displayID = screen.flatMap(NotchGeometry.displayID(of:))

        panel = NotchPanel(
            contentRect: geometry.windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        hostingView = NotchHostingView(rootView: NotchRootView(viewModel: viewModel))
        // The window has a fixed size; SwiftUI must not resize it, and the camera-housing safe area
        // must not push the shape down from the top edge.
        hostingView.sizingOptions = []
        hostingView.safeAreaRegions = []
        hostingView.frame = NSRect(origin: .zero, size: geometry.windowFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        applyGeometryToViewModel()
        wireViewModelHooks()
    }

    deinit {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        for entry in notificationTokens { entry.center.removeObserver(entry.token) }
        for task in timerTasks.values { task.cancel() }
    }

    // MARK: - Public

    func showWindow() {
        if !isInstalled {
            isInstalled = true
            installEventMonitors()
            installNotificationObservers()
            stateObservation = ObservationLoop(read: { [viewModel] in
                ObservedState(
                    presentation: viewModel.presentation,
                    shouldStayOpen: viewModel.shouldStayOpen,
                    isMenuPresented: viewModel.isMenuPresented,
                    renderedShapeSize: viewModel.renderedShapeSize
                )
            }) { [weak self] state in
                self?.observedStateDidChange(state)
            }
        }
        reposition()
        bringToFront()
    }

    /// Re-reads the notch geometry (displays attached/detached, resolution changes, lid closed…).
    func reposition() {
        guard let screen = NotchGeometry.preferredScreen(previous: displayID) else {
            Self.logger.error("No screen available to host the notch")
            return
        }
        displayID = NotchGeometry.displayID(of: screen)
        let newGeometry = NotchGeometry.make(for: screen)
        if newGeometry != geometry {
            geometry = newGeometry
            Self.logger.info("Notch geometry: \(String(describing: newGeometry.notchRect), privacy: .public) physical: \(newGeometry.hasPhysicalNotch, privacy: .public)")
        }
        applyGeometryToViewModel()
        if panel.frame != geometry.windowFrame {
            panel.setFrame(geometry.windowFrame, display: true)
        }
        refreshPointerState()
    }

    #if DEBUG || OTTO_TOOLS
    // MARK: - Self-test access

    /// The notch panel, for `SelfTest` only (it inspects key status, click-through and first responder,
    /// and captures the content view).
    var debugPanel: NSPanel { panel }
    /// The geometry the controller currently lays the notch out with, for `SelfTest` only.
    var debugGeometry: NotchGeometry { geometry }
    #endif

    // MARK: - Setup

    private static var fallbackGeometry: NotchGeometry {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NotchMetrics.virtualNotchSize
        let rect = CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
        return NotchGeometry(screenFrame: frame, hasPhysicalNotch: false, notchRect: rect)
    }

    private func applyGeometryToViewModel() {
        if viewModel.closedNotchSize != geometry.closedSize {
            viewModel.closedNotchSize = geometry.closedSize
        }
        if viewModel.hasPhysicalNotch != geometry.hasPhysicalNotch {
            viewModel.hasPhysicalNotch = geometry.hasPhysicalNotch
        }
    }

    private func wireViewModelHooks() {
        viewModel.onPresentationChange = { [weak self] presentation in
            self?.presentationDidChange(to: presentation)
        }
        viewModel.onRequestKey = { [weak self] focus in
            self?.setKeyFocus(focus)
        }
        viewModel.onBeginScreenCapture = { [weak self] in
            self?.beginScreenCapture()
        }
        viewModel.onEndScreenCapture = { [weak self] in
            self?.endScreenCapture()
        }
    }

    private func installEventMonitors() {
        let mouseMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .leftMouseUp]

        // Events delivered to other apps (the panel ignores the mouse, or the pointer is elsewhere).
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMouseEvent(event, isLocal: false)
            }
        }) {
            mouseMonitors.append(monitor)
        } else {
            Self.logger.error("Could not install the global mouse monitor")
        }

        // Events delivered to Otto's own windows. Local monitors must return the event.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMouseEvent(event, isLocal: true)
            }
            return event
        }) {
            mouseMonitors.append(monitor)
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                self?.handleKeyDown(event) ?? false
            }
            return consumed ? nil : event
        }
    }

    private func installNotificationObservers() {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        observe(center, NSApplication.didChangeScreenParametersNotification, object: nil) { controller in
            controller.reposition()
        }
        observe(workspaceCenter, NSWorkspace.activeSpaceDidChangeNotification, object: nil) { controller in
            controller.bringToFront()
        }
        observe(workspaceCenter, NSWorkspace.screensDidWakeNotification, object: nil) { controller in
            controller.reposition()
            controller.bringToFront()
        }
        observe(center, NSWindow.didResignKeyNotification, object: panel) { controller in
            controller.panelDidResignKey()
        }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        object: AnyObject?,
        perform action: @escaping @MainActor (NotchWindowController) -> Void
    ) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        notificationTokens.append((center, token))
    }

    // MARK: - View model hooks

    private func presentationDidChange(to presentation: NotchViewModel.Presentation) {
        if presentation == .open {
            bringToFront()
        }
        refreshPointerState()
    }

    private func observedStateDidChange(_ state: ObservedState) {
        // Covers presentation changes made without the hook, and shouldStayOpen turning false while
        // the pointer is already outside (menu dismissed, loads finished, panel lost focus).
        refreshPointerState()
    }

    private func setKeyFocus(_ focus: Bool) {
        guard !isHiddenForCapture else { return }
        if focus {
            // A non-activating panel becomes key without activating Otto: the user's app stays active.
            panel.makeKeyAndOrderFront(nil)
        } else if panel.isKeyWindow {
            // Ordering the key panel out returns keyboard focus to the active app's key window.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    private func beginScreenCapture() {
        isHiddenForCapture = true
        apply(pointerMachine.cancelAllTimers())
        panel.orderOut(nil)
    }

    private func endScreenCapture() {
        isHiddenForCapture = false
        bringToFront()
        refreshPointerState()
    }

    private func panelDidResignKey() {
        if viewModel.isEngaged && !viewModel.isMenuPresented {
            viewModel.isEngaged = false
        }
        refreshPointerState()
    }

    private func bringToFront() {
        guard !isHiddenForCapture else { return }
        panel.orderFrontRegardless()
    }

    // MARK: - Pointer

    /// Screen location of an event. Local events carry a window; global ones do not, and their
    /// `locationInWindow` is not reliably in screen space, so use the current pointer location.
    private func screenLocation(of event: NSEvent) -> CGPoint {
        if let window = event.window {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return NSEvent.mouseLocation
    }

    private func refreshPointerState() {
        handlePointer(.refresh, at: NSEvent.mouseLocation)
    }

    private func handleMouseEvent(_ event: NSEvent, isLocal: Bool) {
        let point = screenLocation(of: event)
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            let button: NotchPointerMachine.Button = event.type == .leftMouseDown ? .left : .right
            let target: NotchPointerMachine.ClickTarget
            if !isLocal {
                target = .elsewhere
            } else if event.window === panel {
                target = .panel
            } else {
                target = .otherOttoWindow
            }
            handlePointer(.mouseDown(button, target), at: point)
        case .leftMouseDragged:
            handlePointer(.dragged, at: point)
        case .leftMouseUp:
            handlePointer(.mouseUp, at: point)
        default:
            handlePointer(.refresh, at: point)
        }
    }

    /// Feeds one event, with a fresh snapshot of the world, to the pointer machine and applies the
    /// resulting effects.
    private func handlePointer(_ event: NotchPointerMachine.Event, at point: CGPoint) {
        guard !isHiddenForCapture else { return }
        let context = NotchPointerMachine.Context(
            point: point,
            isButtonPressed: NSEvent.pressedMouseButtons != 0,
            dragPasteboardChangeCount: { NSPasteboard(name: .drag).changeCount },
            isOpen: viewModel.isOpen,
            openReason: viewModel.openReason,
            shouldStayOpen: viewModel.shouldStayOpen,
            isEngaged: viewModel.isEngaged,
            isMenuPresented: viewModel.isMenuPresented,
            hasTransientError: viewModel.transientError != nil,
            renderedShapeSize: viewModel.renderedShapeSize,
            geometry: geometry,
            now: Self.now()
        )
        apply(pointerMachine.handle(event, context))
    }

    /// Applies effects in order. Presentation changes come last (the machine guarantees it); they
    /// re-enter `handlePointer` through the presentation hook with an up-to-date snapshot.
    private func apply(_ effects: [NotchPointerMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .setIgnoresMouseEvents(let ignore):
                if panel.ignoresMouseEvents != ignore {
                    panel.ignoresMouseEvents = ignore
                }
            case .setHovering(let hovering):
                // Only write on change: every write notifies observers.
                if viewModel.isHovering != hovering {
                    viewModel.isHovering = hovering
                }
            case .scheduleTimer(let timer, let deadline):
                scheduleTimer(timer, at: deadline)
            case .cancelTimer(let timer):
                timerTasks.removeValue(forKey: timer)?.cancel()
            case .open(let reason, let focus):
                viewModel.open(reason: reason, focus: focus)
            case .close:
                viewModel.close()
            case .engage:
                viewModel.engage()
            }
        }
    }

    private func scheduleTimer(_ timer: NotchPointerMachine.Timer, at deadline: TimeInterval) {
        timerTasks.removeValue(forKey: timer)?.cancel()
        let delay = max(0, deadline - Self.now())
        timerTasks[timer] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.timerTasks[timer] = nil
            self.handlePointer(.timerFired(timer), at: NSEvent.mouseLocation)
        }
    }

    /// Monotonic clock for the pointer machine.
    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    // MARK: - Keyboard

    /// Shortcuts while the panel is key. Returns true when the event was consumed.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === panel, panel.isKeyWindow else { return false }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {
            // Let an input method cancel its composition first.
            if let textView = panel.firstResponder as? NSTextView, textView.hasMarkedText() {
                return false
            }
            viewModel.close()
            return true
        }

        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "n":
            viewModel.newChat()
            return true
        case ",":
            viewModel.openSettings()
            return true
        case "w":
            viewModel.close()
            return true
        case "v":
            guard shouldPasteAsAttachment() else { return false }
            viewModel.pasteFromClipboard()
            return true
        default:
            return false
        }
    }

    /// ⌘V goes to Otto's clipboard import (files/images → chips, text → composer) unless the composer
    /// is editing and the clipboard holds text, in which case the text view pastes normally.
    private func shouldPasteAsAttachment() -> Bool {
        guard let textView = panel.firstResponder as? NSTextView, textView.isEditable else { return true }
        let pasteboard = NSPasteboard.general
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        let hasText = pasteboard.availableType(from: [.string]) != nil
        return !hasText && NSImage.canInit(with: pasteboard)
    }
}

// MARK: - Supporting types

private extension NotchWindowController {
    /// View-model state the pointer logic depends on beyond pointer movement.
    struct ObservedState: Equatable {
        var presentation: NotchViewModel.Presentation
        var shouldStayOpen: Bool
        var isMenuPresented: Bool
        var renderedShapeSize: CGSize
    }
}

/// Hosting view that acts on the first click even while the panel is not key, so a hover-opened
/// notch responds to its buttons immediately.
private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
