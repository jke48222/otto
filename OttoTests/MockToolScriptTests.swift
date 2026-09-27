//
//  MockToolScriptTests.swift
//  OttoTests
//
//  The demo client's tool scripting: only exact phrases at word boundaries ask for a tool, only when the
//  request offers it, never on the wrap-up request, and never for a prompt the self-test or the promo stage
//  types. After a round it answers from the first tool result.
//

import XCTest
@testable import Otto

private func userEntry(_ blocks: [JSONValue]) -> JSONValue {
    ["role": "user", "content": .array(blocks)]
}

private func typed(_ text: String) -> JSONValue {
    userEntry([["type": "text", "text": .string(text)]])
}

private func definition(_ name: String) -> JSONValue {
    ["name": .string(name), "description": "Test.", "eager_input_streaming": true,
     "input_schema": ["type": "object", "properties": [:]]]
}

private let demoToolNames = ["calendar_create_event", "run_applescript", "run_shortcut"]

private func request(_ messages: [JSONValue], tools: [String] = demoToolNames,
                     toolChoice: JSONValue? = nil) -> MessagesRequest {
    MessagesRequest(model: .opus5, system: "You are Otto.", messages: messages, maxTokens: 64_000, effort: .medium,
                    webAccess: true, clientTools: tools.map(definition), toolChoice: toolChoice)
}

private func events(of request: MessagesRequest) -> [StreamEvent] {
    MockLLMClient.makeScript(for: request).compactMap { step in
        if case .emit(let event) = step { return event }
        return nil
    }
}

private func completedResult(_ events: [StreamEvent]) -> StreamResult? {
    guard case .completed(let result)? = events.last else { return nil }
    return result
}

final class MockToolScriptTests: XCTestCase {
    /// Every prompt the self-test types (SelfTest.swift) plus the attachments-only placeholder.
    private let selfTestPrompts = [
        "What's new in Swift",
        "What's new in Swift?",
        "Tell me more",
        "What color is this?",
        ChatSession.attachmentsOnlyPrompt,
    ]

    func testExactPhrasesPickTheirTools() {
        XCTAssertEqual(MockLLMClient.scriptedTool(forPrompt: "Please run my shortcut on these")?.name, "run_shortcut")
        XCTAssertEqual(MockLLMClient.scriptedTool(forPrompt: "RUN MY SHORTCUT")?.name, "run_shortcut")
        XCTAssertEqual(MockLLMClient.scriptedTool(forPrompt: "Add the dentist to my calendar")?.name,
                       "calendar_create_event")
        XCTAssertEqual(MockLLMClient.scriptedTool(forPrompt: "can you run a script for me")?.name, "run_applescript")
    }

    func testOrdinaryQuestionsNeverPickATool() {
        let questions = [
            "What's the keyboard shortcut for screenshots?",
            "my calendar app is slow",
            "explain JavaScript",
            "How do I run my shortcuts from the menu bar?",
            "rerun my shortcut",
            "add to my calendars",
            "Is it safe to run a scripted install?",
            "What does AppleScript do?",
        ]
        for question in questions {
            XCTAssertNil(MockLLMClient.scriptedTool(forPrompt: question), question)
        }
    }

    func testNoSelfTestOrPromoPromptTriggersATool() {
        let prompts = selfTestPrompts + PromoContent.all.map(\.prompt)
        XCTAssertGreaterThanOrEqual(prompts.count, 9)
        for prompt in prompts {
            XCTAssertNil(MockLLMClient.scriptedTool(forPrompt: prompt), prompt)
            let script = events(of: request([typed(prompt)]))
            XCTAssertEqual(completedResult(script)?.stopReason, "end_turn", prompt)
            XCTAssertFalse(script.contains { if case .toolUseStarted = $0 { return true } else { return false } }, prompt)
        }
    }

    func testCalendarInputUsesTomorrowAtThreePM() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 12
        components.day = 31
        components.hour = 10
        let now = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))
        let tool = try XCTUnwrap(MockLLMClient.scriptedTool(forPrompt: "add lunch to my calendar", now: now))
        XCTAssertEqual(tool.input, ["title": "Dentist", "start": "2027-01-01T15:00", "end": "2027-01-01T16:00"])
    }

    func testToolScriptStreamsThinkingASentenceAndTheCall() throws {
        let script = events(of: request([typed("run my shortcut")]))
        let thinkingDeltas = script.filter { if case .thinkingDelta = $0 { return true } else { return false } }
        XCTAssertEqual(thinkingDeltas.count, 2)

        let sentence = script.compactMap { event -> String? in
            if case .textDelta(let text) = event { return text }
            return nil
        }.joined()
        XCTAssertEqual(sentence, "I'll run your **Resize Images** shortcut on your screenshots.")

        var startedID: String?
        var readyInput: JSONValue?
        var rawInput: String?
        for event in script {
            switch event {
            case .toolUseStarted(let id, let name):
                XCTAssertEqual(name, "run_shortcut")
                startedID = id
            case .toolUseReady(let id, let name, let input, let raw):
                XCTAssertEqual(id, startedID)
                XCTAssertEqual(name, "run_shortcut")
                readyInput = input
                rawInput = raw
            default:
                break
            }
        }
        let expectedInput: JSONValue = ["name": "Resize Images", "input": "~/Desktop/Screenshots"]
        XCTAssertEqual(readyInput, expectedInput)
        XCTAssertEqual(try rawInput.map { try JSONValue.decode($0) }, expectedInput)

        let result = try XCTUnwrap(completedResult(script))
        XCTAssertEqual(result.stopReason, "tool_use")
        XCTAssertEqual(result.content.map { $0.typeName ?? "?" }, ["thinking", "text", "tool_use"])
        XCTAssertFalse(result.content[0]["signature"]?.stringValue?.isEmpty ?? true)
        XCTAssertEqual(result.content[2]["id"]?.stringValue, startedID)
        XCTAssertEqual(result.content[2]["input"], expectedInput)
        XCTAssertNotNil(result.usage?["input_tokens"]?.intValue)
        guard case .usage(let usage) = script[script.count - 2] else { return XCTFail("usage precedes completed") }
        XCTAssertEqual(usage, result.usage)
    }

    func testToolIsOnlyCalledWhenTheRequestOffersIt() {
        let withoutTools = events(of: request([typed("run my shortcut")], tools: []))
        XCTAssertEqual(completedResult(withoutTools)?.stopReason, "end_turn")
        let otherTool = events(of: request([typed("run my shortcut")], tools: ["calendar_create_event"]))
        XCTAssertEqual(completedResult(otherTool)?.stopReason, "end_turn")
        let offered = events(of: request([typed("run a script")], tools: ["run_applescript"]))
        XCTAssertEqual(completedResult(offered)?.content.last?["name"], "run_applescript")
    }

    func testWrapUpRequestNeverCallsATool() {
        let script = events(of: request([typed("run my shortcut")], toolChoice: ["type": "none"]))
        XCTAssertEqual(completedResult(script)?.stopReason, "end_turn")
    }

    func testAnswerAfterAToolRoundQuotesTheFirstResult() throws {
        let results = userEntry([
            ToolOutput.text("Resized 12 images.").toolResultBlock(toolUseID: "toolu_1"),
            ToolOutput.text("Other").toolResultBlock(toolUseID: "toolu_2"),
        ])
        let script = events(of: request([typed("run my shortcut"), ["role": "assistant", "content": []], results]))
        let result = try XCTUnwrap(completedResult(script))
        XCTAssertEqual(result.stopReason, "end_turn")
        let answer = result.content.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(answer.contains("\u{201C}Resized 12 images.\u{201D}"), answer)
        XCTAssertNotNil(result.usage)
    }

    func testAnswerAfterADeclineSaysSo() throws {
        let declined = userEntry([
            ToolOutput.error("declined: The user chose not to run a shortcut.").toolResultBlock(toolUseID: "toolu_1"),
        ])
        let script = events(of: request([typed("run my shortcut"), ["role": "assistant", "content": []], declined]))
        XCTAssertEqual(completedResult(script)?.content.first?["text"], "You declined, so I left things as they are.")
    }

    @MainActor
    func testDemoToolFlowRunsThroughTheSession() async throws {
        let settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        let executor = FakeToolExecutor()
        executor.result = { _ in (.succeeded, .text("Resized 12 images to 1600 px.")) }
        let chat = ChatSession(settings: settings, makeClient: { MockLLMClient(latencyScale: 0) },
                               tools: ToolRegistry(tools: [SideEffectTool(name: "run_shortcut")]),
                               executor: executor, isDemo: true)
        chat.send(text: "Run my shortcut on the screenshots", attachments: [])
        for _ in 0..<500 where chat.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(chat.isStreaming)
        let reply = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(reply.state, .complete)
        XCTAssertEqual(reply.toolCalls.map(\.status), [.succeeded])
        XCTAssertEqual(reply.toolExchanges.count, 1)
        XCTAssertTrue(reply.text.hasPrefix("I'll run your **Resize Images** shortcut on your screenshots."))
        XCTAssertTrue(reply.text.contains("Resized 12 images to 1600 px."), reply.text)
        XCTAssertEqual(executor.executedRounds.count, 1)
    }
}
