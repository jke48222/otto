//
//  ActionsTests.swift
//  OttoiOSTests
//
//  Actions on iPhone, end to end on an inert graph (the scripted client asks for "Dentist" tomorrow at 3 PM when
//  the prompt says "add … to my calendar"): the approval card, arming, approving, declining, Undo, the iOS
//  permission step, the permission mapping, the activity log, the Live Activity's alert and the row helpers.
//

import EventKit
import XCTest
@testable import Otto

@MainActor
final class ActionsTests: XCTestCase {
    private static let request = "Please add the dentist to my calendar"

    /// Sends the scripted request and waits for the first card.
    private func askForEvent(_ graph: MobileComposition) async -> PendingApproval? {
        graph.model.composerText = Self.request
        graph.model.send()
        await waitUntil { graph.model.pendingApproval != nil && graph.model.approvalVisibleSince != nil }
        return graph.model.pendingApproval
    }

    private func waitUntilArmed(_ graph: MobileComposition) async {
        await waitUntil { (graph.model.approvalArmedAt.map { $0 <= Date() }) ?? false }
    }

    private func lastCall(_ graph: MobileComposition) -> (call: ToolCall, messageID: UUID)? {
        guard let message = graph.chat.messages.last(where: { !$0.toolCalls.isEmpty }),
              let call = message.toolCalls.first else { return nil }
        return (call, message.id)
    }

    // MARK: - Approving

    func testAddingAnEventAsksFirstThenRunsAndCanBeUndone() async throws {
        let graph = makeGraph()
        let approval = try XCTUnwrap(await askForEvent(graph))
        XCTAssertEqual(approval.toolName, "calendar_create_event")
        guard case .event(let preview) = approval.body else { return XCTFail("Expected an event card") }
        XCTAssertEqual(preview.title, "Dentist")
        XCTAssertEqual(graph.model.approvalOptions.calendarIdentifier, preview.selectedCalendarID)
        XCTAssertEqual(lastCall(graph)?.call.status, .awaitingApproval)

        await waitUntilArmed(graph)
        graph.model.approve()
        await waitUntil { !graph.chat.isStreaming }

        let (call, messageID) = try XCTUnwrap(lastCall(graph))
        XCTAssertEqual(call.status, .succeeded)
        XCTAssertNil(graph.model.pendingApproval)
        XCTAssertTrue(ToolCallRow.canUndo(call, now: Date()))
        XCTAssertEqual(ToolCallRow.glyph(for: call.status), .succeeded)

        graph.model.undoAction(call.id, in: messageID)
        await waitUntil { self.lastCall(graph)?.call.status == .undone }
        XCTAssertFalse(ToolCallRow.canUndo(try XCTUnwrap(lastCall(graph)).call, now: Date()))
    }

    func testTheCardWaitsForItsArmingDelay() async throws {
        let graph = makeGraph()
        let approval = try XCTUnwrap(await askForEvent(graph))
        let armedAt = try XCTUnwrap(graph.model.approvalArmedAt)
        XCTAssertGreaterThan(armedAt, Date(), "A fresh card isn't armed yet")

        graph.model.approve()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(graph.model.pendingApproval?.callID, approval.callID, "An early tap does nothing")

        graph.model.declineApproval()
        await waitUntil { !graph.chat.isStreaming }
    }

    func testLeavingRestartsArming() async throws {
        let graph = makeGraph()
        _ = try XCTUnwrap(await askForEvent(graph))
        graph.sceneEnteredBackground()
        XCTAssertNil(graph.model.approvalVisibleSince)
        XCTAssertNil(graph.model.approvalArmedAt)

        graph.sceneBecameActive()
        let since = try XCTUnwrap(graph.model.approvalVisibleSince)
        XCTAssertLessThan(abs(since.timeIntervalSinceNow), 1)
        graph.model.declineApproval()
        await waitUntil { !graph.chat.isStreaming }
    }

    func testDecliningLeavesTheCalendarAlone() async throws {
        let graph = makeGraph()
        _ = try XCTUnwrap(await askForEvent(graph))

        graph.model.declineApproval()
        await waitUntil { !graph.chat.isStreaming }

        let call = try XCTUnwrap(lastCall(graph)).call
        XCTAssertEqual(call.status, .denied)
        XCTAssertEqual(ToolCallRow.label(for: call), "You declined: \(call.presentation.title)")
        XCTAssertEqual(ToolCallRow.glyph(for: call.status), .stopped)
    }

    func testStoppingTheReplyCancelsTheCard() async throws {
        let graph = makeGraph()
        _ = try XCTUnwrap(await askForEvent(graph))
        graph.model.stop()
        await waitUntil { !graph.chat.isStreaming }
        XCTAssertNil(graph.model.pendingApproval)
    }

    // MARK: - iOS access

    func testAMissingPermissionIsAskedForThenTheEventIsApproved() async throws {
        let probe = StaticPermissionProbe(statuses: [.calendars: .notDetermined], promptAnswer: .granted)
        let graph = MobileComposition.inert(permissionProbe: probe)
        addTeardownBlock { await graph.terminate() }

        let first = try XCTUnwrap(await askForEvent(graph))
        guard case .permission(let missing, _) = first.kind else { return XCTFail("Expected the permission step") }
        XCTAssertEqual(missing, [.calendars])

        await waitUntilArmed(graph)
        graph.model.approve()
        await waitUntil { graph.model.pendingApproval.map { $0.callID == first.callID && $0.kind != first.kind } ?? false }
        XCTAssertEqual(probe.prompted, [.calendars])
        guard case .approval = graph.model.pendingApproval?.kind else { return XCTFail("Expected the event card next") }

        await waitUntil { graph.model.approvalVisibleSince != nil }
        await waitUntilArmed(graph)
        graph.model.approve()
        await waitUntil { !graph.chat.isStreaming }
        XCTAssertEqual(lastCall(graph)?.call.status, .succeeded)
    }

    func testARefusedPermissionSaysWhereToFixIt() async throws {
        let probe = StaticPermissionProbe(statuses: [.calendars: .notDetermined], promptAnswer: .denied)
        let graph = MobileComposition.inert(permissionProbe: probe)
        addTeardownBlock { await graph.terminate() }

        _ = try XCTUnwrap(await askForEvent(graph))
        await waitUntilArmed(graph)
        graph.model.approve()
        await waitUntil { graph.model.notice != nil }
        XCTAssertEqual(graph.model.notice?.offersSettings, true)
        XCTAssertFalse(graph.model.isObtainingPermission)

        graph.model.declineApproval()
        await waitUntil { !graph.chat.isStreaming }
        XCTAssertEqual(lastCall(graph)?.call.status, .skipped("Permission needed"))
    }

    func testPermissionMapping() {
        XCTAssertEqual(MobilePermissions.status(fromEventKit: .fullAccess), .granted)
        XCTAssertEqual(MobilePermissions.status(fromEventKit: .writeOnly), .limited)
        XCTAssertEqual(MobilePermissions.status(fromEventKit: .notDetermined), .notDetermined)
        XCTAssertEqual(MobilePermissions.status(fromEventKit: .denied), .denied)
        XCTAssertEqual(MobilePermissions.status(fromEventKit: .restricted), .restricted)
        XCTAssertEqual(MobilePermissions.status(fromSpeech: .authorized), .granted)
        XCTAssertEqual(MobilePermissions.status(fromNotifications: .provisional), .granted)
    }

    func testPermissionsAskOnlyWhenIOSStillCan() async {
        let probe = StaticPermissionProbe(statuses: [.calendars: .denied, .reminders: .notDetermined])
        let permissions = MobilePermissions(probe: probe)
        let calendars = await permissions.request(.calendars)
        XCTAssertEqual(calendars, .denied)
        XCTAssertTrue(probe.prompted.isEmpty, "iOS shows its prompt once; a refusal needs the Settings app")

        let reminders = await permissions.request(.reminders)
        XCTAssertEqual(reminders, .granted)
        XCTAssertEqual(probe.prompted, [.reminders])
        XCTAssertNil(permissions.awaiting)
        XCTAssertEqual(permissions.grantedPermissions(), [.reminders])
        XCTAssertEqual(permissions.status(.accessibility), .notDetermined, "The probe decides; the live one says unavailable")
    }

    func testPermissionNotices() {
        XCTAssertTrue(ChatScreenModel.permissionNotice(for: .calendars, status: .denied).contains("Settings"))
        XCTAssertTrue(ChatScreenModel.permissionNotice(for: .calendars, status: .limited).contains("full access"))
        XCTAssertTrue(ChatScreenModel.permissionNotice(for: .reminders, status: .restricted).contains("managed"))
    }

    // MARK: - Around the card

    func testTheActivityLogRecordsTheAction() async throws {
        let graph = makeGraph()
        _ = try XCTUnwrap(await askForEvent(graph))
        await waitUntilArmed(graph)
        graph.model.approve()
        await waitUntil { !graph.chat.isStreaming }

        var entries: [ActionLogEntry] = []
        for _ in 0..<50 where entries.isEmpty {
            entries = await graph.model.services.recentActions(10)
            if entries.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(entries.first?.tool, "calendar_create_event")
        XCTAssertEqual(entries.first?.decision, "approved")
        XCTAssertEqual(ActivityLogPage.outcome(of: try XCTUnwrap(entries.first)), "Done")

        await graph.model.services.clearActionLog()
        let cleared = await graph.model.services.recentActions(10)
        XCTAssertTrue(cleared.isEmpty)
    }

    func testTheLiveActivityAlertsWhenAnActionWaitsWhileAway() {
        let start = Date()
        let working = ReplyActivityAttributes.ContentState(stage: .writing, detail: "", model: "Opus 5",
                                                           startedAt: start, finishedAt: nil)
        let waiting = ReplyActivityAttributes.ContentState(stage: .waitingForApproval,
                                                           detail: "Add “Dentist” to Calendar", model: "Opus 5",
                                                           startedAt: start, finishedAt: nil)
        let alert = ReplyActivityController.approvalAlert(from: working, to: waiting, isAppActive: false)
        XCTAssertEqual(alert?.title, "Needs your OK")
        XCTAssertEqual(alert?.body, "Add “Dentist” to Calendar")
        XCTAssertNil(ReplyActivityController.approvalAlert(from: working, to: waiting, isAppActive: true))
        XCTAssertNil(ReplyActivityController.approvalAlert(from: waiting, to: waiting, isAppActive: false))
    }

    func testAnApprovalWhileAwayCanNotify() async throws {
        let graph = makeGraph()
        let center = try XCTUnwrap(graph.notificationCenter as? InertReplyNotificationCenter)
        graph.settings.mobile.notifyWhenAway = true
        graph.model.composerText = Self.request
        graph.model.send()
        graph.sceneEnteredBackground()
        await waitUntil { graph.model.pendingApproval != nil }
        await waitUntil { !center.posted.isEmpty }
        XCTAssertEqual(center.posted.first?.title, ReplyNotifier.approvalTitle)
        graph.model.declineApproval()
        await waitUntil { !graph.chat.isStreaming }
    }

    func testTheSettingsCatalogOffersCalendarAndReminders() {
        let graph = makeGraph()
        XCTAssertEqual(MobileToolCatalog.groups, [.calendar, .reminders])
        XCTAssertEqual(Set(graph.tools.allTools.map(\.name)),
                       ["calendar_list_events", "calendar_create_event", "reminders_list", "reminders_create"])
        XCTAssertEqual(MobileToolCatalog.actionLogMaxAge(for: .forever), 90 * 86_400)
        XCTAssertEqual(MobileToolCatalog.actionLogMaxAge(for: .week), 7 * 86_400)
    }
}
