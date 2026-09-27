//
//  SelectionTests.swift
//  OttoTests
//
//  Selection snapshots, their attachments and labels, and the read guards (secure input, sensitive apps,
//  password fields) through a fake Accessibility probe: nothing here calls the Accessibility API.
//

import AppKit
import ApplicationServices
import XCTest
@testable import Otto

final class SelectionTests: XCTestCase {
    private let notes = AppRef(pid: 6161, bundleID: "com.apple.Notes", name: "Notes")
    private let chrome = AppRef(pid: 6262, bundleID: "com.google.Chrome", name: "Google Chrome")
    private let safari = AppRef(pid: 6363, bundleID: "com.apple.Safari", name: "Safari")

    // MARK: Snapshot and attachment

    func testMakeAttachment() throws {
        let snapshot = SelectionSnapshot(text: "Fix the typo", app: notes, windowTitle: "Draft", range: nil,
                                         element: nil, source: .accessibility)
        let attachment = try snapshot.makeAttachment()

        XCTAssertEqual(attachment.kind, .text)
        XCTAssertEqual(attachment.displayName, "Selection from Notes")
        XCTAssertEqual(attachment.badge, "SEL")
        XCTAssertEqual(attachment.appBundleID, "com.apple.Notes")
        XCTAssertEqual(attachment.sourceURL?.scheme, "otto-selection")
        XCTAssertEqual(attachment.sourceURL?.absoluteString, "otto-selection:\(snapshot.fingerprint)")
        XCTAssertEqual(attachment.payload, .text("Fix the typo"))
        XCTAssertFalse(attachment.retainsPayloadInHistory)
    }

    func testAttachmentWithoutAnAppIsNamedSelection() throws {
        let snapshot = SelectionSnapshot(text: "text", app: nil, windowTitle: nil, range: nil, element: nil,
                                         source: .service)
        XCTAssertEqual(try snapshot.makeAttachment().displayName, "Selection")
        XCTAssertNil(try snapshot.makeAttachment().appBundleID)
    }

    func testSameTextHasTheSameSourceForDedupe() throws {
        let first = SelectionSnapshot(text: "same words", app: notes, windowTitle: nil, range: nil, element: nil,
                                      source: .accessibility)
        let second = SelectionSnapshot(text: "same words", app: nil, windowTitle: nil, range: nil, element: nil,
                                       source: .service)
        let other = SelectionSnapshot(text: "other words", app: notes, windowTitle: nil, range: nil, element: nil,
                                      source: .accessibility)
        XCTAssertEqual(try first.makeAttachment().sourceURL?.absoluteString,
                       try second.makeAttachment().sourceURL?.absoluteString)
        XCTAssertNotEqual(try first.makeAttachment().sourceURL, try other.makeAttachment().sourceURL)
        XCTAssertEqual(first.fingerprint.count, 16)
        XCTAssertTrue(first.fingerprint.allSatisfy(\.isHexDigit))
    }

    func testWhitespaceOnlyIsRejected() {
        let snapshot = SelectionSnapshot(text: " \n\t ", app: notes, windowTitle: nil, range: nil, element: nil,
                                         source: .service)
        XCTAssertThrowsError(try snapshot.makeAttachment()) { error in
            XCTAssertEqual(error as? AttachmentError, .empty(name: "Selection from Notes"))
        }
    }

    func testOverTheCharacterLimitIsRejected() {
        let text = String(repeating: "a", count: AttachmentLoader.maxTextCharacters + 1)
        let snapshot = SelectionSnapshot(text: text, app: notes, windowTitle: nil, range: nil, element: nil,
                                         source: .service)
        XCTAssertThrowsError(try snapshot.makeAttachment())
        XCTAssertFalse(SelectionReader.isOfferable(text))
        XCTAssertTrue(SelectionReader.isOfferable(String(text.dropLast())))
    }

    func testNULIsStripped() throws {
        let snapshot = SelectionSnapshot(text: "a\0b", app: notes, windowTitle: nil, range: nil, element: nil,
                                         source: .service)
        XCTAssertEqual(snapshot.text, "ab")
        XCTAssertEqual(try snapshot.makeAttachment().payload, .text("ab"))
    }

    func testGhostLabels() {
        func label(_ text: String) -> String {
            SelectionSnapshot(text: text, app: nil, windowTitle: nil, range: nil, element: nil, source: .service).ghostLabel
        }
        XCTAssertEqual(label("Fix typo"), "Selection · “Fix typo”")
        XCTAssertEqual(label("  one   two\nthree "), "Selection · “one two three”")
        XCTAssertEqual(label("one two three four"), "Selection · 4 words")
        XCTAssertEqual(label(String(repeating: "word ", count: 42)), "Selection · 42 words")
        XCTAssertEqual(label("https://example.com/a/very/long/path"), "Selection · 1 word")
        XCTAssertEqual(label("an extraordinarily lengthy"), "Selection · 3 words")
        XCTAssertEqual(SelectionSnapshot(text: "a b c d", app: nil, windowTitle: nil, range: nil, element: nil,
                                         source: .service).wordCount, 4)
    }

    func testWindowTitleIsSanitized() {
        let snapshot = SelectionSnapshot(text: "x", app: notes, windowTitle: "Draft\u{202E}\u{200B}\nNotes",
                                         range: nil, element: nil, source: .accessibility)
        XCTAssertEqual(snapshot.windowTitle, "Draft Notes")
    }

    // MARK: Read guards

    func testSecureInputReadsNothing() async {
        let probe = SelectionProbeFake(secureInput: true, focused: .init(role: "AXTextArea", selectedText: "secret"))
        let result = await SelectionReader.read(from: notes, probe: probe.probe)
        XCTAssertNil(result)
        XCTAssertEqual(probe.focusedReads, 0)
    }

    func testExcludedAppsAreNeverRead() async {
        let probe = SelectionProbeFake(focused: .init(role: "AXTextArea", selectedText: "vault"))
        for bundleID in SelectionReader.excludedBundleIDs {
            let app = AppRef(pid: 7000, bundleID: bundleID, name: "Vault")
            let result = await SelectionReader.read(from: app, probe: probe.probe)
            XCTAssertNil(result, bundleID)
        }
        let byName = AppRef(pid: 7001, bundleID: "com.example.vault", name: "My Password Safe")
        let named = await SelectionReader.read(from: byName, probe: probe.probe)
        XCTAssertNil(named)
        XCTAssertEqual(probe.focusedReads, 0)
    }

    func testSecureTextFieldSubroleIsSkipped() async {
        let probe = SelectionProbeFake(focused: .init(role: "AXTextField", subrole: "AXSecureTextField",
                                                      selectedText: "hunter2"))
        let result = await SelectionReader.read(from: notes, probe: probe.probe)
        XCTAssertNil(result)
    }

    func testChromiumPasswordFieldWithoutSubroleIsSkipped() async {
        let byClass = SelectionProbeFake(focused: .init(role: "AXTextField", domClassList: ["input", "Password-Field"],
                                                        selectedText: "hunter2"))
        let classResult = await SelectionReader.read(from: chrome, probe: byClass.probe)
        XCTAssertNil(classResult)

        let byDescription = SelectionProbeFake(focused: .init(role: "AXTextField", elementDescription: "Password",
                                                              selectedText: "hunter2"))
        let descriptionResult = await SelectionReader.read(from: chrome, probe: byDescription.probe)
        XCTAssertNil(descriptionResult)

        // An ordinary Chromium text field is read.
        let search = SelectionProbeFake(focused: .init(role: "AXTextField", domClassList: ["search"],
                                                       selectedText: "otto notch"))
        let searchResult = await SelectionReader.read(from: chrome, probe: search.probe)
        XCTAssertEqual(searchResult?.text, "otto notch")

        // The heuristic is for Chromium; Safari reports AXSecureTextField itself.
        XCTAssertFalse(SelectionReader.isChromiumFamily(safari))
        XCTAssertTrue(SelectionReader.isChromiumFamily(chrome))
    }

    func testReadsASelection() async {
        let element = AXElementRef(AXUIElementCreateApplication(notes.pid))
        let probe = SelectionProbeFake(focused: .init(role: "AXTextArea", selectedText: "Hello\0 world",
                                                      selectedRange: CFRange(location: 4, length: 11),
                                                      windowTitle: "Shopping", element: element))
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = await SelectionReader.read(from: notes, probe: probe.probe, now: now)

        XCTAssertEqual(snapshot?.text, "Hello world")
        XCTAssertEqual(snapshot?.app, notes)
        XCTAssertEqual(snapshot?.windowTitle, "Shopping")
        XCTAssertEqual(snapshot?.range?.location, 4)
        XCTAssertEqual(snapshot?.range?.length, 11)
        XCTAssertEqual(snapshot?.element, element)
        XCTAssertEqual(snapshot?.source, .accessibility)
        XCTAssertEqual(snapshot?.capturedAt, now)
    }

    func testNothingSelectedOrTooLongReadsNothing() async {
        let empty = SelectionProbeFake(focused: .init(role: "AXTextArea", selectedText: "   "))
        let emptyResult = await SelectionReader.read(from: notes, probe: empty.probe)
        XCTAssertNil(emptyResult)

        let none = SelectionProbeFake(focused: .init(role: "AXTextArea", selectedText: nil))
        let noneResult = await SelectionReader.read(from: notes, probe: none.probe)
        XCTAssertNil(noneResult)

        let long = SelectionProbeFake(focused: .init(role: "AXTextArea",
                                                     selectedText: String(repeating: "x", count: 400_001)))
        let longResult = await SelectionReader.read(from: notes, probe: long.probe)
        XCTAssertNil(longResult)

        let unavailable = SelectionProbeFake(focused: nil)
        let unavailableResult = await SelectionReader.read(from: notes, probe: unavailable.probe)
        XCTAssertNil(unavailableResult)
    }

    // MARK: Services snapshots

    func testServiceSnapshotAdoptsTheMatchingAXSelection() async {
        let element = AXElementRef(AXUIElementCreateApplication(notes.pid))
        let probe = SelectionProbeFake(focused: .init(role: "AXTextArea", selectedText: "make this friendlier",
                                                      selectedRange: CFRange(location: 0, length: 20), element: element))
        let snapshot = await SelectionReader.snapshot(serviceText: "make this friendlier", app: notes, probe: probe.probe)
        XCTAssertEqual(snapshot.source, .service)
        XCTAssertEqual(snapshot.element, element)
        XCTAssertEqual(snapshot.range?.length, 20)

        let different = await SelectionReader.snapshot(serviceText: "something else", app: notes, probe: probe.probe)
        XCTAssertNil(different.element)
        XCTAssertNil(different.range)
        XCTAssertEqual(different.text, "something else")

        let secure = SelectionProbeFake(secureInput: true, focused: probe.focused)
        let guarded = await SelectionReader.snapshot(serviceText: "make this friendlier", app: notes, probe: secure.probe)
        XCTAssertNil(guarded.element)
        XCTAssertEqual(guarded.text, "make this friendlier")
    }

    func testInertReaderNeverReads() async {
        let reader = InertSelectionReader()
        let read = await reader.read(from: notes)
        XCTAssertNil(read)
        let snapshot = await reader.snapshot(serviceText: "hello", app: notes)
        XCTAssertEqual(snapshot.text, "hello")
        XCTAssertEqual(snapshot.source, .service)
        XCTAssertNil(snapshot.element)
    }

    // MARK: Sensitive apps

    func testSensitiveAppsByBundleIDAndName() {
        XCTAssertTrue(SensitiveApps.contains(AppRef(pid: 1, bundleID: "com.1password.1password", name: "1Password")))
        XCTAssertTrue(SensitiveApps.contains(AppRef(pid: 1, bundleID: "COM.APPLE.KEYCHAINACCESS", name: "x")))
        XCTAssertTrue(SensitiveApps.contains(AppRef(pid: 1, bundleID: "me.proton.pass.electron", name: "Proton Pass")))
        XCTAssertTrue(SensitiveApps.contains(AppRef(pid: 1, bundleID: nil, name: "KeePassXC")))
        XCTAssertTrue(SensitiveApps.contains(AppRef(pid: 1, bundleID: "com.example", name: "Passwords")))
        XCTAssertFalse(SensitiveApps.contains(AppRef(pid: 1, bundleID: "com.apple.Notes", name: "Notes")))
        XCTAssertEqual(SelectionReader.excludedBundleIDs, SensitiveApps.bundleIDs)
    }
}

// MARK: - Fake probe

private final class SelectionProbeFake: @unchecked Sendable {
    let secureInput: Bool
    let focused: SelectionReader.FocusedElement?
    private let lock = NSLock()
    private var reads = 0

    init(secureInput: Bool = false, focused: SelectionReader.FocusedElement?) {
        self.secureInput = secureInput
        self.focused = focused
    }

    var focusedReads: Int { lock.withLock { reads } }

    var probe: SelectionReader.Probe {
        SelectionReader.Probe(
            isSecureInputEnabled: { [secureInput] in secureInput },
            focusedElement: { [self] _ in
                lock.withLock { reads += 1 }
                return focused
            }
        )
    }
}
