//
//  PermissionCard.swift
//  Otto
//
//  The dock card for a macOS permission Otto needs, for tool calls and for features alike. All of its words
//  and buttons come from `PermissionCardContent`, the one copy table the view model also reads, so the card
//  and the Return-key rules can't disagree.
//

import Carbon.HIToolbox
import SwiftUI

struct PermissionCard: View {
    let content: PermissionCardContent
    /// The card stands in for a pending approval (a tool that needs macOS access first). Approvals never run on a
    /// bare Return, so its primary takes ⌘↩.
    let isApproval: Bool
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    init(content: PermissionCardContent, isApproval: Bool = false, onPrimary: @escaping () -> Void,
         onSecondary: @escaping () -> Void) {
        self.content = content
        self.isApproval = isApproval
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
    }

    /// The key cap on the primary, read from the notch's key map (§4.4) so the two can't disagree: "↩" when a bare
    /// Return performs it, "⌘↩" otherwise (Quit & Reopen Otto, and any card that stands in for an approval).
    static func primaryHint(for content: PermissionCardContent, isApproval: Bool = false) -> String? {
        guard content.primaryTitle != nil else { return nil }
        var context = NotchKeyContext()
        context.prompt = isApproval ? .approval : .other
        context.promptPrimaryRequiresCommand = content.primaryRequiresCommand
        let bareReturn = NotchKeyCommands.command(keyCode: UInt16(kVK_Return), characters: "\r", flags: [],
                                                  context: context)
        return bareReturn == .promptPrimary ? "↩" : "⌘↩"
    }

    /// The body's inline Markdown (bold names) as styled text; plain text if it doesn't parse.
    static func bodyText(_ body: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: body, options: options)) ?? AttributedString(body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DockCardChrome.spacing) {
            DockCardChrome.Header(
                symbol: content.symbol,
                title: content.title,
                symbolColor: content.primaryAction == nil && content.secondaryTitle.isEmpty
                    ? Theme.orbLight : Theme.textPrimary,
                showsSpinner: content.showsSpinner
            )
            if !content.body.isEmpty {
                Text(Self.bodyText(content.body))
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let steps = content.steps, !steps.isEmpty {
                Text(steps)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if content.primaryTitle != nil || !content.secondaryTitle.isEmpty {
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    if !content.secondaryTitle.isEmpty {
                        DockCardChrome.SecondaryButton(title: content.secondaryTitle, hint: "esc", action: onSecondary)
                    }
                    if let primary = content.primaryTitle {
                        DockCardChrome.PrimaryButton(title: primary, hint: Self.primaryHint(for: content, isApproval: isApproval),
                                                     action: onPrimary)
                            .accessibilityLabel(primary)
                    }
                }
                .frame(height: DockCardChrome.footerHeight)
            }
        }
        .dockCardChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.title)
        .onAppear { DockCardChrome.announce(content.title) }
        .onChange(of: content.title) { _, title in DockCardChrome.announce(title) }
    }
}
