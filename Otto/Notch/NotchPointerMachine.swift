//
//  NotchPointerMachine.swift
//  Otto
//
//  The notch's pointer logic as a pure state machine: click-through, hover-open, exit-close,
//  drag-open and soft focus (the keyboard offered to a pointer resting on the open panel). It knows
//  nothing about windows, NSEvent or wall-clock timers. The window controller
//  gathers a `Context` snapshot (pointer location, buttons, view-model flags, geometry, time) for
//  every event, feeds it in, and applies the returned effects; timers come back in as
//  `.timerFired` events. That keeps every decision unit-testable.
//

import CoreGraphics
import Foundation

struct NotchPointerMachine {
    // MARK: Configuration

    struct Configuration: Equatable {
        /// How long the pointer must rest over the notch before it opens by hover.
        var hoverDwell: TimeInterval = 0.09
        /// How far the pointer may drift and still count as resting.
        var restTolerance: CGFloat = 3
        /// How long the pointer must stay away from the open shape before it closes.
        var exitCloseDelay: TimeInterval = 0.3
        /// Grace period after a drag ends so the drop (delivered separately from the mouse-up we
        /// observe) can engage the view model before we decide nothing was dropped.
        var dropSettle: TimeInterval = 0.25
        /// How far the pointer may stray outside the open shape before an exit-close is scheduled.
        var exitSlack: CGFloat = 14
        /// How long the pointer must rest on the open, unfocused panel before it takes the keyboard.
        var softFocusDwell: TimeInterval = 0.15
        /// Soft focus waits until no key has been pressed anywhere for this long, so someone typing in
        /// their editor with the pointer parked on the notch keeps their keystrokes.
        var softFocusTypingQuiet: TimeInterval = 0.8
        /// How far outside the open shape the pointer must go before soft focus is handed back.
        var softFocusReleaseSlack: CGFloat = 6
        /// How soon a soft focus deferred by secure input (a password field somewhere) checks again.
        var softFocusSecureInputRetry: TimeInterval = 0.5
        /// Shortest wait before a deferred check runs again, so rounding never re-arms a timer for
        /// the instant it fired.
        var minimumRetry: TimeInterval = 0.01
    }

    // MARK: Inputs

    /// Everything the machine needs to know about the world at the moment of an event.
    struct Context {
        /// Pointer location, global coordinates (bottom-left origin).
        var point: CGPoint
        /// Any mouse button is held.
        var isButtonPressed: Bool
        /// `NSPasteboard(name: .drag).changeCount`, read lazily (only when a mouse-down or a drag
        /// over the notch needs it).
        var dragPasteboardChangeCount: () -> Int
        var isOpen: Bool
        var openReason: NotchViewModel.OpenReason?
        var shouldStayOpen: Bool
        var isEngaged: Bool
        var isMenuPresented: Bool
        /// The view model is showing a transient error (e.g. a refused drop).
        var hasTransientError: Bool
        /// Shape size as the UI last reported it (may be stale right after a transition).
        var renderedShapeSize: CGSize
        var geometry: NotchGeometry
        /// Monotonic time in seconds.
        var now: TimeInterval
        /// The panel is the key window (for any reason, soft focus included).
        var isPanelKey = false
        /// The view model holds soft focus (authoritative: the machine never tracks it itself).
        var isSoftFocused = false
        /// Settings → "Type after hovering".
        var softFocusEnabled = false
        /// Seconds since the last key-down anywhere in the session, read lazily.
        var secondsSinceLastKeyDown: () -> TimeInterval = { .infinity }
        /// A secure text field (a password) has the keyboard somewhere, read lazily.
        var isSecureInputActive: () -> Bool = { false }
        /// Settings → "Open on hover". Off: the closed notch still grows under the pointer and takes
        /// clicks and drags, but a resting pointer never opens it.
        var hoverOpenEnabled = true
        /// Pinned open: no exit-close and no outside-click close.
        var isPinned = false
        /// Largest open shape the UI may draw (tall mode raises the height).
        var openShapeLimit = CGSize(width: NotchMetrics.openWidth, height: NotchMetrics.maxOpenHeight)
    }

    enum Button: Equatable { case left, right }

    /// Where a mouse-down was delivered.
    enum ClickTarget: Equatable {
        /// To the notch panel (local monitor).
        case panel
        /// To another Otto window, e.g. Settings (local monitor).
        case otherOttoWindow
        /// To another app or the menu bar (global monitor).
        case elsewhere
    }

    enum Timer: Hashable, CaseIterable { case hoverOpen, exitClose, dropSettle, softFocus }

    enum Event: Equatable {
        /// The pointer moved, or state the pointer logic depends on changed (presentation, shape
        /// size, shouldStayOpen, geometry).
        case refresh
        case mouseDown(Button, ClickTarget)
        case dragged
        case mouseUp
        case timerFired(Timer)
    }

    // MARK: Outputs

    enum Effect: Equatable {
        case setIgnoresMouseEvents(Bool)
        case setHovering(Bool)
        case scheduleTimer(Timer, at: TimeInterval)
        case cancelTimer(Timer)
        case open(NotchViewModel.OpenReason, focus: Bool)
        /// Close the notch. Payload-free on purpose: why it closed is `lastCloseReason`.
        case close
        case engage
        /// Give the resting pointer's panel the keyboard without engaging (`vm.softFocus()`).
        case takeSoftFocus
        /// Hand the keyboard back to the user's app (`vm.releaseSoftFocus()`).
        case releaseSoftFocus
    }

    // MARK: State

    let configuration: Configuration

    /// Presentation as of the previous event; a difference means the notch opened or closed.
    private(set) var wasOpen = false
    /// Set when the notch closes with the pointer still over it: hover must not reopen it until the
    /// pointer has left the hot zone at least once.
    private(set) var hoverSuppressedUntilExit = false
    /// The notch was opened by a content drag whose mouse button is still held.
    private(set) var isDragOpenActive = false
    /// Drag pasteboard change count at the most recent left mouse-down. A different value during a
    /// drag means the drag carries content (files, images, text) rather than moving a window.
    private var dragChangeCountAtMouseDown: Int?
    /// Where and when the pointer last came to rest over the notch; the dwell counts from here.
    private var restAnchor: (point: CGPoint, time: TimeInterval)?
    private(set) var deadlines: [Timer: TimeInterval] = [:]
    /// Why the most recent `.close` was emitted: `.pointerExit` for the exit timer, `.outsideClick`
    /// for a mouse-down elsewhere, `.programmatic` when a drag-open folds up without a drop. The
    /// window controller passes it to `vm.close(_:)`.
    private(set) var lastCloseReason: CloseReason?
    /// Where and when the pointer came to rest on the open panel; the soft-focus dwell counts from here.
    private var softRestAnchor: (point: CGPoint, time: TimeInterval)?
    /// The closed shape's size and the pointer location at the previous closed-notch event, so a
    /// shape that grows under a stationary pointer (a reply drop) can be told from a pointer that
    /// moved onto the notch.
    private var lastClosedShapeSize: CGSize?
    private var lastClosedPoint: CGPoint?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Handling events

    /// Processes one event. Effects are ordered so that an action (`.open`, `.close`, `.engage`,
    /// `.takeSoftFocus`, `.releaseSoftFocus`) always comes last and there is at most one per call:
    /// applying it changes presentation or key status, which re-enters the machine with a `.refresh`,
    /// and no stale effect from this call may run after that.
    mutating func handle(_ event: Event, _ context: Context) -> [Effect] {
        var effects: [Effect] = []
        var action: Effect?

        syncPresentation(context, &effects)

        switch event {
        case .refresh:
            action = updatePointer(context, &effects)

        case .mouseDown(let button, let target):
            if button == .left {
                dragChangeCountAtMouseDown = context.dragPasteboardChangeCount()
            }
            let clickAction = mouseDownAction(button: button, target: target, context)
            let pointerAction = updatePointer(context, &effects)
            // A click's engage/close/open always wins over a soft-focus change in the same call.
            action = clickAction ?? pointerAction

        case .dragged:
            if startsDragOpen(context) {
                isDragOpenActive = true
                cancel(.hoverOpen, &effects)
                // Let the SwiftUI drop target see the drag immediately.
                effects.append(.setIgnoresMouseEvents(false))
                action = .open(.drag, focus: false)
            } else {
                action = updatePointer(context, &effects)
            }

        case .mouseUp:
            if isDragOpenActive {
                isDragOpenActive = false
                schedule(.dropSettle, at: context.now + configuration.dropSettle, &effects)
            }
            action = updatePointer(context, &effects)

        case .timerFired(let timer):
            action = timerFired(timer, context, &effects)
        }

        if let action {
            effects.append(action)
        }
        return effects
    }

    /// Cancels every pending timer (e.g. while the panel is hidden for a screen capture).
    mutating func cancelAllTimers() -> [Effect] {
        var effects: [Effect] = []
        for timer in Timer.allCases {
            cancel(timer, &effects)
        }
        restAnchor = nil
        softRestAnchor = nil
        return effects
    }

    // MARK: - Presentation transitions

    private mutating func syncPresentation(_ context: Context, _ effects: inout [Effect]) {
        guard context.isOpen != wasOpen else { return }
        wasOpen = context.isOpen
        if context.isOpen {
            cancel(.hoverOpen, &effects)
            restAnchor = nil
            // For a hover-open the pointer is already resting on the panel: the soft-focus dwell
            // counts from the moment of opening.
            softRestAnchor = (context.point, context.now)
            lastClosedShapeSize = nil
            lastClosedPoint = nil
        } else {
            cancel(.exitClose, &effects)
            cancel(.dropSettle, &effects)
            stopSoftDwell(&effects)
            isDragOpenActive = false
            if closedHotZone(context).containsInclusive(context.point) {
                hoverSuppressedUntilExit = true
            }
        }
    }

    // MARK: - Pointer

    /// Recomputes click-through, hover, exit-close and soft-focus state for the pointer in `context`.
    /// Returns a soft-focus action (`.releaseSoftFocus`) when the pointer's position calls for one.
    private mutating func updatePointer(_ context: Context, _ effects: inout [Effect]) -> Effect? {
        let point = context.point

        if context.isOpen {
            cancel(.hoverOpen, &effects)
            restAnchor = nil
            effects.append(.setHovering(false))

            let overShape = openShapeContains(point, context)
            // Right after a drag-open the UI may not have reported the open size yet; keep the notch
            // itself a drop target meanwhile.
            let overDragZone = isDragOpenActive && closedHotZone(context).containsInclusive(point)
            effects.append(.setIgnoresMouseEvents(!(overShape || overDragZone)))

            if keepsOpen(context) || overDragZone || keepOpenZone(context).containsInclusive(point) {
                cancel(.exitClose, &effects)
            } else if deadlines[.exitClose] == nil {
                schedule(.exitClose, at: context.now + configuration.exitCloseDelay, &effects)
            }
            return softFocusAction(context, overShape: overShape, &effects)
        }

        cancel(.exitClose, &effects)

        let closedSize = closedShapeSize(context)
        suppressHoverIfShapeGrewUnderPointer(context, closedSize: closedSize)
        lastClosedShapeSize = closedSize
        lastClosedPoint = point

        let inHotZone = closedHotZone(context).containsInclusive(point)
        effects.append(.setIgnoresMouseEvents(!inHotZone))

        guard inHotZone else {
            hoverSuppressedUntilExit = false
            stopHoverDwell(&effects)
            effects.append(.setHovering(false))
            return nil
        }
        guard !hoverSuppressedUntilExit else {
            stopHoverDwell(&effects)
            effects.append(.setHovering(false))
            return nil
        }

        effects.append(.setHovering(true))
        // "Open on hover" off: the grow stays as the "this is clickable" cue, but resting never opens.
        guard context.hoverOpenEnabled else {
            stopHoverDwell(&effects)
            return nil
        }
        // With a button held this is a click (handled by the UI) or a drag (handled by the drag
        // logic), not a hover. The hot zone's margins react to clicks and drags but only the notch
        // itself opens on hover.
        guard !context.isButtonPressed, hoverTarget(context).containsInclusive(point) else {
            stopHoverDwell(&effects)
            return nil
        }

        // Real rest check: the dwell restarts whenever the pointer moves more than `restTolerance`,
        // so a pointer sweeping across the menu bar never opens the notch on its way past.
        if let anchor = restAnchor, anchor.point.distance(to: point) <= configuration.restTolerance {
            // Still resting; the pending timer (or the one scheduled below) will check the dwell.
        } else {
            restAnchor = (point, context.now)
        }
        if deadlines[.hoverOpen] == nil, let anchor = restAnchor {
            schedule(.hoverOpen, at: anchor.time + configuration.hoverDwell, &effects)
        }
        return nil
    }

    /// Hover-exit never closes while the view model wants the notch kept open or it is pinned.
    private func keepsOpen(_ context: Context) -> Bool {
        context.shouldStayOpen || context.isPinned
    }

    /// A closed shape that grows under a stationary pointer (a reply drop sliding out below the
    /// camera, activity ears appearing) must not hover-open the notch: the pointer did not come to the
    /// notch, the notch came to the pointer. Hover stays off until the pointer leaves the hot zone
    /// once; clicks still work. The hover grow is the machine's own answer to the pointer, so growth
    /// no larger than it never suppresses.
    private mutating func suppressHoverIfShapeGrewUnderPointer(_ context: Context, closedSize: CGSize) {
        guard let previousSize = lastClosedShapeSize, let previousPoint = lastClosedPoint,
              previousPoint.distance(to: context.point) <= configuration.restTolerance
        else { return }
        let hoverGrowth = ClosedNotchLayout.hoverGrowth
        let grewBeyondHover = closedSize.width - previousSize.width > hoverGrowth.width + 0.5
            || closedSize.height - previousSize.height > hoverGrowth.height + 0.5
        guard grewBeyondHover else { return }
        let previousTarget = context.geometry.hoverTarget(shapeSize: previousSize)
        let newTarget = context.geometry.hoverTarget(shapeSize: closedSize)
        if !previousTarget.containsInclusive(context.point), newTarget.containsInclusive(context.point) {
            hoverSuppressedUntilExit = true
        }
    }

    /// Soft focus (SPEC-v2 §6.2): a pointer resting on the open, unengaged panel takes the keyboard
    /// after `softFocusDwell`; leaving the shape (plus slack) while soft-focused hands it back.
    private mutating func softFocusAction(_ context: Context, overShape: Bool, _ effects: inout [Effect]) -> Effect? {
        guard context.softFocusEnabled, !context.isEngaged else {
            stopSoftDwell(&effects)
            return nil
        }
        if context.isSoftFocused {
            stopSoftDwell(&effects)
            let stillOver = NotchHitTest.shapeContains(
                context.point,
                rect: currentShapeRect(context),
                topRadius: NotchMetrics.openTopRadius,
                bottomRadius: NotchMetrics.openBottomRadius,
                tolerance: configuration.softFocusReleaseSlack
            )
            return stillOver ? nil : .releaseSoftFocus
        }
        // Key for another reason (the file picker just closed, a click engaged and resigned…).
        guard !context.isPanelKey, overShape, !context.isButtonPressed else {
            stopSoftDwell(&effects)
            return nil
        }
        if let anchor = softRestAnchor, anchor.point.distance(to: context.point) <= configuration.restTolerance {
            // Still resting; the pending timer (or the one scheduled below) checks the dwell.
        } else {
            softRestAnchor = (context.point, context.now)
        }
        if deadlines[.softFocus] == nil, let anchor = softRestAnchor {
            schedule(.softFocus, at: anchor.time + configuration.softFocusDwell, &effects)
        }
        return nil
    }

    private mutating func stopSoftDwell(_ effects: inout [Effect]) {
        softRestAnchor = nil
        cancel(.softFocus, &effects)
    }

    private mutating func stopHoverDwell(_ effects: inout [Effect]) {
        restAnchor = nil
        cancel(.hoverOpen, &effects)
    }

    private mutating func mouseDownAction(button: Button, target: ClickTarget, _ context: Context) -> Effect? {
        switch target {
        case .elsewhere:
            // A click in another app (or on the menu bar) dismisses the notch. While a menu, the
            // file picker or another system sheet the view model reports is up, the click belongs
            // to that UI instead. A pinned notch stays: the click only moves the keyboard.
            guard context.isOpen, !context.isMenuPresented, !context.isPinned else { return nil }
            lastCloseReason = .outsideClick
            return .close
        case .otherOttoWindow:
            return nil
        case .panel:
            if context.isOpen {
                // Clicking into a hover-opened panel commits to it: take focus and stop hover-exit closing.
                guard !context.isEngaged, openShapeContains(context.point, context) else { return nil }
                return .engage
            }
            // The SwiftUI shape handles clicks on itself; clicks on the hot-zone margin around it
            // would otherwise be swallowed by the panel, so treat them as a click on the notch.
            guard button == .left else { return nil }
            let onShape = currentShapeRect(context).containsInclusive(context.point)
            guard !onShape, closedHotZone(context).containsInclusive(context.point) else { return nil }
            return .open(.click, focus: true)
        }
    }

    private func startsDragOpen(_ context: Context) -> Bool {
        guard !context.isOpen, closedHotZone(context).containsInclusive(context.point) else { return false }
        // No mouse-down observed (e.g. the drag started before Otto launched): nothing to compare.
        guard let baseline = dragChangeCountAtMouseDown else { return false }
        return context.dragPasteboardChangeCount() != baseline
    }

    // MARK: - Timers

    private mutating func timerFired(_ timer: Timer, _ context: Context, _ effects: inout [Effect]) -> Effect? {
        guard let deadline = deadlines[timer] else {
            // Cancelled after the task was already on its way.
            return updatePointer(context, &effects)
        }
        // Timers may fire a hair early relative to our clock; wait out the remainder.
        guard context.now + 0.001 >= deadline else {
            effects.append(.scheduleTimer(timer, at: deadline))
            return nil
        }
        deadlines[timer] = nil

        switch timer {
        case .hoverOpen:
            return hoverDwellElapsed(context, &effects)
        case .exitClose:
            let keep = keepsOpen(context)
                || keepOpenZone(context).containsInclusive(context.point)
                || (isDragOpenActive && closedHotZone(context).containsInclusive(context.point))
            guard context.isOpen, !keep else {
                return updatePointer(context, &effects)
            }
            lastCloseReason = .pointerExit
            return .close
        case .dropSettle:
            // After a drag-open ends: if nothing was dropped (a drop engages the view model or starts
            // loads) fold the notch back up — unless the drop was refused with an error (e.g. the
            // attachment limit), which must stay visible. The regular exit-close takes over then.
            let foldUp = context.isOpen
                && context.openReason == .drag
                && !keepsOpen(context)
                && !context.hasTransientError
            guard foldUp else {
                return updatePointer(context, &effects)
            }
            lastCloseReason = .programmatic
            return .close
        case .softFocus:
            return softFocusDwellElapsed(context, &effects)
        }
    }

    private mutating func softFocusDwellElapsed(_ context: Context, _ effects: inout [Effect]) -> Effect? {
        guard context.isOpen, context.softFocusEnabled, !context.isEngaged, !context.isSoftFocused,
              !context.isPanelKey, !context.isButtonPressed, openShapeContains(context.point, context),
              let anchor = softRestAnchor
        else {
            return updatePointer(context, &effects)
        }
        // Moved since the last event we saw: restart the dwell from here.
        guard anchor.point.distance(to: context.point) <= configuration.restTolerance else {
            softRestAnchor = (context.point, context.now)
            schedule(.softFocus, at: context.now + configuration.softFocusDwell, &effects)
            return nil
        }
        let restDeadline = anchor.time + configuration.softFocusDwell
        guard context.now + 0.001 >= restDeadline else {
            schedule(.softFocus, at: restDeadline, &effects)
            return nil
        }
        // Someone is typing in their own app with the pointer parked here: wait until they pause.
        let idle = context.secondsSinceLastKeyDown()
        if idle < configuration.softFocusTypingQuiet {
            let wait = max(configuration.softFocusTypingQuiet - idle, configuration.minimumRetry)
            schedule(.softFocus, at: context.now + wait, &effects)
            return nil
        }
        // A password field has the keyboard somewhere: never pull keystrokes into the composer.
        if context.isSecureInputActive() {
            schedule(.softFocus, at: context.now + configuration.softFocusSecureInputRetry, &effects)
            return nil
        }
        softRestAnchor = nil
        return .takeSoftFocus
    }

    private mutating func hoverDwellElapsed(_ context: Context, _ effects: inout [Effect]) -> Effect? {
        let point = context.point
        guard !context.isOpen,
              context.hoverOpenEnabled,
              !hoverSuppressedUntilExit,
              !context.isButtonPressed,
              hoverTarget(context).containsInclusive(point),
              let anchor = restAnchor
        else {
            return updatePointer(context, &effects)
        }
        // The pointer moved since the last event we saw: restart the dwell from here.
        guard anchor.point.distance(to: point) <= configuration.restTolerance else {
            restAnchor = (point, context.now)
            schedule(.hoverOpen, at: context.now + configuration.hoverDwell, &effects)
            return nil
        }
        // Moved (within tolerance) after the timer was armed: wait for the full dwell.
        let restDeadline = anchor.time + configuration.hoverDwell
        guard context.now + 0.001 >= restDeadline else {
            schedule(.hoverOpen, at: restDeadline, &effects)
            return nil
        }
        restAnchor = nil
        return .open(.hover, focus: false)
    }

    private mutating func schedule(_ timer: Timer, at deadline: TimeInterval, _ effects: inout [Effect]) {
        deadlines[timer] = deadline
        effects.append(.scheduleTimer(timer, at: deadline))
    }

    private mutating func cancel(_ timer: Timer, _ effects: inout [Effect]) {
        guard deadlines.removeValue(forKey: timer) != nil else { return }
        effects.append(.cancelTimer(timer))
    }

    // MARK: - Geometry

    /// Size of the shape as the UI reports it, sanitized: a missing report falls back to the largest
    /// open shape, and sizes never exceed `openShapeLimit` (tall mode raises its height).
    func currentShapeSize(_ context: Context) -> CGSize {
        guard context.isOpen else { return closedShapeSize(context) }
        let limit = context.openShapeLimit
        let reported = context.renderedShapeSize
        guard reported.width >= 1, reported.height >= 1 else {
            return CGSize(width: min(NotchMetrics.openWidth, limit.width), height: limit.height)
        }
        return CGSize(width: min(reported.width, limit.width), height: min(reported.height, limit.height))
    }

    /// The closed shape's size, clamped so a stale open-size report never inflates the hot zone.
    func closedShapeSize(_ context: Context) -> CGSize {
        let reported = context.renderedShapeSize
        guard reported.width >= 1, reported.height >= 1 else { return context.geometry.closedSize }
        let limit = context.geometry.maximumClosedShapeSize
        return CGSize(width: min(reported.width, limit.width), height: min(reported.height, limit.height))
    }

    func currentShapeRect(_ context: Context) -> CGRect {
        context.geometry.shapeRect(size: currentShapeSize(context))
    }

    func closedHotZone(_ context: Context) -> CGRect {
        context.geometry.closedHotZone(shapeSize: closedShapeSize(context))
    }

    func hoverTarget(_ context: Context) -> CGRect {
        context.geometry.hoverTarget(shapeSize: closedShapeSize(context))
    }

    func keepOpenZone(_ context: Context) -> CGRect {
        currentShapeRect(context).insetBy(dx: -configuration.exitSlack, dy: -configuration.exitSlack)
    }

    func openShapeContains(_ point: CGPoint, _ context: Context) -> Bool {
        NotchHitTest.shapeContains(
            point,
            rect: currentShapeRect(context),
            topRadius: NotchMetrics.openTopRadius,
            bottomRadius: NotchMetrics.openBottomRadius
        )
    }
}

private extension CGRect {
    func containsInclusive(_ point: CGPoint) -> Bool {
        NotchHitTest.contains(self, point)
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
