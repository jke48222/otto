//
//  AppSettings.swift
//  Otto
//
//  User preferences. Everything except the API key persists to UserDefaults under `otto.` keys;
//  the API key lives in the Keychain and is cached in memory.
//

import Foundation
import Observation
import Security
import ServiceManagement
import os

@MainActor @Observable final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let model = "otto.model"
        static let effort = "otto.effort"
        static let webAccess = "otto.webAccess"
        static let suggestBrowserTab = "otto.suggestBrowserTab"
        static let autoAttachBrowserTab = "otto.autoAttachBrowserTab"
        static let hotKeyEnabled = "otto.hotKeyEnabled"
        static let showMenuBarIcon = "otto.showMenuBarIcon"
        static let launchAtLogin = "otto.launchAtLogin"
        static let customInstructions = "otto.customInstructions"
    }

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Settings")

    // Stored properties are deliberately declared without default values: with @Observable, an
    // assignment in `init` to a property that has a default runs its `didSet`, which would write
    // every value straight back to UserDefaults (and poke the Keychain / SMAppService) on launch.

    var model: ModelOption {
        didSet { defaults.set(model.rawValue, forKey: Key.model) }
    }

    var effort: EffortLevel {
        didSet { defaults.set(effort.rawValue, forKey: Key.effort) }
    }

    var webAccess: Bool {
        didSet { defaults.set(webAccess, forKey: Key.webAccess) }
    }

    /// Show a ghost chip for the browser tab the user is looking at when the notch opens.
    var suggestBrowserTab: Bool {
        didSet { defaults.set(suggestBrowserTab, forKey: Key.suggestBrowserTab) }
    }

    /// Attach the current browser tab directly instead of suggesting it.
    var autoAttachBrowserTab: Bool {
        didSet { defaults.set(autoAttachBrowserTab, forKey: Key.autoAttachBrowserTab) }
    }

    /// ⌥Space toggles the notch.
    var hotKeyEnabled: Bool {
        didSet { defaults.set(hotKeyEnabled, forKey: Key.hotKeyEnabled) }
    }

    var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
    }

    /// Mirrors `SMAppService.mainApp`. Setting it registers / unregisters the login item and reverts
    /// (with `lastSettingsError` set) when the system refuses.
    var launchAtLogin: Bool {
        didSet { launchAtLoginDidChange(from: oldValue) }
    }

    var customInstructions: String {
        didSet { defaults.set(customInstructions, forKey: Key.customInstructions) }
    }

    /// The user's Anthropic API key. Keychain-backed; assigning "" removes it from the Keychain.
    /// Surrounding whitespace (common when pasting) is stripped.
    var apiKey: String {
        didSet { apiKeyDidChange() }
    }

    /// User-facing description of the last settings operation that failed, if any.
    var lastSettingsError: String?

    /// The Keychain key, else `ANTHROPIC_API_KEY` from the environment, else nil.
    var resolvedAPIKey: String? {
        let stored = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        return environmentAPIKey
    }

    var hasAPIKey: Bool { resolvedAPIKey != nil }

    @ObservationIgnored private let defaults: UserDefaults
    /// False for throwaway settings (the promo stage): the API key then lives only in memory and the
    /// Keychain is never read or written.
    @ObservationIgnored private let usesKeychain: Bool
    @ObservationIgnored private let environmentAPIKey: String?
    /// The value currently stored in the Keychain, so redundant writes are skipped.
    @ObservationIgnored private var persistedAPIKey: String
    /// Set while `launchAtLogin` is being reverted so its `didSet` does not re-run the registration.
    @ObservationIgnored private var isRevertingLaunchAtLogin = false

    init(defaults: UserDefaults = .standard, usesKeychain: Bool = true) {
        self.defaults = defaults
        self.usesKeychain = usesKeychain

        model = defaults.string(forKey: Key.model).flatMap(ModelOption.init(rawValue:)) ?? .opus5
        effort = defaults.string(forKey: Key.effort).flatMap(EffortLevel.init(rawValue:)) ?? .medium
        webAccess = Self.bool(defaults, Key.webAccess, default: true)
        suggestBrowserTab = Self.bool(defaults, Key.suggestBrowserTab, default: true)
        autoAttachBrowserTab = Self.bool(defaults, Key.autoAttachBrowserTab, default: false)
        hotKeyEnabled = Self.bool(defaults, Key.hotKeyEnabled, default: true)
        showMenuBarIcon = Self.bool(defaults, Key.showMenuBarIcon, default: true)
        customInstructions = defaults.string(forKey: Key.customInstructions) ?? ""

        // The login item can be removed in System Settings behind our back, so the system is the
        // source of truth; the stored value is only kept in sync for completeness.
        let registered = Self.isLoginItemRegistered()
        launchAtLogin = registered
        if defaults.object(forKey: Key.launchAtLogin) as? Bool != registered {
            defaults.set(registered, forKey: Key.launchAtLogin)
        }

        let storedKey = !usesKeychain ? "" : KeychainStore.read(account: KeychainStore.apiKeyAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        apiKey = storedKey
        persistedAPIKey = storedKey

        let environmentKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        environmentAPIKey = environmentKey.isEmpty ? nil : environmentKey
    }

    // MARK: - API key

    private func apiKeyDidChange() {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized != apiKey {
            // With @Observable this re-enters didSet; the persisted-value check below makes the
            // nested and the outer call agree, whichever of them runs first.
            apiKey = normalized
        }
        persistAPIKey(normalized)
    }

    private func persistAPIKey(_ normalized: String) {
        guard normalized != persistedAPIKey else { return }
        guard usesKeychain else {
            persistedAPIKey = normalized
            return
        }

        if normalized.isEmpty {
            do {
                try Self.deleteStoredAPIKey()
                persistedAPIKey = ""
                lastSettingsError = nil
            } catch {
                // The key is still stored and would come back on the next launch; say so instead of
                // reporting it removed. `persistedAPIKey` keeps the stored value, so removing again retries.
                Self.logger.error("Keychain delete failed: \(error.localizedDescription, privacy: .public)")
                let detail = (error as? KeychainStoreError).flatMap { SecCopyErrorMessageString($0.status, nil) as String? }
                    ?? error.localizedDescription
                lastSettingsError = "Couldn't remove your API key from the Keychain (\(detail)). "
                    + "Otto won't use it until you quit, but it will be used again next time Otto starts."
            }
            return
        }
        do {
            try KeychainStore.write(normalized, account: KeychainStore.apiKeyAccount)
            persistedAPIKey = normalized
            lastSettingsError = nil
        } catch {
            // Keep the key in memory so Otto still works for this session.
            Self.logger.error("Keychain write failed: \(error.localizedDescription, privacy: .public)")
            lastSettingsError = "Couldn't save your API key to the Keychain (\(error.localizedDescription)). "
                + "Otto will use it until you quit."
        }
    }

    /// Deletes the stored API key, throwing unless the item is gone afterwards (deleted, or never
    /// there).
    private static func deleteStoredAPIKey() throws {
        try KeychainStore.delete(account: KeychainStore.apiKeyAccount)
    }

    // MARK: - Launch at login

    private func launchAtLoginDidChange(from oldValue: Bool) {
        guard !isRevertingLaunchAtLogin, launchAtLogin != oldValue else { return }

        let service = SMAppService.mainApp
        let enable = launchAtLogin
        do {
            if enable {
                if service.status != .enabled {
                    try service.register()
                }
                if service.status == .requiresApproval {
                    lastSettingsError = "Allow Otto in System Settings → General → Login Items to finish "
                        + "turning on launch at login."
                } else {
                    lastSettingsError = nil
                }
            } else {
                if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                }
                lastSettingsError = nil
            }
            defaults.set(enable, forKey: Key.launchAtLogin)
        } catch {
            Self.logger.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
            lastSettingsError = enable
                ? "Couldn't turn on launch at login: \(error.localizedDescription)"
                : "Couldn't turn off launch at login: \(error.localizedDescription)"
            isRevertingLaunchAtLogin = true
            launchAtLogin = oldValue
            isRevertingLaunchAtLogin = false
        }
    }

    private static func isLoginItemRegistered() -> Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Helpers

    private static func bool(_ defaults: UserDefaults, _ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }
}
