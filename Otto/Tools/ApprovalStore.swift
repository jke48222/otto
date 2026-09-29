//
//  ApprovalStore.swift
//  Otto
//
//  What the user has already agreed to: one-time consents for reads ("Read your calendar") and the
//  narrow "Always allow" scopes (one named shortcut each). Stored in UserDefaults as raw keys only,
//  never inputs or outputs; listed and revocable in Settings.
//

import Foundation
import Observation
import os

struct RememberedApproval: Codable, Identifiable, Equatable, Sendable {
    var id: String { scope.toolName + "|" + scope.key }
    let scope: ApprovalScope
    let grantedAt: Date
}

@MainActor @Observable final class ApprovalStore {
    /// [String] consent raw values.
    static let consentsKey = "otto.actions.consents"
    /// JSON [RememberedApproval].
    static let rememberedKey = "otto.actions.rememberedApprovals"

    /// Sorted by label.
    private(set) var consents: [ConsentKey]
    /// Newest first.
    private(set) var remembered: [RememberedApproval]

    @ObservationIgnored private let defaults: UserDefaults

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Tools")

    /// Labels for the consents Otto's own tools ask for. Only raw values are stored, so a consent read back
    /// from UserDefaults gets its label here (an unknown raw value is shown as itself).
    private static let knownConsentLabels: [String: String] = [
        "calendar.read": "Read your calendar",
        "reminders.read": "Read your reminders",
        "shortcuts.list": "See your shortcut names",
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let rawConsents = defaults.stringArray(forKey: Self.consentsKey) ?? []
        consents = Self.sortedConsents(Set(rawConsents).map {
            ConsentKey(rawValue: $0, label: Self.knownConsentLabels[$0] ?? $0)
        })
        remembered = Self.loadRemembered(from: defaults)
    }

    func hasConsent(_ key: ConsentKey) -> Bool {
        consents.contains { $0.rawValue == key.rawValue }
    }

    func grantConsent(_ key: ConsentKey) {
        guard !hasConsent(key) else { return }
        consents = Self.sortedConsents(consents + [key])
        persistConsents()
        Self.logger.info("Consent granted: \(key.rawValue, privacy: .public)")
    }

    func revokeConsent(_ key: ConsentKey) {
        guard hasConsent(key) else { return }
        consents.removeAll { $0.rawValue == key.rawValue }
        persistConsents()
        Self.logger.info("Consent revoked: \(key.rawValue, privacy: .public)")
    }

    func isRemembered(_ scope: ApprovalScope) -> Bool {
        remembered.contains { $0.scope.toolName == scope.toolName && $0.scope.key == scope.key }
    }

    func remember(_ scope: ApprovalScope) {
        guard !isRemembered(scope) else { return }
        remembered.insert(RememberedApproval(scope: scope, grantedAt: Date()), at: 0)
        persistRemembered()
        Self.logger.info("Always allow granted for \(scope.toolName, privacy: .public)")
    }

    func revoke(_ id: RememberedApproval.ID) {
        let before = remembered.count
        remembered.removeAll { $0.id == id }
        guard remembered.count != before else { return }
        persistRemembered()
        Self.logger.info("Always allow revoked")
    }

    /// Consents and remembered approvals.
    func revokeAll() {
        consents = []
        remembered = []
        defaults.removeObject(forKey: Self.consentsKey)
        defaults.removeObject(forKey: Self.rememberedKey)
        Self.logger.info("All approvals revoked")
    }

    // MARK: - Private

    private func persistConsents() {
        defaults.set(consents.map(\.rawValue).sorted(), forKey: Self.consentsKey)
    }

    private func persistRemembered() {
        do {
            let data = try JSONEncoder().encode(remembered)
            defaults.set(data, forKey: Self.rememberedKey)
        } catch {
            Self.logger.error("Couldn't save remembered approvals: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    private static func sortedConsents(_ keys: [ConsentKey]) -> [ConsentKey] {
        keys.sorted { lhs, rhs in
            lhs.label == rhs.label ? lhs.rawValue < rhs.rawValue
                : lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
    }

    private static func loadRemembered(from defaults: UserDefaults) -> [RememberedApproval] {
        guard let data = defaults.data(forKey: rememberedKey) else { return [] }
        do {
            let decoded = try JSONDecoder().decode([RememberedApproval].self, from: data)
            var seen = Set<String>()
            return decoded
                .sorted { $0.grantedAt > $1.grantedAt }
                .filter { seen.insert($0.id).inserted }
        } catch {
            logger.error("Ignored unreadable remembered approvals: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            return []
        }
    }
}
