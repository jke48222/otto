//
//  PermissionCardContent.swift
//  Otto
//
//  The one copy table for permission cards in the dock: what the card says and which buttons it shows for
//  each reason Otto asks, each step of the flow and the permission's status. Shared by the card view and the
//  view model, so the words and the Return-key rules can't drift apart.
//

import Foundation

enum PermissionCardAction: Equatable, Sendable { case request, openSystemSettings, relaunch, justCopy, dismiss }

/// `body` is inline Markdown (bold only, e.g. "**Notes**"); names from outside Otto are sanitized and escaped.
/// Render it with `AttributedString(markdown:)`. An empty `secondaryTitle` means no secondary button (the
/// `.granted` phase, which dismisses itself).
struct PermissionCardContent: Equatable, Sendable {
    var symbol: String; var title: String; var body: String; var steps: String?   // "System Settings → Privacy & Security → Calendars"
    var primaryTitle: String?; var primaryAction: PermissionCardAction?
    var secondaryTitle: String; var secondaryAction: PermissionCardAction
    var showsSpinner: Bool

    /// The primary is destructive (`.relaunch` quits Otto): bare Return never performs it — ⌘↩ or a click only.
    var primaryRequiresCommand: Bool { primaryAction == .relaunch }

    /// `.granted` wins over everything; then status `.restricted` (managed, nothing to do but OK); then status
    /// `.needsRelaunch` shows the relaunch step whatever the phase; otherwise the phase decides.
    static func make(permission: Permission, purpose: PermissionPurpose,
                     phase: PermissionPrompt.Phase, status: PermissionStatus) -> PermissionCardContent {
        if phase == .granted {
            return PermissionCardContent(symbol: "checkmark.circle.fill", title: "You're all set", body: "", steps: nil,
                                         primaryTitle: nil, primaryAction: nil,
                                         secondaryTitle: "", secondaryAction: .dismiss, showsSpinner: false)
        }
        if status == .restricted {
            return PermissionCardContent(symbol: symbol(for: permission, purpose: purpose),
                                         title: explainTitle(permission: permission, purpose: purpose),
                                         body: "This permission is managed by your organization.", steps: nil,
                                         primaryTitle: nil, primaryAction: nil,
                                         secondaryTitle: "OK", secondaryAction: .dismiss, showsSpinner: false)
        }

        let effectivePhase: PermissionPrompt.Phase = status == .needsRelaunch ? .needsRelaunch : phase
        switch effectivePhase {
        case .needsRelaunch:
            return PermissionCardContent(symbol: symbol(for: permission, purpose: purpose), title: "One more step",
                                         body: relaunchBody(permission), steps: steps(permission),
                                         primaryTitle: "Quit & Reopen Otto", primaryAction: .relaunch,
                                         secondaryTitle: "Open System Settings", secondaryAction: .openSystemSettings,
                                         showsSpinner: false)
        case .waiting:
            return PermissionCardContent(symbol: symbol(for: permission, purpose: purpose),
                                         title: "Waiting for System Settings…",
                                         body: waitingBody(permission), steps: steps(permission),
                                         primaryTitle: "Open System Settings", primaryAction: .openSystemSettings,
                                         secondaryTitle: "Cancel", secondaryAction: .dismiss, showsSpinner: true)
        case .explain, .granted:
            let opensSettings = status == .denied
            let secondary = secondaryButton(for: purpose)
            return PermissionCardContent(symbol: symbol(for: permission, purpose: purpose),
                                         title: explainTitle(permission: permission, purpose: purpose),
                                         body: explainBody(permission: permission, purpose: purpose),
                                         steps: steps(permission),
                                         primaryTitle: opensSettings ? "Open System Settings" : "Continue…",
                                         primaryAction: opensSettings ? .openSystemSettings : .request,
                                         secondaryTitle: secondary.title, secondaryAction: secondary.action,
                                         showsSpinner: false)
        }
    }

    // MARK: - Copy

    private static func explainTitle(permission: Permission, purpose: PermissionPurpose) -> String {
        switch purpose {
        case .paste: return "Let Otto paste for you"
        case .selection: return "Let Otto see your selection"
        case .windowCapture(let appName): return "Let Otto see \(plainName(appName))'s window"
        case .voice: return "Otto can't hear you yet"
        case .nowPlayingControl(let appName): return "Let Otto control \(plainName(appName))"
        case .notifications: return "Let Otto notify you"
        case .calendarGlance: return "Show your next meeting"
        case .tool: return "Otto needs \(permission.displayName) access"
        }
    }

    private static func explainBody(permission: Permission, purpose: PermissionPurpose) -> String {
        switch purpose {
        case .paste(let appName):
            return "To put answers straight into \(boldName(appName)), allow Otto under Accessibility. Otto only uses "
                + "it when you ask: to press ⌘V for you and to read text you've selected. Never in the background."
        case .selection(let appName):
            return "To offer the text you've highlighted in \(boldName(appName)), allow Otto under Accessibility. "
                + "Otto reads it only when you open the notch, never sends it until you do, and always skips "
                + "password fields."
        case .windowCapture:
            return "To attach a picture of a window, allow Otto under Screen & System Audio Recording. Otto captures "
                + "a window only when you tap it, and the picture goes nowhere until you send."
        case .voice:
            return "Allow Microphone and Speech Recognition for Otto. Otto listens only while you hold the shortcut "
                + "or the mic, and turns your words into text on this Mac."
        case .nowPlayingControl:
            return "Otto sends play, pause and skip only when you press these buttons. macOS will ask you next."
        case .notifications:
            return "Otto posts a notification only when a reply finishes (or needs your OK) while you can't see "
                + "the notch."
        case .calendarGlance:
            return "Otto reads your calendars to show your next meeting in the notch. Nothing is sent to Claude."
        case .tool(let title, let dataFlow):
            let action = escaped(lowercasedFirst(DisplayText.sanitized(title, maxLength: 120)))
            var body = "To \(action), allow Otto under \(permission.settingsPaneName)."
            if let dataFlow {
                let sentence = escaped(DisplayText.sanitized(dataFlow, maxLength: 200))
                if !sentence.isEmpty { body += " " + sentence }
            }
            return body
        }
    }

    private static func waitingBody(_ permission: Permission) -> String {
        if permission == .notifications {
            return "Allow notifications for **Otto** in System Settings → Notifications. "
                + "Otto will pick up where you left off."
        }
        return "Turn on **Otto** in Privacy & Security → \(permission.settingsPaneName). "
            + "Otto will pick up where you left off."
    }

    private static func relaunchBody(_ permission: Permission) -> String {
        let effect = permission == .screenRecording ? "before it can see windows" : "before the change takes effect"
        return "If you just turned Otto on, macOS needs Otto to reopen \(effect). "
            + "Your conversation is saved if History is on."
    }

    /// Notifications live in their own pane, not under Privacy & Security.
    private static func steps(_ permission: Permission) -> String {
        if permission == .notifications { return "System Settings → Notifications" }
        return "System Settings → Privacy & Security → \(permission.settingsPaneName)"
    }

    private static func secondaryButton(for purpose: PermissionPurpose) -> (title: String, action: PermissionCardAction) {
        if case .paste = purpose { return ("Just Copy", .justCopy) }
        return ("Not Now", .dismiss)
    }

    private static func symbol(for permission: Permission, purpose: PermissionPurpose) -> String {
        switch purpose {
        case .tool: return "lock.shield"
        case .nowPlayingControl: return "playpause"
        case .paste, .selection, .windowCapture, .voice, .notifications, .calendarGlance: break
        }
        switch permission {
        case .accessibility: return "hand.point.up.left"
        case .screenRecording: return "macwindow"
        case .microphone: return "mic"
        case .speechRecognition: return "waveform"
        case .calendars: return "calendar"
        case .reminders: return "checklist"
        case .notifications: return "bell"
        case .automation: return "applescript"
        }
    }

    // MARK: - Text helpers

    private static let nameLimit = 60

    private static func plainName(_ name: String) -> String {
        DisplayText.sanitized(name, maxLength: nameLimit)
    }

    private static func boldName(_ name: String) -> String {
        "**" + escaped(plainName(name)) + "**"
    }

    /// Backslash-escapes the ASCII punctuation Markdown could read as formatting.
    private static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            if "\\`*_[]<>~#|!".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// "Add “Dentist” to Calendar" → "add “Dentist” to Calendar"; leaves acronyms ("URL…") and proper nouns
    /// written in capitals alone.
    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        let rest = text.dropFirst()
        if let second = rest.first, second.isUppercase { return text }
        return first.lowercased() + rest
    }
}
