//
//  HistoryControllerTests.swift
//  Otto
//
//  HistoryController on a real ChatSession (scripted client), an in-memory store and an injected clock:
//  saving, idle fresh start, ⌘N continuation, opening while streaming, delete with Undo, Delete All,
//  History off, retention, launch restore, reading position, onDataRemoved, and RecentsState.
//

import XCTest
@testable import Otto

// MARK: - Fixtures

private func textBlock(_ text: String) -> JSONValue {
    ["type": "text", "text": .string(text)]
}

private func reply(_ text: String) -> ScriptedLLMClient.Response {
    .events([
        .messageStart(model: "claude-opus-5"),
        .textDelta(text),
        .completed(StreamResult(content: [textBlock(text)], stopReason: "end_turn", stopDetails: nil,
                                model: "claude-opus-5", usage: nil)),
    ])
}

private func imageAttachment() -> Attachment {
    let base64 = Data((0..<24_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }).base64EncodedString()
    return Attachment(kind: .image, displayName: "chart.png", badge: "PNG",
                      payload: .image(mediaType: "image/png", base64: base64), byteCount: base64.utf8.count)
}

/// A clock the tests move by hand.
private final class HistoryTestClock {
    var now = Date(timeIntervalSince1970: 1_790_500_000)

    func advance(minutes: Double) {
        now = now.addingTimeInterval(minutes * 60)
    }
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

/// One controller under test with everything it talks to.
@MainActor
private struct HistoryHarness {
    let settings: AppSettings
    let chat: ChatSession
    let client: ScriptedLLMClient
    let store: ConversationStore
    let clock: HistoryTestClock
    let history: HistoryController
    let removals: RemovalLog

    /// Sends `text`, waits for the scripted reply and (with History on) for the turn-end save to reach the index.
    func sendAndFinish(_ text: String, attachments: [Attachment] = [], expectSave: Bool = true,
                       file: StaticString = #filePath, line: UInt = #line) async {
        chat.send(text: text, attachments: attachments)
        await waitUntil(file: file, line: line) { !chat.isStreaming }
        if expectSave { await settleSaves(file: file, line: line) }
    }

    /// Waits until the index shows the chat's conversation as it is now.
    func settleSaves(file: StaticString = #filePath, line: UInt = #line) async {
        let id = chat.conversationID
        let count = chat.messageCount
        let preview = ConversationTitler.preview(for: chat.messages)
        await waitUntil(file: file, line: line) {
            history.summaries.contains { $0.id == id && $0.messageCount == count && $0.preview == preview }
        }
    }

    func stored(_ id: UUID) async throws -> LoadedConversation {
        try await store.load(id: id)
    }
}

@MainActor
private final class RemovalLog {
    var removals: [HistoryRemoval] = []
}

@MainActor
final class HistoryControllerTests: XCTestCase {
    private func makeHarness(
        responses: [ScriptedLLMClient.Response],
        store: ConversationStore = ConversationStore(location: .inMemory),
        undoWindow: Duration = .milliseconds(80),
        configure: (AppSettings) -> Void = { _ in }
    ) throws -> HistoryHarness {
        let suiteName = "otto.tests.history.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults, usesKeychain: false)
        configure(settings)
        let client = ScriptedLLMClient(responses)
        let chat = ChatSession(settings: settings, makeClient: { client })
        let clock = HistoryTestClock()
        var policy = HistoryPolicy.standard
        policy.undoWindow = undoWindow
        let history = HistoryController(settings: settings, chat: chat, store: store, policy: policy, now: { clock.now })
        let removals = RemovalLog()
        history.onDataRemoved = { removals.removals.append($0) }
        return HistoryHarness(settings: settings, chat: chat, client: client, store: store, clock: clock,
                              history: history, removals: removals)
    }

    // MARK: Saving

    func testSavesWhenTheMessageIsSentAndAgainWhenTheReplyFinishes() async throws {
        let harness = try makeHarness(responses: [.stall([.messageStart(model: "claude-opus-5")])])
        let chat = harness.chat
        let history = harness.history

        chat.send(text: "hey otto, can you explain Swift actors? I keep forgetting", attachments: [])
        await waitUntil { history.summaries.count == 1 }
        let sent = try XCTUnwrap(history.summaries.first)
        XCTAssertEqual(sent.id, chat.conversationID)
        XCTAssertEqual(sent.title, "Explain Swift actors?")
        XCTAssertEqual(sent.messageCount, 2)
        XCTAssertTrue(chat.isStreaming)
        let atSend = try await harness.stored(sent.id)
        XCTAssertEqual(atSend.messages.count, 1, "the empty in-flight reply is saved as interrupted and dropped on load")

        chat.cancel()
        // The store runs work in order, so this load sees the save the cancel just queued.
        let atFinish = try await harness.stored(sent.id)
        XCTAssertEqual(atFinish.messages.map(\.state), [.complete, .cancelled], "the turn-end save replaced the send-time one")
        XCTAssertNil(history.lastSaveError)
    }

    func testTitleComesFromTheFirstMessageAndSummaryFollowsReplies() async throws {
        let harness = try makeHarness(responses: [reply("Actors isolate state."), reply("Tasks run concurrently.")])
        await harness.sendAndFinish("what are actors")
        let first = try XCTUnwrap(harness.history.summaries.first)
        XCTAssertEqual(first.title, "What are actors")
        XCTAssertEqual(first.preview, "Actors isolate state.")

        await harness.sendAndFinish("and tasks?")
        let second = try XCTUnwrap(harness.history.summaries.first)
        XCTAssertEqual(harness.history.summaries.count, 1)
        XCTAssertEqual(second.title, "What are actors", "the title never changes")
        XCTAssertEqual(second.preview, "Tasks run concurrently.")
        XCTAssertEqual(second.messageCount, 4)
    }

    func testHistoryOffSavesNothingButContinueStillWorks() async throws {
        let harness = try makeHarness(responses: [reply("Sure.")]) { $0.history.enabled = false }
        let chat = harness.chat
        let history = harness.history
        await harness.sendAndFinish("remember this", attachments: [imageAttachment()], expectSave: false)
        let conversationID = chat.conversationID
        let messages = chat.messages
        let index = await harness.store.loadIndex()
        XCTAssertTrue(index.isEmpty)

        history.startNewConversation()
        XCTAssertEqual(chat.messageCount, 0)
        XCTAssertEqual(history.continuation?.id, conversationID)
        XCTAssertEqual(history.continuation?.title, "Remember this")

        let continued = await history.continueConversation()
        XCTAssertTrue(continued)
        XCTAssertEqual(chat.conversationID, conversationID)
        XCTAssertEqual(chat.messages, messages, "full payloads from the in-memory copy")
        XCTAssertNil(history.continuation)
        let after = await harness.store.loadIndex()
        XCTAssertTrue(after.isEmpty)
    }

    // MARK: Continuity

    func testIdleFreshStartOffersTheOldConversationAndContinueRestoresIt() async throws {
        let harness = try makeHarness(responses: [reply("Here you go.")])
        let chat = harness.chat
        let history = harness.history
        let image = imageAttachment()
        await harness.sendAndFinish("describe this chart", attachments: [image])
        let conversationID = chat.conversationID
        let messages = chat.messages

        harness.clock.advance(minutes: 5)
        XCTAssertFalse(history.startFreshIfIdle(hasUnreadReply: false, hasDraft: false), "not idle yet")
        harness.clock.advance(minutes: 15)
        XCTAssertFalse(history.startFreshIfIdle(hasUnreadReply: true, hasDraft: false), "unread reply waits")
        XCTAssertFalse(history.startFreshIfIdle(hasUnreadReply: false, hasDraft: true), "draft waits")
        XCTAssertTrue(history.startFreshIfIdle(hasUnreadReply: false, hasDraft: false))

        XCTAssertEqual(chat.messageCount, 0)
        XCTAssertNotEqual(chat.conversationID, conversationID)
        XCTAssertEqual(history.continuation?.id, conversationID)

        let continued = await history.continueConversation()
        XCTAssertTrue(continued)
        XCTAssertEqual(chat.conversationID, conversationID)
        XCTAssertEqual(chat.messages, messages)
        XCTAssertEqual(chat.messages.first?.attachments.first?.payload, image.payload)
        XCTAssertNil(history.continuation)
    }

    func testNewChatOffersContinuationAndSendingClearsIt() async throws {
        let harness = try makeHarness(responses: [reply("One."), reply("Two.")])
        let chat = harness.chat
        let history = harness.history
        await harness.sendAndFinish("first chat")
        let firstID = chat.conversationID

        history.startNewConversation()
        XCTAssertEqual(history.continuation?.id, firstID)
        XCTAssertEqual(history.continuation?.title, "First chat")

        chat.send(text: "second chat", attachments: [])
        XCTAssertNil(history.continuation, "sending in the new chat dismisses the chip")
        await waitUntil { !chat.isStreaming }
        await harness.settleSaves()
        XCTAssertEqual(history.summaries.count, 2)

        history.startNewConversation()
        XCTAssertNotNil(history.continuation)
        history.dismissContinuation()
        XCTAssertNil(history.continuation)
    }

    func testOpeningFromDiskWhileStreamingCancelsAndSavesTheReply() async throws {
        let harness = try makeHarness(responses: [reply("Stored answer."), .stall([.messageStart(model: "claude-opus-5")])])
        let chat = harness.chat
        let history = harness.history
        await harness.sendAndFinish("stored question")
        let storedID = chat.conversationID

        history.startNewConversation()
        chat.send(text: "streaming question", attachments: [])
        let streamingID = chat.conversationID
        XCTAssertTrue(chat.isStreaming)

        let opened = await history.open(storedID)
        XCTAssertTrue(opened)
        XCTAssertFalse(chat.isStreaming)
        XCTAssertEqual(chat.conversationID, storedID)
        XCTAssertEqual(chat.messages.map(\.text), ["stored question", "Stored answer."])
        XCTAssertNil(history.lastOpenError)

        await waitUntil { history.summaries.contains { $0.id == streamingID } }
        let left = try await harness.stored(streamingID)
        XCTAssertEqual(left.messages.map(\.state), [.complete, .cancelled])

        let failed = await history.open(UUID())
        XCTAssertFalse(failed)
        XCTAssertEqual(history.lastOpenError, "Couldn't open that conversation. The file may be damaged.")
    }

    // MARK: Deletion

    func testDeleteAndUndoANonCurrentConversation() async throws {
        let harness = try makeHarness(responses: [reply("A."), reply("B.")], undoWindow: .seconds(30))
        let history = harness.history
        await harness.sendAndFinish("conversation a")
        let aID = harness.chat.conversationID
        history.startNewConversation()
        history.dismissContinuation()
        await harness.sendAndFinish("conversation b")

        history.delete(aID)
        XCTAssertEqual(history.pendingDeletion?.id, aID)
        XCTAssertFalse(history.summaries.contains { $0.id == aID })
        history.undoDelete()
        XCTAssertNil(history.pendingDeletion)
        XCTAssertTrue(history.summaries.contains { $0.id == aID })
        XCTAssertTrue(harness.removals.removals.isEmpty)

        history.delete(aID)
        history.commitPendingDeletion()
        await waitUntil { harness.removals.removals == [.conversations([aID])] }
        let index = await harness.store.loadIndex()
        XCTAssertEqual(index.map(\.id), [harness.chat.conversationID])
    }

    func testDeletingTheCurrentConversationEmptiesTheChatAndUndoBringsItBack() async throws {
        let harness = try makeHarness(responses: [reply("Current.")])
        let chat = harness.chat
        let history = harness.history
        await harness.sendAndFinish("current chat")
        let id = chat.conversationID
        let messages = chat.messages

        history.delete(id)
        XCTAssertEqual(chat.messageCount, 0)
        XCTAssertNotEqual(chat.conversationID, id)
        history.undoDelete()
        XCTAssertEqual(chat.conversationID, id)
        XCTAssertEqual(chat.messages, messages)

        history.delete(id)
        await waitUntil { history.pendingDeletion == nil }
        await waitUntil { harness.removals.removals == [.conversations([id])] }
        XCTAssertTrue(history.summaries.isEmpty)
        let index = await harness.store.loadIndex()
        XCTAssertTrue(index.isEmpty, "committed after the Undo window")
    }

    func testDeleteAllEmptiesEverythingWithoutSavingTheChat() async throws {
        let harness = try makeHarness(responses: [reply("One."), reply("Two.")])
        let chat = harness.chat
        let history = harness.history
        await harness.sendAndFinish("one")
        history.startNewConversation()
        await harness.sendAndFinish("two")

        await history.deleteAll()
        XCTAssertEqual(chat.messageCount, 0)
        XCTAssertTrue(history.summaries.isEmpty)
        XCTAssertNil(history.continuation)
        XCTAssertEqual(harness.removals.removals, [.all])
        let index = await harness.store.loadIndex()
        XCTAssertTrue(index.isEmpty)
        XCTAssertEqual(history.storageUsage?.conversationCount, 0)
    }

    func testTurningHistoryOffWipesButKeepsTheChatAndTurningItOnSavesAgain() async throws {
        let harness = try makeHarness(responses: [reply("Kept on screen.")])
        let chat = harness.chat
        let history = harness.history
        await harness.sendAndFinish("keep me")
        let id = chat.conversationID

        await history.setEnabled(false)
        XCTAssertFalse(harness.settings.history.enabled)
        XCTAssertEqual(chat.conversationID, id)
        XCTAssertEqual(chat.messageCount, 2)
        XCTAssertTrue(history.summaries.isEmpty)
        XCTAssertEqual(harness.removals.removals, [.all])
        let wiped = await harness.store.loadIndex()
        XCTAssertTrue(wiped.isEmpty)

        await history.setEnabled(true)
        XCTAssertTrue(harness.settings.history.enabled)
        await harness.settleSaves()
        let saved = await harness.store.loadIndex()
        XCTAssertEqual(saved.map(\.id), [id])
    }

    // MARK: Retention

    func testRetentionPrunesOldConversationsAndReportsThem() async throws {
        let harness = try makeHarness(responses: [reply("Old."), reply("New.")])
        let history = harness.history
        await harness.sendAndFinish("old chat")
        let oldID = harness.chat.conversationID
        history.startNewConversation()
        history.dismissContinuation()

        harness.clock.advance(minutes: 40 * 24 * 60)
        await harness.sendAndFinish("new chat")
        XCTAssertEqual(history.countConversations(olderThan: .month), 1)
        XCTAssertEqual(history.countConversations(olderThan: .forever), 0)

        await history.applyRetention()
        XCTAssertEqual(harness.removals.removals, [.conversations([oldID])])
        XCTAssertEqual(history.summaries.map(\.id), [harness.chat.conversationID])
        let index = await harness.store.loadIndex()
        XCTAssertEqual(index.count, 1)
    }

    // MARK: Launch

    private func seededStore(updatedMinutesAgo minutes: Double, clock: Date) async throws -> (ConversationStore, UUID) {
        let store = ConversationStore(location: .inMemory)
        let id = UUID()
        let reply = ChatMessage(role: .assistant, text: "Earlier answer", apiContent: [textBlock("Earlier answer")],
                                model: "claude-opus-5", createdAt: clock)
        let position = ReadingPosition(anchorMessageID: reply.id, fractionScrolledPast: 0.4, isAtBottom: false,
                                       lastMessageID: reply.id, savedAt: clock)
        let snapshot = ConversationSnapshot(
            id: id, createdAt: clock, updatedAt: clock.addingTimeInterval(-minutes * 60), title: "Earlier",
            messages: [ChatMessage(role: .user, text: "Earlier question", apiContent: [textBlock("Earlier question")], createdAt: clock), reply],
            thumbnails: [:], unavailableAttachmentIDs: [], readingPosition: position)
        _ = try await store.save(snapshot)
        return (store, id)
    }

    func testLaunchRestoresARecentConversation() async throws {
        let now = HistoryTestClock().now
        let (store, id) = try await seededStore(updatedMinutesAgo: 5, clock: now)
        let harness = try makeHarness(responses: [], store: store)
        XCTAssertFalse(harness.history.isIndexLoaded)

        await harness.history.start()
        XCTAssertTrue(harness.history.isIndexLoaded)
        XCTAssertEqual(harness.chat.conversationID, id)
        XCTAssertEqual(harness.chat.messages.map(\.text), ["Earlier question", "Earlier answer"])
        XCTAssertNil(harness.history.continuation)
        XCTAssertEqual(harness.history.lastActivity, now.addingTimeInterval(-300))
        XCTAssertNotNil(harness.history.takeReadingPositionToRestore())

        await harness.history.start()
        XCTAssertEqual(harness.history.summaries.count, 1, "start is idempotent")
    }

    func testLaunchOffersAnOlderConversationAsContinuation() async throws {
        let now = HistoryTestClock().now
        let (store, id) = try await seededStore(updatedMinutesAgo: 30, clock: now)
        let harness = try makeHarness(responses: [], store: store)
        await harness.history.start()
        XCTAssertEqual(harness.chat.messageCount, 0)
        XCTAssertEqual(harness.history.continuation?.id, id)

        let never = try await seededStore(updatedMinutesAgo: 600, clock: now)
        let restoring = try makeHarness(responses: [], store: never.0) { $0.history.idleReset = .never }
        await restoring.history.start()
        XCTAssertEqual(restoring.chat.conversationID, never.1, "Never restores whatever came last")
    }

    // MARK: Reading position

    func testReadingPositionIsPersistedOnCloseAndRestoredOnOpen() async throws {
        let harness = try makeHarness(responses: [reply("Long answer.")])
        let chat = harness.chat
        let history = harness.history
        await harness.sendAndFinish("long question")
        let id = chat.conversationID
        let anchor = try XCTUnwrap(chat.messages.last?.id)
        let position = ReadingPosition(anchorMessageID: anchor, fractionScrolledPast: 0.5, isAtBottom: false,
                                       lastMessageID: anchor, savedAt: harness.clock.now)

        history.noteReadingPosition(position)
        XCTAssertEqual(history.currentReadingPosition, position)
        history.noteActivity()   // engaged close
        let persisted = try await harness.stored(id)
        XCTAssertEqual(persisted.readingPosition, position, "saved by the close")

        history.startNewConversation()
        history.dismissContinuation()
        XCTAssertNil(history.currentReadingPosition)
        let opened = await history.open(id)
        XCTAssertTrue(opened)
        XCTAssertEqual(history.takeReadingPositionToRestore(), position)
        XCTAssertNil(history.takeReadingPositionToRestore(), "one-shot")
        XCTAssertEqual(history.currentReadingPosition, position)
    }

    // MARK: Recents

    func testRecentsSelectsTheContinuationAndSearches() async throws {
        let harness = try makeHarness(responses: [reply("Actors."), reply("Soup.")])
        let history = harness.history
        let recents = RecentsState(history: history)
        await harness.sendAndFinish("swift actor reentrancy")
        let actorID = harness.chat.conversationID
        history.startNewConversation()
        history.dismissContinuation()
        harness.clock.advance(minutes: 1)
        await harness.sendAndFinish("tomato soup recipe")
        let soupID = harness.chat.conversationID
        history.startNewConversation()

        recents.activate(preferred: history.continuation?.id)
        XCTAssertEqual(recents.rows.map(\.id), [soupID, actorID])
        XCTAssertEqual(recents.selectedID, soupID)
        XCTAssertEqual(recents.sections.map(\.id), ["today"])
        XCTAssertEqual(recents.searchFocusRequest, 1)

        recents.moveSelection(by: 1)
        XCTAssertEqual(recents.selectedID, actorID)
        recents.moveSelection(by: 5)
        XCTAssertEqual(recents.selectedID, actorID, "no wrap")
        recents.moveSelection(by: -9)
        XCTAssertEqual(recents.selectedRow?.id, soupID)

        recents.query = "actor"
        XCTAssertTrue(recents.isSearching)
        await waitUntil { !recents.isSearching }
        XCTAssertEqual(recents.rows.map(\.id), [actorID])
        XCTAssertEqual(recents.selectedID, actorID)
        XCTAssertTrue(recents.sections.isEmpty)

        recents.query = ""
        XCTAssertEqual(recents.rows.count, 2)
        history.delete(actorID)
        XCTAssertEqual(recents.rows.map(\.id), [soupID], "refreshes when summaries change")
        XCTAssertEqual(recents.selectedID, soupID)
        history.undoDelete()
        XCTAssertEqual(recents.rows.count, 2)
        recents.deactivate()
    }

    func testDebugSeedShowsRowsWithoutTouchingTheStore() async throws {
        let harness = try makeHarness(responses: [])
        let now = harness.clock.now
        let seeded = (0..<3).map { index in
            ConversationSummary(id: UUID(), title: "Seed \(index)", preview: "", searchText: "", createdAt: now,
                                updatedAt: now.addingTimeInterval(Double(-index * 60)), messageCount: 2, attachmentCount: 0,
                                model: nil, blobs: [:], fileBytes: 0, fileModifiedAt: now)
        }
        harness.history.debugSeed(summaries: seeded.reversed(), continuation: seeded[1])
        XCTAssertEqual(harness.history.summaries.map(\.title), ["Seed 0", "Seed 1", "Seed 2"])
        XCTAssertEqual(harness.history.continuation?.title, "Seed 1")
        XCTAssertFalse(harness.history.isIndexLoaded)
        let index = await harness.store.loadIndex()
        XCTAssertTrue(index.isEmpty)
    }
}
