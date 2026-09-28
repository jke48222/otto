//
//  ComposerGate.swift
//  Otto
//
//  The flavor-neutral seam that can pause sending: a gate is one line above the composer that says why and offers
//  up to two choices (§14.10.1). Only the paid build installs a gate source; every other build leaves it nil.
//

import Foundation

/// Why sending is paused, shown as one line above the composer (§14.10.1). Never a dialog, never at launch.
struct ComposerGate: Equatable, Identifiable, Sendable {
    enum Action: Equatable, Sendable {
        case openURL(URL)                               // VM: close(.programmatic), then NSWorkspace.shared.open
        case openSettings(SettingsTab, SettingsAnchor?) // VM: openSettings(tab:anchor:)
        case gate(String)                               // VM → ComposerGating.handleGateAction(_:) ("check-now")
    }

    struct Choice: Equatable, Sendable {
        let title: String                               // "Buy a License", "Enter License", "Check Now"
        let action: Action
        let isPrimary: Bool                             // off-white capsule; at most one per gate
    }

    let id: String            // "trial-ended", "license-removed", "check-required", "checking", "activating"
    let symbol: String        // SF Symbol, 12 pt
    let message: String       // ≤ 56 characters: one line at 540 pt, 12 pt
    let choices: [Choice]     // 0…2
}

/// Implemented by LicenseController (paid) and StaticLicenseModel (tests, snapshots, self-test). The source and Setapp
/// builds never install one (NotchServices.sendGate == nil), so their behavior is byte-for-byte unchanged.
@MainActor protocol ComposerGating: AnyObject {
    /// nil = sending allowed. Observable in the concrete class (Observation tracks the read through the existential).
    var composerGate: ComposerGate? { get }
    func handleGateAction(_ id: String)
}

/// Thrown by the makeClient backstop (§14.10.1) if a request starts while a gate is up.
struct ComposerGateError: LocalizedError, Equatable, Sendable {
    let message: String
    var errorDescription: String? { message }
}
