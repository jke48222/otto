//
//  StaticLicenseModel.swift
//  Otto
//
//  A LicenseControlling whose state is set from outside: tests, snapshots and the self-test drive the License pane
//  and the composer gate with it. It records every call and changes nothing by itself (dismissMessage aside), and
//  it never touches the Keychain or the network.
//

#if OTTO_LICENSING
import Foundation
import Observation

@MainActor @Observable final class StaticLicenseModel: LicenseControlling {
    var status: LicenseStatus
    var activity: LicenseActivity
    var lastMessage: LicenseMessage?
    var lastRemoval: LicenseRemoval?
    let configuration: LicenseConfiguration
    /// "activate:<normalized key>", "checkNow", "deactivate", "removeFromThisMac", "dismissMessage", "gate:<id>"
    private(set) var calls: [String]

    init(status: LicenseStatus, configuration: LicenseConfiguration = .preview, lastRemoval: LicenseRemoval? = nil,
         lastMessage: LicenseMessage? = nil, activity: LicenseActivity = .idle) {
        self.status = status
        self.configuration = configuration
        self.lastRemoval = lastRemoval
        self.lastMessage = lastMessage
        self.activity = activity
        self.calls = []
    }

    /// LicenseCopy.gate(status:removal:activity:configuration:)
    var composerGate: ComposerGate? {
        LicenseCopy.gate(status: status, removal: lastRemoval, activity: activity, configuration: configuration)
    }

    // Protocol methods record the call; dismissMessage also clears lastMessage. Nothing else changes by itself.

    func activate(key: String) {
        calls.append("activate:\(LicenseKeyRouter.normalize(key) ?? "")")
    }

    func checkNow() {
        calls.append("checkNow")
    }

    func deactivate() {
        calls.append("deactivate")
    }

    func removeFromThisMac() {
        calls.append("removeFromThisMac")
    }

    func dismissMessage() {
        calls.append("dismissMessage")
        lastMessage = nil
    }

    func handleGateAction(_ id: String) {
        calls.append("gate:\(id)")
    }
}
#endif
