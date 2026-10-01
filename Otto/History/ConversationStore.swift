//
//  ConversationStore.swift
//  Otto
//
//  Saved conversations on disk: one JSON file per conversation in Conversations.noindex, an index that
//  rebuilds itself, content-addressed payload blobs in Attachments.noindex, and a Damaged folder for
//  files Otto can't read. All work runs on one serial queue; every file goes through SecureFile. The
//  in-memory location has the same behavior for tests, snapshots and the self-test.
//

import Darwin
import Foundation
import os

struct ConversationSummary: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var preview: String
    /// Plain text of every message, capped at `HistoryPolicy.searchTextLimit`.
    var searchText: String
    var createdAt: Date
    var updatedAt: Date
    var messageCount: Int
    var attachmentCount: Int
    var model: String?
    /// Blob digest → bytes on disk.
    var blobs: [String: Int64]
    var fileBytes: Int64
    var fileModifiedAt: Date
}

struct HistoryStorageUsage: Equatable, Sendable {
    var conversationCount: Int
    var conversationBytes: Int64
    var attachmentBytes: Int64
    /// Files saved by a newer Otto: hidden, never modified, still pruned and deleted.
    var newerVersionCount: Int
    /// Files moved to Damaged/ (never deleted automatically).
    var damagedCount: Int
    var totalBytes: Int64 { conversationBytes + attachmentBytes }
}

enum HistoryStoreError: LocalizedError, Equatable {
    case notFound, damaged, newerVersion, tooLarge, diskFull, io(String)

    /// Completes "Otto couldn't save your latest conversation: …" and similar lines.
    var errorDescription: String? {
        switch self {
        case .notFound: return "the conversation is no longer on this \(OttoDevice.name)"
        case .damaged: return "the file may be damaged"
        case .newerVersion: return "a newer version of Otto saved it"
        case .tooLarge: return "the file is too large to open"
        case .diskFull: return "the disk is full"
        case .io(let reason): return reason
        }
    }
}

/// Thread-safe file store. Work runs on one private serial queue in the order it was enqueued; the async
/// methods wrap the `enqueue…` ones. `flush()` drains the queue synchronously.
final class ConversationStore: @unchecked Sendable {
    enum Location: Sendable { case directory(URL), inMemory }

    /// nil for `.inMemory`. For `.directory`, the Otto root that holds Conversations.noindex and Attachments.noindex.
    var rootURL: URL? { root }

    init(location: Location, policy: HistoryPolicy = .standard) {
        self.policy = policy
        switch location {
        case .directory(let url):
            root = url
            backend = HistoryDiskBackend(root: url, maxFileBytes: policy.maxConversationFileBytes)
        case .inMemory:
            root = nil
            backend = HistoryMemoryBackend(maxFileBytes: policy.maxConversationFileBytes)
        }
    }

    /// Why the store fell back to memory for this session (its folder was unsafe or couldn't be created).
    var fallbackReason: String? { lock.withLock { unsafeFallbackReason } }

    // MARK: - Async API

    /// Validates the index against the files (§3.6 of history.md), rebuilding what changed. Newest first.
    func loadIndex() async -> [ConversationSummary] {
        await withCheckedContinuation { continuation in enqueueLoadIndex { continuation.resume(returning: $0) } }
    }

    func save(_ snapshot: ConversationSnapshot) async throws -> ConversationSummary {
        try await withCheckedThrowingContinuation { continuation in
            enqueueSave(snapshot) { continuation.resume(with: $0) }
        }
    }

    func load(id: UUID) async throws -> LoadedConversation {
        try await withCheckedThrowingContinuation { continuation in
            enqueueLoad(id: id) { continuation.resume(with: $0) }
        }
    }

    func delete(ids: Set<UUID>) async {
        await withCheckedContinuation { continuation in enqueueDelete(ids: ids) { continuation.resume() } }
    }

    /// Removes both data folders (including newer-version and damaged files) and recreates them empty.
    func deleteAll() async throws {
        try await withCheckedThrowingContinuation { continuation in
            enqueueDeleteAll { continuation.resume(with: $0) }
        }
    }

    /// Deletes conversations updated before `cutoff`, except `protected`. Returns the deleted ids.
    func prune(updatedBefore cutoff: Date, protected: Set<UUID>) async -> Set<UUID> {
        await withCheckedContinuation { continuation in
            enqueuePrune(updatedBefore: cutoff, protected: protected) { continuation.resume(returning: $0) }
        }
    }

    /// Deletes every blob `HistoryPolicy.blobsToKeep` doesn't keep, using the index's blob maps.
    func collectGarbage(protectedBlobs: Set<String>, now: Date) async {
        await withCheckedContinuation { continuation in
            enqueueCollectGarbage(protectedBlobs: protectedBlobs, now: now) { continuation.resume() }
        }
    }

    func usage() async -> HistoryStorageUsage {
        await withCheckedContinuation { continuation in enqueueUsage { continuation.resume(returning: $0) } }
    }

    /// Waits for queued work and writes a pending index now (applicationWillTerminate).
    func flush() {
        queue.sync { writeIndexIfDirty() }
    }

    // MARK: - Enqueueing (ordered by call)

    func enqueueLoadIndex(completion: @escaping @Sendable ([ConversationSummary]) -> Void) {
        queue.async { completion(self.loadIndexOnQueue()) }
    }

    /// A later save of the same conversation supersedes this one while it waits; both completions then receive
    /// the later save's result.
    func enqueueSave(_ snapshot: ConversationSnapshot,
                     completion: @escaping @Sendable (Result<ConversationSummary, Error>) -> Void) {
        let generation = lock.withLock { () -> Int in
            let next = (requestedGenerations[snapshot.id] ?? 0) + 1
            requestedGenerations[snapshot.id] = next
            return next
        }
        queue.async { self.saveOnQueue(snapshot, generation: generation, completion: completion) }
    }

    func enqueueLoad(id: UUID, completion: @escaping @Sendable (Result<LoadedConversation, Error>) -> Void) {
        queue.async { completion(Result { try self.loadOnQueue(id: id) }) }
    }

    func enqueueDelete(ids: Set<UUID>, completion: @escaping @Sendable () -> Void) {
        queue.async {
            self.deleteOnQueue(ids)
            completion()
        }
    }

    func enqueueDeleteAll(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { completion(Result { try self.deleteAllOnQueue() }) }
    }

    func enqueuePrune(updatedBefore cutoff: Date, protected: Set<UUID>,
                      completion: @escaping @Sendable (Set<UUID>) -> Void) {
        queue.async { completion(self.pruneOnQueue(before: cutoff, protected: protected)) }
    }

    func enqueueCollectGarbage(protectedBlobs: Set<String>, now: Date, completion: @escaping @Sendable () -> Void) {
        queue.async {
            self.collectGarbageOnQueue(protectedBlobs: protectedBlobs, now: now)
            completion()
        }
    }

    func enqueueUsage(completion: @escaping @Sendable (HistoryStorageUsage) -> Void) {
        queue.async { completion(self.usageOnQueue()) }
    }

    /// Test seam: puts raw bytes where a conversation file goes, as another build of Otto (or damage) would.
    /// The index notices at the next `loadIndex()`; `load(id:)` reads the bytes right away.
    func debugPlaceRawFile(_ data: Data, id: UUID) throws {
        try queue.sync { try currentBackend().placeRawConversation(data, id: id) }
    }

    // MARK: - State (queue-confined unless noted)

    private let root: URL?
    private let policy: HistoryPolicy
    private let queue = DispatchQueue(label: "com.jalenedusei.otto.history", qos: .utility)
    private var backend: HistoryStoreBackend
    private var summaries: [UUID: ConversationSummary] = [:]
    private var hiddenFiles: [UUID: HiddenFile] = [:]
    private var indexLoaded = false
    private var indexDirty = false
    private var indexWriteScheduled = false
    private var memos: [UUID: [UUID: ConversationCodec.EncodedMessage]] = [:]
    private var memoOrder: [UUID] = []
    private var supersededCompletions: [UUID: [@Sendable (Result<ConversationSummary, Error>) -> Void]] = [:]

    /// Guarded by `lock`: touched by callers on any thread.
    private let lock = NSLock()
    private var requestedGenerations: [UUID: Int] = [:]
    private var unsafeFallbackReason: String?

    /// A file Recents doesn't list but retention and Delete All still remove.
    private struct HiddenFile {
        var date: Date
        var bytes: Int64
        var isNewerVersion: Bool
    }

    private enum ReadOutcome {
        case record(StoredConversation)
        case newer(updatedAt: Date?)
    }

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "History")
    private static let indexVersion = 1
    private static let memoLimit = 3
    private static let indexDebounce: TimeInterval = 0.5
    private static let staleTemporaryAge: TimeInterval = 3600

    private static let appVersion: String? = {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return nil }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }()

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.dataEncodingStrategy = .base64
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        decoder.dataDecodingStrategy = .base64
        return decoder
    }

    private struct IndexFile: Codable {
        var indexVersion: Int
        var conversations: [ConversationSummary]
    }

    // MARK: - Queue work

    /// The disk backend after its folders pass the AppSupport checks, or memory for the rest of the session
    /// when they don't.
    private func currentBackend() -> HistoryStoreBackend {
        do {
            try backend.prepare()
        } catch {
            let reason = "Otto couldn't use its data folder"
            Self.logger.fault("History folder refused, keeping history in memory: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            lock.withLock { unsafeFallbackReason = reason }
            backend = HistoryMemoryBackend(maxFileBytes: policy.maxConversationFileBytes)
            summaries = [:]
            hiddenFiles = [:]
            memos = [:]
            memoOrder = []
            indexLoaded = true
        }
        return backend
    }

    private func ensureIndexLoaded() {
        if !indexLoaded { _ = loadIndexOnQueue() }
    }

    private func loadIndexOnQueue() -> [ConversationSummary] {
        let backend = currentBackend()
        backend.removeStaleTemporaryFiles(olderThan: Self.staleTemporaryAge)
        let files: [HistoryFileInfo]
        do {
            files = try backend.listConversations()
        } catch {
            Self.logger.error("Couldn't list conversations: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            files = []
        }

        var cached: [UUID: ConversationSummary]?
        if let data = backend.readIndex(), let index = try? Self.makeDecoder().decode(IndexFile.self, from: data),
           index.indexVersion == Self.indexVersion {
            cached = Dictionary(index.conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        var changed = cached == nil
        var next: [UUID: ConversationSummary] = [:]
        var hidden: [UUID: HiddenFile] = [:]
        var rebuilt = 0

        for file in files {
            if let summary = cached?[file.id], summary.fileBytes == file.bytes,
               abs(summary.fileModifiedAt.timeIntervalSince(file.modifiedAt)) < 0.001 {
                next[file.id] = summary
                continue
            }
            changed = true
            do {
                switch try readRecord(id: file.id, backend: backend) {
                case .record(let record):
                    next[file.id] = ConversationCodec.summary(of: record, fileBytes: file.bytes,
                                                              fileModifiedAt: file.modifiedAt, policy: policy)
                    rebuilt += 1
                case .newer(let updatedAt):
                    hidden[file.id] = HiddenFile(date: updatedAt ?? file.modifiedAt, bytes: file.bytes, isNewerVersion: true)
                }
            } catch HistoryStoreError.tooLarge {
                hidden[file.id] = HiddenFile(date: file.modifiedAt, bytes: file.bytes, isNewerVersion: false)
            } catch HistoryStoreError.damaged {
                backend.quarantine(file.id)
            } catch {
                Self.logger.error("Couldn't read conversation \(file.id.uuidString, privacy: .public): \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
        }
        if let cached, cached.keys.contains(where: { next[$0] == nil }) { changed = true }

        summaries = next
        hiddenFiles = hidden
        indexLoaded = true
        if changed {
            indexDirty = true
            writeIndexIfDirty()
        }
        if rebuilt > 0 {
            Self.logger.info("Re-read \(rebuilt, privacy: .public) conversation files for the index")
        }
        return sortedSummaries()
    }

    private func sortedSummaries() -> [ConversationSummary] {
        summaries.values.sorted { lhs, rhs in
            lhs.updatedAt != rhs.updatedAt ? lhs.updatedAt > rhs.updatedAt : lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func readRecord(id: UUID, backend: HistoryStoreBackend) throws -> ReadOutcome {
        let data = try backend.readConversation(id)
        let decoder = Self.makeDecoder()
        guard let probe = try? decoder.decode(ConversationSchema.VersionProbe.self, from: data) else {
            throw HistoryStoreError.damaged
        }
        if probe.schemaVersion > ConversationSchema.current { return .newer(updatedAt: probe.updatedAt) }

        let record: StoredConversation
        do {
            if probe.schemaVersion == ConversationSchema.current {
                record = try decoder.decode(StoredConversation.self, from: data)
            } else {
                let json = try JSONValue.decode(data)
                let migrated = try ConversationSchema.migrate(json, from: probe.schemaVersion)
                record = try decoder.decode(StoredConversation.self, from: try migrated.encodedData())
            }
        } catch {
            throw HistoryStoreError.damaged
        }
        guard record.id == id else { throw HistoryStoreError.damaged }
        return .record(record)
    }

    private func saveOnQueue(_ snapshot: ConversationSnapshot, generation: Int,
                             completion: @escaping @Sendable (Result<ConversationSummary, Error>) -> Void) {
        let latest = lock.withLock { requestedGenerations[snapshot.id] ?? generation }
        guard latest == generation else {
            supersededCompletions[snapshot.id, default: []].append(completion)
            return
        }
        let backend = currentBackend()
        ensureIndexLoaded()

        var memo = memos[snapshot.id] ?? [:]
        let (record, blobs) = ConversationCodec.encode(snapshot, policy: policy, appVersion: Self.appVersion,
                                                       memo: &memo, blobExists: { backend.hasBlob($0.sha256) })
        let result: Result<ConversationSummary, Error>
        do {
            for blob in blobs { try backend.writeBlob(blob.data, sha: blob.ref.sha256) }
            let data = try Self.makeEncoder().encode(record)
            let info = try backend.writeConversation(data, id: snapshot.id)
            let summary = ConversationCodec.summary(of: record, fileBytes: info.bytes, fileModifiedAt: info.modifiedAt,
                                                    policy: policy)
            summaries[snapshot.id] = summary
            hiddenFiles[snapshot.id] = nil
            rememberMemo(memo, for: snapshot.id)
            scheduleIndexWrite()
            result = .success(summary)
        } catch {
            let mapped = Self.mapped(error)
            Self.logger.error("Couldn't save conversation \(snapshot.id.uuidString, privacy: .public): \(LoggedError(mapped), privacy: .public) \(mapped.localizedDescription, privacy: .private)")
            result = .failure(mapped)
        }
        completion(result)
        for waiting in supersededCompletions.removeValue(forKey: snapshot.id) ?? [] { waiting(result) }
    }

    private func loadOnQueue(id: UUID) throws -> LoadedConversation {
        let backend = currentBackend()
        ensureIndexLoaded()
        if hiddenFiles[id]?.isNewerVersion == true { throw HistoryStoreError.newerVersion }
        do {
            switch try readRecord(id: id, backend: backend) {
            case .record(let record):
                return ConversationCodec.decode(record) { ref in backend.readBlob(ref.sha256) }
            case .newer:
                throw HistoryStoreError.newerVersion
            }
        } catch HistoryStoreError.damaged {
            backend.quarantine(id)
            summaries[id] = nil
            memos[id] = nil
            scheduleIndexWrite()
            Self.logger.error("Moved damaged conversation \(id.uuidString, privacy: .public) to Damaged")
            throw HistoryStoreError.damaged
        } catch {
            throw Self.mapped(error)
        }
    }

    private func deleteOnQueue(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let backend = currentBackend()
        ensureIndexLoaded()
        for id in ids {
            backend.removeConversation(id)
            summaries[id] = nil
            hiddenFiles[id] = nil
            memos[id] = nil
        }
        memoOrder.removeAll { ids.contains($0) }
        scheduleIndexWrite()
        Self.logger.info("Deleted \(ids.count, privacy: .public) conversations")
    }

    private func deleteAllOnQueue() throws {
        let backend = currentBackend()
        summaries = [:]
        hiddenFiles = [:]
        memos = [:]
        memoOrder = []
        indexDirty = false
        indexLoaded = true
        do {
            try backend.removeAll()
        } catch {
            let mapped = Self.mapped(error)
            Self.logger.error("Couldn't delete all history: \(LoggedError(mapped), privacy: .public) \(mapped.localizedDescription, privacy: .private)")
            indexLoaded = false
            throw mapped
        }
        Self.logger.info("Deleted all history")
    }

    private func pruneOnQueue(before cutoff: Date, protected: Set<UUID>) -> Set<UUID> {
        _ = currentBackend()
        ensureIndexLoaded()
        var expired = Set(summaries.values.filter { $0.updatedAt < cutoff }.map(\.id))
        expired.formUnion(hiddenFiles.filter { $0.value.date < cutoff }.map(\.key))
        expired.subtract(protected)
        deleteOnQueue(expired)
        return expired
    }

    private func collectGarbageOnQueue(protectedBlobs: Set<String>, now: Date) {
        let backend = currentBackend()
        ensureIndexLoaded()
        var usage: [HistoryPolicy.BlobUsage] = []
        for summary in summaries.values {
            for (sha, bytes) in summary.blobs {
                usage.append(HistoryPolicy.BlobUsage(sha256: sha, bytes: bytes, lastUsed: summary.updatedAt))
            }
        }
        let budget = policy.payloadBudget(availableBytes: backend.availableCapacity())
        let keep = HistoryPolicy.blobsToKeep(usage, protected: protectedBlobs, now: now,
                                             window: policy.payloadWindow, budget: budget)
        var removed = 0
        for sha in backend.listBlobs().keys where !keep.contains(sha) {
            backend.removeBlob(sha)
            removed += 1
        }
        if removed > 0 { Self.logger.info("Removed \(removed, privacy: .public) attachment blobs") }
    }

    private func usageOnQueue() -> HistoryStorageUsage {
        let backend = currentBackend()
        ensureIndexLoaded()
        let conversationBytes = summaries.values.reduce(Int64(0)) { $0 + $1.fileBytes }
            + hiddenFiles.values.reduce(Int64(0)) { $0 + $1.bytes }
        return HistoryStorageUsage(
            conversationCount: summaries.count,
            conversationBytes: conversationBytes,
            attachmentBytes: backend.listBlobs().values.reduce(0, +),
            newerVersionCount: hiddenFiles.values.filter(\.isNewerVersion).count,
            damagedCount: backend.damagedCount()
        )
    }

    private func rememberMemo(_ memo: [UUID: ConversationCodec.EncodedMessage], for id: UUID) {
        memos[id] = memo
        memoOrder.removeAll { $0 == id }
        memoOrder.append(id)
        while memoOrder.count > Self.memoLimit {
            memos[memoOrder.removeFirst()] = nil
        }
    }

    private func scheduleIndexWrite() {
        indexDirty = true
        guard !indexWriteScheduled else { return }
        indexWriteScheduled = true
        queue.asyncAfter(deadline: .now() + Self.indexDebounce) { [weak self] in
            guard let self else { return }
            self.indexWriteScheduled = false
            self.writeIndexIfDirty()
        }
    }

    private func writeIndexIfDirty() {
        guard indexDirty, indexLoaded else { return }
        indexDirty = false
        do {
            let file = IndexFile(indexVersion: Self.indexVersion, conversations: sortedSummaries())
            try backend.writeIndex(try Self.makeEncoder().encode(file))
        } catch {
            Self.logger.error("Couldn't write the history index: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    private static func mapped(_ error: Error) -> HistoryStoreError {
        if let error = error as? HistoryStoreError { return error }
        if let error = error as? POSIXError, error.code == .ENOSPC || error.code == .EDQUOT { return .diskFull }
        if let error = error as? CocoaError, error.code == .fileWriteOutOfSpace { return .diskFull }
        if let error = error as? AppSupportError {
            switch error {
            case .unsafePath, .notCreatable: return .io("Otto couldn't use its data folder")
            }
        }
        return .io(error.localizedDescription)
    }
}

// MARK: - Backends

private struct HistoryFileInfo {
    var id: UUID
    var bytes: Int64
    var modifiedAt: Date
}

/// Where the store's bytes live. Called only on the store's queue.
private protocol HistoryStoreBackend: AnyObject {
    /// Checks (and creates) the folders; throws when they can't be used safely.
    func prepare() throws
    func listConversations() throws -> [HistoryFileInfo]
    func readConversation(_ id: UUID) throws -> Data
    func writeConversation(_ data: Data, id: UUID) throws -> HistoryFileInfo
    func placeRawConversation(_ data: Data, id: UUID) throws
    func removeConversation(_ id: UUID)
    /// Moves an unreadable file aside; it is never deleted automatically.
    func quarantine(_ id: UUID)
    func damagedCount() -> Int
    func readIndex() -> Data?
    func writeIndex(_ data: Data) throws
    func hasBlob(_ sha: String) -> Bool
    /// The blob's bytes, or nil when it is missing or doesn't match its digest.
    func readBlob(_ sha: String) -> Data?
    func writeBlob(_ data: Data, sha: String) throws
    func removeBlob(_ sha: String)
    func listBlobs() -> [String: Int64]
    func removeAll() throws
    func availableCapacity() -> Int64?
    func removeStaleTemporaryFiles(olderThan age: TimeInterval)
}

private final class HistoryDiskBackend: HistoryStoreBackend {
    private let root: URL
    private let maxFileBytes: Int
    private let conversations: URL
    private let damaged: URL
    private let attachments: URL
    private static let indexName = "index.json"
    private static let maxIndexBytes = 64 * 1024 * 1024

    init(root: URL, maxFileBytes: Int) {
        self.root = root
        self.maxFileBytes = maxFileBytes
        conversations = root.appendingPathComponent(AppSupport.Directory.conversations.rawValue, isDirectory: true)
        damaged = conversations.appendingPathComponent("Damaged", isDirectory: true)
        attachments = root.appendingPathComponent(AppSupport.Directory.attachments.rawValue, isDirectory: true)
    }

    func prepare() throws {
        _ = try AppSupport.secureDirectory(root)
        _ = try AppSupport.secureDirectory(conversations)
        _ = try AppSupport.secureDirectory(attachments)
    }

    func listConversations() throws -> [HistoryFileInfo] {
        try FileManager.default.contentsOfDirectory(atPath: conversations.path).compactMap { name in
            guard name.hasSuffix(".json"), name != Self.indexName else { return nil }
            let stem = String(name.dropLast(5))
            guard let id = UUID(uuidString: stem), id.uuidString == stem else { return nil }
            return Self.regularFileInfo(conversationURL(id)).map { HistoryFileInfo(id: id, bytes: $0.bytes, modifiedAt: $0.modifiedAt) }
        }
    }

    func readConversation(_ id: UUID) throws -> Data {
        let url = conversationURL(id)
        guard let info = Self.regularFileInfo(url) else { throw HistoryStoreError.notFound }
        guard info.bytes <= Int64(maxFileBytes) else { throw HistoryStoreError.tooLarge }
        return try Data(contentsOf: url)
    }

    func writeConversation(_ data: Data, id: UUID) throws -> HistoryFileInfo {
        let url = conversationURL(id)
        try SecureFile.write(data, to: url)
        let info = Self.regularFileInfo(url)
        return HistoryFileInfo(id: id, bytes: info?.bytes ?? Int64(data.count), modifiedAt: info?.modifiedAt ?? Date())
    }

    func placeRawConversation(_ data: Data, id: UUID) throws {
        try SecureFile.write(data, to: conversationURL(id))
    }

    func removeConversation(_ id: UUID) {
        let url = conversationURL(id)
        if unlink(url.path) != 0, errno != ENOENT {
            Self.logger.error("Couldn't delete conversation \(id.uuidString, privacy: .public): errno \(errno, privacy: .public)")
        }
    }

    func quarantine(_ id: UUID) {
        let source = conversationURL(id)
        do {
            _ = try AppSupport.secureDirectory(damaged)
            var destination = damaged.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                let stamp = Int(Date().timeIntervalSince1970)
                destination = damaged.appendingPathComponent("\(id.uuidString)-\(stamp)-\(UUID().uuidString.prefix(8)).json")
            }
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            Self.logger.error("Couldn't move damaged conversation \(id.uuidString, privacy: .public): \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    func damagedCount() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: damaged.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.count
    }

    func readIndex() -> Data? {
        let url = conversations.appendingPathComponent(Self.indexName)
        guard let info = Self.regularFileInfo(url), info.bytes <= Int64(Self.maxIndexBytes) else { return nil }
        return try? Data(contentsOf: url)
    }

    func writeIndex(_ data: Data) throws {
        try SecureFile.write(data, to: conversations.appendingPathComponent(Self.indexName))
    }

    func hasBlob(_ sha: String) -> Bool {
        guard let url = blobURL(sha) else { return false }
        return Self.regularFileInfo(url) != nil
    }

    func readBlob(_ sha: String) -> Data? {
        guard let url = blobURL(sha), Self.regularFileInfo(url) != nil,
              let data = try? Data(contentsOf: url), BlobExternalizer.sha256Hex(data) == sha else { return nil }
        return data
    }

    func writeBlob(_ data: Data, sha: String) throws {
        guard let url = blobURL(sha) else { throw HistoryStoreError.io("invalid attachment digest") }
        _ = try AppSupport.secureDirectory(url.deletingLastPathComponent())
        try SecureFile.writeIfAbsent(data, to: url)
    }

    func removeBlob(_ sha: String) {
        guard let url = blobURL(sha) else { return }
        if unlink(url.path) != 0, errno != ENOENT {
            Self.logger.error("Couldn't delete an attachment blob: errno \(errno, privacy: .public)")
        }
    }

    func listBlobs() -> [String: Int64] {
        var blobs: [String: Int64] = [:]
        let fanOuts = (try? FileManager.default.contentsOfDirectory(atPath: attachments.path)) ?? []
        for fanOut in fanOuts where fanOut.utf8.count == 2 {
            let folder = attachments.appendingPathComponent(fanOut, isDirectory: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                guard BlobRef.isValidDigest(name), name.hasPrefix(fanOut),
                      let info = Self.regularFileInfo(folder.appendingPathComponent(name)) else { continue }
                blobs[name] = info.bytes
            }
        }
        return blobs
    }

    func removeAll() throws {
        for folder in [conversations, attachments] {
            var info = stat()
            guard lstat(folder.path, &info) == 0 else { continue }
            try FileManager.default.removeItem(at: folder)
        }
        try prepare()
    }

    func availableCapacity() -> Int64? {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    func removeStaleTemporaryFiles(olderThan age: TimeInterval) {
        var folders = [conversations]
        let fanOuts = (try? FileManager.default.contentsOfDirectory(atPath: attachments.path)) ?? []
        folders += fanOuts.filter { $0.utf8.count == 2 }.map { attachments.appendingPathComponent($0, isDirectory: true) }
        let cutoff = Date().addingTimeInterval(-age)
        for folder in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.hasPrefix(".") && name.hasSuffix(".tmp") {
                let url = folder.appendingPathComponent(name)
                if let info = Self.regularFileInfo(url), info.modifiedAt < cutoff { unlink(url.path) }
            }
        }
    }

    // MARK: Private

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "History")

    private func conversationURL(_ id: UUID) -> URL {
        conversations.appendingPathComponent("\(id.uuidString).json")
    }

    /// Attachments.noindex/ab/abcdef…; nil for a digest that isn't 64 lowercase hex characters.
    private func blobURL(_ sha: String) -> URL? {
        guard BlobRef.isValidDigest(sha) else { return nil }
        return attachments.appendingPathComponent(String(sha.prefix(2)), isDirectory: true).appendingPathComponent(sha)
    }

    /// Size and modification date of a regular file; nil for a missing file, a symlink or anything else.
    private static func regularFileInfo(_ url: URL) -> (bytes: Int64, modifiedAt: Date)? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        return (Int64(info.st_size), Date(timeIntervalSince1970: modified))
    }
}

private final class HistoryMemoryBackend: HistoryStoreBackend {
    private let maxFileBytes: Int
    private var files: [UUID: (data: Data, modifiedAt: Date)] = [:]
    private var damaged: [Data] = []
    private var index: Data?
    private var blobs: [String: Data] = [:]

    init(maxFileBytes: Int) {
        self.maxFileBytes = maxFileBytes
    }

    func prepare() throws {}

    func listConversations() throws -> [HistoryFileInfo] {
        files.map { HistoryFileInfo(id: $0.key, bytes: Int64($0.value.data.count), modifiedAt: $0.value.modifiedAt) }
    }

    func readConversation(_ id: UUID) throws -> Data {
        guard let file = files[id] else { throw HistoryStoreError.notFound }
        guard file.data.count <= maxFileBytes else { throw HistoryStoreError.tooLarge }
        return file.data
    }

    func writeConversation(_ data: Data, id: UUID) throws -> HistoryFileInfo {
        let now = Date()
        files[id] = (data, now)
        return HistoryFileInfo(id: id, bytes: Int64(data.count), modifiedAt: now)
    }

    func placeRawConversation(_ data: Data, id: UUID) throws {
        files[id] = (data, Date())
    }

    func removeConversation(_ id: UUID) {
        files[id] = nil
    }

    func quarantine(_ id: UUID) {
        if let file = files.removeValue(forKey: id) { damaged.append(file.data) }
    }

    func damagedCount() -> Int { damaged.count }

    func readIndex() -> Data? { index }

    func writeIndex(_ data: Data) throws { index = data }

    func hasBlob(_ sha: String) -> Bool { blobs[sha] != nil }

    func readBlob(_ sha: String) -> Data? { blobs[sha] }

    func writeBlob(_ data: Data, sha: String) throws {
        guard BlobRef.isValidDigest(sha) else { throw HistoryStoreError.io("invalid attachment digest") }
        if blobs[sha] == nil { blobs[sha] = data }
    }

    func removeBlob(_ sha: String) { blobs[sha] = nil }

    func listBlobs() -> [String: Int64] { blobs.mapValues { Int64($0.count) } }

    func removeAll() throws {
        files = [:]
        damaged = []
        index = nil
        blobs = [:]
    }

    func availableCapacity() -> Int64? { nil }

    func removeStaleTemporaryFiles(olderThan age: TimeInterval) {}
}
