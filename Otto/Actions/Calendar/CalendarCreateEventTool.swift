//
//  CalendarCreateEventTool.swift
//  Otto
//
//  `calendar_create_event`: adds one event after the user approves a card that shows the event tile, a
//  calendar picker (unset when the named calendar is missing, read-only or ambiguous), overlapping
//  events, the local rendering of a time given in another zone, and any daylight-saving adjustment.
//  Undo removes the event by identifier, or finds it again by title and dates after a sync changed it.
//

import Foundation

struct CalendarCreateEventTool: OttoTool {
    let eventKit: any EventKitProviding
    let clock: CalendarToolClock

    init(eventKit: any EventKitProviding, clock: CalendarToolClock = .live) {
        self.eventKit = eventKit
        self.clock = clock
    }

    var name: String { "calendar_create_event" }
    var group: ToolGroup? { .calendar }

    var description: String {
        "Create an event in the user's calendar. The user sees a preview and must approve it, and may pick a different calendar. Use local times without an offset unless the user named another time zone. For all-day events set all_day to true and pass dates (YYYY-MM-DD); `end` is then the last day of the event (inclusive). Only create events the user asked for."
    }

    var inputSchema: JSONValue {
        [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "Event title, short (e.g. \"Dentist\")."],
                "start": [
                    "type": "string",
                    "pattern": .string(DateInput.pattern),
                    "description": "Start: YYYY-MM-DDTHH:MM (local) or YYYY-MM-DD for all-day.",
                ],
                "end": [
                    "type": "string",
                    "pattern": .string(DateInput.pattern),
                    "description": "End: YYYY-MM-DDTHH:MM (local), or the last day (YYYY-MM-DD) for all-day events.",
                ],
                "all_day": ["type": "boolean", "description": "True for an all-day event. Defaults to false."],
                "location": ["type": "string", "description": "Optional place or address."],
                "notes": ["type": "string", "description": "Optional notes."],
                "calendar": [
                    "type": "string",
                    "description": "Exact name of a calendar to use. Omit to use the user's default calendar.",
                ],
            ],
            "required": ["title", "start", "end"],
            "additionalProperties": false,
        ]
    }

    var isConcurrencySafe: Bool { false }
    var timeout: Duration { .seconds(15) }
    var rateLimit: ToolRateLimit { ToolRateLimit(perTurn: 5, perHour: nil) }
    var minimumArmingDelay: Duration { .milliseconds(350) }
    var formattedFields: Set<String> { ["start", "end"] }

    /// Tomorrow 3–4 PM in the clock's zone, in "Home".
    var sampleInput: JSONValue {
        let day = DateInput.isoDay(clock.now().addingTimeInterval(86_400), in: clock.timeZone())
        return [
            "title": "Dentist",
            "start": .string("\(day)T15:00"),
            "end": .string("\(day)T16:00"),
            "location": "1 Main St",
            "notes": "Bring the insurance card.",
            "calendar": "Home",
        ]
    }

    @MainActor func isAvailable(in environment: ToolEnvironment) -> Bool {
        environment.isDemo || environment.settings.actions.isEnabled(.calendar)
    }

    func requiredPermissions(for input: JSONValue) -> [Permission] { [.calendars] }

    func approvalRequirement(for input: JSONValue) -> ApprovalRequirement { .everyCall(rememberScope: nil) }

    func validate(_ input: JSONValue) -> ToolError? {
        let checks: [ToolError?] = [
            CalendarToolSupport.checkText(input, "title", required: true, maxLength: 200, singleLine: true),
            CalendarToolSupport.checkText(input, "location", required: false, maxLength: 300, singleLine: true),
            CalendarToolSupport.checkText(input, "notes", required: false, maxLength: 4_000, singleLine: false),
            CalendarToolSupport.checkText(input, "calendar", required: false, maxLength: 200, singleLine: true),
        ]
        if let error = checks.compactMap({ $0 }).first { return error }
        if let allDay = input["all_day"], allDay != .null, allDay.boolValue == nil {
            return CalendarToolSupport.invalid("all_day", "must be true or false")
        }
        do {
            _ = try times(for: input)
            return nil
        } catch let error as ToolError {
            return error
        } catch {
            return CalendarToolSupport.invalid("start", error.localizedDescription)
        }
    }

    func describe(_ input: JSONValue) -> ToolCallPresentation {
        let title = CalendarToolSupport.text(input, "title") ?? "event"
        let timeZone = clock.timeZone()
        var detail: [String] = []
        var doneTitle = "Added “\(title)” to Calendar"
        if let times = try? times(for: input) {
            let when = DateInput.display(times.start, allDay: times.isAllDay, in: timeZone, locale: clock.locale)
            doneTitle = "Added “\(title)” · \(when)"
            detail.append(Self.timeLine(times, in: timeZone, locale: clock.locale, withDay: true))
        }
        if let calendar = CalendarToolSupport.text(input, "calendar") {
            detail.append(calendar)
        }
        return ToolCallPresentation(symbol: "calendar.badge.plus", title: "Add “\(title)” to Calendar",
                                    activeTitle: "Adding to Calendar…", doneTitle: doneTitle,
                                    detail: detail.isEmpty ? nil : detail.joined(separator: " · "), disclosure: nil)
    }

    var preparingPresentation: ToolCallPresentation {
        ToolCallPresentation(symbol: "calendar.badge.plus", title: "Preparing event…", activeTitle: "Adding to Calendar…",
                             doneTitle: "Added to Calendar", detail: nil, disclosure: nil)
    }

    func approvalLabels(for input: JSONValue) -> (confirm: String, decline: String) { ("Add Event", "Don't add") }

    /// Refetches the calendars every time, so the picker reflects a store that was just reset after a grant.
    func approvalBody(for input: JSONValue) async -> ApprovalBody {
        let timeZone = clock.timeZone()
        let locale = clock.locale
        let title = CalendarToolSupport.text(input, "title") ?? ""
        let calendars = await eventKit.calendars(for: .event)
        let defaultID = await eventKit.defaultCalendarID(for: .event)
        let selection = CalendarToolSupport.selection(named: CalendarToolSupport.text(input, "calendar"), in: calendars,
                                                      defaultID: defaultID, noun: "calendar", item: "event")
        var preview = EventPreview(
            title: title, weekday: "", day: "",
            timeLine: "\(input["start"]?.stringValue ?? "") – \(input["end"]?.stringValue ?? "")",
            location: CalendarToolSupport.text(input, "location"),
            notes: CalendarToolSupport.text(input, "notes"),
            calendars: selection.writable.map(CalendarToolSupport.choice),
            selectedCalendarID: selection.selectedID,
            calendarHint: selection.hint,
            conflicts: [], timeZoneNote: nil, adjustmentNote: nil
        )
        guard let times = try? times(for: input) else { return .event(preview) }

        preview.weekday = Self.format(times.start, template: "EEE", in: timeZone, locale: locale).uppercased(with: locale)
        preview.day = Self.format(times.start, template: "d", in: timeZone, locale: locale)
        preview.timeLine = Self.timeLine(times, in: timeZone, locale: locale, withDay: false)
        if !times.isAllDay {
            let others = (try? await eventKit.events(from: times.start, to: times.end, calendarIDs: nil)) ?? []
            preview.conflicts = Self.conflictLines(others, start: times.start, end: times.end, in: timeZone,
                                                   locale: locale)
        }
        preview.timeZoneNote = Self.timeZoneNote(times, in: timeZone, locale: locale)
        preview.adjustmentNote = times.notes.isEmpty ? nil : times.notes.joined(separator: " ")
        return .event(preview)
    }

    func run(_ input: JSONValue, context: ToolRunContext) async throws -> ToolRunResult {
        let timeZone = clock.timeZone()
        let times = try times(for: input)
        let title = CalendarToolSupport.text(input, "title") ?? ""
        let calendars = await eventKit.calendars(for: .event)
        let defaultID = await eventKit.defaultCalendarID(for: .event)
        let selection = CalendarToolSupport.selection(named: CalendarToolSupport.text(input, "calendar"), in: calendars,
                                                      defaultID: defaultID, noun: "calendar", item: "event")
        let chosen = try CalendarToolSupport.chosenID(options: context.options, selection: selection, all: calendars,
                                                      noun: "calendar", item: "event")
        let draft = CalendarEventDraft(title: title, start: times.start, end: times.end, isAllDay: times.isAllDay,
                                       location: CalendarToolSupport.text(input, "location"),
                                       notes: CalendarToolSupport.text(input, "notes"),
                                       timeZone: times.isAllDay ? nil : timeZone)
        try Task.checkCancellation()

        let record: CalendarEventRecord
        do {
            record = try await eventKit.createEvent(draft, calendarID: chosen.id)
        } catch {
            throw CalendarToolSupport.toolError(error, saving: "event", app: "Calendar")
        }

        let calendarName = calendars.first { $0.id == chosen.id }.map { CalendarToolSupport.label($0, among: calendars) }
            ?? record.calendarTitle
        var result: [String: JSONValue] = [
            "status": "created",
            "title": .string(title),
            "all_day": .bool(times.isAllDay),
            "calendar": .string(calendarName),
        ]
        if times.isAllDay {
            result["date"] = .string(DateInput.isoDay(times.start, in: timeZone))
            result["end_date"] = .string(DateInput.isoDay(times.end, in: timeZone))
        } else {
            result["start"] = .string(DateInput.iso(times.start, in: timeZone))
            result["end"] = .string(DateInput.iso(times.end, in: timeZone))
            result["time_zone"] = .string(timeZone.identifier)
        }
        if chosen.changedByUser { result["calendar_changed_by_user"] = true }
        if !times.notes.isEmpty { result["note"] = .string(times.notes.joined(separator: " ")) }

        let when = DateInput.display(times.start, allDay: times.isAllDay, in: timeZone, locale: clock.locale)
        let day = DateInput.display(times.start, allDay: true, in: timeZone, locale: clock.locale)
        let token = UndoToken(
            toolName: name,
            itemID: record.id,
            fallback: UndoFallback(title: record.title, start: record.start, end: record.end,
                                   calendarIdentifier: record.calendarID.isEmpty ? chosen.id : record.calendarID),
            expires: clock.now().addingTimeInterval(ToolLimits.undoWindow.timeInterval),
            doneTitle: "Removed “\(title)”",
            noteForClaude: "the calendar event “\(title)” on \(day) was removed"
        )
        CalendarToolSupport.logger.info("Created event \(record.id, privacy: .public)")
        return ToolRunResult(output: .text(CalendarToolSupport.json(result)), doneTitle: "Added “\(title)” · \(when)",
                             undo: token)
    }

    /// Removes the event by identifier; when a sync or calendar move changed the identifier, searches its calendar
    /// for exactly one event with the same title and dates.
    func undo(_ token: UndoToken) async throws {
        do {
            if try await eventKit.removeEvent(identifier: token.itemID) { return }
        } catch {
            throw CalendarToolSupport.removeError(error, noun: "event", app: "Calendar")
        }
        guard let fallback = token.fallback, let start = fallback.start, let end = fallback.end else {
            throw CalendarToolSupport.alreadyRemoved("event")
        }
        let candidates: [CalendarEventRecord]
        do {
            candidates = try await eventKit.events(from: start.addingTimeInterval(-1), to: end.addingTimeInterval(1),
                                                   calendarIDs: [fallback.calendarIdentifier])
        } catch {
            throw CalendarToolSupport.readError(error, app: "Calendar")
        }
        let matches = candidates.filter {
            $0.title == fallback.title && CalendarToolSupport.sameInstant($0.start, start)
                && CalendarToolSupport.sameInstant($0.end, end)
        }
        guard matches.count <= 1 else { throw CalendarToolSupport.severalMatches("event", app: "Calendar") }
        guard let match = matches.first else { throw CalendarToolSupport.alreadyRemoved("event") }
        do {
            guard try await eventKit.removeEvent(identifier: match.id) else {
                throw CalendarToolSupport.alreadyRemoved("event")
            }
        } catch {
            throw CalendarToolSupport.removeError(error, noun: "event", app: "Calendar")
        }
        CalendarToolSupport.logger.info("Undo found the event again under \(match.id, privacy: .public)")
    }

    // MARK: - Private

    private func times(for input: JSONValue) throws -> DateInput.EventTimes {
        try DateInput.eventTimes(start: input["start"]?.stringValue ?? "", end: input["end"]?.stringValue ?? "",
                                 allDay: CalendarToolSupport.bool(input, "all_day"), now: clock.now(),
                                 in: clock.timeZone(), locale: clock.locale)
    }

    /// "3:00 – 4:00 PM" · "All day" · "Sep 29 – Oct 1" · "Sep 29, 10:00 PM – Sep 30, 1:00 AM".
    /// `withDay` prefixes a single-day line with its date for the row detail ("Tue, Sep 29 · 3:00 – 4:00 PM").
    private static func timeLine(_ times: DateInput.EventTimes, in timeZone: TimeZone, locale: Locale,
                                 withDay: Bool) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameDay = calendar.isDate(times.start, inSameDayAs: times.end)
        let day = DateInput.display(times.start, allDay: true, in: timeZone, locale: locale)
        if times.isAllDay {
            guard !sameDay else { return withDay ? "\(day) · All day" : "All day" }
            return interval(times.start, times.end, template: "MMMd", in: timeZone, locale: locale)
        }
        guard sameDay else {
            return interval(times.start, times.end, template: "MMMdjmm", in: timeZone, locale: locale)
        }
        let hours = interval(times.start, times.end, template: "jmm", in: timeZone, locale: locale)
        return withDay ? "\(day) · \(hours)" : hours
    }

    /// "Overlaps with “Team sync” 3:30 PM", at most two, then "+1 more". All-day and canceled events don't count.
    private static func conflictLines(_ events: [CalendarEventRecord], start: Date, end: Date, in timeZone: TimeZone,
                                      locale: Locale) -> [String] {
        let overlapping = events
            .filter { !$0.isAllDay && $0.status != .canceled && $0.start < end && $0.end > start }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        var lines = overlapping.prefix(2).map { event -> String in
            let title = DisplayText.sanitized(event.title, maxLength: 60)
            let time = DateInput.displayTime(event.start, in: timeZone, locale: locale)
            return title.isEmpty ? "Overlaps with an event at \(time)" : "Overlaps with “\(title)” \(time)"
        }
        if overlapping.count > 2 {
            lines.append("+\(overlapping.count - 2) more")
        }
        return lines
    }

    /// "3:00 PM your time (6:00 PM at UTC−04:00)" when a time was given with an offset other than the user's.
    private static func timeZoneNote(_ times: DateInput.EventTimes, in timeZone: TimeZone, locale: Locale) -> String? {
        guard times.hasAbsoluteInput, let offset = times.inputOffset,
              offset != timeZone.secondsFromGMT(for: times.start),
              let inputZone = TimeZone(secondsFromGMT: offset) else { return nil }
        let local = DateInput.displayTime(times.start, in: timeZone, locale: locale)
        let there = DateInput.displayTime(times.start, in: inputZone, locale: locale)
        let sign = offset < 0 ? "\u{2212}" : "+"
        let minutes = abs(offset) / 60
        let label = String(format: "UTC%@%02d:%02d", sign, minutes / 60, minutes % 60)
        return "\(local) your time (\(there) at \(label))"
    }

    private static func interval(_ start: Date, _ end: Date, template: String, in timeZone: TimeZone,
                                 locale: Locale) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateTemplate = template
        return formatter.string(from: start, to: end)
    }

    private static func format(_ date: Date, template: String, in timeZone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
