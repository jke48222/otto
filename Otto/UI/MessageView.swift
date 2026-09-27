//
//  MessageView.swift
//  Otto
//
//  One conversation turn. User turns are right-aligned soft bubbles; assistant turns are unboxed text with
//  thinking, Otto's notes and server activity, the reply interleaved with its action rows (MessageSegments),
//  sources and a hover footer: paste back into the app, versions, copy, regenerate and what the answer cost.
//

import AppKit
import SwiftUI

struct MessageView: View, Equatable {
    let message: ChatMessage
    let viewModel: NotchViewModel
    /// The newest turn keeps its action footer visible; earlier turns reveal it on hover.
    var isLast: Bool = false
    /// Width available to the conversation column (used for the 78 % bubble cap).
    var availableWidth: CGFloat = NotchMetrics.openWidth - NotchMetrics.openTopRadius * 2 - 32
    /// User turns: attachments History no longer keeps a copy of (history.md §2.5). Empty for other turns.
    var unavailableAttachmentIDs: Set<UUID> = []
    /// The last reply of a regenerated turn: where it sits among the kept replies. nil for every other turn.
    var versionInfo: VersionPager.Position? = nil
    /// Complete replies with text: the app the answer can go back into, while that app still runs.
    var insertTarget: InsertTarget? = nil

    static func == (lhs: MessageView, rhs: MessageView) -> Bool {
        lhs.message == rhs.message && lhs.viewModel === rhs.viewModel && lhs.isLast == rhs.isLast
            && lhs.availableWidth == rhs.availableWidth && lhs.unavailableAttachmentIDs == rhs.unavailableAttachmentIDs
            && lhs.versionInfo == rhs.versionInfo && lhs.insertTarget == rhs.insertTarget
    }

    var body: some View {
        switch message.role {
        case .user:
            UserMessageView(
                message: message,
                maxBubbleWidth: availableWidth * 0.78,
                unavailableAttachmentIDs: unavailableAttachmentIDs,
                onAttachAgain: { url in viewModel.addFiles([url]) }
            )
        case .assistant:
            AssistantMessageView(
                message: message,
                viewModel: viewModel,
                isLast: isLast,
                versionInfo: versionInfo,
                insertTarget: insertTarget
            )
        }
    }
}

// MARK: - User

private struct UserMessageView: View {
    let message: ChatMessage
    let maxBubbleWidth: CGFloat
    let unavailableAttachmentIDs: Set<UUID>
    let onAttachAgain: (URL) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.attachments.isEmpty {
                FlowLayout(spacing: 6, alignment: .trailing) {
                    ForEach(message.attachments) { attachment in
                        MiniAttachmentChip(
                            attachment: attachment,
                            isUnavailable: unavailableAttachmentIDs.contains(attachment.id),
                            onAttachAgain: onAttachAgain
                        )
                    }
                }
                .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
            }
            if !message.text.isEmpty {
                let bubble = RoundedRectangle(cornerRadius: 18, style: .continuous)
                // A soft, flat plate: the composer is the one heavy clay form, so the bubble
                // does not compete with it — faint grain, a hairline of top light, no shadow.
                Text(message.text)
                    .font(Theme.font(14.5))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineSpacing(2.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background {
                        bubble
                            .fill(Theme.clayRaised)
                            .overlay { ClayGrain(intensity: 0.4).clipShape(bubble) }
                            .overlay {
                                bubble
                                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                                    // Top light only, a fixed depth whatever the bubble's height.
                                    .mask(alignment: .top) {
                                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                            .frame(height: 18)
                                    }
                            }
                    }
                    .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .opacity(message.includeInContext ? 1 : 0.6)
    }
}

/// An attachment under a user bubble. One whose payload History dropped (history.md §2.5) is drawn dashed and
/// dimmed with a clock glyph; its menu offers "Attach Again" while the original file is still readable.
private struct MiniAttachmentChip: View {
    let attachment: Attachment
    let isUnavailable: Bool
    let onAttachAgain: (URL) -> Void

    static let unavailableHelp =
        "Otto no longer keeps a copy of this file, so it won't be sent again. Claude still knows it was shared."
    static let attachAgainTitle = "Attach Again"

    private static let cornerRadius: CGFloat = 8

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        HStack(spacing: 5) {
            AttachmentIcon(attachment: attachment, size: 14)
            Text(attachment.displayName)
                .font(Theme.font(11.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
            if isUnavailable {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .opacity(isUnavailable ? 0.6 : 1)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background {
            if isUnavailable {
                shape.strokeBorder(Theme.sendFill.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            } else {
                shape
                    .fill(Color.white.opacity(0.045))
                    .overlay { shape.strokeBorder(Theme.hairline, lineWidth: 1) }
            }
        }
        .contentShape(shape)
        .help(isUnavailable ? Self.unavailableHelp : attachment.displayName)
        .contextMenu {
            if isUnavailable, let url = reattachableURL {
                Button(Self.attachAgainTitle) { onAttachAgain(url) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isUnavailable ? "\(attachment.displayName), no longer stored" : attachment.displayName)
    }

    /// The original file, when it still exists (read when the menu is built, never while scrolling).
    private var reattachableURL: URL? {
        guard let url = attachment.sourceURL, url.isFileURL,
              FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else { return nil }
        return url
    }
}

// MARK: - Assistant

private struct AssistantMessageView: View {
    let message: ChatMessage
    let viewModel: NotchViewModel
    let isLast: Bool
    let versionInfo: VersionPager.Position?
    let insertTarget: InsertTarget?

    @State private var isHovering = false
    @State private var showsThinking = false
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?

    private var isStreaming: Bool { message.state == .streaming }

    private var hasRunningActivity: Bool { message.activities.contains { !$0.isDone } }

    /// The turn was stopped or failed, so its server tool calls may not have finished: they are shown with a
    /// neutral mark instead of a checkmark.
    private var wasInterrupted: Bool {
        switch message.state {
        case .cancelled, .failed: return true
        case .streaming, .complete, .refused: return false
        }
    }

    var body: some View {
        let segments = MessageSegments(message: message)
        VStack(alignment: .leading, spacing: 8) {
            thinkingSection
            if !segments.activities.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(segments.activities) { row in
                        switch row {
                        case .server(let activity):
                            ActivityRow(activity: activity, wasInterrupted: wasInterrupted)
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
                keptCalls(segments.keptCalls)
            }
            footer
            confirmRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .onDisappear { copyResetTask?.cancel() }
    }

    // MARK: Thinking

    @ViewBuilder
    private var thinkingSection: some View {
        if message.isThinking {
            HStack(spacing: 7) {
                OttoOrb(size: 9, isActive: true)
                Text("Thinking…")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.textMuted)
                    .shimmer()
            }
            .transition(.opacity)
        } else if !message.thinking.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(Theme.Motion.content) { showsThinking.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 10)
                            .rotationEffect(.degrees(showsThinking ? 90 : 0))
                        Text("Thought process")
                            .font(Theme.font(13))
                    }
                    .foregroundStyle(Theme.textMuted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.97))
                .accessibilityLabel(showsThinking ? "Hide thought process" : "Show thought process")

                if showsThinking {
                    Text(message.thinking)
                        .font(Theme.font(12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(2.5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 11)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(Color.white.opacity(0.1))
                                .frame(width: 2)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: Body

    /// The reply text cut at each tool round, with that round's rows in between (§5.8).
    private func replyBody(_ segments: MessageSegments) -> some View {
        ForEach(Array(segments.items.enumerated()), id: \.offset) { _, item in
            switch item {
            case .text(let text):
                MarkdownText(text)
            case .tail(let text):
                tail(text, caretAllowed: !segments.hasUnsettledCall)
            case .calls(let calls):
                toolRows(calls)
            }
        }
    }

    /// The text after the last round. While streaming it carries the caret, but only once no call is still in
    /// flight; with no text yet the caret shows alone, unless thinking or a web search already says Otto is busy.
    @ViewBuilder
    private func tail(_ text: String, caretAllowed: Bool) -> some View {
        if isStreaming {
            if !text.isEmpty || (caretAllowed && !message.isThinking && !hasRunningActivity) {
                MarkdownText(text, isStreaming: caretAllowed)
            }
        } else if !text.isEmpty {
            MarkdownText(text)
        }
    }

    private func toolRows(_ calls: [ToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(calls) { call in
                ToolCallCard(
                    call: call,
                    onUndo: { viewModel.undoToolCall(call.id, in: message.id) },
                    onStop: { viewModel.stopToolCall(call.id) },
                    onStopAllowing: { stopAllowing(call) },
                    onRecovery: recover
                )
                .equatable()
            }
        }
    }

    /// The refused turn's caption and the calls that ran before Otto stopped.
    private func keptCalls(_ calls: [ToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MessageSegments.keptCallsCaption)
                .font(Theme.font(11.5, .medium))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityAddTraits(.isHeader)
            toolRows(calls)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch message.state {
        case .refused(let copy):
            StatusLine(symbol: "hand.raised", text: copy, color: Theme.textSecondary)
        case .failed(let copy):
            StatusLine(symbol: "exclamationmark.triangle.fill", text: copy, color: Theme.error)
        case .cancelled:
            StatusLine(symbol: "stop.circle", text: "Stopped", color: Theme.textTertiary)
        case .streaming, .complete:
            EmptyView()
        }
    }

    // MARK: Row actions

    /// [Stop allowing] names the remembered approval by its label; the store holds the full scope.
    private func stopAllowing(_ call: ToolCall) {
        guard let label = ToolCallCard.rememberedLabel(call),
              let remembered = viewModel.approvals.remembered.first(where: {
                  $0.scope.toolName == call.name && $0.scope.label == label
              }) else { return }
        viewModel.stopAllowing(remembered.scope)
    }

    private func recover(_ recovery: ToolRecovery) {
        switch recovery {
        case .openSystemSettings(let permission):
            viewModel.openSystemSettingsFromNotch(for: permission)
        case .openActionsSettings:
            viewModel.openActionsSettings()
        }
    }

    // MARK: Footer

    private var canRetry: Bool {
        switch message.state {
        case .failed, .cancelled, .refused: return true
        case .complete, .streaming: return false
        }
    }

    private var needsSettings: Bool {
        guard case .failed(let copy) = message.state else { return false }
        return copy == LLMError.missingAPIKey.errorDescription || copy == LLMError.invalidAPIKey.errorDescription
    }

    private var isComplete: Bool { message.state == .complete }

    /// The paste control's target, for a complete reply with text.
    private var pasteTarget: InsertTarget? {
        guard isComplete, !message.text.isEmpty else { return nil }
        return insertTarget
    }

    private var isInserting: Bool {
        viewModel.inserter.activity == .inserting(messageID: message.id)
    }

    /// Controls that stay visible on the last reply and appear on hover on older ones.
    private var revealsHoverControls: Bool { isHovering || isLast }

    /// While a reply streams only the version pager shows (disabled), so the turn's versions stay in view.
    @ViewBuilder
    private var footer: some View {
        if !isStreaming || versionInfo != nil {
            HStack(spacing: 4) {
                if !isStreaming {
                    if needsSettings {
                        FooterButton(title: "Open Settings", symbol: "gearshape", isProminent: true) {
                            viewModel.openSettings()
                        }
                    }
                    if canRetry {
                        FooterButton(title: "Retry", symbol: "arrow.clockwise", isProminent: !needsSettings) {
                            viewModel.chat.retry(messageID: message.id)
                        }
                        .disabled(viewModel.chat.isStreaming)
                    }
                    if let target = pasteTarget {
                        InsertAnswerControl(
                            app: target.app,
                            primaryMode: target.selection != nil ? .replaceSelection : .paste,
                            isInserting: isInserting,
                            showsShortcut: isLast,
                            onInsert: { mode in viewModel.insertAnswer(messageID: message.id, mode: mode) },
                            onCopy: copyText
                        )
                        .opacity(revealsHoverControls || isInserting ? 1 : 0)
                    }
                }
                if let versionInfo {
                    VersionPager(position: versionInfo, isStreaming: viewModel.chat.isStreaming) { index in
                        viewModel.chat.showReplyVersion(index)
                    }
                }
                if !isStreaming {
                    if !message.text.isEmpty {
                        FooterButton(title: didCopy ? "Copied" : "Copy", symbol: didCopy ? "checkmark" : "doc.on.doc") {
                            copyText()
                        }
                        .opacity(revealsHoverControls || didCopy ? 1 : 0)
                    }
                    if isLast, isComplete {
                        FooterButton(title: "Regenerate", symbol: "arrow.clockwise") {
                            viewModel.regenerate()
                        }
                        .disabled(viewModel.chat.isStreaming)
                        .opacity(revealsHoverControls ? 1 : 0)
                        .help("Regenerate (⌘R)")
                    }
                }
                Spacer(minLength: 0)
                if isHovering, !isStreaming {
                    answerLabel
                        .transition(.opacity)
                }
            }
            .frame(height: 20)
            .padding(.leading, -6)
        }
    }

    /// Which model answered, or with "Show cost" on, the model and what the answer cost.
    @ViewBuilder
    private var answerLabel: some View {
        if viewModel.settings.usage.showCost {
            AnswerCostLabel(messageID: message.id, ledger: viewModel.ledger, fallbackModel: message.model)
        } else if let model = message.model {
            Text(Self.modelLabel(model))
                .font(Theme.font(11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
    }

    /// The row under the footer when a paste into the app needs a yes first.
    @ViewBuilder
    private var confirmRow: some View {
        if let activity = viewModel.inserter.activity, Self.confirmation(activity, isFor: message.id) {
            InsertConfirmRow(
                activity: activity,
                onConfirm: { viewModel.confirmPendingInsert() },
                onCancel: { viewModel.cancelPendingInsert() }
            )
            .transition(InsertConfirmRow.transition)
        }
    }

    private static func confirmation(_ activity: InsertActivity, isFor messageID: UUID) -> Bool {
        switch activity {
        case .confirmMultiline(let id, _, _, _), .selectionChanged(let id, _): return id == messageID
        case .inserting: return false
        }
    }

    private static func modelLabel(_ model: String) -> String {
        ModelOption(rawValue: model)?.shortName ?? model
    }

    private func copyText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.text, forType: .string)
        didCopy = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
        }
    }
}

// MARK: - Pieces

private struct ActivityRow: View {
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
        HStack(spacing: 7) {
            ZStack {
                if activity.isDone {
                    Image(systemName: wasInterrupted ? "minus" : "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    MiniSpinner(size: 10, lineWidth: 1.5)
                        .transition(.opacity)
                }
            }
            .frame(width: 12, height: 12)
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textMuted)
            Text(activity.label)
                .font(Theme.font(13))
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

/// Otto's own note in a reply (the web pause): a finished activity row with `info.circle`, wrapped rather than
/// truncated because the whole sentence is the point.
private struct NoteRow: View {
    let activity: ToolActivity

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 12)
            Text(activity.label)
                .font(Theme.font(13))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activity.label)
    }
}

private struct SourcePills: View {
    let sources: [SourceLink]
    private static let maxShown = 8

    /// One pill per host, in first-seen order.
    private var entries: [SourceLink] {
        var seen: Set<String> = []
        var result: [SourceLink] = []
        for source in sources {
            let host = Self.host(of: source.url)
            if seen.insert(host).inserted { result.append(source) }
        }
        return result
    }

    var body: some View {
        let all = entries
        let shown = Array(all.prefix(Self.maxShown))
        FlowLayout(spacing: 6) {
            ForEach(shown) { source in
                SourcePill(title: Self.host(of: source.url), detail: source.title, url: source.url)
            }
            if all.count > shown.count {
                Text("+\(all.count - shown.count)")
                    .font(Theme.font(11.5, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 8)
                    .frame(height: SourcePill.height)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func host(of url: URL) -> String {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// A source link: a quiet plate with a secondary-weight label, so it never competes with the
/// reply body it cites.
private struct SourcePill: View {
    let title: String
    let detail: String
    let url: URL
    @State private var isHovering = false

    static let height: CGFloat = 26
    private static let cornerRadius: CGFloat = 10

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.45))
                Text(title)
                    .font(Theme.font(12))
                    .tracking(0.1)
                    .foregroundStyle(isHovering ? Theme.sourceLabelHover : Theme.sourceLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160)
            }
            .padding(.leading, 9)
            .padding(.trailing, 11)
            .frame(height: Self.height)
            .background {
                shape.fill(isHovering ? Theme.sourcePillHoverFill : Theme.sourcePillFill)
            }
            .contentShape(shape)
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.96))
        .onHover { isHovering = $0 }
        .help(detail.isEmpty ? url.absoluteString : "\(detail)\n\(url.absoluteString)")
        .accessibilityLabel("Source: \(detail.isEmpty ? title : detail)")
    }
}
