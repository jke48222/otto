//
//  MobilePlatformTests.swift
//  OttoiOSTests
//
//  What the shared core says and does differently on iPhone: the system prompt, device names in copy, the
//  spoken code note, the transcript's follow logic and the preferences the iPhone adds.
//

import XCTest
@testable import Otto

@MainActor
final class MobilePlatformTests: XCTestCase {
    func testTheSystemPromptDescribesTheIPhone() {
        let prompt = SystemPrompt.make(customInstructions: "", actionsSection: SystemPrompt.actionsOffLine)
        XCTAssertTrue(prompt.contains("on the user's iPhone"))
        XCTAssertTrue(prompt.contains("phone screen"))
        XCTAssertFalse(prompt.contains("notch"))
        XCTAssertFalse(prompt.contains("Mac"))
        XCTAssertFalse(prompt.contains("Otto's Settings"), "There are no Actions to turn on in the iPhone app")
    }

    func testTheChatSendsTheIPhonePrompt() async {
        let graph = makeGraph()
        await ask("Hi", in: graph)
        XCTAssertNotNil(graph.chat.messages.last)
        let prompt = SystemPrompt.make(settings: graph.settings)
        XCTAssertTrue(prompt.contains("iPhone"))
    }

    func testCopyNamesThisIPhone() {
        XCTAssertEqual(OttoDevice.name, "iPhone")
        XCTAssertTrue(HistoryRecentsText.historyOffBody.hasSuffix("on this iPhone."))
        XCTAssertTrue(HistoryRecentsText.noticeBody(retention: .month).hasPrefix("Conversations are saved on this iPhone only"))
        XCTAssertEqual(ConversationCodec.unavailablePayloadText(for: "notes.pdf"),
                       "[notes.pdf is no longer stored on this iPhone.]")
        XCTAssertEqual(HistoryStoreError.notFound.errorDescription, "the conversation is no longer on this iPhone")
    }

    func testCodeIsAnnouncedOnScreen() {
        var chunker = SpeechChunker()
        let sentences = chunker.consume("Try this:\n```swift\nprint(1)\n```\nDone.", isFinal: true)
        XCTAssertEqual(sentences, ["Try this:", "I've put the code on screen.", "Done."])
    }

    func testVoiceNoticesNameTheIPhone() {
        XCTAssertTrue(VoiceController.Notice.asleep.contains("iPhone"))
    }

    // MARK: - Transcript follow logic

    func testDistanceFromBottom() {
        // Content taller than the view, scrolled to the very bottom.
        let atBottom = ScrollMetrics(offset: 500, contentHeight: 1_400, containerHeight: 900, bottomInset: 100)
        XCTAssertEqual(atBottom.distanceFromBottom, 0)

        let scrolledUp = ScrollMetrics(offset: 100, contentHeight: 1_400, containerHeight: 900, bottomInset: 100)
        XCTAssertEqual(scrolledUp.distanceFromBottom, 400)

        // Content that fits is always at the bottom, whatever the composer's inset.
        let short = ScrollMetrics(offset: 0, contentHeight: 540, containerHeight: 625, bottomInset: 216)
        XCTAssertEqual(short.distanceFromBottom, 0)

        // Overscroll past the end is still the bottom.
        let bounced = ScrollMetrics(offset: 560, contentHeight: 1_400, containerHeight: 900, bottomInset: 100)
        XCTAssertEqual(bounced.distanceFromBottom, 0)
    }

    func testVersionPagerShowsOnlyForTheRegeneratedTurn() {
        let userID = UUID()
        let reply = ChatMessage(role: .assistant, text: "Second")
        let versions = ChatSession.ReplyVersions(userMessageID: userID,
                                                 replies: [ChatMessage(role: .assistant, text: "First"), reply],
                                                 currentIndex: 1)
        XCTAssertEqual(ConversationList.versionInfo(of: reply, versions: versions, lastUserID: userID)?.label, "2/2")
        XCTAssertNil(ConversationList.versionInfo(of: reply, versions: versions, lastUserID: UUID()))
        XCTAssertNil(ConversationList.versionInfo(of: reply, versions: nil, lastUserID: userID))
    }

    // MARK: - Preferences

    func testMobileDefaults() {
        let graph = makeGraph()
        let mobile = graph.settings.mobile
        XCTAssertTrue(mobile.liveActivities)
        XCTAssertFalse(mobile.notifyWhenAway)
        XCTAssertTrue(mobile.notificationPreview)
        XCTAssertTrue(mobile.haptics)
        XCTAssertFalse(mobile.demoMode)
        XCTAssertFalse(mobile.didFinishOnboarding)
    }

    func testMobilePreferencesPersist() throws {
        let suiteName = "otto.ios-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let first = AppSettings(defaults: defaults, usesKeychain: false)
        first.mobile.notifyWhenAway = true
        first.mobile.haptics = false
        first.mobile.didFinishOnboarding = true

        let second = AppSettings(defaults: defaults, usesKeychain: false)
        XCTAssertTrue(second.mobile.notifyWhenAway)
        XCTAssertFalse(second.mobile.haptics)
        XCTAssertTrue(second.mobile.didFinishOnboarding)
    }

    func testTheAPIKeyMask() {
        XCTAssertEqual(APIKeyPage.masked("sk-ant-api03-abcdefghijklmnop1234"), "sk-ant-…1234")
        XCTAssertEqual(APIKeyPage.masked("short"), "••••")
    }

    func testModelSubtitlesCarryPrices() {
        XCTAssertTrue(ModelPickerPage.subtitle(for: .opus5).contains("per million tokens"))
        XCTAssertEqual(ModelPickerPage.perMillion(5_000), "$5")
        XCTAssertEqual(ModelPickerPage.perMillion(2_500), "$2.50")
    }
}
