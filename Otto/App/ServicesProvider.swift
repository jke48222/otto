//
//  ServicesProvider.swift
//  Otto
//
//  The macOS Services entry points ("Send Selection to Otto", "Send Files to Otto", "Add to Otto Shelf"). Each handler
//  reads the pasteboard it is handed, reports empty input through the service's error, and passes the rest
//  to the view model without waiting on it.
//

import AppKit
import Foundation
import os

@MainActor final class ServicesProvider: NSObject {
    static let noTextError = "Otto didn't receive any text."
    static let noFilesError = "Otto didn't receive any files."

    private let handler: ServicesHandling
    private let frontmostApp: @MainActor () -> AppRef?

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Context")

    /// `frontmostApp` names the app that invoked the service (Otto is an accessory app and not active, so the
    /// frontmost app is the requester).
    init(handler: ServicesHandling,
         frontmostApp: @escaping @MainActor () -> AppRef? = { NSWorkspace.shared.frontmostApplication.flatMap(AppRef.init) }) {
        self.handler = handler
        self.frontmostApp = frontmostApp
        super.init()
    }

    /// NSMessage "askOtto" — text selections.
    @objc(askOtto:userData:error:)
    func askOtto(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = Self.text(from: pasteboard), text.contains(where: { !$0.isWhitespace && $0 != "\0" }) else {
            error.pointee = Self.noTextError as NSString
            Self.logger.info("Send Selection to Otto received no text")
            return
        }
        let app = frontmostApp()
        Self.logger.info("Send Selection to Otto received \(text.count, privacy: .public) characters")
        Task { [handler] in await handler.askAbout(serviceText: text, app: app) }
    }

    /// NSMessage "askOttoAboutFiles" — Finder file selections.
    @objc(askOttoAboutFiles:userData:error:)
    func askOttoAboutFiles(_ pasteboard: NSPasteboard, userData: String?,
                           error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(from: pasteboard)
        guard !urls.isEmpty else {
            error.pointee = Self.noFilesError as NSString
            return
        }
        let app = frontmostApp()
        Self.logger.info("Send Files to Otto received \(urls.count, privacy: .public) files")
        Task { [handler] in handler.askAbout(fileURLs: urls, app: app) }
    }

    /// NSMessage "addToShelf".
    @objc(addToShelf:userData:error:)
    func addToShelf(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(from: pasteboard)
        guard !urls.isEmpty else {
            error.pointee = Self.noFilesError as NSString
            return
        }
        Self.logger.info("Add to Otto Shelf received \(urls.count, privacy: .public) files")
        Task { [handler] in handler.addToShelf(fileURLs: urls, openShelf: true) }
    }

    /// Pure helpers (tested).
    /// .string, else .rtf/.rtfd → NSAttributedString.string.
    static func text(from pasteboard: NSPasteboard) -> String? {
        if let string = pasteboard.string(forType: .string) { return string }
        if let rtf = pasteboard.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            return attributed.string
        }
        if let rtfd = pasteboard.data(forType: .rtfd),
           let attributed = NSAttributedString(rtfd: rtfd, documentAttributes: nil) {
            return attributed.string
        }
        return nil
    }

    /// readObjects([NSURL], urlReadingFileURLsOnly).
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects ?? []).compactMap { $0 as? URL }
    }
}
