//
//  NotchViewModelCommandTests.swift
//  OttoTests
//
//  Keyboard dispatch (§4.4): every NotchKeyCommand the mapper can produce does what the table says when the view
//  model performs it, and reports whether the key was consumed. Key presses go through the real mapper with the
//  view model's own key context, so the rows that must never act (a bare Return on "Quit & Reopen Otto" or on an
//  approval, consequential chords while only soft-focused) are checked end to end.
//

import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Otto

/// Which test covers each command. The switch has no default, so a new command fails to compile until it is covered.
private func coveringTest(for command: NotchKeyCommand) -> String {
    switch command {
    case .close, .newChat, .openSettings, .togglePin, .enterTallMode, .exitTallMode, .toggleShortcutSheet,
         .dismissOverlay, .selectModel, .copyLastReply:
        return "testPresentationCommands"
    case .pasteAsAttachment:
        // Performing it reads the user's general pasteboard, so only its mapping and consumption are checked.
        return "testPasteAsAttachmentIsConsumedOnlyWhenMapped"
    case .stop, .regenerate, .recallLastMessage, .cancelEditing:
        return "testConversationCommands"
    case .cancelVoice, .finishVoice, .stopSpeaking:
        return "testVoiceCommands"
    case .promptPrimary, .promptSecondary:
        return "testPromptCommandsAnswerTheVisibleCard, testApprovalsGetMayApproveAndVisibleSince"
    case .releaseSoftFocus:
        return "testReleaseSoftFocusHandsTheKeyboardBack"
    case .insertLastAnswer, .confirmInsert, .cancelInsertConfirmation:
        return "testInsertCommandsNeedSomethingToInsert + NotchViewModelFeatureTests insert flows"
    case .toggleHistory, .toggleShelf, .backToChat, .historyMoveSelection, .historyOpenSelected,
         .historyDeleteSelected, .historyUndoDelete, .historyFocusSearch:
        return "testRouteAndRecentsCommands + NotchViewModelFeatureTests.testRecentsOpenDeleteAndUndo"
    case .shelfAskAboutSelection, .shelfPaste:
        return "NotchViewModelFeatureTests.testAskingAboutShelfItemsSkipsFolders, testShelfPasteAddsTheClipboardsFiles"
    case .media, .joinMeeting, .showUsage:
        return "NotchViewModelFeatureTests.testMediaControlExplainsAutomationThenRetriesOnce, "
            + "testJoinMeetingOpensItsLinkAndUsageOpensSettings"
    }
}

@MainActor
final class NotchViewModelCommandTests: XCTestCase {
    /// Maps one key press through `NotchKeyCommands` with the view model's own context and performs the result.
    @discardableResult
    private func press(_ vm: NotchViewModel, keyCode: Int, characters: String?, flags: NSEvent.ModifierFlags = [],
                       input: InputEvidence = .trusted()) -> (command: NotchKeyCommand?, consumed: Bool) {
        let context = vm.keyContext(hasMarkedText: false, composerIsFirstResponder: true,
                                    clipboardWantsAttachmentPaste: false)
        guard let command = NotchKeyCommands.command(keyCode: UInt16(keyCode), characters: characters, flags: flags,
                                                     context: context) else { return (nil, false) }
        return (command, vm.perform(command, input: input))
    }

    private func approval(_ callID: String, armingDelay: Duration = .seconds(1)) -> PendingApproval {
        PendingApproval(callID: callID, messageID: UUID(), toolName: "side_effect", kind: .approval(rememberScope: nil),
                        presentation: .generic(toolName: "side_effect"),
                        body: .text(TextPreview(label: "Input", text: "hello", language: nil)), confirmLabel: "Run",
                        declineLabel: "Don't run", provenance: nil, caution: nil, armingDelay: armingDelay,
                        presentedAt: Date(timeIntervalSince1970: 0), position: 1, total: 1)
    }

    private func keyPress(at uptime: TimeInterval, isRepeat: Bool = false) -> InputEvidence {
        InputEvidence(source: .keyboard, isHardware: true, isRepeat: isRepeat, uptime: uptime)
    }

    private func conversation() -> [ChatMessage] {
        [ChatMessage(role: .user, text: "Question"), ChatMessage(role: .assistant, text: "Answer.")]
    }

    func testEveryCommandHasACoveringTest() {
        let commands: [NotchKeyCommand] = [
            .close, .newChat, .openSettings, .pasteAsAttachment, .stop, .regenerate, .recallLastMessage,
            .cancelEditing, .copyLastReply, .toggleShortcutSheet, .dismissOverlay, .selectModel(.sonnet5),
            .togglePin, .enterTallMode, .exitTallMode, .cancelVoice, .finishVoice, .stopSpeaking, .promptPrimary,
            .promptSecondary, .releaseSoftFocus, .insertLastAnswer(nil), .confirmInsert, .cancelInsertConfirmation,
            .toggleHistory, .toggleShelf, .backToChat, .historyMoveSelection(1), .historyOpenSelected,
            .historyDeleteSelected, .historyUndoDelete, .historyFocusSearch, .shelfAskAboutSelection, .shelfPaste,
            .media(.playPause), .joinMeeting, .showUsage,
        ]
        XCTAssertTrue(commands.allSatisfy { !coveringTest(for: $0).isEmpty })
    }

    // MARK: Presentation

    func testPresentationCommands() async {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        vm.togglePin()

        // ⌘W / Esc: a user close, which also unpins.
        XCTAssertEqual(press(vm, keyCode: kVK_ANSI_W, characters: "w", flags: .command).command, .close)
        XCTAssertFalse(vm.isOpen)
        XCTAssertFalse(vm.isPinned)

        vm.open(reason: .click, focus: true)
        XCTAssertEqual(press(vm, keyCode: kVK_ANSI_P, characters: "p", flags: .command).command, .togglePin)
        XCTAssertTrue(vm.isPinned)

        XCTAssertEqual(press(vm, keyCode: kVK_ANSI_Slash, characters: "/", flags: .command).command,
                       .toggleShortcutSheet)
        XCTAssertEqual(vm.overlay, .shortcutSheet)
        let escape = press(vm, keyCode: kVK_Escape, characters: "\u{1b}")
        XCTAssertEqual(escape.command, .dismissOverlay)
        XCTAssertTrue(escape.consumed)
        XCTAssertNil(vm.overlay)
        XCTAssertFalse(vm.perform(.dismissOverlay, hardwareConfirmed: true), "nothing to dismiss")

        XCTAssertEqual(press(vm, keyCode: kVK_ANSI_2, characters: "2", flags: .command).command,
                       .selectModel(.sonnet5))
        XCTAssertEqual(harness.settings.model, .sonnet5)
        XCTAssertEqual(vm.transientNotice?.text, "Switched to \(ModelOption.sonnet5.shortName)")

        // Tall mode needs a conversation.
        harness.chat.debugSeed(messages: conversation(), isStreaming: false)
        XCTAssertTrue(vm.perform(.enterTallMode, hardwareConfirmed: true))
        XCTAssertTrue(vm.isTallMode)
        XCTAssertTrue(vm.perform(.exitTallMode, hardwareConfirmed: true))
        XCTAssertFalse(vm.isTallMode)

        // ⌘⇧C with nothing to copy says so (and leaves the clipboard alone).
        harness.chat.debugSeed(messages: [], isStreaming: false)
        XCTAssertEqual(press(vm, keyCode: kVK_ANSI_C, characters: "c", flags: [.command, .shift]).command,
                       .copyLastReply)
        XCTAssertEqual(vm.transientError, "There's no reply to copy yet.")

        XCTAssertEqual(press(vm, keyCode: kVK_ANSI_Comma, characters: ",", flags: .command).command, .openSettings)
        XCTAssertFalse(vm.isOpen)
        XCTAssertEqual(harness.settingsRequests.count, 1)
        XCTAssertNil(harness.settingsRequests.first?.tab)

        vm.open(reason: .click, focus: true)
        vm.navigate(to: .shelf)
        harness.chat.debugSeed(messages: conversation(), isStreaming: false)
        XCTAssertEqual(press(vm, keyCode: kVK_ANSI_N, characters: "n", flags: .command).command, .newChat)
        XCTAssertTrue(harness.chat.messages.isEmpty)
        XCTAssertEqual(vm.route, .chat)
    }

    func testPasteAsAttachmentIsConsumedOnlyWhenMapped() {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        // Plain text on the clipboard: ⌘V is the composer's own paste, never the command.
        let context = vm.keyContext(hasMarkedText: false, composerIsFirstResponder: true,
                                    clipboardWantsAttachmentPaste: false)
        XCTAssertNil(NotchKeyCommands.command(keyCode: UInt16(kVK_ANSI_V), characters: "v", flags: .command,
                                              context: context))
        let files = vm.keyContext(hasMarkedText: false, composerIsFirstResponder: true,
                                  clipboardWantsAttachmentPaste: true)
        XCTAssertEqual(NotchKeyCommands.command(keyCode: UInt16(kVK_ANSI_V), characters: "v", flags: .command,
                                                context: files), .pasteAsAttachment)
    }

    // MARK: Conversation

    func testConversationCommands() async {
        let harness = NotchFeatureHarness(self, responses: [
            notchFeatureReply("First answer."), notchFeatureReply("Second answer."),
            .stall([.messageStart(model: "claude-opus-5"), .textDelta("Thinking about")]),
        ])
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        vm.composerText = "Question"
        vm.send()
        await harness.waitForIdle()

        // ⌘R answers again; the first reply is kept as a version.
        XCTAssertEqual(press(vm, keyCode: kVK_ANSI_R, characters: "r", flags: .command).command, .regenerate)
        await harness.waitForIdle()
        XCTAssertEqual(harness.chat.messages.last?.text, "Second answer.")
        XCTAssertEqual(harness.chat.lastTurnVersions?.replies.count, 2)

        // ↑ recalls into an empty composer only.
        vm.composerText = "draft"
        XCTAssertFalse(vm.perform(.recallLastMessage, hardwareConfirmed: true))
        vm.composerText = ""
        XCTAssertEqual(press(vm, keyCode: kVK_UpArrow, characters: nil).command, .recallLastMessage)
        XCTAssertTrue(vm.isEditing)
        XCTAssertEqual(vm.composerText, "Question")
        XCTAssertEqual(press(vm, keyCode: kVK_Escape, characters: "\u{1b}").command, .cancelEditing)
        XCTAssertFalse(vm.isEditing)
        XCTAssertTrue(vm.composerText.isEmpty)
        XCTAssertFalse(vm.perform(.cancelEditing, hardwareConfirmed: true))

        // ⌘. stops a streaming reply.
        vm.composerText = "Another"
        vm.send()
        await notchWaitUntil { harness.chat.messages.last?.text.isEmpty == false }
        let stop = press(vm, keyCode: kVK_ANSI_Period, characters: ".", flags: .command)
        XCTAssertEqual(stop.command, .stop)
        XCTAssertTrue(stop.consumed)
        await harness.waitForIdle()
        XCTAssertEqual(harness.chat.messages.last?.state, .cancelled)

        // With nothing running it is still consumed.
        XCTAssertTrue(vm.perform(.stop, hardwareConfirmed: true))
    }

    // MARK: Voice

    func testVoiceCommands() async {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        await harness.enableVoice()
        harness.engines.script = [(.zero, "note to self", 0.5)]
        harness.settings.voice.autoSend = false
        vm.open(reason: .click, focus: true)

        vm.beginVoice(.toggle(.micButton))
        await notchWaitUntil { vm.voice.isListening }
        XCTAssertEqual(press(vm, keyCode: kVK_Escape, characters: "\u{1b}").command, .cancelVoice)
        XCTAssertEqual(vm.voice.phase, .idle)
        XCTAssertTrue(vm.composerText.isEmpty, "Esc discards what was heard")

        vm.beginVoice(.toggle(.micButton))
        await notchWaitUntil { !vm.voice.transcript.isEmpty }
        XCTAssertEqual(press(vm, keyCode: kVK_Return, characters: "\r").command, .finishVoice)
        await notchWaitUntil { vm.voice.phase == .idle }
        XCTAssertEqual(vm.composerText, "note to self", "auto-send off: the words wait in the composer")

        // ⌘. while listening cancels it.
        vm.composerText = ""
        vm.beginVoice(.toggle(.micButton))
        await notchWaitUntil { vm.voice.isListening }
        XCTAssertTrue(vm.perform(.stop, hardwareConfirmed: true))
        XCTAssertEqual(vm.voice.phase, .idle)

        XCTAssertTrue(vm.perform(.stopSpeaking, hardwareConfirmed: true))
        XCTAssertFalse(vm.voice.isSpeaking)
    }

    // MARK: Dock

    func testPromptCommandsAnswerTheVisibleCard() async {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        XCTAssertFalse(vm.perform(.promptPrimary, hardwareConfirmed: true), "no prompt: not consumed")
        XCTAssertFalse(vm.perform(.promptSecondary, hardwareConfirmed: true))

        vm.presentNeighborCardIfNeeded([NotchNeighbor.known[0]])
        vm.close(.user)
        vm.open(reason: .click, focus: true)
        XCTAssertNotNil(vm.card)
        // Esc takes the card's escape action (keep hover), never the primary.
        let escape = press(vm, keyCode: kVK_Escape, characters: "\u{1b}")
        XCTAssertEqual(escape.command, .promptSecondary)
        XCTAssertTrue(escape.consumed)
        XCTAssertNil(vm.card)
        XCTAssertTrue(harness.settings.notch.hoverToOpen)
        XCTAssertEqual(harness.settings.notch.acknowledgedNeighbors, [NotchNeighbor.known[0].name])

        // Return runs a card's primary when the composer is empty.
        vm.present(card: NotchViewModel.voiceConsentCard(pendingMode: .toggle(.micButton), settings: harness.settings))
        let enter = press(vm, keyCode: kVK_Return, characters: "\r")
        XCTAssertEqual(enter.command, .promptPrimary)
        XCTAssertTrue(harness.settings.voice.enabled)
    }

    func testBareReturnNeverRunsQuitAndReopen() async {
        let harness = NotchFeatureHarness(self, statuses: [.screenRecording: .needsRelaunch])
        let vm = harness.vm
        let flow = Task { await vm.requestPermission(.screenRecording, for: .windowCapture(appName: "Xcode")) }
        await notchWaitUntil { vm.permissionPrompt != nil }
        XCTAssertEqual(vm.permissionCardContent?.primaryAction, .relaunch)

        let bare = press(vm, keyCode: kVK_Return, characters: "\r")
        XCTAssertNil(bare.command, "a bare Return falls through to the composer")
        XCTAssertEqual(harness.relauncher.count, 0)
        XCTAssertNotNil(vm.permissionPrompt)

        let command = press(vm, keyCode: kVK_Return, characters: "\r", flags: .command)
        XCTAssertEqual(command.command, .promptPrimary)
        XCTAssertTrue(command.consumed)
        XCTAssertEqual(harness.relauncher.count, 1)

        vm.permissionPromptAction(.dismiss)
        _ = await flow.value
    }

    func testApprovalsGetMayApproveAndVisibleSince() {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        harness.executor.pendingApproval = approval("call-1")
        vm.open(reason: .click, focus: true)
        harness.uptime = 800
        vm.noteApprovalReviewed(callID: "call-1")
        let since = vm.approvalVisibility?.since
        XCTAssertEqual(since, harness.now)

        // A bare Return never approves.
        XCTAssertNil(press(vm, keyCode: kVK_Return, characters: "\r").command)
        XCTAssertTrue(harness.executor.resolveCalls.isEmpty)

        // ⌘↩ before the card armed, a held key, synthetic input: sent, but never hardware-confirmed.
        press(vm, keyCode: kVK_Return, characters: "\r", flags: .command, input: keyPress(at: 800.5))
        press(vm, keyCode: kVK_Return, characters: "\r", flags: .command, input: keyPress(at: 801.5, isRepeat: true))
        press(vm, keyCode: kVK_Return, characters: "\r", flags: .command, input: .programmatic)
        XCTAssertEqual(harness.executor.resolveCalls.map(\.hardwareConfirmed), [false, false, false])
        XCTAssertEqual(harness.executor.resolveCalls.map(\.visibleSince), [since, since, since])
        XCTAssertNotNil(harness.chat.pendingApproval)

        let approve = press(vm, keyCode: kVK_Return, characters: "\r", flags: .command, input: keyPress(at: 801.2))
        XCTAssertEqual(approve.command, .promptPrimary)
        XCTAssertTrue(approve.consumed)
        XCTAssertEqual(harness.executor.resolveCalls.last,
                       FakeToolExecutor.ResolveCall(decision: .run(ApprovalOptions()), callID: "call-1",
                                                    hardwareConfirmed: true, visibleSince: since))
        XCTAssertNil(harness.chat.pendingApproval)

        // Esc declines, with neither visibility nor hardware input.
        harness.executor.pendingApproval = approval("call-2")
        vm.close(.outsideClick)
        vm.open(reason: .click, focus: true)
        XCTAssertEqual(press(vm, keyCode: kVK_Escape, characters: "\u{1b}", input: .programmatic).command,
                       .promptSecondary)
        XCTAssertEqual(harness.executor.resolveCalls.last?.decision, .deny)
        XCTAssertNil(harness.executor.resolveCalls.last?.visibleSince)
    }

    func testReleaseSoftFocusHandsTheKeyboardBack() {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        harness.executor.pendingApproval = approval("call-1")
        vm.open(reason: .hover, focus: false)
        vm.softFocus()
        XCTAssertTrue(vm.isSoftFocused)
        XCTAssertEqual(harness.keyRequests.last, true)

        // ⌘↩ over a visible approval while only soft-focused: the keyboard goes back, nothing is approved.
        let chord = press(vm, keyCode: kVK_Return, characters: "\r", flags: .command, input: keyPress(at: 9_999))
        XCTAssertEqual(chord.command, .releaseSoftFocus)
        XCTAssertTrue(chord.consumed)
        XCTAssertFalse(vm.isSoftFocused)
        XCTAssertFalse(vm.isEngaged)
        XCTAssertTrue(vm.isOpen)
        XCTAssertEqual(harness.keyRequests.last, false)
        XCTAssertTrue(harness.executor.resolveCalls.isEmpty)
        XCTAssertNotNil(harness.chat.pendingApproval)

        // Performed directly it also reports the key as consumed.
        vm.softFocus()
        XCTAssertTrue(vm.perform(.releaseSoftFocus, hardwareConfirmed: false))
        XCTAssertFalse(vm.isSoftFocused)
        XCTAssertEqual(harness.keyRequests.last, false)
    }

    // MARK: Insert

    func testInsertCommandsNeedSomethingToInsert() {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm
        vm.open(reason: .click, focus: true)
        XCTAssertFalse(vm.canInsertLastAnswer)
        XCTAssertFalse(vm.perform(.insertLastAnswer(nil), hardwareConfirmed: true))
        XCTAssertFalse(vm.perform(.insertLastAnswer(.pastePlain), hardwareConfirmed: true))
        XCTAssertFalse(vm.perform(.confirmInsert, hardwareConfirmed: true))
        XCTAssertFalse(vm.perform(.cancelInsertConfirmation, hardwareConfirmed: true))
        // With an empty composer and nothing to paste, ⌘↩ isn't a command at all.
        XCTAssertNil(press(vm, keyCode: kVK_Return, characters: "\r", flags: .command).command)
    }

    // MARK: Routes and Recents

    func testRouteAndRecentsCommands() {
        let harness = NotchFeatureHarness(self)
        let vm = harness.vm

        // ⌘Y opens Recents focused when closed; ⌘Y again goes back to Chat.
        XCTAssertTrue(vm.perform(.toggleHistory, hardwareConfirmed: true))
        XCTAssertTrue(vm.isOpen)
        XCTAssertTrue(vm.isEngaged)
        XCTAssertEqual(vm.route, .history)
        XCTAssertEqual(press(vm, keyCode: kVK_ANSI_Y, characters: "y", flags: .command).command, .toggleHistory)
        XCTAssertEqual(vm.route, .chat)

        XCTAssertEqual(press(vm, keyCode: kVK_ANSI_D, characters: "d", flags: .command).command, .toggleShelf)
        XCTAssertEqual(vm.route, .shelf)
        XCTAssertEqual(press(vm, keyCode: kVK_Escape, characters: "\u{1b}").command, .backToChat)
        XCTAssertEqual(vm.route, .chat)

        harness.settings.shelf.enabled = false
        XCTAssertFalse(vm.perform(.toggleShelf, hardwareConfirmed: true))
        XCTAssertEqual(vm.route, .chat)

        let now = harness.now
        let summaries = [UUID(), UUID(), UUID()].enumerated().map { index, id in
            ConversationSummary.fixture(id: id, title: "Chat \(index)", updatedAt: now.addingTimeInterval(-Double(index)))
        }
        harness.history.debugSeed(summaries: summaries, continuation: nil)
        vm.toggleHistory()
        XCTAssertEqual(vm.route, .history)
        let first = vm.recents.selectedID
        XCTAssertNotNil(first)
        XCTAssertEqual(press(vm, keyCode: kVK_DownArrow, characters: nil).command, .historyMoveSelection(1))
        XCTAssertNotEqual(vm.recents.selectedID, first)
        XCTAssertEqual(press(vm, keyCode: kVK_UpArrow, characters: nil).command, .historyMoveSelection(-1))
        XCTAssertEqual(vm.recents.selectedID, first)

        let focusRequests = vm.recents.searchFocusRequest
        XCTAssertEqual(press(vm, keyCode: kVK_ANSI_F, characters: "f", flags: .command).command, .historyFocusSearch)
        XCTAssertEqual(vm.recents.searchFocusRequest, focusRequests + 1)

        XCTAssertFalse(vm.perform(.historyUndoDelete, hardwareConfirmed: true), "nothing to undo")
        vm.recents.selectedID = nil
        XCTAssertFalse(vm.perform(.historyOpenSelected, hardwareConfirmed: true))
        XCTAssertFalse(vm.perform(.historyDeleteSelected, hardwareConfirmed: true))
    }
}

private extension ConversationSummary {
    static func fixture(id: UUID, title: String, updatedAt: Date) -> ConversationSummary {
        ConversationSummary(id: id, title: title, preview: "Preview", searchText: title, createdAt: updatedAt,
                            updatedAt: updatedAt, messageCount: 2, attachmentCount: 0, model: nil, blobs: [:],
                            fileBytes: 100, fileModifiedAt: updatedAt)
    }
}
