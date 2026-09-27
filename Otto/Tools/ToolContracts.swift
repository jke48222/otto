//
//  ToolContracts.swift
//  Otto
//
//  The tool contract shared by the tool loop, the executor, the action tools and the dock: what a
//  tool is, how it asks for approval, what the approval card shows and how a round reaches the executor.
//

import AppKit
import Foundation

/// Settings groups of the Actions feature (one toggle each). Order = display order and system-prompt order.
enum ToolGroup: String, CaseIterable, Codable, Sendable {
    case calendar, reminders, shortcuts, media, links, appleScript

    var displayName: String {
        switch self {
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .shortcuts: return "Shortcuts"
        case .media: return "Music & media"
        case .links: return "Links"
        case .appleScript: return "AppleScript"
        }
    }

    var promptPhrase: String {
        switch self {
        case .calendar: return "their calendar"
        case .reminders: return "reminders"
        case .shortcuts: return "Shortcuts"
        case .media: return "Music and Spotify playback"
        case .links: return "opening web links"
        case .appleScript: return "AppleScript"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .shortcuts: return "square.stack.3d.up"
        case .media: return "playpause"
        case .links: return "link"
        case .appleScript: return "applescript"
        }
    }

    static let defaultEnabled: Set<ToolGroup> = [.calendar, .reminders, .shortcuts, .media, .links]
}

/// One-time consent (reads). Stored by ApprovalStore; listed and revocable in Settings.
struct ConsentKey: Hashable, Codable, Sendable {
    /// "calendar.read", "reminders.read", "shortcuts.list".
    let rawValue: String
    /// "Read your calendar".
    let label: String
}

/// The narrow thing an "Always allow" covers. Only run_shortcut offers one in v1.1.
struct ApprovalScope: Hashable, Codable, Sendable {
    /// "run_shortcut".
    let toolName: String
    /// "shortcut:<UUID>" (the identifier, never the name).
    let key: String
    /// "“Log water”".
    let label: String
}

enum ApprovalRequirement: Equatable, Sendable {
    /// Runs without a card (media control).
    case none
    /// A consent card the first time only (reads); combined with the permission card when macOS access is missing.
    case consentOnce(ConsentKey)
    /// A card every call. `rememberScope` offers "Always allow <label>", never under caution or echo.
    case everyCall(rememberScope: ApprovalScope?)
}

struct ToolRateLimit: Equatable, Sendable {
    var perTurn: Int
    /// Rolling 60-minute window, in memory.
    var perHour: Int?
}

/// Loop-wide limits shared by ChatSession (tool loop) and ToolExecutor.
enum ToolLimits {
    static let maxCallsPerTurn = 25
    static let approvalTimeout: Duration = .seconds(600)
    /// Characters of raw JSON echoed back as INVALID_JSON.
    static let maxInvalidInputEcho = 2_000
    static let undoWindow: Duration = .seconds(600)
    /// Server-tool budget for one reply (all rounds and pause_turn continuations together).
    static let webSearchesPerTurn = 10
    static let webFetchesPerTurn = 10
    /// A running call whose tool `mayPresentUI` folds the open notch after this long.
    static let uiFoldDelay: Duration = .seconds(1)
}

/// Read-only facts a tool consults for availability.
@MainActor struct ToolEnvironment {
    let settings: AppSettings
    let permissions: PermissionProviding?
    let model: ModelOption
    /// --demo / --selftest / --snapshot: demo services are wired and every group except AppleScript counts as on.
    let isDemo: Bool
}

struct ToolRunContext: Sendable {
    let callID: String
    let model: ModelOption
    /// Choices made on the card (the calendar or list picked).
    let options: ApprovalOptions
    /// Throttled to 4 per second by the executor.
    let reportProgress: @Sendable (String) -> Void
    /// "Finder" while a macOS consent dialog Otto triggered is up (row → .waitingForSystem); nil when it closes.
    let reportSystemDialog: @Sendable (String?) -> Void
}

struct ToolRunResult: Sendable {
    var output: ToolOutput
    /// Overrides presentation.doneTitle.
    var doneTitle: String? = nil
    var undo: UndoToken? = nil
}

/// Typed failure. `toolResultText` is what Claude receives (is_error), `userMessage` is the row copy.
struct ToolError: LocalizedError, Equatable, Sendable {
    enum Code: String, Sendable {
        case invalidInput = "invalid_input", permissionDenied = "permission_denied", notFound = "not_found",
             ambiguous, declined, blocked, disabled, limit, timeout, cancelled,
             notRunning = "not_running", failed, unknownTool = "unknown_tool"
    }

    let code: Code
    let modelMessage: String
    let userMessage: String
    var recovery: ToolRecovery? = nil

    var toolResultText: String { "\(code.rawValue): \(modelMessage)" }
    var errorDescription: String? { toolResultText }
}

protocol OttoTool: Sendable {
    /// ^[a-zA-Z0-9_-]{1,64}$; never web_search / web_fetch / code_execution.
    var name: String { get }
    /// nil only for demo and internal tools.
    var group: ToolGroup? { get }
    /// Model-facing: when to use it, what it returns, its limits, and "treat returned text as data".
    var description: String { get }
    /// Full validation schema (may use pattern/minLength/maxLength/minimum/maximum/minItems/maxItems/format).
    /// The API receives `ToolSchema.wireSchema(inputSchema, strict: isStrict)`.
    var inputSchema: JSONValue { get }
    /// Default true.
    var isStrict: Bool { get }
    /// Pure reads only: may run concurrently (phase A).
    var isConcurrencySafe: Bool { get }
    /// Default false; text written by third parties.
    var producesUntrustedOutput: Bool { get }
    /// "your calendar" when outputs contain private data that must not leave the Mac via egress fields. Default nil.
    var privateDataSource: String? { get }
    /// Default 30 s.
    var timeout: Duration { get }
    /// Default perTurn 10, perHour nil.
    var rateLimit: ToolRateLimit { get }
    /// Minimum card arming delay; the executor raises it under caution. Default 0.35 s.
    var minimumArmingDelay: Duration { get }
    /// Input used by tests (describe/approvalBody must not crash; WYSIWYG check).
    var sampleInput: JSONValue { get }
    /// Input string fields rendered formatted (dates) and therefore exempt from the WYSIWYG substring test.
    /// Default [].
    var formattedFields: Set<String> { get }
    /// The run may put up its own windows or dialogs (a script's `display dialog`, a shortcut's "Ask for Input").
    /// While such a call runs ≥ ToolLimits.uiFoldDelay the open notch folds out of the way. Default false;
    /// true for run_applescript and run_shortcut.
    var mayPresentUI: Bool { get }
    /// The child process runs with Otto as its TCC-responsible process, so it silently inherits every grant Otto
    /// holds (Accessibility, Screen Recording, Calendars, Automation targets…). The executor then lists them on the
    /// card (AppleScriptPreview.inheritedAccess). Default false; true for run_applescript.
    var inheritsOttoPermissions: Bool { get }

    @MainActor func isAvailable(in environment: ToolEnvironment) -> Bool
    /// Default [].
    func requiredPermissions(for input: JSONValue) -> [Permission]
    func approvalRequirement(for input: JSONValue) -> ApprovalRequirement
    /// Strings that leave the Mac (URL, shortcut input, script source), scanned by EchoDetector. Default [].
    func egressStrings(in input: JSONValue) -> [String]
    /// Local limits beyond the schema (lengths, date semantics). nil = valid (the default).
    func validate(_ input: JSONValue) -> ToolError?
    /// Hard block before asking (e.g. AppleScript admin privileges). nil = may proceed. Default nil.
    func blockReason(for input: JSONValue) -> String?
    func describe(_ input: JSONValue) -> ToolCallPresentation
    /// Default `.generic(toolName: name)`.
    var preparingPresentation: ToolCallPresentation { get }
    /// Card labels. Default ("Run", "Don't run").
    func approvalLabels(for input: JSONValue) -> (confirm: String, decline: String)
    /// Card body for a validated input. Nonisolated; may await services (EventKit actor: calendars, conflicts).
    /// The card initializes ApprovalOptions.calendarIdentifier from EventPreview/ReminderPreview.selected…ID.
    func approvalBody(for input: JSONValue) async -> ApprovalBody
    /// Off the main actor. Honors cancellation promptly. Throw ToolError for typed failures.
    func run(_ input: JSONValue, context: ToolRunContext) async throws -> ToolRunResult
    /// Default: throws ToolError(.failed, "This action can't be undone.").
    func undo(_ token: UndoToken) async throws
}

extension OttoTool {
    var isStrict: Bool { true }
    var producesUntrustedOutput: Bool { false }
    var privateDataSource: String? { nil }
    var timeout: Duration { .seconds(30) }
    var rateLimit: ToolRateLimit { ToolRateLimit(perTurn: 10, perHour: nil) }
    var minimumArmingDelay: Duration { .milliseconds(350) }
    var formattedFields: Set<String> { [] }
    var mayPresentUI: Bool { false }
    var inheritsOttoPermissions: Bool { false }
    var preparingPresentation: ToolCallPresentation { .generic(toolName: name) }

    func requiredPermissions(for input: JSONValue) -> [Permission] { [] }
    func egressStrings(in input: JSONValue) -> [String] { [] }
    func validate(_ input: JSONValue) -> ToolError? { nil }
    func blockReason(for input: JSONValue) -> String? { nil }
    func approvalLabels(for input: JSONValue) -> (confirm: String, decline: String) { ("Run", "Don't run") }

    func undo(_ token: UndoToken) async throws {
        throw ToolError(code: .failed, modelMessage: "This action can't be undone.",
                        userMessage: "This action can't be undone.")
    }

    /// {"name","description","input_schema": ToolSchema.wireSchema(inputSchema, strict: isStrict),
    ///  "eager_input_streaming": true, "strict": true (only when isStrict)}
    func definition() -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "description": .string(description),
            "input_schema": ToolSchema.wireSchema(inputSchema, strict: isStrict),
            "eager_input_streaming": true,
        ]
        if isStrict { object["strict"] = true }
        return .object(object)
    }
}

// MARK: - Approvals

struct CautionBanner: Equatable, Sendable {
    /// "Otto read example.com just before asking."
    let headline: String
    /// "Pages and files can hide instructions. Only continue if you asked for this."
    let body: String
}

struct ApprovalOptions: Equatable, Sendable {
    var alwaysAllow = false
    /// The calendar (events) or list (reminders) chosen on the card.
    var calendarIdentifier: String? = nil
}

enum ApprovalDecision: Equatable, Sendable {
    case run(ApprovalOptions)
    case deny
    /// This call and every remaining card-requiring call of the round.
    case denyAll
    /// Turn stopped, new chat, or conversation replaced.
    case cancelled
    /// No answer within ToolLimits.approvalTimeout (10 minutes).
    case expired
}

/// What the dock shows for the tool loop. Exactly one exists at a time.
struct PendingApproval: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// everyCall.
        case approval(rememberScope: ApprovalScope?)
        /// consentOnce, macOS access already granted.
        case consent(ConsentKey)
        /// macOS access missing (in request order).
        case permission([Permission], consent: ConsentKey?)
    }

    var id: String { callID }
    let callID: String
    let messageID: UUID
    let toolName: String
    let kind: Kind
    let presentation: ToolCallPresentation
    let body: ApprovalBody
    /// "Add Event", "Run Script", "Allow", "Open", "Run Shortcut".
    let confirmLabel: String
    /// "Don't add", "Don't run", "Not now", "Cancel".
    let declineLabel: String
    /// "Requested after reading example.com" / "Earlier in this chat Otto read …".
    let provenance: String?
    let caution: CautionBanner?
    let armingDelay: Duration
    /// When the executor created it, NOT when the user could first see it.
    let presentedAt: Date
    /// 1-based among the card-requiring calls of this round.
    let position: Int
    let total: Int

    /// Arming counts from when the card was actually visible (the VM's `approvalVisibility`), never from
    /// `presentedAt`: a card created while the notch was closed, on another route, or before a notification was
    /// tapped must still make the user wait `armingDelay` after it appears. (No `isArmed`: a stored-clock
    /// property can't be tested with the executor's injected `now`.)
    func armedAt(visibleSince: Date) -> Date { visibleSince.addingTimeInterval(armingDelay.timeInterval) }

    var remainingInRound: Int { total - position }
}

// MARK: - Approval card bodies (rendered by ApprovalBodyView)

enum ApprovalBody: Equatable, Sendable {
    case consent(ConsentPreview)
    case text(TextPreview)
    case event(EventPreview)
    case reminder(ReminderPreview)
    case shortcut(ShortcutPreview)
    case appleScript(AppleScriptPreview)
    case url(URLPreview)

    /// Every string the body displays verbatim (WYSIWYG tests, VoiceOver summary), in reading order.
    /// Pickers contribute the chosen calendar or list only; empty strings are left out.
    var displayedStrings: [String] {
        let strings: [String?]
        switch self {
        case .consent(let preview):
            strings = [preview.title, preview.body, preview.footnote]
        case .text(let preview):
            strings = [preview.label, preview.text]
        case .event(let preview):
            let selected = preview.calendars.first { $0.id == preview.selectedCalendarID }?.title
            strings = [preview.title, preview.weekday, preview.day, preview.timeLine, preview.location, preview.notes,
                       selected, preview.calendarHint]
                + preview.conflicts.map(Optional.some)
                + [preview.timeZoneNote, preview.adjustmentNote]
        case .reminder(let preview):
            let selected = preview.lists.first { $0.id == preview.selectedListID }?.title
            strings = [preview.title, preview.dueLine, preview.notes, selected, preview.listHint]
        case .shortcut(let preview):
            strings = [preview.name, preview.input]
        case .appleScript(let preview):
            strings = [preview.purpose, preview.source]
                + preview.targets.map { Optional.some($0.label) }
                + preview.capabilities.map { Optional.some($0.label) }
                + preview.inheritedAccess.map(Optional.some)
        case .url(let preview):
            strings = [preview.url, preview.displayHost, preview.punycodeHost]
                + preview.warnings.map(Optional.some)
        }
        return strings.compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// Confirm stays disabled until a calendar or list is picked (named calendar not found or ambiguous).
    var requiresSelection: Bool {
        switch self {
        case .event(let preview):
            return preview.calendars.first { $0.id == preview.selectedCalendarID } == nil
        case .reminder(let preview):
            return preview.lists.first { $0.id == preview.selectedListID } == nil
        case .consent, .text, .shortcut, .appleScript, .url:
            return false
        }
    }
}

struct ConsentPreview: Equatable, Sendable { var symbol: String; var title: String; var body: String; var footnote: String? }
struct TextPreview: Equatable, Sendable { var label: String; var text: String; var language: String? }
struct CalendarChoice: Equatable, Sendable, Identifiable {
    /// `colorRGBA`: 4 components, sRGB.
    var id: String; var title: String; var source: String; var colorRGBA: [Double]?
}
struct EventPreview: Equatable, Sendable {
    var title: String
    /// "TUE".
    var weekday: String
    /// "29".
    var day: String
    /// "3:00 – 4:00 PM" · "All day" · "Sep 29 – Oct 1".
    var timeLine: String
    var location: String?
    var notes: String?
    var calendars: [CalendarChoice]
    var selectedCalendarID: String?
    /// "“Wrk” isn't one of your calendars. Pick one."
    var calendarHint: String?
    /// "Overlaps with “Team sync” 3:30 PM" (≤ 2 plus "+1 more").
    var conflicts: [String]
    /// "3:00 PM your time (6:00 PM New York)".
    var timeZoneNote: String?
    /// Daylight-saving adjustment.
    var adjustmentNote: String?
}
struct ReminderPreview: Equatable, Sendable {
    var title: String; var dueLine: String?; var hasAlert: Bool; var notes: String?
    var lists: [CalendarChoice]; var selectedListID: String?; var listHint: String?
}
struct ShortcutPreview: Equatable, Sendable { var name: String; var input: String? }
struct ScriptChip: Equatable, Sendable { var label: String; var isDanger: Bool; var bundleID: String? }
struct AppleScriptPreview: Equatable, Sendable {
    /// Model-written; shown as "Otto says: “…”".
    var purpose: String
    /// EXACT stdin of osascript.
    var source: String
    /// App chips.
    var targets: [ScriptChip]
    /// "Runs shell commands" (danger), …
    var capabilities: [ScriptChip]
    var lineCount: Int
    /// Filled by the executor (tool.inheritsOttoPermissions) from PermissionProviding.grantedPermissions():
    /// ["Accessibility", "Screen & System Audio Recording", "Calendars", "Safari", …]. Rendered as the chip row
    /// "Runs with Otto's access to: … (macOS won't ask again)". Empty = row hidden.
    var inheritedAccess: [String] = []
}
struct URLPreview: Equatable, Sendable { var url: String; var displayHost: String; var punycodeHost: String?; var warnings: [String] }

// MARK: - Loop ↔ executor seam

/// One round handed to the executor.
struct ToolRound: Sendable {
    let messageID: UUID
    /// Model order.
    let callIDs: [String]
    /// 0-based within the turn.
    let roundIndex: Int
    /// The request's messages plus this response's content as a final assistant entry (TrustLedger, EchoDetector).
    let transcript: [JSONValue]
    /// The turn's snapshot, by name.
    let tools: [String: any OttoTool]
    let model: ModelOption
}

/// Implemented by ChatSession; the executor mutates calls only through it (no-op when the turn is no longer active).
@MainActor protocol ToolCallStore: AnyObject {
    func toolCall(_ id: String, in messageID: UUID) -> ToolCall?
    func updateToolCall(_ id: String, in messageID: UUID, _ mutate: (inout ToolCall) -> Void)
}

@MainActor protocol ToolExecuting: AnyObject {
    /// The dock's current tool-loop prompt (observable in the concrete class).
    var pendingApproval: PendingApproval? { get }
    var onAttentionNeeded: ((PendingApproval) -> Void)? { get set }
    /// Per-turn counters (rate limits, declines).
    func beginTurn()
    /// Runs one round; every call ends with a terminal status and a `result`. Throws CancellationError when
    /// the turn is cancelled (pending approval resolved .cancelled, running tools cancelled).
    func execute(_ round: ToolRound, store: ToolCallStore) async throws -> ToolRoundOutcome
    /// Ignores stale call ids. `.run` is ignored unless `hardwareConfirmed` AND `visibleSince != nil` AND the
    /// executor's own clock says `now() >= pending.armedAt(visibleSince:)`. `visibleSince` is when the card
    /// became visible (and fully reviewed) on screen, reported by the VM; nil = not visible now.
    func resolve(_ decision: ApprovalDecision, callID: String, hardwareConfirmed: Bool, visibleSince: Date?)
    func cancelAll()
    /// nil on success; else a short user-facing reason ("the event was already removed").
    func undo(callID: String, messageID: UUID, store: ToolCallStore) async -> String?
    /// [Stop] on one running call.
    func stop(callID: String)
    /// Notes queued for the next user message ("[Note: the user undid an action — …]"); cleared on read.
    func consumeContextNotes() -> [String]
}

/// What the loop must know after a round (the executor owns TrustLedger/EchoDetector; the loop never imports them).
struct ToolRoundOutcome: Equatable, Sendable {
    /// Non-nil when private data is in context (EchoDetector found private phrases, or a call with a
    /// privateDataSource succeeded this round) while fresh medium/high untrusted content is too (trust.caution):
    /// the loop then sends the rest of this reply without server tools.
    var webPause: WebPauseReason? = nil
}

struct WebPauseReason: Equatable, Sendable {
    /// "your calendar", "your selection", "a shortcut's output".
    let privateSource: String
    /// "example.com", "a web search", "report.pdf".
    let untrustedSource: String
}

/// Absolute-path child process runner (ToolExecutor's `ProcessRunner` implements it; services depend on the protocol).
protocol ProcessRunning: Sendable {
    func run(_ executable: URL, arguments: [String], stdin: Data?, timeout: Duration,
             outputLimit: Int) async throws -> ProcessOutput
}

struct ProcessOutput: Equatable, Sendable {
    let stdout: String; let stderr: String; let exitCode: Int32; let timedOut: Bool; let duration: Duration
}
