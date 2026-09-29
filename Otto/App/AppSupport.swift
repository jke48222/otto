//
//  AppSupport.swift
//  Otto
//
//  Where Otto keeps its own files and how it writes them. Every directory is checked on every use
//  (no symlinks, owned by this user, mode 0700, out of Time Machine, `.noindex` names so Spotlight
//  skips them); every file is created 0600 and moved into place atomically. Also the one sanitizer
//  for outside text that Otto only displays.
//

import Darwin
import Foundation
import os

enum AppSupport {
    enum Directory: String, CaseIterable, Sendable {
        case conversations = "Conversations.noindex", attachments = "Attachments.noindex",
             shelf = "Shelf.noindex", logs = "Logs.noindex"
    }

    /// Name of the demo root inside the Otto root.
    static let demoFolderName = "Demo"
    /// Empty marker written at the root as a best-effort extra (Spotlight only honors it at a volume root).
    static let neverIndexMarkerName = ".metadata_never_index"

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Settings")

    /// ~/Library/Application Support/Otto (…/Otto/Demo when demo). EVERY call: lstat; refuse a symlink or a path not
    /// owned by getuid() (AppSupportError.unsafePath + `.fault` log); create if missing; setAttributes posixPermissions
    /// 0o700 unconditionally; isExcludedFromBackup; best-effort empty `.metadata_never_index`.
    static func rootURL(demo: Bool = LaunchOptions.demo) throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw AppSupportError.notCreatable("Application Support")
        }
        return try rootURL(in: base, demo: demo)
    }

    /// rootURL/<directory.rawValue> with the same checks. The `.noindex` suffix keeps Spotlight out.
    static func directory(_ directory: Directory, demo: Bool = LaunchOptions.demo) throws -> URL {
        let root = try rootURL(demo: demo)
        return try secureDirectory(root.appendingPathComponent(directory.rawValue, isDirectory: true))
    }

    /// `rootURL(demo:)` under an explicit base folder instead of the user's Application Support (tests).
    static func rootURL(in base: URL, demo: Bool) throws -> URL {
        var root = try secureDirectory(base.appendingPathComponent("Otto", isDirectory: true))
        if demo {
            root = try secureDirectory(root.appendingPathComponent(demoFolderName, isDirectory: true))
        }
        excludeFromBackup(root)
        let marker = root.appendingPathComponent(neverIndexMarkerName)
        do {
            try SecureFile.writeIfAbsent(Data(), to: marker)
        } catch {
            logger.notice("Couldn't write the Spotlight marker: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
        return root
    }

    /// `directory(_:demo:)` under an explicit base folder instead of the user's Application Support (tests).
    static func directory(_ directory: Directory, in base: URL, demo: Bool) throws -> URL {
        let root = try rootURL(in: base, demo: demo)
        return try secureDirectory(root.appendingPathComponent(directory.rawValue, isDirectory: true))
    }

    /// Checks one directory Otto owns: refuses a symlink, a non-directory or anything not owned by this user;
    /// creates it (0700) when missing; sets mode 0700 on every call, so a 0755 folder is repaired.
    static func secureDirectory(_ url: URL) throws -> URL {
        let path = url.path
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw AppSupportError.notCreatable(path) }
            if mkdir(path, 0o700) != 0, errno != EEXIST {
                logger.error("Couldn't create \(path, privacy: .private): errno \(errno, privacy: .public)")
                throw AppSupportError.notCreatable(path)
            }
            guard lstat(path, &info) == 0 else { throw AppSupportError.notCreatable(path) }
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else { throw refuse(path, reason: "is a symbolic link") }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw refuse(path, reason: "is not a directory") }
        guard info.st_uid == getuid() else { throw refuse(path, reason: "is owned by another user") }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch {
            logger.error("Couldn't set 0700 on \(path, privacy: .private): \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            throw AppSupportError.notCreatable(path)
        }
        return url
    }

    // MARK: - Private

    private static func refuse(_ path: String, reason: String) -> AppSupportError {
        logger.fault("Refused Otto's data folder \(path, privacy: .private): it \(reason, privacy: .public)")
        return .unsafePath(path)
    }

    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        do {
            try mutable.setResourceValues(values)
        } catch {
            logger.notice("Couldn't exclude Otto's data from backups: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }
}

enum AppSupportError: Error, Equatable { case unsafePath(String), notCreatable(String) }

/// The only way Otto writes its own files (history, shelf, ledger, activity log).
enum SecureFile {
    /// Temp file in url's directory via open(O_CREAT|O_EXCL|O_WRONLY, 0o600), full write, close, rename(2) over url.
    static func write(_ data: Data, to url: URL) throws {
        let temporary = try writeTemporary(data, beside: url)
        guard rename(temporary.path, url.path) == 0 else {
            let error = posixError()
            unlink(temporary.path)
            throw error
        }
    }

    /// Content-addressed blobs: false (no error) when the file already exists (EEXIST counts as success).
    /// The data is written to a temp file first and linked into place, so a crash never leaves a partial blob.
    @discardableResult static func writeIfAbsent(_ data: Data, to url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return false }
        let temporary = try writeTemporary(data, beside: url)
        defer { unlink(temporary.path) }
        guard link(temporary.path, url.path) == 0 else {
            if errno == EEXIST { return false }
            throw posixError()
        }
        return true
    }

    // MARK: - Private

    private static func writeTemporary(_ data: Data, beside url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }

        var failure: Error?
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = posixError()
                    return
                }
                remaining -= written
                pointer += written
            }
        }
        if failure == nil, fsync(descriptor) != 0 { failure = posixError() }
        if close(descriptor) != 0, failure == nil { failure = posixError() }
        if let failure {
            unlink(temporary.path)
            throw failure
        }
        return temporary
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// Cleaning for text that comes from outside Otto and is only displayed (never executed).
enum DisplayText {
    /// Removes C0/C1 controls (keeps \n and \t only when allowNewlines), DEL, bidi embeddings/overrides/isolates
    /// (U+202A–U+202E, U+2066–U+2069), zero-width characters (U+200B–U+200F, U+2060, U+FEFF); collapses whitespace
    /// runs to one space; caps at maxLength characters with a trailing "…".
    /// Without allowNewlines, line breaks and tabs count as whitespace (a space); with it, \r\n and \r become \n.
    static func sanitized(_ text: String, maxLength: Int, allowNewlines: Bool = false) -> String {
        guard maxLength > 0 else { return "" }
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            defer { previous = scalar }
            if allowNewlines, scalar == "\n" || scalar == "\r" || scalar == "\t" {
                // "\r\n" is one line break.
                if scalar == "\n", previous == "\r" { continue }
                pendingSpace = false
                scalars.append(scalar == "\t" ? "\t" : "\n")
                continue
            }
            if isRemoved(scalar) { continue }
            if scalar.properties.isWhitespace || scalar.value < 0x20 {
                pendingSpace = true
                continue
            }
            if pendingSpace, let last = scalars.last, last != "\n", last != "\t" {
                scalars.append(" ")
            }
            pendingSpace = false
            scalars.append(scalar)
        }

        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxLength else { return cleaned }
        let kept = String(cleaned.prefix(maxLength - 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return kept + "…"
    }

    /// True when `text` contains any character sanitized() would remove as hidden or bidi (not newlines/tabs).
    static func containsHiddenOrBidi(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isRemoved)
    }

    // MARK: - Private

    /// Hidden, control and bidi characters: never displayed. Line breaks and tabs are whitespace, not hidden.
    private static func isRemoved(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0D, 0x09: return false
        case 0x00...0x1F, 0x7F, 0x80...0x9F: return true
        case 0x202A...0x202E, 0x2066...0x2069: return true
        case 0x200B...0x200F, 0x2060, 0xFEFF: return true
        default: return false
        }
    }
}

extension Duration {
    /// Seconds plus attoseconds / 1e18.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
