//
//  KeychainStore.swift
//  Otto
//
//  Minimal generic-password storage for secrets such as the Anthropic API key and, in the paid build, the
//  license and trial records (§14.9). Items are never synchronizable, so they stay in this Mac's login keychain.
//

import Foundation
import os
import Security

/// A failed Keychain read, write or delete, carrying the Security framework status.
struct KeychainStoreError: LocalizedError, Equatable {
    enum Operation: Equatable { case save, delete, read }

    let status: OSStatus
    var operation: Operation = .save

    var errorDescription: String? {
        let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
        switch operation {
        case .save: return "Couldn't save to the Keychain: \(detail)"
        case .delete: return "Couldn't remove the item from the Keychain: \(detail)"
        case .read: return "Couldn't read from the Keychain: \(detail)"
        }
    }
}

enum KeychainStore {
    static let service = "com.jalenedusei.otto"
    static let apiKeyAccount = "anthropic-api-key"

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Keychain")

    static func read(account: String) -> String? {
        var query = baseQuery(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                logger.error("Keychain item for \(account, privacy: .public) is not UTF-8 text")
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            logger.error("Keychain read for \(account, privacy: .public) failed: \(status)")
            return nil
        }
    }

    /// Like read(account:), but tells "not found" (.success(nil)) from a failure (.failure(KeychainStoreError(status:))).
    /// An item whose data isn't UTF-8 text fails with errSecDecode.
    static func readResult(account: String, service: String = KeychainStore.service) -> Result<String?, KeychainStoreError> {
        var query = baseQuery(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                logger.error("Keychain item for \(account, privacy: .public) is not UTF-8 text")
                return .failure(KeychainStoreError(status: errSecDecode, operation: .read))
            }
            return .success(value)
        case errSecItemNotFound:
            return .success(nil)
        default:
            logger.error("Keychain read for \(account, privacy: .public) failed: \(status)")
            return .failure(KeychainStoreError(status: status, operation: .read))
        }
    }

    /// The item's kSecAttrCreationDate (kSecReturnAttributes); nil when the item is missing or on any error.
    static func creationDate(account: String, service: String = KeychainStore.service) -> Date? {
        var query = baseQuery(account: account, service: service)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                logger.error("Keychain attribute read for \(account, privacy: .public) failed: \(status)")
            }
            return nil
        }
        return (item as? [String: Any])?[kSecAttrCreationDate as String] as? Date
    }

    /// Upserts the value (kSecClassGenericPassword).
    static func write(_ value: String, account: String, service: String = KeychainStore.service) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery(account: account, service: service) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            try add(data, account: account, service: service)
        default:
            logger.error("Keychain update for \(account, privacy: .public) failed: \(status)")
            throw KeychainStoreError(status: status)
        }
    }

    /// Deletes the item. Succeeds when the item is gone afterwards (deleted, or never there);
    /// throws `KeychainStoreError` (operation `.delete`) for any other status.
    static func delete(account: String, service: String = KeychainStore.service) throws {
        let status = SecItemDelete(baseQuery(account: account, service: service) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Keychain delete for \(account, privacy: .public) failed: \(status)")
            throw KeychainStoreError(status: status, operation: .delete)
        }
    }

    private static func add(_ data: Data, account: String, service: String) throws {
        var attributes = baseQuery(account: account, service: service)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "Otto (\(account))"

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Another writer created the item between our update and add; update it instead.
            let retry = SecItemUpdate(baseQuery(account: account, service: service) as CFDictionary,
                                      [kSecValueData as String: data] as CFDictionary)
            guard retry == errSecSuccess else {
                logger.error("Keychain update for \(account, privacy: .public) failed: \(retry)")
                throw KeychainStoreError(status: retry)
            }
        default:
            logger.error("Keychain add for \(account, privacy: .public) failed: \(status)")
            throw KeychainStoreError(status: status)
        }
    }

    /// Internal so KeychainStoreTests can check it. Never contains kSecAttrSynchronizable, which per SecItem.h means
    /// items are neither added nor matched as synchronizable (they never sync through iCloud Keychain).
    static func baseQuery(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
