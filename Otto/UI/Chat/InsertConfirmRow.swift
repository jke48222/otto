//
//  InsertConfirmRow.swift
//  Otto
//
//  The row under a reply's footer when a paste needs a yes first: several lines into a terminal (each may
//  run as a command), or a selection that changed since the question was asked.
//

import SwiftUI

struct InsertConfirmRow: View {
    struct Content: Equatable, Sendable {
        let message: String
        let confirmTitle: String
        let cancelTitle: String

        /// nil while nothing needs confirming (`.inserting`).
        static func make(for activity: InsertActivity) -> Content? {
            switch activity {
            case .inserting:
                return nil
            case .confirmMultiline(_, _, let lines, let appName):
                let app = displayName(appName)
                let count = lines == 1 ? "1 line" : "\(lines) lines"
                return Content(
                    message: "Paste \(count) into \(app)? Each line may run as a command.",
                    confirmTitle: "Paste",
                    cancelTitle: "Cancel"
                )
            case .selectionChanged(_, let appName):
                return Content(
                    message: "Your selection in \(displayName(appName)) changed.",
                    confirmTitle: "Paste at Cursor",
                    cancelTitle: "Copy"
                )
            }
        }

        private static func displayName(_ raw: String) -> String {
            let name = DisplayText.sanitized(raw, maxLength: InsertAnswerControl.Labels.maxAppNameLength)
            return name.isEmpty ? "the app" : name
        }
    }

    let activity: InsertActivity
    /// [Paste] / [Paste at Cursor].
    let onConfirm: () -> Void
    /// Cancel / Copy (the view model copies for a changed selection).
    let onCancel: () -> Void

    /// Slides down from the answer as it fades in; with Reduce Motion only the fade (§4.9).
    static func transition(reduceMotion: Bool) -> AnyTransition {
        .reducible(.opacity.combined(with: .move(edge: .top)), reduceMotion: reduceMotion)
    }

    var body: some View {
        if let content = Content.make(for: activity) {
            HStack(spacing: 10) {
                Text(content.message)
                    .font(Theme.font(12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                ConfirmButton(title: content.confirmTitle, action: onConfirm)
                TextButton(title: content.cancelTitle, action: onCancel)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
        }
    }

    /// Small off-white capsule, like a card's primary button.
    private struct ConfirmButton: View {
        let title: String
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.sendGlyph)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background {
                        Capsule(style: .continuous)
                            .fill(LinearGradient(colors: [Theme.sendTop, Theme.sendBottom], startPoint: .top, endPoint: .bottom))
                            .brightness(isHovering ? 0.03 : 0)
                    }
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
            .onHover { isHovering = $0 }
            .accessibilityLabel(title)
        }
    }

    private struct TextButton: View {
        let title: String
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
            .onHover { isHovering = $0 }
            .accessibilityLabel(title)
        }
    }
}
