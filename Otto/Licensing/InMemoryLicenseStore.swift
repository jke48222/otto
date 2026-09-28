//
//  InMemoryLicenseStore.swift
//  Otto
//
//  License, trial and Gumroad-counted records kept in memory behind a lock (§14.4.4, §14.9). Demo, tests, snapshots,
//  self-test and the Debug `--license-state` graphs use it, so they never touch the Keychain. An injected failure
//  stands in for an unreadable Keychain: every load returns it and every save or delete throws it while it is set.
//

#if OTTO_LICENSING
import Foundation
import os

/// Lock-protected storage (OSAllocatedUnfairLock), hence @unchecked Sendable.
final class InMemoryLicenseStore: LicenseStoring, @unchecked Sendable {
    private struct State {
        var license: LicenseRecord?
        var trial: TrialRecord?
        var counted: GumroadCountedKeys?
        var failure: LicenseStoreError?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(license: LicenseRecord? = nil, trial: TrialRecord? = nil, counted: GumroadCountedKeys? = nil,
         failure: LicenseStoreError? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(license: license, trial: trial, counted: counted,
                                                          failure: failure))
    }

    /// While set, every load returns it and every save or delete throws it, leaving the records unchanged.
    var failure: LicenseStoreError? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    func loadLicense() -> Result<LicenseRecord?, LicenseStoreError> {
        load { $0.license }
    }

    func saveLicense(_ record: LicenseRecord) throws {
        try change { $0.license = record }
    }

    func deleteLicense() throws {
        try change { $0.license = nil }
    }

    func loadTrial() -> Result<TrialRecord?, LicenseStoreError> {
        load { $0.trial }
    }

    func saveTrial(_ record: TrialRecord) throws {
        try change { $0.trial = record }
    }

    func loadGumroadCounted() -> Result<GumroadCountedKeys?, LicenseStoreError> {
        load { $0.counted }
    }

    func saveGumroadCounted(_ keys: GumroadCountedKeys) throws {
        try change { $0.counted = keys }
    }

    // MARK: - Private

    private func load<Value>(_ read: (State) -> Value?) -> Result<Value?, LicenseStoreError> {
        state.withLock { state in
            if let failure = state.failure { return .failure(failure) }
            return .success(read(state))
        }
    }

    private func change(_ apply: (inout State) -> Void) throws {
        let failure = state.withLock { state -> LicenseStoreError? in
            if let failure = state.failure { return failure }
            apply(&state)
            return nil
        }
        if let failure { throw failure }
    }
}
#endif
