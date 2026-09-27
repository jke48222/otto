//
//  NotchHeaderView.swift
//  Otto
//
//  The header row of the expanded notch. It sits beside the camera housing, so its centre is
//  kept empty: the wordmark lives on the left, the ⋮ menu on the right.
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

    private var centerGap: CGFloat { viewModel.closedNotchSize.width + 20 }

    private var sideWidth: CGFloat {
        let inner = NotchMetrics.openWidth - NotchMetrics.openTopRadius * 2 - Self.horizontalPadding * 2
        return max(0, (inner - centerGap) / 2)
    }

    private var modelLabel: String {
        let name = viewModel.settings.model.shortName
        return LaunchOptions.demo ? "\(name) · demo" : name
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                OttoOrb(size: 12, isActive: viewModel.chat.isStreaming)
                // The model name shares the wordmark's baseline.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Otto")
                        .font(Theme.wordmark)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize()
                    Text(modelLabel)
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: sideWidth, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Otto, \(viewModel.settings.model.displayName)")

            Spacer(minLength: 0)

            HeaderMenuButton(viewModel: viewModel)
                // Let the hit area overhang so the pebble's edge lines up with the composer's.
                .padding(.trailing, -(HeaderMenuButton.hitSize - HeaderMenuButton.size) / 2)
                .frame(width: sideWidth, alignment: .trailing)
        }
        .frame(maxHeight: .infinity)
    }
}

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
            CopyLastResponseItem(chat: viewModel.chat) { viewModel.copyLastResponse() }
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
}

/// "Copy Last Response", enabled once a finished reply has text. It reads ChatSession's stored
/// `hasCopyableReply`, which only changes when a turn settles, so streamed deltas never touch it.
private struct CopyLastResponseItem: View {
    let chat: ChatSession
    let action: () -> Void

    var body: some View {
        Button("Copy Last Response", systemImage: "doc.on.doc", action: action)
            .disabled(!chat.hasCopyableReply)
    }
}
