//
//  VoiceWaveformView.swift
//  Otto
//
//  The live microphone waveform: capsule bars drawn from the meter's recent levels, newest at the right, so
//  the trace scrolls left while the user talks. The view reads the lock-protected meter on every animation
//  frame instead of observing it, so 43 Hz audio updates never invalidate SwiftUI. When it stops being
//  active it eases to a flat line.
//

import SwiftUI

/// Pure bar geometry for `VoiceWaveformView` (tested).
struct VoiceWaveformModel: Equatable, Sendable {
    /// The shortest bar, so silence still reads as a line of dots.
    static let minimumBarHeight: CGFloat = 2

    let barCount: Int
    let barWidth: CGFloat
    let gap: CGFloat
    let maxHeight: CGFloat

    init(barCount: Int, barWidth: CGFloat, gap: CGFloat, maxHeight: CGFloat) {
        self.barCount = max(0, barCount)
        self.barWidth = barWidth
        self.gap = gap
        self.maxHeight = maxHeight
    }

    /// ear: 9 bars, 2 pt wide, 2 pt gap, up to 12 pt; inline: 28 bars, 2 pt wide, 2.5 pt gap, up to 18 pt.
    init(style: VoiceWaveformView.Style) {
        switch style {
        case .ear: self.init(barCount: 9, barWidth: 2, gap: 2, maxHeight: 12)
        case .inline: self.init(barCount: 28, barWidth: 2, gap: 2.5, maxHeight: 18)
        }
    }

    /// Width of the whole run of bars.
    var width: CGFloat {
        guard barCount > 0 else { return 0 }
        return CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
    }

    /// Exactly `count` bar heights from `levels` (oldest → newest, as `AudioLevelMeter.recentLevels` returns
    /// them): the newest `count` levels, with missing ones at the oldest end drawn as silence. Each height is
    /// `max(2, level × maxHeight × amplitude)`, with levels clamped to 0…1 (NaN counts as silence) and
    /// `amplitude` clamped to 0…1 (0 draws the flat line of the finishing state).
    func barHeights(levels: [Float], count: Int, amplitude: CGFloat = 1) -> [CGFloat] {
        guard count > 0 else { return [] }
        let scale = maxHeight * Self.clamped(amplitude)
        let newest = levels.suffix(count)
        let padding = count - newest.count
        var heights = Array(repeating: Self.minimumBarHeight, count: padding)
        heights.reserveCapacity(count)
        for level in newest {
            let value = CGFloat(level.isFinite ? min(max(level, 0), 1) : 0)
            heights.append(max(Self.minimumBarHeight, value * scale))
        }
        return heights
    }

    /// One rect per height: laid out left to right, the run centered horizontally in `size`, each bar
    /// centered vertically.
    func barRects(heights: [CGFloat], in size: CGSize) -> [CGRect] {
        let runWidth = CGFloat(heights.count) * barWidth + CGFloat(max(0, heights.count - 1)) * gap
        let originX = (size.width - runWidth) / 2
        return heights.enumerated().map { index, height in
            CGRect(
                x: originX + CGFloat(index) * (barWidth + gap),
                y: (size.height - height) / 2,
                width: barWidth,
                height: height
            )
        }
    }

    private static func clamped(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// Capsule bars that follow the microphone level. Decorative for VoiceOver: the listening pill and the
/// transcript carry the words.
struct VoiceWaveformView: View {
    enum Style: Equatable, Sendable { case ear, inline }

    let style: Style
    /// Read directly on each frame (it is lock-protected); never observed.
    let meter: AudioLevelMeter
    /// Animates while true; false eases the bars to a flat line and pauses the timeline.
    var isActive: Bool

    init(style: Style, meter: AudioLevelMeter, isActive: Bool = true) {
        self.style = style
        self.meter = meter
        self.isActive = isActive
    }

    private var model: VoiceWaveformModel { VoiceWaveformModel(style: style) }

    var body: some View {
        VoiceWaveformCanvas(model: model, meter: meter, isActive: isActive, amplitude: isActive ? 1 : 0)
            .frame(width: model.width, height: model.maxHeight)
            .animation(.easeOut(duration: 0.35), value: isActive)
            .accessibilityHidden(true)
    }
}

/// The drawing, animatable in `amplitude` so the bars ease down to the flat line.
private struct VoiceWaveformCanvas: View, Animatable {
    let model: VoiceWaveformModel
    let meter: AudioLevelMeter
    let isActive: Bool
    var amplitude: CGFloat

    var animatableData: CGFloat {
        get { amplitude }
        set { amplitude = newValue }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isActive)) { _ in
            Canvas { context, size in
                let heights = model.barHeights(
                    levels: meter.recentLevels(count: model.barCount),
                    count: model.barCount,
                    amplitude: amplitude
                )
                let color = Theme.orbLight.opacity(0.92)
                for rect in model.barRects(heights: heights, in: size) {
                    context.fill(Capsule().path(in: rect), with: .color(color))
                }
            }
        }
    }
}
