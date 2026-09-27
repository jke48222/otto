//
//  HistoryStoreTests.swift
//  Otto
//
//  ConversationStore and ConversationCodec on disk (a temporary folder) and in memory: round trips of
//  every message state, attachments, blobs, tool calls and reading positions; missing payloads; damaged,
//  newer-version and migrated files; index rebuilds; retention, garbage collection and Delete All; file
//  modes and folder names.
//

import AppKit
import XCTest
@testable import Otto

// MARK: - Fixtures

private let baseDate = Date(timeIntervalSince1970: 1_790_500_000)

/// Deterministic pseudo-random bytes (compress badly, so sizes stay meaningful).
private func bytes(_ count: Int, seed: UInt32) -> Data {
    var state = seed &* 2_654_435_761 | 1
    return Data((0..<count).map { _ in
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return UInt8(truncatingIfNeeded: state)
    })
}

private func textBlock(_ text: String) -> JSONValue {
    ["type": "text", "text": .string(text)]
}

private func pngData(width: Int = 4, height: Int = 4) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)
    return rep?.representation(using: .png, properties: [:]) ?? Data()
}

private func imageAttachment(_ name: String = "photo.png", seed: UInt32 = 1, size: Int = 30_000,
                             retains: Bool = true) -> Attachment {
    let base64 = bytes(size, seed: seed).base64EncodedString()
    return Attachment(kind: .image, displayName: name, badge: "PNG", sourceURL: URL(fileURLWithPath: "/tmp/\(name)"),
                      thumbnail: NSImage(data: pngData()), payload: .image(mediaType: "image/png", base64: base64),
                      byteCount: base64.utf8.count, retainsPayloadInHistory: retains)
}

private func userMessage(_ text: String, attachments: [Attachment] = []) -> ChatMessage {
    let content = attachments.flatMap { $0.contentBlocks() } + [textBlock(text)]
    return ChatMessage(role: .user, text: text, attachments: attachments, apiContent: content, createdAt: baseDate)
}

private func assistantMessage(_ text: String, state: MessageState = .complete, content: [JSONValue]? = nil) -> ChatMessage {
    ChatMessage(role: .assistant, text: text, apiContent: content ?? (text.isEmpty ? [] : [textBlock(text)]),
                state: state, model: "claude-opus-5", createdAt: baseDate)
}

private func makeSnapshot(
    id: UUID = UUID(),
    messages: [ChatMessage],
    updatedAt: Date = baseDate,
    title: String = "Test conversation",
    thumbnails: [UUID: Data] = [:],
    unavailable: Set<UUID> = [],
    readingPosition: ReadingPosition? = nil
) -> ConversationSnapshot {
    ConversationSnapshot(id: id, createdAt: baseDate, updatedAt: updatedAt, title: title, messages: messages,
                         thumbnails: thumbnails, unavailableAttachmentIDs: unavailable, readingPosition: readingPosition)
}

private func recordData(_ record: StoredConversation) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.dataEncodingStrategy = .base64
    return try encoder.encode(record)
}

private func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func files(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}

/// One store under test: on disk (`root` set) or in memory.
private struct StoreUnderTest {
    let store: ConversationStore
    let root: URL?
    var label: String { root == nil ? "in memory" : "on disk" }
    var conversations: URL? { root?.appendingPathComponent("Conversations.noindex", isDirectory: true) }
    var attachments: URL? { root?.appendingPathComponent("Attachments.noindex", isDirectory: true) }
}

// MARK: - Tests

final class HistoryStoreTests: XCTestCase {
    override func tearDown() {
        ConversationSchema.testSteps = [:]
        super.tearDown()
    }

    private func makeRoot() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("otto-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base.appendingPathComponent("Otto", isDirectory: true)
    }

    /// Runs `body` against a store in a temporary folder and against an in-memory store.
    private func forEachStore(policy: HistoryPolicy = .standard,
                              _ body: (StoreUnderTest) async throws -> Void) async throws {
        let root = try makeRoot()
        try await body(StoreUnderTest(store: ConversationStore(location: .directory(root), policy: policy), root: root))
        try await body(StoreUnderTest(store: ConversationStore(location: .inMemory, policy: policy), root: nil))
    }

    private func assertThrows(_ expected: HistoryStoreError, _ label: String,
                              _ work: () async throws -> Void, line: UInt = #line) async {
        do {
            try await work()
            XCTFail("Expected \(expected) (\(label))", line: line)
        } catch {
            XCTAssertEqual(error as? HistoryStoreError, expected, label, line: line)
        }
    }

    // MARK: Message states

    func testEveryMessageStateRoundTrips() async throws {
        try await forEachStore { env in
            let messages = [
                userMessage("one"), assistantMessage("Done"),
                userMessage("two"), assistantMessage("part", state: .cancelled),
                userMessage("three"), assistantMessage("", state: .refused("Otto can't help with that one.")),
                userMessage("four"), assistantMessage("", state: .failed("The response was interrupted.")),
                userMessage("five"), assistantMessage("partial", state: .streaming),
                userMessage("six"), assistantMessage("", state: .streaming),
            ]
            let snapshot = makeSnapshot(messages: messages)
            _ = try await env.store.save(snapshot)
            let loaded = try await env.store.load(id: snapshot.id)

            XCTAssertEqual(loaded.messages.count, 11, "empty interrupted reply is dropped (\(env.label))")
            XCTAssertEqual(loaded.messages.map(\.state), [
                .complete, .complete, .complete, .cancelled, .complete, .refused("Otto can't help with that one."),
                .complete, .failed("The response was interrupted."), .complete, .cancelled, .complete,
            ], env.label)
            XCTAssertEqual(loaded.messages[9].text, "partial")
            XCTAssertTrue(loaded.messages.allSatisfy { !$0.isThinking })
            XCTAssertEqual(Array(loaded.messages.prefix(4)), Array(messages.prefix(4)), env.label)
            XCTAssertEqual(loaded.title, "Test conversation")
            XCTAssertEqual(loaded.id, snapshot.id)
        }
    }

    // MARK: Attachments and blobs

    func testAttachmentsGoToBlobsOrInlineAndRoundTrip() async throws {
        try await forEachStore { env in
            let image = imageAttachment()
            let pdfBase64 = bytes(24_000, seed: 2).base64EncodedString()
            let pdf = Attachment(kind: .pdf, displayName: "paper.pdf", badge: "PDF", payload: .pdf(base64: pdfBase64),
                                 byteCount: pdfBase64.utf8.count)
            let longText = String(repeating: "lorem ipsum dolor ", count: 1_200)
            let big = Attachment(kind: .text, displayName: "notes.txt", badge: "TXT", payload: .text(longText),
                                 byteCount: longText.utf8.count)
            let small = Attachment(kind: .text, displayName: "todo.txt", badge: "TXT", payload: .text("milk"), byteCount: 4)
            let pageURL = URL(fileURLWithPath: "/")
            let page = Attachment(kind: .webPage, displayName: "Swift.org", badge: "WEB", sourceURL: pageURL,
                                  appBundleID: "com.apple.Safari", payload: .webPage(title: "Swift.org", url: pageURL), byteCount: 0)
            let user = userMessage("What are these?", attachments: [image, pdf, big, small, page])
            let snapshot = makeSnapshot(messages: [user, assistantMessage("Files.")], thumbnails: [image.id: pngData()])

            let summary = try await env.store.save(snapshot)
            XCTAssertEqual(summary.blobs.count, 3, "image, PDF and long text; each stored once (\(env.label))")
            XCTAssertEqual(summary.attachmentCount, 5)

            let loaded = try await env.store.load(id: snapshot.id)
            XCTAssertEqual(loaded.messages, snapshot.messages, env.label)
            XCTAssertTrue(loaded.unavailableAttachmentIDs.isEmpty)
            XCTAssertNotNil(loaded.messages[0].attachments[0].thumbnail, "thumbnail kept")
            XCTAssertNil(loaded.messages[0].attachments[1].thumbnail)

            let usage = await env.store.usage()
            XCTAssertEqual(usage.attachmentBytes, 30_000 + 24_000 + Int64(longText.utf8.count), env.label)

            if let attachments = env.attachments {
                let decoded = bytes(30_000, seed: 1)
                let sha = BlobExternalizer.sha256Hex(decoded)
                let blobURL = attachments.appendingPathComponent(String(sha.prefix(2))).appendingPathComponent(sha)
                XCTAssertEqual(try Data(contentsOf: blobURL), decoded, "base64 payloads are stored decoded")
                let allBlobs = files(in: attachments).flatMap { files(in: attachments.appendingPathComponent($0)) }
                XCTAssertEqual(allBlobs.count, 3)
                let file = try XCTUnwrap(env.conversations?.appendingPathComponent("\(snapshot.id.uuidString).json"))
                XCTAssertLessThan(try Data(contentsOf: file).count, 16 * 1024, "payloads live in blobs, not the file")
            }
        }
    }

    func testMarkersAtDepthRoundTripExactly() async throws {
        try await forEachStore { env in
            let imageData = bytes(20_000, seed: 7).base64EncodedString()
            let toolResult: JSONValue = [
                "type": "tool_result", "tool_use_id": "toolu_1",
                "content": [
                    textBlock("Here is the screenshot"),
                    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": .string(imageData)]],
                ],
            ]
            let fetched: JSONValue = [
                "type": "web_fetch_tool_result", "tool_use_id": "srvtoolu_1",
                "content": [
                    "type": "web_fetch_result", "url": "https://example.com/a.pdf",
                    "content": ["type": "document", "source": ["type": "base64", "media_type": "application/pdf",
                                                               "data": .string(bytes(18_000, seed: 8).base64EncodedString())]],
                ],
            ]
            let user = ChatMessage(role: .user, text: "", apiContent: [toolResult], createdAt: baseDate)
            let assistant = assistantMessage("Read it.", content: [fetched, textBlock("Read it.")])
            let snapshot = makeSnapshot(messages: [userMessage("go"), user, assistant])
            let summary = try await env.store.save(snapshot)
            XCTAssertEqual(summary.blobs.count, 2, env.label)

            let loaded = try await env.store.load(id: snapshot.id)
            XCTAssertEqual(loaded.messages[1].apiContent, [toolResult], env.label)
            XCTAssertEqual(loaded.messages[2].apiContent, [fetched, textBlock("Read it.")], env.label)
            XCTAssertTrue(loaded.textOnlyContextMessageIDs.isEmpty)
        }
    }

    func testMissingBlobsBecomeUnavailableNotesAndTextOnlyContext() async throws {
        try await forEachStore { env in
            let image = imageAttachment()
            let fetched: JSONValue = [
                "type": "web_fetch_tool_result",
                "content": ["type": "document", "title": "Report", "source": ["type": "base64", "media_type": "application/pdf",
                                                                              "data": .string(bytes(20_000, seed: 3).base64EncodedString())]],
            ]
            let user = userMessage("Look", attachments: [image])
            let assistant = assistantMessage("Seen.", content: [fetched, textBlock("Seen.")])
            let old = makeSnapshot(messages: [user, assistant], updatedAt: baseDate.addingTimeInterval(-60 * 86_400))
            _ = try await env.store.save(old)

            let recentImage = imageAttachment("recent.png", seed: 9)
            let recent = makeSnapshot(messages: [userMessage("Keep", attachments: [recentImage])], updatedAt: baseDate)
            _ = try await env.store.save(recent)

            await env.store.collectGarbage(protectedBlobs: [], now: baseDate)
            let usage = await env.store.usage()
            XCTAssertEqual(usage.attachmentBytes, 30_000, "only the recent conversation's image survives (\(env.label))")

            let loaded = try await env.store.load(id: old.id)
            XCTAssertEqual(loaded.unavailableAttachmentIDs, [image.id], env.label)
            let restored = loaded.messages[0].attachments[0]
            XCTAssertEqual(restored.payload, .text("[photo.png is no longer stored on this Mac.]"))
            XCTAssertEqual(restored.byteCount, 0)
            XCTAssertEqual(loaded.messages[0].apiContent[0],
                           textBlock("[Earlier attachment not kept on this Mac: an image. Ask the user to attach it again if you need it.]"))
            XCTAssertEqual(loaded.messages[0].apiContent[1], textBlock("Look"))
            XCTAssertEqual(loaded.textOnlyContextMessageIDs, [assistant.id], env.label)

            let kept = try await env.store.load(id: recent.id)
            XCTAssertEqual(kept.messages, recent.messages, env.label)
        }
    }

    func testAttachmentsHistoryDoesNotKeepLeaveNoPayload() async throws {
        try await forEachStore { env in
            let window = imageAttachment("Safari window", seed: 4, retains: false)
            let selection = Attachment(kind: .text, displayName: "Selection from Notes", badge: "TXT",
                                       payload: .text("private selected text"), byteCount: 21, retainsPayloadInHistory: false)
            let user = userMessage("What is this?", attachments: [window, selection])
            let snapshot = makeSnapshot(messages: [user, assistantMessage("A window.")], thumbnails: [window.id: pngData()])
            let summary = try await env.store.save(snapshot)
            XCTAssertTrue(summary.blobs.isEmpty, env.label)
            let usage = await env.store.usage()
            XCTAssertEqual(usage.attachmentBytes, 0, env.label)

            if let root = env.root, let attachments = env.attachments, let conversations = env.conversations {
                XCTAssertTrue(files(in: attachments).isEmpty, "no blob folders")
                let file = try String(contentsOf: conversations.appendingPathComponent("\(snapshot.id.uuidString).json"), encoding: .utf8)
                XCTAssertFalse(file.contains("private selected text"))
                if case .image(_, let base64) = window.payload { XCTAssertFalse(file.contains(String(base64.prefix(64)))) }
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
            }

            let loaded = try await env.store.load(id: snapshot.id)
            XCTAssertEqual(loaded.unavailableAttachmentIDs, [window.id, selection.id], env.label)
            XCTAssertNotNil(loaded.messages[0].attachments[0].thumbnail, "the chip keeps its thumbnail")
            XCTAssertEqual(loaded.messages[0].attachments[1].payload, .text("[Selection from Notes is no longer stored on this Mac.]"))
            XCTAssertEqual(loaded.messages[0].apiContent, [
                textBlock("[Earlier attachment not kept on this Mac: an image. Ask the user to attach it again if you need it.]"),
                textBlock("[Earlier attachment not kept on this Mac: Selection from Notes. Ask the user to attach it again if you need it.]"),
                textBlock("What is this?"),
            ], env.label)
        }
    }

    func testRestoredUnavailableAttachmentsStayUnavailableOnResave() async throws {
        try await forEachStore { env in
            let image = imageAttachment()
            var restored = image
            restored.payload = .text("[photo.png is no longer stored on this Mac.]")
            restored.byteCount = 0
            let user = ChatMessage(role: .user, text: "Again", attachments: [restored], apiContent: [textBlock("Again")], createdAt: baseDate)
            let snapshot = makeSnapshot(messages: [user], unavailable: [image.id])
            let summary = try await env.store.save(snapshot)
            XCTAssertTrue(summary.blobs.isEmpty)
            let loaded = try await env.store.load(id: snapshot.id)
            XCTAssertEqual(loaded.unavailableAttachmentIDs, [image.id], env.label)
        }
    }

    // MARK: Tool calls

    func testToolCallsRoundTripWithImagesStrippedAndUnfinishedCallsSettled() async throws {
        try await forEachStore { env in
            let presentation = ToolCallPresentation(symbol: "calendar.badge.plus", title: "Add “Dentist” to Calendar",
                                                    activeTitle: "Adding to Calendar…", doneTitle: "Added “Dentist”",
                                                    detail: "Home", disclosure: ToolDisclosure(label: "Input", text: "{}", language: nil))
            let undo = UndoToken(toolName: "create_calendar_event", itemID: "E1", fallback: nil,
                                 expires: baseDate.addingTimeInterval(600), doneTitle: "Removed “Dentist”",
                                 noteForClaude: "the event was removed")
            let succeeded = ToolCall(id: "c1", name: "create_calendar_event", input: ["title": "Dentist"],
                                     presentation: presentation, status: .succeeded, result: .text(#"{"status":"created"}"#),
                                     approvedVia: .userApproved, undo: undo, startedAt: baseDate, finishedAt: baseDate)
            let withImage = ToolCall(id: "c2", name: "screenshot", input: [:], presentation: .generic(toolName: "screenshot"),
                                     status: .succeeded,
                                     result: ToolOutput(parts: [.text("see"), .image(mediaType: "image/png", base64: "iVBORw0KGgo=")], isError: false))
            let running = ToolCall(id: "c3", name: "run_shortcut", input: ["name": "Lights"],
                                   presentation: .generic(toolName: "run_shortcut"), status: .running)
            let queued = ToolCall(id: "c4", name: "open_url", input: nil, invalidInput: "{\"url\":",
                                  presentation: .generic(toolName: "open_url"), status: .queued)
            let exchange = ToolExchange(contentEnd: 1, textEnd: 4, callIDs: ["c1", "c2", "c3"])
            var assistant = assistantMessage("Done", state: .streaming)
            assistant.toolCalls = [succeeded, withImage, running, queued]
            assistant.toolExchanges = [exchange]
            let snapshot = makeSnapshot(messages: [userMessage("Book it"), assistant])

            _ = try await env.store.save(snapshot)
            let loaded = try await env.store.load(id: snapshot.id)
            let calls = loaded.messages[1].toolCalls

            XCTAssertEqual(calls.count, 4, env.label)
            XCTAssertEqual(calls[0], succeeded, env.label)
            XCTAssertEqual(calls[1].result, ToolOutput(parts: [.text("see"), .text("[Image omitted]")], isError: false))
            XCTAssertEqual(calls[2].status, .cancelled)
            XCTAssertEqual(calls[2].result, .error("cancelled: The user stopped Otto before this action started."))
            XCTAssertEqual(calls[3].status, .cancelled)
            XCTAssertNil(calls[3].result, "not part of an exchange")
            XCTAssertEqual(calls[3].invalidInput, "{\"url\":")
            XCTAssertEqual(loaded.messages[1].toolExchanges, [exchange])
            XCTAssertEqual(loaded.messages[1].state, .cancelled)
        }
    }

    func testFilesWithoutToolFieldsDecodeWithEmptyDefaults() throws {
        let json = #"{"id":"3F2C9A1E-0000-4000-8000-000000000001","role":"assistant","createdAt":1790500000,"text":"Hi","state":{"kind":"complete"}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let message = try decoder.decode(StoredMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.toolCalls, [])
        XCTAssertEqual(message.toolExchanges, [])
        XCTAssertEqual(message.attachments.count, 0)
        XCTAssertTrue(message.includeInContext)
    }

    // MARK: Reading position and summary

    func testReadingPositionAndSummaryRoundTrip() async throws {
        try await forEachStore { env in
            let user = userMessage("Explain **actors** please", attachments: [imageAttachment()])
            let reply = assistantMessage("## Actors\nThey isolate state.")
            let position = ReadingPosition(anchorMessageID: reply.id, fractionScrolledPast: 0.25, isAtBottom: false,
                                           lastMessageID: reply.id, savedAt: baseDate)
            let snapshot = makeSnapshot(messages: [user, reply], title: "Explain actors", readingPosition: position)
            let summary = try await env.store.save(snapshot)

            XCTAssertEqual(summary.title, "Explain actors")
            XCTAssertEqual(summary.preview, "Actors", env.label)
            XCTAssertEqual(summary.searchText, "Explain actors please\nActors They isolate state.")
            XCTAssertEqual(summary.messageCount, 2)
            XCTAssertEqual(summary.attachmentCount, 1)
            XCTAssertEqual(summary.model, "claude-opus-5")
            XCTAssertEqual(summary.updatedAt, baseDate)

            let loaded = try await env.store.load(id: snapshot.id)
            XCTAssertEqual(loaded.readingPosition, position, env.label)

            let index = await env.store.loadIndex()
            XCTAssertEqual(index, [summary], env.label)
        }
    }

    // MARK: Damaged, newer and migrated files

    func testDamagedFilesAreQuarantinedAndCounted() async throws {
        try await forEachStore { env in
            let good = makeSnapshot(messages: [userMessage("fine")])
            _ = try await env.store.save(good)
            let brokenID = UUID()
            try env.store.debugPlaceRawFile(Data("{ not json".utf8), id: brokenID)

            let index = await env.store.loadIndex()
            XCTAssertEqual(index.map(\.id), [good.id], env.label)
            let usage = await env.store.usage()
            XCTAssertEqual(usage.damagedCount, 1, env.label)
            await assertThrows(.notFound, env.label) { _ = try await env.store.load(id: brokenID) }

            if let conversations = env.conversations {
                XCTAssertEqual(files(in: conversations.appendingPathComponent("Damaged")), ["\(brokenID.uuidString).json"])
                XCTAssertFalse(files(in: conversations).contains("\(brokenID.uuidString).json"))
            }

            // A file that breaks after it was indexed is quarantined when opened.
            try env.store.debugPlaceRawFile(Data("[]".utf8), id: good.id)
            await assertThrows(.damaged, env.label) { _ = try await env.store.load(id: good.id) }
            let after = await env.store.usage()
            XCTAssertEqual(after.damagedCount, 2, env.label)
        }
    }

    func testNewerVersionFilesAreHiddenUntouchedAndStillPruned() async throws {
        try await forEachStore { env in
            let newerID = UUID()
            let newer = Data(#"{"schemaVersion":2,"updatedAt":1790000000,"somethingNew":{"a":1}}"#.utf8)
            try env.store.debugPlaceRawFile(newer, id: newerID)
            let current = makeSnapshot(messages: [userMessage("current")])
            _ = try await env.store.save(current)

            let index = await env.store.loadIndex()
            XCTAssertEqual(index.map(\.id), [current.id], env.label)
            let usage = await env.store.usage()
            XCTAssertEqual(usage.newerVersionCount, 1, env.label)
            XCTAssertEqual(usage.damagedCount, 0)
            await assertThrows(.newerVersion, env.label) { _ = try await env.store.load(id: newerID) }

            let file = env.conversations?.appendingPathComponent("\(newerID.uuidString).json")
            if let file { XCTAssertEqual(try Data(contentsOf: file), newer, "never rewritten") }

            let pruned = await env.store.prune(updatedBefore: Date(timeIntervalSince1970: 1_790_000_001), protected: [])
            XCTAssertEqual(pruned, [newerID], env.label)
            let afterPrune = await env.store.usage()
            XCTAssertEqual(afterPrune.newerVersionCount, 0)
            if let file { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
        }
    }

    func testMigrationChainRunsForOlderFiles() async throws {
        try await forEachStore { env in
            let id = UUID()
            let record = StoredConversation(schemaVersion: 0, id: id, createdAt: baseDate, updatedAt: baseDate, title: "Old",
                                            appVersion: "0.9", readingPosition: nil, messages: [])
            try env.store.debugPlaceRawFile(try recordData(record), id: id)

            let withoutStep = await env.store.loadIndex()
            XCTAssertTrue(withoutStep.isEmpty, "no step for v0 in the app: damaged (\(env.label))")

            let migratedID = UUID()
            let migratable = StoredConversation(schemaVersion: 0, id: migratedID, createdAt: baseDate, updatedAt: baseDate,
                                            title: "Old", appVersion: "0.9", readingPosition: nil, messages: [])
            try env.store.debugPlaceRawFile(try recordData(migratable), id: migratedID)
            ConversationSchema.testSteps[0] = { json in
                json.setting("schemaVersion", to: 1).setting("title", to: "Migrated")
            }
            let index = await env.store.loadIndex()
            XCTAssertEqual(index.map(\.title), ["Migrated"], env.label)
            let loaded = try await env.store.load(id: migratedID)
            XCTAssertEqual(loaded.title, "Migrated")
            if let conversations = env.conversations {
                let raw = try JSONValue.decode(try Data(contentsOf: conversations.appendingPathComponent("\(migratedID.uuidString).json")))
                XCTAssertEqual(raw["schemaVersion"], 0, "migration is never written back on read")
            }
            ConversationSchema.testSteps = [:]
        }
    }

    func testTooLargeFilesAreRefused() async throws {
        var policy = HistoryPolicy.standard
        policy.maxConversationFileBytes = 2_048
        try await forEachStore(policy: policy) { env in
            let snapshot = makeSnapshot(messages: [userMessage(String(repeating: "long text ", count: 500))])
            _ = try await env.store.save(snapshot)
            await assertThrows(.tooLarge, env.label) { _ = try await env.store.load(id: snapshot.id) }
        }
    }

    // MARK: Retention, garbage collection, delete all

    func testPruneRespectsCutoffAndProtectedIDs() async throws {
        try await forEachStore { env in
            let old = makeSnapshot(messages: [userMessage("old")], updatedAt: baseDate.addingTimeInterval(-40 * 86_400))
            let oldProtected = makeSnapshot(messages: [userMessage("loaded")], updatedAt: baseDate.addingTimeInterval(-40 * 86_400))
            let recent = makeSnapshot(messages: [userMessage("recent")], updatedAt: baseDate.addingTimeInterval(-86_400))
            for snapshot in [old, oldProtected, recent] { _ = try await env.store.save(snapshot) }

            let pruned = await env.store.prune(updatedBefore: baseDate.addingTimeInterval(-30 * 86_400), protected: [oldProtected.id])
            XCTAssertEqual(pruned, [old.id], env.label)
            let index = await env.store.loadIndex()
            XCTAssertEqual(Set(index.map(\.id)), [oldProtected.id, recent.id], env.label)
            await assertThrows(.notFound, env.label) { _ = try await env.store.load(id: old.id) }
        }
    }

    func testGarbageCollectionKeepsProtectedAndRecentBlobs() async throws {
        try await forEachStore { env in
            let oldImage = imageAttachment("old.png", seed: 11)
            let loadedImage = imageAttachment("loaded.png", seed: 12)
            let old = makeSnapshot(messages: [userMessage("a", attachments: [oldImage])], updatedAt: baseDate.addingTimeInterval(-45 * 86_400))
            let loadedOld = makeSnapshot(messages: [userMessage("b", attachments: [loadedImage])], updatedAt: baseDate.addingTimeInterval(-45 * 86_400))
            let oldSummary = try await env.store.save(old)
            let protectedSummary = try await env.store.save(loadedOld)

            await env.store.collectGarbage(protectedBlobs: Set(protectedSummary.blobs.keys), now: baseDate)
            let usage = await env.store.usage()
            XCTAssertEqual(usage.attachmentBytes, 30_000, env.label)
            if let attachments = env.attachments, let sha = oldSummary.blobs.keys.first {
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: attachments.appendingPathComponent(String(sha.prefix(2))).appendingPathComponent(sha).path))
            }
            let loaded = try await env.store.load(id: loadedOld.id)
            XCTAssertTrue(loaded.unavailableAttachmentIDs.isEmpty, env.label)
        }
    }

    func testDeleteAndDeleteAllLeaveEmptyTrees() async throws {
        try await forEachStore { env in
            let first = makeSnapshot(messages: [userMessage("one", attachments: [imageAttachment()])])
            let second = makeSnapshot(messages: [userMessage("two")])
            _ = try await env.store.save(first)
            _ = try await env.store.save(second)
            try env.store.debugPlaceRawFile(Data("broken".utf8), id: UUID())
            _ = await env.store.loadIndex()

            await env.store.delete(ids: [second.id])
            let afterDelete = await env.store.loadIndex()
            XCTAssertEqual(afterDelete.map(\.id), [first.id], env.label)

            try await env.store.deleteAll()
            let index = await env.store.loadIndex()
            XCTAssertTrue(index.isEmpty, env.label)
            let usage = await env.store.usage()
            XCTAssertEqual(usage, HistoryStorageUsage(conversationCount: 0, conversationBytes: 0, attachmentBytes: 0,
                                                      newerVersionCount: 0, damagedCount: 0), env.label)
            if let root = env.root, let conversations = env.conversations, let attachments = env.attachments {
                XCTAssertTrue(files(in: conversations).allSatisfy { $0 == "index.json" })
                XCTAssertTrue(files(in: attachments).isEmpty)
                XCTAssertEqual(try permissions(conversations), 0o700)
                XCTAssertEqual(try permissions(attachments), 0o700)
                XCTAssertEqual(try permissions(root), 0o700)
            }
        }
    }

    // MARK: Disk layout, modes and atomicity

    func testFilesAre0600InNoindexFolders() async throws {
        let root = try makeRoot()
        let store = ConversationStore(location: .directory(root))
        XCTAssertEqual(store.rootURL, root)
        let snapshot = makeSnapshot(messages: [userMessage("modes", attachments: [imageAttachment()])])
        let summary = try await store.save(snapshot)
        store.flush()

        let conversations = root.appendingPathComponent("Conversations.noindex")
        let attachments = root.appendingPathComponent("Attachments.noindex")
        let file = conversations.appendingPathComponent("\(snapshot.id.uuidString).json")
        let sha = try XCTUnwrap(summary.blobs.keys.first)
        let fanOut = attachments.appendingPathComponent(String(sha.prefix(2)))

        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(try permissions(conversations.appendingPathComponent("index.json")), 0o600)
        XCTAssertEqual(try permissions(fanOut.appendingPathComponent(sha)), 0o600)
        for folder in [root, conversations, attachments, fanOut] {
            XCTAssertEqual(try permissions(folder), 0o700, folder.lastPathComponent)
        }
        XCTAssertNil(ConversationStore(location: .inMemory).rootURL)
    }

    func testUnsafeFolderFallsBackToMemory() async throws {
        let root = try makeRoot()
        let target = root.deletingLastPathComponent().appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)

        let store = ConversationStore(location: .directory(root))
        let snapshot = makeSnapshot(messages: [userMessage("kept in memory")])
        _ = try await store.save(snapshot)
        XCTAssertEqual(store.fallbackReason, "Otto couldn't use its data folder")
        let loaded = try await store.load(id: snapshot.id)
        XCTAssertEqual(loaded.messages.count, 1)
        XCTAssertTrue(files(in: target).isEmpty, "nothing was written through the symlink")
    }

    func testPartialTemporaryFileNeverReplacesTheConversation() async throws {
        let root = try makeRoot()
        let store = ConversationStore(location: .directory(root))
        let snapshot = makeSnapshot(messages: [userMessage("version one")])
        _ = try await store.save(snapshot)
        store.flush()

        let conversations = root.appendingPathComponent("Conversations.noindex")
        let partial = conversations.appendingPathComponent(".\(snapshot.id.uuidString).json.\(UUID().uuidString).tmp")
        try Data(#"{"schemaVersion":1,"id":"#.utf8).write(to: partial)

        let reopened = ConversationStore(location: .directory(root))
        let index = await reopened.loadIndex()
        XCTAssertEqual(index.map(\.id), [snapshot.id])
        let loaded = try await reopened.load(id: snapshot.id)
        XCTAssertEqual(loaded.messages.map(\.text), ["version one"])
    }

    func testStaleOrMissingIndexIsRebuilt() async throws {
        let root = try makeRoot()
        let store = ConversationStore(location: .directory(root))
        let first = makeSnapshot(messages: [userMessage("first")], title: "First")
        let second = makeSnapshot(messages: [userMessage("second")], updatedAt: baseDate.addingTimeInterval(60), title: "Second")
        let firstSummary = try await store.save(first)
        let secondSummary = try await store.save(second)
        store.flush()

        let conversations = root.appendingPathComponent("Conversations.noindex")
        try FileManager.default.removeItem(at: conversations.appendingPathComponent("index.json"))
        let rebuilt = await ConversationStore(location: .directory(root)).loadIndex()
        XCTAssertEqual(rebuilt, [secondSummary, firstSummary])

        // A file changed behind the index's back is summarized again; an index entry without a file is dropped.
        var record = ConversationCodec.encode(first, policy: .standard, appVersion: nil).record
        record.title = "Renamed elsewhere"
        record.updatedAt = baseDate.addingTimeInterval(120)
        try SecureFile.write(try recordData(record), to: conversations.appendingPathComponent("\(first.id.uuidString).json"))
        try FileManager.default.removeItem(at: conversations.appendingPathComponent("\(second.id.uuidString).json"))

        let refreshed = await ConversationStore(location: .directory(root)).loadIndex()
        XCTAssertEqual(refreshed.map(\.title), ["Renamed elsewhere"])
    }

    func testSymlinksAndForeignNamesAreIgnored() async throws {
        let root = try makeRoot()
        let store = ConversationStore(location: .directory(root))
        let real = makeSnapshot(messages: [userMessage("real")])
        _ = try await store.save(real)
        store.flush()

        let conversations = root.appendingPathComponent("Conversations.noindex")
        let realFile = conversations.appendingPathComponent("\(real.id.uuidString).json")
        let data = try Data(contentsOf: realFile)
        try data.write(to: conversations.appendingPathComponent("notes.json"))
        try data.write(to: conversations.appendingPathComponent("\(UUID().uuidString.lowercased()).json"))
        try FileManager.default.createSymbolicLink(at: conversations.appendingPathComponent("\(UUID().uuidString).json"),
                                                   withDestinationURL: realFile)

        let index = await ConversationStore(location: .directory(root)).loadIndex()
        XCTAssertEqual(index.map(\.id), [real.id])
    }

    // MARK: Re-saving

    func testResavingReusesEncodedMessagesButRewritesCollectedBlobs() async throws {
        try await forEachStore { env in
            let id = UUID()
            let user = userMessage("Keep this", attachments: [imageAttachment()])
            let old = makeSnapshot(id: id, messages: [user], updatedAt: baseDate.addingTimeInterval(-60 * 86_400))
            _ = try await env.store.save(old)
            await env.store.collectGarbage(protectedBlobs: [], now: baseDate)
            let collected = await env.store.usage()
            XCTAssertEqual(collected.attachmentBytes, 0, env.label)

            let reply = assistantMessage("Kept.")
            let resaved = makeSnapshot(id: id, messages: [user, reply], updatedAt: baseDate)
            _ = try await env.store.save(resaved)
            let usage = await env.store.usage()
            XCTAssertEqual(usage.attachmentBytes, 30_000, "the cached message's blob was written again (\(env.label))")
            let loaded = try await env.store.load(id: id)
            XCTAssertEqual(loaded.messages, resaved.messages, env.label)
            XCTAssertTrue(loaded.unavailableAttachmentIDs.isEmpty)
        }
    }

    // MARK: Supersession

    func testLaterSaveOfTheSameConversationWins() async throws {
        try await forEachStore { env in
            let id = UUID()
            let firstSnapshot = makeSnapshot(id: id, messages: [userMessage("first")], title: "First")
            let secondSnapshot = makeSnapshot(id: id, messages: [userMessage("first"), assistantMessage("second")],
                                              updatedAt: baseDate.addingTimeInterval(1), title: "First")
            let first = expectation(description: "first save")
            let second = expectation(description: "second save")
            let results = HistoryTestResults()
            env.store.enqueueSave(firstSnapshot) { result in
                results.append(result)
                first.fulfill()
            }
            env.store.enqueueSave(secondSnapshot) { result in
                results.append(result)
                second.fulfill()
            }
            await fulfillment(of: [first, second], timeout: 5)

            XCTAssertEqual(results.messageCounts, [2, 2], "the superseded save reports the later result (\(env.label))")
            let loaded = try await env.store.load(id: id)
            XCTAssertEqual(loaded.messages, secondSnapshot.messages, env.label)
        }
    }
}

/// Collects save results from the store's queue.
private final class HistoryTestResults: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []

    func append(_ result: Result<ConversationSummary, Error>) {
        lock.withLock { counts.append((try? result.get())?.messageCount ?? -1) }
    }

    var messageCounts: [Int] { lock.withLock { counts } }
}
