//
//  CalendarCreateReminderTool.swift
//  Otto
//
//  `reminders_create`: adds one reminder after the user approves a card with the reminder tile and a list
//  picker. A date gives a date-only reminder; a time gives a timed one with an alert at that time. Undo
//  removes it by identifier, or finds it again by title and due date in its list.
//

import Foundation

struct CalendarCreateReminderTool: OttoTool {
    let eventKit: any EventKitProviding
    let clock: CalendarToolClock

    init(eventKit: any EventKitProviding, clock: CalendarToolClock = .live) {
        self.eventKit = eventKit
        self.clock = clock
    }

    var name: String { "reminders_create" }
    var group: ToolGroup? { .reminders }

    var description: String {
        "Create a reminder in the Reminders app. The user must approve it. `due` is a date (YYYY-MM-DD) or a local date-time (YYYY-MM-DDTHH:MM); a timed reminder also gets an alert at that time."
    }

    var inputSchema: JSONValue {
        [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "What to be reminded of."],
                "due": [
                    "type": "string",
                    "pattern": .string(DateInput.pattern),
                    "description": "Optional due date or local date-time.",
                ],
                "notes": ["type": "string", "description": "Optional notes."],
                "list": ["type": "string", "description": "Exact name of a list. Omit for the default list."],
            ],
            "required": ["title"],
            "additionalProperties": false,
        ]
    }

    var isConcurrencySafe: Bool { false }
    var timeout: Duration { .seconds(15) }
    var rateLimit: ToolRateLimit { ToolRateLimit(perTurn: 5, perHour: nil) }
    var minimumArmingDelay: Duration { .milliseconds(350) }
    var formattedFields: Set<String> { ["due"] }

    /// Tomorrow 9 AM in the clock's zone, in "Errands".
    var sampleInput: JSONValue {
        let day = DateInput.isoDay(clock.now().addingTimeInterval(86_400), in: clock.timeZone())
        return [
            "title": "Call the plumber",
            "due": .string("\(day)T09:00"),
            "notes": "Ask about the kitchen sink.",
            "list": "Errands",
        ]
    }

    @MainActor func isAvailable(in environment: ToolEnvironment) -> Bool {
        environment.isDemo || environment.settings.actions.isEnabled(.reminders)
    }

    func requiredPermissions(for input: JSONValue) -> [Permission] { [.reminders] }

    func approvalRequirement(for input: JSONValue) -> ApprovalRequirement { .everyCall(rememberScope: nil) }

    func validate(_ input: JSONValue) -> ToolError? {
        let checks: [ToolError?] = [
            CalendarToolSupport.checkText(input, "title", required: true, maxLength: 500, singleLine: true),
            CalendarToolSupport.checkText(input, "notes", required: false, maxLength: 4_000, singleLine: false),
            CalendarToolSupport.checkText(input, "list", required: false, maxLength: 200, singleLine: true),
        ]
        if let error = checks.compactMap({ $0 }).first { return error }
        do {
            _ = try due(for: input)
            return nil
        } catch let error as ToolError {
            return error
        } catch {
            return CalendarToolSupport.invalid("due", error.localizedDescription)
        }
    }

    func describe(_ input: JSONValue) -> ToolCallPresentation {
        let title = CalendarToolSupport.text(input, "title") ?? "reminder"
        var detail: [String] = []
        var doneTitle = "Added “\(title)” to Reminders"
        if let due = try? due(for: input) {
            let when = dueLine(due)
            doneTitle = "Added “\(title)” · \(when)"
            detail.append(when)
        }
        if let list = CalendarToolSupport.text(input, "list") { detail.append(list) }
        return ToolCallPresentation(symbol: "checklist.checked", title: "Add “\(title)” to Reminders",
                                    activeTitle: "Adding to Reminders…", doneTitle: doneTitle,
                                    detail: detail.isEmpty ? nil : detail.joined(separator: " · "), disclosure: nil)
    }

    var preparingPresentation: ToolCallPresentation {
        ToolCallPresentation(symbol: "checklist.checked", title: "Preparing reminder…",
                             activeTitle: "Adding to Reminders…", doneTitle: "Added to Reminders", detail: nil,
                             disclosure: nil)
    }

    func approvalLabels(for input: JSONValue) -> (confirm: String, decline: String) { ("Add Reminder", "Don't add") }

    /// Refetches the lists every time, so the picker reflects a store that was just reset after a grant.
    func approvalBody(for input: JSONValue) async -> ApprovalBody {
        let lists = await eventKit.calendars(for: .reminder)
        let defaultID = await eventKit.defaultCalendarID(for: .reminder)
        let selection = CalendarToolSupport.selection(named: CalendarToolSupport.text(input, "list"), in: lists,
                                                      defaultID: defaultID, noun: "list", item: "reminder")
        let due = try? due(for: input)
        return .reminder(ReminderPreview(
            title: CalendarToolSupport.text(input, "title") ?? "",
            dueLine: due.map(dueLine) ?? CalendarToolSupport.text(input, "due"),
            hasAlert: due?.hasTime ?? false,
            notes: CalendarToolSupport.text(input, "notes"),
            lists: selection.writable.map(CalendarToolSupport.choice),
            selectedListID: selection.selectedID,
            listHint: selection.hint
        ))
    }

    func run(_ input: JSONValue, context: ToolRunContext) async throws -> ToolRunResult {
        let timeZone = clock.timeZone()
        let due = try due(for: input)
        let title = CalendarToolSupport.text(input, "title") ?? ""
        let lists = await eventKit.calendars(for: .reminder)
        let defaultID = await eventKit.defaultCalendarID(for: .reminder)
        let selection = CalendarToolSupport.selection(named: CalendarToolSupport.text(input, "list"), in: lists,
                                                      defaultID: defaultID, noun: "list", item: "reminder")
        let chosen = try CalendarToolSupport.chosenID(options: context.options, selection: selection, all: lists,
                                                      noun: "list", item: "reminder")
        let draft = CalendarReminderDraft(title: title, due: due?.components,
                                          alarmDate: due?.hasTime == true ? due?.date : nil,
                                          notes: CalendarToolSupport.text(input, "notes"))
        try Task.checkCancellation()

        let record: CalendarReminderRecord
        do {
            record = try await eventKit.createReminder(draft, listID: chosen.id)
        } catch {
            throw CalendarToolSupport.toolError(error, saving: "reminder", app: "Reminders")
        }

        let listName = lists.first { $0.id == chosen.id }.map { CalendarToolSupport.label($0, among: lists) }
            ?? record.listTitle
        var result: [String: JSONValue] = [
            "status": "created",
            "title": .string(title),
            "list": .string(listName),
        ]
        if let due {
            result["due"] = .string(due.hasTime ? DateInput.iso(due.date, in: timeZone)
                                                : DateInput.isoDay(due.date, in: timeZone))
            if due.hasTime { result["alert"] = true }
            if !due.notes.isEmpty { result["note"] = .string(due.notes.joined(separator: " ")) }
        }
        if chosen.changedByUser { result["list_changed_by_user"] = true }

        let token = UndoToken(
            toolName: name,
            itemID: record.id,
            fallback: UndoFallback(title: record.title, start: record.dueDate ?? due?.date, end: nil,
                                   calendarIdentifier: record.listID.isEmpty ? chosen.id : record.listID),
            expires: clock.now().addingTimeInterval(ToolLimits.undoWindow.timeInterval),
            doneTitle: "Removed “\(title)”",
            noteForClaude: "the reminder “\(title)” was removed"
        )
        CalendarToolSupport.logger.info("Created reminder \(record.id, privacy: .public)")
        let doneTitle = due.map { "Added “\(title)” · \(dueLine($0))" } ?? "Added “\(title)” to Reminders"
        return ToolRunResult(output: .text(CalendarToolSupport.json(result)), doneTitle: doneTitle, undo: token)
    }

    /// Removes the reminder by identifier; when that fails, searches its list for exactly one reminder with the same
    /// title and due date.
    func undo(_ token: UndoToken) async throws {
        do {
            if try await eventKit.removeReminder(identifier: token.itemID) { return }
        } catch {
            throw CalendarToolSupport.removeError(error, noun: "reminder", app: "Reminders")
        }
        guard let fallback = token.fallback else { throw CalendarToolSupport.alreadyRemoved("reminder") }
        let candidates: [CalendarReminderRecord]
        do {
            candidates = try await eventKit.reminders(in: [fallback.calendarIdentifier], filter: .all)
        } catch {
            throw CalendarToolSupport.readError(error, app: "Reminders")
        }
        let matches = candidates.filter {
            $0.title == fallback.title && CalendarToolSupport.sameInstant($0.dueDate, fallback.start)
        }
        guard matches.count <= 1 else { throw CalendarToolSupport.severalMatches("reminder", app: "Reminders") }
        guard let match = matches.first else { throw CalendarToolSupport.alreadyRemoved("reminder") }
        do {
            guard try await eventKit.removeReminder(identifier: match.id) else {
                throw CalendarToolSupport.alreadyRemoved("reminder")
            }
        } catch {
            throw CalendarToolSupport.removeError(error, noun: "reminder", app: "Reminders")
        }
        CalendarToolSupport.logger.info("Undo found the reminder again under \(match.id, privacy: .public)")
    }

    // MARK: - Private

    private func due(for input: JSONValue) throws -> DateInput.ReminderDue? {
        guard let text = CalendarToolSupport.text(input, "due") else { return nil }
        return try DateInput.reminderDue(text, now: clock.now(), in: clock.timeZone(), locale: clock.locale)
    }

    /// "Tue, Sep 29, 9:00 AM" or "Tue, Sep 29".
    private func dueLine(_ due: DateInput.ReminderDue) -> String {
        DateInput.display(due.date, allDay: !due.hasTime, in: clock.timeZone(), locale: clock.locale)
    }
}
