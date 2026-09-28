//
//  LicensePolicyTests.swift
//  OttoTests
//
//  Every row of the §14.5 status and check-outcome tables at and around each boundary (14 d, 30 d, 44 d, 20 h),
//  the clock's effective now, isCheckDue, and when the clock high-water mark may move.
//

#if OTTO_LICENSING
import XCTest
@testable import Otto

final class LicensePolicyTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600
    private let origin = Date(timeIntervalSince1970: 1_791_000_000) // 2026-10-03, a whole second

    private func record(validatedAt: Date, attemptAt: Date? = nil, pending: PendingRevocation? = nil,
                        backend: LicenseBackendKind = .polar) -> LicenseRecord {
        LicenseRecord(schema: LicenseRecord.currentSchema, backend: backend, apiHost: "api.polar.sh",
                      organizationID: LicenseFixtures.organizationID, benefitID: LicenseFixtures.benefitID,
                      gumroadProductID: nil, key: LicenseFixtures.polarKey, licenseKeyID: LicenseFixtures.licenseKeyID,
                      activationID: LicenseFixtures.activationID, label: "Mac 7F3A",
                      displayKey: LicenseFixtures.polarDisplayKey, seatLimit: 3, activatedAt: validatedAt,
                      lastValidatedAt: validatedAt, lastAttemptAt: attemptAt, pendingRevocation: pending)
    }

    private func trial(startedAt: Date, lastSeenAt: Date? = nil, removal: LicenseRemoval? = nil) -> TrialRecord {
        TrialRecord(schema: TrialRecord.currentSchema, startedAt: startedAt, lastSeenAt: lastSeenAt ?? startedAt,
                    lastLicenseRemoval: removal)
    }

    private func status(license: LicenseRecord?, trial: TrialRecord?, now: Date) -> LicenseStatus {
        LicensePolicy.status(license: .success(license), trial: .success(trial), now: now)
    }

    // MARK: - Constants

    func testConstants() {
        XCTAssertEqual(LicensePolicy.trialLength, 14 * day)
        XCTAssertEqual(LicensePolicy.checkInterval, 24 * hour)
        XCTAssertEqual(LicensePolicy.quietNoticeAfter, 30 * day)
        XCTAssertEqual(LicensePolicy.sendingNeedsCheckAfter, 44 * day)
        XCTAssertEqual(LicensePolicy.revocationConfirmationDelay, 20 * hour)
        XCTAssertEqual(LicensePolicy.manualCheckCooldown, 60)
        XCTAssertEqual(LicensePolicy.minimumClockSample, 300)
        XCTAssertEqual(LicensePolicy.clockAgreementTolerance, 120)
        XCTAssertEqual(LicensePolicy.seatsPerLicense, 3)
        XCTAssertEqual(LicensePolicy.launchCheckDelay, .seconds(10))
        XCTAssertEqual(LicensePolicy.wakeCheckDelay, .seconds(30))
        XCTAssertEqual(LicensePolicy.tickInterval, .seconds(3_600))
    }

    // MARK: - effectiveNow

    func testEffectiveNowNeverGoesBehindTheHighWaterMark() {
        XCTAssertEqual(LicensePolicy.effectiveNow(origin, trial: nil), origin)
        let seen = origin.addingTimeInterval(5 * day)
        let trial = trial(startedAt: origin, lastSeenAt: seen)
        // The clock set back: the high-water mark wins.
        XCTAssertEqual(LicensePolicy.effectiveNow(origin.addingTimeInterval(day), trial: trial), seen)
        XCTAssertEqual(LicensePolicy.effectiveNow(origin.addingTimeInterval(6 * day), trial: trial),
                       origin.addingTimeInterval(6 * day))
    }

    // MARK: - Status: license rows

    func testALicenseReadFailureFailsOpen() {
        let error = LicenseStoreError.keychain(-25_293)
        let result = LicensePolicy.status(license: .failure(error), trial: .success(nil), now: origin)
        XCTAssertEqual(result, .unavailable(error))
        XCTAssertTrue(result.allowsSending)
        XCTAssertNil(result.summary)
    }

    func testLicensedUpToThirtyDays() {
        let license = record(validatedAt: origin)
        let summary = LicenseSummary(record: license)
        XCTAssertEqual(status(license: license, trial: nil, now: origin), .licensed(summary))
        XCTAssertEqual(status(license: license, trial: nil, now: origin.addingTimeInterval(30 * day)), .licensed(summary))
        XCTAssertTrue(status(license: license, trial: nil, now: origin.addingTimeInterval(30 * day)).allowsSending)
    }

    func testOverdueAfterThirtyDaysUpToFortyFour() {
        let license = record(validatedAt: origin)
        let summary = LicenseSummary(record: license)
        let pausesAt = origin.addingTimeInterval(44 * day)
        let justOver = status(license: license, trial: nil, now: origin.addingTimeInterval(30 * day + 1))
        XCTAssertEqual(justOver, .licensedCheckOverdue(summary, sendingPausesAt: pausesAt))
        XCTAssertTrue(justOver.allowsSending)
        XCTAssertEqual(status(license: license, trial: nil, now: pausesAt), .licensedCheckOverdue(summary, sendingPausesAt: pausesAt))
        XCTAssertEqual(justOver.summary, summary)
    }

    func testCheckRequiredAfterFortyFourDays() {
        let license = record(validatedAt: origin)
        let result = status(license: license, trial: nil, now: origin.addingTimeInterval(44 * day + 1))
        XCTAssertEqual(result, .licensedCheckRequired(LicenseSummary(record: license)))
        XCTAssertFalse(result.allowsSending)
        XCTAssertEqual(result.summary, LicenseSummary(record: license))
    }

    func testLicenseAgeUsesTheHighWaterMark() {
        let license = record(validatedAt: origin)
        let trial = trial(startedAt: origin, lastSeenAt: origin.addingTimeInterval(45 * day))
        // The wall clock says day 1, but the Mac has already seen day 45.
        XCTAssertEqual(status(license: license, trial: trial, now: origin.addingTimeInterval(day)),
                       .licensedCheckRequired(LicenseSummary(record: license)))
    }

    func testALicenseWinsOverAnEndedTrialAndAnUnreadableTrial() {
        let license = record(validatedAt: origin.addingTimeInterval(20 * day))
        let ended = trial(startedAt: origin)
        XCTAssertEqual(status(license: license, trial: ended, now: origin.addingTimeInterval(21 * day)),
                       .licensed(LicenseSummary(record: license)))
        XCTAssertEqual(LicensePolicy.status(license: .success(license), trial: .failure(.keychain(-1)),
                                            now: origin.addingTimeInterval(21 * day)),
                       .licensed(LicenseSummary(record: license)))
    }

    // MARK: - Status: trial rows

    func testNoTrialRecordIsAFreshTrial() {
        XCTAssertEqual(status(license: nil, trial: nil, now: origin),
                       .trial(endsAt: origin.addingTimeInterval(14 * day), daysLeft: 14))
    }

    func testTrialDaysLeftRoundUp() {
        let trial = trial(startedAt: origin)
        let endsAt = origin.addingTimeInterval(14 * day)
        XCTAssertEqual(status(license: nil, trial: trial, now: origin), .trial(endsAt: endsAt, daysLeft: 14))
        XCTAssertEqual(status(license: nil, trial: trial, now: origin.addingTimeInterval(1)), .trial(endsAt: endsAt, daysLeft: 14))
        XCTAssertEqual(status(license: nil, trial: trial, now: origin.addingTimeInterval(day)), .trial(endsAt: endsAt, daysLeft: 13))
        XCTAssertEqual(status(license: nil, trial: trial, now: origin.addingTimeInterval(13 * day)),
                       .trial(endsAt: endsAt, daysLeft: 1))
        XCTAssertEqual(status(license: nil, trial: trial, now: endsAt.addingTimeInterval(-1)), .trial(endsAt: endsAt, daysLeft: 1))
        XCTAssertTrue(status(license: nil, trial: trial, now: endsAt.addingTimeInterval(-1)).allowsSending)
    }

    func testTrialEndsAtFourteenDays() {
        let trial = trial(startedAt: origin)
        let endsAt = origin.addingTimeInterval(14 * day)
        let ended = status(license: nil, trial: trial, now: endsAt)
        XCTAssertEqual(ended, .trialEnded(endedAt: endsAt))
        XCTAssertFalse(ended.allowsSending)
        XCTAssertNil(ended.summary)
        XCTAssertEqual(status(license: nil, trial: trial, now: endsAt.addingTimeInterval(400 * day)), .trialEnded(endedAt: endsAt))
    }

    func testSettingTheClockBackNeverExtendsTheTrial() {
        let endsAt = origin.addingTimeInterval(14 * day)
        let trial = trial(startedAt: origin, lastSeenAt: endsAt.addingTimeInterval(hour))
        XCTAssertEqual(status(license: nil, trial: trial, now: origin.addingTimeInterval(2 * day)), .trialEnded(endedAt: endsAt))
    }

    func testAFutureTrialStartIsClampedToNow() {
        let trial = trial(startedAt: origin.addingTimeInterval(30 * day), lastSeenAt: origin)
        let now = origin.addingTimeInterval(day)
        XCTAssertEqual(status(license: nil, trial: trial, now: now), .trial(endsAt: now.addingTimeInterval(14 * day), daysLeft: 14))
    }

    func testALicenseRemovedInsideTheTrialWindowReturnsToTheTrial() {
        let removal = LicenseRemoval(at: origin.addingTimeInterval(3 * day), reason: .refunded)
        let trial = trial(startedAt: origin, lastSeenAt: origin.addingTimeInterval(3 * day), removal: removal)
        XCTAssertEqual(status(license: nil, trial: trial, now: origin.addingTimeInterval(3 * day)),
                       .trial(endsAt: origin.addingTimeInterval(14 * day), daysLeft: 11))
    }

    func testAnUndecodableTrialWithACreationDateCountsFromThatDate() {
        let created = origin
        let failure = LicenseStoreError.undecodable(account: "trial", createdAt: created)
        let endsAt = created.addingTimeInterval(14 * day)
        XCTAssertEqual(LicensePolicy.status(license: .success(nil), trial: .failure(failure), now: created.addingTimeInterval(day)),
                       .trial(endsAt: endsAt, daysLeft: 13))
        XCTAssertEqual(LicensePolicy.status(license: .success(nil), trial: .failure(failure), now: endsAt.addingTimeInterval(-1)),
                       .trial(endsAt: endsAt, daysLeft: 1))
        XCTAssertEqual(LicensePolicy.status(license: .success(nil), trial: .failure(failure), now: endsAt),
                       .trialEnded(endedAt: endsAt))
        // Its creation date also acts as a high-water mark: setting the clock back before it changes nothing.
        XCTAssertEqual(LicensePolicy.status(license: .success(nil), trial: .failure(failure),
                                            now: created.addingTimeInterval(-10 * day)),
                       .trial(endsAt: endsAt, daysLeft: 14))
    }

    func testAnUndecodableTrialWithoutACreationDateIsUnavailable() {
        let failure = LicenseStoreError.undecodable(account: "trial", createdAt: nil)
        let result = LicensePolicy.status(license: .success(nil), trial: .failure(failure), now: origin)
        XCTAssertEqual(result, .unavailable(failure))
        XCTAssertTrue(result.allowsSending)
    }

    func testAKeychainTrialFailureIsUnavailable() {
        let failure = LicenseStoreError.keychain(-25_308)
        XCTAssertEqual(LicensePolicy.status(license: .success(nil), trial: .failure(failure), now: origin),
                       .unavailable(failure))
    }

    // MARK: - isCheckDue

    func testIsCheckDue() {
        XCTAssertTrue(LicensePolicy.isCheckDue(record(validatedAt: origin), trial: nil, now: origin))
        let attempted = record(validatedAt: origin, attemptAt: origin)
        XCTAssertFalse(LicensePolicy.isCheckDue(attempted, trial: nil, now: origin.addingTimeInterval(24 * hour - 1)))
        XCTAssertTrue(LicensePolicy.isCheckDue(attempted, trial: nil, now: origin.addingTimeInterval(24 * hour)))
        // effectiveNow counts: a Mac that has already seen tomorrow is due.
        let trial = trial(startedAt: origin, lastSeenAt: origin.addingTimeInterval(25 * hour))
        XCTAssertTrue(LicensePolicy.isCheckDue(attempted, trial: trial, now: origin.addingTimeInterval(hour)))
        // An attempt recorded under a clock that ran ahead doesn't postpone checks once the clock is right.
        let ranAhead = record(validatedAt: origin, attemptAt: origin.addingTimeInterval(300 * day))
        XCTAssertTrue(LicensePolicy.isCheckDue(ranAhead, trial: nil, now: origin))
    }

    // MARK: - apply

    func testValidRefreshesTheRecordAndClearsPending() {
        let pending = PendingRevocation(firstSeenAt: origin, reason: .notFound)
        let license = record(validatedAt: origin, pending: pending)
        let now = origin.addingTimeInterval(2 * day)
        guard case .keep(let updated) = LicensePolicy.apply(.valid(LicenseValidation(seatLimit: 5, displayKey: "****-ABCDEF")),
                                                            to: license, trial: nil, now: now) else {
            return XCTFail("valid keeps the license")
        }
        XCTAssertEqual(updated.lastValidatedAt, now)
        XCTAssertEqual(updated.lastAttemptAt, now)
        XCTAssertNil(updated.pendingRevocation)
        XCTAssertEqual(updated.seatLimit, 5)
        XCTAssertEqual(updated.displayKey, "****-ABCDEF")
    }

    func testValidWithoutReportedFieldsKeepsThem() {
        let license = record(validatedAt: origin)
        guard case .keep(let updated) = LicensePolicy.apply(.valid(LicenseValidation()), to: license, trial: nil,
                                                            now: origin.addingTimeInterval(day)) else {
            return XCTFail("valid keeps the license")
        }
        XCTAssertEqual(updated.seatLimit, 3)
        XCTAssertEqual(updated.displayKey, LicenseFixtures.polarDisplayKey)
    }

    func testValidUsesEffectiveNow() {
        let license = record(validatedAt: origin)
        let seen = origin.addingTimeInterval(10 * day)
        let trial = trial(startedAt: origin, lastSeenAt: seen)
        guard case .keep(let updated) = LicensePolicy.apply(.valid(LicenseValidation()), to: license, trial: trial,
                                                            now: origin.addingTimeInterval(day)) else {
            return XCTFail("valid keeps the license")
        }
        XCTAssertEqual(updated.lastValidatedAt, seen)
        XCTAssertEqual(updated.lastAttemptAt, seen)
    }

    func testTheFirstGoneOnlyRecordsAPendingRevocation() {
        let license = record(validatedAt: origin)
        let now = origin.addingTimeInterval(day)
        guard case .keep(let updated) = LicensePolicy.apply(.gone(.notFound), to: license, trial: nil, now: now) else {
            return XCTFail("the first gone keeps the license")
        }
        XCTAssertEqual(updated.pendingRevocation, PendingRevocation(firstSeenAt: now, reason: .notFound))
        XCTAssertEqual(updated.lastAttemptAt, now)
        XCTAssertEqual(updated.lastValidatedAt, origin)
    }

    func testGoneInsideTwentyHoursOnlyMovesTheAttempt() {
        let first = origin.addingTimeInterval(day)
        let pending = PendingRevocation(firstSeenAt: first, reason: .notFound)
        let license = record(validatedAt: origin, attemptAt: first, pending: pending)
        for elapsed in [0, 1, 20 * hour - 1] {
            let now = first.addingTimeInterval(elapsed)
            guard case .keep(let updated) = LicensePolicy.apply(.gone(.refunded), to: license, trial: nil, now: now) else {
                return XCTFail("gone after \(elapsed) s keeps the license")
            }
            XCTAssertEqual(updated.pendingRevocation, pending, "\(elapsed)")
            XCTAssertEqual(updated.lastAttemptAt, now)
            XCTAssertEqual(updated.lastValidatedAt, origin)
        }
    }

    func testGoneTwentyHoursLaterRevokes() {
        let first = origin.addingTimeInterval(day)
        let license = record(validatedAt: origin, pending: PendingRevocation(firstSeenAt: first, reason: .notFound))
        XCTAssertEqual(LicensePolicy.apply(.gone(.notFound), to: license, trial: nil, now: first.addingTimeInterval(20 * hour)),
                       .revoke(.notFound))
        XCTAssertEqual(LicensePolicy.apply(.gone(.chargedBack), to: license, trial: nil, now: first.addingTimeInterval(3 * day)),
                       .revoke(.chargedBack))
    }

    func testGoneThenGoneThenRevoke() {
        var license = record(validatedAt: origin)
        let first = origin.addingTimeInterval(day)
        guard case .keep(let pending) = LicensePolicy.apply(.gone(.notFound), to: license, trial: nil, now: first) else {
            return XCTFail("first gone")
        }
        license = pending
        guard case .keep(let still) = LicensePolicy.apply(.gone(.notFound), to: license, trial: nil,
                                                          now: first.addingTimeInterval(hour)) else {
            return XCTFail("second gone inside 20 h")
        }
        XCTAssertEqual(LicensePolicy.apply(.gone(.notFound), to: still, trial: nil, now: first.addingTimeInterval(21 * hour)),
                       .revoke(.notFound))
        XCTAssertEqual(LicenseRemovalReason(.notFound), .revoked)
    }

    func testAPendingRevocationFromTheFutureIsReAnchored() {
        let future = origin.addingTimeInterval(30 * day)
        let license = record(validatedAt: origin, pending: PendingRevocation(firstSeenAt: future, reason: .notFound))
        let now = origin.addingTimeInterval(day)
        guard case .keep(let updated) = LicensePolicy.apply(.gone(.notFound), to: license, trial: nil, now: now) else {
            return XCTFail("a future pending revocation never confirms")
        }
        XCTAssertEqual(updated.pendingRevocation, PendingRevocation(firstSeenAt: now, reason: .notFound))
        XCTAssertEqual(updated.lastAttemptAt, now)
        // And the 20 h start from the re-anchored time.
        guard case .keep = LicensePolicy.apply(.gone(.notFound), to: updated, trial: nil,
                                               now: now.addingTimeInterval(19 * hour)) else {
            return XCTFail("inside 20 h of the re-anchored time")
        }
        XCTAssertEqual(LicensePolicy.apply(.gone(.notFound), to: updated, trial: nil, now: now.addingTimeInterval(20 * hour)),
                       .revoke(.notFound))
    }

    func testUnavailableAndRecordMismatchNeverMoveValidationOrPending() {
        let pending = PendingRevocation(firstSeenAt: origin.addingTimeInterval(day), reason: .notFound)
        let reasons: [LicenseUnavailableReason] = [
            .offline, .timeout, .rateLimited(retryAfter: 30), .rateLimited(retryAfter: nil), .server(status: 503),
            .versionRefused, .unexpectedResponse(status: 418), .misconfigured("Polar benefit has no activation limit"),
            .recordMismatch,
        ]
        for existing in [nil, pending] {
            let license = record(validatedAt: origin, pending: existing)
            for reason in reasons {
                let now = origin.addingTimeInterval(3 * day)
                guard case .keep(let updated) = LicensePolicy.apply(.unavailable(reason), to: license, trial: nil,
                                                                    now: now) else {
                    return XCTFail("\(reason) keeps the license")
                }
                XCTAssertEqual(updated.lastValidatedAt, origin, "\(reason)")
                XCTAssertEqual(updated.pendingRevocation, existing, "\(reason)")
                XCTAssertEqual(updated.lastAttemptAt, now, "\(reason)")
            }
        }
    }

    // MARK: - nextLastSeen

    private func sample(_ wallOffset: TimeInterval, uptime: TimeInterval) -> LicenseClockSample {
        LicenseClockSample(wall: origin.addingTimeInterval(wallOffset), uptime: uptime)
    }

    func testASteadyClockOverFiveMinutesWrites() {
        let since = sample(0, uptime: 1_000)
        XCTAssertEqual(LicensePolicy.nextLastSeen(current: origin, since: since, now: sample(300, uptime: 1_300)),
                       origin.addingTimeInterval(300))
        XCTAssertEqual(LicensePolicy.nextLastSeen(current: origin, since: since, now: sample(3_600, uptime: 4_600)),
                       origin.addingTimeInterval(3_600))
        // Drift within two minutes still agrees.
        XCTAssertEqual(LicensePolicy.nextLastSeen(current: origin, since: since, now: sample(3_720, uptime: 4_600)),
                       origin.addingTimeInterval(3_720))
    }

    func testTheHighWaterMarkNeverMovesBack() {
        let current = origin.addingTimeInterval(10 * day)
        XCTAssertEqual(LicensePolicy.nextLastSeen(current: current, since: sample(0, uptime: 0), now: sample(600, uptime: 600)),
                       current)
    }

    func testUnderFiveMinutesOfUptimeSkips() {
        XCTAssertNil(LicensePolicy.nextLastSeen(current: origin, since: sample(0, uptime: 1_000),
                                                now: sample(299, uptime: 1_299)))
        XCTAssertNil(LicensePolicy.nextLastSeen(current: origin, since: sample(0, uptime: 1_000),
                                                now: sample(0, uptime: 900)))
    }

    func testAWallUptimeDisagreementOverTwoMinutesSkips() {
        let since = sample(0, uptime: 1_000)
        XCTAssertNil(LicensePolicy.nextLastSeen(current: origin, since: since, now: sample(3_721, uptime: 4_600)))
        XCTAssertNil(LicensePolicy.nextLastSeen(current: origin, since: since, now: sample(3_479, uptime: 4_600)))
        XCTAssertNil(LicensePolicy.nextLastSeen(current: origin, since: since, now: sample(-day, uptime: 4_600)))
    }

    /// A +2-year wall jump between two samples 1 h of uptime apart writes nothing, so after the clock returns
    /// daysLeft equals its value before the jump.
    func testATwoYearJumpIsNeverPersisted() {
        let trialStart = origin
        var trial = trial(startedAt: trialStart, lastSeenAt: trialStart.addingTimeInterval(3 * day))
        let beforeWall = trialStart.addingTimeInterval(3 * day)
        let before = LicensePolicy.status(license: .success(nil), trial: .success(trial), now: beforeWall)
        guard case .trial(_, let daysLeftBefore) = before else { return XCTFail("still in the trial") }

        let baseline = LicenseClockSample(wall: beforeWall, uptime: 10_000)
        let jumped = LicenseClockSample(wall: beforeWall.addingTimeInterval(2 * 365 * day + hour), uptime: 13_600)
        XCTAssertNil(LicensePolicy.nextLastSeen(current: trial.lastSeenAt, since: baseline, now: jumped))
        // While the clock is wrong the status reflects it…
        XCTAssertEqual(LicensePolicy.status(license: .success(nil), trial: .success(trial), now: jumped.wall),
                       .trialEnded(endedAt: trialStart.addingTimeInterval(14 * day)))

        // …and the next sample, re-baselined on the jumped clock, sees the correction as another disagreement.
        let corrected = LicenseClockSample(wall: beforeWall.addingTimeInterval(2 * hour), uptime: 17_200)
        XCTAssertNil(LicensePolicy.nextLastSeen(current: trial.lastSeenAt, since: jumped, now: corrected))

        // Once the clock is right, a steady sample writes the true time and the trial reads as before.
        let steady = LicenseClockSample(wall: corrected.wall.addingTimeInterval(hour), uptime: 20_800)
        if let next = LicensePolicy.nextLastSeen(current: trial.lastSeenAt, since: corrected, now: steady) {
            trial.lastSeenAt = next
        }
        XCTAssertEqual(trial.lastSeenAt, steady.wall)
        let after = LicensePolicy.status(license: .success(nil), trial: .success(trial), now: beforeWall)
        guard case .trial(_, let daysLeftAfter) = after else { return XCTFail("the trial is back") }
        XCTAssertEqual(daysLeftAfter, daysLeftBefore)
    }
}
#endif
