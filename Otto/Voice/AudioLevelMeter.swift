//
//  AudioLevelMeter.swift
//  Otto
//
//  The microphone level behind the voice waveform. The audio thread writes one smoothed level per buffer
//  into a small ring; the UI reads the ring straight from the lock, not through Observation, so 43 Hz
//  audio updates never invalidate SwiftUI.
//

import AVFoundation
import os

final class AudioLevelMeter: @unchecked Sendable {
    /// Quietest level that still draws a bar: −55 dBFS maps to 0.
    static let floorDecibels: Float = -55
    /// Loud speech close to the mic: −10 dBFS maps to 1.
    static let ceilingDecibels: Float = -10
    /// Share of the gap closed per buffer while the level rises.
    static let attack: Float = 0.55
    /// Share of the gap closed per buffer while the level falls.
    static let release: Float = 0.12

    private struct Storage {
        var ring: [Float]
        var writeIndex = 0
        var count = 0
        var level: Float = 0
    }

    private let capacity: Int
    private let storage: OSAllocatedUnfairLock<Storage>

    init(capacity: Int = 64) {
        let size = max(1, capacity)
        self.capacity = size
        storage = OSAllocatedUnfairLock(initialState: Storage(ring: Array(repeating: 0, count: size)))
    }

    /// Audio thread: RMS of channel 0 → normalized level → smoothed → ring buffer.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        ingest(rms: Self.rms(of: buffer))
    }

    /// The same pipeline from an RMS amplitude (0…1 full scale).
    func ingest(rms: Float) {
        let target = Self.normalizedLevel(rms: rms)
        storage.withLock { state in
            state.level = Self.smooth(previous: state.level, target: target)
            Self.append(state.level, to: &state, capacity: capacity)
        }
    }

    /// Records a level as is (clamped to 0…1), skipping normalization and smoothing. The scripted engine and
    /// debug seeds use it to show exact levels.
    func record(level: Float) {
        let clamped = Self.clamp(level)
        storage.withLock { state in
            state.level = clamped
            Self.append(clamped, to: &state, capacity: capacity)
        }
    }

    /// The last `count` levels, oldest → newest, padded with 0 at the oldest end.
    func recentLevels(count: Int) -> [Float] {
        guard count > 0 else { return [] }
        return storage.withLock { state in
            let available = min(count, state.count)
            var levels = Array(repeating: Float(0), count: count - available)
            levels.reserveCapacity(count)
            for offset in stride(from: available, to: 0, by: -1) {
                let index = (state.writeIndex - offset + capacity) % capacity
                levels.append(state.ring[index])
            }
            return levels
        }
    }

    var currentLevel: Float {
        storage.withLock { $0.level }
    }

    func reset() {
        storage.withLock { state in
            state = Storage(ring: Array(repeating: 0, count: capacity))
        }
    }

    /// Pure math: −55 dBFS → 0, −10 dBFS → 1, linear in decibels between, clamped.
    static func normalizedLevel(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return clamp((decibels - floorDecibels) / (ceilingDecibels - floorDecibels))
    }

    /// Pure smoothing: attack 0.55 when rising, release 0.12 when falling.
    static func smooth(previous: Float, target: Float) -> Float {
        let factor = target > previous ? attack : release
        return clamp(previous + (target - previous) * factor)
    }

    // MARK: - Private

    private static func append(_ level: Float, to state: inout Storage, capacity: Int) {
        state.ring[state.writeIndex] = level
        state.writeIndex = (state.writeIndex + 1) % capacity
        state.count = min(state.count + 1, capacity)
    }

    private static func clamp(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0, buffer.format.channelCount > 0 else { return 0 }
        var sumOfSquares: Float = 0
        if let channels = buffer.floatChannelData {
            let samples = channels[0]
            let stride = buffer.stride
            for frame in 0..<frames {
                let sample = samples[frame * stride]
                sumOfSquares += sample * sample
            }
        } else if let channels = buffer.int16ChannelData {
            let samples = channels[0]
            let stride = buffer.stride
            for frame in 0..<frames {
                let sample = Float(samples[frame * stride]) / Float(Int16.max)
                sumOfSquares += sample * sample
            }
        } else if let channels = buffer.int32ChannelData {
            let samples = channels[0]
            let stride = buffer.stride
            for frame in 0..<frames {
                let sample = Float(samples[frame * stride]) / Float(Int32.max)
                sumOfSquares += sample * sample
            }
        } else {
            return 0
        }
        return (sumOfSquares / Float(frames)).squareRoot()
    }
}
