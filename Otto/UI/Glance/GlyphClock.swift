//
//  GlyphClock.swift
//  Otto
//
//  The one clock every closed-notch glyph animates from. A frame is the timeline's date snapped to
//  30 fps, so every glyph on screen moves in step; with Reduce Motion the clock returns the same still
//  frame at every date, and each glyph draws its rest pose from it.
//

import Foundation

enum GlyphClock {
    /// Glyph animation rate. The ears are 14 pt wide; more than 30 fps buys nothing visible.
    static let framesPerSecond: Double = 30
    /// The TimelineView interval that matches `framesPerSecond`.
    static let frameInterval: TimeInterval = 1 / framesPerSecond

    /// One instant of glyph animation.
    struct Frame: Equatable, Sendable {
        /// Seconds since the reference date, snapped down to a whole frame. 0 for the still frame.
        let time: TimeInterval
        /// Reduce Motion: glyphs draw their rest pose and ignore `time`.
        let isStill: Bool

        /// Where `time` falls in a loop of `period` seconds, shifted by `offset` seconds: 0 up to (not
        /// including) 1. Always 0 for the still frame or a non-positive period.
        func progress(period: TimeInterval, offset: TimeInterval = 0) -> Double {
            guard !isStill, period > 0 else { return 0 }
            let cycles = (time + offset) / period
            let fraction = cycles - cycles.rounded(.down)
            return min(max(fraction, 0), 1 - .ulpOfOne)
        }

        /// A smooth 0…1…0 wave over `period` seconds (a raised cosine that starts at 0), shifted by
        /// `offset` seconds.
        func wave(period: TimeInterval, offset: TimeInterval = 0) -> Double {
            let angle = progress(period: period, offset: offset) * 2 * Double.pi
            return (1 - cos(angle)) / 2
        }
    }

    /// The frame every glyph shows with Reduce Motion on.
    static let still = Frame(time: 0, isStill: true)

    /// Pure. The frame for `date`: its time snapped down to a 1/30 s boundary, or `still` whatever the
    /// date when `reduceMotion` is on.
    static func frame(at date: Date, reduceMotion: Bool) -> Frame {
        guard !reduceMotion else { return still }
        let index = (date.timeIntervalSinceReferenceDate * framesPerSecond).rounded(.down)
        return Frame(time: index / framesPerSecond, isStill: false)
    }
}
