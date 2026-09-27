//
//  ChatSession.swift
//  Otto
//
//  Owns the conversation: builds Messages API history, streams replies into the in-flight assistant
//  message, and handles pause_turn continuations, refusals, cancellation and retries. It also reports
//  the transcript to History, the reply phase to the closed notch and token usage to the ledger.
//

import Foundation
import Observation
import os

@MainActor @Observable final class ChatSession {
    /// Automatic `pause_turn` continuations allowed per turn.
    static let maxPauseContinuations = 5
    static let refusalMessage = "Otto can't help with that one."
    static let truncationNote = "\n\n_(Reply truncated.)_"
    /// Appended when a turn still wanted to continue after `maxPauseContinuations`.
    static let pauseLimitNote = "\n\n_(Stopped after several web lookups.)_"
    /// Appended to the failure copy when the user message that caused it is left out of the context.
    static let excludedFromContextNote = "Otto left this message out of the conversation so you can keep chatting."
    /// Text block sent when the user attached items without typing anything.
    static let attachmentsOnlyPrompt = "Please take a look at the attached."

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
    /// Whether requests send the restored messages as text only (after the API rejected them as they were).
    @ObservationIgnored private var compactsRestoredContext = false

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
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    /// The assistant message the running task writes into. A task whose id no longer matches (after
    /// `cancel()` / `reset()`) must not touch any state — it is only winding down.
    @ObservationIgnored private var activeAssistantID: UUID?

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

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Chat")

    init(settings: AppSettings, makeClient: @escaping @MainActor () throws -> LLMClient) {
        self.settings = settings
        self.makeClient = makeClient
        conversationID = UUID()
        conversationCreatedAt = Date()
        unavailableAttachmentIDs = []
    }

    // MARK: - Public API

    func send(text: String, attachments: [Attachment]) {
        guard !isStreaming else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        var content = attachments.flatMap { $0.contentBlocks() }
        content.append(Self.textBlock(trimmed.isEmpty ? Self.attachmentsOnlyPrompt : trimmed))
        messages.append(ChatMessage(role: .user, text: trimmed, attachments: attachments, apiContent: content))
        beginAssistantTurn(at: messages.endIndex)
        onTranscriptChanged?(.userMessageAdded)
    }

    /// Stops the in-flight reply. The message keeps whatever streamed so far and becomes `.cancelled`.
    func cancel() {
        if let id = activeAssistantID {
            streamTask?.cancel()
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

    /// Re-runs a failed, cancelled or refused assistant turn in place.
    func retry(messageID: UUID) {
        guard !isStreaming, let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let message = messages[index]
        guard message.role == .assistant else { return }
        switch message.state {
        case .failed, .cancelled, .refused:
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
        beginAssistantTurn(at: index)
    }

    /// Cancels any reply and clears the conversation, which starts a new one with a new id. History hears
    /// `.willReset` first (while the old transcript is still here) unless there was nothing to save.
    func reset() {
        flushPendingDeltas()
        if !messages.isEmpty { onTranscriptChanged?(.willReset) }
        if let id = activeAssistantID { settleUsage(for: id) }
        streamTask?.cancel()
        streamTask = nil
        activeAssistantID = nil
        discardPendingDeltas()
        messages.removeAll()
        isStreaming = false
        updateSummary(recomputeCopyable: true)
        conversationID = UUID()
        conversationCreatedAt = Date()
        if !unavailableAttachmentIDs.isEmpty { unavailableAttachmentIDs = [] }
        textOnlyContextIDs = []
        restoredMessageIDs = []
        compactsRestoredContext = false
        refreshPhase()
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
        isStreaming = false
        updateSummary(recomputeCopyable: true)
        refreshPhase()
        Self.logger.info("Loaded conversation \(conversation.id.uuidString, privacy: .public) with \(conversation.messages.count, privacy: .public) messages")
        onTranscriptChanged?(.loaded)
    }

    /// Snapshots/tests only: replaces the conversation without starting any work.
    func debugSeed(messages: [ChatMessage], isStreaming: Bool) {
        streamTask?.cancel()
        streamTask = nil
        activeAssistantID = nil
        discardPendingDeltas()
        inFlightUsage = nil
        inFlightRequestedModel = nil
        self.messages = messages
        self.isStreaming = isStreaming
        updateSummary(recomputeCopyable: true)
        refreshPhase()
    }

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

    private struct TurnConfig {
        let model: ModelOption
        let effort: EffortLevel
        let webAccess: Bool
        let system: String

        /// Names of the server tools whose blocks this request accepts in history.
        var enabledServerTools: Set<String> {
            ChatSession.serverToolNames(model: model, webAccess: webAccess)
        }
    }

    /// Names of the server tools a request with this model and web setting defines. The 2026 web
    /// tools run dynamic filtering, which emits `code_execution` calls of its own.
    nonisolated static func serverToolNames(model: ModelOption, webAccess: Bool) -> Set<String> {
        guard webAccess else { return [] }
        var names: Set<String> = ["web_search"]
        if model.webFetchToolType != nil { names.insert("web_fetch") }
        if model.webSearchToolType == "web_search_20260209" { names.insert("code_execution") }
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

        var errorDescription: String? {
            switch self {
            case .nothingToSend: return "There's no message for Otto to reply to."
            case .requestTooLarge: return AttachmentBudget.requestTooLargeDescription
            }
        }
    }

    private func beginAssistantTurn(at index: Int) {
        let assistant = ChatMessage(role: .assistant, state: .streaming)
        messages.insert(assistant, at: min(max(index, 0), messages.endIndex))
        activeAssistantID = assistant.id
        isStreaming = true
        discardPendingDeltas()
        updateSummary(recomputeCopyable: false)

        // Captured once so pause_turn continuations resend an identical prefix (same model, tools and
        // system prompt) even if settings change mid-turn.
        let config = TurnConfig(
            model: settings.model,
            effort: settings.effort,
            webAccess: settings.webAccess,
            system: SystemPrompt.make(settings: settings)
        )
        inFlightUsage = nil
        inFlightRequestedModel = config.model.rawValue
        refreshPhase()
        let assistantID = assistant.id
        streamTask = Task { [weak self] in
            await self?.runTurn(assistantID: assistantID, config: config)
        }
    }

    private func runTurn(assistantID: UUID, config: TurnConfig) async {
        guard isActive(assistantID) else { return }

        let client: LLMClient
        do {
            client = try makeClient()
        } catch {
            finishTurn(assistantID, outcome: .failed(error))
            return
        }

        var continuations = 0
        do {
            while true {
                try Task.checkCancellation()
                let resuming = continuations > 0
                flushPendingDeltas()
                inFlightUsage = nil
                let fullHistory = Self.requestHistory(
                    for: messages,
                    inFlight: assistantID,
                    resumingInFlight: resuming,
                    enabledServerTools: config.enabledServerTools,
                    model: config.model
                )
                // The whole request must stay under the API's size limit: earlier turns' attachments
                // give way first; if the new message alone is too big it can't be sent at all.
                guard let history = AttachmentBudget.fitting(fullHistory) else {
                    throw TurnError.requestTooLarge
                }
                // A fresh request must end on a user turn; only a pause_turn continuation may end on
                // the (partial) assistant turn.
                guard let lastRole = history.last?["role"]?.stringValue,
                      lastRole == (resuming ? "assistant" : "user") else {
                    throw TurnError.nothingToSend
                }

                let request = MessagesRequest(
                    model: config.model,
                    system: config.system,
                    messages: history,
                    maxTokens: config.model.maxOutputTokens,
                    effort: config.effort,
                    webAccess: config.webAccess
                )
                let result = try await consume(client.stream(request), into: assistantID)
                guard isActive(assistantID) else { return }
                recordCompletedUsage(result, requestedModel: config.model.rawValue, assistantID: assistantID)

                if result.stopReason == "pause_turn", continuations < Self.maxPauseContinuations {
                    continuations += 1
                    continue
                }
                finishTurn(assistantID, outcome: .completed(stopReason: result.stopReason))
                return
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                finishTurn(assistantID, outcome: .cancelled)
            } else {
                finishTurn(assistantID, outcome: .failed(error))
            }
        }
    }

    /// Folds one streamed response into the assistant message and returns its final result.
    private func consume(
        _ events: AsyncThrowingStream<StreamEvent, Error>,
        into assistantID: UUID
    ) async throws -> StreamResult {
        for try await event in events {
            guard isActive(assistantID) else { throw CancellationError() }
            apply(event, to: assistantID)
            if case .completed(let result) = event {
                return result
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
            message.toolCalls.append(ToolCall(
                id: id,
                name: name,
                presentation: .generic(toolName: name),
                status: .preparing
            ))
        case .toolUseReady(let id, let name, let input, let rawInput):
            let invalidInput = input == nil ? String(rawInput.prefix(ToolLimits.maxInvalidInputEcho)) : nil
            if let existing = message.toolCalls.firstIndex(where: { $0.id == id }) {
                message.toolCalls[existing].input = input
                message.toolCalls[existing].invalidInput = invalidInput
                message.toolCalls[existing].status = .queued
            } else {
                message.toolCalls.append(ToolCall(
                    id: id,
                    name: name,
                    input: input,
                    invalidInput: invalidInput,
                    presentation: .generic(toolName: name),
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
        streamTask = nil

        if let index = messages.lastIndex(where: { $0.id == assistantID }) {
            var message = messages[index]
            message.isThinking = false
            // The turn is over whatever the outcome: a tool call whose result never arrived (stopped,
            // failed, cut off, or still pending at the pause_turn cap) must not keep spinning.
            for activityIndex in message.activities.indices {
                message.activities[activityIndex].isDone = true
            }
            let userIndex = messages[..<index].lastIndex(where: { $0.role == .user })

            switch outcome {
            case .completed(let stopReason):
                switch stopReason {
                case "refusal":
                    // A mid-stream decline: discard the partial output so the refusal copy is all
                    // that is shown (and nothing cut off can be copied).
                    message.text = ""
                    message.thinking = ""
                    message.activities = []
                    message.sources = []
                    message.apiContent = []
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
                message.includeInContext = false
                // When the request was rejected for its content (an attachment the API can't process,
                // a request that is too large or too long), resending that user message would fail
                // every later turn the same way, so it leaves the context too. Retry re-includes it.
                if Self.isRejectedRequestContent(error), let userIndex, messages[userIndex].includeInContext {
                    messages[userIndex].includeInContext = false
                    description += " " + Self.excludedFromContextNote
                }
                message.state = .failed(description)
            }
            messages[index] = message
        }

        isStreaming = false
        updateSummary(recomputeCopyable: true)
        settleUsage(for: assistantID)
        lastFinishedAssistantID = assistantID
        refreshPhase()
        onTranscriptChanged?(.turnFinished)
        onReplyFinished?()
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
    /// in-flight message itself is appended only when resuming a `pause_turn`. Messages with
    /// `includeInContext == false` are skipped; when `model` is given, earlier user turns holding a PDF
    /// over that model's page limit send their attachments as notes; user turns send their `apiContent` (with attachments
    /// of earlier turns replaced by a short note once the request budget is used up — see
    /// `fittingAttachmentBudget`), and assistant turns are rendered by
    /// `contextContent(forAssistant:enabledServerTools:)`. Consecutive same-role turns are left as
    /// they are (the API merges them); leading assistant turns are dropped because a conversation
    /// must start with the user.
    static func requestHistory(
        for messages: [ChatMessage],
        inFlight: UUID?,
        resumingInFlight: Bool,
        enabledServerTools: Set<String>,
        model: ModelOption? = nil
    ) -> [JSONValue] {
        let inFlightIndex = inFlight.flatMap { id in messages.firstIndex(where: { $0.id == id }) }
        let prior = messages[..<(inFlightIndex ?? messages.endIndex)]
        // The user message being answered is sent as it is; see below for earlier ones.
        let answeredUserID = prior.last(where: { $0.role == .user && $0.includeInContext })?.id

        var entries: [(role: ChatRole, content: [JSONValue])] = []
        for message in prior where message.includeInContext {
            let content: [JSONValue]
            switch message.role {
            case .user:
                // A PDF over the model's page limit (e.g. attached for Opus, then switched to Haiku
                // 4.5) would get every later request rejected; earlier turns send a note instead.
                if let model, message.id != answeredUserID,
                   message.attachments.contains(where: { AttachmentBudget.exceedsPageLimit($0, model: model) }) {
                    content = AttachmentBudget.strippingAttachments(from: userContent(message))
                } else {
                    content = userContent(message)
                }
            case .assistant:
                content = contextContent(forAssistant: message, enabledServerTools: enabledServerTools)
            }
            if !content.isEmpty {
                entries.append((message.role, content))
            }
        }

        if resumingInFlight, let inFlightIndex {
            let content = resumedContent(messages[inFlightIndex])
            if !content.isEmpty {
                entries.append((.assistant, content))
            }
        }

        while let first = entries.first, first.role == .assistant {
            entries.removeFirst()
        }
        fittingAttachmentBudget(&entries)
        return entries.map { entry(role: $0.role, content: $0.content) }
    }

    /// Content sent for a finished assistant turn, or [] to leave the turn out.
    ///
    /// - `.complete`: the sanitized API content, with server-tool calls reduced to complete
    ///   call/result pairs for tools this request defines (a call issued by a dropped call goes with
    ///   it) and unsigned thinking dropped. A turn left with nothing but thinking is skipped.
    /// - `.cancelled`: a single text block with the visible text, if there is any.
    /// - `.refused` / `.failed` / `.streaming`: never sent.
    static func contextContent(forAssistant message: ChatMessage, enabledServerTools: Set<String>) -> [JSONValue] {
        switch message.state {
        case .complete:
            let blocks = pairedServerToolBlocks(
                withoutUnsignedThinking(sanitizedAssistantContent(message.apiContent)),
                allowedTools: enabledServerTools
            )
            return blocks.contains(where: { !isThinkingBlock($0) }) ? blocks : []
        case .cancelled:
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [textBlock(text)]
        case .streaming, .refused, .failed:
            return []
        }
    }

    /// Applies the fallback boundary and drops empty text blocks.
    ///
    /// If a `fallback` block exists, the content before the last one came from the model that was
    /// replaced: of it only `text` blocks and complete server-tool call/result pairs are kept (the
    /// text's citations point into those results); thinking, `tool_use`, unpaired `server_tool_use`
    /// and anything unknown is dropped. All `fallback` blocks are dropped, and so are text blocks with
    /// no non-whitespace text (the API rejects them).
    static func sanitizedAssistantContent(_ content: [JSONValue]) -> [JSONValue] {
        var blocks = content
        if let lastFallback = blocks.lastIndex(where: { $0.typeName == "fallback" }) {
            let before = Array(blocks[..<lastFallback])
            let pairedCalls = keptServerToolCalls(in: before, allowedTools: nil, keepPendingCalls: false)
            let kept = before.filter { block in
                if block.typeName == "text" { return true }
                if let id = serverToolCallID(of: block) { return pairedCalls.contains(id) }
                return false
            }
            blocks = kept + blocks[lastFallback...]
        }
        return blocks.filter { block in
            switch block.typeName {
            case "fallback":
                return false
            case "text":
                let text = block["text"]?.stringValue ?? ""
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return true
            }
        }
    }

    // MARK: History helpers

    private static func userContent(_ message: ChatMessage) -> [JSONValue] {
        if !message.apiContent.isEmpty { return message.apiContent }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [textBlock(text)]
    }

    /// Content for the partial in-flight assistant turn when continuing after `pause_turn`.
    ///
    /// The API only resumes a paused turn that is sent back as it came, ending in the pending
    /// server-tool call, so no tool filtering happens here (the turn's tool set is fixed by its
    /// `TurnConfig`). Unsigned thinking is still dropped, and trailing whitespace is trimmed from a
    /// final text block because the API rejects a final assistant turn ending in whitespace.
    private static func resumedContent(_ message: ChatMessage) -> [JSONValue] {
        var blocks = withoutUnsignedThinking(sanitizedAssistantContent(message.apiContent))
        if let last = blocks.last, last.typeName == "text", let text = last["text"]?.stringValue {
            blocks.removeLast()
            let trimmed = trimmingTrailingWhitespace(text)
            if !trimmed.isEmpty {
                blocks.append(last.setting("text", to: .string(trimmed)))
            }
        }
        return blocks
    }

    /// Keeps only complete call/result pairs of tools the request defines (the API rejects history
    /// that uses undefined tools, e.g. after web access was switched off or on Haiku). A call issued by
    /// another call (`caller.tool_id`, e.g. a search run inside dynamic filtering) goes with it.
    private static func pairedServerToolBlocks(_ blocks: [JSONValue], allowedTools: Set<String>) -> [JSONValue] {
        let keptCalls = keptServerToolCalls(in: blocks, allowedTools: allowedTools, keepPendingCalls: false)
        return blocks.filter { block in
            guard let id = serverToolCallID(of: block) else {
                // A server-tool block without an id can't be paired; drop it rather than send it.
                return block.typeName != "server_tool_use" && !isServerToolResult(block)
            }
            return keptCalls.contains(id)
        }
    }

    /// Ids of the `server_tool_use` calls in `blocks` worth keeping: the tool is in `allowedTools`
    /// (any tool when nil), its `*_tool_result` is present unless `keepPendingCalls`, and the call
    /// that issued it (`caller.tool_id`), if any, is itself kept.
    private static func keptServerToolCalls(
        in blocks: [JSONValue],
        allowedTools: Set<String>?,
        keepPendingCalls: Bool
    ) -> Set<String> {
        var calls: [String: (name: String, callerID: String?)] = [:]
        var resultIDs: Set<String> = []
        for block in blocks {
            if block.typeName == "server_tool_use", let id = block["id"]?.stringValue {
                calls[id] = (block["name"]?.stringValue ?? "", block["caller"]?["tool_id"]?.stringValue)
            } else if isServerToolResult(block), let id = block["tool_use_id"]?.stringValue {
                resultIDs.insert(id)
            }
        }

        var kept = Set(calls.compactMap { id, call -> String? in
            if let allowedTools, !allowedTools.contains(call.name) { return nil }
            guard keepPendingCalls || resultIDs.contains(id) else { return nil }
            return id
        })
        // Drop calls whose issuing call was dropped (or is missing), until nothing changes.
        var changed = true
        while changed {
            changed = false
            for id in kept {
                if let callerID = calls[id]?.callerID, !kept.contains(callerID) {
                    kept.remove(id)
                    changed = true
                }
            }
        }
        return kept
    }

    /// The call id a server-tool block belongs to: `id` of a `server_tool_use`, `tool_use_id` of a
    /// `*_tool_result`; nil for every other block.
    private static func serverToolCallID(of block: JSONValue) -> String? {
        if block.typeName == "server_tool_use" { return block["id"]?.stringValue }
        if isServerToolResult(block) { return block["tool_use_id"]?.stringValue }
        return nil
    }

    /// Keeps the request inside `maxRequestAttachmentBytes`, and earlier turns' text documents
    /// inside `maxHistoryTextDocumentBytes`, by replacing attachment blocks of the oldest user turns
    /// with a short text note. The newest user turn is never trimmed: if it alone is too big the API
    /// says so, and `finishTurn` takes it out of the context.
    private static func fittingAttachmentBudget(_ entries: inout [(role: ChatRole, content: [JSONValue])]) {
        guard let newestUser = entries.lastIndex(where: { $0.role == .user }) else { return }
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

    /// Thinking cut off before its signature arrived (e.g. max_tokens mid-thought) cannot be
    /// verified by the API, so it is not sent back.
    private static func withoutUnsignedThinking(_ blocks: [JSONValue]) -> [JSONValue] {
        blocks.filter { block in
            guard block.typeName == "thinking" else { return true }
            return !(block["signature"]?.stringValue ?? "").isEmpty
        }
    }

    private static func isServerToolResult(_ block: JSONValue) -> Bool {
        guard let type = block.typeName else { return false }
        return type.hasSuffix("_tool_result")
    }

    private static func isThinkingBlock(_ block: JSONValue) -> Bool {
        block.typeName == "thinking" || block.typeName == "redacted_thinking"
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var result = text
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        return result
    }

    private static func entry(role: ChatRole, content: [JSONValue]) -> JSONValue {
        ["role": .string(role.rawValue), "content": .array(content)]
    }

    static func textBlock(_ text: String) -> JSONValue {
        ["type": "text", "text": .string(text)]
    }
}
