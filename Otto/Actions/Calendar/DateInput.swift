//
//  DateInput.swift
//  Otto
//
//  The dates Claude sends to the calendar and reminder tools: parsing the one accepted format, turning
//  wall-clock times into instants in the user's time zone (daylight-saving gaps move forward, overlaps
//  take the earlier time), the range rules each tool enforces, and the ISO and display renderings.
//

import Foundation

enum DateInput {
    /// DATE_PATTERN: a day, optionally a time, optionally an offset.
    static let pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}(:[0-9]{2})?(Z|[+-][0-9]{2}:[0-9]{2})?)?$"

    /// Longest range `calendar_list_events` reads.
    static let maximumListDays = 62
    /// Longest timed event `calendar_create_event` creates.
    static let maximumTimedEventDays = 14
    /// Longest all-day event, counting the first and last day.
    static let maximumAllDayEventDays = 31
    /// Starts and due dates outside [now − 1 year, now + 5 years] are treated as a mistyped year.
    static let yearsBefore = 1
    static let yearsAfter = 5

    enum Parsed: Equatable, Sendable {
        /// y-m-d, no time (all-day or the whole day).
        case date(DateComponents)
        /// Wall-clock time in the user's time zone.
        case localDateTime(DateComponents)
        /// Had Z or ±HH:MM.
        case absolute(Date)

        var isDate: Bool {
            if case .date = self { return true }
            return false
        }

        var isAbsolute: Bool {
            if case .absolute = self { return true }
            return false
        }
    }

    /// The range `calendar_list_events` reads: start inclusive, end exclusive.
    struct ListRange: Equatable, Sendable {
        let start: Date
        let end: Date
        /// Daylight-saving notes for wall times that don't exist.
        let notes: [String]
    }

    /// The times `calendar_create_event` saves.
    struct EventTimes: Equatable, Sendable {
        /// Timed: the instant. All-day: 00:00 of the first day.
        let start: Date
        /// Timed: the instant. All-day: one second before 00:00 of the day after the last day, as Calendar stores it.
        let end: Date
        let isAllDay: Bool
        /// True when either input carried Z or an offset (the card then shows the local rendering).
        let hasAbsoluteInput: Bool
        /// Seconds from GMT of the first absolute input, for the card's time-zone note.
        let inputOffset: Int?
        /// Daylight-saving notes for wall times that don't exist.
        let notes: [String]
    }

    /// A reminder's due date: components for `dueDateComponents`, and the alarm instant for timed ones.
    struct ReminderDue: Equatable, Sendable {
        let components: DateComponents
        /// Date-only: 00:00 of that day. Timed: the instant (also the alarm).
        let date: Date
        let hasTime: Bool
        let notes: [String]
    }

    // MARK: - Parsing

    /// Parses one DATE_PATTERN string and checks the calendar date, the time and the offset are real.
    /// `field` names the input in the error ("start" → "$.start: …").
    static func parse(_ string: String, field: String = "date") throws -> Parsed {
        let text = string.trimmingCharacters(in: .whitespaces)
        guard text.range(of: pattern, options: .regularExpression) != nil else {
            throw invalid(field, "must look like YYYY-MM-DD or YYYY-MM-DDTHH:MM[:SS], optionally ending in Z or ±HH:MM")
        }
        let characters = Array(text)
        func number(_ range: Range<Int>) -> Int {
            Int(String(characters[range])) ?? -1
        }

        let year = number(0..<4), month = number(5..<7), day = number(8..<10)
        guard year >= 1, (1...12).contains(month), (1...daysInMonth(year: year, month: month)).contains(day) else {
            throw invalid(field, "\(String(characters[0..<10])) isn't a real date")
        }
        guard characters.count > 10 else {
            return .date(DateComponents(year: year, month: month, day: day))
        }

        let hour = number(11..<13), minute = number(14..<16)
        var index = 16
        var second = 0
        if characters.count > 16, characters[16] == ":" {
            second = number(17..<19)
            index = 19
        }
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
            throw invalid(field, "\(String(characters[11..<index])) isn't a real time")
        }
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard index < characters.count else {
            return .localDateTime(components)
        }

        var offset = 0
        if characters[index] != "Z" {
            let sign = characters[index] == "-" ? -1 : 1
            let offsetHours = number((index + 1)..<(index + 3)), offsetMinutes = number((index + 4)..<(index + 6))
            guard (0...18).contains(offsetHours), (0...59).contains(offsetMinutes) else {
                throw invalid(field, "\(String(characters[index...])) isn't a real UTC offset")
            }
            offset = sign * (offsetHours * 3_600 + offsetMinutes * 60)
        }
        let seconds = wallSeconds(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        return .absolute(Date(timeIntervalSince1970: TimeInterval(seconds - offset)))
    }

    // MARK: - Resolving

    /// Resolves to an instant. `.date` → the start of that day. Nonexistent wall times (spring-forward gap) move
    /// forward by the length of the gap (`adjusted` = true); ambiguous times (fall-back) take the earlier occurrence.
    static func resolve(_ parsed: Parsed, in timeZone: TimeZone) -> (date: Date, adjusted: Bool) {
        switch parsed {
        case .absolute(let date):
            return (date, false)
        case .date(let components):
            return resolveWall(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1,
                               hour: 0, minute: 0, second: 0, in: timeZone)
        case .localDateTime(let components):
            return resolveWall(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1,
                               hour: components.hour ?? 0, minute: components.minute ?? 0,
                               second: components.second ?? 0, in: timeZone)
        }
    }

    /// `calendar_list_events`: a bare `start` date means 00:00 of that day and a bare `end` date means 00:00 of the
    /// next day (the whole day is included). Requires end > start and a span of at most 62 days.
    static func listRange(start: String, end: String, in timeZone: TimeZone, locale: Locale) throws -> ListRange {
        let parsedStart = try parse(start, field: "start")
        let parsedEnd = try parse(end, field: "end")
        let resolvedStart = resolve(parsedStart, in: timeZone)
        let resolvedEnd = resolve(nextDayIfDate(parsedEnd), in: timeZone)
        guard resolvedEnd.date > resolvedStart.date else {
            throw invalid("end", "must be later than start (a bare date as end includes that whole day)")
        }
        let calendar = gregorian(in: timeZone)
        let limit = calendar.date(byAdding: .day, value: maximumListDays, to: resolvedStart.date)
            ?? resolvedStart.date.addingTimeInterval(TimeInterval(maximumListDays * 86_400))
        guard resolvedEnd.date <= limit else {
            throw invalid("end", "the range may span at most \(maximumListDays) days")
        }
        var notes: [String] = []
        if resolvedStart.adjusted, case .localDateTime(let components) = parsedStart {
            notes.append(adjustmentNote(for: components, resolved: resolvedStart.date, in: timeZone, locale: locale))
        }
        if resolvedEnd.adjusted, case .localDateTime(let components) = parsedEnd {
            notes.append(adjustmentNote(for: components, resolved: resolvedEnd.date, in: timeZone, locale: locale))
        }
        return ListRange(start: resolvedStart.date, end: resolvedEnd.date, notes: notes)
    }

    /// `calendar_create_event`. Timed: both inputs carry a time, end > start, at most 14 days. All-day: both are
    /// dates, `end` is the last day (inclusive), at most 31 days. Either way the start must fall between a year
    /// before and five years after `now`, which catches a mistyped year.
    static func eventTimes(start: String, end: String, allDay: Bool, now: Date, in timeZone: TimeZone,
                           locale: Locale) throws -> EventTimes {
        let parsedStart = try parse(start, field: "start")
        let parsedEnd = try parse(end, field: "end")
        let calendar = gregorian(in: timeZone)

        if allDay {
            guard case .date(let firstDay) = parsedStart else {
                throw invalid("start", "all-day events take dates (YYYY-MM-DD), not times")
            }
            guard case .date(let lastDay) = parsedEnd else {
                throw invalid("end", "all-day events take dates (YYYY-MM-DD), not times")
            }
            let firstIndex = dayIndex(firstDay), lastIndex = dayIndex(lastDay)
            guard lastIndex >= firstIndex else {
                throw invalid("end", "must be on or after start (end is the last day of an all-day event)")
            }
            guard lastIndex - firstIndex + 1 <= maximumAllDayEventDays else {
                throw invalid("end", "an all-day event can span at most \(maximumAllDayEventDays) days")
            }
            let resolvedStart = resolve(parsedStart, in: timeZone)
            try checkYearWindow(resolvedStart.date, field: "start", now: now, calendar: calendar)
            let dayAfter = resolve(nextDayIfDate(parsedEnd), in: timeZone)
            return EventTimes(start: resolvedStart.date, end: dayAfter.date.addingTimeInterval(-1), isAllDay: true,
                              hasAbsoluteInput: false, inputOffset: nil, notes: [])
        }

        guard !parsedStart.isDate else {
            throw invalid("start", "timed events take a date and time (YYYY-MM-DDTHH:MM); set all_day to true for an all-day event")
        }
        guard !parsedEnd.isDate else {
            throw invalid("end", "timed events take a date and time (YYYY-MM-DDTHH:MM); set all_day to true for an all-day event")
        }
        let resolvedStart = resolve(parsedStart, in: timeZone)
        let resolvedEnd = resolve(parsedEnd, in: timeZone)
        guard resolvedEnd.date > resolvedStart.date else {
            throw invalid("end", "must be later than start")
        }
        let limit = calendar.date(byAdding: .day, value: maximumTimedEventDays, to: resolvedStart.date)
            ?? resolvedStart.date.addingTimeInterval(TimeInterval(maximumTimedEventDays * 86_400))
        guard resolvedEnd.date <= limit else {
            throw invalid("end", "an event can last at most \(maximumTimedEventDays) days")
        }
        try checkYearWindow(resolvedStart.date, field: "start", now: now, calendar: calendar)

        var notes: [String] = []
        if resolvedStart.adjusted, case .localDateTime(let components) = parsedStart {
            notes.append(adjustmentNote(for: components, resolved: resolvedStart.date, in: timeZone, locale: locale))
        }
        if resolvedEnd.adjusted, case .localDateTime(let components) = parsedEnd {
            notes.append(adjustmentNote(for: components, resolved: resolvedEnd.date, in: timeZone, locale: locale))
        }
        let offset = parsedStart.isAbsolute ? offsetSeconds(in: start)
            : parsedEnd.isAbsolute ? offsetSeconds(in: end) : nil
        return EventTimes(start: resolvedStart.date, end: resolvedEnd.date, isAllDay: false,
                          hasAbsoluteInput: parsedStart.isAbsolute || parsedEnd.isAbsolute, inputOffset: offset,
                          notes: notes)
    }

    /// `reminders_create`: a date gives a date-only due date; a time gives y/m/d/h/m in `timeZone` plus an alarm at
    /// that instant (an absolute time is converted to local components first).
    static func reminderDue(_ string: String, now: Date, in timeZone: TimeZone, locale: Locale) throws -> ReminderDue {
        let parsed = try parse(string, field: "due")
        let calendar = gregorian(in: timeZone)
        let resolved = resolve(parsed, in: timeZone)
        try checkYearWindow(resolved.date, field: "due", now: now, calendar: calendar)
        switch parsed {
        case .date(let components):
            return ReminderDue(components: components, date: resolved.date, hasTime: false, notes: [])
        case .localDateTime(let requested):
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: resolved.date)
            components.timeZone = timeZone
            let notes = resolved.adjusted
                ? [adjustmentNote(for: requested, resolved: resolved.date, in: timeZone, locale: locale)] : []
            return ReminderDue(components: components, date: resolved.date, hasTime: true, notes: notes)
        case .absolute:
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: resolved.date)
            components.timeZone = timeZone
            return ReminderDue(components: components, date: resolved.date, hasTime: true, notes: [])
        }
    }

    // MARK: - Rendering

    /// "2026-09-29T15:00:00-07:00" (always a numeric offset, never "Z").
    static func iso(_ date: Date, in timeZone: TimeZone) -> String {
        let components = gregorian(in: timeZone).dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                                from: date)
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let minutes = abs(offset) / 60
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d",
                      components.year ?? 0, components.month ?? 0, components.day ?? 0,
                      components.hour ?? 0, components.minute ?? 0, components.second ?? 0,
                      sign, minutes / 60, minutes % 60)
    }

    /// "2026-09-29".
    static func isoDay(_ date: Date, in timeZone: TimeZone) -> String {
        let components = gregorian(in: timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// "Tue, Sep 29, 3:00 PM" (all-day: "Tue, Sep 29") in the given locale, for rows and cards.
    /// The day and the time are formatted separately and joined with a comma, because a combined template reads
    /// "Tue, Sep 29 at 3:00 PM" on current macOS.
    static func display(_ date: Date, allDay: Bool, in timeZone: TimeZone,
                        locale: Locale = .autoupdatingCurrent) -> String {
        let day = formatter(template: "EEEMMMd", timeZone: timeZone, locale: locale).string(from: date)
        guard !allDay else { return day }
        return "\(day), \(displayTime(date, in: timeZone, locale: locale))"
    }

    /// "3:00 PM" in the given locale.
    static func displayTime(_ date: Date, in timeZone: TimeZone, locale: Locale = .autoupdatingCurrent) -> String {
        formatter(template: "jmm", timeZone: timeZone, locale: locale).string(from: date)
    }

    /// "2:30 AM doesn't exist on Mar 14 because of daylight saving time, so Otto used 3:30 AM."
    static func adjustmentNote(for requested: DateComponents, resolved: Date, in timeZone: TimeZone,
                               locale: Locale) -> String {
        let seconds = wallSeconds(year: requested.year ?? 1970, month: requested.month ?? 1, day: requested.day ?? 1,
                                  hour: requested.hour ?? 0, minute: requested.minute ?? 0,
                                  second: requested.second ?? 0)
        let wall = Date(timeIntervalSince1970: TimeInterval(seconds))
        let requestedTime = formatter(template: "jmm", timeZone: .gmt, locale: locale).string(from: wall)
        let requestedDay = formatter(template: "MMMd", timeZone: .gmt, locale: locale).string(from: wall)
        let usedTime = displayTime(resolved, in: timeZone, locale: locale)
        return "\(requestedTime) doesn't exist on \(requestedDay) because of daylight saving time, so Otto used \(usedTime)."
    }

    // MARK: - Private

    private static func invalid(_ field: String, _ problem: String) -> ToolError {
        ToolError(code: .invalidInput, modelMessage: "$.\(field): \(problem). Fix the input and call the tool again.",
                  userMessage: "Invalid request")
    }

    private static func checkYearWindow(_ date: Date, field: String, now: Date, calendar: Calendar) throws {
        let earliest = calendar.date(byAdding: .year, value: -yearsBefore, to: now)
            ?? now.addingTimeInterval(-TimeInterval(yearsBefore) * 366 * 86_400)
        let latest = calendar.date(byAdding: .year, value: yearsAfter, to: now)
            ?? now.addingTimeInterval(TimeInterval(yearsAfter) * 365 * 86_400)
        guard date >= earliest, date <= latest else {
            throw invalid(field, "must fall between one year ago and five years from now; check the year")
        }
    }

    /// `.date(d)` → `.date(d + 1 day)`; anything else unchanged.
    private static func nextDayIfDate(_ parsed: Parsed) -> Parsed {
        guard case .date(let components) = parsed else { return parsed }
        return .date(civilDate(fromDayIndex: dayIndex(components) + 1))
    }

    /// Seconds from GMT written in an absolute input ("…-04:00" → -14 400, "…Z" → 0).
    private static func offsetSeconds(in string: String) -> Int? {
        let text = string.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("Z") { return 0 }
        let characters = Array(text)
        guard characters.count >= 6 else { return nil }
        let tail = characters[(characters.count - 6)...]
        guard let sign = tail.first, sign == "+" || sign == "-",
              let hours = Int(String(tail.dropFirst().prefix(2))),
              let minutes = Int(String(tail.suffix(2))) else { return nil }
        return (sign == "-" ? -1 : 1) * (hours * 3_600 + minutes * 60)
    }

    private static func resolveWall(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int,
                                    in timeZone: TimeZone) -> (date: Date, adjusted: Bool) {
        let wall = wallSeconds(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        // The offsets in force a day either side of the wall time cover any single transition near it.
        let before = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(wall - 86_400)))
        let after = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(wall + 86_400)))
        let candidates = Set([before, after]).compactMap { offset -> Date? in
            let instant = Date(timeIntervalSince1970: TimeInterval(wall - offset))
            return timeZone.secondsFromGMT(for: instant) == offset ? instant : nil
        }
        if let earliest = candidates.min() {
            return (earliest, false)
        }
        // A gap: reading the wall time with the offset from before the jump lands the same distance past it.
        return (Date(timeIntervalSince1970: TimeInterval(wall - before)), true)
    }

    /// Seconds since 1970 of a wall-clock time read as if it were UTC.
    private static func wallSeconds(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Int {
        dayIndex(year: year, month: month, day: day) * 86_400 + hour * 3_600 + minute * 60 + second
    }

    private static func dayIndex(_ components: DateComponents) -> Int {
        dayIndex(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's days_from_civil).
    private static func dayIndex(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The inverse of `dayIndex` (civil_from_days).
    private static func civilDate(fromDayIndex index: Int) -> DateComponents {
        let shifted = index + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return DateComponents(year: year, month: month, day: day)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    private static func gregorian(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func formatter(template: String, timeZone: TimeZone, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
