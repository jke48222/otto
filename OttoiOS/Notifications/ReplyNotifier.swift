//
//  ReplyNotifier.swift
//  Otto
//
//  "Otto replied" when a reply finishes while Otto is in the background and no Live Activity is following it
//  (Live Activities off, or iOS declined one). Opt-in: Settings asks for permission when you turn it on. The
//  body is the reply's first line only when previews are allowed; iOS hides it on the Lock Screen by default.
//

import Foundation
import os
import UserNotifications

/// The parts of `UNUserNotificationCenter` the notifier uses, so tests never post.
@MainActor protocol ReplyNotificationCentering: AnyObject {
    func requestAuthorization() async -> Bool
    func authorizationAllowsAlerts() async -> Bool
    func post(identifier: String, title: String, body: String, messageID: UUID)
    func removeAll(identifiers: [String])
}

@MainActor final class ReplyNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let replyIdentifier = "otto.reply"
    static let replyTitle = "Otto replied"
    static let failedTitle = "Otto couldn't finish"
    static let genericBody = "Tap to open Otto."
    static let approvalTitle = "Otto needs your OK"
    static let approvalBody = "Open Otto to answer."
    nonisolated static let messageIDKey = "otto.messageID"

    /// A tapped notification: the reply it is about.
    var onOpenReply: ((UUID) -> Void)?

    private let center: ReplyNotificationCentering

    init(center: ReplyNotificationCentering) {
        self.center = center
        super.init()
    }

    /// Asks for permission (the first time only); false when notifications are off for Otto.
    func requestPermission() async -> Bool {
        await center.requestAuthorization()
    }

    func postReply(_ preview: ReplyPreview, includeText: Bool) {
        let title = preview.outcome == .failed ? Self.failedTitle : Self.replyTitle
        let body = includeText && !preview.text.isEmpty ? preview.text : Self.genericBody
        center.post(identifier: Self.replyIdentifier, title: title, body: body, messageID: preview.id)
    }

    /// An action waits for the user's OK.
    func postApprovalNeeded(_ approval: PendingApproval, includeText: Bool) {
        let detail = DisplayText.sanitized(approval.presentation.title, maxLength: 160)
        let body = includeText && !detail.isEmpty ? detail : Self.approvalBody
        center.post(identifier: Self.replyIdentifier, title: Self.approvalTitle, body: body,
                    messageID: approval.messageID)
    }

    func clearDelivered() {
        center.removeAll(identifiers: [Self.replyIdentifier])
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// While Otto is on screen the chat itself shows the reply.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let messageID = (userInfo[Self.messageIDKey] as? String).flatMap(UUID.init(uuidString:))
        completionHandler()
        guard let messageID else { return }
        Task { @MainActor [weak self] in
            self?.onOpenReply?(messageID)
        }
    }
}

/// The real notification center.
@MainActor final class SystemReplyNotificationCenter: ReplyNotificationCentering {
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Glance")

    nonisolated init() {}

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Self.logger.error("Notification permission request failed: \(LoggedError(error), privacy: .public)")
            return false
        }
    }

    func authorizationAllowsAlerts() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied, .notDetermined: return false
        @unknown default: return false
        }
    }

    func post(identifier: String, title: String, body: String, messageID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = "otto.replies"
        content.interruptionLevel = .active
        content.userInfo = [ReplyNotifier.messageIDKey: messageID.uuidString]
        content.targetContentIdentifier = messageID.uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                Self.logger.error("Reply notification not posted: \(LoggedError(error), privacy: .public)")
            }
        }
    }

    func removeAll(identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

/// Never posts (tests, snapshots).
@MainActor final class InertReplyNotificationCenter: ReplyNotificationCentering {
    private(set) var posted: [(identifier: String, title: String, body: String, messageID: UUID)] = []
    var allowsAlerts = true

    nonisolated init() {}

    func requestAuthorization() async -> Bool { allowsAlerts }
    func authorizationAllowsAlerts() async -> Bool { allowsAlerts }

    func post(identifier: String, title: String, body: String, messageID: UUID) {
        posted.append((identifier, title, body, messageID))
    }

    func removeAll(identifiers: [String]) {
        posted.removeAll { identifiers.contains($0.identifier) }
    }
}
