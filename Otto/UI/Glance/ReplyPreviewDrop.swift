//
//  ReplyPreviewDrop.swift
//  Otto
//
//  The line the closed notch drops under the camera: a finished reply's first line, the approval
//  waiting for the user's OK, or what Otto is waiting for while system UI has the screen. The notch
//  shape itself grows to hold it (ClosedNotchLayout); this view fills the 28 pt it adds.
//

import SwiftUI

struct ReplyPreviewDrop: View {
    let content: DropContent
    /// Pointer over the drop; GlanceController pauses the preview's countdown while it is true.
    @Binding var isHovered: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The leading mark for each kind of drop.
    enum Icon: Equatable, Sendable {
        /// A finished answer: a warm-white checkmark.
        case answered
        /// A failed reply: the error triangle.
        case failed
        /// A declined request: a raised hand.
        case refused
        /// An approval waiting: the amber dot.
        case approval
        /// Waiting on system UI: an hourglass.
        case systemWait
    }

    /// Pure. The icon a drop leads with.
    static func icon(for content: DropContent) -> Icon {
        switch content {
        case .preview(let preview):
            switch preview.outcome {
            case .answered: return .answered
            case .failed: return .failed
            case .refused: return .refused
            }
        case .approval: return .approval
        case .systemWait: return .systemWait
        }
    }

    /// Pure. What VoiceOver reads for the drop.
    static func accessibilityLabel(for content: DropContent) -> String {
        switch content {
        case .preview(let preview):
            switch preview.outcome {
            case .answered: return "Otto replied: \(preview.text)"
            case .failed: return "Otto couldn't finish: \(preview.text)"
            case .refused: return "Otto declined: \(preview.text)"
            }
        case .approval, .systemWait:
            return content.text
        }
    }

    /// How the drop's content arrives and leaves inside the growing shape (glance.md §1.3): in, opacity
    /// with a 4 pt blur and a 6 pt drop after 0.08 s; out, a 0.12 s fade. Reduce Motion: 0.15 s fades.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion {
            return .opacity.animation(.easeInOut(duration: 0.15))
        }
        return .asymmetric(
            insertion: .modifier(active: DropArrival(progress: 0), identity: DropArrival(progress: 1))
                .animation(Theme.Motion.open.delay(0.08)),
            removal: .opacity.animation(.easeOut(duration: 0.12))
        )
    }

    var body: some View {
        HStack(spacing: ReplyPreviewMetrics.iconSpacing) {
            iconView
                .frame(width: ReplyPreviewMetrics.iconSize, height: ReplyPreviewMetrics.iconSize)
            Text(content.text)
                .font(Theme.font(ReplyPreviewMetrics.fontSize))
                .foregroundStyle(isHovered ? Theme.textPrimary : Theme.textBody)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, ReplyPreviewMetrics.horizontalPadding + NotchMetrics.closedTopRadius)
        .frame(maxWidth: .infinity)
        .frame(height: ReplyPreviewMetrics.dropHeight)
        .overlay {
            // A hairline along the drop's bottom curve while the pointer is on it.
            DropBottomEdge(inset: NotchMetrics.closedTopRadius, radius: ClosedNotchLayout.dropBottomRadius)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: content))
    }

    @ViewBuilder
    private var iconView: some View {
        switch Self.icon(for: content) {
        case .answered:
            symbol("checkmark", color: Theme.orbLight)
        case .failed:
            symbol("exclamationmark.triangle.fill", color: Theme.error)
        case .refused:
            symbol("hand.raised", color: Theme.textSecondary)
        case .approval:
            Circle()
                .fill(Theme.attention)
                .frame(width: 5, height: 5)
        case .systemWait:
            symbol("hourglass", color: Theme.textSecondary)
        }
    }

    private func symbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: ReplyPreviewMetrics.iconSize, weight: .semibold))
            .foregroundStyle(color)
    }
}

/// The drop content settling in: fades up while un-blurring (4 pt) and moving down 6 pt into place.
private struct DropArrival: ViewModifier {
    var progress: Double

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 4)
            .offset(y: (1 - progress) * -6)
    }
}

/// The bottom of the notch body under the drop: up each side by the corner radius, round the two
/// convex corners and along the bottom edge. `inset` is the width the shape's concave top ears take.
private struct DropBottomEdge: Shape {
    var inset: CGFloat
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + inset
        let right = rect.maxX - inset
        let corner = max(0, min(radius, (right - left) / 2, rect.height))
        guard right > left else { return Path() }
        // Half the hairline sits inside the edge so it isn't clipped by the shape.
        let bottom = rect.maxY - 0.5
        var path = Path()
        path.move(to: CGPoint(x: left + 0.5, y: bottom - corner))
        path.addArc(tangent1End: CGPoint(x: left + 0.5, y: bottom),
                    tangent2End: CGPoint(x: left + corner, y: bottom), radius: corner)
        path.addLine(to: CGPoint(x: right - corner, y: bottom))
        path.addArc(tangent1End: CGPoint(x: right - 0.5, y: bottom),
                    tangent2End: CGPoint(x: right - 0.5, y: bottom - corner), radius: corner)
        return path
    }
}
