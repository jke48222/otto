//
//  NotchViewModel+Glance.swift
//  Otto
//
//  What the closed notch shows (§4.2) and the glance row's actions (§6.13–§6.16): the resolver's inputs, the
//  closed shape, reply and approval notifications, media controls with their Automation step, the next-meeting
//  chip and the usage details.
//

import AppKit
import Foundation

extension NotchViewModel {
    // MARK: - Closed notch (§4.2)

    /// Everything the resolver weighs, first match wins: voice, the system-UI wait, an approval, the paste flash,
    /// the reply preview, the reply phase, speaking, unread, media.
    var glanceInputs: GlanceInputs {
        GlanceInputs(isListening: voice.isActive, systemWait: systemUIWait,
                     approvalTitle: chat.pendingApproval?.presentation.title, flash: inserter.closedFlash,
                     preview: glance.preview, phase: glance.displayedPhase, isSpeaking: voice.isSpeaking,
                     hasUnreadReply: hasUnreadReply, media: nowPlaying.closedNotchItem)
    }

    var closedGlance: ClosedGlance {
        GlanceResolver.resolve(glanceInputs)
    }

    /// Size and bottom radius of the closed shape (the UI draws it, the controller hit-tests it).
    var closedLayout: ClosedNotchLayout.Result {
        let glance = closedGlance
        return ClosedNotchLayout.make(notchSize: closedNotchSize, glance: glance, isHovering: isHovering,
                                      isListening: voice.isActive, dropText: glance.drop?.text)
    }

    // MARK: - Media (§6.15)

    /// ⌥⌘P / ⌥⌘] / ⌥⌘[ and the strip's buttons. The first control of a player explains Automation, lets macOS
    /// ask, and runs the command once more when allowed.
    func performMedia(_ command: MediaCommand) {
        let player = nowPlaying.item?.player
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.nowPlaying.perform(command, on: player, allowLaunch: false)
            await self.handleMediaOutcome(outcome, command: command, retried: false)
        }
    }

    private func handleMediaOutcome(_ outcome: MediaCommandOutcome, command: MediaCommand, retried: Bool) async {
        switch outcome {
        case .done, .denied:
            // A refusal shows as the strip's caption ("Otto isn't allowed to control Music.").
            return
        case .notRunning:
            showNotice(Self.nothingPlayingNotice, symbol: "info.circle")
        case .failed(let message):
            transientError = message
        case .needsConsent(let player):
            guard !retried else { return }
            let permission = Permission.automation(bundleID: player.rawValue, appName: player.displayName)
            guard await requestPermission(permission, for: .nowPlayingControl(appName: player.displayName)) else {
                return
            }
            let retry = await nowPlaying.perform(command, on: player, allowLaunch: false)
            await handleMediaOutcome(retry, command: command, retried: true)
        }
    }

    static let nothingPlayingNotice = "Nothing is playing right now."

    // MARK: - Calendar (§6.16)

    /// ⌥⌘J and the chip: joins the meeting's link, or opens Calendar when the event has none. The notch closes
    /// first so it never covers the call.
    func joinNextMeeting() {
        guard let next = calendar.next else { return }
        let destination: URL?
        if let link = next.event.meetingLink, link.scheme?.lowercased() == "https" {
            destination = link
        } else {
            destination = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.calendarBundleID)
        }
        guard let destination else { return }
        close(.programmatic)
        openExternalURL(destination)
    }

    private static let calendarBundleID = "com.apple.iCal"

    // MARK: - Usage (§6.14)

    /// ⌥⌘U and "Usage Details…": Settings → Models, scrolled to Usage.
    func openUsageDetails() {
        openSettings(tab: .models, anchor: .usage)
    }

    // MARK: - Wiring (§6.13)

    func installGlanceFeatures() {
        chat.onReplyFinished = { [weak self] in
            guard let self else { return }
            self.noteReplyFinished()
            if let messageID = self.chat.lastFinishedAssistantID {
                self.glance.replyDidFinish(messageID: messageID, notchIsOpen: self.isOpen)
            }
            self.voiceReplyDidFinish()
        }

        // The closed notch and a notification ask for the OK; the notification is withdrawn once it is answered
        // (or the approval goes away). The loop lives as long as the chat keeps this callback.
        let resolved = ObservationLoop(read: { [weak self] in self?.chat.pendingApproval?.callID }, onChange: {
            [weak self] callID in
            if callID == nil { self?.glance.approvalDidResolve() }
        })
        chat.onAttentionNeeded = { [weak self] approval in
            withExtendedLifetime(resolved) {
                guard let self else { return }
                self.glance.approvalDidAppear(title: approval.presentation.title, notchIsOpen: self.isOpen)
            }
        }

        // A tapped reply or approval notification opens the notch focused at that reply (or on the dock).
        notifications?.onOpen = { [weak self] messageID in
            self?.openToReply(messageID)
        }
    }
}
