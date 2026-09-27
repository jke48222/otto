//
//  ToolCallCard.swift
//  Otto
//
//  One client tool call inside a reply: a 24 pt row with a status glyph and what the call is doing or did,
//  then the controls that belong to it (Undo while it can still be undone, Stop while it runs, the recovery
//  link, Stop allowing for a remembered approval). Expanding it shows the exact script, input or address and
//  the output Claude received. Values in, closures out: the message view wires the actions.
//

import SwiftUI

struct ToolCallCard: View, Equatable {
    let call: ToolCall
    var onUndo: () -> Void = {}
    var onStop: () -> Void = {}
    var onStopAllowing: () -> Void = {}
    var onRecovery: (ToolRecovery) -> Void = { _ in }

    static func == (lhs: ToolCallCard, rhs: ToolCallCard) -> Bool {
        lhs.call == rhs.call
    }

    static let rowHeight: CGFloat = 24
    static let disclosureMaxHeight: CGFloat = 140

    @State private var isExpanded = false
    @State private var isHovering = false
    /// Flips when the undo window closes, so [Undo] disappears on time without a running clock.
    @State private var undoExpired = false
    @State private var isPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Pure helpers

    enum Glyph: Equatable {
        case spinner, attention, succeeded, stopped, problem, undone
    }

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

    /// The row's words: the title before the call starts, the active title while it runs, the done title
    /// once it succeeded (or was undone), and what happened otherwise.
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
            return appName.isEmpty ? "Waiting for macOS…" : "Waiting for macOS permission for \(appName)…"
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

    /// "0.4 s", "12 s", "1 min 5 s". nil until the call has both a start and an end.
    static func durationText(for call: ToolCall) -> String? {
        guard let start = call.startedAt, let end = call.finishedAt else { return nil }
        let seconds = max(0, end.timeIntervalSince(start))
        if seconds < 10 { return String(format: "%.1f s", seconds) }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        let whole = Int(seconds.rounded())
        return "\(whole / 60) min \(whole % 60) s"
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

    static func recoveryTitle(_ recovery: ToolRecovery) -> String {
        switch recovery {
        case .openSystemSettings: return "Open Privacy Settings"
        case .openActionsSettings: return "Open Settings"
        }
    }

    /// The label of a remembered approval ("“Log water”") when the call ran under one.
    static func rememberedLabel(_ call: ToolCall) -> String? {
        guard case .rememberedScope(let label)? = call.approvedVia else { return nil }
        return label
    }

    /// Expanding shows something only when there is a disclosure or output text.
    static func hasDetails(_ call: ToolCall) -> Bool {
        call.presentation.disclosure != nil || !(call.result?.previewText ?? "").isEmpty
    }

    static func accessibilityLabel(for call: ToolCall) -> String {
        var parts = [label(for: call)]
        if let duration = durationText(for: call) { parts.append(duration) }
        if rememberedLabel(call) != nil { parts.append("always allowed") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row
            if isExpanded, Self.hasDetails(call) {
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.Motion.content, value: call.status)
        .animation(Theme.Motion.content, value: isExpanded)
        .onHover { isHovering = $0 }
        .task(id: call.undo?.expires) { await waitForUndoExpiry() }
    }

    private var row: some View {
        HStack(spacing: 7) {
            glyphView
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.label(for: call))
                    .font(Theme.font(12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(Self.label(for: call))
                if call.status == .running, let note = call.progressNote, !note.isEmpty {
                    Text(note)
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(for: call))
            Spacer(minLength: 6)
            trailing
        }
        .frame(minHeight: Self.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            guard Self.hasDetails(call) else { return }
            isExpanded.toggle()
        }
    }

    @ViewBuilder
    private var glyphView: some View {
        switch Self.glyph(for: call.status) {
        case .spinner:
            MiniSpinner(size: 11, lineWidth: 1.5, color: Theme.textSecondary)
        case .attention:
            Image(systemName: "hand.raised")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.attention)
                .opacity(reduceMotion ? 1 : (isPulsing ? 1 : 0.55))
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { isPulsing = true }
                }
                .accessibilityLabel("Waiting")
        case .succeeded:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityLabel("Done")
        case .stopped:
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityLabel("Didn't run")
        case .problem:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.error)
                .accessibilityLabel("Problem")
        case .undone:
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityLabel("Undone")
        }
    }

    private var trailing: some View {
        HStack(spacing: 8) {
            if let duration = Self.durationText(for: call) {
                Text(duration)
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            if !undoExpired, Self.canUndo(call, now: Date()) {
                RowLink(title: "Undo", action: onUndo)
            }
            if Self.canStop(call) {
                RowLink(title: "Stop", action: onStop)
            }
            if let recovery = call.recovery {
                RowLink(title: Self.recoveryTitle(recovery)) { onRecovery(recovery) }
            }
            if let remembered = Self.rememberedLabel(call) {
                Text("(always allowed)")
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel("Always allowed: \(remembered)")
                RowLink(title: "Stop allowing", action: onStopAllowing)
                    .accessibilityHint("Otto will ask before running \(remembered) again")
            }
            if Self.hasDetails(call), isHovering || isExpanded {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.9))
                .accessibilityLabel(isExpanded ? "Hide details" : "Show details")
            }
        }
        .font(Theme.font(12))
        .fixedSize()
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let disclosure = call.presentation.disclosure {
                let isScript = disclosure.language?.caseInsensitiveCompare("AppleScript") == .orderedSame
                DetailBox(label: disclosure.label) {
                    DockCardChrome.MonoBox(
                        text: disclosure.text,
                        attributed: isScript ? AppleScriptHighlighter.highlight(disclosure.text) : nil,
                        showsLineNumbers: isScript,
                        maxHeight: Self.disclosureMaxHeight,
                        accessibilityName: disclosure.label
                    )
                } copyText: {
                    disclosure.text
                }
            }
            if let output = call.result?.previewText, !output.isEmpty {
                DetailBox(label: "Output") {
                    DockCardChrome.MonoBox(text: output, fontSize: 11.5, color: Theme.textSecondary,
                                           maxHeight: Self.disclosureMaxHeight, accessibilityName: "Output")
                } copyText: {
                    output
                }
            }
        }
        .padding(.leading, 21)
    }

    private func waitForUndoExpiry() async {
        guard let expires = call.undo?.expires else {
            undoExpired = false
            return
        }
        let remaining = expires.timeIntervalSinceNow
        guard remaining > 0 else {
            undoExpired = true
            return
        }
        undoExpired = false
        try? await Task.sleep(for: .seconds(remaining))
        guard !Task.isCancelled else { return }
        undoExpired = true
    }
}

/// A small text action in a tool row ("Undo", "Stop", "Open Settings").
private struct RowLink: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(12, .medium))
                .foregroundStyle(isHovering ? Theme.textPrimary : Theme.link)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }
}

/// A captioned mono box with a copy pebble (the expanded row's script, input or output).
private struct DetailBox<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    let copyText: () -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(label)
                    .font(Theme.font(10.5, .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                DockCardChrome.CopyButton(text: copyText(), accessibilityName: "Copy \(label.lowercased())")
            }
            content()
        }
    }
}
