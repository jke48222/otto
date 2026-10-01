//
//  OttoIntents.swift
//  Otto
//
//  Ways into Otto from outside the app: Siri, Shortcuts, Spotlight, the Action button and the Control Center
//  control. Each intent opens Otto and hands its request to `OttoIntentRouter`, which the app drains once its
//  chat is ready. Compiled into the app and the widget extension (a control's intent must exist in both); only
//  the app ever performs them.
//

import AppIntents
import Foundation

/// "Chat with Otto": opens a fresh composer, or sends `question` right away when the shortcut supplies one.
struct ChatWithOttoIntent: AppIntent {
    static let title: LocalizedStringResource = "Chat with Otto"
    static let description = IntentDescription("Opens Otto ready for your question, or asks it right away.")
    static let openAppWhenRun = true

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask?")
    var question: String?

    init() {}

    init(question: String?) {
        self.question = question
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let trimmed = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        OttoIntentRouter.shared.submit(.ask(question: trimmed.isEmpty ? nil : trimmed))
        return .result()
    }
}

/// "New Chat in Otto".
struct NewOttoChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New Chat in Otto"
    static let description = IntentDescription("Starts a new conversation with Otto.")
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        OttoIntentRouter.shared.submit(.newChat)
        return .result()
    }
}

/// Hands intent requests to the app. Requests that arrive before the app installed its handler (a cold launch)
/// wait and are delivered, in order, when it does.
@MainActor
final class OttoIntentRouter {
    enum Request: Equatable, Sendable {
        case ask(question: String?)
        case newChat
    }

    static let shared = OttoIntentRouter()

    private var pending: [Request] = []

    var handler: ((Request) -> Void)? {
        didSet { drain() }
    }

    init() {}

    func submit(_ request: Request) {
        pending.append(request)
        drain()
    }

    private func drain() {
        guard let handler else { return }
        let requests = pending
        pending.removeAll()
        requests.forEach(handler)
    }
}
