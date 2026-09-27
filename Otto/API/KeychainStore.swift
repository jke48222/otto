//
//  KeychainStore.swift
//  Otto
//
//  Minimal generic-password storage for secrets such as the Anthropic API key.
//

import Foundation
import os
import Security

/// A failed Keychain write or delete, carrying the Security framework status.
struct KeychainStoreError: LocalizedError, Equatable {
    enum Operation: Equatable { case save, delete }

    let status: OSStatus
    var operation: Operation = .save

    var errorDescription: String? {
        let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
        switch operation {
        case .save: return "Couldn't save to the Keychain: \(detail)"
        case .delete: return "Couldn't remove the item from the Keychain: \(detail)"
        }
    }
}

enum KeychainStore {
    static let service = "com.jalenedusei.otto"
    static let apiKeyAccount = "anthropic-api-key"

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Keychain")

    static func read(account: String) -> String? {
        var query = baseQuery(account: account)
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

    /// Upserts the value (kSecClassGenericPassword).
    static func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            try add(data, account: account)
        default:
            logger.error("Keychain update for \(account, privacy: .public) failed: \(status)")
            throw KeychainStoreError(status: status)
        }
    }

    /// Deletes the item. Succeeds when the item is gone afterwards (deleted, or never there);
    /// throws `KeychainStoreError` (operation `.delete`) for any other status.
    static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Keychain delete for \(account, privacy: .public) failed: \(status)")
            throw KeychainStoreError(status: status, operation: .delete)
        }
    }

    private static func add(_ data: Data, account: String) throws {
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "Otto (\(account))"

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Another writer created the item between our update and add; update it instead.
            let retry = SecItemUpdate(baseQuery(account: account) as CFDictionary,
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

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
