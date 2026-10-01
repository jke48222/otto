//
//  ComposerArea.swift
//  Otto
//
//  The bottom of the chat: a notice line, the edit banner and the attachment chips over the clay slab, which
//  holds + (photos, camera, files, paste), the text field, the mic (hold to talk, or tap to start and tap again
//  to send) and send / stop. While Otto listens the field becomes a live waveform and transcript.
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ComposerArea: View {
    @Bindable var model: ChatScreenModel

    @FocusState private var isFieldFocused: Bool
    @State private var showsPhotoPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showsCamera = false
    @State private var showsFileImporter = false
    @State private var isDropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let placeholder = "Ask anything…"

    private var voice: VoiceController { model.voice }

    var body: some View {
        VStack(spacing: 8) {
            if let notice = model.notice {
                NoticeLine(notice: notice, onOpenSettings: { model.openAppSettings() }, onDismiss: { model.dismissNotice() })
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if voice.isSpeaking, !voice.isActive {
                ReadingAloudCapsule { model.stopSpeaking() }
                    .transition(.opacity)
            }
            if let editing = model.editing {
                EditingBanner(onCancel: { model.cancelEditing() })
                    .id(editing.userMessageID)
                    .transition(.opacity)
            }
            if !model.attachments.isEmpty || model.pendingAttachmentLoads > 0 {
                chips
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            slab
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(alignment: .top) {
            // The transcript fades out under the composer instead of ending at a hard edge.
            LinearGradient(
                stops: [
                    .init(color: Theme.panel.opacity(0), location: 0),
                    .init(color: Theme.panel.opacity(0.92), location: 0.35),
                    .init(color: Theme.panel, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.top, -18)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : Theme.Motion.content, value: model.notice?.id)
        .animation(reduceMotion ? nil : Theme.Motion.content, value: model.attachments.count)
        .animation(reduceMotion ? nil : Theme.Motion.content, value: model.isEditing)
        .animation(reduceMotion ? nil : Theme.Motion.content, value: voice.isSpeaking)
        .onChange(of: model.focusRequest) { _, _ in
            isFieldFocused = true
        }
        .onChange(of: voice.isActive) { _, active in
            // Listening takes the field's place; the keyboard would only cover the waveform.
            if active { isFieldFocused = false }
        }
        .photosPicker(
            isPresented: $showsPhotoPicker,
            selection: $photoSelection,
            maxSelectionCount: max(1, model.remainingAttachmentCapacity),
            selectionBehavior: .ordered,
            matching: .images,
            preferredItemEncoding: .compatible
        )
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            photoSelection = []
            loadPhotos(items)
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                model.addFiles(urls)
            case .failure(let error):
                model.showNotice(error.localizedDescription, isError: true)
            }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { image in
                guard let data = image.jpegData(compressionQuality: 0.9) else { return }
                model.addImages([(data: data, typeIdentifier: UTType.jpeg.identifier, name: "Photo.jpg")])
            }
            .ignoresSafeArea()
        }
        .onDrop(of: [.item], isTargeted: $isDropTargeted) { providers in
            model.addDropped(providers)
            return true
        }
    }

    // MARK: - Chips

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        model.removeAttachment(id: attachment.id)
                    }
                }
                ForEach(0..<model.pendingAttachmentLoads, id: \.self) { _ in
                    PendingAttachmentChip()
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    // MARK: - Slab

    private var slab: some View {
        HStack(alignment: .bottom, spacing: 2) {
            if voice.isActive {
                RoundIconButton(symbol: "xmark", label: "Cancel listening", diameter: 34, glyphSize: 14) {
                    model.cancelVoice()
                }
            } else {
                plusMenu
            }
            Group {
                if voice.isActive {
                    ListeningField(voice: voice)
                } else {
                    TextField(Self.placeholder, text: $model.composerText, axis: .vertical)
                        .font(Theme.font(17))
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.orbLight)
                        .lineLimit(1...8)
                        .focused($isFieldFocused)
                        .padding(.vertical, 12)
                        .accessibilityLabel("Message")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.leading, 2)

            MicButton(state: model.micState, mode: voice.mode) { action in
                switch action {
                case .begin(let mode): model.beginVoice(mode)
                case .finish(let send): model.finishVoice(send: send)
                case .cancel: model.cancelVoice()
                }
            }
            SendButton(mode: model.chat.isStreaming ? .stop : .send,
                       isEnabled: model.chat.isStreaming || model.canSend) {
                if model.chat.isStreaming {
                    model.stop()
                } else {
                    model.send()
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .clay(cornerRadius: 26, style: .slab, isHighlighted: isDropTargeted)
    }

    private var plusMenu: some View {
        Menu {
            Button {
                showsPhotoPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            if CameraPicker.isAvailable {
                Button {
                    showsCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
            Button {
                showsFileImporter = true
            } label: {
                Label("Choose Files", systemImage: "folder")
            }
            Button {
                model.pasteFromClipboard()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
        } label: {
            RoundIconLabel(symbol: "plus", diameter: 34, glyphSize: 17)
        }
        .accessibilityLabel("Attach")
    }

    // MARK: - Photos

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        Task {
            var images: [(data: Data, typeIdentifier: String?, name: String)] = []
            var failed = 0
            for (index, item) in items.enumerated() {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        failed += 1
                        continue
                    }
                    let type = item.supportedContentTypes.first
                    let ext = type?.preferredFilenameExtension ?? "jpg"
                    let name = items.count == 1 ? "Photo.\(ext)" : "Photo \(index + 1).\(ext)"
                    images.append((data: data, typeIdentifier: type?.identifier, name: name))
                } catch {
                    failed += 1
                }
            }
            if !images.isEmpty {
                model.addImages(images)
            }
            if failed > 0 {
                model.showNotice(failed == 1 ? "Otto couldn't read one of those photos."
                                             : "Otto couldn't read \(failed) of those photos.", isError: true)
            }
        }
    }
}

// MARK: - Lines above the slab

/// The notice slot: errors in the error color with a way out when there is one, confirmations quieter.
private struct NoticeLine: View {
    let notice: ChatScreenModel.Notice
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: notice.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
            Text(notice.text)
                .font(Theme.font(14))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if notice.offersSettings {
                Button("Open Settings", action: onOpenSettings)
                    .font(Theme.font(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .foregroundStyle(notice.isError ? Theme.error : Theme.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
                }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Dismiss", onDismiss)
    }
}

/// Shown while a reply is read aloud: what is happening and how to stop it.
private struct ReadingAloudCapsule: View {
    let onStop: () -> Void

    var body: some View {
        Button(action: onStop) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text("Reading aloud")
                    .font(Theme.font(14, .medium))
                Text("Stop")
                    .font(Theme.font(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .clay(cornerRadius: 18, style: .pebble)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.96))
        .accessibilityLabel("Stop reading aloud")
    }
}

/// The question is back in the composer: sending replaces it and its reply.
private struct EditingBanner: View {
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("Editing your last question")
                .font(Theme.font(14))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Button("Cancel", action: onCancel)
                .font(Theme.font(14, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(minHeight: 36)
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - Listening

/// The field while Otto listens: the live waveform and what it has heard so far.
private struct ListeningField: View {
    let voice: VoiceController

    private var hint: String {
        switch voice.phase {
        case .finishing: return "Finishing…"
        case .preparing: return "Getting ready…"
        case .idle, .listening: break
        }
        switch voice.mode {
        case .hold?: return "Listening… let go to send"
        case .toggle?, nil: return "Listening… tap the mic when you're done"
        }
    }

    var body: some View {
        let transcript = voice.transcript
        HStack(spacing: 10) {
            VoiceWaveformView(style: .inline, meter: voice.meter, isActive: voice.phase == .listening)
            Text(transcript.isEmpty ? hint : transcript)
                .font(Theme.font(16))
                .foregroundStyle(transcript.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(transcript.isEmpty ? hint : "Heard: \(transcript)")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The mic: hold to talk (let go to send, slide away to cancel), or tap to start and tap again to send.
private struct MicButton: View {
    enum Action { case begin(VoiceMode), finish(send: Bool), cancel }

    let state: MicState
    let mode: VoiceMode?
    let perform: (Action) -> Void

    /// The finger went down and hasn't been resolved into a tap or a hold yet.
    @State private var pressStart: Date?
    @State private var holdTask: Task<Void, Never>?
    @State private var isHolding = false
    @State private var wasListeningAtPress = false
    @State private var slidOff = false
    @GestureState private var isPressed = false

    /// Farther than this from the mic, letting go cancels.
    static let cancelDistance: CGFloat = 90

    private var isListening: Bool {
        state == .listening || state == .finishing
    }

    private var symbol: String {
        switch state {
        case .listening, .finishing:
            if case .toggle? = mode { return "stop.fill" }
            return "mic.fill"
        case .unavailable: return "mic.slash"
        case .off, .ready: return "mic"
        }
    }

    private var accessibilityText: String {
        switch state {
        case .listening, .finishing: return "Stop listening and send"
        case .unavailable: return "Voice unavailable"
        case .off, .ready: return "Talk to Otto"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(isListening ? Color.white : glyphColor)
            .frame(width: 34, height: 34)
            .background {
                Circle().fill(isListening ? Theme.recording.opacity(slidOff ? 0.35 : 0.9) : Color.clear)
            }
            .scaleEffect(isHolding ? 1.18 : (isPressed ? 0.92 : 1))
            .animation(Theme.Motion.press, value: isHolding)
            .animation(Theme.Motion.press, value: isPressed)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if isHolding {
                    Text(slidOff ? "Let go to cancel" : "Slide away to cancel")
                        .font(Theme.font(12, .medium))
                        .foregroundStyle(slidOff ? Theme.error : Theme.textSecondary)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .offset(y: -40)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .gesture(press)
            .onChange(of: isPressed) { _, pressed in
                // A press the system took away (an alert, a call) never reaches onEnded.
                guard !pressed else { return }
                Task { @MainActor in
                    guard pressStart != nil else { return }
                    resolveRelease(cancelled: true)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if isListening {
                    perform(.finish(send: true))
                } else {
                    perform(.begin(.toggle(.micButton)))
                }
            }
    }

    private var glyphColor: Color {
        switch state {
        case .unavailable: return Theme.textTertiary
        default: return Theme.textPrimary.opacity(0.9)
        }
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($isPressed) { _, pressed, _ in pressed = true }
            .onChanged { value in
                if pressStart == nil {
                    pressStart = Date()
                    wasListeningAtPress = isListening
                    slidOff = false
                    guard !wasListeningAtPress else { return }
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(VoiceMetrics.holdThreshold))
                        guard !Task.isCancelled, pressStart != nil else { return }
                        isHolding = true
                        perform(.begin(.hold(.micButton)))
                    }
                } else if isHolding {
                    let distance = hypot(value.translation.width, value.translation.height)
                    slidOff = distance > Self.cancelDistance
                }
            }
            .onEnded { _ in
                resolveRelease(cancelled: false)
            }
    }

    /// The finger came up (or the press was taken away): a hold ends its session, a tap starts or ends one.
    private func resolveRelease(cancelled: Bool) {
        guard pressStart != nil else { return }
        holdTask?.cancel()
        holdTask = nil
        defer {
            pressStart = nil
            isHolding = false
            slidOff = false
        }
        if isHolding {
            if slidOff {
                perform(.cancel)
            } else {
                // A press taken away keeps what was heard in the composer instead of sending it.
                perform(.finish(send: !cancelled))
            }
        } else if cancelled {
            return
        } else if wasListeningAtPress {
            perform(.finish(send: true))
        } else {
            perform(.begin(.toggle(.micButton)))
        }
    }
}
