//
//  CalendarModels.swift
//  Otto
//
//  Value types and pure rules of the next-meeting chip: the event snapshot read from EventKit, which
//  event the chip shows (NextEventPicker) and which meeting links it trusts (MeetingLinkDetector).
//

import Foundation

struct CalendarEventSnapshot: Equatable, Identifiable, Sendable {
    /// calendarItemIdentifier + "|" + start timestamp.
    let id: String
    /// "Untitled Event" when empty; ≤ 120 chars; control/bidi stripped.
    let title: String
    let start: Date
    let end: Date
    let colorRGBA: [Double]?
    let isAllDay: Bool
    let isCanceled: Bool
    let isDeclined: Bool
    let meetingLink: URL?

    static let untitledTitle = "Untitled Event"
    static let maxTitleLength = 120

    /// Cleans `title` (whatever the source) so every consumer gets display-safe text.
    init(id: String, title: String, start: Date, end: Date, colorRGBA: [Double]?, isAllDay: Bool,
         isCanceled: Bool, isDeclined: Bool, meetingLink: URL?) {
        self.id = id
        let clean = DisplayText.sanitized(title, maxLength: Self.maxTitleLength)
        self.title = clean.isEmpty ? Self.untitledTitle : clean
        self.start = start
        self.end = max(start, end)
        self.colorRGBA = colorRGBA
        self.isAllDay = isAllDay
        self.isCanceled = isCanceled
        self.isDeclined = isDeclined
        self.meetingLink = meetingLink
    }

    /// calendarItemIdentifier + "|" + whole seconds since 1970 of `start` (recurring occurrences differ).
    static func makeID(calendarItemIdentifier: String, start: Date) -> String {
        "\(calendarItemIdentifier)|\(Int(start.timeIntervalSince1970.rounded(.down)))"
    }
}

struct EventGlance: Equatable, Sendable {
    let event: CalendarEventSnapshot
    /// "now" (a minute or less to go, or already running) or "12m" (minutes, rounded up).
    let chipSuffix: String
    /// VoiceOver and the tooltip: "Standup in 12 minutes", "Standup now".
    let spokenText: String
    /// Starts within `NextEventPicker.imminentWindow` (or already running): the chip's dot breathes.
    let isImminent: Bool
}

enum NextEventPicker {
    /// How far ahead the chip looks.
    static let lookahead: TimeInterval = 60 * 60
    /// A meeting that started up to this long ago and hasn't ended still shows, for joining late.
    static let lateJoinWindow: TimeInterval = 10 * 60
    /// Starting this soon marks the chip imminent.
    static let imminentWindow: TimeInterval = 5 * 60
    /// This close to the start, the suffix already says "now".
    static let nowWindow: TimeInterval = 60

    /// The event the chip shows. Only timed, not canceled, not declined, not hidden events count. A
    /// late-join candidate (started ≤ `lateJoinWindow` ago, not over) wins, earliest start first; else the
    /// soonest event starting within `lookahead`. Ties go by title (then id, so the pick is stable).
    static func pick(_ events: [CalendarEventSnapshot], now: Date, hidden: Set<String>) -> EventGlance? {
        let eligible = events.filter { event in
            !event.isAllDay && !event.isCanceled && !event.isDeclined && !hidden.contains(event.id)
        }
        let lateJoin = eligible.filter { event in
            event.start <= now && event.end > now && now.timeIntervalSince(event.start) <= lateJoinWindow
        }
        let upcoming = eligible.filter { event in
            event.start > now && event.start.timeIntervalSince(now) <= lookahead
        }
        guard let best = earliest(lateJoin) ?? earliest(upcoming) else { return nil }
        return glance(for: best, now: now)
    }

    // MARK: - Private

    private static func earliest(_ events: [CalendarEventSnapshot]) -> CalendarEventSnapshot? {
        events.min { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id < rhs.id
        }
    }

    private static func glance(for event: CalendarEventSnapshot, now: Date) -> EventGlance {
        let untilStart = event.start.timeIntervalSince(now)
        if untilStart <= nowWindow {
            return EventGlance(event: event, chipSuffix: "now", spokenText: "\(event.title) now", isImminent: true)
        }
        let minutes = Int((untilStart / 60).rounded(.up))
        return EventGlance(event: event, chipSuffix: "\(minutes)m",
                           spokenText: "\(event.title) in \(minutes) \(minutes == 1 ? "minute" : "minutes")",
                           isImminent: untilStart <= imminentWindow)
    }
}

enum MeetingLinkDetector {
    /// How much of an event's notes the detector scans.
    static let notesScanLimit = 20_000

    /// One allowlisted meeting service: which hosts it answers on and, when it has any, the path prefixes
    /// its join links use.
    private struct Service {
        /// Exact hosts.
        var hosts: Set<String> = []
        /// Parent domains whose subdomains match ("acme.zoom.us" for "zoom.us"); the bare domain doesn't.
        var subdomainsOf: [String] = []
        /// Path prefixes a join link starts with; empty → any path.
        var paths: [String] = []

        func matches(host: String, path: String) -> Bool {
            let hostMatches = hosts.contains(host) || subdomainsOf.contains { host.hasSuffix("." + $0) }
            guard hostMatches else { return false }
            return paths.isEmpty || paths.contains { MeetingLinkDetector.path(path, startsWith: $0) }
        }
    }

    /// glance.md §4.2. https only; anything else is never opened.
    private static let services: [Service] = [
        Service(hosts: ["zoom.us", "zoomgov.com"], subdomainsOf: ["zoom.us"], paths: ["/j/", "/my/", "/w/"]),
        Service(hosts: ["meet.google.com"]),
        Service(hosts: ["teams.microsoft.com", "teams.live.com"], paths: ["/l/meetup-join", "/meet/"]),
        Service(subdomainsOf: ["webex.com"]),
        Service(hosts: ["facetime.apple.com"], paths: ["/join"]),
        Service(hosts: ["meet.goto.com"], subdomainsOf: ["gotomeeting.com"]),
        Service(hosts: ["chime.aws"]),
        Service(hosts: ["whereby.com"]),
    ]

    /// The first allowlisted meeting link in the event's URL field, then its location, then the first
    /// `notesScanLimit` characters of its notes (links found with NSDataDetector). nil when there is none.
    static func link(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, let trusted = trusted(url) { return trusted }
        if let location, let found = firstTrustedLink(in: location) { return found }
        if let notes, let found = firstTrustedLink(in: String(notes.prefix(notesScanLimit))) { return found }
        return nil
    }

    // MARK: - Private

    private static func trusted(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let rawHost = components.host, !rawHost.isEmpty
        else { return nil }
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        // Plain ASCII labels only: no punycode look-alikes, no IP literals with brackets.
        guard host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }),
              !host.hasPrefix("xn--"), !host.contains(".xn--")
        else { return nil }
        let path = components.percentEncodedPath
        return services.contains { $0.matches(host: host, path: path) } ? url : nil
    }

    /// "/j/" matches "/j/123"; "/join" matches "/join" and "/join/…" but not "/joinery".
    fileprivate static func path(_ path: String, startsWith prefix: String) -> Bool {
        if prefix.hasSuffix("/") { return path.hasPrefix(prefix) && path.count > prefix.count }
        return path == prefix || path.hasPrefix(prefix + "/")
    }

    private static func firstTrustedLink(in text: String) -> URL? {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            guard let url = match.url, let trusted = trusted(url) else { continue }
            return trusted
        }
        return nil
    }
}
