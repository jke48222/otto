//
//  ConversationCodec.swift
//  Otto
//
//  Converts between the runtime conversation (ChatMessage, Attachment, ToolCall) and the stored record:
//  payloads go to blobs, attachments History never keeps are reduced to their chip, tool results lose
//  their images, and restored conversations come back with missing payloads explained.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

/// A conversation to save, built on the main actor and encoded off it.
struct ConversationSnapshot: @unchecked Sendable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let title: String
    /// Pending deltas already flushed.
    let messages: [ChatMessage]
    /// Attachment id → PNG (≤ `HistoryPolicy.maxThumbnailBytes`).
    let thumbnails: [UUID: Data]
    let unavailableAttachmentIDs: Set<UUID>
    let readingPosition: ReadingPosition?
}

enum ConversationCodec {
    /// A settled message encoded once, reused by later saves while its encoding key is unchanged.
    struct EncodedMessage: Sendable {
        let key: EncodingKey
        let message: StoredMessage
    }

    /// What must change for a message to be encoded again.
    struct EncodingKey: Equatable, Sendable {
        var state: StoredMessageState
        var includeInContext: Bool
        var textBytes: Int
        var thinkingBytes: Int
        var apiContentCount: Int
        var attachmentCount: Int
        var unavailableAttachments: Int
        var thumbnailCount: Int
        var toolCallCount: Int
        var terminalToolCallCount: Int
        var toolCallStatuses: [ToolCallStatus]
        var toolExchangeCount: Int
    }

    /// Text of a tool call that was never run when the conversation was saved (SPEC-v2 §5.6).
    static let cancelledBeforeRunResult = "cancelled: The user stopped Otto before this action started."

    static func encode(_ snapshot: ConversationSnapshot, policy: HistoryPolicy,
                       appVersion: String?) -> (record: StoredConversation, blobs: [PendingBlob]) {
        var memo: [UUID: EncodedMessage] = [:]
        return encode(snapshot, policy: policy, appVersion: appVersion, memo: &memo, blobExists: { _ in false })
    }

    /// Encodes only the messages whose encoding key changed (or whose blobs are no longer on disk); `memo` is
    /// updated to exactly the snapshot's messages. Blobs of reused messages are not returned.
    static func encode(_ snapshot: ConversationSnapshot, policy: HistoryPolicy, appVersion: String?,
                       memo: inout [UUID: EncodedMessage],
                       blobExists: (BlobRef) -> Bool) -> (record: StoredConversation, blobs: [PendingBlob]) {
        var blobs: [String: PendingBlob] = [:]
        var nextMemo: [UUID: EncodedMessage] = [:]
        var stored: [StoredMessage] = []
        stored.reserveCapacity(snapshot.messages.count)

        for message in snapshot.messages {
            let current = encodingKey(of: message, snapshot: snapshot)
            if let cached = memo[message.id], cached.key == current,
               BlobExternalizer.refs(in: cached.message).allSatisfy(blobExists) {
                stored.append(cached.message)
                nextMemo[message.id] = cached
                continue
            }
            let (encoded, messageBlobs) = encode(message, snapshot: snapshot, policy: policy)
            for blob in messageBlobs where blobs[blob.ref.sha256] == nil { blobs[blob.ref.sha256] = blob }
            stored.append(encoded)
            nextMemo[message.id] = EncodedMessage(key: current, message: encoded)
        }
        memo = nextMemo

        let record = StoredConversation(
            schemaVersion: ConversationSchema.current,
            id: snapshot.id,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            title: snapshot.title,
            appVersion: appVersion,
            readingPosition: snapshot.readingPosition,
            messages: stored
        )
        return (record, blobs.keys.sorted().compactMap { blobs[$0] })
    }

    /// Rebuilds the runtime conversation. A missing blob makes its attachment unavailable, turns a user block into
    /// a note for Claude, and marks an assistant message for text-only context. An interrupted assistant message
    /// with no text, content or tool calls is dropped.
    static func decode(_ record: StoredConversation, readBlob: (BlobRef) -> Data?) -> LoadedConversation {
        var messages: [ChatMessage] = []
        var unavailable = Set<UUID>()
        var textOnly = Set<UUID>()

        for stored in record.messages {
            if stored.role == .assistant, stored.state == .interrupted, stored.text.isEmpty,
               stored.apiContent.isEmpty, stored.toolCalls.isEmpty {
                continue
            }

            var attachments: [Attachment] = []
            for storedAttachment in stored.attachments {
                let (attachment, isAvailable) = decode(storedAttachment, readBlob: readBlob)
                if !isAvailable { unavailable.insert(attachment.id) }
                attachments.append(attachment)
            }

            let (content, missing) = BlobExternalizer.rehydrate(stored.apiContent, read: readBlob) { block in
                missingNote(for: block)
            }
            if missing > 0, stored.role == .assistant { textOnly.insert(stored.id) }

            messages.append(ChatMessage(
                id: stored.id,
                role: stored.role,
                text: stored.text,
                attachments: attachments,
                thinking: stored.thinking,
                isThinking: false,
                activities: stored.activities.map {
                    ToolActivity(id: $0.id, kind: ToolActivity.Kind(rawValue: $0.kind) ?? .other, label: $0.label, isDone: true)
                },
                sources: stored.sources.map { SourceLink(title: $0.title, url: $0.url) },
                apiContent: content,
                state: stored.state.runtime,
                model: stored.model,
                includeInContext: stored.includeInContext,
                createdAt: stored.createdAt,
                toolCalls: restoredToolCalls(stored.toolCalls, exchanges: stored.toolExchanges),
                toolExchanges: stored.toolExchanges
            ))
        }

        return LoadedConversation(
            id: record.id,
            title: record.title,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            messages: messages,
            unavailableAttachmentIDs: unavailable,
            textOnlyContextMessageIDs: textOnly,
            readingPosition: record.readingPosition
        )
    }

    static func summary(of record: StoredConversation, fileBytes: Int64, fileModifiedAt: Date,
                        policy: HistoryPolicy) -> ConversationSummary {
        var blobs: [String: Int64] = [:]
        for message in record.messages {
            for ref in BlobExternalizer.refs(in: message) { blobs[ref.sha256] = ref.bytes }
        }
        let skeleton = record.messages.map { stored in
            ChatMessage(id: stored.id, role: stored.role, text: stored.text, state: stored.state.runtime,
                        createdAt: stored.createdAt)
        }
        let plain = record.messages
            .filter { !$0.text.isEmpty }
            .map { ConversationTitler.plainText(fromMarkdown: $0.text) }
            .joined(separator: "\n")
        let model = record.messages.last { $0.role == .assistant && $0.model != nil }?.model

        return ConversationSummary(
            id: record.id,
            title: DisplayText.sanitized(record.title, maxLength: ConversationTitler.maxTitleLength),
            preview: ConversationTitler.preview(for: skeleton),
            searchText: truncated(plain, toUTF8Bytes: policy.searchTextLimit),
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            messageCount: record.messages.count,
            attachmentCount: record.messages.reduce(0) { $0 + $1.attachments.count },
            model: model,
            blobs: blobs,
            fileBytes: fileBytes,
            fileModifiedAt: fileModifiedAt
        )
    }

    /// The note that replaces an attachment block whose payload is gone (history.md §4 rule 4).
    static func missingNote(for block: JSONValue) -> JSONValue {
        let title = block["title"]?.stringValue.map { DisplayText.sanitized($0, maxLength: 200) }
        let name = (title?.isEmpty == false ? title : nil) ?? (block.typeName == "image" ? "an image" : "a document")
        return ["type": "text", "text": .string("[Earlier attachment not kept on this \(OttoDevice.name): \(name). Ask the user to attach it again if you need it.]")]
    }

    /// Chip text of an attachment whose payload is gone.
    static func unavailablePayloadText(for name: String) -> String {
        "[\(name) is no longer stored on this \(OttoDevice.name).]"
    }

    // MARK: - Encoding

    private static func encodingKey(of message: ChatMessage, snapshot: ConversationSnapshot) -> EncodingKey {
        EncodingKey(
            state: StoredMessageState(message.state),
            includeInContext: message.includeInContext,
            textBytes: message.text.utf8.count,
            thinkingBytes: message.thinking.utf8.count,
            apiContentCount: message.apiContent.count,
            attachmentCount: message.attachments.count,
            unavailableAttachments: message.attachments.filter { snapshot.unavailableAttachmentIDs.contains($0.id) }.count,
            thumbnailCount: message.attachments.filter { snapshot.thumbnails[$0.id] != nil }.count,
            toolCallCount: message.toolCalls.count,
            terminalToolCallCount: message.toolCalls.filter { $0.status.isTerminal }.count,
            toolCallStatuses: message.toolCalls.map(\.status),
            toolExchangeCount: message.toolExchanges.count
        )
    }

    private static func encode(_ message: ChatMessage, snapshot: ConversationSnapshot,
                               policy: HistoryPolicy) -> (StoredMessage, [PendingBlob]) {
        var blobs: [PendingBlob] = []
        var attachments: [StoredAttachment] = []
        var unkeptBlocks: [JSONValue] = []

        for attachment in message.attachments {
            let payload: StoredPayload
            if snapshot.unavailableAttachmentIDs.contains(attachment.id) {
                payload = .unavailable
            } else if !attachment.retainsPayloadInHistory {
                payload = .unavailable
                unkeptBlocks.append(contentsOf: attachment.contentBlocks())
            } else {
                switch attachment.payload {
                case .image(let mediaType, let base64):
                    let blob = BlobExternalizer.blob(forPayload: base64, preferBase64: true)
                    blobs.append(blob)
                    payload = .blob(blob.ref, mediaType: mediaType)
                case .pdf(let base64):
                    let blob = BlobExternalizer.blob(forPayload: base64, preferBase64: true)
                    blobs.append(blob)
                    payload = .blob(blob.ref, mediaType: "application/pdf")
                case .text(let text):
                    if text.utf8.count < policy.externalizeThresholdBytes {
                        payload = .text(text)
                    } else {
                        let blob = BlobExternalizer.blob(forPayload: text, preferBase64: false)
                        blobs.append(blob)
                        payload = .blob(blob.ref, mediaType: "text/plain")
                    }
                case .webPage(let title, let url):
                    payload = .webPage(title: title, url: url)
                }
            }
            let thumbnail = snapshot.thumbnails[attachment.id].flatMap { $0.count <= policy.maxThumbnailBytes ? $0 : nil }
            attachments.append(StoredAttachment(
                id: attachment.id, kind: attachment.kind, displayName: attachment.displayName, badge: attachment.badge,
                sourceURL: attachment.sourceURL, appBundleID: attachment.appBundleID, byteCount: attachment.byteCount,
                thumbnailPNG: thumbnail, payload: payload
            ))
        }

        var content = message.apiContent
        if message.role == .user, !unkeptBlocks.isEmpty {
            content = replacingUnkept(unkeptBlocks, in: content)
        }
        let externalized = BlobExternalizer.externalize(content, threshold: policy.externalizeThresholdBytes)
        blobs.append(contentsOf: externalized.blobs)

        let stored = StoredMessage(
            id: message.id,
            role: message.role,
            createdAt: message.createdAt,
            includeInContext: message.includeInContext,
            text: message.text,
            thinking: message.thinking,
            state: StoredMessageState(message.state),
            attachments: attachments,
            activities: message.activities.map {
                StoredActivity(id: $0.id, kind: $0.kind.rawValue, label: $0.label, isDone: $0.isDone)
            },
            sources: message.sources.map { StoredSource(title: $0.title, url: $0.url) },
            model: message.model,
            apiContent: externalized.content,
            toolCalls: message.toolCalls.map { call in
                var stored = call
                stored.result = call.result?.strippingImages()
                return stored
            },
            toolExchanges: message.toolExchanges
        )
        return (stored, blobs)
    }

    /// Each block of an attachment History doesn't keep becomes the same note a missing blob produces, so its
    /// payload never reaches the disk.
    private static func replacingUnkept(_ unkept: [JSONValue], in content: [JSONValue]) -> [JSONValue] {
        var remaining = unkept
        return content.map { block in
            guard let index = remaining.firstIndex(of: block) else { return block }
            remaining.remove(at: index)
            return missingNote(for: block)
        }
    }

    // MARK: - Decoding

    private static func decode(_ stored: StoredAttachment, readBlob: (BlobRef) -> Data?) -> (Attachment, Bool) {
        var payload: AttachmentPayload?
        switch stored.payload {
        case .blob(let ref, let mediaType):
            if ref.isWellFormed, let data = readBlob(ref), let string = BlobExternalizer.payloadString(data, encoding: ref.encoding) {
                switch stored.kind {
                case .image: payload = .image(mediaType: mediaType ?? "image/png", base64: string)
                case .pdf: payload = .pdf(base64: string)
                case .text: payload = .text(string)
                case .webPage: payload = nil
                }
            }
        case .text(let text):
            payload = .text(text)
        case .webPage(let title, let url):
            payload = .webPage(title: title, url: url)
        case .unavailable:
            payload = nil
        }

        let thumbnail = stored.thumbnailPNG.flatMap { PlatformImage(data: $0) }
        let attachment = Attachment(
            id: stored.id,
            kind: stored.kind,
            displayName: stored.displayName,
            badge: stored.badge,
            sourceURL: stored.sourceURL,
            appBundleID: stored.appBundleID,
            thumbnail: thumbnail,
            payload: payload ?? .text(unavailablePayloadText(for: stored.displayName)),
            byteCount: payload == nil ? 0 : stored.byteCount
        )
        return (attachment, payload != nil)
    }

    /// Calls still running when the conversation was saved can't resume: they load as cancelled, and a call of
    /// an exchange without a result gets the "cancelled before run" result Claude would have received.
    private static func restoredToolCalls(_ calls: [ToolCall], exchanges: [ToolExchange]) -> [ToolCall] {
        let exchangedIDs = Set(exchanges.flatMap(\.callIDs))
        return calls.map { call in
            var restored = call
            if !restored.status.isTerminal { restored.status = .cancelled }
            if restored.result == nil, exchangedIDs.contains(restored.id) {
                restored.result = .error(cancelledBeforeRunResult)
            }
            restored.progressNote = nil
            return restored
        }
    }

    private static func truncated(_ text: String, toUTF8Bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        var bytes = 0
        for character in text {
            let size = character.utf8.count
            if bytes + size > limit { break }
            bytes += size
            result.append(character)
        }
        return result
    }
}
