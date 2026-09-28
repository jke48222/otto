//
//  KeychainLicenseStore.swift
//  Otto
//
//  The live LicenseStoring (§14.9): the license, trial and Gumroad-counted records as UTF-8 JSON generic-password
//  items in the login keychain, written by LicenseCodec through KeychainStore with the store's `service` on every
//  call and the account names of its configuration (plain names for production only, `.sandbox` names otherwise).
//  An item that is present but can't be read (malformed, or from a newer schema) comes back as `.undecodable` with
//  its Keychain creation date, and this store never overwrites it.
//

#if OTTO_LICENSING
import Foundation
import os
import Security

/// `accounts` comes from `configuration.keychainAccounts` (§14.9); tests pass a `com.jalenedusei.otto.tests.<UUID>`
/// service. Every Keychain call passes `service` through (§14.4.5).
final class KeychainLicenseStore: LicenseStoring {
    let service: String
    let accounts: LicenseKeychainAccounts

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "License")

    init(service: String = KeychainStore.service, accounts: LicenseKeychainAccounts) {
        self.service = service
        self.accounts = accounts
    }

    func loadLicense() -> Result<LicenseRecord?, LicenseStoreError> {
        load(LicenseRecord.self, account: accounts.license)
    }

    func saveLicense(_ record: LicenseRecord) throws {
        try save(record, account: accounts.license)
    }

    func deleteLicense() throws {
        do {
            try KeychainStore.delete(account: accounts.license, service: service)
        } catch let error as KeychainStoreError {
            throw LicenseStoreError.keychain(error.status)
        }
    }

    func loadTrial() -> Result<TrialRecord?, LicenseStoreError> {
        load(TrialRecord.self, account: accounts.trial)
    }

    func saveTrial(_ record: TrialRecord) throws {
        try save(record, account: accounts.trial)
    }

    func loadGumroadCounted() -> Result<GumroadCountedKeys?, LicenseStoreError> {
        load(GumroadCountedKeys.self, account: accounts.gumroadCounted)
    }

    func saveGumroadCounted(_ keys: GumroadCountedKeys) throws {
        try save(keys, account: accounts.gumroadCounted)
    }

    // MARK: - Private

    private func load<T: Decodable & LicenseSchemaVersioned>(_ type: T.Type,
                                                             account: String) -> Result<T?, LicenseStoreError> {
        switch KeychainStore.readResult(account: account, service: service) {
        case .success(nil):
            return .success(nil)
        case .success(let text?):
            do {
                return .success(try LicenseCodec.decode(type, from: text, account: account))
            } catch {
                return .failure(undecodable(account))
            }
        case .failure(let error) where error.status == errSecDecode:
            // readResult's answer for an item whose data isn't UTF-8 text: present, but unreadable.
            return .failure(undecodable(account))
        case .failure(let error):
            return .failure(.keychain(error.status))
        }
    }

    /// Writes only over nothing or over an item this version can read: an unreadable item is never overwritten, and
    /// a failed read writes nothing.
    private func save<T: Codable & LicenseSchemaVersioned>(_ value: T, account: String) throws {
        if case .failure(let error) = load(T.self, account: account) {
            Self.logger.error("Not writing the \(account, privacy: .public) item: the existing one can't be read")
            throw error
        }
        let text: String
        do {
            text = try LicenseCodec.encode(value)
        } catch {
            Self.logger.fault("Couldn't encode the \(account, privacy: .public) record")
            throw LicenseStoreError.keychain(errSecParam)
        }
        do {
            try KeychainStore.write(text, account: account, service: service)
        } catch let error as KeychainStoreError {
            throw LicenseStoreError.keychain(error.status)
        }
    }

    private func undecodable(_ account: String) -> LicenseStoreError {
        Self.logger.error("The \(account, privacy: .public) item can't be read by this version of Otto")
        return .undecodable(account: account, createdAt: KeychainStore.creationDate(account: account, service: service))
    }
}
#endif
