//
//  LicenseCopy.swift
//  Otto
//
//  Every string the paid build shows about licenses (§14.10.1 and §14.10.2), in one table shared by the license
//  engine, the composer gate line and Settings → License. The wording is exact; LicenseCopyTests pins it.
//

#if OTTO_LICENSING
import Foundation

enum LicenseCopy {
    // MARK: - Status

    static func statusTitle(_ status: LicenseStatus) -> String {
        statusTitle(status, removal: nil)
    }

    /// The title with the removal taken into account: a trial that ended because a license left this Mac reads
    /// "No license on this Mac" rather than "Your trial has ended".
    static func statusTitle(_ status: LicenseStatus, removal: LicenseRemoval?) -> String {
        switch status {
        case .trial(_, let daysLeft):
            return daysLeft == 1 ? "Free trial: 1 day left" : "Free trial: \(daysLeft) days left"
        case .trialEnded:
            return removal == nil ? "Your trial has ended" : "No license on this Mac"
        case .licensed, .licensedCheckOverdue:
            return "Licensed"
        case .licensedCheckRequired:
            return "License check needed"
        case .unavailable:
            return "License status unknown"
        }
    }

    static func statusDetail(_ status: LicenseStatus, removal: LicenseRemoval?, configuration: LicenseConfiguration,
                             now: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let date = { (value: Date) in shortDate(value, locale: locale, calendar: calendar) }
        switch status {
        case .trial(let endsAt, _):
            return "Every feature works until \(date(endsAt)). After that, sending a message needs a license."
        case .trialEnded:
            if let removal { return removalLine(removal) }
            return "Settings, Recents and demo mode still work. Sending a message needs a license."
        case .licensed(let summary):
            let checked = relativeDay(summary.lastValidatedAt, now: now, locale: locale, calendar: calendar)
            switch summary.backend {
            case .polar: return "Key \(summary.displayKey) on \(summary.label), checked \(checked)."
            case .gumroad: return "Gumroad key \(summary.displayKey), checked \(checked)."
            }
        case .licensedCheckOverdue(let summary, let sendingPausesAt):
            return "Otto hasn't reached \(summary.backend.displayName) since \(date(summary.lastValidatedAt)). "
                + "It keeps sending until \(date(sendingPausesAt)); connect to the internet and it checks on its own."
        case .licensedCheckRequired(let summary):
            return "Otto last reached \(summary.backend.displayName) on \(date(summary.lastValidatedAt)). "
                + "Connect to the internet and click Check Now."
        case .unavailable(.keychain(let status)):
            return "Otto couldn't read its license from the Keychain (error \(status)). It works normally until it can."
        case .unavailable(.undecodable):
            return "A newer version of Otto saved this Mac's license or trial record. "
                + "Otto works normally; update Otto to manage it."
        }
    }

    static func pendingRevocationLine(_ pending: PendingRevocation, backend: LicenseBackendKind,
                                      locale: Locale = .current) -> String {
        let date = shortDate(pending.firstSeenAt, locale: locale, calendar: .current)
        switch backend {
        case .polar:
            return "Polar reported a problem with this license on \(date). If you rotated your key, enter the new one. "
                + "Otherwise Otto checks again tomorrow before it turns the license off."
        case .gumroad:
            return "Gumroad reported a problem with this license on \(date). "
                + "Otto checks again tomorrow before it turns the license off."
        }
    }

    static func removalLine(_ removal: LicenseRemoval) -> String {
        switch removal.reason {
        case .revoked:
            return "Polar no longer accepts the license that was on this Mac. It may have been refunded or turned off, "
                + "or this Mac was removed in the Polar portal. If you rotated your key, enter the new one."
        case .refunded: return "Gumroad reports this purchase as refunded."
        case .chargedBack: return "The payment for this license was disputed."
        case .disabled: return "Gumroad turned this key off."
        case .wrongProduct: return "That key belongs to a different product."
        case .deactivatedByUser: return "You deactivated Otto on this Mac."
        case .removedByUser: return "You removed the license from this Mac."
        }
    }

    // MARK: - Messages

    /// `backend` is the store that answered (nil when no request was made: malformed key, backend disabled).
    static func activationFailure(_ error: LicenseActivationError, backend: LicenseBackendKind?,
                                  supportEmail: String) -> LicenseMessage {
        switch error {
        case .malformedKey:
            return problem("That doesn't look like an Otto license key. Paste the whole key from your receipt email.")
        case .keyNotFound:
            return problem("Otto couldn't find that key. Check it against your receipt email or your Polar purchases page.")
        case .keyNotActive:
            return problem("That key has been refunded or turned off.")
        case .wrongProduct:
            return problem("That key belongs to a different product.")
        case .seatLimitReached(let limit):
            let seats = limit ?? LicensePolicy.seatsPerLicense
            switch backend {
            case .gumroad:
                return problem("That key is already on \(seats) Macs. Email \(supportEmail) and I'll free a seat.")
            case .polar, nil:
                return problem("That key is already on \(seats) Macs. Deactivate Otto in Settings on one of them, "
                               + "or remove a Mac in the Polar portal.")
            }
        case .backendDisabled(.gumroad):
            return problem("That looks like a Gumroad key, but this version of Otto doesn't accept Gumroad keys yet. "
                           + "Email \(supportEmail).")
        case .backendDisabled(.polar):
            return checkFailure(.misconfigured("the Polar settings are missing"), backend: .polar)
        case .unavailable(let reason):
            return checkFailure(reason, backend: backend ?? .polar)
        }
    }

    static func deactivation(_ outcome: LicenseDeactivationOutcome, backend: LicenseBackendKind,
                             supportEmail: String) -> LicenseMessage {
        switch outcome {
        case .freedSeat, .alreadyGone:
            return LicenseMessage(tone: .success, text: "Deactivated. This Mac's seat is free.")
        case .localOnly:
            return removedLocally(backend, supportEmail: supportEmail)
        case .unavailable:
            return problem("Otto couldn't reach \(backend.displayName), so the seat is still in use. "
                           + "Try again, or remove the license from this Mac only.")
        }
    }

    static let activated = LicenseMessage(tone: .success, text: "Activated. Thanks for buying Otto.")

    static let rekeyed = LicenseMessage(tone: .success, text: "Updated to your new key. This Mac keeps its seat.")

    static func activatedUnsaved(status: OSStatus) -> LicenseMessage {
        LicenseMessage(tone: .info, text: "Activated, but Otto couldn't save the license to the Keychain "
                       + "(error \(status)). It applies until you quit Otto.")
    }

    static let checkedValid = LicenseMessage(tone: .success, text: "Checked just now. Your license is active.")

    static func checkFailure(_ reason: LicenseUnavailableReason, backend: LicenseBackendKind) -> LicenseMessage {
        let store = backend.displayName
        switch reason {
        case .offline, .timeout:
            return problem("Otto couldn't reach \(store). Check your connection and try again.")
        case .rateLimited:
            return problem("\(store) asked Otto to slow down. Try again in a minute.")
        case .server, .versionRefused, .unexpectedResponse:
            return problem("\(store) isn't answering right now. Nothing changed on this Mac. Try again later.")
        case .misconfigured(let detail):
            return problem("This build can't check licenses: \(detail).")
        case .recordMismatch:
            return problem("This version of Otto can't check this license. Nothing changed on this Mac.")
        }
    }

    static func removedLocally(_ backend: LicenseBackendKind, supportEmail: String) -> LicenseMessage {
        switch backend {
        case .polar:
            return LicenseMessage(tone: .info, text: "Removed from this Mac. "
                                  + "The seat stays in use until you remove it in the Polar portal.")
        case .gumroad:
            return LicenseMessage(tone: .info, text: "Removed from this Mac. "
                                  + "Gumroad still counts this Mac; email \(supportEmail) to free the seat.")
        }
    }

    // MARK: - Composer gate

    static func gate(status: LicenseStatus, removal: LicenseRemoval?, activity: LicenseActivity,
                     configuration: LicenseConfiguration) -> ComposerGate? {
        let enterLicense = { (isPrimary: Bool) in
            ComposerGate.Choice(title: "Enter License", action: .openSettings(.license, .licenseKey),
                                isPrimary: isPrimary)
        }
        let buyLicense = { (isPrimary: Bool) -> ComposerGate.Choice? in
            configuration.buyURL.map { ComposerGate.Choice(title: "Buy a License", action: .openURL($0),
                                                           isPrimary: isPrimary) }
        }

        switch status {
        case .trialEnded:
            if activity == .activating {
                return ComposerGate(id: "activating", symbol: "key", message: "Activating your license…", choices: [])
            }
            if removal != nil {
                return ComposerGate(id: "license-removed", symbol: "key", message: "This Mac no longer has a license.",
                                    choices: [enterLicense(true)] + [buyLicense(false)].compactMap { $0 })
            }
            return ComposerGate(id: "trial-ended", symbol: "hourglass", message: "Your 14-day trial has ended.",
                                choices: [buyLicense(true)].compactMap { $0 } + [enterLicense(false)])
        case .licensedCheckRequired:
            if activity == .checking {
                return ComposerGate(id: "checking", symbol: "arrow.triangle.2.circlepath",
                                    message: "Checking your license…", choices: [])
            }
            return ComposerGate(id: "check-required", symbol: "wifi.exclamationmark",
                                message: "Otto needs to check your license before it can send.",
                                choices: [ComposerGate.Choice(title: "Check Now", action: .gate("check-now"),
                                                              isPrimary: true),
                                          enterLicense(false)])
        case .trial, .licensed, .licensedCheckOverdue, .unavailable:
            return nil
        }
    }

    // MARK: - Private

    private static func problem(_ text: String) -> LicenseMessage {
        LicenseMessage(tone: .problem, text: text)
    }

    /// {date}: `.dateTime.month(.abbreviated).day()`, e.g. "Oct 11".
    private static func shortDate(_ date: Date, locale: Locale, calendar: Calendar) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        style = style.month(.abbreviated).day()
        return date.formatted(style)
    }

    /// {relative}: "today", "yesterday" or {date}.
    private static func relativeDay(_ date: Date, now: Date, locale: Locale, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        return shortDate(date, locale: locale, calendar: calendar)
    }
}
#endif
