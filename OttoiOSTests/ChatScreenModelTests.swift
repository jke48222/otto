//
//  ChatScreenModelTests.swift
//  OttoiOSTests
//
//  The iPhone chat screen's behavior on an inert graph: sending, editing, intents and links, attachments,
//  coming back to a reply that finished away, voice consent, and spoken replies.
//

import XCTest
@testable import Otto

@MainActor
final class ChatScreenModelTests: XCTestCase {
    // MARK: - Sending

    func testSendClearsTheComposerAndTheReplyArrives() async {
        let graph = makeGraph()
        let model = graph.model
        model.composerText = "What's a good name for a cat?"
        XCTAssertTrue(model.canSend)

        model.send()

        XCTAssertEqual(model.composerText, "")
        XCTAssertEqual(graph.chat.messages.first?.text, "What's a good name for a cat?")
        XCTAssertEqual(model.sendSerial, 1)
        XCTAssertEqual(model.scrollRequest?.target, .bottom)
        await waitUntil { !graph.chat.isStreaming }
        XCTAssertEqual(graph.chat.messages.last?.role, .assistant)
        XCTAssertEqual(graph.chat.messages.last?.state, .complete)
        XCTAssertEqual(model.replySerial, 1, "A reply that lands on screen taps once")
        XCTAssertNil(model.unreadReplyID)
    }

    func testNothingToSendKeepsSendOff() {
        let graph = makeGraph()
        graph.model.composerText = "   \n"
        XCTAssertFalse(graph.model.canSend)
        graph.model.send()
        XCTAssertTrue(graph.chat.messages.isEmpty)
    }

    func testStopEndsTheReply() async {
        let graph = makeGraph(latencyScale: 1)
        graph.model.composerText = "Tell me a long story"
        graph.model.send()
        XCTAssertTrue(graph.chat.isStreaming)
        graph.model.stop()
        XCTAssertFalse(graph.chat.isStreaming)
        XCTAssertEqual(graph.chat.messages.last?.state, .cancelled)
    }

    func testNewChatEmptiesTheChatAndFocusesTheComposer() async {
        let graph = makeGraph()
        await ask("First", in: graph)
        graph.model.composerText = "draft"

        graph.model.newChat()

        XCTAssertTrue(graph.chat.messages.isEmpty)
        XCTAssertEqual(graph.model.composerText, "")
        XCTAssertEqual(graph.model.focusRequest, 1)
    }

    // MARK: - Editing the last question

    func testEditingTheLastQuestionKeepsTheDraftForCancel() async {
        let graph = makeGraph()
        let model = graph.model
        await ask("First question", in: graph)
        model.composerText = "A draft"

        model.editLastQuestion()
        XCTAssertTrue(model.isEditing)
        XCTAssertEqual(model.composerText, "First question")

        model.cancelEditing()
        XCTAssertFalse(model.isEditing)
        XCTAssertEqual(model.composerText, "A draft")
    }

    func testSendingAnEditReplacesTheQuestionAndItsReply() async {
        let graph = makeGraph()
        let model = graph.model
        await ask("First question", in: graph)

        model.editLastQuestion()
        model.composerText = "Better question"
        model.send()
        await waitUntil { !graph.chat.isStreaming }

        XCTAssertEqual(graph.chat.messages.filter { $0.role == .user }.map(\.text), ["Better question"])
        XCTAssertEqual(graph.chat.messages.count, 2)
        XCTAssertFalse(model.isEditing)
    }

    // MARK: - Copy

    func testCopyLastReplyWithoutAReplySaysSo() {
        let graph = makeGraph()
        graph.model.copyLastReply()
        XCTAssertEqual(graph.model.notice?.text, ChatScreenModel.nothingToCopyNotice)
        XCTAssertEqual(graph.model.notice?.isError, true)
    }

    func testCopyingAReplyConfirms() async {
        let graph = makeGraph()
        await ask("Question", in: graph)
        graph.model.copyLastReply()
        XCTAssertEqual(graph.model.notice?.text, ChatScreenModel.copiedNotice)
        XCTAssertEqual(graph.model.notice?.isError, false)
    }

    // MARK: - Intents and links

    func testAskIntentSendsWhenTheComposerIsEmpty() async {
        let graph = makeGraph()
        graph.model.sheet = .recents

        graph.model.handle(OttoIntentRouter.Request.ask(question: "Hello there"))

        XCTAssertNil(graph.model.sheet)
        XCTAssertEqual(graph.chat.messages.first?.text, "Hello there")
        await waitUntil { !graph.chat.isStreaming }
    }

    func testAskIntentAddsToADraftInsteadOfSending() {
        let graph = makeGraph()
        graph.model.composerText = "Draft"

        graph.model.handle(OttoIntentRouter.Request.ask(question: "and more"))

        XCTAssertEqual(graph.model.composerText, "Draft and more")
        XCTAssertTrue(graph.chat.messages.isEmpty)
        XCTAssertEqual(graph.model.focusRequest, 1)
    }

    func testAskIntentWaitsWhileAReplyRuns() async {
        let graph = makeGraph(latencyScale: 1)
        graph.model.composerText = "First"
        graph.model.send()
        XCTAssertTrue(graph.chat.isStreaming)

        graph.model.handle(OttoIntentRouter.Request.ask(question: "Second"))

        XCTAssertEqual(graph.model.composerText, "Second")
        XCTAssertEqual(graph.chat.messages.filter { $0.role == .user }.count, 1)
        graph.model.stop()
    }

    func testAskIntentWithoutAQuestionFocusesTheComposer() {
        let graph = makeGraph()
        graph.model.handle(OttoIntentRouter.Request.ask(question: nil))
        XCTAssertEqual(graph.model.focusRequest, 1)
        XCTAssertTrue(graph.chat.messages.isEmpty)
    }

    func testLinks() async {
        let graph = makeGraph()
        await ask("Question", in: graph)
        let replyID = graph.chat.messages.last!.id

        graph.model.sheet = .settings
        graph.model.handle(OttoDeepLink.reply(replyID))
        XCTAssertNil(graph.model.sheet)
        XCTAssertEqual(graph.model.scrollRequest?.target, .message(replyID))

        graph.model.handle(OttoDeepLink.ask)
        XCTAssertEqual(graph.model.focusRequest, 1)

        graph.model.handle(OttoDeepLink.newChat)
        XCTAssertTrue(graph.chat.messages.isEmpty)
    }

    func testTheRouterHoldsRequestsUntilTheAppIsReady() {
        let router = OttoIntentRouter()
        var received: [OttoIntentRouter.Request] = []
        router.submit(.newChat)
        router.submit(.ask(question: "Hi"))
        XCTAssertTrue(received.isEmpty)

        router.handler = { received.append($0) }
        XCTAssertEqual(received, [.newChat, .ask(question: "Hi")])

        router.submit(.ask(question: nil))
        XCTAssertEqual(received.last, .ask(question: nil))
    }

    // MARK: - Attachments

    func testPhotosBecomeChipsInOrder() async {
        let graph = makeGraph()
        let model = graph.model
        model.addImages([
            (data: Fixtures.pngData(), typeIdentifier: "public.png", name: "Photo 1.png"),
            (data: Fixtures.pngData(size: CGSize(width: 32, height: 32)), typeIdentifier: "public.png", name: "Photo 2.png"),
        ])
        XCTAssertEqual(model.pendingAttachmentLoads, 2)
        XCTAssertFalse(model.canSend, "Send waits for the chips")

        await waitUntil { model.pendingAttachmentLoads == 0 }

        XCTAssertEqual(model.attachments.map(\.displayName), ["Photo 1.png", "Photo 2.png"])
        XCTAssertEqual(model.attachments.first?.kind, .image)
        XCTAssertNotNil(model.attachments.first?.thumbnail)
        XCTAssertTrue(model.canSend)

        model.removeAttachment(id: model.attachments[0].id)
        XCTAssertEqual(model.attachments.map(\.displayName), ["Photo 2.png"])
    }

    func testUnreadablePhotosSayWhy() async {
        let graph = makeGraph()
        graph.model.addImages([(data: Data("not an image".utf8), typeIdentifier: nil, name: "Broken.png")])
        await waitUntil { graph.model.pendingAttachmentLoads == 0 }
        XCTAssertTrue(graph.model.attachments.isEmpty)
        XCTAssertEqual(graph.model.notice?.isError, true)
    }

    func testAttachmentsStopAtTheLimit() async {
        let graph = makeGraph()
        let images = (1...(ChatScreenModel.maxAttachments + 2)).map { index in
            (data: Fixtures.pngData(), typeIdentifier: Optional("public.png"), name: "Photo \(index).png")
        }
        graph.model.addImages(images)
        XCTAssertEqual(graph.model.notice?.text, ChatScreenModel.attachmentLimitMessage)
        await waitUntil { graph.model.pendingAttachmentLoads == 0 }
        XCTAssertEqual(graph.model.attachments.count, ChatScreenModel.maxAttachments)
        XCTAssertEqual(graph.model.remainingAttachmentCapacity, 0)
    }

    func testPastedShortTextGoesIntoTheComposer() async {
        let graph = makeGraph()
        graph.model.composerText = "Look at"
        graph.model.addDropped([NSItemProvider(object: "this sentence" as NSString)])
        await waitUntil { graph.model.pendingAttachmentLoads == 0 }
        XCTAssertEqual(graph.model.composerText, "Look at this sentence")
        XCTAssertTrue(graph.model.attachments.isEmpty)
    }

    func testAnEmptyClipboardSaysSo() {
        let graph = makeGraph()
        graph.model.pasteFromClipboard()
        XCTAssertEqual(graph.model.notice?.isError, true)
        XCTAssertEqual(graph.model.pendingAttachmentLoads, 0)
    }

    // MARK: - Leaving and coming back

    func testAReplyThatFinishesAwayIsShownOnReturn() async {
        let graph = makeGraph(latencyScale: 0.05)
        let model = graph.model
        model.composerText = "Question"
        model.send()
        graph.sceneEnteredBackground()
        XCTAssertFalse(model.isAppActive)
        XCTAssertTrue(graph.backgroundKeeper.isHolding, "A running reply keeps going on background time")

        await waitUntil { !graph.chat.isStreaming }
        let replyID = graph.chat.messages.last?.id
        XCTAssertEqual(model.unreadReplyID, replyID)
        XCTAssertEqual(model.replySerial, 0, "No tap for a reply that landed off screen")
        XCTAssertFalse(graph.backgroundKeeper.isHolding, "Background time goes back once the reply settles")

        graph.sceneBecameActive()
        XCTAssertNil(model.unreadReplyID)
        XCTAssertEqual(model.scrollRequest?.target, replyID.map { ChatScreenModel.ScrollRequest.Target.message($0) })
    }

    func testRunningOutOfBackgroundTimeStopsTheReplyWhereItIs() async throws {
        let graph = makeGraph(latencyScale: 1)
        let time = try XCTUnwrap(graph.backgroundTime as? InertBackgroundTime)
        graph.model.composerText = "Question"
        graph.model.send()
        graph.sceneEnteredBackground()
        XCTAssertTrue(graph.chat.isStreaming)

        time.expire()

        XCTAssertFalse(graph.chat.isStreaming)
        XCTAssertEqual(graph.chat.messages.last?.state, .cancelled)
        XCTAssertFalse(graph.backgroundKeeper.isHolding)
    }

    func testANotificationWhenAwayWithoutALiveActivity() async throws {
        let graph = makeGraph()
        let center = try XCTUnwrap(graph.notificationCenter as? InertReplyNotificationCenter)
        graph.settings.mobile.notifyWhenAway = true
        graph.model.composerText = "Question"
        graph.model.send()
        graph.sceneEnteredBackground()
        await waitUntil { !graph.chat.isStreaming }

        XCTAssertEqual(center.posted.count, 1)
        XCTAssertEqual(center.posted.first?.messageID, graph.chat.messages.last?.id)
        XCTAssertFalse(center.posted.first?.body.isEmpty ?? true)
    }

    func testNoNotificationWhileOnScreen() async throws {
        let graph = makeGraph()
        let center = try XCTUnwrap(graph.notificationCenter as? InertReplyNotificationCenter)
        graph.settings.mobile.notifyWhenAway = true
        await ask("Question", in: graph)
        XCTAssertTrue(center.posted.isEmpty)
    }

    func testTappingTheNotificationShowsTheReply() async {
        let graph = makeGraph()
        await ask("Question", in: graph)
        let replyID = graph.chat.messages.last!.id
        graph.model.sheet = .recents

        graph.notifier.onOpenReply?(replyID)

        XCTAssertNil(graph.model.sheet)
        XCTAssertEqual(graph.model.scrollRequest?.target, .message(replyID))
    }

    // MARK: - Voice

    func testTheMicAsksBeforeItsFirstUse() {
        let graph = makeGraph()
        XCTAssertFalse(graph.settings.voice.enabled)
        XCTAssertEqual(graph.model.micState, .off)

        graph.model.beginVoice(.hold(.micButton))
        XCTAssertEqual(graph.model.voiceConsent, ChatScreenModel.VoiceConsent(pendingMode: .toggle(.micButton)))

        graph.model.declineVoiceConsent()
        XCTAssertNil(graph.model.voiceConsent)
        XCTAssertFalse(graph.settings.voice.enabled)
    }

    func testTurningVoiceOnFromTheQuestion() {
        let graph = makeGraph()
        graph.model.beginVoice(.toggle(.micButton))
        graph.model.acceptVoiceConsent()
        XCTAssertTrue(graph.settings.voice.enabled)
        XCTAssertNil(graph.model.voiceConsent)
        graph.model.cancelVoice()
    }

    func testTheMicIsReadyOnceVoiceIsOn() {
        let graph = makeGraph()
        graph.settings.voice.enabled = true
        XCTAssertEqual(graph.model.micState, .ready)
    }

    func testHeardWordsAreSentWhenAutoSendIsOn() async {
        let graph = makeGraph()
        graph.settings.voice.enabled = true
        graph.settings.voice.autoSend = true
        graph.voice.onFinished?("What's the weather like", true)
        XCTAssertEqual(graph.chat.messages.first?.text, "What's the weather like")
        await waitUntil { !graph.chat.isStreaming }
    }

    func testHeardWordsWaitInTheComposerWithoutAutoSend() {
        let graph = makeGraph()
        graph.settings.voice.autoSend = false
        graph.voice.onFinished?("Remind me later", true)
        XCTAssertEqual(graph.model.composerText, "Remind me later")
        XCTAssertTrue(graph.chat.messages.isEmpty)
        XCTAssertEqual(graph.model.focusRequest, 1)
    }

    func testHearingNothingSaysSo() {
        let graph = makeGraph()
        graph.voice.onFinished?("  ", true)
        XCTAssertEqual(graph.model.notice?.text, ChatScreenModel.heardNothingNotice)
    }
}
