//
//  NotchViewModel+Prompts.swift
//  Otto
//
//  The dock: which prompt shows (approval > permission > card), the explain-first permission flow (§4.6), tool
//  approvals with visibility-based arming and hardware-confirmed input (§4.5, §5.4), card actions and the history
//  notice, and what the notch is waiting on while it folds for system UI.
//

import AppKit
import Foundation

extension NotchViewModel {
    // MARK: - Dock prompts (§4.3)

    /// The one prompt the dock shows: the tool loop's approval, else a feature's permission flow, else the first
    /// card that may show now.
    var currentPrompt: NotchPrompt? {
        if let approval = chat.pendingApproval { return .approval(approval) }
        if let permissionPrompt { return .permission(permissionPrompt) }
        if let card { return .card(card) }
        return nil
    }

    var needsAttention: Bool { chat.pendingApproval != nil }

    /// Head of the card queue among the cards that may show now: the history notice only over an empty
    /// conversation once History has read its index; the neighbor card from the open after it was queued.
    var card: NotchCard? {
        cardQueue.first(where: isCardVisible)?.card
    }

    func isCardVisible(_ queued: QueuedCard) -> Bool {
        switch queued.card.kind {
        case .historyNotice:
            return chat.messages.isEmpty && history.isIndexLoaded
        case .notchNeighbor:
            return queued.queuedAtOpen < openSerial
        case .voiceConsent, .voiceUnavailable, .onDeviceSpeechUnavailable:
            return true
        }
    }

    /// Approvals, permission prompts that still need an answer and cards marked `requiresDecision` hold the notch
    /// open against hover-exit (`StayOpenHold.promptDecision`).
    var promptRequiresDecision: Bool {
        switch currentPrompt {
        case .approval?: return true
        case .permission(let prompt)?: return prompt.phase != .granted
        case .card(let card)?: return card.requiresDecision
        case nil: return false
        }
    }

    /// What the permission card in the dock says: a feature's flow, or a tool approval that needs macOS access.
    var permissionCardContent: PermissionCardContent? {
        switch currentPrompt {
        case .permission(let prompt)?:
            return PermissionCardContent.make(permission: prompt.permission, purpose: prompt.purpose,
                                              phase: prompt.phase, status: permissions.status(prompt.permission))
        case .approval(let approval)?:
            return toolPermissionCardContent(for: approval)
        case .card?, nil:
            return nil
        }
    }

    /// The card of an approval of kind `.permission` (nil for other approvals).
    func toolPermissionCardContent(for approval: PendingApproval) -> PermissionCardContent? {
        guard case .permission(let missing, _) = approval.kind,
              let permission = missing.first(where: { permissions.status($0) != .granted }) ?? missing.first
        else { return nil }
        let phase = toolPermission.flatMap { $0.callID == approval.callID ? $0.phase : nil } ?? .explain
        let purpose = PermissionPurpose.tool(title: approval.presentation.title,
                                             dataFlow: Self.dataFlowSentence(in: approval.body))
        return PermissionCardContent.make(permission: permission, purpose: purpose, phase: phase,
                                          status: permissions.status(permission))
    }

    // MARK: - Cards

    /// Performs `action` on the visible card. A card leaves the queue only through one of its actions.
    func performCardAction(_ action: NotchCard.Action) {
        guard let card else { return }
        if let waiter = removeCard(kind: card.kind) {
            waiter.resume(returning: action)
            return
        }
        performDefaultCardAction(action, on: card)
    }

    private func performDefaultCardAction(_ action: NotchCard.Action, on card: NotchCard) {
        switch action {
        case .enableVoice:
            settings.voice.enabled = true
        case .useServerSpeech:
            settings.voice.allowServerRecognition = true
        case .openSystemSettings(let permission):
            openSystemSettingsFromNotch(for: permission)
        case .openSettings(let tab):
            openSettings(tab: tab)
        case .useClickToOpen:
            settings.notch.hoverToOpen = false
            if case .notchNeighbor(let name) = card.kind { acknowledgeNeighbor(name) }
            showNotice(clickToOpenNotice, symbol: "cursorarrow.click")
        case .keepHover(let neighbor):
            acknowledgeNeighbor(neighbor)
        case .acknowledgeHistory:
            settings.history.noticeAcknowledged = true
        case .declineHistory:
            settings.history.noticeAcknowledged = true
            let history = self.history
            Task { await history.setEnabled(false) }
            transientError = "History is off. Nothing is saved."
        case .openDictationSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                openExternalURL(url)
            }
        case .dismiss:
            break
        }
    }

    private func acknowledgeNeighbor(_ name: String) {
        guard !settings.notch.acknowledgedNeighbors.contains(name) else { return }
        settings.notch.acknowledgedNeighbors.append(name)
    }

    /// Built from the live shortcut, never a hard-coded combo.
    private var clickToOpenNotice: String {
        guard settings.hotKeyEnabled else { return "Otto now opens when you click the notch." }
        return "Otto now opens on click or \(settings.shortcuts.hotKey.displayString)"
    }

    /// First-run notice for History (history.md §1.3), with the retention the user has now.
    static func historyNoticeCard(retention: HistoryRetention) -> NotchCard {
        let kept = retention == .forever
            ? "They stay until you delete them, and you can change this in Settings."
            : "They're deleted after \(retention.shortLabel), and you can change this in Settings."
        return NotchCard(
            kind: .historyNotice,
            symbol: "clock.arrow.circlepath",
            title: "Otto now remembers your chats",
            message: "Conversations are saved on this Mac only, so you can pick them up with ⌘Y. " + kept,
            footnote: nil,
            primary: NotchCard.ActionButton(title: "Got It", action: .acknowledgeHistory),
            secondary: NotchCard.ActionButton(title: "Don't Save History", action: .declineHistory),
            escapeAction: .acknowledgeHistory,
            requiresDecision: false
        )
    }

    // MARK: - Feature permission flow (§4.6)

    /// Explain-first flow in the dock. Opens the notch focused if closed. Returns true when granted; the caller then
    /// runs the pending action once. `lastPermissionDeclineAction` says how a flow ended without a grant.
    func requestPermission(_ permission: Permission, for purpose: PermissionPurpose) async -> Bool {
        await permissions.refresh([permission])
        if permissions.status(permission) == .granted { return true }
        if !isOpen {
            open(reason: .programmatic, focus: true)
        }
        let prompt = PermissionPrompt(id: UUID(), permission: permission, purpose: purpose, phase: .explain)
        return await withCheckedContinuation { continuation in
            beginPermissionPrompt(prompt, continuation: continuation)
        }
    }

    /// The permission card's buttons. For a tool approval that needs access, only the decline and relaunch buttons
    /// act here; its primary goes through `resolveApproval(_:input:)`, which checks the input.
    func permissionPromptAction(_ action: PermissionCardAction) {
        if case .approval(let approval)? = currentPrompt {
            switch action {
            case .dismiss, .justCopy:
                resolveApproval(.deny, input: .programmatic)
            case .relaunch:
                permissions.relaunch()
            case .request, .openSystemSettings:
                Self.logger.notice("Ignored a permission action for approval \(approval.callID, privacy: .public) without input evidence")
            }
            return
        }
        guard let prompt = permissionPrompt else { return }
        switch action {
        case .request:
            runPermissionStep { [weak self] in await self?.requestStep(prompt) }
        case .openSystemSettings:
            runPermissionStep { [weak self] in await self?.settingsStep(prompt) }
        case .relaunch:
            permissions.relaunch()
        case .justCopy, .dismiss:
            finishPermissionFlow(granted: false, declinedWith: action)
        }
    }

    /// Asks macOS for `permission` from a notch flow that shows no PermissionPrompt (the voice consent's requests).
    /// The notch folds while the dialog, or System Settings after it, is up.
    @discardableResult func requestFromNotch(_ permission: Permission) async -> PermissionStatus {
        let permissions = self.permissions
        return await trackNotchPermissionRequest(permission) {
            await permissions.request(permission)
        }
    }

    private func isCurrent(_ prompt: PermissionPrompt) -> Bool {
        permissionPrompt?.id == prompt.id
    }

    private func requestStep(_ prompt: PermissionPrompt) async {
        let status = await permissions.request(prompt.permission)
        guard isCurrent(prompt) else { return }
        if status == .granted {
            await grantedStep(prompt)
        } else if let awaiting = permissions.awaiting, Self.permission(of: awaiting) == prompt.permission {
            // The Accessibility / Screen Recording alert outlives the request, or macOS could only offer Settings.
            await waitStep(prompt)
        } else {
            // Denied: the card now offers Open System Settings.
            setPermissionPhase(.explain, for: prompt.id)
        }
    }

    private func settingsStep(_ prompt: PermissionPrompt) async {
        permissions.openSystemSettings(for: prompt.permission)
        await waitStep(prompt)
    }

    private func waitStep(_ prompt: PermissionPrompt) async {
        setPermissionPhase(.waiting, for: prompt.id)
        let granted = await permissions.waitForGrant(prompt.permission, timeout: permissionWaitTimeout)
        guard !Task.isCancelled, isCurrent(prompt) else { return }
        if granted {
            await grantedStep(prompt)
        } else {
            let relaunch = permissions.status(prompt.permission) == .needsRelaunch
            setPermissionPhase(relaunch ? .needsRelaunch : .explain, for: prompt.id)
        }
    }

    /// "You're all set" for `grantedCardLifetime`, then the flow resumes its caller once.
    private func grantedStep(_ prompt: PermissionPrompt) async {
        setPermissionPhase(.granted, for: prompt.id)
        try? await Task.sleep(for: grantedCardLifetime)
        guard isCurrent(prompt) else { return }
        finishPermissionFlow(granted: true)
    }

    // MARK: - Approvals (§4.5, §5.4)

    /// `.run` reaches the executor with hardwareConfirmed = InputProvenance.mayApprove(input, armedAtUptime:
    /// visibility.sinceUptime + armingDelay) and visibleSince = approvalVisibility?.since; decline paths need neither.
    /// An approval that needs macOS access first runs the permission steps, then answers `.run` for the same press.
    func resolveApproval(_ decision: ApprovalDecision, input: InputEvidence) {
        guard let approval = chat.pendingApproval else { return }
        let visibility = approvalVisibility.flatMap { $0.callID == approval.callID ? $0 : nil }
        guard case .run(let options) = decision else {
            endToolPermissionFlow(callID: approval.callID)
            chat.resolveApproval(decision, hardwareConfirmed: input.isHardware && !input.isRepeat,
                                 visibleSince: visibility?.since)
            return
        }
        let armedAt = visibility.map { $0.sinceUptime + approval.armingDelay.timeInterval }
        let mayApprove = InputProvenance.mayApprove(input, armedAtUptime: armedAt)

        if case .permission(let missing, _) = approval.kind {
            guard mayApprove, let visibility else {
                Self.logger.notice("blocked_synthetic_input on the permission card for \(approval.callID, privacy: .public)")
                return
            }
            continueToolPermissionFlow(callID: approval.callID, missing: missing, options: options,
                                       visibleSince: visibility.since)
            return
        }
        if approval.body.requiresSelection, options.calendarIdentifier == nil { return }
        chat.resolveApproval(.run(options), hardwareConfirmed: mayApprove, visibleSince: visibility?.since)
    }

    /// Return / ⌘↩ on the dock (the key mapper already refused bare Return for approvals and for "Quit & Reopen").
    func performPromptPrimary(input: InputEvidence) {
        switch currentPrompt {
        case .approval?:
            resolveApproval(.run(approvalOptions), input: input)
        case .permission?:
            if let action = permissionCardContent?.primaryAction {
                permissionPromptAction(action)
            }
        case .card(let card)?:
            performCardAction(card.primary.action)
        case nil:
            break
        }
    }

    /// Esc on the dock: approval → deny, permission → its secondary, card → its escape action (the safe choice).
    func performPromptSecondary() {
        switch currentPrompt {
        case .approval?:
            resolveApproval(.deny, input: .programmatic)
        case .permission?:
            if let action = permissionCardContent?.secondaryAction {
                permissionPromptAction(action)
            }
        case .card(let card)?:
            performCardAction(card.escapeAction)
        case nil:
            break
        }
    }

    /// Asks macOS for each missing permission in order (the notch folds while its UI is up), then answers `.run` so
    /// the executor re-checks access. A refusal leaves the card on its explain step (now "Open System Settings").
    private func continueToolPermissionFlow(callID: String, missing: [Permission], options: ApprovalOptions,
                                            visibleSince: Date) {
        runToolPermissionStep { [weak self] in
            guard let self else { return }
            for permission in missing {
                let granted = await self.obtainForTool(permission, callID: callID)
                guard !Task.isCancelled, self.chat.pendingApproval?.callID == callID else { return }
                guard granted else { return }
            }
            self.setToolPermissionPhase(nil, callID: callID)
            self.chat.resolveApproval(.run(options), hardwareConfirmed: true, visibleSince: visibleSince)
        }
    }

    private func obtainForTool(_ permission: Permission, callID: String) async -> Bool {
        await permissions.refresh([permission])
        switch permissions.status(permission) {
        case .granted, .unavailable:
            return true
        case .restricted:
            return false
        case .needsRelaunch:
            permissions.relaunch()
            return false
        case .notDetermined, .limited:
            let status = await permissions.request(permission)
            guard chat.pendingApproval?.callID == callID else { return false }
            if status == .granted { return true }
            if let awaiting = permissions.awaiting, Self.permission(of: awaiting) == permission {
                return await waitForTool(permission, callID: callID)
            }
            setToolPermissionPhase(.explain, callID: callID)
            return false
        case .denied:
            permissions.openSystemSettings(for: permission)
            return await waitForTool(permission, callID: callID)
        }
    }

    private func waitForTool(_ permission: Permission, callID: String) async -> Bool {
        setToolPermissionPhase(.waiting, callID: callID)
        let granted = await permissions.waitForGrant(permission, timeout: permissionWaitTimeout)
        guard chat.pendingApproval?.callID == callID else { return false }
        if granted { return true }
        let relaunch = permissions.status(permission) == .needsRelaunch
        setToolPermissionPhase(relaunch ? .needsRelaunch : .explain, callID: callID)
        return false
    }

    /// "Event details are sent to Claude to answer.": the consent body's closing sentence, when the call is a read.
    static func dataFlowSentence(in body: ApprovalBody) -> String? {
        guard case .consent(let preview) = body else { return nil }
        let text = preview.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: ". ", options: .backwards) else { return nil }
        let sentence = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return sentence.isEmpty ? nil : sentence
    }

    // MARK: - System UI wait (§4.5)

    /// (a) permissions.awaiting, only for a flow started in the notch; (b) chat.systemUIToolWait; (c) an Automation
    /// prompt Otto triggered itself. A switch flipped in the Settings window never folds the notch.
    var derivedSystemUIWait: SystemUIWait? {
        if let awaiting = permissions.awaiting, isNotchPermissionFlow(for: Self.permission(of: awaiting)) {
            switch awaiting {
            case .systemPrompt(let permission): return .systemPrompt(permission)
            case .systemSettings(let permission): return .systemSettings(permission)
            }
        }
        if let toolWait = chat.systemUIToolWait { return toolWait }
        if let automation = automationPromptInFlight { return .systemPrompt(automation) }
        return nil
    }

    private func isNotchPermissionFlow(for permission: Permission) -> Bool {
        if permissionPrompt?.permission == permission { return true }
        if case .permission(let missing, _)? = chat.pendingApproval?.kind, missing.contains(permission) { return true }
        return notchPermissionRequests.contains(permission)
    }
}
