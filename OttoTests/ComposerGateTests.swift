//
//  ComposerGateTests.swift
//  OttoTests
//
//  The flavor-neutral gate values (equality and identity), the backstop error, and the usage-report throttle the
//  Setapp build uses.
//

import XCTest
@testable import Otto

final class ComposerGateTests: XCTestCase {
    private func makeGate(id: String = "trial-ended", message: String = "Your 14-day trial has ended.") -> ComposerGate {
        ComposerGate(id: id, symbol: "hourglass", message: message, choices: [
            ComposerGate.Choice(title: "Buy a License",
                                action: .openURL(URL(string: "https://otto.example.test/buy")!), isPrimary: true),
            ComposerGate.Choice(title: "Enter License", action: .openSettings(.general, nil), isPrimary: false),
        ])
    }

    func testGatesCompareByValueAndIdentifyByID() {
        XCTAssertEqual(makeGate(), makeGate())
        XCTAssertEqual(makeGate().id, "trial-ended")
        XCTAssertNotEqual(makeGate(), makeGate(id: "license-removed"))
        XCTAssertNotEqual(makeGate(), makeGate(message: "This Mac no longer has a license."))
        XCTAssertEqual(makeGate().choices.filter(\.isPrimary).count, 1)
    }

    func testActionsCompareByPayload() {
        XCTAssertEqual(ComposerGate.Action.gate("check-now"), .gate("check-now"))
        XCTAssertNotEqual(ComposerGate.Action.gate("check-now"), .gate("other"))
        XCTAssertNotEqual(ComposerGate.Action.openSettings(.general, nil), .openSettings(.general, .usage))
        XCTAssertNotEqual(ComposerGate.Action.openURL(URL(string: "https://a.example.test")!),
                          .openURL(URL(string: "https://b.example.test")!))
    }

    func testBackstopErrorCarriesTheGateMessage() {
        let error = ComposerGateError(message: "Your 14-day trial has ended.")
        XCTAssertEqual(error.errorDescription, "Your 14-day trial has ended.")
        XCTAssertEqual(error.localizedDescription, "Your 14-day trial has ended.")
        XCTAssertEqual(error, ComposerGateError(message: "Your 14-day trial has ended."))
    }

    // MARK: - UsageReportThrottle

    func testFirstReportIsAllowedAndRecorded() {
        var throttle = UsageReportThrottle()
        XCTAssertNil(throttle.lastReportAt)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(throttle.shouldReport(now: now))
        XCTAssertEqual(throttle.lastReportAt, now)
    }

    func testReportsUnderFiveMinutesApartAreRefused() {
        var throttle = UsageReportThrottle()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(throttle.shouldReport(now: start))
        XCTAssertFalse(throttle.shouldReport(now: start.addingTimeInterval(1)))
        XCTAssertFalse(throttle.shouldReport(now: start.addingTimeInterval(299.9)))
        // A refused attempt doesn't move the window.
        XCTAssertEqual(throttle.lastReportAt, start)
    }

    func testReportsFiveMinutesApartAreAllowed() {
        var throttle = UsageReportThrottle()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(UsageReportThrottle.minimumInterval, 300)
        XCTAssertTrue(throttle.shouldReport(now: start))
        XCTAssertTrue(throttle.shouldReport(now: start.addingTimeInterval(300)))
        XCTAssertEqual(throttle.lastReportAt, start.addingTimeInterval(300))
        XCTAssertFalse(throttle.shouldReport(now: start.addingTimeInterval(400)))
        XCTAssertTrue(throttle.shouldReport(now: start.addingTimeInterval(3_600)))
    }

    func testAClockSetBackDelaysReportingByAtMostOneInterval() {
        var throttle = UsageReportThrottle()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(throttle.shouldReport(now: start))
        XCTAssertFalse(throttle.shouldReport(now: start.addingTimeInterval(-60)))
        XCTAssertTrue(throttle.shouldReport(now: start.addingTimeInterval(-86_400)))
    }
}
