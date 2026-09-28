//
//  ComposerGateLineTests.swift
//  OttoTests
//
//  The composer gate line: its fixed height, the order and style of its choices (the primary capsule first),
//  what VoiceOver reads, no pulse with Reduce Motion, and that it lays out at the notch's width with zero, one
//  or two choices and a message too long for one line.
//

import AppKit
import SwiftUI
import XCTest
@testable import Otto

@MainActor
final class ComposerGateLineTests: XCTestCase {
    private let buyURL = URL(string: "https://otto-fixture.test/buy") ?? URL(fileURLWithPath: "/")

    private var buy: ComposerGate.Choice {
        ComposerGate.Choice(title: "Buy a License", action: .openURL(buyURL), isPrimary: true)
    }

    private func enter(isPrimary: Bool) -> ComposerGate.Choice {
        ComposerGate.Choice(title: "Enter License", action: .openSettings(.general, nil), isPrimary: isPrimary)
    }

    private func gate(_ choices: [ComposerGate.Choice], message: String = "Your 14-day trial has ended.")
        -> ComposerGate {
        ComposerGate(id: "trial-ended", symbol: "hourglass", message: message, choices: choices)
    }

    // MARK: - Metrics

    func testHeightAndCapsuleSize() {
        XCTAssertEqual(ComposerGateLine.height, 30)
        XCTAssertEqual(ComposerGateLine.primaryHeight, 22)
        XCTAssertEqual(ComposerGateLine.horizontalPadding, 16)
    }

    // MARK: - Choices

    func testPrimaryComesFirstAsTheCapsuleAndTheSecondaryIsText() {
        let choices = ComposerGateLine.orderedChoices(gate([enter(isPrimary: false), buy]))

        XCTAssertEqual(choices.map(\.title), ["Buy a License", "Enter License"])
        XCTAssertEqual(choices.map(ComposerGateLine.style(for:)), [.primaryCapsule, .text])
    }

    func testChoiceOrderIsKeptWhenThePrimaryIsAlreadyFirst() {
        let checkNow = ComposerGate.Choice(title: "Check Now", action: .gate("check-now"), isPrimary: true)
        let choices = ComposerGateLine.orderedChoices(gate([checkNow, enter(isPrimary: false)]))

        XCTAssertEqual(choices.map(\.title), ["Check Now", "Enter License"])
        XCTAssertEqual(choices.first?.action, .gate("check-now"))
    }

    func testAtMostTwoChoicesAndOnePrimary() {
        let extra = ComposerGate.Choice(title: "Check Now", action: .gate("check-now"), isPrimary: true)
        let choices = ComposerGateLine.orderedChoices(gate([enter(isPrimary: false), buy, extra]))

        XCTAssertEqual(choices.count, 2)
        XCTAssertEqual(choices.filter(\.isPrimary).count, 1, "a second primary never draws a second capsule")
        XCTAssertEqual(choices.map(\.title), ["Buy a License", "Enter License"])
    }

    func testAGateWithoutChoicesDrawsNone() {
        XCTAssertTrue(ComposerGateLine.orderedChoices(gate([], message: "Checking your license…")).isEmpty)
    }

    func testTheLicenseGatesKeepTheirPrimaryFirst() {
        let removed = ComposerGate(id: "license-removed", symbol: "key", message: "This Mac no longer has a license.",
                                   choices: [enter(isPrimary: true),
                                             ComposerGate.Choice(title: "Buy a License", action: .openURL(buyURL),
                                                                 isPrimary: false)])
        XCTAssertEqual(ComposerGateLine.orderedChoices(removed).map(ComposerGateLine.style(for:)),
                       [.primaryCapsule, .text])
        XCTAssertEqual(ComposerGateLine.orderedChoices(removed).map(\.title), ["Enter License", "Buy a License"])
    }

    // MARK: - Accessibility and motion

    func testAccessibilityLabelIsTheMessage() {
        XCTAssertEqual(ComposerGateLine.accessibilityLabel(for: gate([buy])), "Your 14-day trial has ended.")
        let check = ComposerGate(id: "check-required", symbol: "wifi.exclamationmark",
                                 message: "Otto needs to check your license before it can send.", choices: [])
        XCTAssertEqual(ComposerGateLine.accessibilityLabel(for: check),
                       "Otto needs to check your license before it can send.")
    }

    func testNoPulseWithReduceMotion() {
        XCTAssertNil(ComposerGateLine.pulseAnimation(reduceMotion: true))
        XCTAssertNotNil(ComposerGateLine.pulseAnimation(reduceMotion: false))
        XCTAssertEqual(ComposerGateLine.pulseDuration, .milliseconds(600))
    }

    // MARK: - Layout

    func testLaysOutAtItsHeightWithZeroOneAndTwoChoices() async throws {
        let long = String(repeating: "Sending is paused until the license check finishes. ", count: 4)
        let gates = [
            gate([buy, enter(isPrimary: false)]),
            gate([buy]),
            gate([], message: "Activating your license…"),
            gate([buy, enter(isPrimary: false)], message: long),
        ]
        for (index, value) in gates.enumerated() {
            var chosen: [String] = []
            let line = ComposerGateLine(gate: value, attention: index) { chosen.append($0.title) }
            let host = try await host(line, width: 540)
            XCTAssertEqual(host.fittingSize.height, ComposerGateLine.height, accuracy: 0.5, "gate \(index)")
            XCTAssertTrue(chosen.isEmpty, "laying out never picks a choice")
        }
    }

    func testAttentionBumpsKeepTheLineInPlace() async throws {
        let value = gate([buy, enter(isPrimary: false)])
        let host = NSHostingView(rootView: ComposerGateLine(gate: value, attention: 0) { _ in })
        let window = makeWindow(host, width: 540)
        defer { close(window) }
        host.layoutSubtreeIfNeeded()

        for attention in 1...3 {
            host.rootView = ComposerGateLine(gate: value, attention: attention) { _ in }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, ComposerGateLine.height, accuracy: 0.5)
    }

    // MARK: - Helpers

    private func host<V: View>(_ view: V, width: CGFloat) async throws -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        let window = makeWindow(host, width: width)
        defer { close(window) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return host
    }

    private func makeWindow(_ host: NSView, width: CGFloat) -> NSWindow {
        let size = NSSize(width: width, height: ComposerGateLine.height)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        return window
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
    }
}
