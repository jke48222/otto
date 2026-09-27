//
//  ReadingRestore.swift
//  Otto
//
//  Where the transcript should land when the notch opens: the start of a reply that finished while it was
//  closed, else where the user stopped reading (if the conversation hasn't moved on since), else the bottom.
//

import Foundation

enum ReadingRestore {
    /// 1. unreadReplyID exists in messages → .messageTop(unreadReplyID)
    /// 2. saved != nil && !saved.isAtBottom && saved.lastMessageID == messages.last?.id && anchor exists → .messageTop(anchor)
    /// 3. .bottom        (the view turns .messageTop into .bottom when the content fits the viewport)
    static func target(unreadReplyID: UUID?, saved: ReadingPosition?, messages: [ChatMessage]) -> TranscriptRestoreTarget {
        if let unreadReplyID, messages.contains(where: { $0.id == unreadReplyID }) {
            return .messageTop(unreadReplyID)
        }
        if let saved, !saved.isAtBottom, saved.lastMessageID == messages.last?.id,
           messages.contains(where: { $0.id == saved.anchorMessageID }) {
            return .messageTop(saved.anchorMessageID)
        }
        return .bottom
    }
}
