//
//  GlanceRow.swift
//  Otto
//
//  The row under the open notch's header on the Chat page (§4.1): the Now Playing strip and the
//  next-meeting chip. With both, the chip sits trailing at its own width and the strip takes the
//  rest; with one, it has the row to itself. The row adds nothing to the layout when neither has
//  anything to show.
//

import SwiftUI

struct GlanceRow: View {
    let nowPlaying: NowPlayingMonitor
    let calendar: CalendarGlance
    /// The view model's `performMedia(_:)`.
    let onMediaCommand: (MediaCommand) -> Void
    /// The view model's `joinNextMeeting()`.
    let onJoinMeeting: () -> Void
    /// Opens Privacy & Security → Automation (the strip's "Open Settings" link).
    let onOpenAutomationSettings: () -> Void
    /// The macOS Automation dialog for the playing app is on screen.
    var isAwaitingMediaConsent: Bool = false
    /// The row's width: the open panel's content width unless the host lays it out narrower.
    var availableWidth: CGFloat = GlanceRow.contentWidth
    /// False while the panel can't be seen: timelines stop ticking.
    var isVisible: Bool = true

    /// The open panel's width inside its side walls and 16 pt padding.
    static let contentWidth: CGFloat = NotchMetrics.openWidth - NotchMetrics.openTopRadius * 2 - 16 * 2
    /// Between the strip and the chip.
    static let spacing: CGFloat = 8
    /// The chip's share of the row while the strip is showing; the strip keeps the rest.
    static let chipShareBesideStrip: CGFloat = 0.42
    /// The strip never gets narrower than this beside the chip.
    static let minimumStripWidth: CGFloat = 220

    /// Pure. The row shows when either child has something.
    static func isShown(hasMedia: Bool, hasEvent: Bool) -> Bool {
        hasMedia || hasEvent
    }

    /// Pure. The widest the chip may be in a row `rowWidth` wide: the whole row alone; beside the strip,
    /// at most `chipShareBesideStrip` of it and never so wide that the strip drops below
    /// `minimumStripWidth`. The chip hides itself when this is under `NextEventChip.minimumWidth`.
    static func chipMaxWidth(rowWidth: CGFloat, hasStrip: Bool) -> CGFloat {
        let width = max(0, rowWidth)
        guard hasStrip else { return width }
        let share = (width * chipShareBesideStrip).rounded(.down)
        let leftOver = width - spacing - minimumStripWidth
        return max(0, min(share, leftOver))
    }

    /// Pure. The row's height: the tallest child present (strip 36, chip 26), 0 when empty. A strip
    /// caption adds to the strip below this.
    static func height(hasMedia: Bool, hasEvent: Bool) -> CGFloat {
        max(hasMedia ? NowPlayingStrip.height : 0, hasEvent ? NextEventChip.height : 0)
    }

    var body: some View {
        let hasMedia = nowPlaying.item != nil
        let hasEvent = calendar.next != nil
        let chipWidth = Self.chipMaxWidth(rowWidth: availableWidth, hasStrip: hasMedia)
        let showsChip = hasEvent && NextEventChip.isShown(maxWidth: chipWidth)
        if Self.isShown(hasMedia: hasMedia, hasEvent: showsChip) {
            HStack(alignment: .top, spacing: Self.spacing) {
                if hasMedia {
                    NowPlayingStrip(monitor: nowPlaying, onCommand: onMediaCommand,
                                    onOpenAutomationSettings: onOpenAutomationSettings,
                                    isAwaitingConsent: isAwaitingMediaConsent, isVisible: isVisible)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
                if showsChip {
                    NextEventChip(calendar: calendar, maxWidth: chipWidth, onJoin: onJoinMeeting,
                                  isVisible: isVisible)
                        // Beside the strip, centred on its 36 pt tray.
                        .padding(.top, hasMedia ? (NowPlayingStrip.height - NextEventChip.height) / 2 : 0)
                        .transition(.opacity)
                }
                if !hasMedia {
                    Spacer(minLength: 0)
                }
            }
            .frame(width: availableWidth, alignment: .leading)
            .animation(Theme.Motion.content, value: hasMedia)
            .animation(Theme.Motion.content, value: showsChip)
        }
    }
}
