//
//  URLOpening.swift
//  Otto
//
//  Opens approved links in the user's default web browser, named explicitly, so a universal link can't
//  hand the address to some other installed app that claims it.
//

import AppKit
import Foundation
import os

/// How open_url opens a checked http(s) URL. Tests and demo mode inject fakes.
protocol URLOpening: Sendable {
    /// Opens `url` in the default web browser. False when there's no default browser or macOS refused.
    func open(_ url: URL) async -> Bool
}

struct DefaultBrowserOpener: URLOpening {
    /// Finds the app that opens a URL (the default browser for an https URL).
    typealias BrowserLocator = @Sendable (URL) async -> URL?
    /// Opens a URL with a specific app.
    typealias Launcher = @Sendable (_ url: URL, _ applicationURL: URL) async throws -> Void

    /// What the default browser is looked up with: a plain https page, never the link itself (which a
    /// universal-link app could claim).
    static let probeURL: URL? = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "example.com"
        return components.url
    }()

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Actions")

    private let browserLocator: BrowserLocator
    private let launcher: Launcher

    init(browserLocator: @escaping BrowserLocator = DefaultBrowserOpener.workspaceBrowser,
         launcher: @escaping Launcher = DefaultBrowserOpener.workspaceLaunch) {
        self.browserLocator = browserLocator
        self.launcher = launcher
    }

    func open(_ url: URL) async -> Bool {
        guard let probe = Self.probeURL, let browser = await browserLocator(probe) else {
            Self.logger.error("No default web browser to open a link with")
            return false
        }
        do {
            try await launcher(url, browser)
            return true
        } catch {
            Self.logger.error("The browser didn't open the link: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - NSWorkspace

    @MainActor private static func workspaceBrowserURL(for probe: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    static let workspaceBrowser: BrowserLocator = { probe in
        await workspaceBrowserURL(for: probe)
    }

    @MainActor private static func workspaceOpen(_ url: URL, applicationURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration)
    }

    static let workspaceLaunch: Launcher = { url, applicationURL in
        try await workspaceOpen(url, applicationURL: applicationURL)
    }
}
