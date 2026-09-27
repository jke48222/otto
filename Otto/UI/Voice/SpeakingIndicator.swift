//
//  SpeakingIndicator.swift
//  Otto
//
//  Three slow bars in the closed notch's right ear while Otto reads a reply aloud: the same geometry as the
//  streaming equalizer, moving at about a third of its speed so the two read differently at a glance. With
//  Reduce Motion, or when not animating, the bars hold still and the timeline pauses.
//

import SwiftUI

struct SpeakingIndicator: View {
    static let barCount = 3
    static let barWidth: CGFloat = 2.5
    static let barSpacing: CGFloat = 2.2
    static let height: CGFloat = 13
    static let minimumBarHeight: CGFloat = 3.5
    /// Resting heights: a small, uneven stair so a still indicator doesn't look like a flat line.
    static let restingHeights: [CGFloat] = [5, 8, 6]

    private static let speeds: [Double] = [2.4, 3.1, 2.0]
    private static let phases: [Double] = [0, 1.7, 3.4]

    var isAnimating: Bool
    var color: Color

    init(isAnimating: Bool = true, color: Color = Theme.orbLight) {
        self.isAnimating = isAnimating
        self.color = color
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moving = isAnimating && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !moving)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: Self.barSpacing) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: Self.barWidth,
                               height: Self.barHeight(index: index, time: time, isAnimating: moving))
                }
            }
            .frame(height: Self.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Otto is reading the reply aloud")
    }

    /// Pure (tested): bar `index` at `time`, always within `minimumBarHeight…height`; the resting height when
    /// not animating.
    static func barHeight(index: Int, time: TimeInterval, isAnimating: Bool) -> CGFloat {
        let slot = min(max(index, 0), barCount - 1)
        guard isAnimating else { return restingHeights[slot] }
        let wave = sin(time * speeds[slot] + phases[slot])
        let wobble = sin(time * speeds[(slot + 1) % barCount] * 0.43 + phases[slot] * 2)
        let value = min(max(0.5 + 0.32 * wave + 0.18 * wobble, 0), 1)
        return minimumBarHeight + CGFloat(value) * (height - minimumBarHeight)
    }
}
