//
//  VoiceComponentsTests.swift
//  OttoTests
//
//  The pure parts of the voice UI: waveform bar heights and layout, the mic button's look, copy and gesture
//  rules for every MicState, the transcript split shared by the composer overlay and the listening pill,
//  and the speaking indicator's bar range.
//

import SwiftUI
import XCTest
@testable import Otto

final class VoiceComponentsTests: XCTestCase {
    // MARK: - VoiceWaveformModel

    func testStyleMetricsMatchTheSpec() {
        let ear = VoiceWaveformModel(style: .ear)
        XCTAssertEqual(ear.barCount, 9)
        XCTAssertEqual(ear.barWidth, 2)
        XCTAssertEqual(ear.gap, 2)
        XCTAssertEqual(ear.maxHeight, 12)
        XCTAssertEqual(ear.width, 9 * 2 + 8 * 2)

        let inline = VoiceWaveformModel(style: .inline)
        XCTAssertEqual(inline.barCount, 28)
        XCTAssertEqual(inline.barWidth, 2)
        XCTAssertEqual(inline.gap, 2.5)
        XCTAssertEqual(inline.maxHeight, 18)
        XCTAssertEqual(inline.width, 28 * 2 + 27 * 2.5, accuracy: 0.0001)
    }

    func testBarHeightsScaleLevelsWithATwoPointFloor() {
        let model = VoiceWaveformModel(style: .ear)
        let heights = model.barHeights(levels: [0, 0.1, 0.5, 1], count: 4)
        XCTAssertEqual(heights, [2, 2, 6, 12])
    }

    func testBarHeightsKeepTheNewestLevelsAtTheRight() {
        let model = VoiceWaveformModel(style: .ear)
        let heights = model.barHeights(levels: [1, 1, 0.25, 0.5, 0.75], count: 3)
        XCTAssertEqual(heights, [3, 6, 9])
    }

    func testBarHeightsPadMissingLevelsAtTheOldestEnd() {
        let model = VoiceWaveformModel(style: .inline)
        let heights = model.barHeights(levels: [0.5, 1], count: 5)
        XCTAssertEqual(heights, [2, 2, 2, 9, 18])
        XCTAssertEqual(model.barHeights(levels: [], count: 3), [2, 2, 2])
    }

    func testBarHeightsClampOutOfRangeAndNonFiniteLevels() {
        let model = VoiceWaveformModel(style: .ear)
        let heights = model.barHeights(levels: [-0.5, 1.8, .nan, .infinity], count: 4)
        XCTAssertEqual(heights, [2, 12, 2, 2])
    }

    func testBarHeightsReturnExactlyCountBars() {
        let model = VoiceWaveformModel(style: .ear)
        let levels = (0..<64).map { Float($0) / 64 }
        XCTAssertEqual(model.barHeights(levels: levels, count: 9).count, 9)
        XCTAssertEqual(model.barHeights(levels: levels, count: 0), [])
        XCTAssertEqual(model.barHeights(levels: levels, count: -3), [])
    }

    func testZeroAmplitudeDrawsTheFlatLine() {
        let model = VoiceWaveformModel(style: .ear)
        let levels: [Float] = [0.2, 0.9, 1, 0.6]
        XCTAssertEqual(model.barHeights(levels: levels, count: 4, amplitude: 0), [2, 2, 2, 2])
        // Half amplitude: 0.2 × 12 × 0.5 = 1.2 falls under the floor.
        let half = model.barHeights(levels: levels, count: 4, amplitude: 0.5)
        for (height, expected) in zip(half, [2, 5.4, 6, 3.6] as [CGFloat]) {
            XCTAssertEqual(height, expected, accuracy: 0.0001)
        }
        XCTAssertEqual(model.barHeights(levels: levels, count: 4, amplitude: 3), model.barHeights(levels: levels, count: 4))
    }

    func testBarHeightsStayWithinTheFloorAndMaximum() {
        for style in [VoiceWaveformView.Style.ear, .inline] {
            let model = VoiceWaveformModel(style: style)
            let levels = stride(from: Float(-1), through: 2, by: 0.05).map { $0 }
            for height in model.barHeights(levels: levels, count: levels.count) {
                XCTAssertGreaterThanOrEqual(height, VoiceWaveformModel.minimumBarHeight)
                XCTAssertLessThanOrEqual(height, model.maxHeight)
            }
        }
    }

    func testBarRectsAreCenteredAndEvenlySpaced() {
        let model = VoiceWaveformModel(style: .ear)
        let size = CGSize(width: model.width + 10, height: model.maxHeight)
        let rects = model.barRects(heights: [2, 12, 6], in: size)
        XCTAssertEqual(rects.count, 3)
        let runWidth: CGFloat = 3 * 2 + 2 * 2
        XCTAssertEqual(rects[0].minX, (size.width - runWidth) / 2, accuracy: 0.0001)
        XCTAssertEqual(rects[1].minX - rects[0].minX, 4, accuracy: 0.0001)
        XCTAssertEqual(rects[2].minX - rects[1].minX, 4, accuracy: 0.0001)
        for rect in rects {
            XCTAssertEqual(rect.width, 2)
            XCTAssertEqual(rect.midY, size.height / 2, accuracy: 0.0001)
        }
        XCTAssertEqual(rects[1].height, 12)
    }

    // MARK: - MicButton presentation

    func testMicStateMapsToGlyphAndLook() {
        let expected: [(MicState, String?, MicButton.Presentation.Look)] = [
            (.off, "mic", .ghost),
            (.ready, "mic", .ghost),
            (.listening, "mic.fill", .active),
            (.finishing, nil, .finishing),
            (.unavailable(.microphoneDenied), "mic.slash", .unavailable),
            (.unavailable(.speechDenied), "mic.slash", .unavailable),
            (.unavailable(.noInputDevice), "mic.slash", .unavailable),
            (.unavailable(.recognizerUnavailable(localeName: "English (India)")), "mic.slash", .unavailable),
            (.unavailable(.dictationDisabled), "mic.slash", .unavailable),
        ]
        for (state, symbol, look) in expected {
            let presentation = MicButton.Presentation(state: state)
            XCTAssertEqual(presentation.symbolName, symbol, "\(state)")
            XCTAssertEqual(presentation.look, look, "\(state)")
        }
    }

    func testMicStateMapsToAccessibilityCopy() {
        XCTAssertEqual(MicButton.accessibilityLabel, "Talk to Otto")

        let ready = MicButton.Presentation(state: .ready)
        XCTAssertEqual(ready.accessibilityValue, "")
        XCTAssertEqual(ready.accessibilityHint, "Double-tap to start listening, again to send")

        let off = MicButton.Presentation(state: .off)
        XCTAssertEqual(off.accessibilityValue, "Voice is off")
        XCTAssertEqual(off.accessibilityHint, "Double-tap to set up voice")

        let listening = MicButton.Presentation(state: .listening)
        XCTAssertEqual(listening.accessibilityValue, "Listening")
        XCTAssertEqual(listening.accessibilityHint, "Double-tap to send")

        let finishing = MicButton.Presentation(state: .finishing)
        XCTAssertEqual(finishing.accessibilityValue, "Finishing")
        XCTAssertEqual(finishing.accessibilityHint, "")
    }

    func testUnavailableReasonsNameTheProblem() {
        let expected: [(VoiceUnavailableReason, String)] = [
            (.microphoneDenied, "Otto isn't allowed to use the microphone"),
            (.speechDenied, "Otto isn't allowed to use Speech Recognition"),
            (.noInputDevice, "No microphone is connected"),
            (.recognizerUnavailable(localeName: "English (India)"), "Speech recognition for English (India) isn't available"),
            (.dictationDisabled, "Dictation is off"),
        ]
        for (reason, text) in expected {
            let presentation = MicButton.Presentation(state: .unavailable(reason))
            XCTAssertEqual(presentation.accessibilityValue, text)
            XCTAssertEqual(presentation.help, text)
            XCTAssertEqual(presentation.accessibilityHint, "Double-tap to see how to fix it")
        }
    }

    func testOnlyAReadyMicCanStartAHold() {
        XCTAssertTrue(MicButton.Presentation(state: .ready).allowsHold)
        for state: MicState in [.off, .listening, .finishing, .unavailable(.dictationDisabled)] {
            XCTAssertFalse(MicButton.Presentation(state: state).allowsHold, "\(state)")
        }
    }

    func testFinishingIgnoresPresses() {
        XCTAssertFalse(MicButton.Presentation(state: .finishing).acceptsPress)
        for state: MicState in [.off, .ready, .listening, .unavailable(.noInputDevice)] {
            XCTAssertTrue(MicButton.Presentation(state: state).acceptsPress, "\(state)")
        }
    }

    /// The button feeds the shared machine with `holdEnabled = allowsHold`; check the two paths it relies on.
    func testGesturePathsThroughTheHoldMachine() {
        var ready = HoldGestureMachine(holdEnabled: MicButton.Presentation(state: .ready).allowsHold,
                                       holdThreshold: VoiceMetrics.holdThreshold)
        XCTAssertEqual(ready.press(at: 10), [.scheduleHoldCheck(at: 10 + VoiceMetrics.holdThreshold)])
        XCTAssertEqual(ready.holdCheck(at: 10.3), [.holdBegan])
        XCTAssertEqual(ready.release(at: 11), [.holdEnded])
        XCTAssertEqual(ready.press(at: 20), [.scheduleHoldCheck(at: 20 + VoiceMetrics.holdThreshold)])
        XCTAssertEqual(ready.release(at: 20.1), [.tap])

        var listening = HoldGestureMachine(holdEnabled: MicButton.Presentation(state: .listening).allowsHold,
                                           holdThreshold: VoiceMetrics.holdThreshold)
        XCTAssertEqual(listening.press(at: 30), [.tap])
        XCTAssertEqual(listening.release(at: 31), [])
    }

    // MARK: - VoiceTranscriptText

    func testTranscriptJoinsSettledWordsAndTheTailWithOneSpace() {
        let text = VoiceTranscriptText(finalized: "  What's on my  calendar ", volatile: " tomorrow ")
        XCTAssertEqual(text.settled, "What's on my calendar")
        XCTAssertEqual(text.tail, " tomorrow")
        XCTAssertEqual(text.combined, "What's on my calendar tomorrow")
        XCTAssertFalse(text.isEmpty)
    }

    func testTranscriptWithOnlyOneHalf() {
        let tailOnly = VoiceTranscriptText(finalized: "", volatile: "Hello")
        XCTAssertEqual(tailOnly.settled, "")
        XCTAssertEqual(tailOnly.tail, "Hello")

        let settledOnly = VoiceTranscriptText(finalized: "Hello there", volatile: "   ")
        XCTAssertEqual(settledOnly.combined, "Hello there")
        XCTAssertEqual(settledOnly.tail, "")

        XCTAssertTrue(VoiceTranscriptText(finalized: " \n", volatile: "\t").isEmpty)
    }

    func testTranscriptRemovesHiddenAndBidiCharacters() {
        let text = VoiceTranscriptText(finalized: "Open\u{202E}the\u{200B} notes", volatile: "now\u{0007}")
        XCTAssertEqual(text.combined, "Openthe notes now")
    }

    func testCaptionKeepsTheNewestCharacters() {
        let text = VoiceTranscriptText(
            finalized: "one two three four five six",
            volatile: "seven",
            keepingLast: 16
        )
        XCTAssertLessThanOrEqual(text.combined.count, 16)
        XCTAssertTrue(text.combined.hasSuffix("six seven"))
        XCTAssertEqual(text.tail, " seven")
        // The cut lands inside "four"; the caption starts on the next whole word.
        XCTAssertEqual(text.settled, "five six")
    }

    func testCaptionShorterThanTheLimitIsUntouched() {
        let text = VoiceTranscriptText(finalized: "Remind me", volatile: "later", keepingLast: 160)
        XCTAssertEqual(text.combined, "Remind me later")
    }

    func testCaptionWithAVeryLongTailDropsTheSettledWords() {
        let text = VoiceTranscriptText(finalized: "earlier words", volatile: "abcdefghij", keepingLast: 4)
        XCTAssertEqual(text.settled, "")
        XCTAssertEqual(text.tail, "ghij")
    }

    func testAttributedTranscriptColorsTheTail() {
        let text = VoiceTranscriptText(finalized: "Play", volatile: "music")
        let attributed = text.attributed(settledColor: .white, tailColor: .gray)
        XCTAssertEqual(String(attributed.characters), "Play music")
        let runs = Array(attributed.runs)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.first?.foregroundColor, .white)
        XCTAssertEqual(runs.last?.foregroundColor, .gray)
    }

    // MARK: - SpeakingIndicator

    func testSpeakingBarsStayWithinTheEar() {
        for index in 0..<SpeakingIndicator.barCount {
            for step in 0..<400 {
                let height = SpeakingIndicator.barHeight(index: index, time: Double(step) * 0.037, isAnimating: true)
                XCTAssertGreaterThanOrEqual(height, SpeakingIndicator.minimumBarHeight)
                XCTAssertLessThanOrEqual(height, SpeakingIndicator.height)
            }
        }
        XCTAssertLessThanOrEqual(SpeakingIndicator.height, 13)
    }

    func testStillSpeakingBarsHoldTheirRestingHeights() {
        for index in 0..<SpeakingIndicator.barCount {
            let first = SpeakingIndicator.barHeight(index: index, time: 0, isAnimating: false)
            let later = SpeakingIndicator.barHeight(index: index, time: 1234.5, isAnimating: false)
            XCTAssertEqual(first, later)
            XCTAssertEqual(first, SpeakingIndicator.restingHeights[index])
        }
    }

    func testSpeakingBarsMoveWhenAnimating() {
        let heights = (0..<20).map { SpeakingIndicator.barHeight(index: 1, time: Double($0) * 0.25, isAnimating: true) }
        XCTAssertGreaterThan(Set(heights).count, 1)
    }
}
