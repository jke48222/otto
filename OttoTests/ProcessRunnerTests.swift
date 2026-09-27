//
//  ProcessRunnerTests.swift
//  OttoTests
//
//  The child-process runner: output, stdin and exit codes, the minimal environment (no
//  ANTHROPIC_API_KEY), the private working folder, output caps, and that a timeout or a cancel kills
//  the whole process group, background children included. Runs only /bin and /usr/bin tools.
//

import Darwin
import XCTest
@testable import Otto

final class ProcessRunnerTests: XCTestCase {
    private let runner = ProcessRunner()
    private let shell = URL(fileURLWithPath: "/bin/sh")

    private func sh(_ script: String, stdin: Data? = nil, timeout: Duration = .seconds(10),
                    outputLimit: Int = 1_048_576) async throws -> ProcessOutput {
        try await runner.run(shell, arguments: ["-c", script], stdin: stdin, timeout: timeout, outputLimit: outputLimit)
    }

    /// Waits up to `seconds` for no process to be left in `group` (kill(-pgid, 0) fails with ESRCH).
    private func groupIsGone(_ group: pid_t, within seconds: Double = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if killpg(group, 0) != 0, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func processIsGone(_ pid: pid_t, within seconds: Double = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    // MARK: - Basics

    func testStdoutStderrAndExitCode() async throws {
        let output = try await sh("echo hello; echo oops >&2; exit 3")
        XCTAssertEqual(output.stdout, "hello\n")
        XCTAssertEqual(output.stderr, "oops\n")
        XCTAssertEqual(output.exitCode, 3)
        XCTAssertFalse(output.timedOut)
        XCTAssertLessThan(output.duration, .seconds(5))
    }

    func testStdinIsWrittenAndClosed() async throws {
        let text = String(repeating: "line of input\n", count: 20_000)
        let output = try await runner.run(URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: Data(text.utf8),
                                          timeout: .seconds(10), outputLimit: 1_048_576)
        XCTAssertEqual(output.stdout, text)
        XCTAssertEqual(output.exitCode, 0)

        let noInput = try await runner.run(URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: nil,
                                           timeout: .seconds(5), outputLimit: 1_024)
        XCTAssertEqual(noInput.stdout, "", "stdin is closed at once when there is nothing to send")
        XCTAssertFalse(noInput.timedOut)
    }

    func testSignalledExitCode() async throws {
        let output = try await sh("kill -9 $$")
        XCTAssertEqual(output.exitCode, 128 + SIGKILL)
    }

    func testRelativePathIsRefused() async throws {
        let relative = try XCTUnwrap(URL(string: "bin/echo"))
        do {
            _ = try await runner.run(relative, arguments: [], stdin: nil, timeout: .seconds(1), outputLimit: 10)
            XCTFail("a relative path must not run")
        } catch let failure as ProcessRunner.Failure {
            XCTAssertEqual(failure, .notAbsolutePath("bin/echo"))
        }
    }

    func testMissingExecutableFailsToSpawn() async throws {
        do {
            _ = try await runner.run(URL(fileURLWithPath: "/usr/bin/otto-does-not-exist"), arguments: [], stdin: nil,
                                     timeout: .seconds(1), outputLimit: 10)
            XCTFail("expected a spawn failure")
        } catch let failure as ProcessRunner.Failure {
            XCTAssertEqual(failure, .spawnFailed(errno: ENOENT))
        }
    }

    // MARK: - Environment

    func testEnvironmentIsMinimalAndHasNoAPIKey() async throws {
        setenv("ANTHROPIC_API_KEY", "sk-ant-test-should-not-leak", 1)
        setenv("OTTO_TEST_INHERITED", "1", 1)
        defer {
            unsetenv("ANTHROPIC_API_KEY")
            unsetenv("OTTO_TEST_INHERITED")
        }
        let output = try await runner.run(URL(fileURLWithPath: "/usr/bin/env"), arguments: [], stdin: nil,
                                          timeout: .seconds(5), outputLimit: 65_536)
        let variables = Set(output.stdout.split(separator: "\n").map { String($0.split(separator: "=")[0]) })
        XCTAssertEqual(variables, ["PATH", "HOME", "USER", "LANG", "TMPDIR"])
        XCTAssertFalse(output.stdout.contains("ANTHROPIC_API_KEY"))
        XCTAssertFalse(output.stdout.contains("sk-ant-test"))
        XCTAssertTrue(output.stdout.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin\n"))
        XCTAssertTrue(output.stdout.contains("LANG=en_US.UTF-8\n"))
    }

    func testPrivateWorkingFolderIsTMPDIRAndIsRemoved() async throws {
        let output = try await sh("pwd -P; echo \"$TMPDIR\"; /usr/bin/stat -f %Lp .")
        let lines = output.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        let folder = lines[0]
        XCTAssertTrue(folder.contains("otto-process-"))
        XCTAssertTrue(lines[1].hasSuffix("/"))
        XCTAssertTrue(URL(fileURLWithPath: lines[1]).resolvingSymlinksInPath().path.hasSuffix(
            URL(fileURLWithPath: folder).lastPathComponent))
        XCTAssertEqual(lines[2], "700")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder), "the folder is removed afterwards")
    }

    // MARK: - Limits

    func testOutputIsCappedAndTheRestDrained() async throws {
        let output = try await sh("head -c 300000 /dev/zero | tr '\\0' a; head -c 300000 /dev/zero | tr '\\0' b >&2",
                                  outputLimit: 1_000)
        XCTAssertEqual(output.stdout, String(repeating: "a", count: 1_000))
        XCTAssertEqual(output.stderr, String(repeating: "b", count: 1_000))
        XCTAssertEqual(output.exitCode, 0, "the child never blocked on a full pipe")
        XCTAssertFalse(output.timedOut)
    }

    func testTimeoutKillsTheWholeProcessGroup() async throws {
        let started = ContinuousClock.now
        // sh prints its pid (= the group id) and the background sleep's pid, then waits on the foreground sleep.
        let output = try await sh("echo $$; sleep 30 & echo $!; sleep 30", timeout: .seconds(1))
        XCTAssertTrue(output.timedOut)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(8))
        let pids = output.stdout.split(separator: "\n").compactMap { pid_t(String($0)) }
        XCTAssertEqual(pids.count, 2)
        guard pids.count == 2 else { return }
        let groupGone = await groupIsGone(pids[0])
        XCTAssertTrue(groupGone, "every process in the group was killed")
        let backgroundGone = await processIsGone(pids[1])
        XCTAssertTrue(backgroundGone, "the background sleep died too")
    }

    func testCancellationKillsTheProcessGroupAndThrows() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("otto-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let task = Task {
            try await self.sh("echo $$ > '\(pidFile.path)'; sleep 30 & sleep 30", timeout: .seconds(60))
        }
        var group: pid_t?
        let deadline = Date().addingTimeInterval(5)
        while group == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            let text = try? String(contentsOf: pidFile, encoding: .utf8)
            group = text.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled run throws")
        } catch is CancellationError {}
        let pgid = try XCTUnwrap(group)
        let gone = await groupIsGone(pgid)
        XCTAssertTrue(gone)
    }

    func testABackgroundChildHoldingThePipeDoesNotHangTheRun() async throws {
        let started = ContinuousClock.now
        let output = try await sh("echo started; sleep 5 &")
        XCTAssertEqual(output.stdout, "started\n")
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(4))
    }

    func testAlreadyCancelledTaskNeverSpawns() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("otto-never-\(UUID().uuidString)")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.sh("touch '\(marker.path)'")
        }
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
