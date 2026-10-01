//
//  MessageRows.swift
//  Otto
//
//  One conversation turn on iPhone, in the Mac's look: questions are soft clay plates on the right (long press
//  to copy or edit the last one); replies are unboxed text with thinking, web activity, the reply itself, its
//  sources and a footer of actions (copy, share, read aloud, regenerate, versions) with the model and cost.
//

import SwiftUI

struct MessageRow: View, Equatable {
    let message: ChatMessage
    let model: ChatScreenModel
    /// The newest turn.
    var isLast: Bool
    /// The last question, while no reply streams: it can be edited.
    var isEditable: Bool
    /// User turns: attachments History no longer keeps a copy of.
    var unavailableAttachmentIDs: Set<UUID>
    /// The last reply of a regenerated turn: where it sits among the kept replies.
    var versionInfo: VersionPager.Position?
    /// Some reply is streaming (Retry, Regenerate and the pager wait for it).
    var isChatStreaming: Bool
    var showsCost: Bool
    var maxBubbleWidth: CGFloat

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message && lhs.model === rhs.model && lhs.isLast == rhs.isLast
            && lhs.isEditable == rhs.isEditable && lhs.unavailableAttachmentIDs == rhs.unavailableAttachmentIDs
            && lhs.versionInfo == rhs.versionInfo && lhs.isChatStreaming == rhs.isChatStreaming
            && lhs.showsCost == rhs.showsCost && lhs.maxBubbleWidth == rhs.maxBubbleWidth
    }

    var body: some View {
        switch message.role {
        case .user:
            UserMessageRow(message: message, model: model, isEditable: isEditable,
                           unavailableAttachmentIDs: unavailableAttachmentIDs, maxBubbleWidth: maxBubbleWidth)
        case .assistant:
            AssistantMessageRow(message: message, model: model, isLast: isLast, versionInfo: versionInfo,
                                isChatStreaming: isChatStreaming, showsCost: showsCost)
        }
    }
}

// MARK: - Question

private struct UserMessageRow: View {
    let message: ChatMessage
    let model: ChatScreenModel
    let isEditable: Bool
    let unavailableAttachmentIDs: Set<UUID>
    let maxBubbleWidth: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.attachments.isEmpty {
                FlowRow(spacing: 6, lineSpacing: 6, alignment: .trailing) {
                    ForEach(message.attachments) { attachment in
                        SentAttachmentChip(attachment: attachment,
                                           isUnavailable: unavailableAttachmentIDs.contains(attachment.id))
                    }
                }
                .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
            }
            if !message.text.isEmpty {
                bubble
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .opacity(message.includeInContext ? 1 : 0.6)
    }

    private var bubble: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return Text(message.text)
            .font(Theme.font(16.5))
            .foregroundStyle(Color.white.opacity(0.93))
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background {
                // The Mac's flat plate: faint grain and a hairline of top light, no shadow, so the composer
                // stays the one heavy clay form.
                shape
                    .fill(Theme.clayRaised)
                    .overlay { ClayGrain(intensity: 0.4).clipShape(shape) }
                    .overlay {
                        shape
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                            .mask(alignment: .top) {
                                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 18)
                            }
                    }
            }
            .contentShape(.contextMenuPreview, shape)
            .contextMenu {
                Button {
                    model.copy(message)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if isEditable {
                    Button {
                        model.editLastQuestion()
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
                ShareLink(item: message.text) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
            .accessibilityLabel("You: \(message.text)")
    }
}

// MARK: - Reply

private struct AssistantMessageRow: View {
    let message: ChatMessage
    let model: ChatScreenModel
    let isLast: Bool
    let versionInfo: VersionPager.Position?
    let isChatStreaming: Bool
    let showsCost: Bool

    @State private var showsThinking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isStreaming: Bool { message.state == .streaming }
    private var hasRunningActivity: Bool { message.activities.contains { !$0.isDone } }

    /// Stopped or failed: web calls that never finished get a neutral mark instead of a checkmark.
    private var wasInterrupted: Bool {
        switch message.state {
        case .cancelled, .failed: return true
        case .streaming, .complete, .refused: return false
        }
    }

    var body: some View {
        let segments = MessageSegments(message: message)
        VStack(alignment: .leading, spacing: 10) {
            thinkingSection
            if !segments.activities.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(segments.activities) { row in
                        switch row {
                        case .server(let activity):
                            WebActivityRow(activity: activity, wasInterrupted: wasInterrupted)
                        case .note(let activity):
                            NoteRow(activity: activity)
                        }
                    }
                }
            }
            replyBody(segments)
            if !message.sources.isEmpty {
                SourcePills(sources: message.sources)
            }
            statusLine
            if !segments.keptCalls.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(MessageSegments.keptCallsCaption)
                        .font(Theme.font(12.5, .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityAddTraits(.isHeader)
                    toolRows(segments.keptCalls)
                }
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Thinking

    @ViewBuilder
    private var thinkingSection: some View {
        if message.isThinking {
            HStack(spacing: 8) {
                OttoOrb(size: 10, isActive: true)
                Text("Thinking…")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.textMuted)
                    .shimmer(isActive: !reduceMotion)
            }
            .transition(.opacity)
        } else if !message.thinking.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : Theme.Motion.content) { showsThinking.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 12)
                            .rotationEffect(.degrees(showsThinking ? 90 : 0))
                        Text("Thought process")
                            .font(Theme.font(14.5))
                    }
                    .foregroundStyle(Theme.textMuted)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.97))
                .accessibilityLabel(showsThinking ? "Hide thought process" : "Show thought process")

                if showsThinking {
                    Text(message.thinking)
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(2.5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(Color.white.opacity(0.1))
                                .frame(width: 2)
                        }
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: Body

    /// The reply cut at each tool round, with that round's rows in between.
    private func replyBody(_ segments: MessageSegments) -> some View {
        ForEach(Array(segments.items.enumerated()), id: \.offset) { _, item in
            switch item {
            case .text(let text):
                MarkdownText(text, baseSize: Self.bodySize)
            case .tail(let text):
                tail(text, caretAllowed: !segments.hasUnsettledCall)
            case .calls(let calls):
                toolRows(calls)
            }
        }
    }

    static let bodySize: CGFloat = 16.5

    /// The text after the last round, with the caret while it streams (alone, until thinking or a web search
    /// says Otto is busy).
    @ViewBuilder
    private func tail(_ text: String, caretAllowed: Bool) -> some View {
        if isStreaming {
            if !text.isEmpty || (caretAllowed && !message.isThinking && !hasRunningActivity) {
                MarkdownText(text, isStreaming: caretAllowed, baseSize: Self.bodySize)
            }
        } else if !text.isEmpty {
            MarkdownText(text, baseSize: Self.bodySize)
        }
    }

    private func toolRows(_ calls: [ToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(calls) { call in
                ToolCallRow(call: call, messageID: message.id, model: model)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch message.state {
        case .refused(let copy):
            ReplyStatusLine(symbol: "hand.raised", text: copy, color: Theme.textSecondary)
        case .failed(let copy):
            ReplyStatusLine(symbol: "exclamationmark.triangle.fill", text: copy, color: Theme.error)
        case .cancelled:
            ReplyStatusLine(symbol: "stop.circle", text: "Stopped", color: Theme.textTertiary)
        case .streaming, .complete:
            EmptyView()
        }
    }

    // MARK: Footer

    private var canRetry: Bool {
        switch message.state {
        case .failed, .cancelled, .refused: return true
        case .complete, .streaming: return false
        }
    }

    /// The key is missing or was rejected: Settings is where it goes.
    private var needsSettings: Bool {
        guard case .failed(let copy) = message.state else { return false }
        return copy == LLMError.missingAPIKey.errorDescription || copy == LLMError.invalidAPIKey.errorDescription
    }

    /// The conversation outgrew the context: Retry would fail the same way, so New Chat takes its place.
    private var offersNewChat: Bool {
        guard case .failed(let copy) = message.state else { return false }
        return copy == ChatSession.conversationTooLongDescription
    }

    private var hasText: Bool { !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// While a reply streams only the version pager shows (disabled), so the turn's versions stay in view.
    @ViewBuilder
    private var footer: some View {
        if !isStreaming || versionInfo != nil {
            VStack(alignment: .leading, spacing: 8) {
                if !isStreaming, needsSettings || offersNewChat || canRetry {
                    HStack(spacing: 8) {
                        if needsSettings {
                            ReplyActionButton(title: "Open Settings", symbol: "gearshape", isProminent: true) {
                                model.showSettings()
                            }
                        }
                        if offersNewChat {
                            ReplyActionButton(title: "New Chat", symbol: "square.and.pencil", isProminent: true) {
                                model.newChat()
                            }
                            .disabled(isChatStreaming)
                        } else if canRetry {
                            ReplyActionButton(title: "Retry", symbol: "arrow.clockwise", isProminent: !needsSettings) {
                                model.retry(message.id)
                            }
                            .disabled(isChatStreaming)
                        }
                    }
                }
                HStack(spacing: 2) {
                    if !isStreaming, hasText {
                        FooterIconButton(symbol: "doc.on.doc", label: "Copy") { model.copy(message) }
                        ShareLink(item: message.text) {
                            FooterIconLabel(symbol: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share")
                        FooterIconButton(symbol: "speaker.wave.2", label: "Read aloud") { model.readAloud(message) }
                    }
                    if !isStreaming, isLast, message.state == .complete {
                        FooterIconButton(symbol: "arrow.clockwise", label: "Regenerate") { model.regenerate() }
                            .disabled(isChatStreaming)
                    }
                    if let versionInfo {
                        VersionPager(position: versionInfo, isStreaming: isChatStreaming) { index in
                            model.chat.showReplyVersion(index)
                        }
                        .padding(.horizontal, 4)
                    }
                    Spacer(minLength: 8)
                    if !isStreaming {
                        answerLabel
                    }
                }
                .padding(.leading, -8)
            }
        }
    }

    /// Which model answered, or with Show Cost on, the model and what the answer cost.
    @ViewBuilder
    private var answerLabel: some View {
        if showsCost {
            AnswerCostLabel(messageID: message.id, ledger: model.ledger, fallbackModel: message.model)
        } else if let name = message.model.map(CostFormatter.modelName), !name.isEmpty {
            Text(name)
                .font(Theme.font(12))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
    }
}

// MARK: - Pieces

/// A glyph-only action under a reply, 44 pt tall to hit.
private struct FooterIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FooterIconLabel(symbol: symbol)
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.88))
        .accessibilityLabel(label)
    }
}

private struct FooterIconLabel: View {
    let symbol: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .opacity(isEnabled ? 1 : 0.4)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
    }
}

/// A web search or fetch in a reply: a spinner while it runs, then a checkmark (a dash when the reply stopped).
private struct WebActivityRow: View {
    let activity: ToolActivity
    var wasInterrupted = false

    private var symbol: String {
        switch activity.kind {
        case .webSearch: return "magnifyingglass"
        case .webFetch: return "doc.text"
        case .other: return "wrench.and.screwdriver"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if activity.isDone {
                    Image(systemName: wasInterrupted ? "minus" : "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .transition(.opacity)
                } else {
                    MiniSpinner(size: 12, lineWidth: 1.6)
                        .transition(.opacity)
                }
            }
            .frame(width: 14, height: 14)
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textMuted)
            Text(activity.label)
                .font(Theme.font(14.5))
                .foregroundStyle(activity.isDone ? Theme.textMuted : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .animation(.easeOut(duration: 0.2), value: activity.isDone)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            activity.isDone ? "\(activity.label), \(wasInterrupted ? "stopped" : "done")" : activity.label
        )
    }
}

/// Otto's own note in a reply (the web pause), wrapped because the whole sentence is the point.
private struct NoteRow: View {
    let activity: ToolActivity

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 14)
            Text(activity.label)
                .font(Theme.font(14.5))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activity.label)
    }
}

/// An action Otto took: how it stands, what it did (or why it didn't), and its controls: Undo while an added
/// event or reminder can still be removed, Stop while it runs, Open Settings when Actions are off.
struct ToolCallRow: View {
    let call: ToolCall
    let messageID: UUID
    let model: ChatScreenModel

    enum Glyph: Equatable { case spinner, attention, succeeded, stopped, problem, undone }

    static func glyph(for status: ToolCallStatus) -> Glyph {
        switch status {
        case .preparing, .queued, .running, .waitingForSystem: return .spinner
        case .needsPermission, .awaitingApproval: return .attention
        case .succeeded: return .succeeded
        case .denied, .cancelled, .skipped: return .stopped
        case .failed, .blocked: return .problem
        case .undone: return .undone
        }
    }

    /// The row's words: the title before the call starts, the active title while it runs, the done title once it
    /// succeeded (or was undone), and what happened otherwise.
    static func label(for call: ToolCall) -> String {
        let presentation = call.presentation
        switch call.status {
        case .preparing, .queued:
            return presentation.title
        case .needsPermission:
            return "Waiting for your permission"
        case .awaitingApproval:
            return "Waiting for your OK"
        case .waitingForSystem(let appName):
            return appName.isEmpty ? "Waiting for iOS…" : "Waiting for iOS permission for \(appName)…"
        case .running:
            return presentation.activeTitle
        case .succeeded, .undone:
            return presentation.doneTitle
        case .failed(let reason):
            return reason.isEmpty ? "Didn't finish: \(presentation.title)" : "\(presentation.title): \(reason)"
        case .denied:
            return "You declined: \(presentation.title)"
        case .blocked(let reason):
            return reason.isEmpty ? "Blocked: \(presentation.title)" : "Blocked: \(reason)"
        case .cancelled:
            return "Stopped: \(presentation.title)"
        case .skipped(let reason):
            return reason.isEmpty ? "Skipped: \(presentation.title)" : "Skipped: \(presentation.title) (\(reason))"
        }
    }

    static func canUndo(_ call: ToolCall, now: Date) -> Bool {
        guard call.status == .succeeded, let undo = call.undo else { return false }
        return now < undo.expires
    }

    static func canStop(_ call: ToolCall) -> Bool {
        switch call.status {
        case .running, .waitingForSystem: return true
        default: return false
        }
    }

    var body: some View {
        // Re-evaluated now and then, so Undo goes away when its 10 minutes are up.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            HStack(alignment: .center, spacing: 10) {
                glyph
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(DisplayText.sanitized(Self.label(for: call), maxLength: 240))
                        .font(Theme.font(14.5))
                        .foregroundStyle(call.status == .undone ? Theme.textTertiary : Theme.textSecondary)
                        .strikethrough(call.status == .undone, color: Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if call.status == .succeeded, let detail = call.presentation.detail, !detail.isEmpty {
                        Text(DisplayText.sanitized(detail, maxLength: 200))
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if Self.canUndo(call, now: context.date) {
                    RowButton(title: "Undo") { model.undoAction(call.id, in: messageID) }
                } else if Self.canStop(call) {
                    RowButton(title: "Stop") { model.stopAction(call.id) }
                } else if call.recovery != nil {
                    RowButton(title: "Settings") { model.showSettings() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
                    }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var glyph: some View {
        switch Self.glyph(for: call.status) {
        case .spinner:
            MiniSpinner(size: 13, lineWidth: 1.7)
        case .attention:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.attention)
        case .succeeded:
            Image(systemName: call.presentation.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.orbLight)
        case .stopped:
            Image(systemName: "minus.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        case .problem:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.error)
        case .undone:
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

/// A small text button at the end of an action row.
private struct RowButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(13.5, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
    }
}
