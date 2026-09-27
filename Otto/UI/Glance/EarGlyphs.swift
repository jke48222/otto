//
//  EarGlyphs.swift
//  Otto
//
//  The small marks in the closed notch's ears: the orb, one glyph per reply phase, the approval pulse,
//  the unread dot, the paste checkmark, the speaking bars, the media artwork and equalizer, and the
//  hourglass shown while Otto waits on system UI. One 30 fps TimelineView drives whichever glyph is
//  showing from GlyphClock; it pauses while the ear is hidden, and with Reduce Motion every glyph holds
//  a still frame.
//

import AppKit
import SwiftUI

struct EarGlyphView: View {
    let glyph: EarGlyph
    /// Supplies the artwork for `.artwork`; only that glyph reads it.
    let nowPlaying: NowPlayingMonitor
    /// Forces still frames (snapshots); the system's Reduce Motion setting applies either way.
    var reduceMotion: Bool = false
    /// False while the ear can't be seen (notch open, panel hidden for a screen capture): the timeline
    /// stops ticking.
    var isVisible: Bool = true

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// Largest box a glyph draws in (glance.md §1.3); the artwork ear is the one 16 × 16 exception.
    static let glyphSize = CGSize(width: 14, height: 13)
    static let artworkSize = CGSize(width: 16, height: 16)

    /// What an ear draws, independent of labels (a new search label doesn't restart the glyph).
    enum Kind: Hashable, Sendable {
        case none
        case orb(active: Bool)
        /// Three dots in a wave: slow and dim while connecting, brighter while thinking.
        case thinkingDots(isSlow: Bool)
        case search
        case writing
        case action
        case approval
        case unreadDot
        case checkmark
        case speaking
        case artwork(NowPlayingItem.ID)
        case equalizer
        case systemWait

        /// The box the glyph draws in.
        var size: CGSize {
            switch self {
            case .none: return .zero
            case .artwork: return EarGlyphView.artworkSize
            default: return EarGlyphView.glyphSize
            }
        }

        /// Kinds that move. The rest draw once and need no timeline.
        var isAnimated: Bool {
            switch self {
            case .orb(let active): return active
            case .thinkingDots, .search, .writing, .action, .approval, .speaking, .equalizer, .systemWait: return true
            case .none, .unreadDot, .checkmark, .artwork: return false
            }
        }
    }

    /// Pure. The glyph an ear shows for `glyph`; an idle phase draws nothing.
    static func kind(for glyph: EarGlyph) -> Kind {
        switch glyph {
        case .none: return .none
        case .orb(let active): return .orb(active: active)
        case .phase(let phase): return kind(for: phase)
        case .unreadDot: return .unreadDot
        case .approval: return .approval
        case .checkmark: return .checkmark
        case .speaking: return .speaking
        case .artwork(let id): return .artwork(id)
        case .equalizer: return .equalizer
        case .systemWait: return .systemWait
        }
    }

    /// Pure. The glyph for a reply phase (glance.md §1.1).
    static func kind(for phase: ReplyPhase) -> Kind {
        switch phase {
        case .idle: return .none
        case .connecting: return .thinkingDots(isSlow: true)
        case .thinking: return .thinkingDots(isSlow: false)
        case .searching: return .search
        case .writing: return .writing
        case .runningAction: return .action
        case .awaitingApproval: return .approval
        }
    }

    /// Pure. Whether the timeline ticks: only for a moving glyph that can be seen, without Reduce Motion.
    static func isTicking(_ kind: Kind, isVisible: Bool, reduceMotion: Bool) -> Bool {
        kind.isAnimated && isVisible && !reduceMotion
    }

    private var holdsStill: Bool { reduceMotion || systemReduceMotion }

    var body: some View {
        let current = Self.kind(for: glyph)
        ZStack {
            if current != .none {
                glyphBody(current)
                    .frame(width: current.size.width, height: current.size.height)
                    .id(current)
                    .transition(holdsStill ? .opacity : .opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(holdsStill ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.2), value: current)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func glyphBody(_ kind: Kind) -> some View {
        switch kind {
        case .none:
            EmptyView()
        case .unreadDot:
            UnreadDot()
        case .checkmark:
            PasteCheckmark()
        case .artwork(let id):
            ArtworkEar(itemID: id, nowPlaying: nowPlaying)
        default:
            let ticking = Self.isTicking(kind, isVisible: isVisible, reduceMotion: holdsStill)
            TimelineView(.animation(minimumInterval: GlyphClock.frameInterval, paused: !ticking)) { context in
                AnimatedGlyph(kind: kind, frame: GlyphClock.frame(at: context.date, reduceMotion: holdsStill))
            }
        }
    }
}

// MARK: - Animated glyphs

/// Draws one moving glyph at one frame.
private struct AnimatedGlyph: View {
    let kind: EarGlyphView.Kind
    let frame: GlyphClock.Frame

    var body: some View {
        switch kind {
        case .orb:
            BreathingOrb(frame: frame)
        case .thinkingDots(let isSlow):
            ThinkingDots(isSlow: isSlow, frame: frame)
        case .search:
            SearchGlyph(frame: frame)
        case .writing:
            WritingGlyph(frame: frame)
        case .action:
            ActionGlyph(frame: frame)
        case .approval:
            ApprovalPulse(frame: frame)
        case .speaking:
            GlyphBars(style: .speaking, frame: frame)
        case .equalizer:
            GlyphBars(style: .equalizer, frame: frame)
        case .systemWait:
            HourglassGlyph(frame: frame)
        case .none, .unreadDot, .checkmark, .artwork:
            EmptyView()
        }
    }
}

/// Otto's orb, breathing (scale 0.9 ↔ 1.1, opacity 0.72 ↔ 1 over 2.1 s) while a turn is active.
private struct BreathingOrb: View {
    let frame: GlyphClock.Frame

    var body: some View {
        let breath = frame.isStill ? 1 : frame.wave(period: 2.1)
        OttoOrb(size: 12, isActive: false)
            .scaleEffect(frame.isStill ? 1 : 0.9 + 0.2 * breath)
            .opacity(frame.isStill ? 1 : 0.72 + 0.28 * breath)
    }
}

/// Connecting: a slow (1.8 s) dim wave, opacity up to 0.6. Thinking: a 1.2 s wave, opacity 0.35 → 1.
private struct ThinkingDots: View {
    let isSlow: Bool
    let frame: GlyphClock.Frame

    private static let dotSize: CGFloat = 3
    private static let spacing: CGFloat = 2

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.orbLight)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .opacity(opacity(index))
            }
        }
    }

    private func opacity(_ index: Int) -> Double {
        let low = isSlow ? 0.2 : 0.35
        let high = isSlow ? 0.6 : 1
        if frame.isStill {
            // Rest pose: a frozen wave, brightest on the left.
            return high - (high - low) * Double(index) / 2
        }
        let period: TimeInterval = isSlow ? 1.8 : 1.2
        // Each dot trails the one before it by a sixth of the loop.
        let wave = frame.wave(period: period, offset: -period * Double(index) / 6)
        return low + (high - low) * wave
    }
}

/// A magnifier (7 pt ring, 3 pt handle) drifting round a 2 pt circle every 1.6 s.
private struct SearchGlyph: View {
    let frame: GlyphClock.Frame

    var body: some View {
        Canvas { context, size in
            let angle = frame.isStill ? -Double.pi / 4 : frame.progress(period: 1.6) * 2 * Double.pi
            let drift = CGPoint(x: 2 * cos(angle), y: 2 * sin(angle))
            // A 7 pt ring (2.8 pt radius plus the stroke) and its handle stay inside the box at any drift.
            let center = CGPoint(x: size.width / 2 - 0.6 + drift.x, y: size.height / 2 - 0.7 + drift.y)
            let radius: CGFloat = 2.8
            let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                              width: radius * 2, height: radius * 2))
            var handle = Path()
            let diagonal = CGFloat(0.5.squareRoot())
            let start = CGPoint(x: center.x + radius * diagonal, y: center.y + radius * diagonal)
            handle.move(to: start)
            handle.addLine(to: CGPoint(x: start.x + 3 * diagonal, y: start.y + 3 * diagonal))
            let style = StrokeStyle(lineWidth: 1.4, lineCap: .round)
            context.stroke(ring, with: .color(Theme.orbLight), style: style)
            context.stroke(handle, with: .color(Theme.orbLight), style: style)
        }
    }
}

/// Two 1.8 pt lines; the lower one grows 3 → 12 pt behind a caret dot, looping every 1.4 s.
private struct WritingGlyph: View {
    let frame: GlyphClock.Frame

    var body: some View {
        Canvas { context, size in
            let lineWidth: CGFloat = 1.8
            let left: CGFloat = 1
            let upperY = size.height / 2 - 2.5
            let lowerY = size.height / 2 + 2.5
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)

            var upper = Path()
            upper.move(to: CGPoint(x: left, y: upperY))
            upper.addLine(to: CGPoint(x: left + 11, y: upperY))
            context.stroke(upper, with: .color(Theme.orbLight.opacity(0.55)), style: style)

            let growth = frame.isStill ? 0.55 : frame.progress(period: 1.4)
            let length = 3 + 9 * CGFloat(growth)
            var lower = Path()
            lower.move(to: CGPoint(x: left, y: lowerY))
            lower.addLine(to: CGPoint(x: left + length - 2.5, y: lowerY))
            context.stroke(lower, with: .color(Theme.orbLight), style: style)

            let caret = CGRect(x: left + length - 0.9, y: lowerY - 0.9, width: 1.8, height: 1.8)
            context.fill(Path(ellipseIn: caret), with: .color(Theme.orbLight))
        }
    }
}

/// A three-quarter arc (11 pt, 1.5 pt stroke) turning once a second round a 2.5 pt dot.
private struct ActionGlyph: View {
    let frame: GlyphClock.Frame

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Theme.orbLight, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 11 - 1.5, height: 11 - 1.5)
                .rotationEffect(.degrees(frame.isStill ? 0 : frame.progress(period: 1.0) * 360))
            Circle()
                .fill(Theme.orbLight)
                .frame(width: 2.5, height: 2.5)
        }
    }
}

/// An amber 5 pt dot with a ring pulsing out from it (scale 1 → 2.2, opacity 0.6 → 0, every 1.6 s).
private struct ApprovalPulse: View {
    let frame: GlyphClock.Frame

    private static let dotSize: CGFloat = 5

    var body: some View {
        let pulse = frame.isStill ? 0.5 : frame.progress(period: 1.6)
        ZStack {
            Circle()
                .stroke(Theme.attention, lineWidth: 1)
                .frame(width: Self.dotSize, height: Self.dotSize)
                .scaleEffect(1 + 1.2 * pulse)
                .opacity(0.6 * (1 - pulse))
            Circle()
                .fill(Theme.attention)
                .frame(width: Self.dotSize, height: Self.dotSize)
        }
    }
}

/// Three bars: the media equalizer (quick, uneven) or Otto speaking (slow, even).
private struct GlyphBars: View {
    enum Style { case equalizer, speaking }

    let style: Style
    let frame: GlyphClock.Frame

    private static let barWidth: CGFloat = 2.5
    private static let spacing: CGFloat = 2.2
    private static let minimumHeight: CGFloat = 3.5
    private static let maximumHeight: CGFloat = 13

    var body: some View {
        HStack(alignment: .center, spacing: Self.spacing) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Theme.orbLight)
                    .frame(width: Self.barWidth, height: height(index))
            }
        }
    }

    private func height(_ index: Int) -> CGFloat {
        let level: Double
        if frame.isStill {
            level = style == .equalizer ? [0.35, 0.75, 0.5][index] : [0.45, 0.6, 0.45][index]
        } else {
            switch style {
            case .equalizer:
                // Two sines per bar at unrelated rates, so the bars never fall into step.
                let periods: [TimeInterval] = [0.88, 0.68, 1.01]
                let wave = frame.wave(period: periods[index], offset: Double(index) * 0.23)
                let wobble = frame.wave(period: periods[(index + 1) % 3] * 2.3, offset: Double(index) * 0.51)
                level = 0.15 + 0.6 * wave + 0.25 * wobble
            case .speaking:
                level = 0.25 + 0.5 * frame.wave(period: 1.6, offset: -0.4 * Double(index))
            }
        }
        let clamped = CGFloat(min(max(level, 0), 1))
        return Self.minimumHeight + (Self.maximumHeight - Self.minimumHeight) * clamped
    }
}

/// An 11 pt hourglass that flips half a turn every 2 s: it rests for 1.6 s, then turns over 0.4 s.
private struct HourglassGlyph: View {
    let frame: GlyphClock.Frame

    private static let period: TimeInterval = 2
    private static let flipDuration: TimeInterval = 0.4

    var body: some View {
        Image(systemName: "hourglass")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .rotationEffect(.degrees(angle))
    }

    private var angle: Double {
        guard !frame.isStill else { return 0 }
        let flips = (frame.time / Self.period).rounded(.down)
        let intoCycle = frame.time - flips * Self.period
        let flipStart = Self.period - Self.flipDuration
        let turning = max(0, intoCycle - flipStart) / Self.flipDuration
        // Ease in and out so the turn reads as a flip, not a spin.
        let eased = (1 - cos(min(turning, 1) * Double.pi)) / 2
        return (flips.truncatingRemainder(dividingBy: 2) + eased) * 180
    }
}

// MARK: - Still glyphs

/// The unread-reply dot: 6 pt of the orb's warm white with a soft glow.
private struct UnreadDot: View {
    var body: some View {
        Circle()
            .fill(Theme.orbLight)
            .frame(width: 6, height: 6)
            .shadow(color: Theme.orbLight.opacity(0.7), radius: 4)
    }
}

/// The ✓ after Otto pastes an answer.
private struct PasteCheckmark: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.orbLight)
    }
}

/// The playing track's artwork, 16 × 16 with 4 pt corners and a hairline edge, or a music note while
/// there is none. Artwork of another track never shows.
private struct ArtworkEar: View {
    let itemID: NowPlayingItem.ID
    let nowPlaying: NowPlayingMonitor

    private static let cornerRadius: CGFloat = 4

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        Group {
            if nowPlaying.item?.id == itemID, let artwork = nowPlaying.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                shape
                    .fill(Color.white.opacity(0.08))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
            }
        }
        .frame(width: EarGlyphView.artworkSize.width, height: EarGlyphView.artworkSize.height)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5) }
    }
}
