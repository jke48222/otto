//
//  AppleScriptRunner.swift
//  Otto
//
//  Runs an approved AppleScript with `/usr/bin/osascript -l AppleScript -`, the source on stdin (never
//  in argv or a temp file), and turns osascript's errors into typed tool errors. Also answers the two
//  questions the run_applescript tool asks about target apps: is it running, and is macOS about to
//  ask the user whether Otto may control it.
//

import AppKit
import CoreServices
import Foundation
import os

/// What running a script produced.
struct ScriptRunResult: Equatable, Sendable {
    /// stdout without trailing line breaks.
    let output: String
    let duration: Duration
}

/// A running app a script targets.
struct ScriptRunningApp: Equatable, Sendable {
    let name: String
    let bundleID: String
}

/// How run_applescript runs scripts and inspects their target apps. Tests and demo mode inject fakes.
protocol AppleScriptRunning: Sendable {
    /// Runs `source` exactly as given. Throws `ToolError` (mapped osascript errors, timeout) or CancellationError.
    func run(_ source: String, timeout: Duration) async throws -> ScriptRunResult
    /// The running app a target names, by bundle identifier or name; nil when it isn't running.
    func runningApp(for target: ScriptTarget) -> ScriptRunningApp?
    /// True while an Apple event from Otto to `bundleID` needs the user's answer (the macOS Automation prompt is
    /// up, or would be). Never prompts.
    func automationConsentPending(bundleID: String) -> Bool
}

struct AppleScriptRunner: AppleScriptRunning {
    static let executable = URL(fileURLWithPath: "/usr/bin/osascript")
    static let arguments = ["-l", "AppleScript", "-"]
    static let defaultTimeout: Duration = .seconds(10)
    static let outputLimit = 1_048_576

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Actions")

    private let runner: any ProcessRunning

    init(runner: any ProcessRunning) {
        self.runner = runner
    }

    func run(_ source: String, timeout: Duration) async throws -> ScriptRunResult {
        let output: ProcessOutput
        do {
            output = try await runner.run(Self.executable, arguments: Self.arguments, stdin: Data(source.utf8),
                                          timeout: timeout, outputLimit: Self.outputLimit)
        } catch let error as CancellationError {
            throw error
        } catch let error as ToolError {
            throw error
        } catch {
            Self.logger.error("osascript didn't start: \(String(describing: error), privacy: .public)")
            throw ToolError(code: .failed, modelMessage: "Otto couldn't start osascript to run the script.",
                            userMessage: "Couldn't start the script")
        }
        try Task.checkCancellation()
        Self.logger.info("osascript exited \(output.exitCode, privacy: .public) timedOut=\(output.timedOut, privacy: .public)")
        guard output.exitCode == 0, !output.timedOut else {
            throw Self.mapError(stderr: output.stderr, exitCode: output.exitCode, timedOut: output.timedOut,
                                source: source, timeout: timeout)
        }
        return ScriptRunResult(output: Self.trimmingTrailingNewlines(output.stdout), duration: output.duration)
    }

    func runningApp(for target: ScriptTarget) -> ScriptRunningApp? {
        guard !target.isDynamic else { return nil }
        let apps = NSWorkspace.shared.runningApplications
        let match: NSRunningApplication?
        if let bundleID = target.bundleID {
            match = apps.first { $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame }
        } else {
            match = apps.first { $0.localizedName?.caseInsensitiveCompare(target.name) == .orderedSame }
        }
        guard let match, !match.isTerminated, let bundleID = match.bundleIdentifier else { return nil }
        return ScriptRunningApp(name: match.localizedName ?? target.name, bundleID: bundleID)
    }

    func automationConsentPending(bundleID: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status: OSStatus = withExtendedLifetime(target) {
            guard let address = target.aeDesc else { return OSStatus(procNotFound) }
            return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, false)
        }
        return Int(status) == errAEEventWouldRequireUserConsent
    }

    // MARK: - Error mapping (pure)

    /// Maps osascript's stderr to a typed error. Understands `execution error: ‹message› (‹code›)` and
    /// `‹start›:‹end›: syntax error: ‹message›`, where start/end are character offsets into `source`.
    static func mapError(stderr: String, exitCode: Int32, timedOut: Bool = false, source: String = "",
                         timeout: Duration = defaultTimeout) -> ToolError {
        if timedOut {
            let seconds = Int(timeout.timeInterval.rounded())
            return ToolError(code: .timeout,
                             modelMessage: "The script didn't finish within \(seconds) seconds and was stopped. "
                                 + "If macOS asked for permission, the user can try again.",
                             userMessage: "Stopped after \(seconds) s")
        }
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if let syntax = parseSyntaxError(text) {
            let line = syntax.offset.flatMap { lineNumber(atOffset: $0, in: source) }
            let location = line.map { " at line \($0)" } ?? ""
            return ToolError(code: .invalidInput, modelMessage: "Syntax error\(location): \(syntax.message)",
                             userMessage: "Syntax error\(location)")
        }

        guard let execution = parseExecutionError(text) else {
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init)
            let message = firstLine ?? "osascript exited with status \(exitCode)"
            return ToolError(code: .failed, modelMessage: message, userMessage: "Script failed: \(shortened(message))")
        }

        let message = execution.message
        let code = execution.code
        let lowered = message.lowercased()
        if code == -1743 {
            let app = appName(inNotAuthorizedMessage: message) ?? "the app"
            let bundleID = ScriptKnownApps.bundleID(forName: app) ?? ""
            return ToolError(code: .permissionDenied,
                             modelMessage: "macOS isn't letting Otto control \(app). The user can allow it in "
                                 + "System Settings → Privacy & Security → Automation → Otto.",
                             userMessage: "Automation for \(app) is off",
                             recovery: .openSystemSettings(.automation(bundleID: bundleID, appName: app)))
        }
        if code == -1719 || code == -25211 || lowered.contains("assistive access") {
            return ToolError(code: .permissionDenied,
                             modelMessage: "macOS requires Accessibility access for Otto to control other apps' "
                                 + "interfaces.",
                             userMessage: "Accessibility access is off",
                             recovery: .openSystemSettings(.accessibility))
        }
        switch code {
        case -1728:
            return ToolError(code: .failed,
                             modelMessage: "\(message) (-1728: the script referred to something that doesn't exist)",
                             userMessage: "Script failed: \(shortened(message))")
        case -1712:
            return ToolError(code: .timeout, modelMessage: "The app didn't answer in time.",
                             userMessage: "The app didn't answer in time")
        case -600:
            let app = appName(beforeGotAnError: message) ?? "The app"
            return ToolError(code: .notRunning, modelMessage: "\(app) isn't running.",
                             userMessage: "\(app) isn't running")
        case -128:
            return ToolError(code: .declined, modelMessage: "The user cancelled a dialog the script showed.",
                             userMessage: "You cancelled the script's dialog")
        default:
            let codeText = code.map { " (\($0))" } ?? ""
            return ToolError(code: .failed, modelMessage: "\(message)\(codeText)",
                             userMessage: "Script failed: \(shortened(message))")
        }
    }

    private static func parseSyntaxError(_ text: String) -> (offset: Int?, message: String)? {
        let pattern = #"^(?:(\d+):(\d+):\s*)?syntax error:\s*(.*?)(?:\s*\((-?\d+)\))?\s*$"#
        guard let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init),
              let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: firstLine, range: NSRange(firstLine.startIndex..., in: firstLine))
        else { return nil }
        let offset = group(1, of: result, in: firstLine).flatMap { Int($0) }
        let message = group(3, of: result, in: firstLine) ?? ""
        return (offset, message.isEmpty ? "The script couldn't be compiled." : message)
    }

    private static func parseExecutionError(_ text: String) -> (message: String, code: Int?)? {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        let pattern = #"execution error:\s*(.*?)\s*(?:\((-?\d+)\))?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: flattened, range: NSRange(flattened.startIndex..., in: flattened))
        else { return nil }
        let message = group(1, of: result, in: flattened) ?? ""
        let code = group(2, of: result, in: flattened).flatMap { Int($0) }
        return (message.isEmpty ? "The script failed." : message, code)
    }

    private static func group(_ index: Int, of result: NSTextCheckingResult, in text: String) -> String? {
        guard index < result.numberOfRanges, let range = Range(result.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    /// 1-based line of a UTF-16 offset into `source`; nil when the source isn't known.
    private static func lineNumber(atOffset offset: Int, in source: String) -> Int? {
        guard !source.isEmpty else { return nil }
        var line = 1
        var previous: UInt16 = 0
        for (position, unit) in source.utf16.enumerated() {
            guard position < offset else { break }
            if unit == 0x0A, previous != 0x0D { line += 1 }
            if unit == 0x0D { line += 1 }
            previous = unit
        }
        return line
    }

    /// "Not authorized to send Apple events to Finder." → "Finder".
    private static func appName(inNotAuthorizedMessage message: String) -> String? {
        guard let range = message.range(of: "send Apple events to ", options: .caseInsensitive) else { return nil }
        let name = message[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return name.isEmpty ? nil : DisplayText.sanitized(name, maxLength: 60)
    }

    /// "Finder got an error: Application isn't running." → "Finder".
    private static func appName(beforeGotAnError message: String) -> String? {
        guard let range = message.range(of: " got an error", options: .caseInsensitive) else { return nil }
        let name = String(message[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : DisplayText.sanitized(name, maxLength: 60)
    }

    private static func shortened(_ message: String) -> String {
        DisplayText.sanitized(message, maxLength: 120)
    }

    static func trimmingTrailingNewlines(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, last.isNewline { result.removeLast() }
        return String(result)
    }
}
