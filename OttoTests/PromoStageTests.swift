//
//  PromoStageTests.swift
//  Otto
//
//  The promo stage's scripted client and pointer easing (the marketing footage depends on both).
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
        var events: [StreamEvent] = []
        for try await event in PromoLLMClient(timeScale: 0).stream(request(prompt: prompt)) {
            events.append(event)
        }
        return events
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

    func testPromptsMatchTheirConversation() {
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
