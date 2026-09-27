//
//  AppleScriptCodeView.swift
//  Otto
//
//  The exact script an approval card asks to run: numbered, highlighted, wrapped at the box width so no
//  character sits out of sight, and scrolled vertically only. When the script runs taller than the box, the
//  card waits until the last row has been on screen before it reports the script as reviewed. Also the chip
//  row naming the access a script inherits from Otto.
//

import SwiftUI

struct AppleScriptCodeView: View {
    let source: String
    /// Fires once: right away when the script fits, otherwise when its last row has been scrolled into view.
    var onReviewed: () -> Void = {}

    static let maxHeight: CGFloat = 168
    static let fontSize: CGFloat = AppleScriptHighlighter.fontSize

    @State private var overflows = false

    private var lineCount: Int { AppleScriptCodeLayout.lineCount(of: source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Script")
                    .font(Theme.font(10.5, .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                Text(AppleScriptCodeLayout.lineCountLabel(lineCount))
                    .font(Theme.font(10.5))
                    .foregroundStyle(Theme.textTertiary)
                DockCardChrome.CopyButton(text: source, accessibilityName: "Copy script")
            }
            DockCardChrome.MonoBox(
                text: source,
                attributed: AppleScriptHighlighter.highlight(source),
                fontSize: Self.fontSize,
                showsLineNumbers: true,
                maxHeight: Self.maxHeight,
                accessibilityName: "Script, \(AppleScriptCodeLayout.lineCountLabel(lineCount))",
                onOverflowChange: { overflows = $0 },
                onLastRowShown: onReviewed
            )
            if overflows {
                Text(AppleScriptCodeLayout.reviewFooter(lineCount: lineCount))
                    .font(Theme.font(10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// "Runs with Otto's access to: Accessibility · Calendars (macOS won't ask again)": what a script inherits
/// because it runs as Otto. Hidden when empty; tinted as a danger when it includes Accessibility or Screen
/// Recording, which let a script read the screen or drive other apps.
struct ScriptInheritedAccessRow: View {
    let access: [String]

    static let lead = "Runs with Otto's access to:"
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

    var body: some View {
        if !access.isEmpty {
            let danger = Self.isDanger(access)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: danger ? "exclamationmark.shield.fill" : "lock.shield")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(Self.lead)
                        .font(Theme.font(11.5, .medium))
                }
                .foregroundStyle(danger ? Theme.error : Theme.textSecondary)
                .frame(height: 22)
                ForEach(Array(access.enumerated()), id: \.offset) { _, name in
                    DockCardChrome.Chip(label: name, isDanger: Self.isDangerous(name), fontSize: 11)
                }
                Text(Self.trail)
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(height: 22)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spokenSummary(access))
        }
    }
}
