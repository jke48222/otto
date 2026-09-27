//
//  NotchWindowController.swift
//  Otto
//
//  Owns the notch panel and all pointer/keyboard plumbing around it:
//  - pointer: event monitors gather a snapshot for every mouse event and feed it to
//    `NotchPointerMachine`, which decides click-through (the panel only accepts mouse events over
//    the drawn shape or the closed notch's hot zone), hover-open (the pointer resting on the notch),
//    exit-close, drag-open and soft focus; this class applies the machine's effects and runs its
//    timers. Any mouse-down stops a reply being read aloud, and clicks on the panel are recorded for
//    input provenance (approvals);
//  - keyboard: while the panel is key, key-downs go through the three cross-cutting rules of
//    SPEC-v2 §4.4 (speech stops, typing promotes soft focus, typing ends listening), then
//    `NotchKeyCommands` maps them and the view model performs the command;
//  - keyboard focus: the non-activating panel takes key status without activating Otto and hands
//    focus back to the user's app when it closes;
//  - window size: tall reading mode grows the window before the content springs open and shrinks
//    it once the content has folded back.
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
    /// Pointer-entry tracking for `pointerEnteredPanel()`: where the pointer was at the previous
    /// event, and whether it was over the open shape then.
    private var lastPointerLocation: CGPoint?
    private var isPointerOverOpenShape = false
    /// Shrinks the window after tall mode ends, once the content has folded back.
    private var pendingShrink: Task<Void, Never>?
    /// How long the window keeps its tall size after tall mode ends (the content's close spring).
    private static let shrinkDelay: Duration = .milliseconds(500)

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
        panel.quickLookController = viewModel.shelf.quickLook

        applyGeometryToViewModel()
        wireViewModelHooks()
        let frame = geometry.windowFrame(openHeightLimit: viewModel.openHeightLimit)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
    }

    deinit {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        for entry in notificationTokens { entry.center.removeObserver(entry.token) }
        for task in timerTasks.values { task.cancel() }
        pendingShrink?.cancel()
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
                    renderedShapeSize: viewModel.renderedShapeSize,
                    openHeightLimit: viewModel.openHeightLimit,
                    isPinned: viewModel.isPinned
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
        // The frame for the current height limit; a shrink still waiting on the close spring is moot.
        pendingShrink?.cancel()
        pendingShrink = nil
        let frame = geometry.windowFrame(openHeightLimit: viewModel.openHeightLimit)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        refreshPointerState()
    }

    /// The screen hosting the notch (the display the geometry was made for).
    var notchScreen: NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first { NotchGeometry.displayID(of: $0) == displayID }
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
        if viewModel.tallOpenHeight != geometry.tallOpenHeight {
            viewModel.tallOpenHeight = geometry.tallOpenHeight
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
        viewModel.onWillChangeOpenHeightLimit = { [weak self] limit in
            self?.openHeightLimitWillChange(to: limit)
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
        observe(center, NSWindow.didBecomeKeyNotification, object: panel) { controller in
            controller.panelDidBecomeKey()
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
        // A taller limit that arrived without the hook (a snapshot seed, a new screen height) must
        // never leave the content clipped by the window.
        let needed = geometry.windowFrame(openHeightLimit: state.openHeightLimit)
        if needed.height > panel.frame.height {
            growWindow(to: needed)
        }
        // Covers presentation changes made without the hook, and shouldStayOpen turning false while
        // the pointer is already outside (menu dismissed, loads finished, panel lost focus, unpinned).
        refreshPointerState()
    }

    /// Tall mode is about to start or end. Growing happens now, before SwiftUI starts the spring, so
    /// the first frames aren't clipped; shrinking waits for the content to fold back, and is
    /// cancelled if tall mode comes back first. The root view is top-aligned and autoresizing, so
    /// nothing visibly moves.
    private func openHeightLimitWillChange(to limit: CGFloat) {
        let frame = geometry.windowFrame(openHeightLimit: limit)
        if frame.height >= panel.frame.height {
            growWindow(to: frame)
            return
        }
        pendingShrink?.cancel()
        pendingShrink = Task { [weak self] in
            try? await Task.sleep(for: Self.shrinkDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingShrink = nil
            let current = self.geometry.windowFrame(openHeightLimit: self.viewModel.openHeightLimit)
            if self.panel.frame != current {
                self.panel.setFrame(current, display: false)
            }
            self.refreshPointerState()
        }
    }

    private func growWindow(to frame: CGRect) {
        pendingShrink?.cancel()
        pendingShrink = nil
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
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

    private func panelDidBecomeKey() {
        if !viewModel.isPanelKey {
            viewModel.isPanelKey = true
        }
        refreshPointerState()
    }

    /// Key is already gone: clear soft focus (and engagement, unless a menu or sheet took it) without
    /// asking for key again.
    private func panelDidResignKey() {
        if viewModel.isPanelKey {
            viewModel.isPanelKey = false
        }
        viewModel.panelDidLoseKey()
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
            // A click anywhere, in any app, stops a reply being read aloud.
            if viewModel.voice.isSpeaking {
                viewModel.stopSpeaking()
            }
            let button: NotchPointerMachine.Button = event.type == .leftMouseDown ? .left : .right
            let target: NotchPointerMachine.ClickTarget
            if !isLocal {
                target = .elsewhere
            } else if event.window === panel {
                target = .panel
                // SwiftUI buttons act on mouse-up; approvals judge the click by this mouse-down.
                let evidence = InputProvenance.evidence(for: event, mouseDown: nil)
                viewModel.notePanelMouseDown(uptime: event.timestamp, isHardware: evidence.isHardware)
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
            now: Self.now(),
            isPanelKey: panel.isKeyWindow,
            isSoftFocused: viewModel.isSoftFocused,
            softFocusEnabled: settings.notch.typeAfterHover,
            secondsSinceLastKeyDown: {
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            },
            isSecureInputActive: { IsSecureEventInputEnabled() },
            hoverOpenEnabled: settings.notch.hoverToOpen,
            isPinned: viewModel.isPinned,
            openShapeLimit: CGSize(width: NotchMetrics.openWidth, height: viewModel.openHeightLimit)
        )
        trackPointerEntry(context)
        apply(pointerMachine.handle(event, context))
    }

    /// The pointer moved onto the open shape: a new enter/exit cycle (it ends a voice reply's hold).
    /// A shape that opens or grows under a resting pointer is not an entry.
    private func trackPointerEntry(_ context: NotchPointerMachine.Context) {
        let over = context.isOpen && pointerMachine.openShapeContains(context.point, context)
        let moved = lastPointerLocation.map { hypot($0.x - context.point.x, $0.y - context.point.y) > 0.5 } ?? false
        let entered = over && !isPointerOverOpenShape && moved
        lastPointerLocation = context.point
        isPointerOverOpenShape = over
        if entered {
            viewModel.pointerEnteredPanel()
        }
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
                viewModel.close(pointerMachine.lastCloseReason ?? .programmatic)
            case .engage:
                viewModel.engage()
            case .takeSoftFocus:
                viewModel.softFocus()
            case .releaseSoftFocus:
                viewModel.releaseSoftFocus()
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

    /// Key-downs while the panel is key (SPEC-v2 §4.4). Returns true when the event was consumed.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === panel, panel.isKeyWindow else { return false }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let keyCode = event.keyCode

        // The context is captured before rule 1, so Esc or ⌘. while Otto speaks map to .stopSpeaking
        // and do nothing else: the speech was the thing to stop.
        let textView = panel.firstResponder as? NSTextView
        let context = viewModel.keyContext(
            hasMarkedText: textView?.hasMarkedText() ?? false,
            composerIsFirstResponder: viewModel.route == .chat && textView?.isEditable == true,
            clipboardWantsAttachmentPaste: Self.isPasteChord(event, flags: flags) && shouldPasteAsAttachment()
        )

        // Rule 1: any key stops speech; an unmapped key still passes through.
        if context.isSpeaking {
            viewModel.stopSpeaking()
        }

        // Rule 2: a typing key promotes soft focus to engagement. The Return that promotes is
        // consumed (it never sends, confirms or answers); every other typing key reaches the composer.
        switch NotchKeyCommands.softFocusPromotion(keyCode: keyCode, flags: flags,
                                                   isSoftFocused: viewModel.isSoftFocused,
                                                   isEngaged: viewModel.isEngaged) {
        case .engageAndConsume:
            viewModel.engage()
            return true
        case .engageAndPassThrough:
            viewModel.engage()
            finishListeningIfTyping(keyCode: keyCode, flags: flags, isListening: context.isListening)
            return false
        case .none:
            break
        }

        // Rule 3: typing while listening ends listening (the transcript goes to the composer) and
        // the key goes on to the composer.
        if finishListeningIfTyping(keyCode: keyCode, flags: flags, isListening: context.isListening) {
            return false
        }

        guard let command = NotchKeyCommands.command(keyCode: keyCode, characters: event.charactersIgnoringModifiers,
                                                     flags: flags, context: context) else { return false }
        let input = InputProvenance.evidence(for: event, mouseDown: nil)
        let consumed = viewModel.perform(command, input: input)
        Self.logger.debug("key command \(String(describing: command), privacy: .public) consumed: \(consumed, privacy: .public)")
        return consumed
    }

    /// Rule 3 of §4.4. Returns true when it finished listening.
    @discardableResult
    private func finishListeningIfTyping(keyCode: UInt16, flags: NSEvent.ModifierFlags, isListening: Bool) -> Bool {
        guard isListening, NotchKeyCommands.isTypingKey(keyCode: keyCode, flags: flags),
              !Self.returnAndEscapeKeyCodes.contains(Int(keyCode)) else { return false }
        viewModel.finishVoice(send: false)
        return true
    }

    private static let returnAndEscapeKeyCodes: Set<Int> = [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape]

    /// ⌘V on any layout (the mapper falls back to the key code, so this does too). Only then is the
    /// clipboard worth reading.
    private static func isPasteChord(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags == .command else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "v" || Int(event.keyCode) == kVK_ANSI_V
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
        var openHeightLimit: CGFloat
        var isPinned: Bool
    }
}

/// Hosting view that acts on the first click even while the panel is not key, so a hover-opened
/// notch responds to its buttons immediately.
private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
