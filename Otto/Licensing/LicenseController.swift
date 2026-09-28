//
//  LicenseController.swift
//  Otto
//
//  The paid build's license engine (§14.4.4, §14.5): it reads the license and trial records, creates the trial record
//  once, computes the status through LicensePolicy, runs background checks (10 s after launch, 30 s after a wake and
//  on an hourly tick, each only when one is due), and carries out the user's Activate, Check Now, Deactivate and
//  Remove from This Mac. It never blocks launch, never deletes anything but the license item, never shows a dialog,
//  and never downgrades on an answer that could be an outage. The clock's high-water mark (trial.lastSeenAt) moves
//  only through LicensePolicy.nextLastSeen, from tick() and stop().
//

#if OTTO_LICENSING
import AppKit
import Foundation
import Observation
import os

@MainActor @Observable final class LicenseController: LicenseControlling {
    private(set) var status: LicenseStatus
    private(set) var activity: LicenseActivity
    private(set) var lastMessage: LicenseMessage?
    private(set) var lastRemoval: LicenseRemoval?
    let configuration: LicenseConfiguration

    /// nil = sending allowed (§14.10.1).
    var composerGate: ComposerGate? {
        LicenseCopy.gate(status: status, removal: lastRemoval, activity: activity, configuration: configuration)
    }

    #if DEBUG
    /// `--license-clock-offset` (§14.10.4): seconds added to every reading of the controller's clock (grace windows,
    /// revocation confirmation). While it is not zero the controller never advances trial.lastSeenAt, so shifting
    /// the clock can't move the Keychain's high-water mark. Set it before start().
    @ObservationIgnored var clockOffset: TimeInterval = 0
    #endif

    /// A license this session holds only in memory: a save or a delete the store refused. It wins over the store until
    /// a later save or delete succeeds, so the license applies (or stays removed) until Otto quits.
    private enum SessionLicense {
        case record(LicenseRecord)
        case removed
    }

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "License")

    @ObservationIgnored private let store: LicenseStoring
    @ObservationIgnored private let backends: [any LicenseBackend]
    @ObservationIgnored private let scheduler: LicenseScheduling
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let uptime: () -> TimeInterval
    @ObservationIgnored private let randomLabel: () -> String
    @ObservationIgnored private let notificationCenter: NotificationCenter

    @ObservationIgnored private var licenseResult: Result<LicenseRecord?, LicenseStoreError>
    @ObservationIgnored private var trialResult: Result<TrialRecord?, LicenseStoreError>
    @ObservationIgnored private var sessionLicense: SessionLicense?
    /// A trial record whose save the store refused (a Keychain that refuses writes): used for this session only.
    @ObservationIgnored private var unsavedTrial: TrialRecord?
    /// Why the license left this Mac when there is no readable trial record to keep it in.
    @ObservationIgnored private var removalWithoutTrial: LicenseRemoval?
    /// The message the last completed check produced; Check Now inside the cooldown answers with it.
    @ObservationIgnored private var lastCheckMessage: LicenseMessage?
    @ObservationIgnored private var clockBaseline: LicenseClockSample?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var launchWork: LicenseScheduledWork?
    @ObservationIgnored private var wakeWork: LicenseScheduledWork?
    @ObservationIgnored private var tickWork: LicenseScheduledWork?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    init(configuration: LicenseConfiguration, store: LicenseStoring, backends: [any LicenseBackend],
         scheduler: LicenseScheduling, now: @escaping () -> Date = Date.init,
         uptime: @escaping () -> TimeInterval = LicenseController.continuousUptime,
         randomLabel: @escaping () -> String = LicenseKeyRouter.randomLabel,
         notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.configuration = configuration
        self.store = store
        self.backends = backends
        self.scheduler = scheduler
        self.now = now
        self.uptime = uptime
        self.randomLabel = randomLabel
        self.notificationCenter = notificationCenter
        // Reads only: the status is right from the first frame; start() creates the trial record and schedules.
        let license = store.loadLicense()
        let trial = store.loadTrial()
        licenseResult = license
        trialResult = trial
        status = LicensePolicy.status(license: license, trial: trial, now: now())
        activity = .idle
        lastMessage = nil
        lastRemoval = nil
        refreshStatus()
    }

    /// clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9: keeps counting while the Mac sleeps (Darwin).
    nonisolated static func continuousUptime() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    // MARK: - Lifecycle

    /// Live paid graph only: loads the records (creating the trial record once), computes the status, schedules the
    /// launch check and the hourly tick, starts watching for wakes, and takes the first clock baseline.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        reload()
        createTrialIfNeeded()
        refreshStatus()
        clockBaseline = clockSample()
        launchWork = scheduler.schedule(after: LicensePolicy.launchCheckDelay) { [weak self] in
            self?.launchWork = nil
            self?.runBackgroundCheck()
        }
        scheduleTick()
        wakeObserver = notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                      queue: nil) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.handleWake() }
            } else {
                Task { @MainActor in self?.handleWake() }
            }
        }
        Self.logger.info("License engine started: \(Self.name(of: self.status), privacy: .public)")
    }

    /// One nextLastSeen write attempt, then cancels the scheduled work (applicationWillTerminate).
    func stop() {
        reload()
        recordLastSeen()
        launchWork?.cancel()
        launchWork = nil
        wakeWork?.cancel()
        wakeWork = nil
        tickWork?.cancel()
        tickWork = nil
        if let wakeObserver {
            notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        isStarted = false
    }

    /// Runs a due background check now, then a nextLastSeen write attempt (the scheduler calls it; tests call it
    /// directly).
    func tick() {
        runBackgroundCheck()
        recordLastSeen()
    }

    // MARK: - LicenseControlling

    func activate(key rawKey: String) {
        guard activity == .idle else { return }
        guard let key = LicenseKeyRouter.normalize(rawKey) else {
            lastMessage = activationFailure(.malformedKey, backend: nil)
            return
        }
        let enabled = configuration.enabledBackends.intersection(backends.map(\.kind))
        let kinds = LicenseKeyRouter.candidates(for: key, enabled: enabled)
        guard !kinds.isEmpty else {
            let kind: LicenseBackendKind = LicenseKeyRouter.looksLikeGumroad(key) ? .gumroad : .polar
            lastMessage = activationFailure(.backendDisabled(kind), backend: nil)
            return
        }

        reload()
        refreshStatus()
        if case .failure(let error) = licenseResult {
            // Nothing is written while the license item can't be read (§14.9); the status line says why.
            lastMessage = LicenseMessage(tone: .problem,
                                         text: LicenseCopy.statusDetail(.unavailable(error), removal: nil,
                                                                        configuration: configuration, now: currentDate))
            return
        }
        let previous = currentLicense
        var freshLabel: String?
        var attempts: [(backend: any LicenseBackend, label: String, existing: LicenseRecord?)] = []
        for kind in kinds {
            guard let backend = backend(for: kind) else { continue }
            if let previous, previous.backend == kind {
                attempts.append((backend, previous.label, previous))
            } else {
                let label = freshLabel ?? randomLabel()
                freshLabel = label
                attempts.append((backend, label, nil))
            }
        }

        lastMessage = nil
        activity = .activating
        Task { [weak self] in
            var answeredBy: LicenseBackendKind?
            var result: Result<LicenseRecord, LicenseActivationError> = .failure(.keyNotFound)
            for attempt in attempts {
                answeredBy = attempt.backend.kind
                result = await attempt.backend.activate(key: key, label: attempt.label, existing: attempt.existing)
                // Only "no such key" moves on; only a key of neither shape has a second candidate.
                if case .failure(.keyNotFound) = result { continue }
                break
            }
            self?.finishActivation(result, answeredBy: answeredBy, previous: previous)
        }
    }

    func checkNow() {
        guard activity == .idle else { return }
        reload()
        refreshStatus()
        guard let record = currentLicense else { return }
        if let lastAttemptAt = record.lastAttemptAt {
            let elapsed = effectiveNow.timeIntervalSince(lastAttemptAt)
            if elapsed >= 0, elapsed < LicensePolicy.manualCheckCooldown {
                // Inside the cooldown: answer from the last result without a request.
                lastMessage = lastCheckMessage ?? message(fromRecord: record)
                return
            }
        }
        lastMessage = nil
        performCheck(of: record, manual: true)
    }

    func deactivate() {
        guard activity == .idle else { return }
        reload()
        refreshStatus()
        guard let record = currentLicense else { return }
        let backend = backend(for: record.backend)
        lastMessage = nil
        activity = .deactivating
        Task { [weak self] in
            let outcome: LicenseDeactivationOutcome
            if let backend {
                outcome = await backend.deactivate(record)
            } else if record.backend == .gumroad {
                outcome = .localOnly
            } else {
                outcome = .unavailable(.misconfigured(Self.missingSettings(record.backend)))
            }
            self?.finishDeactivation(outcome, of: record)
        }
    }

    func removeFromThisMac() {
        guard activity == .idle else { return }
        reload()
        guard let record = currentLicense else {
            refreshStatus()
            return
        }
        removeLicense(reason: .removedByUser, at: effectiveNow)
        lastMessage = LicenseCopy.removedLocally(record.backend, supportEmail: configuration.supportEmail)
        Self.logger.info("License removed from this Mac by the user (\(record.backend.rawValue, privacy: .public))")
    }

    func dismissMessage() {
        lastMessage = nil
    }

    func handleGateAction(_ id: String) {
        switch id {
        case "check-now":
            checkNow()
        default:
            Self.logger.error("Unknown gate action \(id, privacy: .public)")
        }
    }

    // MARK: - Checks

    private func handleWake() {
        guard isStarted else { return }
        wakeWork?.cancel()
        wakeWork = scheduler.schedule(after: LicensePolicy.wakeCheckDelay) { [weak self] in
            self?.wakeWork = nil
            self?.runBackgroundCheck()
        }
    }

    private func scheduleTick() {
        tickWork = scheduler.schedule(after: LicensePolicy.tickInterval) { [weak self] in
            guard let self else { return }
            self.tickWork = nil
            self.tick()
            if self.isStarted { self.scheduleTick() }
        }
    }

    /// Reloads the records and refreshes the status; then, when nothing else is running and a check is due, checks.
    private func runBackgroundCheck() {
        reload()
        refreshStatus()
        guard activity == .idle, let record = currentLicense,
              LicensePolicy.isCheckDue(record, trial: policyTrial, now: currentDate) else { return }
        performCheck(of: record, manual: false)
    }

    private func performCheck(of record: LicenseRecord, manual: Bool) {
        let backend = backend(for: record.backend)
        activity = .checking
        Task { [weak self] in
            let outcome: LicenseCheckOutcome
            if let backend {
                outcome = await backend.validate(record)
            } else {
                outcome = .unavailable(.misconfigured(Self.missingSettings(record.backend)))
            }
            self?.finishCheck(outcome, of: record, manual: manual)
        }
    }

    private func finishCheck(_ outcome: LicenseCheckOutcome, of checked: LicenseRecord, manual: Bool) {
        activity = .idle
        reload()
        Self.logger.info("License check (\(checked.backend.rawValue, privacy: .public), \(manual ? "manual" : "background", privacy: .public)): \(Self.name(of: outcome), privacy: .public)")
        guard let current = currentLicense, current.backend == checked.backend, current.key == checked.key,
              current.activationID == checked.activationID else {
            // The license changed or became unreadable while the request was out: the answer is about another record.
            refreshStatus()
            return
        }

        let message: LicenseMessage
        switch LicensePolicy.apply(outcome, to: current, trial: policyTrial, now: currentDate) {
        case .keep(let updated):
            if let error = persistLicense(updated) {
                Self.logger.error("Couldn't save the checked license: \(Self.name(of: error), privacy: .public)")
            }
            message = checkMessage(for: outcome, updated: updated)
        case .revoke(let reason):
            let removal = LicenseRemoval(at: effectiveNow, reason: LicenseRemovalReason(reason))
            removeLicense(reason: removal.reason, at: removal.at)
            message = LicenseMessage(tone: .problem, text: LicenseCopy.removalLine(removal))
            Self.logger.notice("License revoked after two answers: \(reason.rawValue, privacy: .public)")
        }
        lastCheckMessage = message
        if manual { lastMessage = message }
        refreshStatus()
    }

    private func checkMessage(for outcome: LicenseCheckOutcome, updated: LicenseRecord) -> LicenseMessage {
        switch outcome {
        case .valid:
            return LicenseCopy.checkedValid
        case .unavailable(let reason):
            return LicenseCopy.checkFailure(reason, backend: updated.backend)
        case .gone(let reason):
            let pending = updated.pendingRevocation ?? PendingRevocation(firstSeenAt: effectiveNow, reason: reason)
            return LicenseMessage(tone: .problem,
                                  text: LicenseCopy.pendingRevocationLine(pending, backend: updated.backend))
        }
    }

    /// The answer Check Now gives inside the cooldown when this session hasn't seen the last check's result (it ran
    /// in an earlier launch): read back from what that check left in the record.
    private func message(fromRecord record: LicenseRecord) -> LicenseMessage {
        if let pending = record.pendingRevocation {
            return LicenseMessage(tone: .problem,
                                  text: LicenseCopy.pendingRevocationLine(pending, backend: record.backend))
        }
        if let lastAttemptAt = record.lastAttemptAt, record.lastValidatedAt >= lastAttemptAt {
            return LicenseCopy.checkedValid
        }
        return LicenseCopy.checkFailure(.server(status: 0), backend: record.backend)
    }

    // MARK: - Activation and removal

    private func finishActivation(_ result: Result<LicenseRecord, LicenseActivationError>,
                                  answeredBy: LicenseBackendKind?, previous: LicenseRecord?) {
        activity = .idle
        reload()
        switch result {
        case .failure(let error):
            lastMessage = activationFailure(error, backend: answeredBy)
            Self.logger.info("Activation failed (\(answeredBy?.rawValue ?? "none", privacy: .public)): \(String(describing: error), privacy: .public)")
            refreshStatus()
        case .success(var record):
            record.pendingRevocation = nil
            let rekeyed = previous.map {
                $0.backend == record.backend && $0.activationID != nil && $0.activationID == record.activationID
                    && $0.key != record.key
            } ?? false
            if let error = persistLicense(record) {
                lastMessage = LicenseCopy.activatedUnsaved(status: Self.osStatus(of: error))
                Self.logger.error("Activated, but couldn't save the license: \(Self.name(of: error), privacy: .public)")
            } else {
                lastMessage = rekeyed ? LicenseCopy.rekeyed : LicenseCopy.activated
            }
            clearRemoval()
            lastCheckMessage = nil
            refreshStatus()
            Self.logger.info("Activated (\(record.backend.rawValue, privacy: .public)\(rekeyed ? ", re-keyed" : "", privacy: .public))")
        }
    }

    private func finishDeactivation(_ outcome: LicenseDeactivationOutcome, of record: LicenseRecord) {
        activity = .idle
        reload()
        switch outcome {
        case .freedSeat, .alreadyGone, .localOnly:
            if let current = currentLicense, current.backend == record.backend, current.key == record.key {
                removeLicense(reason: .deactivatedByUser, at: effectiveNow)
            }
        case .unavailable:
            break  // the license stays; the message offers Remove from This Mac
        }
        lastMessage = LicenseCopy.deactivation(outcome, backend: record.backend,
                                               supportEmail: configuration.supportEmail)
        refreshStatus()
        Self.logger.info("Deactivation (\(record.backend.rawValue, privacy: .public)): \(String(describing: outcome), privacy: .public)")
    }

    /// Deletes the license item and records why in the trial record (§14.5).
    private func removeLicense(reason: LicenseRemovalReason, at date: Date) {
        do {
            try store.deleteLicense()
            sessionLicense = nil
        } catch {
            sessionLicense = .removed
            Self.logger.error("Couldn't delete the license item: \(Self.name(of: Self.storeError(error)), privacy: .public)")
        }
        licenseResult = .success(nil)
        let removal = LicenseRemoval(at: date, reason: reason)
        if var trial = decodedTrial {
            trial.lastLicenseRemoval = removal
            persistTrial(trial)
            removalWithoutTrial = nil
        } else {
            removalWithoutTrial = removal
        }
        refreshStatus()
    }

    /// The next activation clears trial.lastLicenseRemoval.
    private func clearRemoval() {
        removalWithoutTrial = nil
        guard var trial = decodedTrial, trial.lastLicenseRemoval != nil else { return }
        trial.lastLicenseRemoval = nil
        persistTrial(trial)
    }

    private func activationFailure(_ error: LicenseActivationError, backend: LicenseBackendKind?) -> LicenseMessage {
        LicenseCopy.activationFailure(error, backend: backend, supportEmail: configuration.supportEmail)
    }

    // MARK: - Records

    private var currentDate: Date {
        #if DEBUG
        return now().addingTimeInterval(clockOffset)
        #else
        return now()
        #endif
    }

    private var currentLicense: LicenseRecord? {
        if case .success(let record) = licenseResult { return record }
        return nil
    }

    /// The trial record as read, or nil when there is none or it can't be read (it is then never written).
    private var decodedTrial: TrialRecord? {
        if case .success(let record) = trialResult { return record }
        return nil
    }

    /// The trial record the policy works with: an unreadable item with a creation date counts as a record started
    /// then (§14.5), exactly as LicensePolicy.status reads it.
    private var policyTrial: TrialRecord? {
        switch trialResult {
        case .success(let record):
            return record
        case .failure(.undecodable(_, let createdAt?)):
            return TrialRecord(schema: TrialRecord.currentSchema, startedAt: createdAt, lastSeenAt: createdAt,
                               lastLicenseRemoval: nil)
        case .failure:
            return nil
        }
    }

    private var effectiveNow: Date {
        LicensePolicy.effectiveNow(currentDate, trial: policyTrial)
    }

    private func reload() {
        switch sessionLicense {
        case .record(let record):
            licenseResult = .success(record)
        case .removed:
            licenseResult = .success(nil)
        case nil:
            licenseResult = store.loadLicense()
        }
        trialResult = unsavedTrial.map { .success($0) } ?? store.loadTrial()
    }

    private func refreshStatus() {
        let newStatus = LicensePolicy.status(license: licenseResult, trial: trialResult, now: currentDate)
        if newStatus != status { status = newStatus }
        let newRemoval = decodedTrial?.lastLicenseRemoval ?? removalWithoutTrial
        if newRemoval != lastRemoval { lastRemoval = newRemoval }
    }

    /// The trial starts at the first start() of a live paid build, and only when both records read cleanly: never
    /// after a Keychain read failure, never over an unreadable item. The clock offset is never part of it.
    private func createTrialIfNeeded() {
        guard case .success = licenseResult, case .success(nil) = trialResult else { return }
        let startedAt = now()
        let trial = TrialRecord(schema: TrialRecord.currentSchema, startedAt: startedAt, lastSeenAt: startedAt,
                                lastLicenseRemoval: nil)
        persistTrial(trial)
        Self.logger.info("Trial started")
    }

    /// Saves the license; on failure the record lives in memory for this session. Returns the failure, if any.
    @discardableResult
    private func persistLicense(_ record: LicenseRecord) -> LicenseStoreError? {
        licenseResult = .success(record)
        do {
            try store.saveLicense(record)
            sessionLicense = nil
            return nil
        } catch {
            sessionLicense = .record(record)
            return Self.storeError(error)
        }
    }

    /// Saves the trial record; on a Keychain failure it lives in memory for this session. An item the store reports
    /// as unreadable is left alone and read as unreadable from then on.
    private func persistTrial(_ record: TrialRecord) {
        do {
            try store.saveTrial(record)
            unsavedTrial = nil
            trialResult = .success(record)
        } catch {
            let storeError = Self.storeError(error)
            Self.logger.error("Couldn't save the trial record: \(Self.name(of: storeError), privacy: .public)")
            if case .undecodable = storeError {
                unsavedTrial = nil
                trialResult = .failure(storeError)
            } else {
                unsavedTrial = record
                trialResult = .success(record)
            }
        }
    }

    // MARK: - The clock's high-water mark

    private func clockSample() -> LicenseClockSample {
        LicenseClockSample(wall: now(), uptime: uptime())
    }

    /// The only place trial.lastSeenAt moves (tick() and stop(), never start() or a wake). Every call re-baselines.
    private func recordLastSeen() {
        let sample = clockSample()
        defer { clockBaseline = sample }
        guard let baseline = clockBaseline else { return }
        #if DEBUG
        guard clockOffset == 0 else { return }
        #endif
        guard var trial = decodedTrial,
              let next = LicensePolicy.nextLastSeen(current: trial.lastSeenAt, since: baseline, now: sample),
              next > trial.lastSeenAt else { return }
        trial.lastSeenAt = next
        persistTrial(trial)
        refreshStatus()
    }

    // MARK: - Helpers

    private func backend(for kind: LicenseBackendKind) -> (any LicenseBackend)? {
        guard configuration.enabledBackends.contains(kind) else { return nil }
        return backends.first { $0.kind == kind }
    }

    private nonisolated static func missingSettings(_ kind: LicenseBackendKind) -> String {
        "the \(kind.displayName) settings are missing"
    }

    private static func storeError(_ error: Error) -> LicenseStoreError {
        (error as? LicenseStoreError) ?? .keychain(errSecIO)
    }

    private static func osStatus(of error: LicenseStoreError) -> OSStatus {
        switch error {
        case .keychain(let status): return status
        case .undecodable: return errSecDecode
        }
    }

    // Log names: outcome and status names only, never keys, activation ids, labels or emails.

    private static func name(of outcome: LicenseCheckOutcome) -> String {
        switch outcome {
        case .valid: return "valid"
        case .gone(let reason): return "gone(\(reason.rawValue))"
        case .unavailable(let reason): return "unavailable(\(reason))"
        }
    }

    private static func name(of error: LicenseStoreError) -> String {
        switch error {
        case .keychain(let status): return "keychain(\(status))"
        case .undecodable(let account, _): return "undecodable(\(account))"
        }
    }

    private static func name(of status: LicenseStatus) -> String {
        switch status {
        case .trial(_, let daysLeft): return "trial(\(daysLeft) days left)"
        case .trialEnded: return "trialEnded"
        case .licensed(let summary): return "licensed(\(summary.backend.rawValue))"
        case .licensedCheckOverdue(let summary, _): return "licensedCheckOverdue(\(summary.backend.rawValue))"
        case .licensedCheckRequired(let summary): return "licensedCheckRequired(\(summary.backend.rawValue))"
        case .unavailable(let error): return "unavailable(\(name(of: error)))"
        }
    }
}
#endif
