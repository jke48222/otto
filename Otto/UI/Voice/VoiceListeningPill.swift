//
//  VoiceListeningPill.swift
//  Otto
//
//  The closed notch while Otto listens. The notch grows into a pill: on the camera row a breathing red dot
//  in the left ear and a 9-bar live waveform in the right, each the same distance in from its side, vertically
//  centered on the camera row, and under the camera a one-line caption with the
//  newest words. It draws only the contents; the closed frame sizes the black shape with ClosedNotchLayout
//  and places this view inside it.
//

import SwiftUI

struct VoiceListeningPill: View {
    /// The spring the frame uses when the pill grows in (the close spring takes it out).
    static let appearAnimation = Animation.spring(response: 0.32, dampingFraction: 0.8)
    static let disappearAnimation = Theme.Motion.close
    static let captionFontSize: CGFloat = 12.5
    /// Characters the one-line caption keeps; head truncation trims whatever still doesn't fit.
    static let captionCharacterLimit = 160
    static let captionHorizontalPadding: CGFloat = 18
    /// From the pill's outer edges in to the dot and the waveform: where a full-size glyph's edge sits in the other
    /// closed states (the concave top corner, then a 14 pt glyph centered in its ear), so the two marks sit the
    /// same distance in from their sides whatever their widths.
    static let earInset: CGFloat = NotchMetrics.closedTopRadius
        + (ClosedNotchView.earWidth - EarGlyphView.glyphSize.width) / 2

    /// The camera housing (hardware or virtual notch) the pill grows from.
    let notchSize: CGSize
    /// Read directly by the waveform; never observed.
    let meter: AudioLevelMeter
    let finalizedText: String
    let volatileText: String
    /// The final words are landing: the waveform flattens and the dot fades to the orb's light.
    var isFinishing: Bool

    init(notchSize: CGSize, meter: AudioLevelMeter, finalizedText: String, volatileText: String,
         isFinishing: Bool = false) {
        self.notchSize = notchSize
        self.meter = meter
        self.finalizedText = finalizedText
        self.volatileText = volatileText
        self.isFinishing = isFinishing
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let caption = VoiceTranscriptText(
            finalized: finalizedText,
            volatile: volatileText,
            keepingLast: Self.captionCharacterLimit
        )
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VoiceRecordingDot(isFinishing: isFinishing, breathes: !reduceMotion)
                    .padding(.leading, Self.earInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear
                    .frame(width: notchSize.width)
                VoiceWaveformView(style: .ear, meter: meter, isActive: !isFinishing)
                    .padding(.trailing, Self.earInset)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: notchSize.height)

            captionView(caption)
                .frame(maxWidth: .infinity)
                .frame(height: VoiceMetrics.captionHeight)
                .padding(.horizontal, Self.captionHorizontalPadding)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isFinishing ? "Otto is finishing listening" : "Otto is listening")
        .accessibilityValue(caption.combined)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private func captionView(_ caption: VoiceTranscriptText) -> some View {
        if caption.isEmpty {
            Text("Listening…")
                .font(Theme.font(Self.captionFontSize))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .shimmer(isActive: !isFinishing && !reduceMotion)
        } else {
            Text(caption.attributed(settledColor: Theme.textSecondary, tailColor: Theme.textTertiary))
                .font(Theme.font(Self.captionFontSize))
                .lineLimit(1)
                .truncationMode(.head)
        }
    }
}

/// The 8 pt recording dot with a soft glow. Breathes (0.85 ↔ 1.1 over 1.2 s) while listening unless Reduce
/// Motion is on; fades to the orb's light while finishing.
private struct VoiceRecordingDot: View {
    static let diameter: CGFloat = 8

    let isFinishing: Bool
    let breathes: Bool

    var body: some View {
        let color = isFinishing ? Theme.orbLight : Theme.recording
        let dot = Circle()
            .fill(color)
            .frame(width: Self.diameter, height: Self.diameter)
            .shadow(color: color.opacity(isFinishing ? 0.25 : 0.55), radius: 3.5)
            .animation(.easeOut(duration: 0.3), value: isFinishing)
        if breathes && !isFinishing {
            dot.phaseAnimator([false, true]) { content, expanded in
                content.scaleEffect(expanded ? 1.1 : 0.85)
            } animation: { _ in
                .easeInOut(duration: 0.6)
            }
        } else {
            dot
        }
    }
}
