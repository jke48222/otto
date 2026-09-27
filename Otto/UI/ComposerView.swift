//
//  ComposerView.swift
//  Otto
//
//  The composer well: a multi-line prompt field, the "+" attach menu and the off-white
//  send / stop button.
//

import AppKit
import SwiftUI

struct ComposerView: View {
    @Bindable var viewModel: NotchViewModel
    @FocusState private var isFieldFocused: Bool
    @State private var focusTask: Task<Void, Never>?

    static let minHeight: CGFloat = 56
    static let cornerRadius: CGFloat = 26
    /// Hit area of the chromeless + button.
    static let attachSize: CGFloat = 30
    static let sendSize: CGFloat = 32
    /// Inset of the send button from the well's trailing and bottom edges.
    private static let trailingInset: CGFloat = 10
    private static let verticalInset: CGFloat = (minHeight - sendSize) / 2

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            TextField(
                "Ask Otto anything…",
                text: $viewModel.composerText,
                prompt: Text("Ask Otto anything…").foregroundStyle(Theme.rgb(0x76767B)),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(Theme.font(15))
            .foregroundStyle(Color.white.opacity(0.92))
            .tint(Theme.sendFill)
            .lineLimit(1...6)
            .focused($isFieldFocused)
            .onSubmit(submit)
            .onExitCommand { viewModel.close() }
            // Center one line of 15 pt text on the 32 pt send button; extra lines grow upward.
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Message Otto")

            HStack(spacing: 12) {
                AttachMenuButton(viewModel: viewModel)
                SendButton(viewModel: viewModel)
            }
            .padding(.leading, 8)
        }
        .padding(.leading, 18)
        .padding(.trailing, Self.trailingInset)
        .padding(.vertical, Self.verticalInset)
        .frame(minHeight: Self.minHeight)
        .clay(cornerRadius: Self.cornerRadius)
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .onTapGesture { isFieldFocused = true }
        .onChange(of: viewModel.focusRequest) { requestFocus() }
        .onAppear {
            if viewModel.isEngaged { requestFocus() }
        }
        .onDisappear { focusTask?.cancel() }
    }

    private func submit() {
        guard viewModel.canSend else { return }
        viewModel.send()
        requestFocus()
    }

    /// The panel may only just be becoming key when focus is requested, so focus on the next
    /// run-loop turns rather than synchronously.
    private func requestFocus() {
        focusTask?.cancel()
        focusTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            isFieldFocused = true
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, !isFieldFocused else { return }
            isFieldFocused = true
        }
    }
}

// MARK: - Attach menu

private struct AttachMenuButton: View {
    let viewModel: NotchViewModel

    var body: some View {
        Menu {
            Button("Attach Files…", systemImage: "paperclip") { viewModel.pickFiles() }
            Button("Capture Screen Region", systemImage: "camera.viewfinder") { viewModel.captureScreenshot() }
            Button("Paste from Clipboard", systemImage: "doc.on.clipboard") { viewModel.pasteFromClipboard() }
            if let suggestion = viewModel.suggestedTab {
                Divider()
                Button("Attach Current Tab", systemImage: "globe") { viewModel.acceptSuggestedTab() }
                    .help(suggestion.displayName)
            }
        } label: {
            PlusGlyph()
                .stroke(Color.white.opacity(0.78), style: StrokeStyle(lineWidth: PlusGlyph.lineWidth, lineCap: .round))
                .frame(width: 14, height: 14)
                .frame(width: ComposerView.attachSize, height: ComposerView.attachSize)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .ghostMenuButton(isMenuPresented: viewModel.isMenuPresented)
        // Sit on the send button's vertical center (the row is bottom-aligned).
        .padding(.bottom, (ComposerView.sendSize - ComposerView.attachSize) / 2)
        .help("Attach files, a screenshot or the clipboard")
        .accessibilityLabel("Attach")
    }
}

/// A thin, even-stroked + (the SF Symbol's light weight is not adjustable to 1.25 pt).
private struct PlusGlyph: Shape {
    static let lineWidth: CGFloat = 1.25

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // The round caps reach half a stroke past the ends, so the glyph spans exactly the frame.
        let inset = Self.lineWidth / 2
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + inset))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - inset))
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.midY))
        return path
    }
}

// MARK: - Send / stop

private struct SendButton: View {
    let viewModel: NotchViewModel

    private var isStreaming: Bool { viewModel.chat.isStreaming }
    private var isEnabled: Bool { isStreaming || viewModel.canSend }

    var body: some View {
        Button {
            if isStreaming {
                viewModel.stop()
            } else if viewModel.canSend {
                viewModel.send()
            }
        } label: {
            Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                // 13 pt medium draws a thin arrow (≈1.5 pt stroke), as in the reference.
                .font(.system(size: isStreaming ? 11 : 13, weight: isStreaming ? .semibold : .medium))
                .foregroundStyle(isEnabled ? Theme.sendGlyph : Theme.sendDisabledGlyph)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: ComposerView.sendSize, height: ComposerView.sendSize)
                .background { disc }
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!isEnabled)
        .animation(.easeOut(duration: 0.15), value: isEnabled)
        .help(isStreaming ? "Stop" : "Send (Return)")
        .accessibilityLabel(isStreaming ? "Stop reply" : "Send")
    }

    /// Enabled: a cool light-grey disc, gently domed (#E2E3E5 → #C9CACC), with a line of light
    /// across its top and a soft shadow. Disabled: a dark clay disc on the pebble gradient (rather
    /// than a faded pearl, which reads as a muddy gray blob, or a flat grey hole).
    private var disc: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Theme.sendTop, Theme.sendBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.5), location: 0),
                                .init(color: Color.white.opacity(0), location: 0.45),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
                }
                .background { LayeredShadow(shape: Circle(), opacity: 0.5, radius: 6, y: 2.5, layers: 8) }
                .opacity(isEnabled ? 1 : 0)
            Circle()
                .fill(LinearGradient(stops: Theme.sendDisabledGradient, startPoint: .top, endPoint: .bottom))
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.12), location: 0),
                                .init(color: Color.white.opacity(0), location: 0.45),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
                }
                .background { LayeredShadow(shape: Circle(), opacity: 0.45, radius: 3, y: 1.5, layers: 6) }
                .opacity(isEnabled ? 0 : 1)
        }
    }
}
