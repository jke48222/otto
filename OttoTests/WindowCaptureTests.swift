//
//  WindowCaptureTests.swift
//  OttoTests
//
//  Window picking and sizing (pure), window-list parsing, and the guards that keep password managers and
//  secure input out of the window chip and captures. No window list or ScreenCaptureKit call is made.
//

import AppKit
import XCTest
@testable import Otto

final class WindowCaptureTests: XCTestCase {
    private let xcode = AppRef(pid: 8181, bundleID: "com.apple.dt.Xcode", name: "Xcode")
    private let onePassword = AppRef(pid: 8282, bundleID: "com.1password.1password", name: "1Password")

    // MARK: pickWindow

    func testPickWindowFollowsZOrder() {
        let candidates = [
            WindowCandidate(windowID: 1, pid: 10, layer: 0, frame: CGRect(x: 0, y: 0, width: 400, height: 300), isOnScreen: true),
            WindowCandidate(windowID: 2, pid: 10, layer: 0, frame: CGRect(x: 0, y: 0, width: 400, height: 300), isOnScreen: true),
        ]
        XCTAssertEqual(WindowCapture.pickWindow(candidates: candidates, zOrder: [2, 1], pid: 10), 2)
        XCTAssertEqual(WindowCapture.pickWindow(candidates: candidates, zOrder: [1, 2], pid: 10), 1)
    }

    func testPickWindowSkipsOtherLayersOffScreenWindowsAndOtherApps() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let candidates = [
            WindowCandidate(windowID: 1, pid: 10, layer: 25, frame: frame, isOnScreen: true),
            WindowCandidate(windowID: 2, pid: 10, layer: 0, frame: frame, isOnScreen: false),
            WindowCandidate(windowID: 3, pid: 11, layer: 0, frame: frame, isOnScreen: true),
            WindowCandidate(windowID: 4, pid: 10, layer: 0, frame: frame, isOnScreen: true),
        ]
        XCTAssertEqual(WindowCapture.pickWindow(candidates: candidates, zOrder: [1, 2, 3, 4], pid: 10), 4)
        XCTAssertNil(WindowCapture.pickWindow(candidates: candidates, zOrder: [1, 2, 3], pid: 10))
        XCTAssertNil(WindowCapture.pickWindow(candidates: candidates, zOrder: [9], pid: 10))
        XCTAssertNil(WindowCapture.pickWindow(candidates: [], zOrder: [4], pid: 10))
    }

    // MARK: captureSize

    func testCaptureSizeAtTwoXScale() {
        let size = WindowCapture.captureSize(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 2)
        XCTAssertEqual(size.width, 1600)
        XCTAssertEqual(size.height, 1200)
    }

    func testCaptureSizeCapsTheLongEdgeAndKeepsTheAspect() {
        let size = WindowCapture.captureSize(contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000), scale: 2)
        XCTAssertEqual(size.width, AttachmentLoader.maxImageLongEdge)
        XCTAssertEqual(size.height, 1250)

        let tall = WindowCapture.captureSize(contentRect: CGRect(x: 0, y: 0, width: 500, height: 2000), scale: 1,
                                             maxLongEdge: 1000)
        XCTAssertEqual(tall.width, 250)
        XCTAssertEqual(tall.height, 1000)
    }

    func testCaptureSizeLeavesTinyWindowsAlone() {
        let size = WindowCapture.captureSize(contentRect: CGRect(x: 0, y: 0, width: 64, height: 80), scale: 1)
        XCTAssertEqual(size.width, 64)
        XCTAssertEqual(size.height, 80)
    }

    // MARK: Window list

    func testWindowIDsKeepVisibleLayerZeroWindowsOfThePID() {
        func window(_ number: Int, pid: Int, layer: Int = 0, alpha: Double = 1, width: Double = 400,
                    height: Double = 300) -> [String: Any] {
            [
                kCGWindowNumber as String: NSNumber(value: number),
                kCGWindowOwnerPID as String: NSNumber(value: pid),
                kCGWindowLayer as String: NSNumber(value: layer),
                kCGWindowAlpha as String: NSNumber(value: alpha),
                kCGWindowIsOnscreen as String: NSNumber(value: true),
                kCGWindowBounds as String: CGRect(x: 0, y: 0, width: width, height: height).dictionaryRepresentation,
            ]
        }
        let list = [
            window(1, pid: 10, layer: 25),
            window(2, pid: 11),
            window(3, pid: 10, alpha: 0),
            window(4, pid: 10, width: 63),
            window(5, pid: 10),
            window(6, pid: 10, width: 64, height: 64),
        ]
        XCTAssertEqual(WindowCapture.windowIDs(in: list, pid: 10), [5, 6])
        XCTAssertEqual(WindowCapture.windowIDs(in: list, pid: 11), [2])
        XCTAssertEqual(WindowCapture.windowIDs(in: [["junk": 1]], pid: 10), [])
    }

    // MARK: Guards

    func testSecureInputMeansNoOfferAndNoCapture() async {
        let fake = WindowEnvironmentFake(secureInput: true, windowIDs: [42])
        let offered = await WindowCapture.hasCapturableWindow(xcode, environment: fake.environment)
        XCTAssertFalse(offered)
        do {
            _ = try await WindowCapture.capture(xcode, environment: fake.environment)
            XCTFail("Capture ran under secure input")
        } catch {
            XCTAssertEqual(error as? WindowCaptureError, .secureInput)
        }
        XCTAssertEqual(fake.listReads, 0)
        XCTAssertEqual(fake.captures, 0)
    }

    func testSensitiveAppsGetNoOfferAndNoCapture() async {
        let fake = WindowEnvironmentFake(secureInput: false, windowIDs: [42])
        let offered = await WindowCapture.hasCapturableWindow(onePassword, environment: fake.environment)
        XCTAssertFalse(offered)
        let byName = AppRef(pid: 8383, bundleID: "com.example.safe", name: "Bitwarden Beta")
        let offeredByName = await WindowCapture.hasCapturableWindow(byName, environment: fake.environment)
        XCTAssertFalse(offeredByName)
        do {
            _ = try await WindowCapture.capture(onePassword, environment: fake.environment)
            XCTFail("Captured a password manager")
        } catch {
            XCTAssertEqual(error as? WindowCaptureError, .passwordManager(appName: "1Password"))
        }
        XCTAssertEqual(fake.listReads, 0)
        XCTAssertEqual(fake.captures, 0)
    }

    func testOfferNeedsAWindow() async {
        let none = WindowEnvironmentFake(secureInput: false, windowIDs: [])
        let noWindow = await WindowCapture.hasCapturableWindow(xcode, environment: none.environment)
        XCTAssertFalse(noWindow)
        let some = WindowEnvironmentFake(secureInput: false, windowIDs: [7])
        let hasWindow = await WindowCapture.hasCapturableWindow(xcode, environment: some.environment)
        XCTAssertTrue(hasWindow)
    }

    func testCaptureIsNeverKeptInHistory() async throws {
        let fake = WindowEnvironmentFake(secureInput: false, windowIDs: [7])
        let attachment = try await WindowCapture.capture(xcode, environment: fake.environment)
        XCTAssertEqual(fake.captures, 1)
        XCTAssertFalse(attachment.retainsPayloadInHistory)
        XCTAssertEqual(attachment.appBundleID, "com.apple.dt.Xcode")
        XCTAssertNil(attachment.sourceURL)
        XCTAssertEqual(attachment.displayName, "Xcode window.png")
    }

    func testInertCaptureFindsNothing() async {
        let inert = InertWindowCapture()
        let offered = await inert.hasCapturableWindow(xcode)
        XCTAssertFalse(offered)
        do {
            _ = try await inert.capture(xcode)
            XCTFail("Inert capture returned a picture")
        } catch {
            XCTAssertEqual(error as? WindowCaptureError, .noWindow(appName: "Xcode"))
        }
    }

    func testErrorCopy() {
        XCTAssertEqual(WindowCaptureError.permissionNeeded.errorDescription,
                       "Otto needs Screen Recording permission to see windows.")
        XCTAssertEqual(WindowCaptureError.appQuit(appName: "Xcode").errorDescription, "Xcode quit before Otto could look.")
        XCTAssertEqual(WindowCaptureError.noWindow(appName: "Xcode").errorDescription,
                       "Xcode has no window open on this screen.")
        XCTAssertEqual(WindowCaptureError.passwordManager(appName: "1Password").errorDescription,
                       "Otto doesn't capture password managers.")
    }
}

// MARK: - Fake environment

private final class WindowEnvironmentFake: @unchecked Sendable {
    private let secureInput: Bool
    private let windowIDs: [CGWindowID]
    private let lock = NSLock()
    private var reads = 0
    private var captureCount = 0

    init(secureInput: Bool, windowIDs: [CGWindowID]) {
        self.secureInput = secureInput
        self.windowIDs = windowIDs
    }

    var listReads: Int { lock.withLock { reads } }
    var captures: Int { lock.withLock { captureCount } }

    var environment: WindowCapture.Environment {
        WindowCapture.Environment(
            isSecureInputEnabled: { [secureInput] in secureInput },
            frontWindowIDs: { [self] _ in
                lock.withLock { reads += 1 }
                return windowIDs
            },
            captureFrontWindow: { [self] app in
                lock.withLock { captureCount += 1 }
                return Attachment(kind: .image, displayName: "\(app.name) window.png", badge: "PNG",
                                  sourceURL: URL(fileURLWithPath: "/tmp/should-be-cleared.png"),
                                  payload: .image(mediaType: "image/png", base64: "iVBORw0KGgo="), byteCount: 12)
            }
        )
    }
}
