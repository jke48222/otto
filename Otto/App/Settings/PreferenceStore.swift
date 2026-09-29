//
//  PreferenceStore.swift
//  Otto
//
//  Typed reads and writes over UserDefaults for the settings groups. Reads fall back to a default when a
//  key is missing or holds the wrong type, and clamp numbers to their range.
//

import Foundation
import os

struct PreferenceStore {
    let defaults: UserDefaults

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Settings")

    func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    func int(_ key: String, _ fallback: Int, in range: ClosedRange<Int>? = nil) -> Int {
        let value = (defaults.object(forKey: key) as? NSNumber)?.intValue ?? fallback
        guard let range else { return value }
        return Self.clamp(value, to: range)
    }

    func double(_ key: String, _ fallback: Double, in range: ClosedRange<Double>? = nil) -> Double {
        var value = (defaults.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
        if !value.isFinite { value = fallback }
        guard let range else { return value }
        return Self.clamp(value, to: range)
    }

    func string(_ key: String, _ fallback: String) -> String {
        defaults.object(forKey: key) as? String ?? fallback
    }

    func strings(_ key: String, _ fallback: [String]) -> [String] {
        defaults.object(forKey: key) as? [String] ?? fallback
    }

    func value<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
        guard let raw = defaults.object(forKey: key) as? String else { return fallback }
        return T(rawValue: raw) ?? fallback
    }

    func decoded<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let data = defaults.object(forKey: key) as? Data else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Self.logger.error("Couldn't decode the preference \(key, privacy: .public): \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// nil removes the key.
    func set(_ value: Any?, _ key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// JSONEncoder, sorted keys. nil removes the key.
    func setEncoded<T: Encodable>(_ value: T?, _ key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            defaults.set(try encoder.encode(value), forKey: key)
        } catch {
            Self.logger.error("Couldn't encode the preference \(key, privacy: .public): \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
