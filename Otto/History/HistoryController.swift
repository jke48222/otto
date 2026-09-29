//
//  HistoryController.swift
//  Otto
//
//  Keeps conversations across ⌘N, idle time and relaunches: saves the transcript when a message is sent
//  and when a reply finishes, starts a fresh chat after an idle period with the old one offered as
//  "Continue", restores the latest conversation at launch, and handles delete with Undo, Delete All,
//  turning History off, retention and the reading position. Talks to ChatSession only through its
//  transcript surface (onTranscriptChanged, transcriptSnapshot, load, reset, cancel).
//

import AppKit
import Foundation
import Observation
import os

@MainActor @Observable final class HistoryController {
    init(settings: AppSettings, chat: ChatSession, store: ConversationStore,
         policy: HistoryPolicy = .standard, now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.chat = chat
        self.store = store
        self.policy = policy
        self.now = now
        summaries = []
        isIndexLoaded = false
        isOpeningConversation = false
        chat.onTranscriptChanged = { [weak self] change in
            self?.transcriptChanged(change)
        }
    }

    @ObservationIgnored let store: ConversationStore
    /// The clock every rule reads (injected by tests and the self-test).
    @ObservationIgnored let now: () -> Date

    /// Newest first, without a conversation whose deletion is pending.
    private(set) var summaries: [ConversationSummary]
    /// True once `start()` has read the index (the first-run notice waits for it).
    private(set) var isIndexLoaded: Bool
    /// The conversation the Continue chip offers.
    private(set) var continuation: ConversationSummary?
    /// Drives the Undo bar.
    private(set) var pendingDeletion: ConversationSummary?
    private(set) var storageUsage: HistoryStorageUsage?
    /// Shown in Settings.
    private(set) var lastSaveError: String?
    /// Transient error line after a conversation failed to open.
    private(set) var lastOpenError: String?
    /// Row spinner: true once opening has taken longer than 150 ms.
    private(set) var isOpeningConversation: Bool

    /// Always true: with History off, Recents explains "History is off" and Continue works from memory.
    var isAvailable: Bool { true }

    /// Last user activity in the current conversation (send, reply finished, engaged close, load).
    @ObservationIgnored private(set) var lastActivity: Date?

    /// Fired after data left the disk: `.conversations(ids)` when a row delete is committed or retention prunes;
    /// `.all` for Delete All History and for setEnabled(false). Wired by AppComposition (SPEC-v2 §6.12).
    @ObservationIgnored var onDataRemoved: ((HistoryRemoval) -> Void)?
    /// Called whenever `summaries` changes (RecentsState refreshes its rows).
    @ObservationIgnored var onSummariesChanged: (() -> Void)?

    /// The id of the conversation in the chat right now.
    var currentConversationID: UUID { chat.conversationID }

    // MARK: - Launch

    /// Launch: reads the index, prunes per retention, collects garbage, restores the latest conversation or offers
    /// it as the continuation (history.md §7.2), and starts the 6-hourly maintenance and the retention observation.
    /// Idempotent.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        let loaded = await withCheckedContinuation { continuation in
            store.enqueueLoadIndex { continuation.resume(returning: $0) }
        }
        let known = Set(loaded.map(\.id))
        let excluded = removedIDs.union(pendingDeletion.map { [$0.id] } ?? [])
        summaries = Self.newestFirst(loaded.filter { !excluded.contains($0.id) } + summaries.filter { !known.contains($0.id) })
        isIndexLoaded = true
        summariesDidChange()

        await applyRetention()
        await restoreLatestConversation()

        startMaintenance()
        let settings = self.settings
        retentionObservation = ObservationLoop(read: { settings.history.retention }) { [weak self] _ in
            Task { await self?.applyRetention() }
        }
    }

    // MARK: - Transcript

    /// ChatSession's single transcript observer (wired in init).
    func transcriptChanged(_ change: TranscriptChange) {
        switch change {
        case .userMessageAdded:
            // Sending in the new chat dismisses the Continue chip.
            dismissContinuation()
            lastActivity = now()
            saveCurrentConversation()
        case .turnFinished:
            lastActivity = now()
            saveCurrentConversation()
        case .messagesRemoved, .willReset:
            saveCurrentConversation()
        case .loaded:
            lastActivity = now()
            removedIDs.remove(chat.conversationID)
        }
    }

    // MARK: - Continuity

    /// Called by NotchViewModel.open before the presentation changes. Returns true when it started fresh.
    @discardableResult func startFreshIfIdle(hasUnreadReply: Bool, hasDraft: Bool) -> Bool {
        let context = HistoryPolicy.IdleContext(
            now: now(),
            lastActivity: lastActivity,
            interval: settings.history.idleReset,
            hasMessages: chat.messageCount > 0,
            isStreaming: chat.isStreaming,
            hasUnreadReply: hasUnreadReply,
            hasDraft: hasDraft
        )
        guard HistoryPolicy.shouldStartFresh(context) else { return false }
        Self.logger.info("Starting a fresh conversation after idle time")
        leaveCurrentConversation()
        return true
    }

    /// ⌘N: saves and resets the chat, offering the conversation just left as the continuation.
    func startNewConversation() {
        guard chat.messageCount > 0 || chat.isStreaming else {
            chat.reset()
            return
        }
        leaveCurrentConversation()
    }

    func continueConversation() async -> Bool {
        guard let target = continuation else { return false }
        return await open(target.id)
    }

    func dismissContinuation() {
        continuation = nil
        stash = nil
    }

    /// Send or engaged close.
    func noteActivity() {
        lastActivity = now()
        persistReadingPositionIfChanged()
    }

    /// Loads a conversation (from the in-memory stash when it matches, else from disk) into the chat. A running
    /// reply is stopped and saved as cancelled first. False, with `lastOpenError` set, when it couldn't be read.
    func open(_ id: UUID) async -> Bool {
        lastOpenError = nil
        if chat.conversationID == id, chat.messageCount > 0 {
            if continuation?.id == id { continuation = nil }
            return true
        }
        if let stash, stash.id == id {
            switchTo(stash)
            return true
        }
        guard pendingDeletion?.id != id else { return false }

        let indicator = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.isOpeningConversation = true
        }
        let result = await loadFromStore(id)
        indicator.cancel()
        isOpeningConversation = false

        switch result {
        case .success(let conversation):
            switchTo(conversation)
            return true
        case .failure(let error):
            Self.logger.error("Couldn't open conversation \(id.uuidString, privacy: .public): \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            lastOpenError = Self.openFailureMessage
            if let error = error as? HistoryStoreError, error == .damaged || error == .notFound {
                removeSummaries([id])
                if continuation?.id == id { continuation = nil }
                await refreshUsage()
            }
            return false
        }
    }

    // MARK: - Deletion

    /// Removes the row now and deletes it from disk after the Undo window (or at the next commit point). Commits
    /// an earlier pending deletion first. Deleting the current conversation empties the chat without saving it.
    func delete(_ id: UUID) {
        commitPendingDeletion()
        guard let index = summaries.firstIndex(where: { $0.id == id }) else { return }
        let summary = summaries.remove(at: index)
        pendingDeletion = summary
        deletionWasContinuation = continuation?.id == id
        if deletionWasContinuation { continuation = nil }

        if chat.conversationID == id, chat.messageCount > 0 {
            isDiscardingCurrent = true
            if chat.isStreaming { chat.cancel() }
            undoStash = loadedConversation(from: chat.transcriptSnapshot())
            chat.reset()
            isDiscardingCurrent = false
        } else if let stash, stash.id == id {
            undoStash = stash
        }
        summariesDidChange()

        let window = policy.undoWindow
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled, let self, self.pendingDeletion?.id == id else { return }
            self.commitPendingDeletion()
        }
    }

    func undoDelete() {
        guard let summary = pendingDeletion else { return }
        undoTask?.cancel()
        undoTask = nil
        pendingDeletion = nil
        summaries = Self.newestFirst(summaries + [summary])
        if deletionWasContinuation { continuation = summary }
        deletionWasContinuation = false
        if let conversation = undoStash, conversation.id == summary.id, chat.messageCount == 0, !chat.isStreaming {
            switchTo(conversation)
        }
        undoStash = nil
        summariesDidChange()
    }

    /// Deletes the pending row from disk now (notch close, page switch, Delete All, `flush()`).
    func commitPendingDeletion() {
        persistReadingPositionIfChanged()
        guard let summary = pendingDeletion else { return }
        undoTask?.cancel()
        undoTask = nil
        pendingDeletion = nil
        undoStash = nil
        deletionWasContinuation = false
        let ids: Set<UUID> = [summary.id]
        removedIDs.formUnion(ids)
        if stash?.id == summary.id { stash = nil }
        forget(ids)
        let generation = wipeGeneration
        store.enqueueDelete(ids: ids) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onDataRemoved?(.conversations(ids))
                guard generation == self.wipeGeneration else { return }
                await self.collectGarbage()
                await self.refreshUsage()
            }
        }
    }

    /// Settings → Delete All History (after its confirmation): empties the chat without saving it and wipes both
    /// data folders.
    func deleteAll() async {
        isDiscardingCurrent = true
        if chat.isStreaming { chat.cancel() }
        chat.reset()
        isDiscardingCurrent = false
        await wipe()
    }

    /// false: deletes everything saved and stops saving (the conversation on screen stays, in memory).
    /// true: saves the current conversation right away.
    func setEnabled(_ enabled: Bool) async {
        settings.history.enabled = enabled
        if enabled {
            saveCurrentConversation()
        } else {
            await wipe()
        }
    }

    /// Prunes conversations older than the retention, collects blobs and refreshes the usage line.
    func applyRetention() async {
        if let cutoff = HistoryPolicy.retentionCutoff(settings.history.retention, now: now()) {
            let protected = protectedIDs
            let pruned = await withCheckedContinuation { continuation in
                store.enqueuePrune(updatedBefore: cutoff, protected: protected) { continuation.resume(returning: $0) }
            }
            if !pruned.isEmpty {
                Self.logger.info("Retention removed \(pruned.count, privacy: .public) conversations")
                removedIDs.formUnion(pruned)
                forget(pruned)
                removeSummaries(pruned)
                if let continuation, pruned.contains(continuation.id) { self.continuation = nil }
                onDataRemoved?(.conversations(pruned))
            }
        }
        await collectGarbage()
        await refreshUsage()
    }

    /// How many conversations a shorter retention would delete now (for the confirmation copy).
    func countConversations(olderThan retention: HistoryRetention) -> Int {
        guard let cutoff = HistoryPolicy.retentionCutoff(retention, now: now()) else { return 0 }
        let protected = protectedIDs
        return summaries.filter { $0.updatedAt < cutoff && !protected.contains($0.id) }.count
    }

    // MARK: - Search

    func search(_ query: String) async -> [RecentsRow] {
        let rows = summaries
        let currentID = chat.conversationID
        return await Task.detached(priority: .userInitiated) {
            HistorySearch.run(query, in: rows, currentID: currentID)
        }.value
    }

    // MARK: - Reading position

    /// In memory for the current conversation; written with its next save.
    func noteReadingPosition(_ position: ReadingPosition) {
        readingPosition = (chat.conversationID, position)
    }

    var currentReadingPosition: ReadingPosition? {
        guard let readingPosition, readingPosition.id == chat.conversationID else { return nil }
        return readingPosition.position
    }

    /// One-shot, set by `open` / `continueConversation`.
    func takeReadingPositionToRestore() -> ReadingPosition? {
        defer { positionToRestore = nil }
        return positionToRestore
    }

    // MARK: - Maintenance

    func refreshUsage() async {
        storageUsage = await withCheckedContinuation { continuation in
            store.enqueueUsage { continuation.resume(returning: $0) }
        }
    }

    /// applicationWillTerminate: commits a pending deletion, enqueues a save of the current conversation and
    /// drains the store.
    func flush() {
        commitPendingDeletion()
        saveCurrentConversation()
        store.flush()
    }

    /// Snapshots and tests: shows these rows and chip without touching the store.
    func debugSeed(summaries: [ConversationSummary], continuation: ConversationSummary?) {
        self.summaries = Self.newestFirst(summaries)
        self.continuation = continuation
        summariesDidChange()
    }

    // MARK: - Private state

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let chat: ChatSession
    @ObservationIgnored private let policy: HistoryPolicy
    @ObservationIgnored private var hasStarted = false
    /// Full copy of the conversation just left (idle reset, ⌘N, opening another), so Continue is instant and works
    /// with History off.
    @ObservationIgnored private var stash: LoadedConversation?
    /// The current conversation while its deletion can still be undone.
    @ObservationIgnored private var undoStash: LoadedConversation?
    @ObservationIgnored private var deletionWasContinuation = false
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    /// Set while the chat is emptied on purpose (delete, Delete All), so the reset isn't saved.
    @ObservationIgnored private var isDiscardingCurrent = false
    @ObservationIgnored private var isWipingHistory = false
    /// Bumped by every wipe; work that started before one is dropped.
    @ObservationIgnored private var wipeGeneration = 0
    /// Deleted or pruned: late saves of these never bring them back.
    @ObservationIgnored private var removedIDs: Set<UUID> = []
    @ObservationIgnored private var titles: [UUID: String] = [:]
    @ObservationIgnored private var textOnlyContextIDs: [UUID: Set<UUID>] = [:]
    /// Attachment id → PNG thumbnail (nil when the image couldn't be rendered small enough).
    @ObservationIgnored private var thumbnailCache: [UUID: Data?] = [:]
    @ObservationIgnored private var readingPosition: (id: UUID, position: ReadingPosition)?
    @ObservationIgnored private var persistedReadingPositions: [UUID: ReadingPosition] = [:]
    @ObservationIgnored private var positionToRestore: ReadingPosition?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var retentionObservation: ObservationLoop<HistoryRetention>?

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "History")
    private static let openFailureMessage = "Couldn't open that conversation. The file may be damaged."
    private static let thumbnailPixels: CGFloat = 128

    /// Never pruned or collected: the chat, the stash and a deletion that can still be undone.
    private var protectedIDs: Set<UUID> {
        Set([chat.conversationID, stash?.id, pendingDeletion?.id, undoStash?.id].compactMap { $0 })
    }

    // MARK: - Private: saving

    private func saveCurrentConversation() {
        guard settings.history.enabled, !isWipingHistory, !isDiscardingCurrent else { return }
        let transcript = chat.transcriptSnapshot()
        guard !transcript.messages.isEmpty, !removedIDs.contains(transcript.conversationID) else { return }

        let snapshot = ConversationSnapshot(
            id: transcript.conversationID,
            createdAt: transcript.createdAt,
            updatedAt: now(),
            title: title(for: transcript.conversationID, messages: transcript.messages),
            messages: transcript.messages,
            thumbnails: thumbnails(for: transcript.messages),
            unavailableAttachmentIDs: transcript.unavailableAttachmentIDs,
            readingPosition: readingPosition(for: transcript.conversationID)
        )
        if let position = snapshot.readingPosition { persistedReadingPositions[snapshot.id] = position }
        let generation = wipeGeneration
        store.enqueueSave(snapshot) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.finishSave(result, generation: generation)
            }
        }
    }

    private func finishSave(_ result: Result<ConversationSummary, Error>, generation: Int) {
        guard generation == wipeGeneration else { return }
        switch result {
        case .success(let summary):
            if let reason = store.fallbackReason {
                lastSaveError = "\(reason), so conversations are kept only until Otto quits."
            } else {
                lastSaveError = nil
            }
            guard !removedIDs.contains(summary.id), pendingDeletion?.id != summary.id else { return }
            upsert(summary)
        case .failure(let error):
            lastSaveError = "Otto couldn't save your latest conversation: \(error.localizedDescription)."
            Self.logger.error("Save failed: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    private func persistReadingPositionIfChanged() {
        guard let readingPosition, readingPosition.id == chat.conversationID, chat.messageCount > 0,
              !chat.isStreaming, persistedReadingPositions[readingPosition.id] != readingPosition.position else { return }
        saveCurrentConversation()
    }

    private func readingPosition(for id: UUID) -> ReadingPosition? {
        if let readingPosition, readingPosition.id == id { return readingPosition.position }
        return persistedReadingPositions[id]
    }

    private func title(for id: UUID, messages: [ChatMessage]) -> String {
        if let title = titles[id] { return title }
        let title = summaries.first(where: { $0.id == id })?.title ?? ConversationTitler.title(for: messages)
        titles[id] = title
        return title
    }

    /// PNG thumbnails of the transcript's attachments, rendered once each.
    private func thumbnails(for messages: [ChatMessage]) -> [UUID: Data] {
        var result: [UUID: Data] = [:]
        var seen = Set<UUID>()
        for attachment in messages.flatMap(\.attachments) {
            seen.insert(attachment.id)
            if let cached = thumbnailCache[attachment.id] {
                if let cached { result[attachment.id] = cached }
                continue
            }
            let data = attachment.thumbnail.flatMap { Self.pngThumbnail($0, maxBytes: policy.maxThumbnailBytes) }
            thumbnailCache[attachment.id] = .some(data)
            if let data { result[attachment.id] = data }
        }
        thumbnailCache = thumbnailCache.filter { seen.contains($0.key) }
        return result
    }

    private static func pngThumbnail(_ image: NSImage, maxBytes: Int) -> Data? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              source.width > 0, source.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let scale = min(1, thumbnailPixels / CGFloat(max(source.width, source.height)))
        let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]),
              data.count <= maxBytes else { return nil }
        return data
    }

    // MARK: - Private: switching conversations

    /// Stashes and resets the current conversation (saved through `.willReset`) and offers it as the continuation.
    private func leaveCurrentConversation() {
        if chat.isStreaming { chat.cancel() }
        let transcript = chat.transcriptSnapshot()
        guard !transcript.messages.isEmpty else {
            chat.reset()
            return
        }
        let left = loadedConversation(from: transcript)
        stash = left
        chat.reset()
        continuation = summaries.first(where: { $0.id == left.id }) ?? synthesizedSummary(of: left)
    }

    /// Makes `conversation` the chat's conversation, stashing the one it replaces.
    private func switchTo(_ conversation: LoadedConversation) {
        persistReadingPositionIfChanged()
        if chat.isStreaming { chat.cancel() }
        let leaving = chat.transcriptSnapshot()
        if !leaving.messages.isEmpty, leaving.conversationID != conversation.id {
            stash = loadedConversation(from: leaving)
        } else if stash?.id == conversation.id {
            stash = nil
        }
        if continuation?.id == conversation.id { continuation = nil }

        titles[conversation.id] = conversation.title
        textOnlyContextIDs[conversation.id] = conversation.textOnlyContextMessageIDs
        readingPosition = conversation.readingPosition.map { (conversation.id, $0) }
        if let position = conversation.readingPosition { persistedReadingPositions[conversation.id] = position }
        positionToRestore = conversation.readingPosition
        chat.load(conversation)
    }

    private func restoreLatestConversation() async {
        guard settings.history.enabled, chat.messageCount == 0, let latest = summaries.first else { return }
        let idle = settings.history.idleReset.interval
        let isRecent = idle.map { now().timeIntervalSince(latest.updatedAt) < $0 } ?? true
        guard isRecent else {
            continuation = latest
            return
        }
        let result = await loadFromStore(latest.id)
        guard case .success(let conversation) = result, chat.messageCount == 0, !chat.isStreaming else {
            if case .failure = result { continuation = nil }
            return
        }
        switchTo(conversation)
        lastActivity = latest.updatedAt
        Self.logger.info("Restored conversation \(latest.id.uuidString, privacy: .public) at launch")
    }

    private func loadFromStore(_ id: UUID) async -> Result<LoadedConversation, Error> {
        await withCheckedContinuation { continuation in
            store.enqueueLoad(id: id) { continuation.resume(returning: $0) }
        }
    }

    private func loadedConversation(from transcript: TranscriptSnapshot) -> LoadedConversation {
        LoadedConversation(
            id: transcript.conversationID,
            title: title(for: transcript.conversationID, messages: transcript.messages),
            createdAt: transcript.createdAt,
            updatedAt: lastActivity ?? now(),
            messages: transcript.messages,
            unavailableAttachmentIDs: transcript.unavailableAttachmentIDs,
            textOnlyContextMessageIDs: textOnlyContextIDs[transcript.conversationID] ?? [],
            readingPosition: readingPosition(for: transcript.conversationID)
        )
    }

    /// The Continue chip's row when the conversation isn't in the index (History off, or its save hasn't landed).
    private func synthesizedSummary(of conversation: LoadedConversation) -> ConversationSummary {
        ConversationSummary(
            id: conversation.id,
            title: conversation.title,
            preview: ConversationTitler.preview(for: conversation.messages),
            searchText: "",
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            messageCount: conversation.messages.count,
            attachmentCount: conversation.messages.reduce(0) { $0 + $1.attachments.count },
            model: conversation.messages.last { $0.role == .assistant && $0.model != nil }?.model,
            blobs: [:],
            fileBytes: 0,
            fileModifiedAt: now()
        )
    }

    // MARK: - Private: bookkeeping

    /// Delete All and History off: forgets everything saved, then removes both data folders.
    private func wipe() async {
        isWipingHistory = true
        wipeGeneration += 1
        undoTask?.cancel()
        undoTask = nil
        pendingDeletion = nil
        undoStash = nil
        deletionWasContinuation = false
        stash = nil
        continuation = nil
        summaries = []
        titles = [:]
        persistedReadingPositions = [:]
        removedIDs = []
        summariesDidChange()

        let result = await withCheckedContinuation { continuation in
            store.enqueueDeleteAll { continuation.resume(returning: $0) }
        }
        switch result {
        case .success:
            lastSaveError = nil
        case .failure(let error):
            lastSaveError = "Otto couldn't delete all history: \(error.localizedDescription)."
        }
        isWipingHistory = false
        onDataRemoved?(.all)
        await refreshUsage()
    }

    private func collectGarbage() async {
        let protected = protectedIDs
        var blobs = Set<String>()
        for summary in summaries where protected.contains(summary.id) { blobs.formUnion(summary.blobs.keys) }
        if let pendingDeletion { blobs.formUnion(pendingDeletion.blobs.keys) }
        let now = now()
        await withCheckedContinuation { continuation in
            store.enqueueCollectGarbage(protectedBlobs: blobs, now: now) { continuation.resume() }
        }
    }

    private func upsert(_ summary: ConversationSummary) {
        if let index = summaries.firstIndex(where: { $0.id == summary.id }) {
            guard summaries[index].updatedAt <= summary.updatedAt else { return }
            summaries[index] = summary
        } else {
            summaries.append(summary)
        }
        summaries = Self.newestFirst(summaries)
        if continuation?.id == summary.id { continuation = summary }
        summariesDidChange()
    }

    private func removeSummaries(_ ids: Set<UUID>) {
        let before = summaries.count
        summaries.removeAll { ids.contains($0.id) }
        if summaries.count != before { summariesDidChange() }
    }

    private func forget(_ ids: Set<UUID>) {
        for id in ids {
            titles[id] = nil
            textOnlyContextIDs[id] = nil
            persistedReadingPositions[id] = nil
        }
    }

    private func summariesDidChange() {
        onSummariesChanged?()
    }

    private func startMaintenance() {
        maintenanceTask?.cancel()
        let interval = policy.maintenanceInterval
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.applyRetention()
            }
        }
    }

    private static func newestFirst(_ summaries: [ConversationSummary]) -> [ConversationSummary] {
        summaries.sorted { lhs, rhs in
            lhs.updatedAt != rhs.updatedAt ? lhs.updatedAt > rhs.updatedAt : lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
