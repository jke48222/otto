//
//  NowPlayingStrip.swift
//  Otto
//
//  The Now Playing strip in the open notch's glance row: artwork, title, artist and player, three
//  transport buttons, and a hairline showing the position (extrapolated locally between resyncs, and a
//  seek bar once Otto may control the player). Commands go out through `onCommand`; the view model
//  explains and asks for Automation consent before the first one runs. A caption under the strip says
//  when the macOS dialog is up, when control is off, or when a command failed.
//

import AppKit
import SwiftUI

struct NowPlayingStrip: View {
    let monitor: NowPlayingMonitor
    /// Runs a transport command (the view model's `performMedia(_:)`).
    let onCommand: (MediaCommand) -> Void
    /// Opens Privacy & Security → Automation, from the caption's "Open Settings" link.
    let onOpenAutomationSettings: () -> Void
    /// The macOS Automation dialog for the playing app is on screen.
    var isAwaitingConsent: Bool = false
    /// False while the panel can't be seen: the position stops ticking.
    var isVisible: Bool = true

    static let height: CGFloat = 36
    static let cornerRadius: CGFloat = 12
    static let artworkSize: CGFloat = 26
    static let artworkCornerRadius: CGFloat = 6
    static let artworkInset: CGFloat = 5
    static let controlSize: CGFloat = 26
    static let hairlineHeight: CGFloat = 2
    static let hoveredHairlineHeight: CGFloat = 4
    /// Controls dim to this while Otto isn't allowed to control the player.
    static let deniedControlOpacity: Double = 0.4
    /// VoiceOver's increment and decrement step on the position.
    static let accessibilitySeekStep: TimeInterval = 15

    /// The line under the strip.
    enum Caption: Equatable, Sendable {
        /// "Allow Otto to control ‹App› in the dialog."
        case awaitingConsent(String)
        /// Control is off in System Settings; shown with an "Open Settings" link.
        case denied(String)
        /// The last command failed for another reason ("Spotify didn't respond.").
        case failed(String)

        var text: String {
            switch self {
            case .awaitingConsent(let text), .denied(let text), .failed(let text): return text
            }
        }
    }

    /// Pure. The caption for `item`'s player: the dialog first, then a denial, then the last failure.
    static func caption(for item: NowPlayingItem, consent: BrowserContext.AutomationConsent?,
                        lastControlError: String?, isAwaitingConsent: Bool) -> Caption? {
        let app = item.player.displayName
        if isAwaitingConsent {
            return .awaitingConsent("Allow Otto to control \(app) in the dialog.")
        }
        if consent == .denied {
            return .denied(lastControlError ?? "Otto isn't allowed to control \(app).")
        }
        if let lastControlError, !lastControlError.isEmpty {
            return .failed(lastControlError)
        }
        return nil
    }

    /// Pure. How far through the track `item` is at `date` (0…1), extrapolated from the last known
    /// position while playing. nil when the position or a positive duration is unknown.
    static func progress(of item: NowPlayingItem, at date: Date) -> Double? {
        guard let duration = item.duration, duration > 0, let elapsed = item.elapsed(at: date) else { return nil }
        return min(max(elapsed / duration, 0), 1)
    }

    /// Pure. Seeking needs a known duration and Automation already allowed for the player.
    static func canSeek(_ item: NowPlayingItem, consent: BrowserContext.AutomationConsent?) -> Bool {
        guard let duration = item.duration, duration > 0 else { return false }
        return consent == .authorized
    }

    /// Pure. The position a seek to `fraction` of the bar lands on, clamped to the track.
    static func seekTarget(fraction: Double, duration: TimeInterval) -> TimeInterval {
        guard duration > 0, fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1) * duration
    }

    /// Pure. The second line: "Artist · Spotify", or just the player when the artist is unknown.
    static func subtitle(for item: NowPlayingItem) -> String {
        let artist = DisplayText.sanitized(item.artist, maxLength: 120)
        return artist.isEmpty ? item.player.displayName : "\(artist) · \(item.player.displayName)"
    }

    /// Pure. "3:07", or "1:02:03" past an hour.
    static func clockText(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        let paddedSeconds = secs < 10 ? "0\(secs)" : "\(secs)"
        if hours > 0 {
            let paddedMinutes = minutes < 10 ? "0\(minutes)" : "\(minutes)"
            return "\(hours):\(paddedMinutes):\(paddedSeconds)"
        }
        return "\(minutes):\(paddedSeconds)"
    }

    @State private var isHovering = false

    var body: some View {
        if let item = monitor.item {
            let consent = monitor.consent[item.player]
            let caption = Self.caption(for: item, consent: consent, lastControlError: monitor.lastControlError,
                                       isAwaitingConsent: isAwaitingConsent)
            VStack(alignment: .leading, spacing: 6) {
                tray(item, consent: consent)
                if let caption {
                    captionLine(caption)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: caption)
        }
    }

    // MARK: - Tray

    private func tray(_ item: NowPlayingItem, consent: BrowserContext.AutomationConsent?) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return HStack(spacing: 8) {
            artwork(for: item)
            VStack(alignment: .leading, spacing: 1) {
                Text(DisplayText.sanitized(item.title, maxLength: 200))
                    .font(Theme.font(12.5, .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(Self.subtitle(for: item))
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            controls(for: item)
                .opacity(consent == .denied ? Self.deniedControlOpacity : 1)
        }
        .padding(.leading, Self.artworkInset)
        .padding(.trailing, Self.artworkInset)
        .frame(height: Self.height)
        .overlay {
            ZStack(alignment: .bottom) {
                Color.clear
                PositionHairline(item: item, canSeek: Self.canSeek(item, consent: consent),
                                 isExpanded: isHovering, isVisible: isVisible, onSeek: { onCommand(.seek($0)) })
            }
            .clipShape(shape)
        }
        .clay(cornerRadius: Self.cornerRadius, style: .tray)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    @ViewBuilder
    private func artwork(for item: NowPlayingItem) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.artworkCornerRadius, style: .continuous)
        Group {
            if let image = monitor.artwork {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                shape
                    .fill(Color.white.opacity(0.06))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
            }
        }
        .frame(width: Self.artworkSize, height: Self.artworkSize)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5) }
        .accessibilityHidden(true)
    }

    private func controls(for item: NowPlayingItem) -> some View {
        let isPlaying = item.state == .playing
        return HStack(spacing: 2) {
            TransportButton(symbol: "backward.fill", label: "Previous track") { onCommand(.previous) }
            TransportButton(symbol: isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Pause" : "Play") {
                onCommand(isPlaying ? .pause : .play)
            }
            TransportButton(symbol: "forward.fill", label: "Next track") { onCommand(.next) }
        }
    }

    // MARK: - Caption

    private func captionLine(_ caption: Caption) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(caption.text)
                .font(Theme.font(11.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if case .denied = caption {
                Button("Open Settings", action: onOpenAutomationSettings)
                    .buttonStyle(.plain)
                    .font(Theme.font(11.5, .medium))
                    .foregroundStyle(Theme.link)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Controls

/// A 26 pt ghost circle button: no surface at rest, a faint disc on hover.
private struct TransportButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: NowPlayingStrip.controlSize, height: NowPlayingStrip.controlSize)
                .background { Circle().fill(Color.white.opacity(isHovering ? 0.07 : 0)) }
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.92))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The position along the strip's bottom edge: a 2 pt hairline (4 pt while the strip is hovered),
/// extrapolated once a second while playing. With `canSeek`, a click or drag seeks.
private struct PositionHairline: View {
    let item: NowPlayingItem
    let canSeek: Bool
    let isExpanded: Bool
    let isVisible: Bool
    let onSeek: (TimeInterval) -> Void

    /// The fraction under the pointer while dragging.
    @State private var dragFraction: Double?

    /// Taller than the line so the seek target is easy to hit, short enough to stay clear of the buttons.
    private static let hitHeight: CGFloat = 6

    var body: some View {
        let ticking = isVisible && item.state == .playing && dragFraction == nil
        TimelineView(.animation(minimumInterval: 1, paused: !ticking)) { context in
            let fraction = dragFraction ?? NowPlayingStrip.progress(of: item, at: context.date)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .bottomLeading) {
                    Color.clear
                    if let fraction {
                        line(width: width, fraction: fraction)
                    }
                }
                .contentShape(Rectangle())
                .gesture(seekGesture(width: width), including: canSeek ? .all : .none)
            }
            .frame(height: Self.hitHeight)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue(accessibilityValue(at: context.date))
            .accessibilityAdjustableAction { direction in
                adjust(direction, at: context.date)
            }
        }
        .allowsHitTesting(canSeek)
    }

    private func line(width: CGFloat, fraction: Double) -> some View {
        let height = isExpanded || dragFraction != nil ? NowPlayingStrip.hoveredHairlineHeight : NowPlayingStrip.hairlineHeight
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
            Rectangle()
                .fill(Theme.orbLight.opacity(0.55))
                .frame(width: width * CGFloat(fraction))
        }
        .frame(width: width, height: height)
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dragFraction = fraction(at: value.location.x, width: width)
            }
            .onEnded { value in
                let fraction = fraction(at: value.location.x, width: width)
                dragFraction = nil
                guard let duration = item.duration else { return }
                onSeek(NowPlayingStrip.seekTarget(fraction: fraction, duration: duration))
            }
    }

    private func fraction(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1)
    }

    private func accessibilityValue(at date: Date) -> String {
        guard let elapsed = item.elapsed(at: date) else { return "Unknown" }
        guard let duration = item.duration, duration > 0 else { return NowPlayingStrip.clockText(elapsed) }
        return "\(NowPlayingStrip.clockText(elapsed)) of \(NowPlayingStrip.clockText(duration))"
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection, at date: Date) {
        guard canSeek, let duration = item.duration, duration > 0, let elapsed = item.elapsed(at: date) else { return }
        let step = NowPlayingStrip.accessibilitySeekStep
        switch direction {
        case .increment: onSeek(min(elapsed + step, duration))
        case .decrement: onSeek(max(elapsed - step, 0))
        @unknown default: break
        }
    }
}
