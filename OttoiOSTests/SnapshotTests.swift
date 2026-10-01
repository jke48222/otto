//
//  SnapshotTests.swift
//  OttoiOSTests
//
//  Draws the iPhone screens with seeded content, full screen in a window of their own, and writes them as PNGs
//  to $OTTO_SNAPSHOT_DIR when it is set (CI uploads them as the ios-snapshots artifact). Without it the screens
//  are still drawn, so a view that traps fails the test.
//

import SwiftUI
import UIKit
import XCTest
@testable import Otto

@MainActor
final class SnapshotTests: XCTestCase {
    // MARK: - Chat

    func testEmptyChat() async throws {
        let graph = makeSnapshotGraph()
        graph.history.debugSeed(summaries: Self.summaries, continuation: Self.summaries[0])
        try await Snapshot.render(RootView(composition: graph), named: "chat-empty")
    }

    func testEmptyChatWithoutAKey() async throws {
        let graph = makeSnapshotGraph(hasKey: false)
        try await Snapshot.render(RootView(composition: graph), named: "chat-needs-key")
    }

    func testConversation() async throws {
        let graph = makeSnapshotGraph()
        graph.chat.debugSeed(messages: Self.conversation(streaming: false), isStreaming: false)
        try await Snapshot.render(RootView(composition: graph), named: "chat-conversation")
    }

    func testStreamingReply() async throws {
        let graph = makeSnapshotGraph()
        graph.chat.debugSeed(messages: Self.conversation(streaming: true), isStreaming: true)
        try await Snapshot.render(RootView(composition: graph), named: "chat-streaming")
    }

    func testComposerWithAttachments() async throws {
        let graph = makeSnapshotGraph()
        graph.chat.debugSeed(messages: Array(Self.conversation(streaming: false).prefix(2)), isStreaming: false)
        graph.model.debugSeed(
            composerText: "Compare these two and tell me which one fits a carry-on",
            attachments: [Fixtures.imageAttachment(name: "Backpack.png"),
                          Attachment(kind: .pdf, displayName: "Airline baggage rules.pdf", badge: "PDF",
                                     payload: .pdf(base64: ""), byteCount: 0)],
            pendingAttachmentLoads: 1,
            notice: ChatScreenModel.Notice(id: UUID(), text: "You can attach up to 10 items.", isError: true,
                                           offersSettings: false)
        )
        try await Snapshot.render(RootView(composition: graph), named: "chat-composer")
    }

    func testListening() async throws {
        let graph = makeSnapshotGraph()
        graph.settings.voice.enabled = true
        graph.chat.debugSeed(messages: Array(Self.conversation(streaming: false).prefix(2)), isStreaming: false)
        graph.voice.debugSeed(phase: .listening, finalized: "What's the tallest mountain", volatile: "in Portugal",
                              levels: (0..<28).map { Float(0.2 + 0.6 * abs(sin(Double($0) * 0.55))) })
        try await Snapshot.render(RootView(composition: graph), named: "chat-listening")
    }

    func testFailedReply() async throws {
        let graph = makeSnapshotGraph()
        graph.chat.debugSeed(messages: [
            ChatMessage(role: .user, text: "Summarize today's news about the eclipse"),
            ChatMessage(role: .assistant, state: .failed(LLMError.invalidAPIKey.errorDescription ?? "")),
        ], isStreaming: false)
        try await Snapshot.render(RootView(composition: graph), named: "chat-failed")
    }

    // MARK: - Sheets and first run

    func testRecents() async throws {
        let graph = makeSnapshotGraph()
        graph.settings.history.noticeAcknowledged = true
        graph.history.debugSeed(summaries: Self.summaries, continuation: nil)
        graph.model.showRecents()
        try await Snapshot.render(RecentsScreen(model: graph.model), named: "recents")
    }

    func testSettings() async throws {
        let graph = makeSnapshotGraph()
        try await Snapshot.render(SettingsScreen(model: graph.model), named: "settings")
    }

    func testOnboarding() async throws {
        let graph = makeSnapshotGraph(hasKey: false)
        try await Snapshot.render(OnboardingView(settings: graph.settings) {}, named: "onboarding")
    }

    // MARK: - Live Activity

    func testLiveActivity() async throws {
        let started = Date().addingTimeInterval(-14)
        let working = ReplyActivityAttributes.ContentState(stage: .searching, detail: "Searching “Lisbon weather October”",
                                                           model: "Opus 5", startedAt: started, finishedAt: nil)
        let replied = ReplyActivityAttributes.ContentState(
            stage: .replied, detail: "Pack light layers: days reach 22 °C, evenings drop to 15 °C, and rain is likely.",
            model: "Opus 5", startedAt: started, finishedAt: Date()
        )
        try await Snapshot.render(LiveActivityPreview(working: working, replied: replied), named: "live-activity")
    }

    // MARK: - Fixtures

    private func makeSnapshotGraph(hasKey: Bool = true) -> MobileComposition {
        let graph = makeGraph(isDemo: false)
        if hasKey {
            graph.settings.apiKey = "sk-ant-snapshot-0000000000000000"
        }
        graph.settings.mobile.didFinishOnboarding = true
        return graph
    }

    static func conversation(streaming: Bool) -> [ChatMessage] {
        let start = Date().addingTimeInterval(-600)
        var messages = [
            ChatMessage(role: .user, text: "What should I pack for a long weekend in Lisbon in October?",
                        attachments: [Fixtures.imageAttachment(name: "Itinerary.png")], createdAt: start),
            ChatMessage(
                role: .assistant,
                text: """
                    October in Lisbon is **mild with a chance of rain**: days around 22 °C, evenings near 15 °C.

                    - A light rain jacket or packable umbrella
                    - Layers: a sweater or overshirt for the evenings
                    - **Comfortable shoes with grip**, since the calçada stones get slippery
                    - Sunglasses and sunscreen for the afternoons

                    If you're heading to Sintra, bring one warmer layer; it runs a few degrees cooler.
                    """,
                thinking: "The user wants packing advice for Lisbon in October. Check typical weather first.",
                activities: [
                    ToolActivity(id: "srvtoolu_1", kind: .webSearch, label: "Searching “Lisbon weather October”",
                                 isDone: true),
                    ToolActivity(id: "srvtoolu_2", kind: .webFetch, label: "Reading visitlisboa.com", isDone: true),
                ],
                sources: [
                    SourceLink(title: "Lisbon in October", url: URL(string: "https://www.visitlisboa.com/en")!),
                    SourceLink(title: "Climate", url: URL(string: "https://weatherspark.com/lisbon")!),
                ],
                model: "claude-opus-5",
                createdAt: start.addingTimeInterval(20)
            ),
            ChatMessage(role: .user, text: "Turn that into a checklist I can tick off.",
                        createdAt: start.addingTimeInterval(120)),
        ]
        if streaming {
            messages.append(ChatMessage(role: .assistant, text: "Here's your checklist:\n\n- [ ] Rain jacket\n- [ ] Layers",
                                        state: .streaming, model: "claude-opus-5",
                                        createdAt: start.addingTimeInterval(125)))
        } else {
            messages.append(ChatMessage(
                role: .assistant,
                text: """
                    Here's your checklist:

                    - [ ] Rain jacket or umbrella
                    - [ ] Sweater for the evenings
                    - [ ] Shoes with grip
                    - [ ] Sunglasses and sunscreen
                    """,
                model: "claude-opus-5",
                createdAt: start.addingTimeInterval(125)
            ))
        }
        return messages
    }

    static var summaries: [ConversationSummary] {
        let now = Date()
        func summary(_ title: String, _ preview: String, hoursAgo: Double, attachments: Int = 0) -> ConversationSummary {
            let date = now.addingTimeInterval(-hoursAgo * 3_600)
            return ConversationSummary(id: UUID(), title: title, preview: preview, searchText: title + " " + preview,
                                       createdAt: date, updatedAt: date, messageCount: 4, attachmentCount: attachments,
                                       model: "claude-opus-5", blobs: [:], fileBytes: 2_048, fileModifiedAt: date)
        }
        return [
            summary("Packing for Lisbon", "Here's your checklist: rain jacket, layers, shoes with grip…", hoursAgo: 0.5,
                    attachments: 1),
            summary("Sourdough starter rescue", "Feed it twice a day at room temperature for three days…", hoursAgo: 3),
            summary("Explain the Monty Hall problem", "Switching wins two times out of three, because…", hoursAgo: 27),
            summary("Birthday message for Sam", "Happy birthday, Sam! Another lap around the sun…", hoursAgo: 80),
            summary("SwiftUI scroll position", "Use ScrollPosition with scrollTo(edge: .bottom)…", hoursAgo: 200),
            summary("Tide times in Cascais", "Low tide is at 4:12 PM; the next high tide…", hoursAgo: 600),
        ]
    }
}

// MARK: - Rendering

@MainActor
enum Snapshot {
    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["OTTO_SNAPSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Renders `view` full screen in its own window, above the test host's, and writes `<name>.png` when
    /// OTTO_SNAPSHOT_DIR is set.
    @discardableResult
    static func render<V: View>(_ view: V, named name: String,
                                settle: Duration = .milliseconds(900)) async throws -> UIImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "The test host has no window scene")
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        let host = UIHostingController(rootView: view.preferredColorScheme(.dark))
        host.view.backgroundColor = UIColor(white: 0.024, alpha: 1)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: settle)

        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertGreaterThan(image.size.width, 0)
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try XCTUnwrap(image.pngData(), "No PNG for \(name)")
            try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        }
        return image
    }
}

/// How the reply's Live Activity looks: the Dynamic Island while Otto works (compact and expanded) and the Lock
/// Screen once it replied. The island's shape is drawn here; on a device the system draws it.
private struct LiveActivityPreview: View {
    let working: ReplyActivityAttributes.ContentState
    let replied: ReplyActivityAttributes.ContentState

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.3), Color(red: 0.05, green: 0.06, blue: 0.1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 28) {
                // Compact: the orb on the left of the camera, the glyph on the right.
                HStack(spacing: 0) {
                    OttoOrb(size: 15, isActive: false)
                    Spacer()
                    ReplyActivityGlyph(state: working)
                }
                .padding(.horizontal, 14)
                .frame(width: 250, height: 37)
                .background(Capsule().fill(Color.black))
                .padding(.top, 11)

                // Expanded.
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center) {
                        OttoOrb(size: 26, isActive: false)
                        Spacer()
                        Text(working.title)
                            .font(Theme.font(15, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        ReplyActivityClock(state: working)
                            .font(Theme.font(13, .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ReplyActivityDetail(state: working)
                        .font(Theme.font(14))
                        .lineLimit(2)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(width: 370)
                .background(RoundedRectangle(cornerRadius: 44, style: .continuous).fill(Color.black))

                Spacer().frame(height: 40)

                // Lock Screen.
                ReplyActivityBanner(state: replied)
                    .frame(width: 360)
                    .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.panel.opacity(0.92)))
            }
        }
        .environment(\.colorScheme, .dark)
    }
}
