//
//  ProcessRunner.swift
//  Otto
//
//  Runs one child process for the action tools (shortcuts, osascript, tccutil): an absolute path, no
//  shell, a minimal explicit environment without the API key, a private temp folder as its working
//  directory, and its own process group, so a timeout or a Stop kills everything it started
//  (SIGTERM to the group, then SIGKILL a second later). stdout and stderr are drained at the same time
//  and capped; the rest is read and thrown away so the child never blocks on a full pipe.
//

import Darwin
import Foundation
import os

struct ProcessRunner: ProcessRunning {
    /// Why a process couldn't be started. Once it has started, a run always returns a `ProcessOutput`
    /// (or throws CancellationError when the task was cancelled).
    enum Failure: Error, Equatable, LocalizedError {
        case notAbsolutePath(String)
        case setupFailed(String, errno: Int32)
        case spawnFailed(errno: Int32)

        var errorDescription: String? {
            switch self {
            case .notAbsolutePath(let path):
                return "Otto only runs programs by absolute path (\(path) isn't one)."
            case .setupFailed(let step, let code):
                return "Otto couldn't prepare the process (\(step): \(String(cString: strerror(code))))."
            case .spawnFailed(let code):
                return "Otto couldn't start the process (\(String(cString: strerror(code))))."
            }
        }
    }

    /// The whole environment a child gets (plus HOME, USER and TMPDIR). Nothing is inherited from Otto.
    static let searchPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    static let locale = "en_US.UTF-8"
    /// Time between SIGTERM and SIGKILL to the process group.
    static let killGrace: DispatchTimeInterval = .seconds(1)
    /// How long the pipes may stay open after the process exits (a background child can hold them).
    static let drainGrace: DispatchTimeInterval = .seconds(1)

    init() {}

    func run(_ executable: URL, arguments: [String], stdin: Data?, timeout: Duration,
             outputLimit: Int) async throws -> ProcessOutput {
        guard executable.isFileURL, executable.path.hasPrefix("/") else {
            throw Failure.notAbsolutePath(executable.path)
        }
        let session = ProcessRunnerSession(executable: executable.path, arguments: arguments, stdin: stdin,
                                           timeout: timeout, outputLimit: max(0, outputLimit))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.start(continuation)
            }
        } onCancel: {
            session.cancel()
        }
    }

    /// The environment every child starts with.
    static func environment(temporaryDirectory: String) -> [String] {
        [
            "PATH=\(searchPath)",
            "HOME=\(NSHomeDirectory())",
            "USER=\(NSUserName())",
            "LANG=\(locale)",
            "TMPDIR=\(temporaryDirectory.hasSuffix("/") ? temporaryDirectory : temporaryDirectory + "/")",
        ]
    }
}

/// One run. Every piece of mutable state is touched only on `queue`.
private final class ProcessRunnerSession: @unchecked Sendable {
    private let executable: String
    private let arguments: [String]
    private let stdinData: Data?
    private let timeout: Duration
    private let outputLimit: Int
    private let queue = DispatchQueue(label: "com.jalenedusei.otto.process")

    private var continuation: CheckedContinuation<ProcessOutput, Error>?
    private var pid: pid_t = 0
    private var started = false
    private var cancelled = false
    private var timedOut = false
    private var terminating = false
    private var killSent = false
    private var leaderExited = false
    private var reaped = false
    private var finished = false
    private var exitCode: Int32 = -1
    private var startInstant = ContinuousClock.now

    private var exitSource: DispatchSourceProcess?
    private var channels: [DispatchIO] = []
    /// stdout, stderr.
    private var buffers = [Data(), Data()]
    private var drainFinished = [false, false]
    private let drains = DispatchGroup()
    private var temporaryDirectory: URL?

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Actions")

    init(executable: String, arguments: [String], stdin: Data?, timeout: Duration, outputLimit: Int) {
        self.executable = executable
        self.arguments = arguments
        self.stdinData = stdin
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    func start(_ continuation: CheckedContinuation<ProcessOutput, Error>) {
        queue.async {
            self.continuation = continuation
            guard !self.cancelled else {
                self.resume(with: .failure(CancellationError()))
                return
            }
            do {
                try self.spawn()
            } catch {
                self.removeTemporaryDirectory()
                self.resume(with: .failure(error))
            }
        }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            guard self.started, !self.reaped else { return }
            self.terminate()
        }
    }

    // MARK: - Spawning

    private func spawn() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("otto-process-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(folder.path, 0o700) == 0 else { throw ProcessRunner.Failure.setupFailed("mkdir", errno: errno) }
        temporaryDirectory = folder

        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1], errors: [Int32] = [-1, -1]
        guard pipe(&input) == 0 else { throw ProcessRunner.Failure.setupFailed("pipe", errno: errno) }
        guard pipe(&output) == 0 else {
            closeAll(input)
            throw ProcessRunner.Failure.setupFailed("pipe", errno: errno)
        }
        guard pipe(&errors) == 0 else {
            closeAll(input + output)
            throw ProcessRunner.Failure.setupFailed("pipe", errno: errno)
        }
        for descriptor in input + output + errors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        // Writing to a child that already quit must not raise SIGPIPE in Otto.
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&actions, folder.path)

        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        let argv = ([executable] + arguments).map { strdup($0) }
        let envp = ProcessRunner.environment(temporaryDirectory: folder.path).map { strdup($0) }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        let status = posix_spawn(&child, executable, &actions, &attributes, argv + [nil], envp + [nil])
        closeAll([input[0], output[1], errors[1]])
        guard status == 0 else {
            closeAll([input[1], output[0], errors[0]])
            throw ProcessRunner.Failure.spawnFailed(errno: status)
        }

        pid = child
        started = true
        startInstant = .now
        Self.logger.info("Started \(self.executable, privacy: .public) as pid \(child, privacy: .public)")

        writeInput(to: input[1])
        drain(output[0], stream: 0)
        drain(errors[0], stream: 1)
        watchExit()
        scheduleTimeout()
        if cancelled { terminate() }
    }

    private func writeInput(to descriptor: Int32) {
        guard let data = stdinData, !data.isEmpty else {
            close(descriptor)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard var pointer = buffer.baseAddress else { return }
                var remaining = buffer.count
                while remaining > 0 {
                    let written = Darwin.write(descriptor, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    remaining -= written
                    pointer += written
                }
            }
            close(descriptor)
        }
    }

    private func drain(_ descriptor: Int32, stream: Int) {
        drains.enter()
        let channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in
            close(descriptor)
        }
        channel.setLimit(lowWater: 1)
        channels.append(channel)
        channel.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, _ in
            self?.received(data, done: done, stream: stream)
        }
    }

    private func received(_ data: DispatchData?, done: Bool, stream: Int) {
        if let data, !data.isEmpty {
            let room = outputLimit - buffers[stream].count
            if room > 0 { buffers[stream].append(contentsOf: data.prefix(room)) }
        }
        if done, !drainFinished[stream] {
            drainFinished[stream] = true
            drains.leave()
        }
    }

    // MARK: - Exit, timeout, termination

    private func watchExit() {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.noteExit() }
        exitSource = source
        source.resume()
        // The child may have exited before the source was armed.
        queue.async { self.noteExit() }
    }

    private func scheduleTimeout() {
        let nanoseconds = max(0, Int(timeout.timeInterval * 1_000_000_000))
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) {
            guard !self.reaped, !self.leaderExited, !self.terminating else { return }
            self.timedOut = true
            Self.logger.notice("pid \(self.pid, privacy: .public) timed out; stopping its process group")
            self.terminate()
        }
    }

    /// SIGTERM to the whole group now, SIGKILL after `killGrace`. The leader stays unreaped until the SIGKILL is
    /// sent, so its pid (the group id) can't be reused by another process in between.
    private func terminate() {
        guard !terminating, !reaped else { return }
        terminating = true
        killpg(pid, SIGTERM)
        queue.asyncAfter(deadline: .now() + ProcessRunner.killGrace) {
            guard !self.reaped else { return }
            killpg(self.pid, SIGKILL)
            self.killSent = true
            if self.leaderExited { self.reap() }
        }
    }

    private func noteExit() {
        guard started, !reaped, !leaderExited else { return }
        var info = siginfo_t()
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        let exited = result == 0 ? info.si_pid == pid : errno == ECHILD
        guard exited else { return }
        leaderExited = true
        if !terminating || killSent { reap() }
    }

    private func reap() {
        guard !reaped else { return }
        reaped = true
        exitSource?.cancel()
        exitSource = nil
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
        if result == pid {
            let signal = status & 0x7f
            exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        }
        // A background child outside the group (or one that ignored every signal) can keep the pipes open.
        queue.asyncAfter(deadline: .now() + ProcessRunner.drainGrace) {
            self.channels.forEach { $0.close(flags: .stop) }
        }
        drains.notify(queue: queue) { self.finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        channels.forEach { $0.close(flags: .stop) }
        channels = []
        removeTemporaryDirectory()
        let elapsed = ContinuousClock.now - startInstant
        Self.logger.info("pid \(self.pid, privacy: .public) ended with \(self.exitCode, privacy: .public)\(self.timedOut ? " (timed out)" : "", privacy: .public)")
        if cancelled {
            resume(with: .failure(CancellationError()))
            return
        }
        let output = ProcessOutput(stdout: String(decoding: buffers[0], as: UTF8.self),
                                   stderr: String(decoding: buffers[1], as: UTF8.self),
                                   exitCode: exitCode, timedOut: timedOut, duration: elapsed)
        resume(with: .success(output))
    }

    private func resume(with result: Result<ProcessOutput, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func removeTemporaryDirectory() {
        guard let folder = temporaryDirectory else { return }
        temporaryDirectory = nil
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            Self.logger.error("Couldn't remove a process temp folder: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    private func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 { close(descriptor) }
    }
}
