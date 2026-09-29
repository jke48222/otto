//
//  SendGateTests.swift
//  OttoTests
//
//  The composer gate on the notch view model (SPEC-v2 §14.10.1), in every flavor through a private fake
//  ComposerGating: while a gate is up nothing can start a request, a blocked send or voice send keeps the draft,
//  its chips and the transcript and bumps `gateAttention`, the gate's choices route to the browser (after the notch
//  closes), to Settings and back to the gate's owner; with no gate the view model behaves as before.
//

import XCTest
@testable import Otto

/// A gate whose value the test sets; records the gate actions it is asked to handle.
@MainActor @Observable
private final class FakeSendGate: ComposerGating {
    var composerGate: ComposerGate?
    private(set) var handledActions: [String] = []

    init(_ gate: ComposerGate?) {
        composerGate = gate
    }

    func handleGateAction(_ id: String) {
        handledActions.append(id)
    }
}

private let buyURL = URL(string: "https://otto.example/buy")

/// The paid build's "trial-ended" gate, spelled out so the test compiles without the licensing flag.
private func trialEndedGate() -> ComposerGate {
    ComposerGate(
        id: "trial-ended",
        symbol: "hourglass",
        message: "Your 14-day trial has ended.",
        choices: [
            ComposerGate.Choice(title: "Buy a License",
                                action: .openURL(buyURL ?? URL(fileURLWithPath: "/")),
                                isPrimary: true),
            ComposerGate.Choice(title: "Enter License", action: .openSettings(.general, .usage), isPrimary: false),
        ]
    )
}

private func checkRequiredGate() -> ComposerGate {
    ComposerGate(
        id: "check-required",
        symbol: "wifi.exclamationmark",
        message: "Otto needs to check your license before it can send.",
        choices: [ComposerGate.Choice(title: "Check Now", action: .gate("check-now"), isPrimary: true)]
    )
}

private func reply(_ text: String) -> ScriptedLLMClient.Response {
    .events([
        .messageStart(model: "claude-opus-5"),
        .textDelta(text),
        .completed(StreamResult(content: [["type": "text", "text": .string(text)]], stopReason: "end_turn",
                                stopDetails: nil, model: "claude-opus-5", usage: nil)),
    ])
}

private func textAttachment(_ name: String) -> Attachment {
    Attachment(kind: .text, displayName: name, badge: "TXT", sourceURL: URL(fileURLWithPath: "/tmp/otto-tests/\(name)"),
               payload: .text("notes"), byteCount: 5)
}

@MainActor
final class SendGateTests: XCTestCase {
    private struct Harness {
        let vm: NotchViewModel
        let chat: ChatSession
        let client: ScriptedLLMClient
        let gate: FakeSendGate?
    }

    /// A view model over inert services; `gate` (when given) is its send gate.
    private func makeHarness(gate: ComposerGate?, installsGate: Bool = true,
                             responses: [ScriptedLLMClient.Response] = [reply("Hi.")]) -> Harness {
        let settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        // Keep the tests away from AppleScript lookups of whatever browser happens to be frontmost.
        settings.suggestBrowserTab = false
        let client = ScriptedLLMClient(responses)
        let chat = ChatSession(settings: settings, makeClient: { client })
        let fake = installsGate ? FakeSendGate(gate) : nil
        var services = NotchServices.inert(settings: settings, chat: chat)
        services.sendGate = fake
        let vm = NotchViewModel(settings: settings, chat: chat, services: services)
        return Harness(vm: vm, chat: chat, client: client, gate: fake)
    }

    private func waitUntil(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: - A gate is up

    func testAGateMakesSendingImpossible() {
        let harness = makeHarness(gate: trialEndedGate())
        let vm = harness.vm
        vm.composerText = "hello"

        XCTAssertTrue(vm.sendGate === harness.gate)
        XCTAssertEqual(vm.composerGate?.id, "trial-ended")
        XCTAssertTrue(vm.isSendBlocked)
        XCTAssertFalse(vm.canSend, "a draft that could go stays put while sending is paused")
        XCTAssertEqual(vm.gateAttention, 0)
    }

    func testBlockedSendKeepsTheDraftAndItsChips() async {
        let harness = makeHarness(gate: trialEndedGate())
        let vm = harness.vm
        vm.composerText = "hello"
        vm.addAttachment(textAttachment("notes.txt"))

        vm.send()
        await Task.yield()

        XCTAssertEqual(harness.chat.messageCount, 0, "no user message")
        XCTAssertTrue(harness.client.requests.isEmpty, "no request")
        XCTAssertEqual(vm.composerText, "hello", "the draft stays")
        XCTAssertEqual(vm.attachments.map(\.displayName), ["notes.txt"], "the chips stay")
        XCTAssertEqual(vm.gateAttention, 1, "the line pulses once")

        vm.send()
        XCTAssertEqual(vm.gateAttention, 2, "each attempt pulses again")
        XCTAssertEqual(vm.composerText, "hello")
    }

    func testAnEmptyComposerIsNotABlockedAttempt() {
        let harness = makeHarness(gate: trialEndedGate())
        harness.vm.send()
        XCTAssertEqual(harness.vm.gateAttention, 0, "Return with nothing to send doesn't pulse the line")
        XCTAssertEqual(harness.chat.messageCount, 0)
    }

    func testBlockedVoiceSendKeepsTheTranscriptInTheComposer() async {
        let harness = makeHarness(gate: trialEndedGate())
        let vm = harness.vm
        vm.settings.voice.autoSend = true

        vm.handleVoiceResult("What's the weather in Lisbon", send: true)
        await Task.yield()

        XCTAssertEqual(harness.chat.messageCount, 0, "the voice turn didn't send")
        XCTAssertTrue(harness.client.requests.isEmpty)
        XCTAssertEqual(vm.composerText, "What's the weather in Lisbon", "the transcript waits in the composer")
        XCTAssertEqual(vm.gateAttention, 1)
    }

    func testRegenerateAndRetryFromTheReplyFooterAreBlocked() async {
        // The footer's Regenerate and Retry ask blockIfSendingPaused() first and stop when it says true.
        let harness = makeHarness(gate: nil, responses: [reply("First answer.")])
        let vm = harness.vm
        vm.composerText = "Question"
        vm.send()
        await waitUntil { !harness.chat.isStreaming && harness.chat.messageCount == 2 }
        let messagesBefore = harness.chat.messages

        harness.gate?.composerGate = trialEndedGate()
        XCTAssertTrue(vm.blockIfSendingPaused(), "a regenerate or retry stops here")
        XCTAssertEqual(vm.gateAttention, 1)
        XCTAssertEqual(harness.chat.messages, messagesBefore, "the reply and its turn are untouched")
        XCTAssertEqual(harness.client.requests.count, 1, "no second request")

        XCTAssertTrue(vm.blockIfSendingPaused(attempted: false), "a check that isn't an attempt…")
        XCTAssertEqual(vm.gateAttention, 1, "…doesn't pulse the line")
    }

    // MARK: - Choices

    func testBuyClosesTheNotchThenOpensTheLink() throws {
        let harness = makeHarness(gate: trialEndedGate())
        let vm = harness.vm
        var opened: [(url: URL, wasOpen: Bool)] = []
        vm.openExternalURL = { [weak vm] url in opened.append((url, vm?.isOpen ?? false)) }
        vm.open(reason: .click, focus: true)
        XCTAssertTrue(vm.isOpen)

        let buy = try XCTUnwrap(vm.composerGate?.choices.first { $0.title == "Buy a License" })
        vm.performGateChoice(buy)

        XCTAssertFalse(vm.isOpen, "the notch closes for the browser")
        XCTAssertEqual(opened.map(\.url), [try XCTUnwrap(buyURL)])
        XCTAssertEqual(opened.first?.wasOpen, false, "the link opens after the notch closed")
    }

    func testSettingsChoiceOpensItsTabAndSection() throws {
        let harness = makeHarness(gate: trialEndedGate())
        let vm = harness.vm
        var requests: [(tab: SettingsTab?, anchor: SettingsAnchor?)] = []
        vm.onOpenSettingsTab = { tab, anchor in requests.append((tab, anchor)) }
        vm.open(reason: .click, focus: true)

        let enter = try XCTUnwrap(vm.composerGate?.choices.first { $0.title == "Enter License" })
        vm.performGateChoice(enter)

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.tab, .general)
        XCTAssertEqual(requests.first?.anchor, .usage)
        XCTAssertFalse(vm.isOpen, "Settings takes over from the notch")
        XCTAssertTrue(harness.gate?.handledActions.isEmpty ?? false)
    }

    func testGateChoiceGoesBackToTheGatesOwner() throws {
        let harness = makeHarness(gate: checkRequiredGate())
        let check = try XCTUnwrap(harness.vm.composerGate?.choices.first)

        harness.vm.performGateChoice(check)

        XCTAssertEqual(harness.gate?.handledActions, ["check-now"])
    }

    // MARK: - The gate goes away

    func testSendingWorksAgainOnceTheGateLifts() async {
        let harness = makeHarness(gate: trialEndedGate())
        let vm = harness.vm
        vm.composerText = "hello"
        vm.send()
        XCTAssertEqual(harness.chat.messageCount, 0)

        harness.gate?.composerGate = nil
        XCTAssertFalse(vm.isSendBlocked)
        XCTAssertTrue(vm.canSend)
        vm.send()
        await waitUntil { !harness.chat.isStreaming && harness.chat.messageCount == 2 }

        XCTAssertEqual(harness.chat.messages.first?.text, "hello")
        XCTAssertEqual(vm.composerText, "", "sent drafts clear as before")
        XCTAssertEqual(vm.gateAttention, 1, "only the blocked attempt counted")
    }

    // MARK: - No gate

    func testWithoutAGateNothingChanges() async {
        let harness = makeHarness(gate: nil, installsGate: false)
        let vm = harness.vm
        XCTAssertNil(vm.sendGate)
        XCTAssertNil(vm.composerGate)
        XCTAssertFalse(vm.isSendBlocked)
        XCTAssertFalse(vm.blockIfSendingPaused())

        vm.composerText = "hello"
        XCTAssertTrue(vm.canSend)
        vm.send()
        await waitUntil { !harness.chat.isStreaming && harness.chat.messageCount == 2 }

        XCTAssertEqual(harness.client.requests.count, 1)
        XCTAssertEqual(vm.composerText, "")
        XCTAssertEqual(vm.gateAttention, 0)
    }

    func testTheDefaultInitializerHasNoGate() {
        let settings = AppSettings(defaults: TestDefaults.make(for: self), usesKeychain: false)
        settings.suggestBrowserTab = false
        let vm = NotchViewModel(settings: settings, chat: ChatSession(settings: settings, makeClient: { MockLLMClient() }))
        XCTAssertNil(vm.sendGate, "NotchServices.inert keeps nil")
        XCTAssertFalse(vm.isSendBlocked)
    }
}
