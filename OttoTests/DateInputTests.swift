//
//  DateInputTests.swift
//  OttoTests
//
//  DateInput: the accepted formats, real-date checks, daylight-saving gaps and overlaps, the list range
//  (bare end dates, 62 days), event rules (inclusive all-day ends, 14 and 31 days, year slips), reminder
//  due dates, and the ISO and display renderings.
//

import XCTest
@testable import Otto

final class DateInputTests: XCTestCase {
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
    private let english = Locale(identifier: "en_US")
    /// 2026-09-27 21:03:00 UTC = Sunday 2:03 PM in Los Angeles.
    private let now = Date(timeIntervalSince1970: 1_790_542_980)

    // MARK: - Parsing

    func testParsesEveryAcceptedForm() throws {
        XCTAssertEqual(try DateInput.parse("2026-09-29"), .date(DateComponents(year: 2026, month: 9, day: 29)))
        XCTAssertEqual(try DateInput.parse("2026-09-29T15:00"),
                       .localDateTime(DateComponents(year: 2026, month: 9, day: 29, hour: 15, minute: 0, second: 0)))
        XCTAssertEqual(try DateInput.parse("2026-09-29T15:00:30"),
                       .localDateTime(DateComponents(year: 2026, month: 9, day: 29, hour: 15, minute: 0, second: 30)))
        // 2026-09-29 15:00 UTC.
        let utc = Date(timeIntervalSince1970: 1_790_694_000)
        XCTAssertEqual(try DateInput.parse("2026-09-29T15:00Z"), .absolute(utc))
        XCTAssertEqual(try DateInput.parse("2026-09-29T11:00:00-04:00"), .absolute(utc))
        XCTAssertEqual(try DateInput.parse("2026-09-29T20:30+05:30"), .absolute(utc))
    }

    func testRejectsMalformedAndImpossibleInputWithThePath() {
        for bad in ["tomorrow", "2026-9-29", "2026-09-29 15:00", "2026-09-29T15", "2026-02-30", "2027-02-29",
                    "2026-13-01", "2026-00-10", "0000-01-01", "2026-09-29T24:00", "2026-09-29T12:60",
                    "2026-09-29T12:00:61", "2026-09-29T12:00+19:00", "2026-09-29T12:00+05:60"] {
            XCTAssertThrowsError(try DateInput.parse(bad, field: "start"), bad) { error in
                let toolError = error as? ToolError
                XCTAssertEqual(toolError?.code, .invalidInput, bad)
                XCTAssertTrue(toolError?.modelMessage.hasPrefix("$.start: ") ?? false, bad)
                XCTAssertTrue(toolError?.modelMessage.hasSuffix(". Fix the input and call the tool again.") ?? false, bad)
            }
        }
        XCTAssertNoThrow(try DateInput.parse("2028-02-29"), "2028 is a leap year")
    }

    func testPatternMatchesTheParser() {
        for good in ["2026-09-29", "2026-09-29T15:00", "2026-09-29T15:00:00", "2026-09-29T15:00Z",
                     "2026-09-29T15:00:00-07:00"] {
            XCTAssertNotNil(good.range(of: DateInput.pattern, options: .regularExpression), good)
        }
        for bad in ["2026-09-29T15", "2026-09-29T15:00:00.000Z", "29/09/2026", "2026-09-29T15:00-0700", ""] {
            XCTAssertNil(bad.range(of: DateInput.pattern, options: .regularExpression), bad)
        }
    }

    // MARK: - Resolving

    func testBareDateResolvesToMidnight() throws {
        let resolved = DateInput.resolve(try DateInput.parse("2026-09-29"), in: losAngeles)
        XCTAssertFalse(resolved.adjusted)
        XCTAssertEqual(DateInput.iso(resolved.date, in: losAngeles), "2026-09-29T00:00:00-07:00")
    }

    func testDaylightSavingGapMovesForward() throws {
        // Clocks jump from 2:00 to 3:00 on 2027-03-14 in Los Angeles: 2:30 doesn't exist.
        let resolved = DateInput.resolve(try DateInput.parse("2027-03-14T02:30"), in: losAngeles)
        XCTAssertTrue(resolved.adjusted)
        XCTAssertEqual(DateInput.iso(resolved.date, in: losAngeles), "2027-03-14T03:30:00-07:00")
        XCTAssertEqual(resolved.date, Date(timeIntervalSince1970: 1_805_020_200))

        let note = DateInput.adjustmentNote(for: DateComponents(year: 2027, month: 3, day: 14, hour: 2, minute: 30),
                                            resolved: resolved.date, in: losAngeles, locale: english)
        XCTAssertEqual(normalized(note), "2:30 AM doesn't exist on Mar 14 because of daylight saving time, so Otto used 3:30 AM.")
    }

    func testDaylightSavingOverlapTakesTheEarlierTime() throws {
        // Clocks fall back from 2:00 to 1:00 on 2027-11-07: 1:30 happens twice; the PDT one comes first.
        let resolved = DateInput.resolve(try DateInput.parse("2027-11-07T01:30"), in: losAngeles)
        XCTAssertFalse(resolved.adjusted)
        XCTAssertEqual(DateInput.iso(resolved.date, in: losAngeles), "2027-11-07T01:30:00-07:00")
        XCTAssertEqual(resolved.date, Date(timeIntervalSince1970: 1_825_576_200))
    }

    func testAbsoluteTimesIgnoreTheZone() throws {
        let resolved = DateInput.resolve(try DateInput.parse("2026-09-29T22:00Z"), in: losAngeles)
        XCTAssertFalse(resolved.adjusted)
        XCTAssertEqual(DateInput.iso(resolved.date, in: losAngeles), "2026-09-29T15:00:00-07:00")
    }

    // MARK: - List range

    func testBareEndDateIncludesTheWholeDay() throws {
        let range = try DateInput.listRange(start: "2026-09-28", end: "2026-09-28", in: losAngeles, locale: english)
        XCTAssertEqual(DateInput.iso(range.start, in: losAngeles), "2026-09-28T00:00:00-07:00")
        XCTAssertEqual(DateInput.iso(range.end, in: losAngeles), "2026-09-29T00:00:00-07:00")
        XCTAssertEqual(range.notes, [])

        let timed = try DateInput.listRange(start: "2026-09-28T09:00", end: "2026-09-28T17:00", in: losAngeles,
                                            locale: english)
        XCTAssertEqual(DateInput.iso(timed.end, in: losAngeles), "2026-09-28T17:00:00-07:00")
    }

    func testListRangeSpansAtMost62Days() throws {
        // Sep 1 through Nov 1 is 62 whole days, across the fall-back hour.
        XCTAssertNoThrow(try DateInput.listRange(start: "2026-09-01", end: "2026-11-01", in: losAngeles, locale: english))
        assertInvalid(try DateInput.listRange(start: "2026-09-01", end: "2026-11-02", in: losAngeles, locale: english),
                      path: "$.end", containing: "at most 62 days")
        assertInvalid(try DateInput.listRange(start: "2026-09-28T10:00", end: "2026-09-28T09:00", in: losAngeles,
                                              locale: english),
                      path: "$.end", containing: "later than start")
        assertInvalid(try DateInput.listRange(start: "2026-09-28", end: "soon", in: losAngeles, locale: english),
                      path: "$.end", containing: "YYYY-MM-DD")
    }

    // MARK: - Events

    func testAllDayEndIsInclusive() throws {
        let times = try DateInput.eventTimes(start: "2026-09-29", end: "2026-10-01", allDay: true, now: now,
                                             in: losAngeles, locale: english)
        XCTAssertTrue(times.isAllDay)
        XCTAssertEqual(DateInput.iso(times.start, in: losAngeles), "2026-09-29T00:00:00-07:00")
        XCTAssertEqual(DateInput.iso(times.end, in: losAngeles), "2026-10-01T23:59:59-07:00")

        let oneDay = try DateInput.eventTimes(start: "2026-09-29", end: "2026-09-29", allDay: true, now: now,
                                              in: losAngeles, locale: english)
        XCTAssertEqual(DateInput.iso(oneDay.end, in: losAngeles), "2026-09-29T23:59:59-07:00")

        XCTAssertNoThrow(try DateInput.eventTimes(start: "2026-10-01", end: "2026-10-31", allDay: true, now: now,
                                                  in: losAngeles, locale: english))
        assertInvalid(try DateInput.eventTimes(start: "2026-10-01", end: "2026-11-01", allDay: true, now: now,
                                               in: losAngeles, locale: english),
                      path: "$.end", containing: "at most 31 days")
        assertInvalid(try DateInput.eventTimes(start: "2026-10-02", end: "2026-10-01", allDay: true, now: now,
                                               in: losAngeles, locale: english),
                      path: "$.end", containing: "on or after start")
    }

    func testKindsMustMatchAllDay() {
        assertInvalid(try DateInput.eventTimes(start: "2026-09-29T15:00", end: "2026-09-29T16:00", allDay: true, now: now,
                                               in: losAngeles, locale: english),
                      path: "$.start", containing: "all-day events take dates")
        assertInvalid(try DateInput.eventTimes(start: "2026-09-29", end: "2026-09-29T16:00", allDay: false, now: now,
                                               in: losAngeles, locale: english),
                      path: "$.start", containing: "set all_day to true")
        assertInvalid(try DateInput.eventTimes(start: "2026-09-29T15:00", end: "2026-09-30", allDay: false, now: now,
                                               in: losAngeles, locale: english),
                      path: "$.end", containing: "set all_day to true")
    }

    func testTimedEventOrderAndLength() throws {
        assertInvalid(try DateInput.eventTimes(start: "2026-09-29T16:00", end: "2026-09-29T16:00", allDay: false, now: now,
                                               in: losAngeles, locale: english),
                      path: "$.end", containing: "later than start")
        XCTAssertNoThrow(try DateInput.eventTimes(start: "2026-09-29T09:00", end: "2026-10-13T09:00", allDay: false,
                                                  now: now, in: losAngeles, locale: english))
        assertInvalid(try DateInput.eventTimes(start: "2026-09-29T09:00", end: "2026-10-13T09:01", allDay: false, now: now,
                                               in: losAngeles, locale: english),
                      path: "$.end", containing: "at most 14 days")
    }

    func testYearSlipsAreRejected() {
        assertInvalid(try DateInput.eventTimes(start: "2062-09-29T15:00", end: "2062-09-29T16:00", allDay: false, now: now,
                                               in: losAngeles, locale: english),
                      path: "$.start", containing: "check the year")
        assertInvalid(try DateInput.eventTimes(start: "2025-09-01T15:00", end: "2025-09-01T16:00", allDay: false, now: now,
                                               in: losAngeles, locale: english),
                      path: "$.start", containing: "check the year")
        assertInvalid(try DateInput.eventTimes(start: "2016-09-29", end: "2016-09-29", allDay: true, now: now,
                                               in: losAngeles, locale: english),
                      path: "$.start", containing: "check the year")
        assertInvalid(try DateInput.reminderDue("2206-09-29", now: now, in: losAngeles, locale: english),
                      path: "$.due", containing: "check the year")
        XCTAssertNoThrow(try DateInput.eventTimes(start: "2025-10-01T15:00", end: "2025-10-01T16:00", allDay: false,
                                                  now: now, in: losAngeles, locale: english))
        XCTAssertNoThrow(try DateInput.eventTimes(start: "2031-09-01T15:00", end: "2031-09-01T16:00", allDay: false,
                                                  now: now, in: losAngeles, locale: english))
    }

    func testEventTimesCarryOffsetsAndDaylightSavingNotes() throws {
        let absolute = try DateInput.eventTimes(start: "2026-09-29T18:00-04:00", end: "2026-09-29T19:00-04:00",
                                                allDay: false, now: now, in: losAngeles, locale: english)
        XCTAssertTrue(absolute.hasAbsoluteInput)
        XCTAssertEqual(absolute.inputOffset, -14_400)
        XCTAssertEqual(DateInput.iso(absolute.start, in: losAngeles), "2026-09-29T15:00:00-07:00")

        let gap = try DateInput.eventTimes(start: "2027-03-14T02:30", end: "2027-03-14T04:00", allDay: false, now: now,
                                           in: losAngeles, locale: english)
        XCTAssertFalse(gap.hasAbsoluteInput)
        XCTAssertNil(gap.inputOffset)
        XCTAssertEqual(gap.notes.map(normalized),
                       ["2:30 AM doesn't exist on Mar 14 because of daylight saving time, so Otto used 3:30 AM."])
    }

    // MARK: - Reminders

    func testReminderDueDates() throws {
        let dateOnly = try DateInput.reminderDue("2026-09-29", now: now, in: losAngeles, locale: english)
        XCTAssertEqual(dateOnly.components, DateComponents(year: 2026, month: 9, day: 29))
        XCTAssertFalse(dateOnly.hasTime)
        XCTAssertEqual(DateInput.iso(dateOnly.date, in: losAngeles), "2026-09-29T00:00:00-07:00")

        let local = try DateInput.reminderDue("2026-09-29T09:00", now: now, in: losAngeles, locale: english)
        XCTAssertTrue(local.hasTime)
        XCTAssertEqual(local.components.hour, 9)
        XCTAssertEqual(local.components.minute, 0)
        XCTAssertEqual(local.components.day, 29)
        XCTAssertEqual(local.components.timeZone, losAngeles)
        XCTAssertEqual(DateInput.iso(local.date, in: losAngeles), "2026-09-29T09:00:00-07:00")

        let absolute = try DateInput.reminderDue("2026-09-29T16:00Z", now: now, in: losAngeles, locale: english)
        XCTAssertEqual(absolute.components.hour, 9, "converted to local components")
        XCTAssertEqual(absolute.components.timeZone, losAngeles)

        let gap = try DateInput.reminderDue("2027-03-14T02:30", now: now, in: losAngeles, locale: english)
        XCTAssertEqual(gap.components.hour, 3)
        XCTAssertEqual(gap.components.minute, 30)
        XCTAssertEqual(gap.notes.count, 1)
    }

    // MARK: - Rendering

    func testISOAndDisplay() {
        let date = Date(timeIntervalSince1970: 1_790_719_200) // 2026-09-29 22:00 UTC = 3:00 PM PDT
        XCTAssertEqual(DateInput.iso(date, in: losAngeles), "2026-09-29T15:00:00-07:00")
        XCTAssertEqual(DateInput.iso(date, in: .gmt), "2026-09-29T22:00:00+00:00")
        XCTAssertEqual(DateInput.iso(date, in: TimeZone(identifier: "Asia/Kolkata") ?? .gmt), "2026-09-30T03:30:00+05:30")
        XCTAssertEqual(DateInput.isoDay(date, in: losAngeles), "2026-09-29")
        XCTAssertEqual(normalized(DateInput.display(date, allDay: false, in: losAngeles, locale: english)),
                       "Tue, Sep 29, 3:00 PM")
        XCTAssertEqual(DateInput.display(date, allDay: true, in: losAngeles, locale: english), "Tue, Sep 29")
        XCTAssertEqual(normalized(DateInput.displayTime(date, in: losAngeles, locale: english)), "3:00 PM")
    }

    // MARK: - Helpers

    /// Date formatters use narrow and thin no-break spaces; compare with plain ones.
    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{2009}", with: " ")
    }

    private func assertInvalid<T>(_ expression: @autoclosure () throws -> T, path: String, containing text: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let toolError = error as? ToolError else {
                return XCTFail("expected a ToolError, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(toolError.code, .invalidInput, file: file, line: line)
            XCTAssertTrue(toolError.modelMessage.hasPrefix(path + ": "), toolError.modelMessage, file: file, line: line)
            XCTAssertTrue(toolError.modelMessage.contains(text), toolError.modelMessage, file: file, line: line)
            XCTAssertEqual(toolError.userMessage, "Invalid request", file: file, line: line)
        }
    }
}
