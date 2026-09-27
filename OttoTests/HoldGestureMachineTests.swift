//
//  HoldGestureMachineTests.swift
//  Otto
//

import XCTest
@testable import Otto

final class HoldGestureMachineTests: XCTestCase {
    // MARK: - Hold enabled

    func testShortPressIsATapOnRelease() {
        var machine = HoldGestureMachine(holdEnabled: true)
        XCTAssertEqual(machine.press(at: 10), [.scheduleHoldCheck(at: 10.3)])
        XCTAssertEqual(machine.release(at: 10.12), [.tap])
        XCTAssertEqual(machine.holdCheck(at: 10.3), [], "the scheduled check finds the key up")
        XCTAssertNil(machine.pressedAt)
    }

    func testPressJustUnderTheThresholdIsStillATap() {
        var machine = HoldGestureMachine(holdEnabled: true)
        _ = machine.press(at: 10)
        XCTAssertEqual(machine.release(at: 10.299), [.tap])
    }

    func testHoldBeginsAtTheThresholdAndEndsOnRelease() {
        var machine = HoldGestureMachine(holdEnabled: true)
        _ = machine.press(at: 10)
        XCTAssertEqual(machine.holdCheck(at: 10.3), [.holdBegan])
        XCTAssertTrue(machine.isHolding)
        XCTAssertEqual(machine.holdCheck(at: 10.5), [], "a hold begins once")
        XCTAssertEqual(machine.release(at: 12), [.holdEnded])
        XCTAssertFalse(machine.isHolding)
        XCTAssertNil(machine.pressedAt)
    }

    func testEarlyHoldCheckDoesNothing() {
        var machine = HoldGestureMachine(holdEnabled: true)
        _ = machine.press(at: 10)
        XCTAssertEqual(machine.holdCheck(at: 10.2), [])
        XCTAssertFalse(machine.isHolding)
        XCTAssertEqual(machine.holdCheck(at: 10.31), [.holdBegan])
    }

    func testReleaseAfterTheThresholdBeforeTheCheckRanDoesNothing() {
        var machine = HoldGestureMachine(holdEnabled: true)
        _ = machine.press(at: 10)
        XCTAssertEqual(machine.release(at: 10.4), [])
        XCTAssertEqual(machine.holdCheck(at: 10.4), [])
    }

    func testDuplicatePressIsIgnored() {
        var machine = HoldGestureMachine(holdEnabled: true)
        _ = machine.press(at: 10)
        XCTAssertEqual(machine.press(at: 10.1), [])
        XCTAssertEqual(machine.pressedAt, 10, "the first press keeps its time")
        XCTAssertEqual(machine.holdCheck(at: 10.3), [.holdBegan])
    }

    func testReleaseWithoutPressDoesNothing() {
        var machine = HoldGestureMachine(holdEnabled: true)
        XCTAssertEqual(machine.release(at: 5), [])
        XCTAssertEqual(machine.holdCheck(at: 5), [])
    }

    func testCustomThreshold() {
        var machine = HoldGestureMachine(holdEnabled: true, holdThreshold: 0.5)
        XCTAssertEqual(machine.press(at: 1), [.scheduleHoldCheck(at: 1.5)])
        XCTAssertEqual(machine.holdCheck(at: 1.4), [])
        XCTAssertEqual(machine.release(at: 1.45), [.tap])
    }

    func testResetForgetsThePress() {
        var machine = HoldGestureMachine(holdEnabled: true)
        _ = machine.press(at: 10)
        _ = machine.holdCheck(at: 10.3)
        machine.reset()
        XCTAssertEqual(machine, HoldGestureMachine(holdEnabled: true))
        XCTAssertEqual(machine.release(at: 11), [])
    }

    // MARK: - Hold disabled

    func testDisabledTapsImmediatelyOnPress() {
        var machine = HoldGestureMachine(holdEnabled: false)
        XCTAssertEqual(machine.press(at: 10), [.tap])
        XCTAssertEqual(machine.holdCheck(at: 11), [], "no hold without hold-to-talk")
        XCTAssertEqual(machine.release(at: 11), [])
        XCTAssertEqual(machine.press(at: 12), [.tap], "the next press taps again")
    }

    func testDisabledIsTheDefault() {
        var machine = HoldGestureMachine()
        XCTAssertFalse(machine.holdEnabled)
        XCTAssertEqual(machine.holdThreshold, 0.3)
        XCTAssertEqual(machine.press(at: 0), [.tap])
    }

    func testEnablingHoldMidPressDoesNotTapTwice() {
        var machine = HoldGestureMachine(holdEnabled: false)
        XCTAssertEqual(machine.press(at: 10), [.tap])
        machine.holdEnabled = true
        XCTAssertEqual(machine.holdCheck(at: 10.5), [])
        XCTAssertEqual(machine.release(at: 10.6), [])
    }

    func testDisablingHoldWhileHoldingStillEndsTheHold() {
        var machine = HoldGestureMachine(holdEnabled: true)
        _ = machine.press(at: 10)
        _ = machine.holdCheck(at: 10.3)
        machine.holdEnabled = false
        XCTAssertEqual(machine.release(at: 11), [.holdEnded])
    }
}

@MainActor
final class GlobalShortcutRouterTests: XCTestCase {
    private final class Recorder {
        var events: [String] = []
    }

    private func makeRouter(_ recorder: Recorder) -> GlobalShortcutRouter {
        GlobalShortcutRouter(onTap: { recorder.events.append("tap") },
                             onHoldBegan: { recorder.events.append("holdBegan") },
                             onHoldEnded: { recorder.events.append("holdEnded") })
    }

    func testHoldDisabledTapsOnPress() {
        let recorder = Recorder()
        let router = makeRouter(recorder)
        XCTAssertFalse(router.holdEnabled)
        router.pressed()
        XCTAssertEqual(recorder.events, ["tap"], "no added latency with hold-to-talk off")
        router.released()
        XCTAssertEqual(recorder.events, ["tap"])
    }

    func testHoldEnabledQuickPressTapsOnRelease() async throws {
        let recorder = Recorder()
        let router = makeRouter(recorder)
        router.holdEnabled = true
        router.pressed()
        XCTAssertEqual(recorder.events, [])
        router.released()
        XCTAssertEqual(recorder.events, ["tap"])
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(recorder.events, ["tap"], "the cancelled hold check never fires")
    }

    func testHoldEnabledLongPressBeginsAndEndsAHold() async throws {
        let recorder = Recorder()
        let router = makeRouter(recorder)
        router.holdEnabled = true
        router.pressed()
        let deadline = Date().addingTimeInterval(3)
        while recorder.events.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(recorder.events, ["holdBegan"])
        router.released()
        XCTAssertEqual(recorder.events, ["holdBegan", "holdEnded"])
    }
}
