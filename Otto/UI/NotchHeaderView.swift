//
//  NotchHeaderView.swift
//  Otto
//
//  The header row of the expanded notch. It sits beside the camera housing, so its centre is kept
//  empty. Left: the orb, the wordmark and the model quick menu on Chat, or a back pebble and the page
//  title on Recents and the Shelf. Right: the pin (while pinned), the Shelf and Recents pebbles and the
//  ⋮ menu. A double-click on the left group or the empty centre toggles tall reading mode.
//

import AppKit
import SwiftUI

struct NotchHeaderView: View {
    let viewModel: NotchViewModel

    /// Horizontal padding applied to the header by its container (inside the shape's side walls).
    static let horizontalPadding: CGFloat = 16
    /// Tall enough that the ⋮ pebble, centred on the row, keeps 6 pt of air under the panel's top
    /// edge instead of pressing against the bezel.
    static let minimumHeight: CGFloat = HeaderMenuButton.size + 2 * HeaderMenuButton.topClearance
    /// Between the controls of the right group.
    static let rightSpacing: CGFloat = 6

    // MARK: - Pure

    /// Width of each side group: the panel's inner width minus the camera gap, halved.
    static func sideWidth(closedNotchWidth: CGFloat) -> CGFloat {
        let inner = NotchMetrics.openWidth - NotchMetrics.openTopRadius * 2 - horizontalPadding * 2
        return max(0, (inner - (closedNotchWidth + 20)) / 2)
    }

    /// The Shelf pebble shows while the Shelf is on and has items, or while its page is open.
    static func showsShelfPebble(isShelfAvailable: Bool, itemCount: Int, route: NotchRoute) -> Bool {
        isShelfAvailable && (itemCount > 0 || route == .shelf)
    }

    /// Width the right group needs: the pin (22 pt), each pebble and ⋮ (34 pt hit areas), 6 pt apart.
    static func rightGroupWidth(isPinned: Bool, showsShelf: Bool, showsHistory: Bool) -> CGFloat {
        var widths: [CGFloat] = [HeaderMenuButton.hitSize]
        if showsHistory { widths.append(RoutePebble.hitSize) }
        if showsShelf { widths.append(RoutePebble.hitSize) }
        if isPinned { widths.append(PinIndicator.size) }
        return widths.reduce(0, +) + CGFloat(widths.count - 1) * rightSpacing
    }

    // MARK: - Body

    var body: some View {
        let sideWidth = Self.sideWidth(closedNotchWidth: viewModel.closedNotchSize.width)
        HStack(spacing: 0) {
            leftGroup
                .frame(width: sideWidth, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: toggleTallMode)

            // The camera gap: nothing drawn, but a double-click here toggles tall mode too.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: toggleTallMode)
                .accessibilityHidden(true)

            rightGroup
                // Let the hit areas overhang so the ⋮ pebble's edge lines up with the composer's.
                .padding(.trailing, -(HeaderMenuButton.hitSize - HeaderMenuButton.size) / 2)
                .frame(width: sideWidth, alignment: .trailing)
        }
        .frame(maxHeight: .infinity)
    }

    /// Tall reading mode belongs to the conversation, so the double-click only works on Chat.
    private func toggleTallMode() {
        guard viewModel.route == .chat else { return }
        viewModel.toggleTallMode()
    }

    // MARK: - Left group

    private var leftGroup: some View {
        ZStack(alignment: .leading) {
            if viewModel.route == .chat {
                chatTitle
                    .transition(.opacity)
            } else {
                PageTitle(route: viewModel.route) { viewModel.navigate(to: .chat) }
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.content, value: viewModel.route)
    }

    private var chatTitle: some View {
        HStack(spacing: 7) {
            OttoOrb(size: 12, isActive: viewModel.chat.isStreaming || viewModel.voice.isListening)
                .accessibilityHidden(true)
            // The model menu shares the wordmark's baseline.
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("Otto")
                    .font(Theme.wordmark)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                HeaderModelMenu(
                    settings: viewModel.settings,
                    onSelectModel: { viewModel.selectModel($0) },
                    onOpenSettings: { viewModel.openSettings() }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: viewModel.isTallMode ? "Exit tall reading mode" : "Tall reading mode",
                             toggleTallMode)
    }

    // MARK: - Right group

    private var rightGroup: some View {
        let routes = viewModel.availableRoutes
        let shelfCount = viewModel.shelf.store.items.count
        let showsShelf = Self.showsShelfPebble(isShelfAvailable: routes.contains(.shelf), itemCount: shelfCount,
                                               route: viewModel.route)
        return HStack(spacing: Self.rightSpacing) {
            if viewModel.isPinned {
                PinIndicator { viewModel.togglePin() }
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            if showsShelf {
                RoutePebble(route: .shelf, isActive: viewModel.route == .shelf, badgeCount: shelfCount) {
                    viewModel.toggle(route: .shelf)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            if routes.contains(.history) {
                RoutePebble(route: .history, isActive: viewModel.route == .history) {
                    viewModel.toggle(route: .history)
                }
            }
            HeaderMenuButton(viewModel: viewModel)
        }
        .animation(Theme.Motion.content, value: viewModel.isPinned)
        .animation(Theme.Motion.content, value: showsShelf)
    }
}

// MARK: - Page title

/// On Recents and the Shelf: a back pebble to Chat and the page's name in the wordmark's serif.
private struct PageTitle: View {
    let route: NotchRoute
    let onBack: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: RoutePebble.size, height: RoutePebble.size)
                    .background {
                        ClaySurface(shape: Circle(), style: .pebble, isHighlighted: isHovering)
                    }
                    .frame(width: RoutePebble.hitSize, height: RoutePebble.hitSize)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableButtonStyle(pressedScale: 0.95))
            // The hit area overhangs so the pebble's edge lines up with where the orb sits on Chat.
            .padding(.leading, -(RoutePebble.hitSize - RoutePebble.size) / 2)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
            .help("Back to Chat")
            .accessibilityLabel("Back to Chat")

            Text(route.title)
                .font(Theme.wordmark)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
        }
    }
}

// MARK: - ⋮ menu

private struct HeaderMenuButton: View {
    let viewModel: NotchViewModel

    /// The visible pebble.
    static let size: CGFloat = 28
    /// The clickable area around it.
    static let hitSize: CGFloat = 34
    /// Minimum air between the pebble and the panel's top edge.
    static let topClearance: CGFloat = 6

    var body: some View {
        Menu {
            Button("New Chat", systemImage: "square.and.pencil") { viewModel.newChat() }
                .keyboardShortcut("n", modifiers: .command)
            routeItems
            Divider()
            RegenerateItem(chat: viewModel.chat) { viewModel.regenerate() }
            CopyLastResponseItem(chat: viewModel.chat) { viewModel.copyLastResponse() }
            Divider()
            Button(viewModel.isPinned ? "Unpin" : "Pin Open",
                   systemImage: viewModel.isPinned ? "pin.slash" : "pin") { viewModel.togglePin() }
                .keyboardShortcut("p", modifiers: .command)
            tallModeItem
            Button("Keyboard Shortcuts", systemImage: "keyboard") { viewModel.toggleShortcutSheet() }
                .keyboardShortcut("/", modifiers: .command)
            Divider()
            UsageMenuItems(ledger: viewModel.ledger) { viewModel.openUsageDetails() }
            Divider()
            Button("Settings…", systemImage: "gearshape") { viewModel.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit Otto", systemImage: "power") { NSApp.terminate(nil) }
        } label: {
            VerticalDots()
                .frame(width: Self.hitSize, height: Self.hitSize)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .clayMenuButton(isMenuPresented: viewModel.isMenuPresented, diameter: Self.size)
        .help("Otto menu")
        .accessibilityLabel("Otto menu")
    }

    /// Recents and the Shelf, when they exist. The page showing now carries a checkmark; choosing it again
    /// goes back to Chat.
    @ViewBuilder
    private var routeItems: some View {
        let routes = viewModel.availableRoutes
        if routes.contains(.history) {
            Toggle(isOn: routeBinding(.history)) {
                Label("Recent Conversations", systemImage: NotchRoute.history.symbol)
            }
            .keyboardShortcut("y", modifiers: .command)
        }
        if routes.contains(.shelf) {
            Toggle(isOn: routeBinding(.shelf)) {
                Label(NotchRoute.shelf.title, systemImage: NotchRoute.shelf.symbol)
            }
            .keyboardShortcut("d", modifiers: .command)
        }
    }

    @ViewBuilder
    private var tallModeItem: some View {
        if viewModel.isTallMode {
            Button("Exit Tall Reading Mode", systemImage: "arrow.down.right.and.arrow.up.left") {
                viewModel.setTallMode(false)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
        } else {
            Button("Tall Reading Mode", systemImage: "arrow.up.left.and.arrow.down.right") {
                viewModel.setTallMode(true)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
        }
    }

    private func routeBinding(_ route: NotchRoute) -> Binding<Bool> {
        Binding(get: { viewModel.route == route }, set: { _ in viewModel.toggle(route: route) })
    }
}

/// "Regenerate", once there is a turn to answer again. It reads ChatSession's O(1) message count, so
/// streamed deltas never touch it.
private struct RegenerateItem: View {
    let chat: ChatSession
    let action: () -> Void

    var body: some View {
        Button("Regenerate", systemImage: "arrow.clockwise", action: action)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(chat.messageCount == 0)
    }
}

/// "Copy Last Response", enabled once a finished reply has text. It reads ChatSession's stored
/// `hasCopyableReply`, which only changes when a turn settles, so streamed deltas never touch it.
private struct CopyLastResponseItem: View {
    let chat: ChatSession
    let action: () -> Void

    var body: some View {
        Button("Copy Last Response", systemImage: "doc.on.doc", action: action)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!chat.hasCopyableReply)
    }
}
