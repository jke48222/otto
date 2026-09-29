//
//  CalendarToolSupport.swift
//  Otto
//
//  What the four calendar and reminder tools share: the clock and locale they read, input field checks
//  (the local limits beyond the schema), matching a calendar or list by name, the compact sorted-key
//  JSON results capped at the tool-output limit, and the error copy for EventKit failures.
//

import Foundation
import os

/// The time, zone and locale the calendar tools use. The zone is read per call so it follows travel.
struct CalendarToolClock: Sendable {
    var now: @Sendable () -> Date
    var timeZone: @Sendable () -> TimeZone
    var locale: Locale

    static let live = CalendarToolClock(now: { Date() }, timeZone: { TimeZone.current }, locale: .autoupdatingCurrent)
}

/// Identifiers a create tool's Undo already removed in this process. Undo checks it before the title-and-date
/// fallback, so a second Undo of the same item (or of an item whose fallback match was removed) reports "already
/// removed" instead of searching again and deleting a lookalike the user made.
final class UndoneCalendarItems: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: Set<String> = []

    init() {}

    func contains(_ identifier: String) -> Bool {
        lock.withLock { identifiers.contains(identifier) }
    }

    func insert(_ identifiers: String...) {
        lock.withLock { self.identifiers.formUnion(identifiers) }
    }
}

enum CalendarToolSupport {
    static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Actions")

    /// Longest notes excerpt returned to Claude per event or reminder.
    static let notesExcerptLength = 300
    /// Attendee names returned per event; the rest are counted in "attendees_more".
    static let maximumAttendees = 10
    /// Items returned by a list call.
    static let maximumListItems = 200

    /// "Otto won't ask again. You can change this in Settings → Actions."
    static let consentFootnote = "Otto won't ask again. You can change this in Settings → Actions."

    // MARK: - Input fields

    /// The field's string trimmed of surrounding whitespace; nil when absent, not a string, or blank
    /// (blank counts as missing).
    static func text(_ input: JSONValue, _ key: String) -> String? {
        guard let raw = input[key]?.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func bool(_ input: JSONValue, _ key: String) -> Bool {
        input[key]?.boolValue ?? false
    }

    /// Checks one text field against its limit in Characters (after trimming). `singleLine` fields may not contain
    /// line breaks; no field may contain hidden or direction-changing characters, so the card shows exactly what
    /// is saved.
    static func checkText(_ input: JSONValue, _ key: String, required: Bool, maxLength: Int,
                          singleLine: Bool) -> ToolError? {
        if let value = input[key], value != .null, value.stringValue == nil {
            return invalid(key, "must be a string")
        }
        guard let text = text(input, key) else {
            return required ? invalid(key, "is required and can't be blank") : nil
        }
        if text.count > maxLength {
            return invalid(key, "must be at most \(maxLength) characters (it has \(text.count))")
        }
        if DisplayText.containsHiddenOrBidi(text) {
            return invalid(key, "contains hidden or direction-changing characters")
        }
        if singleLine, text.contains(where: \.isNewline) || text.contains("\t") {
            return invalid(key, "must be a single line")
        }
        return nil
    }

    /// `invalid_input` with the §5.6 copy: "$.path: problem. Fix the input and call the tool again."
    static func invalid(_ key: String, _ problem: String) -> ToolError {
        ToolError(code: .invalidInput, modelMessage: "$.\(key): \(problem). Fix the input and call the tool again.",
                  userMessage: "Invalid request")
    }

    // MARK: - Calendars and lists

    enum NameMatch: Equatable {
        case none
        case one(CalendarListInfo)
        case many([CalendarListInfo])
    }

    /// Case-insensitive match on the trimmed title.
    static func match(_ name: String, in calendars: [CalendarListInfo]) -> NameMatch {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = calendars.filter {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wanted) == .orderedSame
        }
        switch found.count {
        case 0: return .none
        case 1: return found.first.map(NameMatch.one) ?? .none
        default: return .many(found)
        }
    }

    /// "Work (iCloud)" when another calendar shares the title, else "Work".
    static func label(_ calendar: CalendarListInfo, among calendars: [CalendarListInfo]) -> String {
        let shared = calendars.filter { $0.title.caseInsensitiveCompare(calendar.title) == .orderedSame }.count > 1
        guard shared, !calendar.source.isEmpty else { return calendar.title }
        return "\(calendar.title) (\(calendar.source))"
    }

    /// "Home, Work (iCloud), Work (Google)".
    static func labels(_ calendars: [CalendarListInfo], among all: [CalendarListInfo]) -> String {
        calendars.map { label($0, among: all) }.joined(separator: ", ")
    }

    /// A picker entry. Titles come from outside Otto, so they are sanitized for display.
    static func choice(_ calendar: CalendarListInfo) -> CalendarChoice {
        CalendarChoice(id: calendar.id, title: DisplayText.sanitized(calendar.title, maxLength: 80),
                       source: DisplayText.sanitized(calendar.source, maxLength: 60), colorRGBA: calendar.colorRGBA)
    }

    /// What a create card's picker starts with.
    struct Selection: Equatable {
        /// Writable calendars or lists, in picker order.
        let writable: [CalendarListInfo]
        /// Preselected; nil leaves the picker unset (Confirm stays disabled until the user picks).
        let selectedID: String?
        /// Why the picker is unset.
        let hint: String?
    }

    /// Resolves the calendar (`noun` "calendar", `item` "event") or list ("list", "reminder") a create call names.
    /// A unique writable match is preselected; a missing, read-only or ambiguous name leaves the picker unset with a
    /// hint. Without a name the default calendar is used when it accepts new items.
    static func selection(named name: String?, in calendars: [CalendarListInfo], defaultID: String?,
                          noun: String, item: String) -> Selection {
        let writable = calendars.filter(\.isWritable)
        guard let name else {
            if let defaultID, writable.contains(where: { $0.id == defaultID }) {
                return Selection(writable: writable, selectedID: defaultID, hint: nil)
            }
            return Selection(writable: writable, selectedID: nil, hint: "Pick a \(noun) for this \(item).")
        }
        switch match(name, in: calendars) {
        case .one(let calendar) where calendar.isWritable:
            return Selection(writable: writable, selectedID: calendar.id, hint: nil)
        case .one:
            return Selection(writable: writable, selectedID: nil, hint: "“\(name)” is read-only. Pick another \(noun).")
        case .none:
            return Selection(writable: writable, selectedID: nil,
                             hint: "“\(name)” isn't one of your \(noun)s. Pick one.")
        case .many(let found):
            let writableMatches = found.filter(\.isWritable)
            if writableMatches.count == 1, let only = writableMatches.first {
                return Selection(writable: writable, selectedID: only.id, hint: nil)
            }
            return Selection(writable: writable, selectedID: nil,
                             hint: "More than one \(noun) is named “\(name)”. Pick one.")
        }
    }

    /// The calendar or list a create call saves to: the one picked on the card, else the preselected one.
    /// Returns the id and whether the user changed the preselection.
    static func chosenID(options: ApprovalOptions, selection: Selection, all: [CalendarListInfo],
                         noun: String, item: String) throws -> (id: String, changedByUser: Bool) {
        if let picked = options.calendarIdentifier {
            guard all.contains(where: { $0.id == picked }) else {
                throw ToolError(code: .notFound,
                                modelMessage: "The \(noun) the user picked no longer exists. Ask them which \(noun) to use.",
                                userMessage: "That \(noun) is gone")
            }
            return (picked, picked != selection.selectedID)
        }
        guard let selected = selection.selectedID else {
            throw ToolError(code: .notFound,
                            modelMessage: "No \(noun) was picked for the \(item). Ask the user which \(noun) to use.",
                            userMessage: "No \(noun) picked")
        }
        return (selected, false)
    }

    /// Filters the calendars of a read call to the one named, or every calendar when no name is given.
    /// Throws `not_found` / `ambiguous` listing the choices.
    static func readScope(named name: String?, in calendars: [CalendarListInfo], noun: String,
                          plural: String) throws -> [String]? {
        guard let name else { return nil }
        switch match(name, in: calendars) {
        case .one(let calendar):
            return [calendar.id]
        case .none:
            let names = calendars.isEmpty ? "none" : labels(calendars, among: calendars)
            throw ToolError(code: .notFound,
                            modelMessage: "There is no \(noun) named “\(name)”. The user's \(plural): \(names).",
                            userMessage: "No \(noun) named “\(DisplayText.sanitized(name, maxLength: 60))”")
        case .many(let found):
            throw ToolError(code: .ambiguous,
                            modelMessage: "More than one \(noun) is named “\(name)”: \(labels(found, among: calendars)). Ask the user which one they mean.",
                            userMessage: "More than one \(noun) named “\(DisplayText.sanitized(name, maxLength: 60))”")
        }
    }

    // MARK: - Results

    /// Compact JSON with sorted keys.
    static func json(_ object: [String: JSONValue]) -> String {
        JSONValue.object(object).encodedString()
    }

    /// Builds `{…, "<key>": [items], "count": n, "truncated": bool}`, dropping items from the end until the text fits
    /// `ToolOutput.maxTextCharacters`. `total` is how many items matched before the list limit.
    static func listResult(_ base: [String: JSONValue], key: String, items: [JSONValue], total: Int) -> String {
        var kept = items
        func render() -> String {
            var object = base
            object[key] = .array(kept)
            object["count"] = .int(Int64(kept.count))
            object["truncated"] = .bool(kept.count < total)
            return json(object)
        }
        var text = render()
        while text.count > ToolOutput.maxTextCharacters, !kept.isEmpty {
            let excess = Double(text.count - ToolOutput.maxTextCharacters) / Double(text.count)
            let drop = max(1, min(kept.count, Int((Double(kept.count) * excess).rounded(.up))))
            kept.removeLast(drop)
            text = render()
        }
        return text
    }

    /// Up to 300 characters of notes; line breaks kept, hidden characters removed.
    static func notesExcerpt(_ notes: String?) -> JSONValue? {
        guard let notes else { return nil }
        let clean = DisplayText.sanitized(notes, maxLength: notesExcerptLength, allowNewlines: true)
        return clean.isEmpty ? nil : .string(clean)
    }

    /// A title or place from a calendar, with hidden characters removed.
    static func cleanLine(_ text: String?, maxLength: Int = 500) -> JSONValue? {
        guard let text else { return nil }
        let clean = DisplayText.sanitized(text, maxLength: maxLength)
        return clean.isEmpty ? nil : .string(clean)
    }

    /// "1 event" / "3 events".
    static func count(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    // MARK: - Errors

    /// Maps a failure of the EventKit seam; `ToolError`s and cancellation pass through.
    static func toolError(_ error: Error, saving noun: String, app: String) -> Error {
        if error is ToolError || error is CancellationError { return error }
        guard let storeError = error as? CalendarStoreError else {
            return ToolError(code: .failed, modelMessage: "\(app) couldn't save the \(noun) (\(error.localizedDescription)).",
                             userMessage: "\(app) couldn't save the \(noun)")
        }
        switch storeError {
        case .calendarNotFound:
            return ToolError(code: .notFound,
                             modelMessage: "The chosen \(app == "Calendar" ? "calendar" : "list") no longer exists. Ask the user to pick another one.",
                             userMessage: "That \(app == "Calendar" ? "calendar" : "list") is gone")
        case .readOnly(let title):
            return ToolError(code: .failed, modelMessage: "“\(title)” is read-only.",
                             userMessage: "“\(DisplayText.sanitized(title, maxLength: 60))” is read-only")
        case .saveFailed(let description), .removeFailed(let description), .fetchFailed(let description):
            return ToolError(code: .failed, modelMessage: "\(app) couldn't save the \(noun) (\(description)).",
                             userMessage: "\(app) couldn't save the \(noun)")
        }
    }

    /// Maps a failure while removing an item for Undo.
    static func removeError(_ error: Error, noun: String, app: String) -> Error {
        if error is ToolError || error is CancellationError { return error }
        let description: String
        if case .removeFailed(let text)? = error as? CalendarStoreError {
            description = text
        } else {
            description = error.localizedDescription
        }
        return ToolError(code: .failed, modelMessage: "\(app) couldn't remove the \(noun) (\(description)).",
                         userMessage: "\(app) couldn't remove the \(noun)")
    }

    /// Undo found nothing to remove.
    static func alreadyRemoved(_ noun: String) -> ToolError {
        ToolError(code: .notFound, modelMessage: "The \(noun) was already removed.",
                  userMessage: "the \(noun) was already removed")
    }

    /// Undo found more than one item that looks like the created one, so it removed none.
    static func severalMatches(_ noun: String, app: String) -> ToolError {
        ToolError(code: .ambiguous,
                  modelMessage: "More than one matching \(noun) was found, so Otto removed none of them.",
                  userMessage: "more than one matching \(noun), so remove it in \(app)")
    }

    /// Two optional instants within a second of each other (or both nil).
    static func sameInstant(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left?, right?): return abs(left.timeIntervalSince(right)) < 1
        default: return false
        }
    }

    /// A read failed.
    static func readError(_ error: Error, app: String) -> Error {
        if error is ToolError || error is CancellationError { return error }
        let description: String
        if case .fetchFailed(let text)? = error as? CalendarStoreError {
            description = text
        } else {
            description = error.localizedDescription
        }
        return ToolError(code: .failed, modelMessage: "\(app) couldn't be read (\(description)).",
                         userMessage: "Couldn't read \(app)")
    }
}
