//
//  LoggedError.swift
//  Otto
//
//  The part of an error that is safe to write to the unified log in the clear.
//  Cocoa file errors put the file name (and `String(describing:)` the full path)
//  into their description, so a description is only ever logged `.private`
//  (SPEC-v2 §0.3, §4.10); the domain and code identify the failure without it.
//

import Foundation

/// An error's domain and code, for `privacy: .public` log interpolation next to a `.private` description:
/// `logger.error("…: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")`.
struct LoggedError: CustomStringConvertible, Equatable, Sendable {
    let domain: String
    let code: Int

    init(_ error: Error) {
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
    }

    var description: String { "[\(domain) \(code)]" }
}
