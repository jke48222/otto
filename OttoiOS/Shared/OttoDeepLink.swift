//
//  OttoDeepLink.swift
//  Otto
//
//  The otto:// links the widgets, the Live Activity and notifications open: ask (a fresh composer, keyboard
//  up), a new chat, or a reply to scroll to. Compiled into the app and the widget extension.
//

import Foundation

enum OttoDeepLink: Equatable, Sendable {
    /// Open Otto with the composer focused (the Ask widget and control).
    case ask
    /// Start a new chat, then focus the composer.
    case newChat
    /// Open the chat at this reply (the Live Activity and notifications).
    case reply(UUID)
    /// Just bring Otto forward.
    case open

    static let scheme = "otto"

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .ask:
            components.host = "ask"
        case .newChat:
            components.host = "new"
        case .reply(let id):
            components.host = "reply"
            components.path = "/" + id.uuidString
        case .open:
            components.host = "open"
        }
        // Every case builds a valid URL from fixed parts; the fallback only keeps this non-optional.
        return components.url ?? URL(fileURLWithPath: "/")
    }

    /// nil for any other scheme or an unknown link. Hosts and ids are case-insensitive.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host?.lowercased() else { return nil }
        switch host {
        case "ask":
            self = .ask
        case "new":
            self = .newChat
        case "open":
            self = .open
        case "reply":
            let component = url.pathComponents.first { $0 != "/" } ?? ""
            guard let id = UUID(uuidString: component) else { return nil }
            self = .reply(id)
        default:
            return nil
        }
    }
}
