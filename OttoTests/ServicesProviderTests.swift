//
//  ServicesProviderTests.swift
//  OttoTests
//
//  The three Services handlers against private pasteboards and a fake ServicesHandling: what reaches the
//  handler, what is refused through the service's error, and that no handler waits on the view model.
//

import AppKit
import XCTest
@testable import Otto

@MainActor
final class ServicesProviderTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var handler: ServicesHandlerFake!
    private var provider: ServicesProvider!
    private var directory: URL!

    private let pages = AppRef(pid: 3131, bundleID: "com.apple.iWork.Pages", name: "Pages")

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("otto.tests.services.\(UUID().uuidString)"))
        handler = ServicesHandlerFake()
        let app = pages
        provider = ServicesProvider(handler: handler, frontmostApp: { app })
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OttoServicesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        pasteboard = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func writeFiles(_ names: [String]) throws -> [URL] {
        let urls = try names.map { name -> URL in
            let url = directory.appendingPathComponent(name)
            try Data("contents".utf8).write(to: url)
            return url
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        return urls
    }

    private func waitForCalls(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while handler.calls.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Ask Otto

    func testAskOttoPassesTheTextAndTheRequestingApp() async {
        pasteboard.clearContents()
        pasteboard.setString("make this friendlier", forType: .string)
        var error: NSString?

        provider.askOtto(pasteboard, userData: nil, error: &error)
        XCTAssertNil(error)
        await waitForCalls(1)

        XCTAssertEqual(handler.calls, [.askText("make this friendlier", pages)])
    }

    func testAskOttoFallsBackToRichText() async throws {
        let rich = NSAttributedString(string: "styled words", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        let rtf = try XCTUnwrap(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]))
        pasteboard.clearContents()
        pasteboard.setData(rtf, forType: .rtf)
        XCTAssertEqual(ServicesProvider.text(from: pasteboard), "styled words")

        var error: NSString?
        provider.askOtto(pasteboard, userData: nil, error: &error)
        await waitForCalls(1)
        XCTAssertEqual(handler.calls, [.askText("styled words", pages)])
    }

    func testAskOttoRefusesEmptyText() async {
        for text in ["", "   \n\t", "\0"] {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            var error: NSString?
            provider.askOtto(pasteboard, userData: nil, error: &error)
            XCTAssertEqual(error as String?, "Otto didn't receive any text.")
        }
        pasteboard.clearContents()
        var error: NSString?
        provider.askOtto(pasteboard, userData: nil, error: &error)
        XCTAssertEqual(error as String?, "Otto didn't receive any text.")

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(handler.calls.isEmpty)
    }

    func testHandlersNeverWaitOnTheViewModel() async {
        handler.blocksTextRequests = true
        pasteboard.clearContents()
        pasteboard.setString("text", forType: .string)
        var error: NSString?

        // Returns even though the handler is still suspended.
        provider.askOtto(pasteboard, userData: nil, error: &error)
        XCTAssertNil(error)
        await waitForCalls(1)
        XCTAssertEqual(handler.calls.count, 1)
        handler.releaseTextRequests()
    }

    func testMissingRequestingAppIsPassedAsNil() async {
        let anonymous = ServicesProvider(handler: handler, frontmostApp: { nil })
        pasteboard.clearContents()
        pasteboard.setString("text", forType: .string)
        var error: NSString?
        anonymous.askOtto(pasteboard, userData: nil, error: &error)
        await waitForCalls(1)
        XCTAssertEqual(handler.calls, [.askText("text", nil)])
    }

    // MARK: Files

    func testAskOttoAboutFiles() async throws {
        let urls = try writeFiles(["a.txt", "b.pdf"])
        XCTAssertEqual(ServicesProvider.fileURLs(from: pasteboard).map(\.standardizedFileURL),
                       urls.map(\.standardizedFileURL))
        var error: NSString?

        provider.askOttoAboutFiles(pasteboard, userData: nil, error: &error)
        XCTAssertNil(error)
        await waitForCalls(1)

        guard case .askFiles(let received, let app) = handler.calls.first else { return XCTFail("No files call") }
        XCTAssertEqual(received.map(\.standardizedFileURL), urls.map(\.standardizedFileURL))
        XCTAssertEqual(app, pages)
    }

    func testAddToShelfOpensTheShelf() async throws {
        let urls = try writeFiles(["photo.png"])
        var error: NSString?

        provider.addToShelf(pasteboard, userData: nil, error: &error)
        XCTAssertNil(error)
        await waitForCalls(1)

        guard case .shelf(let received, let openShelf) = handler.calls.first else { return XCTFail("No shelf call") }
        XCTAssertEqual(received.map(\.standardizedFileURL), urls.map(\.standardizedFileURL))
        XCTAssertTrue(openShelf)
    }

    func testFileServicesRefusePasteboardsWithoutFiles() async {
        pasteboard.clearContents()
        pasteboard.setString("https://example.com", forType: .string)
        XCTAssertTrue(ServicesProvider.fileURLs(from: pasteboard).isEmpty)

        var filesError: NSString?
        provider.askOttoAboutFiles(pasteboard, userData: nil, error: &filesError)
        XCTAssertEqual(filesError as String?, "Otto didn't receive any files.")

        var shelfError: NSString?
        provider.addToShelf(pasteboard, userData: nil, error: &shelfError)
        XCTAssertEqual(shelfError as String?, "Otto didn't receive any files.")

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(handler.calls.isEmpty)
    }
}

// MARK: - Fake handler

@MainActor private final class ServicesHandlerFake: ServicesHandling {
    enum Call: Equatable {
        case askText(String, AppRef?)
        case askFiles([URL], AppRef?)
        case shelf([URL], Bool)
    }

    private(set) var calls: [Call] = []
    var blocksTextRequests = false
    private var blocked: [CheckedContinuation<Void, Never>] = []

    func askAbout(serviceText: String, app: AppRef?) async {
        calls.append(.askText(serviceText, app))
        if blocksTextRequests {
            await withCheckedContinuation { blocked.append($0) }
        }
    }

    func askAbout(fileURLs: [URL], app: AppRef?) {
        calls.append(.askFiles(fileURLs, app))
    }

    func addToShelf(fileURLs: [URL], openShelf: Bool) {
        calls.append(.shelf(fileURLs, openShelf))
    }

    func releaseTextRequests() {
        let pending = blocked
        blocked.removeAll()
        pending.forEach { $0.resume() }
    }
}
