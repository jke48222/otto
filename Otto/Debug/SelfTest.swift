//
//  SelfTest.swift
//  Otto
//
//  `--selftest <dir>`: drives the real notch stack (AppSettings in a throwaway defaults suite,
//  ChatSession on MockLLMClient, NotchViewModel, NotchWindowController on the real screen) through a
//  scripted session — open, type, send, stream, close mid-reply, reopen, new chat, attach files — and
//  exercises the pointer state machine against the live geometry. Writes `report.json` (pass/fail per
//  step) and PNG captures of the panel's content view into <dir>, then exits: 0 when every step
//  passed, 1 otherwise, 3 if the run wedged.
//
//  It never moves the pointer, clicks, or touches other apps; browser-tab suggestions are turned off
//  so no Automation prompt can appear.
//

// Debug tooling: compiled only into Debug builds, or into a Release build made with the
// OTTO_TOOLS compilation condition (scripts/make_media.sh does this to record footage).
#if DEBUG || OTTO_TOOLS

import AppKit
import os
import Quartz

@MainActor
final class SelfTest {
    // MARK: Entry point

    static func start(reportingTo directory: URL) {
        let test = SelfTest(directory: directory)
        running = test
        // Watchdog on a background queue: a wedged main thread still ends the process.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 180) {
            FileHandle.standardError.write(Data("Self-test timed out.\n".utf8))
            exit(3)
        }
        Task { @MainActor in
            let passed = await test.run()
            exit(passed ? 0 : 1)
        }
    }

    private static var running: SelfTest?
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "SelfTest")

    // MARK: Report

    private struct StepReport: Encodable {
        var name: String
        var passed: Bool
        var failures: [String]
        /// Checks that can't be made in this session (e.g. key status while the screen is locked).
        var skipped: [String]
        var notes: [String]
        var captures: [String]
        var durationMs: Int
    }

    private struct Report: Encodable {
        var startedAt: String
        var screen: String
        var screenLocked: Bool
        var passed: Int
        var failed: Int
        var steps: [StepReport]
    }

    private let directory: URL
    private var steps: [StepReport] = []
    private var current: StepReport?

    // MARK: Stack

    private let suiteName = "otto.selftest.\(UUID().uuidString)"
    private var settings: AppSettings?
    private var chat: ChatSession?
    private var viewModel: NotchViewModel?
    private var controller: NotchWindowController?
    private var tempFiles: [URL] = []

    private init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Script

    private func run() async -> Bool {
        let startedAt = ISO8601DateFormatter().string(from: Date())
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("Couldn't create \(directory.path): \(error.localizedDescription)\n".utf8))
            return false
        }

        await step("launch stack") { try await self.launch() }
        if steps.last?.passed == true, let vm = viewModel, let chat, let controller {
            await step("open programmatically with focus") { await self.openWithFocus(vm, controller) }
            await step("type into the composer") { await self.typeIntoComposer(vm, controller) }
            await step("send and stream a reply") { await self.sendAndStream(vm, chat, controller) }
            await step("close while a reply streams") { await self.closeWhileStreaming(vm, chat, controller) }
            await step("reopen clears unread") { await self.reopen(vm, controller) }
            await step("new chat") { await self.newChat(vm, chat) }
            await step("attach files and remove a chip") { try await self.attachFiles(vm, controller) }
            await step("send with an attachment") { await self.sendWithAttachment(vm, chat, controller) }
            await step("pointer machine on live geometry") { self.pointerMachine(vm, controller) }
            await step("live click-through matches the machine") { self.liveClickThrough(vm, controller) }
            await step("close returns focus") { await self.closeReturnsFocus(vm, controller) }
        }

        cleanUp()
        let screen = controller.map { controller -> String in
            let geometry = controller.debugGeometry
            return "frame \(geometry.screenFrame), notch \(geometry.notchRect), physical \(geometry.hasPhysicalNotch)"
        } ?? "unknown"
        let failed = steps.filter { !$0.passed }.count
        let report = Report(startedAt: startedAt, screen: screen, screenLocked: Self.isScreenLocked, passed: steps.count - failed, failed: failed, steps: steps)
        writeReport(report)
        for step in steps {
            print("\(step.passed ? "PASS" : "FAIL")  \(step.name)"
                  + (step.failures.isEmpty ? "" : " — " + step.failures.joined(separator: "; "))
                  + (step.skipped.isEmpty ? "" : " [skipped: " + step.skipped.joined(separator: "; ") + "]"))
        }
        print("\(report.passed) passed, \(report.failed) failed → \(directory.appendingPathComponent("report.json").path)")
        return failed == 0
    }

    // MARK: Steps

    private func launch() async throws {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fail("Couldn't create a UserDefaults suite")
            return
        }
        let settings = AppSettings(defaults: defaults)
        // No AppleScript lookups (and so no Automation prompt) during the run.
        settings.suggestBrowserTab = false
        settings.autoAttachBrowserTab = false
        settings.model = .opus5
        settings.webAccess = true
        let chat = ChatSession(settings: settings, makeClient: { MockLLMClient(latencyScale: 0.2) })
        let viewModel = NotchViewModel(settings: settings, chat: chat)
        let controller = NotchWindowController(viewModel: viewModel, settings: settings)
        controller.showWindow()

        self.settings = settings
        self.chat = chat
        self.viewModel = viewModel
        self.controller = controller

        await pause(0.4)
        let panel = controller.debugPanel
        let geometry = controller.debugGeometry
        check(panel.isVisible, "panel is on screen")
        check(!viewModel.isOpen, "starts closed")
        check(panel.frame == geometry.windowFrame, "panel frame \(panel.frame) == geometry window frame \(geometry.windowFrame)")
        check(abs(panel.frame.maxY - geometry.screenFrame.maxY) < 0.5, "panel top is flush with the screen top")
        check(abs(panel.frame.midX - geometry.notchRect.midX) < 0.5, "panel is centered on the notch")
        check(viewModel.closedNotchSize == geometry.closedSize, "view model has the notch size")
        note("geometry: screen \(geometry.screenFrame), notch \(geometry.notchRect), physical \(geometry.hasPhysicalNotch)")
        check(viewModel.renderedShapeSize.width <= geometry.maximumClosedShapeSize.width,
              "closed shape (\(viewModel.renderedShapeSize)) fits the closed notch")
        capture("01-closed")
    }

    private func openWithFocus(_ vm: NotchViewModel, _ controller: NotchWindowController) async {
        vm.open(reason: .programmatic, focus: true)
        let panel = controller.debugPanel
        check(vm.isOpen, "view model is open")
        check(vm.isEngaged, "view model is engaged")
        let settled = await waitUntil(2) { vm.renderedShapeSize.width >= NotchMetrics.openWidth - 0.5 }
        check(settled, "UI reports the open shape width (\(vm.renderedShapeSize))")
        let focused = await waitUntil(2) { self.composerTextView(panel) != nil && (panel.isKeyWindow || Self.isScreenLocked) }
        note("app active: \(NSApp.isActive), key window: \(String(describing: NSApp.keyWindow?.title)), "
             + "panel canBecomeKey: \(panel.canBecomeKey), frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
        checkFocus(panel.isKeyWindow, "panel is key")
        check(focused, "composer is first responder (first responder: \(String(describing: panel.firstResponder)))")
        check(!panel.ignoresMouseEvents || !shapeContainsPointer(vm, controller),
              "panel accepts the mouse when the pointer is over the shape")
        await pause(0.5)
        capture("02-open-empty")
    }

    private func typeIntoComposer(_ vm: NotchViewModel, _ controller: NotchWindowController) async {
        let panel = controller.debugPanel
        vm.composerText = "What's new in Swift"
        let mirrored = await waitUntil(1) { self.composerTextView(panel)?.string == "What's new in Swift" }
        check(mirrored, "composer shows the view model's text (shows \(composerTextView(panel)?.string ?? "nil"))")
        // Type through the real text view: the binding must carry it back to the view model.
        if let textView = composerTextView(panel) {
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            textView.insertText("?", replacementRange: textView.selectedRange())
        }
        let typed = await waitUntil(1) { vm.composerText == "What's new in Swift?" }
        check(typed, "typing updates the view model (composerText = \(vm.composerText))")
        check(vm.canSend, "canSend")
        await pause(0.2)
        capture("03-composer")
    }

    private func sendAndStream(_ vm: NotchViewModel, _ chat: ChatSession, _ controller: NotchWindowController) async {
        let panel = controller.debugPanel
        // Return in the composer submits.
        if let textView = composerTextView(panel) {
            textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }
        let submitted = await waitUntil(1) { chat.messageCount == 2 }
        check(submitted, "Return in the composer sends (messages: \(chat.messageCount), composer: \(vm.composerText.debugDescription))")
        if !submitted {
            vm.composerText = "What's new in Swift?"
            vm.send()
        }
        check(chat.isStreaming, "chat is streaming")
        check(vm.composerText.isEmpty, "composer cleared after send")
        check(vm.isEngaged && vm.isOpen, "stays open and engaged")
        check(chat.messages.first?.text == "What's new in Swift?", "user message text")

        let started = await waitUntil(8) { (chat.messages.last?.text.count ?? 0) > 40 }
        check(started, "reply text starts streaming")
        let hasActivity = chat.messages.last?.activities.isEmpty == false
        check(hasActivity, "web-search activity shown while streaming")
        capture("04-streaming")

        let finished = await waitUntil(20) { !chat.isStreaming }
        check(finished, "reply finishes")
        guard let reply = chat.messages.last else { return fail("no assistant message") }
        check(reply.role == .assistant, "last message is the assistant")
        check(reply.state == .complete, "assistant message complete (\(reply.state))")
        check(reply.text.contains("demo reply"), "reply has the scripted text")
        check(reply.text.contains("```swift"), "reply has the code block")
        check(reply.sources.count >= 1, "reply has sources (\(reply.sources.count))")
        check(reply.activities.allSatisfy(\.isDone), "all activities done")
        check(!reply.thinking.isEmpty, "summarized thinking recorded")
        check(reply.model == MockLLMClient.demoModel, "model recorded (\(reply.model ?? "nil"))")
        check(!reply.apiContent.isEmpty, "API content recorded for history")
        check(chat.hasCopyableReply, "Copy Last Response is available")
        check(chat.lastMessageState == .complete, "lastMessageState summary is .complete")
        check(!vm.hasUnreadReply, "no unread badge while open")
        await pause(0.6)
        capture("05-reply")
    }

    private func closeWhileStreaming(_ vm: NotchViewModel, _ chat: ChatSession, _ controller: NotchWindowController) async {
        let panel = controller.debugPanel
        vm.composerText = "Tell me more"
        vm.send()
        check(chat.isStreaming, "second reply streams")
        _ = await waitUntil(5) { (chat.messages.last?.text.count ?? 0) > 0 }
        vm.close()
        check(!vm.isOpen, "closed")
        check(!vm.isEngaged, "no longer engaged")
        check(chat.isStreaming, "reply keeps streaming after close")
        check(vm.showsClosedActivity, "closed notch shows activity ears")
        let earsDrawn = await waitUntil(2) {
            vm.renderedShapeSize.width >= vm.closedNotchSize.width + 2 * NotchMetrics.activityEarWidth - 0.5
        }
        check(earsDrawn, "closed shape grows by the activity ears (\(vm.renderedShapeSize))")
        checkFocus(!panel.isKeyWindow, "panel gave up key status")
        // The open content leaves with an animated transition; capture once it has gone.
        await pause(0.7)
        check(chat.isStreaming, "still streaming when captured")
        capture("06-closed-streaming")

        let finished = await waitUntil(20) { !chat.isStreaming }
        check(finished, "second reply finishes while closed")
        check(chat.messages.last?.state == .complete, "second reply complete")
        check(vm.hasUnreadReply, "hasUnreadReply after finishing while closed")
        check(vm.showsClosedActivity, "ears stay for the unread reply")
        await pause(0.5)
        capture("07-closed-unread")
    }

    private func reopen(_ vm: NotchViewModel, _ controller: NotchWindowController) async {
        vm.open(reason: .programmatic, focus: true)
        check(vm.isOpen, "open again")
        check(!vm.hasUnreadReply, "unread cleared on open")
        let settled = await waitUntil(2) { vm.renderedShapeSize.width >= NotchMetrics.openWidth - 0.5 }
        check(settled, "open width again")
        check(vm.renderedShapeSize.height <= NotchMetrics.maxOpenHeight + 0.5,
              "open height within the cap (\(vm.renderedShapeSize.height))")
        let panel = controller.debugPanel
        let focused = await waitUntil(2) { self.composerTextView(panel) != nil && (panel.isKeyWindow || Self.isScreenLocked) }
        check(focused, "composer is first responder again")
        checkFocus(panel.isKeyWindow, "panel is key again")
        await pause(0.6)
        capture("08-reopened-conversation")
    }

    private func newChat(_ vm: NotchViewModel, _ chat: ChatSession) async {
        vm.newChat()
        check(chat.messages.isEmpty, "messages cleared")
        check(chat.messageCount == 0 && chat.lastMessageState == nil, "summaries reset")
        check(!chat.hasCopyableReply, "nothing to copy")
        check(vm.isOpen, "still open")
        await pause(0.5)
        capture("09-new-chat")
    }

    private func attachFiles(_ vm: NotchViewModel, _ controller: NotchWindowController) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("otto-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        tempFiles.append(folder)
        let textURL = folder.appendingPathComponent("notes.txt")
        try "Remember the milk.\nAnd the bread.".write(to: textURL, atomically: true, encoding: .utf8)
        let imageURL = folder.appendingPathComponent("swatch.png")
        try Self.makePNG().write(to: imageURL)

        vm.addFiles([textURL, imageURL])
        check(vm.pendingAttachmentLoads == 2, "two placeholder chips while loading (\(vm.pendingAttachmentLoads))")
        check(!vm.canSend, "can't send while loading")
        let loaded = await waitUntil(5) { vm.pendingAttachmentLoads == 0 }
        check(loaded, "loads finish")
        check(vm.attachments.count == 2, "two chips (\(vm.attachments.map(\.displayName)))")
        check(vm.attachments.map(\.displayName) == ["notes.txt", "swatch.png"], "chips keep the picked order")
        check(vm.attachments.first?.kind == .text && vm.attachments.first?.badge == "TXT", "text chip kind/badge")
        check(vm.attachments.last?.kind == .image && vm.attachments.last?.badge == "PNG", "image chip kind/badge")
        check(vm.attachments.last?.thumbnail != nil, "image chip has a thumbnail")
        check(vm.transientError == nil, "no error (\(vm.transientError ?? ""))")

        vm.addFiles([textURL])
        await pause(0.3)
        check(vm.attachments.count == 2 && vm.pendingAttachmentLoads == 0, "the same file isn't attached twice")
        await pause(0.4)
        capture("10-chips")

        if let text = vm.attachments.first {
            vm.removeAttachment(id: text.id)
        }
        check(vm.attachments.map(\.displayName) == ["swatch.png"], "removed the text chip")
        await pause(0.5)
        capture("11-chip-removed")
    }

    private func sendWithAttachment(_ vm: NotchViewModel, _ chat: ChatSession, _ controller: NotchWindowController) async {
        vm.composerText = "What color is this?"
        vm.send()
        check(vm.attachments.isEmpty, "chips cleared on send")
        guard let user = chat.messages.first else { return fail("no user message") }
        check(user.attachments.count == 1, "user message carries the attachment")
        check(user.apiContent.first?.typeName == "image", "image block goes first")
        check(user.apiContent.last?.typeName == "text", "text block last")
        let finished = await waitUntil(20) { !chat.isStreaming }
        check(finished, "reply finishes")
        check(chat.messages.last?.text.contains("1 attachment") == true
              || chat.messages.last?.text.contains("one attachment") == true
              || chat.messages.last?.text.contains("an attachment") == true,
              "reply mentions the attachment (\(chat.messages.last?.text.prefix(90) ?? ""))")
        await pause(0.6)
        capture("12-reply-with-attachment")
    }

    /// Drives a fresh `NotchPointerMachine` with synthetic points around the live notch.
    private func pointerMachine(_ vm: NotchViewModel, _ controller: NotchWindowController) {
        let geometry = controller.debugGeometry
        let closedSize = geometry.closedSize
        let openSize = CGSize(width: NotchMetrics.openWidth, height: min(vm.renderedShapeSize.height, NotchMetrics.maxOpenHeight))
        let notch = geometry.notchRect
        let center = CGPoint(x: notch.midX, y: notch.midY)
        // Beside the widest (open) shape, level with the notch: off every zone whatever the height.
        let farAway = CGPoint(x: notch.midX + NotchMetrics.openWidth / 2 + 120, y: notch.midY - 60)
        let dwell = NotchPointerMachine.Configuration().hoverDwell

        func context(_ point: CGPoint, _ now: TimeInterval, open: Bool = false, stayOpen: Bool = false,
                     button: Bool = false) -> NotchPointerMachine.Context {
            NotchPointerMachine.Context(
                point: point,
                isButtonPressed: button,
                dragPasteboardChangeCount: { 0 },
                isOpen: open,
                openReason: open ? .hover : nil,
                shouldStayOpen: stayOpen,
                isEngaged: stayOpen,
                isMenuPresented: false,
                hasTransientError: false,
                renderedShapeSize: open ? openSize : closedSize,
                geometry: geometry,
                now: now
            )
        }

        // Resting on the notch opens it after the dwell.
        var machine = NotchPointerMachine()
        var effects = machine.handle(.refresh, context(center, 0))
        check(effects.contains(.setIgnoresMouseEvents(false)), "closed: pointer on the notch is not click-through")
        check(effects.contains(.setHovering(true)), "closed: hovering on the notch")
        check(effects.contains(.scheduleTimer(.hoverOpen, at: dwell)), "closed: dwell timer armed")
        effects = machine.handle(.timerFired(.hoverOpen), context(center, dwell))
        check(effects.last == .open(.hover, focus: false), "rest for \(Int(dwell * 1000)) ms opens by hover")

        // Far away: click-through, no hover.
        machine = NotchPointerMachine()
        effects = machine.handle(.refresh, context(farAway, 0))
        check(effects.contains(.setIgnoresMouseEvents(true)), "closed: pointer elsewhere is click-through")
        check(!effects.contains(.setHovering(true)), "closed: pointer elsewhere is not hovering")

        // Hot-zone margin beside the notch: takes clicks but never opens on hover.
        machine = NotchPointerMachine()
        let margin = CGPoint(x: notch.minX - 5, y: notch.midY)
        effects = machine.handle(.refresh, context(margin, 0))
        check(effects.contains(.setIgnoresMouseEvents(false)), "margin: not click-through")
        check(!effects.contains { if case .scheduleTimer(.hoverOpen, _) = $0 { return true }; return false },
              "margin: no hover dwell")

        // A sweep across the menu bar at 1000 pt/s never opens.
        machine = NotchPointerMachine()
        var now: TimeInterval = 0
        var pending: TimeInterval?
        var opened = false
        var x = notch.minX - 60
        while x <= notch.maxX + 60 {
            if let deadline = pending, deadline <= now {
                pending = nil
                let fired = machine.handle(.timerFired(.hoverOpen), context(CGPoint(x: x, y: center.y), now))
                opened = opened || fired.contains(.open(.hover, focus: false))
                pending = Self.hoverDeadline(in: fired) ?? pending
            }
            let moved = machine.handle(.refresh, context(CGPoint(x: x, y: center.y), now))
            opened = opened || moved.contains(.open(.hover, focus: false))
            if moved.contains(.cancelTimer(.hoverOpen)) { pending = nil }
            pending = Self.hoverDeadline(in: moved) ?? pending
            x += 5
            now += 0.005
        }
        check(!opened, "a 1000 pt/s sweep across the notch doesn't open it")

        // Open: over the shape accepts the mouse; leaving schedules a close unless it should stay open.
        let shape = geometry.shapeRect(size: openSize)
        let inside = CGPoint(x: shape.midX, y: shape.midY)
        machine = NotchPointerMachine()
        effects = machine.handle(.refresh, context(inside, 0, open: true))
        check(effects.contains(.setIgnoresMouseEvents(false)), "open: pointer over the shape is not click-through")
        effects = machine.handle(.refresh, context(farAway, 1, open: true))
        check(effects.contains(.setIgnoresMouseEvents(true)), "open: pointer away is click-through")
        check(effects.contains(.scheduleTimer(.exitClose, at: 1.3)), "open: leaving schedules the 300 ms close")
        effects = machine.handle(.timerFired(.exitClose), context(farAway, 1.3, open: true))
        check(effects.last == .close, "open: close fires after 300 ms away")

        machine = NotchPointerMachine()
        _ = machine.handle(.refresh, context(inside, 0, open: true, stayOpen: true))
        effects = machine.handle(.refresh, context(farAway, 1, open: true, stayOpen: true))
        check(!effects.contains { if case .scheduleTimer(.exitClose, _) = $0 { return true }; return false },
              "open + engaged: leaving doesn't schedule a close")

        machine = NotchPointerMachine()
        _ = machine.handle(.refresh, context(inside, 0, open: true))
        effects = machine.handle(.mouseDown(.left, .elsewhere), context(farAway, 0.1, open: true))
        check(effects.last == .close, "open: a click in another app closes")

        // The drawn shape: centre inside, the rounded bottom corner and beside the body outside.
        check(NotchHitTest.shapeContains(inside, rect: shape, topRadius: NotchMetrics.openTopRadius,
                                         bottomRadius: NotchMetrics.openBottomRadius), "hit test: centre is on the shape")
        let corner = CGPoint(x: shape.minX + NotchMetrics.openTopRadius + 3, y: shape.minY + 3)
        check(!NotchHitTest.shapeContains(corner, rect: shape, topRadius: NotchMetrics.openTopRadius,
                                          bottomRadius: NotchMetrics.openBottomRadius), "hit test: rounded bottom corner is off the shape")
        let beside = CGPoint(x: shape.minX + 3, y: shape.midY)
        check(!NotchHitTest.shapeContains(beside, rect: shape, topRadius: NotchMetrics.openTopRadius,
                                          bottomRadius: NotchMetrics.openBottomRadius), "hit test: beside the body (under the flare) is off the shape")
    }

    /// The real panel's click-through state should be what the machine computes for the real pointer.
    private func liveClickThrough(_ vm: NotchViewModel, _ controller: NotchWindowController) {
        let pointer = NSEvent.mouseLocation
        let overShape = shapeContainsPointer(vm, controller)
        note("pointer at \(pointer); over the open shape: \(overShape)")
        check(controller.debugPanel.ignoresMouseEvents == !overShape,
              "panel.ignoresMouseEvents (\(controller.debugPanel.ignoresMouseEvents)) == !over shape (\(!overShape))")
    }

    private func closeReturnsFocus(_ vm: NotchViewModel, _ controller: NotchWindowController) async {
        vm.close()
        let panel = controller.debugPanel
        let settled = await waitUntil(2) { vm.renderedShapeSize.width <= vm.closedNotchSize.width + 0.5 }
        check(settled, "closed shape is back to the notch size (\(vm.renderedShapeSize))")
        checkFocus(!panel.isKeyWindow, "panel isn't key after close")
        check(panel.isVisible, "panel stays ordered in (closed notch)")
        check(!vm.showsClosedActivity, "no ears when nothing is unread")
        await pause(0.3)
        capture("13-closed-again")
    }

    // MARK: - Helpers

    private func step(_ name: String, _ body: () async throws -> Void) async {
        let start = ContinuousClock.now
        current = StepReport(name: name, passed: true, failures: [], skipped: [], notes: [], captures: [], durationMs: 0)
        do {
            try await body()
        } catch {
            fail("threw: \(error.localizedDescription)")
        }
        guard var finished = current else { return }
        let elapsed = ContinuousClock.now - start
        finished.durationMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        finished.passed = finished.failures.isEmpty
        steps.append(finished)
        current = nil
        Self.logger.info("\(finished.passed ? "PASS" : "FAIL", privacy: .public) \(name, privacy: .public)")
    }

    private func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { fail(message()) }
    }

    /// A check about keyboard focus. While the screen is locked (loginwindow is frontmost) AppKit makes
    /// no window key, so the check is recorded as skipped instead.
    private func checkFocus(_ condition: Bool, _ message: @autoclosure () -> String) {
        if Self.isScreenLocked {
            if !condition { current?.skipped.append(message() + " (screen locked)") }
        } else {
            check(condition, message())
        }
    }

    private static var isScreenLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) == true
            || (session?["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    private func fail(_ message: String) {
        current?.failures.append(message)
    }

    private func note(_ message: String) {
        current?.notes.append(message)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    /// Polls `condition` on the main actor every 20 ms; false on timeout.
    private func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// The composer's text view when it is the panel's first responder.
    private func composerTextView(_ panel: NSPanel) -> NSTextView? {
        guard let textView = panel.firstResponder as? NSTextView, textView.isEditable else { return nil }
        return textView
    }

    private func shapeContainsPointer(_ vm: NotchViewModel, _ controller: NotchWindowController) -> Bool {
        let geometry = controller.debugGeometry
        return NotchHitTest.shapeContains(
            NSEvent.mouseLocation,
            rect: geometry.shapeRect(size: vm.renderedShapeSize),
            topRadius: NotchMetrics.openTopRadius,
            bottomRadius: NotchMetrics.openBottomRadius
        )
    }

    private static func hoverDeadline(in effects: [NotchPointerMachine.Effect]) -> TimeInterval? {
        for effect in effects {
            if case .scheduleTimer(.hoverOpen, let deadline) = effect { return deadline }
        }
        return nil
    }

    /// Captures the panel's content view (the live SwiftUI hierarchy) at 2×.
    private func capture(_ name: String) {
        guard let view = controller?.debugPanel.contentView else { return fail("no content view to capture") }
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return fail("couldn't allocate a capture bitmap") }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        // Composite onto a mid-grey backdrop so the transparent window area and the shadow read clearly.
        let backdrop = NSImage(size: size, flipped: false) { rect in
            NSColor(deviceWhite: 0.55, alpha: 1).setFill()
            rect.fill()
            rep.draw(in: rect)
            return true
        }
        let url = directory.appendingPathComponent("\(name).png")
        guard let tiff = backdrop.tiffRepresentation, let flattened = NSBitmapImageRep(data: tiff),
              let data = flattened.representation(using: .png, properties: [:])
        else { return fail("couldn't encode \(name).png") }
        do {
            try data.write(to: url, options: .atomic)
            current?.captures.append(url.lastPathComponent)
        } catch {
            fail("couldn't write \(url.path): \(error.localizedDescription)")
        }
    }

    private func writeReport(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Couldn't write the report: \(error.localizedDescription)\n".utf8))
        }
    }

    private func cleanUp() {
        chat?.reset()
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    /// A small opaque PNG (a warm gradient swatch).
    private static func makePNG() throws -> Data {
        let size = 64
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw CocoaError(.fileWriteUnknown) }
        for y in 0..<size {
            for x in 0..<size {
                rep.setColor(NSColor(deviceRed: CGFloat(x) / 63, green: 0.45, blue: CGFloat(y) / 63, alpha: 1), atX: x, y: y)
            }
        }
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}

#endif
