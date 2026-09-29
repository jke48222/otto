//
//  ComposerView.swift
//  Otto
//
//  The composer well: a multi-line prompt field (or, while Otto listens, the live transcript over it), the mic,
//  the "+" attach menu and the off-white send / stop button. It glows while the keyboard goes to it and its
//  chrome dims while an approval waits in the dock (its text never does). While sending is paused (§14.10.1)
//  the send button is disabled and the text stays editable. Esc belongs to the panel's key monitor, never to
//  the field; ⇧↩ inserts a new line.
//

import AppKit
import SwiftUI

struct ComposerView: View {
    @Bindable var viewModel: NotchViewModel

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
    }

    @FocusState private var isFieldFocused: Bool
    @State private var focusTask: Task<Void, Never>?

    /// The tooltip of the send button, Regenerate and Retry while sending is paused (§14.10.1).
    static let sendingPausedHelp = "Sending is paused. See the line above."

    static let minHeight: CGFloat = 56
    static let cornerRadius: CGFloat = 26
    /// Hit area of the chromeless + button.
    static let attachSize: CGFloat = 30
    static let sendSize: CGFloat = 32
    /// Inset of the send button from the well's trailing and bottom edges.
    private static let trailingInset: CGFloat = 10
    private static let verticalInset: CGFloat = (minHeight - sendSize) / 2
    /// The well's chrome (slab, mic, +, send) while an approval waits in the dock: still usable for a draft, but
    /// clearly not the focus. The text and its placeholder ("Waiting for your OK…") are never dimmed, so they
    /// keep AA contrast; the dimmer slab behind them only raises it.
    private static let dimmedOpacity: Double = 0.55
    private var chromeOpacity: Double { viewModel.needsAttention ? Self.dimmedOpacity : 1 }
    /// Between the mic and the +, and from the + to send.
    private static let accessorySpacing: CGFloat = 8
    private static let sendSpacing: CGFloat = 12

    /// A voice session owns the well: the transcript shows over the (hidden) field.
    private var isVoiceActive: Bool { viewModel.voice.isActive }

    /// "Where do my keys go?": the panel is key and the field has focus (soft or hard focus alike).
    private var showsFocusGlow: Bool { viewModel.isPanelKey && isFieldFocused && !isVoiceActive }

    var body: some View {
        let placeholder = viewModel.composerPlaceholder
        HStack(alignment: .bottom, spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextField(
                    placeholder,
                    text: $viewModel.composerText,
                    prompt: Text(placeholder).foregroundStyle(Theme.placeholder),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(Theme.font(15))
                .foregroundStyle(Color.white.opacity(0.92))
                .tint(Theme.sendFill)
                .lineLimit(1...6)
                .focused($isFieldFocused)
                // The field editor treats ⇧↩ as a submit; only ⌥↩ inserts a line. Take ⇧↩ before it does, so it
                // inserts a new line as the ⌘/ sheet promises (interaction.md §4.5). Return alone still sends.
                .onKeyPress(.return, phases: .down) { press in
                    Self.insertsNewline(for: press.modifiers) && insertNewlineInField() ? .handled : .ignored
                }
                .onSubmit(submit)
                .opacity(isVoiceActive ? 0 : 1)
                .allowsHitTesting(!isVoiceActive)
                .accessibilityHidden(isVoiceActive)
                .accessibilityLabel("Message Otto")

                if isVoiceActive {
                    LiveTranscriptView(
                        finalizedText: viewModel.voice.finalizedText,
                        volatileText: viewModel.voice.volatileText,
                        meter: viewModel.voice.meter,
                        isFinishing: viewModel.voice.phase == .finishing
                    )
                    .transition(.opacity)
                }
            }
            // Center one line of 15 pt text on the 32 pt send button; extra lines grow upward.
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.18), value: isVoiceActive)

            HStack(spacing: Self.accessorySpacing) {
                MicButton(
                    state: viewModel.micState,
                    meter: viewModel.voice.meter,
                    onTap: tapMic,
                    onHoldBegan: { viewModel.beginVoice(.hold(.micButton)) },
                    onHoldEnded: {
                        if viewModel.voice.isActive { viewModel.finishVoice(send: true) }
                    },
                    onOpenVoiceSettings: { viewModel.openSettings(tab: .voice) }
                )
                AttachMenuButton(viewModel: viewModel)
            }
            // Sit on the send button's vertical center (the row is bottom-aligned).
            .padding(.bottom, (Self.sendSize - Self.attachSize) / 2)
            .padding(.leading, 8)
            .opacity(chromeOpacity)

            SendButton(viewModel: viewModel)
                .padding(.leading, Self.sendSpacing)
                .opacity(chromeOpacity)
        }
        .padding(.leading, 18)
        .padding(.trailing, Self.trailingInset)
        .padding(.vertical, Self.verticalInset)
        .frame(minHeight: Self.minHeight)
        .background {
            ClaySurface(shape: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .opacity(chromeOpacity)
        }
        .overlay { FocusGlow(isVisible: showsFocusGlow) }
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .onTapGesture { isFieldFocused = true }
        .animation(.easeOut(duration: 0.2), value: viewModel.needsAttention)
        .onChange(of: viewModel.focusRequest) { requestFocus() }
        .onAppear {
            if viewModel.isEngaged { requestFocus() }
        }
        .onDisappear { focusTask?.cancel() }
    }

    /// ⇧↩ (and ⌥↩, which the field editor already handles the same way) insert a new line; ↩ alone sends and the
    /// ⌘ chords belong to the panel's key map.
    static func insertsNewline(for modifiers: EventModifiers) -> Bool {
        let chord = modifiers.intersection([.shift, .option, .command, .control])
        return chord == .shift || chord == .option
    }

    /// Inserts a line break at the selection through the field editor, so undo and the binding both see it. Does
    /// nothing (returns false) while an input method is composing, which owns Return, or while the field isn't
    /// the first responder.
    private func insertNewlineInField() -> Bool {
        guard !isVoiceActive,
              let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
              textView.isEditable, !textView.hasMarkedText() else { return false }
        textView.insertNewlineIgnoringFieldEditor(nil)
        return true
    }

    /// Return in the field sends; while Otto listens it finishes and sends what was said instead.
    private func submit() {
        if viewModel.voice.isActive {
            viewModel.finishVoice(send: true)
            return
        }
        if viewModel.isSendBlocked {
            // send() keeps the draft and points at the gate line.
            viewModel.send()
            return
        }
        guard viewModel.canSend else { return }
        viewModel.send()
        requestFocus()
    }

    /// A click on the mic: starts listening (or asks for consent, or shows why it can't), and while listening
    /// finishes and sends.
    private func tapMic() {
        switch viewModel.micState {
        case .listening:
            viewModel.finishVoice(send: true)
        case .finishing:
            break
        case .off, .ready, .unavailable:
            viewModel.beginVoice(.toggle(.micButton))
        }
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

// MARK: - Focus glow

/// The well's top light brightens (the rim's white 0.10 reads as 0.18) and a 1 pt `orbLight` ring appears just
/// outside it, while the keyboard goes to the composer.
private struct FocusGlow: View {
    let isVisible: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ComposerView.cornerRadius, style: .continuous)
        ZStack {
            shape
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                .mask(alignment: .top) {
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 18)
                }
            shape
                .inset(by: -1)
                .strokeBorder(Theme.orbLight.opacity(0.22), lineWidth: 1)
        }
        .opacity(isVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: isVisible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Attach menu

private struct AttachMenuButton: View {
    let viewModel: NotchViewModel

    /// Whether the app the notch opened from has a window Otto may capture (checked on each open).
    private enum WindowAvailability: Equatable {
        case unknown, available, none, passwordManager
    }

    @State private var windowAvailability: WindowAvailability = .unknown

    static let passwordManagerCaption = "Otto doesn't capture password managers"

    var body: some View {
        // Reading the presentation re-evaluates the menu on every open, when the app it names is captured.
        let isOpen = viewModel.presentation == .open
        Menu {
            Button("Attach Files…", systemImage: "paperclip") { viewModel.pickFiles() }
            Button("Capture Screen Region", systemImage: "camera.viewfinder") { viewModel.captureScreenshot() }
            Button("Paste from Clipboard", systemImage: "doc.on.clipboard") { viewModel.pasteFromClipboard() }
            if isOpen, let selectionTitle = viewModel.selectionMenuTitle {
                Button(selectionTitle, systemImage: "text.quote") { viewModel.attachSelectionFromMenu() }
            }
            if isOpen, let windowTitle = viewModel.windowMenuTitle {
                Button(windowTitle, systemImage: "macwindow") { viewModel.attachWindowFromMenu() }
                    .disabled(windowAvailability != .available)
                if windowAvailability == .passwordManager {
                    Text(Self.passwordManagerCaption)
                }
            }
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
        .help("Attach files, a screenshot or the clipboard")
        .accessibilityLabel("Attach")
        .task(id: isOpen) { await refreshWindowAvailability(isOpen: isOpen) }
    }

    /// A window the chip already offers is capturable; a password manager never is; otherwise ask the window list.
    private func refreshWindowAvailability(isOpen: Bool) async {
        guard isOpen, let app = viewModel.openContextApp else {
            windowAvailability = .unknown
            return
        }
        if SensitiveApps.contains(app) {
            windowAvailability = .passwordManager
            return
        }
        if viewModel.suggestions.window?.app == app {
            windowAvailability = .available
            return
        }
        let hasWindow = await viewModel.suggestions.hasCapturableWindow(app)
        guard !Task.isCancelled else { return }
        windowAvailability = hasWindow ? .available : .none
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

    /// What the button does right now.
    private enum Role: Equatable {
        /// Finish listening and send what was said.
        case finishVoice
        /// The last words are landing; nothing to do.
        case finishing
        case stop
        case send
    }

    private var role: Role {
        switch viewModel.voice.phase {
        case .preparing, .listening: return .finishVoice
        case .finishing: return .finishing
        case .idle: break
        }
        return viewModel.chat.isStreaming ? .stop : .send
    }

    private var isEnabled: Bool {
        switch role {
        case .finishVoice, .stop: return true
        case .finishing: return false
        case .send: return viewModel.canSend
        }
    }

    private var help: String {
        switch role {
        case .finishVoice, .finishing: return "Send what you said (Return)"
        case .stop: return "Stop (⌘.)"
        case .send: return viewModel.isSendBlocked ? ComposerView.sendingPausedHelp : "Send (Return)"
        }
    }

    private var accessibilityLabel: String {
        switch role {
        case .finishVoice, .finishing: return "Send what you said"
        case .stop: return "Stop reply"
        case .send: return "Send"
        }
    }

    var body: some View {
        let role = self.role
        let isEnabled = self.isEnabled
        let isStop = role == .stop
        Button {
            switch role {
            case .finishVoice: viewModel.finishVoice(send: true)
            case .stop: viewModel.stop()
            case .send: if viewModel.canSend { viewModel.send() }
            case .finishing: break
            }
        } label: {
            Image(systemName: isStop ? "stop.fill" : "arrow.up")
                // 13 pt medium draws a thin arrow (≈1.5 pt stroke), as in the reference.
                .font(.system(size: isStop ? 11 : 13, weight: isStop ? .semibold : .medium))
                .foregroundStyle(isEnabled ? Theme.sendGlyph : Theme.sendDisabledGlyph)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: ComposerView.sendSize, height: ComposerView.sendSize)
                .background { disc(isEnabled: isEnabled) }
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!isEnabled)
        .animation(.easeOut(duration: 0.15), value: isEnabled)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Enabled: a cool light-grey disc, gently domed (#E2E3E5 → #C9CACC), with a line of light
    /// across its top and a soft shadow. Disabled: a dark clay disc on the pebble gradient (rather
    /// than a faded pearl, which reads as a muddy gray blob, or a flat grey hole).
    private func disc(isEnabled: Bool) -> some View {
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
