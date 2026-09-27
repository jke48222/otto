//
//  ConversationRecord.swift
//  Otto
//
//  The on-disk shape of a conversation (schema v1): Codable records kept apart from the runtime models,
//  blob references, message states and the migration chain for older files.
//

import Foundation

enum ConversationSchema {
    static let current = 1

    /// Read first, so a file from a newer Otto is recognized without decoding the rest.
    struct VersionProbe: Decodable {
        let schemaVersion: Int
        let updatedAt: Date?
    }

    /// Applies the v(n) → v(n+1) steps up to `current`. Throws `HistoryStoreError.damaged` for a version no
    /// step knows.
    static func migrate(_ json: JSONValue, from version: Int) throws -> JSONValue {
        guard version >= 0, version <= current else { throw HistoryStoreError.damaged }
        var value = json
        var step = version
        while step < current {
            guard let migration = testSteps[step] ?? builtInSteps[step] else { throw HistoryStoreError.damaged }
            value = try migration(value)
            step += 1
        }
        return value
    }

    /// Test seam: extra steps registered by unit tests (empty in the app).
    nonisolated(unsafe) static var testSteps: [Int: (JSONValue) throws -> JSONValue] = [:]

    /// Steps shipped with the app. Schema 1 is the first version, so there are none yet.
    private static let builtInSteps: [Int: (JSONValue) throws -> JSONValue] = [:]
}

struct BlobRef: Codable, Hashable, Sendable {
    enum Encoding: String, Codable, Sendable { case base64, utf8 }

    /// 64 lowercase hex characters.
    var sha256: String
    /// `base64`: the blob holds the decoded bytes and is re-encoded on load. `utf8`: the string's bytes.
    var encoding: Encoding
    /// Size on disk.
    var bytes: Int64

    /// Whether `sha256` is safe to use as a file name (untrusted files can carry anything here).
    var isWellFormed: Bool { Self.isValidDigest(sha256) }

    static func isValidDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct StoredConversation: Codable, Sendable {
    var schemaVersion: Int
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var appVersion: String?
    var readingPosition: ReadingPosition?
    var messages: [StoredMessage]
}

struct StoredMessage: Codable, Sendable {
    var id: UUID
    var role: ChatRole
    var createdAt: Date
    var includeInContext: Bool
    var text: String
    var thinking: String
    var state: StoredMessageState
    var attachments: [StoredAttachment]
    var activities: [StoredActivity]
    var sources: [StoredSource]
    var model: String?
    /// With blob markers in place of large payloads.
    var apiContent: [JSONValue]
    /// Client tool calls; results have their images replaced by a note.
    var toolCalls: [ToolCall]
    var toolExchanges: [ToolExchange]

    init(id: UUID, role: ChatRole, createdAt: Date, includeInContext: Bool, text: String, thinking: String,
         state: StoredMessageState, attachments: [StoredAttachment], activities: [StoredActivity],
         sources: [StoredSource], model: String?, apiContent: [JSONValue], toolCalls: [ToolCall],
         toolExchanges: [ToolExchange]) {
        self.id = id
        self.role = role
        self.createdAt = createdAt
        self.includeInContext = includeInContext
        self.text = text
        self.thinking = thinking
        self.state = state
        self.attachments = attachments
        self.activities = activities
        self.sources = sources
        self.model = model
        self.apiContent = apiContent
        self.toolCalls = toolCalls
        self.toolExchanges = toolExchanges
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, createdAt, includeInContext, text, thinking, state, attachments, activities, sources, model,
             apiContent, toolCalls, toolExchanges
    }

    /// Everything but identity, role and date decodes with a default, so additive fields never need a schema bump.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(ChatRole.self, forKey: .role)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        includeInContext = try container.decodeIfPresent(Bool.self, forKey: .includeInContext) ?? true
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        thinking = try container.decodeIfPresent(String.self, forKey: .thinking) ?? ""
        state = try container.decodeIfPresent(StoredMessageState.self, forKey: .state) ?? .complete
        attachments = try container.decodeIfPresent([StoredAttachment].self, forKey: .attachments) ?? []
        activities = try container.decodeIfPresent([StoredActivity].self, forKey: .activities) ?? []
        sources = try container.decodeIfPresent([StoredSource].self, forKey: .sources) ?? []
        model = try container.decodeIfPresent(String.self, forKey: .model)
        apiContent = try container.decodeIfPresent([JSONValue].self, forKey: .apiContent) ?? []
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        toolExchanges = try container.decodeIfPresent([ToolExchange].self, forKey: .toolExchanges) ?? []
    }
}

enum StoredMessageState: Codable, Equatable, Sendable {
    case complete, cancelled, interrupted
    case refused(String), failed(String)

    /// `.streaming` is saved as `.interrupted` (the send-time save, or a crash).
    init(_ state: MessageState) {
        switch state {
        case .complete: self = .complete
        case .streaming: self = .interrupted
        case .cancelled: self = .cancelled
        case .refused(let message): self = .refused(message)
        case .failed(let message): self = .failed(message)
        }
    }

    /// `.interrupted` loads as `.cancelled`.
    var runtime: MessageState {
        switch self {
        case .complete: return .complete
        case .cancelled, .interrupted: return .cancelled
        case .refused(let message): return .refused(message)
        case .failed(let message): return .failed(message)
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, message }

    /// An unknown kind decodes as `.cancelled`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        switch kind {
        case "complete": self = .complete
        case "interrupted": self = .interrupted
        case "refused": self = .refused(message)
        case "failed": self = .failed(message)
        default: self = .cancelled
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .complete: try container.encode("complete", forKey: .kind)
        case .cancelled: try container.encode("cancelled", forKey: .kind)
        case .interrupted: try container.encode("interrupted", forKey: .kind)
        case .refused(let message):
            try container.encode("refused", forKey: .kind)
            try container.encode(message, forKey: .message)
        case .failed(let message):
            try container.encode("failed", forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }
}

struct StoredActivity: Codable, Equatable, Sendable {
    var id: String
    /// `ToolActivity.Kind.rawValue`.
    var kind: String
    var label: String
    var isDone: Bool
}

struct StoredSource: Codable, Equatable, Sendable {
    var title: String
    var url: URL
}

struct StoredAttachment: Codable, Sendable {
    var id: UUID
    var kind: AttachmentKind
    var displayName: String
    var badge: String
    var sourceURL: URL?
    var appBundleID: String?
    var byteCount: Int
    /// PNG, at most 128 px and `HistoryPolicy.maxThumbnailBytes`.
    var thumbnailPNG: Data?
    var payload: StoredPayload
}

enum StoredPayload: Codable, Sendable {
    /// Image (with its media type), PDF, or text too large to keep inline.
    case blob(BlobRef, mediaType: String?)
    /// Text under `HistoryPolicy.externalizeThresholdBytes`.
    case text(String)
    case webPage(title: String, url: URL)
    /// Not kept: already gone when saved, or an attachment History never stores (window pictures, selections).
    case unavailable

    private enum CodingKeys: String, CodingKey { case kind, blob, mediaType, text, title, url }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "blob":
            self = .blob(try container.decode(BlobRef.self, forKey: .blob),
                         mediaType: try container.decodeIfPresent(String.self, forKey: .mediaType))
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "webPage":
            self = .webPage(title: try container.decode(String.self, forKey: .title),
                            url: try container.decode(URL.self, forKey: .url))
        default:
            self = .unavailable
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .blob(let ref, let mediaType):
            try container.encode("blob", forKey: .kind)
            try container.encode(ref, forKey: .blob)
            try container.encodeIfPresent(mediaType, forKey: .mediaType)
        case .text(let text):
            try container.encode("text", forKey: .kind)
            try container.encode(text, forKey: .text)
        case .webPage(let title, let url):
            try container.encode("webPage", forKey: .kind)
            try container.encode(title, forKey: .title)
            try container.encode(url, forKey: .url)
        case .unavailable:
            try container.encode("unavailable", forKey: .kind)
        }
    }
}
