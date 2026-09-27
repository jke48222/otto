//
//  AudioLevelMeterTests.swift
//  OttoTests
//
//  The voice waveform's level math: decibel endpoints and monotonic normalization, attack and release
//  smoothing, the ring's oldest-to-newest order, and levels read from real PCM buffers.
//

import AVFoundation
import XCTest
@testable import Otto

final class AudioLevelMeterTests: XCTestCase {
    private func rms(decibels: Float) -> Float {
        pow(10, decibels / 20)
    }

    // MARK: - Normalization

    func testNormalizedLevelEndpoints() {
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: rms(decibels: -55)), 0, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: rms(decibels: -10)), 1, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: rms(decibels: -32.5)), 0.5, accuracy: 0.0001)
    }

    func testNormalizedLevelClampsOutsideTheRange() {
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: rms(decibels: -90)), 0)
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: 0), 0)
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: -0.5), 0)
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: .nan), 0)
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: .infinity), 0)
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: rms(decibels: -3)), 1)
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: 1), 1)
    }

    func testNormalizedLevelIsMonotonic() {
        var previous: Float = -1
        for step in 0...200 {
            let decibels = -80 + Float(step) * 0.4
            let level = AudioLevelMeter.normalizedLevel(rms: rms(decibels: decibels))
            XCTAssertGreaterThanOrEqual(level, previous, "level fell at \(decibels) dBFS")
            XCTAssertTrue((0...1).contains(level))
            previous = level
        }
    }

    // MARK: - Smoothing

    func testSmoothingAttacksFastAndReleasesSlowly() {
        XCTAssertEqual(AudioLevelMeter.smooth(previous: 0, target: 1), 0.55, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelMeter.smooth(previous: 0.2, target: 0.6), 0.42, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelMeter.smooth(previous: 1, target: 0), 0.88, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelMeter.smooth(previous: 0.5, target: 0.1), 0.452, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelMeter.smooth(previous: 0.3, target: 0.3), 0.3, accuracy: 0.0001)
    }

    func testIngestSmoothsTowardTheTarget() {
        let meter = AudioLevelMeter()
        meter.ingest(rms: rms(decibels: -10))
        XCTAssertEqual(meter.currentLevel, 0.55, accuracy: 0.0001)
        meter.ingest(rms: rms(decibels: -10))
        XCTAssertEqual(meter.currentLevel, 0.7975, accuracy: 0.0001)
        meter.ingest(rms: 0)
        XCTAssertEqual(meter.currentLevel, 0.7018, accuracy: 0.0001)
    }

    // MARK: - Ring

    func testRecentLevelsAreOldestToNewestAndPaddedWithZeros() {
        let meter = AudioLevelMeter(capacity: 8)
        for level: Float in [0.1, 0.2, 0.3] {
            meter.record(level: level)
        }
        XCTAssertEqual(meter.recentLevels(count: 5), [0, 0, 0.1, 0.2, 0.3])
        XCTAssertEqual(meter.recentLevels(count: 2), [0.2, 0.3])
        XCTAssertEqual(meter.recentLevels(count: 0), [])
        XCTAssertEqual(meter.currentLevel, 0.3)
    }

    func testRingKeepsTheNewestLevelsWhenItWrapsAround() {
        let meter = AudioLevelMeter(capacity: 4)
        for level: Float in [0.1, 0.2, 0.3, 0.4, 0.5, 0.6] {
            meter.record(level: level)
        }
        XCTAssertEqual(meter.recentLevels(count: 4), [0.3, 0.4, 0.5, 0.6])
        XCTAssertEqual(meter.recentLevels(count: 6), [0, 0, 0.3, 0.4, 0.5, 0.6])
    }

    func testRecordClampsAndResetClears() {
        let meter = AudioLevelMeter(capacity: 4)
        meter.record(level: 3)
        meter.record(level: -1)
        XCTAssertEqual(meter.recentLevels(count: 2), [1, 0])
        meter.reset()
        XCTAssertEqual(meter.recentLevels(count: 4), [0, 0, 0, 0])
        XCTAssertEqual(meter.currentLevel, 0)
    }

    // MARK: - Buffers

    func testIngestReadsChannelZeroOfAFloatBuffer() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        let channels = try XCTUnwrap(buffer.floatChannelData)
        // Channel 0: a full-scale square wave (RMS 1). Channel 1 stays silent and must be ignored.
        for frame in 0..<1024 {
            channels[0][frame] = frame.isMultiple(of: 2) ? 1 : -1
            channels[1][frame] = 0
        }
        let meter = AudioLevelMeter()
        meter.ingest(buffer)
        XCTAssertEqual(meter.currentLevel, 0.55, accuracy: 0.0001)

        let silent = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        silent.frameLength = 1024
        let silentChannels = try XCTUnwrap(silent.floatChannelData)
        for channel in 0..<2 {
            silentChannels[channel].update(repeating: 0, count: 1024)
        }
        let quiet = AudioLevelMeter()
        quiet.ingest(silent)
        XCTAssertEqual(quiet.currentLevel, 0)
        XCTAssertEqual(quiet.recentLevels(count: 1), [0])
    }
}
