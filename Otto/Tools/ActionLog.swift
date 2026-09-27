//
//  ActionLog.swift
//  Otto
//
//  The local activity log of the tool loop: one line per call with the tool, how it was decided,
//  how it ended, its title, the host or shortcut it touched and (for scripts) a fingerprint. It never
//  holds inputs, notes or outputs. Kept in Logs.noindex/actions.jsonl (0600, rotated at 1 MB, two
//  files), follows the History retention and is cleared with History.
//

import CryptoKit
import Foundation
import os

struct ActionLogEntry: Codable, Equatable, Sendable {
    let id: UUID; let date: Date; let tool: String
    /// "auto" "consent" "approved" "approved_always" "declined" "blocked" "limit" "timed_out" "cancelled"
    /// "blocked_synthetic_input".
    let decision: String
    /// "ok" | "error:<code>" | "not_run".
    let outcome: String
    /// presentation.title only, never notes, inputs or outputs.
    let summary: String
    let provenance: String?; let caution: Bool; let durationMs: Int?
    /// run_applescript only: SHA-256 of the approved source, and its first 200 characters (the full source only
    /// while settings.actions.logFullScripts is on).
    let scriptSHA256: String?; let script: String?
    /// Shortcut name / URL host / media app.
    let target: String?
}

extension ActionLogEntry {
    /// Characters of an AppleScript source kept when full scripts aren't logged.
    static let scriptPrefixLength = 200

    /// The script fields for an approved AppleScript source: its SHA-256 (lowercase hex of the UTF-8 bytes)
    /// and either the whole source (`keepFull`) or its first `scriptPrefixLength` characters.
    static func scriptRecord(_ source: String, keepFull: Bool) -> (sha256: String, script: String) {
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return (digest, keepFull ? source : String(source.prefix(scriptPrefixLength)))
    }
}

actor ActionLog {
    static let fileName = "actions.jsonl"
    static let rotatedFileName = "actions.1.jsonl"
    /// The current file rotates once it would pass this size.
    static let rotationBytes = 1_048_576
    /// In-memory logs keep at most this many entries.
    static let memoryCapacity = 5_000

    private let directory: URL?
    private var maxAge: TimeInterval?
    /// Entries of an in-memory log, or of a file log that fell back to memory for this session.
    private var memory: [ActionLogEntry] = []
    private var fellBackToMemory = false
    /// The current file's bytes after the first read, so an append doesn't re-read it.
    private var currentData: Data?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Actions")

    /// nil directory = in-memory (tests, snapshots, demo). maxAge nil = no time limit (size rotation only).
    init(directory: URL?, maxAge: TimeInterval? = 30 * 86_400) {
        self.directory = directory
        self.maxAge = maxAge
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.makeDateFormatter().string(from: date))
        }
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = Self.makeDateFormatter().date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date")
            }
            return date
        }
        self.decoder = decoder
    }

    /// AppComposition keeps it equal to settings.history.retention (`.forever` → 90 days).
    func setMaxAge(_ maxAge: TimeInterval?) {
        self.maxAge = maxAge
    }

    /// Prunes expired entries whenever it rotates.
    func append(_ entry: ActionLogEntry) {
        Self.logger.info("Action \(entry.tool, privacy: .public): \(entry.decision, privacy: .public) → \(entry.outcome, privacy: .public)")
        guard let folder = writableDirectory() else {
            appendToMemory(entry)
            return
        }
        let line: Data
        do {
            line = try encoder.encode(entry) + Data("\n".utf8)
        } catch {
            Self.logger.error("Couldn't encode an activity entry: \(error.localizedDescription, privacy: .public)")
            return
        }
        var current = currentData ?? readFile(folder.appendingPathComponent(Self.fileName))
        do {
            var rotated = false
            if !current.isEmpty, current.count + line.count > Self.rotationBytes {
                try SecureFile.write(current, to: folder.appendingPathComponent(Self.rotatedFileName))
                current = Data()
                rotated = true
            }
            current.append(line)
            try SecureFile.write(current, to: folder.appendingPathComponent(Self.fileName))
            currentData = current
            if rotated { prune(now: Date()) }
        } catch {
            currentData = nil
            Self.logger.error("Couldn't write the activity log: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Launch + each rotation: drops entries older than maxAge.
    func prune(now: Date) {
        guard let maxAge else { return }
        let cutoff = now.addingTimeInterval(-maxAge)
        memory.removeAll { $0.date < cutoff }
        guard let folder = writableDirectory() else { return }
        for name in [Self.rotatedFileName, Self.fileName] {
            let url = folder.appendingPathComponent(name)
            let data = name == Self.fileName ? (currentData ?? readFile(url)) : readFile(url)
            guard !data.isEmpty else { continue }
            let kept = lines(of: data).filter { line in
                guard let entry = try? decoder.decode(ActionLogEntry.self, from: line) else { return false }
                return entry.date >= cutoff
            }
            let rewritten = kept.reduce(into: Data()) { result, line in
                result.append(line)
                result.append(Data("\n".utf8))
            }
            guard rewritten != data else { continue }
            do {
                try SecureFile.write(rewritten, to: url)
                if name == Self.fileName { currentData = rewritten }
            } catch {
                if name == Self.fileName { currentData = nil }
                Self.logger.error("Couldn't prune the activity log: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The newest `limit` entries, newest first.
    func recent(limit: Int) -> [ActionLogEntry] {
        guard limit > 0 else { return [] }
        var entries: [ActionLogEntry] = []
        if let folder = writableDirectory() {
            for name in [Self.rotatedFileName, Self.fileName] {
                let url = folder.appendingPathComponent(name)
                let data = name == Self.fileName ? (currentData ?? readFile(url)) : readFile(url)
                entries += lines(of: data).compactMap { try? decoder.decode(ActionLogEntry.self, from: $0) }
            }
        }
        entries += memory
        return Array(entries.suffix(limit).reversed())
    }

    /// Delete All History / History off / Settings "Clear Log".
    func clear() throws {
        memory = []
        currentData = nil
        guard let directory else { return }
        var failure: Error?
        for name in [Self.fileName, Self.rotatedFileName] {
            let path = directory.appendingPathComponent(name).path
            if unlink(path) != 0, errno != ENOENT {
                failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        currentData = Data()
        if let failure {
            currentData = nil
            Self.logger.error("Couldn't clear the activity log: \(failure.localizedDescription, privacy: .public)")
            throw failure
        }
        Self.logger.info("Activity log cleared")
    }

    // MARK: - Private

    /// The log folder after the ownership/mode checks; nil for an in-memory log or after a refused folder
    /// (the log then keeps this session's entries in memory).
    private func writableDirectory() -> URL? {
        guard let directory, !fellBackToMemory else { return nil }
        do {
            return try AppSupport.secureDirectory(directory)
        } catch {
            fellBackToMemory = true
            currentData = nil
            Self.logger.fault("The activity log folder was refused; keeping entries in memory: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func appendToMemory(_ entry: ActionLogEntry) {
        memory.append(entry)
        guard memory.count > Self.memoryCapacity else { return }
        memory.removeFirst(memory.count - Self.memoryCapacity)
        prune(now: Date())
    }

    /// A regular file's contents; empty for a missing file, a symlink or anything else.
    private func readFile(_ url: URL) -> Data {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return Data() }
        do {
            return try Data(contentsOf: url)
        } catch {
            Self.logger.error("Couldn't read the activity log: \(error.localizedDescription, privacy: .public)")
            return Data()
        }
    }

    private func lines(of data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n")).map { Data($0) }.filter { !$0.isEmpty }
    }

    private static func makeDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
