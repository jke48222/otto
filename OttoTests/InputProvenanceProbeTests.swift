//
//  InputProvenanceProbeTests.swift
//  OttoTests
//
//  Gate H1 probe (interactive, skipped by default). Shows a small window and records the source
//  process id and auto-repeat flag of a real click, a real ⌘↩ and a ⌘↩ posted by System Events, so
//  a person can confirm on a notched Mac that hardware input carries pid 0 and synthetic input
//  doesn't. Run it with:
//
//      TEST_RUNNER_OTTO_PROVENANCE_PROBE=1 xcodebuild … test -only-testing:OttoTests/InputProvenanceProbeTests
//

import AppKit
import os
import XCTest
@testable import Otto

@MainActor
final class InputProvenanceProbeTests: XCTestCase {
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Input")
    /// How long each step waits for the person.
    private static let stepTimeout: TimeInterval = 120

    func testHardwareAndSyntheticInputProvenance() throws {
        guard ProcessInfo.processInfo.environment["OTTO_PROVENANCE_PROBE"] == "1" else {
            throw XCTSkip("Interactive gate H1 probe. Run with TEST_RUNNER_OTTO_PROVENANCE_PROBE=1.")
        }

        let view = ProvenanceProbeView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Otto input provenance probe"
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate()
        defer { window.close() }

        view.instruction = "1 of 3: click inside this window."
        report("Probe step 1 of 3: click inside the probe window.")
        let click = try waitForEvent(on: view) { $0.type == .leftMouseDown }

        view.instruction = "2 of 3: press ⌘↩ on this Mac's keyboard."
        report("Probe step 2 of 3: press Command-Return on this Mac's keyboard.")
        let keyPress = try waitForEvent(on: view) { Self.isCommandReturn($0) }

        let pid = ProcessInfo.processInfo.processIdentifier
        let command = "osascript -e 'tell application \"System Events\" to set frontmost of "
            + "(first process whose unix id is \(pid)) to true' -e 'delay 0.5' "
            + "-e 'tell application \"System Events\" to keystroke return using command down'"
        view.instruction = "3 of 3: run the osascript line from the test log in Terminal."
        report("Probe step 3 of 3: run this line in Terminal (it brings the probe forward and posts ⌘↩):\n\(command)")
        let posted = try waitForEvent(on: view) { Self.isCommandReturn($0) }

        let results = [("click", click), ("⌘↩ keyboard", keyPress), ("⌘↩ System Events", posted)]
        for (label, event) in results {
            let sourcePID = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
            let evidence = InputProvenance.evidence(for: event, mouseDown: nil)
            let repeatFlag = event.type == .keyDown ? event.isARepeat : false
            report("\(label): eventSourceUnixProcessID=\(sourcePID) isARepeat=\(repeatFlag) "
                   + "isHardware=\(evidence.isHardware)")
        }

        XCTAssertEqual(click.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID), 0,
                       "a real click should carry source pid 0")
        XCTAssertEqual(keyPress.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID), 0,
                       "a real key press should carry source pid 0")
        XCTAssertFalse(keyPress.isARepeat)
        XCTAssertNotEqual(posted.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID), 0,
                          "a key posted by System Events should carry its process id")
        XCTAssertFalse(InputProvenance.evidence(for: posted, mouseDown: nil).isHardware)
    }

    // MARK: - Private

    private static func isCommandReturn(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == 36
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    private func waitForEvent(on view: ProvenanceProbeView, matching predicate: (NSEvent) -> Bool) throws -> NSEvent {
        let start = view.events.count
        let deadline = Date().addingTimeInterval(Self.stepTimeout)
        while Date() < deadline {
            if let event = view.events.dropFirst(start).first(where: predicate) { return event }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("No matching input within \(Int(Self.stepTimeout)) seconds")
        throw XCTSkip("The probe step timed out.")
    }

    /// Both the unified log and the xcodebuild output, so the person running the gate sees it.
    private func report(_ message: String) {
        Self.logger.notice("\(message, privacy: .public)")
        print(message)
    }
}

/// Records every mouse-down and key-down it receives, including ⌘-key equivalents.
private final class ProvenanceProbeView: NSView {
    private(set) var events: [NSEvent] = []
    private let label = NSTextField(wrappingLabelWithString: "")

    var instruction: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.frame = bounds.insetBy(dx: 24, dy: 24)
        label.autoresizingMask = [.width, .height]
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        events.append(event)
    }

    override func keyDown(with event: NSEvent) {
        events.append(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        events.append(event)
        return true
    }
}
