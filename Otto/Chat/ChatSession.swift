//
//  ChatSession.swift
//  Otto
//
//  Owns the conversation: builds Messages API history, streams replies into the in-flight assistant
//  message, and runs the client tool loop (rounds handed to the tool executor, results sent back in the same
//  reply) along with pause_turn continuations, refusals, cancellation, retries and regenerated versions. It
//  also reports the transcript to History, the reply phase to the closed notch and token usage to the ledger.
//

import Foundation
import Observation
import os

@MainActor @Observable final class ChatSession: ToolCallStore {
    /// Automatic `pause_turn` continuations allowed per turn.
    static let maxPauseContinuations = 5
    static let refusalMessage = "Otto can't help with that one."
    static let truncationNote = "\n\n_(Reply truncated.)_"
    /// Appended when a turn still wanted to continue after `maxPauseContinuations`.
    static let pauseLimitNote = "\n\n_(Stopped after several web lookups.)_"
    /// Appended when Claude still asked for actions after the action limit's wrap-up request.
    static let toolLimitNote = "\n\n_(Stopped after several actions.)_"
    /// Appended to the failure copy when the user message that caused it is left out of the context.
    static let excludedFromContextNote = "Otto left this message out of the conversation so you can keep chatting."
    /// Text block sent when the user attached items without typing anything.
    static let attachmentsOnlyPrompt = "Please take a look at the attached."
    /// `ToolActivity` id of the note that web access is paused for the rest of a reply (`otto.` ids are Otto's own).
    static let webPausedActivityID = "otto.webPaused"

    /// Budget for attachment payload (base64 image/PDF data and text documents) in one request. The
    /// Messages API rejects requests over 32 MB; this leaves room for JSON escaping and the rest.
    static let maxRequestAttachmentBytes = 28_000_000
    /// Budget for text-document attachments of *earlier* turns (≈150k tokens), so a long conversation
    /// with large files keeps fitting the context window. The newest user message is always sent whole.
    static let maxHistoryTextDocumentBytes = 600_000

    private(set) var messages: [ChatMessage] = []
    private(set) var isStreaming = false

    // Cheap summaries of `messages`, kept in sync where messages are added, removed or settle (never
    // per streamed delta), so views that only need them don't observe the whole transcript.
    /// `messages.count`.
    private(set) var messageCount = 0
    /// State of the last message, if any.
    private(set) var lastMessageState: MessageState?
    /// Whether some completed assistant reply has visible text (what Copy Last Response copies).
    private(set) var hasCopyableReply = false

    /// Streamed text/thinking is written into `messages` at most this often; every write re-renders
    /// the transcript, and deltas arrive far faster than that is useful.
    static let deltaFlushInterval: Duration = .milliseconds(33)

    /// Called on the main actor whenever a turn ends (complete, refused, cancelled or failed).
    /// Not called by `reset()`, which discards the conversation instead of finishing a reply.
    @ObservationIgnored var onReplyFinished: (() -> Void)?

    // MARK: Conversation identity & transcript

    /// Identity of the current conversation: a new UUID after `reset()`, the restored id after `load(_:)`.
    private(set) var conversationID: UUID
    @ObservationIgnored private(set) var conversationCreatedAt: Date
    /// Restored attachments whose payload is gone. Changes only on `load(_:)` and `reset()`.
    private(set) var unavailableAttachmentIDs: Set<UUID>
    /// Single observer (HistoryController). Called synchronously on the main actor.
    @ObservationIgnored var onTranscriptChanged: ((TranscriptChange) -> Void)?

    /// Assistant turns of a restored conversation whose server-tool payload is gone, so they can only be
    /// sent back as text.
    @ObservationIgnored private var textOnlyContextIDs: Set<UUID> = []
    /// Ids of the messages that came from `load(_:)`.
    @ObservationIgnored private var restoredMessageIDs: Set<UUID> = []
    /// Whether the API already rejected the restored messages as they were stored (they are then compacted once).
    @ObservationIgnored private var compactsRestoredContext = false
    /// Earlier messages sent compacted for the rest of the conversation, after a request was too large or too long
    /// for the model (or the API rejected restored turns as stored): assistant turns as their visible text only,
    /// user turns without their attachments (see `requestHistory`).
    @ObservationIgnored private var compactedContextIDs: Set<UUID> = []
    /// What a failed reply had left of its web search and fetch budget, so Retry continues it with that budget.
    @ObservationIgnored private var failedReplyWebBudgets: [UUID: (searches: Int, fetches: Int)] = [:]

    // MARK: Glance

    /// What the in-flight reply is doing (`ReplyPhase.derive`). Assigned only when it changes, and never
    /// per streamed delta once text is showing.
    private(set) var phase: ReplyPhase = .idle
    /// The assistant message of the turn that finished last; set before `onReplyFinished` runs.
    private(set) var lastFinishedAssistantID: UUID?

    // MARK: Usage

    /// Receives one record per Messages API response (a partial one when a turn ends without
    /// `.completed` after usage arrived) and one `finishAnswer` per settled turn.
    @ObservationIgnored weak var usageRecorder: UsageRecording?

    // MARK: Tool loop

    /// The dock's current tool-loop prompt (the executor's; observable through it).
    var pendingApproval: PendingApproval? { executor?.pendingApproval }
    /// Called on the main actor when the executor puts a new prompt in the dock.
    @ObservationIgnored var onAttentionNeeded: ((PendingApproval) -> Void)?
    /// The in-flight tool call that needs system UI (the view model folds the notch while non-nil): a call in
    /// `.waitingForSystem(app)` → `.toolDialog(appName: app)`; else a `.running` call whose tool `mayPresentUI`
    /// and that started at least `ToolLimits.uiFoldDelay` ago → `.toolRun(title: activeTitle)` (with the "fewer
    /// prompts" safety mode, tool runs never fold). A one-shot timer re-evaluates at the delay mark.
    private(set) var systemUIToolWait: SystemUIWait?

    // MARK: Keyboard essentials

    /// Replies to one user turn, kept when it is regenerated.
    struct ReplyVersions: Equatable {
        let userMessageID: UUID
        /// Complete replies to that user turn, oldest first.
        var replies: [ChatMessage]
        /// Index of the reply currently in `messages`; `replies.count` while a new one streams or when the shown
        /// reply isn't a stored version (failed, cancelled, refused).
        var currentIndex: Int
    }

    /// Versions of the reply to the last user turn (nil until the first regenerate). Cleared by send,
    /// replaceLastTurn, reset and debugSeed.
    private(set) var lastTurnVersions: ReplyVersions?

    /// The newest user message (↑ recall and edit).
    var lastUserMessage: ChatMessage? { messages.last(where: { $0.role == .user }) }

    enum RegenerateOutcome: Equatable { case started, nothingToRegenerate }

    // MARK: Spoken replies

    /// Called after each delta flush that wrote text into an assistant message, and once more with
    /// `isFinal == true` (the final text) when a turn completes. Cancelled, refused and failed turns get no
    /// final call.
    @ObservationIgnored var onAssistantTextProgress: ((_ assistantID: UUID, _ text: String, _ isFinal: Bool) -> Void)?

    // MARK: Clock seams

    /// The time used for `<context>` blocks, the system prompt date and `systemUIToolWait` (tests replace it).
    @ObservationIgnored var clock: @MainActor () -> Date = { Date() }
    /// Runs `action` once after `delay`; `systemUIToolWait` uses it to re-evaluate at the fold delay (tests
    /// capture the action and fire it themselves).
    @ObservationIgnored var scheduleSystemUIRefresh:
        @MainActor (_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> Void = { delay, action in
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            action()
        }
    }

    /// Trimmed text of the most recent completed assistant reply that has visible text.
    var lastAssistantText: String? {
        for message in messages.reversed() where message.role == .assistant && message.state == .complete {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let makeClient: @MainActor () throws -> LLMClient
    @ObservationIgnored private let registry: ToolRegistry
    @ObservationIgnored private let executor: ToolExecuting?
    @ObservationIgnored private let permissions: PermissionProviding?
    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    /// The assistant message the running task writes into. A task whose id no longer matches (after
    /// `cancel()` / `reset()`) must not touch any state — it is only winding down.
    @ObservationIgnored private var activeAssistantID: UUID?
    /// The configuration of the running turn (its tool snapshot and safety mode).
    @ObservationIgnored private var activeConfig: TurnConfig?

    /// Streamed deltas not yet written into their message (see `deltaFlushInterval`).
    private struct PendingDeltas {
        var assistantID: UUID?
        var text = ""
        var thinking = ""
        var isEmpty: Bool { text.isEmpty && thinking.isEmpty }
    }
    @ObservationIgnored private var pendingDeltas = PendingDeltas()
    @ObservationIgnored private var lastDeltaFlush: ContinuousClock.Instant?
    @ObservationIgnored private var deltaFlushTask: Task<Void, Never>?
    /// The latest cumulative `usage` of the response being streamed (`StreamEvent.usage`), kept for
    /// partial-usage accounting when a response ends without `.completed`.
    @ObservationIgnored private var inFlightUsage: JSONValue?
    /// The model the running turn requested (`MessagesRequest.model`), for usage records.
    @ObservationIgnored private var inFlightRequestedModel: String?
    /// Whether the response being streamed has delivered any event (a rejected request delivers none).
    @ObservationIgnored private var responseDeliveredEvent = false
    /// A `systemUIToolWait` re-evaluation is scheduled.
    @ObservationIgnored private var systemUIRefreshScheduled = false

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Chat")
    private static let toolLogger = Logger(subsystem: "com.jalenedusei.otto", category: "Tools")

    /// Shown when Undo is asked of a session that has no executor.
    private static let undoUnavailableReason = "actions aren't available right now"

    /// `tools` defaults to an empty registry. Swift 5 evaluates default arguments outside the main actor, and
    /// callers of this main-actor initializer are on it, so the default is built with `assumeIsolated`.
    init(
        settings: AppSettings,
        makeClient: @escaping @MainActor () throws -> LLMClient,
        tools: ToolRegistry = MainActor.assumeIsolated { ToolRegistry() },
        executor: ToolExecuting? = nil,
        permissions: PermissionProviding? = nil,
        isDemo: Bool = LaunchOptions.demo
    ) {
        self.settings = settings
        self.makeClient = makeClient
        self.registry = tools
        self.executor = executor
        self.permissions = permissions
        self.isDemo = isDemo
        conversationID = UUID()
        conversationCreatedAt = Date()
        unavailableAttachmentIDs = []
        executor?.onAttentionNeeded = { [weak self] approval in
            self?.onAttentionNeeded?(approval)
        }
    }

    // MARK: - Public API

    func send(text: String, attachments: [Attachment]) {
        guard !isStreaming else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        let config = makeTurnConfig()
        var content = attachments.flatMap { $0.contentBlocks() }
        if !config.tools.isEmpty {
            // Stored in the message, so history stays byte-stable on later turns.
            content += registry.userContextBlocks(tools: config.tools, now: clock(), timeZone: .current)
            // Only notes about this conversation's actions: an undo elsewhere must not reach this chat.
            let messageIDs = Set(messages.lazy.filter { $0.role == .assistant }.map(\.id))
            content += (executor?.consumeContextNotes(forMessages: messageIDs) ?? []).map(Self.textBlock)
        }
        content.append(Self.textBlock(trimmed.isEmpty ? Self.attachmentsOnlyPrompt : trimmed))
        lastTurnVersions = nil
        messages.append(ChatMessage(role: .user, text: trimmed, attachments: attachments, apiContent: content))
        beginAssistantTurn(at: messages.endIndex, config: config)
        onTranscriptChanged?(.userMessageAdded)
    }

    /// Stops the in-flight reply. The message keeps whatever streamed so far and becomes `.cancelled`; a
    /// pending approval resolves as cancelled first.
    func cancel() {
        if let id = activeAssistantID {
            streamTask?.cancel()
            executor?.cancelAll()
            finishTurn(id, outcome: .cancelled)
            return
        }
        // Only reachable after `debugSeed(isStreaming: true)`: there is no task, so settle the state.
        guard isStreaming else { return }
        for index in messages.indices where messages[index].state == .streaming {
            messages[index].state = .cancelled
            messages[index].isThinking = false
        }
        isStreaming = false
        updateSummary(recomputeCopyable: true)
        refreshPhase()
    }

    /// Re-runs a failed, cancelled or refused assistant turn in place. A failed turn whose actions already ran (it
    /// stayed in the context) is continued from its last exchange instead, so nothing runs a second time.
    func retry(messageID: UUID) {
        guard !isStreaming, let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let message = messages[index]
        guard message.role == .assistant else { return }
        switch message.state {
        case .failed:
            if message.includeInContext, !message.toolExchanges.isEmpty {
                resumeFailedToolTurn(at: index)
                return
            }
        case .cancelled, .refused:
            break
        case .complete, .streaming:
            return
        }

        messages.remove(at: index)
        if let userIndex = messages[..<index].lastIndex(where: { $0.role == .user }) {
            messages[userIndex].includeInContext = true
        }
        updateSummary(recomputeCopyable: true)
        // Normally the retried turn is the last one, so this appends. For an older turn the new reply
        // takes its place and only the conversation up to that point is sent (see `requestHistory`);
        // appending it after later turns would make the request end on an assistant message.
        beginAssistantTurn(at: index, config: makeTurnConfig())
    }

    /// Continues a failed turn whose tool rounds ran (foundation.md §8): the message goes back to streaming with
    /// whatever came after its last exchange dropped (the partial response that failed, and calls it announced that
    /// never ran), and the next request re-sends the conversation up to that exchange's results. It is still one
    /// reply, so everything SPEC §5.9 allows per reply carries over: the round count, a web pause, the web search
    /// and fetch budget, and (through `ToolExecuting.resumeTurn`) the per-tool limits and declines.
    private func resumeFailedToolTurn(at index: Int) {
        var message = messages[index]
        guard let last = message.toolExchanges.last else { return }
        let exchanged = Set(message.toolExchanges.flatMap(\.callIDs))
        message.apiContent = Array(message.apiContent.prefix(max(0, last.contentEnd)))
        message.text = String(message.text.prefix(max(0, last.textEnd)))
        message.toolCalls.removeAll { !exchanged.contains($0.id) }
        message.isThinking = false
        message.state = .streaming
        messages[index] = message
        if let userIndex = messages[..<index].lastIndex(where: { $0.role == .user }) {
            messages[userIndex].includeInContext = true
        }
        var state = LoopState()
        state.toolRounds = message.toolExchanges.count
        state.webPaused = message.activities.contains { $0.id == Self.webPausedActivityID }
        state.resumesReply = true
        let budget = failedReplyWebBudgets.removeValue(forKey: message.id) ?? Self.webBudgetLeft(in: message.apiContent)
        state.searchesLeft = budget.searches
        state.fetchesLeft = budget.fetches
        Self.toolLogger.info("Continuing a failed reply after \(state.toolRounds, privacy: .public) rounds")
        startTurn(assistantID: message.id, config: makeTurnConfig(), state: state)
    }

    /// Cancels any reply and clears the conversation, which starts a new one with a new id. History hears
    /// `.willReset` first (while the old transcript is still here) unless there was nothing to save.
    func reset() {
        flushPendingDeltas()
        if !messages.isEmpty { onTranscriptChanged?(.willReset) }
        if let id = activeAssistantID {
            executor?.cancelAll()
            settleUsage(for: id)
        }
        streamTask?.cancel()
        streamTask = nil
        activeAssistantID = nil
        activeConfig = nil
        discardPendingDeltas()
        messages.removeAll()
        isStreaming = false
        lastTurnVersions = nil
        updateSummary(recomputeCopyable: true)
        conversationID = UUID()
        conversationCreatedAt = Date()
        if !unavailableAttachmentIDs.isEmpty { unavailableAttachmentIDs = [] }
        textOnlyContextIDs = []
        restoredMessageIDs = []
        compactsRestoredContext = false
        compactedContextIDs = []
        failedReplyWebBudgets = [:]
        refreshPhase()
        refreshSystemUIToolWait()
    }

    /// Flushes pending deltas and returns the transcript (cheap: the arrays are copy-on-write).
    func transcriptSnapshot() -> TranscriptSnapshot {
        flushPendingDeltas()
        return TranscriptSnapshot(
            conversationID: conversationID,
            createdAt: conversationCreatedAt,
            messages: messages,
            unavailableAttachmentIDs: unavailableAttachmentIDs
        )
    }

    /// Replaces the conversation with a restored one. A running reply is cancelled first, which reports
    /// `.turnFinished` for the old conversation before `.loaded` reports the new one.
    func load(_ conversation: LoadedConversation) {
        if activeAssistantID != nil { cancel() }
        streamTask?.cancel()
        streamTask = nil
        activeAssistantID = nil
        activeConfig = nil
        discardPendingDeltas()
        inFlightUsage = nil
        inFlightRequestedModel = nil
        if conversationID != conversation.id { conversationID = conversation.id }
        conversationCreatedAt = conversation.createdAt
        messages = conversation.messages
        if unavailableAttachmentIDs != conversation.unavailableAttachmentIDs {
            unavailableAttachmentIDs = conversation.unavailableAttachmentIDs
        }
        textOnlyContextIDs = conversation.textOnlyContextMessageIDs
        restoredMessageIDs = Set(conversation.messages.map(\.id))
        compactsRestoredContext = false
        compactedContextIDs = []
        failedReplyWebBudgets = [:]
        lastTurnVersions = nil
        isStreaming = false
        updateSummary(recomputeCopyable: true)
        refreshPhase()
        refreshSystemUIToolWait()
        Self.logger.info("Loaded conversation \(conversation.id.uuidString, privacy: .public) with \(conversation.messages.count, privacy: .public) messages")
        onTranscriptChanged?(.loaded)
    }

    /// Snapshots/tests only: replaces the conversation without starting any work.
    func debugSeed(messages: [ChatMessage], isStreaming: Bool) {
        streamTask?.cancel()
        streamTask = nil
        activeAssistantID = nil
        activeConfig = nil
        discardPendingDeltas()
        inFlightUsage = nil
        inFlightRequestedModel = nil
        lastTurnVersions = nil
        self.messages = messages
        self.isStreaming = isStreaming
        updateSummary(recomputeCopyable: true)
        refreshPhase()
        refreshSystemUIToolWait()
    }

    // MARK: - Regenerate, versions, edit and resend

    /// Re-answers the last user turn with the current settings. A reply that is streaming is cancelled first;
    /// complete replies to that turn are kept as versions.
    @discardableResult func regenerate() -> RegenerateOutcome {
        guard messages.contains(where: { $0.role == .user }) else { return .nothingToRegenerate }
        if isStreaming { cancel() }
        guard let userIndex = messages.lastIndex(where: { $0.role == .user }) else { return .nothingToRegenerate }

        let userID = messages[userIndex].id
        var versions = ReplyVersions(userMessageID: userID, replies: [], currentIndex: 0)
        if let existing = lastTurnVersions, existing.userMessageID == userID {
            versions = existing
        }
        let stored = Set(versions.replies.map(\.id))
        for message in messages[(userIndex + 1)...] where Self.isStorableVersion(message) && !stored.contains(message.id) {
            versions.replies.append(message)
        }

        let removesMessages = userIndex + 1 < messages.endIndex
        if removesMessages {
            messages.removeSubrange((userIndex + 1)...)
        }
        messages[userIndex].includeInContext = true
        versions.currentIndex = versions.replies.count
        lastTurnVersions = versions
        updateSummary(recomputeCopyable: true)
        if removesMessages { onTranscriptChanged?(.messagesRemoved) }
        beginAssistantTurn(at: messages.endIndex, config: makeTurnConfig())
        return .started
    }

    /// Shows stored version `index` of the last turn's reply (not while streaming).
    func showReplyVersion(_ index: Int) {
        guard !isStreaming, var versions = lastTurnVersions, versions.replies.indices.contains(index),
              let userIndex = messages.lastIndex(where: { $0.role == .user }),
              messages[userIndex].id == versions.userMessageID else { return }
        if userIndex + 1 < messages.endIndex {
            messages.removeSubrange((userIndex + 1)...)
        }
        messages.append(versions.replies[index])
        versions.currentIndex = index
        lastTurnVersions = versions
        updateSummary(recomputeCopyable: true)
        refreshPhase()
    }

    /// Removes the last user turn and everything after it, then sends `text` and `attachments` in its place.
    /// A running reply is cancelled first. Does nothing when there is nothing to send.
    func replaceLastTurn(text: String, attachments: [Attachment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        if isStreaming { cancel() }
        if let userIndex = messages.lastIndex(where: { $0.role == .user }) {
            messages.removeSubrange(userIndex...)
            lastTurnVersions = nil
            updateSummary(recomputeCopyable: true)
            onTranscriptChanged?(.messagesRemoved)
        }
        send(text: text, attachments: attachments)
    }

    private static func isStorableVersion(_ message: ChatMessage) -> Bool {
        message.role == .assistant && message.state == .complete
            && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Tool loop surface

    /// Forwards the user's answer to the dock's current prompt to the executor.
    func resolveApproval(_ decision: ApprovalDecision, hardwareConfirmed: Bool, visibleSince: Date?) {
        guard let executor, let pending = executor.pendingApproval else { return }
        executor.resolve(decision, callID: pending.callID, hardwareConfirmed: hardwareConfirmed,
                         visibleSince: visibleSince)
    }

    /// Removes the item a call created. nil on success; else a short reason for the notice.
    func undoToolCall(_ callID: String, in messageID: UUID) async -> String? {
        guard let executor else { return Self.undoUnavailableReason }
        // Resolve the token's tool from the registry, not only from the rounds this process ran: a call restored
        // from History (after a relaunch or an update) keeps a live Undo for its window.
        executor.registerUndoTools(registry.allTools)
        return await executor.undo(callID: callID, messageID: messageID, store: self)
    }

    /// [Stop] on one running call.
    func stopToolCall(_ callID: String) {
        executor?.stop(callID: callID)
    }

    // MARK: ToolCallStore

    func toolCall(_ id: String, in messageID: UUID) -> ToolCall? {
        messages.last(where: { $0.id == messageID })?.toolCalls.first(where: { $0.id == id })
    }

    /// Applies an executor mutation. A settled reply only takes Undo's changes (status `.undone` of a call that
    /// succeeded, its presentation and finish time, and the undo token).
    func updateToolCall(_ id: String, in messageID: UUID, _ mutate: (inout ToolCall) -> Void) {
        guard let index = messages.lastIndex(where: { $0.id == messageID }),
              let callIndex = messages[index].toolCalls.firstIndex(where: { $0.id == id }) else { return }
        let original = messages[index].toolCalls[callIndex]
        var updated = original
        mutate(&updated)
        let isActiveTurn = isActive(messageID)
        if !isActiveTurn {
            var accepted = original
            if updated.status == .undone, original.status == .succeeded || original.status == .undone {
                accepted.status = .undone
                accepted.presentation = updated.presentation
                accepted.finishedAt = updated.finishedAt
            }
            accepted.undo = updated.undo
            updated = accepted
        }
        guard updated != original else { return }
        messages[index].toolCalls[callIndex] = updated
        if isActiveTurn {
            refreshPhase()
            refreshSystemUIToolWait()
        }
    }

    // MARK: - Summaries

    /// Re-derives `phase` from the in-flight assistant message (the last streaming assistant message of a
    /// seeded conversation when no turn runs), assigning only when it changed.
    private func refreshPhase() {
        let inFlight: ChatMessage?
        if let id = activeAssistantID {
            inFlight = messages.last(where: { $0.id == id })
        } else if isStreaming {
            inFlight = messages.last(where: { $0.role == .assistant && $0.state == .streaming })
        } else {
            inFlight = nil
        }
        let derived = ReplyPhase.derive(from: inFlight)
        if phase != derived { phase = derived }
    }

    /// Re-derives `systemUIToolWait` from the running turn's calls, assigning only when it changed.
    private func refreshSystemUIToolWait() {
        let wait = currentSystemUIToolWait()
        if systemUIToolWait != wait { systemUIToolWait = wait }
    }

    private func currentSystemUIToolWait() -> SystemUIWait? {
        guard let id = activeAssistantID, let config = activeConfig,
              let message = messages.last(where: { $0.id == id }) else { return nil }
        for call in message.toolCalls {
            if case .waitingForSystem(let appName) = call.status { return .toolDialog(appName: appName) }
        }
        guard config.foldsForToolRuns else { return nil }
        let foldDelay = ToolLimits.uiFoldDelay.timeInterval
        let now = clock()
        var nextCheck: TimeInterval?
        for call in message.toolCalls where call.status == .running {
            guard config.toolsByName[call.name]?.mayPresentUI == true, let startedAt = call.startedAt else { continue }
            let elapsed = now.timeIntervalSince(startedAt)
            if elapsed >= foldDelay { return .toolRun(title: call.presentation.activeTitle) }
            nextCheck = min(nextCheck ?? .infinity, foldDelay - elapsed)
        }
        if let nextCheck { requestSystemUIRefresh(after: nextCheck) }
        return nil
    }

    /// One pending re-evaluation at a time; a stale one only re-derives the same value.
    private func requestSystemUIRefresh(after seconds: TimeInterval) {
        guard !systemUIRefreshScheduled else { return }
        systemUIRefreshScheduled = true
        scheduleSystemUIRefresh(.milliseconds(Int64((seconds * 1000).rounded(.up)))) { [weak self] in
            guard let self else { return }
            self.systemUIRefreshScheduled = false
            self.refreshSystemUIToolWait()
        }
    }

    /// Updates `messageCount`, `lastMessageState` and (when asked) `hasCopyableReply`, assigning only
    /// values that changed so observers aren't invalidated for nothing.
    private func updateSummary(recomputeCopyable: Bool) {
        if messageCount != messages.count { messageCount = messages.count }
        let lastState = messages.last?.state
        if lastMessageState != lastState { lastMessageState = lastState }
        if recomputeCopyable {
            let copyable = lastAssistantText != nil
            if hasCopyableReply != copyable { hasCopyableReply = copyable }
        }
    }

    // MARK: - Turn lifecycle

    /// Everything a turn needs, captured once so tool rounds and pause_turn continuations resend an identical
    /// prefix (same model, tools and system prompt) even if settings change mid-turn.
    private struct TurnConfig {
        let model: ModelOption
        let effort: EffortLevel
        let webAccess: Bool
        let system: String
        /// The client tools offered this turn, sorted by name.
        let tools: [any OttoTool]
        let clientToolDefinitions: [JSONValue]
        let toolsByName: [String: any OttoTool]
        let maxToolRounds: Int
        let safetyMode: ActionSafetyMode

        var clientToolNames: Set<String> { Set(toolsByName.keys) }
        /// "Safer" pauses web access once private data and fresh untrusted content meet.
        var pausesWebAccess: Bool { safetyMode == .safer }
        /// "Safer" folds the notch while a tool that may show its own UI runs.
        var foldsForToolRuns: Bool { safetyMode == .safer }

        /// Names of the server tools a request with these limits defines.
        func enabledServerTools(limits: ServerToolLimits) -> Set<String> {
            ChatSession.serverToolNames(model: model, webAccess: webAccess, limits: limits)
        }
    }

    /// Names of the server tools a request with this model and web setting defines. The 2026 web
    /// tools run dynamic filtering, which emits `code_execution` calls of its own.
    nonisolated static func serverToolNames(model: ModelOption, webAccess: Bool) -> Set<String> {
        serverToolNames(model: model, webAccess: webAccess, limits: ServerToolLimits())
    }

    /// As above, leaving out a tool whose `max_uses` is 0 in this request (the reply's budget is spent, or web
    /// access is paused), and `code_execution` when no web tool is left.
    nonisolated private static func serverToolNames(
        model: ModelOption,
        webAccess: Bool,
        limits: ServerToolLimits
    ) -> Set<String> {
        guard webAccess else { return [] }
        var names: Set<String> = []
        if limits.webSearch > 0 { names.insert("web_search") }
        if model.webFetchToolType != nil, limits.webFetch > 0 { names.insert("web_fetch") }
        if !names.isEmpty, model.webSearchToolType == "web_search_20260209" { names.insert("code_execution") }
        return names
    }

    private enum TurnOutcome {
        case completed(stopReason: String?)
        case cancelled
        case failed(Error)
    }

    private enum TurnError: LocalizedError, Equatable {
        case nothingToSend
        case requestTooLarge
        /// Even with every earlier turn compacted the request is too large or too long for the model.
        case conversationTooLong

        var errorDescription: String? {
            switch self {
            case .nothingToSend: return "There's no message for Otto to reply to."
            case .requestTooLarge: return AttachmentBudget.requestTooLargeDescription
            case .conversationTooLong: return ChatSession.conversationTooLongDescription
            }
        }
    }

    #if os(macOS)
    /// Shown when a conversation no longer fits one request, whatever Otto leaves out of the earlier turns.
    nonisolated static let conversationTooLongDescription =
        "This conversation is too long for Otto to continue. Start a new chat (⌘N) to keep going."
    #else
    /// Shown when a conversation no longer fits one request, whatever Otto leaves out of the earlier turns.
    nonisolated static let conversationTooLongDescription =
        "This conversation is too long for Otto to continue. Start a new chat to keep going."
    #endif

    /// The configuration a turn started now would use. No executor means no client tools.
    private func makeTurnConfig() -> TurnConfig {
        let model = settings.model
        let offered: [any OttoTool]
        if executor != nil {
            let environment = ToolEnvironment(settings: settings, permissions: permissions, model: model, isDemo: isDemo)
            offered = registry.availableTools(in: environment)
        } else {
            offered = []
        }
        var byName: [String: any OttoTool] = [:]
        for tool in offered { byName[tool.name] = tool }
        let actionsSection = offered.isEmpty
            ? SystemPrompt.actionsOffLine
            : SystemPrompt.actionsSection(groups: registry.enabledGroups(for: offered), timeZone: .current)
        return TurnConfig(
            model: model,
            effort: settings.effort,
            webAccess: settings.webAccess,
            system: SystemPrompt.make(customInstructions: settings.customInstructions, actionsSection: actionsSection,
                                      now: clock(), timeZone: .current),
            tools: offered,
            clientToolDefinitions: registry.definitions(for: offered),
            toolsByName: byName,
            maxToolRounds: settings.actions.maxToolRounds,
            safetyMode: settings.actionSafetyMode
        )
    }

    private func beginAssistantTurn(at index: Int, config: TurnConfig) {
        let assistant = ChatMessage(role: .assistant, state: .streaming)
        messages.insert(assistant, at: min(max(index, 0), messages.endIndex))
        startTurn(assistantID: assistant.id, config: config, state: LoopState())
    }

    /// Runs the request loop for the streaming assistant message `assistantID`, starting from `state`.
    private func startTurn(assistantID: UUID, config: TurnConfig, state: LoopState) {
        activeAssistantID = assistantID
        activeConfig = config
        isStreaming = true
        discardPendingDeltas()
        updateSummary(recomputeCopyable: true)

        inFlightUsage = nil
        inFlightRequestedModel = config.model.rawValue
        refreshPhase()
        streamTask = Task { [weak self] in
            await self?.runTurn(assistantID: assistantID, config: config, state: state)
        }
    }

    /// Mutable state of one turn's request loop.
    private struct LoopState {
        var pauseContinuations = 0
        var toolRounds = 0
        var resuming = false
        var toolChoice: JSONValue?
        var wrapUpSent = false
        var searchesLeft = ToolLimits.webSearchesPerTurn
        var fetchesLeft = ToolLimits.webFetchesPerTurn
        var webPaused = false
        /// The server-tool limits of the last fresh request (a pause_turn continuation reuses them).
        var limits = ServerToolLimits()
        /// The turn continues a failed reply (Retry): the executor keeps that reply's per-reply counters.
        var resumesReply = false
    }

    /// The web search and fetch budget a reply's content leaves, counting its server-tool calls (for a reply this
    /// process no longer has the numbers of).
    static func webBudgetLeft(in content: [JSONValue]) -> (searches: Int, fetches: Int) {
        let names = content.filter { $0.typeName == "server_tool_use" }.compactMap { $0["name"]?.stringValue }
        let searches = names.filter { $0 == "web_search" }.count
        let fetches = names.filter { $0 == "web_fetch" }.count
        return (max(0, ToolLimits.webSearchesPerTurn - searches), max(0, ToolLimits.webFetchesPerTurn - fetches))
    }

    /// Ends a response that streamed more client calls than `ToolLimits.maxStreamedCallsPerResponse`.
    private struct TooManyToolCalls: Error {}

    private func runTurn(assistantID: UUID, config: TurnConfig, state initialState: LoopState) async {
        guard isActive(assistantID) else { return }

        let client: LLMClient
        do {
            client = try makeClient()
        } catch {
            finishTurn(assistantID, outcome: .failed(error))
            return
        }

        if initialState.resumesReply, let message = messages.last(where: { $0.id == assistantID }) {
            executor?.resumeTurn(messageID: assistantID, calls: message.toolCalls)
        } else {
            executor?.beginTurn()
        }
        var state = initialState
        do {
            while true {
                try Task.checkCancellation()
                flushPendingDeltas()
                inFlightUsage = nil
                responseDeliveredEvent = false
                if !state.resuming {
                    // A pause_turn continuation resumes that response, so it keeps its server tools and limits.
                    state.limits = state.webPaused
                        ? .none
                        : ServerToolLimits(webSearch: min(5, state.searchesLeft), webFetch: min(5, state.fetchesLeft))
                }
                let fullHistory = Self.requestHistory(
                    for: messages,
                    inFlight: assistantID,
                    resumingInFlight: state.resuming,
                    enabledServerTools: config.enabledServerTools(limits: state.limits),
                    clientToolNames: config.clientToolNames,
                    model: config.model,
                    compacting: compactingIDs()
                )
                // The whole request must stay under the API's size limit: earlier turns' attachments
                // give way first, then earlier turns are compacted (server-tool payloads such as a fetched PDF
                // live in assistant turns); if it still can't fit, the new message or the conversation is too big.
                guard let history = AttachmentBudget.fitting(fullHistory) else {
                    if compactEarlierContext(after: TurnError.requestTooLarge, assistantID: assistantID) { continue }
                    throw Self.overflowFailure(TurnError.requestTooLarge, history: fullHistory)
                }
                // What the executor's trust and echo checks read: the same conversation with every server-tool
                // result kept, because a page Claude read stays behind its thinking and text even once this
                // request defines no web tools (web pause, spent budget, Web access off, Haiku), or once earlier
                // turns are compacted for size (their pages still shaped what they said).
                let trustTranscript = executor == nil ? history : Self.requestHistory(
                    for: messages,
                    inFlight: assistantID,
                    resumingInFlight: state.resuming,
                    enabledServerTools: nil,
                    clientToolNames: config.clientToolNames,
                    model: config.model,
                    compacting: textOnlyContextIDs
                )
                // A fresh request must end on a user turn; only a pause_turn continuation may end on
                // the (partial) assistant turn.
                guard let lastRole = history.last?["role"]?.stringValue,
                      lastRole == (state.resuming ? "assistant" : "user") else {
                    throw TurnError.nothingToSend
                }

                let request = MessagesRequest(
                    model: config.model,
                    system: config.system,
                    messages: history,
                    maxTokens: config.model.maxOutputTokens,
                    effort: config.effort,
                    webAccess: config.webAccess,
                    clientTools: config.clientToolDefinitions,
                    toolChoice: state.toolChoice,
                    serverToolLimits: state.limits
                )
                let result: StreamResult
                do {
                    responseDeliveredEvent = false
                    result = try await consume(client.stream(request), into: assistantID)
                } catch where compactEarlierContext(after: error, assistantID: assistantID) {
                    // Too large or too long for the model (e.g. fetched PDFs, or a switch to Haiku 4.5), or a
                    // continued chat whose stored thinking or server-tool payload the API no longer accepts: the
                    // earlier turns are compacted and the request is sent again instead of failing every turn.
                    continue
                } catch where !responseDeliveredEvent && Self.isContextOverflow(error) {
                    throw Self.overflowFailure(error, history: history)
                }
                guard isActive(assistantID) else { return }
                let usage = result.usage ?? inFlightUsage
                recordCompletedUsage(result, requestedModel: config.model.rawValue, assistantID: assistantID)
                let serverToolUse = usage?["server_tool_use"]
                state.searchesLeft = max(0, state.searchesLeft - (serverToolUse?["web_search_requests"]?.intValue ?? 0))
                state.fetchesLeft = max(0, state.fetchesLeft - (serverToolUse?["web_fetch_requests"]?.intValue ?? 0))

                switch result.stopReason {
                case "pause_turn" where state.pauseContinuations < Self.maxPauseContinuations:
                    state.pauseContinuations += 1
                    state.resuming = true
                    continue
                case "tool_use":
                    state.resuming = false
                    guard try await runToolRound(result, transcript: trustTranscript, assistantID: assistantID,
                                                 config: config, state: &state) else { return }
                    continue
                default:
                    finishTurn(assistantID, outcome: .completed(stopReason: result.stopReason))
                    return
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                finishTurn(assistantID, outcome: .cancelled)
            } else if error is TooManyToolCalls {
                endRunawayResponse(assistantID)
            } else {
                // Retry continues a reply whose actions ran; it must not get a fresh web budget. A response that
                // failed part-way may already have searched.
                let partial = inFlightUsage?["server_tool_use"]
                failedReplyWebBudgets[assistantID] = (
                    max(0, state.searchesLeft - (partial?["web_search_requests"]?.intValue ?? 0)),
                    max(0, state.fetchesLeft - (partial?["web_fetch_requests"]?.intValue ?? 0))
                )
                finishTurn(assistantID, outcome: .failed(error))
            }
        }
    }

    /// A response that kept streaming client calls past the reply's limit was cancelled: nothing it asked for runs,
    /// and the turn ends with the limit note.
    private func endRunawayResponse(_ assistantID: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == assistantID }) else { return }
        let ids = Self.unexchangedCallIDs(of: messages[index])
        Self.toolLogger.info("Stopped a reply that streamed \(ids.count, privacy: .public) actions at once")
        settle(ids, in: assistantID) { call in
            call.status = .skipped("Action limit reached")
            call.result = nil
        }
        appendNote(Self.toolLimitNote, to: assistantID)
        finishTurn(assistantID, outcome: .completed(stopReason: "end_turn"))
    }

    /// Calls of the message outside every exchange (the response being streamed), in order.
    private static func unexchangedCallIDs(of message: ChatMessage) -> [String] {
        let exchanged = Set(message.toolExchanges.flatMap(\.callIDs))
        return message.toolCalls.map(\.id).filter { !exchanged.contains($0) }
    }

    /// Handles a response that stopped for `tool_use`: records the round and runs it (or answers it with the
    /// action limit). Returns false when the turn finished instead.
    private func runToolRound(
        _ result: StreamResult,
        transcript: [JSONValue],
        assistantID: UUID,
        config: TurnConfig,
        state: inout LoopState
    ) async throws -> Bool {
        let calls = newClientCallIDs(in: result.content, of: assistantID)
        guard !calls.isEmpty else {
            finishTurn(assistantID, outcome: .completed(stopReason: "end_turn"))
            return false
        }
        if state.wrapUpSent {
            // Claude asked again after the wrap-up request: nothing runs, and without an exchange the orphaned
            // tool_use blocks never reach history.
            settle(calls, in: assistantID) { call in
                call.status = .skipped("Action limit reached")
            }
            appendNote(Self.toolLimitNote, to: assistantID)
            finishTurn(assistantID, outcome: .completed(stopReason: "end_turn"))
            return false
        }

        recordExchange(calls, in: assistantID)
        let totalCalls = messages.last(where: { $0.id == assistantID })?.toolCalls.count ?? 0
        if state.toolRounds >= config.maxToolRounds || totalCalls > ToolLimits.maxCallsPerTurn {
            let rounds = state.toolRounds
            Self.toolLogger.info(
                "Action limit reached after \(rounds, privacy: .public) rounds and \(totalCalls, privacy: .public) calls"
            )
            settle(calls, in: assistantID) { call in
                call.status = .skipped("Action limit reached")
                call.result = .error(ToolHistory.Copy.actionLimit)
            }
            state.toolChoice = ["type": "none"]
            state.wrapUpSent = true
            return true
        }

        state.toolRounds += 1
        state.pauseContinuations = 0
        guard let executor else {
            // No tools were offered, so Claude can't have meant any of these.
            settle(calls, in: assistantID) { call in
                call.status = .failed("Unknown action")
                call.result = .error(ToolHistory.Copy.unknownTool(call.name))
            }
            return true
        }
        let round = ToolRound(
            messageID: assistantID,
            callIDs: calls,
            roundIndex: state.toolRounds - 1,
            transcript: transcript + [Self.entry(role: .assistant, content: result.content)],
            tools: config.toolsByName,
            model: config.model,
            knownTools: Dictionary(registry.allTools.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        )
        let roundNumber = state.toolRounds
        Self.toolLogger.info("Running round \(roundNumber, privacy: .public) with \(calls.count, privacy: .public) calls")
        let outcome = try await executor.execute(round, store: self)
        guard isActive(assistantID) else { throw CancellationError() }
        if let reason = outcome.webPause, config.webAccess, config.pausesWebAccess, !state.webPaused {
            state.webPaused = true
            appendWebPauseNote(reason, to: assistantID)
        }
        return true
    }

    /// Client tool_use ids of this response, in model order, that no earlier round of the turn recorded. A call
    /// the stream never announced gets its row now.
    private func newClientCallIDs(in content: [JSONValue], of assistantID: UUID) -> [String] {
        guard let index = messages.lastIndex(where: { $0.id == assistantID }) else { return [] }
        let recorded = Set(messages[index].toolExchanges.flatMap(\.callIDs))
        let ids = ToolHistory.clientToolUseIDs(in: content).filter { !recorded.contains($0) }
        var message = messages[index]
        var changed = false
        for block in content where ToolHistory.isClientToolUse(block) {
            guard let id = block["id"]?.stringValue, ids.contains(id),
                  !message.toolCalls.contains(where: { $0.id == id }) else { continue }
            let name = block["name"]?.stringValue ?? ""
            let input: JSONValue?
            if case .object? = block["input"] { input = block["input"] } else { input = nil }
            let presentation = activeConfig?.toolsByName[name]?.preparingPresentation ?? .generic(toolName: name)
            message.toolCalls.append(ToolCall(id: id, name: name, input: input, presentation: presentation,
                                              status: .queued))
            changed = true
        }
        if changed { messages[index] = message }
        return ids
    }

    private func recordExchange(_ callIDs: [String], in assistantID: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == assistantID }) else { return }
        let exchange = ToolExchange(
            contentEnd: messages[index].apiContent.count,
            textEnd: messages[index].text.count,
            callIDs: callIDs
        )
        messages[index].toolExchanges.append(exchange)
    }

    /// Applies `mutate` to the given calls (and stamps their finish time).
    private func settle(_ callIDs: [String], in assistantID: UUID, _ mutate: (inout ToolCall) -> Void) {
        guard let index = messages.lastIndex(where: { $0.id == assistantID }) else { return }
        let now = clock()
        var message = messages[index]
        for callIndex in message.toolCalls.indices where callIDs.contains(message.toolCalls[callIndex].id) {
            mutate(&message.toolCalls[callIndex])
            message.toolCalls[callIndex].finishedAt = now
        }
        messages[index] = message
        refreshPhase()
    }

    private func appendNote(_ note: String, to assistantID: UUID) {
        flushPendingDeltas()
        guard let index = messages.lastIndex(where: { $0.id == assistantID }) else { return }
        messages[index].text += note
    }

    private func appendWebPauseNote(_ reason: WebPauseReason, to assistantID: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == assistantID }),
              !messages[index].activities.contains(where: { $0.id == Self.webPausedActivityID }) else { return }
        let privateSource = DisplayText.sanitized(reason.privateSource, maxLength: 80)
        let untrustedSource = DisplayText.sanitized(reason.untrustedSource, maxLength: 80)
        let label = "Web access paused for the rest of this reply: this chat now holds \(privateSource) "
            + "and text from \(untrustedSource)."
        messages[index].activities.append(ToolActivity(id: Self.webPausedActivityID, kind: .other, label: label,
                                                       isDone: true))
        Self.toolLogger.info("Web access paused for the rest of the reply")
    }

    /// Messages sent compacted: restored assistant turns whose payload is gone, and the earlier turns compacted
    /// after a request did not fit (`compactEarlierContext`).
    private func compactingIDs() -> Set<UUID> {
        textOnlyContextIDs.union(compactedContextIDs)
    }

    /// After a request failed before anything streamed, compacts the earlier turns that are not compacted yet and
    /// returns true so it is sent again: when it was too large or too long for the model (any conversation; the
    /// user messages before the one being answered also lose their attachments), or when the API rejected the
    /// content of a restored conversation (once; its stored thinking or server-tool payload may be stale). Returns
    /// false when nothing is left to compact.
    private func compactEarlierContext(after error: Error, assistantID: UUID) -> Bool {
        guard !(error is CancellationError), !Task.isCancelled, !responseDeliveredEvent else { return false }
        let overflow = Self.isContextOverflow(error)
        let restoredRejection = !restoredMessageIDs.isEmpty && !compactsRestoredContext
            && Self.isRejectedRequestContent(error)
        guard overflow || restoredRejection else { return false }
        if restoredRejection { compactsRestoredContext = true }
        let candidates = earlierContextIDs(before: assistantID, includingUserAttachments: overflow)
            .subtracting(compactingIDs())
        guard !candidates.isEmpty else { return false }
        compactedContextIDs.formUnion(candidates)
        Self.logger.info("Resending with \(candidates.count, privacy: .public) earlier messages compacted")
        return true
    }

    /// The assistant turns in the context before `assistantID`, plus (when `includingUserAttachments`) the user
    /// turns before the one being answered that hold an attachment.
    private func earlierContextIDs(before assistantID: UUID, includingUserAttachments: Bool) -> Set<UUID> {
        let end = messages.firstIndex(where: { $0.id == assistantID }) ?? messages.endIndex
        let prior = messages[..<end].filter(\.includeInContext)
        let answeredUserID = prior.last(where: { $0.role == .user })?.id
        var ids = Set<UUID>()
        for message in prior {
            switch message.role {
            case .assistant:
                ids.insert(message.id)
            case .user:
                if includingUserAttachments, message.id != answeredUserID,
                   Self.userContent(message).contains(where: { $0.typeName == "image" || $0.typeName == "document" }) {
                    ids.insert(message.id)
                }
            }
        }
        return ids
    }

    /// A request that was too large (`TurnError.requestTooLarge`, HTTP 413, `request_too_large`) or too long for
    /// the model's context window (HTTP 400 "prompt is too long").
    static func isContextOverflow(_ error: Error) -> Bool {
        if let error = error as? TurnError { return error == .requestTooLarge }
        guard let error = error as? LLMError else { return false }
        switch error {
        case .http(let status, let type, let message):
            return status == 413 || type == "request_too_large"
                || (status == 400 && message.lowercased().contains("prompt is too long"))
        case .streamError(let type, let message):
            return type == "request_too_large" || message.lowercased().contains("prompt is too long")
        default:
            return false
        }
    }

    /// What a request that still overflows once everything earlier is compacted fails with: the original error
    /// when the message being answered makes up most of it (its attachments are the problem, and `finishTurn` takes
    /// it out of the context), else `conversationTooLong`.
    private static func overflowFailure(_ error: Error, history: [JSONValue]) -> Error {
        guard let answered = AttachmentBudget.answeredUserIndex(in: history) else { return error }
        let answeredBytes = AttachmentBudget.estimatedEncodedBytes(history[answered])
        let totalBytes = AttachmentBudget.estimatedEncodedBytes(.array(history))
        return answeredBytes * 2 >= totalBytes ? error : TurnError.conversationTooLong
    }

    /// Folds one streamed response into the assistant message and returns its final result.
    private func consume(
        _ events: AsyncThrowingStream<StreamEvent, Error>,
        into assistantID: UUID
    ) async throws -> StreamResult {
        for try await event in events {
            guard isActive(assistantID) else { throw CancellationError() }
            responseDeliveredEvent = true
            apply(event, to: assistantID)
            switch event {
            case .completed(let result):
                return result
            case .toolUseStarted, .toolUseReady:
                // A response that repeats a call hundreds of times would otherwise stream (and bill) until
                // max_tokens before the round limit could apply.
                if let message = messages.last(where: { $0.id == assistantID }),
                   Self.unexchangedCallIDs(of: message).count > ToolLimits.maxStreamedCallsPerResponse {
                    throw TooManyToolCalls()
                }
            default:
                break
            }
        }
        try Task.checkCancellation()
        throw LLMError.network("The connection closed before the reply finished.")
    }

    private func apply(_ event: StreamEvent, to assistantID: UUID) {
        switch event {
        case .textDelta(let delta):
            bufferDelta(text: delta, thinking: "", for: assistantID)
            return
        case .thinkingDelta(let delta):
            bufferDelta(text: "", thinking: delta, for: assistantID)
            return
        default:
            // Everything else is applied in order after the text that streamed before it.
            flushPendingDeltas()
        }

        guard let index = messages.lastIndex(where: { $0.id == assistantID }) else { return }
        var message = messages[index]

        switch event {
        case .messageStart(let model):
            message.model = model
        case .thinkingStarted:
            message.isThinking = true
        case .thinkingDelta(let delta):
            message.thinking += delta
        case .textDelta(let delta):
            message.isThinking = false
            message.text += delta
        case .toolActivity(let activity):
            if let existing = message.activities.firstIndex(where: { $0.id == activity.id }) {
                var updated = activity
                if updated.label.isEmpty { updated.label = message.activities[existing].label }
                message.activities[existing] = updated
            } else {
                message.activities.append(activity)
            }
        case .sources(let links):
            var known = Set(message.sources.map(\.id))
            for link in links where known.insert(link.id).inserted {
                message.sources.append(link)
            }
        case .fallback(_, let toModel):
            if let toModel { message.model = toModel }
        case .completed(let result):
            message.apiContent.append(contentsOf: result.content)
            if message.model == nil { message.model = result.model }
        case .toolUseStarted(let id, let name):
            guard !message.toolCalls.contains(where: { $0.id == id }) else { return }
            let presentation = activeConfig?.toolsByName[name]?.preparingPresentation ?? .generic(toolName: name)
            message.toolCalls.append(ToolCall(id: id, name: name, presentation: presentation, status: .preparing))
        case .toolUseReady(let id, let name, let input, let rawInput):
            // The executor writes the real presentation once the input has been validated.
            let invalidInput = input == nil ? String(rawInput.prefix(ToolLimits.maxInvalidInputEcho)) : nil
            if let existing = message.toolCalls.firstIndex(where: { $0.id == id }) {
                message.toolCalls[existing].input = input
                message.toolCalls[existing].invalidInput = invalidInput
                message.toolCalls[existing].status = .queued
            } else {
                let presentation = activeConfig?.toolsByName[name]?.preparingPresentation ?? .generic(toolName: name)
                message.toolCalls.append(ToolCall(
                    id: id,
                    name: name,
                    input: input,
                    invalidInput: invalidInput,
                    presentation: presentation,
                    status: .queued
                ))
            }
        case .usage(let usage):
            // Usage never changes the message; it is only remembered for accounting.
            inFlightUsage = usage
            return
        }

        messages[index] = message
        refreshPhase()
    }

    // MARK: - Usage

    /// Records one finished Messages API response: its own usage, else the latest `.usage` it streamed.
    /// A response that reported no usage at all is not recorded.
    private func recordCompletedUsage(_ result: StreamResult, requestedModel: String, assistantID: UUID) {
        let usage = result.usage ?? inFlightUsage
        inFlightUsage = nil
        guard let usage, let usageRecorder else { return }
        usageRecorder.record(
            usage: usage,
            requestedModel: requestedModel,
            servedModel: result.model,
            stopReason: result.stopReason,
            isPartial: false,
            messageID: assistantID,
            at: Date()
        )
    }

    /// Closes the usage books of a turn that is ending: a response cut off after it reported usage is
    /// recorded as partial, then the answer is finished.
    private func settleUsage(for assistantID: UUID) {
        let usage = inFlightUsage
        let requestedModel = inFlightRequestedModel
        inFlightUsage = nil
        inFlightRequestedModel = nil
        guard let usageRecorder else { return }
        if let usage, let requestedModel {
            usageRecorder.record(
                usage: usage,
                requestedModel: requestedModel,
                servedModel: messages.last(where: { $0.id == assistantID })?.model,
                stopReason: nil,
                isPartial: true,
                messageID: assistantID,
                at: Date()
            )
        }
        usageRecorder.finishAnswer(messageID: assistantID)
    }

    // MARK: - Delta coalescing

    /// Queues streamed text/thinking and writes it into the message at most every
    /// `deltaFlushInterval`. The first text (or thinking) of a message is written at once so the
    /// "Thinking…" row and caret react immediately.
    private func bufferDelta(text: String, thinking: String, for assistantID: UUID) {
        if pendingDeltas.assistantID != assistantID {
            flushPendingDeltas()
            pendingDeltas = PendingDeltas(assistantID: assistantID)
        }
        pendingDeltas.text += text
        pendingDeltas.thinking += thinking

        let message = messages.last(where: { $0.id == assistantID })
        let startsField = (!text.isEmpty && message?.text.isEmpty == true)
            || (!thinking.isEmpty && message?.thinking.isEmpty == true)
        guard !startsField,
              let elapsed = lastDeltaFlush.map({ ContinuousClock.now - $0 }),
              elapsed < Self.deltaFlushInterval else {
            flushPendingDeltas()
            return
        }
        guard deltaFlushTask == nil else { return }
        let delay = Self.deltaFlushInterval - elapsed
        deltaFlushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.deltaFlushTask = nil
            self.flushPendingDeltas()
        }
    }

    /// Writes any queued deltas into their message now.
    private func flushPendingDeltas() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        guard let assistantID = pendingDeltas.assistantID, !pendingDeltas.isEmpty else { return }
        let pending = pendingDeltas
        pendingDeltas = PendingDeltas(assistantID: assistantID)
        lastDeltaFlush = ContinuousClock.now
        guard let index = messages.lastIndex(where: { $0.id == assistantID }) else { return }
        var message = messages[index]
        // Only the first text of a message (or text after a thinking block) can move the phase; later
        // deltas leave it alone so a long reply doesn't re-derive it per flush.
        let movesPhase = !pending.text.isEmpty && (message.text.isEmpty || message.isThinking)
        if !pending.thinking.isEmpty {
            message.thinking += pending.thinking
        }
        if !pending.text.isEmpty {
            message.isThinking = false
            message.text += pending.text
        }
        messages[index] = message
        if movesPhase { refreshPhase() }
        if !pending.text.isEmpty {
            onAssistantTextProgress?(assistantID, message.text, false)
        }
    }

    /// Drops queued deltas (the conversation was replaced or a new turn starts).
    private func discardPendingDeltas() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        pendingDeltas = PendingDeltas()
        lastDeltaFlush = nil
    }

    private func finishTurn(_ assistantID: UUID, outcome: TurnOutcome) {
        guard isActive(assistantID) else { return }
        flushPendingDeltas()
        discardPendingDeltas()
        activeAssistantID = nil
        activeConfig = nil
        streamTask = nil

        var completedText: String?
        if let index = messages.lastIndex(where: { $0.id == assistantID }) {
            var message = messages[index]
            message.isThinking = false
            // The turn is over whatever the outcome: a tool call whose result never arrived (stopped,
            // failed, cut off, or still pending at the pause_turn cap) must not keep spinning.
            for activityIndex in message.activities.indices {
                message.activities[activityIndex].isDone = true
            }
            settleOpenToolCalls(in: &message, outcome: outcome)
            let userIndex = messages[..<index].lastIndex(where: { $0.role == .user })

            switch outcome {
            case .completed(let stopReason):
                switch stopReason {
                case "refusal":
                    // A mid-stream decline: discard the partial output so the refusal copy is all
                    // that is shown (and nothing cut off can be copied). Actions that already ran stay
                    // visible under "Done before Otto stopped".
                    message.text = ""
                    message.thinking = ""
                    message.activities = []
                    message.sources = []
                    message.apiContent = []
                    message.toolExchanges = []
                    message.toolCalls = message.toolCalls.filter(Self.hasRun)
                    message.state = .refused(Self.refusalMessage)
                    message.includeInContext = false
                    if let userIndex {
                        messages[userIndex].includeInContext = false
                    }
                case "max_tokens":
                    message.state = .complete
                    message.text += Self.truncationNote
                case "pause_turn":
                    // Only reached after `maxPauseContinuations`: the answer is incomplete.
                    message.state = .complete
                    message.text += Self.pauseLimitNote
                default:
                    message.state = .complete
                }
            case .cancelled:
                message.state = .cancelled
            case .failed(let error):
                var description = error.localizedDescription
                Self.logger.error("Reply failed: \(description, privacy: .public)")
                let rejected = Self.isRejectedRequestContent(error)
                // Actions that already ran must stay in the context, or Claude would repeat them; a request the
                // API rejected for its content leaves it (its user message too, below).
                message.includeInContext = !message.toolExchanges.isEmpty && !rejected
                // When the request was rejected for its content (an attachment the API can't process,
                // a request that is too large or too long), resending that user message would fail
                // every later turn the same way, so it leaves the context too. Retry re-includes it.
                if rejected, let userIndex, messages[userIndex].includeInContext {
                    messages[userIndex].includeInContext = false
                    description += " " + Self.excludedFromContextNote
                }
                message.state = .failed(description)
            }
            messages[index] = message

            if message.state == .complete {
                completedText = message.text
                if let userIndex, var versions = lastTurnVersions, versions.userMessageID == messages[userIndex].id,
                   Self.isStorableVersion(message) {
                    versions.replies.append(message)
                    versions.currentIndex = versions.replies.count - 1
                    lastTurnVersions = versions
                }
            }
        }

        isStreaming = false
        updateSummary(recomputeCopyable: true)
        settleUsage(for: assistantID)
        lastFinishedAssistantID = assistantID
        refreshPhase()
        refreshSystemUIToolWait()
        if let completedText {
            onAssistantTextProgress?(assistantID, completedText, true)
        }
        onTranscriptChanged?(.turnFinished)
        onReplyFinished?()
    }

    /// Gives every call that is not terminal yet its final status. A call inside an exchange also gets the
    /// result sent back for it, so every exchange stays complete.
    private func settleOpenToolCalls(in message: inout ChatMessage, outcome: TurnOutcome) {
        let exchanged = Set(message.toolExchanges.flatMap(\.callIDs))
        let now = clock()
        for index in message.toolCalls.indices where !message.toolCalls[index].status.isTerminal {
            let inExchange = exchanged.contains(message.toolCalls[index].id)
            switch outcome {
            case .cancelled:
                let wasRunning: Bool
                switch message.toolCalls[index].status {
                case .running, .waitingForSystem: wasRunning = true
                default: wasRunning = false
                }
                message.toolCalls[index].status = .cancelled
                message.toolCalls[index].result = .error(
                    wasRunning ? ToolHistory.Copy.cancelledWhileRunning : ToolHistory.Copy.cancelledBeforeRun
                )
            case .completed, .failed:
                message.toolCalls[index].status = .skipped(inExchange ? "Reply ended early" : "Reply was cut off")
                message.toolCalls[index].result = inExchange ? .error(ToolHistory.Copy.cancelledBeforeRun) : nil
            }
            message.toolCalls[index].finishedAt = now
        }
    }

    /// Calls whose side effect may have happened: kept visible when a reply is refused.
    private static func hasRun(_ call: ToolCall) -> Bool {
        switch call.status {
        case .succeeded, .failed, .undone: return true
        default: return false
        }
    }

    private func isActive(_ assistantID: UUID) -> Bool {
        activeAssistantID == assistantID
    }

    /// Whether the API rejected the request because of what it contains (HTTP 400/413,
    /// `invalid_request_error`, `request_too_large`), as opposed to a transient failure (network,
    /// 429, 5xx, overloaded) where resending the same content may succeed.
    static func isRejectedRequestContent(_ error: Error) -> Bool {
        if let error = error as? TurnError { return error == .requestTooLarge }
        guard let error = error as? LLMError else { return false }
        let contentErrorTypes: Set<String> = ["invalid_request_error", "request_too_large"]
        switch error {
        case .http(let status, let type, _):
            return status == 400 || status == 413 || type.map(contentErrorTypes.contains) == true
        case .streamError(let type, _):
            return type.map(contentErrorTypes.contains) == true
        case .missingAPIKey, .invalidAPIKey, .rateLimited, .overloaded, .network, .decoding:
            return false
        }
    }

    // MARK: - History

    /// The `messages` array for a request made on behalf of the assistant message `inFlight`.
    ///
    /// Only messages before `inFlight` are considered (all messages when it is nil or absent); the
    /// in-flight message itself is included when resuming a `pause_turn` or once it has tool exchanges
    /// (`ToolHistory.entries`). Messages with `includeInContext == false` are skipped; when `model` is given,
    /// earlier user turns holding a PDF over that model's page limit send their attachments as notes; user
    /// turns send their `apiContent` (with attachments of earlier turns replaced by a short note once the
    /// request budget is used up — see `fittingAttachmentBudget`), and assistant turns are rendered by
    /// `ToolHistory` (tool rounds of tools outside `clientToolNames` as `<earlier_action_result>` blocks).
    /// Messages in `compacting` are sent compacted: an assistant turn as its visible text only, an earlier user turn
    /// without its attachments (the one being answered is never changed).
    /// `enabledServerTools` nil keeps every complete server-tool pair (the executor's trust transcript). Consecutive
    /// same-role turns are left as they are (the API merges them); leading assistant turns are dropped
    /// because a conversation must start with the user.
    static func requestHistory(
        for messages: [ChatMessage],
        inFlight: UUID?,
        resumingInFlight: Bool,
        enabledServerTools: Set<String>?,
        clientToolNames: Set<String> = [],
        model: ModelOption? = nil,
        compacting: Set<UUID> = []
    ) -> [JSONValue] {
        let inFlightIndex = inFlight.flatMap { id in messages.firstIndex(where: { $0.id == id }) }
        let prior = messages[..<(inFlightIndex ?? messages.endIndex)]
        // The user message being answered is sent as it is; see below for earlier ones.
        let answeredUserID = prior.last(where: { $0.role == .user && $0.includeInContext })?.id

        var entries: [ToolHistory.Entry] = []
        var answeredUserEntry: Int?
        for message in prior where message.includeInContext {
            switch message.role {
            case .user:
                let content: [JSONValue]
                // A PDF over the model's page limit (e.g. attached for Opus, then switched to Haiku
                // 4.5) would get every later request rejected; earlier turns send a note instead.
                if message.id != answeredUserID, compacting.contains(message.id) {
                    content = AttachmentBudget.strippingAttachments(from: userContent(message))
                } else if let model, message.id != answeredUserID,
                   message.attachments.contains(where: { AttachmentBudget.exceedsPageLimit($0, model: model) }) {
                    content = AttachmentBudget.strippingAttachments(from: userContent(message))
                } else {
                    content = userContent(message)
                }
                if !content.isEmpty {
                    if message.id == answeredUserID { answeredUserEntry = entries.endIndex }
                    entries.append((.user, content))
                }
            case .assistant:
                if compacting.contains(message.id) {
                    let content = ToolHistory.compactedContent(forAssistant: message)
                    if !content.isEmpty { entries.append((.assistant, content)) }
                } else {
                    entries += ToolHistory.entries(
                        for: message,
                        enabledServerTools: enabledServerTools,
                        clientToolNames: clientToolNames,
                        isInFlight: false,
                        resuming: false
                    )
                }
            }
        }

        if let inFlightIndex {
            entries += ToolHistory.entries(
                for: messages[inFlightIndex],
                enabledServerTools: enabledServerTools,
                clientToolNames: clientToolNames,
                isInFlight: true,
                resuming: resumingInFlight
            )
        }

        var dropped = 0
        while let first = entries.first, first.role == .assistant {
            entries.removeFirst()
            dropped += 1
        }
        let newestUser = answeredUserEntry.map { $0 - dropped }
        fittingAttachmentBudget(&entries, newestUser: newestUser)
        return entries.map { entry(role: $0.role, content: $0.content) }
    }

    /// Content sent for a finished assistant turn without tool exchanges, or [] to leave the turn out
    /// (`ToolHistory.contextContent(forAssistant:enabledServerTools:)`).
    static func contextContent(forAssistant message: ChatMessage, enabledServerTools: Set<String>) -> [JSONValue] {
        ToolHistory.contextContent(forAssistant: message, enabledServerTools: enabledServerTools)
    }

    /// `ToolHistory.sanitizedAssistantContent(_:)`.
    static func sanitizedAssistantContent(_ content: [JSONValue]) -> [JSONValue] {
        ToolHistory.sanitizedAssistantContent(content)
    }

    /// `ToolHistory.textBlock(_:)`.
    static func textBlock(_ text: String) -> JSONValue {
        ToolHistory.textBlock(text)
    }

    // MARK: History helpers

    private static func userContent(_ message: ChatMessage) -> [JSONValue] {
        if !message.apiContent.isEmpty { return message.apiContent }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [textBlock(text)]
    }

    /// Keeps the request inside `maxRequestAttachmentBytes`, and earlier turns' text documents
    /// inside `maxHistoryTextDocumentBytes`, by replacing attachment blocks of the oldest user turns
    /// with a short text note. The newest user message (`newestUser`, else the last user entry) is never
    /// trimmed: if it alone is too big the API says so, and `finishTurn` takes it out of the context. Tool
    /// results that follow it in a tool loop are not user messages and are never trimmed here.
    private static func fittingAttachmentBudget(_ entries: inout [ToolHistory.Entry], newestUser: Int?) {
        guard let newestUser = newestUser ?? entries.lastIndex(where: { $0.role == .user }),
              entries.indices.contains(newestUser) else { return }
        var totalBytes = entries[newestUser].content.reduce(0) { $0 + attachmentPayloadBytes($1) }
        var historyTextBytes = 0

        for index in entries.indices.reversed() where index < newestUser && entries[index].role == .user {
            entries[index].content = entries[index].content.map { block in
                let bytes = attachmentPayloadBytes(block)
                guard bytes > 0 else { return block }
                let isTextDocument = block["source"]?["type"]?.stringValue == "text"
                let fits = totalBytes + bytes <= maxRequestAttachmentBytes
                    && (!isTextDocument || historyTextBytes + bytes <= maxHistoryTextDocumentBytes)
                guard fits else { return omittedAttachmentNote(for: block) }
                totalBytes += bytes
                if isTextDocument { historyTextBytes += bytes }
                return block
            }
        }
    }

    /// Size of an image/document block's data (base64 or text); 0 for every other block.
    private static func attachmentPayloadBytes(_ block: JSONValue) -> Int {
        guard block.typeName == "image" || block.typeName == "document",
              let data = block["source"]?["data"]?.stringValue else { return 0 }
        return data.utf8.count
    }

    private static func omittedAttachmentNote(for block: JSONValue) -> JSONValue {
        let title = block["title"]?.stringValue ?? (block.typeName == "image" ? "an image" : "a document")
        return textBlock("[Earlier attachment omitted to keep the conversation within limits: \(title)]")
    }

    private static func entry(role: ChatRole, content: [JSONValue]) -> JSONValue {
        ["role": .string(role.rawValue), "content": .array(content)]
    }
}
