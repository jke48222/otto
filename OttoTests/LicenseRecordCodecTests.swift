//
//  LicenseRecordCodecTests.swift
//  OttoTests
//
//  The Keychain records' JSON (§14.9): round trips including the record's own host and IDs, sorted keys, ISO 8601
//  UTC dates, nil fields left out, and a newer or malformed record reported as undecodable.
//

#if OTTO_LICENSING
import XCTest
@testable import Otto

final class LicenseRecordCodecTests: XCTestCase {
    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    private func polarRecord() throws -> LicenseRecord {
        LicenseRecord(schema: 1, backend: .polar, apiHost: "api.polar.sh",
                      organizationID: LicenseFixtures.organizationID, benefitID: LicenseFixtures.benefitID,
                      gumroadProductID: nil, key: LicenseFixtures.polarKey, licenseKeyID: LicenseFixtures.licenseKeyID,
                      activationID: LicenseFixtures.activationID, label: "Mac 7F3A",
                      displayKey: LicenseFixtures.polarDisplayKey, seatLimit: 3,
                      activatedAt: try date("2026-10-12T14:03:00Z"), lastValidatedAt: try date("2026-10-13T09:12:44Z"),
                      lastAttemptAt: try date("2026-10-13T09:12:44Z"), pendingRevocation: nil)
    }

    func testPolarRecordMatchesTheDocumentedJSON() throws {
        let text = try LicenseCodec.encode(try polarRecord())
        let expected = #"{"activatedAt":"2026-10-12T14:03:00Z","activationID":"b6724bc8-7ad9-4ca0-b143-7c896fcbb6fe","#
            + #""apiHost":"api.polar.sh","backend":"polar","benefitID":"\#(LicenseFixtures.benefitID)","#
            + #""displayKey":"****-E304DA","key":"OTTO-1C285B2D-6CE6-4BC7-B8BE-ADB6A7E304DA","label":"Mac 7F3A","#
            + #""lastAttemptAt":"2026-10-13T09:12:44Z","lastValidatedAt":"2026-10-13T09:12:44Z","#
            + #""licenseKeyID":"508176f7-065a-4b5d-b524-4e9c8a11ed63","#
            + #""organizationID":"\#(LicenseFixtures.organizationID)","schema":1,"seatLimit":3}"#
        XCTAssertEqual(text, expected)
    }

    func testPolarRecordRoundTripsWithItsHostAndIDs() throws {
        var record = try polarRecord()
        record.apiHost = "sandbox-api.polar.sh"
        record.pendingRevocation = PendingRevocation(firstSeenAt: try date("2026-10-14T08:00:00Z"), reason: .notFound)
        let text = try LicenseCodec.encode(record)
        XCTAssertTrue(text.contains(#""pendingRevocation":{"firstSeenAt":"2026-10-14T08:00:00Z","reason":"notFound"}"#))
        let decoded = try LicenseCodec.decode(LicenseRecord.self, from: text, account: "license.sandbox")
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.apiHost, "sandbox-api.polar.sh")
        XCTAssertEqual(decoded.organizationID, LicenseFixtures.organizationID)
        XCTAssertEqual(decoded.benefitID, LicenseFixtures.benefitID)
        XCTAssertNil(decoded.gumroadProductID)
    }

    func testGumroadRecordRoundTripsAndOmitsNilFields() throws {
        let record = LicenseRecord(schema: 1, backend: .gumroad, apiHost: "api.gumroad.com", organizationID: nil,
                                   benefitID: nil, gumroadProductID: LicenseFixtures.gumroadProductID,
                                   key: LicenseFixtures.gumroadKey, licenseKeyID: nil, activationID: nil, label: "",
                                   displayKey: "****-7E8F90", seatLimit: 6,
                                   activatedAt: try date("2026-10-12T14:03:00Z"),
                                   lastValidatedAt: try date("2026-10-12T14:03:00Z"), lastAttemptAt: nil,
                                   pendingRevocation: nil)
        let text = try LicenseCodec.encode(record)
        for omitted in ["organizationID", "benefitID", "licenseKeyID", "activationID", "lastAttemptAt", "pendingRevocation"] {
            XCTAssertFalse(text.contains("\"\(omitted)\""), omitted)
        }
        XCTAssertTrue(text.contains(#""gumroadProductID":"OttoFixtureProduct==""#))
        XCTAssertTrue(text.contains(#""backend":"gumroad""#))
        XCTAssertEqual(try LicenseCodec.decode(LicenseRecord.self, from: text, account: "license"), record)
    }

    func testKeysAreSorted() throws {
        let text = try LicenseCodec.encode(try polarRecord())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let keys = object.keys.sorted()
        let positions = keys.compactMap { text.range(of: "\"\($0)\":")?.lowerBound }
        XCTAssertEqual(positions.count, keys.count)
        XCTAssertEqual(positions, positions.sorted())
    }

    func testTrialRecordMatchesTheDocumentedJSON() throws {
        let trial = TrialRecord(schema: 1, startedAt: try date("2026-10-05T18:40:02Z"),
                                lastSeenAt: try date("2026-10-13T09:12:44Z"), lastLicenseRemoval: nil)
        let text = try LicenseCodec.encode(trial)
        XCTAssertEqual(text, #"{"lastSeenAt":"2026-10-13T09:12:44Z","schema":1,"startedAt":"2026-10-05T18:40:02Z"}"#)
        XCTAssertEqual(try LicenseCodec.decode(TrialRecord.self, from: text, account: "trial"), trial)
    }

    func testTrialRecordRoundTripsARemoval() throws {
        let removal = LicenseRemoval(at: try date("2026-10-08T10:00:00Z"), reason: .deactivatedByUser)
        let trial = TrialRecord(schema: 1, startedAt: try date("2026-10-05T18:40:02Z"),
                                lastSeenAt: try date("2026-10-13T09:12:44Z"), lastLicenseRemoval: removal)
        let text = try LicenseCodec.encode(trial)
        XCTAssertTrue(text.contains(#""lastLicenseRemoval":{"at":"2026-10-08T10:00:00Z","reason":"deactivatedByUser"}"#))
        XCTAssertEqual(try LicenseCodec.decode(TrialRecord.self, from: text, account: "trial"), trial)
    }

    func testGumroadCountedKeysRoundTrip() throws {
        let keys = GumroadCountedKeys(schema: 1, hashes: ["0a1b", "ff00"])
        let text = try LicenseCodec.encode(keys)
        XCTAssertEqual(text, #"{"hashes":["0a1b","ff00"],"schema":1}"#)
        XCTAssertEqual(try LicenseCodec.decode(GumroadCountedKeys.self, from: text, account: "gumroad-counted"), keys)
    }

    func testANewerSchemaIsUndecodable() throws {
        let text = #"{"lastSeenAt":"2026-10-13T09:12:44Z","schema":2,"startedAt":"2026-10-05T18:40:02Z"}"#
        XCTAssertThrowsError(try LicenseCodec.decode(TrialRecord.self, from: text, account: "trial")) { error in
            XCTAssertEqual(error as? LicenseStoreError, .undecodable(account: "trial", createdAt: nil))
        }
        // A newer record whose shape changed too is still reported as newer, never as a decoding crash.
        XCTAssertThrowsError(try LicenseCodec.decode(LicenseRecord.self, from: #"{"schema":2,"v2":true}"#,
                                                     account: "license")) { error in
            XCTAssertEqual(error as? LicenseStoreError, .undecodable(account: "license", createdAt: nil))
        }
    }

    func testMalformedTextIsUndecodable() {
        for text in ["", "not json", #"{"schema":1}"#, #"{"schema":"1"}"#, #"[1,2]"#,
                     #"{"lastSeenAt":"yesterday","schema":1,"startedAt":"2026-10-05T18:40:02Z"}"#] {
            XCTAssertThrowsError(try LicenseCodec.decode(TrialRecord.self, from: text, account: "trial.sandbox"), text) { error in
                XCTAssertEqual(error as? LicenseStoreError, .undecodable(account: "trial.sandbox", createdAt: nil))
            }
        }
    }

    func testRemovalReasonsFromGoneReasons() {
        XCTAssertEqual(LicenseRemovalReason(.notFound), .revoked)
        XCTAssertEqual(LicenseRemovalReason(.refunded), .refunded)
        XCTAssertEqual(LicenseRemovalReason(.chargedBack), .chargedBack)
        XCTAssertEqual(LicenseRemovalReason(.disabled), .disabled)
        XCTAssertEqual(LicenseRemovalReason(.wrongProduct), .wrongProduct)
        XCTAssertEqual(LicenseBackendKind.polar.displayName, "Polar")
        XCTAssertEqual(LicenseBackendKind.gumroad.displayName, "Gumroad")
    }

    func testKeychainAccountNames() {
        XCTAssertEqual(LicenseKeychainAccounts.production,
                       LicenseKeychainAccounts(license: "license", trial: "trial", gumroadCounted: "gumroad-counted"))
        XCTAssertEqual(LicenseKeychainAccounts.sandbox,
                       LicenseKeychainAccounts(license: "license.sandbox", trial: "trial.sandbox",
                                               gumroadCounted: "gumroad-counted.sandbox"))
    }
}
#endif
