//
//  ReadingRestoreTests.swift
//  Otto
//

import XCTest
@testable import Otto

final class ReadingRestoreTests: XCTestCase {
    private let messages: [ChatMessage] = [
        ChatMessage(role: .user, text: "First question"),
        ChatMessage(role: .assistant, text: "First answer"),
        ChatMessage(role: .user, text: "Second question"),
        ChatMessage(role: .assistant, text: "Second answer"),
    ]

    private func position(anchor: UUID, isAtBottom: Bool = false, lastMessageID: UUID?) -> ReadingPosition {
        ReadingPosition(anchorMessageID: anchor, fractionScrolledPast: 0.4, isAtBottom: isAtBottom,
                        lastMessageID: lastMessageID, savedAt: Date(timeIntervalSince1970: 0))
    }

    func testUnreadReplyWins() {
        let saved = position(anchor: messages[1].id, lastMessageID: messages[3].id)
        XCTAssertEqual(ReadingRestore.target(unreadReplyID: messages[3].id, saved: saved, messages: messages),
                       .messageTop(messages[3].id))
    }

    func testUnreadReplyThatIsGoneFallsThroughToTheSavedPosition() {
        let saved = position(anchor: messages[1].id, lastMessageID: messages[3].id)
        XCTAssertEqual(ReadingRestore.target(unreadReplyID: UUID(), saved: saved, messages: messages),
                       .messageTop(messages[1].id))
        XCTAssertEqual(ReadingRestore.target(unreadReplyID: UUID(), saved: nil, messages: messages), .bottom)
    }

    func testSavedPositionWithMatchingTailRestoresTheAnchor() {
        let saved = position(anchor: messages[1].id, lastMessageID: messages[3].id)
        XCTAssertEqual(ReadingRestore.target(unreadReplyID: nil, saved: saved, messages: messages),
                       .messageTop(messages[1].id))
    }

    func testSavedAtBottomGoesToBottom() {
        let saved = position(anchor: messages[1].id, isAtBottom: true, lastMessageID: messages[3].id)
        XCTAssertEqual(ReadingRestore.target(unreadReplyID: nil, saved: saved, messages: messages), .bottom)
    }

    func testDifferentTailGoesToBottom() {
        let saved = position(anchor: messages[1].id, lastMessageID: messages[2].id)
        XCTAssertEqual(ReadingRestore.target(unreadReplyID: nil, saved: saved, messages: messages), .bottom,
                       "a new turn or a regenerate since saving")
        let savedWithoutTail = position(anchor: messages[1].id, lastMessageID: nil)
        XCTAssertEqual(ReadingRestore.target(unreadReplyID: nil, saved: savedWithoutTail, messages: messages), .bottom)
    }

    func testMissingAnchorGoesToBottom() {
        let saved = position(anchor: UUID(), lastMessageID: messages[3].id)
        XCTAssertEqual(ReadingRestore.target(unreadReplyID: nil, saved: saved, messages: messages), .bottom)
    }

    func testNothingSavedGoesToBottom() {
        XCTAssertEqual(ReadingRestore.target(unreadReplyID: nil, saved: nil, messages: messages), .bottom)
        XCTAssertEqual(ReadingRestore.target(unreadReplyID: nil, saved: nil, messages: []), .bottom)
    }

    func testEmptyTranscriptIgnoresASavedPositionWithoutTail() {
        let saved = position(anchor: UUID(), lastMessageID: nil)
        XCTAssertEqual(ReadingRestore.target(unreadReplyID: nil, saved: saved, messages: []), .bottom)
    }
}
