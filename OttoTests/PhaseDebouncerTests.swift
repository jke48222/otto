//
//  PhaseDebouncerTests.swift
//  OttoTests
//
//  The phase glyph's minimum dwell: non-urgent phases wait their turn, idle and awaiting-approval
//  never wait, and the controller follows chat.phase through the debouncer once started.
//

import XCTest
@testable import Otto

final class PhaseDebouncerTests: XCTestCase {
    func testFirstPhaseShowsImmediately() {
        var debouncer = PhaseDebouncer()
        let result = debouncer.update(.connecting, now: 100)
        XCTAssertEqual(result.display, .connecting)
        XCTAssertNil(result.recheckAt)
    }

    func testSamePhaseIsANoOp() {
        var debouncer = PhaseDebouncer()
        _ = debouncer.update(.thinking, now: 0)
        let result = debouncer.update(.thinking, now: 0.1)
        XCTAssertEqual(result.display, .thinking)
        XCTAssertNil(result.recheckAt)
    }

    func testChangeWithinDwellWaitsAndAsksForARecheck() {
        var debouncer = PhaseDebouncer()
        _ = debouncer.update(.thinking, now: 10)
        let early = debouncer.update(.writing, now: 10.1)
        XCTAssertEqual(early.display, .thinking)
        XCTAssertEqual(early.recheckAt ?? 0, 10.4, accuracy: 1e-9)

        let atRecheck = debouncer.update(.writing, now: 10.4)
        XCTAssertEqual(atRecheck.display, .writing)
        XCTAssertNil(atRecheck.recheckAt)
    }

    func testFlickerCollapsesToTheLatestPhase() {
        var debouncer = PhaseDebouncer()
        _ = debouncer.update(.thinking, now: 0)
        XCTAssertEqual(debouncer.update(.searching(label: "Searching"), now: 0.1).display, .thinking)
        XCTAssertEqual(debouncer.update(.writing, now: 0.2).display, .thinking)
        // Back to the displayed phase before the dwell ends: nothing to recheck.
        let back = debouncer.update(.thinking, now: 0.3)
        XCTAssertEqual(back.display, .thinking)
        XCTAssertNil(back.recheckAt)
        XCTAssertEqual(debouncer.update(.writing, now: 0.5).display, .writing)
    }

    func testLabelChangeCountsAsAChange() {
        var debouncer = PhaseDebouncer()
        _ = debouncer.update(.searching(label: "a"), now: 0)
        XCTAssertEqual(debouncer.update(.searching(label: "b"), now: 0.2).display, .searching(label: "a"))
        XCTAssertEqual(debouncer.update(.searching(label: "b"), now: 0.4).display, .searching(label: "b"))
    }

    func testUrgentPhasesBypassTheDwell() {
        var debouncer = PhaseDebouncer()
        _ = debouncer.update(.writing, now: 0)
        let approval = debouncer.update(.awaitingApproval(label: "Run “Resize”"), now: 0.05)
        XCTAssertEqual(approval.display, .awaitingApproval(label: "Run “Resize”"))
        XCTAssertNil(approval.recheckAt)

        // The approval phase itself dwells before a non-urgent phase replaces it…
        XCTAssertEqual(debouncer.update(.runningAction(label: "Resizing"), now: 0.1).display,
                       .awaitingApproval(label: "Run “Resize”"))
        // …but idle never waits.
        let idle = debouncer.update(.idle, now: 0.15)
        XCTAssertEqual(idle.display, .idle)
        XCTAssertNil(idle.recheckAt)
    }

    func testCustomDwell() {
        var debouncer = PhaseDebouncer(minimumDwell: 1)
        XCTAssertEqual(debouncer.minimumDwell, 1)
        _ = debouncer.update(.thinking, now: 0)
        XCTAssertEqual(debouncer.update(.writing, now: 0.9).recheckAt, 1)
        XCTAssertEqual(debouncer.update(.writing, now: 1).display, .writing)
    }

    func testZeroDwellNeverWaits() {
        var debouncer = PhaseDebouncer(minimumDwell: 0)
        _ = debouncer.update(.thinking, now: 0)
        XCTAssertEqual(debouncer.update(.writing, now: 0).display, .writing)
    }
}

@MainActor
final class GlanceControllerPhaseTests: XCTestCase {
    private func makeChat() -> (AppSettings, ChatSession) {
        let settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        return (settings, ChatSession(settings: settings, makeClient: { MockLLMClient(latencyScale: 0) }))
    }

    private func streaming(text: String) -> [ChatMessage] {
        [ChatMessage(role: .user, text: "Hi"),
         ChatMessage(role: .assistant, text: text, state: .streaming, model: "claude-opus-5")]
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testNotStartedIgnoresChatPhase() async {
        let (settings, chat) = makeChat()
        let glance = GlanceController.inert(settings: settings, chat: chat)
        chat.debugSeed(messages: streaming(text: "Hello"), isStreaming: true)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(chat.phase, .writing)
        XCTAssertEqual(glance.displayedPhase, .idle)
    }

    func testStartedFollowsChatPhase() async {
        let (settings, chat) = makeChat()
        let glance = GlanceController.inert(settings: settings, chat: chat)
        glance.start()
        chat.debugSeed(messages: streaming(text: "Hello"), isStreaming: true)
        await waitUntil { glance.displayedPhase == .writing }
        XCTAssertEqual(glance.displayedPhase, .writing)

        chat.debugSeed(messages: [], isStreaming: false)
        await waitUntil { glance.displayedPhase == .idle }
        XCTAssertEqual(glance.displayedPhase, .idle)
    }

    func testStartAdoptsTheCurrentPhase() {
        let (settings, chat) = makeChat()
        chat.debugSeed(messages: streaming(text: ""), isStreaming: true)
        let glance = GlanceController.inert(settings: settings, chat: chat)
        glance.start()
        XCTAssertEqual(glance.displayedPhase, chat.phase)
        XCTAssertTrue(glance.displayedPhase.isActive)
    }

    func testDwellDefersAChangeUntilTheRecheck() async {
        let (settings, chat) = makeChat()
        let glance = GlanceController.inert(settings: settings, chat: chat)
        var clock = Date(timeIntervalSinceReferenceDate: 1_000)
        glance.now = { clock }
        var requested: [Duration] = []
        var release: CheckedContinuation<Void, Never>?
        glance.sleep = { duration in
            requested.append(duration)
            await withCheckedContinuation { release = $0 }
        }

        var thinking = ChatMessage(role: .assistant, state: .streaming, model: "claude-opus-5")
        thinking.isThinking = true
        chat.debugSeed(messages: [thinking], isStreaming: true)
        glance.start()
        XCTAssertEqual(glance.displayedPhase, .thinking)

        clock = clock.addingTimeInterval(0.1)
        chat.debugSeed(messages: streaming(text: "Hello"), isStreaming: true)
        await waitUntil { !requested.isEmpty && release != nil }
        XCTAssertEqual(glance.displayedPhase, .thinking, "the change waits for the dwell")
        XCTAssertEqual(requested.count, 1)
        XCTAssertGreaterThanOrEqual(requested.first ?? .zero, .milliseconds(299))
        XCTAssertLessThanOrEqual(requested.first ?? .zero, .milliseconds(301))

        clock = clock.addingTimeInterval(0.35)
        release?.resume()
        await waitUntil { glance.displayedPhase == .writing }
        XCTAssertEqual(glance.displayedPhase, .writing)
    }

    func testDebugSeedSetsPhaseAndPreview() {
        let (settings, chat) = makeChat()
        let glance = GlanceController.inert(settings: settings, chat: chat)
        let preview = ReplyPreview(id: UUID(), outcome: .refused, text: "Otto can't help with that one.")
        glance.debugSeed(phase: .searching(label: "Searching the web"), preview: preview)
        XCTAssertEqual(glance.displayedPhase, .searching(label: "Searching the web"))
        XCTAssertEqual(glance.preview, preview)
    }
}
