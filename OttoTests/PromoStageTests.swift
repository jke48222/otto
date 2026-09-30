//
//  PromoStageTests.swift
//  Otto
//
//  The promo stage's scripted client, its tool turns, stage clock and privacy seam, and the pointer easing
//  (the marketing footage depends on all of them).
//

import XCTest
@testable import Otto

final class PromoStageTests: XCTestCase {
    private func request(prompt: String) -> MessagesRequest {
        MessagesRequest(
            model: .opus5,
            system: "",
            messages: [["role": "user", "content": [["type": "text", "text": .string(prompt)]]]],
            maxTokens: 1024,
            effort: .medium,
            webAccess: true
        )
    }

    private func collect(_ prompt: String) async throws -> [StreamEvent] {
        try await collect(request(prompt: prompt))
    }

    private func collect(_ request: MessagesRequest) async throws -> [StreamEvent] {
        var events: [StreamEvent] = []
        for try await event in PromoLLMClient(timeScale: 0).stream(request) {
            events.append(event)
        }
        return events
    }

    private func toolDefinition(_ name: String) -> JSONValue {
        ["name": .string(name), "description": "Test.", "input_schema": ["type": "object", "properties": [:]]]
    }

    /// A tool-capable request: context blocks before the typed text, as ChatSession sends them.
    private func actionRequest(_ messages: [JSONValue], tools: [String] = ["calendar_create_event"]) -> MessagesRequest {
        MessagesRequest(model: .opus5, system: "", messages: messages, maxTokens: 1024, effort: .medium,
                        webAccess: true, clientTools: tools.map(toolDefinition), toolChoice: nil)
    }

    private func typedEntry(_ prompt: String) -> JSONValue {
        ["role": "user", "content": [
            ["type": "text", "text": "<context>Local time: Tuesday</context>"],
            ["type": "text", "text": .string(prompt)],
        ]]
    }

    private func streamedText(_ events: [StreamEvent]) -> String {
        events.reduce(into: "") { text, event in
            if case .textDelta(let delta) = event { text += delta }
        }
    }

    private func completed(_ events: [StreamEvent]) -> StreamResult? {
        guard case .completed(let result)? = events.last else { return nil }
        return result
    }

    func testEveryConversationStreamsItsWholeAnswer() async throws {
        for conversation in PromoContent.all {
            let events = try await collect(conversation.prompt)
            var text = ""
            var sources: [SourceLink] = []
            var finishedTools = Set<String>()
            var completed: StreamResult?
            for event in events {
                switch event {
                case .textDelta(let delta): text += delta
                case .sources(let links): sources += links
                case .toolActivity(let activity) where activity.isDone: finishedTools.insert(activity.id)
                case .completed(let result): completed = result
                default: break
                }
            }
            XCTAssertEqual(text, conversation.answer, conversation.prompt)
            XCTAssertEqual(sources, conversation.allSources, conversation.prompt)
            XCTAssertEqual(finishedTools.count, conversation.activities.count, conversation.prompt)
            XCTAssertEqual(completed?.stopReason, "end_turn")
            guard case .completed = events.last else { return XCTFail("stream must end with .completed") }
        }
    }

    func testActionTurnStreamsItsSentenceThenStopsForTheTool() async throws {
        let schedule = PromoContent.schedule
        let call = try XCTUnwrap(schedule.toolCall)
        let events = try await collect(actionRequest([typedEntry(schedule.prompt)]))
        XCTAssertEqual(streamedText(events), call.sentence)
        let result = try XCTUnwrap(completed(events))
        XCTAssertEqual(result.stopReason, "tool_use")
        var started: String?
        var ready: (name: String, input: JSONValue?)?
        for event in events {
            if case .toolUseStarted(let id, _) = event { started = id }
            if case .toolUseReady(let id, let name, let input, _) = event {
                XCTAssertEqual(id, started)
                ready = (name, input)
            }
        }
        XCTAssertEqual(ready?.name, "calendar_create_event")
        XCTAssertEqual(ready?.input, call.input)
        XCTAssertEqual(result.content.last?.typeName, "tool_use")
        XCTAssertTrue(events.contains { if case .thinkingStarted = $0 { return true } else { return false } })
    }

    func testToolResultRequestStreamsTheConfirmation() async throws {
        let schedule = PromoContent.schedule
        let messages: [JSONValue] = [
            typedEntry(schedule.prompt),
            ["role": "assistant", "content": [["type": "text", "text": .string(schedule.answer)]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_x", "content": "Added."]]],
        ]
        let events = try await collect(actionRequest(messages))
        XCTAssertEqual(streamedText(events), schedule.afterTool)
        XCTAssertEqual(completed(events)?.stopReason, "end_turn")
        XCTAssertFalse(events.contains { if case .toolUseStarted = $0 { return true } else { return false } })
    }

    func testActionTurnWithoutItsToolSaysItIsOff() async throws {
        let events = try await collect(actionRequest([typedEntry(PromoContent.schedule.prompt)], tools: []))
        XCTAssertEqual(streamedText(events), "That action is turned off, so I can't do it from here.")
        XCTAssertEqual(completed(events)?.stopReason, "end_turn")
    }

    func testTypedPromptSkipsToolResultsAndContextBlocks() {
        let messages: [JSONValue] = [
            typedEntry("Schedule Sam's review for tomorrow at 10"),
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_x", "content": "ok"]]],
        ]
        XCTAssertEqual(PromoLLMClient.lastTypedPrompt(in: messages), "Schedule Sam's review for tomorrow at 10")
        XCTAssertTrue(PromoLLMClient.startsWithToolResults(messages))
        XCTAssertFalse(PromoLLMClient.startsWithToolResults([typedEntry("hi")]))
    }

    /// Tuesday 8 October 2030, 9:41 AM in New York: the menu bar's "Tue 9:41 AM", in the future so Undo
    /// stays live, and "tomorrow at 10" is Wednesday the 9th.
    func testStageClockIsATuesdayMorningInTheFuture() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = PromoContent.stageZone
        let parts = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: PromoContent.stageNow)
        XCTAssertEqual(parts.year, 2030)
        XCTAssertEqual(parts.month, 10)
        XCTAssertEqual(parts.day, 8)
        XCTAssertEqual(parts.weekday, 3, "Tuesday")
        XCTAssertEqual(parts.hour, 9)
        XCTAssertEqual(parts.minute, 41)
        XCTAssertEqual(PromoContent.stageZone.identifier, "America/New_York")
        XCTAssertGreaterThan(PromoContent.stageNow, Date())
        XCTAssertEqual(PromoContent.stageClock.now(), PromoContent.stageNow)
        let input = try XCTUnwrap(PromoContent.schedule.toolCall?.input)
        XCTAssertEqual(input["start"]?.stringValue, "2030-10-09T10:00")
        XCTAssertEqual(input["end"]?.stringValue, "2030-10-09T10:30")
        XCTAssertEqual(input["calendar"]?.stringValue, "Work")
    }

    func testPromptsMatchTheirConversation() {
        XCTAssertEqual(PromoContent.conversation(forPrompt: "schedule sam's review for tomorrow at 10").prompt,
                       PromoContent.schedule.prompt)
        XCTAssertEqual(PromoContent.conversation(forPrompt: "  what's wrong in this screenshot? ").prompt, PromoContent.screenshot.prompt)
        XCTAssertEqual(PromoContent.conversation(forPrompt: "anything else").prompt, PromoContent.summarize.prompt)
    }

    /// The media must never show a real website: every promo address is on the reserved `.example` TLD.
    func testPromoAddressesAreReservedExampleDomains() {
        XCTAssertEqual(PromoContent.articleURL.host?.hasSuffix(".example"), true)
        for conversation in PromoContent.all {
            for source in conversation.allSources {
                XCTAssertEqual(source.url.host?.hasSuffix(".example"), true, source.url.absoluteString)
            }
            for activity in conversation.activities where activity.kind == .webFetch {
                XCTAssertTrue(activity.label.hasSuffix(".example"), activity.label)
            }
        }
    }

    /// The privacy seam: with a stand-in set, opening records it and never reads the real frontmost app.
    @MainActor
    func testDebugFrontmostAppStandsInForTheRealOne() throws {
        let suite = "otto.tests.promo.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, usesKeychain: false)
        settings.suggestBrowserTab = false
        let chat = ChatSession(settings: settings, makeClient: { PromoLLMClient(timeScale: 0) })
        let viewModel = NotchViewModel(settings: settings, chat: chat)
        let studio = AppRef(pid: -4_141, bundleID: "example.promo.studio", name: "Studio", bundleURL: nil)
        viewModel.debugFrontmostApp = studio
        viewModel.open(reason: .hover, focus: false)
        XCTAssertEqual(viewModel.openContextApp, studio)
        viewModel.close()
        viewModel.debugFrontmostApp = nil
        viewModel.open(reason: .hover, focus: false)
        XCTAssertNotEqual(viewModel.openContextApp, studio)
    }

    /// The whole action path on the promo cast: the real registry and executor over the demo calendar on the
    /// stage clock. The card comes up, the approved call adds the event with a live Undo, the confirmation
    /// streams, and nothing on stage names a real app or offers to paste.
    @MainActor
    func testCastRunsAnActionTurnThroughTheRealExecutor() async throws {
        let cast = try XCTUnwrap(PromoCast.make())
        defer { cast.tearDown() }
        await cast.warmUp()
        XCTAssertNotNil(cast.tools.tool(named: "calendar_create_event"))
        cast.viewModel.open(reason: .hover, focus: false)
        XCTAssertEqual(cast.viewModel.openContextApp, PromoContent.studioApp)

        let ok = await cast.preRollActionTurn(PromoContent.schedule)
        XCTAssertTrue(ok)
        XCTAssertEqual(cast.timing.scale, 1)
        let assistant = try XCTUnwrap(cast.chat.messages.last(where: { $0.role == .assistant }))
        let call = try XCTUnwrap(assistant.toolCalls.first)
        XCTAssertEqual(call.name, "calendar_create_event")
        XCTAssertEqual(call.status, .succeeded)
        let undo = try XCTUnwrap(call.undo)
        XCTAssertGreaterThan(undo.expires, Date())
        XCTAssertTrue(assistant.text.hasSuffix(try XCTUnwrap(PromoContent.schedule.afterTool)), assistant.text)
        let events = try await cast.eventKit.events(from: PromoContent.stageNow,
                                                     to: PromoContent.stageNow.addingTimeInterval(3 * 86_400),
                                                     calendarIDs: nil)
        let added = try XCTUnwrap(events.first { $0.title == "Release notes review" })
        XCTAssertEqual(added.calendarTitle, "Work")
        XCTAssertNil(cast.privacyProblem())
    }

    /// The voice take's scripted recognizer builds the launch-update prompt word by word, ends on the whole
    /// prompt (what finish delivers and sends), and the prompt fits the closed pill without head truncation.
    func testVoiceScriptBuildsTheLaunchUpdatePrompt() throws {
        let prompt = PromoContent.launchUpdate.prompt
        XCTAssertLessThanOrEqual(prompt.count, 40)
        let steps = PromoContent.voiceScript
        XCTAssertEqual(steps.last?.text, prompt)
        XCTAssertEqual(steps.first?.text, "Write")
        var previous = ""
        for step in steps {
            XCTAssertTrue(step.text.hasPrefix(previous), step.text)
            XCTAssertTrue((0.3...0.8).contains(step.level), "\(step.level)")
            previous = step.text
        }
        let total = steps.reduce(Duration.zero) { $0 + $1.delay }
        XCTAssertEqual(total.timeInterval, 1.8, accuracy: 0.1)
    }

    /// The Shelf beat's files are real files on disk with the desktop icons' names, and the painted
    /// thumbnailer draws every one of them (Quick Look and system icons never appear on stage).
    func testShelfFixturesArePaintedWithoutQuickLook() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("otto-promo-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = try PromoContent.writeFixtures(PromoContent.desktopFixtures, to: folder)
        XCTAssertEqual(urls.map(\.lastPathComponent),
                       ["launch-plan.md", "screenshot.png", "invoice.pdf", "release-notes.md", "hero-draft.png"])
        XCTAssertEqual(PromoContent.shelfFixtures.map(\.name), ["release-notes.md", "hero-draft.png"])
        let thumbnailer = PromoShelfThumbnailer()
        for url in urls {
            let image = await thumbnailer.thumbnail(for: url, size: CGSize(width: 64, height: 64), scale: 2)
            XCTAssertNotNil(image, url.lastPathComponent)
        }
    }

    /// recents.png's rows come from the film's world, the first is the current conversation, and they span
    /// Today, Yesterday and the previous week.
    func testRecentSummariesSpanThreeDays() {
        let current = UUID()
        let rows = PromoContent.recentSummaries(currentID: current, now: PromoContent.stageNow)
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows.first?.id, current)
        XCTAssertEqual(rows.first?.title, "What to fix before Friday")
        XCTAssertTrue(rows.allSatisfy { $0.updatedAt <= PromoContent.stageNow })
        XCTAssertEqual(Set(rows.map(\.id)).count, 6)
    }

    func testEasingIsMonotonicFromZeroToOne() {
        let easing = PromoEasing(x1: 0.42, y1: 0, x2: 0.18, y2: 1)
        XCTAssertEqual(easing.value(at: 0), 0)
        XCTAssertEqual(easing.value(at: 1), 1)
        var previous = 0.0
        for step in 1...100 {
            let value = easing.value(at: Double(step) / 100)
            XCTAssertGreaterThanOrEqual(value, previous - 1e-9)
            previous = value
        }
        let linear = PromoEasing(x1: 0.25, y1: 0.25, x2: 0.75, y2: 0.75)
        XCTAssertEqual(linear.value(at: 0.3), 0.3, accuracy: 1e-4)
    }

    @MainActor
    func testThrowawaySettingsKeepTheKeyInMemory() throws {
        let suite = "otto.tests.promo.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, usesKeychain: false)
        XCTAssertEqual(settings.apiKey, "")
        settings.apiKey = "  sk-ant-test-in-memory  "
        XCTAssertEqual(settings.apiKey, "sk-ant-test-in-memory")
        XCTAssertNil(settings.lastSettingsError)
        settings.apiKey = ""
        XCTAssertNil(settings.lastSettingsError)
    }
}
