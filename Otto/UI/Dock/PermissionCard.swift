//
//  PermissionCard.swift
//  Otto
//
//  The dock card for a macOS permission Otto needs, for tool calls and for features alike. All of its words
//  and buttons come from `PermissionCardContent`, the one copy table the view model also reads, so the card
//  and the Return-key rules can't disagree.
//

import SwiftUI

struct PermissionCard: View {
    let content: PermissionCardContent
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    init(content: PermissionCardContent, onPrimary: @escaping () -> Void, onSecondary: @escaping () -> Void) {
        self.content = content
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
    }

    /// Return performs the primary unless it quits Otto, which takes ⌘↩ (§4.4).
    static func primaryHint(for content: PermissionCardContent) -> String? {
        guard content.primaryTitle != nil else { return nil }
        return content.primaryRequiresCommand ? "⌘↩" : "↩"
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
                        DockCardChrome.PrimaryButton(title: primary, hint: Self.primaryHint(for: content),
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
