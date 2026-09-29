//
//  AppleScriptCodeView.swift
//  Otto
//
//  The exact script an approval card asks to run: numbered, highlighted, wrapped at the box width so no
//  character sits out of sight, and scrolled vertically only. On the card the box is the only scroller and takes
//  the height left under the rows above it. When the script runs taller than the box, the card waits until the
//  last row has been on screen before it reports the script as reviewed. Also the row naming the access a script
//  inherits from Otto.
//

import SwiftUI

struct AppleScriptCodeView: View {
    let source: String
    var sizing: ApprovalBodyView.CodeBoxSizing = .ownCap
    /// `.fillsCard` only: the box got less than `minimumFlexHeight` for a script that doesn't fit.
    var onCramped: () -> Void = {}
    /// Fires once: right away when the script fits, otherwise when its last row has been scrolled into view.
    var onReviewed: () -> Void = {}

    static let maxHeight: CGFloat = 168
    /// The least a code box that fills the card may get before the card lets its whole body scroll instead: about
    /// three rows of code.
    static let minimumFlexHeight: CGFloat = 60
    static let fontSize: CGFloat = AppleScriptHighlighter.fontSize

    /// Whether a box `boxHeight` tall is too short to review a script that overflows it (0: squeezed out entirely).
    static func isCramped(boxHeight: CGFloat, overflows: Bool) -> Bool {
        overflows && boxHeight < minimumFlexHeight - 0.5
    }

    @State private var overflows = false
    @State private var boxHeight: CGFloat?
    @State private var reportedCramped = false

    private var lineCount: Int { AppleScriptCodeLayout.lineCount(of: source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Script")
                    .font(Theme.font(11, .semibold))
                    .tracking(0.2)
                    .foregroundStyle(Theme.textTertiaryOnClay)
                Spacer(minLength: 8)
                // "22 lines · scroll to review" sits above the box, where it shows as soon as the box does; the
                // card's footer repeats the hint beside the disabled primary (§5.7).
                Text(overflows ? AppleScriptCodeLayout.reviewFooter(lineCount: lineCount)
                               : AppleScriptCodeLayout.lineCountLabel(lineCount))
                    .font(Theme.font(11.5))
                    .foregroundStyle(overflows ? Theme.textSecondary : Theme.textTertiaryOnClay)
                DockCardChrome.CopyButton(text: source, accessibilityName: "Copy script")
            }
            DockCardChrome.MonoBox(
                text: source,
                attributed: AppleScriptHighlighter.highlight(source),
                fontSize: Self.fontSize,
                showsLineNumbers: true,
                maxHeight: sizing == .fullHeight ? .infinity : Self.maxHeight,
                accessibilityName: "Script, \(AppleScriptCodeLayout.lineCountLabel(lineCount))",
                onOverflowChange: {
                    overflows = $0
                    reportIfCramped()
                },
                onLastRowShown: onReviewed
            )
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                boxHeight = $0
                reportIfCramped()
            }
        }
    }

    private func reportIfCramped() {
        guard sizing == .fillsCard, !reportedCramped, let boxHeight,
              Self.isCramped(boxHeight: boxHeight, overflows: overflows) else { return }
        reportedCramped = true
        onCramped()
    }
}

/// "Runs with Otto's access to: Accessibility · Calendars (macOS won't ask again)": what a script inherits
/// because it runs as Otto. Hidden when empty; tinted as a danger when it includes Accessibility or Screen
/// Recording, which let a script read the screen or drive other apps. Compact (on a card whose code box takes the
/// rest of the height), it keeps to one line: the trailing note goes first, then the chips that don't fit fold
/// into "+2 more", dangerous ones kept in sight; the full list is in the tooltip and the accessibility label.
struct ScriptInheritedAccessRow: View {
    let access: [String]
    var isCompact = false

    static let lead = "Runs with Otto's access to:"
    /// The lead when the row has to keep to one line (the tooltip and VoiceOver still say the whole sentence).
    static let shortLead = "Otto's access:"
    static let trail = "macOS won't ask again."

    static func isDanger(_ access: [String]) -> Bool {
        access.contains(where: isDangerous)
    }

    static func isDangerous(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("Accessibility") || name.localizedCaseInsensitiveContains("Screen")
    }

    /// The whole row as one sentence, for VoiceOver.
    static func spokenSummary(_ access: [String]) -> String {
        "\(lead) \(access.joined(separator: ", ")). \(trail)"
    }

    /// One way to draw the row on a single line.
    struct CompactVariant: Equatable {
        let shown: [String]
        let hidden: [String]
        let showsTrail: Bool
        let usesShortLead: Bool
    }

    /// The one-line forms, widest first: every chip with the note, every chip, every chip under the short lead,
    /// then fewer chips (dangerous ones first) and "+n more", down to none shown.
    static func compactVariants(_ access: [String]) -> [CompactVariant] {
        var variants = [
            CompactVariant(shown: access, hidden: [], showsTrail: true, usesShortLead: false),
            CompactVariant(shown: access, hidden: [], showsTrail: false, usesShortLead: false),
            CompactVariant(shown: access, hidden: [], showsTrail: false, usesShortLead: true),
        ]
        let ordered = access.filter(isDangerous) + access.filter { !isDangerous($0) }
        for count in stride(from: ordered.count - 1, through: 0, by: -1) {
            variants.append(CompactVariant(shown: Array(ordered.prefix(count)), hidden: Array(ordered.dropFirst(count)),
                                           showsTrail: false, usesShortLead: true))
        }
        return variants
    }

    /// The access row's chips and lead: a half step under the card's 12 pt chips. At 12 pt the full row wraps to
    /// three lines on the card and starves a short script's code box, and the compact row loses its second
    /// danger chip at the 14-inch dock height.
    static let chipFontSize: CGFloat = 11.5

    /// "+2 more".
    static func moreLabel(_ hidden: [String]) -> String {
        "+\(hidden.count) more"
    }

    var body: some View {
        if !access.isEmpty {
            Group {
                if isCompact {
                    ViewThatFits(in: .horizontal) {
                        ForEach(Array(Self.compactVariants(access).enumerated()), id: \.offset) { _, variant in
                            HStack(spacing: 6) {
                                leadLabel(short: variant.usesShortLead)
                                ForEach(Array(variant.shown.enumerated()), id: \.offset) { _, name in
                                    DockCardChrome.Chip(label: name, isDanger: Self.isDangerous(name),
                                                        fontSize: Self.chipFontSize)
                                }
                                if !variant.hidden.isEmpty {
                                    DockCardChrome.Chip(label: Self.moreLabel(variant.hidden),
                                                        isDanger: variant.hidden.contains(where: Self.isDangerous),
                                                        fontSize: Self.chipFontSize)
                                }
                                if variant.showsTrail { trailLabel }
                            }
                            .fixedSize()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        leadLabel(short: false)
                        ForEach(Array(access.enumerated()), id: \.offset) { _, name in
                            DockCardChrome.Chip(label: name, isDanger: Self.isDangerous(name),
                                                fontSize: Self.chipFontSize)
                        }
                        trailLabel
                    }
                }
            }
            .help(Self.spokenSummary(access))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spokenSummary(access))
        }
    }

    /// Only the shield carries the danger tint (with the danger chips); the lead itself stays plain text, so the
    /// row doesn't turn into one long coral block that pulls the eye off the script.
    private func leadLabel(short: Bool) -> some View {
        let danger = Self.isDanger(access)
        return HStack(spacing: 5) {
            Image(systemName: danger ? "exclamationmark.shield.fill" : "lock.shield")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(danger ? Theme.error : Theme.textSecondary)
            Text(short ? Self.shortLead : Self.lead)
                .font(Theme.font(Self.chipFontSize, .medium))
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(height: DockCardChrome.Chip.height)
    }

    /// Centered in the chips' 24 pt line, which puts its baseline on theirs.
    private var trailLabel: some View {
        Text(Self.trail)
            .font(Theme.font(11.5))
            .foregroundStyle(Theme.textTertiaryOnClay)
            .frame(height: DockCardChrome.Chip.height)
    }
}
