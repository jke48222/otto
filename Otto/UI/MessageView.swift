//
//  MessageView.swift
//  Otto
//
//  One conversation turn. User turns are right-aligned soft bubbles; assistant turns are
//  unboxed text with thinking, tool activity, sources and a hover footer.
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

    static func == (lhs: MessageView, rhs: MessageView) -> Bool {
        lhs.message == rhs.message && lhs.viewModel === rhs.viewModel && lhs.isLast == rhs.isLast
            && lhs.availableWidth == rhs.availableWidth
    }

    var body: some View {
        switch message.role {
        case .user:
            UserMessageView(message: message, maxBubbleWidth: availableWidth * 0.78)
        case .assistant:
            AssistantMessageView(message: message, viewModel: viewModel, isLast: isLast)
        }
    }
}

// MARK: - User

private struct UserMessageView: View {
    let message: ChatMessage
    let maxBubbleWidth: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.attachments.isEmpty {
                FlowLayout(spacing: 6, alignment: .trailing) {
                    ForEach(message.attachments) { attachment in
                        MiniAttachmentChip(attachment: attachment)
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

private struct MiniAttachmentChip: View {
    let attachment: Attachment

    var body: some View {
        HStack(spacing: 5) {
            AttachmentIcon(attachment: attachment, size: 14)
            Text(attachment.displayName)
                .font(Theme.font(11.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                }
        }
        .help(attachment.displayName)
    }
}

// MARK: - Assistant

private struct AssistantMessageView: View {
    let message: ChatMessage
    let viewModel: NotchViewModel
    let isLast: Bool

    @State private var isHovering = false
    @State private var showsThinking = false
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?

    private var isStreaming: Bool { message.state == .streaming }

    private var hasRunningActivity: Bool { message.activities.contains { !$0.isDone } }

    /// The turn was stopped or failed, so its tool calls may not have finished: they are shown with
    /// a neutral mark instead of a checkmark.
    private var wasInterrupted: Bool {
        switch message.state {
        case .cancelled, .failed: return true
        case .streaming, .complete, .refused: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thinkingSection
            if !message.activities.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(message.activities) { activity in
                        ActivityRow(activity: activity, wasInterrupted: wasInterrupted)
                    }
                }
            }
            content
            if !message.sources.isEmpty {
                SourcePills(sources: message.sources)
            }
            footer
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

    @ViewBuilder
    private var content: some View {
        switch message.state {
        case .refused(let copy):
            VStack(alignment: .leading, spacing: 6) {
                if !message.text.isEmpty { MarkdownText(message.text) }
                StatusLine(symbol: "hand.raised", text: copy, color: Theme.textSecondary)
            }
        case .failed(let copy):
            VStack(alignment: .leading, spacing: 6) {
                if !message.text.isEmpty { MarkdownText(message.text) }
                StatusLine(symbol: "exclamationmark.triangle.fill", text: copy, color: Theme.error)
            }
        case .cancelled:
            VStack(alignment: .leading, spacing: 6) {
                if !message.text.isEmpty { MarkdownText(message.text) }
                StatusLine(symbol: "stop.circle", text: "Stopped", color: Theme.textTertiary)
            }
        case .streaming:
            if !message.text.isEmpty || (!message.isThinking && !hasRunningActivity) {
                MarkdownText(message.text, isStreaming: true)
            }
        case .complete:
            MarkdownText(message.text)
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

    @ViewBuilder
    private var footer: some View {
        if !isStreaming {
            HStack(spacing: 4) {
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
                if !message.text.isEmpty {
                    FooterButton(title: didCopy ? "Copied" : "Copy", symbol: didCopy ? "checkmark" : "doc.on.doc") {
                        copyText()
                    }
                    .opacity(isHovering || isLast || didCopy ? 1 : 0)
                }
                Spacer(minLength: 0)
                if let model = message.model, isHovering {
                    Text(Self.modelLabel(model))
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .frame(height: 20)
            .padding(.leading, -6)
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

private struct StatusLine: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(Theme.font(13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .foregroundStyle(color)
    }
}

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

private struct FooterButton: View {
    let title: String
    let symbol: String
    var isProminent: Bool = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(Theme.font(11.5, .medium))
            }
            .foregroundStyle(isProminent || isHovering ? Theme.textPrimary : Theme.textTertiary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.08 : (isProminent ? 0.05 : 0)))
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
    }
}
