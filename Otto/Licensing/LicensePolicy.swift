//
//  LicensePolicy.swift
//  Otto
//
//  The license state machine's pure rules (§14.5): status from the Keychain records, how a check's outcome changes
//  a record, when a background check is due, and when the clock's high-water mark may move. No clock, no I/O.
//

#if OTTO_LICENSING
import Foundation

enum LicenseRecordUpdate: Equatable, Sendable { case keep(LicenseRecord), revoke(LicenseGoneReason) }

/// One reading of both clocks. `uptime` is continuous uptime in seconds (CLOCK_MONOTONIC, which keeps counting while
/// the Mac sleeps), so wall-clock changes show up as a disagreement between the two.
struct LicenseClockSample: Equatable, Sendable {
    let wall: Date
    let uptime: TimeInterval
}

enum LicensePolicy {
    static let trialLength: TimeInterval = 14 * 86_400
    static let checkInterval: TimeInterval = 24 * 3_600            // at most one background attempt per 24 h
    static let quietNoticeAfter: TimeInterval = 30 * 86_400        // Settings line
    static let sendingNeedsCheckAfter: TimeInterval = 44 * 86_400  // 30 + 14 → the composer gate
    static let revocationConfirmationDelay: TimeInterval = 20 * 3_600
    static let manualCheckCooldown: TimeInterval = 60
    static let lastSeenWriteInterval: TimeInterval = 3_600
    static let minimumClockSample: TimeInterval = 300         // uptime a lastSeenAt write needs behind it
    static let clockAgreementTolerance: TimeInterval = 120    // allowed wall-vs-uptime drift over one sample
    static let seatsPerLicense = 3
    static let requestTimeout: TimeInterval = 15
    static let launchCheckDelay: Duration = .seconds(10)
    static let wakeCheckDelay: Duration = .seconds(30)
    static let tickInterval: Duration = .seconds(3_600)

    private static let day: TimeInterval = 86_400

    /// max(now, trial?.lastSeenAt ?? now) — every decision below uses it.
    static func effectiveNow(_ now: Date, trial: TrialRecord?) -> Date {
        guard let lastSeenAt = trial?.lastSeenAt else { return now }
        return max(now, lastSeenAt)
    }

    /// A trial read that failed with .undecodable(createdAt: d), d != nil, counts as a trial record with
    /// startedAt = lastSeenAt = d (§14.5 status table).
    static func status(license: Result<LicenseRecord?, LicenseStoreError>,
                       trial: Result<TrialRecord?, LicenseStoreError>, now: Date) -> LicenseStatus {
        let trialRecord: TrialRecord?
        var trialError: LicenseStoreError?
        switch trial {
        case .success(let record):
            trialRecord = record
        case .failure(.undecodable(_, let createdAt?)):
            trialRecord = TrialRecord(schema: TrialRecord.currentSchema, startedAt: createdAt, lastSeenAt: createdAt,
                                      lastLicenseRemoval: nil)
        case .failure(let error):
            trialRecord = nil
            trialError = error
        }
        let effective = effectiveNow(now, trial: trialRecord)

        switch license {
        case .failure(let error):
            return .unavailable(error)
        case .success(let record?):
            let summary = LicenseSummary(record: record)
            let age = effective.timeIntervalSince(record.lastValidatedAt)
            if age <= quietNoticeAfter { return .licensed(summary) }
            if age <= sendingNeedsCheckAfter {
                return .licensedCheckOverdue(summary,
                                             sendingPausesAt: record.lastValidatedAt.addingTimeInterval(sendingNeedsCheckAfter))
            }
            return .licensedCheckRequired(summary)
        case .success(nil):
            if let trialError { return .unavailable(trialError) }
            guard let trialRecord else {
                return .trial(endsAt: now.addingTimeInterval(trialLength), daysLeft: Int(trialLength / day))
            }
            // A start date in the future (recorded under a clock that ran ahead) counts from now instead.
            let endsAt = min(trialRecord.startedAt, effective).addingTimeInterval(trialLength)
            guard effective < endsAt else { return .trialEnded(endedAt: endsAt) }
            let daysLeft = Int((endsAt.timeIntervalSince(effective) / day).rounded(.up))
            return .trial(endsAt: endsAt, daysLeft: min(max(daysLeft, 1), Int(trialLength / day)))
        }
    }

    /// lastAttemptAt == nil || effectiveNow − lastAttemptAt ≥ checkInterval. An attempt dated after effectiveNow
    /// (recorded under a clock that ran ahead) is due too, so a corrected clock never postpones checks.
    static func isCheckDue(_ record: LicenseRecord, trial: TrialRecord?, now: Date) -> Bool {
        guard let lastAttemptAt = record.lastAttemptAt else { return true }
        let elapsed = effectiveNow(now, trial: trial).timeIntervalSince(lastAttemptAt)
        return elapsed < 0 || elapsed >= checkInterval
    }

    static func apply(_ outcome: LicenseCheckOutcome, to record: LicenseRecord,
                      trial: TrialRecord?, now: Date) -> LicenseRecordUpdate {
        let effective = effectiveNow(now, trial: trial)
        var updated = record
        updated.lastAttemptAt = effective
        switch outcome {
        case .valid(let validation):
            updated.lastValidatedAt = effective
            updated.pendingRevocation = nil
            if let seatLimit = validation.seatLimit { updated.seatLimit = seatLimit }
            if let displayKey = validation.displayKey { updated.displayKey = displayKey }
            return .keep(updated)
        case .gone(let reason):
            guard let pending = record.pendingRevocation, pending.firstSeenAt <= effective else {
                // The first "gone", or one pending since a time later than now (a clock that ran ahead): the 20 h
                // confirmation window starts now.
                updated.pendingRevocation = PendingRevocation(firstSeenAt: effective, reason: reason)
                return .keep(updated)
            }
            if effective.timeIntervalSince(pending.firstSeenAt) >= revocationConfirmationDelay {
                return .revoke(reason)
            }
            return .keep(updated)
        case .unavailable:
            return .keep(updated)
        }
    }

    /// The only way lastSeenAt moves (§14.5). `since` is the controller's baseline from start() or the previous call;
    /// the hourly tick and stop() call it. nil (skip this write, re-baseline) when now.uptime − since.uptime <
    /// minimumClockSample, or when |(now.wall − since.wall) − (now.uptime − since.uptime)| > clockAgreementTolerance
    /// (the clock was set or corrected in between); otherwise max(current, now.wall).
    static func nextLastSeen(current: Date, since: LicenseClockSample, now: LicenseClockSample) -> Date? {
        let uptimeElapsed = now.uptime - since.uptime
        guard uptimeElapsed >= minimumClockSample else { return nil }
        let wallElapsed = now.wall.timeIntervalSince(since.wall)
        guard abs(wallElapsed - uptimeElapsed) <= clockAgreementTolerance else { return nil }
        return max(current, now.wall)
    }
}
#endif
