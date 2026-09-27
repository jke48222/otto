//
//  VersionPager.swift
//  Otto
//
//  "‹ 2/3 ›" in the last reply's footer when that turn has been regenerated: steps through the kept
//  replies. Disabled at the ends and while a reply streams.
//

import SwiftUI

struct VersionPager: View {
    /// Where the shown reply sits among the turn's replies.
    struct Position: Equatable, Sendable {
        /// 0-based index of the shown reply.
        let index: Int
        /// Pages: the stored replies, plus one when the shown reply isn't stored (it failed, was cancelled,
        /// was refused or is still streaming).
        let count: Int
        /// Stored replies the pager can switch to.
        let storedCount: Int

        var label: String { "\(index + 1)/\(count)" }
        var previousIndex: Int? { index > 0 ? min(index - 1, storedCount - 1) : nil }
        var nextIndex: Int? { index + 1 < storedCount ? index + 1 : nil }
    }

    /// nil when there is nothing to page through: no versions, or a single stored reply that is the one shown.
    static func position(for versions: ChatSession.ReplyVersions?) -> Position? {
        guard let versions else { return nil }
        return position(currentIndex: versions.currentIndex, storedCount: versions.replies.count)
    }

    static func position(currentIndex: Int, storedCount: Int) -> Position? {
        guard storedCount > 0 else { return nil }
        let showsUnstored = currentIndex >= storedCount
        let count = storedCount + (showsUnstored ? 1 : 0)
        guard count > 1 else { return nil }
        return Position(index: min(max(currentIndex, 0), count - 1), count: count, storedCount: storedCount)
    }

    let position: Position
    let isStreaming: Bool
    /// Shows stored reply `index` (ChatSession.showReplyVersion).
    let onShow: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ChevronButton(symbol: "chevron.left", label: "Previous version") {
                if let index = position.previousIndex { onShow(index) }
            }
            .disabled(isStreaming || position.previousIndex == nil)

            Text(position.label)
                .font(Theme.font(11))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 2)
                .accessibilityHidden(true)

            ChevronButton(symbol: "chevron.right", label: "Next version") {
                if let index = position.nextIndex { onShow(index) }
            }
            .disabled(isStreaming || position.nextIndex == nil)
        }
        .frame(height: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Version \(position.index + 1) of \(position.count)")
    }

    /// A chevron in FooterButton's look: tertiary at rest, a faint plate and primary glyph on hover.
    private struct ChevronButton: View {
        let symbol: String
        let label: String
        let action: () -> Void

        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isHovering && isEnabled ? Theme.textPrimary : Theme.textTertiary)
                    .frame(width: 20, height: 20)
                    .background {
                        Circle().fill(Color.white.opacity(isHovering && isEnabled ? 0.08 : 0))
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.9))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovering = $0 }
            .help(label)
            .accessibilityLabel(label)
        }
    }
}
