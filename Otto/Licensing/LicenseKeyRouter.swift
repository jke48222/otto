//
//  LicenseKeyRouter.swift
//  Otto
//
//  Cleans up a pasted license key and decides which store may see it. Polar and Gumroad keys have shapes that
//  can't overlap, so a key of one shape is only ever sent to its own store (§14.5 activation).
//

#if OTTO_LICENSING
import Foundation

enum LicenseKeyRouter {
    static let maximumKeyLength = 128

    /// Trims, removes spaces, tabs and line breaks inside the key (mail clients wrap keys); never changes case.
    /// nil when empty or longer than 128 characters.
    static func normalize(_ raw: String) -> String? {
        let key = String(raw.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard !key.isEmpty, key.count <= maximumKeyLength else { return nil }
        return key
    }

    /// Case-insensitive: ^(?:[A-Za-z0-9]{1,24}-)?[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$
    /// (Polar generates "<PREFIX>-<UUID>", uppercase: "OTTO-1C285B2D-6CE6-4BC7-B8BE-ADB6A7E304DA"; a bare UUID when the
    /// benefit has no prefix.)
    static func looksLikePolar(_ key: String) -> Bool {
        matchesWhole(key, polarShape)
    }

    /// Case-insensitive: ^[0-9A-F]{8}-[0-9A-F]{8}-[0-9A-F]{8}-[0-9A-F]{8}$ (the two shapes can't overlap)
    static func looksLikeGumroad(_ key: String) -> Bool {
        matchesWhole(key, gumroadShape)
    }

    /// Polar shape → [.polar] only; Gumroad shape → [.gumroad] only; neither shape → [.polar, .gumroad]; kinds not in
    /// `enabled` drop out. A Polar-shaped key is never sent to Gumroad and a Gumroad-shaped key never to Polar.
    static func candidates(for key: String, enabled: Set<LicenseBackendKind>) -> [LicenseBackendKind] {
        let shaped: [LicenseBackendKind]
        if looksLikePolar(key) {
            shaped = [.polar]
        } else if looksLikeGumroad(key) {
            shaped = [.gumroad]
        } else {
            shaped = [.polar, .gumroad]
        }
        return shaped.filter(enabled.contains)
    }

    /// "****-" + the last 6 characters (Polar's own display_key format), used for Gumroad keys.
    static func displayKey(for key: String) -> String {
        "****-" + key.suffix(6)
    }

    /// "Mac " + 4 uppercase hex digits from SystemRandomNumberGenerator ("Mac 7F3A").
    static func randomLabel() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = UInt16.random(in: .min ... .max, using: &generator)
        return "Mac " + String(format: "%04X", value)
    }

    // MARK: - Private

    private static let polarShape = makeExpression(
        "^(?:[A-Za-z0-9]{1,24}-)?[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")
    private static let gumroadShape = makeExpression("^[0-9A-F]{8}-[0-9A-F]{8}-[0-9A-F]{8}-[0-9A-F]{8}$")

    private static func makeExpression(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// The whole key must match: `$` alone would also accept a key followed by one line break.
    private static func matchesWhole(_ key: String, _ expression: NSRegularExpression?) -> Bool {
        guard let expression else { return false }
        let range = NSRange(key.startIndex..., in: key)
        return expression.firstMatch(in: key, range: range)?.range == range
    }
}
#endif
