//
//  GlanceResolverTests.swift
//  OttoTests
//
//  The §4.2 priority table: each row on its own, every pair of rows (the higher one wins), and every
//  combination of conditions (the first matching row decides everything).
//

import XCTest
@testable import Otto

final class GlanceResolverTests: XCTestCase {
    /// Rows 1–9 of §4.2 (row 10 is "nothing set").
    private enum Row: Int, CaseIterable {
        case listening = 1, systemWait, approval, flash, preview, phase, speaking, unread, media
    }

    private let preview = ReplyPreview(id: UUID(), outcome: .answered, text: "Here's the plan for Tuesday.")
    private let media = NowPlayingItem(id: "com.apple.Music|42", player: .music, title: "Clair de Lune",
                                       artist: "Debussy", album: "Suite", duration: 300, position: 12,
                                       positionDate: Date(timeIntervalSince1970: 0), state: .playing, artworkURL: nil)
    private let wait = SystemUIWait.systemSettings(.calendars)
    private let phase = ReplyPhase.searching(label: "Searching the web")

    private func inputs(_ rows: Set<Row>) -> GlanceInputs {
        GlanceInputs(
            isListening: rows.contains(.listening),
            systemWait: rows.contains(.systemWait) ? wait : nil,
            approvalTitle: rows.contains(.approval) ? "Add “Dentist” to Calendar" : nil,
            flash: rows.contains(.flash) ? .pasted(appName: "Notes") : nil,
            preview: rows.contains(.preview) ? preview : nil,
            phase: rows.contains(.phase) ? phase : .idle,
            isSpeaking: rows.contains(.speaking),
            hasUnreadReply: rows.contains(.unread),
            media: rows.contains(.media) ? media : nil
        )
    }

    /// What row `row` shows (left, right, drop), given whether speech is also active.
    private func expected(_ row: Row?, speaking: Bool) -> (EarGlyph, EarGlyph, DropContent?) {
        switch row {
        case .listening?: return (.none, .none, nil)
        case .systemWait?: return (.orb(active: true), .systemWait, .systemWait("Waiting for System Settings…"))
        case .approval?: return (.orb(active: true), .approval, .approval(label: "Add “Dentist” to Calendar"))
        case .flash?: return (.orb(active: false), .checkmark, nil)
        case .preview?: return (.orb(active: false), speaking ? .speaking : .unreadDot, .preview(preview))
        case .phase?: return (.orb(active: true), speaking ? .speaking : .phase(phase), nil)
        case .speaking?: return (.orb(active: false), .speaking, nil)
        case .unread?: return (.orb(active: false), .unreadDot, nil)
        case .media?: return (.artwork(media.id), .equalizer, nil)
        case nil: return (.none, .none, nil)
        }
    }

    private func assertResolves(_ rows: Set<Row>, file: StaticString = #filePath, line: UInt = #line) {
        let winner = rows.min { $0.rawValue < $1.rawValue }
        let glance = GlanceResolver.resolve(inputs(rows))
        let (left, right, drop) = expected(winner, speaking: rows.contains(.speaking))
        let names = rows.map(\.rawValue).sorted()
        XCTAssertEqual(glance.left, left, "rows \(names)", file: file, line: line)
        XCTAssertEqual(glance.right, right, "rows \(names)", file: file, line: line)
        XCTAssertEqual(glance.drop, drop, "rows \(names)", file: file, line: line)
        XCTAssertFalse(glance.accessibilityLabel.isEmpty, "rows \(names)", file: file, line: line)
    }

    func testEachRowAlone() {
        for row in Row.allCases {
            assertResolves([row])
        }
        assertResolves([])
    }

    func testEveryPairHigherRowWins() {
        for first in Row.allCases {
            for second in Row.allCases where second.rawValue > first.rawValue {
                assertResolves([first, second])
            }
        }
    }

    func testEveryCombinationFirstMatchWins() {
        let all = Row.allCases
        for mask in 0..<(1 << all.count) {
            let rows = Set(all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            assertResolves(rows)
        }
    }

    func testNothingShowsNoEars() {
        let glance = GlanceResolver.resolve(GlanceInputs())
        XCTAssertEqual(glance, ClosedGlance())
        XCTAssertFalse(glance.hasEars)
        XCTAssertNil(glance.drop)
    }

    func testListeningHasNoEarsOrDrop() {
        let glance = GlanceResolver.resolve(inputs([.listening, .systemWait, .approval, .preview]))
        XCTAssertFalse(glance.hasEars)
        XCTAssertNil(glance.drop)
        XCTAssertEqual(glance.accessibilityLabel, "Otto is listening")
    }

    func testSystemWaitRowUsesEachWaitsDropText() {
        let waits: [SystemUIWait] = [.systemSettings(.accessibility), .systemPrompt(.microphone),
                                     .toolDialog(appName: "Finder"), .toolRun(title: "Running “Resize Images”…")]
        for wait in waits {
            var input = inputs([.approval, .preview, .phase])
            input.systemWait = wait
            let glance = GlanceResolver.resolve(input)
            XCTAssertEqual(glance.left, .orb(active: true))
            XCTAssertEqual(glance.right, .systemWait)
            XCTAssertEqual(glance.drop, .systemWait(wait.dropText))
            XCTAssertEqual(glance.drop?.text, wait.dropText)
            XCTAssertTrue(glance.accessibilityLabel.contains(wait.dropText))
        }
    }

    func testApprovalDropText() {
        XCTAssertEqual(DropContent.approval(label: "Run “Wipe Downloads”").text, "Needs your OK · Run “Wipe Downloads”")
        XCTAssertEqual(DropContent.approval(label: "  ").text, "Needs your OK")
        XCTAssertEqual(DropContent.approval(label: "Evil\u{202E}txt").text, "Needs your OK · Eviltxt")
        let glance = GlanceResolver.resolve(inputs([.approval]))
        XCTAssertEqual(glance.accessibilityLabel, "Otto needs your OK: Add “Dentist” to Calendar")
    }

    func testPhaseGlyphForEveryActivePhase() {
        let phases: [ReplyPhase] = [.connecting, .thinking, .searching(label: "a"), .writing,
                                    .runningAction(label: "b"), .awaitingApproval(label: "c")]
        for phase in phases {
            let glance = GlanceResolver.resolve(GlanceInputs(phase: phase))
            XCTAssertEqual(glance.left, .orb(active: true))
            XCTAssertEqual(glance.right, .phase(phase))
            XCTAssertTrue(glance.accessibilityLabel.hasPrefix("Otto"))
        }
    }

    func testPreviewLabelsFollowTheOutcome() {
        let id = UUID()
        let answered = GlanceResolver.resolve(GlanceInputs(preview: ReplyPreview(id: id, outcome: .answered, text: "Yes.")))
        let failed = GlanceResolver.resolve(GlanceInputs(preview: ReplyPreview(id: id, outcome: .failed, text: "Offline.")))
        let refused = GlanceResolver.resolve(GlanceInputs(preview: ReplyPreview(id: id, outcome: .refused, text: "No.")))
        XCTAssertEqual(answered.accessibilityLabel, "Otto replied: Yes.")
        XCTAssertEqual(failed.accessibilityLabel, "Otto couldn't finish: Offline.")
        XCTAssertEqual(refused.accessibilityLabel, "Otto declined: No.")
    }

    func testMediaLabelIsSanitized() {
        var item = media
        item.title = "Track\u{202E}Name"
        let glance = GlanceResolver.resolve(GlanceInputs(media: item))
        XCTAssertEqual(glance.accessibilityLabel, "Playing TrackName by Debussy")
    }
}
