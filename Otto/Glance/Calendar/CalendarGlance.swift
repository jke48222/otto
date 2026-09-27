//
//  CalendarGlance.swift
//  Otto
//
//  State behind the next-meeting chip in the open notch's glance row: calendar access, the next event
//  worth showing, and the calendars Settings lists for exclusion. Reads through CalendarEventSource,
//  refreshes when the store changes or Calendars access is granted, and ticks every 30 s only while
//  the notch is open.
//

import Foundation
import Observation
import os

@MainActor @Observable final class CalendarGlance {
    enum Access: Equatable, Sendable { case notDetermined, granted, denied, restricted }

    /// Refresh cadence while the panel is open.
    static let tickInterval: Duration = .seconds(30)

    private(set) var access: Access
    private(set) var next: EventGlance?
    /// For Settings (exclusion list).
    private(set) var calendars: [CalendarChoice]

    /// Wall clock and sleeping, replaceable in tests.
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let store: CalendarEventSource
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var grantToken: NSObjectProtocol?

    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isPanelOpen = false
    @ObservationIgnored private var hidden: Set<String> = []
    @ObservationIgnored private var cachedEvents: [CalendarEventSnapshot] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// Bumped per refresh so an older, slower read never overwrites a newer one.
    @ObservationIgnored private var generation = 0

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Calendar")

    /// Observes PermissionEvents.didGrant on `notificationCenter`: a Calendars grant resets the store and refreshes.
    init(settings: AppSettings, store: CalendarEventSource = EventKitCalendarSource(),
         notificationCenter: NotificationCenter = .default) {
        self.settings = settings
        self.store = store
        self.notificationCenter = notificationCenter
        access = store.authorization
        next = nil
        calendars = []

        grantToken = notificationCenter.addObserver(forName: PermissionEvents.didGrant, object: nil,
                                                    queue: .main) { [weak self] notification in
            let permission = PermissionEvents.permission(from: notification)
            MainActor.assumeIsolated {
                guard permission == .calendars else { return }
                self?.calendarsGranted()
            }
        }
        store.onStoreChanged = { [weak self] in
            self?.storeDidChange()
        }
    }

    deinit {
        if let grantToken { notificationCenter.removeObserver(grantToken) }
    }

    /// Begins reading (the live app, after launch). Idempotent.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        refresh()
        if isPanelOpen { startTicking() }
    }

    func stop() {
        isStarted = false
        stopTicking()
        refreshTask?.cancel()
        refreshTask = nil
        generation += 1
    }

    /// Re-reads access, the calendar list and the events around now, then picks the next event.
    func refresh() {
        let currentAccess = store.authorization
        if access != currentAccess { access = currentAccess }
        generation += 1
        let token = generation
        refreshTask?.cancel()

        guard currentAccess == .granted else {
            refreshTask = nil
            cachedEvents = []
            setNext(nil)
            if !calendars.isEmpty { calendars = [] }
            return
        }

        let enabled = settings.glance.calendarChipEnabled
        let excluded = Set(settings.glance.calendarExcludedIDs)
        let reference = now()
        let window = (start: reference.addingTimeInterval(-NextEventPicker.lateJoinWindow),
                      end: reference.addingTimeInterval(NextEventPicker.lookahead + Self.tickInterval.timeInterval))
        refreshTask = Task { [weak self, store] in
            let choices = await store.calendars()
            let events = enabled ? await store.events(from: window.start, to: window.end, excluding: excluded) : []
            guard let self, !Task.isCancelled, token == self.generation else { return }
            self.refreshTask = nil
            if self.calendars != choices { self.calendars = choices }
            self.cachedEvents = events
            self.repick()
        }
    }

    /// Opening the notch refreshes and starts the 30 s tick; closing stops it.
    func panelDidOpen() {
        isPanelOpen = true
        guard isStarted else { return }
        refresh()
        startTicking()
    }

    func panelDidClose() {
        isPanelOpen = false
        stopTicking()
    }

    /// Hides one occurrence from the chip for the rest of this launch.
    func hide(eventID: String) {
        hidden.insert(eventID)
        repick()
    }

    func debugSeed(next: EventGlance?) {
        refreshTask?.cancel()
        refreshTask = nil
        generation += 1
        self.next = next
    }

    // MARK: - Private

    private func calendarsGranted() {
        store.reset()
        Self.logger.info("Calendars access granted; store reset")
        refresh()
    }

    private func storeDidChange() {
        guard isStarted else { return }
        refresh()
    }

    private func repick() {
        guard settings.glance.calendarChipEnabled, access == .granted else {
            setNext(nil)
            return
        }
        setNext(NextEventPicker.pick(cachedEvents, now: now(), hidden: hidden))
    }

    private func setNext(_ value: EventGlance?) {
        if next != value { next = value }
    }

    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self, sleep] in
            while !Task.isCancelled {
                do { try await sleep(Self.tickInterval) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
