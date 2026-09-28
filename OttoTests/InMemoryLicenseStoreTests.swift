//
//  InMemoryLicenseStoreTests.swift
//  OttoTests
//
//  The in-memory LicenseStoring: empty and seeded loads, round trips of the three records, delete, and an injected
//  failure that makes every load fail and every save or delete throw without changing anything.
//

#if OTTO_LICENSING
import Security
import XCTest
@testable import Otto

final class InMemoryLicenseStoreTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_791_000_000)

    private var license: LicenseRecord {
        LicenseRecord(schema: LicenseRecord.currentSchema, backend: .polar, apiHost: "api.polar.sh",
                      organizationID: LicenseFixtures.organizationID, benefitID: LicenseFixtures.benefitID,
                      gumroadProductID: nil, key: LicenseFixtures.polarKey, licenseKeyID: LicenseFixtures.licenseKeyID,
                      activationID: LicenseFixtures.activationID, label: "Mac 7F3A",
                      displayKey: LicenseFixtures.polarDisplayKey, seatLimit: 3, activatedAt: origin,
                      lastValidatedAt: origin, lastAttemptAt: origin, pendingRevocation: nil)
    }

    private var trial: TrialRecord {
        TrialRecord(schema: TrialRecord.currentSchema, startedAt: origin, lastSeenAt: origin.addingTimeInterval(60),
                    lastLicenseRemoval: LicenseRemoval(at: origin, reason: .refunded))
    }

    private let counted = GumroadCountedKeys(schema: GumroadCountedKeys.currentSchema, hashes: ["a1", "b2"])

    func testAnEmptyStoreHasNoRecords() {
        let store = InMemoryLicenseStore()
        XCTAssertEqual(store.loadLicense(), .success(nil))
        XCTAssertEqual(store.loadTrial(), .success(nil))
        XCTAssertEqual(store.loadGumroadCounted(), .success(nil))
        XCTAssertNil(store.failure)
    }

    func testASeededStoreLoadsItsRecords() {
        let store = InMemoryLicenseStore(license: license, trial: trial, counted: counted)
        XCTAssertEqual(store.loadLicense(), .success(license))
        XCTAssertEqual(store.loadTrial(), .success(trial))
        XCTAssertEqual(store.loadGumroadCounted(), .success(counted))
    }

    func testRoundTripsAndDelete() throws {
        let store = InMemoryLicenseStore()
        try store.saveLicense(license)
        try store.saveTrial(trial)
        try store.saveGumroadCounted(counted)
        XCTAssertEqual(store.loadLicense(), .success(license))
        XCTAssertEqual(store.loadTrial(), .success(trial))
        XCTAssertEqual(store.loadGumroadCounted(), .success(counted))

        var updated = license
        updated.pendingRevocation = PendingRevocation(firstSeenAt: origin, reason: .notFound)
        try store.saveLicense(updated)
        XCTAssertEqual(store.loadLicense(), .success(updated))

        try store.deleteLicense()
        XCTAssertEqual(store.loadLicense(), .success(nil))
        XCTAssertEqual(store.loadTrial(), .success(trial), "deleting the license leaves the trial record")
        try store.deleteLicense()
        XCTAssertEqual(store.loadLicense(), .success(nil), "deleting nothing succeeds")
    }

    func testAnInjectedFailureFailsEveryLoadAndEveryWrite() {
        let failure = LicenseStoreError.keychain(errSecInteractionNotAllowed)
        let store = InMemoryLicenseStore(license: license, trial: trial, counted: counted, failure: failure)
        XCTAssertEqual(store.loadLicense(), .failure(failure))
        XCTAssertEqual(store.loadTrial(), .failure(failure))
        XCTAssertEqual(store.loadGumroadCounted(), .failure(failure))

        XCTAssertThrowsError(try store.saveLicense(license)) { XCTAssertEqual($0 as? LicenseStoreError, failure) }
        XCTAssertThrowsError(try store.deleteLicense()) { XCTAssertEqual($0 as? LicenseStoreError, failure) }
        XCTAssertThrowsError(try store.saveTrial(trial)) { XCTAssertEqual($0 as? LicenseStoreError, failure) }
        XCTAssertThrowsError(try store.saveGumroadCounted(counted)) {
            XCTAssertEqual($0 as? LicenseStoreError, failure)
        }

        // Clearing the failure shows the records exactly as they were.
        store.failure = nil
        XCTAssertEqual(store.loadLicense(), .success(license))
        XCTAssertEqual(store.loadTrial(), .success(trial))
        XCTAssertEqual(store.loadGumroadCounted(), .success(counted))
    }

    func testAFailureSetLaterStopsWritesAndAnUndecodableFailureIsReported() throws {
        let store = InMemoryLicenseStore()
        let failure = LicenseStoreError.undecodable(account: "trial.sandbox", createdAt: origin)
        store.failure = failure
        XCTAssertEqual(store.loadTrial(), .failure(failure))
        XCTAssertThrowsError(try store.saveTrial(trial))
        store.failure = nil
        XCTAssertEqual(store.loadTrial(), .success(nil), "the refused write changed nothing")
        try store.saveTrial(trial)
        XCTAssertEqual(store.loadTrial(), .success(trial))
    }

    func testConcurrentWritesAreSafe() {
        let store = InMemoryLicenseStore()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let keys = GumroadCountedKeys(schema: GumroadCountedKeys.currentSchema, hashes: ["\(index)"])
            try? store.saveGumroadCounted(keys)
            _ = store.loadGumroadCounted()
        }
        guard case .success(let keys?) = store.loadGumroadCounted() else { return XCTFail("expected a record") }
        XCTAssertEqual(keys.hashes.count, 1)
    }
}
#endif
