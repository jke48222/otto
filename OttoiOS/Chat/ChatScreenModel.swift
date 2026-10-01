//
//  ChatScreenModel.swift
//  Otto
//
//  The iPhone chat screen's state and actions, the counterpart of the Mac's NotchViewModel: the draft and its
//  attachments, sending, stopping, regenerating and editing the last question, voice and spoken replies, Recents
//  and Settings, notices, and what happens when Otto leaves the screen and comes back. Everything that touches
//  the system goes through `ChatScreenServices`, so tests drive the whole screen without UIKit.
//

import Foundation
import Observation
import os

/// Platform effects the screen needs, as closures (tests pass recorders).
struct ChatScreenServices {
    /// Item providers for what is on the clipboard (images, links, text, files).
    var clipboardProviders: @MainActor () -> [NSItemProvider] = { [] }
    /// Puts text on the clipboard.
    var copyText: @MainActor (String) -> Void = { _ in }
    /// Opens iOS Settings at Otto's page (a refused permission).
    var openAppSettings: @MainActor () -> Void = {}
    var voicePermissions: VoicePermissionChecking = StaticVoicePermissions()
    /// Asks for notification permission (Settings → "Notify me when a reply finishes"); false when refused.
    var requestNotificationPermission: @MainActor () async -> Bool = { true }
    /// Live Activities are allowed for Otto in iOS Settings.
    var liveActivitiesAllowed: @MainActor () -> Bool = { true }
}

@MainActor @Observable final class ChatScreenModel {
    enum Sheet: String, Identifiable, Sendable {
        case recents, settings
        var id: String { rawValue }
    }

    /// One line above the composer, gone after a few seconds.
    struct Notice: Equatable, Identifiable, Sendable {
        let id: UUID
        let text: String
        let isError: Bool
        /// Shows an "Open Settings" button (a refused permission).
        var offersSettings: Bool
    }

    /// The question being edited: sending replaces it and its reply. The draft it displaced comes back on Cancel.
    struct EditingTurn: Equatable, Sendable {
        let userMessageID: UUID
        let displacedText: String
        let displacedAttachments: [Attachment]
    }

    /// A one-shot scroll request for the conversation.
    struct ScrollRequest: Equatable, Sendable {
        enum Target: Equatable, Sendable { case bottom, message(UUID) }
        let target: Target
        let serial: Int
    }

    /// Asked before the mic is used the first time, like the Mac's consent card.
    struct VoiceConsent: Equatable, Sendable {
        let pendingMode: VoiceMode
    }

    static let maxAttachments = 10
    static let attachmentLimitMessage = "You can attach up to \(maxAttachments) items."
    static let attachmentLoadTimeout: Duration = .seconds(30)
    static let noticeLifetime: Duration = .seconds(4)
    static let nothingToCopyNotice = "There's no reply to copy yet."
    static let copiedNotice = "Copied"
    static let heardNothingNotice = "Didn't catch that. Try again."
    static let stillReplyingNotice = "Otto is still replying. Send your words when it's done."
    static let microphoneDeniedNotice = "Otto can't hear you yet. Allow the microphone for Otto in Settings."
    static let speechDeniedNotice = "Otto can't turn speech into text yet. Allow Speech Recognition for Otto in Settings."

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Chat")

    // MARK: Composer

    var composerText: String
    private(set) var attachments: [Attachment]
    private(set) var pendingAttachmentLoads: Int
    private(set) var editing: EditingTurn?
    /// Bumped whenever the composer should take the keyboard.
    private(set) var focusRequest: Int

    // MARK: Screen

    var sheet: Sheet?
    private(set) var notice: Notice?
    private(set) var scrollRequest: ScrollRequest?
    /// A reply that finished while Otto was off screen and hasn't been looked at.
    private(set) var unreadReplyID: UUID?
    /// Otto is on screen (scene phase active).
    private(set) var isAppActive: Bool
    /// Bumped per send and per finished reply (haptics).
    private(set) var sendSerial: Int
    private(set) var replySerial: Int
    /// The mic's first-use question, while it is up.
    var voiceConsent: VoiceConsent?

    // MARK: Graph

    let settings: AppSettings
    let chat: ChatSession
    let history: HistoryController
    let recents: RecentsState
    let ledger: UsageLedger
    let voice: VoiceController
    let audio: AudioSessionCoordinator
    @ObservationIgnored let services: ChatScreenServices
    let isDemo: Bool

    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var scrollSerial = 0
    @ObservationIgnored private var loadingFileURLs: Set<URL> = []
    /// User messages asked by voice (spoken replies "When I ask by voice").
    @ObservationIgnored private var voiceTurnUserMessageIDs: Set<UUID> = []
    @ObservationIgnored private var isSendingVoiceTurn = false
    @ObservationIgnored private var speakingLoop: ObservationLoop<Bool>?

    init(settings: AppSettings, chat: ChatSession, history: HistoryController, recents: RecentsState,
         ledger: UsageLedger, voice: VoiceController, audio: AudioSessionCoordinator,
         services: ChatScreenServices = ChatScreenServices(), isDemo: Bool = false) {
        self.settings = settings
        self.chat = chat
        self.history = history
        self.recents = recents
        self.ledger = ledger
        self.voice = voice
        self.audio = audio
        self.services = services
        self.isDemo = isDemo
        composerText = ""
        attachments = []
        pendingAttachmentLoads = 0
        editing = nil
        focusRequest = 0
        sheet = nil
        notice = nil
        scrollRequest = nil
        unreadReplyID = nil
        isAppActive = true
        sendSerial = 0
        replySerial = 0
        voiceConsent = nil
        installVoiceFeatures()
    }

    // MARK: - Derived state

    var hasDraft: Bool {
        !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    var canSend: Bool {
        !chat.isStreaming && pendingAttachmentLoads == 0 && hasDraft
    }

    var isEditing: Bool { editing != nil }

    /// Room left for chips, counting loads still in flight.
    var remainingAttachmentCapacity: Int {
        max(0, Self.maxAttachments - attachments.count - pendingAttachmentLoads)
    }

    /// The chat needs a key before it can answer (and isn't the demo).
    var needsAPIKey: Bool { !isDemo && !settings.hasAPIKey }

    /// The mic, as the composer draws it.
    var micState: MicState {
        switch voice.phase {
        case .preparing, .listening: return .listening
        case .finishing: return .finishing
        case .idle: break
        }
        guard settings.voice.enabled else { return .off }
        if Self.isRefused(services.voicePermissions.microphone) { return .unavailable(.microphoneDenied) }
        if Self.isRefused(services.voicePermissions.speechRecognition) { return .unavailable(.speechDenied) }
        return .ready
    }

    // MARK: - Sending

    func send() {
        guard canSend else { return }
        // Checked again here: the model may have changed since the chips were added, and a PDF within Opus's page
        // limit can be over Haiku's. Such a message could never be answered.
        if let problem = AttachmentBudget.problem(with: attachments, model: settings.model) {
            showNotice(problem.localizedDescription, isError: true)
            return
        }
        let text = composerText
        let sent = attachments
        let previousUserID = chat.lastUserMessage?.id

        stopSpeaking()
        if let editing, editing.userMessageID == chat.lastUserMessage?.id {
            chat.replaceLastTurn(text: text, attachments: sent)
        } else {
            chat.send(text: text, attachments: sent)
        }
        editing = nil
        composerText = ""
        attachments = []

        if let userID = chat.lastUserMessage?.id, userID != previousUserID {
            if isSendingVoiceTurn { voiceTurnUserMessageIDs.insert(userID) }
            sendSerial += 1
        }
        isSendingVoiceTurn = false
        history.dismissContinuation()
        history.noteActivity()
        unreadReplyID = nil
        scroll(to: .bottom)
    }

    func stop() {
        chat.cancel()
    }

    func regenerate() {
        guard !chat.isStreaming else { return }
        stopSpeaking()
        if chat.regenerate() == .started {
            scroll(to: .bottom)
        }
    }

    func retry(_ messageID: UUID) {
        guard !chat.isStreaming else { return }
        chat.retry(messageID: messageID)
        scroll(to: .bottom)
    }

    /// Saves the conversation (offered back as Continue) and starts an empty one.
    func newChat() {
        stopSpeaking()
        if voice.isActive { voice.cancel() }
        editing = nil
        history.startNewConversation()
        composerText = ""
        attachments = []
        voiceTurnUserMessageIDs = []
        unreadReplyID = nil
        notice = nil
        focusRequest += 1
    }

    // MARK: - Editing the last question

    /// Puts the last question back in the composer; sending replaces it and its reply. A draft it displaces
    /// comes back on Cancel.
    func editLastQuestion() {
        guard let message = chat.lastUserMessage else { return }
        if editing == nil {
            editing = EditingTurn(userMessageID: message.id, displacedText: composerText,
                                  displacedAttachments: attachments)
        }
        composerText = message.text
        attachments = message.attachments
        focusRequest += 1
    }

    func cancelEditing() {
        guard let editing else { return }
        self.editing = nil
        composerText = editing.displacedText
        attachments = editing.displacedAttachments
    }

    // MARK: - Copy

    func copy(_ message: ChatMessage) {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        services.copyText(text)
        showNotice(Self.copiedNotice, isError: false)
    }

    func copyLastReply() {
        guard let text = chat.lastAssistantText else {
            showNotice(Self.nothingToCopyNotice, isError: true)
            return
        }
        services.copyText(text)
        showNotice(Self.copiedNotice, isError: false)
    }

    // MARK: - Attachments

    /// Files from the document picker (security-scoped URLs; the loader opens the scope while it reads).
    func addFiles(_ urls: [URL]) {
        var jobs: [AttachmentJob] = []
        for url in urls where url.isFileURL {
            let fileURL = url.standardizedFileURL
            let isDuplicate = loadingFileURLs.contains(fileURL)
                || jobs.contains { $0.sourceURL == fileURL }
                || attachments.contains { $0.sourceURL?.standardizedFileURL == fileURL }
            guard !isDuplicate else { continue }
            // The picker's own URL carries the security scope; a derived one may not.
            jobs.append(AttachmentJob(name: fileURL.lastPathComponent, sourceURL: fileURL) {
                try await AttachmentLoader.load(fileURL: url)
            })
        }
        start(jobs)
    }

    /// Photos (from the photo picker) and camera captures, as encoded bytes.
    func addImages(_ images: [(data: Data, typeIdentifier: String?, name: String)]) {
        let jobs = images.map { image in
            AttachmentJob(name: image.name, sourceURL: nil) {
                try await AttachmentLoader.load(imageData: image.data, typeIdentifier: image.typeIdentifier,
                                                name: image.name)
            }
        }
        start(jobs)
    }

    /// The clipboard: images, links and files become chips; short text goes into the composer.
    func pasteFromClipboard() {
        let providers = services.clipboardProviders()
        guard !providers.isEmpty else {
            showNotice("There's nothing on the clipboard to attach.", isError: true)
            return
        }
        addProviders(providers, textName: AttachmentLoader.clipboardTextName)
    }

    /// Items dragged onto the composer from another app: the same rules as the clipboard.
    func addDropped(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        addProviders(providers, textName: AttachmentLoader.droppedTextName)
    }

    private func addProviders(_ providers: [NSItemProvider], textName: String) {
        guard remainingAttachmentCapacity > 0 else {
            showNotice(Self.attachmentLimitMessage, isError: true)
            return
        }
        pendingAttachmentLoads += 1
        Task { [weak self] in
            let (content, errors) = await AttachmentLoader.load(providers: providers, textName: textName)
            guard let self else { return }
            self.pendingAttachmentLoads -= 1
            if let text = content.inlineText {
                self.appendToComposer(text)
                self.focusRequest += 1
            }
            var failures = errors
            for attachment in content.attachments {
                if let failure = self.insert(attachment, before: []) { failures.append(failure) }
            }
            self.report(failures)
        }
    }

    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// A load the composer waits on.
    private struct AttachmentJob {
        let name: String
        let sourceURL: URL?
        let load: @Sendable () async throws -> Attachment
    }

    /// Loads in parallel; each chip lands as soon as its item is read, in the order the items were picked.
    private func start(_ jobs: [AttachmentJob]) {
        guard !jobs.isEmpty else { return }
        let capacity = remainingAttachmentCapacity
        let accepted = Array(jobs.prefix(capacity))
        if accepted.count < jobs.count {
            showNotice(Self.attachmentLimitMessage, isError: true)
        }
        guard !accepted.isEmpty else { return }
        pendingAttachmentLoads += accepted.count
        let batch = LoadBatch(count: accepted.count)
        for (index, job) in accepted.enumerated() {
            if let url = job.sourceURL { loadingFileURLs.insert(url) }
            let load = job.load
            Task { [weak self] in
                let result = await Self.race(load, timeout: Self.attachmentLoadTimeout)
                guard let self else { return }
                self.pendingAttachmentLoads -= 1
                if let url = job.sourceURL { self.loadingFileURLs.remove(url) }
                switch result {
                case .success(let attachment)?:
                    if let failure = self.insert(attachment, before: batch.committedIDs(after: index)) {
                        batch.failures.append(failure)
                    } else {
                        batch.committed[index, default: []].append(attachment.id)
                    }
                case .failure(let error)?:
                    batch.failures.append(error)
                case nil:
                    batch.failures.append(AttachmentError.unreadable(name: job.name))
                }
                batch.remaining -= 1
                if batch.remaining == 0 { self.report(batch.failures) }
            }
        }
    }

    /// Adds a chip unless it is already attached (same file), there is no room, or it can't go to the current
    /// model. Returns why it was refused (nil for added or a silent duplicate).
    private func insert(_ attachment: Attachment, before laterIDs: Set<UUID>) -> Error? {
        if let url = attachment.sourceURL, url.isFileURL,
           attachments.contains(where: { $0.sourceURL?.standardizedFileURL == url.standardizedFileURL }) {
            return nil
        }
        guard attachments.count < Self.maxAttachments else {
            return AttachmentNotice(message: Self.attachmentLimitMessage)
        }
        if let problem = AttachmentBudget.problem(with: attachments + [attachment], model: settings.model) {
            return problem
        }
        if let position = attachments.firstIndex(where: { laterIDs.contains($0.id) }) {
            attachments.insert(attachment, at: position)
        } else {
            attachments.append(attachment)
        }
        return nil
    }

    /// One notice for a batch: the first failure, and how many more there were.
    private func report(_ failures: [Error]) {
        guard let first = failures.first else { return }
        let more = failures.count - 1
        let text = more > 0 ? "\(first.localizedDescription) (and \(more) more)" : first.localizedDescription
        showNotice(text, isError: true)
    }

    private final class LoadBatch {
        var remaining: Int
        var failures: [Error] = []
        var committed: [Int: [UUID]] = [:]

        init(count: Int) {
            remaining = count
        }

        func committedIDs(after index: Int) -> Set<UUID> {
            Set(committed.filter { $0.key > index }.values.joined())
        }
    }

    private struct AttachmentNotice: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The load's result, or nil when it took longer than `timeout` (a read that hangs is abandoned, not awaited).
    nonisolated static func race(_ load: @escaping @Sendable () async throws -> Attachment,
                                 timeout: Duration) async -> Result<Attachment, Error>? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<Attachment, Error>?, Never>) in
            let gate = ResumeOnce(continuation)
            Task.detached {
                do {
                    gate.resume(.success(try await load()))
                } catch {
                    gate.resume(.failure(error))
                }
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                gate.resume(nil)
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<Attachment, Error>?, Never>?

        init(_ continuation: CheckedContinuation<Result<Attachment, Error>?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Result<Attachment, Error>?) {
            let pending: CheckedContinuation<Result<Attachment, Error>?, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
    }

    // MARK: - Conversations

    func showRecents() {
        recents.activate(preferred: history.continuation?.id)
        sheet = .recents
    }

    func showSettings() {
        sheet = .settings
    }

    /// Opens a conversation from Recents; the sheet closes once it is in the chat.
    func openConversation(_ id: UUID) {
        stopSpeaking()
        editing = nil
        Task { [weak self] in
            guard let self else { return }
            if await self.history.open(id) {
                self.sheet = nil
                self.restoreReading()
            } else if let message = self.history.lastOpenError {
                self.showNotice(message, isError: true)
            }
        }
    }

    /// The Continue chip.
    func continueConversation() {
        stopSpeaking()
        Task { [weak self] in
            guard let self else { return }
            if await self.history.continueConversation() {
                self.restoreReading()
            } else if let message = self.history.lastOpenError {
                self.showNotice(message, isError: true)
            }
        }
    }

    func dismissContinuation() {
        history.dismissContinuation()
    }

    private func restoreReading() {
        let target = ReadingRestore.target(unreadReplyID: nil, saved: history.takeReadingPositionToRestore(),
                                           messages: chat.messages)
        switch target {
        case .messageTop(let messageID):
            scroll(to: .message(messageID))
        case .bottom:
            scroll(to: .bottom)
        }
    }

    // MARK: - Scrolling

    func scroll(to target: ScrollRequest.Target) {
        scrollSerial += 1
        scrollRequest = ScrollRequest(target: target, serial: scrollSerial)
    }

    // MARK: - Notices

    func showNotice(_ text: String, isError: Bool, offersSettings: Bool = false) {
        let notice = Notice(id: UUID(), text: text, isError: isError, offersSettings: offersSettings)
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeLifetime)
            guard !Task.isCancelled, let self, self.notice?.id == notice.id else { return }
            self.notice = nil
        }
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    func openAppSettings() {
        dismissNotice()
        services.openAppSettings()
    }

    // MARK: - Leaving and coming back

    /// Otto is on screen again: a fresh chat after the idle interval (the old one offered as Continue), and the
    /// reply that finished while you were away scrolled into view.
    func sceneBecameActive() {
        guard !isAppActive else { return }
        isAppActive = true
        if history.startFreshIfIdle(hasUnreadReply: unreadReplyID != nil, hasDraft: hasDraft) {
            editing = nil
            unreadReplyID = nil
            return
        }
        if let unread = unreadReplyID {
            unreadReplyID = nil
            scroll(to: .message(unread))
        }
    }

    /// Otto left the screen.
    func sceneEnteredBackground() {
        guard isAppActive else { return }
        isAppActive = false
        history.noteActivity()
    }

    /// `chat.onReplyFinished` (through the composition): unread while away, a tap of feedback while on screen.
    func replyFinished() {
        voiceReplyDidFinish()
        if isAppActive {
            replySerial += 1
        } else {
            unreadReplyID = chat.lastFinishedAssistantID
        }
    }

    /// A notification or the Live Activity was tapped: show that reply.
    func revealReply(_ messageID: UUID) {
        sheet = nil
        if unreadReplyID == messageID { unreadReplyID = nil }
        if chat.messages.contains(where: { $0.id == messageID }) {
            scroll(to: .message(messageID))
        }
    }

    // MARK: - Links and intents

    func handle(_ link: OttoDeepLink) {
        switch link {
        case .ask:
            sheet = nil
            focusRequest += 1
        case .newChat:
            sheet = nil
            newChat()
        case .reply(let id):
            revealReply(id)
        case .open:
            break
        }
    }

    func handle(_ request: OttoIntentRouter.Request) {
        sheet = nil
        switch request {
        case .newChat:
            newChat()
        case .ask(let question):
            guard let question else {
                focusRequest += 1
                return
            }
            if chat.isStreaming {
                // A reply is running: the question waits in the composer instead of interrupting it.
                appendToComposer(question)
                focusRequest += 1
                return
            }
            if !hasDraft {
                composerText = question
                send()
            } else {
                appendToComposer(question)
                focusRequest += 1
            }
        }
    }

    // MARK: - Voice

    /// The mic button: hold to talk, or tap to start and tap again to stop. The first use asks for consent, then
    /// Microphone and Speech Recognition (iOS's own prompts).
    func beginVoice(_ mode: VoiceMode) {
        stopSpeaking()
        guard !voice.isActive else { return }
        guard settings.voice.enabled else {
            voiceConsent = VoiceConsent(pendingMode: mode.asToggle)
            return
        }
        let permissions = services.voicePermissions
        if permissions.microphone == .granted, permissions.speechRecognition == .granted {
            startListening(mode)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard await self.obtainVoicePermissions() else { return }
            // The finger that asked was lifted during the prompts: listen until the mic is tapped again.
            self.startListening(mode.asToggle)
        }
    }

    /// The consent sheet's "Turn On Voice".
    func acceptVoiceConsent() {
        guard let consent = voiceConsent else { return }
        voiceConsent = nil
        settings.voice.enabled = true
        Self.logger.info("Voice turned on from the consent prompt")
        beginVoice(consent.pendingMode)
    }

    func declineVoiceConsent() {
        voiceConsent = nil
    }

    /// Release (hold) or the second tap (toggle): the transcript arrives through `voice.onFinished`.
    func finishVoice(send: Bool) {
        voice.finish(send: send)
    }

    func cancelVoice() {
        voice.cancel()
    }

    func stopSpeaking() {
        voice.stopSpeaking()
    }

    /// Reads one reply aloud from the start (the reply's Read Aloud).
    func readAloud(_ message: ChatMessage) {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.role == .assistant, !text.isEmpty, !voice.isActive else { return }
        if audio.mode != .speaking {
            audio.activate(.speaking)
        }
        voice.speaker.read(assistantID: message.id, text: message.text)
    }

    private func obtainVoicePermissions() async -> Bool {
        let permissions = services.voicePermissions
        let microphone = await permissions.requestMicrophone()
        guard microphone == .granted else {
            showNotice(Self.microphoneDeniedNotice, isError: true, offersSettings: true)
            return false
        }
        let speech = await permissions.requestSpeechRecognition()
        guard speech == .granted else {
            showNotice(Self.speechDeniedNotice, isError: true, offersSettings: true)
            return false
        }
        return true
    }

    private func startListening(_ mode: VoiceMode) {
        guard !voice.isActive else { return }
        guard audio.activate(.listening) else {
            showNotice(VoiceError.audioEngine("").localizedDescription, isError: true)
            return
        }
        do {
            try voice.start(mode)
        } catch let error as VoiceError {
            audio.activate(.idle)
            handleVoiceError(error)
        } catch {
            audio.activate(.idle)
            showNotice(error.localizedDescription, isError: true)
        }
    }

    private func handleVoiceError(_ error: VoiceError) {
        Self.logger.notice("Voice couldn't listen: \(String(describing: error), privacy: .public)")
        switch error {
        case .microphoneDenied:
            showNotice(Self.microphoneDeniedNotice, isError: true, offersSettings: true)
        case .speechDenied:
            showNotice(Self.speechDeniedNotice, isError: true, offersSettings: true)
        case .dictationDisabled:
            showNotice("Dictation is off. Turn on Dictation in Settings → General → Keyboard to talk to Otto.",
                       isError: true, offersSettings: false)
        case .onDeviceUnavailable(let localeName):
            showNotice("On-device speech recognition isn't available for \(localeName). Allow Apple's speech "
                       + "service in Otto's Settings → Voice to use it.", isError: true)
        case .noInputDevice, .recognizerUnavailable, .audioEngine, .recognition:
            showNotice(error.localizedDescription, isError: true)
        }
    }

    private func installVoiceFeatures() {
        voice.onFinished = { [weak self] transcript, send in
            self?.handleVoiceResult(transcript, send: send)
        }
        voice.onError = { [weak self] error in
            self?.releaseAudioIfQuiet()
            self?.handleVoiceError(error)
        }
        voice.onNotice = { [weak self] message in
            self?.showNotice(message, isError: false)
        }
        chat.onAssistantTextProgress = { [weak self] assistantID, text, isFinal in
            self?.speakReplyIfWanted(assistantID: assistantID, text: text, isFinal: isFinal)
        }
        let voice = voice
        speakingLoop = ObservationLoop(read: { voice.isSpeaking }) { [weak self] speaking in
            if !speaking { self?.releaseAudioIfQuiet() }
        }
    }

    /// `voice.onFinished`: nil → nothing; empty → a notice; a send with auto-send on → the message goes (unless a
    /// reply is still running); anything else waits in the composer.
    private func handleVoiceResult(_ transcript: String?, send: Bool) {
        releaseAudioIfQuiet()
        guard let transcript else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            showNotice(Self.heardNothingNotice, isError: false)
            return
        }
        appendToComposer(text)
        guard send, settings.voice.autoSend else {
            focusRequest += 1
            return
        }
        if chat.isStreaming, !isEditing {
            showNotice(Self.stillReplyingNotice, isError: false)
            return
        }
        isSendingVoiceTurn = true
        self.send()
        isSendingVoiceTurn = false
    }

    /// Back to an inactive session once Otto neither listens nor speaks, so other audio resumes.
    private func releaseAudioIfQuiet() {
        guard !voice.isActive, !voice.isSpeaking else { return }
        audio.activate(.idle)
    }

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
        guard !voice.isActive else { return }
        if audio.mode != .speaking {
            audio.activate(.speaking)
        }
        voice.speaker.progress(assistantID: assistantID, text: text, isFinal: isFinal)
    }

    /// A reply that didn't complete stops being read.
    private func voiceReplyDidFinish() {
        let finishedID = chat.lastFinishedAssistantID
        let finished = chat.messages.last { $0.id == finishedID }
        if finished?.state != .complete {
            voice.speaker.stop()
        }
    }

    private func appendToComposer(_ text: String) {
        if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            composerText = text
        } else if composerText.last?.isWhitespace == true {
            composerText += text
        } else {
            composerText += " " + text
        }
    }

    private static func isRefused(_ status: PermissionStatus) -> Bool {
        status == .denied || status == .restricted
    }

    // MARK: - Snapshots and tests

    /// Sets the visible composer state directly, without loads or side effects.
    func debugSeed(composerText: String, attachments: [Attachment], pendingAttachmentLoads: Int = 0,
                   notice: Notice? = nil, editing: EditingTurn? = nil) {
        self.composerText = composerText
        self.attachments = attachments
        self.pendingAttachmentLoads = pendingAttachmentLoads
        self.notice = notice
        self.editing = editing
    }
}

extension VoiceMode {
    /// A session that waited on a prompt: whatever was held has been released since.
    var asToggle: VoiceMode {
        switch self {
        case .hold(let source), .toggle(let source): return .toggle(source)
        }
    }
}
