//
//  SparkleUpdaterTests.swift
//  OttoTests
//
//  The paid build's Sparkle adapter without starting Sparkle: the gentle-reminder callbacks set and clear the
//  pending update, the toggles map to the updater, start() pins Accept-Language before it starts, and creating the
//  live updater leaves Sparkle stopped. A recording engine stands in for SPUUpdater, so no test writes Sparkle's SU*
//  preferences into the test host's defaults.
//

#if OTTO_SPARKLE
import Sparkle
import XCTest
@testable import Otto

@MainActor
final class SparkleUpdaterTests: XCTestCase {
    private final class RecordingEngine: SparkleUpdater.Engine {
        var automaticallyChecksForUpdates: Bool {
            didSet { events.append("automaticallyChecks=\(automaticallyChecksForUpdates)") }
        }
        var automaticallyDownloadsUpdates: Bool {
            didSet { events.append("automaticallyDownloads=\(automaticallyDownloadsUpdates)") }
        }
        var canCheckForUpdates = false
        var lastUpdateCheckDate: Date?
        var httpHeaders: [String: String]? {
            didSet { events.append("httpHeaders=\(httpHeaders ?? [:])") }
        }
        private(set) var events: [String] = []
        private var onChange: (@MainActor () -> Void)?

        init(automaticallyChecks: Bool = true, automaticallyDownloads: Bool = true) {
            automaticallyChecksForUpdates = automaticallyChecks
            automaticallyDownloadsUpdates = automaticallyDownloads
        }

        func startUpdater() {
            events.append("startUpdater")
            canCheckForUpdates = true
        }

        func checkForUpdates() {
            events.append("checkForUpdates")
        }

        func observeChanges(_ onChange: @escaping @MainActor () -> Void) {
            self.onChange = onChange
        }

        /// What Sparkle's KVO does after one of the observed values changes.
        func notifyChange() {
            onChange?()
        }
    }

    private let configuredInfo: [String: Any] = [
        "SUFeedURL": "https://otto.otto-fixture.test/appcast.xml",
        "SUPublicEDKey": "pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ=",
    ]

    private var activations = 0

    override func setUp() {
        super.setUp()
        activations = 0
    }

    private func makeUpdater(_ engine: RecordingEngine, info: [String: Any]? = nil) -> SparkleUpdater {
        SparkleUpdater(engine: engine, activateApp: { [weak self] in self?.activations += 1 },
                       infoDictionary: info ?? configuredInfo)
    }

    // MARK: Contract values

    func testSparkleUpdaterDescribesItself() {
        let updater = makeUpdater(RecordingEngine())
        XCTAssertEqual(updater.source, .sparkle)
        XCTAssertTrue(updater.allowsUserSettings)
        XCTAssertFalse(updater.canShowReleaseNotes)
        XCTAssertNil(updater.pendingUpdate)
        XCTAssertNil(updater.lastCheck)
    }

    // MARK: Gentle reminders

    func testScheduledUpdateIsShownBySparkleOnlyInImmediateFocus() {
        let updater = makeUpdater(RecordingEngine())
        let delegate = updater.sparkleDelegate
        let item = SUAppcastItem.empty()
        XCTAssertEqual(delegate.supportsGentleScheduledUpdateReminders, true)
        XCTAssertEqual(delegate.standardUserDriverShouldHandleShowingScheduledUpdate?(item, andInImmediateFocus: true),
                       true)
        XCTAssertEqual(delegate.standardUserDriverShouldHandleShowingScheduledUpdate?(item, andInImmediateFocus: false),
                       false)
    }

    func testUpdateLeftToOttoBecomesPending() {
        let updater = makeUpdater(RecordingEngine())
        updater.sparkleWillHandleShowingUpdate(false, version: "1.2.0")
        XCTAssertEqual(updater.pendingUpdate, PendingUpdate(version: "1.2.0", releaseNotes: nil))
    }

    func testUpdateSparkleShowsItselfIsNotPending() {
        let updater = makeUpdater(RecordingEngine())
        updater.sparkleWillHandleShowingUpdate(true, version: "1.2.0")
        XCTAssertNil(updater.pendingUpdate)
    }

    func testUserAttentionClearsThePendingUpdate() {
        let updater = makeUpdater(RecordingEngine())
        updater.sparkleWillHandleShowingUpdate(false, version: "1.2.0")
        updater.sparkleDelegate.standardUserDriverDidReceiveUserAttention?(forUpdate: SUAppcastItem.empty())
        XCTAssertNil(updater.pendingUpdate)
    }

    func testFinishedSessionClearsThePendingUpdate() {
        let updater = makeUpdater(RecordingEngine())
        updater.sparkleWillHandleShowingUpdate(false, version: "1.3.0")
        XCTAssertEqual(updater.pendingUpdate?.version, "1.3.0")
        updater.sparkleDelegate.standardUserDriverWillFinishUpdateSession?()
        XCTAssertNil(updater.pendingUpdate)
    }

    // MARK: Toggles

    func testTogglesStartFromTheUpdater() {
        let updater = makeUpdater(RecordingEngine(automaticallyChecks: false, automaticallyDownloads: true))
        XCTAssertFalse(updater.automaticallyChecks)
        XCTAssertTrue(updater.automaticallyDownloads)
    }

    func testTogglesWriteThroughToTheUpdater() {
        let engine = RecordingEngine()
        let updater = makeUpdater(engine)
        updater.automaticallyChecks = false
        XCTAssertFalse(engine.automaticallyChecksForUpdates)
        updater.automaticallyDownloads = false
        XCTAssertFalse(engine.automaticallyDownloadsUpdates)
        updater.automaticallyChecks = true
        XCTAssertTrue(engine.automaticallyChecksForUpdates)
        XCTAssertEqual(engine.events, ["automaticallyChecks=false", "automaticallyDownloads=false",
                                       "automaticallyChecks=true"])
    }

    func testSettingTheSameValueDoesNotRewriteSparklesPreference() {
        let engine = RecordingEngine()
        let updater = makeUpdater(engine)
        updater.automaticallyChecks = true
        updater.automaticallyDownloads = true
        XCTAssertEqual(engine.events, [])
    }

    func testChangesInsideSparkleAreMirrored() {
        let engine = RecordingEngine()
        let updater = makeUpdater(engine)
        let checkedAt = Date(timeIntervalSince1970: 1_790_000_000)
        engine.automaticallyDownloadsUpdates = false
        engine.canCheckForUpdates = true
        engine.lastUpdateCheckDate = checkedAt
        engine.notifyChange()
        XCTAssertFalse(updater.automaticallyDownloads)
        XCTAssertTrue(updater.canCheckNow)
        XCTAssertEqual(updater.lastCheck, checkedAt)
        // Mirroring a value that came from Sparkle never writes it back.
        XCTAssertEqual(engine.events, ["automaticallyDownloads=false"])
    }

    // MARK: Start, check, install

    func testStartPinsAcceptLanguageBeforeStartingSparkle() {
        let engine = RecordingEngine()
        let updater = makeUpdater(engine)
        updater.start()
        XCTAssertEqual(engine.httpHeaders, ["Accept-Language": "en"])
        XCTAssertEqual(engine.events, ["httpHeaders=[\"Accept-Language\": \"en\"]", "startUpdater"])
        XCTAssertTrue(updater.canCheckNow)
        updater.start()
        XCTAssertEqual(engine.events.filter { $0 == "startUpdater" }.count, 1)
    }

    func testInitDoesNotStartSparkle() {
        let engine = RecordingEngine()
        let updater = makeUpdater(engine)
        XCTAssertEqual(engine.events, [])
        XCTAssertNil(engine.httpHeaders)
        XCTAssertFalse(updater.canCheckNow)
    }

    func testPlaceholderConfigurationNeverStartsSparkle() {
        let engine = RecordingEngine()
        let updater = makeUpdater(engine, info: [
            "SUFeedURL": "https://JALEN_MUST_SET_SITE_HOST/appcast.xml",
            "SUPublicEDKey": "JALEN_MUST_SET_SPARKLE_PUBLIC_ED_KEY",
        ])
        updater.start()
        XCTAssertEqual(engine.events, [])
        XCTAssertFalse(updater.canCheckNow)
    }

    func testConfigurationProblems() {
        XCTAssertNil(SparkleUpdater.configurationProblem(infoDictionary: configuredInfo))
        XCTAssertNotNil(SparkleUpdater.configurationProblem(infoDictionary: [:]))
        XCTAssertNotNil(SparkleUpdater.configurationProblem(infoDictionary: [
            "SUFeedURL": "http://otto.otto-fixture.test/appcast.xml", "SUPublicEDKey": "key",
        ]))
        XCTAssertNotNil(SparkleUpdater.configurationProblem(infoDictionary: [
            "SUFeedURL": "https://$(OTTO_SITE_HOST)/appcast.xml", "SUPublicEDKey": "key",
        ]))
        XCTAssertNotNil(SparkleUpdater.configurationProblem(infoDictionary: [
            "SUFeedURL": "https://otto.otto-fixture.test/appcast.xml", "SUPublicEDKey": "",
        ]))
    }

    func testCheckNowActivatesOttoThenChecks() {
        let engine = RecordingEngine()
        let updater = makeUpdater(engine)
        updater.checkNow()
        XCTAssertEqual(activations, 0, "no check before Sparkle can check")
        XCTAssertEqual(engine.events, [])
        updater.start()
        updater.checkNow()
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(engine.events.last, "checkForUpdates")
    }

    func testInstallPendingUpdateBringsSparklesWindowBack() {
        let engine = RecordingEngine()
        let updater = makeUpdater(engine)
        updater.start()
        updater.sparkleWillHandleShowingUpdate(false, version: "1.2.0")
        engine.canCheckForUpdates = false
        engine.notifyChange()
        updater.installPendingUpdate()
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(engine.events.last, "checkForUpdates")
    }

    func testReleaseNotesStayInSparklesWindow() {
        let engine = RecordingEngine()
        let updater = makeUpdater(engine)
        updater.showReleaseNotes()
        XCTAssertEqual(engine.events, [])
        XCTAssertEqual(activations, 0)
    }

    // MARK: The live updater

    func testLiveUpdaterIsCreatedStopped() throws {
        let updater = SparkleUpdater()
        let live = try XCTUnwrap(updater.engine as? SparkleUpdater.LiveEngine)
        XCTAssertFalse(live.controller.updater.canCheckForUpdates)
        XCTAssertFalse(live.controller.updater.sessionInProgress)
        XCTAssertNil(live.controller.updater.httpHeaders)
        XCTAssertFalse(updater.canCheckNow)
        XCTAssertNil(updater.pendingUpdate)
    }
}
#endif
