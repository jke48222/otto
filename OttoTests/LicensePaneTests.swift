//
//  LicensePaneTests.swift
//  OttoTests
//
//  Settings → License with StaticLicenseModel: every status and message lays out; the rows of §14.10.2 for each
//  state, including the pending-revocation line followed by the key field and Activate; the demo line without a
//  model; the problems banner; the two confirmations; buttons reaching the model; and the key field taking focus
//  in a key window when the pane opens for `.licenseKey`.
//

#if OTTO_LICENSING
import AppKit
import SwiftUI
import XCTest
@testable import Otto

@MainActor
final class LicensePaneTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows = []
    }

    // MARK: - Fixtures

    /// Noon UTC, so the day is the same in every time zone within ±11 hours (pendingRevocationLine uses .current).
    private func noon(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12)) ?? .distantPast
    }

    private var now: Date { noon(10, 11) }

    private func summary(_ backend: LicenseBackendKind, pending: PendingRevocation? = nil,
                         seatLimit: Int? = 3) -> LicenseSummary {
        let polar = backend == .polar
        let record = LicenseRecord(schema: 1, backend: backend, apiHost: polar ? "api.polar.sh" : "api.gumroad.com",
                                   organizationID: polar ? LicenseFixtures.organizationID : nil,
                                   benefitID: polar ? LicenseFixtures.benefitID : nil,
                                   gumroadProductID: polar ? nil : LicenseFixtures.gumroadProductID,
                                   key: polar ? LicenseFixtures.polarKey : LicenseFixtures.gumroadKey,
                                   licenseKeyID: nil, activationID: polar ? LicenseFixtures.activationID : nil,
                                   label: polar ? "Mac 7F3A" : "",
                                   displayKey: polar ? "****-E304DA" : "****-7E8F90", seatLimit: seatLimit,
                                   activatedAt: noon(9, 1), lastValidatedAt: noon(10, 11), lastAttemptAt: nil,
                                   pendingRevocation: pending)
        return LicenseSummary(record: record)
    }

    private var pending: PendingRevocation { PendingRevocation(firstSeenAt: noon(10, 10), reason: .notFound) }

    private var everyStatus: [LicenseStatus] {
        [
            .trial(endsAt: noon(10, 20), daysLeft: 9),
            .trial(endsAt: noon(10, 12), daysLeft: 1),
            .trialEnded(endedAt: noon(10, 1)),
            .licensed(summary(.polar)),
            .licensed(summary(.gumroad)),
            .licensed(summary(.polar, pending: pending)),
            .licensed(summary(.gumroad, pending: PendingRevocation(firstSeenAt: noon(10, 10), reason: .disabled))),
            .licensedCheckOverdue(summary(.polar), sendingPausesAt: noon(10, 25)),
            .licensedCheckRequired(summary(.gumroad, seatLimit: nil)),
            .unavailable(.keychain(-25_293)),
            .unavailable(.undecodable(account: "license", createdAt: nil)),
        ]
    }

    private var everyMessage: [LicenseMessage?] {
        [
            nil,
            LicenseCopy.activated,
            LicenseCopy.rekeyed,
            LicenseCopy.activatedUnsaved(status: -25_293),
            LicenseCopy.checkedValid,
            LicenseCopy.activationFailure(.seatLimitReached(limit: 3), backend: .polar,
                                          supportEmail: LicenseConfiguration.preview.supportEmail),
            LicenseCopy.checkFailure(.offline, backend: .gumroad),
            LicenseCopy.deactivation(.unavailable(.timeout), backend: .polar,
                                     supportEmail: LicenseConfiguration.preview.supportEmail),
            LicenseCopy.removedLocally(.gumroad, supportEmail: LicenseConfiguration.preview.supportEmail),
        ]
    }

    private func rows(_ model: LicenseControlling?) -> [LicensePane.Row] {
        LicensePane.rows(model: model, now: now, locale: locale, calendar: calendar)
    }

    private var sandboxRow: LicensePane.Row { .configuration(problems: [], isSandbox: true) }

    private let footerRow = LicensePane.Row.footer

    // MARK: - Layout

    func testLaysOutForEveryStatusMessageAndActivity() async throws {
        let removal = LicenseRemoval(at: noon(10, 5), reason: .revoked)
        for status in everyStatus {
            for message in everyMessage {
                let model = StaticLicenseModel(status: status, lastMessage: message)
                try await layOut(LicensePane(model: model, focusKeyField: false) { _ in })
            }
            for activity in [LicenseActivity.activating, .checking, .deactivating] {
                let model = StaticLicenseModel(status: status, lastRemoval: removal, activity: activity)
                try await layOut(LicensePane(model: model, focusKeyField: false) { _ in })
            }
        }
    }

    func testLaysOutForEveryRemovalAndAMisconfiguredBuild() async throws {
        let reasons: [LicenseRemovalReason] = [.revoked, .refunded, .chargedBack, .disabled, .wrongProduct,
                                               .deactivatedByUser, .removedByUser]
        for reason in reasons {
            let model = StaticLicenseModel(status: .trialEnded(endedAt: noon(10, 1)),
                                           lastRemoval: LicenseRemoval(at: noon(10, 5), reason: reason))
            try await layOut(LicensePane(model: model, focusKeyField: false) { _ in })
        }
        let model = StaticLicenseModel(status: .trialEnded(endedAt: noon(10, 1)), configuration: misconfigured)
        try await layOut(LicensePane(model: model, focusKeyField: true) { _ in })
        try await layOut(LicensePane(model: nil, focusKeyField: false) { _ in })
    }

    // MARK: - Rows

    func testDemoLineWhenTheModelIsNil() {
        XCTAssertEqual(rows(nil), [.demo("Licenses aren't checked in demo mode.")])
    }

    func testTrialRows() {
        let model = StaticLicenseModel(status: .trial(endsAt: noon(10, 20), daysLeft: 9))
        XCTAssertEqual(rows(model), [
            sandboxRow,
            .status(title: "Free trial: 9 days left",
                    detail: "Every feature works until Oct 20. After that, sending a message needs a license.",
                    badge: .trial),
            .keyEntry(showsBuy: true),
            footerRow,
        ])
    }

    func testTrialEndedRows() {
        let model = StaticLicenseModel(status: .trialEnded(endedAt: noon(10, 1)))
        XCTAssertEqual(rows(model), [
            sandboxRow,
            .status(title: "Your trial has ended",
                    detail: "Settings, Recents and demo mode still work. Sending a message needs a license.",
                    badge: .ended),
            .keyEntry(showsBuy: true),
            footerRow,
        ])
    }

    func testRemovalLineReplacesTheDetailOnce() {
        let removal = LicenseRemoval(at: noon(10, 5), reason: .deactivatedByUser)
        let model = StaticLicenseModel(status: .trialEnded(endedAt: noon(10, 1)), lastRemoval: removal)
        XCTAssertEqual(rows(model), [
            sandboxRow,
            .status(title: "No license on this Mac", detail: nil, badge: .ended),
            .removal("You deactivated Otto on this Mac."),
            .keyEntry(showsBuy: true),
            footerRow,
        ])
    }

    func testRemovalLineDuringTheTrialKeepsTheTrialDetail() {
        let removal = LicenseRemoval(at: noon(10, 5), reason: .refunded)
        let model = StaticLicenseModel(status: .trial(endsAt: noon(10, 20), daysLeft: 9), lastRemoval: removal)
        let result = rows(model)
        XCTAssertTrue(result.contains(.removal("Gumroad reports this purchase as refunded.")))
        XCTAssertTrue(result.contains(.status(
            title: "Free trial: 9 days left",
            detail: "Every feature works until Oct 20. After that, sending a message needs a license.",
            badge: .trial)))
    }

    func testLicensedPolarRows() {
        let model = StaticLicenseModel(status: .licensed(summary(.polar)))
        let confirmation = LicensePane.Confirmation(
            title: "Deactivate Otto on this Mac?",
            message: "This frees one of your 3 seats. You can enter the key again later.",
            confirmTitle: "Deactivate")
        XCTAssertEqual(rows(model), [
            sandboxRow,
            .status(title: "Licensed", detail: "Key ****-E304DA on Mac 7F3A, checked today.", badge: .active),
            .detail(label: "This Mac", value: "Mac 7F3A"),
            .detail(label: "Key", value: "****-E304DA"),
            .detail(label: "Seats", value: "3 Macs"),
            .licensedActions(backend: .polar, confirmation: confirmation, showsPortal: true),
            footerRow,
        ])
    }

    func testLicensedGumroadRows() {
        let model = StaticLicenseModel(status: .licensed(summary(.gumroad)))
        let confirmation = LicensePane.Confirmation(
            title: "Remove the license from this Mac?",
            message: "Gumroad keeps counting this Mac until I reset it. Email support@example.com to free the seat.",
            confirmTitle: "Remove")
        let result = rows(model)
        XCTAssertTrue(result.contains(.detail(label: "This Mac", value: "Gumroad key")))
        XCTAssertTrue(result.contains(.licensedActions(backend: .gumroad, confirmation: confirmation,
                                                       showsPortal: false)))
        XCTAssertFalse(result.contains { $0.id == "keyEntry" })
    }

    func testPendingRevocationShowsTheLineThenTheKeyFieldAndActivate() {
        let model = StaticLicenseModel(status: .licensed(summary(.polar, pending: pending)))
        let result = rows(model)
        let line = "Polar reported a problem with this license on Oct 10. If you rotated your key, enter the new one. "
            + "Otherwise Otto checks again tomorrow before it turns the license off."
        guard let lineIndex = result.firstIndex(of: .pendingRevocation(line)) else {
            return XCTFail("no pending-revocation line in \(result)")
        }
        XCTAssertEqual(result[lineIndex + 1], .keyEntry(showsBuy: false), "the key field and Activate, without Buy")
        XCTAssertTrue(result.contains(.detail(label: "Key", value: "****-E304DA")), "the license rows stay")
        XCTAssertTrue(LicensePane.canActivate(key: LicenseFixtures.polarKey, activity: model.activity))

        let gumroad = StaticLicenseModel(status: .licensedCheckRequired(
            summary(.gumroad, pending: PendingRevocation(firstSeenAt: noon(10, 10), reason: .disabled))))
        XCTAssertTrue(rows(gumroad).contains(.pendingRevocation(
            "Gumroad reported a problem with this license on Oct 10. "
                + "Otto checks again tomorrow before it turns the license off.")))
        XCTAssertTrue(rows(gumroad).contains(.keyEntry(showsBuy: false)))
    }

    func testBadges() {
        XCTAssertEqual(LicensePane.badge(for: .trial(endsAt: now, daysLeft: 3))?.title, "Trial")
        XCTAssertEqual(LicensePane.badge(for: .trialEnded(endedAt: now))?.title, "Ended")
        XCTAssertEqual(LicensePane.badge(for: .licensed(summary(.polar)))?.title, "Active")
        XCTAssertEqual(LicensePane.badge(for: .licensedCheckOverdue(summary(.polar), sendingPausesAt: now))?.title,
                       "Check needed")
        XCTAssertEqual(LicensePane.badge(for: .licensedCheckRequired(summary(.polar)))?.title, "Check needed")
        XCTAssertNil(LicensePane.badge(for: .unavailable(.keychain(-25_293))))
    }

    func testSeats() {
        XCTAssertEqual(LicensePane.seatsText(3), "3 Macs")
        XCTAssertEqual(LicensePane.seatsText(nil), "3 Macs")
        XCTAssertEqual(LicensePane.seatsText(1), "1 Mac")
        XCTAssertEqual(LicensePane.seatsText(6), "6 Macs")
    }

    func testUnavailableShowsTheStatusWithoutAKeyField() {
        let model = StaticLicenseModel(status: .unavailable(.keychain(-25_293)))
        XCTAssertEqual(rows(model), [
            sandboxRow,
            .status(title: "License status unknown",
                    detail: "Otto couldn't read its license from the Keychain (error -25293). "
                        + "It works normally until it can.",
                    badge: nil),
            footerRow,
        ])
    }

    func testProblemsBannerAndNoBuyWithoutASite() {
        let model = StaticLicenseModel(status: .trialEnded(endedAt: noon(10, 1)), configuration: misconfigured)
        let result = rows(model)
        XCTAssertEqual(result.first, .configuration(problems: misconfigured.problems, isSandbox: false))
        XCTAssertTrue(result.contains(.keyEntry(showsBuy: false)), "no Buy while the site host is missing")
        XCTAssertFalse(result.contains(.footer), "no site, no Terms, Privacy or Refunds links")
        XCTAssertEqual(LicensePane.problemsTitle, "This build can't check licenses:")
        XCTAssertEqual(LicensePane.problemsFooter, "Set them in Config/Commercial.xcconfig.")
        XCTAssertEqual(LicensePane.sandboxBadge, "Polar sandbox")
        XCTAssertEqual(LicensePane.keyPlaceholder, "OTTO-… or a Gumroad key")
    }

    func testMessageRowOffersRemovalOnlyAfterAFailedDeactivation() {
        let support = LicenseConfiguration.preview.supportEmail
        let failed = LicenseCopy.deactivation(.unavailable(.offline), backend: .polar, supportEmail: support)
        let licensed = StaticLicenseModel(status: .licensed(summary(.polar)), lastMessage: failed)
        XCTAssertTrue(rows(licensed).contains(.message(failed, offersRemoval: true)))

        let offline = LicenseCopy.checkFailure(.offline, backend: .polar)
        let checking = StaticLicenseModel(status: .licensed(summary(.polar)), lastMessage: offline)
        XCTAssertTrue(rows(checking).contains(.message(offline, offersRemoval: false)))

        let trial = StaticLicenseModel(status: .trial(endsAt: noon(10, 20), daysLeft: 9),
                                       lastMessage: LicenseCopy.activated)
        XCTAssertTrue(rows(trial).contains(.message(LicenseCopy.activated, offersRemoval: false)))
    }

    // MARK: - Actions

    func testButtonsCallTheModel() {
        let model = StaticLicenseModel(status: .licensed(summary(.polar)), lastMessage: LicenseCopy.checkedValid)
        var opened: [URL] = []
        let perform = { (action: LicensePane.Action) in
            LicensePane.perform(action, model: model) { opened.append($0) }
        }

        perform(.activate("  \(LicenseFixtures.polarKey)\n"))
        perform(.activate("   "))
        perform(.checkNow)
        perform(.deactivate)
        perform(.removeFromThisMac)
        perform(.dismissMessage)
        perform(.buy)
        perform(.openPortal)
        perform(.openSitePage("terms"))
        perform(.openSitePage("privacy"))
        perform(.openSitePage("refunds"))

        XCTAssertEqual(model.calls, ["activate:\(LicenseFixtures.polarKey)", "checkNow", "deactivate",
                                     "removeFromThisMac", "dismissMessage"])
        XCTAssertNil(model.lastMessage, "Dismiss clears the message")
        XCTAssertEqual(opened.map(\.absoluteString), [
            "https://otto-sandy.vercel.app/buy",
            "https://sandbox.polar.sh/otto-preview/portal",
            "https://otto-sandy.vercel.app/terms",
            "https://otto-sandy.vercel.app/privacy",
            "https://otto-sandy.vercel.app/refunds",
        ])
    }

    func testBusyModelIgnoresActivateCheckAndDeactivate() {
        let model = StaticLicenseModel(status: .licensed(summary(.polar)), activity: .checking)
        LicensePane.perform(.activate(LicenseFixtures.polarKey), model: model) { _ in }
        LicensePane.perform(.checkNow, model: model) { _ in }
        LicensePane.perform(.deactivate, model: model) { _ in }
        XCTAssertEqual(model.calls, [])
        XCTAssertFalse(LicensePane.canActivate(key: LicenseFixtures.polarKey, activity: .activating))
        XCTAssertFalse(LicensePane.canActivate(key: " \n", activity: .idle))
    }

    func testConfirmations() {
        XCTAssertEqual(LicensePane.Confirmation.forBackend(.polar, seats: 3, supportEmail: "help@otto-fixture.test"),
                       LicensePane.Confirmation(
                           title: "Deactivate Otto on this Mac?",
                           message: "This frees one of your 3 seats. You can enter the key again later.",
                           confirmTitle: "Deactivate"))
        XCTAssertEqual(LicensePane.Confirmation.forBackend(.gumroad, seats: 3,
                                                           supportEmail: "help@otto-fixture.test"),
                       LicensePane.Confirmation(
                           title: "Remove the license from this Mac?",
                           message: "Gumroad keeps counting this Mac until I reset it. "
                               + "Email help@otto-fixture.test to free the seat.",
                           confirmTitle: "Remove"))
    }

    // MARK: - Focus

    func testKeyFieldTakesFocusInAKeyWindow() async throws {
        let model = StaticLicenseModel(status: .trialEnded(endedAt: noon(10, 1)))
        let window = try await hostInKeyWindow(LicensePane(model: model, focusKeyField: true) { _ in })
        try XCTSkipUnless(NSApp.isActive, "The test host isn't the active app, so no window of it can be key.")
        XCTAssertTrue(window.isKeyWindow)
        let responder = String(describing: window.firstResponder)
        XCTAssertTrue(window.firstResponder is NSTextView, "the key field's field editor leads, got \(responder)")
    }

    // MARK: - Helpers

    private var misconfigured: LicenseConfiguration {
        LicenseConfiguration(siteHost: "", supportEmail: "", polar: nil, gumroad: nil, gumroadExplicitlyOff: false,
                             problems: ["OTTO_POLAR_ORGANIZATION_ID is still a placeholder",
                                        "OTTO_SITE_HOST is still a placeholder"])
    }

    private func form(_ pane: LicensePane) -> some View {
        Form { pane }
            .formStyle(.grouped)
    }

    private func layOut(_ pane: LicensePane) async throws {
        let size = NSSize(width: 560, height: 640)
        let host = NSHostingView(rootView: form(pane))
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
        try await Task.sleep(for: .milliseconds(20))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertEqual(host.frame.size, size)
    }

    /// A titled window (a borderless one can't become key), made key the way Settings shows its panel.
    private func hostInKeyWindow(_ pane: LicensePane) async throws -> NSWindow {
        let size = NSSize(width: 560, height: 640)
        let host = NSHostingView(rootView: form(pane))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        // The pane asks for focus 50 ms after the field appears; give it a few run-loop turns beyond that.
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
            if window.firstResponder is NSTextView { break }
        }
        return window
    }
}
#endif
