//
//  EventKitService.swift
//  Otto
//
//  The live `EventKitProviding`: one EKEventStore inside an actor, so EventKit objects never leave it
//  (only Sendable records do). A store created before Otto had access can keep answering with no
//  calendars, so the store is reset whenever Calendars or Reminders access is granted.
//

import CoreGraphics
import EventKit
import Foundation
import os

actor EventKitService: EventKitProviding {
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Actions")

    private let store: EKEventStore
    private let grantObserver: CalendarGrantObserver
    /// How many times the store was reset after a grant (tests read it).
    private(set) var resetCount = 0

    /// `notificationCenter` delivers `PermissionEvents.didGrant`.
    init(store: EKEventStore = EKEventStore(), notificationCenter: NotificationCenter = .default) {
        self.store = store
        let observer = CalendarGrantObserver(center: notificationCenter)
        grantObserver = observer
        observer.setHandler { [weak self] permission in
            Task { await self?.resetStore(after: permission) }
        }
    }

    // MARK: - EventKitProviding

    func calendars(for kind: CalendarItemKind) async -> [CalendarListInfo] {
        store.calendars(for: Self.entityType(kind))
            .map(Self.info)
            .sorted { ($0.source, $0.title, $0.id) < ($1.source, $1.title, $1.id) }
    }

    func defaultCalendarID(for kind: CalendarItemKind) async -> String? {
        switch kind {
        case .event: return store.defaultCalendarForNewEvents?.calendarIdentifier
        case .reminder: return store.defaultCalendarForNewReminders()?.calendarIdentifier
        }
    }

    func events(from start: Date, to end: Date, calendarIDs: [String]?) async throws -> [CalendarEventRecord] {
        let calendars = calendarIDs.map { ids in ids.compactMap { store.calendar(withIdentifier: $0) } }
        if let calendars, calendars.isEmpty { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let records = store.events(matching: predicate).map(Self.record).sorted { $0.start < $1.start }
        Self.logger.info("Read \(records.count, privacy: .public) events")
        return records
    }

    func createEvent(_ draft: CalendarEventDraft, calendarID: String) async throws -> CalendarEventRecord {
        let calendar = try writableCalendar(calendarID)
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay
        event.location = draft.location
        event.notes = draft.notes
        event.timeZone = draft.isAllDay ? nil : draft.timeZone
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            Self.logger.error("Saving an event failed: \(error.localizedDescription, privacy: .public)")
            throw CalendarStoreError.saveFailed(error.localizedDescription)
        }
        let record = Self.record(event)
        Self.logger.info("Saved event \(record.id, privacy: .public): \(record.title, privacy: .private)")
        return record
    }

    func removeEvent(identifier: String) async throws -> Bool {
        let found = store.event(withIdentifier: identifier) ?? (store.calendarItem(withIdentifier: identifier) as? EKEvent)
        guard let event = found else { return false }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            Self.logger.error("Removing an event failed: \(error.localizedDescription, privacy: .public)")
            throw CalendarStoreError.removeFailed(error.localizedDescription)
        }
        Self.logger.info("Removed event \(identifier, privacy: .public)")
        return true
    }

    func reminders(in listIDs: [String]?, filter: CalendarReminderFilter) async throws -> [CalendarReminderRecord] {
        let lists = listIDs.map { ids in ids.compactMap { store.calendar(withIdentifier: $0) } }
        if let lists, lists.isEmpty { return [] }
        var records: [CalendarReminderRecord]
        switch filter {
        case .incomplete:
            records = try await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil,
                                                                            calendars: lists))
        case .incompleteAndCompleted(let since):
            records = try await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil,
                                                                            calendars: lists))
            let known = Set(records.map(\.id))
            let completed = try await fetch(store.predicateForCompletedReminders(withCompletionDateStarting: since,
                                                                                ending: nil, calendars: lists))
            records += completed.filter { !known.contains($0.id) }
        case .all:
            records = try await fetch(store.predicateForReminders(in: lists))
        }
        Self.logger.info("Read \(records.count, privacy: .public) reminders")
        return records
    }

    func createReminder(_ draft: CalendarReminderDraft, listID: String) async throws -> CalendarReminderRecord {
        let list = try writableCalendar(listID)
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.dueDateComponents = draft.due
        if let alarmDate = draft.alarmDate {
            reminder.addAlarm(EKAlarm(absoluteDate: alarmDate))
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            Self.logger.error("Saving a reminder failed: \(error.localizedDescription, privacy: .public)")
            throw CalendarStoreError.saveFailed(error.localizedDescription)
        }
        let record = Self.record(reminder)
        Self.logger.info("Saved reminder \(record.id, privacy: .public): \(record.title, privacy: .private)")
        return record
    }

    func removeReminder(identifier: String) async throws -> Bool {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return false }
        do {
            try store.remove(reminder, commit: true)
        } catch {
            Self.logger.error("Removing a reminder failed: \(error.localizedDescription, privacy: .public)")
            throw CalendarStoreError.removeFailed(error.localizedDescription)
        }
        Self.logger.info("Removed reminder \(identifier, privacy: .public)")
        return true
    }

    // MARK: - Private

    private func resetStore(after permission: Permission) {
        store.reset()
        resetCount += 1
        Self.logger.info("Reset the event store after \(permission.displayName, privacy: .public) access was granted")
    }

    private func writableCalendar(_ identifier: String) throws -> EKCalendar {
        guard let calendar = store.calendar(withIdentifier: identifier) else {
            throw CalendarStoreError.calendarNotFound
        }
        guard calendar.allowsContentModifications else {
            throw CalendarStoreError.readOnly(calendar.title)
        }
        return calendar
    }

    /// Wraps `fetchReminders(matching:completion:)`; task cancellation cancels the fetch and resumes at once.
    private func fetch(_ predicate: NSPredicate) async throws -> [CalendarReminderRecord] {
        let store = self.store
        let pending = CalendarReminderFetch()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.begin(continuation)
                let request = store.fetchReminders(matching: predicate) { reminders in
                    pending.finish(.success((reminders ?? []).map(Self.record)))
                }
                pending.attach(request)
            }
        } onCancel: {
            if let request = pending.cancel() {
                store.cancelFetchRequest(request)
            }
        }
    }

    private static func entityType(_ kind: CalendarItemKind) -> EKEntityType {
        switch kind {
        case .event: return .event
        case .reminder: return .reminder
        }
    }

    private static func info(_ calendar: EKCalendar) -> CalendarListInfo {
        CalendarListInfo(id: calendar.calendarIdentifier, title: calendar.title, source: calendar.source?.title ?? "",
                         colorRGBA: rgba(calendar.cgColor), isWritable: calendar.allowsContentModifications)
    }

    private static func rgba(_ color: CGColor?) -> [Double]? {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 4 else { return nil }
        return components.prefix(4).map(Double.init)
    }

    private static func record(_ event: EKEvent) -> CalendarEventRecord {
        let status: CalendarEventRecord.Status?
        switch event.status {
        case .confirmed: status = .confirmed
        case .tentative: status = .tentative
        case .canceled: status = .canceled
        default: status = nil
        }
        let attendees = (event.attendees ?? []).compactMap { participant -> String? in
            guard let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return nil
            }
            return name
        }
        let startDate: Date? = event.startDate
        let endDate: Date? = event.endDate
        let start = startDate ?? Date(timeIntervalSince1970: 0)
        return CalendarEventRecord(
            id: event.eventIdentifier ?? event.calendarItemIdentifier,
            title: event.title ?? "",
            start: start,
            end: endDate ?? start,
            isAllDay: event.isAllDay,
            calendarID: event.calendar?.calendarIdentifier ?? "",
            calendarTitle: event.calendar?.title ?? "",
            location: nonEmpty(event.location),
            notes: nonEmpty(event.notes),
            attendees: attendees,
            status: status,
            timeZone: event.timeZone
        )
    }

    private static func record(_ reminder: EKReminder) -> CalendarReminderRecord {
        let due = reminder.dueDateComponents
        let hasTime = due?.hour != nil
        var dueDate: Date?
        if let due, let year = due.year, let month = due.month, let day = due.day {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = due.timeZone ?? .current
            dueDate = calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                         hour: due.hour ?? 0, minute: due.minute ?? 0))
        }
        return CalendarReminderRecord(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            listID: reminder.calendar?.calendarIdentifier ?? "",
            listTitle: reminder.calendar?.title ?? "",
            due: due,
            dueDate: dueDate,
            dueHasTime: hasTime,
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            priority: reminder.priority,
            notes: nonEmpty(reminder.notes),
            creationDate: reminder.creationDate
        )
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

/// Resets EventKit stores when Calendars or Reminders access is granted: observes `PermissionEvents.didGrant` and
/// forwards only those two permissions. The observer is removed when this object goes away.
final class CalendarGrantObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let center: NotificationCenter
    private var token: NSObjectProtocol?
    private var handler: (@Sendable (Permission) -> Void)?

    init(center: NotificationCenter = .default) {
        self.center = center
        token = center.addObserver(forName: PermissionEvents.didGrant, object: nil, queue: nil) { [weak self] note in
            guard let permission = PermissionEvents.permission(from: note),
                  permission == .calendars || permission == .reminders else { return }
            self?.deliver(permission)
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }

    func setHandler(_ handler: @escaping @Sendable (Permission) -> Void) {
        lock.withLock { self.handler = handler }
    }

    private func deliver(_ permission: Permission) {
        let handler = lock.withLock { self.handler }
        handler?(permission)
    }
}

/// One reminders fetch: resumes its continuation exactly once, whether EventKit answers or the task is cancelled.
private final class CalendarReminderFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[CalendarReminderRecord], Error>?
    private var request: Any?
    private var isCancelled = false

    func begin(_ continuation: CheckedContinuation<[CalendarReminderRecord], Error>) {
        let cancelled = lock.withLock { () -> Bool in
            if isCancelled { return true }
            self.continuation = continuation
            return false
        }
        if cancelled {
            continuation.resume(throwing: CancellationError())
        }
    }

    func attach(_ request: Any) {
        lock.withLock { self.request = request }
    }

    func finish(_ result: Result<[CalendarReminderRecord], Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<[CalendarReminderRecord], Error>? in
            defer { self.continuation = nil; request = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    /// Marks the fetch cancelled, resumes with CancellationError, and returns the request to cancel (if any).
    func cancel() -> Any? {
        let (continuation, request) = lock.withLock { () -> (CheckedContinuation<[CalendarReminderRecord], Error>?, Any?) in
            isCancelled = true
            defer { self.continuation = nil; self.request = nil }
            return (self.continuation, self.request)
        }
        continuation?.resume(throwing: CancellationError())
        return request
    }
}
