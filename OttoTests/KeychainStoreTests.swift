//
//  KeychainStoreTests.swift
//  OttoTests
//
//  The Keychain query KeychainStore builds: the service and account it carries, and that it never asks for a
//  synchronizable item. Nothing here reads or writes a Keychain item.
//

import Security
import XCTest
@testable import Otto

final class KeychainStoreTests: XCTestCase {
    func testBaseQueryCarriesThePassedServiceAndAccount() {
        let query = KeychainStore.baseQuery(account: "license.sandbox", service: "com.jalenedusei.otto.tests.query")
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.jalenedusei.otto.tests.query")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "license.sandbox")
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
    }

    func testBaseQueryNeverAsksForSynchronizableItems() {
        for account in [KeychainStore.apiKeyAccount, "license", "trial", "gumroad-counted", "trial.sandbox"] {
            let query = KeychainStore.baseQuery(account: account, service: KeychainStore.service)
            XCTAssertNil(query[kSecAttrSynchronizable as String], account)
            XCTAssertEqual(Set(query.keys), [kSecClass as String, kSecAttrService as String, kSecAttrAccount as String])
        }
    }

    func testTheAPIKeyKeepsTheAppService() {
        XCTAssertEqual(KeychainStore.service, "com.jalenedusei.otto")
        XCTAssertEqual(KeychainStore.apiKeyAccount, "anthropic-api-key")
        let query = KeychainStore.baseQuery(account: KeychainStore.apiKeyAccount, service: KeychainStore.service)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.jalenedusei.otto")
    }

    func testCallSitesWithoutAServiceStillCompile() {
        // Built, never run: the API key's call sites pass no service and must keep compiling against the defaults.
        let calls: [() throws -> Void] = [
            { _ = KeychainStore.read(account: KeychainStore.apiKeyAccount) },
            { _ = KeychainStore.readResult(account: KeychainStore.apiKeyAccount) },
            { _ = KeychainStore.creationDate(account: KeychainStore.apiKeyAccount) },
            { try KeychainStore.write("value", account: KeychainStore.apiKeyAccount) },
            { try KeychainStore.delete(account: KeychainStore.apiKeyAccount) },
        ]
        XCTAssertEqual(calls.count, 5)
    }

    func testReadErrorsDescribeTheRead() {
        let error = KeychainStoreError(status: errSecInteractionNotAllowed, operation: .read)
        XCTAssertTrue(error.errorDescription?.hasPrefix("Couldn't read from the Keychain") ?? false)
        XCTAssertEqual(KeychainStoreError(status: errSecDecode).operation, .save)
    }
}
