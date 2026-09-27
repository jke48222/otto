//
//  ReplyNotificationDeciderTests.swift
//  OttoTests
//
//  When Otto posts a notification (policy × open × attention × duration × approval), what it may say
//  (never text while locked or asleep), what the presenter hands to the notification center, the
//  attention monitor's state, and that the inert controller never reaches the system.
//

import UserNotifications
import XCTest
@testable import Otto

// MARK: - Decider

final class ReplyNotificationDeciderTests: XCTestCase {
    private let visible = AttentionSnapshot()
    private let away = AttentionSnapshot(idleSeconds: 600)
    private let locked = AttentionSnapshot(isScreenLocked: true)
    private let asleep = AttentionSnapshot(areDisplaysAsleep: true)
    private let otherDisplay = AttentionSnapshot(isPointerOnOtherDisplay: true)
    private let fullScreen = AttentionSnapshot(isFullScreenAppOnNotchDisplay: true)

    private func decide(_ policy: ReplyNotificationPolicy, open: Bool, _ attention: AttentionSnapshot,
                        duration: TimeInterval, approval: Bool) -> Bool {
        ReplyNotificationDecider.shouldNotify(policy: policy, notchIsOpen: open, attention: attention,
                                              turnDuration: duration, isApproval: approval)
    }

    func testMinimumTurnDuration() {
        XCTAssertEqual(ReplyNotificationDecider.minimumTurnDuration, 5)
    }

    func testCanSeeNotch() {
        XCTAssertTrue(visible.canSeeNotch)
        XCTAssertTrue(AttentionSnapshot(idleSeconds: 59.9).canSeeNotch)
        XCTAssertFalse(AttentionSnapshot(idleSeconds: 60).canSeeNotch)
        for snapshot in [away, locked, asleep, otherDisplay, fullScreen] {
            XCTAssertFalse(snapshot.canSeeNotch, "\(snapshot)")
        }
    }

    /// Every combination against the rule written out independently of the implementation:
    /// off → false; open && canSee → false; always → !open || !canSee;
    /// whenOutOfSight → !canSee && (isApproval || turnDuration ≥ 5).
    func testFullMatrix() {
        let attentions: [(String, AttentionSnapshot)] = [
            ("visible", visible), ("away", away), ("locked", locked), ("asleep", asleep),
            ("otherDisplay", otherDisplay), ("fullScreen", fullScreen),
        ]
        let durations: [TimeInterval] = [0, 4.9, 5, 60]
        var checked = 0
        for policy in ReplyNotificationPolicy.allCases {
            for open in [false, true] {
                for (name, attention) in attentions {
                    let canSee = name == "visible"
                    for duration in durations {
                        for approval in [false, true] {
                            let expected: Bool
                            switch policy {
                            case .off: expected = false
                            case .always: expected = !open || !canSee
                            case .whenOutOfSight: expected = !canSee && (approval || duration >= 5)
                            }
                            XCTAssertEqual(decide(policy, open: open, attention, duration: duration, approval: approval),
                                           expected, "\(policy) open=\(open) \(name) \(duration)s approval=\(approval)")
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 3 * 2 * 6 * 4 * 2)
    }

    func testReadableExamples() {
        // Off never notifies.
        XCTAssertFalse(decide(.off, open: false, locked, duration: 60, approval: true))
        // "Whenever the notch is closed": any reply while closed, even a fast one with the person right there.
        XCTAssertTrue(decide(.always, open: false, visible, duration: 30, approval: false))
        XCTAssertTrue(decide(.always, open: false, visible, duration: 0.5, approval: false))
        XCTAssertTrue(decide(.always, open: false, visible, duration: 0, approval: true))
        // An open notch nobody can see (locked, another display) still notifies under "always".
        XCTAssertTrue(decide(.always, open: true, locked, duration: 0, approval: false))
        XCTAssertTrue(decide(.always, open: true, otherDisplay, duration: 1, approval: false))
        // "When Otto's out of sight": nothing while the person can see the notch…
        XCTAssertFalse(decide(.whenOutOfSight, open: false, visible, duration: 30, approval: false))
        XCTAssertFalse(decide(.whenOutOfSight, open: false, visible, duration: 30, approval: true))
        // …fires while locked, behind a full-screen app, or with the pointer on another display…
        XCTAssertTrue(decide(.whenOutOfSight, open: false, locked, duration: 30, approval: false))
        XCTAssertTrue(decide(.whenOutOfSight, open: false, fullScreen, duration: 5, approval: false))
        XCTAssertTrue(decide(.whenOutOfSight, open: false, otherDisplay, duration: 5, approval: false))
        // …but only for turns of 5 s or more, unless it's an approval.
        XCTAssertFalse(decide(.whenOutOfSight, open: false, locked, duration: 4.9, approval: false))
        XCTAssertTrue(decide(.whenOutOfSight, open: false, locked, duration: 0, approval: true))
        // An open notch in front of someone never notifies; an open notch nobody can see does.
        XCTAssertFalse(decide(.always, open: true, visible, duration: 30, approval: true))
        XCTAssertTrue(decide(.whenOutOfSight, open: true, away, duration: 30, approval: false))
    }

    func testLockedOrAsleepNeverIncludesText() {
        XCTAssertTrue(ReplyNotificationDecider.includesText(previewsEnabled: true, attention: visible))
        XCTAssertTrue(ReplyNotificationDecider.includesText(previewsEnabled: true, attention: away))
        XCTAssertTrue(ReplyNotificationDecider.includesText(previewsEnabled: true, attention: fullScreen))
        XCTAssertFalse(ReplyNotificationDecider.includesText(previewsEnabled: true, attention: locked))
        XCTAssertFalse(ReplyNotificationDecider.includesText(previewsEnabled: true, attention: asleep))
        XCTAssertFalse(ReplyNotificationDecider.includesText(
            previewsEnabled: true, attention: AttentionSnapshot(isScreenLocked: true, areDisplaysAsleep: true)))
        XCTAssertFalse(ReplyNotificationDecider.includesText(previewsEnabled: false, attention: visible))
    }

    func testPolicyNames() {
        XCTAssertEqual(ReplyNotificationPolicy.off.displayName, "Never")
        XCTAssertEqual(ReplyNotificationPolicy.whenOutOfSight.displayName, "When Otto's out of sight")
        XCTAssertEqual(ReplyNotificationPolicy.always.displayName, "Whenever the notch is closed")
    }
}

// MARK: - Test doubles

/// Records what the presenter hands to the notification center; never posts.
private final class GlanceSpyNotificationCenter: GlanceNotificationCenter {
    weak var delegate: UNUserNotificationCenterDelegate?
    private(set) var added: [UNNotificationRequest] = []
    private(set) var removedDelivered: [[String]] = []
    private(set) var removedPending: [[String]] = []

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
        added.append(request)
        completionHandler?(nil)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDelivered.append(identifiers)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPending.append(identifiers)
    }
}

// MARK: - Presenter

@MainActor
final class NotificationPresenterTests: XCTestCase {
    private var center = GlanceSpyNotificationCenter()
    private var centersMade = 0

    private func makePresenter() -> NotificationPresenter {
        NotificationPresenter(center: { [unowned self] in
            self.centersMade += 1
            return self.center
        })
    }

    func testCreatingAPresenterTouchesNoCenter() {
        _ = makePresenter()
        XCTAssertEqual(centersMade, 0)
    }

    func testInstallBecomesTheDelegate() {
        let presenter = makePresenter()
        presenter.install()
        XCTAssertTrue(center.delegate === presenter)
        XCTAssertEqual(centersMade, 1)
    }

    func testReplyWithText() throws {
        let presenter = makePresenter()
        let preview = ReplyPreview(id: UUID(), outcome: .answered, text: "Your flight leaves at 9:40.")
        presenter.postReply(preview, includeText: true)
        let request = try XCTUnwrap(center.added.last)
        XCTAssertEqual(request.identifier, NotificationPresenter.replyIdentifier)
        XCTAssertNil(request.trigger)
        XCTAssertEqual(request.content.title, "Otto replied")
        XCTAssertEqual(request.content.body, "Your flight leaves at 9:40.")
        XCTAssertEqual(request.content.targetContentIdentifier, preview.id.uuidString)
        XCTAssertEqual(request.content.userInfo.count, 1)
        XCTAssertEqual(request.content.userInfo[NotificationPresenter.messageIDKey] as? String, preview.id.uuidString)
        XCTAssertEqual(request.content.categoryIdentifier, "", "no actions")
        XCTAssertEqual(request.content.threadIdentifier, "otto.replies")
        XCTAssertEqual(request.content.interruptionLevel, .active)
        XCTAssertNil(request.content.sound)
        XCTAssertEqual(NotificationPresenter.messageID(from: request.content.userInfo), preview.id)
    }

    func testFailedReplyTitle() throws {
        let presenter = makePresenter()
        let preview = ReplyPreview(id: UUID(), outcome: .failed, text: "Otto is being rate limited.")
        presenter.postReply(preview, includeText: true)
        let shown = try XCTUnwrap(center.added.last)
        XCTAssertEqual(shown.content.title, "Otto couldn't finish")
        XCTAssertEqual(shown.content.body, "Otto is being rate limited.")

        presenter.postReply(preview, includeText: false)
        let hidden = try XCTUnwrap(center.added.last)
        XCTAssertEqual(hidden.content.title, "Otto replied", "the lock screen doesn't learn the outcome")
        XCTAssertEqual(hidden.content.body, "Tap to open Otto.")
    }

    func testReplyWithoutText() throws {
        let presenter = makePresenter()
        let preview = ReplyPreview(id: UUID(), outcome: .answered, text: "Secret plans")
        presenter.postReply(preview, includeText: false)
        let request = try XCTUnwrap(center.added.last)
        XCTAssertEqual(request.content.title, "Otto replied")
        XCTAssertEqual(request.content.body, "Tap to open Otto.")
        XCTAssertFalse(request.content.body.contains("Secret"))
        XCTAssertFalse(request.content.subtitle.contains("Secret"))
        XCTAssertEqual(request.content.userInfo.count, 1)
    }

    func testApprovalWithAndWithoutText() throws {
        let presenter = makePresenter()
        presenter.postApproval(title: "Run “Wipe Downloads”", includeText: true)
        let shown = try XCTUnwrap(center.added.last)
        XCTAssertEqual(shown.identifier, NotificationPresenter.approvalIdentifier)
        XCTAssertEqual(shown.content.title, "Otto needs your OK")
        XCTAssertEqual(shown.content.body, "Run “Wipe Downloads”")
        XCTAssertEqual(shown.content.categoryIdentifier, "", "no Run/Deny actions")
        XCTAssertTrue(shown.content.userInfo.isEmpty)
        XCTAssertNil(shown.content.sound)
        XCTAssertEqual(shown.content.threadIdentifier, "otto.replies")
        XCTAssertNil(NotificationPresenter.messageID(from: shown.content.userInfo))

        presenter.postApproval(title: "Run “Wipe Downloads”", includeText: false)
        let hidden = try XCTUnwrap(center.added.last)
        XCTAssertEqual(hidden.content.title, "Otto needs your OK")
        XCTAssertEqual(hidden.content.body, "Tap to open Otto.")
        XCTAssertFalse(hidden.content.title.contains("Wipe") || hidden.content.body.contains("Wipe"))
    }

    func testApprovalTitleIsSanitized() throws {
        let presenter = makePresenter()
        presenter.postApproval(title: "Run\u{202E} “x”\n", includeText: true)
        XCTAssertEqual(try XCTUnwrap(center.added.last).content.body, "Run “x”")
    }

    func testWithdrawAndClear() {
        let presenter = makePresenter()
        presenter.withdrawApproval()
        XCTAssertEqual(center.removedDelivered.last, [NotificationPresenter.approvalIdentifier])
        XCTAssertEqual(center.removedPending.last, [NotificationPresenter.approvalIdentifier])

        presenter.clearDelivered()
        XCTAssertEqual(Set(center.removedDelivered.last ?? []), ["otto.reply", "otto.approval"])
        XCTAssertEqual(Set(center.removedPending.last ?? []), ["otto.reply", "otto.approval"])
    }

    func testMessageIDParsing() {
        let id = UUID()
        XCTAssertEqual(NotificationPresenter.messageIDKey, "otto.messageID")
        XCTAssertEqual(NotificationPresenter.messageID(from: ["otto.messageID": id.uuidString]), id)
        XCTAssertNil(NotificationPresenter.messageID(from: ["otto.messageID": "not-a-uuid"]))
        XCTAssertNil(NotificationPresenter.messageID(from: ["messageID": id.uuidString]))
        XCTAssertNil(NotificationPresenter.messageID(from: [:]))
    }
}

// MARK: - Attention monitor

@MainActor
final class AttentionMonitorTests: XCTestCase {
    private let workspace = NotificationCenter()
    private let distributed = NotificationCenter()

    private func makeMonitor(idle: TimeInterval = 0, locked: Bool = false, asleep: Bool = false,
                             pointerElsewhere: Bool = false, fullScreen: Bool = false) -> AttentionMonitor {
        AttentionMonitor(notchScreen: { nil }, workspaceCenter: workspace, distributedCenter: distributed,
                         idleSeconds: { idle }, initialLockState: { locked }, initialDisplaysAsleep: { asleep },
                         pointerOnOtherDisplay: { _ in pointerElsewhere }, fullScreenAppOnDisplay: { _ in fullScreen })
    }

    func testReadsInitialStateOnStart() {
        let monitor = makeMonitor(idle: 12, locked: true, asleep: true)
        XCTAssertFalse(monitor.snapshot().isScreenLocked, "nothing is read before start()")
        monitor.start()
        let snapshot = monitor.snapshot()
        XCTAssertTrue(snapshot.isScreenLocked)
        XCTAssertTrue(snapshot.areDisplaysAsleep)
        XCTAssertEqual(snapshot.idleSeconds, 12)
        XCTAssertFalse(snapshot.isPointerOnOtherDisplay)
        XCTAssertFalse(snapshot.isFullScreenAppOnNotchDisplay)
    }

    func testSnapshotCarriesTheProbes() {
        XCTAssertTrue(makeMonitor(pointerElsewhere: true).snapshot().isPointerOnOtherDisplay)
        XCTAssertTrue(makeMonitor(fullScreen: true).snapshot().isFullScreenAppOnNotchDisplay)
        XCTAssertFalse(makeMonitor(fullScreen: true).snapshot().canSeeNotch)
        XCTAssertFalse(makeMonitor(idle: 75).snapshot().canSeeNotch)
    }

    func testProbesReceiveTheNotchScreen() {
        var seen: [NSScreen?] = []
        let screen = NSScreen.screens.first
        let monitor = AttentionMonitor(notchScreen: { screen }, workspaceCenter: workspace, distributedCenter: distributed,
                                       idleSeconds: { 0 }, initialLockState: { false }, initialDisplaysAsleep: { false },
                                       pointerOnOtherDisplay: { seen.append($0); return false },
                                       fullScreenAppOnDisplay: { seen.append($0); return false })
        _ = monitor.snapshot()
        XCTAssertEqual(seen.count, 2)
        XCTAssertTrue(seen.allSatisfy { $0 === screen })
    }

    func testFollowsLockSleepAndSessionSwitches() {
        let monitor = makeMonitor()
        monitor.start()
        distributed.post(name: AttentionMonitor.screenLockedNotification, object: nil)
        XCTAssertTrue(monitor.snapshot().isScreenLocked)
        distributed.post(name: AttentionMonitor.screenUnlockedNotification, object: nil)
        XCTAssertFalse(monitor.snapshot().isScreenLocked)

        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertTrue(monitor.snapshot().areDisplaysAsleep)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertFalse(monitor.snapshot().areDisplaysAsleep)

        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        XCTAssertTrue(monitor.snapshot().isScreenLocked)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertFalse(monitor.snapshot().isScreenLocked)
    }

    func testStartIsIdempotent() {
        let monitor = makeMonitor()
        monitor.start()
        monitor.start()
        distributed.post(name: AttentionMonitor.screenLockedNotification, object: nil)
        XCTAssertTrue(monitor.snapshot().isScreenLocked)
    }

    // MARK: Full-screen detection (pure core)

    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    private func window(pid: Int32, layer: Int, bounds: CGRect) -> [String: Any] {
        [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: NSNumber(value: layer),
         kCGWindowBounds as String: bounds.dictionaryRepresentation as NSDictionary]
    }

    func testFullScreenWindowOfTheFrontmostAppCoversTheDisplay() {
        let windows = [window(pid: 42, layer: 0, bounds: display)]
        XCTAssertTrue(AttentionMonitor.windowsCoverDisplay(windows, ownerPID: 42, displayBounds: display))
    }

    func testOtherOwnersLayersAndSizesDoNotCount() {
        let smaller = CGRect(x: 0, y: 25, width: 1512, height: 957)
        let offset = CGRect(x: 1512, y: 0, width: 1512, height: 982)
        XCTAssertFalse(AttentionMonitor.windowsCoverDisplay([window(pid: 7, layer: 0, bounds: display)],
                                                            ownerPID: 42, displayBounds: display))
        XCTAssertFalse(AttentionMonitor.windowsCoverDisplay([window(pid: 42, layer: 25, bounds: display)],
                                                            ownerPID: 42, displayBounds: display))
        XCTAssertFalse(AttentionMonitor.windowsCoverDisplay([window(pid: 42, layer: 0, bounds: smaller)],
                                                            ownerPID: 42, displayBounds: display))
        XCTAssertFalse(AttentionMonitor.windowsCoverDisplay([window(pid: 42, layer: 0, bounds: offset)],
                                                            ownerPID: 42, displayBounds: display))
        XCTAssertFalse(AttentionMonitor.windowsCoverDisplay([[kCGWindowOwnerPID as String: NSNumber(value: 42)]],
                                                            ownerPID: 42, displayBounds: display))
        XCTAssertFalse(AttentionMonitor.windowsCoverDisplay([], ownerPID: 42, displayBounds: display))
    }

    func testSecondDisplayOriginMustMatch() {
        let external = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        let windows = [window(pid: 42, layer: 0, bounds: external)]
        XCTAssertTrue(AttentionMonitor.windowsCoverDisplay(windows, ownerPID: 42, displayBounds: external))
        XCTAssertFalse(AttentionMonitor.windowsCoverDisplay(windows, ownerPID: 42, displayBounds: display))
    }
}

// MARK: - Controller notifications

@MainActor
final class GlanceControllerNotificationTests: XCTestCase {
    private let center = GlanceSpyNotificationCenter()
    private let workspace = NotificationCenter()
    private let distributed = NotificationCenter()
    private var clock = Date(timeIntervalSinceReferenceDate: 9_000)
    private var announcements: [String] = []

    private struct Harness {
        let settings: AppSettings
        let chat: ChatSession
        let glance: GlanceController
        let presenter: NotificationPresenter
    }

    private func makeHarness(policy: ReplyNotificationPolicy = .always, previews: Bool = true,
                             locked: Bool = false) -> Harness {
        let settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        settings.glance.notificationPolicy = policy
        settings.glance.notificationIncludesPreview = previews
        let chat = ChatSession(settings: settings, makeClient: { MockLLMClient(latencyScale: 0) })
        let presenter = NotificationPresenter(center: { [center] in center })
        let attention = AttentionMonitor(notchScreen: { nil }, workspaceCenter: workspace, distributedCenter: distributed,
                                         idleSeconds: { 0 }, initialLockState: { locked }, initialDisplaysAsleep: { false },
                                         pointerOnOtherDisplay: { _ in false }, fullScreenAppOnDisplay: { _ in false })
        let glance = GlanceController(settings: settings, chat: chat, notifications: presenter, attention: attention)
        glance.now = { [unowned self] in self.clock }
        glance.sleep = { _ in try await Task.sleep(for: .seconds(3600)) }
        glance.announce = { [unowned self] in self.announcements.append($0) }
        return Harness(settings: settings, chat: chat, glance: glance, presenter: presenter)
    }

    /// Runs a turn of `seconds` (tracked by the started controller) that ends in `answer`.
    private func finishTurn(_ harness: Harness, seconds: TimeInterval, answer: ChatMessage) {
        var streaming = answer
        streaming.state = .streaming
        streaming.model = "claude-opus-5"
        harness.chat.debugSeed(messages: [ChatMessage(role: .user, text: "Q"), streaming], isStreaming: true)
        harness.glance.start()
        clock = clock.addingTimeInterval(seconds)
        harness.chat.debugSeed(messages: [ChatMessage(role: .user, text: "Q"), answer], isStreaming: false)
    }

    func testStartInstallsAndStartsTheMonitor() {
        let harness = makeHarness(locked: true)
        harness.glance.start()
        XCTAssertTrue(center.delegate === harness.presenter)
        distributed.post(name: AttentionMonitor.screenUnlockedNotification, object: nil)
        XCTAssertFalse(harness.glance.attention?.snapshot().isScreenLocked ?? true)
    }

    func testLongReplyPostsWithText() throws {
        let harness = makeHarness()
        let answer = ChatMessage(role: .assistant, text: "All done.", state: .complete)
        finishTurn(harness, seconds: 20, answer: answer)
        harness.glance.replyDidFinish(messageID: answer.id, notchIsOpen: false)
        let request = try XCTUnwrap(center.added.last)
        XCTAssertEqual(request.content.body, "All done.")
        XCTAssertEqual(request.content.targetContentIdentifier, answer.id.uuidString)
    }

    func testQuickReplyPostsWheneverTheNotchIsClosed() throws {
        let harness = makeHarness(policy: .always)
        let answer = ChatMessage(role: .assistant, text: "Hi!", state: .complete)
        finishTurn(harness, seconds: 1, answer: answer)
        harness.glance.replyDidFinish(messageID: answer.id, notchIsOpen: false)
        XCTAssertEqual(try XCTUnwrap(center.added.last).content.body, "Hi!")
    }

    func testQuickReplyOutOfSightDoesNotPost() {
        let harness = makeHarness(policy: .whenOutOfSight, locked: true)
        let answer = ChatMessage(role: .assistant, text: "Hi!", state: .complete)
        finishTurn(harness, seconds: 4, answer: answer)
        harness.glance.replyDidFinish(messageID: answer.id, notchIsOpen: false)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testNeverStartedMeansZeroDuration() {
        let harness = makeHarness(policy: .whenOutOfSight, locked: true)
        let answer = ChatMessage(role: .assistant, text: "Hi!", state: .complete)
        harness.chat.debugSeed(messages: [ChatMessage(role: .user, text: "Q"), answer], isStreaming: false)
        harness.glance.replyDidFinish(messageID: answer.id, notchIsOpen: false)
        XCTAssertTrue(center.added.isEmpty, "0 s is under the 5 s minimum")
    }

    func testQuickApprovalOutOfSightPosts() throws {
        let harness = makeHarness(policy: .whenOutOfSight, locked: true)
        harness.glance.start()
        harness.glance.approvalDidAppear(title: "Run “Resize”", notchIsOpen: false)
        XCTAssertEqual(try XCTUnwrap(center.added.last).content.title, "Otto needs your OK")
    }

    func testPreviewDropAndAnnouncementWhileVisible() {
        let harness = makeHarness(policy: .off)
        let answer = ChatMessage(role: .assistant, text: "All set.", state: .complete)
        finishTurn(harness, seconds: 3, answer: answer)
        harness.glance.replyDidFinish(messageID: answer.id, notchIsOpen: false)
        XCTAssertEqual(harness.glance.preview?.text, "All set.")
        XCTAssertEqual(announcements, ["Otto replied: All set."])
    }

    func testNoPreviewWhileLockedButTheNotificationStillGoes() throws {
        let harness = makeHarness(policy: .whenOutOfSight, locked: true)
        let answer = ChatMessage(role: .assistant, text: "All set.", state: .complete)
        finishTurn(harness, seconds: 30, answer: answer)
        harness.glance.replyDidFinish(messageID: answer.id, notchIsOpen: false)
        XCTAssertNil(harness.glance.preview, "straight to the unread dot")
        XCTAssertTrue(announcements.isEmpty)
        XCTAssertEqual(try XCTUnwrap(center.added.last).content.body, "Tap to open Otto.")
    }

    func testNoPreviewWhileOpen() {
        let harness = makeHarness(policy: .off)
        let answer = ChatMessage(role: .assistant, text: "All set.", state: .complete)
        finishTurn(harness, seconds: 3, answer: answer)
        harness.glance.replyDidFinish(messageID: answer.id, notchIsOpen: true)
        XCTAssertNil(harness.glance.preview)
    }

    func testNewChatDropsTheShowingPreview() async {
        let harness = makeHarness(policy: .off)
        let answer = ChatMessage(role: .assistant, text: "All set.", state: .complete)
        finishTurn(harness, seconds: 3, answer: answer)
        harness.glance.replyDidFinish(messageID: answer.id, notchIsOpen: false)
        XCTAssertNotNil(harness.glance.preview)
        harness.chat.reset()
        for _ in 0..<50 where harness.glance.preview != nil {
            await Task.yield()
        }
        XCTAssertNil(harness.glance.preview)
    }

    func testLockedScreenNeverShowsReplyText() throws {
        let harness = makeHarness(policy: .whenOutOfSight, previews: true)
        let answer = ChatMessage(role: .assistant, text: "Private details", state: .complete)
        finishTurn(harness, seconds: 30, answer: answer)
        distributed.post(name: AttentionMonitor.screenLockedNotification, object: nil)
        harness.glance.replyDidFinish(messageID: answer.id, notchIsOpen: false)
        let request = try XCTUnwrap(center.added.last)
        XCTAssertEqual(request.content.title, "Otto replied")
        XCTAssertEqual(request.content.body, "Tap to open Otto.")
    }

    func testSleepingDisplaysNeverShowApprovalNames() throws {
        let harness = makeHarness(policy: .whenOutOfSight, previews: true)
        harness.glance.start()
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        harness.glance.approvalDidAppear(title: "Run “Wipe Downloads”", notchIsOpen: false)
        let request = try XCTUnwrap(center.added.last)
        XCTAssertEqual(request.content.title, "Otto needs your OK")
        XCTAssertEqual(request.content.body, "Tap to open Otto.")
    }

    func testPreviewSettingOffHidesText() throws {
        let harness = makeHarness(previews: false)
        harness.glance.start()
        harness.glance.approvalDidAppear(title: "Run “Resize”", notchIsOpen: false)
        XCTAssertEqual(try XCTUnwrap(center.added.last).content.body, "Tap to open Otto.")
    }

    func testApprovalLifecycle() throws {
        let harness = makeHarness()
        harness.glance.start()
        harness.glance.approvalDidAppear(title: "Run “Resize”", notchIsOpen: false)
        XCTAssertEqual(try XCTUnwrap(center.added.last).content.body, "Run “Resize”")
        harness.glance.approvalDidResolve()
        XCTAssertEqual(center.removedDelivered.last, ["otto.approval"])
        XCTAssertEqual(center.removedPending.last, ["otto.approval"])
    }

    func testPolicyOffPostsNothing() {
        let harness = makeHarness(policy: .off)
        let answer = ChatMessage(role: .assistant, text: "Done.", state: .complete)
        finishTurn(harness, seconds: 60, answer: answer)
        harness.glance.replyDidFinish(messageID: answer.id, notchIsOpen: false)
        harness.glance.approvalDidAppear(title: "Run", notchIsOpen: false)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testCancelledReplyPostsNothing() {
        let harness = makeHarness()
        let answer = ChatMessage(role: .assistant, text: "Half", state: .cancelled)
        finishTurn(harness, seconds: 60, answer: answer)
        harness.glance.replyDidFinish(messageID: answer.id, notchIsOpen: false)
        XCTAssertTrue(center.added.isEmpty)
        XCTAssertNil(harness.glance.preview)
    }

    func testNotchDidOpenClearsDelivered() {
        let harness = makeHarness()
        harness.glance.notchDidOpen()
        XCTAssertEqual(Set(center.removedDelivered.last ?? []), ["otto.reply", "otto.approval"])
    }
}

// MARK: - Inert

@MainActor
final class GlanceControllerInertTests: XCTestCase {
    func testInertHasNoSystemServicesAndStillWorksInMemory() async {
        let settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        settings.glance.notificationPolicy = .always
        let chat = ChatSession(settings: settings, makeClient: { MockLLMClient(latencyScale: 0) })
        let answer = ChatMessage(role: .assistant, text: "Done.", state: .complete)
        chat.debugSeed(messages: [ChatMessage(role: .user, text: "Q"), answer], isStreaming: false)

        let glance = GlanceController.inert(settings: settings, chat: chat)
        XCTAssertNil(glance.notifications, "no notification center")
        XCTAssertNil(glance.attention, "no monitors")
        glance.sleep = { _ in try await Task.sleep(for: .seconds(3600)) }

        glance.start()
        glance.replyDidFinish(messageID: answer.id, notchIsOpen: false)
        XCTAssertEqual(glance.preview?.id, answer.id, "previews are in-memory behavior")
        glance.approvalDidAppear(title: "Run", notchIsOpen: false)
        glance.approvalDidResolve()
        glance.notchDidOpen()
        XCTAssertNil(glance.preview)
        XCTAssertNil(glance.notifications)
        XCTAssertNil(glance.attention)
    }
}
