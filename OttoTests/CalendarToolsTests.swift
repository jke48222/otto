//
//  CalendarToolsTests.swift
//  OttoTests
//
//  The four calendar and reminder tools against a fake EventKitProviding: result JSON (sorted keys, status,
//  limits), error codes and copy, card bodies (pickers, hints, conflicts, time-zone and daylight-saving
//  notes), WYSIWYG, undo by identifier and by the fallback search after a sync changed the identifier,
//  the store reset on a grant, and the demo service. Nothing here touches the user's calendars.
//

import EventKit
import XCTest
@testable import Otto

final class CalendarToolsTests: XCTestCase {
    private static let losAngeles = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
    /// 2026-09-27 21:03:00 UTC = Sunday 2:03 PM in Los Angeles.
    private static let now = Date(timeIntervalSince1970: 1_790_542_980)
    private static let clock = CalendarToolClock(now: { CalendarToolsTests.now },
                                                 timeZone: { CalendarToolsTests.losAngeles },
                                                 locale: Locale(identifier: "en_US"))

    private static let home = CalendarListInfo(id: "cal-home", title: "Home", source: "iCloud",
                                               colorRGBA: [0.2, 0.4, 0.9, 1], isWritable: true)
    private static let work = CalendarListInfo(id: "cal-work", title: "Work", source: "iCloud", colorRGBA: nil,
                                               isWritable: true)
    private static let holidays = CalendarListInfo(id: "cal-holidays", title: "Holidays", source: "Subscribed",
                                                   colorRGBA: nil, isWritable: false)
    private static let errands = CalendarListInfo(id: "list-errands", title: "Errands", source: "iCloud", colorRGBA: nil,
                                                  isWritable: true)
    private static let groceries = CalendarListInfo(id: "list-groceries", title: "Groceries", source: "iCloud",
                                                    colorRGBA: nil, isWritable: true)

    // MARK: - calendar_list_events

    func testListEventsResultShape() async throws {
        let fake = FakeEventKit()
        await fake.seedEvents([
            event("e1", "Standup", at("2026-09-28T09:30"), at("2026-09-28T09:45"), calendar: Self.work,
                  location: "Zoom", notes: String(repeating: "Agenda. ", count: 60),
                  attendees: (1...12).map { "Person \($0)" }),
            event("e2", "Mom's birthday", at("2026-09-28T00:00"), at("2026-09-28T23:59:59"), calendar: Self.home,
                  allDay: true),
            event("e3", "Offsite", at("2026-09-27T00:00"), at("2026-09-29T23:59:59"), calendar: Self.work, allDay: true),
            event("e4", "Floating call", at("2026-09-28T13:00"), at("2026-09-28T13:30"), calendar: Self.home,
                  status: .tentative, floating: true),
        ])
        let tool = CalendarListEventsTool(eventKit: fake, clock: Self.clock)
        let input: JSONValue = ["start": "2026-09-28", "end": "2026-09-28"]
        XCTAssertNil(tool.validate(input))

        let result = try await tool.run(input, context: context())
        let text = try outputText(result)
        XCTAssertFalse(result.output.isError)
        XCTAssertEqual(try JSONValue.decode(text).encodedString(), text, "compact JSON with sorted keys")
        let json = try JSONValue.decode(text)
        XCTAssertEqual(json["status"], "ok")
        XCTAssertEqual(json["time_zone"], "America/Los_Angeles")
        XCTAssertEqual(json["range"], ["start": "2026-09-28T00:00:00-07:00", "end": "2026-09-29T00:00:00-07:00"])
        XCTAssertEqual(json["count"], 4)
        XCTAssertEqual(json["truncated"], false)
        XCTAssertEqual(result.doneTitle, "Checked your calendar · 4 events")

        let events = try XCTUnwrap(json["events"]?.arrayValue)
        XCTAssertEqual(events.map { $0["title"]?.stringValue }, ["Offsite", "Mom's birthday", "Standup", "Floating call"])

        XCTAssertEqual(events[0], ["title": "Offsite", "date": "2026-09-27", "end_date": "2026-09-29", "all_day": true,
                                   "calendar": "Work", "status": "confirmed"])
        XCTAssertEqual(events[1], ["title": "Mom's birthday", "date": "2026-09-28", "all_day": true, "calendar": "Home",
                                   "status": "confirmed"])

        let standup = events[2]
        XCTAssertEqual(standup["start"], "2026-09-28T09:30:00-07:00")
        XCTAssertEqual(standup["end"], "2026-09-28T09:45:00-07:00")
        XCTAssertEqual(standup["all_day"], false)
        XCTAssertEqual(standup["location"], "Zoom")
        XCTAssertEqual(standup["attendees"]?.arrayValue?.count, 10)
        XCTAssertEqual(standup["attendees_more"], 2)
        XCTAssertLessThanOrEqual(standup["notes"]?.stringValue?.count ?? 0, 300)
        XCTAssertNil(standup["floating"])

        XCTAssertEqual(events[3]["floating"], true)
        XCTAssertEqual(events[3]["status"], "tentative")
        XCTAssertNil(events[3]["location"], "empty fields are left out")

        let fetch = await fake.lastEventFetch
        XCTAssertNil(fetch?.calendarIDs, "no calendar named → all calendars")
    }

    func testListEventsNamedCalendarNotFoundOrAmbiguous() async throws {
        let fake = FakeEventKit()
        let workGoogle = CalendarListInfo(id: "cal-work-google", title: "Work", source: "Google", colorRGBA: nil,
                                          isWritable: true)
        await fake.setCalendars([Self.home, Self.work, workGoogle], for: .event)
        let tool = CalendarListEventsTool(eventKit: fake, clock: Self.clock)

        let missing = await runError(tool, ["start": "2026-09-28", "end": "2026-09-29", "calendar": "Wrk"])
        XCTAssertEqual(missing?.code, .notFound)
        XCTAssertEqual(missing?.toolResultText,
                       "not_found: There is no calendar named “Wrk”. The user's calendars: Home, Work (iCloud), Work (Google).")

        let ambiguous = await runError(tool, ["start": "2026-09-28", "end": "2026-09-29", "calendar": " work "])
        XCTAssertEqual(ambiguous?.code, .ambiguous)
        XCTAssertEqual(ambiguous?.toolResultText,
                       "ambiguous: More than one calendar is named “work”: Work (iCloud), Work (Google). Ask the user which one they mean.")

        _ = try await tool.run(["start": "2026-09-28", "end": "2026-09-29", "calendar": "HOME"], context: context())
        let fetch = await fake.lastEventFetch
        XCTAssertEqual(fetch?.calendarIDs, ["cal-home"], "names match case-insensitively")
    }

    func testListEventsCapsCountAndSize() async throws {
        let fake = FakeEventKit()
        let start = at("2026-09-28T08:00")
        await fake.seedEvents((0..<250).map { index in
            event("e\(index)", "Event \(index)", start.addingTimeInterval(TimeInterval(index * 60)),
                  start.addingTimeInterval(TimeInterval(index * 60 + 30)), calendar: Self.work,
                  notes: String(repeating: "n", count: 400))
        })
        let tool = CalendarListEventsTool(eventKit: fake, clock: Self.clock)
        let result = try await tool.run(["start": "2026-09-28", "end": "2026-09-28"], context: context())
        let text = try outputText(result)
        XCTAssertLessThanOrEqual(text.count, ToolOutput.maxTextCharacters)
        let json = try JSONValue.decode(text)
        let count = try XCTUnwrap(json["count"]?.intValue)
        XCTAssertLessThanOrEqual(count, 200)
        XCTAssertGreaterThan(count, 0)
        XCTAssertEqual(json["events"]?.arrayValue?.count, count)
        XCTAssertEqual(json["truncated"], true)
        XCTAssertEqual(result.doneTitle, "Checked your calendar · 250 events")
    }

    func testListEventsValidation() {
        let tool = CalendarListEventsTool(eventKit: FakeEventKit(), clock: Self.clock)
        XCTAssertEqual(tool.validate(["start": "2026-09-28T10:00", "end": "2026-09-28T09:00"])?.toolResultText,
                       "invalid_input: $.end: must be later than start (a bare date as end includes that whole day). Fix the input and call the tool again.")
        XCTAssertEqual(tool.validate(["start": "2026-09-01", "end": "2026-12-01"])?.code, .invalidInput)
        XCTAssertEqual(tool.validate(["start": "2026-09-28", "end": "2026-09-29",
                                      "calendar": .string(String(repeating: "c", count: 201))])?.toolResultText,
                       "invalid_input: $.calendar: must be at most 200 characters (it has 201). Fix the input and call the tool again.")
        XCTAssertNil(tool.validate(["start": "2026-09-28", "end": "2026-09-29", "calendar": "   "]),
                     "blank counts as missing")
    }

    func testReadToolsAskForConsentOnce() async {
        let events = CalendarListEventsTool(eventKit: FakeEventKit(), clock: Self.clock)
        XCTAssertTrue(events.approvalLabels(for: events.sampleInput) == ("Allow", "Not now"))
        let eventsBody = await events.approvalBody(for: events.sampleInput)
        XCTAssertEqual(eventsBody, .consent(ConsentPreview(
            symbol: "calendar", title: "Let Otto read your calendar?",
            body: "Otto looks at your events only when you ask about your schedule. Event details are sent to Claude to answer.",
            footnote: "Otto won't ask again. You can change this in Settings → Actions.")))

        let reminders = CalendarListRemindersTool(eventKit: FakeEventKit(), clock: Self.clock)
        let remindersBody = await reminders.approvalBody(for: reminders.sampleInput)
        XCTAssertEqual(remindersBody, .consent(ConsentPreview(
            symbol: "checklist", title: "Let Otto read your reminders?",
            body: "Otto looks at your reminders only when you ask about them. Reminder details are sent to Claude to answer.",
            footnote: "Otto won't ask again. You can change this in Settings → Actions.")))

        let presentation = events.describe(["start": "2026-09-28", "end": "2026-09-30", "calendar": "Work"])
        XCTAssertEqual(presentation.title, "Check your calendar")
        XCTAssertEqual(presentation.activeTitle, "Checking your calendar…")
        XCTAssertEqual(presentation.detail, "Mon, Sep 28 – Wed, Sep 30 · Work")
    }

    // MARK: - calendar_create_event: card

    func testCreateEventCardShowsTheTileConflictsAndPicker() async throws {
        let fake = FakeEventKit()
        await fake.seedEvents([
            event("c1", "1:1", at("2026-09-29T15:00"), at("2026-09-29T15:30"), calendar: Self.work),
            event("c2", "Team sync", at("2026-09-29T15:30"), at("2026-09-29T16:00"), calendar: Self.work),
            event("c3", "Focus", at("2026-09-29T15:45"), at("2026-09-29T17:00"), calendar: Self.work),
            event("c4", "Canceled thing", at("2026-09-29T15:10"), at("2026-09-29T15:20"), calendar: Self.work,
                  status: .canceled),
            event("c5", "Holiday", at("2026-09-29T00:00"), at("2026-09-29T23:59:59"), calendar: Self.holidays,
                  allDay: true),
            event("c6", "Later", at("2026-09-29T16:00"), at("2026-09-29T17:00"), calendar: Self.home),
        ])
        let tool = CalendarCreateEventTool(eventKit: fake, clock: Self.clock)
        let input: JSONValue = ["title": "Dentist", "start": "2026-09-29T15:00", "end": "2026-09-29T16:00",
                                "location": "1 Main St", "notes": "Bring the insurance card.", "calendar": "Home"]
        XCTAssertNil(tool.validate(input))
        XCTAssertTrue(tool.approvalLabels(for: input) == ("Add Event", "Don't add"))

        let body = await tool.approvalBody(for: input)
        guard case .event(let preview) = body else { return XCTFail("expected an event body, got \(body)") }
        XCTAssertEqual(preview.title, "Dentist")
        XCTAssertEqual(preview.weekday, "TUE")
        XCTAssertEqual(preview.day, "29")
        XCTAssertEqual(normalized(preview.timeLine), "3:00 – 4:00 PM")
        XCTAssertEqual(preview.location, "1 Main St")
        XCTAssertEqual(preview.notes, "Bring the insurance card.")
        XCTAssertEqual(preview.calendars.map(\.id), ["cal-home", "cal-work"], "read-only calendars aren't offered")
        XCTAssertEqual(preview.calendars.first?.colorRGBA, [0.2, 0.4, 0.9, 1])
        XCTAssertEqual(preview.selectedCalendarID, "cal-home")
        XCTAssertNil(preview.calendarHint)
        XCTAssertEqual(preview.conflicts.map(normalized),
                       ["Overlaps with “1:1” 3:00 PM", "Overlaps with “Team sync” 3:30 PM", "+1 more"])
        XCTAssertNil(preview.timeZoneNote)
        XCTAssertNil(preview.adjustmentNote)
        XCTAssertFalse(body.requiresSelection)

        let presentation = tool.describe(input)
        XCTAssertEqual(presentation.symbol, "calendar.badge.plus")
        XCTAssertEqual(presentation.title, "Add “Dentist” to Calendar")
        XCTAssertEqual(presentation.activeTitle, "Adding to Calendar…")
        XCTAssertEqual(normalized(presentation.doneTitle), "Added “Dentist” · Tue, Sep 29, 3:00 PM")
        XCTAssertEqual(presentation.detail.map(normalized), "Tue, Sep 29 · 3:00 – 4:00 PM · Home")
    }

    func testCreateEventPickerStartsUnsetWhenTheCalendarCantBeUsed() async {
        let fake = FakeEventKit()
        let otherWork = CalendarListInfo(id: "cal-work-google", title: "Work", source: "Google", colorRGBA: nil,
                                         isWritable: true)
        await fake.setCalendars([Self.home, Self.work, otherWork, Self.holidays], for: .event)
        let tool = CalendarCreateEventTool(eventKit: fake, clock: Self.clock)
        let base: JSONValue = ["title": "Dentist", "start": "2026-09-29T15:00", "end": "2026-09-29T16:00"]

        func preview(_ calendar: String?) async -> (EventPreview?, Bool) {
            var input = base
            if let calendar { input = input.setting("calendar", to: .string(calendar)) }
            let body = await tool.approvalBody(for: input)
            guard case .event(let preview) = body else { return (nil, false) }
            return (preview, body.requiresSelection)
        }

        let (missing, missingBlocks) = await preview("Wrk")
        XCTAssertNil(missing?.selectedCalendarID)
        XCTAssertEqual(missing?.calendarHint, "“Wrk” isn't one of your calendars. Pick one.")
        XCTAssertTrue(missingBlocks)

        let (readOnly, readOnlyBlocks) = await preview("Holidays")
        XCTAssertNil(readOnly?.selectedCalendarID)
        XCTAssertEqual(readOnly?.calendarHint, "“Holidays” is read-only. Pick another calendar.")
        XCTAssertTrue(readOnlyBlocks)

        let (ambiguous, ambiguousBlocks) = await preview("Work")
        XCTAssertNil(ambiguous?.selectedCalendarID)
        XCTAssertEqual(ambiguous?.calendarHint, "More than one calendar is named “Work”. Pick one.")
        XCTAssertTrue(ambiguousBlocks)

        let (defaulted, defaultedBlocks) = await preview(nil)
        XCTAssertEqual(defaulted?.selectedCalendarID, "cal-home")
        XCTAssertFalse(defaultedBlocks)

        await fake.setDefault("cal-holidays", for: .event)
        let (readOnlyDefault, readOnlyDefaultBlocks) = await preview(nil)
        XCTAssertNil(readOnlyDefault?.selectedCalendarID, "a read-only default opens the picker unset")
        XCTAssertEqual(readOnlyDefault?.calendarHint, "Pick a calendar for this event.")
        XCTAssertTrue(readOnlyDefaultBlocks)
    }

    func testCalendarsAreRefetchedBeforeEveryPreview() async {
        let fake = FakeEventKit()
        await fake.setCalendars([], for: .event)
        await fake.setDefault(nil, for: .event)
        let tool = CalendarCreateEventTool(eventKit: fake, clock: Self.clock)
        let input: JSONValue = ["title": "Dentist", "start": "2026-09-29T15:00", "end": "2026-09-29T16:00"]

        let before = await tool.approvalBody(for: input)
        XCTAssertTrue(before.requiresSelection, "a store without access shows no calendars")

        // Access arrives, the store is reset and now returns calendars.
        await fake.setCalendars([Self.home, Self.work], for: .event)
        await fake.setDefault("cal-home", for: .event)
        let after = await tool.approvalBody(for: input)
        guard case .event(let preview) = after else { return XCTFail("expected an event body") }
        XCTAssertEqual(preview.calendars.map(\.id), ["cal-home", "cal-work"])
        XCTAssertEqual(preview.selectedCalendarID, "cal-home")
        let fetches = await fake.calendarFetches
        XCTAssertEqual(fetches, 2)
    }

    func testCreateEventCardNotesTimeZoneAndDaylightSaving() async {
        let tool = CalendarCreateEventTool(eventKit: FakeEventKit(), clock: Self.clock)
        let absolute = await tool.approvalBody(for: ["title": "Call with Ana", "start": "2026-09-29T18:00-04:00",
                                                     "end": "2026-09-29T19:00-04:00"])
        guard case .event(let offsetPreview) = absolute else { return XCTFail("expected an event body") }
        XCTAssertEqual(offsetPreview.timeZoneNote.map(normalized), "3:00 PM your time (6:00 PM at UTC\u{2212}04:00)")

        let gap = await tool.approvalBody(for: ["title": "Early run", "start": "2027-03-14T02:30",
                                                "end": "2027-03-14T04:00"])
        guard case .event(let gapPreview) = gap else { return XCTFail("expected an event body") }
        XCTAssertEqual(gapPreview.adjustmentNote.map(normalized),
                       "2:30 AM doesn't exist on Mar 14 because of daylight saving time, so Otto used 3:30 AM.")
        XCTAssertNil(gapPreview.timeZoneNote)
    }

    func testCreateEventValidation() {
        let tool = CalendarCreateEventTool(eventKit: FakeEventKit(), clock: Self.clock)
        let base: JSONValue = ["title": "Dentist", "start": "2026-09-29T15:00", "end": "2026-09-29T16:00"]
        XCTAssertNil(tool.validate(base))
        XCTAssertEqual(tool.validate(base.setting("title", to: "   "))?.toolResultText,
                       "invalid_input: $.title: is required and can't be blank. Fix the input and call the tool again.")
        XCTAssertEqual(tool.validate(base.setting("title", to: .string(String(repeating: "t", count: 201))))?.code,
                       .invalidInput)
        XCTAssertNil(tool.validate(base.setting("title", to: .string(String(repeating: "t", count: 200)))))
        XCTAssertEqual(tool.validate(base.setting("title", to: "Dentist\u{202E}tsitneD"))?.toolResultText,
                       "invalid_input: $.title: contains hidden or direction-changing characters. Fix the input and call the tool again.")
        XCTAssertEqual(tool.validate(base.setting("title", to: "Two\nlines"))?.toolResultText,
                       "invalid_input: $.title: must be a single line. Fix the input and call the tool again.")
        XCTAssertEqual(tool.validate(base.setting("location", to: .string(String(repeating: "l", count: 301))))?.code,
                       .invalidInput)
        XCTAssertEqual(tool.validate(base.setting("notes", to: .string(String(repeating: "n", count: 4_001))))?.code,
                       .invalidInput)
        XCTAssertNil(tool.validate(base.setting("notes", to: "Line one\nLine two")), "notes may span lines")
        XCTAssertEqual(tool.validate(base.setting("all_day", to: true))?.toolResultText,
                       "invalid_input: $.start: all-day events take dates (YYYY-MM-DD), not times. Fix the input and call the tool again.")
        XCTAssertEqual(tool.validate(base.setting("start", to: "2062-09-29T15:00").setting("end", to: "2062-09-29T16:00"))?.code,
                       .invalidInput)
    }

    // MARK: - calendar_create_event: run

    func testCreateEventResultAndUndoToken() async throws {
        let fake = FakeEventKit()
        let tool = CalendarCreateEventTool(eventKit: fake, clock: Self.clock)
        let input: JSONValue = ["title": "Dentist", "start": "2026-09-29T15:00", "end": "2026-09-29T16:00",
                                "location": "1 Main St", "calendar": "Home"]
        let result = try await tool.run(input, context: context())
        let text = try outputText(result)
        XCTAssertEqual(text, #"{"all_day":false,"calendar":"Home","end":"2026-09-29T16:00:00-07:00","start":"2026-09-29T15:00:00-07:00","status":"created","time_zone":"America/Los_Angeles","title":"Dentist"}"#)
        XCTAssertEqual(result.doneTitle.map(normalized), "Added “Dentist” · Tue, Sep 29, 3:00 PM")

        let drafts = await fake.createdEvents
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.calendarID, "cal-home")
        XCTAssertEqual(drafts.first?.draft, CalendarEventDraft(title: "Dentist", start: at("2026-09-29T15:00"),
                                                               end: at("2026-09-29T16:00"), isAllDay: false,
                                                               location: "1 Main St", notes: nil,
                                                               timeZone: Self.losAngeles))

        let token = try XCTUnwrap(result.undo)
        XCTAssertEqual(token.toolName, "calendar_create_event")
        XCTAssertEqual(token.itemID, "event-1")
        XCTAssertEqual(token.fallback, UndoFallback(title: "Dentist", start: at("2026-09-29T15:00"),
                                                    end: at("2026-09-29T16:00"), calendarIdentifier: "cal-home"))
        XCTAssertEqual(token.expires, Self.now.addingTimeInterval(600))
        XCTAssertEqual(token.doneTitle, "Removed “Dentist”")
        XCTAssertEqual(token.noteForClaude, "the calendar event “Dentist” on Tue, Sep 29 was removed")
    }

    func testCreateEventHonorsTheCalendarPickedOnTheCard() async throws {
        let fake = FakeEventKit()
        let tool = CalendarCreateEventTool(eventKit: fake, clock: Self.clock)
        let input: JSONValue = ["title": "Dentist", "start": "2026-09-29T15:00", "end": "2026-09-29T16:00",
                                "calendar": "Home"]
        let picked = try await tool.run(input, context: context(calendar: "cal-work"))
        let json = try JSONValue.decode(outputText(picked))
        XCTAssertEqual(json["calendar"], "Work")
        XCTAssertEqual(json["calendar_changed_by_user"], true)

        let same = try await tool.run(input, context: context(calendar: "cal-home"))
        XCTAssertNil(try JSONValue.decode(outputText(same))["calendar_changed_by_user"])

        let unresolved: JSONValue = input.setting("calendar", to: "Wrk")
        let gone = await runError(tool, unresolved, context: context(calendar: "cal-deleted"))
        XCTAssertEqual(gone?.code, .notFound)
        let unpicked = await runError(tool, unresolved)
        XCTAssertEqual(unpicked?.toolResultText,
                       "not_found: No calendar was picked for the event. Ask the user which calendar to use.")
        let resolved = try await tool.run(unresolved, context: context(calendar: "cal-work"))
        XCTAssertEqual(try JSONValue.decode(outputText(resolved))["calendar"], "Work")
    }

    func testCreateAllDayEvent() async throws {
        let fake = FakeEventKit()
        let tool = CalendarCreateEventTool(eventKit: fake, clock: Self.clock)
        let input: JSONValue = ["title": "Conference", "start": "2026-09-29", "end": "2026-10-01", "all_day": true]
        XCTAssertNil(tool.validate(input))

        let body = await tool.approvalBody(for: input)
        guard case .event(let preview) = body else { return XCTFail("expected an event body") }
        XCTAssertEqual(normalized(preview.timeLine), "Sep 29 – Oct 1")
        XCTAssertEqual(preview.conflicts, [])

        let result = try await tool.run(input, context: context())
        let json = try JSONValue.decode(outputText(result))
        XCTAssertEqual(json["all_day"], true)
        XCTAssertEqual(json["date"], "2026-09-29")
        XCTAssertEqual(json["end_date"], "2026-10-01")
        XCTAssertNil(json["start"])
        XCTAssertEqual(result.doneTitle, "Added “Conference” · Tue, Sep 29")
        let draft = await fake.createdEvents.first?.draft
        XCTAssertEqual(draft?.isAllDay, true)
        XCTAssertNil(draft?.timeZone)
        XCTAssertEqual(draft?.start, at("2026-09-29T00:00"))
        XCTAssertEqual(draft?.end, at("2026-10-01T23:59:59"))

        let single = await tool.approvalBody(for: ["title": "Day off", "start": "2026-09-29", "end": "2026-09-29",
                                                   "all_day": true])
        guard case .event(let singlePreview) = single else { return XCTFail("expected an event body") }
        XCTAssertEqual(singlePreview.timeLine, "All day")
    }

    func testCreateEventAdjustedForDaylightSavingSaysSo() async throws {
        let tool = CalendarCreateEventTool(eventKit: FakeEventKit(), clock: Self.clock)
        let result = try await tool.run(["title": "Early run", "start": "2027-03-14T02:30", "end": "2027-03-14T04:00"],
                                        context: context())
        let json = try JSONValue.decode(outputText(result))
        XCTAssertEqual(json["start"], "2027-03-14T03:30:00-07:00")
        XCTAssertEqual(json["note"]?.stringValue.map(normalized),
                       "2:30 AM doesn't exist on Mar 14 because of daylight saving time, so Otto used 3:30 AM.")
    }

    func testCreateEventErrors() async {
        let fake = FakeEventKit()
        let tool = CalendarCreateEventTool(eventKit: fake, clock: Self.clock)
        let input: JSONValue = ["title": "Dentist", "start": "2026-09-29T15:00", "end": "2026-09-29T16:00"]

        let readOnly = await runError(tool, input, context: context(calendar: "cal-holidays"))
        XCTAssertEqual(readOnly?.toolResultText, "failed: “Holidays” is read-only.")
        XCTAssertEqual(readOnly?.userMessage, "“Holidays” is read-only")

        await fake.setSaveError(.saveFailed("The calendar is full"))
        let failed = await runError(tool, input)
        XCTAssertEqual(failed?.toolResultText, "failed: Calendar couldn't save the event (The calendar is full).")
        XCTAssertEqual(failed?.userMessage, "Calendar couldn't save the event")
    }

    // MARK: - calendar_create_event: undo

    func testUndoRemovesTheEventByIdentifier() async throws {
        let fake = FakeEventKit()
        let tool = CalendarCreateEventTool(eventKit: fake, clock: Self.clock)
        let result = try await tool.run(["title": "Dentist", "start": "2026-09-29T15:00", "end": "2026-09-29T16:00"],
                                        context: context())
        let token = try XCTUnwrap(result.undo)
        try await tool.undo(token)
        let remaining = await fake.storedEvents
        XCTAssertEqual(remaining, [])
        let removals = await fake.eventRemovals
        XCTAssertEqual(removals, ["event-1"])
        let fallbackSearches = await fake.eventFetches
        XCTAssertEqual(fallbackSearches, 0, "no search when the identifier still works")
    }

    func testUndoFindsTheEventAfterItsIdentifierChanged() async throws {
        let fake = FakeEventKit()
        await fake.seedEvents([
            event("other", "Dentist", at("2026-09-29T15:00"), at("2026-09-29T16:00"), calendar: Self.work),
            event("other-2", "Checkup", at("2026-09-29T15:00"), at("2026-09-29T16:00"), calendar: Self.home),
        ])
        let tool = CalendarCreateEventTool(eventKit: fake, clock: Self.clock)
        let result = try await tool.run(["title": "Dentist", "start": "2026-09-29T15:00", "end": "2026-09-29T16:00",
                                         "calendar": "Home"], context: context())
        let token = try XCTUnwrap(result.undo)

        // A full sync gives the event a new identifier.
        await fake.renameEvent("event-1", to: "event-1-synced")
        try await tool.undo(token)

        let remaining = await fake.storedEvents.map(\.id)
        XCTAssertEqual(remaining.sorted(), ["other", "other-2"], "only the created event is removed")
        let removals = await fake.eventRemovals
        XCTAssertEqual(removals, ["event-1", "event-1-synced"])
        let search = await fake.lastEventFetch
        XCTAssertEqual(search?.calendarIDs, ["cal-home"])
        XCTAssertEqual(search?.start, at("2026-09-29T14:59:59"))
        XCTAssertEqual(search?.end, at("2026-09-29T16:00:01"))
    }

    func testUndoReportsARemovedOrDuplicatedEvent() async throws {
        let fake = FakeEventKit()
        let tool = CalendarCreateEventTool(eventKit: fake, clock: Self.clock)
        let input: JSONValue = ["title": "Dentist", "start": "2026-09-29T15:00", "end": "2026-09-29T16:00"]

        let first = try await tool.run(input, context: context())
        let firstToken = try XCTUnwrap(first.undo)
        _ = try await fake.removeEvent(identifier: "event-1")
        do {
            try await tool.undo(firstToken)
            XCTFail("undo must fail when the event is gone")
        } catch let error as ToolError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertEqual(error.userMessage, "the event was already removed")
        }

        let second = try await tool.run(input, context: context())
        let secondToken = try XCTUnwrap(second.undo)
        await fake.renameEvent(secondToken.itemID, to: "copy-a")
        await fake.seedEvents([event("copy-b", "Dentist", at("2026-09-29T15:00"), at("2026-09-29T16:00"),
                                     calendar: Self.home)])
        do {
            try await tool.undo(secondToken)
            XCTFail("undo must refuse to guess between two matches")
        } catch let error as ToolError {
            XCTAssertEqual(error.code, .ambiguous)
            XCTAssertEqual(error.userMessage, "more than one matching event, so remove it in Calendar")
        }
        let remaining = await fake.storedEvents.map(\.id)
        XCTAssertEqual(remaining.sorted(), ["copy-a", "copy-b"])
    }

    // MARK: - reminders_list

    func testListRemindersResultShapeAndOrder() async throws {
        let fake = FakeEventKit()
        let created = at("2026-09-20T08:00")
        await fake.seedReminders([
            reminder("r1", "Buy stamps", list: Self.errands, created: created),
            reminder("r2", "Call plumber", list: Self.errands, due: "2026-09-28T09:00", priority: 1,
                     notes: String(repeating: "x", count: 400), created: created),
            reminder("r3", "Pay rent", list: Self.groceries, due: "2026-09-27", priority: 5, created: created),
            reminder("r4", "Water plants", list: Self.errands, created: created.addingTimeInterval(-60)),
            reminder("r5", "Old task", list: Self.errands, priority: 9, completed: at("2026-09-25T10:00"),
                     created: created),
        ])
        let tool = CalendarListRemindersTool(eventKit: fake, clock: Self.clock)
        XCTAssertNil(tool.validate([:]))

        let result = try await tool.run([:], context: context())
        let text = try outputText(result)
        XCTAssertEqual(try JSONValue.decode(text).encodedString(), text, "compact JSON with sorted keys")
        let json = try JSONValue.decode(text)
        XCTAssertEqual(json["status"], "ok")
        XCTAssertEqual(json["time_zone"], "America/Los_Angeles")
        XCTAssertEqual(json["count"], 4)
        XCTAssertEqual(json["truncated"], false)
        XCTAssertEqual(result.doneTitle, "Checked your reminders · 4 reminders")
        let filter = await fake.lastReminderFetch
        XCTAssertEqual(filter?.filter, .incomplete)
        XCTAssertNotNil(filter)
        XCTAssertNil(filter?.listIDs)

        let reminders = try XCTUnwrap(json["reminders"]?.arrayValue)
        XCTAssertEqual(reminders.map { $0["title"]?.stringValue }, ["Pay rent", "Call plumber", "Water plants", "Buy stamps"],
                       "dated first by due date, then undated by creation")
        XCTAssertEqual(reminders[0], ["title": "Pay rent", "list": "Groceries", "due": "2026-09-27", "priority": "medium"])
        XCTAssertEqual(reminders[1]["due"], "2026-09-28T09:00:00-07:00")
        XCTAssertEqual(reminders[1]["priority"], "high")
        XCTAssertLessThanOrEqual(reminders[1]["notes"]?.stringValue?.count ?? 0, 300)
        XCTAssertEqual(reminders[3], ["title": "Buy stamps", "list": "Errands"])

        let withCompleted = try await tool.run(["list": "errands", "include_completed": true], context: context())
        let completedJSON = try JSONValue.decode(outputText(withCompleted))
        let lastFetch = await fake.lastReminderFetch
        XCTAssertEqual(lastFetch?.listIDs, ["list-errands"])
        XCTAssertEqual(lastFetch?.filter, .incompleteAndCompleted(since: Self.now.addingTimeInterval(-30 * 86_400)))
        let old = completedJSON["reminders"]?.arrayValue?.first { $0["title"] == "Old task" }
        XCTAssertEqual(old?["completed"], "2026-09-25")
        XCTAssertEqual(old?["priority"], "low")
    }

    func testListRemindersErrors() async {
        let tool = CalendarListRemindersTool(eventKit: FakeEventKit(), clock: Self.clock)
        let missing = await runError(tool, ["list": "Chores"])
        XCTAssertEqual(missing?.toolResultText, "not_found: There is no list named “Chores”. The user's lists: Errands, Groceries.")
        XCTAssertEqual(tool.validate(["include_completed": "yes"])?.code, .invalidInput)
        XCTAssertEqual(CalendarListRemindersTool.priorityName(0), nil)
        XCTAssertEqual(CalendarListRemindersTool.priorityName(4), "high")
        XCTAssertEqual(CalendarListRemindersTool.priorityName(6), "low")
    }

    // MARK: - reminders_create

    func testCreateReminderCardResultAndDraft() async throws {
        let fake = FakeEventKit()
        let tool = CalendarCreateReminderTool(eventKit: fake, clock: Self.clock)
        let input: JSONValue = ["title": "Call the plumber", "due": "2026-09-29T09:00", "notes": "Kitchen sink.",
                                "list": "Errands"]
        XCTAssertNil(tool.validate(input))
        XCTAssertTrue(tool.approvalLabels(for: input) == ("Add Reminder", "Don't add"))

        let body = await tool.approvalBody(for: input)
        XCTAssertEqual(body, .reminder(ReminderPreview(
            title: "Call the plumber", dueLine: DateInput.display(at("2026-09-29T09:00"), allDay: false,
                                                                   in: Self.losAngeles, locale: Locale(identifier: "en_US")),
            hasAlert: true, notes: "Kitchen sink.",
            lists: [CalendarToolSupport.choice(Self.errands), CalendarToolSupport.choice(Self.groceries)],
            selectedListID: "list-errands", listHint: nil)))

        let result = try await tool.run(input, context: context())
        let text = try outputText(result)
        XCTAssertEqual(text, #"{"alert":true,"due":"2026-09-29T09:00:00-07:00","list":"Errands","status":"created","title":"Call the plumber"}"#)
        XCTAssertEqual(result.doneTitle.map(normalized), "Added “Call the plumber” · Tue, Sep 29, 9:00 AM")

        let created = await fake.createdReminders
        let draft = try XCTUnwrap(created.first)
        XCTAssertEqual(draft.listID, "list-errands")
        XCTAssertEqual(draft.draft.due?.hour, 9)
        XCTAssertEqual(draft.draft.due?.day, 29)
        XCTAssertEqual(draft.draft.due?.timeZone, Self.losAngeles)
        XCTAssertEqual(draft.draft.alarmDate, at("2026-09-29T09:00"))
        XCTAssertEqual(draft.draft.notes, "Kitchen sink.")

        let token = try XCTUnwrap(result.undo)
        XCTAssertEqual(token.toolName, "reminders_create")
        XCTAssertEqual(token.itemID, "reminder-1")
        XCTAssertEqual(token.fallback, UndoFallback(title: "Call the plumber", start: at("2026-09-29T09:00"), end: nil,
                                                    calendarIdentifier: "list-errands"))
        XCTAssertEqual(token.doneTitle, "Removed “Call the plumber”")
        XCTAssertEqual(token.noteForClaude, "the reminder “Call the plumber” was removed")
    }

    func testCreateReminderDateOnlyAndUndatedAndPicker() async throws {
        let fake = FakeEventKit()
        let tool = CalendarCreateReminderTool(eventKit: fake, clock: Self.clock)

        let dated = try await tool.run(["title": "Pay rent", "due": "2026-10-01"], context: context())
        XCTAssertEqual(try outputText(dated), #"{"due":"2026-10-01","list":"Errands","status":"created","title":"Pay rent"}"#)
        let first = await fake.createdReminders.first?.draft
        XCTAssertEqual(first?.due, DateComponents(year: 2026, month: 10, day: 1))
        XCTAssertNil(first?.alarmDate, "date-only reminders get no alarm")

        let undated = try await tool.run(["title": "Buy stamps", "list": "Groceries"], context: context(calendar: "list-errands"))
        XCTAssertEqual(try outputText(undated),
                       #"{"list":"Errands","list_changed_by_user":true,"status":"created","title":"Buy stamps"}"#)
        XCTAssertEqual(undated.doneTitle, "Added “Buy stamps” to Reminders")

        let body = await tool.approvalBody(for: ["title": "Buy stamps", "list": "Chores"])
        guard case .reminder(let preview) = body else { return XCTFail("expected a reminder body") }
        XCTAssertNil(preview.selectedListID)
        XCTAssertEqual(preview.listHint, "“Chores” isn't one of your lists. Pick one.")
        XCTAssertFalse(preview.hasAlert)
        XCTAssertNil(preview.dueLine)
        XCTAssertTrue(body.requiresSelection)

        XCTAssertEqual(tool.validate(["title": .string(String(repeating: "r", count: 501))])?.code, .invalidInput)
        XCTAssertNil(tool.validate(["title": .string(String(repeating: "r", count: 500))]))
        XCTAssertEqual(tool.validate(["title": "Pay rent", "due": "2026-02-30"])?.toolResultText,
                       "invalid_input: $.due: 2026-02-30 isn't a real date. Fix the input and call the tool again.")
    }

    func testUndoReminderByIdentifierAndByFallback() async throws {
        let fake = FakeEventKit()
        let tool = CalendarCreateReminderTool(eventKit: fake, clock: Self.clock)
        let input: JSONValue = ["title": "Call the plumber", "due": "2026-09-29T09:00", "list": "Errands"]

        let first = try await tool.run(input, context: context())
        try await tool.undo(try XCTUnwrap(first.undo))
        let afterFirst = await fake.storedReminders
        XCTAssertEqual(afterFirst, [])

        await fake.seedReminders([reminder("other", "Call the plumber", list: Self.errands, due: "2026-09-30T09:00",
                                           created: Self.now)])
        let second = try await tool.run(input, context: context())
        let token = try XCTUnwrap(second.undo)
        await fake.renameReminder(token.itemID, to: "synced")
        try await tool.undo(token)
        let remaining = await fake.storedReminders.map(\.id)
        XCTAssertEqual(remaining, ["other"], "the same title on another day is left alone")
        let search = await fake.lastReminderFetch
        XCTAssertEqual(search?.listIDs, ["list-errands"])
        XCTAssertEqual(search?.filter, .all)

        let third = try await tool.run(["title": "Buy stamps"], context: context())
        let thirdToken = try XCTUnwrap(third.undo)
        _ = try await fake.removeReminder(identifier: thirdToken.itemID)
        do {
            try await tool.undo(thirdToken)
            XCTFail("undo must fail when the reminder is gone")
        } catch let error as ToolError {
            XCTAssertEqual(error.userMessage, "the reminder was already removed")
        }
    }

    func testASecondUndoNeverRemovesALookalike() async throws {
        let fake = FakeEventKit()
        let tool = CalendarCreateEventTool(eventKit: fake, clock: Self.clock)
        let result = try await tool.run(["title": "Dentist", "start": "2026-09-29T15:00", "end": "2026-09-29T16:00",
                                         "calendar": "Home"], context: context())
        let token = try XCTUnwrap(result.undo)
        try await tool.undo(token)

        // The user adds the same event by hand; a repeated Undo must not take it.
        await fake.seedEvents([event("user-copy", "Dentist", at("2026-09-29T15:00"), at("2026-09-29T16:00"),
                                     calendar: Self.home)])
        do {
            try await tool.undo(token)
            XCTFail("a second undo must report the event as removed")
        } catch let error as ToolError {
            XCTAssertEqual(error.code, .notFound)
        }
        let remaining = await fake.storedEvents.map(\.id)
        XCTAssertEqual(remaining, ["user-copy"])
    }

    func testReminderFallbackSkipsCompletedAndOlderLookalikes() async throws {
        let fake = FakeEventKit()
        let tool = CalendarCreateReminderTool(eventKit: fake, clock: Self.clock)
        await fake.seedReminders([
            reminder("older", "Buy milk", list: Self.errands, created: Self.now.addingTimeInterval(-86_400)),
            reminder("done", "Buy milk", list: Self.errands, completed: Self.now, created: Self.now),
        ])
        let token = UndoToken(toolName: tool.name, itemID: "synced-away",
                              fallback: UndoFallback(title: "Buy milk", start: nil, end: nil,
                                                     calendarIdentifier: Self.errands.id, created: Self.now),
                              expires: Self.now.addingTimeInterval(600), doneTitle: "Removed “Buy milk”",
                              noteForClaude: "the reminder “Buy milk” was removed")
        do {
            try await tool.undo(token)
            XCTFail("neither the older nor the completed reminder is the one Otto created")
        } catch let error as ToolError {
            XCTAssertEqual(error.code, .notFound)
        }
        let remaining = await fake.storedReminders.map(\.id)
        XCTAssertEqual(remaining.sorted(), ["done", "older"])
    }

    // MARK: - WYSIWYG

    /// Every string the model wrote (except formatted dates) is shown verbatim on the card, so what the user approves
    /// is what gets saved.
    func testCardsShowEveryInputStringVerbatim() async throws {
        let fake = FakeEventKit()
        let creates: [any OttoTool] = [CalendarCreateEventTool(eventKit: fake, clock: Self.clock),
                                       CalendarCreateReminderTool(eventKit: fake, clock: Self.clock)]
        for tool in creates {
            let input = tool.sampleInput
            XCTAssertNil(tool.validate(input), tool.name)
            let shown = await tool.approvalBody(for: input).displayedStrings
            for (key, value) in input.objectValue ?? [:] where !tool.formattedFields.contains(key) {
                guard let text = value.stringValue else { continue }
                XCTAssertTrue(shown.contains { $0.contains(text) }, "\(tool.name).\(key) “\(text)” is not on the card")
            }
        }

        // Reads show a consent card; the header (title and detail) names what they read.
        let reads: [any OttoTool] = [CalendarListEventsTool(eventKit: fake, clock: Self.clock),
                                     CalendarListRemindersTool(eventKit: fake, clock: Self.clock)]
        for tool in reads {
            let input = tool.sampleInput
            let presentation = tool.describe(input)
            let shown = [presentation.title, presentation.detail ?? ""]
            for (key, value) in input.objectValue ?? [:] where !tool.formattedFields.contains(key) {
                guard let text = value.stringValue else { continue }
                XCTAssertTrue(shown.contains { $0.contains(text) }, "\(tool.name).\(key) “\(text)” is not shown")
            }
        }
    }

    func testDescribeNeverCrashesOnOddInput() async {
        let fake = FakeEventKit()
        let tools: [any OttoTool] = [CalendarListEventsTool(eventKit: fake, clock: Self.clock),
                                     CalendarCreateEventTool(eventKit: fake, clock: Self.clock),
                                     CalendarListRemindersTool(eventKit: fake, clock: Self.clock),
                                     CalendarCreateReminderTool(eventKit: fake, clock: Self.clock)]
        for tool in tools {
            for input: JSONValue in [[:], ["start": 3, "due": "nope", "title": .null], .null] {
                _ = tool.describe(input)
                _ = await tool.approvalBody(for: input)
                if tool.name != "reminders_list" {
                    XCTAssertNotNil(tool.validate(input), tool.name)
                }
            }
        }
    }

    // MARK: - Store reset on grant

    func testGrantObserverForwardsOnlyCalendarsAndReminders() {
        let center = NotificationCenter()
        let received = LockedList<Permission>()
        let observer = CalendarGrantObserver(center: center)
        observer.setHandler { received.append($0) }
        PermissionEvents.post(.calendars, center: center)
        PermissionEvents.post(.microphone, center: center)
        PermissionEvents.post(.reminders, center: center)
        PermissionEvents.post(.automation(bundleID: "com.apple.Music", appName: "Music"), center: center)
        XCTAssertEqual(received.items, [.calendars, .reminders])
    }

    func testEventKitServiceResetsItsStoreWhenAccessIsGranted() async throws {
        let center = NotificationCenter()
        let store = ResetCountingEventStore()
        let service = EventKitService(store: store, notificationCenter: center)

        PermissionEvents.post(.microphone, center: center)
        PermissionEvents.post(.calendars, center: center)
        try await waitUntil { await service.resetCount == 1 }
        XCTAssertEqual(store.resets, 1)

        PermissionEvents.post(.reminders, center: center)
        try await waitUntil { await service.resetCount == 2 }
        XCTAssertEqual(store.resets, 2)
    }

    // MARK: - Demo service

    func testDemoServiceRoundTripsWithoutEventKit() async throws {
        let demo = DemoEventKitService(now: Self.now, timeZone: Self.losAngeles)
        let calendars = await demo.calendars(for: .event)
        XCTAssertEqual(calendars.map(\.title), ["Home", "Work", "Holidays"])
        XCTAssertEqual(calendars.filter(\.isWritable).map(\.title), ["Home", "Work"])
        let lists = await demo.calendars(for: .reminder)
        XCTAssertEqual(lists.map(\.title), ["Reminders", "Errands"])

        let list = CalendarListEventsTool(eventKit: demo, clock: Self.clock)
        let listed = try await list.run(["start": "2026-09-28", "end": "2026-09-28"], context: context())
        let titles = try JSONValue.decode(outputText(listed))["events"]?.arrayValue?.compactMap { $0["title"]?.stringValue }
        XCTAssertEqual(titles, ["Standup", "Lunch with Sam"])

        let create = CalendarCreateEventTool(eventKit: demo, clock: Self.clock)
        let created = try await create.run(["title": "Dentist", "start": "2026-09-29T15:00", "end": "2026-09-29T16:00"],
                                           context: context())
        XCTAssertEqual(try JSONValue.decode(outputText(created))["calendar"], "Home")
        try await create.undo(try XCTUnwrap(created.undo))
        let afterUndo = try await demo.events(from: at("2026-09-29T00:00"), to: at("2026-09-30T00:00"), calendarIDs: nil)
        XCTAssertEqual(afterUndo.map(\.title), ["Design review"])

        let readOnly = await runError(create, ["title": "Dentist", "start": "2026-09-29T15:00", "end": "2026-09-29T16:00"],
                                      context: context(calendar: DemoEventKitService.holidaysCalendarID))
        XCTAssertEqual(readOnly?.toolResultText, "failed: “Holidays” is read-only.")

        let reminders = CalendarListRemindersTool(eventKit: demo, clock: Self.clock)
        let listedReminders = try await reminders.run([:], context: context())
        let reminderTitles = try JSONValue.decode(outputText(listedReminders))["reminders"]?.arrayValue?
            .compactMap { $0["title"]?.stringValue }
        XCTAssertEqual(reminderTitles, ["Call the plumber", "Buy stamps"])

        let addReminder = CalendarCreateReminderTool(eventKit: demo, clock: Self.clock)
        let added = try await addReminder.run(["title": "Water plants", "due": "2026-09-30"], context: context())
        try await addReminder.undo(try XCTUnwrap(added.undo))
        let remaining = try await demo.reminders(in: nil, filter: .all).map(\.title)
        XCTAssertEqual(remaining, ["Call the plumber", "Buy stamps"])
    }

    // MARK: - Helpers

    private func context(calendar: String? = nil) -> ToolRunContext {
        ToolRunContext(callID: "call_1", model: .opus5, options: ApprovalOptions(calendarIdentifier: calendar),
                       reportProgress: { _ in }, reportSystemDialog: { _ in })
    }

    private func outputText(_ result: ToolRunResult) throws -> String {
        guard case .text(let text)? = result.output.parts.first else {
            return try XCTUnwrap(nil as String?, "the result has no text part")
        }
        return text
    }

    private func runError(_ tool: any OttoTool, _ input: JSONValue, context: ToolRunContext? = nil) async -> ToolError? {
        do {
            _ = try await tool.run(input, context: context ?? self.context())
            XCTFail("\(tool.name) should have failed for \(input.encodedString())")
            return nil
        } catch let error as ToolError {
            return error
        } catch {
            XCTFail("unexpected \(error)")
            return nil
        }
    }

    /// A local wall time in Los Angeles ("2026-09-29T15:00" or with seconds).
    private func at(_ text: String) -> Date {
        guard let parsed = try? DateInput.parse(text) else { return .distantPast }
        return DateInput.resolve(parsed, in: Self.losAngeles).date
    }

    private func event(_ id: String, _ title: String, _ start: Date, _ end: Date, calendar: CalendarListInfo,
                       allDay: Bool = false, location: String? = nil, notes: String? = nil, attendees: [String] = [],
                       status: CalendarEventRecord.Status = .confirmed, floating: Bool = false) -> CalendarEventRecord {
        CalendarEventRecord(id: id, title: title, start: start, end: end, isAllDay: allDay, calendarID: calendar.id,
                            calendarTitle: calendar.title, location: location, notes: notes, attendees: attendees,
                            status: status, timeZone: allDay || floating ? nil : Self.losAngeles)
    }

    private func reminder(_ id: String, _ title: String, list: CalendarListInfo, due: String? = nil, priority: Int = 0,
                          notes: String? = nil, completed: Date? = nil, created: Date) -> CalendarReminderRecord {
        var components: DateComponents?
        var dueDate: Date?
        if let due, let parsed = try? DateInput.parse(due) {
            dueDate = DateInput.resolve(parsed, in: Self.losAngeles).date
            switch parsed {
            case .date(let parts): components = parts
            case .localDateTime(let parts): components = parts
            case .absolute: components = nil
            }
        }
        return CalendarReminderRecord(id: id, title: title, listID: list.id, listTitle: list.title, due: components,
                                      dueDate: dueDate, dueHasTime: components?.hour != nil,
                                      isCompleted: completed != nil, completionDate: completed, priority: priority,
                                      notes: notes, creationDate: created)
    }

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{2009}", with: " ")
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met within \(timeout) s")
    }
}

// MARK: - Fakes

/// In-memory EventKitProviding that records what the tools asked for.
private actor FakeEventKit: EventKitProviding {
    struct EventFetch: Equatable { let start: Date; let end: Date; let calendarIDs: [String]? }
    struct ReminderFetch: Equatable { let listIDs: [String]?; let filter: CalendarReminderFilter }
    struct CreatedEvent { let draft: CalendarEventDraft; let calendarID: String }
    struct CreatedReminder { let draft: CalendarReminderDraft; let listID: String }

    private var calendarsByKind: [CalendarItemKind: [CalendarListInfo]] = [
        .event: [CalendarListInfo(id: "cal-home", title: "Home", source: "iCloud", colorRGBA: [0.2, 0.4, 0.9, 1],
                                  isWritable: true),
                 CalendarListInfo(id: "cal-work", title: "Work", source: "iCloud", colorRGBA: nil, isWritable: true),
                 CalendarListInfo(id: "cal-holidays", title: "Holidays", source: "Subscribed", colorRGBA: nil,
                                  isWritable: false)],
        .reminder: [CalendarListInfo(id: "list-errands", title: "Errands", source: "iCloud", colorRGBA: nil,
                                     isWritable: true),
                    CalendarListInfo(id: "list-groceries", title: "Groceries", source: "iCloud", colorRGBA: nil,
                                     isWritable: true)],
    ]
    private var defaults: [CalendarItemKind: String] = [.event: "cal-home", .reminder: "list-errands"]
    private var saveError: CalendarStoreError?
    private var nextID = 1

    private(set) var storedEvents: [CalendarEventRecord] = []
    private(set) var storedReminders: [CalendarReminderRecord] = []
    private(set) var createdEvents: [CreatedEvent] = []
    private(set) var createdReminders: [CreatedReminder] = []
    private(set) var eventRemovals: [String] = []
    private(set) var calendarFetches = 0
    private(set) var eventFetches = 0
    private(set) var lastEventFetch: EventFetch?
    private(set) var lastReminderFetch: ReminderFetch?

    func setCalendars(_ calendars: [CalendarListInfo], for kind: CalendarItemKind) { calendarsByKind[kind] = calendars }
    func setDefault(_ id: String?, for kind: CalendarItemKind) { defaults[kind] = id }
    func setSaveError(_ error: CalendarStoreError?) { saveError = error }
    func seedEvents(_ events: [CalendarEventRecord]) { storedEvents += events }
    func seedReminders(_ reminders: [CalendarReminderRecord]) { storedReminders += reminders }

    /// What a full sync or a calendar move does to an identifier.
    func renameEvent(_ id: String, to newID: String) {
        storedEvents = storedEvents.map { event in
            guard event.id == id else { return event }
            return CalendarEventRecord(id: newID, title: event.title, start: event.start, end: event.end,
                                       isAllDay: event.isAllDay, calendarID: event.calendarID,
                                       calendarTitle: event.calendarTitle, location: event.location, notes: event.notes,
                                       attendees: event.attendees, status: event.status, timeZone: event.timeZone)
        }
    }

    func renameReminder(_ id: String, to newID: String) {
        storedReminders = storedReminders.map { reminder in
            guard reminder.id == id else { return reminder }
            return CalendarReminderRecord(id: newID, title: reminder.title, listID: reminder.listID,
                                          listTitle: reminder.listTitle, due: reminder.due, dueDate: reminder.dueDate,
                                          dueHasTime: reminder.dueHasTime, isCompleted: reminder.isCompleted,
                                          completionDate: reminder.completionDate, priority: reminder.priority,
                                          notes: reminder.notes, creationDate: reminder.creationDate)
        }
    }

    func calendars(for kind: CalendarItemKind) async -> [CalendarListInfo] {
        calendarFetches += 1
        return calendarsByKind[kind] ?? []
    }

    func defaultCalendarID(for kind: CalendarItemKind) async -> String? { defaults[kind] }

    func events(from start: Date, to end: Date, calendarIDs: [String]?) async throws -> [CalendarEventRecord] {
        eventFetches += 1
        lastEventFetch = EventFetch(start: start, end: end, calendarIDs: calendarIDs)
        return storedEvents.filter { event in
            event.start < end && event.end > start && (calendarIDs.map { $0.contains(event.calendarID) } ?? true)
        }
    }

    func createEvent(_ draft: CalendarEventDraft, calendarID: String) async throws -> CalendarEventRecord {
        guard let calendar = calendarsByKind[.event]?.first(where: { $0.id == calendarID }) else {
            throw CalendarStoreError.calendarNotFound
        }
        guard calendar.isWritable else { throw CalendarStoreError.readOnly(calendar.title) }
        if let saveError { throw saveError }
        createdEvents.append(CreatedEvent(draft: draft, calendarID: calendarID))
        let record = CalendarEventRecord(id: "event-\(nextID)", title: draft.title, start: draft.start, end: draft.end,
                                         isAllDay: draft.isAllDay, calendarID: calendarID, calendarTitle: calendar.title,
                                         location: draft.location, notes: draft.notes, attendees: [],
                                         status: .confirmed, timeZone: draft.timeZone)
        nextID += 1
        storedEvents.append(record)
        return record
    }

    func removeEvent(identifier: String) async throws -> Bool {
        eventRemovals.append(identifier)
        guard let index = storedEvents.firstIndex(where: { $0.id == identifier }) else { return false }
        storedEvents.remove(at: index)
        return true
    }

    func reminders(in listIDs: [String]?, filter: CalendarReminderFilter) async throws -> [CalendarReminderRecord] {
        lastReminderFetch = ReminderFetch(listIDs: listIDs, filter: filter)
        return storedReminders.filter { reminder in
            guard listIDs.map({ $0.contains(reminder.listID) }) ?? true else { return false }
            switch filter {
            case .incomplete: return !reminder.isCompleted
            case .incompleteAndCompleted(let since):
                return !reminder.isCompleted || (reminder.completionDate.map { $0 >= since } ?? false)
            case .all: return true
            }
        }
    }

    func createReminder(_ draft: CalendarReminderDraft, listID: String) async throws -> CalendarReminderRecord {
        guard let list = calendarsByKind[.reminder]?.first(where: { $0.id == listID }) else {
            throw CalendarStoreError.calendarNotFound
        }
        if let saveError { throw saveError }
        createdReminders.append(CreatedReminder(draft: draft, listID: listID))
        var dueDate: Date?
        if let due = draft.due, let year = due.year, let month = due.month, let day = due.day {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = due.timeZone ?? TimeZone(identifier: "America/Los_Angeles") ?? .gmt
            dueDate = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: due.hour ?? 0,
                                                         minute: due.minute ?? 0))
        }
        let record = CalendarReminderRecord(id: "reminder-\(nextID)", title: draft.title, listID: listID,
                                            listTitle: list.title, due: draft.due, dueDate: dueDate,
                                            dueHasTime: draft.due?.hour != nil, isCompleted: false, completionDate: nil,
                                            priority: 0, notes: draft.notes, creationDate: nil)
        nextID += 1
        storedReminders.append(record)
        return record
    }

    func removeReminder(identifier: String) async throws -> Bool {
        guard let index = storedReminders.firstIndex(where: { $0.id == identifier }) else { return false }
        storedReminders.remove(at: index)
        return true
    }
}

/// Counts `reset()` calls instead of reloading anything. Never asked for access and never read.
private final class ResetCountingEventStore: EKEventStore, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var resets: Int { lock.withLock { count } }

    override func reset() {
        lock.withLock { count += 1 }
    }
}

private final class LockedList<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    var items: [Element] { lock.withLock { storage } }

    func append(_ element: Element) {
        lock.withLock { storage.append(element) }
    }
}
