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

        h.move(to: CGPoint(x: 100, y: 100))
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
        XCTAssertEqual(h.closeReasons, [.pointerExit], "the exit timer closes as a pointer exit")
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
        XCTAssertEqual(h.closeReasons, [.outsideClick])
        XCTAssertEqual(h.lastEffects.last, .close, "Effect.close stays payload-free")
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


    // MARK: - Soft focus (SPEC-v2 §6.2)

    func testRestingOnHoverOpenedPanelTakesSoftFocusOnce() {
        var h = Harness()
        h.move(to: Self.notchCenter)
        h.advance(by: 0.1)
        XCTAssertTrue(h.isOpen)
        XCTAssertTrue(h.softFocusActions.isEmpty)

        // The dwell counts from the moment of opening (90 ms hover + 150 ms rest).
        h.advance(by: 0.13)
        XCTAssertTrue(h.softFocusActions.isEmpty, "not before the 150 ms rest")
        h.advance(by: 0.03)
        XCTAssertEqual(h.softFocusActions, [.takeSoftFocus])
        XCTAssertTrue(h.isSoftFocused)
        XCTAssertTrue(h.isPanelKey)
        XCTAssertFalse(h.isEngaged, "soft focus is not engagement")
        XCTAssertEqual(h.engageCount, 0)

        h.advance(by: 2)
        XCTAssertEqual(h.softFocusActions, [.takeSoftFocus], "exactly once")
    }

    func testMovingOnThePanelRestartsTheSoftFocusDwell() {
        var h = Harness()
        h.openExternally(.hover)
        let shape = h.openShapeRect
        h.move(to: CGPoint(x: shape.midX, y: shape.midY))
        h.advance(by: 0.1)
        h.move(to: CGPoint(x: shape.midX + 30, y: shape.midY))
        h.advance(by: 0.1)
        XCTAssertTrue(h.softFocusActions.isEmpty, "the rest starts over where the pointer stopped")
        h.advance(by: 0.06)
        XCTAssertEqual(h.softFocusActions, [.takeSoftFocus])
    }

    func testLeavingTheShapeBeyondTheSlackReleasesSoftFocus() {
        var h = Harness()
        h.openExternally(.hover)
        let shape = h.openShapeRect
        h.move(to: CGPoint(x: shape.midX, y: shape.midY))
        h.advance(by: 0.2)
        XCTAssertTrue(h.isSoftFocused)

        // The body's right edge sits `openTopRadius` in from the rect (the flare above it).
        let bodyEdge = shape.maxX - NotchMetrics.openTopRadius
        h.move(to: CGPoint(x: bodyEdge + 4, y: shape.midY))
        XCTAssertTrue(h.isSoftFocused, "within the 6 pt slack nothing changes")
        XCTAssertEqual(h.softFocusActions, [.takeSoftFocus])

        h.move(to: CGPoint(x: bodyEdge + 10, y: shape.midY))
        XCTAssertEqual(h.softFocusActions, [.takeSoftFocus, .releaseSoftFocus])
        XCTAssertFalse(h.isSoftFocused)
        XCTAssertFalse(h.isPanelKey)
        XCTAssertTrue(h.isOpen, "the regular exit-close decides about closing")
    }

    func testRecentTypingDefersSoftFocusUntilQuiet() {
        var h = Harness()
        h.openExternally(.hover)
        let shape = h.openShapeRect
        h.move(to: CGPoint(x: shape.midX, y: shape.midY))
        // The user was typing in their editor 0.25 s ago with the pointer parked on the notch.
        h.lastKeyDownAt = h.now - 0.25
        let quietAt = h.now + 0.55
        h.advance(by: 0.3)
        XCTAssertTrue(h.softFocusActions.isEmpty, "keystrokes stay with the user's app")
        h.advance(by: quietAt - h.now - 0.01)
        XCTAssertTrue(h.softFocusActions.isEmpty)
        h.advance(by: 0.02)
        XCTAssertEqual(h.softFocusActions, [.takeSoftFocus], "taken once the keyboard has been quiet for 0.8 s")
    }

    func testSecureInputNeverTakesSoftFocus() {
        var h = Harness()
        h.secureInput = true
        h.openExternally(.hover)
        let shape = h.openShapeRect
        h.move(to: CGPoint(x: shape.midX, y: shape.midY))
        h.advance(by: 3)
        XCTAssertTrue(h.softFocusActions.isEmpty, "a password field is focused somewhere")
        XCTAssertTrue(h.isOpen)

        h.secureInput = false
        h.advance(by: 0.6)
        XCTAssertEqual(h.softFocusActions, [.takeSoftFocus])
    }

    func testSoftFocusNeverWhileButtonHeldEngagedOrDisabled() {
        var held = Harness()
        held.openExternally(.hover)
        held.move(to: CGPoint(x: held.openShapeRect.midX, y: held.openShapeRect.midY))
        held.isButtonPressed = true
        held.send(.refresh)
        held.advance(by: 1)
        XCTAssertTrue(held.softFocusActions.isEmpty, "button held")

        var engaged = Harness()
        engaged.openExternally(.hotkey, focus: true)
        engaged.move(to: CGPoint(x: engaged.openShapeRect.midX, y: engaged.openShapeRect.midY))
        engaged.advance(by: 1)
        XCTAssertTrue(engaged.softFocusActions.isEmpty, "already engaged")
        XCTAssertNil(engaged.timers[.softFocus])

        var disabled = Harness()
        disabled.softFocusEnabled = false
        disabled.openExternally(.hover)
        disabled.move(to: CGPoint(x: disabled.openShapeRect.midX, y: disabled.openShapeRect.midY))
        disabled.advance(by: 1)
        XCTAssertTrue(disabled.softFocusActions.isEmpty, "Type after hovering is off")
        XCTAssertNil(disabled.timers[.softFocus])
    }

    func testPanelAlreadyKeyDoesNotTakeSoftFocus() {
        var h = Harness()
        h.isPanelKey = true
        h.openExternally(.hover)
        h.move(to: CGPoint(x: h.openShapeRect.midX, y: h.openShapeRect.midY))
        h.advance(by: 1)
        XCTAssertTrue(h.softFocusActions.isEmpty)
    }

    func testClickWhileSoftFocusedEngagesWithoutASoftEffect() {
        var h = Harness()
        h.openExternally(.hover)
        let inside = CGPoint(x: h.openShapeRect.midX, y: h.openShapeRect.midY)
        h.move(to: inside)
        h.advance(by: 0.2)
        XCTAssertTrue(h.isSoftFocused)

        h.send(.mouseDown(.left, .panel))
        XCTAssertEqual(h.lastEffects.last, .engage, "the click wins")
        XCTAssertFalse(h.lastEffects.contains(.takeSoftFocus))
        XCTAssertFalse(h.lastEffects.contains(.releaseSoftFocus))
        XCTAssertTrue(h.isEngaged)
        XCTAssertFalse(h.isSoftFocused)
    }

    func testClickDuringTheSoftDwellEngagesOnly() {
        var h = Harness()
        h.openExternally(.hover)
        h.move(to: CGPoint(x: h.openShapeRect.midX, y: h.openShapeRect.midY))
        h.advance(by: 0.1)
        h.send(.mouseDown(.left, .panel))
        XCTAssertEqual(h.lastEffects.last, .engage)
        h.advance(by: 1)
        XCTAssertTrue(h.softFocusActions.isEmpty, "engaged: the soft dwell is moot")
        XCTAssertNil(h.timers[.softFocus])
    }

    func testClosingCancelsTheSoftDwell() {
        var h = Harness()
        h.openExternally(.hover)
        h.move(to: CGPoint(x: h.openShapeRect.midX, y: h.openShapeRect.midY))
        XCTAssertNotNil(h.timers[.softFocus])
        h.closeExternally()
        XCTAssertNil(h.timers[.softFocus])
        h.advance(by: 1)
        XCTAssertTrue(h.softFocusActions.isEmpty)
    }

    func testProgrammaticOpenUnderARestingPointerNeverTakesSoftFocus() {
        // The unfold after a macOS dialog: the user just clicked Allow where the panel reappears.
        var h = Harness()
        h.move(to: CGPoint(x: h.openShapeRect.midX, y: h.openShapeRect.midY))
        h.openExternally(.programmatic)
        XCTAssertTrue(h.machine.softFocusAwaitsEntry)
        XCTAssertNil(h.timers[.softFocus])
        h.advance(by: 2)
        XCTAssertTrue(h.softFocusActions.isEmpty, "the user's app keeps the keyboard")
        XCTAssertTrue(h.isOpen)

        // Drifting within the panel is not coming to it either.
        h.move(to: CGPoint(x: h.openShapeRect.midX + 40, y: h.openShapeRect.midY))
        h.advance(by: 2)
        XCTAssertTrue(h.softFocusActions.isEmpty)
    }

    func testProgrammaticOpenTakesSoftFocusOnceThePointerLeavesAndComesBack() {
        var h = Harness()
        let inside = CGPoint(x: h.openShapeRect.midX, y: h.openShapeRect.midY)
        h.move(to: inside)
        h.openExternally(.programmatic)
        h.move(to: CGPoint(x: 100, y: 100))
        XCTAssertFalse(h.machine.softFocusAwaitsEntry, "seen outside the shape, away from where it opened")
        h.move(to: inside)
        h.advance(by: 0.16)
        XCTAssertEqual(h.softFocusActions, [.takeSoftFocus])
    }

    func testStaleClosedSizeAtOpenDoesNotCountAsLeaving() {
        // Right after an open the UI may still report the closed size: the resting pointer is "outside"
        // that stale shape without having moved.
        var h = Harness()
        let inside = CGPoint(x: h.openShapeRect.midX, y: h.openShapeRect.midY)
        h.move(to: inside)
        h.isOpen = true
        h.openReason = .programmatic
        h.renderedShapeSize = h.geometry.closedSize
        h.send(.refresh)
        h.renderedShapeSize = h.openSize
        h.send(.refresh)
        XCTAssertTrue(h.machine.softFocusAwaitsEntry)
        h.advance(by: 2)
        XCTAssertTrue(h.softFocusActions.isEmpty)
    }

    func testOtherUnfocusedOpensAlsoWaitForEntry() {
        for reason in [NotchViewModel.OpenReason.drag, .voice, .click] {
            var h = Harness()
            h.move(to: CGPoint(x: h.openShapeRect.midX, y: h.openShapeRect.midY))
            h.openExternally(reason)
            h.advance(by: 2)
            XCTAssertTrue(h.softFocusActions.isEmpty, "\(reason)")
        }
    }

    // MARK: - Open on hover (F10)

    func testHoverOpenDisabledNeverOpensOnRestButClicksStillOpen() {
        var h = Harness()
        h.hoverOpenEnabled = false
        h.move(to: Self.notchCenter)
        XCTAssertTrue(h.isHovering, "the grow stays as the clickable cue")
        XCTAssertFalse(h.ignoresMouseEvents)
        XCTAssertNil(h.timers[.hoverOpen], "no dwell is scheduled")
        h.advance(by: 1)
        XCTAssertFalse(h.isOpen)
        XCTAssertTrue(h.opens.isEmpty)

        // A stale dwell timer that fires anyway does nothing either.
        h.send(.timerFired(.hoverOpen))
        XCTAssertFalse(h.isOpen)

        h.move(to: CGPoint(x: 658.5, y: 975))
        h.send(.mouseDown(.left, .panel))
        XCTAssertEqual(h.opens, [.click], "a click on the hot-zone margin still opens")
    }

    // MARK: - Pinned (F11)

    func testPinnedIgnoresOutsideClicksAndExit() {
        var h = Harness()
        h.openExternally(.hover)
        h.isPinned = true
        h.move(to: CGPoint(x: 100, y: 100))
        XCTAssertNil(h.timers[.exitClose], "no exit-close is scheduled while pinned")
        h.advance(by: 2)
        XCTAssertTrue(h.isOpen)

        h.send(.mouseDown(.left, .elsewhere))
        XCTAssertTrue(h.isOpen, "an outside click only moves the keyboard")
        XCTAssertEqual(h.closeCount, 0)

        // Unpinned: the normal exit rules apply on the next pointer event.
        h.isPinned = false
        h.send(.refresh)
        h.advance(by: 0.35)
        XCTAssertFalse(h.isOpen)
        XCTAssertEqual(h.closeReasons, [.pointerExit])
    }

    func testPinnedExitTimerThatFiresAnywayKeepsOpen() {
        var h = Harness()
        h.openExternally(.hover)
        h.move(to: CGPoint(x: 100, y: 100))
        XCTAssertNotNil(h.timers[.exitClose])
        h.isPinned = true
        h.advance(by: 1)
        XCTAssertTrue(h.isOpen)
    }

    func testPinIsSuspendedWhileSystemUIWaits() {
        // Pinned, folded for System Settings, then reopened by a click on the closed notch (§4.5).
        var h = Harness()
        h.isPinned = true
        h.isWaitingOnSystemUI = true
        h.openExternally(.click, focus: true)

        // One click in System Settings goes straight back to it.
        h.move(to: CGPoint(x: 100, y: 100))
        h.send(.mouseDown(.left, .elsewhere))
        XCTAssertFalse(h.isOpen)
        XCTAssertEqual(h.closeReasons, [.outsideClick])
    }

    func testPinDoesNotKeepAnUnengagedPanelOpenOverSystemUI() {
        var h = Harness()
        h.openExternally(.hover)
        h.isPinned = true
        h.isWaitingOnSystemUI = true
        h.move(to: CGPoint(x: 100, y: 100))
        XCTAssertNotNil(h.timers[.exitClose], "leaving the panel closes it as if it weren't pinned")
        h.advance(by: 0.35)
        XCTAssertFalse(h.isOpen)
        XCTAssertEqual(h.closeReasons, [.pointerExit])
    }

    func testPinHoldsAgainOnceTheSystemUIIsGone() {
        var h = Harness()
        h.openExternally(.hover)
        h.isPinned = true
        h.isWaitingOnSystemUI = true
        h.send(.refresh)
        h.isWaitingOnSystemUI = false
        h.move(to: CGPoint(x: 100, y: 100))
        h.advance(by: 1)
        h.send(.mouseDown(.left, .elsewhere))
        XCTAssertTrue(h.isOpen)
        XCTAssertEqual(h.closeCount, 0)
    }

    func testPinnedSoftFocusIsReleasedButThePanelStays() {
        var h = Harness()
        h.openExternally(.hover)
        h.isPinned = true
        h.move(to: CGPoint(x: h.openShapeRect.midX, y: h.openShapeRect.midY))
        h.advance(by: 0.2)
        XCTAssertTrue(h.isSoftFocused)
        h.move(to: CGPoint(x: 100, y: 100))
        XCTAssertEqual(h.softFocusActions, [.takeSoftFocus, .releaseSoftFocus])
        h.advance(by: 1)
        XCTAssertTrue(h.isOpen)
    }

    // MARK: - Tall mode (F11)

    func testOpenShapeClampsToTheOpenShapeLimit() {
        let geometry = Harness().geometry
        func context(rendered: CGSize, limit: CGSize?) -> NotchPointerMachine.Context {
            var context = NotchPointerMachine.Context(
                point: .zero, isButtonPressed: false, dragPasteboardChangeCount: { 0 }, isOpen: true,
                openReason: .hotkey, shouldStayOpen: true, isEngaged: true, isMenuPresented: false,
                hasTransientError: false, renderedShapeSize: rendered, geometry: geometry, now: 0
            )
            if let limit { context.openShapeLimit = limit }
            return context
        }
        let machine = NotchPointerMachine()
        let tall = CGSize(width: NotchMetrics.openWidth, height: geometry.tallOpenHeight)

        XCTAssertEqual(machine.currentShapeSize(context(rendered: CGSize(width: 580, height: 760), limit: nil)),
                       CGSize(width: 580, height: NotchMetrics.maxOpenHeight), "normal mode caps at 560")
        XCTAssertEqual(machine.currentShapeSize(context(rendered: CGSize(width: 580, height: 760), limit: tall)),
                       CGSize(width: 580, height: 760), "tall mode lets the shape grow")
        XCTAssertEqual(machine.currentShapeSize(context(rendered: CGSize(width: 700, height: 900), limit: tall)),
                       tall, "never beyond the limit")
        XCTAssertEqual(machine.currentShapeSize(context(rendered: .zero, limit: tall)), tall,
                       "an unreported size falls back to the limit's height")
        XCTAssertEqual(machine.currentShapeSize(context(rendered: .zero, limit: nil)),
                       CGSize(width: NotchMetrics.openWidth, height: NotchMetrics.maxOpenHeight))
    }

    func testTallShapeKeepsThePointerOnThePanel() {
        var h = Harness()
        let tallHeight = h.geometry.tallOpenHeight
        h.openShapeLimit = CGSize(width: NotchMetrics.openWidth, height: tallHeight)
        h.openSize = CGSize(width: NotchMetrics.openWidth, height: tallHeight)
        h.openExternally(.hover)
        // Low on the tall panel, far below where a normal panel ends.
        h.move(to: CGPoint(x: h.openShapeRect.midX, y: h.geometry.screenFrame.maxY - tallHeight + 60))
        XCTAssertFalse(h.ignoresMouseEvents)
        h.advance(by: 1)
        XCTAssertTrue(h.isOpen)
    }

    // MARK: - Drop growth (glance.md §8.6)

    func testDropGrowingUnderAStationaryPointerDoesNotHoverOpen() {
        var h = Harness()
        // Resting just below the camera housing, outside the hot zone.
        let belowNotch = CGPoint(x: 756, y: 935)
        h.move(to: belowNotch)
        XCTAssertTrue(h.ignoresMouseEvents)
        XCTAssertFalse(h.isHovering)

        // A reply preview drops out of the closed notch, under the pointer.
        h.renderedShapeSize = CGSize(width: 380, height: 32 + ReplyPreviewMetrics.dropHeight)
        h.send(.refresh)
        XCTAssertFalse(h.ignoresMouseEvents, "the drop still takes clicks (SwiftUI opens on its tap)")
        XCTAssertFalse(h.isHovering)
        XCTAssertNil(h.timers[.hoverOpen])
        XCTAssertFalse(h.lastEffects.contains { if case .scheduleTimer(.hoverOpen, _) = $0 { return true }; return false })
        h.advance(by: 1)
        XCTAssertFalse(h.isOpen, "the notch came to the pointer, not the other way round")

        // A click on the drop is the SwiftUI shape's: the machine neither opens nor blocks it.
        h.send(.mouseDown(.left, .panel))
        XCTAssertTrue(h.opens.isEmpty)
        XCTAssertFalse(h.ignoresMouseEvents)

        // After leaving and coming back, hover opens as usual.
        h.move(to: CGPoint(x: 100, y: 100))
        h.move(to: belowNotch)
        XCTAssertTrue(h.isHovering)
        h.advance(by: 0.1)
        XCTAssertEqual(h.opens, [.hover])
    }

    func testEarsGrowingUnderAStationaryPointerDoNotHoverOpen() {
        var h = Harness()
        let besideNotch = CGPoint(x: 640, y: 970)
        h.move(to: besideNotch)
        XCTAssertFalse(h.isHovering)
        h.renderedShapeSize = CGSize(width: 185 + NotchMetrics.activityEarWidth * 2, height: 32)
        h.send(.refresh)
        XCTAssertNil(h.timers[.hoverOpen])
        h.advance(by: 1)
        XCTAssertFalse(h.isOpen)
    }

    func testHoverGrowBesideTheNotchStillOpens() {
        var h = Harness()
        // 3 pt beside the housing: the hot zone reacts and the notch grows to meet the pointer.
        h.move(to: CGPoint(x: 660.5, y: 970))
        XCTAssertTrue(h.isHovering)
        XCTAssertNil(h.timers[.hoverOpen], "not on the notch yet")
        h.renderedShapeSize = CGSize(width: 185 + ClosedNotchLayout.hoverGrowth.width,
                                     height: 32 + ClosedNotchLayout.hoverGrowth.height)
        h.send(.refresh)
        XCTAssertNotNil(h.timers[.hoverOpen], "the machine's own hover grow never suppresses hover")
        h.advance(by: 0.1)
        XCTAssertEqual(h.opens, [.hover])
    }

    func testPointerMovingOntoAGrownDropHoverOpens() {
        var h = Harness()
        h.renderedShapeSize = CGSize(width: 380, height: 32 + ReplyPreviewMetrics.dropHeight)
        h.move(to: CGPoint(x: 100, y: 100))
        h.move(to: CGPoint(x: 756, y: 935))
        h.advance(by: 0.1)
        XCTAssertEqual(h.opens, [.hover], "a pointer that moves onto the drop opens it")
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
        h.move(to: CGPoint(x: 100, y: 100))
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
    var openSize = CGSize(width: 580, height: 320)

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
    var isPanelKey = false
    var isSoftFocused = false
    var softFocusEnabled = true
    /// Virtual-clock time of the last key-down anywhere; nil = none for ages.
    var lastKeyDownAt: TimeInterval?
    var secureInput = false
    var hoverOpenEnabled = true
    var isPinned = false
    var isWaitingOnSystemUI = false
    var openShapeLimit = CGSize(width: NotchMetrics.openWidth, height: NotchMetrics.maxOpenHeight)

    var ignoresMouseEvents = true
    var isHovering = false
    var timers: [Machine.Timer: TimeInterval] = [:]
    var opens: [NotchViewModel.OpenReason] = []
    var closeCount = 0
    var closeReasons: [CloseReason] = []
    var engageCount = 0
    var softFocusActions: [Machine.Effect] = []
    /// Effects of the most recent top-level `send`.
    var lastEffects: [Machine.Effect] = []
    private var sendDepth = 0

    var shouldStayOpen: Bool { isEngaged || isMenuPresented || pendingLoads }

    var openShapeRect: CGRect { geometry.shapeRect(size: openSize) }

    var context: Machine.Context {
        let count = dragChangeCount
        let idle = lastKeyDownAt.map { now - $0 } ?? .infinity
        let secure = secureInput
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
            now: now,
            isPanelKey: isPanelKey,
            isSoftFocused: isSoftFocused,
            softFocusEnabled: softFocusEnabled,
            secondsSinceLastKeyDown: { idle },
            isSecureInputActive: { secure },
            hoverOpenEnabled: hoverOpenEnabled,
            isPinned: isPinned,
            isWaitingOnSystemUI: isWaitingOnSystemUI,
            openShapeLimit: openShapeLimit
        )
    }

    /// Effects that change presentation or key status; at most one per call, and it comes last.
    static func isAction(_ effect: Machine.Effect) -> Bool {
        switch effect {
        case .open, .close, .engage, .takeSoftFocus, .releaseSoftFocus: return true
        case .setIgnoresMouseEvents, .setHovering, .scheduleTimer, .cancelTimer: return false
        }
    }

    mutating func send(_ event: Machine.Event, file: StaticString = #filePath, line: UInt = #line) {
        let effects = machine.handle(event, context)
        let actions = effects.enumerated().filter { Self.isAction($0.element) }
        XCTAssertLessThanOrEqual(actions.count, 1, "at most one action per call: \(effects)", file: file, line: line)
        if let action = actions.first {
            XCTAssertEqual(action.offset, effects.count - 1, "the action comes last: \(effects)", file: file, line: line)
        }
        // Nested sends (the re-entry after a presentation or key change) don't replace the outer call's.
        if sendDepth == 0 { lastEffects = effects }
        sendDepth += 1
        apply(effects)
        sendDepth -= 1
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
                if let reason = machine.lastCloseReason { closeReasons.append(reason) }
                closeExternally()
            case .engage:
                engageCount += 1
                isEngaged = true
                isSoftFocused = false
                isPanelKey = true
            case .takeSoftFocus:
                softFocusActions.append(effect)
                isSoftFocused = true
                isPanelKey = true
                send(.refresh)
            case .releaseSoftFocus:
                softFocusActions.append(effect)
                isSoftFocused = false
                isPanelKey = false
                send(.refresh)
            }
        }
    }

    /// The view model opened (by the machine, ⌥Space, the menu bar…); the controller's hook refreshes.
    mutating func openExternally(_ reason: NotchViewModel.OpenReason, focus: Bool = false) {
        isOpen = true
        openReason = reason
        if focus {
            isEngaged = true
            isPanelKey = true
        }
        renderedShapeSize = openSize
        send(.refresh)
    }

    mutating func closeExternally() {
        isOpen = false
        openReason = nil
        isEngaged = false
        isSoftFocused = false
        isPanelKey = false
        isPinned = false
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
