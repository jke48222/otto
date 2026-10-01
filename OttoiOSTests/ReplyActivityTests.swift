//
//  ReplyActivityTests.swift
//  OttoiOSTests
//
//  The reply's Live Activity: what each phase shows, how a finished, failed or paused reply reads, and when the
//  controller starts, updates and ends the activity.
//

import XCTest
@testable import Otto

@MainActor
final class ReplyActivityTests: XCTestCase {
    private typealias State = ReplyActivityAttributes.ContentState
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Pure state

    func testWorkingStates() {
        XCTAssertNil(ReplyActivityController.workingState(for: .idle, model: "Opus 5", startedAt: start))
        let cases: [(ReplyPhase, State.Stage, String)] = [
            (.connecting, .connecting, ""),
            (.thinking, .thinking, ""),
            (.searching(label: "Searching “tide times”"), .searching, "Searching “tide times”"),
            (.writing, .writing, ""),
            (.runningAction(label: "Adding to Calendar"), .acting, "Adding to Calendar"),
            (.awaitingApproval(label: "Add “Dentist” to Calendar"), .waitingForApproval, "Add “Dentist” to Calendar"),
        ]
        for (phase, stage, detail) in cases {
            let state = ReplyActivityController.workingState(for: phase, model: "Opus 5", startedAt: start)
            XCTAssertEqual(state?.stage, stage, "\(phase)")
            XCTAssertEqual(state?.detail, detail, "\(phase)")
            XCTAssertEqual(state?.model, "Opus 5")
            XCTAssertEqual(state?.startedAt, start)
            XCTAssertNil(state?.finishedAt)
        }
    }

    func testDetailsAreCleanedAndCapped() {
        let noisy = "Searching \u{202E}" + String(repeating: "x", count: 300)
        let state = ReplyActivityController.workingState(for: .searching(label: noisy), model: "Opus 5", startedAt: start)
        XCTAssertFalse(state?.detail.contains("\u{202E}") ?? true)
        XCTAssertLessThanOrEqual(state?.detail.count ?? .max, 120)
    }

    func testAFinishedReplyShowsItsFirstLineOnlyWhenPreviewsAreOn() throws {
        let working = try XCTUnwrap(ReplyActivityController.workingState(for: .writing, model: "Opus 5", startedAt: start))
        let message = ChatMessage(role: .assistant, text: "Low tide is at 4:12 PM.\n\nMore detail follows.",
                                  state: .complete, model: "claude-sonnet-5")
        let end = start.addingTimeInterval(9)

        let shown = try XCTUnwrap(ReplyActivityController.finishedState(for: message, from: working, showsText: true,
                                                                         at: end))
        XCTAssertEqual(shown.stage, .replied)
        XCTAssertEqual(shown.title, "Otto replied")
        XCTAssertTrue(shown.detail.hasPrefix("Low tide is at 4:12 PM."))
        XCTAssertEqual(shown.model, "Sonnet 5")
        XCTAssertEqual(shown.finishedAt, end)
        XCTAssertTrue(shown.isFinished)
        XCTAssertFalse(shown.isWorking)

        let hidden = try XCTUnwrap(ReplyActivityController.finishedState(for: message, from: working, showsText: false,
                                                                          at: end))
        XCTAssertEqual(hidden.detail, "")
    }

    func testAFailedReplyReadsAsFailed() throws {
        let working = try XCTUnwrap(ReplyActivityController.workingState(for: .thinking, model: "Opus 5", startedAt: start))
        let message = ChatMessage(role: .assistant, state: .failed("Claude is overloaded right now."))
        let state = try XCTUnwrap(ReplyActivityController.finishedState(for: message, from: working, showsText: true,
                                                                        at: start))
        XCTAssertEqual(state.stage, .failed)
        XCTAssertEqual(state.symbol, "exclamationmark.triangle.fill")
    }

    func testAStoppedReplyHasNothingToShow() throws {
        let working = try XCTUnwrap(ReplyActivityController.workingState(for: .writing, model: "Opus 5", startedAt: start))
        let message = ChatMessage(role: .assistant, text: "Partial", state: .cancelled)
        XCTAssertNil(ReplyActivityController.finishedState(for: message, from: working, showsText: true, at: start))
    }

    func testPausedState() throws {
        let working = try XCTUnwrap(ReplyActivityController.workingState(for: .writing, model: "Opus 5", startedAt: start))
        let paused = ReplyActivityController.pausedState(from: working, at: start.addingTimeInterval(30))
        XCTAssertEqual(paused.stage, .paused)
        XCTAssertEqual(paused.title, "Paused")
        XCTAssertTrue(paused.isFinished)
        XCTAssertEqual(paused.startedAt, start)
    }

    func testWaitingForApprovalDoesNotBreathe() throws {
        let state = try XCTUnwrap(ReplyActivityController.workingState(for: .awaitingApproval(label: "OK?"), model: "Opus 5",
                                                                       startedAt: start))
        XCTAssertFalse(state.isWorking)
        XCTAssertEqual(state.title, "Needs your OK")
    }

    func testStatesRoundTripThroughCodable() throws {
        let state = State(stage: .searching, detail: "Searching “otters”", model: "Opus 5", startedAt: start,
                          finishedAt: nil)
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(State.self, from: data), state)
    }

    // MARK: - Controller

    func testTheActivityFollowsAReplyAndReportsItWhenAway() async throws {
        let graph = makeGraph(latencyScale: 0.05)
        let host = try XCTUnwrap(graph.activities as? InertReplyActivities)
        graph.replyActivity.start()
        XCTAssertEqual(host.log, ["endAll"], "Activities a previous launch left behind end first")

        graph.model.composerText = "Question"
        graph.model.send()
        graph.sceneEnteredBackground()
        await waitUntil { !graph.chat.isStreaming }
        await waitUntil { host.log.contains { $0.contains(" replied") } }

        XCTAssertTrue(host.log.contains { $0.hasPrefix("request ") })
        XCTAssertNotNil(graph.replyActivity.current)
        XCTAssertFalse(host.log.contains { $0.hasSuffix(" alert") }, "No alert unless notifications are asked for")

        graph.sceneBecameActive()
        XCTAssertNil(graph.replyActivity.current)
        XCTAssertTrue(host.log.last?.hasPrefix("end ") ?? false, host.log.joined(separator: "\n"))
    }

    func testTheActivityAlertsWhenNotificationsAreOn() async throws {
        let graph = makeGraph(latencyScale: 0.05)
        let host = try XCTUnwrap(graph.activities as? InertReplyActivities)
        graph.settings.mobile.notifyWhenAway = true
        graph.replyActivity.start()

        graph.model.composerText = "Question"
        graph.model.send()
        graph.sceneEnteredBackground()
        await waitUntil { !graph.chat.isStreaming }
        await waitUntil { host.log.contains { $0.hasSuffix(" replied alert") } }
    }

    func testAReplyThatFinishesOnScreenEndsItsActivity() async throws {
        let graph = makeGraph(latencyScale: 0.05)
        let host = try XCTUnwrap(graph.activities as? InertReplyActivities)
        graph.replyActivity.start()

        await ask("Question", in: graph)
        await waitUntil { graph.replyActivity.current == nil }
        XCTAssertTrue(host.log.contains { $0.hasPrefix("request ") })
        XCTAssertTrue(host.log.last?.hasPrefix("end ") ?? false, host.log.joined(separator: "\n"))
    }

    func testNoActivityWhenTurnedOff() async throws {
        let graph = makeGraph(latencyScale: 0.05)
        let host = try XCTUnwrap(graph.activities as? InertReplyActivities)
        graph.settings.mobile.liveActivities = false
        graph.replyActivity.start()

        await ask("Question", in: graph)
        XCTAssertEqual(host.log, ["endAll"])
    }

    func testNoActivityWhenTheSystemTurnedThemOff() async throws {
        let graph = makeGraph(latencyScale: 0.05)
        let host = try XCTUnwrap(graph.activities as? InertReplyActivities)
        host.areActivitiesEnabled = false
        graph.replyActivity.start()

        await ask("Question", in: graph)
        XCTAssertEqual(host.log, ["endAll"])
    }

    func testRunningOutOfTimeLeavesTheActivityPaused() async throws {
        let graph = makeGraph(latencyScale: 1)
        let host = try XCTUnwrap(graph.activities as? InertReplyActivities)
        let time = try XCTUnwrap(graph.backgroundTime as? InertBackgroundTime)
        graph.replyActivity.start()

        graph.model.composerText = "Question"
        graph.model.send()
        await waitUntil { host.log.contains { $0.hasPrefix("request ") } }
        graph.sceneEnteredBackground()

        time.expire()

        await waitUntil { host.log.contains { $0.hasSuffix(" paused") } }
        XCTAssertEqual(graph.replyActivity.current?.state.stage, .paused)
    }
}
