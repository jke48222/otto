//
//  UpdatesSectionTests.swift
//  OttoTests
//
//  The Updates section with StaticUpdaterModel: the Sparkle rows and their exact captions, the download toggle
//  disabled while checks are off, "Last checked" wording, the ready-to-install row, the Setapp variant (no
//  toggles, its own wording, What's New…, a check when it appears), buttons reaching the updater, and layout.
//  Compiled in the paid project only.
//

#if OTTO_SPARKLE
import AppKit
import SwiftUI
import XCTest
@testable import Otto

@MainActor
final class UpdatesSectionTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private func noon(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12)) ?? .distantPast
    }

    private func rows(_ updater: UpdaterControlling, siteHost: String? = "otto-fixture.test",
                      now: Date? = nil) -> [UpdatesSection.Row] {
        UpdatesSection.rows(updater: updater, siteHost: siteHost, now: now ?? noon(10, 11), locale: locale,
                            calendar: calendar)
    }

    // MARK: - Sparkle

    func testSparkleRowsAndCaptions() {
        let updater = StaticUpdaterModel(source: .sparkle)

        XCTAssertEqual(rows(updater), [
            .automaticChecks(title: "Check for updates automatically",
                             caption: "Once a day Otto asks otto-fixture.test for the release list. The request "
                                 + "carries Otto's version number and nothing that identifies you or your Mac."),
            .automaticDownloads(title: "Download and install updates automatically",
                                caption: "Updates install when Otto quits. You can install sooner here.",
                                isEnabled: true),
            .checkNow(title: "Check Now", status: "Not checked yet", isEnabled: true),
        ])
    }

    func testCaptionEndsWithNothingThatIdentifiesYou() {
        XCTAssertTrue(UpdatesSection.automaticChecksCaption(siteHost: "otto-fixture.test")
            .hasSuffix("nothing that identifies you or your Mac."))
        XCTAssertEqual(UpdatesSection.automaticChecksCaption(siteHost: nil),
                       "Once a day Otto asks its website for the release list. The request carries Otto's version "
                           + "number and nothing that identifies you or your Mac.")
        XCTAssertEqual(UpdatesSection.automaticChecksCaption(siteHost: ""),
                       UpdatesSection.automaticChecksCaption(siteHost: nil))
    }

    func testDownloadToggleIsDisabledWhileChecksAreOff() {
        let updater = StaticUpdaterModel(source: .sparkle, automaticallyChecks: false, automaticallyDownloads: true)

        XCTAssertTrue(rows(updater).contains(.automaticDownloads(
            title: "Download and install updates automatically",
            caption: "Updates install when Otto quits. You can install sooner here.", isEnabled: false)))

        updater.automaticallyChecks = true
        XCTAssertTrue(rows(updater).contains(.automaticDownloads(
            title: "Download and install updates automatically",
            caption: "Updates install when Otto quits. You can install sooner here.", isEnabled: true)))
    }

    func testCheckNowFollowsTheUpdater() {
        let updater = StaticUpdaterModel(source: .sparkle)
        updater.canCheckNow = false
        XCTAssertTrue(rows(updater).contains(.checkNow(title: "Check Now", status: "Not checked yet", isEnabled: false)))
    }

    func testLastCheckedWording() {
        let now = noon(10, 11)
        XCTAssertEqual(UpdatesSection.lastCheckedText(nil, now: now, locale: locale, calendar: calendar),
                       "Not checked yet")
        XCTAssertEqual(UpdatesSection.lastCheckedText(now.addingTimeInterval(-3_600), now: now, locale: locale,
                                                      calendar: calendar), "Last checked today")
        XCTAssertEqual(UpdatesSection.lastCheckedText(noon(10, 10), now: now, locale: locale, calendar: calendar),
                       "Last checked yesterday")
        XCTAssertEqual(UpdatesSection.lastCheckedText(noon(10, 2), now: now, locale: locale, calendar: calendar),
                       "Last checked Oct 2")

        let updater = StaticUpdaterModel(source: .sparkle, lastCheck: noon(10, 10))
        XCTAssertTrue(rows(updater, now: now).contains(.checkNow(title: "Check Now", status: "Last checked yesterday",
                                                                  isEnabled: true)))
    }

    func testSparklePendingRow() {
        let updater = StaticUpdaterModel(source: .sparkle, pendingUpdate: PendingUpdate(version: "1.2.0",
                                                                                         releaseNotes: nil))
        XCTAssertEqual(rows(updater).last, .pending(text: "Otto 1.2.0 is ready.", buttonTitle: "Install and Relaunch…"))
        XCTAssertFalse(rows(updater).contains { $0.id == "releaseNotes" }, "Sparkle's own window shows the notes")
    }

    func testSparkleWithoutUserSettingsHidesTheToggles() {
        let updater = StaticUpdaterModel(source: .sparkle)
        updater.allowsUserSettings = false
        XCTAssertEqual(rows(updater).map(\.id), ["checkNow"])
    }

    // MARK: - Setapp

    func testSetappRows() {
        let updater = StaticUpdaterModel(source: .setapp)
        XCTAssertEqual(rows(updater, siteHost: nil), [
            .setappNote("Setapp keeps Otto up to date."),
            .releaseNotes(title: "What's New…"),
        ])

        updater.pendingUpdate = PendingUpdate(version: "1.2.0", releaseNotes: "- Faster replies")
        XCTAssertEqual(rows(updater, siteHost: nil), [
            .setappNote("Setapp keeps Otto up to date."),
            .pending(text: "Setapp has Otto 1.2.0 ready.", buttonTitle: "Update and Relaunch…"),
            .releaseNotes(title: "What's New…"),
        ])
    }

    func testSetappHidesTheTogglesAndCheckNow() {
        let ids = rows(StaticUpdaterModel(source: .setapp)).map(\.id)
        XCTAssertFalse(ids.contains("automaticChecks"))
        XCTAssertFalse(ids.contains("automaticDownloads"))
        XCTAssertFalse(ids.contains("checkNow"))
    }

    // MARK: - Actions

    func testButtonsReachTheUpdater() {
        let updater = StaticUpdaterModel(source: .sparkle)
        UpdatesSection.perform(.checkNow, on: updater)
        UpdatesSection.perform(.install, on: updater)
        UpdatesSection.perform(.releaseNotes, on: updater)
        XCTAssertEqual(updater.calls, ["checkNow", "install", "releaseNotes"])
    }

    // MARK: - Layout

    func testBothVariantsLayOutAndSetappChecksWhenShown() async throws {
        let pending = PendingUpdate(version: "1.2.0", releaseNotes: nil)
        let sparkle = StaticUpdaterModel(source: .sparkle, pendingUpdate: pending, lastCheck: Date())
        let sparkleOff = StaticUpdaterModel(source: .sparkle, automaticallyChecks: false)
        let setapp = StaticUpdaterModel(source: .setapp, pendingUpdate: pending)
        var opened: [URL] = []

        for updater in [sparkle, sparkleOff] {
            try await layOut(UpdatesSection(updater: updater, siteHost: "otto-fixture.test") { opened.append($0) })
            XCTAssertEqual(updater.calls, [], "showing the Sparkle section never checks by itself")
        }
        try await layOut(UpdatesSection(updater: setapp, siteHost: nil) { opened.append($0) })
        XCTAssertEqual(setapp.calls, ["checkNow"], "Setapp's local state is read when the section appears")
        XCTAssertTrue(opened.isEmpty)
    }

    private func layOut(_ section: UpdatesSection) async throws {
        let size = NSSize(width: 560, height: 420)
        let host = NSHostingView(rootView: Form { section }.formStyle(.grouped))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertEqual(host.frame.size, size)
    }
}
#endif
