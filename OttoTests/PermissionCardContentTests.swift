//
//  PermissionCardContentTests.swift
//  OttoTests
//
//  The permission card copy table: exact words and buttons for every reason Otto asks, every phase of the
//  flow and every status, and the rule that only "Quit & Reopen Otto" needs ⌘↩.
//

import XCTest
@testable import Otto

final class PermissionCardContentTests: XCTestCase {
    private let music = Permission.automation(bundleID: "com.apple.Music", appName: "Music")

    private var allPurposes: [PermissionPurpose] {
        [.paste(appName: "Notes"), .selection(appName: "Notes"), .windowCapture(appName: "Safari"), .voice,
         .nowPlayingControl(appName: "Music"), .notifications, .calendarGlance,
         .tool(title: "Add “Dentist” to Calendar", dataFlow: "Event details are sent to Claude to answer."),
         .tool(title: "Add “Dentist” to Calendar", dataFlow: nil)]
    }
    private let allPhases: [PermissionPrompt.Phase] = [.explain, .waiting, .needsRelaunch, .granted]
    private let allStatuses: [PermissionStatus] = [.granted, .notDetermined, .denied, .restricted, .limited,
                                                   .needsRelaunch, .unavailable]
    private var allPermissions: [Permission] { Permission.systemWide + [music] }

    // MARK: - Explain, per purpose

    func testPasteExplainCopy() {
        let content = make(.accessibility, .paste(appName: "Notes"), .explain, .notDetermined)
        XCTAssertEqual(content.symbol, "hand.point.up.left")
        XCTAssertEqual(content.title, "Let Otto paste for you")
        XCTAssertEqual(content.body, "To put answers straight into **Notes**, allow Otto under Accessibility. Otto only "
                       + "uses it when you ask: to press ⌘V for you and to read text you've selected. Never in the "
                       + "background.")
        XCTAssertEqual(content.steps, "System Settings → Privacy & Security → Accessibility")
        assertButtons(content, primary: ("Continue…", .request), secondary: ("Just Copy", .justCopy))
        XCTAssertFalse(content.showsSpinner)

        let denied = make(.accessibility, .paste(appName: "Notes"), .explain, .denied)
        assertButtons(denied, primary: ("Open System Settings", .openSystemSettings), secondary: ("Just Copy", .justCopy))
    }

    func testSelectionExplainCopy() {
        let content = make(.accessibility, .selection(appName: "Pages"), .explain, .notDetermined)
        XCTAssertEqual(content.title, "Let Otto see your selection")
        XCTAssertEqual(content.body, "To offer the text you've highlighted in **Pages**, allow Otto under Accessibility. "
                       + "Otto reads it only when you open the notch, never sends it until you do, and always skips "
                       + "password fields.")
        assertButtons(content, primary: ("Continue…", .request), secondary: ("Not Now", .dismiss))
        let denied = make(.accessibility, .selection(appName: "Pages"), .explain, .denied)
        assertButtons(denied, primary: ("Open System Settings", .openSystemSettings), secondary: ("Not Now", .dismiss))
    }

    func testWindowCaptureExplainCopy() {
        let content = make(.screenRecording, .windowCapture(appName: "Safari"), .explain, .notDetermined)
        XCTAssertEqual(content.symbol, "macwindow")
        XCTAssertEqual(content.title, "Let Otto see Safari's window")
        XCTAssertEqual(content.body, "To attach a picture of a window, allow Otto under Screen & System Audio Recording. "
                       + "Otto captures a window only when you tap it, and the picture goes nowhere until you send.")
        XCTAssertEqual(content.steps, "System Settings → Privacy & Security → Screen & System Audio Recording")
        assertButtons(content, primary: ("Continue…", .request), secondary: ("Not Now", .dismiss))
    }

    func testVoiceExplainCopy() {
        let microphone = make(.microphone, .voice, .explain, .denied)
        XCTAssertEqual(microphone.symbol, "mic")
        XCTAssertEqual(microphone.title, "Otto can't hear you yet")
        XCTAssertEqual(microphone.body, "Allow Microphone and Speech Recognition for Otto. Otto listens only while you "
                       + "hold the shortcut or the mic, and turns your words into text on this Mac.")
        XCTAssertEqual(microphone.steps, "System Settings → Privacy & Security → Microphone")
        assertButtons(microphone, primary: ("Open System Settings", .openSystemSettings), secondary: ("Not Now", .dismiss))

        let speech = make(.speechRecognition, .voice, .explain, .denied)
        XCTAssertEqual(speech.symbol, "waveform")
        XCTAssertEqual(speech.steps, "System Settings → Privacy & Security → Speech Recognition")
    }

    func testNowPlayingControlExplainCopy() {
        let content = make(music, .nowPlayingControl(appName: "Music"), .explain, .notDetermined)
        XCTAssertEqual(content.symbol, "playpause")
        XCTAssertEqual(content.title, "Let Otto control Music")
        XCTAssertEqual(content.body, "Otto sends play, pause and skip only when you press these buttons. macOS will ask "
                       + "you next.")
        XCTAssertEqual(content.steps, "System Settings → Privacy & Security → Automation")
        assertButtons(content, primary: ("Continue…", .request), secondary: ("Not Now", .dismiss))
    }

    func testNotificationsExplainCopy() {
        let content = make(.notifications, .notifications, .explain, .notDetermined)
        XCTAssertEqual(content.symbol, "bell")
        XCTAssertEqual(content.title, "Let Otto notify you")
        XCTAssertEqual(content.body, "Otto posts a notification only when a reply finishes (or needs your OK) while you "
                       + "can't see the notch.")
        XCTAssertEqual(content.steps, "System Settings → Notifications")
        assertButtons(content, primary: ("Continue…", .request), secondary: ("Not Now", .dismiss))
    }

    func testCalendarGlanceExplainCopy() {
        let content = make(.calendars, .calendarGlance, .explain, .notDetermined)
        XCTAssertEqual(content.symbol, "calendar")
        XCTAssertEqual(content.title, "Show your next meeting")
        XCTAssertEqual(content.body, "Otto reads your calendars to show your next meeting in the notch. Nothing is sent "
                       + "to Claude.")
        XCTAssertEqual(content.steps, "System Settings → Privacy & Security → Calendars")
        assertButtons(content, primary: ("Continue…", .request), secondary: ("Not Now", .dismiss))
        // Write-only access can be upgraded from the system prompt.
        assertButtons(make(.calendars, .calendarGlance, .explain, .limited), primary: ("Continue…", .request),
                      secondary: ("Not Now", .dismiss))
    }

    func testToolExplainCopy() {
        let read = make(.calendars, .tool(title: "Add “Dentist” to Calendar",
                                          dataFlow: "Event details are sent to Claude to answer."), .explain, .notDetermined)
        XCTAssertEqual(read.symbol, "lock.shield")
        XCTAssertEqual(read.title, "Otto needs Calendars access")
        XCTAssertEqual(read.body, "To add “Dentist” to Calendar, allow Otto under Calendars. Event details are sent to "
                       + "Claude to answer.")
        XCTAssertEqual(read.steps, "System Settings → Privacy & Security → Calendars")
        assertButtons(read, primary: ("Continue…", .request), secondary: ("Not Now", .dismiss))

        let write = make(.reminders, .tool(title: "Add “Milk” to Reminders", dataFlow: nil), .explain, .denied)
        XCTAssertEqual(write.title, "Otto needs Reminders access")
        XCTAssertEqual(write.body, "To add “Milk” to Reminders, allow Otto under Reminders.")
        assertButtons(write, primary: ("Open System Settings", .openSystemSettings), secondary: ("Not Now", .dismiss))

        let automation = make(music, .tool(title: "Play Music", dataFlow: nil), .explain, .notDetermined)
        XCTAssertEqual(automation.title, "Otto needs Automation (Music) access")
        XCTAssertEqual(automation.body, "To play Music, allow Otto under Automation.")
    }

    func testToolTitleKeepsLeadingAcronymsAndEscapesMarkdown() {
        let acronym = make(.accessibility, .tool(title: "URL of the front tab", dataFlow: nil), .explain, .notDetermined)
        XCTAssertEqual(acronym.body, "To URL of the front tab, allow Otto under Accessibility.")

        let marked = make(.calendars, .tool(title: "Add *bold* [link](x)", dataFlow: nil), .explain, .notDetermined)
        XCTAssertEqual(marked.body, #"To add \*bold\* \[link\](x), allow Otto under Calendars."#)
    }

    func testAppNamesAreSanitizedAndEscaped() {
        let content = make(.accessibility, .paste(appName: "Note\u{202E}s_*\n"), .explain, .notDetermined)
        XCTAssertTrue(content.body.hasPrefix(#"To put answers straight into **Notes\_\***, allow"#), content.body)

        let long = String(repeating: "A", count: 200)
        let title = make(.screenRecording, .windowCapture(appName: long), .explain, .notDetermined).title
        XCTAssertLessThanOrEqual(title.count, "Let Otto see 's window".count + 60)
    }

    // MARK: - Phases

    func testWaitingCopy() {
        for permission in allPermissions where permission != .notifications {
            let content = make(permission, .calendarGlance, .waiting, .denied)
            XCTAssertEqual(content.title, "Waiting for System Settings…")
            XCTAssertTrue(content.showsSpinner)
            XCTAssertEqual(content.body, "Turn on **Otto** in Privacy & Security → \(permission.settingsPaneName). Otto "
                           + "will pick up where you left off.")
            XCTAssertEqual(content.steps, "System Settings → Privacy & Security → \(permission.settingsPaneName)")
            assertButtons(content, primary: ("Open System Settings", .openSystemSettings), secondary: ("Cancel", .dismiss))
        }
        let notifications = make(.notifications, .notifications, .waiting, .denied)
        XCTAssertEqual(notifications.body, "Allow notifications for **Otto** in System Settings → Notifications. Otto "
                       + "will pick up where you left off.")
        assertButtons(notifications, primary: ("Open System Settings", .openSystemSettings),
                      secondary: ("Cancel", .dismiss))
    }

    func testNeedsRelaunchCopy() {
        let content = make(.screenRecording, .windowCapture(appName: "Safari"), .needsRelaunch, .denied)
        XCTAssertEqual(content.title, "One more step")
        XCTAssertEqual(content.body, "If you just turned Otto on, macOS needs Otto to reopen before it can see windows. "
                       + "Your conversation is saved if History is on.")
        XCTAssertEqual(content.steps, "System Settings → Privacy & Security → Screen & System Audio Recording")
        assertButtons(content, primary: ("Quit & Reopen Otto", .relaunch),
                      secondary: ("Open System Settings", .openSystemSettings))
        XCTAssertTrue(content.primaryRequiresCommand)
        XCTAssertFalse(content.showsSpinner)

        // The status alone is enough: a waiting card whose status turned needsRelaunch offers the relaunch.
        XCTAssertEqual(make(.screenRecording, .windowCapture(appName: "Safari"), .waiting, .needsRelaunch), content)
        XCTAssertEqual(make(.screenRecording, .windowCapture(appName: "Safari"), .explain, .needsRelaunch), content)
    }

    func testGrantedCopy() {
        for purpose in allPurposes {
            for status in allStatuses {
                let content = make(.calendars, purpose, .granted, status)
                XCTAssertEqual(content.symbol, "checkmark.circle.fill")
                XCTAssertEqual(content.title, "You're all set")
                XCTAssertEqual(content.body, "")
                XCTAssertNil(content.steps)
                XCTAssertNil(content.primaryTitle)
                XCTAssertNil(content.primaryAction)
                XCTAssertEqual(content.secondaryTitle, "")
                XCTAssertFalse(content.showsSpinner)
            }
        }
    }

    func testRestrictedVariant() {
        for purpose in allPurposes {
            for phase in [PermissionPrompt.Phase.explain, .waiting, .needsRelaunch] {
                let content = make(.calendars, purpose, phase, .restricted)
                let explain = make(.calendars, purpose, .explain, .notDetermined)
                XCTAssertEqual(content.title, explain.title)
                XCTAssertEqual(content.symbol, explain.symbol)
                XCTAssertEqual(content.body, "This permission is managed by your organization.")
                XCTAssertNil(content.steps)
                XCTAssertNil(content.primaryTitle)
                XCTAssertNil(content.primaryAction)
                XCTAssertEqual(content.secondaryTitle, "OK")
                XCTAssertEqual(content.secondaryAction, .dismiss)
                XCTAssertFalse(content.showsSpinner)
            }
        }
    }

    // MARK: - Whole table

    func testEveryCombinationIsCompleteAndOnlyRelaunchNeedsCommand() {
        for permission in allPermissions {
            for purpose in allPurposes {
                for phase in allPhases {
                    for status in allStatuses {
                        let content = make(permission, purpose, phase, status)
                        let label = "\(permission) \(purpose) \(phase) \(status)"
                        XCTAssertFalse(content.title.isEmpty, label)
                        XCTAssertFalse(content.symbol.isEmpty, label)
                        XCTAssertEqual(content.primaryTitle == nil, content.primaryAction == nil, label)
                        XCTAssertEqual(content.primaryRequiresCommand, content.primaryAction == .relaunch, label)
                        let isRelaunchStep = phase != .granted && status != .restricted
                            && (phase == .needsRelaunch || status == .needsRelaunch)
                        XCTAssertEqual(content.primaryRequiresCommand, isRelaunchStep, label)
                        if phase != .granted {
                            XCTAssertFalse(content.body.isEmpty, label)
                            XCTAssertFalse(content.secondaryTitle.isEmpty, label)
                        }
                        XCTAssertFalse(content.title.contains("‹") || content.body.contains("‹"), label)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func make(_ permission: Permission, _ purpose: PermissionPurpose, _ phase: PermissionPrompt.Phase,
                      _ status: PermissionStatus) -> PermissionCardContent {
        PermissionCardContent.make(permission: permission, purpose: purpose, phase: phase, status: status)
    }

    private func assertButtons(_ content: PermissionCardContent,
                               primary: (String, PermissionCardAction),
                               secondary: (String, PermissionCardAction),
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(content.primaryTitle, primary.0, file: file, line: line)
        XCTAssertEqual(content.primaryAction, primary.1, file: file, line: line)
        XCTAssertEqual(content.secondaryTitle, secondary.0, file: file, line: line)
        XCTAssertEqual(content.secondaryAction, secondary.1, file: file, line: line)
        XCTAssertEqual(content.primaryRequiresCommand, primary.1 == .relaunch, file: file, line: line)
    }
}
