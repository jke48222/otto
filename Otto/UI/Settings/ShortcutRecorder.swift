//
//  ShortcutRecorder.swift
//  Otto
//
//  The global-shortcut field in Settings → General. Click it and press a combination: a valid one is
//  registered and saved, an invalid one (typing keys, macOS chords, Otto's own notch chords, a shortcut
//  another app holds) is refused with the reason and the old one stays. Delete while recording turns the
//  shortcut off (None); Esc cancels; ↺ goes back to ⌥Space.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorder: View {
    @Bindable var settings: AppSettings

    @State private var isRecording = false
    @State private var liveModifiers: NSEvent.ModifierFlags = []
    @State private var feedback: Feedback?
    @State private var shakes = 0
    @State private var feedbackTask: Task<Void, Never>?

    private enum Feedback: Equatable {
        case rejected(String)
        case applied(String)
    }

    init(settings: AppSettings) {
        self.settings = settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Keyboard shortcut")
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    RecorderField(
                        text: fieldText,
                        isPlaceholder: !isRecording && !settings.hotKeyEnabled,
                        isRecording: isRecording,
                        onBegin: beginRecording,
                        onCancel: endRecording,
                        onClear: clear,
                        onCommit: commit,
                        onLiveModifiers: { liveModifiers = $0 }
                    )
                    .frame(width: 150, height: 24)
                    .modifier(ShakeEffect(shakes: CGFloat(shakes)))
                    .accessibilityLabel("Keyboard shortcut")
                    .accessibilityValue(settings.hotKeyEnabled ? settings.shortcuts.hotKey.displayString : "None")
                    .accessibilityHint("Click, then press the new shortcut. Delete turns it off.")

                    Button {
                        reset()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to ⌥Space")
                    .accessibilityLabel("Reset to ⌥Space")
                    .opacity(Self.isDefault(settings) ? 0 : 1)
                    .disabled(Self.isDefault(settings))
                }
            }
            switch feedback {
            case .rejected(let message)?:
                SettingsCaption(message, color: SettingsTone.error)
            case .applied(let message)?:
                SettingsCaption(message)
            case nil:
                if settings.voice.enabled && settings.voice.holdShortcutToTalk && settings.hotKeyEnabled {
                    SettingsCaption("Hold it to talk.")
                }
            }
        }
        // Whatever ends recording elsewhere (the window closing, another recorder) ends it here too, so the field
        // never shows "Type shortcut…" while the global shortcut is registered again.
        .onChange(of: settings.shortcuts.isRecording) { _, recording in
            if !recording, isRecording {
                isRecording = false
                liveModifiers = []
            }
        }
        .onDisappear {
            if isRecording { endRecording() }
            feedbackTask?.cancel()
        }
    }

    private var fieldText: String {
        if isRecording {
            let held = HotKeyCombo(keyCode: 0, carbonModifiers: HotKeyCombo.carbonModifiers(from: liveModifiers))
            let glyphs = held.displayKeyCaps.dropLast().joined()
            return glyphs.isEmpty ? "Type shortcut…" : glyphs + "…"
        }
        return settings.hotKeyEnabled ? settings.shortcuts.hotKey.displayString : "None"
    }

    // MARK: Recording

    private func beginRecording() {
        isRecording = true
        liveModifiers = []
        settings.shortcuts.isRecording = true
        showFeedback(nil)
    }

    private func endRecording() {
        isRecording = false
        liveModifiers = []
        settings.shortcuts.isRecording = false
    }

    private func commit(_ combo: HotKeyCombo) {
        endRecording()
        present(Self.commit(combo, settings: settings, systemShortcuts: SystemShortcuts.current()), for: combo)
    }

    private func clear() {
        endRecording()
        Self.clear(settings: settings)
        showFeedback(nil)
    }

    private func reset() {
        present(Self.reset(settings: settings, systemShortcuts: SystemShortcuts.current()), for: .optionSpace)
    }

    private func present(_ result: HotKeyApplyResult, for combo: HotKeyCombo) {
        switch result {
        case .applied:
            showFeedback(.applied("Press \(combo.displayString) anywhere to open Otto."), clearAfter: .seconds(3))
        case .rejected(let message):
            showFeedback(.rejected(message))
            withAnimation(.linear(duration: 0.3)) { shakes += 1 }
        }
    }

    private func showFeedback(_ value: Feedback?, clearAfter delay: Duration? = nil) {
        feedbackTask?.cancel()
        feedback = value
        guard let delay else { return }
        feedbackTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            feedback = nil
        }
    }

    // MARK: Rules (tested)

    /// ⌥Space and on.
    @MainActor static func isDefault(_ settings: AppSettings) -> Bool {
        settings.hotKeyEnabled && settings.shortcuts.hotKey == .optionSpace
    }

    /// Validates `combo` (typing keys, macOS chords, enabled system shortcuts, Otto's own notch chords), then
    /// registers and saves it through `ShortcutSettings.apply`. A combo that took also turns the shortcut on.
    @MainActor @discardableResult
    static func commit(_ combo: HotKeyCombo, settings: AppSettings, systemShortcuts: [SystemShortcut]) -> HotKeyApplyResult {
        let problem = combo.validationProblem(systemShortcuts: systemShortcuts)
        let result = settings.shortcuts.apply(combo, validationMessage: problem?.errorDescription)
        if result == .applied, !settings.hotKeyEnabled {
            settings.hotKeyEnabled = true
        }
        return result
    }

    /// Delete while recording: no global shortcut (the field shows None). The stored combo is kept for later.
    @MainActor static func clear(settings: AppSettings) {
        settings.hotKeyEnabled = false
    }

    /// ↺: back to ⌥Space, on.
    @MainActor @discardableResult
    static func reset(settings: AppSettings, systemShortcuts: [SystemShortcut]) -> HotKeyApplyResult {
        commit(.optionSpace, settings: settings, systemShortcuts: systemShortcuts)
    }
}

// MARK: - Field

/// The rounded field that takes the keystrokes.
private struct RecorderField: NSViewRepresentable {
    let text: String
    let isPlaceholder: Bool
    let isRecording: Bool
    let onBegin: () -> Void
    let onCancel: () -> Void
    let onClear: () -> Void
    let onCommit: (HotKeyCombo) -> Void
    let onLiveModifiers: (NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        update(view)
        return view
    }

    func updateNSView(_ view: RecorderNSView, context: Context) {
        update(view)
    }

    private func update(_ view: RecorderNSView) {
        view.onBegin = onBegin
        view.onCancel = onCancel
        view.onClear = onClear
        view.onCommit = onCommit
        view.onLiveModifiers = onLiveModifiers
        view.display(text: text, isPlaceholder: isPlaceholder || isRecording, isRecording: isRecording)
    }
}

/// Internal (not private) for its unit tests.
final class RecorderNSView: NSView {
    var onBegin: () -> Void = {}
    var onCancel: () -> Void = {}
    var onClear: () -> Void = {}
    var onCommit: (HotKeyCombo) -> Void = { _ in }
    var onLiveModifiers: (NSEvent.ModifierFlags) -> Void = { _ in }

    private(set) var isRecording = false
    private let label = NSTextField(labelWithString: "")
    /// The window's resign-key and will-close observers while the view is in one.
    private var windowObservers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
        setAccessibilityRole(.button)
        updateColors()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Recording holds the global shortcut off (AppComposition unregisters it while `isRecording`). The Settings
    /// panel is non-activating, so clicking another app resigns its key status without resigning this first
    /// responder: stop recording then too, and when the window closes, so the shortcut never stays off unseen.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow !== window else { return }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        if newWindow == nil { cancelRecording() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, windowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        windowObservers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelRecording() }
            }
        }
    }

    /// Ends recording without changing the shortcut, as Esc does.
    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        updateColors()
        onCancel()
    }

    func display(text: String, isPlaceholder: Bool, isRecording: Bool) {
        label.stringValue = text
        label.textColor = isPlaceholder ? .secondaryLabelColor : .labelColor
        self.isRecording = isRecording
        updateColors()
    }

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        if !isRecording {
            isRecording = true
            onBegin()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        if !isRecording {
            isRecording = true
            onBegin()
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            // Space or Return on a focused field starts recording, like clicking it.
            if Int(event.keyCode) == kVK_Space || Int(event.keyCode) == kVK_Return {
                isRecording = true
                onBegin()
            } else {
                super.keyDown(with: event)
            }
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape where modifiers.isEmpty:
            cancelRecording()
        case kVK_Delete where modifiers.isEmpty, kVK_ForwardDelete where modifiers.isEmpty:
            isRecording = false
            onClear()
        default:
            guard let combo = HotKeyCombo(event: event) else { return }
            isRecording = false
            onCommit(combo)
        }
    }

    /// ⌘ combinations reach performKeyEquivalent before keyDown; while recording they belong to the recorder,
    /// not to the menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        if isRecording {
            onLiveModifiers(event.modifierFlags.intersection([.command, .option, .control, .shift]))
        }
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        }
    }
}

/// A short horizontal shake: three 4 pt swings per step of `shakes`.
private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 4 * sin(shakes * .pi * 6), y: 0))
    }
}
