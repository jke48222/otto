//
//  CalendarEventSource.swift
//  Otto
//
//  EventKit behind a seam for the next-meeting chip. The live source owns one EKEventStore, reads it
//  on a private serial queue (never on the main thread), and reports store changes. The inert source
//  serves fixed events for tests, snapshots and the demo, and never touches EventKit.
//

import EventKit
import Foundation
import os

/// EventKit behind a seam. Live: one EKEventStore; `reset()` runs whenever PermissionEvents.didGrant(.calendars)
/// arrives (a store created before access was granted can keep returning no calendars until it is reset).
@MainActor protocol CalendarEventSource: AnyObject {
    var authorization: CalendarGlance.Access { get }
    func calendars() async -> [CalendarChoice]
    func events(from start: Date, to end: Date, excluding calendarIDs: Set<String>) async -> [CalendarEventSnapshot]
    func reset()
    var onStoreChanged: (@MainActor () -> Void)? { get set }      // EKEventStoreChanged
}

@MainActor final class EventKitCalendarSource: CalendarEventSource {
    var onStoreChanged: (@MainActor () -> Void)? {
        get { relay.handler }
        set { relay.handler = newValue }
    }

    /// The store and the queue every read runs on. EKEventStore is thread-safe for reads, but one
    /// serial queue keeps `reset()` ordered with the fetches around it.
    private let box: CalendarStoreBox
    private let relay: CalendarChangeRelay

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Calendar")

    /// Nonisolated so it can be `CalendarGlance.init`'s default argument; it only creates the store and
    /// registers for its change notification (delivered on the main queue).
    nonisolated init() {
        let box = CalendarStoreBox()
        let relay = CalendarChangeRelay()
        relay.observe(box.store)
        self.box = box
        self.relay = relay
    }

    var authorization: CalendarGlance.Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied, .writeOnly: return .denied
        @unknown default: return .denied
        }
    }

    func calendars() async -> [CalendarChoice] {
        guard authorization == .granted else { return [] }
        let box = box
        return await withCheckedContinuation { continuation in
            box.queue.async {
                let choices = box.store.calendars(for: .event).map { calendar in
                    CalendarChoice(id: calendar.calendarIdentifier,
                                   title: DisplayText.sanitized(calendar.title, maxLength: 80),
                                   source: DisplayText.sanitized(calendar.source?.title ?? "", maxLength: 80),
                                   colorRGBA: CalendarColor.rgba(calendar.cgColor))
                }
                continuation.resume(returning: choices.sorted { lhs, rhs in
                    lhs.source != rhs.source ? lhs.source < rhs.source : lhs.title < rhs.title
                })
            }
        }
    }

    func events(from start: Date, to end: Date, excluding calendarIDs: Set<String>) async -> [CalendarEventSnapshot] {
        guard authorization == .granted, end > start else { return [] }
        let box = box
        let snapshots: [CalendarEventSnapshot] = await withCheckedContinuation { continuation in
            box.queue.async {
                let calendars = box.store.calendars(for: .event).filter { !calendarIDs.contains($0.calendarIdentifier) }
                guard !calendars.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                let predicate = box.store.predicateForEvents(withStart: start, end: end, calendars: calendars)
                let events = box.store.events(matching: predicate)
                continuation.resume(returning: events.compactMap(CalendarEventMapper.snapshot))
            }
        }
        Self.logger.debug("Read \(snapshots.count, privacy: .public) calendar events")
        return snapshots
    }

    func reset() {
        let box = box
        box.queue.async {
            box.store.reset()
        }
        Self.logger.info("Calendar store reset")
    }
}

/// Fixed events, no EventKit: tests, snapshots, the demo. Calendar exclusion does not apply (snapshots
/// carry no calendar id).
@MainActor final class InertCalendarSource: CalendarEventSource {
    var onStoreChanged: (@MainActor () -> Void)?
    var authorization: CalendarGlance.Access = .granted
    var storedEvents: [CalendarEventSnapshot]
    var calendarChoices: [CalendarChoice] = []

    init(events: [CalendarEventSnapshot] = []) {
        storedEvents = events
    }

    func calendars() async -> [CalendarChoice] {
        calendarChoices
    }

    func events(from start: Date, to end: Date, excluding calendarIDs: Set<String>) async -> [CalendarEventSnapshot] {
        storedEvents.filter { $0.end > start && $0.start < end }
    }

    func reset() {}
}

// MARK: - Private helpers

/// Forwards EKEventStoreChanged (main queue) to the source's `onStoreChanged`; removes its observer when released.
private final class CalendarChangeRelay: @unchecked Sendable {
    /// Read and written on the main actor only (the notification is delivered on the main queue).
    var handler: (@MainActor () -> Void)?
    private var token: NSObjectProtocol?

    func observe(_ store: EKEventStore) {
        token = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                                       queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handler?()
            }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

/// The EventKit store and its read queue, handed across to that queue.
private final class CalendarStoreBox: @unchecked Sendable {
    let store = EKEventStore()
    let queue = DispatchQueue(label: "com.jalenedusei.otto.calendar", qos: .utility)
}

private enum CalendarEventMapper {
    /// Runs on the store's queue.
    static func snapshot(_ event: EKEvent) -> CalendarEventSnapshot? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        let itemID = event.calendarItemIdentifier
        let isDeclined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
        return CalendarEventSnapshot(
            id: CalendarEventSnapshot.makeID(calendarItemIdentifier: itemID, start: start),
            title: event.title ?? "",
            start: start,
            end: end,
            colorRGBA: CalendarColor.rgba(event.calendar?.cgColor),
            isAllDay: event.isAllDay,
            isCanceled: event.status == .canceled,
            isDeclined: isDeclined,
            meetingLink: MeetingLinkDetector.link(url: event.url, location: event.location, notes: event.notes)
        )
    }
}

private enum CalendarColor {
    /// Four sRGB components, or nil when the color can't be converted.
    static func rgba(_ color: CGColor?) -> [Double]? {
        guard let color,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 4
        else { return nil }
        return components.prefix(4).map { Double($0) }
    }
}
