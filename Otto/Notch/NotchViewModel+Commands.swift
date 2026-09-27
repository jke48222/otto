//
//  NotchViewModel+Commands.swift
//  Otto
//
//  Keyboard dispatch (§4.4): performs every NotchKeyCommand the window controller maps from a key event, and
//  reports whether the event was consumed. Also the one init-time hook that wires the feature files into the
//  chat session and the subsystems.
//

import Foundation

extension NotchViewModel {
    // MARK: - Keyboard (§4.4)

    /// Performs `command`. Returns true when the event is consumed. Only a dock primary uses `input`: approvals
    /// reach the executor through `resolveApproval(_:input:)`, which checks it against the card's arming.
    @discardableResult func perform(_ command: NotchKeyCommand, input: InputEvidence) -> Bool {
        switch command {
        case .close:
            close(.user)
        case .newChat:
            newChat()
        case .openSettings:
            openSettings()
        case .pasteAsAttachment:
            pasteFromClipboard()
        case .stop:
            stopFromKeyboard()
        case .regenerate:
            regenerate()
        case .recallLastMessage:
            return recallLastMessage()
        case .cancelEditing:
            guard isEditing else { return false }
            cancelEditing()
        case .copyLastReply:
            copyLastResponse()
        case .toggleShortcutSheet:
            toggleShortcutSheet()
        case .dismissOverlay:
            guard overlay != nil else { return false }
            dismissOverlay()
        case .selectModel(let model):
            selectModel(model)
        case .togglePin:
            togglePin()
        case .enterTallMode:
            setTallMode(true)
        case .exitTallMode:
            setTallMode(false)
        case .cancelVoice:
            cancelVoice()
        case .finishVoice:
            finishVoice(send: true)
        case .stopSpeaking:
            stopSpeaking()
        case .promptPrimary:
            guard currentPrompt != nil else { return false }
            performPromptPrimary(input: input)
        case .promptSecondary:
            guard currentPrompt != nil else { return false }
            performPromptSecondary()
        case .releaseSoftFocus:
            handBackKeyboard()
        case .insertLastAnswer(let mode):
            guard canInsertLastAnswer else { return false }
            insertLastAnswer(mode: mode)
        case .confirmInsert:
            guard hasInsertConfirmation else { return false }
            confirmPendingInsert()
        case .cancelInsertConfirmation:
            guard hasInsertConfirmation else { return false }
            cancelPendingInsert()
        case .toggleHistory:
            toggleHistory()
        case .toggleShelf:
            guard availableRoutes.contains(.shelf) else { return false }
            toggle(route: .shelf)
        case .backToChat:
            navigate(to: .chat)
        case .historyMoveSelection(let delta):
            recents.moveSelection(by: delta)
        case .historyOpenSelected:
            guard recents.selectedRow != nil else { return false }
            openSelectedRecent()
        case .historyDeleteSelected:
            guard recents.selectedRow != nil else { return false }
            deleteSelectedRecent()
        case .historyUndoDelete:
            guard history.pendingDeletion != nil else { return false }
            undoRecentDeletion()
        case .historyFocusSearch:
            recents.focusSearch()
        case .shelfAskAboutSelection:
            askAboutShelfItems(shelf.targetIDs)
        case .shelfPaste:
            pasteToShelf()
        case .media(let mediaCommand):
            performMedia(mediaCommand)
        case .joinMeeting:
            guard calendar.next != nil else { return false }
            joinNextMeeting()
        case .showUsage:
            openUsageDetails()
        }
        return true
    }

    /// Convenience for tests/SelfTest: input = hardwareConfirmed ? .trusted() : .programmatic.
    @discardableResult func perform(_ command: NotchKeyCommand, hardwareConfirmed: Bool) -> Bool {
        perform(command, input: hardwareConfirmed ? .trusted() : .programmatic)
    }

    /// ⌘.: stops the reply, else cancels listening, else stops speech. Consumed either way.
    private func stopFromKeyboard() {
        if chat.isStreaming {
            stop()
        } else if voice.isActive {
            cancelVoice()
        } else {
            stopSpeaking()
        }
    }

    /// A consequential chord while the panel was only soft-focused: the keyboard goes back to the user's app and
    /// nothing else happens.
    private func handBackKeyboard() {
        if isSoftFocused {
            releaseSoftFocus()
        } else if !isEngaged {
            onRequestKey?(false)
        }
    }

    // MARK: - Feature wiring

    /// Called once by `init` (through `FeatureInstalling`) after every stored property is set.
    func installFeatures() {
        installVoiceFeatures()
        installGlanceFeatures()
        installShelfFeatures()
    }
}
