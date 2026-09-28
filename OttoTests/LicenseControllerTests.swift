//
//  LicenseControllerTests.swift
//  OttoTests
//
//  The license engine on fakes only (§14.17.1): InMemoryLicenseStore and FakeLicenseStore, FakeLicenseBackend,
//  ManualLicenseScheduler, an injected wall clock and uptime, and a private NotificationCenter for wakes. Covers the
//  trial record, when background checks run, the clock high-water mark, activation, deactivation, revocation, the
//  fail-open Keychain path, the composer gate and Check Now with its cooldown. No network, no Keychain.
//

#if OTTO_LICENSING
import AppKit
import XCTest
@testable import Otto

@MainActor
final class LicenseControllerTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600
    private let origin = Date(timeIntervalSince1970: 1_791_000_000) // 2026-10-03, a whole second
    private let label = "Mac 0A1B"
    private let rotatedKey = "OTTO-9F8E7D6C-5B4A-4321-8FED-CBA987654321"

    private var clock: TestClock!
    private var scheduler: ManualLicenseScheduler!
    private var polar: FakeLicenseBackend!
    private var gumroad: FakeLicenseBackend!
    private var center: NotificationCenter!

    override func setUp() async throws {
        clock = TestClock(wall: origin, uptime: 50_000)
        scheduler = ManualLicenseScheduler()
        polar = FakeLicenseBackend(kind: .polar)
        gumroad = FakeLicenseBackend(kind: .gumroad)
        center = NotificationCenter()
    }

    // MARK: - Helpers

    /// `LicenseConfiguration.preview` with Gumroad switched on, for the candidate-order tests.
    private var gumroadOnConfiguration: LicenseConfiguration {
        let preview = LicenseConfiguration.preview
        return LicenseConfiguration(siteHost: preview.siteHost, supportEmail: preview.supportEmail,
                                    polar: preview.polar,
                                    gumroad: GumroadConfiguration(productID: LicenseFixtures.gumroadProductID),
                                    gumroadExplicitlyOff: false, problems: [])
    }

    private func makeController(store: LicenseStoring,
                                configuration: LicenseConfiguration = .preview) -> LicenseController {
        let clock = clock!
        let label = label
        return LicenseController(configuration: configuration, store: store, backends: [polar, gumroad],
                                 scheduler: scheduler, now: { clock.wall }, uptime: { clock.uptime },
                                 randomLabel: { label }, notificationCenter: center)
    }

    private func polarRecord(key: String = LicenseFixtures.polarKey, validatedAt: Date, attemptAt: Date? = nil,
                             pending: PendingRevocation? = nil) -> LicenseRecord {
        LicenseRecord(schema: LicenseRecord.currentSchema, backend: .polar, apiHost: "sandbox-api.polar.sh",
                      organizationID: LicenseFixtures.organizationID, benefitID: LicenseFixtures.benefitID,
                      gumroadProductID: nil, key: key, licenseKeyID: LicenseFixtures.licenseKeyID,
                      activationID: LicenseFixtures.activationID, label: "Mac 7F3A",
                      displayKey: LicenseKeyRouter.displayKey(for: key), seatLimit: 3, activatedAt: validatedAt,
                      lastValidatedAt: validatedAt, lastAttemptAt: attemptAt, pendingRevocation: pending)
    }

    private func gumroadRecord(key: String = LicenseFixtures.gumroadKey, validatedAt: Date) -> LicenseRecord {
        LicenseRecord(schema: LicenseRecord.currentSchema, backend: .gumroad, apiHost: "api.gumroad.com",
                      organizationID: nil, benefitID: nil, gumroadProductID: LicenseFixtures.gumroadProductID,
                      key: key, licenseKeyID: nil, activationID: nil, label: "",
                      displayKey: LicenseKeyRouter.displayKey(for: key), seatLimit: 3, activatedAt: validatedAt,
                      lastValidatedAt: validatedAt, lastAttemptAt: validatedAt, pendingRevocation: nil)
    }

    private func trial(startedAt: Date, lastSeenAt: Date? = nil, removal: LicenseRemoval? = nil) -> TrialRecord {
        TrialRecord(schema: TrialRecord.currentSchema, startedAt: startedAt, lastSeenAt: lastSeenAt ?? startedAt,
                    lastLicenseRemoval: removal)
    }

    private func storedTrial(_ store: LicenseStoring) -> TrialRecord? {
        guard case .success(let trial) = store.loadTrial() else { return nil }
        return trial
    }

    private func storedLicense(_ store: LicenseStoring) -> LicenseRecord? {
        guard case .success(let license) = store.loadLicense() else { return nil }
        return license
    }

    /// Waits for the Task an action or a check started to land (activity back to .idle).
    private func settle(_ controller: LicenseController, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while controller.activity != .idle, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(controller.activity, .idle, "the work never finished", file: file, line: line)
    }

    private func postWake() {
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
    }

    // MARK: - The trial record

    func testFirstStartWritesOneTrialRecordAndAReinstallKeepsIt() {
        let store = FakeLicenseStore()
        let first = makeController(store: store)
        XCTAssertEqual(store.writes, [], "init only reads")
        first.start()
        XCTAssertEqual(store.writes, ["saveTrial"])
        XCTAssertEqual(storedTrial(store), trial(startedAt: origin))
        XCTAssertEqual(first.status, .trial(endsAt: origin.addingTimeInterval(14 * day), daysLeft: 14))
        first.start()
        XCTAssertEqual(store.writes, ["saveTrial"], "a second start() changes nothing")

        // Three days later Otto is deleted and installed again: the Keychain record survives and counts on.
        clock.advance(3 * day)
        let reinstalled = makeController(store: store)
        reinstalled.start()
        XCTAssertEqual(store.writes, ["saveTrial"])
        XCTAssertEqual(storedTrial(store)?.startedAt, origin)
        XCTAssertEqual(reinstalled.status, .trial(endsAt: origin.addingTimeInterval(14 * day), daysLeft: 11))
    }

    func testTheTrialOnAnInMemoryStoreSurvivesASecondController() {
        let store = InMemoryLicenseStore()
        makeController(store: store).start()
        clock.advance(15 * day)
        let second = makeController(store: store)
        second.start()
        XCTAssertEqual(storedTrial(store)?.startedAt, origin)
        XCTAssertEqual(second.status, .trialEnded(endedAt: origin.addingTimeInterval(14 * day)))
        XCTAssertEqual(second.composerGate?.id, "trial-ended")
    }

    func testATrialWhoseSaveFailsLastsForThisSession() {
        let store = FakeLicenseStore()
        store.saveFailure = .keychain(errSecInteractionNotAllowed)
        let controller = makeController(store: store)
        controller.start()
        XCTAssertEqual(controller.status, .trial(endsAt: origin.addingTimeInterval(14 * day), daysLeft: 14))
        clock.advance(2 * day)
        controller.tick()
        XCTAssertEqual(controller.status, .trial(endsAt: origin.addingTimeInterval(14 * day), daysLeft: 12))
    }

    // MARK: - When checks run

    func testNoBackendCallBeforeTenSecondsAfterStart() async {
        let store = InMemoryLicenseStore(license: polarRecord(validatedAt: origin.addingTimeInterval(-2 * day),
                                                              attemptAt: origin.addingTimeInterval(-2 * day)),
                                         trial: trial(startedAt: origin.addingTimeInterval(-20 * day)))
        polar.scriptValidate([.valid(LicenseValidation(seatLimit: 3, displayKey: nil))])
        let controller = makeController(store: store)
        controller.start()
        XCTAssertEqual(polar.calls, [], "launch computes status from the Keychain alone")
        scheduler.advance(by: .milliseconds(9_999))
        clock.advance(9.999)
        XCTAssertEqual(polar.calls, [])

        scheduler.advance(by: .milliseconds(1))
        clock.advance(0.001)
        await settle(controller)
        XCTAssertEqual(polar.calls, ["validate:\(LicenseFixtures.activationID)"])
        XCTAssertEqual(storedLicense(store)?.lastValidatedAt, clock.wall)
        XCTAssertEqual(storedLicense(store)?.lastAttemptAt, clock.wall)
        XCTAssertNil(controller.lastMessage, "a background check never sets the user's message")
    }

    func testTheLaunchCheckSkipsALicenseCheckedWithinADay() async {
        let store = InMemoryLicenseStore(license: polarRecord(validatedAt: origin.addingTimeInterval(-hour),
                                                              attemptAt: origin.addingTimeInterval(-hour)),
                                         trial: trial(startedAt: origin.addingTimeInterval(-20 * day)))
        let controller = makeController(store: store)
        controller.start()
        scheduler.advance(by: .seconds(10))
        await settle(controller)
        XCTAssertEqual(polar.calls, [])
    }

    func testAWakeChecksThirtySecondsLaterWhenACheckIsDue() async {
        let store = InMemoryLicenseStore(license: polarRecord(validatedAt: origin.addingTimeInterval(-2 * day),
                                                              attemptAt: origin.addingTimeInterval(-2 * day)),
                                         trial: trial(startedAt: origin.addingTimeInterval(-20 * day)))
        polar.scriptValidate([.valid(LicenseValidation()), .valid(LicenseValidation())])
        let controller = makeController(store: store)
        controller.start()
        scheduler.advance(by: .seconds(10))
        await settle(controller)
        XCTAssertEqual(polar.calls.count, 1)

        // A wake while nothing is due schedules a look that makes no request.
        postWake()
        scheduler.advance(by: .seconds(30))
        await settle(controller)
        XCTAssertEqual(polar.calls.count, 1)

        // The Mac slept for a day: the wake check runs 30 s after the wake, not before.
        clock.advance(25 * hour)
        postWake()
        scheduler.advance(by: .seconds(29))
        await settle(controller)
        XCTAssertEqual(polar.calls.count, 1)
        scheduler.advance(by: .seconds(1))
        await settle(controller)
        XCTAssertEqual(polar.calls.count, 2)
        XCTAssertEqual(storedLicense(store)?.lastValidatedAt, clock.wall)
    }

    func testTheHourlyTickChecksOnlyWhenACheckIsDue() async {
        let lastAttempt = origin.addingTimeInterval(-23 * hour)
        let store = InMemoryLicenseStore(license: polarRecord(validatedAt: lastAttempt, attemptAt: lastAttempt),
                                         trial: trial(startedAt: origin.addingTimeInterval(-20 * day)))
        polar.scriptValidate([.unavailable(.offline)])
        let controller = makeController(store: store)
        controller.start()
        scheduler.advance(by: .seconds(10))
        await settle(controller)
        XCTAssertEqual(polar.calls, [], "23 h after the last attempt nothing is due")

        clock.advance(hour)
        scheduler.advance(by: .seconds(3_590))
        await settle(controller)
        XCTAssertEqual(polar.calls.count, 1, "the hourly tick runs the check that became due")
        XCTAssertEqual(storedLicense(store)?.lastAttemptAt, clock.wall)
        XCTAssertEqual(storedLicense(store)?.lastValidatedAt, lastAttempt, "an outage never counts as valid")

        clock.advance(hour)
        scheduler.advance(by: .seconds(3_600))
        await settle(controller)
        XCTAssertEqual(polar.calls.count, 1, "one attempt per 24 h, whatever the outcome")
    }

    // MARK: - The clock high-water mark

    func testLastSeenIsWrittenOnlyByTheTickAndStop() async {
        let started = origin.addingTimeInterval(-2 * day)
        let store = FakeLicenseStore(trial: trial(startedAt: started))
        let controller = makeController(store: store)
        controller.start()
        XCTAssertEqual(store.writes, [], "start() never moves lastSeenAt")

        clock.advance(hour)
        postWake()
        scheduler.advance(by: .seconds(30))
        await settle(controller)
        XCTAssertEqual(store.writes, [], "a wake never moves lastSeenAt")

        controller.tick()
        XCTAssertEqual(store.writes, ["saveTrial"])
        XCTAssertEqual(storedTrial(store)?.lastSeenAt, clock.wall)
        XCTAssertEqual(storedTrial(store)?.startedAt, started)

        clock.advance(10 * 60)
        controller.stop()
        XCTAssertEqual(store.writes, ["saveTrial", "saveTrial"])
        XCTAssertEqual(storedTrial(store)?.lastSeenAt, clock.wall)
        XCTAssertEqual(scheduler.pendingCount, 0, "stop() cancels the scheduled work")

        // A relaunch: start() on a new controller writes nothing, and a tick less than 5 minutes later skips.
        let relaunched = makeController(store: store)
        relaunched.start()
        clock.advance(4 * 60)
        relaunched.tick()
        XCTAssertEqual(store.writes, ["saveTrial", "saveTrial"])
    }

    func testTheScheduledTickWritesLastSeenAfterAnHourOfSteadyClock() {
        let store = FakeLicenseStore(trial: trial(startedAt: origin))
        let controller = makeController(store: store)
        controller.start()
        clock.advance(hour)
        scheduler.advance(by: .seconds(3_600))
        XCTAssertEqual(store.writes, ["saveTrial"])
        XCTAssertEqual(storedTrial(store)?.lastSeenAt, clock.wall)
        XCTAssertEqual(scheduler.pendingCount, 1, "the next tick is scheduled")
        controller.stop()
    }

    func testAWallClockJumpIsNeverPersisted() {
        let started = origin.addingTimeInterval(-2 * day)
        let store = FakeLicenseStore(trial: trial(startedAt: started))
        let controller = makeController(store: store)
        controller.start()
        let daysLeftBefore = controller.status

        // The clock jumps two years ahead between two samples an hour of uptime apart.
        let steadyWall = clock.wall
        clock.uptime += hour
        clock.wall = steadyWall.addingTimeInterval(2 * 365 * day)
        controller.tick()
        XCTAssertEqual(store.writes, [], "a jump is a wall/uptime disagreement: nothing is written")
        XCTAssertEqual(controller.status, .trialEnded(endedAt: started.addingTimeInterval(14 * day)),
                       "while the clock is wrong the status follows it")

        // NTP puts it back an hour later: that sample disagrees too, and still nothing is written.
        clock.uptime += hour
        clock.wall = steadyWall.addingTimeInterval(2 * hour)
        controller.tick()
        XCTAssertEqual(store.writes, [])
        XCTAssertEqual(storedTrial(store)?.lastSeenAt, started)
        guard case .trial(_, let daysLeftAfter) = controller.status,
              case .trial(_, let daysLeftBeforeValue) = daysLeftBefore else {
            return XCTFail("expected the trial to be back: \(controller.status)")
        }
        XCTAssertEqual(daysLeftAfter, daysLeftBeforeValue)

        // Once the clock is steady again the high-water mark moves, to the right time.
        clock.advance(hour)
        controller.tick()
        XCTAssertEqual(store.writes, ["saveTrial"])
        XCTAssertEqual(storedTrial(store)?.lastSeenAt, clock.wall)
    }

    #if DEBUG
    func testTheDebugClockOffsetShiftsStatusButNeverWritesLastSeen() {
        let store = FakeLicenseStore(trial: trial(startedAt: origin))
        let controller = makeController(store: store)
        controller.clockOffset = 3 * day
        controller.start()
        XCTAssertEqual(controller.status, .trial(endsAt: origin.addingTimeInterval(14 * day), daysLeft: 11))
        clock.advance(hour)
        controller.tick()
        clock.advance(hour)
        controller.stop()
        XCTAssertEqual(store.writes, [])
        XCTAssertEqual(storedTrial(store)?.lastSeenAt, origin)
    }
    #endif

    // MARK: - Activation

    func testActivationSuccessLicensesThisMac() async {
        let store = FakeLicenseStore(trial: trial(startedAt: origin.addingTimeInterval(-20 * day)))
        let controller = makeController(store: store)
        controller.start()
        XCTAssertEqual(controller.composerGate?.id, "trial-ended")
        let activated = polarRecord(validatedAt: origin)
        polar.scriptActivate([.success(activated)])

        controller.activate(key: "  \(LicenseFixtures.polarKey)\n")
        XCTAssertEqual(controller.activity, .activating)
        XCTAssertEqual(controller.composerGate?.id, "activating")
        await settle(controller)

        XCTAssertEqual(polar.calls, ["activate:\(LicenseFixtures.polarKey)|\(label)|nil"])
        XCTAssertEqual(controller.lastMessage, LicenseCopy.activated)
        XCTAssertEqual(controller.status, .licensed(LicenseSummary(record: activated)))
        XCTAssertNil(controller.composerGate)
        XCTAssertEqual(storedLicense(store), activated)
        XCTAssertEqual(store.writes, ["saveLicense"])
    }

    func testEachActivationFailureLeavesTheStatusAndSaysWhy() async {
        let failures: [LicenseActivationError] = [
            .malformedKey, .keyNotFound, .keyNotActive, .wrongProduct, .seatLimitReached(limit: 3),
            .unavailable(.offline), .unavailable(.timeout), .unavailable(.rateLimited(retryAfter: 30)),
            .unavailable(.server(status: 503)), .unavailable(.versionRefused),
            .unavailable(.misconfigured("Polar benefit has no activation limit")), .unavailable(.recordMismatch),
        ]
        for failure in failures {
            let store = FakeLicenseStore(trial: trial(startedAt: origin.addingTimeInterval(-20 * day)))
            let backend = FakeLicenseBackend(kind: .polar)
            backend.scriptActivate([.failure(failure)])
            let controller = LicenseController(configuration: .preview, store: store, backends: [backend],
                                               scheduler: scheduler, now: { [clock] in clock!.wall },
                                               uptime: { [clock] in clock!.uptime }, randomLabel: { "Mac 0A1B" },
                                               notificationCenter: center)
            controller.start()
            controller.activate(key: LicenseFixtures.polarKey)
            await settle(controller)
            XCTAssertEqual(controller.lastMessage,
                           LicenseCopy.activationFailure(failure, backend: .polar,
                                                         supportEmail: LicenseConfiguration.preview.supportEmail),
                           "\(failure)")
            XCTAssertEqual(controller.lastMessage?.tone, .problem)
            XCTAssertEqual(controller.status, .trialEnded(endedAt: origin.addingTimeInterval(-6 * day)))
            XCTAssertEqual(controller.composerGate?.id, "trial-ended")
            XCTAssertEqual(store.writes, [], "\(failure)")
        }
    }

    func testAKeyThatCantBeAKeyNeverReachesABackend() {
        let controller = makeController(store: InMemoryLicenseStore(), configuration: gumroadOnConfiguration)
        controller.start()
        controller.activate(key: " \n\t ")
        XCTAssertEqual(controller.activity, .idle)
        XCTAssertEqual(controller.lastMessage,
                       LicenseCopy.activationFailure(.malformedKey, backend: nil, supportEmail: "support@example.com"))
        XCTAssertEqual(polar.calls + gumroad.calls, [])
    }

    func testAGumroadKeyWithGumroadOffNeverReachesABackend() {
        let controller = makeController(store: InMemoryLicenseStore())
        controller.start()
        controller.activate(key: LicenseFixtures.gumroadKey)
        XCTAssertEqual(controller.activity, .idle)
        XCTAssertEqual(controller.lastMessage,
                       LicenseCopy.activationFailure(.backendDisabled(.gumroad), backend: nil,
                                                     supportEmail: "support@example.com"))
        XCTAssertEqual(polar.calls + gumroad.calls, [])
    }

    func testAGumroadSeatLimitNamesGumroad() async {
        let controller = makeController(store: InMemoryLicenseStore(), configuration: gumroadOnConfiguration)
        controller.start()
        gumroad.scriptActivate([.failure(.seatLimitReached(limit: 6))])
        controller.activate(key: LicenseFixtures.gumroadKey)
        await settle(controller)
        XCTAssertEqual(polar.calls, [], "a Gumroad-shaped key never reaches Polar")
        XCTAssertEqual(gumroad.calls, ["activate:\(LicenseFixtures.gumroadKey)|\(label)|nil"])
        XCTAssertEqual(controller.lastMessage?.text,
                       "That key is already on 6 Macs. Email support@example.com and I'll free a seat.")
    }

    func testAKeyOfNeitherShapeTriesPolarThenGumroad() async {
        let store = InMemoryLicenseStore()
        let controller = makeController(store: store, configuration: gumroadOnConfiguration)
        controller.start()
        let key = "LEGACY-KEY-42"
        let record = gumroadRecord(key: key, validatedAt: origin)
        polar.scriptActivate([.failure(.keyNotFound)])
        gumroad.scriptActivate([.success(record)])
        controller.activate(key: key)
        await settle(controller)
        XCTAssertEqual(polar.calls, ["activate:\(key)|\(label)|nil"])
        XCTAssertEqual(gumroad.calls, ["activate:\(key)|\(label)|nil"])
        XCTAssertEqual(controller.status, .licensed(LicenseSummary(record: record)))
        XCTAssertEqual(controller.lastMessage, LicenseCopy.activated)
    }

    func testOnlyKeyNotFoundMovesOnToTheNextCandidate() async {
        let controller = makeController(store: InMemoryLicenseStore(), configuration: gumroadOnConfiguration)
        controller.start()
        polar.scriptActivate([.failure(.keyNotActive)])
        controller.activate(key: "LEGACY-KEY-42")
        await settle(controller)
        XCTAssertEqual(polar.calls.count, 1)
        XCTAssertEqual(gumroad.calls, [])
        XCTAssertEqual(controller.lastMessage,
                       LicenseCopy.activationFailure(.keyNotActive, backend: .polar,
                                                     supportEmail: "support@example.com"))
    }

    func testAPolarShapedKeyNeverReachesTheGumroadFake() async {
        let controller = makeController(store: InMemoryLicenseStore(), configuration: gumroadOnConfiguration)
        controller.start()
        polar.scriptActivate([.failure(.keyNotFound), .failure(.keyNotFound)])
        controller.activate(key: LicenseFixtures.polarKey)
        await settle(controller)
        controller.activate(key: LicenseFixtures.polarKeyUnprefixed.lowercased())
        await settle(controller)
        XCTAssertEqual(polar.calls.count, 2)
        XCTAssertEqual(gumroad.calls, [])
        XCTAssertEqual(controller.lastMessage,
                       LicenseCopy.activationFailure(.keyNotFound, backend: .polar,
                                                     supportEmail: "support@example.com"))
    }

    func testActivationIsIgnoredWhileBusy() async {
        let controller = makeController(store: InMemoryLicenseStore())
        controller.start()
        polar.scriptActivate([.success(polarRecord(validatedAt: origin))])
        controller.activate(key: LicenseFixtures.polarKey)
        controller.activate(key: rotatedKey)
        await settle(controller)
        XCTAssertEqual(polar.calls, ["activate:\(LicenseFixtures.polarKey)|\(label)|nil"])
    }

    func testActivationIsOfferedWhileARevocationIsPendingAndARekeyClearsIt() async {
        let pending = PendingRevocation(firstSeenAt: origin.addingTimeInterval(-hour), reason: .notFound)
        let current = polarRecord(validatedAt: origin.addingTimeInterval(-2 * day),
                                  attemptAt: origin.addingTimeInterval(-hour), pending: pending)
        let store = FakeLicenseStore(license: current, trial: trial(startedAt: origin.addingTimeInterval(-40 * day)))
        let controller = makeController(store: store)
        controller.start()
        XCTAssertEqual(controller.status.summary?.pendingRevocation, pending)

        // The backend re-keys on the existing activation (it keeps the label and the IDs).
        var rekeyed = current
        rekeyed.key = rotatedKey
        rekeyed.displayKey = LicenseKeyRouter.displayKey(for: rotatedKey)
        rekeyed.lastValidatedAt = origin
        rekeyed.lastAttemptAt = origin
        polar.scriptActivate([.success(rekeyed)])
        controller.activate(key: rotatedKey)
        await settle(controller)

        XCTAssertEqual(polar.calls, ["activate:\(rotatedKey)|Mac 7F3A|\(LicenseFixtures.activationID)"],
                       "the current label and record go with the request")
        XCTAssertEqual(controller.lastMessage, LicenseCopy.rekeyed)
        XCTAssertNil(storedLicense(store)?.pendingRevocation)
        XCTAssertEqual(storedLicense(store)?.key, rotatedKey)
        XCTAssertNil(controller.status.summary?.pendingRevocation)
    }

    func testActivationClearsTheLastRemoval() async {
        let removal = LicenseRemoval(at: origin.addingTimeInterval(-day), reason: .refunded)
        let store = InMemoryLicenseStore(trial: trial(startedAt: origin.addingTimeInterval(-30 * day), removal: removal))
        let controller = makeController(store: store)
        controller.start()
        XCTAssertEqual(controller.lastRemoval, removal)
        XCTAssertEqual(controller.composerGate?.id, "license-removed")
        polar.scriptActivate([.success(polarRecord(validatedAt: origin))])
        controller.activate(key: LicenseFixtures.polarKey)
        await settle(controller)
        XCTAssertNil(controller.lastRemoval)
        XCTAssertNil(storedTrial(store)?.lastLicenseRemoval)
        XCTAssertEqual(storedTrial(store)?.startedAt, origin.addingTimeInterval(-30 * day))
    }

    func testAKeychainSaveFailureKeepsTheLicenseForThisSession() async {
        let store = FakeLicenseStore(trial: trial(startedAt: origin.addingTimeInterval(-20 * day)))
        let controller = makeController(store: store)
        controller.start()
        store.saveFailure = .keychain(errSecInteractionNotAllowed)
        let activated = polarRecord(validatedAt: origin)
        polar.scriptActivate([.success(activated)])
        controller.activate(key: LicenseFixtures.polarKey)
        await settle(controller)

        XCTAssertEqual(controller.lastMessage, LicenseCopy.activatedUnsaved(status: errSecInteractionNotAllowed))
        XCTAssertEqual(controller.lastMessage?.tone, .info)
        XCTAssertEqual(controller.status, .licensed(LicenseSummary(record: activated)))
        XCTAssertNil(storedLicense(store))

        // Later reads still see the license this session holds in memory.
        clock.advance(hour)
        controller.tick()
        await settle(controller)
        XCTAssertEqual(controller.status, .licensed(LicenseSummary(record: activated)))
        XCTAssertNil(controller.composerGate)
        XCTAssertNil(storedLicense(store), "nothing reaches the store while it refuses writes")
    }

    func testActivationWhileTheLicenseCantBeReadWritesNothing() {
        let store = FakeLicenseStore()
        store.loadFailure = .keychain(errSecInteractionNotAllowed)
        let controller = makeController(store: store)
        controller.start()
        controller.activate(key: LicenseFixtures.polarKey)
        XCTAssertEqual(controller.activity, .idle)
        XCTAssertEqual(polar.calls, [])
        XCTAssertEqual(store.writes, [])
        XCTAssertEqual(controller.lastMessage?.tone, .problem)
        XCTAssertEqual(controller.lastMessage?.text,
                       "Otto couldn't read its license from the Keychain (error \(errSecInteractionNotAllowed)). "
                       + "It works normally until it can.")
    }

    // MARK: - Deactivation

    func testTheFourDeactivationOutcomes() async {
        let cases: [(LicenseBackendKind, LicenseDeactivationOutcome)] = [
            (.polar, .freedSeat), (.polar, .alreadyGone), (.gumroad, .localOnly), (.polar, .unavailable(.offline)),
        ]
        for (kind, outcome) in cases {
            let record = kind == .polar ? polarRecord(validatedAt: origin) : gumroadRecord(validatedAt: origin)
            let startedAt = origin.addingTimeInterval(-5 * day)
            let store = FakeLicenseStore(license: record, trial: trial(startedAt: startedAt))
            let polarBackend = FakeLicenseBackend(kind: .polar)
            let gumroadBackend = FakeLicenseBackend(kind: .gumroad)
            (kind == .polar ? polarBackend : gumroadBackend).scriptDeactivate([outcome])
            let controller = LicenseController(configuration: gumroadOnConfiguration, store: store,
                                               backends: [polarBackend, gumroadBackend], scheduler: scheduler,
                                               now: { [clock] in clock!.wall }, uptime: { [clock] in clock!.uptime },
                                               randomLabel: { "Mac 0A1B" }, notificationCenter: center)
            controller.start()
            controller.deactivate()
            XCTAssertEqual(controller.activity, .deactivating)
            await settle(controller)

            let expected = LicenseCopy.deactivation(outcome, backend: kind, supportEmail: "support@example.com")
            XCTAssertEqual(controller.lastMessage, expected, "\(outcome)")
            XCTAssertEqual((kind == .polar ? polarBackend : gumroadBackend).calls.count, 1)
            if case .unavailable = outcome {
                XCTAssertEqual(storedLicense(store), record, "the license stays")
                XCTAssertEqual(controller.status, .licensed(LicenseSummary(record: record)))
                XCTAssertNil(controller.lastRemoval)
                XCTAssertEqual(store.writes, [])
            } else {
                let removal = LicenseRemoval(at: origin, reason: .deactivatedByUser)
                XCTAssertNil(storedLicense(store), "\(outcome)")
                XCTAssertEqual(controller.lastRemoval, removal)
                XCTAssertEqual(storedTrial(store)?.lastLicenseRemoval, removal)
                XCTAssertEqual(controller.status, .trial(endsAt: startedAt.addingTimeInterval(14 * day), daysLeft: 9),
                               "a license removed inside the trial window returns the Mac to its trial")
                XCTAssertEqual(store.writes, ["deleteLicense", "saveTrial"])
            }
        }
    }

    func testRemoveFromThisMacAfterAFailedDeactivation() async {
        let record = polarRecord(validatedAt: origin)
        let store = FakeLicenseStore(license: record, trial: trial(startedAt: origin.addingTimeInterval(-30 * day)))
        let controller = makeController(store: store)
        controller.start()
        polar.scriptDeactivate([.unavailable(.timeout)])
        controller.deactivate()
        await settle(controller)
        XCTAssertEqual(controller.lastMessage?.tone, .problem)
        XCTAssertNotNil(storedLicense(store))

        controller.removeFromThisMac()
        XCTAssertEqual(polar.calls, ["deactivate:\(LicenseFixtures.activationID)"], "removal is local only")
        XCTAssertNil(storedLicense(store))
        XCTAssertEqual(controller.lastRemoval, LicenseRemoval(at: origin, reason: .removedByUser))
        XCTAssertEqual(controller.lastMessage, LicenseCopy.removedLocally(.polar, supportEmail: "support@example.com"))
        XCTAssertEqual(controller.composerGate?.id, "license-removed")
    }

    // MARK: - Revocation

    func testRevocationNeedsTwoGoneAnswersAtLeastTwentyHoursApart() async {
        let startedAt = origin.addingTimeInterval(-30 * day)
        let record = polarRecord(validatedAt: origin.addingTimeInterval(-2 * day),
                                 attemptAt: origin.addingTimeInterval(-2 * day))
        let store = FakeLicenseStore(license: record, trial: trial(startedAt: startedAt))
        polar.scriptValidate([.gone(.notFound), .gone(.notFound), .gone(.notFound)])
        let controller = makeController(store: store)
        controller.start()

        controller.checkNow()
        await settle(controller)
        let pending = PendingRevocation(firstSeenAt: origin, reason: .notFound)
        XCTAssertEqual(storedLicense(store)?.pendingRevocation, pending)
        XCTAssertEqual(controller.status.summary?.pendingRevocation, pending)
        XCTAssertEqual(controller.lastMessage,
                       LicenseMessage(tone: .problem, text: LicenseCopy.pendingRevocationLine(pending, backend: .polar)))
        XCTAssertNil(controller.composerGate, "one answer never acts alone")

        clock.advance(19 * hour + 59 * 60)
        controller.checkNow()
        await settle(controller)
        XCTAssertEqual(storedLicense(store)?.pendingRevocation, pending, "the 20 h window keeps its start")
        XCTAssertNotNil(controller.status.summary)

        clock.advance(60)
        controller.checkNow()
        await settle(controller)
        let removal = LicenseRemoval(at: clock.wall, reason: .revoked)
        XCTAssertNil(storedLicense(store))
        XCTAssertEqual(controller.lastRemoval, removal)
        XCTAssertEqual(storedTrial(store)?.lastLicenseRemoval, removal)
        XCTAssertEqual(controller.status, .trialEnded(endedAt: startedAt.addingTimeInterval(14 * day)))
        XCTAssertEqual(controller.composerGate?.id, "license-removed")
        XCTAssertEqual(controller.lastMessage, LicenseMessage(tone: .problem, text: LicenseCopy.removalLine(removal)))
        XCTAssertEqual(polar.calls.count, 3)
    }

    func testAValidAnswerClearsAPendingRevocation() async {
        let pending = PendingRevocation(firstSeenAt: origin.addingTimeInterval(-25 * hour), reason: .notFound)
        let record = polarRecord(validatedAt: origin.addingTimeInterval(-3 * day),
                                 attemptAt: origin.addingTimeInterval(-25 * hour), pending: pending)
        let store = InMemoryLicenseStore(license: record, trial: trial(startedAt: origin.addingTimeInterval(-30 * day)))
        polar.scriptValidate([.valid(LicenseValidation(seatLimit: 3, displayKey: nil))])
        let controller = makeController(store: store)
        controller.start()
        scheduler.advance(by: .seconds(10))
        await settle(controller)
        XCTAssertNil(storedLicense(store)?.pendingRevocation)
        XCTAssertEqual(storedLicense(store)?.lastValidatedAt, origin)
    }

    // MARK: - Keychain failures fail open

    func testAKeychainReadFailureFailsOpenAndWritesNothing() async {
        let store = FakeLicenseStore(license: polarRecord(validatedAt: origin.addingTimeInterval(-60 * day)),
                                     trial: trial(startedAt: origin.addingTimeInterval(-90 * day)))
        store.loadFailure = .keychain(errSecInteractionNotAllowed)
        let controller = makeController(store: store)
        controller.start()
        XCTAssertEqual(controller.status, .unavailable(.keychain(errSecInteractionNotAllowed)))
        XCTAssertTrue(controller.status.allowsSending)
        XCTAssertNil(controller.composerGate)

        scheduler.advance(by: .seconds(10))
        clock.advance(hour)
        controller.tick()
        controller.checkNow()
        controller.deactivate()
        controller.removeFromThisMac()
        await settle(controller)
        clock.advance(hour)
        controller.stop()
        XCTAssertEqual(store.writes, [], "no trial is created and nothing is written after a read failure")
        XCTAssertEqual(polar.calls, [])

        // A later read that succeeds brings the real status back.
        store.loadFailure = nil
        controller.tick()
        await settle(controller)
        XCTAssertEqual(controller.composerGate?.id, "check-required")
    }

    func testAnUnreadableTrialIsDatedFromItsCreationAndNeverOverwritten() {
        let created = origin.addingTimeInterval(-3 * day)
        let store = LicenseControllerUnreadableTrialStore(createdAt: created)
        let controller = makeController(store: store)
        controller.start()
        XCTAssertEqual(controller.status, .trial(endsAt: created.addingTimeInterval(14 * day), daysLeft: 11))
        clock.advance(hour)
        controller.tick()
        controller.stop()
        XCTAssertEqual(store.trialWrites, 0)

        clock.advance(12 * day)
        let later = makeController(store: store)
        later.start()
        XCTAssertEqual(later.status, .trialEnded(endedAt: created.addingTimeInterval(14 * day)))
        XCTAssertEqual(later.composerGate?.id, "trial-ended")
        XCTAssertEqual(store.trialWrites, 0)
    }

    // MARK: - The composer gate

    func testTheGatePerStatus() {
        let ended = origin.addingTimeInterval(-20 * day)
        let cases: [(LicenseRecord?, TrialRecord?, String?)] = [
            (nil, trial(startedAt: origin.addingTimeInterval(-day)), nil),
            (nil, trial(startedAt: ended), "trial-ended"),
            (nil, trial(startedAt: ended, removal: LicenseRemoval(at: origin, reason: .revoked)), "license-removed"),
            (polarRecord(validatedAt: origin.addingTimeInterval(-10 * day)), trial(startedAt: ended), nil),
            (polarRecord(validatedAt: origin.addingTimeInterval(-35 * day)), trial(startedAt: ended), nil),
            (polarRecord(validatedAt: origin.addingTimeInterval(-45 * day)), trial(startedAt: ended), "check-required"),
        ]
        for (license, trial, gateID) in cases {
            let controller = makeController(store: InMemoryLicenseStore(license: license, trial: trial))
            controller.start()
            XCTAssertEqual(controller.composerGate?.id, gateID, "\(controller.status)")
            XCTAssertEqual(controller.composerGate,
                           LicenseCopy.gate(status: controller.status, removal: controller.lastRemoval,
                                            activity: controller.activity, configuration: .preview))
            XCTAssertEqual(controller.status.allowsSending, gateID == nil)
        }
        let unreadable = makeController(store: InMemoryLicenseStore(failure: .undecodable(account: "license.sandbox",
                                                                                            createdAt: nil)))
        unreadable.start()
        XCTAssertNil(unreadable.composerGate)
    }

    func testCheckNowFromTheGate() async {
        let record = polarRecord(validatedAt: origin.addingTimeInterval(-45 * day),
                                 attemptAt: origin.addingTimeInterval(-hour))
        let store = InMemoryLicenseStore(license: record, trial: trial(startedAt: origin.addingTimeInterval(-60 * day)))
        polar.scriptValidate([.valid(LicenseValidation(seatLimit: 3, displayKey: LicenseFixtures.polarDisplayKey))])
        let controller = makeController(store: store)
        controller.start()
        XCTAssertEqual(controller.composerGate?.id, "check-required")

        controller.handleGateAction("check-now")
        XCTAssertEqual(controller.activity, .checking)
        XCTAssertEqual(controller.composerGate?.id, "checking")
        await settle(controller)
        XCTAssertEqual(polar.calls, ["validate:\(LicenseFixtures.activationID)"])
        XCTAssertNil(controller.composerGate)
        XCTAssertEqual(controller.lastMessage, LicenseCopy.checkedValid)
        XCTAssertEqual(storedLicense(store)?.lastValidatedAt, origin)

        controller.handleGateAction("something-else")
        XCTAssertEqual(polar.calls.count, 1)
    }

    func testAFailedCheckNeverDowngrades() async {
        let record = polarRecord(validatedAt: origin.addingTimeInterval(-45 * day),
                                 attemptAt: origin.addingTimeInterval(-hour))
        let store = InMemoryLicenseStore(license: record, trial: trial(startedAt: origin.addingTimeInterval(-60 * day)))
        polar.scriptValidate([.unavailable(.offline)])
        let controller = makeController(store: store)
        controller.start()
        controller.checkNow()
        await settle(controller)
        XCTAssertEqual(controller.lastMessage, LicenseCopy.checkFailure(.offline, backend: .polar))
        XCTAssertEqual(storedLicense(store)?.lastValidatedAt, record.lastValidatedAt)
        XCTAssertNil(storedLicense(store)?.pendingRevocation)
        XCTAssertEqual(controller.composerGate?.id, "check-required")
    }

    // MARK: - Check Now's cooldown

    func testCheckNowHonorsTheSixtySecondCooldown() async {
        let record = polarRecord(validatedAt: origin.addingTimeInterval(-2 * day),
                                 attemptAt: origin.addingTimeInterval(-2 * day))
        let store = InMemoryLicenseStore(license: record, trial: trial(startedAt: origin.addingTimeInterval(-20 * day)))
        polar.scriptValidate([.valid(LicenseValidation()), .valid(LicenseValidation())])
        let controller = makeController(store: store)
        controller.start()
        controller.checkNow()
        await settle(controller)
        XCTAssertEqual(polar.calls.count, 1)
        controller.dismissMessage()
        XCTAssertNil(controller.lastMessage)

        clock.advance(59)
        controller.checkNow()
        XCTAssertEqual(controller.activity, .idle, "inside the cooldown no request starts")
        XCTAssertEqual(polar.calls.count, 1)
        XCTAssertEqual(controller.lastMessage, LicenseCopy.checkedValid, "it answers from the last result")

        clock.advance(1)
        controller.checkNow()
        await settle(controller)
        XCTAssertEqual(polar.calls.count, 2)
    }

    func testTheCooldownAnswersFromARecordLeftByAnEarlierLaunch() {
        let pending = PendingRevocation(firstSeenAt: origin.addingTimeInterval(-30), reason: .notFound)
        let record = polarRecord(validatedAt: origin.addingTimeInterval(-2 * day),
                                 attemptAt: origin.addingTimeInterval(-30), pending: pending)
        let controller = makeController(store: InMemoryLicenseStore(license: record,
                                                                    trial: trial(startedAt: origin.addingTimeInterval(-20 * day))))
        controller.start()
        controller.checkNow()
        XCTAssertEqual(polar.calls, [])
        XCTAssertEqual(controller.lastMessage,
                       LicenseMessage(tone: .problem, text: LicenseCopy.pendingRevocationLine(pending, backend: .polar)))
    }

    // MARK: - The live clock

    func testContinuousUptimeMovesForward() {
        let first = LicenseController.continuousUptime()
        let second = LicenseController.continuousUptime()
        XCTAssertGreaterThan(first, 0)
        XCTAssertGreaterThanOrEqual(second, first)
    }
}

// MARK: - Private fakes

/// The wall clock and continuous uptime the controller reads; `advance` moves both, a steady clock.
private final class TestClock {
    var wall: Date
    var uptime: TimeInterval

    init(wall: Date, uptime: TimeInterval) {
        self.wall = wall
        self.uptime = uptime
    }

    func advance(_ seconds: TimeInterval) {
        wall = wall.addingTimeInterval(seconds)
        uptime += seconds
    }
}

/// A store whose trial item is present but unreadable (a forged or damaged item with a Keychain creation date), and
/// which refuses to overwrite it, as KeychainLicenseStore does. The license item is readable and absent.
private final class LicenseControllerUnreadableTrialStore: LicenseStoring, @unchecked Sendable {
    private let createdAt: Date
    private let lock = NSLock()
    private var writes = 0

    init(createdAt: Date) {
        self.createdAt = createdAt
    }

    var trialWrites: Int { lock.withLock { writes } }

    func loadLicense() -> Result<LicenseRecord?, LicenseStoreError> { .success(nil) }
    func saveLicense(_ record: LicenseRecord) throws {}
    func deleteLicense() throws {}

    func loadTrial() -> Result<TrialRecord?, LicenseStoreError> {
        .failure(.undecodable(account: "trial.sandbox", createdAt: createdAt))
    }

    func saveTrial(_ record: TrialRecord) throws {
        lock.withLock { writes += 1 }
        throw LicenseStoreError.undecodable(account: "trial.sandbox", createdAt: createdAt)
    }

    func loadGumroadCounted() -> Result<GumroadCountedKeys?, LicenseStoreError> { .success(nil) }
    func saveGumroadCounted(_ keys: GumroadCountedKeys) throws {}
}
#endif
