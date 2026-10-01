//
//  ApprovalCard.swift
//  Otto
//
//  The card that asks before an action runs, above the composer: exactly what will be added (the event or
//  reminder, and the calendar or list it goes to), why Otto is asking, any caution, and the two answers. The
//  confirm button stays off until the card has been on screen for the approval's arming delay (it fills while it
//  waits) and until a calendar or list is picked when one is required. A card that needs iOS access says so, and
//  its confirm button brings up iOS's own prompt first.
//

import SwiftUI

struct ApprovalCard: View {
    let approval: PendingApproval
    let model: ChatScreenModel

    private var selection: Binding<String?> {
        Binding(
            get: { model.approvalOptions.calendarIdentifier ?? ChatScreenModel.initialSelection(for: approval) },
            set: { if let id = $0 { model.selectApprovalCalendar(id) } }
        )
    }

    /// The access step needs no pick: EventKit lists no calendars until iOS grants access.
    private var hasRequiredSelection: Bool {
        guard missingPermissions.isEmpty, approval.body.requiresSelection else { return true }
        guard let picked = model.approvalOptions.calendarIdentifier else { return false }
        switch approval.body {
        case .event(let preview): return preview.calendars.contains { $0.id == picked }
        case .reminder(let preview): return preview.lists.contains { $0.id == picked }
        case .consent, .text, .shortcut, .appleScript, .url: return true
        }
    }

    private var missingPermissions: [Permission] {
        if case .permission(let missing, _) = approval.kind { return missing }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ApprovalBodyContent(approvalBody: approval.body, selection: selection,
                                choosesCalendar: missingPermissions.isEmpty)
            if !missingPermissions.isEmpty {
                CardNote(symbol: "lock",
                         text: "Otto needs access to your \(Self.names(missingPermissions)). iOS will ask next.",
                         color: Theme.textSecondary)
            }
            if let provenance = approval.provenance, !provenance.isEmpty {
                CardNote(symbol: "info.circle", text: DisplayText.sanitized(provenance, maxLength: 200),
                         color: Theme.textTertiary)
            }
            if let caution = approval.caution {
                CautionView(caution: caution)
            }
            buttons
        }
        .padding(16)
        .clay(cornerRadius: 22, style: .tray)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Otto asks: \(approval.presentation.title)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: approval.presentation.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.orbLight)
                .accessibilityHidden(true)
            Text(DisplayText.sanitized(approval.presentation.title, maxLength: 160))
                .font(Theme.font(16, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if approval.total > 1 {
                Text("\(approval.position) of \(approval.total)")
                    .font(Theme.font(12.5, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    private var buttons: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    model.declineApproval()
                } label: {
                    Text(approval.declineLabel)
                        .font(Theme.font(15.5, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.97))

                ArmingConfirmButton(
                    title: missingPermissions.isEmpty ? approval.confirmLabel : "Continue",
                    armedAt: model.approvalArmedAt,
                    isEnabled: hasRequiredSelection && !model.isObtainingPermission,
                    isWorking: model.isObtainingPermission
                ) {
                    model.approve()
                }
            }
            if approval.remainingInRound > 0 {
                Button("Don't run the other \(approval.remainingInRound) either") {
                    model.declineAllApprovals()
                }
                .font(Theme.font(13.5, .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(minHeight: 36)
            }
        }
    }

    static func names(_ permissions: [Permission]) -> String {
        let names = permissions.map(\.displayName)
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// The confirm button: it fills from left to right while the card arms, then lights up.
private struct ArmingConfirmButton: View {
    let title: String
    let armedAt: Date?
    let isEnabled: Bool
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: armedAt == nil || isArmed(at: Date()))) { context in
            let armed = isArmed(at: context.date)
            Button(action: action) {
                ZStack {
                    Capsule(style: .continuous).fill(Color.white.opacity(0.08))
                    GeometryReader { proxy in
                        Capsule(style: .continuous)
                            .fill(LinearGradient(colors: [Theme.sendTop, Theme.sendBottom], startPoint: .top,
                                                 endPoint: .bottom))
                            .frame(width: proxy.size.width * progress(at: context.date))
                            .opacity(armed && isEnabled ? 1 : 0.35)
                    }
                    .clipShape(Capsule(style: .continuous))
                    HStack(spacing: 6) {
                        if isWorking {
                            MiniSpinner(size: 13, color: Theme.sendGlyph)
                        }
                        Text(title)
                            .font(Theme.font(15.5, .semibold))
                    }
                    .foregroundStyle(armed && isEnabled ? Theme.sendGlyph : Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 46)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.97))
            .disabled(!armed || !isEnabled)
            .accessibilityLabel(title)
            .accessibilityHint(armed ? "" : "Available in a moment")
        }
    }

    private func isArmed(at date: Date) -> Bool {
        guard let armedAt else { return false }
        return date >= armedAt
    }

    /// 0…1 toward `armedAt`, over the last second at most.
    private func progress(at date: Date) -> CGFloat {
        guard let armedAt else { return 0 }
        let remaining = armedAt.timeIntervalSince(date)
        guard remaining > 0 else { return 1 }
        return CGFloat(max(0, 1 - remaining))
    }
}

/// "Otto read example.com just before asking." with the advice under it.
private struct CautionView: View {
    let caution: CautionBanner

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(caution.headline)
                    .font(Theme.font(14, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.attention)
            Text(caution.body)
                .font(Theme.font(13.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.attention.opacity(0.1)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Bodies

/// Exactly what will happen: the event, the reminder, the read Otto asks to make, or (for what only the Mac runs)
/// the plain text of it.
struct ApprovalBodyContent: View {
    let approvalBody: ApprovalBody
    @Binding var selection: String?
    /// false on the access step: the calendar or list is picked on the card that follows it.
    var choosesCalendar = true

    var body: some View {
        switch approvalBody {
        case .consent(let preview):
            ConsentBodyView(preview: preview)
        case .event(let preview):
            EventBodyView(preview: preview, selection: $selection, choosesCalendar: choosesCalendar)
        case .reminder(let preview):
            ReminderBodyView(preview: preview, selection: $selection, choosesList: choosesCalendar)
        case .text(let preview):
            PlainBody(label: preview.label, text: preview.text)
        case .shortcut(let preview):
            PlainBody(label: "Shortcut", text: [preview.name, preview.input].compactMap { $0 }.joined(separator: "\n"))
        case .appleScript(let preview):
            PlainBody(label: preview.purpose, text: preview.source)
        case .url(let preview):
            PlainBody(label: preview.displayHost, text: preview.url)
        }
    }
}

private struct ConsentBodyView: View {
    let preview: ConsentPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: preview.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text(preview.title)
                    .font(Theme.font(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(preview.body)
                .font(Theme.font(14.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let footnote = preview.footnote, !footnote.isEmpty {
                Text(footnote)
                    .font(Theme.font(12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct EventBodyView: View {
    let preview: EventPreview
    @Binding var selection: String?
    let choosesCalendar: Bool

    private var selected: CalendarChoice? { preview.calendars.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(CalendarColor.color(for: selected))
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                VStack(spacing: 0) {
                    Text(preview.weekday)
                        .font(Theme.font(11, .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(preview.day)
                        .font(Theme.font(26, .light))
                        .foregroundStyle(Theme.textPrimary)
                }
                .frame(width: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(DisplayText.sanitized(preview.title, maxLength: 200))
                        .font(Theme.font(16, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(preview.timeLine)
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.textSecondary)
                    if let location = preview.location, !location.isEmpty {
                        CardNote(symbol: "mappin", text: DisplayText.sanitized(location, maxLength: 200),
                                 color: Theme.textTertiary)
                    }
                    if let notes = preview.notes, !notes.isEmpty {
                        CardNote(symbol: "note.text", text: DisplayText.sanitized(notes, maxLength: 600),
                                 color: Theme.textTertiary)
                    }
                    if choosesCalendar {
                        CalendarChoicePicker(choices: preview.calendars, selection: $selection, noun: "Calendar")
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .background(Theme.codeFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if choosesCalendar, let hint = preview.calendarHint, !hint.isEmpty {
                CardNote(symbol: "questionmark.circle", text: hint, color: Theme.attention)
            }
            ForEach(Array(preview.conflicts.enumerated()), id: \.offset) { _, conflict in
                CardNote(symbol: "exclamationmark.circle", text: conflict, color: Theme.textSecondary)
            }
            if let note = preview.timeZoneNote, !note.isEmpty {
                CardNote(symbol: "globe", text: note, color: Theme.textSecondary)
            }
            if let note = preview.adjustmentNote, !note.isEmpty {
                CardNote(symbol: "clock.arrow.2.circlepath", text: note, color: Theme.textSecondary)
            }
        }
    }
}

private struct ReminderBodyView: View {
    let preview: ReminderPreview
    @Binding var selection: String?
    let choosesList: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .strokeBorder(Theme.textSecondary, lineWidth: 1.5)
                    .frame(width: 18, height: 18)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(DisplayText.sanitized(preview.title, maxLength: 200))
                        .font(Theme.font(16, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if preview.dueLine != nil || preview.hasAlert {
                        HStack(spacing: 5) {
                            if let due = preview.dueLine, !due.isEmpty {
                                Text(due)
                            }
                            if preview.hasAlert {
                                Image(systemName: "bell.fill")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .accessibilityLabel("With an alert")
                            }
                        }
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.textSecondary)
                    }
                    if let notes = preview.notes, !notes.isEmpty {
                        CardNote(symbol: "note.text", text: DisplayText.sanitized(notes, maxLength: 600),
                                 color: Theme.textTertiary)
                    }
                    if choosesList {
                        CalendarChoicePicker(choices: preview.lists, selection: $selection, noun: "List")
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Theme.codeFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if choosesList, let hint = preview.listHint, !hint.isEmpty {
                CardNote(symbol: "questionmark.circle", text: hint, color: Theme.attention)
            }
        }
    }
}

/// What only the Mac runs, shown as plain text (an iPhone never offers those tools).
private struct PlainBody: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Theme.font(12.5, .semibold))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.codeText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.codeFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// The calendars (or lists) to choose from, grouped by account, with the chosen one's color.
private struct CalendarChoicePicker: View {
    let choices: [CalendarChoice]
    @Binding var selection: String?
    /// "Calendar" / "List".
    let noun: String

    private var selected: CalendarChoice? { choices.first { $0.id == selection } }

    private var groups: [(source: String, choices: [CalendarChoice])] {
        var order: [String] = []
        var bySource: [String: [CalendarChoice]] = [:]
        for choice in choices {
            if bySource[choice.source] == nil { order.append(choice.source) }
            bySource[choice.source, default: []].append(choice)
        }
        return order.map { ($0, bySource[$0] ?? []) }
    }

    var body: some View {
        Menu {
            Picker(noun, selection: $selection) {
                ForEach(groups, id: \.source) { group in
                    Section(group.source) {
                        ForEach(group.choices) { choice in
                            Text(choice.title).tag(Optional(choice.id))
                        }
                    }
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(CalendarColor.color(for: selected))
                    .frame(width: 8, height: 8)
                Text(selected?.title ?? "Choose a \(noun.lowercased())")
                    .font(Theme.font(13.5, .medium))
                    .foregroundStyle(selected == nil ? Theme.attention : Theme.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(Color.white.opacity(0.06), in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .accessibilityLabel(noun)
        .accessibilityValue(selected?.title ?? "None chosen")
    }
}

private enum CalendarColor {
    static func color(for choice: CalendarChoice?) -> Color {
        guard let components = choice?.colorRGBA, components.count == 4 else { return Theme.orbDark }
        return Color(.sRGB, red: components[0], green: components[1], blue: components[2], opacity: components[3])
    }
}

/// A one-line note: symbol + text.
private struct CardNote: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.font(13.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }
}
