//
//  ToolLoopTests.swift
//  OttoTests
//
//  ChatSession's client tool loop against the ToolExecuting seam (foundation.md §10 cases 1–18, adapted: the
//  executor's own policy is W1-EXEC's and is played here by fakes), plus the per-reply server-tool budget, the
//  web pause, the action limit's wrap-up request and `systemUIToolWait`. Nothing touches the network, TCC or
//  the user's data.
//

import XCTest
@testable import Otto

// MARK: - Fixtures

private func textBlock(_ text: String) -> JSONValue {
    ["type": "text", "text": .string(text)]
}

private let planThinking: JSONValue = ["type": "thinking", "thinking": "Plan.", "signature": "sig-plan"]

private func toolUseBlock(_ id: String, _ name: String, _ input: JSONValue) -> JSONValue {
    ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
}

private func entry(_ role: String, _ content: [JSONValue]) -> JSONValue {
    ["role": .string(role), "content": .array(content)]
}

private struct PlannedCall {
    let id: String
    let name: String
    /// nil = the streamed JSON was invalid (`raw` is what streamed).
    let input: JSONValue?
    var raw: String?
}

private func echo(_ id: String, _ text: String = "hi") -> PlannedCall {
    PlannedCall(id: id, name: "echo", input: ["text": .string(text)])
}

private func sideEffect(_ id: String, _ input: String = "water") -> PlannedCall {
    PlannedCall(id: id, name: "side_effect", input: ["input": .string(input)])
}

/// Content of a response that asks for `calls` after thinking and one sentence.
private func roundContent(_ calls: [PlannedCall], text: String) -> [JSONValue] {
    [planThinking, textBlock(text)] + calls.map { toolUseBlock($0.id, $0.name, $0.input ?? [:]) }
}

/// A response that streams thinking, `text` and the calls, then stops for `tool_use`.
private func toolRound(
    _ calls: [PlannedCall],
    text: String = "On it.",
    stopReason: String = "tool_use",
    usage: JSONValue? = nil
) -> ScriptedLLMClient.Response {
    var events: [StreamEvent] = [.messageStart(model: "claude-opus-5"), .thinkingStarted, .thinkingDelta("Plan."),
                                 .textDelta(text)]
    for call in calls {
        events.append(.toolUseStarted(id: call.id, name: call.name))
        events.append(.toolUseReady(id: call.id, name: call.name, input: call.input,
                                    rawInput: call.raw ?? call.input?.encodedString() ?? ""))
    }
    events.append(.completed(StreamResult(content: roundContent(calls, text: text), stopReason: stopReason,
                                          stopDetails: nil, model: "claude-opus-5", usage: usage)))
    return .events(events)
}

private func finalReply(_ text: String, content: [JSONValue]? = nil, stopReason: String = "end_turn",
                        usage: JSONValue? = nil) -> ScriptedLLMClient.Response {
    .events([
        .messageStart(model: "claude-opus-5"),
        .textDelta(text),
        .completed(StreamResult(content: content ?? [textBlock(text)], stopReason: stopReason, stopDetails: nil,
                                model: "claude-opus-5", usage: usage)),
    ])
}

private func usage(searches: Int = 0, fetches: Int = 0, output: Int = 10) -> JSONValue {
    ["input_tokens": 100, "output_tokens": .int(Int64(output)),
     "server_tool_use": ["web_search_requests": .int(Int64(searches)), "web_fetch_requests": .int(Int64(fetches))]]
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for condition", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// A tool whose availability a test flips.
private final class AvailabilityFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var isOn: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private struct FlagTool: OttoTool {
    let flag: AvailabilityFlag
    var name = "flag_tool"
    var group: ToolGroup? = .links
    var description = "Opens a test link."
    var inputSchema: JSONValue {
        ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"], "additionalProperties": false]
    }
    var isConcurrencySafe: Bool { false }
    var sampleInput: JSONValue { ["url": "https://example.com"] }

    @MainActor func isAvailable(in environment: ToolEnvironment) -> Bool { flag.isOn }
    func approvalRequirement(for input: JSONValue) -> ApprovalRequirement { .none }
    func describe(_ input: JSONValue) -> ToolCallPresentation {
        ToolCallPresentation(symbol: "link", title: "Open \"<page>\"", activeTitle: "Opening…", doneTitle: "Opened",
                             detail: nil, disclosure: nil)
    }
    func approvalBody(for input: JSONValue) async -> ApprovalBody {
        .url(URLPreview(url: "https://example.com", displayHost: "example.com", punycodeHost: nil, warnings: []))
    }
    func run(_ input: JSONValue, context: ToolRunContext) async throws -> ToolRunResult {
        ToolRunResult(output: .text("Opened."))
    }
}

/// Opens once; `wait()` returns at once after that.
@MainActor private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// An executor whose round is a closure (for the cases FakeToolExecutor doesn't model: a running tool, a
/// permission card, a macOS dialog). `ask` puts a prompt in the dock and waits for `resolve`.
@MainActor private final class ClosureExecutor: ToolExecuting {
    var pendingApproval: PendingApproval?
    var onAttentionNeeded: ((PendingApproval) -> Void)?
    var body: @MainActor (ToolRound, ToolCallStore, ClosureExecutor) async throws -> ToolRoundOutcome = { _, _, _ in
        ToolRoundOutcome()
    }
    private(set) var cancelAllCount = 0
    private var continuation: CheckedContinuation<ApprovalDecision, Never>?

    func beginTurn() {}

    func execute(_ round: ToolRound, store: ToolCallStore) async throws -> ToolRoundOutcome {
        try await body(round, store, self)
    }

    func ask(_ kind: PendingApproval.Kind, call: ToolCall, round: ToolRound) async -> ApprovalDecision {
        let approval = PendingApproval(
            callID: call.id, messageID: round.messageID, toolName: call.name, kind: kind,
            presentation: call.presentation,
            body: .consent(ConsentPreview(symbol: "calendar", title: "Read your calendar", body: "Test.", footnote: nil)),
            confirmLabel: "Allow", declineLabel: "Not now", provenance: nil, caution: nil, armingDelay: .zero,
            presentedAt: Date(), position: 1, total: 1
        )
        pendingApproval = approval
        onAttentionNeeded?(approval)
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ decision: ApprovalDecision, callID: String, hardwareConfirmed: Bool, visibleSince: Date?) {
        guard pendingApproval?.callID == callID else { return }
        finish(decision)
    }

    func cancelAll() {
        cancelAllCount += 1
        finish(.cancelled)
    }

    func undo(callID: String, messageID: UUID, store: ToolCallStore) async -> String? { nil }
    func stop(callID: String) {}
    /// Undo notes by the assistant message whose action was undone.
    var notes: [UUID: [String]] = [:]
    func consumeContextNotes() -> [String] {
        defer { notes = [:] }
        return notes.values.flatMap { $0 }
    }
    func consumeContextNotes(forMessages messageIDs: Set<UUID>) -> [String] {
        let taken = messageIDs.flatMap { notes[$0] ?? [] }
        for id in messageIDs { notes[id] = nil }
        return taken
    }

    private func finish(_ decision: ApprovalDecision) {
        pendingApproval = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: decision)
    }
}

/// Records when a running tool saw its cancellation.
private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date?
    var cancelledAt: Date? { lock.withLock { date } }
    func record() { lock.withLock { if date == nil { date = Date() } } }
}

/// A settable clock and the one-shot timers `systemUIToolWait` asked for.
@MainActor private final class ManualTimer {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var scheduled: [(delay: Duration, action: @MainActor () -> Void)] = []

    func install(on chat: ChatSession) {
        chat.clock = { [unowned self] in self.now }
        chat.scheduleSystemUIRefresh = { [unowned self] delay, action in self.scheduled.append((delay, action)) }
    }

    func fireAll() {
        let actions = scheduled.map(\.action)
        scheduled = []
        actions.forEach { $0() }
    }
}

// MARK: - Tests

@MainActor
final class ToolLoopTests: XCTestCase {
    private func makeSettings() -> AppSettings {
        AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
    }

    private func makeSession(
        _ client: ScriptedLLMClient,
        executor: ToolExecuting,
        tools: [any OttoTool] = [EchoTool(), SideEffectTool()],
        settings: AppSettings? = nil
    ) -> (ChatSession, AppSettings) {
        let settings = settings ?? makeSettings()
        let chat = ChatSession(settings: settings, makeClient: { client }, tools: ToolRegistry(tools: tools),
                               executor: executor, isDemo: false)
        return (chat, settings)
    }

    private func run(_ chat: ChatSession, _ text: String = "Do it", file: StaticString = #filePath,
                     line: UInt = #line) async {
        chat.send(text: text, attachments: [])
        await waitUntil(file: file, line: line) { !chat.isStreaming }
    }

    private func reply(_ chat: ChatSession, file: StaticString = #filePath, line: UInt = #line) throws -> ChatMessage {
        try XCTUnwrap(chat.messages.last(where: { $0.role == .assistant }), file: file, line: line)
    }

    // MARK: 1–2. Round trips

    func testSingleRoundTripHistoryAndExchange() async throws {
        let client = ScriptedLLMClient([toolRound([echo("t1")]), finalReply("Here you go.")])
        let executor = FakeToolExecutor()
        let (chat, _) = makeSession(client, executor: executor)
        await run(chat, "Echo hi")

        let requests = client.requests
        XCTAssertEqual(requests.count, 2)
        let user = chat.messages[0]
        XCTAssertEqual(requests[1].messages, [
            entry("user", user.apiContent),
            entry("assistant", roundContent([echo("t1")], text: "On it.")),
            entry("user", [ToolOutput.text("Done.").toolResultBlock(toolUseID: "t1")]),
        ])
        let message = try reply(chat)
        XCTAssertEqual(message.state, .complete)
        XCTAssertEqual(message.text, "On it.Here you go.")
        XCTAssertEqual(message.toolExchanges, [ToolExchange(contentEnd: 3, textEnd: 6, callIDs: ["t1"])])
        XCTAssertEqual(message.toolCalls.map(\.status), [.succeeded])
        XCTAssertEqual(message.apiContent.count, 4)

        XCTAssertEqual(executor.beginTurnCount, 1)
        let round = try XCTUnwrap(executor.executedRounds.first)
        XCTAssertEqual(round.messageID, message.id)
        XCTAssertEqual(round.callIDs, ["t1"])
        XCTAssertEqual(round.roundIndex, 0)
        XCTAssertEqual(round.model, .opus5)
        XCTAssertEqual(Set(round.tools.keys), ["echo", "side_effect"])
        XCTAssertEqual(round.transcript, requests[0].messages + [entry("assistant", roundContent([echo("t1")], text: "On it."))])

        let registry = ToolRegistry(tools: [EchoTool(), SideEffectTool()])
        for request in requests {
            XCTAssertEqual(request.clientTools, registry.definitions(for: registry.allTools))
            XCTAssertNil(request.toolChoice)
            XCTAssertEqual(request.system, requests[0].system, "tool rounds resend an identical prefix")
        }
        XCTAssertTrue(requests[0].system.contains("Actions on this Mac:"))
    }

    func testParallelCallsAnswerInOneUserMessageInModelOrder() async throws {
        let client = ScriptedLLMClient([toolRound([echo("b", "second"), echo("a", "first")]), finalReply("Both done.")])
        let executor = FakeToolExecutor()
        executor.result = { call in (.succeeded, .text(call.input?["text"]?.stringValue ?? "")) }
        let (chat, _) = makeSession(client, executor: executor)
        await run(chat)

        XCTAssertEqual(client.requests[1].messages.last, entry("user", [
            ToolOutput.text("second").toolResultBlock(toolUseID: "b"),
            ToolOutput.text("first").toolResultBlock(toolUseID: "a"),
        ]))
        XCTAssertEqual(executor.executedRounds.first?.callIDs, ["b", "a"])
        XCTAssertEqual(try reply(chat).toolExchanges.first?.callIDs, ["b", "a"])
    }

    // MARK: 3. Approvals

    func testApprovalsAreForwardedWithTheirHardwareEvidence() async throws {
        let client = ScriptedLLMClient([toolRound([sideEffect("s1"), sideEffect("s2")]), finalReply("Okay.")])
        let executor = FakeToolExecutor()
        executor.asksForApproval = true
        let (chat, _) = makeSession(client, executor: executor)
        var attention: [String] = []
        chat.onAttentionNeeded = { attention.append($0.callID) }

        chat.resolveApproval(.deny, hardwareConfirmed: true, visibleSince: nil)
        XCTAssertTrue(executor.resolveCalls.isEmpty, "nothing to answer yet")

        chat.send(text: "Log water twice", attachments: [])
        await waitUntil { chat.pendingApproval?.callID == "s1" }
        XCTAssertEqual(attention, ["s1"])

        let visible = Date()
        chat.resolveApproval(.run(ApprovalOptions()), hardwareConfirmed: false, visibleSince: visible)
        XCTAssertEqual(chat.pendingApproval?.callID, "s1", "a synthetic press doesn't approve")
        chat.resolveApproval(.run(ApprovalOptions(alwaysAllow: true)), hardwareConfirmed: true, visibleSince: visible)
        await waitUntil { chat.pendingApproval?.callID == "s2" }
        chat.resolveApproval(.deny, hardwareConfirmed: false, visibleSince: nil)
        await waitUntil { !chat.isStreaming }

        XCTAssertEqual(executor.resolveCalls, [
            .init(decision: .run(ApprovalOptions()), callID: "s1", hardwareConfirmed: false, visibleSince: visible),
            .init(decision: .run(ApprovalOptions(alwaysAllow: true)), callID: "s1", hardwareConfirmed: true,
                  visibleSince: visible),
            .init(decision: .deny, callID: "s2", hardwareConfirmed: false, visibleSince: nil),
        ])
        XCTAssertEqual(attention, ["s1", "s2"])
        let message = try reply(chat)
        XCTAssertEqual(message.toolCalls.map(\.status), [.succeeded, .denied])
        let results = client.requests[1].messages.last?["content"]?.arrayValue ?? []
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[1]["is_error"], true)
        XCTAssertEqual(results[1]["content"]?[0]?["text"],
                       "declined: The user declined this action. Don't try to work around it.")
        XCTAssertNil(chat.pendingApproval)
    }

    // MARK: 4–5. Invalid input and unknown tools

    func testInvalidJSONReachesTheExecutorAndItsErrorIsEchoed() async throws {
        let raw = #"{"text": "cut"#
        let client = ScriptedLLMClient([
            toolRound([PlannedCall(id: "bad", name: "echo", input: nil, raw: raw)]),
            finalReply("Sorry."),
        ])
        let executor = FakeToolExecutor()
        let invalidCopy = #"invalid_input: The tool input wasn't valid JSON. Send the complete input again. {"INVALID_JSON":"{\"text\": \"cut"}"#
        executor.result = { call in
            call.input == nil ? (.failed("Couldn't read the request"), .error(invalidCopy)) : (.succeeded, .text("Done."))
        }
        let (chat, _) = makeSession(client, executor: executor)
        await run(chat)

        let message = try reply(chat)
        XCTAssertNil(message.toolCalls.first?.input)
        XCTAssertEqual(message.toolCalls.first?.invalidInput, raw)
        XCTAssertEqual(message.toolCalls.first?.status, .failed("Couldn't read the request"))
        let history = client.requests[1].messages
        XCTAssertEqual(history[1]["content"]?[2], toolUseBlock("bad", "echo", [:]), "the block keeps its start input")
        XCTAssertEqual(history[2], entry("user", [ToolOutput.error(invalidCopy).toolResultBlock(toolUseID: "bad")]))
    }

    func testUnknownToolIsAnsweredWithoutEverOfferingIt() async throws {
        let client = ScriptedLLMClient([
            toolRound([PlannedCall(id: "m1", name: "mystery", input: [:])]),
            finalReply("I can't do that."),
        ])
        let executor = FakeToolExecutor()
        let copy = ToolHistory.Copy.unknownTool("mystery")
        executor.result = { _ in (.failed("Unknown action"), .error(copy)) }
        let (chat, _) = makeSession(client, executor: executor)
        await run(chat)

        XCTAssertNil(executor.executedRounds.first?.tools["mystery"])
        let history = client.requests[1].messages
        XCTAssertEqual(history[1], entry("assistant", [planThinking, textBlock("On it.")]),
                       "a call to a tool that isn't offered is never echoed as tool_use")
        XCTAssertEqual(history[2], entry("user", [textBlock(
            #"<earlier_action_result tool="mystery" title="Use mystery" untrusted="true">"#
                + ToolHistory.escaped(copy) + "</earlier_action_result>"
        )]))
    }

    // MARK: 6–7. Cut off and refused

    func testMaxTokensWithToolUseNeverRunsAndIsNeverEchoed() async throws {
        let client = ScriptedLLMClient([toolRound([echo("t1")], stopReason: "max_tokens"), finalReply("Next.")])
        let executor = FakeToolExecutor()
        let (chat, _) = makeSession(client, executor: executor)
        await run(chat)

        XCTAssertTrue(executor.executedRounds.isEmpty)
        let message = try reply(chat)
        XCTAssertEqual(message.toolCalls.map(\.status), [.skipped("Reply was cut off")])
        XCTAssertNil(message.toolCalls.first?.result)
        XCTAssertTrue(message.toolExchanges.isEmpty)
        XCTAssertTrue(message.text.hasSuffix(ChatSession.truncationNote))

        await run(chat, "Go on")
        let history = client.requests[1].messages
        XCTAssertEqual(history[1], entry("assistant", [planThinking, textBlock("On it.")]))
        XCTAssertFalse(history.contains { $0.encodedString().contains("tool_use") })
    }

    func testRefusalAfterAToolRanLeavesTheContextButKeepsTheCallVisible() async throws {
        let refusal: ScriptedLLMClient.Response = .events([
            .messageStart(model: "claude-opus-5"),
            .completed(StreamResult(content: [], stopReason: "refusal", stopDetails: nil, model: "claude-opus-5", usage: nil)),
        ])
        let client = ScriptedLLMClient([toolRound([echo("t1"), echo("t2")]), refusal, finalReply("Hello.")])
        let executor = FakeToolExecutor()
        executor.result = { call in
            call.id == "t1" ? (.succeeded, .text("Done.")) : (.failed("Timed out"), .error("timeout: Took too long."))
        }
        let (chat, _) = makeSession(client, executor: executor)
        await run(chat)

        let message = try reply(chat)
        XCTAssertEqual(message.state, .refused(ChatSession.refusalMessage))
        XCTAssertTrue(message.toolExchanges.isEmpty)
        XCTAssertEqual(message.toolCalls.map(\.id), ["t1", "t2"])
        XCTAssertEqual(message.toolCalls.map(\.status), [.succeeded, .failed("Timed out")])
        XCTAssertFalse(chat.messages[0].includeInContext)

        await run(chat, "Something else")
        XCTAssertEqual(client.requests[2].messages.count, 1, "the refused turn and its question leave the context")
    }

    // MARK: 8–9. Cancellation

    func testCancelDuringApprovalSettlesTheRoundAndKeepsTheExchange() async throws {
        let client = ScriptedLLMClient([toolRound([sideEffect("s1")]), finalReply("Fine.")])
        let executor = FakeToolExecutor()
        executor.asksForApproval = true
        let (chat, _) = makeSession(client, executor: executor)
        chat.send(text: "Log water", attachments: [])
        await waitUntil { chat.pendingApproval != nil }

        chat.cancel()
        XCTAssertEqual(executor.cancelAllCount, 1)
        XCTAssertNil(chat.pendingApproval)
        let message = try reply(chat)
        XCTAssertEqual(message.state, .cancelled)
        XCTAssertEqual(message.toolCalls.map(\.status), [.cancelled])
        XCTAssertEqual(message.toolCalls.first?.result, .error(ToolHistory.Copy.cancelledBeforeRun))

        await run(chat, "Never mind")
        let history = client.requests[1].messages
        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(history[1], entry("assistant", roundContent([sideEffect("s1")], text: "On it.")))
        XCTAssertEqual(history[2], entry("user", [
            ToolOutput.error(ToolHistory.Copy.cancelledBeforeRun).toolResultBlock(toolUseID: "s1"),
        ]))
    }

    func testCancelWhileAToolRunsCancelsItPromptly() async throws {
        let client = ScriptedLLMClient([toolRound([PlannedCall(id: "w1", name: "slow", input: ["label": "wait"])])])
        let executor = ClosureExecutor()
        let probe = CancellationProbe()
        executor.body = { round, store, _ in
            for id in round.callIDs {
                guard let call = store.toolCall(id, in: round.messageID), let tool = round.tools[call.name],
                      let input = call.input else { continue }
                store.updateToolCall(id, in: round.messageID) { $0.status = .running; $0.startedAt = Date() }
                let context = ToolRunContext(callID: id, model: round.model, options: ApprovalOptions(),
                                             reportProgress: { _ in }, reportSystemDialog: { _ in })
                do {
                    _ = try await tool.run(input, context: context)
                } catch {
                    probe.record()
                    throw error
                }
            }
            return ToolRoundOutcome()
        }
        let (chat, _) = makeSession(client, executor: executor, tools: [SlowTool()])
        chat.send(text: "Wait a minute", attachments: [])
        await waitUntil { chat.messages.last?.toolCalls.first?.status == .running }

        let cancelledAt = Date()
        chat.cancel()
        await waitUntil { probe.cancelledAt != nil }
        let elapsed = try XCTUnwrap(probe.cancelledAt).timeIntervalSince(cancelledAt)
        XCTAssertLessThan(elapsed, 0.1)
        let message = try reply(chat)
        XCTAssertEqual(message.toolCalls.first?.status, .cancelled)
        XCTAssertEqual(message.toolCalls.first?.result, .error(ToolHistory.Copy.cancelledWhileRunning))
    }

    // MARK: 10. Limits

    func testRoundLimitAnswersWithLimitCopyAndSendsAWrapUpRequest() async throws {
        let settings = makeSettings()
        settings.actions.maxToolRounds = 3
        let client = ScriptedLLMClient([
            toolRound([echo("t1")]), toolRound([echo("t2")]), toolRound([echo("t3")]), toolRound([echo("t4")]),
            finalReply("Here's what I got done."),
        ])
        let executor = FakeToolExecutor()
        let (chat, _) = makeSession(client, executor: executor, settings: settings)
        await run(chat)

        XCTAssertEqual(executor.executedRounds.map(\.callIDs), [["t1"], ["t2"], ["t3"]])
        let message = try reply(chat)
        XCTAssertEqual(message.toolCalls.last?.status, .skipped("Action limit reached"))
        XCTAssertEqual(message.toolCalls.last?.result, .error(ToolHistory.Copy.actionLimit))
        XCTAssertEqual(message.toolExchanges.count, 4)
        let requests = client.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests.prefix(4).map(\.toolChoice), [nil, nil, nil, nil])
        XCTAssertEqual(requests[4].toolChoice, ["type": "none"])
        XCTAssertEqual(requests[4].clientTools, requests[0].clientTools, "the tool list stays, only tool_choice changes")
        XCTAssertEqual(requests[4].messages.last, entry("user", [
            ToolOutput.error(ToolHistory.Copy.actionLimit).toolResultBlock(toolUseID: "t4"),
        ]))
        XCTAssertTrue(message.text.hasSuffix("Here's what I got done."))
        XCTAssertEqual(message.state, .complete)
    }

    func testToolUseAfterTheWrapUpEndsTheTurnWithTheLimitNote() async throws {
        let settings = makeSettings()
        settings.actions.maxToolRounds = 3
        let client = ScriptedLLMClient([
            toolRound([echo("t1")]), toolRound([echo("t2")]), toolRound([echo("t3")]), toolRound([echo("t4")]),
            toolRound([echo("t5")], text: "One more."),
        ])
        let executor = FakeToolExecutor()
        let (chat, _) = makeSession(client, executor: executor, settings: settings)
        await run(chat)

        XCTAssertEqual(client.requests.count, 5)
        let message = try reply(chat)
        XCTAssertEqual(message.state, .complete)
        XCTAssertTrue(message.text.hasSuffix("One more." + ChatSession.toolLimitNote))
        XCTAssertEqual(message.toolExchanges.count, 4, "the last calls get no exchange")
        let last = try XCTUnwrap(message.toolCalls.last)
        XCTAssertEqual(last.id, "t5")
        XCTAssertEqual(last.status, .skipped("Action limit reached"))
        XCTAssertNil(last.result)

        await run(chat, "Thanks")
        let history = client.requests[5].messages
        XCTAssertFalse(history.contains { $0.encodedString().contains("\"t5\"") }, "the orphaned call is never echoed")
    }

    func testMoreThanTheCallLimitInOneRoundRunsNothing() async throws {
        let calls = (1...(ToolLimits.maxCallsPerTurn + 1)).map { echo("c\($0)") }
        let client = ScriptedLLMClient([toolRound(calls), finalReply("Too many.")])
        let executor = FakeToolExecutor()
        let (chat, _) = makeSession(client, executor: executor)
        await run(chat)

        XCTAssertTrue(executor.executedRounds.isEmpty)
        XCTAssertEqual(client.requests[1].toolChoice, ["type": "none"])
        let statuses = try reply(chat).toolCalls.map(\.status)
        XCTAssertEqual(statuses.count, ToolLimits.maxCallsPerTurn + 1)
        XCTAssertTrue(statuses.allSatisfy { $0 == .skipped("Action limit reached") })
    }

    // MARK: 11–12. pause_turn and fallback inside the loop

    func testPauseTurnInsideTheLoopResumesAfterTheToolResults() async throws {
        let pending: [JSONValue] = [
            textBlock("Checking the web too. "),
            ["type": "server_tool_use", "id": "srv1", "name": "web_search", "input": ["query": "dentist"]],
        ]
        let client = ScriptedLLMClient([
            toolRound([echo("t1")]),
            .events([
                .messageStart(model: "claude-opus-5"),
                .textDelta("Checking the web too. "),
                .completed(StreamResult(content: pending, stopReason: "pause_turn", stopDetails: nil,
                                        model: "claude-opus-5", usage: nil)),
            ]),
            finalReply("Found it."),
        ])
        let executor = FakeToolExecutor()
        let (chat, _) = makeSession(client, executor: executor)
        await run(chat)

        let resume = client.requests[2]
        XCTAssertEqual(Array(resume.messages.suffix(2)), [
            entry("user", [ToolOutput.text("Done.").toolResultBlock(toolUseID: "t1")]),
            entry("assistant", pending),
        ])
        XCTAssertEqual(resume.serverToolLimits, client.requests[1].serverToolLimits)
        XCTAssertEqual(executor.executedRounds.count, 1)
        XCTAssertEqual(try reply(chat).text, "On it.Checking the web too. Found it.")
    }

    func testFallbackInALaterSegmentKeepsTheEarlierToolUse() async throws {
        let fallback: JSONValue = ["type": "fallback", "from": ["model": "claude-opus-5"], "to": ["model": "claude-sonnet-5"]]
        let client = ScriptedLLMClient([
            toolRound([echo("t1")]),
            finalReply("New", content: [["type": "thinking", "thinking": "x", "signature": "s"], textBlock("Old"),
                                        fallback, textBlock("New")]),
            finalReply("Sure."),
        ])
        let (chat, _) = makeSession(client, executor: FakeToolExecutor())
        await run(chat)
        await run(chat, "And?")

        let history = client.requests[2].messages
        XCTAssertEqual(history[1], entry("assistant", roundContent([echo("t1")], text: "On it.")))
        XCTAssertEqual(history[2], entry("user", [ToolOutput.text("Done.").toolResultBlock(toolUseID: "t1")]))
        XCTAssertEqual(history[3], entry("assistant", [textBlock("Old"), textBlock("New")]))
    }

    // MARK: 13. A tool turned off later

    func testRoundsOfAToolTurnedOffLaterAreDowngraded() async throws {
        let flag = AvailabilityFlag()
        let tool = FlagTool(flag: flag)
        let client = ScriptedLLMClient([
            toolRound([PlannedCall(id: "f1", name: "flag_tool", input: ["url": "https://example.com"])]),
            finalReply("Opened."),
            finalReply("Okay."),
        ])
        let executor = FakeToolExecutor()
        executor.result = { _ in (.succeeded, .text(#"{"status":"opened","url":"https://example.com/?a=<b>&c"}"#)) }
        let (chat, _) = makeSession(client, executor: executor, tools: [tool])
        await run(chat, "Open it")
        flag.isOn = false
        await run(chat, "Thanks")

        let request = client.requests[2]
        XCTAssertEqual(request.clientTools, [])
        XCTAssertTrue(request.system.contains(SystemPrompt.actionsOffLine))
        XCTAssertEqual(request.messages[1], entry("assistant", [planThinking, textBlock("On it.")]))
        XCTAssertEqual(request.messages[2], entry("user", [textBlock(
            #"<earlier_action_result tool="flag_tool" title="Use flag_tool" untrusted="true">"#
                + #"{&quot;status&quot;:&quot;opened&quot;,&quot;url&quot;:&quot;https://example.com/?a=&lt;b&gt;&amp;c&quot;}"#
                + "</earlier_action_result>"
        )]))
        XCTAssertFalse(request.messages.contains { $0.encodedString().contains("tool_result") })
        XCTAssertEqual(chat.messages[2].apiContent, [textBlock("Thanks")], "no context block without tools")
    }

    // MARK: 14. Images

    func testToolImagesOfEarlierTurnsBecomeNotes() async throws {
        let client = ScriptedLLMClient([toolRound([echo("t1")]), finalReply("Took it."), finalReply("Sure.")])
        let executor = FakeToolExecutor()
        executor.result = { _ in (.succeeded, ToolOutput(parts: [.image(mediaType: "image/png", base64: "AAAA")], isError: false)) }
        let (chat, _) = makeSession(client, executor: executor)
        await run(chat)
        XCTAssertEqual(client.requests[1].messages.last?["content"]?[0]?["content"]?[0]?["type"], "image",
                       "the in-flight turn keeps its image")
        await run(chat, "Again?")
        XCTAssertEqual(client.requests[2].messages[2]["content"]?[0]?["content"]?[0],
                       ["type": "text", "text": "[Image from Use echo omitted]"])
    }

    // MARK: 15. Executor failures

    func testTimeoutResultIsEchoedVerbatim() async throws {
        let client = ScriptedLLMClient([toolRound([echo("t1")]), finalReply("It timed out.")])
        let executor = FakeToolExecutor()
        let copy = "timeout: echo didn't finish within 1 seconds."
        executor.result = { _ in (.failed("Timed out"), .error(copy)) }
        let (chat, _) = makeSession(client, executor: executor)
        await run(chat)
        XCTAssertEqual(client.requests[1].messages.last, entry("user", [ToolOutput.error(copy).toolResultBlock(toolUseID: "t1")]))
        XCTAssertEqual(try reply(chat).toolCalls.first?.status, .failed("Timed out"))
    }

    // MARK: 16. Permission prompt

    func testPermissionPromptIsForwardedAndDenyingSkipsOnlyThatCall() async throws {
        let client = ScriptedLLMClient([
            toolRound([PlannedCall(id: "p1", name: "consent_read", input: ["query": "today"]), echo("t2")]),
            finalReply("Okay."),
        ])
        let executor = ClosureExecutor()
        executor.body = { round, store, executor in
            for id in round.callIDs {
                guard let call = store.toolCall(id, in: round.messageID) else { continue }
                if call.name == "consent_read" {
                    store.updateToolCall(id, in: round.messageID) { call in
                        call.presentation = ToolCallPresentation(symbol: "calendar", title: "Read your calendar",
                                                                 activeTitle: "Reading…", doneTitle: "Read",
                                                                 detail: nil, disclosure: nil)
                        call.status = .needsPermission
                    }
                    let current = store.toolCall(id, in: round.messageID) ?? call
                    let decision = await executor.ask(.permission([.calendars], consent: nil), call: current, round: round)
                    if decision == .cancelled { throw CancellationError() }
                    store.updateToolCall(id, in: round.messageID) { call in
                        call.status = .skipped("Permission needed")
                        call.result = .error("permission_denied: Otto doesn't have Calendars access.")
                    }
                } else {
                    store.updateToolCall(id, in: round.messageID) { call in
                        call.status = .succeeded
                        call.result = .text("hi")
                    }
                }
            }
            return ToolRoundOutcome()
        }
        let (chat, _) = makeSession(client, executor: executor, tools: [ConsentReadTool(), EchoTool()])
        chat.send(text: "What's on today?", attachments: [])
        await waitUntil { chat.pendingApproval != nil }

        XCTAssertEqual(chat.pendingApproval?.kind, .permission([.calendars], consent: nil))
        XCTAssertEqual(chat.phase, .awaitingApproval(label: "Read your calendar"))
        XCTAssertNil(chat.systemUIToolWait)
        chat.resolveApproval(.deny, hardwareConfirmed: false, visibleSince: nil)
        await waitUntil { !chat.isStreaming }

        XCTAssertEqual(try reply(chat).toolCalls.map(\.status), [.skipped("Permission needed"), .succeeded])
        XCTAssertEqual(client.requests[1].messages.last?["content"]?.arrayValue?.count, 2)
    }

    // MARK: 17. Usage

    func testUsageIsRecordedForEveryRoundOfOneAnswer() async throws {
        let client = ScriptedLLMClient([
            toolRound([echo("t1")], usage: usage(output: 10)),
            toolRound([echo("t2")], usage: usage(output: 20)),
            finalReply("Done.", usage: usage(output: 30)),
        ])
        let (chat, _) = makeSession(client, executor: FakeToolExecutor())
        let recorder = FakeUsageRecorder()
        chat.usageRecorder = recorder
        await run(chat)

        let message = try reply(chat)
        XCTAssertEqual(recorder.records.map { $0.usage?["output_tokens"]?.intValue }, [10, 20, 30])
        XCTAssertEqual(recorder.records.map(\.stopReason), ["tool_use", "tool_use", "end_turn"])
        XCTAssertEqual(Set(recorder.records.map(\.messageID)), [message.id])
        XCTAssertFalse(recorder.records.contains(where: \.isPartial))
        XCTAssertEqual(recorder.finishedAnswers, [message.id])
    }

    // MARK: 18. Availability changes mid-turn

    func testToolSnapshotHoldsForTheWholeTurn() async throws {
        let flag = AvailabilityFlag()
        let client = ScriptedLLMClient([
            toolRound([echo("t1")]), toolRound([echo("t2")]), finalReply("Done."), finalReply("Later."),
        ])
        let executor = FakeToolExecutor()
        executor.result = { _ in
            flag.isOn = false
            return (.skipped("Turned off in Settings"), .error("disabled: The user turned this action off in Otto's settings."))
        }
        let (chat, _) = makeSession(client, executor: executor, tools: [EchoTool(), FlagTool(flag: flag)])
        await run(chat)

        let requests = client.requests
        XCTAssertEqual(requests[1].clientTools, requests[0].clientTools)
        XCTAssertEqual(requests[2].clientTools, requests[0].clientTools)
        XCTAssertEqual(requests[2].system, requests[0].system)
        XCTAssertEqual(executor.executedRounds.map { Set($0.tools.keys) }, [["echo", "flag_tool"], ["echo", "flag_tool"]])
        XCTAssertEqual(try reply(chat).toolCalls.map(\.status), [.skipped("Turned off in Settings"), .skipped("Turned off in Settings")])

        await run(chat, "Next")
        XCTAssertEqual(client.requests[3].clientTools.compactMap { $0["name"]?.stringValue }, ["echo"])
    }

    // MARK: - Failed turns

    func testFailedTurnWhoseActionsRanStaysInContext() async throws {
        let client = ScriptedLLMClient([
            toolRound([echo("t1")]),
            .failure(LLMError.overloaded, after: []),
            finalReply("Back."),
        ])
        let (chat, _) = makeSession(client, executor: FakeToolExecutor())
        await run(chat)
        let failed = try reply(chat)
        guard case .failed = failed.state else { return XCTFail("expected a failure") }
        XCTAssertTrue(failed.includeInContext)
        XCTAssertEqual(failed.toolCalls.map(\.status), [.succeeded])

        await run(chat, "Try again")
        let history = client.requests[2].messages
        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(history[1], entry("assistant", roundContent([echo("t1")], text: "On it.")))
        XCTAssertEqual(history[2], entry("user", [ToolOutput.text("Done.").toolResultBlock(toolUseID: "t1")]))
    }

    func testRetryAfterActionsRanContinuesFromTheLastExchange() async throws {
        let client = ScriptedLLMClient([
            toolRound([sideEffect("t1")]),
            // Round 2 fails after announcing a call that never ran.
            .failure(LLMError.overloaded, after: [
                .messageStart(model: "claude-opus-5"), .textDelta(" Next."), .toolUseStarted(id: "t9", name: "echo"),
            ]),
            toolRound([echo("t2")], text: " Then this."),
            finalReply(" All done."),
        ])
        let executor = FakeToolExecutor()
        let (chat, _) = makeSession(client, executor: executor)
        await run(chat, "Log water")
        let failed = try reply(chat)
        guard case .failed = failed.state else { return XCTFail("expected a failure") }
        XCTAssertTrue(failed.includeInContext)
        XCTAssertEqual(failed.toolCalls.map(\.id), ["t1", "t9"])

        chat.retry(messageID: failed.id)
        XCTAssertTrue(chat.isStreaming)
        XCTAssertEqual(chat.messages[1].id, failed.id, "the same message continues")
        XCTAssertEqual(chat.messages[1].text, "On it.", "what streamed after the last exchange is dropped")
        await waitUntil { !chat.isStreaming }

        // The retry re-sends from the last exchange: the action that ran is never asked for again.
        XCTAssertEqual(client.requests[2].messages, [
            entry("user", chat.messages[0].apiContent),
            entry("assistant", roundContent([sideEffect("t1")], text: "On it.")),
            entry("user", [ToolOutput.text("Done.").toolResultBlock(toolUseID: "t1")]),
        ])
        XCTAssertEqual(executor.executedRounds.map(\.callIDs), [["t1"], ["t2"]])
        XCTAssertEqual(executor.executedRounds.last?.roundIndex, 1, "the round count carries over")
        XCTAssertEqual(executor.executedRounds.last?.messageID, failed.id)

        let message = try reply(chat)
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(message.id, failed.id)
        XCTAssertEqual(message.state, .complete)
        XCTAssertEqual(message.text, "On it. Then this. All done.")
        XCTAssertEqual(message.toolCalls.map(\.id), ["t1", "t2"], "the call that never ran is gone")
        XCTAssertEqual(message.toolCalls.map(\.status), [.succeeded, .succeeded])
        XCTAssertEqual(message.toolExchanges.map(\.callIDs), [["t1"], ["t2"]])
        XCTAssertEqual(message.toolExchanges.last?.contentEnd, 6)
    }

    /// Retry continues the same reply, so it keeps what the reply spent of its web budget.
    func testRetryKeepsTheReplysWebBudget() async throws {
        let client = ScriptedLLMClient([
            toolRound([echo("t1")], usage: usage(searches: 8, fetches: 8)),
            .failure(LLMError.overloaded, after: []),
            finalReply("Done."),
        ])
        let (chat, _) = makeSession(client, executor: FakeToolExecutor())
        await run(chat)
        let failed = try reply(chat)
        guard case .failed = failed.state else { return XCTFail("expected a failure") }
        chat.retry(messageID: failed.id)
        await waitUntil { !chat.isStreaming }
        XCTAssertEqual(try reply(chat).state, .complete)
        XCTAssertEqual(client.requests.map(\.serverToolLimits), [
            ServerToolLimits(), ServerToolLimits(webSearch: 2, webFetch: 2), ServerToolLimits(webSearch: 2, webFetch: 2),
        ], "the resumed request has 2 searches and 2 fetches left, not a fresh 10 + 10")
    }

    func testWebBudgetOfARestoredReplyIsRecountedFromItsContent() {
        let content: [JSONValue] = [
            ["type": "server_tool_use", "id": "a", "name": "web_search", "input": [:]],
            ["type": "server_tool_use", "id": "b", "name": "web_search", "input": [:]],
            ["type": "server_tool_use", "id": "c", "name": "web_fetch", "input": [:]],
            ["type": "server_tool_use", "id": "d", "name": "code_execution", "input": [:]],
            textBlock("Hi"),
        ]
        let left = ChatSession.webBudgetLeft(in: content)
        XCTAssertEqual(left.searches, ToolLimits.webSearchesPerTurn - 2)
        XCTAssertEqual(left.fetches, ToolLimits.webFetchesPerTurn - 1)
    }

    /// Two declines, a failure, then Retry: the continued reply still auto-declines the next card-requiring call.
    func testRetryKeepsDeclineFatigue() async throws {
        let client = ScriptedLLMClient([
            toolRound([sideEffect("s1", "one"), sideEffect("s2", "two")]),
            .failure(LLMError.overloaded, after: []),
            toolRound([sideEffect("s3", "three")], text: " Again."),
            finalReply(" Okay."),
        ])
        let executor = ToolExecutor(permissions: FakePermissionProvider(default: .granted),
                                    approvals: ApprovalStore(defaults: TestDefaults.make(for: self)), log: nil)
        let (chat, _) = makeSession(client, executor: executor)
        chat.send(text: "Log water", attachments: [])
        for id in ["s1", "s2"] {
            await waitUntil { chat.pendingApproval?.callID == id }
            chat.resolveApproval(.deny, hardwareConfirmed: false, visibleSince: nil)
        }
        await waitUntil { !chat.isStreaming }
        let failed = try reply(chat)
        guard case .failed = failed.state else { return XCTFail("expected a failure") }

        chat.retry(messageID: failed.id)
        await waitUntil { chat.pendingApproval != nil || !chat.isStreaming }
        XCTAssertNil(chat.pendingApproval, "no new card after two declines in this reply")
        if chat.pendingApproval != nil { chat.cancel() }
        await waitUntil { !chat.isStreaming }
        let s3 = try XCTUnwrap(try reply(chat).toolCalls.first { $0.id == "s3" })
        XCTAssertEqual(s3.status, .denied)
        XCTAssertEqual(s3.result, .error(
            "declined: The user declined several actions in this reply. Ask them before trying again."))
    }

    func testRetryOfAFailedTurnWithoutActionsStillStartsOver() async throws {
        let client = ScriptedLLMClient([.failure(LLMError.overloaded, after: []), finalReply("Fine.")])
        let executor = FakeToolExecutor()
        let (chat, _) = makeSession(client, executor: executor)
        await run(chat)
        let failedID = try reply(chat).id
        chat.retry(messageID: failedID)
        await waitUntil { !chat.isStreaming }
        XCTAssertNotEqual(try reply(chat).id, failedID)
        XCTAssertEqual(try reply(chat).text, "Fine.")
    }

    func testRejectedContentTakesAFailedToolTurnOutOfContext() async throws {
        let client = ScriptedLLMClient([
            toolRound([echo("t1")]),
            .failure(LLMError.http(status: 400, type: "invalid_request_error", message: "Bad image"), after: []),
            finalReply("Back."),
        ])
        let (chat, _) = makeSession(client, executor: FakeToolExecutor())
        await run(chat)
        XCTAssertFalse(try reply(chat).includeInContext)
        XCTAssertFalse(chat.messages[0].includeInContext)
        await run(chat, "Start over")
        XCTAssertEqual(client.requests[2].messages.count, 1)
    }

    func testResetCancelsTheRoundAndClearsTheToolState() async throws {
        let client = ScriptedLLMClient([toolRound([sideEffect("s1")])])
        let executor = FakeToolExecutor()
        executor.asksForApproval = true
        let (chat, _) = makeSession(client, executor: executor)
        chat.send(text: "Log water", attachments: [])
        await waitUntil { chat.pendingApproval != nil }
        chat.reset()
        XCTAssertEqual(executor.cancelAllCount, 1)
        XCTAssertNil(chat.pendingApproval)
        XCTAssertNil(chat.systemUIToolWait)
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertEqual(chat.phase, .idle)
    }

    // MARK: - Runaway responses

    func testAResponseStreamingTooManyCallsIsStoppedEarly() async throws {
        var events: [StreamEvent] = [.messageStart(model: "claude-opus-5"), .textDelta("Adding it.")]
        for index in 0..<(ToolLimits.maxStreamedCallsPerResponse * 4) {
            events.append(.toolUseStarted(id: "r\(index)", name: "side_effect"))
        }
        let client = ScriptedLLMClient([.stall(events)])
        let executor = FakeToolExecutor()
        let (chat, _) = makeSession(client, executor: executor)
        await run(chat, "Add a reminder")

        let message = try reply(chat)
        XCTAssertEqual(message.state, .complete)
        XCTAssertEqual(message.text, "Adding it." + ChatSession.toolLimitNote)
        XCTAssertEqual(message.toolCalls.count, ToolLimits.maxStreamedCallsPerResponse + 1,
                       "stopped at the first call over the limit")
        XCTAssertTrue(message.toolCalls.allSatisfy { $0.status == .skipped("Action limit reached") && $0.result == nil })
        XCTAssertTrue(message.toolExchanges.isEmpty)
        XCTAssertTrue(executor.executedRounds.isEmpty, "nothing ran")
        await waitUntil { client.cancellations == 1 }
        XCTAssertEqual(client.requests.count, 1)
    }

    // MARK: - Undo notes

    func testUndoNotesOnlyReachTheConversationTheyBelongTo() async throws {
        let client = ScriptedLLMClient([finalReply("Added."), finalReply("Sunny."), finalReply("Okay.")])
        let executor = ClosureExecutor()
        let (chat, _) = makeSession(client, executor: executor)
        await run(chat, "Add Dentist")
        let firstReply = try reply(chat).id
        let note = "[Note: the user undid an action \u{2014} the calendar event \u{201C}Dentist\u{201D} was removed.]"
        executor.notes[firstReply] = [note]

        chat.reset()
        await run(chat, "What's the weather?")
        XCTAssertFalse(chat.messages[0].apiContent.contains(ToolHistory.textBlock(note)), "a new chat never gets it")
        XCTAssertEqual(executor.notes[firstReply], [note], "it waits for its own conversation")

        executor.notes[try reply(chat).id] = ["[Note: this chat]"]
        await run(chat, "Thanks")
        XCTAssertTrue(chat.messages[2].apiContent.contains(ToolHistory.textBlock("[Note: this chat]")))
        XCTAssertFalse(chat.messages[2].apiContent.contains(ToolHistory.textBlock(note)))
    }

    // MARK: - Server-tool budget and web pause

    func testTheExecutorSeesAPageReadEvenAfterWebToolsLeaveTheRequest() async throws {
        let fetchCall: JSONValue = ["type": "server_tool_use", "id": "srv1", "name": "web_fetch",
                                    "input": ["url": "https://evil.example/"]]
        let fetchResult: JSONValue = [
            "type": "web_fetch_tool_result", "tool_use_id": "srv1",
            "content": ["type": "web_fetch_result", "url": "https://evil.example/", "content": ["type": "document"]],
        ]
        let read = PlannedCall(id: "r1", name: "private_read", input: ["range": "today"])
        let firstContent: [JSONValue] = [planThinking, fetchCall, fetchResult, textBlock("Reading.")]
            + [toolUseBlock("r1", "private_read", ["range": "today"])]
        let client = ScriptedLLMClient([
            .events([
                .messageStart(model: "claude-opus-5"),
                .toolUseStarted(id: read.id, name: read.name),
                .toolUseReady(id: read.id, name: read.name, input: read.input, rawInput: read.input?.encodedString() ?? ""),
                .completed(StreamResult(content: firstContent, stopReason: "tool_use", stopDetails: nil,
                                        model: "claude-opus-5", usage: usage(fetches: 1))),
            ]),
            toolRound([sideEffect("s1")]),
            finalReply("Done."),
        ])
        let executor = FakeToolExecutor()
        executor.scriptedOutcomes = [
            ToolRoundOutcome(webPause: WebPauseReason(privateSource: "your calendar", untrustedSource: "evil.example")),
        ]
        let (chat, _) = makeSession(client, executor: executor, tools: [EchoTool(), PrivateReadTool(), SideEffectTool()])
        await run(chat, "Summarize evil.example and add the date")

        XCTAssertEqual(client.requests[1].serverToolLimits, .none)
        func hasFetchResult(_ entries: [JSONValue]) -> Bool {
            entries.contains { $0["content"]?.arrayValue?.contains(fetchResult) == true }
        }
        XCTAssertFalse(hasFetchResult(client.requests[1].messages), "the paused request defines no web tools")
        let second = try XCTUnwrap(executor.executedRounds.last)
        XCTAssertTrue(hasFetchResult(second.transcript), "the trust check still sees the page")
        let trust = TrustLedger.assess(transcript: second.transcript, untrustedTools: [:])
        XCTAssertTrue(trust.caution)
        XCTAssertEqual(trust.cautionHeadlineSource, "evil.example")
        XCTAssertEqual(Set(second.knownTools.keys), ["echo", "private_read", "side_effect"])
    }

    func testServerToolBudgetShrinksAcrossTheReply() async throws {
        let client = ScriptedLLMClient([
            toolRound([echo("t1")], usage: usage(searches: 4, fetches: 5)),
            toolRound([echo("t2")], usage: usage(searches: 4, fetches: 5)),
            toolRound([echo("t3")], usage: usage(searches: 2)),
            finalReply("Done."),
            finalReply("Fresh budget."),
        ])
        let (chat, _) = makeSession(client, executor: FakeToolExecutor())
        await run(chat)

        XCTAssertEqual(client.requests.map(\.serverToolLimits), [
            ServerToolLimits(webSearch: 5, webFetch: 5),
            ServerToolLimits(webSearch: 5, webFetch: 5),
            ServerToolLimits(webSearch: 2, webFetch: 0),
            .none,
        ])
        let tools = AnthropicClient.makeRequestBody(client.requests[2])["tools"]?.arrayValue ?? []
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue }, ["web_search", "echo", "side_effect"])
        XCTAssertEqual(tools.first?["max_uses"], 2)
        let spent = AnthropicClient.makeRequestBody(client.requests[3])["tools"]?.arrayValue ?? []
        XCTAssertEqual(spent.compactMap { $0["name"]?.stringValue }, ["echo", "side_effect"])

        await run(chat, "Again")
        XCTAssertEqual(client.requests[4].serverToolLimits, ServerToolLimits(), "each reply starts a new budget")
    }

    func testWebPausePullsServerToolsForTheRestOfTheReply() async throws {
        let client = ScriptedLLMClient([
            toolRound([PlannedCall(id: "r1", name: "private_read", input: ["range": "today"])]),
            toolRound([echo("t2")]),
            finalReply("Here's your day."),
            finalReply("Next reply."),
        ])
        let executor = FakeToolExecutor()
        executor.scriptedOutcomes = [
            ToolRoundOutcome(webPause: WebPauseReason(privateSource: "your calendar", untrustedSource: "example.com")),
            ToolRoundOutcome(webPause: WebPauseReason(privateSource: "your calendar", untrustedSource: "example.com")),
        ]
        let (chat, _) = makeSession(client, executor: executor, tools: [EchoTool(), PrivateReadTool()])
        await run(chat)

        XCTAssertEqual(client.requests.map(\.serverToolLimits), [ServerToolLimits(), .none, .none])
        let message = try reply(chat)
        XCTAssertEqual(message.activities, [ToolActivity(
            id: ChatSession.webPausedActivityID,
            kind: .other,
            label: "Web access paused for the rest of this reply: this chat now holds your calendar and text from example.com.",
            isDone: true
        )])
        XCTAssertNil(AnthropicClient.makeRequestBody(client.requests[1])["tools"]?.arrayValue?
            .first { $0["name"] == "web_search" })

        await run(chat, "And tomorrow?")
        XCTAssertEqual(client.requests[3].serverToolLimits, ServerToolLimits())
    }

    func testWebPauseNeedsWebAccessAndTheSaferMode() async throws {
        for turnsWebOff in [true, false] {
            let settings = makeSettings()
            if turnsWebOff {
                settings.webAccess = false
            } else {
                settings.actionSafetyMode = .fewerPrompts
            }
            let client = ScriptedLLMClient([toolRound([echo("t1")]), finalReply("Done.")])
            let executor = FakeToolExecutor()
            executor.scriptedOutcomes = [
                ToolRoundOutcome(webPause: WebPauseReason(privateSource: "your calendar", untrustedSource: "a web search")),
            ]
            let (chat, _) = makeSession(client, executor: executor, settings: settings)
            await run(chat)
            XCTAssertTrue(try reply(chat).activities.isEmpty)
            XCTAssertEqual(client.requests[1].serverToolLimits, ServerToolLimits())
        }
    }

    func testPauseTurnResumptionKeepsThePausedRequestsServerTools() async throws {
        let pending: [JSONValue] = [["type": "server_tool_use", "id": "srv1", "name": "web_search", "input": ["query": "x"]]]
        let client = ScriptedLLMClient([
            toolRound([echo("t1")]),
            .events([
                .messageStart(model: "claude-opus-5"),
                .completed(StreamResult(content: pending, stopReason: "pause_turn", stopDetails: nil,
                                        model: "claude-opus-5", usage: usage(searches: 8))),
            ]),
            toolRound([echo("t2")]),
            finalReply("Done."),
        ])
        let executor = FakeToolExecutor()
        executor.scriptedOutcomes = [
            ToolRoundOutcome(),
            ToolRoundOutcome(webPause: WebPauseReason(privateSource: "your calendar", untrustedSource: "example.com")),
        ]
        let (chat, _) = makeSession(client, executor: executor)
        await run(chat)

        XCTAssertEqual(client.requests.map(\.serverToolLimits), [
            ServerToolLimits(),
            ServerToolLimits(),
            ServerToolLimits(),   // the pause_turn resumption keeps the paused request's tools
            .none,                // paused after the second round
        ])
        XCTAssertEqual(client.requests[2].messages.last, entry("assistant", pending))
    }

    func testBudgetAppliesAgainAfterAResumption() async throws {
        let client = ScriptedLLMClient([
            .events([
                .messageStart(model: "claude-opus-5"),
                .completed(StreamResult(content: [["type": "server_tool_use", "id": "s", "name": "web_search",
                                                   "input": ["query": "x"]]],
                                        stopReason: "pause_turn", stopDetails: nil, model: "claude-opus-5",
                                        usage: usage(searches: 9))),
            ]),
            toolRound([echo("t1")]),
            finalReply("Done."),
        ])
        let (chat, _) = makeSession(client, executor: FakeToolExecutor())
        await run(chat)
        XCTAssertEqual(client.requests.map(\.serverToolLimits), [
            ServerToolLimits(), ServerToolLimits(), ServerToolLimits(webSearch: 1, webFetch: 5),
        ])
    }

    // MARK: - systemUIToolWait

    private func dialogExecutor(dialog: Gate, running: Gate, finish: Gate) -> ClosureExecutor {
        let executor = ClosureExecutor()
        executor.body = { round, store, _ in
            for id in round.callIDs {
                guard let call = store.toolCall(id, in: round.messageID), let tool = round.tools[call.name],
                      let input = call.input else { continue }
                store.updateToolCall(id, in: round.messageID) { call in
                    call.presentation = tool.describe(input)
                    call.status = .waitingForSystem("Finder")
                }
                await dialog.wait()
                store.updateToolCall(id, in: round.messageID) { call in
                    call.status = .running
                    call.startedAt = (store as? ChatSession)?.clock()
                }
                await running.wait()
                await finish.wait()
                store.updateToolCall(id, in: round.messageID) { call in
                    call.status = .succeeded
                    call.result = .text("Finished.")
                }
            }
            return ToolRoundOutcome()
        }
        return executor
    }

    func testSystemUIToolWaitFollowsDialogsAndLongRunsOfToolsThatShowUI() async throws {
        let client = ScriptedLLMClient([
            toolRound([PlannedCall(id: "u1", name: "slow", input: ["label": "resize"])]),
            finalReply("Done."),
        ])
        let dialog = Gate(), running = Gate(), finish = Gate()
        let (chat, _) = makeSession(client, executor: dialogExecutor(dialog: dialog, running: running, finish: finish),
                                    tools: [SlowTool(mayPresentUI: true)])
        let timer = ManualTimer()
        timer.install(on: chat)
        chat.send(text: "Resize them", attachments: [])

        await waitUntil { chat.systemUIToolWait != nil }
        XCTAssertEqual(chat.systemUIToolWait, .toolDialog(appName: "Finder"))
        XCTAssertEqual(chat.phase, .awaitingApproval(label: "Wait"))

        dialog.open()
        await waitUntil { chat.messages.last?.toolCalls.first?.status == .running }
        XCTAssertNil(chat.systemUIToolWait, "a run shorter than the fold delay doesn't fold")
        XCTAssertEqual(timer.scheduled.count, 1)
        XCTAssertEqual(timer.scheduled.first?.delay, ToolLimits.uiFoldDelay)

        timer.now = timer.now.addingTimeInterval(0.5)
        timer.fireAll()
        XCTAssertNil(chat.systemUIToolWait)
        XCTAssertEqual(timer.scheduled.first?.delay, .milliseconds(500), "re-armed for the rest of the delay")

        timer.now = timer.now.addingTimeInterval(0.5)
        timer.fireAll()
        XCTAssertEqual(chat.systemUIToolWait, .toolRun(title: "Waiting…"))

        running.open()
        finish.open()
        await waitUntil { !chat.isStreaming }
        XCTAssertNil(chat.systemUIToolWait, "cleared when the turn finishes")
    }

    func testToolsThatShowNoUINeverFold() async throws {
        let client = ScriptedLLMClient([
            toolRound([PlannedCall(id: "u1", name: "slow", input: ["label": "x"])]),
            finalReply("Done."),
        ])
        let dialog = Gate(), running = Gate(), finish = Gate()
        dialog.open()
        let (chat, _) = makeSession(client, executor: dialogExecutor(dialog: dialog, running: running, finish: finish),
                                    tools: [SlowTool(mayPresentUI: false)])
        let timer = ManualTimer()
        timer.install(on: chat)
        chat.send(text: "Wait", attachments: [])
        await waitUntil { chat.messages.last?.toolCalls.first?.status == .running }
        timer.now = timer.now.addingTimeInterval(5)
        timer.fireAll()
        XCTAssertNil(chat.systemUIToolWait)
        XCTAssertTrue(timer.scheduled.isEmpty)
        running.open()
        finish.open()
        await waitUntil { !chat.isStreaming }
    }

    func testFewerPromptsModeKeepsDialogFoldsButNeverFoldsForRuns() async throws {
        let settings = makeSettings()
        settings.actionSafetyMode = .fewerPrompts
        let client = ScriptedLLMClient([
            toolRound([PlannedCall(id: "u1", name: "slow", input: ["label": "x"])]),
            finalReply("Done."),
        ])
        let dialog = Gate(), running = Gate(), finish = Gate()
        let (chat, _) = makeSession(client, executor: dialogExecutor(dialog: dialog, running: running, finish: finish),
                                    tools: [SlowTool(mayPresentUI: true)], settings: settings)
        let timer = ManualTimer()
        timer.install(on: chat)
        chat.send(text: "Resize", attachments: [])
        await waitUntil { chat.systemUIToolWait != nil }
        XCTAssertEqual(chat.systemUIToolWait, .toolDialog(appName: "Finder"))

        dialog.open()
        await waitUntil { chat.messages.last?.toolCalls.first?.status == .running }
        timer.now = timer.now.addingTimeInterval(3)
        timer.fireAll()
        XCTAssertNil(chat.systemUIToolWait)
        running.open()
        finish.open()
        await waitUntil { !chat.isStreaming }
    }

    // MARK: - Store, undo and stop

    func testSettledRepliesOnlyTakeUndoChanges() async throws {
        let client = ScriptedLLMClient([toolRound([sideEffect("s1")]), finalReply("Added.")])
        let executor = FakeToolExecutor()
        let (chat, _) = makeSession(client, executor: executor)
        await run(chat)
        let message = try reply(chat)

        chat.updateToolCall("s1", in: message.id) { call in
            call.status = .failed("Late")
            call.result = nil
        }
        XCTAssertEqual(chat.toolCall("s1", in: message.id)?.status, .succeeded, "a finished turn ignores the executor")

        let undone = await chat.undoToolCall("s1", in: message.id)
        XCTAssertNil(undone)
        XCTAssertEqual(executor.undoRequests, [.init(callID: "s1", messageID: message.id)])
        XCTAssertEqual(chat.toolCall("s1", in: message.id)?.status, .undone)
        XCTAssertEqual(chat.toolCall("s1", in: message.id)?.result, .text("Done."))

        executor.undoResult = "the event was already removed"
        let failure = await chat.undoToolCall("s1", in: message.id)
        XCTAssertEqual(failure, "the event was already removed")

        chat.stopToolCall("s1")
        XCTAssertEqual(executor.stoppedCallIDs, ["s1"])
        XCTAssertNil(chat.toolCall("missing", in: message.id))
    }

    func testUndoTokenAndDoneTitleLandOnASettledCall() async throws {
        let client = ScriptedLLMClient([toolRound([sideEffect("s1")]), finalReply("Added.")])
        let (chat, _) = makeSession(client, executor: FakeToolExecutor())
        await run(chat)
        let message = try reply(chat)
        let token = UndoToken(toolName: "side_effect", itemID: "id", fallback: nil, expires: Date(), doneTitle: "Removed",
                              noteForClaude: "it was removed")
        chat.updateToolCall("s1", in: message.id) { $0.undo = token }
        XCTAssertEqual(chat.toolCall("s1", in: message.id)?.undo, token)
        chat.updateToolCall("s1", in: message.id) { call in
            call.status = .undone
            call.presentation.doneTitle = "Removed"
        }
        XCTAssertEqual(chat.toolCall("s1", in: message.id)?.status, .undone)
        XCTAssertEqual(chat.toolCall("s1", in: message.id)?.presentation.doneTitle, "Removed")
    }
}
