//
//  EventKitProviding.swift
//  Otto
//
//  The seam between the calendar and reminder tools and EventKit. `EventKitService` implements it over
//  one EKEventStore, `DemoEventKitService` over seeded in-memory data, and tests use fakes, so only
//  the live service ever touches the user's calendars. Only Sendable records cross it.
//

import Foundation

/// What a calendar holds: events (Calendar) or reminders (a Reminders list).
enum CalendarItemKind: String, Sendable {
    case event, reminder
}

/// A calendar or a reminder list.
struct CalendarListInfo: Equatable, Identifiable, Sendable {
    /// `EKCalendar.calendarIdentifier`.
    let id: String
    let title: String
    /// The account: "iCloud", "Google", "On My Mac".
    let source: String
    /// sRGB, 4 components.
    let colorRGBA: [Double]?
    /// False for subscribed, birthday and other read-only calendars.
    let isWritable: Bool
}

/// An event read from or saved to a calendar.
struct CalendarEventRecord: Equatable, Sendable {
    enum Status: String, Sendable {
        case confirmed, tentative, canceled
    }

    /// `EKEvent.eventIdentifier` (falls back to `calendarItemIdentifier` when EventKit has none).
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarID: String
    let calendarTitle: String
    let location: String?
    let notes: String?
    /// Display names only, never addresses.
    let attendees: [String]
    let status: Status?
    /// nil = floating (and every all-day event).
    let timeZone: TimeZone?
}

/// What `createEvent` saves.
struct CalendarEventDraft: Equatable, Sendable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    /// The user's zone for timed events; nil for all-day events.
    var timeZone: TimeZone?
}

/// A reminder read from or saved to a list.
struct CalendarReminderRecord: Equatable, Sendable {
    /// `EKReminder.calendarItemIdentifier`.
    let id: String
    let title: String
    let listID: String
    let listTitle: String
    /// `dueDateComponents` as stored.
    let due: DateComponents?
    /// The due components as an instant (00:00 for date-only reminders); nil when undated.
    let dueDate: Date?
    let dueHasTime: Bool
    let isCompleted: Bool
    let completionDate: Date?
    /// 0 = none, 1–4 high, 5 medium, 6–9 low.
    let priority: Int
    let notes: String?
    let creationDate: Date?
}

/// What `createReminder` saves.
struct CalendarReminderDraft: Equatable, Sendable {
    var title: String
    /// y/m/d, or y/m/d/h/m with a time zone.
    var due: DateComponents?
    /// Timed reminders get an alarm at the due instant.
    var alarmDate: Date?
    var notes: String?
}

/// Which reminders a fetch returns.
enum CalendarReminderFilter: Equatable, Sendable {
    case incomplete
    /// Incomplete ones plus those completed on or after the date.
    case incompleteAndCompleted(since: Date)
    /// Every reminder in the lists (the undo search).
    case all
}

/// Typed failures of the EventKit seam; the tools turn them into `ToolError`s.
enum CalendarStoreError: Error, Equatable, Sendable {
    /// The calendar or list id no longer exists.
    case calendarNotFound
    /// The calendar or list doesn't accept new items; associated value = its title.
    case readOnly(String)
    /// EventKit refused to save; associated value = its description.
    case saveFailed(String)
    /// EventKit refused to remove; associated value = its description.
    case removeFailed(String)
    /// A fetch failed or was cancelled.
    case fetchFailed(String)
}

/// Everything the calendar and reminder tools need from EventKit. Calls always read the store fresh, so a
/// calendar added in the Calendar app shows up in the next card's picker.
protocol EventKitProviding: Sendable {
    /// Calendars (`.event`) or reminder lists (`.reminder`), sorted by source and title.
    func calendars(for kind: CalendarItemKind) async -> [CalendarListInfo]
    /// The calendar or list new items go to by default; nil when none is set.
    func defaultCalendarID(for kind: CalendarItemKind) async -> String?
    /// Events overlapping [start, end) in the given calendars (nil = all), sorted by start.
    func events(from start: Date, to end: Date, calendarIDs: [String]?) async throws -> [CalendarEventRecord]
    /// Saves one event (span `.thisEvent`, committed) and returns it as stored.
    func createEvent(_ draft: CalendarEventDraft, calendarID: String) async throws -> CalendarEventRecord
    /// Removes the event with that identifier. false = no such event.
    func removeEvent(identifier: String) async throws -> Bool
    /// Reminders in the given lists (nil = all). Honors cancellation.
    func reminders(in listIDs: [String]?, filter: CalendarReminderFilter) async throws -> [CalendarReminderRecord]
    /// Saves one reminder and returns it as stored.
    func createReminder(_ draft: CalendarReminderDraft, listID: String) async throws -> CalendarReminderRecord
    /// Removes the reminder with that identifier. false = no such reminder.
    func removeReminder(identifier: String) async throws -> Bool
}
