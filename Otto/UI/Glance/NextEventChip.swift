//
//  NextEventChip.swift
//  Otto
//
//  The next-meeting chip in the open notch's glance row: a dot in the calendar's color, the event title
//  and how soon it starts ("Standup · 12m"). Click joins the meeting (or opens Calendar when the event
//  has no meeting link); the context menu also copies the link or hides the event. Event titles come
//  from invites anyone can send, so they are plain text, and only allowlisted https meeting links exist.
//

import AppKit
import os
import SwiftUI

struct NextEventChip: View {
    let calendar: CalendarGlance
    /// The widest the chip may be. Below `minimumWidth` it isn't shown at all.
    let maxWidth: CGFloat
    /// Joins the chip's meeting (the view model's `joinNextMeeting()`).
    let onJoin: () -> Void
    /// Opens Calendar; nil opens Calendar.app directly.
    var onOpenCalendar: (() -> Void)?
    /// False while the panel can't be seen: an imminent event's dot stops breathing.
    var isVisible: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    static let height: CGFloat = 26
    static let cornerRadius: CGFloat = 10
    static let horizontalPadding: CGFloat = 9
    static let dotSize: CGFloat = 6
    /// Narrower than this, the title can't show a useful few characters, so the chip hides.
    static let minimumWidth: CGFloat = 64
    /// An imminent event's dot breathes on this loop.
    static let breathPeriod: TimeInterval = 2

    private static let calendarBundleID = "com.apple.iCal"
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Calendar")

    /// Pure. The chip only shows when it gets at least `minimumWidth`.
    static func isShown(maxWidth: CGFloat) -> Bool {
        maxWidth >= minimumWidth
    }

    /// Pure. The chip's text after the dot: "Standup · 12m".
    static func label(for glance: EventGlance) -> (title: String, suffix: String) {
        (DisplayText.sanitized(glance.event.title, maxLength: CalendarEventSnapshot.maxTitleLength),
         "· \(glance.chipSuffix)")
    }

    /// Pure. The tooltip: "Standup in 12 minutes", then the time range and where the link goes
    /// ("2:30 – 2:45 PM · Join on zoom.us", or "· No meeting link").
    static func tooltip(for glance: EventGlance, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let range = formatter.string(from: glance.event.start, to: glance.event.end)
        let destination: String
        if let host = glance.event.meetingLink?.host?.lowercased(), !host.isEmpty {
            destination = "Join on \(host)"
        } else {
            destination = "No meeting link"
        }
        return "\(glance.spokenText)\n\(range) · \(destination)"
    }

    /// Pure. The dot's color from the calendar's RGBA components (0…1); secondary text when unknown.
    static func dotColor(rgba: [Double]?) -> Color {
        guard let rgba, rgba.count >= 3, rgba.allSatisfy(\.isFinite) else { return Theme.textSecondary }
        func channel(_ value: Double) -> Double { min(max(value, 0), 1) }
        let alpha = rgba.count >= 4 ? channel(rgba[3]) : 1
        return Color(.sRGB, red: channel(rgba[0]), green: channel(rgba[1]), blue: channel(rgba[2]),
                     opacity: alpha)
    }

    var body: some View {
        if let glance = calendar.next, Self.isShown(maxWidth: maxWidth) {
            chip(glance)
        }
    }

    private func chip(_ glance: EventGlance) -> some View {
        let label = Self.label(for: glance)
        let hasLink = glance.event.meetingLink != nil
        return Button {
            if hasLink { onJoin() } else { openCalendar() }
        } label: {
            HStack(spacing: 6) {
                dot(glance)
                // The suffix never truncates; the title gives way in its middle.
                HStack(spacing: 0) {
                    Text(label.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(" " + label.suffix)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(Theme.font(12, .medium))
            .foregroundStyle(Theme.chipLabel)
            .padding(.horizontal, Self.horizontalPadding)
            .frame(height: Self.height)
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        }
        .buttonStyle(ChipButtonStyle(isHovering: isHovering))
        .onHover { isHovering = $0 }
        .modifier(WidthCap(maxWidth: maxWidth))
        .help(Self.tooltip(for: glance))
        .contextMenu {
            if hasLink {
                Button("Join Meeting", action: onJoin)
                Button("Copy Meeting Link") { copyLink(glance) }
            }
            Button("Open Calendar", action: openCalendar)
            Button("Hide This Event") { calendar.hide(eventID: glance.event.id) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(glance.spokenText)
        .accessibilityHint(hasLink ? "Joins the meeting" : "Opens Calendar")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if hasLink { onJoin() } else { openCalendar() } }
    }

    @ViewBuilder
    private func dot(_ glance: EventGlance) -> some View {
        let color = Self.dotColor(rgba: glance.event.colorRGBA)
        let breathes = glance.isImminent && !reduceMotion
        if breathes {
            TimelineView(.animation(minimumInterval: GlyphClock.frameInterval, paused: !isVisible)) { context in
                let frame = GlyphClock.frame(at: context.date, reduceMotion: false)
                Circle()
                    .fill(color)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .opacity(1 - 0.55 * frame.wave(period: Self.breathPeriod))
            }
            .frame(width: Self.dotSize, height: Self.dotSize)
        } else {
            Circle()
                .fill(color)
                .frame(width: Self.dotSize, height: Self.dotSize)
        }
    }

    private func openCalendar() {
        if let onOpenCalendar {
            onOpenCalendar()
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.calendarBundleID) else {
            Self.logger.notice("Calendar.app isn't installed")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Self.logger.error("Opening Calendar failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func copyLink(_ glance: EventGlance) {
        guard let link = glance.event.meetingLink else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link.absoluteString, forType: .string)
        Self.logger.info("Copied a meeting link")
    }
}

/// The clay chip: lifts a touch on hover, sinks while pressed.
private struct ChipButtonStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .clay(cornerRadius: NextEventChip.cornerRadius, style: .chip, isPressed: configuration.isPressed,
                  isHighlighted: isHovering && !configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

/// Offers the chip at most `maxWidth` and lets it keep its own (smaller) width, so the clay hugs the text
/// and the title truncates only when it has to.
private struct WidthCap: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        CappedWidthLayout(maxWidth: maxWidth) { content }
    }
}

private struct CappedWidthLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = min(proposal.width ?? maxWidth, maxWidth)
        return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
