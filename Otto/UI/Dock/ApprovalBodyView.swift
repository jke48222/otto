//
//  ApprovalBodyView.swift
//  Otto
//
//  The middle of an approval card: exactly what will happen, shown before it runs. A consent sentence, the
//  event or reminder with its calendar picker, a shortcut and its input, a script with its chips and code,
//  or the address a link opens. Every string in `ApprovalBody.displayedStrings` is on screen; text that
//  leaves the Mac (inputs, scripts, addresses) wraps by character and scrolls, and is never cut short.
//

import AppKit
import SwiftUI

struct ApprovalBodyView: View {
    /// How a script's code box takes its height on the card.
    enum CodeBoxSizing: Equatable, Sendable {
        /// The box is the card's only scroller: it takes the height left under the compact rows above it
        /// (up to `AppleScriptCodeView.maxHeight`) and scrolls inside. `onCodeCramped` fires when that leaves
        /// less than `AppleScriptCodeView.minimumFlexHeight` for a script that doesn't fit.
        case fillsCard
        /// The box shows every row and the card's body scrolls instead (still one scroller).
        case fullHeight
        /// The box scrolls inside its own 168 pt cap (hosting outside a card).
        case ownCap
    }

    private let approvalBody: ApprovalBody
    @Binding private var options: ApprovalOptions
    private let codeSizing: CodeBoxSizing
    private let onCodeCramped: () -> Void
    private let onReviewed: () -> Void

    @State private var didReportReviewed = false

    init(body: ApprovalBody, options: Binding<ApprovalOptions>, codeSizing: CodeBoxSizing = .ownCap,
         onCodeCramped: @escaping () -> Void = {}, onReviewed: @escaping () -> Void = {}) {
        approvalBody = body
        _options = options
        self.codeSizing = codeSizing
        self.onCodeCramped = onCodeCramped
        self.onReviewed = onReviewed
    }

    /// The target line of a Shortcut or URL body (the shortcut's name, the host): 13 pt medium in primary, a step
    /// under the card's 14 pt semibold title, so it reads as the thing named rather than a second heading.
    static let identityFont = Theme.font(13, .medium)
    /// The app or site icon beside the identity line.
    static let identityIconSide: CGFloat = 14
    static let identityIconRadius: CGFloat = 3.5
    /// From the identity line down to the section under it ("Input", "Address").
    static let identitySpacing: CGFloat = 10

    /// Bodies whose code box the card sizes itself (`CodeBoxSizing`) instead of nesting it in the card's scroll: a
    /// script, whose exact code is the point of the card.
    static func flexesCodeBox(_ body: ApprovalBody) -> Bool {
        if case .appleScript = body { return true }
        return false
    }

    /// Whether the body holds a scrolling box whose last row has to be seen before the body counts as
    /// reviewed. Bodies without one are reviewed as soon as they appear.
    static func needsScrollReview(_ body: ApprovalBody) -> Bool {
        switch body {
        case .text, .appleScript, .url: return true
        case .shortcut(let preview): return !(preview.input ?? "").isEmpty
        case .consent, .event, .reminder: return false
        }
    }

    /// The calendar (events) or list (reminders) the picker shows: the one picked on the card, else the one
    /// the tool chose.
    static func selectedChoiceID(body: ApprovalBody, options: ApprovalOptions) -> String? {
        switch body {
        case .event(let preview): return options.calendarIdentifier ?? preview.selectedCalendarID
        case .reminder(let preview): return options.calendarIdentifier ?? preview.selectedListID
        case .consent, .text, .shortcut, .appleScript, .url: return nil
        }
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                seedSelection()
                if !Self.needsScrollReview(approvalBody) { reportReviewed() }
            }
            .onChange(of: approvalBody) { _, _ in
                didReportReviewed = false
                seedSelection()
                if !Self.needsScrollReview(approvalBody) { reportReviewed() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch approvalBody {
        case .consent(let preview):
            ConsentBody(preview: preview)
        case .text(let preview):
            TextBody(preview: preview, onShown: reportReviewed)
        case .event(let preview):
            EventBody(preview: preview, selection: selectionBinding)
        case .reminder(let preview):
            ReminderBody(preview: preview, selection: selectionBinding)
        case .shortcut(let preview):
            ShortcutBody(preview: preview, onShown: reportReviewed)
        case .appleScript(let preview):
            ScriptBody(preview: preview, sizing: codeSizing, onCramped: onCodeCramped, onShown: reportReviewed)
        case .url(let preview):
            URLBody(preview: preview, onShown: reportReviewed)
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { Self.selectedChoiceID(body: approvalBody, options: options) },
            set: { options.calendarIdentifier = $0 }
        )
    }

    /// The card starts from the calendar or list the tool picked (the view model normally seeds it already).
    private func seedSelection() {
        guard options.calendarIdentifier == nil else { return }
        switch approvalBody {
        case .event(let preview) where preview.selectedCalendarID != nil:
            options.calendarIdentifier = preview.selectedCalendarID
        case .reminder(let preview) where preview.selectedListID != nil:
            options.calendarIdentifier = preview.selectedListID
        default:
            break
        }
    }

    private func reportReviewed() {
        guard !didReportReviewed else { return }
        didReportReviewed = true
        onReviewed()
    }
}

// MARK: - Rendered-text record

extension ApprovalBodyView {
    /// Collects every string the body's views put on screen, as each view appears. Nothing records in the
    /// app (the environment value is nil there); tests host a body with a recorder to prove WYSIWYG.
    @MainActor final class TextRecorder {
        private(set) var strings: [String] = []

        func record(_ text: String) {
            guard !text.isEmpty else { return }
            strings.append(text)
        }
    }
}

private struct DockTextRecorderKey: EnvironmentKey {
    static let defaultValue: ApprovalBodyView.TextRecorder? = nil
}

extension EnvironmentValues {
    /// Set only by tests (see `ApprovalBodyView.TextRecorder`).
    var dockTextRecorder: ApprovalBodyView.TextRecorder? {
        get { self[DockTextRecorderKey.self] }
        set { self[DockTextRecorderKey.self] = newValue }
    }
}

private struct DockRecordedText: ViewModifier {
    let text: String
    @Environment(\.dockTextRecorder) private var recorder

    func body(content: Content) -> some View {
        content.onAppear { recorder?.record(text) }
    }
}

extension View {
    /// Marks `text` as drawn by this view (for `ApprovalBodyView.TextRecorder`).
    func dockRecordsText(_ text: String) -> some View {
        modifier(DockRecordedText(text: text))
    }
}

// MARK: - Consent

private struct ConsentBody: View {
    let preview: ConsentPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: preview.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text(preview.title)
                    .font(Theme.font(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .dockRecordsText(preview.title)
            }
            Text(preview.body)
                .font(Theme.font(13))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .dockRecordsText(preview.body)
            if let footnote = preview.footnote, !footnote.isEmpty {
                Text(footnote)
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.textTertiaryOnClay)
                    .fixedSize(horizontal: false, vertical: true)
                    .dockRecordsText(footnote)
            }
        }
    }
}

// MARK: - Text

private struct TextBody: View {
    let preview: TextPreview
    let onShown: () -> Void

    private var isScript: Bool { preview.language?.caseInsensitiveCompare("AppleScript") == .orderedSame }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                BoxLabel(text: preview.label)
                Spacer(minLength: 8)
                DockCardChrome.CopyButton(text: preview.text, accessibilityName: "Copy \(preview.label)")
            }
            DockCardChrome.MonoBox(
                text: preview.text,
                attributed: isScript ? AppleScriptHighlighter.highlight(preview.text) : nil,
                showsLineNumbers: isScript,
                maxHeight: isScript ? AppleScriptCodeView.maxHeight : 148,
                accessibilityName: preview.label,
                onLastRowShown: onShown
            )
        }
    }
}

/// The small caption over a mono box ("Input", "Address"). VoiceOver reads the box's own name.
private struct BoxLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.font(11, .semibold))
            .tracking(0.2)
            .foregroundStyle(Theme.textTertiaryOnClay)
            .accessibilityHidden(true)
            .dockRecordsText(text)
    }
}

// MARK: - Calendar and list picker

/// A borderless menu of calendars (or lists) grouped by account, with the chosen one's color dot.
private struct ChoicePicker: View {
    let choices: [CalendarChoice]
    @Binding var selection: String?
    /// "Calendar" / "List", for the placeholder and VoiceOver.
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
            .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(ApprovalBodyColors.color(for: selected))
                    .frame(width: 7, height: 7)
                Text(selected?.title ?? "Choose a \(noun.lowercased())")
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(selected == nil ? Theme.attention : Theme.textSecondary)
                    .fixedSize()
                    .dockRecordsText(selected?.title ?? "")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiaryOnClay)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color.white.opacity(0.06), in: Capsule(style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(noun)
        .accessibilityValue(selected?.title ?? "None chosen")
    }
}

private enum ApprovalBodyColors {
    static func color(for choice: CalendarChoice?) -> Color {
        guard let components = choice?.colorRGBA, components.count == 4 else { return Theme.orbDark }
        return Color(.sRGB, red: components[0], green: components[1], blue: components[2], opacity: components[3])
    }
}

/// A one-line note under a tile: symbol + text.
private struct NoteLine: View {
    let symbol: String
    let text: String
    var color: Color = Theme.textSecondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.font(11.5))
                .fixedSize(horizontal: false, vertical: true)
                .dockRecordsText(text)
        }
        .foregroundStyle(color)
    }
}

/// The event and reminder tile: a recessed well like the Input and Address boxes (the same code fill, no
/// shadow, no clay rim), so the card never nests a second raised surface.
private enum TileWell {
    static let padding: CGFloat = 12
    static let cornerRadius: CGFloat = 12
}

private extension View {
    func tileWell() -> some View {
        background(Theme.codeFill, in: RoundedRectangle(cornerRadius: TileWell.cornerRadius, style: .continuous))
    }
}

// MARK: - Event

private struct EventBody: View {
    let preview: EventPreview
    @Binding var selection: String?

    private var selectedChoice: CalendarChoice? { preview.calendars.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(ApprovalBodyColors.color(for: selectedChoice))
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                VStack(spacing: 0) {
                    Text(preview.weekday)
                        .font(Theme.font(10, .semibold))
                        .foregroundStyle(Theme.textTertiaryOnClay)
                        .dockRecordsText(preview.weekday)
                    Text(preview.day)
                        .font(Theme.font(22, .light))
                        .foregroundStyle(Theme.textPrimary)
                        .dockRecordsText(preview.day)
                }
                .frame(width: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview.title)
                        .font(Theme.font(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .dockRecordsText(preview.title)
                    Text(preview.timeLine)
                        .font(Theme.font(12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .dockRecordsText(preview.timeLine)
                    if let location = preview.location, !location.isEmpty {
                        NoteLine(symbol: "mappin", text: location, color: Theme.textTertiaryOnClay)
                    }
                    if let notes = preview.notes, !notes.isEmpty {
                        NoteLine(symbol: "note.text", text: notes, color: Theme.textTertiaryOnClay)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ChoicePicker(choices: preview.calendars, selection: $selection, noun: "Calendar")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(TileWell.padding)
            .tileWell()

            if let hint = preview.calendarHint, !hint.isEmpty {
                NoteLine(symbol: "questionmark.circle", text: hint, color: Theme.attention)
            }
            ForEach(Array(preview.conflicts.enumerated()), id: \.offset) { _, conflict in
                NoteLine(symbol: "exclamationmark.circle", text: conflict)
            }
            if let note = preview.timeZoneNote, !note.isEmpty {
                NoteLine(symbol: "globe", text: note)
            }
            if let note = preview.adjustmentNote, !note.isEmpty {
                NoteLine(symbol: "clock.arrow.2.circlepath", text: note)
            }
        }
    }
}

// MARK: - Reminder

private struct ReminderBody: View {
    let preview: ReminderPreview
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .strokeBorder(Theme.textSecondary, lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview.title)
                        .font(Theme.font(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .dockRecordsText(preview.title)
                    if preview.dueLine != nil || preview.hasAlert {
                        HStack(spacing: 5) {
                            if let due = preview.dueLine, !due.isEmpty {
                                Text(due)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .dockRecordsText(due)
                            }
                            if preview.hasAlert {
                                Image(systemName: "bell.fill")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .accessibilityLabel("With an alert")
                            }
                        }
                        .font(Theme.font(12.5))
                        .foregroundStyle(Theme.textSecondary)
                    }
                    if let notes = preview.notes, !notes.isEmpty {
                        NoteLine(symbol: "note.text", text: notes, color: Theme.textTertiaryOnClay)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ChoicePicker(choices: preview.lists, selection: $selection, noun: "List")
            }
            .padding(TileWell.padding)
            .tileWell()

            if let hint = preview.listHint, !hint.isEmpty {
                NoteLine(symbol: "questionmark.circle", text: hint, color: Theme.attention)
            }
        }
    }
}

// MARK: - Identity icon

/// The 14 pt app or site icon on a Shortcut or URL body's identity line (radius 3.5), or a symbol when there's none.
private struct IdentityIcon: View {
    let image: NSImage?
    let fallbackSymbol: String

    var body: some View {
        let side = ApprovalBodyView.identityIconSide
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: ApprovalBodyView.identityIconRadius, style: .continuous))
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

// MARK: - Shortcut

private struct ShortcutBody: View {
    let preview: ShortcutPreview
    let onShown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ApprovalBodyView.identitySpacing) {
            HStack(spacing: 7) {
                IdentityIcon(image: AppIconCache.icon(forBundleID: "com.apple.shortcuts"),
                             fallbackSymbol: "square.stack.3d.up")
                Text(preview.name)
                    .font(ApprovalBodyView.identityFont)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .dockRecordsText(preview.name)
            }
            if let input = preview.input, !input.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        BoxLabel(text: "Input")
                        Spacer(minLength: 8)
                        DockCardChrome.CopyButton(text: input, accessibilityName: "Copy input")
                    }
                    DockCardChrome.MonoBox(text: input, maxHeight: 118, accessibilityName: "Input",
                                           onLastRowShown: onShown)
                }
            } else {
                Text("No input")
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.textTertiaryOnClay)
            }
        }
    }
}

// MARK: - AppleScript

private struct ScriptBody: View {
    /// A script this short leaves the card room for the whole access sentence, so only longer ones compact it.
    static let fullAccessRowMaxLines = 3

    static func compactsAccessRow(sizing: ApprovalBodyView.CodeBoxSizing, lineCount: Int) -> Bool {
        sizing == .fillsCard && lineCount > fullAccessRowMaxLines
    }

    let preview: AppleScriptPreview
    let sizing: ApprovalBodyView.CodeBoxSizing
    let onCramped: () -> Void
    let onShown: () -> Void

    var body: some View {
        // On the card, the rows above the code stay compact and the code box takes the rest (§5.7): the purpose
        // gives up its second line before the code gives up rows, and the access row keeps to one line.
        let fillsCard = sizing == .fillsCard
        VStack(alignment: .leading, spacing: fillsCard ? 8 : 10) {
            if !preview.purpose.isEmpty {
                let purpose = "Otto says: “\(preview.purpose)”"
                (Text("Otto says: ").font(Theme.font(11.5)).foregroundColor(Theme.textTertiaryOnClay)
                    + Text("“\(preview.purpose)”").font(Theme.font(13).italic()).foregroundColor(Theme.textPrimary))
                    .lineLimit(fillsCard ? 2 : nil)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: !fillsCard)
                    .help(purpose)
                    .dockRecordsText(purpose)
            }
            if !preview.targets.isEmpty || !preview.capabilities.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(preview.targets.enumerated()), id: \.offset) { _, chip in
                        DockCardChrome.Chip(label: chip.label, symbol: "app", bundleID: chip.bundleID,
                                            isDanger: chip.isDanger)
                    }
                    ForEach(Array(preview.capabilities.enumerated()), id: \.offset) { _, chip in
                        DockCardChrome.Chip(label: chip.label,
                                            symbol: chip.isDanger ? "exclamationmark.triangle.fill" : "gearshape",
                                            isDanger: chip.isDanger)
                    }
                }
            }
            ScriptInheritedAccessRow(access: preview.inheritedAccess,
                                     isCompact: Self.compactsAccessRow(sizing: sizing, lineCount: preview.lineCount))
            AppleScriptCodeView(source: preview.source, sizing: sizing, onCramped: onCramped, onReviewed: onShown)
                .layoutPriority(1)
        }
    }
}

// MARK: - URL

private struct URLBody: View {
    let preview: URLPreview
    let onShown: () -> Void

    /// Scheme + host secondary, path primary, query and fragment tertiary.
    static func styledAddress(_ address: String) -> AttributedString {
        let parts = URLParts(address)
        var result = AttributedString()
        for (text, color) in [(parts.origin, Theme.textSecondary), (parts.path, Theme.textPrimary),
                              (parts.rest, Theme.textTertiary)] where !text.isEmpty {
            var container = AttributeContainer()
            container.swiftUI.font = Theme.mono(11.5)
            container.swiftUI.foregroundColor = color
            result.append(AttributedString(text, attributes: container))
        }
        return result
    }

    private var browserIcon: NSImage? {
        guard let url = URL(string: preview.url),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return NSWorkspace.shared.icon(forFile: app.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ApprovalBodyView.identitySpacing) {
            HStack(alignment: .center, spacing: 7) {
                IdentityIcon(image: browserIcon, fallbackSymbol: "safari")
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.displayHost)
                        .font(ApprovalBodyView.identityFont)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .dockRecordsText(preview.displayHost)
                    if let punycode = preview.punycodeHost, !punycode.isEmpty, punycode != preview.displayHost {
                        Text(punycode)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .dockRecordsText(punycode)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    BoxLabel(text: "Address")
                    Spacer(minLength: 8)
                    DockCardChrome.CopyButton(text: preview.url, accessibilityName: "Copy address")
                }
                DockCardChrome.MonoBox(text: preview.url, attributed: Self.styledAddress(preview.url),
                                       fontSize: 11.5, maxHeight: 96, accessibilityName: "Address",
                                       onLastRowShown: onShown)
            }
            if !preview.warnings.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
                        DockCardChrome.Chip(label: warning, symbol: "exclamationmark.triangle.fill",
                                            tint: Theme.attention)
                    }
                }
            }
        }
    }

    /// Splits an address into "scheme://host", "/path" and "?query#fragment" without changing a character.
    private struct URLParts {
        let origin: String
        let path: String
        let rest: String

        init(_ address: String) {
            var originEnd = address.startIndex
            if let scheme = address.range(of: "://") {
                originEnd = address[scheme.upperBound...].firstIndex { "/?#".contains($0) } ?? address.endIndex
            } else if let colon = address.firstIndex(of: ":") {
                originEnd = address.index(after: colon)
            }
            let restStart = address[originEnd...].firstIndex { "?#".contains($0) } ?? address.endIndex
            origin = String(address[..<originEnd])
            path = String(address[originEnd..<restStart])
            rest = String(address[restStart...])
        }
    }
}
