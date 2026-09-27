//
//  SensitiveApps.swift
//  Otto
//
//  Apps whose content Otto never reads: password managers and Keychain Access. One list serves
//  selection reads, the window chip and window captures.
//

import Foundation

/// Apps whose content Otto never reads — one list for selection reads, window chips and window captures.
enum SensitiveApps {
    /// 1Password (com.1password.1password, com.agilebits.onepassword7), Bitwarden (com.bitwarden.desktop),
    /// Keychain Access (com.apple.keychainaccess), Passwords (com.apple.Passwords), LastPass (com.lastpass.LastPass),
    /// KeePassXC (org.keepassxc.keepassxc), Enpass (in.sinew.Enpass-Desktop), Proton Pass (me.proton.pass.electron),
    /// Dashlane (com.dashlane.dashlanephonefinal) — verified with `osascript -e 'id of app "…"'` before release (R5).
    static let bundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.lastpass.LastPass",
        "org.keepassxc.keepassxc",
        "in.sinew.Enpass-Desktop",
        "me.proton.pass.electron",
        "com.dashlane.dashlanephonefinal",
    ]

    /// Words in an app's name that mark it as a password manager, whatever its bundle identifier.
    private static let nameMarkers = ["password", "keychain", "1password", "bitwarden", "keepass", "lastpass",
                                      "dashlane", "enpass"]

    /// Bundle identifiers compare case-insensitively, like Launch Services does.
    private static let lowercasedBundleIDs = Set(bundleIDs.map { $0.lowercased() })

    /// bundle id match, or localized name matching /password|keychain|1password|bitwarden|keepass|lastpass|dashlane|enpass/i.
    static func contains(_ app: AppRef) -> Bool {
        if let bundleID = app.bundleID, lowercasedBundleIDs.contains(bundleID.lowercased()) { return true }
        let name = app.name.lowercased()
        return nameMarkers.contains { name.contains($0) }
    }
}
