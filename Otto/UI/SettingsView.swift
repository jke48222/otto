//
//  SettingsView.swift
//  Otto
//
//  One Settings pane per SettingsTab, and the services the panes read from. The window controller hosts one
//  SettingsView per tab; snapshots and the promo stage use `SettingsView(settings:)`, which shows General
//  with inert services. The paid and licensing-check builds add the License tab (§14.10.2): the license pane
//  and, in the paid build, the Updates section.
//

import AppKit
import SwiftUI
import os

/// What the Settings panes read and act on besides AppSettings. Optional services are missing in graphs that
/// don't run them; their rows then show what they can without them.
@MainActor struct SettingsServices {
    var permissions: PermissionsCenter
    var approvals: ApprovalStore
    var actionLog: ActionLog?
    var ledger: UsageLedger
    var history: HistoryController?
    var shelf: ShelfController?
    var calendar: CalendarGlance?
    var nowPlaying: NowPlayingMonitor?
    var neighbors: NotchNeighborMonitor?
    /// Voice preview.
    var speaker: ReplySpeaker?
    /// tccutil reset.
    var processRunner: ProcessRunning?
    #if OTTO_LICENSING
    /// Settings → License. nil in demo and inert graphs (the tab then says licenses aren't checked).
    var license: LicenseControlling? = nil
    #endif
    #if OTTO_SPARKLE || OTTO_SETAPP
    /// The updates section (License tab in the paid build, General in Setapp). nil in demo and inert graphs.
    var updater: UpdaterControlling? = nil
    #endif

    /// Same recipe as NotchServices.inert: PermissionsCenter(StaticPermissionProbe([:], default: .notDetermined),
    /// no-op openURL and relauncher), in-memory ledger, actionLog nil, every optional service nil. Approvals and the
    /// permission flags live in a throwaway defaults suite, so nothing here reads or writes the user's data.
    static func inert(settings: AppSettings) -> SettingsServices {
        let defaults = InertStorage.defaults()
        return SettingsServices(
            permissions: PermissionsCenter(probe: StaticPermissionProbe([:], default: .notDetermined),
                                           defaults: defaults,
                                           openURL: { _ in },
                                           relauncher: InertRelauncher()),
            approvals: ApprovalStore(defaults: defaults),
            actionLog: nil,
            ledger: UsageLedger(fileURL: nil),
            history: nil,
            shelf: nil,
            calendar: nil,
            nowPlaying: nil,
            neighbors: nil,
            speaker: nil,
            processRunner: nil
        )
    }

    /// Relaunching is never part of an inert graph.
    private struct InertRelauncher: AppRelaunching {
        func relaunch() {}
    }

    private enum InertStorage {
        static let suiteName = "otto.settings.inert"
        private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Settings")

        /// One reusable suite, emptied each time, so inert graphs start clean and leave at most one small file.
        static func defaults() -> UserDefaults {
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                // UserDefaults refuses only NSGlobalDomain and the app's own identifier as suite names.
                logger.fault("The inert Settings defaults suite was refused")
                return .standard
            }
            defaults.removePersistentDomain(forName: suiteName)
            return defaults
        }
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let tab: SettingsTab
    @State private var services: SettingsServices
    #if OTTO_LICENSING
    @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?
    @Environment(\.settingsOpenExternal) private var openExternal
    #endif

    /// General, with inert services (snapshots, the promo stage).
    init(settings: AppSettings) {
        self.init(settings: settings, tab: .general, services: .inert(settings: settings))
    }

    init(settings: AppSettings, tab: SettingsTab, services: SettingsServices) {
        self.settings = settings
        self.tab = tab
        _services = State(initialValue: services)
    }

    var body: some View {
        pane
            .environment(services.permissions)
            .frame(minWidth: 480, idealWidth: SettingsWindowController.contentWidth,
                   minHeight: SettingsWindowController.heightRange.lowerBound,
                   idealHeight: SettingsWindowController.height(for: tab))
    }

    @ViewBuilder private var pane: some View {
        switch tab {
        case .general: SettingsGeneralPane(settings: settings, services: services)
        case .notch: SettingsNotchPane(settings: settings, services: services)
        case .models: SettingsModelsPane(settings: settings, services: services)
        case .context: SettingsContextPane(settings: settings, services: services)
        case .actions: SettingsActionsPane(settings: settings, services: services)
        case .voice: SettingsVoicePane(settings: settings, services: services)
        case .privacy: SettingsPrivacyPane(settings: settings, services: services)
        #if OTTO_LICENSING
        case .license: licensePane
        #endif
        }
    }

    #if OTTO_LICENSING
    /// Settings → License: the license pane (only the demo line when there is no license engine), then the paid
    /// build's Updates section. "Enter License" (anchor `.licenseKey`) focuses the key field, which sits at the top.
    private var licensePane: some View {
        let opener = openExternal
        return SettingsPane(tab: .license, settings: settings) {
            LicensePane(model: services.license,
                        focusKeyField: navigation?.pendingAnchor == .licenseKey,
                        openExternal: { opener($0) })
            #if OTTO_SPARKLE
            if let updater = services.updater {
                UpdatesSection(updater: updater, siteHost: services.license?.configuration.siteHost,
                               openExternal: { opener($0) })
            }
            #endif
        }
    }
    #endif
}
