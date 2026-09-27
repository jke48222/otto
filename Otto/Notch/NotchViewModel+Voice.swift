//
//  NotchViewModel+Voice.swift
//  Otto
//
//  Voice mode in the notch (§6.7): consent from the mic button only, the Microphone and Speech Recognition
//  requests (the notch folds while macOS asks), the cards for a missing microphone, Dictation turned off or
//  on-device speech that isn't available, what happens to a finished transcript, spoken replies and the hold that
//  keeps the notch open until a spoken question's reply has been read.
//

import Foundation
import os

extension NotchViewModel {
    // MARK: - State

    /// `.off` while voice is disabled (a click asks for consent); `.unavailable` while a voice card explains why
    /// Otto can't listen, or while Microphone or Speech Recognition is refused.
    var micState: MicState {
        guard settings.voice.enabled else { return .off }
        switch voice.phase {
        case .preparing, .listening: return .listening
        case .finishing: return .finishing
        case .idle: break
        }
        if let reason = queuedVoiceUnavailableReason { return .unavailable(reason) }
        if Self.isRefused(permissions.status(.microphone)) { return .unavailable(.microphoneDenied) }
        if Self.isRefused(permissions.status(.speechRecognition)) { return .unavailable(.speechDenied) }
        return .ready
    }

    // MARK: - Entry points

    /// The mic button and the global shortcut's hold. With voice off only the mic button asks for consent (a held
    /// shortcut is an ordinary tap then, §6.5). A session that had to wait for permissions starts in toggle mode:
    /// the key or button that asked for it was released during the dialogs.
    func beginVoice(_ mode: VoiceMode) {
        voice.stopSpeaking()
        guard !voice.isActive else { return }
        guard settings.voice.enabled else {
            guard mode.voiceSource == .micButton else { return }
            presentVoiceCard(Self.voiceConsentCard(pendingMode: mode, settings: settings))
            return
        }
        if mode.voiceSource == .micButton, let reason = queuedVoiceUnavailableReason {
            // The card already explains it; bring it forward instead of failing again the same way.
            presentVoiceCard(Self.voiceUnavailableCard(reason))
            return
        }
        if permissions.status(.microphone) == .granted, permissions.status(.speechRecognition) == .granted {
            startListening(mode)
            return
        }
        runVoicePermissions(thenListen: mode.asToggle)
    }

    /// Release, Return, the mic button: ends listening; the transcript arrives through `voice.onFinished`.
    func finishVoice(send: Bool) {
        voice.finish(send: send)
    }

    /// Esc, ⌘.: discards what was heard.
    func cancelVoice() {
        voice.cancel()
        setVoiceReplyHold(false)
    }

    func stopSpeaking() {
        voice.stopSpeaking()
    }

    // MARK: - Wiring

    func installVoiceFeatures() {
        voice.onFinished = { [weak self] transcript, send in
            self?.handleVoiceResult(transcript, send: send)
        }
        voice.onError = { [weak self] error in
            self?.handleVoiceError(error, mode: .toggle(.micButton))
        }
        voice.onNotice = { [weak self] message in
            self?.showNoticeWhenVisible(message)
        }
        chat.onAssistantTextProgress = { [weak self] assistantID, text, isFinal in
            self?.speakReplyIfWanted(assistantID: assistantID, text: text, isFinal: isFinal)
        }
    }

    /// Part of `chat.onReplyFinished` (after the unread bookkeeping): a reply that didn't complete stops being
    /// read, and a spoken question's hold ends 8 s after its reply (or when the speech ends, whichever is later).
    func voiceReplyDidFinish() {
        let finishedID = chat.lastFinishedAssistantID
        let finished = chat.messages.last { $0.id == finishedID }
        if finished?.state != .complete {
            voice.speaker.stop()
        }
        if voiceReplyHold {
            releaseVoiceReplyHold(afterReply: finishedID)
        }
    }

    // MARK: - Listening

    /// Starts a session now (permissions are granted). A card that said why Otto couldn't listen goes away.
    func startListening(_ mode: VoiceMode) {
        guard !voice.isActive else { return }
        do {
            try voice.start(mode)
            dismissVoiceUnavailableCards()
        } catch let error as VoiceError {
            handleVoiceError(error, mode: mode)
        } catch {
            transientError = error.localizedDescription
        }
    }

    /// Microphone, then Speech Recognition: a first request shows macOS's own dialog (the notch folds out of its
    /// way); a refusal shows the permission card, whose "Open System Settings" resumes listening once granted.
    private func runVoicePermissions(thenListen mode: VoiceMode) {
        Task { [weak self] in
            guard let self else { return }
            await self.permissions.refresh([.microphone, .speechRecognition])
            for permission in [Permission.microphone, .speechRecognition] {
                guard await self.obtainVoicePermission(permission) else { return }
            }
            self.startListening(mode)
        }
    }

    private func obtainVoicePermission(_ permission: Permission) async -> Bool {
        switch permissions.status(permission) {
        case .granted:
            return true
        case .notDetermined:
            if await requestFromNotch(permission) == .granted { return true }
            return await requestPermission(permission, for: .voice)
        case .denied, .restricted, .limited, .needsRelaunch, .unavailable:
            return await requestPermission(permission, for: .voice)
        }
    }

    /// What a failed start (or an error that ended a session) shows.
    func handleVoiceError(_ error: VoiceError, mode: VoiceMode) {
        Self.voiceLogger.notice("Voice couldn't listen: \(String(describing: error), privacy: .public)")
        switch error {
        case .microphoneDenied:
            askAgainForVoicePermission(.microphone, mode: mode)
        case .speechDenied:
            askAgainForVoicePermission(.speechRecognition, mode: mode)
        case .noInputDevice:
            presentVoiceCard(Self.voiceUnavailableCard(.noInputDevice))
        case .recognizerUnavailable(let localeName):
            presentVoiceCard(Self.voiceUnavailableCard(.recognizerUnavailable(localeName: localeName)))
        case .dictationDisabled:
            presentVoiceCard(Self.voiceUnavailableCard(.dictationDisabled))
        case .onDeviceUnavailable(let localeName):
            if settings.voice.allowServerRecognition {
                transientError = error.localizedDescription
            } else {
                presentVoiceCard(Self.onDeviceSpeechCard(localeName: localeName, pendingMode: mode.asToggle))
            }
        case .audioEngine, .recognition:
            transientError = error.localizedDescription
        }
    }

    private func askAgainForVoicePermission(_ permission: Permission, mode: VoiceMode) {
        Task { [weak self] in
            guard let self, await self.requestPermission(permission, for: .voice) else { return }
            self.startListening(mode.asToggle)
        }
    }

    // MARK: - Cards

    /// Shows a voice card (opening the notch focused: the user just asked to talk) and acts on the answer.
    private func presentVoiceCard(_ card: NotchCard) {
        if !isOpen {
            open(reason: .programmatic, focus: true)
        } else if route != .chat {
            navigate(to: .chat)
        }
        Task { [weak self] in
            guard let self else { return }
            let action = await self.awaitCardDecision(card)
            self.performVoiceCardAction(action)
        }
    }

    private func performVoiceCardAction(_ action: NotchCard.Action) {
        switch action {
        case .enableVoice(let mode):
            settings.voice.enabled = true
            Self.voiceLogger.info("Voice turned on from the consent card")
            runVoicePermissions(thenListen: mode.asToggle)
        case .useServerSpeech(let mode):
            settings.voice.allowServerRecognition = true
            startListening(mode.asToggle)
        case .openDictationSettings:
            if let url = URL(string: Self.dictationSettingsURL) {
                openExternalURL(url)
            }
        case .openSystemSettings(let permission):
            openSystemSettingsFromNotch(for: permission)
        case .openSettings(let tab):
            openSettings(tab: tab)
        case .dismiss, .useClickToOpen, .keepHover, .acknowledgeHistory, .declineHistory:
            break
        }
    }

    /// The reason of a queued "can't listen" card, if any.
    private var queuedVoiceUnavailableReason: VoiceUnavailableReason? {
        for queued in cardQueue {
            if case .voiceUnavailable(let reason) = queued.card.kind { return reason }
        }
        return nil
    }

    private func dismissVoiceUnavailableCards() {
        let kinds = cardQueue.map(\.card.kind).filter { kind in
            if case .voiceUnavailable = kind { return true }
            if case .onDeviceSpeechUnavailable = kind { return true }
            return false
        }
        for kind in kinds {
            removeCard(kind: kind)?.resume(returning: .dismiss)
        }
    }

    static let dictationSettingsURL = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"

    /// The first mic-button press with voice off. Mentions the shortcut only while it exists and can be held.
    static func voiceConsentCard(pendingMode: VoiceMode, settings: AppSettings) -> NotchCard {
        let holdHow = settings.hotKeyEnabled && settings.voice.holdShortcutToTalk
            ? "Hold the mic or \(settings.shortcuts.hotKey.displayString) and speak, then let go to send."
            : "Hold the mic and speak, then let go to send."
        return NotchCard(
            kind: .voiceConsent(pendingMode: pendingMode),
            symbol: "waveform",
            title: "Talk to Otto",
            message: holdHow + " Otto turns your words into text on this Mac, and only that text goes to Claude.",
            footnote: "You can change this anytime in Settings → Voice.",
            primary: NotchCard.ActionButton(title: "Turn On Voice", action: .enableVoice(pendingMode)),
            secondary: NotchCard.ActionButton(title: "Not Now", action: .dismiss),
            escapeAction: .dismiss,
            requiresDecision: true
        )
    }

    static func voiceUnavailableCard(_ reason: VoiceUnavailableReason) -> NotchCard {
        let notNow = NotchCard.ActionButton(title: "Not Now", action: .dismiss)
        let voiceSettings = NotchCard.ActionButton(title: "Voice Settings…", action: .openSettings(.voice))
        let ok = NotchCard.ActionButton(title: "OK", action: .dismiss)
        let title: String
        let message: String
        let primary: NotchCard.ActionButton
        let secondary: NotchCard.ActionButton
        switch reason {
        case .dictationDisabled:
            title = "Dictation is off"
            message = "Turn on Dictation in System Settings → Keyboard to talk to Otto."
            primary = NotchCard.ActionButton(title: "Open System Settings", action: .openDictationSettings)
            secondary = notNow
        case .noInputDevice:
            title = "No microphone found"
            message = "Connect a microphone or a headset to talk to Otto."
            primary = ok
            secondary = voiceSettings
        case .recognizerUnavailable(let localeName):
            title = "Speech recognition isn't available"
            message = "Speech recognition for \(localeName) isn't available right now. Try again in a moment, "
                + "or pick another language in Settings → Voice."
            primary = ok
            secondary = voiceSettings
        case .microphoneDenied:
            title = "Otto can't hear you yet"
            message = "Allow Microphone for Otto in System Settings → Privacy & Security."
            primary = NotchCard.ActionButton(title: "Open System Settings", action: .openSystemSettings(.microphone))
            secondary = notNow
        case .speechDenied:
            title = "Otto can't hear you yet"
            message = "Allow Speech Recognition for Otto in System Settings → Privacy & Security."
            primary = NotchCard.ActionButton(title: "Open System Settings",
                                             action: .openSystemSettings(.speechRecognition))
            secondary = notNow
        }
        return NotchCard(kind: .voiceUnavailable(reason), symbol: "mic.slash", title: title, message: message,
                         footnote: nil, primary: primary, secondary: secondary, escapeAction: .dismiss,
                         requiresDecision: true)
    }

    static func onDeviceSpeechCard(localeName: String, pendingMode: VoiceMode) -> NotchCard {
        NotchCard(
            kind: .onDeviceSpeechUnavailable(localeName: localeName, pendingMode: pendingMode),
            symbol: "waveform",
            title: "On-device speech isn't available",
            message: "On-device speech recognition isn't available for \(localeName). Otto can use Apple's speech "
                + "service, which sends your audio to Apple to be transcribed.",
            footnote: "You can change this anytime in Settings → Voice.",
            primary: NotchCard.ActionButton(title: "Use Apple's Service", action: .useServerSpeech(pendingMode)),
            secondary: NotchCard.ActionButton(title: "Not Now", action: .dismiss),
            escapeAction: .dismiss,
            requiresDecision: true
        )
    }

    // MARK: - Transcript

    static let heardNothingNotice = "Didn't catch that. Try again."
    static let stillReplyingNotice = "Otto is still replying. Press Return when it's done."

    /// `voice.onFinished`: nil → nothing; empty → a notice; a send with auto-send on → the composer is sent with
    /// its attachments (edit mode honored), except while a reply streams; anything else lands in the composer.
    func handleVoiceResult(_ transcript: String?, send: Bool) {
        guard let transcript else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            showNoticeWhenVisible(Self.heardNothingNotice)
            return
        }
        appendVoiceText(text)

        guard send else {
            // The 2-minute cap, a lost microphone or typing: the words wait in the composer. A closed notch stays
            // closed (the user may be away); its notice shows on the next open.
            if isOpen { requestFocus() }
            return
        }
        guard settings.voice.autoSend else {
            focusComposerForVoice()
            return
        }
        if chat.isStreaming, !isEditing {
            focusComposerForVoice()
            showNotice(Self.stillReplyingNotice, symbol: "info.circle", lifetime: .seconds(4))
            return
        }

        let wasClosed = !isOpen
        let openedByVoice = isOpen && openReason == .voice
        let previousUserID = chat.lastUserMessage?.id
        isSendingVoiceTurn = true
        self.send()
        isSendingVoiceTurn = false
        guard chat.lastUserMessage?.id != previousUserID else {
            // Not sent (an attachment still loading, or over a limit): the words stay in the composer.
            focusComposerForVoice()
            return
        }
        if wasClosed {
            open(reason: .voice, focus: false)
            setVoiceReplyHold(true)
        } else if openedByVoice {
            setVoiceReplyHold(true)
        }
    }

    private func appendVoiceText(_ text: String) {
        if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            composerText = text
        } else if composerText.last?.isWhitespace == true {
            composerText += text
        } else {
            composerText += " " + text
        }
    }

    private func focusComposerForVoice() {
        if isOpen {
            if route != .chat { navigate(to: .chat) }
            engage()
            requestFocus()
        } else {
            open(reason: .programmatic, focus: true)
        }
    }

    /// Voice notices that arrive while the notch is closed wait for the next open (the 4-second line would expire
    /// unseen).
    func showNoticeWhenVisible(_ message: String) {
        guard !isOpen else {
            showNotice(message, symbol: "info.circle", lifetime: .seconds(4))
            return
        }
        var pending: ObservationLoop<Bool>?
        pending = ObservationLoop(read: { [weak self] in self?.isOpen ?? false }, onChange: { [weak self] isOpen in
            guard isOpen else { return }
            pending?.cancel()
            pending = nil
            self?.showNotice(message, symbol: "info.circle", lifetime: .seconds(4))
        })
    }

    // MARK: - Spoken replies and the reply hold

    /// `chat.onAssistantTextProgress`: reads the reply aloud per Settings → Voice → "Read replies aloud".
    private func speakReplyIfWanted(assistantID: UUID, text: String, isFinal: Bool) {
        switch settings.voice.spokenReplies {
        case .off:
            return
        case .always:
            break
        case .afterVoice:
            guard let index = chat.messages.firstIndex(where: { $0.id == assistantID }),
                  let question = chat.messages[..<index].last(where: { $0.role == .user }),
                  voiceTurnUserMessageIDs.contains(question.id) else { return }
        }
        voice.speaker.progress(assistantID: assistantID, text: text, isFinal: isFinal)
    }

    /// Ends the hold `VoiceMetrics.replyHold` after the reply, or when Otto stops reading it aloud if that is
    /// later. A newer reply (another voice question) keeps its own hold.
    private func releaseVoiceReplyHold(afterReply replyID: UUID?) {
        Task { [weak self] in
            try? await Task.sleep(for: VoiceMetrics.replyHold)
            while self?.voice.isSpeaking == true, self?.voiceReplyHold == true {
                try? await Task.sleep(for: Self.speechEndPoll)
            }
            guard let self, self.voiceReplyHold, !self.chat.isStreaming,
                  self.chat.lastFinishedAssistantID == replyID else { return }
            self.setVoiceReplyHold(false)
        }
    }

    private static let speechEndPoll: Duration = .milliseconds(250)

    private static func isRefused(_ status: PermissionStatus) -> Bool {
        status == .denied || status == .restricted
    }

    static let voiceLogger = Logger(subsystem: "com.jalenedusei.otto", category: "Voice")
}

fileprivate extension VoiceMode {
    var voiceSource: VoiceSource {
        switch self {
        case .hold(let source), .toggle(let source): return source
        }
    }

    /// A session that waited on a dialog or a card: whatever was held has been released since.
    var asToggle: VoiceMode { .toggle(voiceSource) }
}
