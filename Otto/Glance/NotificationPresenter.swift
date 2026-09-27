//
//  NotificationPresenter.swift
//  Otto
//
//  The one place Otto posts macOS notifications: "Otto replied" when a reply lands while the notch is
//  out of sight, and "Otto needs your OK" when an action waits for approval. Also decides whether a
//  notification is warranted at all (ReplyNotificationDecider).
//

import Foundation
import os
import UserNotifications

/// Pure policy: whether a finished reply or a pending approval should post a notification (glance.md §1.4).
enum ReplyNotificationDecider {
    /// Under "When Otto's out of sight", a reply that took less than this doesn't notify: the person just
    /// asked and is probably still there. Approvals always count.
    static let minimumTurnDuration: TimeInterval = 5

    /// - `.off` → never.
    /// - Open and in sight → never (the notch itself is showing the reply).
    /// - `.always` ("Whenever the notch is closed") → whenever the notch is closed or out of sight.
    /// - `.whenOutOfSight` → only when the person can't see the notch, and the turn took at least
    ///   `minimumTurnDuration` (approvals skip the duration check).
    static func shouldNotify(policy: ReplyNotificationPolicy, notchIsOpen: Bool, attention: AttentionSnapshot,
                             turnDuration: TimeInterval, isApproval: Bool) -> Bool {
        let canSee = attention.canSeeNotch
        if policy == .off { return false }
        if notchIsOpen && canSee { return false }
        switch policy {
        case .off: return false
        case .always: return !notchIsOpen || !canSee
        case .whenOutOfSight: return !canSee && (isApproval || turnDuration >= minimumTurnDuration)
        }
    }

    /// Whether a notification may carry the reply's text or the action's name: the setting allows it
    /// and the screen is neither locked nor asleep (the lock screen never shows content).
    static func includesText(previewsEnabled: Bool, attention: AttentionSnapshot) -> Bool {
        previewsEnabled && !(attention.isScreenLocked || attention.areDisplaysAsleep)
    }
}

/// The parts of `UNUserNotificationCenter` the presenter uses (a seam so tests never post).
protocol GlanceNotificationCenter: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?)
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: GlanceNotificationCenter {}

@MainActor final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let replyIdentifier = "otto.reply"
    static let approvalIdentifier = "otto.approval"
    /// userInfo key of the message id (the only thing a notification carries besides its copy).
    nonisolated static let messageIDKey = "otto.messageID"
    /// Every Otto notification shares one thread in Notification Center.
    static let threadIdentifier = "otto.replies"

    static let replyTitle = "Otto replied"
    static let failedTitle = "Otto couldn't finish"
    static let approvalTitle = "Otto needs your OK"
    static let genericBody = "Tap to open Otto."

    /// Message id from userInfo (nil for approvals: open focused on the dock).
    var onOpen: ((UUID?) -> Void)?

    private let makeCenter: () -> GlanceNotificationCenter
    private var resolvedCenter: GlanceNotificationCenter?
    private var center: GlanceNotificationCenter {
        if let resolvedCenter { return resolvedCenter }
        let created = makeCenter()
        resolvedCenter = created
        return created
    }

    nonisolated private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Glance")

    /// The live center is created on first use, so constructing a presenter touches nothing.
    init(center makeCenter: @escaping () -> GlanceNotificationCenter = { UNUserNotificationCenter.current() }) {
        self.makeCenter = makeCenter
        super.init()
    }

    /// Becomes the center's delegate (taps route to `onOpen`). Live app only; never on tests/snapshots.
    func install() {
        center.delegate = self
    }

    /// includeText true → "Otto replied" (or "Otto couldn't finish" for a failed reply) with the preview's
    /// first line; false → title "Otto replied", body "Tap to open Otto." (no reply text, no outcome).
    /// userInfo and targetContentIdentifier carry only the message id.
    func postReply(_ preview: ReplyPreview, includeText: Bool) {
        let content = Self.baseContent()
        content.title = includeText && preview.outcome == .failed ? Self.failedTitle : Self.replyTitle
        content.body = includeText && !preview.text.isEmpty ? preview.text : Self.genericBody
        content.userInfo = [Self.messageIDKey: preview.id.uuidString]
        content.targetContentIdentifier = preview.id.uuidString
        post(UNNotificationRequest(identifier: Self.replyIdentifier, content: content, trigger: nil))
    }

    /// Title "Otto needs your OK"; body = the action title when includeText, else "Tap to open Otto.".
    /// No Run/Deny actions: approving always happens in the notch, where the full request is shown.
    func postApproval(title: String, includeText: Bool) {
        let content = Self.baseContent()
        content.title = Self.approvalTitle
        let actionTitle = DisplayText.sanitized(title, maxLength: 120)
        content.body = includeText && !actionTitle.isEmpty ? actionTitle : Self.genericBody
        post(UNNotificationRequest(identifier: Self.approvalIdentifier, content: content, trigger: nil))
    }

    /// Removes the approval notification (delivered and pending).
    func withdrawApproval() {
        remove([Self.approvalIdentifier])
    }

    /// Removes both the reply and the approval notification (delivered and pending).
    func clearDelivered() {
        remove([Self.replyIdentifier, Self.approvalIdentifier])
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Otto is always "frontmost" as an agent app; its own notch shows everything a banner would.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let isOpen = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let messageID = Self.messageID(from: response.notification.request.content.userInfo)
        completionHandler()
        guard isOpen else { return }
        Task { @MainActor [weak self] in
            self?.onOpen?(messageID)
        }
    }

    /// The message id a notification carries, if any.
    nonisolated static func messageID(from userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo[messageIDKey] as? String).flatMap(UUID.init(uuidString:))
    }

    // MARK: - Private

    /// No sound, the `.active` interruption level, and one thread for every Otto notification.
    private static func baseContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.threadIdentifier = threadIdentifier
        content.interruptionLevel = .active
        content.sound = nil
        return content
    }

    private func post(_ request: UNNotificationRequest) {
        let identifier = request.identifier
        center.add(request) { error in
            if let error {
                Self.logger.error("Notification \(identifier, privacy: .public) not posted: \((error as NSError).code, privacy: .public)")
            }
        }
    }

    private func remove(_ identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
