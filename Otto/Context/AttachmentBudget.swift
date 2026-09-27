//
//  AttachmentBudget.swift
//  Otto
//
//  Request-level limits for attachments. Each attachment is capped when it is
//  loaded, but the Messages API also rejects any request body over 32 MB and
//  every earlier turn's attachments are re-sent as history, so the total has
//  to be checked when a chip is added, when a message is sent, and again for
//  every request built from the conversation.
//

import Foundation

enum AttachmentBudget {
    /// Most the `messages` array of one request may take once JSON-encoded. The API limit is 32 MB for the
    /// whole body; the rest is left for the system prompt, tool definitions and the other request fields.
    static let maxRequestContentBytes = 30_000_000

    /// Models with a 200K-token context window (Claude Haiku 4.5) accept at most 100 PDF pages per request.
    static let smallContextMaxPDFPages = 100

    /// User-facing copy when a message can't be sent even after earlier attachments were dropped.
    static let requestTooLargeDescription =
        "This message's attachments are too large to send together (the limit is about 30 MB). Remove some and try again."

    static func maxPDFPages(for model: ModelOption) -> Int {
        model == .haiku45 ? smallContextMaxPDFPages : AttachmentLoader.maxPDFPages
    }

    /// Whether `attachment` is a PDF with more pages than `model` accepts.
    static func exceedsPageLimit(_ attachment: Attachment, model: ModelOption) -> Bool {
        guard let pages = AttachmentLoader.pdfPageCount(of: attachment) else { return false }
        return pages > maxPDFPages(for: model)
    }

    /// JSON-encoded size of the content blocks these attachments add to a message.
    static func encodedBytes(of attachments: [Attachment]) -> Int {
        attachments.reduce(0) { total, attachment in
            total + attachment.contentBlocks().reduce(0) { $0 + estimatedEncodedBytes($1) + 1 }
        }
    }

    /// The first reason `attachments` can't be sent together in one message to `model`, or nil:
    /// a PDF over the model's page limit, or a combined payload over `maxRequestContentBytes` (reported on
    /// the attachment that crosses it). Check it before adding a chip (with the new attachment last) and again
    /// before sending, since the model may have changed in between.
    static func problem(with attachments: [Attachment], model: ModelOption) -> AttachmentError? {
        if let pdf = attachments.first(where: { exceedsPageLimit($0, model: model) }) {
            return .tooLarge(name: pdf.displayName, limit: "\(maxPDFPages(for: model)) pages with \(model.displayName)")
        }
        var total = 0
        for attachment in attachments {
            total += encodedBytes(of: [attachment])
            if total > maxRequestContentBytes {
                return .tooLarge(name: attachment.displayName, limit: "about 30 MB for all attachments in a message")
            }
        }
        return nil
    }

    /// Makes a request's `messages` array (`[{"role", "content"}]`) fit `limit`: while it is too large, the
    /// image and document blocks of the oldest user turns are replaced by a short text note, one turn at a
    /// time. The last user turn — the one being answered — is never changed. Returns nil when even that
    /// isn't enough (the new message alone is too large; see `requestTooLargeDescription`).
    static func fitting(_ messages: [JSONValue], limit: Int = maxRequestContentBytes) -> [JSONValue]? {
        var result = messages
        var total = estimatedEncodedBytes(.array(result))
        if total <= limit { return result }

        let protectedIndex = result.lastIndex { $0["role"]?.stringValue == ChatRole.user.rawValue }
        for index in result.indices where index != protectedIndex {
            guard result[index]["role"]?.stringValue == ChatRole.user.rawValue,
                  let content = result[index]["content"]?.arrayValue,
                  content.contains(where: isAttachmentBlock)
            else { continue }
            let stripped = result[index].setting("content", to: .array(strippingAttachments(from: content)))
            total += estimatedEncodedBytes(stripped) - estimatedEncodedBytes(result[index])
            result[index] = stripped
            if total <= limit { return result }
        }
        return nil
    }

    /// A user turn's content with every image and document block replaced by a short text note, so the
    /// conversation keeps its shape (and the model knows something was there) without the payload.
    static func strippingAttachments(from content: [JSONValue]) -> [JSONValue] {
        content.map { block in
            guard isAttachmentBlock(block) else { return block }
            let kind = block.typeName == "image" ? "An image" : "A document"
            let title = block["title"]?.stringValue.map { " (\($0))" } ?? ""
            let note = "[\(kind)\(title) attached earlier in the conversation was removed from this request to stay within the size limit.]"
            return ["type": "text", "text": .string(note)]
        }
    }

    /// Size of `value` as `JSONValue.makeEncoder()` writes it (sorted keys, unescaped slashes). Base64 payloads
    /// are counted without scanning them; other strings are scanned for characters that need escaping.
    static func estimatedEncodedBytes(_ value: JSONValue) -> Int {
        switch value {
        case .null: return 4
        case .bool(let flag): return flag ? 4 : 5
        case .int(let number): return String(number).utf8.count
        case .double(let number): return String(number).utf8.count
        case .string(let string): return encodedBytes(of: string)
        case .array(let elements):
            return 2 + max(0, elements.count - 1) + elements.reduce(0) { $0 + estimatedEncodedBytes($1) }
        case .object(let object):
            let isBase64Source = object["type"]?.stringValue == "base64"
            var total = 2 + max(0, object.count - 1)
            for (key, element) in object {
                total += encodedBytes(of: key) + 1
                if isBase64Source, key == "data", case .string(let data) = element {
                    total += data.utf8.count + 2  // base64 never needs escaping
                } else {
                    total += estimatedEncodedBytes(element)
                }
            }
            return total
        }
    }

    // MARK: - Private

    private static func isAttachmentBlock(_ block: JSONValue) -> Bool {
        block.typeName == "image" || block.typeName == "document"
    }

    private static func encodedBytes(of string: String) -> Int {
        var string = string
        return string.withUTF8 { bytes in
            var total = bytes.count + 2
            for byte in bytes where byte < 0x20 || byte == 0x22 || byte == 0x5C {
                switch byte {
                case 0x22, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D: total += 1
                default: total += 5
                }
            }
            return total
        }
    }
}
