//
//  DockComponentsTests.swift
//  OttoTests
//
//  The dock's pure helpers (tool-row copy and glyphs, arming progress, button enablement, the character
//  wrap behind every code and address box) and a WYSIWYG check that an approval body puts every string
//  it promises on screen, recorded by the views themselves as they appear in a hosted window.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import Otto

@MainActor
final class DockComponentsTests: XCTestCase {
    // MARK: - Tool rows

    func testRowLabelForEveryStatus() {
        let presentation = ToolCallPresentation(symbol: "calendar.badge.plus", title: "Add “Dentist” to Calendar",
                                                activeTitle: "Adding to Calendar…",
                                                doneTitle: "Added “Dentist” · Tue, Sep 29, 3:00 PM",
                                                detail: nil, disclosure: nil)
        func label(_ status: ToolCallStatus) -> String {
            ToolCallCard.label(for: makeCall(status: status, presentation: presentation))
        }

        XCTAssertEqual(label(.preparing), "Add “Dentist” to Calendar")
        XCTAssertEqual(label(.queued), "Add “Dentist” to Calendar")
        XCTAssertEqual(label(.needsPermission), "Waiting for your permission")
        XCTAssertEqual(label(.awaitingApproval), "Waiting for your OK")
        XCTAssertEqual(label(.waitingForSystem("Finder")), "Waiting for macOS permission for Finder…")
        XCTAssertEqual(label(.waitingForSystem("")), "Waiting for macOS…")
        XCTAssertEqual(label(.running), "Adding to Calendar…")
        XCTAssertEqual(label(.succeeded), "Added “Dentist” · Tue, Sep 29, 3:00 PM")
        XCTAssertEqual(label(.undone), "Added “Dentist” · Tue, Sep 29, 3:00 PM",
                       "the executor swaps in the undo token's done title; the row shows it as is")
        XCTAssertEqual(label(.failed("Timed out")), "Add “Dentist” to Calendar: Timed out")
        XCTAssertEqual(label(.denied), "You declined: Add “Dentist” to Calendar")
        XCTAssertEqual(label(.blocked("it asked for administrator privileges")),
                       "Blocked: it asked for administrator privileges")
        XCTAssertEqual(label(.cancelled), "Stopped: Add “Dentist” to Calendar")
        XCTAssertEqual(label(.skipped("Limit reached")), "Skipped: Add “Dentist” to Calendar (Limit reached)")
    }

    func testRowGlyphForEveryStatus() {
        XCTAssertEqual(ToolCallCard.glyph(for: .preparing), .spinner)
        XCTAssertEqual(ToolCallCard.glyph(for: .queued), .spinner)
        XCTAssertEqual(ToolCallCard.glyph(for: .running), .spinner)
        XCTAssertEqual(ToolCallCard.glyph(for: .waitingForSystem("Finder")), .spinner)
        XCTAssertEqual(ToolCallCard.glyph(for: .needsPermission), .attention)
        XCTAssertEqual(ToolCallCard.glyph(for: .awaitingApproval), .attention)
        XCTAssertEqual(ToolCallCard.glyph(for: .succeeded), .succeeded)
        XCTAssertEqual(ToolCallCard.glyph(for: .denied), .stopped)
        XCTAssertEqual(ToolCallCard.glyph(for: .cancelled), .stopped)
        XCTAssertEqual(ToolCallCard.glyph(for: .skipped("Limit reached")), .stopped)
        XCTAssertEqual(ToolCallCard.glyph(for: .failed("Timed out")), .problem)
        XCTAssertEqual(ToolCallCard.glyph(for: .blocked("no")), .problem)
        XCTAssertEqual(ToolCallCard.glyph(for: .undone), .undone)
    }

    func testRowControls() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        var call = makeCall(status: .succeeded)
        call.undo = UndoToken(toolName: "calendar_create_event", itemID: "E1", fallback: nil,
                              expires: now.addingTimeInterval(60), doneTitle: "Removed “Dentist”",
                              noteForClaude: "removed")
        XCTAssertTrue(ToolCallCard.canUndo(call, now: now))
        XCTAssertFalse(ToolCallCard.canUndo(call, now: now.addingTimeInterval(60)), "Undo ends at expiry")
        call.status = .undone
        XCTAssertFalse(ToolCallCard.canUndo(call, now: now))

        XCTAssertTrue(ToolCallCard.canStop(makeCall(status: .running)))
        XCTAssertTrue(ToolCallCard.canStop(makeCall(status: .waitingForSystem("Finder"))))
        XCTAssertFalse(ToolCallCard.canStop(makeCall(status: .queued)))
        XCTAssertFalse(ToolCallCard.canStop(makeCall(status: .succeeded)))

        XCTAssertEqual(ToolCallCard.recoveryTitle(.openSystemSettings(.calendars)), "Open Privacy Settings")
        XCTAssertEqual(ToolCallCard.recoveryTitle(.openActionsSettings), "Open Settings")

        var remembered = makeCall(status: .succeeded)
        remembered.approvedVia = .rememberedScope(label: "“Log water”")
        XCTAssertEqual(ToolCallCard.rememberedLabel(remembered), "“Log water”")
        remembered.approvedVia = .userApproved
        XCTAssertNil(ToolCallCard.rememberedLabel(remembered))
    }

    func testRowDurationAndDetails() {
        var call = makeCall(status: .succeeded)
        XCTAssertNil(ToolCallCard.durationText(for: call))
        let start = Date(timeIntervalSinceReferenceDate: 0)
        call.startedAt = start
        call.finishedAt = start.addingTimeInterval(0.42)
        XCTAssertEqual(ToolCallCard.durationText(for: call), "0.4 s")
        call.finishedAt = start.addingTimeInterval(12.4)
        XCTAssertEqual(ToolCallCard.durationText(for: call), "12 s")
        call.finishedAt = start.addingTimeInterval(65)
        XCTAssertEqual(ToolCallCard.durationText(for: call), "1 min 5 s")

        XCTAssertFalse(ToolCallCard.hasDetails(call))
        call.result = .text("Done.")
        XCTAssertTrue(ToolCallCard.hasDetails(call))
        call.result = nil
        call.presentation.disclosure = ToolDisclosure(label: "Script", text: "beep", language: "AppleScript")
        XCTAssertTrue(ToolCallCard.hasDetails(call))
    }

    func testToolCallCardEqualityFollowsTheCall() {
        let call = makeCall(status: .running)
        XCTAssertEqual(ToolCallCard(call: call), ToolCallCard(call: call, onUndo: { XCTFail("never called") }))
        XCTAssertNotEqual(ToolCallCard(call: call), ToolCallCard(call: makeCall(status: .succeeded)))
    }

    // MARK: - Arming

    func testArmingProgressCountsFromVisibility() {
        let since = Date(timeIntervalSinceReferenceDate: 500)
        let delay = Duration.seconds(2)
        XCTAssertEqual(ApprovalCard.armingProgress(visibleSince: nil, armingDelay: delay, now: since), 0)
        XCTAssertEqual(ApprovalCard.armingProgress(visibleSince: nil, armingDelay: delay,
                                                   now: since.addingTimeInterval(100)), 0,
                       "never armed while the card isn't visible")
        XCTAssertEqual(ApprovalCard.armingProgress(visibleSince: since, armingDelay: delay, now: since), 0)
        XCTAssertEqual(ApprovalCard.armingProgress(visibleSince: since, armingDelay: delay,
                                                   now: since.addingTimeInterval(0.5)), 0.25, accuracy: 1e-9)
        XCTAssertEqual(ApprovalCard.armingProgress(visibleSince: since, armingDelay: delay,
                                                   now: since.addingTimeInterval(2)), 1)
        XCTAssertEqual(ApprovalCard.armingProgress(visibleSince: since, armingDelay: delay,
                                                   now: since.addingTimeInterval(30)), 1)
        XCTAssertEqual(ApprovalCard.armingProgress(visibleSince: since, armingDelay: delay,
                                                   now: since.addingTimeInterval(-1)), 0,
                       "a clock that runs backwards doesn't arm early")
        XCTAssertEqual(ApprovalCard.armingProgress(visibleSince: since, armingDelay: .zero, now: since), 1)
    }

    func testArmingAnnouncement() {
        XCTAssertEqual(ApprovalCard.armingAnnouncement(delay: .milliseconds(350)), "Available in 1 second")
        XCTAssertEqual(ApprovalCard.armingAnnouncement(delay: .milliseconds(1_500)), "Available in 2 seconds")
        XCTAssertNil(ApprovalCard.armingAnnouncement(delay: .zero))
        let approval = makeApproval(body: .text(TextPreview(label: "Input", text: "hi", language: nil)))
        XCTAssertEqual(ApprovalCard.appearanceAnnouncement(for: approval),
                       "Approval needed: Run “Log water”. Available in 1 second.")
    }

    func testPrimaryEnablement() {
        let since = Date(timeIntervalSinceReferenceDate: 0)
        let armed = since.addingTimeInterval(5)
        let simple = makeApproval(body: .shortcut(ShortcutPreview(name: "Log water", input: nil)))

        XCTAssertFalse(ApprovalCard.isPrimaryEnabled(approval: simple, options: ApprovalOptions(),
                                                     visibleSince: nil, now: armed), "disabled while not visible")
        XCTAssertFalse(ApprovalCard.isPrimaryEnabled(approval: simple, options: ApprovalOptions(),
                                                     visibleSince: since, now: since.addingTimeInterval(0.1)),
                       "disabled while arming")
        XCTAssertTrue(ApprovalCard.isPrimaryEnabled(approval: simple, options: ApprovalOptions(),
                                                    visibleSince: since, now: armed))

        let choices = [CalendarChoice(id: "home", title: "Home", source: "iCloud", colorRGBA: nil),
                       CalendarChoice(id: "work", title: "Work", source: "iCloud", colorRGBA: nil)]
        let unresolved = makeApproval(body: .event(makeEvent(calendars: choices, selected: nil)))
        XCTAssertTrue(unresolved.body.requiresSelection)
        XCTAssertFalse(ApprovalCard.isPrimaryEnabled(approval: unresolved, options: ApprovalOptions(),
                                                     visibleSince: since, now: armed),
                       "requiresSelection keeps it disabled until a calendar is picked")
        XCTAssertFalse(ApprovalCard.isPrimaryEnabled(approval: unresolved,
                                                     options: ApprovalOptions(calendarIdentifier: "gone"),
                                                     visibleSince: since, now: armed),
                       "a pick that isn't one of the calendars doesn't count")
        XCTAssertTrue(ApprovalCard.isPrimaryEnabled(approval: unresolved,
                                                    options: ApprovalOptions(calendarIdentifier: "work"),
                                                    visibleSince: since, now: armed))

        let resolved = makeApproval(body: .event(makeEvent(calendars: choices, selected: "home")))
        XCTAssertTrue(ApprovalCard.isPrimaryEnabled(approval: resolved, options: ApprovalOptions(),
                                                    visibleSince: since, now: armed))

        let reminder = makeApproval(body: .reminder(ReminderPreview(title: "Water", dueLine: nil, hasAlert: false,
                                                                    notes: nil, lists: choices, selectedListID: nil,
                                                                    listHint: "Pick a list")))
        XCTAssertFalse(ApprovalCard.hasRequiredSelection(body: reminder.body, options: ApprovalOptions()))
        XCTAssertTrue(ApprovalCard.hasRequiredSelection(body: reminder.body,
                                                        options: ApprovalOptions(calendarIdentifier: "home")))
    }

    func testCardCopyHelpers() {
        XCTAssertNil(ApprovalCard.counterText(position: 1, total: 1))
        XCTAssertEqual(ApprovalCard.reviewHint(reviewed: false), "Scroll to review")
        XCTAssertNil(ApprovalCard.reviewHint(reviewed: true))
        XCTAssertEqual(ApprovalCard.counterText(position: 2, total: 3), "2 of 3")

        let scope = ApprovalScope(toolName: "run_shortcut", key: "shortcut:1", label: "“Log water”")
        XCTAssertEqual(ApprovalCard.rememberLabel(for: .approval(rememberScope: scope)), "Always allow “Log water”")
        XCTAssertNil(ApprovalCard.rememberLabel(for: .approval(rememberScope: nil)))
        XCTAssertNil(ApprovalCard.rememberLabel(for: .consent(ConsentKey(rawValue: "calendar.read",
                                                                         label: "Read your calendar"))))

        XCTAssertEqual(ApprovalCard.accessibilityApproval(assistiveInputRunning: true), .approve)
        XCTAssertEqual(ApprovalCard.accessibilityApproval(assistiveInputRunning: false),
                       .explain("Approve with this Mac's keyboard or trackpad."))

        let provenance = ApprovalCard.provenanceText("Requested after reading example.com")
        XCTAssertEqual(String(provenance.characters), "Requested after reading example.com")
        let bold = provenance.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(provenance[$0.range].characters) }
        XCTAssertEqual(bold, ["example.com"])
        let plain = ApprovalCard.provenanceText("Earlier in this chat Otto searched the web")
        XCTAssertTrue(plain.runs.allSatisfy { $0.inlinePresentationIntent == nil })
    }

    /// After a screen capture the view model drops the card's review while the card stays up; the card reports it
    /// again once nothing covers it, only for its own call, and not while it is still covered.
    func testReviewedCardReportsAgainAfterItWasCovered() {
        let since = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertTrue(ApprovalCard.reportsReviewAgain(reportedCallID: "call-1", callID: "call-1", visibleSince: nil,
                                                      isSuspended: false), "capture ended, visibility was dropped")
        XCTAssertFalse(ApprovalCard.reportsReviewAgain(reportedCallID: "call-1", callID: "call-1", visibleSince: nil,
                                                       isSuspended: true), "still capturing")
        XCTAssertFalse(ApprovalCard.reportsReviewAgain(reportedCallID: "call-1", callID: "call-1", visibleSince: since,
                                                       isSuspended: false), "already visible and arming")
        XCTAssertFalse(ApprovalCard.reportsReviewAgain(reportedCallID: nil, callID: "call-1", visibleSince: nil,
                                                       isSuspended: false), "never reviewed")
        XCTAssertFalse(ApprovalCard.reportsReviewAgain(reportedCallID: "call-1", callID: "call-2", visibleSince: nil,
                                                       isSuspended: false), "a review never carries to another call")
    }

    func testPromptChromeHelpers() {
        let permission = PermissionCardContent.make(permission: .accessibility, purpose: .paste(appName: "Notes"),
                                                    phase: .needsRelaunch, status: .needsRelaunch)
        XCTAssertEqual(PermissionCard.primaryHint(for: permission), "⌘↩", "Quit & Reopen never runs on bare Return")
        let explain = PermissionCardContent.make(permission: .calendars, purpose: .calendarGlance,
                                                 phase: .explain, status: .notDetermined)
        XCTAssertEqual(PermissionCard.primaryHint(for: explain), "↩")

        // A card standing in for an approval (a tool that needs Calendars first): the key map refuses a bare Return
        // for approvals, so the cap must say ⌘↩.
        let tool = PermissionCardContent.make(permission: .calendars,
                                              purpose: .tool(title: "Add “Dentist” to Calendar", dataFlow: nil),
                                              phase: .explain, status: .notDetermined)
        var approvalContext = NotchKeyContext()
        approvalContext.prompt = .approval
        approvalContext.promptPrimaryRequiresCommand = tool.primaryRequiresCommand
        XCTAssertNotEqual(NotchKeyCommands.command(keyCode: UInt16(kVK_Return), characters: "\r", flags: [],
                                                   context: approvalContext), .promptPrimary)
        XCTAssertEqual(NotchKeyCommands.command(keyCode: UInt16(kVK_Return), characters: "\r", flags: .command,
                                                context: approvalContext), .promptPrimary)
        XCTAssertEqual(PermissionCard.primaryHint(for: tool, isApproval: true), "⌘↩")
        XCTAssertEqual(String(PermissionCard.bodyText("Otto pastes into **Notes**.").characters),
                       "Otto pastes into Notes.")

        let card = NotchCard(kind: .notchNeighbor(name: "NotchNook"), symbol: "rectangle.topthird.inset.filled",
                             title: "Another notch app is running", message: "m", footnote: nil,
                             primary: .init(title: "Use Click to Open", action: .useClickToOpen),
                             secondary: .init(title: "Keep Hover", action: .keepHover(neighbor: "NotchNook")),
                             escapeAction: .keepHover(neighbor: "NotchNook"), requiresDecision: false)
        XCTAssertEqual(NotchCardView.hints(for: card).primary, "↩")
        XCTAssertEqual(NotchCardView.hints(for: card).secondary, "esc")

        let approval = NotchPrompt.approval(makeApproval(body: .url(URLPreview(url: "https://a.b", displayHost: "a.b",
                                                                               punycodeHost: nil, warnings: []))))
        XCTAssertEqual(AttentionCapsule.text(for: approval), "Otto needs your OK")
        XCTAssertEqual(AttentionCapsule.text(for: .card(card)), "Otto has a question")

        XCTAssertTrue(ScriptInheritedAccessRow.isDanger(["Calendars", "Accessibility"]))
        XCTAssertTrue(ScriptInheritedAccessRow.isDanger(["Screen & System Audio Recording"]))
        XCTAssertFalse(ScriptInheritedAccessRow.isDanger(["Calendars", "Safari"]))
    }

    // MARK: - Wrap

    func testWrapRowsJoinBackToTheExactSource() {
        let long = String(repeating: "set x to \"abcdefghij\" & ", count: 12) + "\"end\""
        let sources = [
            "",
            "beep",
            "tell application \"Finder\"\n\tactivate\nend tell",
            "tell application \"Finder\"\n\tactivate\nend tell\n",
            long,
            "line one\r\nline two\rline three\n\n\nafter blanks",
            "\t\t\tdeeply\t\tindented\t",
            "display dialog \"日本語のテキストがとても長い行に続きます、そしてさらに続きます\"",
            "set emoji to \"👩🏽‍💻🚀🇺🇸 e\u{301} café\"\n" + String(repeating: "🙂", count: 30),
            String(repeating: "x", count: 200),
        ]
        for source in sources {
            for columns in [4, 5, 13, 40, 80] {
                let rows = AppleScriptCodeLayout.wrap(source, columns: columns)
                XCTAssertEqual(rows.map(\.text).joined(), source, "columns \(columns): \(source.debugDescription)")
                for row in rows {
                    let width = row.text.reduce(0) { $0 + AppleScriptCodeLayout.columnWidth(of: $1) }
                    XCTAssertEqual(width, row.width)
                    XCTAssertLessThanOrEqual(row.width, columns, "row \(row.index) of \(source.debugDescription)")
                    XCTAssertFalse(row.text.dropLast().contains(where: \.isNewline),
                                   "a terminator only ever ends a row")
                }
                XCTAssertEqual(rows.map(\.index), Array(rows.indices))
            }
        }
    }

    /// A row that runs out of room breaks after its last space or separator when that keeps half the row, so an
    /// identifier moves to the next row whole; otherwise, and never inside indentation, it breaks at the character.
    func testWrapPrefersTokenBoundaries() {
        let line = "\tif not (exists folder \"Installers and Archives\" of downloadsFolder) then"
        let rows = AppleScriptCodeLayout.wrap(line, columns: 60)
        XCTAssertEqual(rows.map(\.text).joined(), line)
        XCTAssertEqual(rows.map(\.text), ["\tif not (exists folder \"Installers and Archives\" of ", "downloadsFolder) then"])
        XCTAssertEqual(rows.map(\.width), [55, 21])

        let path = AppleScriptCodeLayout.wrap("~/Desktop/Screenshots/very-long-folder/end", columns: 24)
        XCTAssertEqual(path.map(\.text), ["~/Desktop/Screenshots/", "very-long-folder/end"])

        XCTAssertEqual(AppleScriptCodeLayout.wrap("ab cdefghijklmnop", columns: 8).map(\.text), ["ab cdefg", "hijklmno", "p"],
                       "a break that would leave less than half a row falls back to the character")
    }

    /// The code box's viewport holds whole rows: everything when it fits, else as many rows as fit.
    func testMonoBoxViewportSnapsToWholeRows() {
        typealias Cap = DockCardChrome.RowSnappedCap
        XCTAssertEqual(Cap.viewportHeight(contentHeight: 51, available: 80, rowHeight: 17), 51, "fits: all of it")
        XCTAssertEqual(Cap.viewportHeight(contentHeight: 374, available: 77, rowHeight: 17), 68, "4 rows, not 4.5")
        XCTAssertEqual(Cap.viewportHeight(contentHeight: 374, available: 68, rowHeight: 17), 68)
        XCTAssertEqual(Cap.viewportHeight(contentHeight: 374, available: 10, rowHeight: 17), 0)
        XCTAssertEqual(Cap.viewportHeight(contentHeight: 374, available: .infinity, rowHeight: 17), 374)
    }

    func testWrapNumbersLinesAndMarksContinuations() {
        let rows = AppleScriptCodeLayout.wrap("abcdefghij\nxy\n\nz", columns: 4)
        XCTAssertEqual(rows.map(\.text), ["abcd", "efgh", "ij\n", "xy\n", "\n", "z"])
        XCTAssertEqual(rows.map(\.lineNumber), [1, nil, nil, 2, 3, 4])
        XCTAssertEqual(rows.map(\.isContinuation), [false, true, true, false, false, false])
        XCTAssertEqual(rows.map(\.displayText), ["abcd", "efgh", "ij", "xy", "", "z"])
        XCTAssertEqual(AppleScriptCodeLayout.lineCount(of: "abcdefghij\nxy\n\nz"), 4)
        XCTAssertEqual(AppleScriptCodeLayout.lineCount(of: "a\nb\n"), 2, "a final terminator adds no line")
        XCTAssertEqual(AppleScriptCodeLayout.lineCount(of: ""), 0)

        let tabs = AppleScriptCodeLayout.wrap("\tab\tc", columns: 8)
        XCTAssertEqual(tabs.map(\.text), ["\tab", "\tc"], "a tab takes four columns")
        XCTAssertEqual(tabs.first?.displayText, "    ab")

        let wide = AppleScriptCodeLayout.wrap("日本語テキスト", columns: 5)
        XCTAssertEqual(wide.map(\.text), ["日本", "語テ", "キス", "ト"], "wide characters take two columns")

        XCTAssertEqual(AppleScriptCodeLayout.wrap("abcdef", columns: 1).map(\.text), ["abcd", "ef"],
                       "never fewer than four columns, so every character fits a row")
    }

    func testReviewFlagForScriptsTallerThanTheBox() {
        let rowHeight = (AppleScriptCodeView.fontSize * 1.35).rounded(.up)
        let short = AppleScriptCodeLayout.wrap("tell application \"Music\" to play", columns: 60)
        XCTAssertFalse(AppleScriptCodeLayout.needsScrollToReview(rowCount: short.count, rowHeight: rowHeight,
                                                                 verticalPadding: 16,
                                                                 maxHeight: AppleScriptCodeView.maxHeight))
        let long = AppleScriptCodeLayout.wrap((1...40).map { "log \($0)" }.joined(separator: "\n"), columns: 60)
        XCTAssertTrue(AppleScriptCodeLayout.needsScrollToReview(rowCount: long.count, rowHeight: rowHeight,
                                                                verticalPadding: 16,
                                                                maxHeight: AppleScriptCodeView.maxHeight))
        let oneLongLine = AppleScriptCodeLayout.wrap(String(repeating: "a", count: 2_000), columns: 60)
        XCTAssertTrue(AppleScriptCodeLayout.needsScrollToReview(rowCount: oneLongLine.count, rowHeight: rowHeight,
                                                                verticalPadding: 16,
                                                                maxHeight: AppleScriptCodeView.maxHeight),
                      "a single wrapped line can overflow too")
        XCTAssertEqual(AppleScriptCodeLayout.reviewFooter(lineCount: 40), "40 lines · scroll to review")
        XCTAssertEqual(AppleScriptCodeLayout.lineCountLabel(1), "1 line")

        XCTAssertTrue(AppleScriptCodeLayout.isLastRowVisible(lastRowMaxY: 150, viewportHeight: 168))
        XCTAssertFalse(AppleScriptCodeLayout.isLastRowVisible(lastRowMaxY: 400, viewportHeight: 168))
        XCTAssertEqual(ApprovalBodyView.needsScrollReview(.appleScript(scriptPreview(source: "beep"))), true)
        XCTAssertEqual(ApprovalBodyView.needsScrollReview(.shortcut(ShortcutPreview(name: "A", input: nil))), false)
    }

    func testAttributedRowsKeepHighlightingAndText() {
        let source = "tell application \"Finder\"\n\t-- a comment that runs long\nend tell"
        let rows = AppleScriptCodeLayout.wrap(source, columns: 12)
        let styled = AppleScriptCodeLayout.attributedRows(AppleScriptHighlighter.highlight(source), rows: rows)
        XCTAssertEqual(styled.count, rows.count)
        XCTAssertEqual(styled.map { String($0.characters) }, rows.map(\.displayText))
        let firstRunColors = styled[0].runs.map(\.swiftUI.foregroundColor)
        XCTAssertTrue(firstRunColors.contains(AppleScriptHighlighter.Palette.keyword))
    }

    func testColumnsFollowTheFont() {
        let columns = AppleScriptCodeLayout.columns(forWidth: 400, fontSize: 12)
        XCTAssertGreaterThan(columns, 40)
        XCTAssertLessThan(columns, 80)
        XCTAssertEqual(AppleScriptCodeLayout.columns(forWidth: 0, fontSize: 12), AppleScriptCodeLayout.tabWidth)
        XCTAssertGreaterThan(AppleScriptCodeLayout.columns(forWidth: 400, fontSize: 10), columns)
    }

    // MARK: - WYSIWYG

    func testApprovalBodyRendersEveryDisplayedString() {
        let calendars = [
            CalendarChoice(id: "home", title: "Home", source: "iCloud", colorRGBA: [0.9, 0.3, 0.2, 1]),
            CalendarChoice(id: "work", title: "Work", source: "Exchange", colorRGBA: nil),
        ]
        var event = makeEvent(calendars: calendars, selected: "home")
        event.location = "1 Main St"
        event.notes = "Bring the insurance card"
        event.calendarHint = "“Wrk” isn't one of your calendars"
        event.conflicts = ["Overlaps with “Team sync” 3:30 PM", "+1 more"]
        event.timeZoneNote = "3:00 PM your time (6:00 PM New York)"
        event.adjustmentNote = "Moved an hour for daylight saving time"

        let longInput = "~/Desktop/Screenshots/" + String(repeating: "very-long-folder-name/", count: 12) + "end"
        let bodies: [ApprovalBody] = [
            .consent(ConsentPreview(symbol: "calendar", title: "Read your calendar",
                                    body: "Event details are sent to Claude to answer.",
                                    footnote: "You can turn this off in Settings.")),
            .text(TextPreview(label: "Message", text: "Hello there\nsecond line", language: nil)),
            .event(event),
            .reminder(ReminderPreview(title: "Drink water", dueLine: "Tomorrow, 9:00 AM", hasAlert: true,
                                      notes: "Two glasses", lists: calendars, selectedListID: "work",
                                      listHint: "Pick a list")),
            .shortcut(ShortcutPreview(name: "Resize Images", input: longInput)),
            .appleScript(scriptPreview(source: "tell application \"Finder\"\n\tactivate\nend tell")),
            .url(URLPreview(url: "https://xn--pple-43d.com/path/to/page?query=1#top", displayHost: "аpple.com",
                            punycodeHost: "xn--pple-43d.com", warnings: ["Looks like apple.com", "Not https"])),
        ]

        for body in bodies {
            let rendered = renderedText(of: body)
            XCTAssertFalse(rendered.isEmpty, "nothing rendered for \(body)")
            for string in body.displayedStrings {
                XCTAssertTrue(rendered.contains { $0.contains(string) },
                              "“\(string)” is not on screen for \(body)\nrendered: \(rendered)")
            }
        }
    }

    // MARK: - Review gating

    func testShortBodyCountsAsReviewedOnAppear() {
        var reviewed = 0
        host(ApprovalCard(approval: makeApproval(body: .shortcut(ShortcutPreview(name: "Log water", input: nil))),
                          options: .constant(ApprovalOptions()), visibleSince: nil,
                          onReviewed: { reviewed += 1 }, onDecision: { _ in XCTFail("no decision without input") }))
        XCTAssertEqual(reviewed, 1)
    }

    /// The approval-applescript-long scene on the 14-inch MacBook Pro (a 287 pt dock): the code box is the card's
    /// only scroller and shows at least three rows of the script. With a caution banner and a provenance line there
    /// is no room for that, so the whole body scrolls with every code row in it, still with one scroller only.
    func testLongScriptCodeIsTheCardsOnlyScroller() {
        let source = (1...22).map { "\tset item\($0) to folder \"Folder \($0)\" of downloadsFolder" }.joined(separator: "\n")
        var preview = scriptPreview(source: source)
        preview.purpose = "Move installers and archives, then images, out of Downloads into two new folders."
        preview.capabilities = []
        preview.inheritedAccess = ["Accessibility", "Screen & System Audio Recording", "Calendars", "Finder"]

        func scrollers(caution: Bool) -> [NSScrollView] {
            let base = makeApproval(body: .appleScript(preview))
            let approval = PendingApproval(
                callID: base.callID, messageID: base.messageID, toolName: "run_applescript", kind: base.kind,
                presentation: base.presentation, body: base.body, confirmLabel: "Run Script", declineLabel: "Don't run",
                provenance: caution ? "Requested after reading example.com" : nil,
                caution: caution ? CautionBanner(headline: "Otto read example.com just before asking.",
                                                 body: "Pages and files can hide instructions. Only continue if you asked for this.")
                    : nil,
                armingDelay: base.armingDelay, presentedAt: base.presentedAt, position: 1, total: 1)
            let card = ApprovalCard(approval: approval, options: .constant(ApprovalOptions()), visibleSince: nil,
                                    onReviewed: {}, onDecision: { _ in })
            let hosting = NSHostingView(rootView: card.frame(width: 548).frame(maxHeight: 287, alignment: .top)
                .background(Theme.panel))
            hosting.frame = NSRect(x: 0, y: 0, width: 548, height: 600)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.close() }
            settle(hosting)
            settle(hosting)
            return scrollViews(in: hosting).filter { scrollView in
                (scrollView.documentView?.frame.height ?? 0) > scrollView.frame.height + 1
            }
        }

        let plain = scrollers(caution: false)
        XCTAssertEqual(plain.count, 1, "one scroller: the code box")
        // The box's padding sits outside its scroller, which is always a whole number of rows tall.
        let rowHeight = (AppleScriptCodeView.fontSize * 1.35).rounded(.up)
        let viewport = plain.first?.frame.height ?? 0
        XCTAssertGreaterThanOrEqual(viewport, 3 * rowHeight, "at least three rows of the script show before any scrolling")
        XCTAssertEqual(viewport.truncatingRemainder(dividingBy: rowHeight), 0, accuracy: 0.5,
                       "the viewport ends between rows, never halfway through one")

        XCTAssertEqual(scrollers(caution: true).count, 1, "never a scroller inside a scroller")
    }

    func testCompactAccessRowKeepsDangerousAccessInSight() {
        let access = ["Calendars", "Accessibility", "Finder", "Screen & System Audio Recording"]
        let variants = ScriptInheritedAccessRow.compactVariants(access)
        XCTAssertEqual(variants.first?.shown, access)
        XCTAssertEqual(variants.first?.showsTrail, true)
        let folded = variants.first { $0.hidden.count == 2 }
        XCTAssertEqual(folded?.shown, ["Accessibility", "Screen & System Audio Recording"])
        XCTAssertEqual(folded.map { ScriptInheritedAccessRow.moreLabel($0.hidden) }, "+2 more")
        XCTAssertEqual(variants.last?.shown, [])
        XCTAssertTrue(ScriptInheritedAccessRow.spokenSummary(access).contains("Calendars, Accessibility, Finder"))
    }

    func testLongScriptIsNotReviewedUntilItsLastRowIsShown() {
        let source = (1...60).map { "log \"step \($0)\"" }.joined(separator: "\n")
        var reviewed = 0
        host(ApprovalCard(approval: makeApproval(body: .appleScript(scriptPreview(source: source))),
                          options: .constant(ApprovalOptions()), visibleSince: nil,
                          onReviewed: { reviewed += 1 }, onDecision: { _ in }))
        XCTAssertEqual(reviewed, 0, "arming can't start while most of the script is out of sight")

        var shortReviewed = 0
        var fitting = scriptPreview(source: "beep")
        fitting.capabilities = []
        fitting.inheritedAccess = []
        host(ApprovalCard(approval: makeApproval(body: .appleScript(fitting)),
                          options: .constant(ApprovalOptions()), visibleSince: nil,
                          onReviewed: { shortReviewed += 1 }, onDecision: { _ in }))
        XCTAssertEqual(shortReviewed, 1, "a script that fits is reviewed as soon as it shows")
    }

    func testANewCallInTheSameCardIsReviewedAgain() {
        let first = makeApproval(body: .shortcut(ShortcutPreview(name: "Log water", input: nil)))
        let model = CardModel(approval: first)
        var reviewed = 0
        let hosting = NSHostingView(rootView: CardHost(model: model, onReviewed: { reviewed += 1 })
            .frame(width: 548).background(Theme.panel))
        hosting.frame = NSRect(x: 0, y: 0, width: 548, height: 600)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        settle(hosting)
        XCTAssertEqual(reviewed, 1)

        model.approval = PendingApproval(callID: "call-2", messageID: first.messageID, toolName: first.toolName,
                                         kind: first.kind, presentation: first.presentation, body: first.body,
                                         confirmLabel: first.confirmLabel, declineLabel: first.declineLabel,
                                         provenance: nil, caution: nil, armingDelay: first.armingDelay,
                                         presentedAt: first.presentedAt, position: 2, total: 2)
        settle(hosting)
        XCTAssertEqual(reviewed, 2, "the next call must be reported as reviewed on its own")
    }

    // MARK: - Helpers

    private func makeCall(status: ToolCallStatus,
                          presentation: ToolCallPresentation = .generic(toolName: "run_shortcut")) -> ToolCall {
        ToolCall(id: "call-1", name: "run_shortcut", input: nil, invalidInput: nil, presentation: presentation,
                 status: status, result: nil, provenance: nil, approvedVia: nil, recovery: nil, undo: nil,
                 progressNote: nil, startedAt: nil, finishedAt: nil)
    }

    private func makeApproval(body: ApprovalBody) -> PendingApproval {
        PendingApproval(callID: "call-1", messageID: UUID(), toolName: "run_shortcut",
                        kind: .approval(rememberScope: nil),
                        presentation: ToolCallPresentation(symbol: "square.stack.3d.up", title: "Run “Log water”",
                                                           activeTitle: "Running…", doneTitle: "Ran",
                                                           detail: nil, disclosure: nil),
                        body: body, confirmLabel: "Run Shortcut", declineLabel: "Don't run", provenance: nil,
                        caution: nil, armingDelay: .milliseconds(350), presentedAt: Date(), position: 1, total: 1)
    }

    private func makeEvent(calendars: [CalendarChoice], selected: String?) -> EventPreview {
        EventPreview(title: "Dentist", weekday: "TUE", day: "29", timeLine: "3:00 – 4:00 PM", location: nil,
                     notes: nil, calendars: calendars, selectedCalendarID: selected, calendarHint: nil,
                     conflicts: [], timeZoneNote: nil, adjustmentNote: nil)
    }

    private func scriptPreview(source: String) -> AppleScriptPreview {
        AppleScriptPreview(purpose: "Bring Finder to the front", source: source,
                           targets: [ScriptChip(label: "Finder", isDanger: false, bundleID: "com.apple.finder")],
                           capabilities: [ScriptChip(label: "Runs shell commands", isDanger: true, bundleID: nil)],
                           lineCount: AppleScriptCodeLayout.lineCount(of: source),
                           inheritedAccess: ["Accessibility", "Calendars"])
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { subview -> [NSScrollView] in
            ((subview as? NSScrollView).map { [$0] } ?? []) + scrollViews(in: subview)
        }
    }

    private func settle(_ hosting: NSView) {
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// Hosts a dock view at dock width in an off-screen window and lets it lay out and appear.
    private func host<V: View>(_ view: V) {
        let hosting = NSHostingView(rootView: view.frame(width: 548).background(Theme.panel))
        hosting.frame = NSRect(x: 0, y: 0, width: 548, height: 600)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// Hosts the body at dock width in an off-screen window with a text recorder, lets it lay out and
    /// appear, and returns every string its views put on screen.
    private func renderedText(of body: ApprovalBody) -> [String] {
        var options = ApprovalOptions()
        let binding = Binding(get: { options }, set: { options = $0 })
        let recorder = ApprovalBodyView.TextRecorder()
        let view = ApprovalBodyView(body: body, options: binding)
            .frame(width: 520)
            .padding(8)
            .background(Theme.panel)
            .environment(\.dockTextRecorder, recorder)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 536, height: 700)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        return recorder.strings
    }
}

@MainActor @Observable
private final class CardModel {
    var approval: PendingApproval

    init(approval: PendingApproval) {
        self.approval = approval
    }
}

/// An approval card whose approval can be swapped in place, like the dock does between calls of a round.
private struct CardHost: View {
    let model: CardModel
    let onReviewed: () -> Void

    var body: some View {
        ApprovalCard(approval: model.approval, options: .constant(ApprovalOptions()), visibleSince: nil,
                     onReviewed: onReviewed, onDecision: { _ in })
    }
}
