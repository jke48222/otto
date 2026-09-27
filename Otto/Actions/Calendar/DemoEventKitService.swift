//
//  DemoEventKitService.swift
//  Otto
//
//  The `EventKitProviding` used by --demo, --selftest and --snapshot: two calendars, a read-only holiday
//  calendar, two reminder lists and a few items around the day it was created, all in memory. It never
//  imports or touches EventKit, so nothing reaches the user's real calendars or reminders.
//

import Foundation

actor DemoEventKitService: EventKitProviding {
    static let homeCalendarID = "demo-calendar-home"
    static let workCalendarID = "demo-calendar-work"
    static let holidaysCalendarID = "demo-calendar-holidays"
    static let remindersListID = "demo-list-reminders"
    static let errandsListID = "demo-list-errands"

    private var eventCalendars: [CalendarListInfo]
    private var reminderLists: [CalendarListInfo]
    private var storedEvents: [CalendarEventRecord]
    private var storedReminders: [CalendarReminderRecord]
    private var nextID = 1

    /// Seeds items relative to `now` in `timeZone`: tomorrow's standup and lunch, a review the day after, a holiday,
    /// and two reminders.
    init(now: Date = Date(), timeZone: TimeZone = .current) {
        eventCalendars = [
            CalendarListInfo(id: Self.homeCalendarID, title: "Home", source: "On My Mac",
                             colorRGBA: [0.30, 0.62, 0.95, 1], isWritable: true),
            CalendarListInfo(id: Self.workCalendarID, title: "Work", source: "On My Mac",
                             colorRGBA: [0.95, 0.55, 0.25, 1], isWritable: true),
            CalendarListInfo(id: Self.holidaysCalendarID, title: "Holidays", source: "Subscribed",
                             colorRGBA: [0.35, 0.78, 0.45, 1], isWritable: false),
        ]
        reminderLists = [
            CalendarListInfo(id: Self.remindersListID, title: "Reminders", source: "On My Mac",
                             colorRGBA: [0.30, 0.62, 0.95, 1], isWritable: true),
            CalendarListInfo(id: Self.errandsListID, title: "Errands", source: "On My Mac",
                             colorRGBA: [0.85, 0.35, 0.55, 1], isWritable: true),
        ]

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        func event(_ id: String, _ title: String, _ start: Date, _ end: Date, calendarID: String, calendarTitle: String,
                   allDay: Bool = false, location: String? = nil, attendees: [String] = []) -> CalendarEventRecord {
            CalendarEventRecord(id: id, title: title, start: start, end: end, isAllDay: allDay, calendarID: calendarID,
                                calendarTitle: calendarTitle, location: location, notes: nil, attendees: attendees,
                                status: .confirmed, timeZone: allDay ? nil : timeZone)
        }
        storedEvents = [
            event("demo-event-standup", "Standup", at(1, 9, 30), at(1, 9, 45), calendarID: Self.workCalendarID,
                  calendarTitle: "Work", location: "Zoom", attendees: ["Priya Shah", "Leo Park"]),
            event("demo-event-lunch", "Lunch with Sam", at(1, 12, 30), at(1, 13, 30), calendarID: Self.homeCalendarID,
                  calendarTitle: "Home", location: "Tartine"),
            event("demo-event-review", "Design review", at(2, 15), at(2, 16), calendarID: Self.workCalendarID,
                  calendarTitle: "Work"),
            event("demo-event-holiday", "Company holiday", at(3, 0), at(4, 0).addingTimeInterval(-1),
                  calendarID: Self.holidaysCalendarID, calendarTitle: "Holidays", allDay: true),
        ]

        let tomorrowNine = at(1, 9)
        let tomorrowParts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: tomorrowNine)
        storedReminders = [
            CalendarReminderRecord(id: "demo-reminder-plumber", title: "Call the plumber", listID: Self.remindersListID,
                                   listTitle: "Reminders", due: tomorrowParts, dueDate: tomorrowNine, dueHasTime: true,
                                   isCompleted: false, completionDate: nil, priority: 1, notes: nil,
                                   creationDate: at(-2, 18)),
            CalendarReminderRecord(id: "demo-reminder-stamps", title: "Buy stamps", listID: Self.errandsListID,
                                   listTitle: "Errands", due: nil, dueDate: nil, dueHasTime: false, isCompleted: false,
                                   completionDate: nil, priority: 0, notes: nil, creationDate: at(-1, 8)),
        ]
    }

    // MARK: - EventKitProviding

    func calendars(for kind: CalendarItemKind) async -> [CalendarListInfo] {
        kind == .event ? eventCalendars : reminderLists
    }

    func defaultCalendarID(for kind: CalendarItemKind) async -> String? {
        kind == .event ? Self.homeCalendarID : Self.remindersListID
    }

    func events(from start: Date, to end: Date, calendarIDs: [String]?) async throws -> [CalendarEventRecord] {
        storedEvents
            .filter { event in
                event.start < end && event.end > start && (calendarIDs.map { $0.contains(event.calendarID) } ?? true)
            }
            .sorted { $0.start < $1.start }
    }

    func createEvent(_ draft: CalendarEventDraft, calendarID: String) async throws -> CalendarEventRecord {
        let calendar = try writable(calendarID, in: eventCalendars)
        let record = CalendarEventRecord(id: makeID("event"), title: draft.title, start: draft.start, end: draft.end,
                                         isAllDay: draft.isAllDay, calendarID: calendar.id,
                                         calendarTitle: calendar.title, location: draft.location, notes: draft.notes,
                                         attendees: [], status: .confirmed, timeZone: draft.timeZone)
        storedEvents.append(record)
        return record
    }

    func removeEvent(identifier: String) async throws -> Bool {
        guard let index = storedEvents.firstIndex(where: { $0.id == identifier }) else { return false }
        storedEvents.remove(at: index)
        return true
    }

    func reminders(in listIDs: [String]?, filter: CalendarReminderFilter) async throws -> [CalendarReminderRecord] {
        storedReminders.filter { reminder in
            guard listIDs.map({ $0.contains(reminder.listID) }) ?? true else { return false }
            switch filter {
            case .incomplete:
                return !reminder.isCompleted
            case .incompleteAndCompleted(let since):
                return !reminder.isCompleted || (reminder.completionDate.map { $0 >= since } ?? false)
            case .all:
                return true
            }
        }
    }

    func createReminder(_ draft: CalendarReminderDraft, listID: String) async throws -> CalendarReminderRecord {
        let list = try writable(listID, in: reminderLists)
        var dueDate: Date?
        if let due = draft.due, let year = due.year, let month = due.month, let day = due.day {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = due.timeZone ?? .current
            dueDate = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: due.hour ?? 0,
                                                         minute: due.minute ?? 0))
        }
        let record = CalendarReminderRecord(id: makeID("reminder"), title: draft.title, listID: list.id,
                                            listTitle: list.title, due: draft.due, dueDate: dueDate,
                                            dueHasTime: draft.due?.hour != nil, isCompleted: false,
                                            completionDate: nil, priority: 0, notes: draft.notes,
                                            creationDate: Date())
        storedReminders.append(record)
        return record
    }

    func removeReminder(identifier: String) async throws -> Bool {
        guard let index = storedReminders.firstIndex(where: { $0.id == identifier }) else { return false }
        storedReminders.remove(at: index)
        return true
    }

    // MARK: - Private

    private func writable(_ id: String, in calendars: [CalendarListInfo]) throws -> CalendarListInfo {
        guard let calendar = calendars.first(where: { $0.id == id }) else { throw CalendarStoreError.calendarNotFound }
        guard calendar.isWritable else { throw CalendarStoreError.readOnly(calendar.title) }
        return calendar
    }

    private func makeID(_ kind: String) -> String {
        defer { nextID += 1 }
        return "demo-\(kind)-\(nextID)"
    }
}
