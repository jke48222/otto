//
//  NotchPointerMachineTests.swift
//  Otto
//

import CoreGraphics
import XCTest
@testable import Otto

final class NotchPointerMachineTests: XCTestCase {
    // 14" MacBook Pro: 1512×982 pt, camera housing x 663.5…848.5, 32 pt tall.
    private static let notchCenter = CGPoint(x: 756, y: 970)

    // MARK: - Hover dwell

    func testRestingOnNotchOpensAfterDwell() {
        var h = Harness()
        h.move(to: Self.notchCenter)
        XCTAssertTrue(h.isHovering)
        XCTAssertFalse(h.ignoresMouseEvents)

        h.advance(by: 0.05)
        XCTAssertFalse(h.isOpen, "must not open before the dwell elapses")

        h.advance(by: 0.05)
        XCTAssertTrue(h.isOpen)
        XCTAssertEqual(h.opens, [.hover])
        XCTAssertFalse(h.isEngaged, "hover-open does not take focus")
        XCTAssertFalse(h.isHovering)
    }

    func testCrossingNotchAtNormalSpeedDoesNotOpen() {
        for speed in [150.0, 500.0, 1500.0] {
            var h = Harness()
            h.glide(from: CGPoint(x: 400, y: 972), to: CGPoint(x: 1100, y: 972), speed: speed)
            h.advance(by: 0.5)
            XCTAssertFalse(h.isOpen, "a pointer crossing the notch at \(speed) pt/s must not open it")
            XCTAssertTrue(h.opens.isEmpty)
        }
    }

    func testStoppingAfterACrossingStillOpens() {
        var h = Harness()
        h.glide(from: CGPoint(x: 400, y: 972), to: Self.notchCenter, speed: 800)
        XCTAssertFalse(h.isOpen)
        h.advance(by: 0.1)
        XCTAssertTrue(h.isOpen)
        XCTAssertEqual(h.opens, [.hover])
    }

    func testSmallJitterCountsAsResting() {
        var h = Harness()
        h.move(to: Self.notchCenter)
        for step in 0..<8 {
            h.advance(by: 0.01)
            h.move(to: CGPoint(x: Self.notchCenter.x + (step.isMultiple(of: 2) ? 1 : -1), y: Self.notchCenter.y))
        }
        h.advance(by: 0.02)
        XCTAssertTrue(h.isOpen)
    }

    func testMovementRestartsTheDwell() {
        var h = Harness()
        h.move(to: Self.notchCenter)
        h.advance(by: 0.07)
        h.move(to: CGPoint(x: Self.notchCenter.x + 20, y: Self.notchCenter.y))
        h.advance(by: 0.05)
        XCTAssertFalse(h.isOpen, "the dwell counts from where the pointer came to rest")
        h.advance(by: 0.05)
        XCTAssertTrue(h.isOpen)
    }

    func testLeavingCancelsDwell() {
        var h = Harness()
        h.move(to: Self.notchCenter)
        h.advance(by: 0.05)
        h.move(to: CGPoint(x: 756, y: 800))
        XCTAssertFalse(h.isHovering)
        XCTAssertTrue(h.ignoresMouseEvents)
        XCTAssertNil(h.timers[.hoverOpen])
        h.advance(by: 0.5)
        XCTAssertFalse(h.isOpen)
    }

    func testHotZoneMarginHoversButDoesNotOpen() {
        var h = Harness()
        // 5 pt left of the housing: inside the ±8 pt hot zone, outside the notch itself.
        h.move(to: CGPoint(x: 658.5, y: 975))
        XCTAssertTrue(h.isHovering)
        XCTAssertFalse(h.ignoresMouseEvents, "the margin still takes clicks and drags")
        h.advance(by: 0.5)
        XCTAssertFalse(h.isOpen)
    }

    func testButtonHeldDoesNotHoverOpen() {
        var h = Harness()
        h.isButtonPressed = true
        h.move(to: Self.notchCenter)
        h.advance(by: 0.5)
        XCTAssertFalse(h.isOpen)
    }

    func testCloseWithPointerOnNotchSuppressesHoverUntilExit() {
        var h = Harness()
        h.move(to: Self.notchCenter)
        h.advance(by: 0.1)
        XCTAssertTrue(h.isOpen)

        // Esc (or the ⌥Space toggle) closes while the pointer is still on the notch.
        h.closeExternally()
        h.advance(by: 0.5)
        XCTAssertFalse(h.isOpen, "must not reopen under the resting pointer")
        XCTAssertFalse(h.isHovering)

        h.move(to: CGPoint(x: 756, y: 700))
        h.move(to: Self.notchCenter)
        h.advance(by: 0.1)
        XCTAssertTrue(h.isOpen, "hover works again after the pointer left once")
    }

    // MARK: - Exit close

    func testExitSlackKeepsOpenAndLeavingCloses() {
        var h = Harness()
        h.openExternally(.hover)
        let shape = h.openShapeRect

        h.move(to: CGPoint(x: shape.maxX + 10, y: shape.midY))
        h.advance(by: 1)
        XCTAssertTrue(h.isOpen, "within the 14 pt slack")

        h.move(to: CGPoint(x: shape.maxX + 20, y: shape.midY))
        h.advance(by: 0.2)
        XCTAssertTrue(h.isOpen)
        h.advance(by: 0.15)
        XCTAssertFalse(h.isOpen)
        XCTAssertEqual(h.closeCount, 1)
    }

    func testReturningCancelsExitClose() {
        var h = Harness()
        h.openExternally(.hover)
        let shape = h.openShapeRect
        h.move(to: CGPoint(x: shape.midX, y: shape.minY - 40))
        h.advance(by: 0.2)
        h.move(to: CGPoint(x: shape.midX, y: shape.midY))
        XCTAssertNil(h.timers[.exitClose])
        h.advance(by: 1)
        XCTAssertTrue(h.isOpen)
    }

    func testShouldStayOpenPreventsExitClose() {
        var h = Harness()
        h.openExternally(.hotkey, focus: true)
        h.move(to: CGPoint(x: 100, y: 100))
        h.advance(by: 1)
        XCTAssertTrue(h.isOpen)

        // Losing focus lets the exit close run once state is refreshed.
        h.isEngaged = false
        h.send(.refresh)
        h.advance(by: 0.35)
        XCTAssertFalse(h.isOpen)
    }

    // MARK: - Click-through

    func testClickThroughOutsideTheShape() {
        var h = Harness()
        h.move(to: CGPoint(x: 1000, y: 975))
        XCTAssertTrue(h.ignoresMouseEvents, "menu bar beside the closed notch gets its clicks")

        h.openExternally(.hotkey, focus: true)
        let shape = h.openShapeRect
        h.move(to: CGPoint(x: shape.midX, y: shape.midY))
        XCTAssertFalse(h.ignoresMouseEvents)

        // Inside the concave top-left ear: outside the drawn shape although inside its rect.
        h.move(to: CGPoint(x: shape.minX + 1, y: shape.maxY - 12))
        XCTAssertTrue(h.ignoresMouseEvents)

        // Beside the open shape (in the transparent window margin).
        h.move(to: CGPoint(x: shape.maxX + 10, y: shape.midY))
        XCTAssertTrue(h.ignoresMouseEvents)
    }

    func testGlobalClickClosesUnlessMenuPresented() {
        var h = Harness()
        h.openExternally(.hotkey, focus: true)
        h.point = CGPoint(x: 100, y: 100)
        h.isMenuPresented = true
        h.send(.mouseDown(.left, .elsewhere))
        XCTAssertTrue(h.isOpen)

        h.isMenuPresented = false
        h.send(.mouseDown(.left, .elsewhere))
        XCTAssertFalse(h.isOpen)
    }

    func testClickIntoHoverOpenedPanelEngages() {
        var h = Harness()
        h.move(to: Self.notchCenter)
        h.advance(by: 0.1)
        XCTAssertTrue(h.isOpen)
        let shape = h.openShapeRect
        h.point = CGPoint(x: shape.midX, y: shape.midY)
        h.send(.mouseDown(.left, .panel))
        XCTAssertEqual(h.engageCount, 1)
        XCTAssertTrue(h.isEngaged)
    }

    func testClickOnHotZoneMarginOpensFocused() {
        var h = Harness()
        h.move(to: CGPoint(x: 658.5, y: 975))
        h.send(.mouseDown(.left, .panel))
        XCTAssertEqual(h.opens, [.click])
        XCTAssertTrue(h.isEngaged)
    }

    func testClickInOtherOttoWindowDoesNotClose() {
        var h = Harness()
        h.openExternally(.hotkey, focus: true)
        h.point = CGPoint(x: 100, y: 100)
        h.send(.mouseDown(.left, .otherOttoWindow))
        XCTAssertTrue(h.isOpen)
    }

    // MARK: - Drag open

    func testContentDragOpensAndFoldsUpWithoutDrop() {
        var h = Harness()
        h.beginDrag(at: CGPoint(x: 300, y: 500))
        h.dragChangeCount += 1 // The drag carries files.
        h.drag(to: CGPoint(x: 700, y: 960))
        XCTAssertEqual(h.opens, [.drag])
        XCTAssertFalse(h.ignoresMouseEvents, "the SwiftUI drop target must see the drag")
        XCTAssertFalse(h.isEngaged)

        h.endDrag()
        h.advance(by: 0.2)
        XCTAssertTrue(h.isOpen)
        h.advance(by: 0.1)
        XCTAssertFalse(h.isOpen, "nothing was dropped")
    }

    func testContentDragWithDropStaysOpen() {
        var h = Harness()
        h.beginDrag(at: CGPoint(x: 300, y: 500))
        h.dragChangeCount += 1
        h.drag(to: CGPoint(x: 700, y: 960))
        // The drop engages the view model and starts loading.
        h.isEngaged = true
        h.pendingLoads = true
        h.endDrag()
        h.advance(by: 1)
        XCTAssertTrue(h.isOpen)
    }

    func testRefusedDropKeepsNotchOpenToShowTheError() {
        var h = Harness()
        h.beginDrag(at: CGPoint(x: 300, y: 500))
        h.dragChangeCount += 1
        h.drag(to: CGPoint(x: 700, y: 960))
        // handleDrop refused (attachment limit) and set a transient error without engaging.
        h.hasTransientError = true
        h.endDrag()
        h.advance(by: 1)
        XCTAssertTrue(h.isOpen, "the error must stay visible")

        // Moving away closes it through the regular exit-close.
        h.move(to: CGPoint(x: 100, y: 100))
        h.advance(by: 0.35)
        XCTAssertFalse(h.isOpen)
    }

    func testWindowDragDoesNotOpen() {
        var h = Harness()
        h.beginDrag(at: CGPoint(x: 300, y: 500))
        // Moving a window: the drag pasteboard does not change.
        h.drag(to: CGPoint(x: 700, y: 960))
        h.advance(by: 1)
        XCTAssertTrue(h.opens.isEmpty, "neither a drag-open nor a hover-open while the button is held")
        XCTAssertFalse(h.isOpen)
    }

    // MARK: - Timers

    func testEarlyTimerReschedulesForTheRemainder() {
        var h = Harness()
        h.move(to: Self.notchCenter)
        let deadline = h.timers[.hoverOpen]
        XCTAssertNotNil(deadline)
        h.now += 0.03
        h.send(.timerFired(.hoverOpen))
        XCTAssertFalse(h.isOpen)
        XCTAssertEqual(h.timers[.hoverOpen], deadline)
    }

    func testStaleTimerAfterCancelIsIgnored() {
        var h = Harness()
        h.move(to: Self.notchCenter)
        h.move(to: CGPoint(x: 756, y: 700))
        h.now += 1
        h.send(.timerFired(.hoverOpen))
        XCTAssertFalse(h.isOpen)
    }

    func testCancelAllTimers() {
        var h = Harness()
        h.move(to: Self.notchCenter)
        XCTAssertNotNil(h.timers[.hoverOpen])
        h.apply(h.machine.cancelAllTimers())
        XCTAssertTrue(h.timers.isEmpty)
        h.advance(by: 1)
        XCTAssertFalse(h.isOpen)
    }
}

// MARK: - Harness

/// Simulates the window controller and the view model around a `NotchPointerMachine`: it applies
/// effects to fake state, re-enters the machine after presentation changes (as the controller's
/// presentation hook does), and fires timers on a virtual clock.
private struct Harness {
    typealias Machine = NotchPointerMachine

    var machine = Machine()
    let geometry = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        hasPhysicalNotch: true,
        notchRect: CGRect(x: 663.5, y: 950, width: 185, height: 32)
    )
    let openSize = CGSize(width: 580, height: 320)

    var point = CGPoint(x: 100, y: 500)
    var isButtonPressed = false
    var dragChangeCount = 0
    var isOpen = false
    var openReason: NotchViewModel.OpenReason?
    var isEngaged = false
    var isMenuPresented = false
    var pendingLoads = false
    var hasTransientError = false
    var renderedShapeSize = CGSize(width: 185, height: 32)
    var now: TimeInterval = 1_000

    var ignoresMouseEvents = true
    var isHovering = false
    var timers: [Machine.Timer: TimeInterval] = [:]
    var opens: [NotchViewModel.OpenReason] = []
    var closeCount = 0
    var engageCount = 0

    var shouldStayOpen: Bool { isEngaged || isMenuPresented || pendingLoads }

    var openShapeRect: CGRect { geometry.shapeRect(size: openSize) }

    var context: Machine.Context {
        let count = dragChangeCount
        return Machine.Context(
            point: point,
            isButtonPressed: isButtonPressed,
            dragPasteboardChangeCount: { count },
            isOpen: isOpen,
            openReason: openReason,
            shouldStayOpen: shouldStayOpen,
            isEngaged: isEngaged,
            isMenuPresented: isMenuPresented,
            hasTransientError: hasTransientError,
            renderedShapeSize: renderedShapeSize,
            geometry: geometry,
            now: now
        )
    }

    mutating func send(_ event: Machine.Event) {
        apply(machine.handle(event, context))
    }

    mutating func apply(_ effects: [Machine.Effect]) {
        for effect in effects {
            switch effect {
            case .setIgnoresMouseEvents(let value):
                ignoresMouseEvents = value
            case .setHovering(let value):
                isHovering = value
            case .scheduleTimer(let timer, let deadline):
                timers[timer] = deadline
            case .cancelTimer(let timer):
                timers[timer] = nil
            case .open(let reason, let focus):
                opens.append(reason)
                openExternally(reason, focus: focus)
            case .close:
                closeCount += 1
                closeExternally()
            case .engage:
                engageCount += 1
                isEngaged = true
            }
        }
    }

    /// The view model opened (by the machine, ⌥Space, the menu bar…); the controller's hook refreshes.
    mutating func openExternally(_ reason: NotchViewModel.OpenReason, focus: Bool = false) {
        isOpen = true
        openReason = reason
        if focus { isEngaged = true }
        renderedShapeSize = openSize
        send(.refresh)
    }

    mutating func closeExternally() {
        isOpen = false
        openReason = nil
        isEngaged = false
        isMenuPresented = false
        renderedShapeSize = geometry.closedSize
        send(.refresh)
    }

    mutating func move(to newPoint: CGPoint) {
        point = newPoint
        send(.refresh)
    }

    /// Moves in a straight line at `speed` pt/s with a mouse-moved event every 8 ms.
    mutating func glide(from start: CGPoint, to end: CGPoint, speed: Double) {
        let interval = 0.008
        let length = hypot(end.x - start.x, end.y - start.y)
        let steps = max(1, Int((Double(length) / speed / interval).rounded(.up)))
        move(to: start)
        for step in 1...steps {
            advance(by: interval)
            let t = CGFloat(step) / CGFloat(steps)
            move(to: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
    }

    mutating func beginDrag(at start: CGPoint) {
        point = start
        send(.mouseDown(.left, .elsewhere))
        isButtonPressed = true
    }

    mutating func drag(to target: CGPoint) {
        let start = point
        for step in 1...10 {
            advance(by: 0.01)
            let t = CGFloat(step) / 10
            point = CGPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t)
            send(.dragged)
        }
    }

    mutating func endDrag() {
        isButtonPressed = false
        send(.mouseUp)
    }

    /// Advances the virtual clock, firing due timers in deadline order.
    mutating func advance(by interval: TimeInterval) {
        let end = now + interval
        while let (timer, deadline) = timers.min(by: { $0.value < $1.value }), deadline <= end {
            timers[timer] = nil
            now = max(now, deadline)
            send(.timerFired(timer))
        }
        now = end
    }
}
