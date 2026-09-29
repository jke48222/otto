//
//  AppCompositionFlavorTests.swift
//  OttoTests
//
//  What each flavor adds to the object graph (SPEC-v2 §14.10, §14.11). Every flavor: the inert graph has no send
//  gate, no license engine, no updater and no extra status menu items, and the makeClient backstop fails a request
//  that starts while a gate is up. Builds with licensing: the backstop on a StaticLicenseModel, the status menu's
//  License items and where they lead, the live store's Keychain accounts (read from the store, never the
//  Keychain), and the Debug `--license-state` seeds. The paid and Setapp builds add their update items.
//

import AppKit
import XCTest
@testable import Otto

/// A gate the test raises and lowers.
@MainActor
private final class FakeGate: ComposerGating {
    var composerGate: ComposerGate?

    func handleGateAction(_ id: String) {}
}

/// Counts the clients the backstop lets through.
@MainActor
private final class ClientCounter {
    private(set) var made = 0

    func make() -> LLMClient {
        made += 1
        return MockLLMClient(latencyScale: 0)
    }
}

@MainActor
final class AppCompositionFlavorTests: XCTestCase {
    // MARK: - Every flavor

    func testInertGraphHasNoFlavorParts() {
        let composition = AppComposition.inert()
        defer { composition.terminate() }

        XCTAssertNil(composition.viewModel.sendGate, "nothing pauses sending")
        XCTAssertNil(composition.viewModel.composerGate)
        #if OTTO_LICENSING
        XCTAssertNil(composition.license, "inert graphs run no license engine")
        #endif
        #if OTTO_SPARKLE || OTTO_SETAPP
        XCTAssertNil(composition.updater, "inert graphs run no updater")
        #endif
        XCTAssertTrue(AppComposition.extraMenuItems(for: AppComposition.FlavorServices(), openSettings: { _, _ in })
            .isEmpty, "no status menu items without a license engine or updater")
    }

    #if !OTTO_LICENSING && !OTTO_SETAPP
    func testSourceBuildAddsNothing() {
        XCTAssertEqual(OttoBuild.flavor, .source)
        XCTAssertNil(AppComposition.FlavorServices().sendGate, "the source build has nothing that pauses sending")
        XCTAssertTrue(AppComposition.extraMenuItems(for: AppComposition.FlavorServices(), openSettings: { _, _ in })
            .isEmpty, "and no status menu items of its own")
    }
    #endif

    func testBackstopWithoutAGateIsMakeClientItself() throws {
        let counter = ClientCounter()
        let makeClient = AppComposition.backstopped({ counter.make() }, by: nil)
        _ = try makeClient()
        XCTAssertEqual(counter.made, 1)
    }

    func testBackstopThrowsTheGateMessageWhileAGateIsUp() throws {
        let counter = ClientCounter()
        let gate = FakeGate()
        let makeClient = AppComposition.backstopped({ counter.make() }, by: gate)

        _ = try makeClient()
        XCTAssertEqual(counter.made, 1, "no gate: the request starts")

        gate.composerGate = ComposerGate(id: "trial-ended", symbol: "hourglass",
                                         message: "Your 14-day trial has ended.", choices: [])
        XCTAssertThrowsError(try makeClient()) { error in
            XCTAssertEqual(error as? ComposerGateError, ComposerGateError(message: "Your 14-day trial has ended."))
            XCTAssertEqual(error.localizedDescription, "Your 14-day trial has ended.")
        }
        XCTAssertEqual(counter.made, 1, "no client while the gate is up")

        gate.composerGate = nil
        _ = try makeClient()
        XCTAssertEqual(counter.made, 2)
    }

    func testBackstopFailsTheTurnThatStartsWhileAGateIsUp() async {
        let settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        let gate = FakeGate()
        gate.composerGate = ComposerGate(id: "check-required", symbol: "wifi.exclamationmark",
                                         message: "Otto needs to check your license before it can send.",
                                         choices: [])
        let chat = ChatSession(settings: settings,
                               makeClient: AppComposition.backstopped({ MockLLMClient(latencyScale: 0) }, by: gate))

        chat.send(text: "hello", attachments: [])
        let deadline = Date().addingTimeInterval(5)
        while chat.isStreaming, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(chat.isStreaming)
        XCTAssertEqual(chat.messages.last?.state, .failed("Otto needs to check your license before it can send."),
                       "ChatSession's own error path shows the gate's message on that turn")
    }

    // MARK: - Builds with licensing

    #if OTTO_LICENSING
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func licensedModel(configuration: LicenseConfiguration = .preview) -> StaticLicenseModel {
        let record = AppComposition.sampleLicenseRecord(configuration: configuration,
                                                        activatedAt: Self.now.addingTimeInterval(-86_400),
                                                        validatedAt: Self.now)
        return StaticLicenseModel(status: .licensed(LicenseSummary(record: record)))
    }

    func testBackstopOnAStaticLicenseModel() throws {
        let counter = ClientCounter()
        let license = licensedModel()
        let makeClient = AppComposition.backstopped({ counter.make() }, by: license)

        _ = try makeClient()
        XCTAssertEqual(counter.made, 1, "licensed: requests start")

        license.status = .trialEnded(endedAt: Self.now)
        XCTAssertThrowsError(try makeClient()) { error in
            XCTAssertEqual(error as? ComposerGateError, ComposerGateError(message: "Your 14-day trial has ended."))
        }
        XCTAssertEqual(counter.made, 1)
    }

    func testLicenseMenuItemFollowsWhetherSendingNeedsALicense() throws {
        var flavor = AppComposition.FlavorServices()
        let license = licensedModel()
        flavor.license = license
        var requests: [(tab: SettingsTab, anchor: SettingsAnchor?)] = []
        let openSettings: @MainActor (SettingsTab, SettingsAnchor?) -> Void = { requests.append(($0, $1)) }

        var items = AppComposition.extraMenuItems(for: flavor, openSettings: openSettings)
        XCTAssertEqual(items.map(\.title), ["License…"])
        perform(try XCTUnwrap(items.first))
        XCTAssertEqual(requests.last?.tab, .license)
        XCTAssertNil(requests.last?.anchor)

        license.status = .trialEnded(endedAt: Self.now)
        items = AppComposition.extraMenuItems(for: flavor, openSettings: openSettings)
        XCTAssertEqual(items.map(\.title), ["Enter License…"])
        perform(try XCTUnwrap(items.first))
        XCTAssertEqual(requests.last?.tab, .license)
        XCTAssertEqual(requests.last?.anchor, .licenseKey, "straight to the key field")
        XCTAssertEqual(requests.count, 2)
    }

    func testLiveStoreUsesTheConfigurationsKeychainAccounts() {
        let preview = AppComposition.makeLicenseStore(for: .preview)
        XCTAssertEqual(preview.accounts, LicenseConfiguration.preview.keychainAccounts)
        XCTAssertEqual(preview.accounts, .sandbox, "the sandbox configuration never touches the production items")
        XCTAssertEqual(preview.service, KeychainStore.service)

        let production = LicenseConfiguration(
            siteHost: "otto.example",
            supportEmail: "support@otto.example",
            polar: LicenseConfiguration.preview.polar.map {
                PolarConfiguration(apiHost: LicenseConfiguration.polarProductionHost,
                                   organizationID: $0.organizationID, benefitID: $0.benefitID,
                                   portalSlug: $0.portalSlug)
            },
            gumroad: nil,
            gumroadExplicitlyOff: true,
            problems: []
        )
        XCTAssertEqual(AppComposition.makeLicenseStore(for: production).accounts, .production)

        let misconfigured = LicenseConfiguration(siteHost: "otto.example", supportEmail: "support@otto.example",
                                                 polar: production.polar, gumroad: nil, gumroadExplicitlyOff: false,
                                                 problems: ["OTTO_GUMROAD_PRODUCT_ID is still a placeholder"])
        XCTAssertEqual(AppComposition.makeLicenseStore(for: misconfigured).accounts, .sandbox)
    }

    func testSampleLicenseRecordCarriesTheConfigurationsIDs() {
        let record = AppComposition.sampleLicenseRecord(configuration: .preview, activatedAt: Self.now,
                                                        validatedAt: Self.now)
        XCTAssertEqual(record.backend, .polar)
        XCTAssertEqual(record.apiHost, LicenseConfiguration.preview.polar?.apiHost)
        XCTAssertEqual(record.organizationID, LicenseConfiguration.preview.polar?.organizationID)
        XCTAssertEqual(record.benefitID, LicenseConfiguration.preview.polar?.benefitID)
        XCTAssertTrue(LicenseKeyRouter.looksLikePolar(record.key))
        XCTAssertEqual(record.displayKey, LicenseKeyRouter.displayKey(for: record.key))
        XCTAssertEqual(record.seatLimit, LicensePolicy.seatsPerLicense)
    }

    #if DEBUG
    func testLicenseStateSeedsReachEveryState() {
        func status(_ state: LaunchOptions.LicenseState) -> LicenseStatus {
            let store = AppComposition.seededLicenseStore(state, configuration: .preview, now: Self.now)
            return LicensePolicy.status(license: store.loadLicense(), trial: store.loadTrial(),
                                        now: Self.now.addingTimeInterval(1))
        }

        guard case .trial(_, let daysLeft) = status(.trial) else { return XCTFail("trial: \(status(.trial))") }
        XCTAssertEqual(daysLeft, 11)
        guard case .trial(_, let lastDay) = status(.trialLastDay) else {
            return XCTFail("trial-last-day: \(status(.trialLastDay))")
        }
        XCTAssertEqual(lastDay, 1)
        guard case .trialEnded = status(.ended) else { return XCTFail("ended: \(status(.ended))") }
        guard case .trialEnded = status(.removed) else { return XCTFail("removed: \(status(.removed))") }
        let removed = AppComposition.seededLicenseStore(.removed, configuration: .preview, now: Self.now)
        XCTAssertEqual(try? removed.loadTrial().get()?.lastLicenseRemoval?.reason, .revoked)
        guard case .licensed = status(.licensed) else { return XCTFail("licensed: \(status(.licensed))") }
        guard case .licensedCheckOverdue = status(.overdue) else { return XCTFail("overdue: \(status(.overdue))") }
        guard case .licensedCheckRequired = status(.required) else {
            return XCTFail("required: \(status(.required))")
        }
        guard case .unavailable(.keychain) = status(.keychainError) else {
            return XCTFail("keychain-error: \(status(.keychainError))")
        }
        XCTAssertEqual(Set(LaunchOptions.LicenseState.allCases.map(\.rawValue)),
                       ["trial", "trial-last-day", "ended", "removed", "licensed", "overdue", "required",
                        "keychain-error"])
    }
    #endif
    #endif

    // MARK: - Update items (paid and Setapp)

    #if OTTO_SPARKLE
    func testPaidMenuListsInstallLicenseAndCheckForUpdates() throws {
        var flavor = AppComposition.FlavorServices()
        flavor.license = licensedModel()
        let updater = StaticUpdaterModel(source: .sparkle)
        flavor.updater = updater

        var items = AppComposition.extraMenuItems(for: flavor, openSettings: { _, _ in })
        XCTAssertEqual(items.map(\.title), ["License…", "Check for Updates…"])
        XCTAssertTrue(items[1].isEnabled)
        perform(items[1])
        XCTAssertEqual(updater.calls, ["checkNow"])

        updater.canCheckNow = false
        updater.pendingUpdate = PendingUpdate(version: "1.2.0", releaseNotes: nil)
        items = AppComposition.extraMenuItems(for: flavor, openSettings: { _, _ in })
        XCTAssertEqual(items.map(\.title), ["Install Otto 1.2.0…", "License…", "Check for Updates…"])
        XCTAssertFalse(items[2].isEnabled, "disabled while the updater can't check")
        perform(items[0])
        XCTAssertEqual(updater.calls, ["checkNow", "install"])
    }
    #endif

    #if OTTO_SETAPP
    func testSetappMenuListsOnlyAPendingUpdate() throws {
        var flavor = AppComposition.FlavorServices()
        let updater = StaticUpdaterModel(source: .setapp)
        flavor.updater = updater
        XCTAssertTrue(AppComposition.extraMenuItems(for: flavor, openSettings: { _, _ in }).isEmpty)

        updater.pendingUpdate = PendingUpdate(version: "1.2.0", releaseNotes: "Fixes.")
        let items = AppComposition.extraMenuItems(for: flavor, openSettings: { _, _ in })
        XCTAssertEqual(items.map(\.title), ["Install Otto 1.2.0…"])
        perform(items[0])
        XCTAssertEqual(updater.calls, ["install"])
    }
    #endif

    // MARK: - Helpers

    /// Runs a menu item's action the way the menu does, through a menu of its own.
    private func perform(_ item: NSMenuItem) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item)
        menu.performActionForItem(at: menu.index(of: item))
        menu.removeItem(item)
    }
}
