//
//  WindowCapture.swift
//  Otto
//
//  The "Window: ‹App›" chip: finds an app's front window through CGWindowList (no permission needed) and
//  captures just that window with ScreenCaptureKit, in memory, never for password managers or while a
//  password field is active. Also the seam (`WindowCapturing`) that tests, snapshots and promo use instead.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os
import ScreenCaptureKit

enum WindowCaptureError: LocalizedError, Equatable {
    case permissionNeeded
    case appQuit(appName: String)
    case noWindow(appName: String)
    case failed
    /// The app is a password manager (SensitiveApps).
    case passwordManager(appName: String)
    /// Secure input is on (a password field, a sudo prompt or Secure Keyboard Entry).
    case secureInput

    var errorDescription: String? {
        switch self {
        case .permissionNeeded:
            return "Otto needs Screen Recording permission to see windows."
        case .appQuit(let appName):
            return "\(appName) quit before Otto could look."
        case .noWindow(let appName):
            return "\(appName) has no window open on this screen."
        case .failed:
            return "Otto couldn't capture that window. Try Capture Screen Region instead."
        case .passwordManager:
            return "Otto doesn't capture password managers."
        case .secureInput:
            return "Otto doesn't capture windows while a password field is active."
        }
    }
}

struct WindowCandidate: Equatable, Sendable {
    let windowID: CGWindowID; let pid: pid_t; let layer: Int; let frame: CGRect; let isOnScreen: Bool
}

/// Seams so tests, snapshots and promo never read real selections or windows.
protocol WindowCapturing: Sendable {
    func hasCapturableWindow(_ app: AppRef) async -> Bool                          // CGWindowList, no permission needed
    func capture(_ app: AppRef) async throws -> Attachment                         // ScreenCaptureKit, WindowCaptureError
}

/// Wraps `WindowCapture`'s statics (real window list and ScreenCaptureKit).
struct LiveWindowCapture: WindowCapturing {
    init() {}

    func hasCapturableWindow(_ app: AppRef) async -> Bool {
        await WindowCapture.hasCapturableWindow(app)
    }

    func capture(_ app: AppRef) async throws -> Attachment {
        try await WindowCapture.capture(app)
    }
}

/// Never finds a window; capture always throws `.noWindow`.
struct InertWindowCapture: WindowCapturing {
    init() {}

    func hasCapturableWindow(_ app: AppRef) async -> Bool { false }

    func capture(_ app: AppRef) async throws -> Attachment {
        throw WindowCaptureError.noWindow(appName: app.name)
    }
}

enum WindowCapture {
    static let minimumSide: CGFloat = 64
    static let captureTimeout: Duration = .seconds(3)

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Context")

    /// The system calls behind the chip; tests pass fakes so nothing reads real windows.
    struct Environment: Sendable {
        var isSecureInputEnabled: @Sendable () -> Bool
        var frontWindowIDs: @Sendable (pid_t) async -> [CGWindowID]
        /// Captures the app's front window (after every guard has passed).
        var captureFrontWindow: @Sendable (AppRef) async throws -> Attachment

        static let live = Environment(
            isSecureInputEnabled: { IsSecureEventInputEnabled() },
            frontWindowIDs: { pid in await WindowCapture.frontWindowIDs(pid: pid) },
            captureFrontWindow: { app in try await WindowCapture.captureWithScreenCaptureKit(app) }
        )
    }

    /// Front-to-back on-screen window IDs owned by `pid`, layer 0, alpha > 0, ≥ minimumSide
    /// (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)).
    /// No permission needed. Runs off-main.
    static func frontWindowIDs(pid: pid_t) async -> [CGWindowID] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        let windows = (info as? [[String: Any]]) ?? []
        return windowIDs(in: windows, pid: pid)
    }

    /// Never for SensitiveApps or while secure input is on.
    static func hasCapturableWindow(_ app: AppRef) async -> Bool {
        await hasCapturableWindow(app, environment: .live)
    }

    static func hasCapturableWindow(_ app: AppRef, environment: Environment) async -> Bool {
        guard !SensitiveApps.contains(app), !environment.isSecureInputEnabled() else { return false }
        return !(await environment.frontWindowIDs(app.pid)).isEmpty
    }

    /// Pure (tested): the ids in `windowList` (a CGWindowListCopyWindowInfo result, front to back) that belong to
    /// `pid`, sit on layer 0, are visible and are at least `minimumSide` on both sides.
    static func windowIDs(in windowList: [[String: Any]], pid: pid_t) -> [CGWindowID] {
        windowList.compactMap { window -> CGWindowID? in
            guard let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner == pid,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            if let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0 { return nil }
            if let onScreen = (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue, !onScreen { return nil }
            guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= minimumSide, bounds.height >= minimumSide else { return nil }
            return CGWindowID(number)
        }
    }

    /// Pure (tested): first z-ordered id that is a layer-0 on-screen candidate of `pid`.
    static func pickWindow(candidates: [WindowCandidate], zOrder: [CGWindowID], pid: pid_t) -> CGWindowID? {
        let eligible = Set(candidates.filter { $0.pid == pid && $0.layer == 0 && $0.isOnScreen }.map(\.windowID))
        return zOrder.first { eligible.contains($0) }
    }

    /// Pure (tested): pixel size = contentRect × scale, scaled down so the long edge ≤ maxLongEdge.
    static func captureSize(contentRect: CGRect, scale: CGFloat,
                            maxLongEdge: Int = AttachmentLoader.maxImageLongEdge) -> (width: Int, height: Int) {
        let width = max(contentRect.width * max(scale, 0), 1)
        let height = max(contentRect.height * max(scale, 0), 1)
        let longEdge = max(width, height)
        let factor = longEdge > CGFloat(maxLongEdge) ? CGFloat(maxLongEdge) / longEdge : 1
        return (max(Int((width * factor).rounded()), 1), max(Int((height * factor).rounded()), 1))
    }

    /// Throws WindowCaptureError. Never includes Otto's windows (filter is one foreign window). The attachment's
    /// payload is never written to History.
    static func capture(_ app: AppRef) async throws -> Attachment {
        try await capture(app, environment: .live)
    }

    /// Re-checks both guards right before capturing.
    static func capture(_ app: AppRef, environment: Environment) async throws -> Attachment {
        if SensitiveApps.contains(app) { throw WindowCaptureError.passwordManager(appName: app.name) }
        if environment.isSecureInputEnabled() { throw WindowCaptureError.secureInput }
        var attachment = try await environment.captureFrontWindow(app)
        attachment.appBundleID = app.bundleID
        attachment.sourceURL = nil
        attachment.retainsPayloadInHistory = false
        return attachment
    }

    // MARK: ScreenCaptureKit

    private static func captureWithScreenCaptureKit(_ app: AppRef) async throws -> Attachment {
        guard await MainActor.run(body: { app.isRunning }) else { throw WindowCaptureError.appQuit(appName: app.name) }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw mapped(error)
        }
        let candidates = content.windows.map { window in
            WindowCandidate(windowID: window.windowID, pid: window.owningApplication?.processID ?? -1,
                            layer: window.windowLayer, frame: window.frame, isOnScreen: window.isOnScreen)
        }
        let zOrder = await frontWindowIDs(pid: app.pid)
        guard let windowID = pickWindow(candidates: candidates, zOrder: zOrder, pid: app.pid),
              let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw WindowCaptureError.noWindow(appName: app.name)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)
        let size = captureSize(contentRect: info.contentRect, scale: CGFloat(info.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB

        let image = try await screenshot(filter: filter, configuration: configuration)
        let nsImage = NSImage(cgImage: image, size: info.contentRect.size)
        do {
            let attachment = try await AttachmentLoader.load(image: nsImage, name: "\(app.name) window.png")
            logger.info("Captured a window of \(image.width, privacy: .public)×\(image.height, privacy: .public) px")
            return attachment
        } catch {
            logger.error("Couldn't encode a window capture: \(String(describing: error), privacy: .public)")
            throw WindowCaptureError.failed
        }
    }

    /// `SCScreenshotManager.captureImage` raced against `captureTimeout`.
    private static func screenshot(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        let box = ContextCaptureBox(filter: filter, configuration: configuration)
        let result: Result<ContextCapturedImage, WindowCaptureError> = await ContextDeadline.race(
            fallback: .failure(.failed), deadline: captureTimeout
        ) { resolve in
            Task {
                do {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: box.filter,
                                                                           configuration: box.configuration)
                    resolve(.success(ContextCapturedImage(image: image)))
                } catch {
                    resolve(.failure(mapped(error)))
                }
            }
        }
        switch result {
        case .success(let captured): return captured.image
        case .failure(let error):
            logger.error("Window capture failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private static func mapped(_ error: Error) -> WindowCaptureError {
        if let captureError = error as? WindowCaptureError { return captureError }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return .permissionNeeded
        }
        return .failed
    }
}

/// Carries ScreenCaptureKit objects into the capture task (they are only read there).
private final class ContextCaptureBox: @unchecked Sendable {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration

    init(filter: SCContentFilter, configuration: SCStreamConfiguration) {
        self.filter = filter
        self.configuration = configuration
    }
}

/// An immutable captured image handed back across the deadline race.
private struct ContextCapturedImage: @unchecked Sendable {
    let image: CGImage
}
