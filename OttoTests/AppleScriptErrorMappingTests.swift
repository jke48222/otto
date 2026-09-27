//
//  AppleScriptErrorMappingTests.swift
//  OttoTests
//
//  osascript's stderr → typed tool errors (actions.md §5.7 table), and the runner's process contract:
//  `/usr/bin/osascript -l AppleScript -` with the source on stdin, through a fake process runner.
//

import XCTest
@testable import Otto

final class AppleScriptErrorMappingTests: XCTestCase {
    private func map(_ stderr: String, source: String = "") -> ToolError {
        AppleScriptRunner.mapError(stderr: stderr, exitCode: 1, source: source)
    }

    func testAutomationDenied() {
        let error = map("0:44: execution error: Not authorized to send Apple events to Finder. (-1743)")
        XCTAssertEqual(error.code, .permissionDenied)
        XCTAssertEqual(error.toolResultText,
                       "permission_denied: macOS isn't letting Otto control Finder. The user can allow it in System "
                           + "Settings → Privacy & Security → Automation → Otto.")
        XCTAssertEqual(error.recovery, .openSystemSettings(.automation(bundleID: "com.apple.finder", appName: "Finder")))
    }

    func testAccessibilityRequired() {
        for stderr in [
            "12:40: execution error: System Events got an error: Otto is not allowed assistive access. (-1719)",
            "execution error: System Events got an error: osascript is not allowed to send keystrokes. (-25211)",
        ] {
            let error = map(stderr)
            XCTAssertEqual(error.code, .permissionDenied, stderr)
            XCTAssertEqual(error.modelMessage,
                           "macOS requires Accessibility access for Otto to control other apps' interfaces.")
            XCTAssertEqual(error.recovery, .openSystemSettings(.accessibility))
        }
    }

    func testCantGetObject() {
        let error = map("0:30: execution error: Finder got an error: Can’t get file \"x\". (-1728)")
        XCTAssertEqual(error.code, .failed)
        XCTAssertTrue(error.modelMessage.hasPrefix("Finder got an error: Can’t get file \"x\"."))
        XCTAssertTrue(error.modelMessage.contains("-1728"))
        XCTAssertTrue(error.userMessage.hasPrefix("Script failed: Finder got an error"))
    }

    func testAppDidNotAnswer() {
        let error = map("execution error: Music got an error: AppleEvent timed out. (-1712)")
        XCTAssertEqual(error.toolResultText, "timeout: The app didn't answer in time.")
    }

    func testAppNotRunning() {
        let error = map("0:20: execution error: Spotify got an error: Application isn’t running. (-600)")
        XCTAssertEqual(error.toolResultText, "not_running: Spotify isn't running.")
    }

    func testUserCancelledDialog() {
        let error = map("0:25: execution error: User canceled. (-128)")
        XCTAssertEqual(error.toolResultText, "declined: The user cancelled a dialog the script showed.")
    }

    func testSyntaxErrorReportsTheLine() {
        let source = "tell application \"Finder\"\n  get name of\nend tell"
        let offset = source.utf16.count - 8
        let error = map("\(offset):\(offset + 3): syntax error: Expected expression but found “end”. (-2741)",
                        source: source)
        XCTAssertEqual(error.code, .invalidInput)
        XCTAssertEqual(error.modelMessage, "Syntax error at line 3: Expected expression but found “end”.")
    }

    func testSyntaxErrorWithoutSource() {
        let error = map("0:3: syntax error: A unknown token can’t go here. (-2740)")
        XCTAssertEqual(error.modelMessage, "Syntax error: A unknown token can’t go here.")
    }

    func testTimeoutKill() {
        let error = AppleScriptRunner.mapError(stderr: "", exitCode: 15, timedOut: true)
        XCTAssertEqual(error.toolResultText,
                       "timeout: The script didn't finish within 10 seconds and was stopped. If macOS asked for "
                           + "permission, the user can try again.")
    }

    func testOtherErrors() {
        let error = map("0:10: execution error: The variable x is not defined. (-2753)")
        XCTAssertEqual(error.toolResultText, "failed: The variable x is not defined. (-2753)")
        let unknown = map("something odd happened\nsecond line")
        XCTAssertEqual(unknown.toolResultText, "failed: something odd happened")
        let empty = AppleScriptRunner.mapError(stderr: "", exitCode: 3)
        XCTAssertEqual(empty.toolResultText, "failed: osascript exited with status 3")
    }

    // MARK: - Runner

    func testRunnerSendsTheSourceOnStdin() async throws {
        let fake = FakeProcessRunner(defaultOutput: ProcessOutput(stdout: "Macintosh HD\n\n", stderr: "", exitCode: 0,
                                                                  timedOut: false, duration: .milliseconds(40)))
        let runner = AppleScriptRunner(runner: fake)
        let source = "tell application \"Finder\" to get name of startup disk"
        let result = try await runner.run(source, timeout: .seconds(10))

        XCTAssertEqual(result, ScriptRunResult(output: "Macintosh HD", duration: .milliseconds(40)))
        let invocation = try XCTUnwrap(fake.invocations.first)
        XCTAssertEqual(invocation.executable.path, "/usr/bin/osascript")
        XCTAssertEqual(invocation.arguments, ["-l", "AppleScript", "-"])
        XCTAssertEqual(invocation.stdin, Data(source.utf8))
        XCTAssertEqual(invocation.timeout, .seconds(10))
        XCTAssertFalse(invocation.arguments.contains(source), "the source never goes in argv")
    }

    func testRunnerMapsFailures() async {
        let fake = FakeProcessRunner(defaultOutput: ProcessOutput(
            stdout: "", stderr: "0:25: execution error: User canceled. (-128)\n", exitCode: 1, timedOut: false,
            duration: .milliseconds(5)))
        do {
            _ = try await AppleScriptRunner(runner: fake).run("display dialog \"x\"", timeout: .seconds(10))
            XCTFail("expected an error")
        } catch let error as ToolError {
            XCTAssertEqual(error.code, .declined)
        } catch {
            XCTFail("unexpected \(error)")
        }

        fake.setOutput(ProcessOutput(stdout: "", stderr: "", exitCode: 15, timedOut: true, duration: .seconds(10)),
                       for: "/usr/bin/osascript")
        do {
            _ = try await AppleScriptRunner(runner: fake).run("delay 30", timeout: .seconds(10))
            XCTFail("expected an error")
        } catch let error as ToolError {
            XCTAssertEqual(error.code, .timeout)
        } catch {
            XCTFail("unexpected \(error)")
        }

        struct SpawnFailure: Error {}
        fake.setError(SpawnFailure())
        do {
            _ = try await AppleScriptRunner(runner: fake).run("beep", timeout: .seconds(10))
            XCTFail("expected an error")
        } catch let error as ToolError {
            XCTAssertEqual(error.code, .failed)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
