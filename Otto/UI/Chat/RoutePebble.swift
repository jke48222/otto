//
//  RoutePebble.swift
//  Otto
//
//  A header pebble for one page of the open notch (Recents, Shelf). The active page's pebble carries a
//  white 0.10 wash and a primary-white glyph, and clicking it goes back to Chat. The Shelf pebble can carry
//  a count badge.
//

import SwiftUI

struct RoutePebble: View {
    let route: NotchRoute
    let isActive: Bool
    /// Items on the page (the Shelf's file count); nil or 0 shows no badge.
    var badgeCount: Int?
    let action: () -> Void

    init(route: NotchRoute, isActive: Bool, badgeCount: Int? = nil, action: @escaping () -> Void) {
        self.route = route
        self.isActive = isActive
        self.badgeCount = badgeCount
        self.action = action
    }

    /// The visible pebble, matching the ⋮ pebble.
    static let size: CGFloat = 28
    /// The clickable area around it.
    static let hitSize: CGFloat = 34
    /// The white wash on the open page's pebble.
    static let activeWashOpacity: Double = 0.10

    /// "3", "99+", or nil for no badge.
    static func badgeText(for count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    /// The chord that toggles this page (§4.4).
    static func shortcut(for route: NotchRoute) -> String? {
        switch route {
        case .chat: return nil
        case .history: return "⌘Y"
        case .shelf: return "⌘D"
        }
    }

    /// Tooltip: "Recents (⌘Y)", or "Back to Chat" on the active page.
    static func help(for route: NotchRoute, isActive: Bool) -> String {
        if isActive { return "Back to Chat" }
        guard let shortcut = shortcut(for: route) else { return route.title }
        return "\(route.title) (\(shortcut))"
    }

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: route.symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isActive ? Theme.textPrimary : Color.white.opacity(isHovering ? 0.9 : 0.72))
                .frame(width: Self.size, height: Self.size)
                .background {
                    ClaySurface(
                        shape: Circle(),
                        style: .pebble,
                        isHighlighted: isHovering && !isActive
                    )
                    .overlay {
                        // The open page's pebble: a lit wash, crossfaded in (color only).
                        Circle()
                            .fill(Color.white.opacity(Self.activeWashOpacity))
                            .opacity(isActive ? 1 : 0)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let badge = Self.badgeText(for: badgeCount) {
                        Text(badge)
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.badgeText)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 3.5)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Capsule().fill(Theme.badgeFill))
                            .offset(x: 4, y: -3)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: Self.hitSize, height: Self.hitSize)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .animation(.easeOut(duration: 0.15), value: isActive)
        .help(Self.help(for: route, isActive: isActive))
        .accessibilityLabel(route.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var accessibilityValue: String {
        guard let count = badgeCount, count > 0 else { return "" }
        return count == 1 ? "1 item" : "\(count) items"
    }
}
