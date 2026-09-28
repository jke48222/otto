//
//  KeychainLicenseStoreTests.swift
//  OttoTests
//
//  KeychainLicenseStore against the real login keychain, opt-in only: skipped unless OTTO_KEYCHAIN_TESTS=1 (pass
//  TEST_RUNNER_OTTO_KEYCHAIN_TESTS=1 to xcodebuild). Every item lives under a throwaway
//  com.jalenedusei.otto.tests.<UUID> service, never Otto's own, and tearDown deletes all of them.
//

#if OTTO_LICENSING
import Security
import XCTest
@testable import Otto

final class KeychainLicenseStoreTests: XCTestCase {
    private static let servicePrefix = "com.jalenedusei.otto.tests."
    private let origin = Date(timeIntervalSince1970: 1_791_000_000)
    private var service = ""

    override func setUpWithError() throws {
        service = Self.servicePrefix + UUID().uuidString
        // The guard comes first, before anything can reach the Keychain.
        XCTAssertTrue(service.hasPrefix(Self.servicePrefix))
        XCTAssertNotEqual(service, KeychainStore.service)
        guard service.hasPrefix(Self.servicePrefix), service != KeychainStore.service else {
            throw XCTSkip("Refusing to touch a service outside \(Self.servicePrefix)")
        }
        guard ProcessInfo.processInfo.environment["OTTO_KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip("Touches the login keychain. Run with TEST_RUNNER_OTTO_KEYCHAIN_TESTS=1.")
        }
    }

    override func tearDownWithError() throws {
        guard service.hasPrefix(Self.servicePrefix), service != KeychainStore.service,
              ProcessInfo.processInfo.environment["OTTO_KEYCHAIN_TESTS"] == "1" else { return }
        for accounts in [LicenseKeychainAccounts.production, .sandbox] {
            for account in [accounts.license, accounts.trial, accounts.gumroadCounted] {
                try KeychainStore.delete(account: account, service: service)
            }
        }
    }

    private var license: LicenseRecord {
        LicenseRecord(schema: LicenseRecord.currentSchema, backend: .polar, apiHost: "sandbox-api.polar.sh",
                      organizationID: LicenseFixtures.organizationID, benefitID: LicenseFixtures.benefitID,
                      gumroadProductID: nil, key: LicenseFixtures.polarKey, licenseKeyID: LicenseFixtures.licenseKeyID,
                      activationID: LicenseFixtures.activationID, label: "Mac 7F3A",
                      displayKey: LicenseFixtures.polarDisplayKey, seatLimit: 3, activatedAt: origin,
                      lastValidatedAt: origin, lastAttemptAt: origin, pendingRevocation: nil)
    }

    func testTheServiceIsATestService() {
        XCTAssertTrue(service.hasPrefix(Self.servicePrefix))
        let store = KeychainLicenseStore(service: service, accounts: .sandbox)
        XCTAssertEqual(store.service, service)
        XCTAssertEqual(store.accounts, .sandbox)
    }

    func testRoundTrip() throws {
        let store = KeychainLicenseStore(service: service, accounts: .sandbox)
        XCTAssertEqual(store.loadLicense(), .success(nil))
        XCTAssertEqual(store.loadTrial(), .success(nil))
        XCTAssertEqual(store.loadGumroadCounted(), .success(nil))

        let trial = TrialRecord(schema: TrialRecord.currentSchema, startedAt: origin, lastSeenAt: origin,
                                lastLicenseRemoval: nil)
        let counted = GumroadCountedKeys(schema: GumroadCountedKeys.currentSchema, hashes: ["00ff"])
        try store.saveLicense(license)
        try store.saveTrial(trial)
        try store.saveGumroadCounted(counted)
        XCTAssertEqual(store.loadLicense(), .success(license))
        XCTAssertEqual(store.loadTrial(), .success(trial))
        XCTAssertEqual(store.loadGumroadCounted(), .success(counted))

        // The values are the codec's JSON under the configuration's account names.
        XCTAssertEqual(KeychainStore.readResult(account: "license.sandbox", service: service),
                       .success(try LicenseCodec.encode(license)))

        var updated = license
        updated.pendingRevocation = PendingRevocation(firstSeenAt: origin, reason: .notFound)
        try store.saveLicense(updated)
        XCTAssertEqual(store.loadLicense(), .success(updated))

        try store.deleteLicense()
        XCTAssertEqual(store.loadLicense(), .success(nil))
        XCTAssertEqual(store.loadTrial(), .success(trial))
    }

    func testASandboxStoreNeverReadsOrDeletesAProductionItem() throws {
        let planted = try LicenseCodec.encode(license)
        try KeychainStore.write(planted, account: "license", service: service)

        let sandbox = KeychainLicenseStore(service: service, accounts: .sandbox)
        XCTAssertEqual(sandbox.loadLicense(), .success(nil))
        try sandbox.deleteLicense()
        try sandbox.saveLicense(license)
        try sandbox.deleteLicense()
        XCTAssertEqual(KeychainStore.readResult(account: "license", service: service), .success(planted))

        let production = KeychainLicenseStore(service: service, accounts: .production)
        XCTAssertEqual(production.loadLicense(), .success(license))
    }

    func testAnUnparseableTrialReportsItsCreationDateAndIsNeverOverwritten() throws {
        let before = Date().addingTimeInterval(-5)
        try KeychainStore.write("{\"schema\":1,\"startedAt\":", account: "trial.sandbox", service: service)
        let after = Date().addingTimeInterval(5)
        let store = KeychainLicenseStore(service: service, accounts: .sandbox)

        guard case .failure(.undecodable(let account, let createdAt?)) = store.loadTrial() else {
            return XCTFail("expected an undecodable trial with a creation date: \(store.loadTrial())")
        }
        XCTAssertEqual(account, "trial.sandbox")
        XCTAssertGreaterThanOrEqual(createdAt, before)
        XCTAssertLessThanOrEqual(createdAt, after)

        let replacement = TrialRecord(schema: TrialRecord.currentSchema, startedAt: origin, lastSeenAt: origin,
                                      lastLicenseRemoval: nil)
        XCTAssertThrowsError(try store.saveTrial(replacement)) { error in
            guard case .undecodable = error as? LicenseStoreError else {
                return XCTFail("expected .undecodable, got \(error)")
            }
        }
        XCTAssertEqual(KeychainStore.readResult(account: "trial.sandbox", service: service),
                       .success("{\"schema\":1,\"startedAt\":"))
    }

    func testARecordFromANewerSchemaIsNeverOverwritten() throws {
        let newer = "{\"schema\":2,\"startedAt\":\"2026-10-03T00:00:00Z\",\"lastSeenAt\":\"2026-10-03T00:00:00Z\"}"
        try KeychainStore.write(newer, account: "trial.sandbox", service: service)
        let store = KeychainLicenseStore(service: service, accounts: .sandbox)
        guard case .failure(.undecodable) = store.loadTrial() else { return XCTFail("expected .undecodable") }
        let replacement = TrialRecord(schema: TrialRecord.currentSchema, startedAt: origin, lastSeenAt: origin,
                                      lastLicenseRemoval: nil)
        XCTAssertThrowsError(try store.saveTrial(replacement))
        XCTAssertEqual(KeychainStore.readResult(account: "trial.sandbox", service: service), .success(newer))
    }
}
#endif
