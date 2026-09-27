//
//  BlobExternalizer.swift
//  Otto
//
//  Moves large image and document payloads out of stored API content into content-addressed blobs, and
//  puts them back on load. Pure and thread-safe.
//

import CryptoKit
import Foundation

/// A blob the store still has to write.
struct PendingBlob: Sendable {
    let ref: BlobRef
    let data: Data
}

enum BlobExternalizer {
    /// Key of the object that replaces an externalized `source.data` string. The Messages API only ever puts a
    /// string in `source.data`, so an object there is unambiguous.
    static let markerKey = "otto_blob"

    /// Replaces large `source.data` strings of `image`/`document` blocks, at any depth, with blob markers.
    /// Returns the new content and the blobs to write (one per distinct digest).
    static func externalize(_ content: [JSONValue], threshold: Int) -> (content: [JSONValue], blobs: [PendingBlob]) {
        var blobs: [String: PendingBlob] = [:]
        let result = content.map { externalized($0, threshold: threshold, blobs: &blobs) }
        return (result, blobs.keys.sorted().compactMap { blobs[$0] })
    }

    /// Replaces markers with payload strings. `read` returns nil when the blob is gone; for each block whose blob
    /// is missing, `onMissing` decides the replacement (nil drops the block).
    static func rehydrate(_ content: [JSONValue],
                          read: (BlobRef) -> Data?,
                          onMissing: (_ block: JSONValue) -> JSONValue?) -> (content: [JSONValue], missing: Int) {
        var missing = 0
        let result = content.compactMap { rehydrated($0, read: read, onMissing: onMissing, missing: &missing) }
        return (result, missing)
    }

    /// Every blob a stored message references (API content markers and attachment payloads).
    static func refs(in message: StoredMessage) -> Set<BlobRef> {
        var refs = Set<BlobRef>()
        for block in message.apiContent { collectRefs(in: block, into: &refs) }
        for attachment in message.attachments {
            if case .blob(let ref, _) = attachment.payload { refs.insert(ref) }
        }
        return refs
    }

    /// SHA-256 of `data` as 64 lowercase hex characters.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The blob for a payload string: base64 text is stored decoded when it re-encodes to exactly the same
    /// string (so a round trip is byte-identical); anything else is stored as UTF-8.
    static func blob(forPayload string: String, preferBase64: Bool) -> PendingBlob {
        if preferBase64, let decoded = Data(base64Encoded: string), decoded.base64EncodedString() == string {
            let ref = BlobRef(sha256: sha256Hex(decoded), encoding: .base64, bytes: Int64(decoded.count))
            return PendingBlob(ref: ref, data: decoded)
        }
        let data = Data(string.utf8)
        return PendingBlob(ref: BlobRef(sha256: sha256Hex(data), encoding: .utf8, bytes: Int64(data.count)), data: data)
    }

    /// The payload string a blob stands for, or nil when the bytes aren't valid for its encoding.
    static func payloadString(_ data: Data, encoding: BlobRef.Encoding) -> String? {
        switch encoding {
        case .base64: return data.base64EncodedString()
        case .utf8: return String(data: data, encoding: .utf8)
        }
    }

    /// The ref inside a marker object, if `value` is one.
    static func markerRef(_ value: JSONValue) -> BlobRef? {
        guard let marker = value[markerKey]?.objectValue,
              let sha = marker["sha256"]?.stringValue,
              let encodingName = marker["encoding"]?.stringValue,
              let encoding = BlobRef.Encoding(rawValue: encodingName),
              let bytes = marker["bytes"]?.intValue else { return nil }
        return BlobRef(sha256: sha, encoding: encoding, bytes: Int64(bytes))
    }

    static func marker(for ref: BlobRef) -> JSONValue {
        [markerKey: ["sha256": .string(ref.sha256), "encoding": .string(ref.encoding.rawValue), "bytes": .int(ref.bytes)]]
    }

    // MARK: - Private

    private static func isPayloadBlock(_ value: JSONValue) -> Bool {
        value.typeName == "image" || value.typeName == "document"
    }

    private static func externalized(_ value: JSONValue, threshold: Int, blobs: inout [String: PendingBlob]) -> JSONValue {
        switch value {
        case .array(let items):
            return .array(items.map { externalized($0, threshold: threshold, blobs: &blobs) })
        case .object(var object):
            if isPayloadBlock(value), case .object(var source)? = object["source"],
               let data = source["data"]?.stringValue, data.utf8.count >= threshold {
                let pending = blob(forPayload: data, preferBase64: source["type"]?.stringValue != "text")
                blobs[pending.ref.sha256] = blobs[pending.ref.sha256] ?? pending
                source["data"] = marker(for: pending.ref)
                object["source"] = .object(source)
                return .object(object)
            }
            for (key, child) in object {
                object[key] = externalized(child, threshold: threshold, blobs: &blobs)
            }
            return .object(object)
        default:
            return value
        }
    }

    private static func rehydrated(_ value: JSONValue, read: (BlobRef) -> Data?,
                                   onMissing: (JSONValue) -> JSONValue?, missing: inout Int) -> JSONValue? {
        switch value {
        case .array(let items):
            return .array(items.compactMap { rehydrated($0, read: read, onMissing: onMissing, missing: &missing) })
        case .object(var object):
            if case .object(var source)? = object["source"], let data = source["data"], let ref = markerRef(data) {
                guard ref.isWellFormed, let bytes = read(ref), let payload = payloadString(bytes, encoding: ref.encoding) else {
                    missing += 1
                    return onMissing(value)
                }
                source["data"] = .string(payload)
                object["source"] = .object(source)
                return .object(object)
            }
            for (key, child) in object {
                object[key] = rehydrated(child, read: read, onMissing: onMissing, missing: &missing)
            }
            return .object(object)
        default:
            return value
        }
    }

    private static func collectRefs(in value: JSONValue, into refs: inout Set<BlobRef>) {
        switch value {
        case .array(let items):
            items.forEach { collectRefs(in: $0, into: &refs) }
        case .object(let object):
            if let ref = markerRef(value) {
                refs.insert(ref)
                return
            }
            object.values.forEach { collectRefs(in: $0, into: &refs) }
        default:
            break
        }
    }
}
