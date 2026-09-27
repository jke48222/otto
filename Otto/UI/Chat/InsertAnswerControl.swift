//
//  InsertAnswerControl.swift
//  Otto
//
//  The reply footer's paste control: "[app icon] Paste into Notes ⌘↩ [⌄]", or "[⌶] Replace selection ⌘↩ [⌄]"
//  when the question carried a selection. The ⌄ menu offers the other ways to put the answer back.
//

import AppKit
import SwiftUI

struct InsertAnswerControl: View {
    /// The app the question was asked from.
    let app: AppRef
    /// `.replaceSelection` when the turn carried a selection, else `.paste`.
    let primaryMode: InsertMode
    let isInserting: Bool
    /// The "⌘↩" hint: only on the last reply, the one ⌘↩ acts on.
    let showsShortcut: Bool
    let onInsert: (InsertMode) -> Void
    let onCopy: () -> Void

    init(app: AppRef, primaryMode: InsertMode, isInserting: Bool, showsShortcut: Bool,
         onInsert: @escaping (InsertMode) -> Void, onCopy: @escaping () -> Void) {
        self.app = app
        self.primaryMode = primaryMode
        self.isInserting = isInserting
        self.showsShortcut = showsShortcut
        self.onInsert = onInsert
        self.onCopy = onCopy
    }

    /// Every string the control shows, from the app name and the primary mode.
    struct Labels: Equatable, Sendable {
        enum MenuAction: Equatable, Sendable { case insert(InsertMode), copy }
        struct MenuItem: Equatable, Sendable { let title: String; let action: MenuAction }

        let appName: String
        let primaryTitle: String
        let help: String
        let accessibilityLabel: String
        let menuItems: [MenuItem]

        static let pastingTitle = "Pasting…"
        static let menuHelp = "More ways to use this answer"

        /// Longest app name shown; longer names end in "…" (the button also truncates at 110 pt).
        static let maxAppNameLength = 40

        static func make(appName rawName: String, primaryMode: InsertMode) -> Labels {
            let name = DisplayText.sanitized(rawName, maxLength: maxAppNameLength)
            let appName = name.isEmpty ? "the app" : name
            let pasteTitle = "Paste into \(appName)"
            let plainItem = MenuItem(title: "Paste as Plain Text (⌥⌘↩)", action: .insert(.pastePlain))
            let copyItem = MenuItem(title: "Copy", action: .copy)
            switch primaryMode {
            case .replaceSelection:
                return Labels(
                    appName: appName,
                    primaryTitle: "Replace selection",
                    help: "Replace your selection in \(appName) with this answer (⌘↩)",
                    accessibilityLabel: "Replace selection in \(appName) with this answer",
                    menuItems: [MenuItem(title: pasteTitle, action: .insert(.paste)), plainItem, copyItem]
                )
            case .paste, .pastePlain:
                return Labels(
                    appName: appName,
                    primaryTitle: pasteTitle,
                    help: "Paste this answer into \(appName) (⌘↩)",
                    accessibilityLabel: "Paste answer into \(appName)",
                    menuItems: primaryMode == .pastePlain ? [copyItem] : [plainItem, copyItem]
                )
            }
        }
    }

    private var labels: Labels { Labels.make(appName: app.name, primaryMode: primaryMode) }

    var body: some View {
        HStack(spacing: 0) {
            PrimaryButton(
                labels: labels,
                app: app,
                primaryMode: primaryMode,
                isInserting: isInserting,
                showsShortcut: showsShortcut,
                action: { onInsert(primaryMode) }
            )
            MoreMenu(items: labels.menuItems, onInsert: onInsert, onCopy: onCopy)
                .disabled(isInserting)
        }
        .frame(height: 20)
        .fixedSize(horizontal: true, vertical: false)
    }

    private struct PrimaryButton: View {
        let labels: Labels
        let app: AppRef
        let primaryMode: InsertMode
        let isInserting: Bool
        let showsShortcut: Bool
        let action: () -> Void

        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 4) {
                    leadingGlyph
                    Text(isInserting ? Labels.pastingTitle : labels.primaryTitle)
                        .font(Theme.font(11.5, .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 110, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    if showsShortcut && !isInserting {
                        Text("⌘↩")
                            .font(Theme.font(10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize()
                    }
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(isHovering ? 0.08 : 0.05))
                }
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
            .disabled(isInserting)
            .onHover { isHovering = $0 }
            .help(labels.help)
            .accessibilityLabel(isInserting ? "Pasting into \(labels.appName)" : labels.accessibilityLabel)
        }

        @ViewBuilder
        private var leadingGlyph: some View {
            if isInserting {
                MiniSpinner(size: 10)
            } else if primaryMode == .replaceSelection {
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: 9.5, weight: .semibold))
            } else if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 9.5, weight: .semibold))
            }
        }
    }

    private struct MoreMenu: View {
        let items: [Labels.MenuItem]
        let onInsert: (InsertMode) -> Void
        let onCopy: () -> Void

        @State private var isHovering = false

        var body: some View {
            Menu {
                ForEach(items, id: \.title) { item in
                    Button(item.title) {
                        switch item.action {
                        case .insert(let mode): onInsert(mode)
                        case .copy: onCopy()
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(isHovering ? Theme.textSecondary : Theme.textTertiary)
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { isHovering = $0 }
            .help(Labels.menuHelp)
            .accessibilityLabel(Labels.menuHelp)
        }
    }
}
