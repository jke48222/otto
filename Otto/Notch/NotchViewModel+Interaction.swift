//
//  NotchViewModel+Interaction.swift
//  Otto
//
//  What the window controller and the views ask the view model while the user works: the routes that exist,
//  the open height limit, the keyboard context for every key event (§4.4), the composer's placeholder, the model
//  switch notice, regenerate and the reading position. Also the one hook the feature files use to wire
//  themselves in at init.
//

import Foundation

extension NotchViewModel {
    // MARK: - Routes and height

    /// .chat, + .history when History is available, + .shelf when the Shelf is on.
    var availableRoutes: [NotchRoute] {
        var routes: [NotchRoute] = [.chat]
        if history.isAvailable { routes.append(.history) }
        if settings.shelf.enabled { routes.append(.shelf) }
        return routes
    }

    /// isTallMode && systemUIWait == nil ? tallOpenHeight : NotchMetrics.maxOpenHeight (tall mode stays sticky; it is
    /// only suspended while system UI needs the screen).
    var openHeightLimit: CGFloat {
        isTallMode && systemUIWait == nil ? tallOpenHeight : NotchMetrics.maxOpenHeight
    }

    var isEditing: Bool { editingTurn != nil }

    // MARK: - Keyboard (§4.4)

    /// Snapshot for one key event. Prompts and the insert confirmation count only on Chat, where they are rendered.
    func keyContext(hasMarkedText: Bool, composerIsFirstResponder: Bool,
                    clipboardWantsAttachmentPaste: Bool) -> NotchKeyContext {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let onChat = route == .chat
        var context = NotchKeyContext()
        context.route = route
        context.isEngaged = isEngaged
        context.hasMarkedText = hasMarkedText
        context.composerIsFirstResponder = composerIsFirstResponder
        context.composerIsEmpty = trimmed.isEmpty && attachments.isEmpty
        context.composerHasText = !trimmed.isEmpty
        context.clipboardWantsAttachmentPaste = clipboardWantsAttachmentPaste
        context.hasUserMessage = chat.lastUserMessage != nil
        context.isStreaming = chat.isStreaming
        context.isEditing = isEditing
        context.overlay = overlay
        switch currentPrompt {
        case .approval? where onChat: context.prompt = .approval
        case .permission? where onChat, .card? where onChat: context.prompt = .other
        default: context.prompt = .none
        }
        context.promptPrimaryRequiresCommand = onChat && (permissionCardContent?.primaryRequiresCommand ?? false)
        context.hasInsertConfirmation = onChat && hasInsertConfirmation
        context.canInsertLastAnswer = lastAnswerIsInsertable
        context.historySearchIsEmpty = recents.query.isEmpty
        context.hasPendingHistoryDeletion = history.pendingDeletion != nil
        context.isListening = voice.isListening
        context.isSpeaking = voice.isSpeaking
        context.hasNowPlaying = settings.glance.nowPlayingEnabled && nowPlaying.item != nil
        context.hasMeetingChip = settings.glance.calendarChipEnabled && calendar.next != nil
        context.isHistoryAvailable = availableRoutes.contains(.history)
        context.isShelfEnabled = settings.shelf.enabled
        return context
    }

    /// The insert control is asking the user to confirm a multi-line paste or a changed selection.
    var hasInsertConfirmation: Bool {
        switch inserter.activity {
        case .confirmMultiline?, .selectionChanged?: return true
        case .inserting?, nil: return false
        }
    }

    /// The last reply is complete and the app its question came from is still running.
    var lastAnswerIsInsertable: Bool {
        guard let last = chat.messages.last, last.role == .assistant, last.state == .complete,
              !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return inserter.target(forAssistant: last.id, in: chat.messages) != nil
    }

    // MARK: - Composer

    /// Listening → "Listening…"; approval pending → "Waiting for your OK…"; a selection chip over an empty composer →
    /// "Ask about your selection…"; else "Ask Otto anything…".
    var composerPlaceholder: String {
        if voice.isListening { return "Listening…" }
        if chat.pendingApproval != nil { return "Waiting for your OK…" }
        let hasSelection = attachments.contains { $0.sourceURL?.scheme == SelectionSnapshot.sourceScheme }
        if hasSelection, composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Ask about your selection…"
        }
        return "Ask Otto anything…"
    }

    // MARK: - Regenerate and model

    /// ⌘R: answers the last question again (the current reply is kept as a version).
    func regenerate() {
        voice.stopSpeaking()
        guard chat.regenerate() == .started else { return }
        history.noteActivity()
    }

    /// Switches the model for the next message and says so; a reply that is streaming keeps its model. Otto never
    /// changes the model on its own.
    func selectModel(_ model: ModelOption) {
        let wasStreaming = chat.isStreaming
        settings.model = model
        var text = wasStreaming ? "\(model.shortName) from your next message" : "Switched to \(model.shortName)"
        if AttachmentBudget.problem(with: attachments, model: model) != nil {
            text += " · a PDF here is too long for \(model.shortName)"
        }
        showNotice(text, symbol: "sparkles")
    }

    // MARK: - Reading position (§6.6)

    /// ConversationView reports where the user is reading; History keeps it with the conversation.
    func noteReadingPosition(_ position: ReadingPosition) {
        history.noteReadingPosition(position)
    }

    /// After a conversation was opened or continued: land where the user left off (or at the bottom).
    func applyReadingRestore(saved: ReadingPosition?) {
        let target = ReadingRestore.target(unreadReplyID: nil, saved: saved, messages: chat.messages)
        if case .messageTop(let messageID) = target {
            setReadingAnchor(messageID)
        }
    }
}

// MARK: - Feature wiring

extension NotchViewModel {
    /// The one init-time hook for the feature files: `init` calls `installFeatures()` last. A feature file wires its
    /// callbacks by declaring `func installFeatures()` on NotchViewModel, which then replaces the empty default below.
    @MainActor protocol FeatureInstalling {
        func installFeatures()
    }
}

extension NotchViewModel.FeatureInstalling {
    func installFeatures() {}
}

extension NotchViewModel: NotchViewModel.FeatureInstalling {}
