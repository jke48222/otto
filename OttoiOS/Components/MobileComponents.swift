//
//  MobileComponents.swift
//  Otto
//
//  Small pieces the iPhone screens share, in the Mac's clay look sized for touch: the felt background, round
//  clay and ghost buttons, the wrapping row, attachment chips and thumbnails, source pills and status lines.
//

import SwiftUI

// MARK: - Background

/// The near-black felt every screen sits on.
struct OttoBackground: View {
    var body: some View {
        Theme.panel
            .overlay { NoiseTexture() }
            .ignoresSafeArea()
    }
}

// MARK: - Buttons

/// A round button: a raised clay pebble (`.clay`) or a bare glyph that lights up when pressed (`.ghost`).
struct RoundIconButton: View {
    enum Style { case clay, ghost }

    let symbol: String
    let label: String
    var style: Style = .ghost
    var diameter: CGFloat = 36
    var glyphSize: CGFloat = 15
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundIconLabel(symbol: symbol, style: style, diameter: diameter, glyphSize: glyphSize)
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.92))
        .accessibilityLabel(label)
    }
}

/// The look of `RoundIconButton`, for menus that need it as their label.
struct RoundIconLabel: View {
    let symbol: String
    var style: RoundIconButton.Style = .ghost
    var diameter: CGFloat = 36
    var glyphSize: CGFloat = 15

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: glyphSize, weight: .medium))
            .foregroundStyle(Theme.textPrimary.opacity(0.9))
            .frame(width: diameter, height: diameter)
            .background {
                switch style {
                case .clay:
                    ClaySurface(shape: Circle(), style: .pebble)
                case .ghost:
                    Circle().fill(Color.white.opacity(0.001))
                }
            }
            .contentShape(Circle())
            // Touch targets stay at least 44 pt even when the drawn circle is smaller.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// The send disc: off-white with a dark arrow, a stop square while a reply streams.
struct SendButton: View {
    enum Mode { case send, stop }

    let mode: Mode
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: mode == .stop ? "stop.fill" : "arrow.up")
                .font(.system(size: mode == .stop ? 13 : 16, weight: .semibold))
                .foregroundStyle(isEnabled ? Theme.sendGlyph : Theme.sendDisabledGlyph)
                .frame(width: 34, height: 34)
                .background {
                    if isEnabled {
                        Circle().fill(LinearGradient(colors: [Theme.sendTop, Theme.sendBottom],
                                                     startPoint: .top, endPoint: .bottom))
                    } else {
                        Circle().fill(LinearGradient(stops: Theme.sendDisabledGradient,
                                                     startPoint: .top, endPoint: .bottom))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.9))
        .disabled(!isEnabled)
        .accessibilityLabel(mode == .stop ? "Stop" : "Send")
        .keyboardShortcut(mode == .stop ? KeyEquivalent(".") : .return, modifiers: .command)
    }
}

/// A small labeled action under a reply ("Retry", "Open Settings").
struct ReplyActionButton: View {
    let title: String
    let symbol: String
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(title)
                    .font(Theme.font(13.5, .medium))
            }
            .foregroundStyle(isProminent ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background {
                Capsule(style: .continuous).fill(Color.white.opacity(isProminent ? 0.09 : 0.05))
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
    }
}

// MARK: - Layout

/// Lays children out in rows, wrapping to the next row when one is full.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x: CGFloat
            switch alignment {
            case .trailing: x = bounds.maxX - row.width
            case .center: x = bounds.minX + (bounds.width - row.width) / 2
            default: x = bounds.minX
            }
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Attachments

/// An attachment's leading picture: its thumbnail, else a badge with its type ("PDF", "TXT", "WEB").
struct AttachmentThumb: View {
    let attachment: Attachment
    var size: CGFloat = 22

    var body: some View {
        if let thumbnail = attachment.thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .accessibilityHidden(true)
        } else if attachment.kind == .webPage {
            Image(systemName: "globe")
                .font(.system(size: size * 0.62, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Text(attachment.badge)
                .font(.system(size: max(7, size * 0.33), weight: .bold, design: .rounded))
                .foregroundStyle(Theme.badgeText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 2)
                .frame(width: size, height: size * 0.82)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.badgeFill))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// A composer chip: picture, name and a remove button.
struct AttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            AttachmentThumb(attachment: attachment, size: 22)
            Text(DisplayText.sanitized(attachment.displayName, maxLength: 80))
                .font(Theme.font(13.5))
                .foregroundStyle(Theme.chipLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.85))
            .accessibilityLabel("Remove \(attachment.displayName)")
        }
        .padding(.leading, 8)
        .frame(height: 36)
        .clay(cornerRadius: 12, style: .chip)
        .accessibilityElement(children: .combine)
    }
}

/// A chip for an item still loading.
struct PendingAttachmentChip: View {
    var body: some View {
        HStack(spacing: 7) {
            MiniSpinner(size: 13)
            Text("Adding…")
                .font(Theme.font(13.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .clay(cornerRadius: 12, style: .chip)
        .accessibilityLabel("Adding an attachment")
    }
}

/// An attachment above a sent message.
struct SentAttachmentChip: View {
    let attachment: Attachment
    let isUnavailable: Bool

    var body: some View {
        HStack(spacing: 6) {
            AttachmentThumb(attachment: attachment, size: 18)
            Text(DisplayText.sanitized(attachment.displayName, maxLength: 80))
                .font(Theme.font(12.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 170, alignment: .leading)
            if isUnavailable {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .opacity(isUnavailable ? 0.6 : 1)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isUnavailable ? "\(attachment.displayName), no longer stored" : attachment.displayName)
    }
}

// MARK: - Replies

/// A reply's sources: one quiet pill per host.
struct SourcePills: View {
    let sources: [SourceLink]
    private static let maxShown = 8

    @Environment(\.openURL) private var openURL

    private var entries: [SourceLink] {
        var seen: Set<String> = []
        return sources.filter { seen.insert(Self.host(of: $0.url)).inserted }
    }

    var body: some View {
        let all = entries
        FlowRow(spacing: 6, lineSpacing: 6) {
            ForEach(all.prefix(Self.maxShown)) { source in
                Button {
                    openURL(source.url)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.45))
                        Text(Self.host(of: source.url))
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.sourceLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 170)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(Capsule(style: .continuous).fill(Theme.sourcePillHoverFill))
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.96))
                .accessibilityLabel("Source: \(source.title.isEmpty ? Self.host(of: source.url) : source.title)")
            }
            if all.count > Self.maxShown {
                Text("+\(all.count - Self.maxShown)")
                    .font(Theme.font(12.5, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(height: 30)
            }
        }
    }

    static func host(of url: URL) -> String {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// One line of state under a reply: refused, failed or stopped.
struct ReplyStatusLine: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(Theme.font(14.5))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

/// The Mac's empty-page pattern: a glyph, a title and a line of explanation.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.font(17, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(Theme.font(14.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
    }
}
