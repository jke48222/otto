//
//  LicenseCopyTests.swift
//  OttoTests
//
//  Every string of §14.10.1 and §14.10.2, exactly, in en_US with a fixed calendar and time zone, plus the composer
//  gate table including the activity rows and a build without a buy link.
//

#if OTTO_LICENSING
import XCTest
@testable import Otto

final class LicenseCopyTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private let support = "help@otto-fixture.test"
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// Noon UTC, so the day is the same in every time zone within ±11 hours (pendingRevocationLine uses .current).
    private func noon(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12)) ?? .distantPast
    }

    private func summary(_ backend: LicenseBackendKind, validatedAt: Date,
                         pending: PendingRevocation? = nil) -> LicenseSummary {
        let polar = backend == .polar
        let record = LicenseRecord(schema: 1, backend: backend, apiHost: polar ? "api.polar.sh" : "api.gumroad.com",
                                   organizationID: polar ? LicenseFixtures.organizationID : nil,
                                   benefitID: polar ? LicenseFixtures.benefitID : nil,
                                   gumroadProductID: polar ? nil : LicenseFixtures.gumroadProductID,
                                   key: polar ? LicenseFixtures.polarKey : LicenseFixtures.gumroadKey,
                                   licenseKeyID: nil, activationID: polar ? LicenseFixtures.activationID : nil,
                                   label: polar ? "Mac 7F3A" : "",
                                   displayKey: polar ? "****-E304DA" : "****-7E8F90", seatLimit: 3,
                                   activatedAt: validatedAt, lastValidatedAt: validatedAt, lastAttemptAt: nil,
                                   pendingRevocation: pending)
        return LicenseSummary(record: record)
    }

    private func detail(_ status: LicenseStatus, removal: LicenseRemoval? = nil, now: Date) -> String {
        LicenseCopy.statusDetail(status, removal: removal, configuration: .preview, now: now, locale: locale,
                                 calendar: calendar)
    }

    // MARK: - Status titles and details

    func testTrialCopy() {
        XCTAssertEqual(LicenseCopy.statusTitle(.trial(endsAt: noon(10, 25), daysLeft: 14)), "Free trial: 14 days left")
        XCTAssertEqual(LicenseCopy.statusTitle(.trial(endsAt: noon(10, 12), daysLeft: 1)), "Free trial: 1 day left")
        XCTAssertEqual(detail(.trial(endsAt: noon(10, 25), daysLeft: 14), now: noon(10, 11)),
                       "Every feature works until Oct 25. After that, sending a message needs a license.")
    }

    func testTrialEndedCopy() {
        let ended = LicenseStatus.trialEnded(endedAt: noon(10, 25))
        XCTAssertEqual(LicenseCopy.statusTitle(ended), "Your trial has ended")
        XCTAssertEqual(LicenseCopy.statusTitle(ended, removal: nil), "Your trial has ended")
        XCTAssertEqual(detail(ended, now: noon(10, 26)),
                       "Settings, Recents and demo mode still work. Sending a message needs a license.")

        let removal = LicenseRemoval(at: noon(10, 26), reason: .deactivatedByUser)
        XCTAssertEqual(LicenseCopy.statusTitle(ended, removal: removal), "No license on this Mac")
        XCTAssertEqual(detail(ended, removal: removal, now: noon(10, 27)), "You deactivated Otto on this Mac.")
    }

    func testLicensedCopy() {
        let now = noon(10, 13)
        let today = summary(.polar, validatedAt: now.addingTimeInterval(-3_600))
        XCTAssertEqual(LicenseCopy.statusTitle(.licensed(today)), "Licensed")
        XCTAssertEqual(detail(.licensed(today), now: now), "Key ****-E304DA on Mac 7F3A, checked today.")
        XCTAssertEqual(detail(.licensed(summary(.polar, validatedAt: noon(10, 12))), now: now),
                       "Key ****-E304DA on Mac 7F3A, checked yesterday.")
        XCTAssertEqual(detail(.licensed(summary(.polar, validatedAt: noon(10, 11))), now: now),
                       "Key ****-E304DA on Mac 7F3A, checked Oct 11.")
        XCTAssertEqual(detail(.licensed(summary(.gumroad, validatedAt: noon(10, 12))), now: now),
                       "Gumroad key ****-7E8F90, checked yesterday.")
    }

    func testOverdueCopy() {
        let polar = summary(.polar, validatedAt: noon(9, 11))
        let overdue = LicenseStatus.licensedCheckOverdue(polar, sendingPausesAt: noon(10, 25))
        XCTAssertEqual(LicenseCopy.statusTitle(overdue), "Licensed")
        XCTAssertEqual(detail(overdue, now: noon(10, 12)),
                       "Otto hasn't reached Polar since Sep 11. It keeps sending until Oct 25; connect to the internet "
                       + "and it checks on its own.")
        let gumroad = LicenseStatus.licensedCheckOverdue(summary(.gumroad, validatedAt: noon(9, 11)),
                                                         sendingPausesAt: noon(10, 25))
        XCTAssertEqual(detail(gumroad, now: noon(10, 12)),
                       "Otto hasn't reached Gumroad since Sep 11. It keeps sending until Oct 25; connect to the internet "
                       + "and it checks on its own.")
    }

    func testCheckRequiredCopy() {
        let required = LicenseStatus.licensedCheckRequired(summary(.polar, validatedAt: noon(8, 28)))
        XCTAssertEqual(LicenseCopy.statusTitle(required), "License check needed")
        XCTAssertEqual(detail(required, now: noon(10, 12)),
                       "Otto last reached Polar on Aug 28. Connect to the internet and click Check Now.")
    }

    func testUnavailableCopy() {
        let keychain = LicenseStatus.unavailable(.keychain(-25_293))
        XCTAssertEqual(LicenseCopy.statusTitle(keychain), "License status unknown")
        XCTAssertEqual(detail(keychain, now: noon(10, 12)),
                       "Otto couldn't read its license from the Keychain (error -25293). It works normally until it can.")
        let newer = LicenseStatus.unavailable(.undecodable(account: "license", createdAt: nil))
        XCTAssertEqual(LicenseCopy.statusTitle(newer), "License status unknown")
        XCTAssertEqual(detail(newer, now: noon(10, 12)),
                       "A newer version of Otto saved this Mac's license or trial record. Otto works normally; "
                       + "update Otto to manage it.")
    }

    // MARK: - Lines

    func testPendingRevocationLines() {
        let pending = PendingRevocation(firstSeenAt: noon(10, 11), reason: .notFound)
        XCTAssertEqual(LicenseCopy.pendingRevocationLine(pending, backend: .polar, locale: locale),
                       "Polar reported a problem with this license on Oct 11. If you rotated your key, enter the new "
                       + "one. Otherwise Otto checks again tomorrow before it turns the license off.")
        XCTAssertEqual(LicenseCopy.pendingRevocationLine(pending, backend: .gumroad, locale: locale),
                       "Gumroad reported a problem with this license on Oct 11. Otto checks again tomorrow before it "
                       + "turns the license off.")
    }

    func testRemovalLines() {
        let lines: [(LicenseRemovalReason, String)] = [
            (.revoked, "Polar no longer accepts the license that was on this Mac. It may have been refunded or turned "
                + "off, or this Mac was removed in the Polar portal. If you rotated your key, enter the new one."),
            (.refunded, "Gumroad reports this purchase as refunded."),
            (.chargedBack, "The payment for this license was disputed."),
            (.disabled, "Gumroad turned this key off."),
            (.wrongProduct, "That key belongs to a different product."),
            (.deactivatedByUser, "You deactivated Otto on this Mac."),
            (.removedByUser, "You removed the license from this Mac."),
        ]
        for (reason, text) in lines {
            XCTAssertEqual(LicenseCopy.removalLine(LicenseRemoval(at: noon(10, 11), reason: reason)), text)
        }
    }

    // MARK: - Messages

    func testSuccessAndInfoMessages() {
        XCTAssertEqual(LicenseCopy.activated, LicenseMessage(tone: .success, text: "Activated. Thanks for buying Otto."))
        XCTAssertEqual(LicenseCopy.rekeyed,
                       LicenseMessage(tone: .success, text: "Updated to your new key. This Mac keeps its seat."))
        XCTAssertEqual(LicenseCopy.activatedUnsaved(status: -25_308),
                       LicenseMessage(tone: .info, text: "Activated, but Otto couldn't save the license to the Keychain "
                                      + "(error -25308). It applies until you quit Otto."))
        XCTAssertEqual(LicenseCopy.checkedValid,
                       LicenseMessage(tone: .success, text: "Checked just now. Your license is active."))
    }

    func testActivationFailures() {
        func text(_ error: LicenseActivationError, _ backend: LicenseBackendKind?) -> LicenseMessage {
            LicenseCopy.activationFailure(error, backend: backend, supportEmail: support)
        }
        let expected: [(LicenseActivationError, LicenseBackendKind?, String)] = [
            (.malformedKey, nil,
             "That doesn't look like an Otto license key. Paste the whole key from your receipt email."),
            (.keyNotFound, .polar,
             "Otto couldn't find that key. Check it against your receipt email or your Polar purchases page."),
            (.keyNotActive, .polar, "That key has been refunded or turned off."),
            (.wrongProduct, .gumroad, "That key belongs to a different product."),
            (.seatLimitReached(limit: 3), .polar,
             "That key is already on 3 Macs. Deactivate Otto in Settings on one of them, or remove a Mac in the Polar portal."),
            (.seatLimitReached(limit: 6), .gumroad,
             "That key is already on 6 Macs. Email help@otto-fixture.test and I'll free a seat."),
            (.seatLimitReached(limit: nil), .polar,
             "That key is already on 3 Macs. Deactivate Otto in Settings on one of them, or remove a Mac in the Polar portal."),
            (.backendDisabled(.gumroad), nil,
             "That looks like a Gumroad key, but this version of Otto doesn't accept Gumroad keys yet. "
                + "Email help@otto-fixture.test."),
            (.unavailable(.offline), .polar, "Otto couldn't reach Polar. Check your connection and try again."),
            (.unavailable(.timeout), .gumroad, "Otto couldn't reach Gumroad. Check your connection and try again."),
            (.unavailable(.recordMismatch), .polar,
             "This version of Otto can't check this license. Nothing changed on this Mac."),
        ]
        for (error, backend, message) in expected {
            XCTAssertEqual(text(error, backend), LicenseMessage(tone: .problem, text: message), "\(error)")
        }
    }

    func testCheckFailures() {
        let expected: [(LicenseUnavailableReason, LicenseBackendKind, String)] = [
            (.offline, .polar, "Otto couldn't reach Polar. Check your connection and try again."),
            (.timeout, .polar, "Otto couldn't reach Polar. Check your connection and try again."),
            (.rateLimited(retryAfter: 2), .polar, "Polar asked Otto to slow down. Try again in a minute."),
            (.rateLimited(retryAfter: nil), .gumroad, "Gumroad asked Otto to slow down. Try again in a minute."),
            (.server(status: 502), .polar, "Polar isn't answering right now. Nothing changed on this Mac. Try again later."),
            (.versionRefused, .polar, "Polar isn't answering right now. Nothing changed on this Mac. Try again later."),
            (.unexpectedResponse(status: 418), .gumroad,
             "Gumroad isn't answering right now. Nothing changed on this Mac. Try again later."),
            (.misconfigured("Polar benefit has no activation limit"), .polar,
             "This build can't check licenses: Polar benefit has no activation limit."),
            (.recordMismatch, .polar, "This version of Otto can't check this license. Nothing changed on this Mac."),
        ]
        for (reason, backend, message) in expected {
            XCTAssertEqual(LicenseCopy.checkFailure(reason, backend: backend),
                           LicenseMessage(tone: .problem, text: message), "\(reason)")
        }
    }

    func testDeactivationMessages() {
        let freed = LicenseMessage(tone: .success, text: "Deactivated. This Mac's seat is free.")
        XCTAssertEqual(LicenseCopy.deactivation(.freedSeat, backend: .polar, supportEmail: support), freed)
        XCTAssertEqual(LicenseCopy.deactivation(.alreadyGone, backend: .polar, supportEmail: support), freed)
        XCTAssertEqual(LicenseCopy.deactivation(.localOnly, backend: .gumroad, supportEmail: support),
                       LicenseMessage(tone: .info, text: "Removed from this Mac. Gumroad still counts this Mac; email "
                                      + "help@otto-fixture.test to free the seat."))
        XCTAssertEqual(LicenseCopy.deactivation(.unavailable(.offline), backend: .polar, supportEmail: support),
                       LicenseMessage(tone: .problem, text: "Otto couldn't reach Polar, so the seat is still in use. "
                                      + "Try again, or remove the license from this Mac only."))
    }

    func testRemovedLocallyMessages() {
        XCTAssertEqual(LicenseCopy.removedLocally(.polar, supportEmail: support),
                       LicenseMessage(tone: .info, text: "Removed from this Mac. The seat stays in use until you remove "
                                      + "it in the Polar portal."))
        XCTAssertEqual(LicenseCopy.removedLocally(.gumroad, supportEmail: support),
                       LicenseMessage(tone: .info, text: "Removed from this Mac. Gumroad still counts this Mac; email "
                                      + "help@otto-fixture.test to free the seat."))
    }

    // MARK: - Composer gate

    private func gate(_ status: LicenseStatus, removal: LicenseRemoval? = nil, activity: LicenseActivity = .idle,
                      configuration: LicenseConfiguration = .preview) -> ComposerGate? {
        LicenseCopy.gate(status: status, removal: removal, activity: activity, configuration: configuration)
    }

    private var buyURL: URL { URL(string: "https://otto-sandy.vercel.app/buy") ?? URL(fileURLWithPath: "/") }

    func testTrialEndedGate() {
        let gate = gate(.trialEnded(endedAt: noon(10, 25)))
        XCTAssertEqual(gate, ComposerGate(id: "trial-ended", symbol: "hourglass", message: "Your 14-day trial has ended.",
                                          choices: [
                                              .init(title: "Buy a License", action: .openURL(buyURL), isPrimary: true),
                                              .init(title: "Enter License", action: .openSettings(.license, .licenseKey),
                                                    isPrimary: false),
                                          ]))
    }

    func testLicenseRemovedGate() {
        let removal = LicenseRemoval(at: noon(10, 11), reason: .revoked)
        XCTAssertEqual(gate(.trialEnded(endedAt: noon(10, 25)), removal: removal),
                       ComposerGate(id: "license-removed", symbol: "key", message: "This Mac no longer has a license.",
                                    choices: [
                                        .init(title: "Enter License", action: .openSettings(.license, .licenseKey),
                                              isPrimary: true),
                                        .init(title: "Buy a License", action: .openURL(buyURL), isPrimary: false),
                                    ]))
    }

    func testCheckRequiredGate() {
        let required = LicenseStatus.licensedCheckRequired(summary(.polar, validatedAt: noon(8, 28)))
        XCTAssertEqual(gate(required),
                       ComposerGate(id: "check-required", symbol: "wifi.exclamationmark",
                                    message: "Otto needs to check your license before it can send.",
                                    choices: [
                                        .init(title: "Check Now", action: .gate("check-now"), isPrimary: true),
                                        .init(title: "Enter License", action: .openSettings(.license, .licenseKey),
                                              isPrimary: false),
                                    ]))
    }

    func testActivityGates() {
        let required = LicenseStatus.licensedCheckRequired(summary(.polar, validatedAt: noon(8, 28)))
        XCTAssertEqual(gate(required, activity: .checking),
                       ComposerGate(id: "checking", symbol: "arrow.triangle.2.circlepath",
                                    message: "Checking your license…", choices: []))
        XCTAssertEqual(gate(.trialEnded(endedAt: noon(10, 25)), activity: .activating),
                       ComposerGate(id: "activating", symbol: "key", message: "Activating your license…", choices: []))
        XCTAssertEqual(gate(.trialEnded(endedAt: noon(10, 25)), removal: LicenseRemoval(at: noon(10, 11), reason: .refunded),
                            activity: .activating)?.id, "activating")
        // Other activities leave the idle gate.
        XCTAssertEqual(gate(required, activity: .activating)?.id, "check-required")
        XCTAssertEqual(gate(.trialEnded(endedAt: noon(10, 25)), activity: .checking)?.id, "trial-ended")
    }

    func testNoGateForEveryOtherStatus() {
        let polar = summary(.polar, validatedAt: noon(10, 11))
        let statuses: [LicenseStatus] = [
            .trial(endsAt: noon(10, 25), daysLeft: 3), .licensed(polar),
            .licensedCheckOverdue(polar, sendingPausesAt: noon(11, 24)), .unavailable(.keychain(-25_293)),
            .unavailable(.undecodable(account: "license", createdAt: nil)),
        ]
        for status in statuses {
            for activity in [LicenseActivity.idle, .activating, .checking, .deactivating] {
                XCTAssertNil(gate(status, activity: activity), "\(status) \(activity)")
            }
        }
    }

    func testBuyIsLeftOutWithoutABuyURL() {
        let misconfigured = LicenseConfiguration(siteHost: "", supportEmail: "", polar: nil, gumroad: nil,
                                                 gumroadExplicitlyOff: false,
                                                 problems: ["OTTO_SITE_HOST is still a placeholder"])
        XCTAssertNil(misconfigured.buyURL)
        let ended = gate(.trialEnded(endedAt: noon(10, 25)), configuration: misconfigured)
        XCTAssertEqual(ended?.choices, [.init(title: "Enter License", action: .openSettings(.license, .licenseKey),
                                              isPrimary: false)])
        let removed = gate(.trialEnded(endedAt: noon(10, 25)), removal: LicenseRemoval(at: noon(10, 11), reason: .revoked),
                           configuration: misconfigured)
        XCTAssertEqual(removed?.choices.map(\.title), ["Enter License"])
    }

    func testGateMessagesFitOneLine() {
        let removal = LicenseRemoval(at: noon(10, 11), reason: .revoked)
        let required = LicenseStatus.licensedCheckRequired(summary(.polar, validatedAt: noon(8, 28)))
        let gates = [
            gate(.trialEnded(endedAt: noon(10, 25))), gate(.trialEnded(endedAt: noon(10, 25)), removal: removal),
            gate(required), gate(required, activity: .checking),
            gate(.trialEnded(endedAt: noon(10, 25)), activity: .activating),
        ].compactMap { $0 }
        XCTAssertEqual(gates.count, 5)
        for gate in gates {
            XCTAssertLessThanOrEqual(gate.message.count, 56, gate.message)
            XCTAssertLessThanOrEqual(gate.choices.count, 2)
            XCTAssertLessThanOrEqual(gate.choices.filter(\.isPrimary).count, 1)
        }
    }
}
#endif
