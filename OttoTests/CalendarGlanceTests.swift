//
//  CalendarGlanceTests.swift
//  OttoTests
//
//  The next-meeting chip: which event it picks (late join, 60-minute look-ahead, hidden, declined,
//  canceled, all-day), which meeting links it trusts, and CalendarGlance over a spy event source
//  (store reset on a Calendars grant, refreshes, the tick that runs only while the notch is open).
//

import XCTest
@testable import Otto

// MARK: - Picker

final class NextEventPickerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, startIn minutes: Double, length: Double = 30, title: String = "Sync",
                       allDay: Bool = false, canceled: Bool = false, declined: Bool = false,
                       link: URL? = nil) -> CalendarEventSnapshot {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarEventSnapshot(id: id, title: title, start: start, end: start.addingTimeInterval(length * 60),
                                     colorRGBA: [0.2, 0.4, 0.8, 1], isAllDay: allDay, isCanceled: canceled,
                                     isDeclined: declined, meetingLink: link)
    }

    private func pick(_ events: [CalendarEventSnapshot], hidden: Set<String> = []) -> EventGlance? {
        NextEventPicker.pick(events, now: now, hidden: hidden)
    }

    func testNothingToShow() {
        XCTAssertNil(pick([]))
    }

    func testUpcomingWithinAnHour() {
        let glance = pick([event("a", startIn: 12)])
        XCTAssertEqual(glance?.event.id, "a")
        XCTAssertEqual(glance?.chipSuffix, "12m")
        XCTAssertEqual(glance?.spokenText, "Sync in 12 minutes")
        XCTAssertEqual(glance?.isImminent, false)
    }

    func testSixtyMinuteLookahead() {
        XCTAssertEqual(NextEventPicker.lookahead, 3600)
        XCTAssertEqual(pick([event("a", startIn: 60)])?.chipSuffix, "60m")
        XCTAssertEqual(pick([event("a", startIn: 60)])?.spokenText, "Sync in 60 minutes")
        XCTAssertNil(pick([event("a", startIn: 60.5)]))
        XCTAssertNil(pick([event("a", startIn: 180)]))
    }

    func testMinutesRoundUp() {
        XCTAssertEqual(pick([event("a", startIn: 1.5)])?.chipSuffix, "2m")
        XCTAssertEqual(pick([event("a", startIn: 4.1)])?.chipSuffix, "5m")
        XCTAssertEqual(pick([event("a", startIn: 11.01)])?.chipSuffix, "12m")
        XCTAssertEqual(pick([event("a", startIn: 61.0 / 60)])?.chipSuffix, "2m")
        XCTAssertEqual(pick([event("a", startIn: 61.0 / 60)])?.spokenText, "Sync in 2 minutes")
    }

    func testNowWithinAMinuteOrInProgress() {
        XCTAssertEqual(pick([event("a", startIn: 1)])?.chipSuffix, "now", "exactly 60 s to go")
        XCTAssertEqual(pick([event("a", startIn: 0.25)])?.chipSuffix, "now")
        XCTAssertEqual(pick([event("a", startIn: 0)])?.chipSuffix, "now")
        XCTAssertEqual(pick([event("a", startIn: -3)])?.chipSuffix, "now")
        XCTAssertEqual(pick([event("a", startIn: -3)])?.spokenText, "Sync now")
    }

    func testImminentWithinFiveMinutes() {
        XCTAssertEqual(pick([event("a", startIn: 5)])?.isImminent, true)
        XCTAssertEqual(pick([event("a", startIn: 2)])?.isImminent, true)
        XCTAssertEqual(pick([event("a", startIn: 5.1)])?.isImminent, false)
        XCTAssertEqual(pick([event("a", startIn: -3)])?.isImminent, true)
    }

    func testLateJoinWindow() {
        XCTAssertEqual(NextEventPicker.lateJoinWindow, 600)
        XCTAssertNotNil(pick([event("a", startIn: -10)]))
        XCTAssertNil(pick([event("a", startIn: -10.5, length: 60)]), "too late to join")
    }

    func testEndedEventsNeverShow() {
        XCTAssertNil(pick([event("a", startIn: -5, length: 5)]))
        XCTAssertNil(pick([event("a", startIn: -5, length: 4)]))
        XCTAssertNotNil(pick([event("a", startIn: -5, length: 6)]))
    }

    func testFiltersAllDayCanceledDeclinedAndHidden() {
        XCTAssertNil(pick([event("a", startIn: 10, allDay: true)]))
        XCTAssertNil(pick([event("a", startIn: 10, canceled: true)]))
        XCTAssertNil(pick([event("a", startIn: 10, declined: true)]))
        XCTAssertNil(pick([event("a", startIn: 10)], hidden: ["a"]))
        XCTAssertNil(pick([event("a", startIn: -2, canceled: true)]), "a canceled meeting isn't joinable late")
        let next = pick([event("a", startIn: 10, declined: true), event("b", startIn: 20, canceled: true),
                         event("c", startIn: 30), event("d", startIn: 40)], hidden: ["c"])
        XCTAssertEqual(next?.event.id, "d")
    }

    func testLateJoinBeatsUpcoming() {
        let next = pick([event("later", startIn: 40), event("sooner", startIn: 0.5), event("running", startIn: -2)])
        XCTAssertEqual(next?.event.id, "running")
        let twoRunning = pick([event("recent", startIn: -1), event("earlier", startIn: -8)])
        XCTAssertEqual(twoRunning?.event.id, "earlier", "late-join candidates: earliest start first")
    }

    func testSoonestUpcomingWins() {
        XCTAssertEqual(pick([event("later", startIn: 40), event("sooner", startIn: 15)])?.event.id, "sooner")
    }

    func testTiesGoByTitle() throws {
        let link = try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij"))
        let tied = pick([event("z", startIn: 10, title: "Zulu", link: link), event("a", startIn: 10, title: "Alpha")])
        XCTAssertEqual(tied?.event.id, "a", "a meeting link doesn't break ties; the title does")
        let running = pick([event("z", startIn: -4, title: "Zulu"), event("a", startIn: -4, title: "Alpha")])
        XCTAssertEqual(running?.event.id, "a")
    }

    func testSnapshotCleansTitles() {
        XCTAssertEqual(event("a", startIn: 1, title: "").title, "Untitled Event")
        XCTAssertEqual(event("a", startIn: 1, title: " \u{202E}\u{200B} ").title, "Untitled Event")
        XCTAssertEqual(event("a", startIn: 1, title: "Stand\u{202E}up\nnotes").title, "Standup notes")
        let long = event("a", startIn: 1, title: String(repeating: "x", count: 300)).title
        XCTAssertEqual(long.count, 120)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testSnapshotID() {
        let start = Date(timeIntervalSince1970: 1_800_000_000.75)
        XCTAssertEqual(CalendarEventSnapshot.makeID(calendarItemIdentifier: "ABC", start: start), "ABC|1800000000")
    }
}

// MARK: - Meeting links

final class MeetingLinkDetectorTests: XCTestCase {
    private func link(_ url: String?, location: String? = nil, notes: String? = nil) -> String? {
        MeetingLinkDetector.link(url: url.flatMap(URL.init(string:)), location: location, notes: notes)?.absoluteString
    }

    func testAllowedHosts() {
        let good = [
            "https://zoom.us/j/123456789?pwd=abc",
            "https://zoom.us/my/jane.doe",
            "https://zoom.us/w/99887766",
            "https://acme.zoom.us/j/123456789",
            "https://us02web.zoom.us/j/1",
            "https://zoomgov.com/j/1601234567",
            "https://meet.google.com/abc-defg-hij",
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=x",
            "https://teams.live.com/meet/9876543210",
            "https://acme.webex.com/meet/jane",
            "https://acme.webex.com/acme/j.php?MTID=m1",
            "https://facetime.apple.com/join#v=1&p=abc",
            "https://meet.goto.com/123456789",
            "https://global.gotomeeting.com/join/123456789",
            "https://chime.aws/1234567890",
            "https://whereby.com/team-room",
            "https://ZOOM.US/j/1",
        ]
        for url in good {
            XCTAssertEqual(link(url), url, url)
        }
    }

    func testPathRules() {
        let bad = [
            "https://zoom.us/",
            "https://zoom.us/signin",
            "https://zoom.us/j/",
            "https://acme.zoom.us/profile",
            "https://zoomgov.com/download",
            "https://teams.microsoft.com/",
            "https://teams.microsoft.com/l/app/123",
            "https://teams.microsoft.com/l/meetup-joinery/1",
            "https://teams.live.com/free",
            "https://facetime.apple.com/",
            "https://facetime.apple.com/joinery",
        ]
        for url in bad {
            XCTAssertNil(link(url), url)
        }
    }

    func testHostsOutsideTheAllowlist() {
        let bad = [
            "https://zoom.com/j/1",                       // not on the list
            "https://www.zoomgov.com/j/1",                // zoomgov.com is exact-host only
            "https://webex.com/meet/jane",                // *.webex.com means a subdomain
            "https://gotomeeting.com/join/1",             // *.gotomeeting.com means a subdomain
            "https://goto.com/meet/1",
            "https://app.whereby.com/room",
            "https://www.chime.aws/1",
        ]
        for url in bad {
            XCTAssertNil(link(url), url)
        }
    }

    func testRejectsLookAlikesAndTricks() {
        let bad = [
            "https://zoom.us.evil.com/j/1",
            "https://evilzoom.us/j/1",
            "https://zoom-us.com/j/1",
            "https://meet.google.com.attacker.net/abc",
            "https://notmeet.google.com/abc",
            "https://google.com/meet/abc",
            "https://teams.microsoft.com.evil.io/l/meetup-join/1",
            "https://evilwebex.com/meet/jane",
            "https://acme.gotomeeting.com.evil.net/join/1",
            "https://user:pass@zoom.us/j/1",
            "https://zoom.us@evil.com/j/1",
            "https://zoom.us:8443/j/1",
            "https://zооm.us/j/1",               // Cyrillic о
            "https://xn--zm-dmaa.us/j/1",
        ]
        for url in bad {
            XCTAssertNil(link(url), url)
        }
    }

    func testRejectsNonHTTPS() {
        XCTAssertNil(link("http://zoom.us/j/1"))
        XCTAssertNil(link("http://meet.google.com/abc-defg-hij"))
        XCTAssertNil(link("zoommtg://zoom.us/join?confno=1"))
        XCTAssertNil(link("javascript://zoom.us/%0Aalert(1)"))
        XCTAssertNil(link("file:///Users/me/zoom.us/j/1"))
        XCTAssertNil(link("ftp://meet.google.com/abc"))
        XCTAssertNil(link(nil, location: "zoom.us/j/1"), "a bare host becomes http:// and is ignored")
        XCTAssertNil(link(nil, notes: "javascript:alert(1) file:///etc/passwd http://zoom.us/j/1"))
    }

    func testSearchOrderURLThenLocationThenNotes() {
        XCTAssertEqual(link("https://zoom.us/j/1", location: "https://meet.google.com/aaa-bbbb-ccc"),
                       "https://zoom.us/j/1")
        XCTAssertEqual(link("https://example.com/agenda", location: "Room 4 · https://meet.google.com/aaa-bbbb-ccc",
                            notes: "https://zoom.us/j/2"),
                       "https://meet.google.com/aaa-bbbb-ccc")
        XCTAssertEqual(link(nil, location: "Room 4", notes: "Agenda: https://docs.example.com/x\nJoin: https://zoom.us/j/2"),
                       "https://zoom.us/j/2")
    }

    func testNotesAreScannedOnlyToTheLimit() {
        XCTAssertEqual(MeetingLinkDetector.notesScanLimit, 20_000)
        let filler = String(repeating: "a", count: 19_000) + " "
        XCTAssertEqual(link(nil, notes: filler + "https://zoom.us/j/3"), "https://zoom.us/j/3")
        let longFiller = String(repeating: "a", count: 20_000) + " "
        XCTAssertNil(link(nil, notes: longFiller + "https://zoom.us/j/3"))
    }

    func testSkipsUntrustedLinksInText() {
        XCTAssertEqual(link(nil, notes: "Join https://zoom.us.evil.com/j/1 or https://acme.zoom.us/j/7"),
                       "https://acme.zoom.us/j/7")
        XCTAssertNil(link(nil, location: "", notes: "No link here"))
        XCTAssertNil(link(nil))
    }
}

// MARK: - CalendarGlance

/// Records calls; serves fixed events. Never touches EventKit.
@MainActor
private final class CalendarSpySource: CalendarEventSource {
    var authorization: CalendarGlance.Access = .granted
    var onStoreChanged: (@MainActor () -> Void)?
    var storedEvents: [CalendarEventSnapshot] = []
    var choices: [CalendarChoice] = [CalendarChoice(id: "work", title: "Work", source: "iCloud", colorRGBA: nil)]
    private(set) var resetCount = 0
    private(set) var eventRequests: [(start: Date, end: Date, excluded: Set<String>)] = []

    func calendars() async -> [CalendarChoice] { choices }

    func events(from start: Date, to end: Date, excluding calendarIDs: Set<String>) async -> [CalendarEventSnapshot] {
        eventRequests.append((start, end, calendarIDs))
        return storedEvents
    }

    func reset() { resetCount += 1 }
}

@MainActor
final class CalendarGlanceTests: XCTestCase {
    private let center = NotificationCenter()
    private let source = CalendarSpySource()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var settings: AppSettings!

    override func setUp() async throws {
        settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        settings.glance.calendarChipEnabled = true
    }

    private func event(_ id: String, startIn minutes: Double) -> CalendarEventSnapshot {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarEventSnapshot(id: id, title: "Design review", start: start, end: start.addingTimeInterval(1800),
                                     colorRGBA: nil, isAllDay: false, isCanceled: false, isDeclined: false,
                                     meetingLink: nil)
    }

    private func makeGlance() -> CalendarGlance {
        let glance = CalendarGlance(settings: settings, store: source, notificationCenter: center)
        glance.now = { [now] in now }
        return glance
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testDidGrantCalendarsResetsTheStore() async {
        let glance = makeGlance()
        PermissionEvents.post(.calendars, center: center)
        XCTAssertEqual(source.resetCount, 1)
        PermissionEvents.post(.microphone, center: center)
        PermissionEvents.post(.reminders, center: center)
        XCTAssertEqual(source.resetCount, 1, "only a Calendars grant resets the store")
        PermissionEvents.post(.calendars, center: center)
        XCTAssertEqual(source.resetCount, 2)
        withExtendedLifetime(glance) {}
    }

    func testDidGrantRefreshesAccessAndEvents() async {
        source.authorization = .notDetermined
        let glance = makeGlance()
        glance.start()
        XCTAssertEqual(glance.access, .notDetermined)
        XCTAssertNil(glance.next)

        source.authorization = .granted
        source.storedEvents = [event("a", startIn: 15)]
        PermissionEvents.post(.calendars, center: center)
        XCTAssertEqual(glance.access, .granted)
        await waitUntil { glance.next != nil }
        XCTAssertEqual(glance.next?.event.id, "a")
        XCTAssertEqual(glance.calendars.map(\.id), ["work"])
    }

    func testDefaultCenterIsNotObservedWhenAnotherIsInjected() {
        let glance = makeGlance()
        PermissionEvents.post(.calendars, center: NotificationCenter())
        XCTAssertEqual(source.resetCount, 0)
        withExtendedLifetime(glance) {}
    }

    func testStartRefreshesWithTheExclusionList() async throws {
        settings.glance.calendarExcludedIDs = ["home", "holidays"]
        source.storedEvents = [event("a", startIn: 30)]
        let glance = makeGlance()
        glance.start()
        await waitUntil { glance.next != nil }
        XCTAssertEqual(glance.next?.chipSuffix, "30m")
        let request = try XCTUnwrap(source.eventRequests.last)
        XCTAssertEqual(request.excluded, ["home", "holidays"])
        XCTAssertLessThanOrEqual(request.start, now.addingTimeInterval(-NextEventPicker.lateJoinWindow))
        XCTAssertGreaterThanOrEqual(request.end, now.addingTimeInterval(NextEventPicker.lookahead))
    }

    func testDeniedAccessShowsNothingAndReadsNothing() async {
        source.authorization = .denied
        source.storedEvents = [event("a", startIn: 5)]
        let glance = makeGlance()
        glance.start()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(glance.access, .denied)
        XCTAssertNil(glance.next)
        XCTAssertTrue(glance.calendars.isEmpty)
        XCTAssertTrue(source.eventRequests.isEmpty)
    }

    func testChipOffReadsCalendarsButNoEvents() async {
        settings.glance.calendarChipEnabled = false
        source.storedEvents = [event("a", startIn: 5)]
        let glance = makeGlance()
        glance.start()
        await waitUntil { !glance.calendars.isEmpty }
        XCTAssertEqual(glance.calendars.map(\.id), ["work"])
        XCTAssertNil(glance.next)
        XCTAssertTrue(source.eventRequests.isEmpty)
    }

    func testStoreChangeRefreshes() async {
        let glance = makeGlance()
        glance.start()
        await waitUntil { [source] in source.eventRequests.count == 1 }
        source.storedEvents = [event("b", startIn: 45)]
        source.onStoreChanged?()
        await waitUntil { glance.next != nil }
        XCTAssertEqual(glance.next?.event.id, "b")
    }

    func testStoreChangeBeforeStartIsIgnored() async {
        let glance = makeGlance()
        source.onStoreChanged?()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(source.eventRequests.isEmpty)
        withExtendedLifetime(glance) {}
    }

    func testHideDropsThatOccurrence() async {
        source.storedEvents = [event("a", startIn: 10), event("b", startIn: 20)]
        let glance = makeGlance()
        glance.start()
        await waitUntil { glance.next != nil }
        XCTAssertEqual(glance.next?.event.id, "a")
        glance.hide(eventID: "a")
        XCTAssertEqual(glance.next?.event.id, "b")
        glance.hide(eventID: "b")
        XCTAssertNil(glance.next)
    }

    func testTicksOnlyWhileOpen() async {
        var sleeps: [Duration] = []
        var cancelledSleeps = 0
        let glance = makeGlance()
        glance.sleep = { duration in
            sleeps.append(duration)
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                cancelledSleeps += 1
                throw error
            }
        }
        glance.start()
        XCTAssertTrue(sleeps.isEmpty, "no tick while closed")

        glance.panelDidOpen()
        await waitUntil { sleeps.count == 1 }
        XCTAssertEqual(sleeps, [CalendarGlance.tickInterval])
        XCTAssertEqual(CalendarGlance.tickInterval, .seconds(30))

        glance.panelDidOpen()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sleeps.count, 1, "one tick loop at a time")

        glance.panelDidClose()
        await waitUntil { cancelledSleeps == 1 }
        XCTAssertEqual(cancelledSleeps, 1)
    }

    func testTickRefreshes() async {
        var ticks = 0
        let glance = makeGlance()
        glance.sleep = { _ in
            ticks += 1
            if ticks > 2 { try await Task.sleep(for: .seconds(3600)) }
        }
        glance.start()
        glance.panelDidOpen()
        // start() + panelDidOpen() + two immediate ticks.
        await waitUntil { [source] in source.eventRequests.count >= 4 }
        XCTAssertGreaterThanOrEqual(source.eventRequests.count, 4)
        glance.panelDidClose()
    }

    func testOpeningBeforeStartDoesNotTick() async {
        var sleeps = 0
        let glance = makeGlance()
        glance.sleep = { _ in
            sleeps += 1
            try await Task.sleep(for: .seconds(3600))
        }
        glance.panelDidOpen()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sleeps, 0)

        glance.start()
        await waitUntil { sleeps == 1 }
        XCTAssertEqual(sleeps, 1, "start() while open begins the tick")
        glance.stop()
    }

    func testDebugSeed() {
        let glance = makeGlance()
        let seeded = EventGlance(event: event("x", startIn: 3), chipSuffix: "3m",
                                 spokenText: "Design review in 3 minutes", isImminent: true)
        glance.debugSeed(next: seeded)
        XCTAssertEqual(glance.next, seeded)
        glance.debugSeed(next: nil)
        XCTAssertNil(glance.next)
    }

    func testInertSourceServesItsEventsWithoutEventKit() async {
        let running = event("r", startIn: -5)
        let inert = InertCalendarSource(events: [running, event("late", startIn: 300)])
        XCTAssertEqual(inert.authorization, .granted)
        let window = await inert.events(from: now, to: now.addingTimeInterval(3600), excluding: ["any"])
        XCTAssertEqual(window.map(\.id), ["r"])
        inert.reset()
        let calendars = await inert.calendars()
        XCTAssertTrue(calendars.isEmpty)

        let glance = CalendarGlance(settings: settings, store: inert, notificationCenter: center)
        glance.now = { [now] in now }
        glance.start()
        await waitUntil { glance.next != nil }
        XCTAssertEqual(glance.next?.event.id, "r")
        XCTAssertEqual(glance.next?.chipSuffix, "now")
    }
}
