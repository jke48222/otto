//
//  GlanceComponentsTests.swift
//  OttoTests
//
//  The pure rules behind the glance components: GlyphClock frames (constant with Reduce Motion), which
//  glyph each EarGlyph draws (incl. systemWait) and when its timeline ticks, the drop's icon, the Now
//  Playing strip's extrapolated progress, seeking and caption, the next-meeting chip's width rule and
//  tooltip, the glance row's layout, the answer cost label and the Usage menu rows. A render pass checks
//  every glyph stays inside its box.
//

import AppKit
import SwiftUI
import XCTest
@testable import Otto

// MARK: - GlyphClock

final class GlyphClockTests: XCTestCase {
    func testReduceMotionReturnsTheSameStillFrameAtEveryDate() {
        let dates = [
            Date(timeIntervalSinceReferenceDate: 0),
            Date(timeIntervalSinceReferenceDate: 0.017),
            Date(timeIntervalSinceReferenceDate: 812_345_678.9),
            Date(),
            Date.distantFuture,
        ]
        let frames = dates.map { GlyphClock.frame(at: $0, reduceMotion: true) }
        for frame in frames {
            XCTAssertEqual(frame, GlyphClock.still)
            XCTAssertTrue(frame.isStill)
        }
    }

    func testStillFrameHoldsEveryLoopAtItsStart() {
        let still = GlyphClock.frame(at: Date(), reduceMotion: true)
        XCTAssertEqual(still.progress(period: 1.2), 0)
        XCTAssertEqual(still.progress(period: 1.6, offset: 0.4), 0)
        XCTAssertEqual(still.wave(period: 2.1), 0)
    }

    func testFramesSnapToThirtyPerSecond() {
        let base = 800_000_000.0
        let first = GlyphClock.frame(at: Date(timeIntervalSinceReferenceDate: base + 0.001), reduceMotion: false)
        let sameFrame = GlyphClock.frame(at: Date(timeIntervalSinceReferenceDate: base + 0.03), reduceMotion: false)
        let nextFrame = GlyphClock.frame(at: Date(timeIntervalSinceReferenceDate: base + 0.034), reduceMotion: false)

        XCTAssertFalse(first.isStill)
        XCTAssertEqual(first, sameFrame)
        XCTAssertNotEqual(first, nextFrame)
        XCTAssertEqual(nextFrame.time - first.time, 1.0 / 30.0, accuracy: 1e-6)
        XCTAssertEqual(GlyphClock.frameInterval, 1.0 / 30.0, accuracy: 1e-12)
    }

    func testMovingFramesChangeOverTime() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let later = start.addingTimeInterval(0.3)
        let a = GlyphClock.frame(at: start, reduceMotion: false)
        let b = GlyphClock.frame(at: later, reduceMotion: false)
        XCTAssertNotEqual(a.progress(period: 1.2), b.progress(period: 1.2))
    }

    func testProgressStaysInsideTheLoop() {
        for step in 0..<200 {
            let frame = GlyphClock.frame(at: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(step) * 0.037),
                                         reduceMotion: false)
            for period in [0.88, 1.2, 1.6, 2.0] {
                let progress = frame.progress(period: period, offset: -0.2)
                XCTAssertGreaterThanOrEqual(progress, 0)
                XCTAssertLessThan(progress, 1)
                let wave = frame.wave(period: period)
                XCTAssertGreaterThanOrEqual(wave, 0)
                XCTAssertLessThanOrEqual(wave, 1)
            }
        }
    }

    func testNonPositivePeriodIsSafe() {
        let frame = GlyphClock.frame(at: Date(timeIntervalSinceReferenceDate: 12.5), reduceMotion: false)
        XCTAssertEqual(frame.progress(period: 0), 0)
        XCTAssertEqual(frame.progress(period: -1), 0)
    }
}

// MARK: - Ear glyphs

final class EarGlyphSelectionTests: XCTestCase {
    func testEveryEarGlyphMapsToItsDrawing() {
        XCTAssertEqual(EarGlyphView.kind(for: .none), .none)
        XCTAssertEqual(EarGlyphView.kind(for: .orb(active: true)), .orb(active: true))
        XCTAssertEqual(EarGlyphView.kind(for: .orb(active: false)), .orb(active: false))
        XCTAssertEqual(EarGlyphView.kind(for: .unreadDot), .unreadDot)
        XCTAssertEqual(EarGlyphView.kind(for: .approval), .approval)
        XCTAssertEqual(EarGlyphView.kind(for: .checkmark), .checkmark)
        XCTAssertEqual(EarGlyphView.kind(for: .speaking), .speaking)
        XCTAssertEqual(EarGlyphView.kind(for: .artwork("com.spotify.client|abc")), .artwork("com.spotify.client|abc"))
        XCTAssertEqual(EarGlyphView.kind(for: .equalizer), .equalizer)
        XCTAssertEqual(EarGlyphView.kind(for: .systemWait), .systemWait)
    }

    func testEveryPhaseMapsToItsGlyph() {
        XCTAssertEqual(EarGlyphView.kind(for: .phase(.idle)), .none)
        XCTAssertEqual(EarGlyphView.kind(for: .phase(.connecting)), .thinkingDots(isSlow: true))
        XCTAssertEqual(EarGlyphView.kind(for: .phase(.thinking)), .thinkingDots(isSlow: false))
        XCTAssertEqual(EarGlyphView.kind(for: .phase(.searching(label: "Searching the web"))), .search)
        XCTAssertEqual(EarGlyphView.kind(for: .phase(.writing)), .writing)
        XCTAssertEqual(EarGlyphView.kind(for: .phase(.runningAction(label: "Adding “Standup”"))), .action)
        XCTAssertEqual(EarGlyphView.kind(for: .phase(.awaitingApproval(label: "Run “Resize”"))), .approval)
    }

    func testLabelsDoNotChangeTheGlyph() {
        // A new search label mustn't restart the glyph's cross-fade.
        XCTAssertEqual(EarGlyphView.kind(for: .phase(.searching(label: "a"))),
                       EarGlyphView.kind(for: .phase(.searching(label: "b"))))
        XCTAssertEqual(EarGlyphView.kind(for: .phase(.runningAction(label: "a"))),
                       EarGlyphView.kind(for: .phase(.runningAction(label: "b"))))
    }

    func testGlyphsFitTheEarBox() {
        let limit = CGSize(width: 14, height: 13)
        XCTAssertEqual(EarGlyphView.glyphSize, limit)
        for kind in allKinds where kind != .artwork("x") {
            XCTAssertLessThanOrEqual(kind.size.width, limit.width, "\(kind)")
            XCTAssertLessThanOrEqual(kind.size.height, limit.height, "\(kind)")
        }
        XCTAssertEqual(EarGlyphView.Kind.artwork("x").size, CGSize(width: 16, height: 16))
        XCTAssertEqual(EarGlyphView.Kind.none.size, .zero)
    }

    func testTimelineTicksOnlyForVisibleMovingGlyphsWithoutReduceMotion() {
        for kind in allKinds {
            XCTAssertFalse(EarGlyphView.isTicking(kind, isVisible: false, reduceMotion: false), "hidden \(kind)")
            XCTAssertFalse(EarGlyphView.isTicking(kind, isVisible: true, reduceMotion: true), "reduce motion \(kind)")
        }
        let moving: [EarGlyphView.Kind] = [.orb(active: true), .thinkingDots(isSlow: true), .thinkingDots(isSlow: false),
                                           .search, .writing, .action, .approval, .speaking, .equalizer, .systemWait]
        for kind in moving {
            XCTAssertTrue(EarGlyphView.isTicking(kind, isVisible: true, reduceMotion: false), "\(kind)")
        }
        let still: [EarGlyphView.Kind] = [.none, .orb(active: false), .unreadDot, .checkmark, .artwork("x")]
        for kind in still {
            XCTAssertFalse(EarGlyphView.isTicking(kind, isVisible: true, reduceMotion: false), "\(kind)")
        }
    }

    private var allKinds: [EarGlyphView.Kind] {
        [.none, .orb(active: true), .orb(active: false), .thinkingDots(isSlow: true), .thinkingDots(isSlow: false),
         .search, .writing, .action, .approval, .unreadDot, .checkmark, .speaking, .artwork("x"), .equalizer,
         .systemWait]
    }
}

@MainActor
final class EarGlyphRenderTests: XCTestCase {
    func testEveryGlyphRendersInsideItsBox() throws {
        let settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        let monitor = NowPlayingMonitor(settings: settings, scripting: DemoMediaScripting())
        let glyphs: [EarGlyph] = [
            .orb(active: true), .orb(active: false), .phase(.connecting), .phase(.thinking),
            .phase(.searching(label: "Searching")), .phase(.writing), .phase(.runningAction(label: "Run")),
            .phase(.awaitingApproval(label: "Run")), .unreadDot, .approval, .checkmark, .speaking,
            .artwork("none"), .equalizer, .systemWait,
        ]
        for glyph in glyphs {
            for reduceMotion in [true, false] {
                let view = EarGlyphView(glyph: glyph, nowPlaying: monitor, reduceMotion: reduceMotion, isVisible: false)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage, "\(glyph)")
                XCTAssertLessThanOrEqual(CGFloat(image.width) / 2, 16, "\(glyph)")
                XCTAssertLessThanOrEqual(CGFloat(image.height) / 2, 16, "\(glyph)")
            }
        }
    }
}

// MARK: - Drop

final class ReplyPreviewDropTests: XCTestCase {
    func testIconPerDropContent() {
        let id = UUID()
        XCTAssertEqual(ReplyPreviewDrop.icon(for: .preview(ReplyPreview(id: id, outcome: .answered, text: "Hi"))), .answered)
        XCTAssertEqual(ReplyPreviewDrop.icon(for: .preview(ReplyPreview(id: id, outcome: .failed, text: "No"))), .failed)
        XCTAssertEqual(ReplyPreviewDrop.icon(for: .preview(ReplyPreview(id: id, outcome: .refused, text: "No"))), .refused)
        XCTAssertEqual(ReplyPreviewDrop.icon(for: .approval(label: "Run “Resize”")), .approval)
        XCTAssertEqual(ReplyPreviewDrop.icon(for: .systemWait("Waiting for System Settings…")), .systemWait)
    }

    func testAccessibilityLabels() {
        let preview = ReplyPreview(id: UUID(), outcome: .answered, text: "Swift actors isolate state.")
        XCTAssertEqual(ReplyPreviewDrop.accessibilityLabel(for: .preview(preview)), "Otto replied: Swift actors isolate state.")
        XCTAssertEqual(ReplyPreviewDrop.accessibilityLabel(for: .approval(label: "Run “Resize”")), "Needs your OK · Run “Resize”")
        XCTAssertEqual(ReplyPreviewDrop.accessibilityLabel(for: .systemWait("Answer the macOS prompt to continue")),
                       "Answer the macOS prompt to continue")
    }
}

// MARK: - Now Playing strip

final class NowPlayingStripRulesTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(state: PlaybackState = .playing, position: TimeInterval? = 30,
                      duration: TimeInterval? = 200, artist: String = "Marlow Vey",
                      player: MediaPlayer = .spotify) -> NowPlayingItem {
        NowPlayingItem(id: "\(player.rawValue)|t", player: player, title: "Low Tide", artist: artist, album: "Demo",
                       duration: duration, position: position, positionDate: anchor, state: state, artworkURL: nil)
    }

    func testProgressExtrapolatesWhilePlaying() throws {
        let playing = item()
        XCTAssertEqual(try XCTUnwrap(NowPlayingStrip.progress(of: playing, at: anchor)), 30.0 / 200, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(NowPlayingStrip.progress(of: playing, at: anchor.addingTimeInterval(10))),
                       40.0 / 200, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(NowPlayingStrip.progress(of: playing, at: anchor.addingTimeInterval(70))),
                       100.0 / 200, accuracy: 1e-9)
    }

    func testProgressHoldsWhilePaused() throws {
        let paused = item(state: .paused)
        XCTAssertEqual(try XCTUnwrap(NowPlayingStrip.progress(of: paused, at: anchor.addingTimeInterval(120))),
                       30.0 / 200, accuracy: 1e-9)
    }

    func testProgressClampsToTheTrack() throws {
        XCTAssertEqual(try XCTUnwrap(NowPlayingStrip.progress(of: item(), at: anchor.addingTimeInterval(10_000))), 1)
        XCTAssertEqual(try XCTUnwrap(NowPlayingStrip.progress(of: item(), at: anchor.addingTimeInterval(-10_000))), 0)
    }

    func testProgressNeedsAPositionAndADuration() {
        XCTAssertNil(NowPlayingStrip.progress(of: item(position: nil), at: anchor))
        XCTAssertNil(NowPlayingStrip.progress(of: item(duration: nil), at: anchor))
        XCTAssertNil(NowPlayingStrip.progress(of: item(duration: 0), at: anchor))
    }

    func testSeekingNeedsConsentAndADuration() {
        XCTAssertTrue(NowPlayingStrip.canSeek(item(), consent: .authorized))
        XCTAssertFalse(NowPlayingStrip.canSeek(item(), consent: .wouldPrompt))
        XCTAssertFalse(NowPlayingStrip.canSeek(item(), consent: .denied))
        XCTAssertFalse(NowPlayingStrip.canSeek(item(), consent: nil))
        XCTAssertFalse(NowPlayingStrip.canSeek(item(duration: nil), consent: .authorized))
    }

    func testSeekTargetClampsToTheTrack() {
        XCTAssertEqual(NowPlayingStrip.seekTarget(fraction: 0.25, duration: 200), 50)
        XCTAssertEqual(NowPlayingStrip.seekTarget(fraction: -1, duration: 200), 0)
        XCTAssertEqual(NowPlayingStrip.seekTarget(fraction: 3, duration: 200), 200)
        XCTAssertEqual(NowPlayingStrip.seekTarget(fraction: .nan, duration: 200), 0)
        XCTAssertEqual(NowPlayingStrip.seekTarget(fraction: 0.5, duration: 0), 0)
    }

    func testCaptionPrecedence() {
        let spotify = item()
        XCTAssertNil(NowPlayingStrip.caption(for: spotify, consent: .authorized, lastControlError: nil,
                                             isAwaitingConsent: false))
        XCTAssertEqual(NowPlayingStrip.caption(for: spotify, consent: .denied, lastControlError: "Spotify didn't respond.",
                                               isAwaitingConsent: true),
                       .awaitingConsent("Allow Otto to control Spotify in the dialog."))
        XCTAssertEqual(NowPlayingStrip.caption(for: spotify, consent: .denied, lastControlError: nil,
                                               isAwaitingConsent: false),
                       .denied("Otto isn't allowed to control Spotify."))
        XCTAssertEqual(NowPlayingStrip.caption(for: spotify, consent: .authorized, lastControlError: "Spotify didn't respond.",
                                               isAwaitingConsent: false),
                       .failed("Spotify didn't respond."))
    }

    func testSubtitleAndClock() {
        XCTAssertEqual(NowPlayingStrip.subtitle(for: item()), "Marlow Vey · Spotify")
        XCTAssertEqual(NowPlayingStrip.subtitle(for: item(artist: "", player: .music)), "Music")
        XCTAssertEqual(NowPlayingStrip.clockText(0), "0:00")
        XCTAssertEqual(NowPlayingStrip.clockText(187.9), "3:07")
        XCTAssertEqual(NowPlayingStrip.clockText(3723), "1:02:03")
        XCTAssertEqual(NowPlayingStrip.clockText(-4), "0:00")
        XCTAssertEqual(NowPlayingStrip.clockText(.infinity), "0:00")
    }
}

// MARK: - Next-meeting chip and glance row

final class NextEventChipRulesTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func glance(link: URL?) -> EventGlance {
        let event = CalendarEventSnapshot(id: "e|1", title: "Standup", start: start, end: start.addingTimeInterval(15 * 60),
                                          colorRGBA: [0.2, 0.4, 0.8, 1], isAllDay: false, isCanceled: false,
                                          isDeclined: false, meetingLink: link)
        return EventGlance(event: event, chipSuffix: "12m", spokenText: "Standup in 12 minutes", isImminent: false)
    }

    func testChipHidesBelowSixtyFourPoints() {
        XCTAssertEqual(NextEventChip.minimumWidth, 64)
        XCTAssertFalse(NextEventChip.isShown(maxWidth: 0))
        XCTAssertFalse(NextEventChip.isShown(maxWidth: 63.5))
        XCTAssertTrue(NextEventChip.isShown(maxWidth: 64))
        XCTAssertTrue(NextEventChip.isShown(maxWidth: 400))
    }

    func testChipWidthInTheGlanceRow() {
        let row: CGFloat = 508
        XCTAssertEqual(GlanceRow.contentWidth, 508)
        // Alone, the chip may use the whole row.
        XCTAssertEqual(GlanceRow.chipMaxWidth(rowWidth: row, hasStrip: false), 508)
        // Beside the strip: 42 % of the row.
        XCTAssertEqual(GlanceRow.chipMaxWidth(rowWidth: row, hasStrip: true), 213)
        // A narrow row keeps the strip at 220 pt first; the chip gets what is left, then hides.
        XCTAssertEqual(GlanceRow.chipMaxWidth(rowWidth: 320, hasStrip: true), 92)
        XCTAssertEqual(GlanceRow.chipMaxWidth(rowWidth: 280, hasStrip: true), 52)
        XCTAssertFalse(NextEventChip.isShown(maxWidth: GlanceRow.chipMaxWidth(rowWidth: 280, hasStrip: true)))
        XCTAssertEqual(GlanceRow.chipMaxWidth(rowWidth: 100, hasStrip: true), 0)
        XCTAssertEqual(GlanceRow.chipMaxWidth(rowWidth: -5, hasStrip: false), 0)
    }

    func testGlanceRowVisibilityAndHeight() {
        XCTAssertFalse(GlanceRow.isShown(hasMedia: false, hasEvent: false))
        XCTAssertTrue(GlanceRow.isShown(hasMedia: true, hasEvent: false))
        XCTAssertTrue(GlanceRow.isShown(hasMedia: false, hasEvent: true))
        XCTAssertEqual(GlanceRow.height(hasMedia: false, hasEvent: false), 0)
        XCTAssertEqual(GlanceRow.height(hasMedia: true, hasEvent: false), 36)
        XCTAssertEqual(GlanceRow.height(hasMedia: false, hasEvent: true), 26)
        XCTAssertEqual(GlanceRow.height(hasMedia: true, hasEvent: true), 36)
    }

    func testLabelKeepsTheSuffixApart() {
        let label = NextEventChip.label(for: glance(link: nil))
        XCTAssertEqual(label.title, "Standup")
        XCTAssertEqual(label.suffix, "· 12m")
    }

    func testTooltipNamesTheRangeAndTheLinkHost() throws {
        let locale = Locale(identifier: "en_US")
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let zoom = try XCTUnwrap(URL(string: "https://acme.zoom.us/j/123"))
        let withLink = NextEventChip.tooltip(for: glance(link: zoom), locale: locale, timeZone: utc)
        let lines = withLink.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.first, "Standup in 12 minutes")
        XCTAssertTrue(lines[1].hasSuffix(" · Join on acme.zoom.us"), lines[1])
        XCTAssertTrue(lines[1].contains("8:00"), lines[1])
        XCTAssertTrue(lines[1].contains("8:15"), lines[1])

        let withoutLink = NextEventChip.tooltip(for: glance(link: nil), locale: locale, timeZone: utc)
        XCTAssertTrue(withoutLink.hasSuffix(" · No meeting link"), withoutLink)
    }

    func testDotColorFallsBackWhenTheCalendarColorIsUnusable() {
        XCTAssertEqual(NextEventChip.dotColor(rgba: nil), Theme.textSecondary)
        XCTAssertEqual(NextEventChip.dotColor(rgba: [0.2]), Theme.textSecondary)
        XCTAssertEqual(NextEventChip.dotColor(rgba: [.nan, 0, 0, 1]), Theme.textSecondary)
        XCTAssertNotEqual(NextEventChip.dotColor(rgba: [0.2, 0.4, 0.8, 1]), Theme.textSecondary)
    }
}

// MARK: - Cost label and Usage menu

final class UsageComponentsTests: XCTestCase {
    private func answer(model: String = "claude-opus-5", input: Int = 1_204, output: Int = 612,
                        searches: Int = 0) -> AnswerUsage {
        let usage = TokenUsage(input: input, output: output, webSearches: searches)
        let cost = ModelPricing.price(for: model)?.cost(of: usage)
        var answer = AnswerUsage(messageID: UUID())
        answer.requests = 1
        answer.lines = [PricedLine(model: model, usage: usage, costNanos: cost)]
        return answer
    }

    func testCostLabelUsesTheLedgerSummary() throws {
        let known = answer(searches: 1)
        XCTAssertEqual(AnswerCostLabel.text(answer: known, fallbackModel: "claude-sonnet-5"), CostFormatter.summary(known))
        XCTAssertEqual(AnswerCostLabel.tooltip(answer: known), CostFormatter.tooltip(known))
        let text = try XCTUnwrap(AnswerCostLabel.text(answer: known, fallbackModel: nil))
        XCTAssertTrue(text.hasPrefix("Opus 5 · ≈"), text)
        XCTAssertTrue(text.contains("1 search"), text)
    }

    func testCostLabelFallsBackToTheModelName() {
        XCTAssertEqual(AnswerCostLabel.text(answer: nil, fallbackModel: "claude-opus-5"), "Opus 5")
        XCTAssertNil(AnswerCostLabel.tooltip(answer: nil))
        let empty = AnswerUsage(messageID: UUID())
        XCTAssertEqual(AnswerCostLabel.text(answer: empty, fallbackModel: "claude-haiku-4-5"), "Haiku 4.5")
        XCTAssertNil(AnswerCostLabel.text(answer: nil, fallbackModel: nil))
        XCTAssertNil(AnswerCostLabel.text(answer: nil, fallbackModel: ""))
    }

    func testUsageMenuRows() {
        let today = UsageTotals(costNanos: 120_000_000, replies: 8)
        XCTAssertEqual(UsageMenuItems.todayTitle(today), "Today  ≈12¢ · 8 replies")
        XCTAssertEqual(UsageMenuItems.todayTitle(UsageTotals(costNanos: 4_000_000, replies: 1)), "Today  ≈0.4¢ · 1 reply")
        XCTAssertEqual(UsageMenuItems.todayTitle(UsageTotals()), "Today  0¢ · 0 replies")
        XCTAssertEqual(UsageMenuItems.monthTitle(UsageTotals(costNanos: 3_400_000_000, replies: 90)), "This month  ≈$3.40")
        XCTAssertEqual(UsageMenuItems.monthTitle(UsageTotals(unpricedTokens: 12_400, replies: 2)),
                       "This month  12.4k tokens")
        XCTAssertEqual(UsageMenuItems.detailsTitle, "Usage Details…")
    }
}
