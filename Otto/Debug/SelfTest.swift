//
//  SelfTest.swift
//  Otto
//
//  `--selftest <dir>`: drives the real app stack, built by `AppComposition.selfTest(directory:)` (MockLLMClient,
//  demo action and media services, a mutable permission probe, preferences in a throwaway suite, History under
//  <dir>/History, everything else in memory, the notch window on the real screen), through a scripted session:
//  the v1.0 steps (open, type, send, stream, close mid-reply, reopen, new chat, attach files, pointer machine on
//  the live geometry), then the v1.1 steps of SPEC-v2 §10.2 (tool approvals and arming, the actions demo, the
//  fold for System Settings, routes, soft focus, the key map, regenerate, pin, Settings on the current Space,
//  scripted voice, Services, the Shelf, drop zones, a dry-run paste, permission cards, the closed-notch glance,
//  History and, on a signed build, a few real system probes). Writes `report.json` (pass/fail per step) and PNG
//  captures of the panel's content view into <dir>, then exits: 0 when every step passed, 1 otherwise, 3 if the
//  run wedged.
//
//  It never moves the pointer, clicks, posts key events outside its own panel, pastes into another app or
//  opens System Settings (the composition records the URLs instead); browser-tab suggestions are off so no
//  Automation prompt can appear.
//

// Debug tooling: compiled only into Debug builds, or into a Release build made with the
// OTTO_TOOLS compilation condition (scripts/make_media.sh does this to record footage).
#if DEBUG || OTTO_TOOLS

import AppKit
import Carbon.HIToolbox
import EventKit
import os
import Quartz
import Security

@MainActor
final class SelfTest {
    // MARK: Entry point

    /// How long the whole run may take before the watchdog ends the process (SPEC-v2 §10.2, R12).
    private static let watchdogSeconds: Double = 420

    static func start(reportingTo directory: URL) {
        let test = SelfTest(directory: directory)
        running = test
        // Watchdog on a background queue: a wedged main thread still ends the process.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + watchdogSeconds) {
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

    private var composition: AppComposition?
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
        if steps.last?.passed == true, let composition, let vm = viewModel, let chat, let controller {
            // v1.0 steps (checks unchanged).
            await step("open programmatically with focus") { await self.openWithFocus(vm, controller) }
            await step("type into the composer") { await self.typeIntoComposer(vm, controller) }
            await step("send and stream a reply") { await self.sendAndStream(vm, chat, controller) }
            await step("close while a reply streams") { await self.closeWhileStreaming(vm, chat, controller) }
            await step("reopen clears unread") { await self.reopen(vm, controller) }
            await step("new chat") { await self.newChat(vm, chat) }
            await step("attach files and remove a chip") { try await self.attachFiles(vm, controller) }
            await step("send with an attachment") { await self.sendWithAttachment(vm, chat, controller) }
            await step("pointer machine on live geometry") { await self.pointerMachine(vm, controller) }
            await step("live click-through matches the machine") { self.liveClickThrough(vm, controller) }
            await step("close returns focus") { await self.closeReturnsFocus(vm, controller) }

            // v1.1 steps (SPEC-v2 §10.2, in order).
            await step("tool approval", retryable: true) { await self.toolApproval(vm, chat) }
            await step("tool deny", retryable: true) { await self.toolDeny(vm, chat) }
            await step("stop during approval", retryable: true) { await self.stopDuringApproval(vm, chat) }
            await step("arming follows visibility", retryable: true) { await self.armingFollowsVisibility(vm, chat) }
            await step("actions demo", retryable: true) { await self.actionsDemo(composition, vm, chat) }
            await step("fold", retryable: true) { await self.fold(composition, vm, controller) }
            await step("routes & sheet", retryable: true) { await self.routesAndSheet(vm, controller) }
            await step("soft-focus", retryable: true) { await self.softFocus(vm, chat, controller) }
            await step("key-commands", retryable: true) { await self.keyCommands(vm, chat, controller) }
            await step("regenerate", retryable: true) { await self.regenerate(vm, chat, controller) }
            await step("pinned-outside-click", retryable: true) { await self.pinnedOutsideClick(vm, controller) }
            await step("settings-space", retryable: true) { await self.settingsSpace(composition, vm) }
            await step("voice-scripted", retryable: true) { await self.voiceScripted(composition, vm, chat, controller) }
            await step("servicesAsk", retryable: true) { await self.servicesAsk(vm, chat, controller) }
            await step("shelfDrop", retryable: true) { try await self.shelfDrop(vm) }
            await step("dropZones", retryable: true) { await self.dropZones(vm) }
            await step("insertDryRun", retryable: true) { await self.insertDryRun() }
            await step("permissionCard", retryable: true) { await self.permissionCard(vm, controller) }
            await step("glance", retryable: true) { await self.glance(vm, chat, controller) }
            await step("history", retryable: true) { await self.history(composition, vm, chat) }
            await step("real probes", retryable: true) { await self.realProbes() }
        }

        let screen = controller.map { controller -> String in
            let geometry = controller.debugGeometry
            return "frame \(geometry.screenFrame), notch \(geometry.notchRect), physical \(geometry.hasPhysicalNotch)"
        } ?? "unknown"
        cleanUp()
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

    // MARK: - v1.0 steps

    private func launch() async throws {
        let composition = AppComposition.selfTest(directory: directory)
        let settings = composition.settings
        settings.model = .opus5
        settings.webAccess = true
        composition.start()
        self.composition = composition
        guard let controller = composition.notchWindowController else {
            fail("the self-test graph has no notch window")
            return
        }
        let viewModel = composition.viewModel

        self.settings = settings
        self.chat = composition.chat
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
        let folder = try makeTempFolder()
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
    private func pointerMachine(_ vm: NotchViewModel, _ controller: NotchWindowController) async {
        // The open shape is measured from the UI: let a transition that is still running finish first.
        let openSettled = await waitUntil(2) {
            vm.renderedShapeSize.width >= NotchMetrics.openWidth - 0.5
                && vm.renderedShapeSize.height >= NotchMetrics.openTopRadius + NotchMetrics.openBottomRadius + 1
        }
        if !openSettled {
            note("the open shape hadn't settled (\(vm.renderedShapeSize)); measuring it as it is")
        }
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

    // MARK: - v1.1: tool loop and approvals (§10.2 steps 1–5)

    /// "run my shortcut": the card waits its arming delay from the moment it was seen; an early ⌘↩ does nothing.
    private func toolApproval(_ vm: NotchViewModel, _ chat: ChatSession) async {
        await startFreshChat(vm, chat)
        vm.composerText = Self.shortcutPrompt
        vm.send()
        guard let shown = await waitForVisibleApproval(vm, chat) else { return }
        let (approval, visibility) = shown
        check(approval.toolName == "run_shortcut", "the card is for run_shortcut (\(approval.toolName))")
        let armedAt = visibility.sinceUptime + approval.armingDelay.timeInterval
        let pressedEarly = ProcessInfo.processInfo.systemUptime < armedAt
        vm.perform(.promptPrimary, hardwareConfirmed: true)
        if pressedEarly {
            check(chat.pendingApproval?.callID == approval.callID, "⌘↩ before the card armed leaves it pending")
            check(toolCall(approval.callID, in: chat)?.status == .awaitingApproval,
                  "the call still awaits approval (\(String(describing: toolCall(approval.callID, in: chat)?.status)))")
        } else {
            current?.skipped.append("the early ⌘↩ check (the card armed before the self-test could press)")
        }
        await settleShape(viewModel)
        capture("approval")

        let approved = await approveOnceArmed(approval, vm, chat)
        check(approved, "⌘↩ after arming answers the card")
        let ran = await waitUntil(10) { self.toolCall(approval.callID, in: chat)?.status == .succeeded }
        check(ran, "⌘↩ after arming runs the call (\(String(describing: toolCall(approval.callID, in: chat)?.status)))")
        check(toolCall(approval.callID, in: chat)?.approvedVia != nil, "the call records how it was approved")
        let finished = await waitUntil(20) { !chat.isStreaming }
        check(finished, "the reply finishes after the tool round")
        let text = chat.messages.last?.text ?? ""
        check(text.contains(Self.shortcutOutput), "the final text quotes the shortcut's output (\(text.prefix(120)))")
    }

    /// Esc on the card declines it; the notch stays open and the reply says so.
    private func toolDeny(_ vm: NotchViewModel, _ chat: ChatSession) async {
        await ensureOpenEngaged(vm)
        vm.composerText = Self.shortcutPrompt
        vm.send()
        guard let approval = await waitForVisibleApproval(vm, chat)?.0 else { return }
        vm.perform(.promptSecondary, hardwareConfirmed: false)
        let denied = await waitUntil(5) { self.toolCall(approval.callID, in: chat)?.status == .denied }
        check(denied, "Esc declines the call (\(String(describing: toolCall(approval.callID, in: chat)?.status)))")
        check(chat.pendingApproval == nil, "no card after declining")
        check(vm.isOpen, "the notch stays open")
        let finished = await waitUntil(20) { !chat.isStreaming }
        check(finished, "the reply finishes")
        let text = chat.messages.last?.text ?? ""
        check(text.contains("You declined"), "the reply says it was declined (\(text.prefix(120)))")
    }

    /// ⌘. while the card is up cancels the call and keeps the exchange.
    private func stopDuringApproval(_ vm: NotchViewModel, _ chat: ChatSession) async {
        await ensureOpenEngaged(vm)
        vm.composerText = Self.shortcutPrompt
        vm.send()
        let asked = await waitUntil(15) { chat.pendingApproval != nil }
        guard asked, let approval = chat.pendingApproval else { return fail("an approval card appears") }
        vm.perform(.stop, hardwareConfirmed: false)
        let stopped = await waitUntil(5) { chat.pendingApproval == nil && !chat.isStreaming }
        check(stopped, "⌘. removes the card and stops the reply")
        let status = toolCall(approval.callID, in: chat)?.status
        check(status == .cancelled, "the call is cancelled (\(String(describing: status)))")
        let message = chat.messages.last { $0.id == approval.messageID }
        check(message?.toolExchanges.isEmpty == false, "the exchange is kept on the reply")
    }

    /// A card created while the notch was closed arms only after it has been on screen for its delay.
    private func armingFollowsVisibility(_ vm: NotchViewModel, _ chat: ChatSession) async {
        await ensureOpenEngaged(vm)
        vm.composerText = Self.shortcutPrompt
        vm.send()
        vm.close(.user)
        let created = await waitUntil(15) { chat.pendingApproval != nil }
        guard created, let approval = chat.pendingApproval else { return fail("the approval is created while closed") }
        check(!vm.isOpen, "the notch stayed closed")
        check(vm.approvalVisibility == nil, "no visibility stamp while closed")
        await pause(2)
        check(vm.approvalVisibility == nil, "still no visibility stamp after 2 s closed")

        let openedAt = Date()
        vm.open(reason: .programmatic, focus: true)
        let seen = await waitUntil(5) { vm.approvalVisibility?.callID == approval.callID }
        guard seen, let visibility = vm.approvalVisibility else { return fail("the card is stamped visible after opening") }
        check(visibility.since >= openedAt,
              "visibility counts from the open (\(visibility.since.timeIntervalSince(openedAt)) s after it), not from creation")
        let armedAt = visibility.sinceUptime + approval.armingDelay.timeInterval
        let pressedEarly = ProcessInfo.processInfo.systemUptime < armedAt
        vm.perform(.promptPrimary, hardwareConfirmed: true)
        if pressedEarly {
            check(chat.pendingApproval?.callID == approval.callID, "an immediate ⌘↩ after opening is ignored")
        } else {
            current?.skipped.append("the immediate ⌘↩ check (the card armed before the self-test could press)")
        }
        let approved = await approveOnceArmed(approval, vm, chat)
        check(approved, "after the arming delay ⌘↩ answers the card")
        let ran = await waitUntil(10) { self.toolCall(approval.callID, in: chat)?.status == .succeeded }
        check(ran, "after the arming delay it runs (\(String(describing: toolCall(approval.callID, in: chat)?.status)))")
        let finished = await waitUntil(20) { !chat.isStreaming }
        check(finished, "the reply finishes")
    }

    /// "add dentist to my calendar" on the demo EventKit store, then Undo and the note Claude gets about it.
    private func actionsDemo(_ composition: AppComposition, _ vm: NotchViewModel, _ chat: ChatSession) async {
        await startFreshChat(vm, chat)
        let store = composition.actionServices.eventKit
        let before = await dentistEvents(in: store)
        vm.composerText = "add dentist to my calendar"
        vm.send()
        guard let approval = await waitForVisibleApproval(vm, chat)?.0 else { return }
        check(approval.toolName == "calendar_create_event", "the card is for calendar_create_event (\(approval.toolName))")
        if case .event(let preview) = approval.body {
            check(preview.title == "Dentist", "the event card shows “Dentist” (\(preview.title))")
            let selected = preview.selectedCalendarID ?? ""
            check(selected.hasPrefix("demo-calendar"), "the card picks a demo calendar (\(selected))")
            check(preview.calendars.contains { $0.id == selected }, "the picked calendar is one of the card's choices")
        } else {
            fail("the card shows an event (\(approval.body))")
        }
        if case .permission = approval.kind {
            note("the card asks for Calendars access first; once granted the approval comes back and arms again")
        }
        let approved = await approveOnceArmed(approval, vm, chat)
        check(approved, "⌘↩ after arming answers the card")
        let created = await waitUntil(10) { self.toolCall(approval.callID, in: chat)?.status == .succeeded }
        check(created, "approving adds the event (\(String(describing: toolCall(approval.callID, in: chat)?.status)))")
        let after = await dentistEvents(in: store)
        check(after.count == before.count + 1, "the demo calendar has the new event (\(before.count) → \(after.count))")
        let finished = await waitUntil(20) { !chat.isStreaming }
        check(finished, "the reply finishes")

        vm.undoToolCall(approval.callID, in: approval.messageID)
        let undone = await waitUntil(5) { self.toolCall(approval.callID, in: chat)?.status == .undone }
        check(undone, "Undo marks the call undone (\(String(describing: toolCall(approval.callID, in: chat)?.status)))")
        let afterUndo = await dentistEvents(in: store)
        check(afterUndo.count == before.count, "Undo removed the event (\(afterUndo.count) left)")

        vm.composerText = "Thanks"
        vm.send()
        let carriesNote = chat.lastUserMessage?.apiContent.contains { block in
            block["text"]?.stringValue?.contains("the user undid an action") == true
        } == true
        check(carriesNote, "the next message tells Claude about the undo")
        let answered = await waitUntil(20) { !chat.isStreaming }
        check(answered, "the follow-up reply finishes")
    }

    // MARK: - v1.1: fold, routes, soft focus, keys (§10.2 steps 6–12)

    /// A permission flow that opens System Settings folds the notch out of its way and brings it back on the grant.
    private func fold(_ composition: AppComposition, _ vm: NotchViewModel, _ controller: NotchWindowController) async {
        guard let probe = composition.permissionProbe else { return fail("the self-test graph has a mutable permission probe") }
        await ensureOpenEngaged(vm)
        probe.set(.calendars, .denied)
        let openedBefore = composition.openedExternalURLs.count
        let flow = SelfTestFlowResult()
        Task { @MainActor in
            flow.granted = await vm.requestPermission(.calendars, for: .calendarGlance)
        }
        let explained = await waitUntil(5) { vm.permissionPrompt?.phase == .explain }
        guard explained else { return fail("the Calendars card explains first (\(String(describing: vm.permissionPrompt)))") }
        check(vm.permissionCardContent?.primaryAction == .openSystemSettings,
              "a denied permission offers Open System Settings (\(String(describing: vm.permissionCardContent?.primaryAction)))")
        vm.perform(.promptPrimary, hardwareConfirmed: true)

        let folded = await waitUntil(5) { vm.presentation == .closed && vm.isFolded }
        check(folded, "the notch folds while System Settings is up (presentation \(vm.presentation), folded \(vm.isFolded))")
        check(composition.openedExternalURLs.count == openedBefore + 1
              && composition.openedExternalURLs.last == Permission.calendars.settingsURL,
              "System Settings was asked for the Calendars pane (\(composition.openedExternalURLs.suffix(1)))")
        let waitingText = SystemUIWait.systemSettings(.calendars).dropText
        check(vm.closedGlance.drop == .systemWait(waitingText),
              "the closed notch says “\(waitingText)” (\(String(describing: vm.closedGlance.drop)))")
        check(waitingText == "Waiting for System Settings…", "the wait text is exact (\(waitingText))")
        let dropDrawn = await waitUntil(3) { vm.renderedShapeSize.height > vm.closedNotchSize.height + 0.5 }
        check(dropDrawn, "the closed shape shows the waiting line (\(vm.renderedShapeSize))")
        await pause(0.5)
        await settleShape(viewModel)
        capture("closed-waiting")

        probe.set(.calendars, .granted)
        var trace: [String] = []
        let reopened = await waitUntil(6) {
            let state = "open \(vm.isOpen) folded \(vm.isFolded) phase \(String(describing: vm.permissionPrompt?.phase)) "
                + "wait \(String(describing: vm.systemUIWait)) awaiting \(String(describing: vm.permissions.awaiting))"
            if trace.last != state { trace.append(state) }
            return vm.isOpen && vm.permissionPrompt?.phase == .granted
        }
        if !reopened { note("states: " + trace.joined(separator: " → ")) }
        check(reopened, "the notch reopens on the “You're all set” card after the grant (open \(vm.isOpen), "
              + "phase \(String(describing: vm.permissionPrompt?.phase)))")
        check(!vm.isEngaged, "it reopens without taking the keyboard")
        checkFocus(!controller.debugPanel.isKeyWindow, "the panel isn't key after the unfold")
        let resolved = await waitUntil(5) { flow.granted != nil }
        check(resolved && flow.granted == true, "the flow reports the grant (\(String(describing: flow.granted)))")
        check(!vm.isFolded, "no longer folded")
    }

    /// ⌘/ shows the shortcut sheet, Esc hides it; ⌘Y Recents, ⌘D Shelf, Esc back to Chat.
    private func routesAndSheet(_ vm: NotchViewModel, _ controller: NotchWindowController) async {
        await ensureOpenEngaged(vm)
        await pressKey(kVK_ANSI_Slash, "/", .command, vm, controller)
        check(vm.overlay == .shortcutSheet, "⌘/ shows the shortcut sheet (\(String(describing: vm.overlay)))")
        await pause(0.5)
        await settleShape(viewModel)
        capture("shortcuts")
        await pressKey(kVK_Escape, "\u{1b}", [], vm, controller)
        check(vm.overlay == nil, "Esc dismisses the sheet")
        check(vm.isOpen, "and keeps the notch open")
        await pressKey(kVK_ANSI_Y, "y", .command, vm, controller)
        check(vm.route == .history, "⌘Y opens Recents (\(vm.route))")
        await pressKey(kVK_ANSI_D, "d", .command, vm, controller)
        check(vm.route == .shelf, "⌘D opens the Shelf (\(vm.route))")
        await pressKey(kVK_Escape, "\u{1b}", [], vm, controller)
        check(vm.route == .chat, "Esc goes back to Chat (\(vm.route))")
        check(vm.isOpen, "the notch is still open")
    }

    /// interaction.md §8.2 step 1, plus: ⌘↩ while only soft-focused hands the keyboard back and approves nothing.
    private func softFocus(_ vm: NotchViewModel, _ chat: ChatSession, _ controller: NotchWindowController) async {
        let panel = controller.debugPanel
        // A card waits in the dock, so a ⌘↩ that reached it could approve something.
        await startFreshChat(vm, chat)
        vm.composerText = Self.shortcutPrompt
        vm.send()
        let asked = await waitUntil(15) { chat.pendingApproval != nil }
        guard asked, let approval = chat.pendingApproval else { return fail("an approval card appears") }

        // The machine hands soft focus back as soon as the real pointer is off the panel, and the self-test never
        // moves the pointer: with "Type after hovering" off the machine leaves soft focus to the view model.
        let settings = vm.settings
        let typeAfterHover = settings.notch.typeAfterHover
        settings.notch.typeAfterHover = false
        defer { settings.notch.typeAfterHover = typeAfterHover }

        vm.close()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        vm.open(reason: .hover, focus: false)
        // The real pointer is wherever the user left it: pin so the exit timer can't close the hover-open notch.
        vm.togglePin()
        check(vm.isOpen && !vm.isEngaged, "hover-open without focus")
        let notKey = await waitUntil(1) { !panel.isKeyWindow }
        check(notKey, "a hover-open panel isn't key")

        vm.softFocus()
        check(vm.isSoftFocused && !vm.isEngaged, "soft focus is not engagement")
        let tookKey = await waitUntil(2) { panel.isKeyWindow || Self.isScreenLocked }
        checkFocus(tookKey && panel.isKeyWindow, "soft focus makes the panel key")
        let composerFocused = await waitUntil(2) { self.composerTextView(panel) != nil || Self.isScreenLocked }
        checkFocus(composerFocused && composerTextView(panel) != nil, "the composer is first responder under soft focus")
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost,
              "the frontmost app is unchanged (Otto never activates for soft focus)")
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        note("seconds since the last key-down (R4): \(sinceKey)")

        await pressKey(kVK_Return, "\r", .command, vm, controller, retakeKeyboard: false)
        let handedBack = await waitUntil(2) { !vm.isSoftFocused && !panel.isKeyWindow }
        check(handedBack, "⌘↩ while soft-focused hands the keyboard back (soft \(vm.isSoftFocused), key \(panel.isKeyWindow))")
        check(chat.pendingApproval?.callID == approval.callID
              && toolCall(approval.callID, in: chat)?.status == .awaitingApproval,
              "⌘↩ while soft-focused approves nothing")
        check(vm.isOpen, "the notch stays open")

        vm.softFocus()
        _ = await waitUntil(2) { panel.isKeyWindow || Self.isScreenLocked }
        vm.releaseSoftFocus()
        let released = await waitUntil(2) { !panel.isKeyWindow }
        check(released, "releasing soft focus gives up key status")
        check(panel.isVisible && vm.isOpen, "the panel stays visible and open")

        vm.performPromptSecondary()
        _ = await waitUntil(20) { !chat.isStreaming }
        vm.togglePin()
    }

    /// interaction.md §8.2 step 2: ⌘/, ↑, ⌘P and ⌘⇧↑ through the panel's own key handling.
    private func keyCommands(_ vm: NotchViewModel, _ chat: ChatSession, _ controller: NotchWindowController) async {
        let panel = controller.debugPanel
        await startFreshChat(vm, chat)
        vm.composerText = "Summarize the Swift 6 migration guide"
        vm.send()
        let answered = await waitUntil(20) { !chat.isStreaming && chat.messageCount == 2 }
        check(answered, "a conversation to work with")
        _ = await waitUntil(2) { self.composerTextView(panel) != nil || Self.isScreenLocked }

        await pressKey(kVK_ANSI_Slash, "/", .command, vm, controller)
        check(vm.overlay == .shortcutSheet, "⌘/ toggles the sheet on")
        await pause(0.5)
        await settleShape(viewModel)
        capture("20-shortcuts")
        await pressKey(kVK_ANSI_Slash, "/", .command, vm, controller)
        check(vm.overlay == nil, "⌘/ toggles the sheet off")

        let question = chat.lastUserMessage?.text ?? ""
        await pressKey(kVK_UpArrow, Self.upArrowCharacters, [], vm, controller)
        check(vm.isEditing, "↑ in an empty composer recalls the last question")
        check(vm.composerText == question, "the composer holds the question (\(vm.composerText))")
        let caretAtEnd = await waitUntil(1) {
            guard let textView = self.composerTextView(panel) else { return Self.isScreenLocked }
            return textView.string == question
                && textView.selectedRange() == NSRange(location: (textView.string as NSString).length, length: 0)
        }
        checkFocus(caretAtEnd, "the caret sits at the end of the recalled text")
        await pause(0.4)
        await settleShape(viewModel)
        capture("21-editing")
        await pressKey(kVK_Escape, "\u{1b}", [], vm, controller)
        check(!vm.isEditing && vm.composerText.isEmpty, "Esc cancels editing")

        let wasPinned = vm.isPinned
        await pressKey(kVK_ANSI_P, "p", .command, vm, controller)
        check(vm.isPinned == !wasPinned, "⌘P toggles the pin")
        await pressKey(kVK_ANSI_P, "p", .command, vm, controller)
        check(vm.isPinned == wasPinned, "⌘P again toggles it back")

        let geometry = controller.debugGeometry
        let tallFrameHeight = geometry.tallOpenHeight + NotchMetrics.shadowMargin
        await pressKey(kVK_UpArrow, Self.upArrowCharacters, [.command, .shift], vm, controller)
        check(vm.isTallMode, "⌘⇧↑ enters tall mode")
        let grew = await waitUntil(3) {
            abs(panel.frame.height - tallFrameHeight) < 0.5 && vm.renderedShapeSize.height > NotchMetrics.maxOpenHeight
        }
        check(grew, "the window is tall (\(panel.frame.height) vs \(tallFrameHeight)) and the shape uses it "
              + "(\(vm.renderedShapeSize.height) > \(NotchMetrics.maxOpenHeight))")
        await pause(0.5)
        await settleShape(viewModel)
        capture("22-tall")
        await pressKey(kVK_DownArrow, Self.downArrowCharacters, [.command, .shift], vm, controller)
        check(!vm.isTallMode, "⌘⇧↓ leaves tall mode")
        _ = await waitUntil(3) { vm.renderedShapeSize.height <= NotchMetrics.maxOpenHeight + 0.5 }
    }

    /// interaction.md §8.2 step 3: ⌘R answers the last question again and keeps both versions.
    private func regenerate(_ vm: NotchViewModel, _ chat: ChatSession, _ controller: NotchWindowController) async {
        await ensureOpenEngaged(vm)
        guard chat.lastUserMessage != nil else { return fail("a question to regenerate") }
        await pressKey(kVK_ANSI_R, "r", .command, vm, controller)
        let started = await waitUntil(3) { chat.isStreaming }
        check(started, "⌘R starts a new reply")
        let finished = await waitUntil(20) { !chat.isStreaming }
        check(finished, "the new version completes")
        check(chat.messages.last?.state == .complete, "the new version is complete")
        check(chat.lastTurnVersions?.replies.count == 2,
              "the footer pager has two versions (\(chat.lastTurnVersions?.replies.count ?? 0))")
    }

    /// interaction.md §8.2 step 4: a pinned notch ignores a click in another app.
    private func pinnedOutsideClick(_ vm: NotchViewModel, _ controller: NotchWindowController) async {
        await ensureOpenEngaged(vm)
        if !vm.isPinned { vm.togglePin() }
        check(vm.isPinned, "pinned")
        let geometry = controller.debugGeometry
        let openSize = CGSize(width: NotchMetrics.openWidth, height: min(vm.renderedShapeSize.height, vm.openHeightLimit))
        let shape = geometry.shapeRect(size: openSize)
        let inside = CGPoint(x: shape.midX, y: shape.midY)
        let farAway = CGPoint(x: geometry.notchRect.midX + NotchMetrics.openWidth / 2 + 120, y: geometry.notchRect.midY - 60)

        func context(_ point: CGPoint, _ now: TimeInterval) -> NotchPointerMachine.Context {
            NotchPointerMachine.Context(
                point: point, isButtonPressed: false, dragPasteboardChangeCount: { 0 }, isOpen: true,
                openReason: vm.openReason, shouldStayOpen: false, isEngaged: false, isMenuPresented: false,
                hasTransientError: false, renderedShapeSize: openSize, geometry: geometry, now: now,
                isPinned: vm.isPinned, openShapeLimit: CGSize(width: NotchMetrics.openWidth, height: vm.openHeightLimit)
            )
        }
        var machine = NotchPointerMachine()
        _ = machine.handle(.refresh, context(inside, 0))
        var effects = machine.handle(.mouseDown(.left, .elsewhere), context(farAway, 0.1))
        check(!effects.contains(.close), "a pinned notch ignores a click in another app (\(effects))")
        effects = machine.handle(.refresh, context(farAway, 0.2))
        check(!effects.contains { if case .scheduleTimer(.exitClose, _) = $0 { return true }; return false },
              "and never schedules an exit close")
        await pause(0.5)
        check(vm.isOpen, "the live notch is still open")
        vm.togglePin()
        check(!vm.isPinned, "unpinned again")
    }

    /// interaction.md §8.2 step 5: Settings opens on the current Space without activating Otto.
    private func settingsSpace(_ composition: AppComposition, _ vm: NotchViewModel) async {
        await ensureOpenEngaged(vm)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        vm.openSettings()
        let settingsController = composition.settingsWindowController
        let shown = await waitUntil(3) { settingsController.panel?.isVisible == true }
        guard shown, let panel = settingsController.panel else { return fail("the Settings panel appears") }
        check(!vm.isOpen, "the notch closes for Settings")
        let key = await waitUntil(2) { panel.isKeyWindow || Self.isScreenLocked }
        checkFocus(key && panel.isKeyWindow, "the Settings panel is key")
        // A non-activating panel that is key reports NSApp.isActive == true on this macOS even though another app
        // stays frontmost, so "doesn't activate" is measured on the frontmost app.
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
        check(frontmostAfter == frontmost && frontmostAfter != ownPID,
              "opening Settings doesn't activate Otto (the frontmost app is unchanged)")
        note("NSApp.isActive with Settings key: \(NSApp.isActive)")
        check(panel.isOnActiveSpace, "Settings is on the active Space")
        check(panel.collectionBehavior.contains(.fullScreenAuxiliary), "collection behavior has .fullScreenAuxiliary")
        check(panel.collectionBehavior.contains(.moveToActiveSpace), "collection behavior has .moveToActiveSpace")
        await pause(0.3)
        panel.cancelOperation(nil)
        let closed = await waitUntil(2) { !panel.isVisible }
        check(closed, "Esc (cancelOperation) closes Settings")
    }

    /// interaction.md §8.2 step 6: hold-to-talk on the scripted speech engine with the notch closed.
    private func voiceScripted(_ composition: AppComposition, _ vm: NotchViewModel, _ chat: ChatSession,
                               _ controller: NotchWindowController) async {
        let settings = composition.settings
        await startFreshChat(vm, chat)
        vm.close(.user)
        _ = await waitUntil(2) { vm.renderedShapeSize.width <= vm.closedNotchSize.width + 2 * NotchMetrics.activityEarWidth + 0.5 }
        settings.voice.enabled = true
        settings.voice.autoSend = true
        defer { settings.voice.enabled = false }

        vm.beginVoice(.hold(.shortcut))
        let listening = await waitUntil(3) { vm.voice.isListening }
        check(listening, "holding the shortcut starts listening (\(vm.voice.phase))")
        check(!vm.isOpen, "the notch stays closed while listening")
        let pill = await waitUntil(3) { vm.renderedShapeSize.width >= VoiceMetrics.pillMinWidth - 0.5 }
        check(pill, "the closed notch grows into the listening pill (\(vm.renderedShapeSize.width))")
        let heard = await waitUntil(4) { vm.voice.transcript == AppComposition.selfTestVoiceTranscript }
        check(heard, "the scripted transcript arrives (\(vm.voice.transcript))")
        await pause(0.3)
        await settleShape(viewModel)
        capture("23-closed-listening")

        vm.finishVoice(send: true)
        let sent = await waitUntil(5) { chat.lastUserMessage?.text == AppComposition.selfTestVoiceTranscript }
        check(sent, "releasing sends what was heard (\(chat.lastUserMessage?.text ?? "nothing"))")
        let opened = await waitUntil(3) { vm.isOpen }
        check(opened, "the notch opens for the reply")
        check(vm.openReason == .voice, "opened by voice (\(String(describing: vm.openReason)))")
        checkFocus(!controller.debugPanel.isKeyWindow, "the panel doesn't take the keyboard")
        check(!vm.isEngaged, "not engaged")
        check(vm.voiceReplyHold, "the voice reply hold keeps it open")
        if !vm.voiceReplyHold {
            note("hold gone: engaged \(vm.isEngaged), pointer over the open shape \(shapeContainsPointer(vm, controller)), "
                 + "holds \(vm.stayOpenHolds), streaming \(chat.isStreaming)")
        }
        await pause(0.8)
        await settleShape(viewModel)
        capture("24-voice-reply")
        let finished = await waitUntil(20) { !chat.isStreaming }
        check(finished, "the reply finishes")
        vm.stopSpeaking()
    }

    // MARK: - v1.1: context in and out (§10.2 steps 14–18)

    /// "Ask Otto" through the real Services provider, on a private pasteboard.
    private func servicesAsk(_ vm: NotchViewModel, _ chat: ChatSession, _ controller: NotchWindowController) async {
        vm.close(.user)
        vm.newChat()
        let sourceApp = AppRef(pid: Self.fakeAppPID, bundleID: "com.apple.Notes", name: "Notes")
        let provider = ServicesProvider(handler: vm, frontmostApp: { sourceApp })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("otto.selftest.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("The quarterly numbers are in: revenue is up 12% on last year.", forType: .string)
        var serviceError: NSString?
        provider.askOtto(pasteboard, userData: nil, error: &serviceError)
        check(serviceError == nil, "the service accepts the text (\(serviceError.map { String($0) } ?? ""))")

        let attached = await waitUntil(5) { vm.isOpen && vm.attachments.count == 1 }
        check(attached, "the notch opens with one chip (open \(vm.isOpen), chips \(vm.attachments.map(\.displayName)))")
        check(vm.isEngaged, "engaged")
        check(vm.route == .chat, "on Chat")
        let name = vm.attachments.first?.displayName ?? ""
        check(name.hasPrefix("Selection from"), "the chip reads “Selection from …” (\(name))")
        let panel = controller.debugPanel
        let focused = await waitUntil(2) { (self.composerTextView(panel) != nil && panel.isKeyWindow) || Self.isScreenLocked }
        checkFocus(focused && composerTextView(panel) != nil, "the composer has focus")
        await pause(0.4)
        await settleShape(viewModel)
        capture("services-ask")
        if let chip = vm.attachments.first {
            vm.removeAttachment(id: chip.id)
        }
    }

    /// "Add to Otto Shelf" with the Shelf opening: the page shows the tiles and the landing hold keeps it open.
    private func shelfDrop(_ vm: NotchViewModel) async throws {
        let folder = try makeTempFolder()
        var files: [URL] = []
        for (index, text) in ["Budget draft", "Meeting notes"].enumerated() {
            let url = folder.appendingPathComponent("shelf-\(index + 1).txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            files.append(url)
        }
        vm.close(.user)
        let store = vm.shelf.store
        let before = store.count
        let beforeIDs = Set(store.items.map(\.id))
        vm.addToShelf(fileURLs: files, openShelf: true)
        check(vm.isOpen, "the notch opens for the Shelf")
        check(vm.route == .shelf, "on the Shelf page (\(vm.route))")
        check(!vm.isEngaged, "a Shelf drop doesn't take the keyboard")
        check(store.count == before + files.count, "the Shelf has the new items (\(before) → \(store.count))")
        check(vm.stayOpenHolds.contains(.shelfLanding), "the landing hold keeps it open (\(vm.stayOpenHolds))")
        let added = Set(store.items.map(\.id)).subtracting(beforeIDs)
        check(vm.shelf.selection == added, "the new tiles are selected")
        await pause(0.7)
        await settleShape(viewModel)
        capture("shelf")
        vm.shelf.remove(added)
        let removed = await waitUntil(2) { store.count == before }
        check(removed, "removing the items empties them from the Shelf (\(store.count))")
        check(FileManager.default.fileExists(atPath: files[0].path), "the originals are untouched")
        vm.navigate(to: .chat)
    }

    /// The drop halves against the live open width.
    private func dropZones(_ vm: NotchViewModel) async {
        await ensureOpenEngaged(vm)
        let width = vm.renderedShapeSize.width
        check(width >= NotchMetrics.openWidth - 0.5, "measured on the open shape (\(width))")
        check(DropZone.zone(forX: width * 0.25, width: width, acceptsShelf: true) == .shelf, "left half → Shelf")
        check(DropZone.zone(forX: width * 0.75, width: width, acceptsShelf: true) == .ask, "right half → Ask")
        check(DropZone.zone(forX: width / 2, width: width, acceptsShelf: true) == .ask, "the middle belongs to Ask")
        check(DropZone.zone(forX: width * 0.25, width: width, acceptsShelf: false) == .ask,
              "without a Shelf target everything is Ask")
    }

    /// The paste sequence end to end, against a fake app: nothing reaches the user's clipboard or apps.
    private func insertDryRun() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("otto.selftest.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let seeded = "What the user had copied"
        pasteboard.clearContents()
        pasteboard.setString(seeded, forType: .string)
        let target = AppRef(pid: Self.fakeAppPID, bundleID: "com.example.editor", name: "Editor")
        let keys = SelfTestKeySender()
        let environment = SelfTestInsertEnvironment(target: target)
        let inserter = AnswerInserter(pasteboard: pasteboard, keys: keys, environment: environment)
        let request = InsertRequest(markdown: "The **answer**, pasted.", target: InsertTarget(app: target, selection: nil),
                                    mode: .paste, restoreClipboard: true)
        let preflight = await inserter.preflight(request)
        check(preflight == .ready, "preflight is ready (\(preflight))")
        var relinquished = false
        let outcome = await inserter.perform(request) { relinquished = true }
        check(relinquished, "the notch is asked to give up focus first")
        check(outcome == .pasted(verified: true, clipboard: .restored), "the answer is pasted and verified (\(outcome))")
        check(keys.pasteCount == 1, "exactly one ⌘V (\(keys.pasteCount))")
        check(environment.activationRequests == 1, "the target app is brought forward once (\(environment.activationRequests))")
        check(pasteboard.string(forType: .string) == seeded, "the clipboard holds what it had before")
    }

    /// A permission card in the dock: Esc dismisses the card first, the next Esc closes the notch.
    private func permissionCard(_ vm: NotchViewModel, _ controller: NotchWindowController) async {
        await ensureOpenEngaged(vm)
        let prompt = PermissionPrompt(id: UUID(), permission: .accessibility, purpose: .selection(appName: "Notes"),
                                      phase: .explain)
        vm.debugSeed(features: NotchDebugSeed(permissionPrompt: prompt))
        check(vm.currentPrompt == .permission(prompt), "the dock shows the permission card")
        await pause(0.6)
        await settleShape(viewModel)
        capture("permission")
        await pressKey(kVK_Escape, "\u{1b}", [], vm, controller)
        check(vm.permissionPrompt == nil, "Esc dismisses the card")
        check(vm.isOpen, "before closing the notch")
        await pressKey(kVK_Escape, "\u{1b}", [], vm, controller)
        check(!vm.isOpen, "the next Esc closes the notch")
    }

    // MARK: - v1.1: glance and History (§10.2 steps 19–20)

    /// The closed notch while a reply streams and after: phase ears, the reply preview, the unread dot, and a click
    /// that opens at the start of the answer.
    private func glance(_ vm: NotchViewModel, _ chat: ChatSession, _ controller: NotchWindowController) async {
        await startFreshChat(vm, chat)
        vm.composerText = "Tell me about glances"
        vm.send()
        _ = await waitUntil(5) { (chat.messages.last?.text.count ?? 0) > 0 }
        vm.close()
        check(chat.isStreaming, "the reply streams with the notch closed")
        let ears = await waitUntil(3) {
            abs(vm.renderedShapeSize.width - (vm.closedNotchSize.width + 2 * NotchMetrics.activityEarWidth)) < 0.5
        }
        check(ears, "phase ears: closed width + 68 (\(vm.renderedShapeSize.width) vs \(vm.closedNotchSize.width))")
        check(vm.closedGlance.hasEars, "the glance has ears while streaming")

        let finished = await waitUntil(20) { !chat.isStreaming }
        check(finished, "the reply finishes while closed")
        let finishedAt = ContinuousClock.now
        guard let reply = chat.messages.last, reply.role == .assistant else { return fail("an assistant reply") }
        let previewShown = await waitUntil(3) {
            if case .preview? = vm.closedGlance.drop { return vm.renderedShapeSize.height > vm.closedNotchSize.height + 0.5 }
            return false
        }
        check(previewShown, "the reply preview drops below the notch (\(String(describing: vm.closedGlance.drop)), "
              + "\(vm.renderedShapeSize))")
        if previewShown {
            checkDropGrowthDoesNotHoverOpen(vm, controller)
        }

        // §10.2: 4.6 s after the reply finished the preview has gone and the unread dot shows (a pointer resting on
        // the preview pauses its countdown, so allow a little longer and say so).
        await waitUntilInstant(finishedAt + .milliseconds(4_600))
        var unreadDot = vm.closedGlance.drop == nil
            && (vm.closedGlance.left == .unreadDot || vm.closedGlance.right == .unreadDot)
        if !unreadDot {
            unreadDot = await waitUntil(3) {
                vm.closedGlance.drop == nil && (vm.closedGlance.left == .unreadDot || vm.closedGlance.right == .unreadDot)
            }
            note("the unread dot came \(ContinuousClock.now - finishedAt) after the reply (the preview was paused)")
        }
        check(unreadDot, "the unread dot replaces the preview (\(vm.closedGlance.left), \(vm.closedGlance.right), "
              + "drop \(String(describing: vm.closedGlance.drop)))")
        check(vm.hasUnreadReply, "the reply is unread")

        let openedAt = Date()
        switch ClosedNotchView.clickAction(for: vm.closedGlance, isListening: false) {
        case .openToReply(let messageID):
            vm.openToReply(messageID)
        case .stopSpeakingAndOpen:
            vm.stopSpeaking()
            vm.open(reason: .click, focus: true)
        case .open:
            vm.open(reason: .click, focus: true)
        case .none:
            fail("a click on the closed notch does nothing")
        }
        check(vm.isOpen, "a click opens the notch")
        check(!vm.hasUnreadReply, "opening reads the reply")
        let consumed = await waitUntil(3) { vm.readingAnchor == nil }
        check(consumed, "the conversation consumed the reading anchor")
        let landed = await waitUntil(3) {
            guard let position = vm.history.currentReadingPosition else { return false }
            return position.anchorMessageID == reply.id && position.savedAt >= openedAt
        }
        let position = vm.history.currentReadingPosition
        check(landed, "the reading report names the answer (\(String(describing: position?.anchorMessageID == reply.id)))")
        if let position, landed {
            // The report names the answer as the message being read, so the question above it is scrolled away (its
            // bottom is under the 22 pt top fade) and the answer's top is at most the fade plus the 14 pt row spacing
            // below the viewport top. Above it, the answer is scrolled past by fraction × its height, and the
            // conversation's document height bounds that height.
            let documentHeight = conversationScrollView(in: controller.debugPanel)?.documentView?.frame.height
            let bound = documentHeight ?? Self.fallbackAnswerHeight
            let scrolledPast = position.fractionScrolledPast * bound
            note("answer scrolled past ≤ \(Int(scrolledPast.rounded(.up))) pt (fraction \(position.fractionScrolledPast), "
                 + "document \(documentHeight.map { "\(Int($0)) pt" } ?? "not found"))")
            check(scrolledPast <= 40, "the answer's top is within 40 pt of the viewport top")
            if position.isAtBottom {
                note("the conversation fits the viewport, so the answer is fully visible")
            }
        }
    }

    /// A drop growing under a resting pointer must not hover-open the notch (the notch came to the pointer).
    private func checkDropGrowthDoesNotHoverOpen(_ vm: NotchViewModel, _ controller: NotchWindowController) {
        let geometry = controller.debugGeometry
        let closedSize = geometry.closedSize
        let grownSize = vm.closedLayout.size
        let grownTarget = geometry.hoverTarget(shapeSize: grownSize)
        let point = CGPoint(x: geometry.notchRect.midX, y: grownTarget.minY + 2)
        guard !geometry.hoverTarget(shapeSize: closedSize).contains(point), grownTarget.contains(point) else {
            current?.skipped.append("drop growth check: no point lies under the drop but off the plain notch")
            return
        }
        let dwell = NotchPointerMachine.Configuration().hoverDwell
        func context(_ size: CGSize, _ now: TimeInterval) -> NotchPointerMachine.Context {
            NotchPointerMachine.Context(
                point: point, isButtonPressed: false, dragPasteboardChangeCount: { 0 }, isOpen: false, openReason: nil,
                shouldStayOpen: false, isEngaged: false, isMenuPresented: false, hasTransientError: false,
                renderedShapeSize: size, geometry: geometry, now: now
            )
        }
        var machine = NotchPointerMachine()
        var effects = machine.handle(.refresh, context(closedSize, 0))
        effects += machine.handle(.refresh, context(grownSize, 0.05))
        effects += machine.handle(.refresh, context(grownSize, 0.3))
        effects += machine.handle(.timerFired(.hoverOpen), context(grownSize, 0.3 + dwell))
        effects += machine.handle(.refresh, context(grownSize, 1.5))
        check(!effects.contains(.open(.hover, focus: false)),
              "a drop growing under a resting pointer doesn't hover-open the notch")
    }

    /// history.md §13.2 steps 1–5 on `ConversationStore(.directory(<dir>/History))`.
    private func history(_ composition: AppComposition, _ vm: NotchViewModel, _ chat: ChatSession) async {
        let history = composition.history
        let recents = composition.recents
        let conversations = directory
            .appendingPathComponent("History", isDirectory: true)
            .appendingPathComponent(AppSupport.Directory.conversations.rawValue, isDirectory: true)

        // 1. Save on turn end (a retried step first removes the conversation its first attempt left).
        await startFreshChat(vm, chat)
        for leftover in history.summaries where leftover.title == "History check" {
            history.delete(leftover.id)
            history.commitPendingDeletion()
        }
        vm.composerText = "History check"
        vm.send()
        let finished = await waitUntil(20) { !chat.isStreaming }
        check(finished, "the reply finishes")
        let id = chat.conversationID
        let file = conversations.appendingPathComponent("\(id.uuidString).json")
        let saved = await waitUntil(5) {
            FileManager.default.fileExists(atPath: file.path)
                && history.summaries.contains { $0.id == id && $0.title == "History check" }
        }
        check(saved, "the conversation is saved in Conversations.noindex and indexed as “History check”")
        check(Self.posixPermissions(of: file) == 0o600, "the conversation file is 0600 (\(String(Self.posixPermissions(of: file) ?? 0, radix: 8)))")
        let index = conversations.appendingPathComponent("index.json")
        let indexSaved = await waitUntil(5) { FileManager.default.fileExists(atPath: index.path) }
        check(indexSaved, "the index is written")
        if indexSaved {
            check(Self.posixPermissions(of: index) == 0o600, "the index is 0600")
        }

        // 2. Recents.
        vm.toggleHistory()
        check(vm.route == .history, "⌘Y shows Recents (\(vm.route))")
        check(recents.selectedID != nil, "a row is selected")
        await pause(0.5)
        await settleShape(viewModel)
        capture("recents")
        recents.query = "History check"
        let found = await waitUntil(3) { !recents.isSearching && recents.rows.count == 1 && recents.rows.first?.id == id }
        check(found, "searching finds exactly that conversation (\(recents.rows.map(\.title)))")
        await pause(0.3)
        await settleShape(viewModel)
        capture("recents-search")
        recents.query = ""

        // 3. New chat, then Continue.
        vm.navigate(to: .chat)
        vm.newChat()
        check(chat.messages.isEmpty, "⌘N empties the chat")
        check(history.continuation?.id == id, "the Continue chip offers the conversation just left")
        await pause(0.5)
        await settleShape(viewModel)
        capture("continue-chip")
        vm.continuePreviousConversation()
        let continued = await waitUntil(3) { chat.conversationID == id && chat.messageCount == 2 }
        check(continued, "Continue brings it back (\(chat.messageCount) messages)")

        // 4. Delete with Undo, then for good.
        vm.toggleHistory()
        recents.selectedID = id
        vm.deleteSelectedRecent()
        check(!history.summaries.contains { $0.id == id }, "the row goes at once")
        check(history.pendingDeletion?.id == id, "the Undo bar shows")
        vm.undoRecentDeletion()
        check(history.summaries.contains { $0.id == id }, "Undo brings the row back")
        recents.selectedID = id
        vm.deleteSelectedRecent()
        history.commitPendingDeletion()
        let removed = await waitUntil(5) { !FileManager.default.fileExists(atPath: file.path) }
        check(removed, "committing the deletion removes the file")
        vm.navigate(to: .chat)

        // 5. Idle fresh start, on a side stack whose History reads an injected clock.
        await idleFreshStart(composition.settings)
    }

    /// history.md §13.2 step 5: a HistoryController on a clock the step moves 20 minutes ahead.
    private func idleFreshStart(_ settings: AppSettings) async {
        let previousInterval = settings.history.idleReset
        settings.history.idleReset = .fifteenMinutes
        defer { settings.history.idleReset = previousInterval }
        let clock = SelfTestClock()
        let chat = ChatSession(settings: settings, makeClient: { MockLLMClient(latencyScale: 0) })
        let history = HistoryController(settings: settings, chat: chat, store: ConversationStore(location: .inMemory),
                                        now: { clock.now })
        var services = NotchServices.inert(settings: settings, chat: chat)
        services.history = history
        services.recents = RecentsState(history: history)
        let vm = NotchViewModel(settings: settings, chat: chat, services: services)

        vm.open(reason: .programmatic, focus: true)
        vm.composerText = "Idle check"
        vm.send()
        let answered = await waitUntil(20) { !chat.isStreaming && chat.messageCount == 2 }
        check(answered, "the side stack answers")
        let conversationID = chat.conversationID
        vm.close(.user)
        clock.now = clock.now.addingTimeInterval(20 * 60)
        vm.open(reason: .programmatic, focus: true)
        check(chat.messages.isEmpty, "after 20 idle minutes the notch opens on a fresh chat")
        check(history.continuation?.id == conversationID, "and offers the previous conversation to continue")
        vm.close(.user)
        chat.reset()
    }

    // MARK: - v1.1: real probes (§10.2 step 21)

    /// Only on a build signed with a stable identity: TCC and Apple Events answers mean nothing for an ad-hoc build.
    private func realProbes() async {
        guard let identity = Self.stableSigningIdentity else {
            current?.skipped.append("real probes (this build is signed ad hoc, not with a stable identity)")
            return
        }
        note("signed with \(identity)")
        let status = EKEventStore.authorizationStatus(for: .event)
        note("EventKit authorization status for events: \(status.rawValue)")
        let runner = ProcessRunner()
        do {
            let shortcuts = try await runner.run(URL(fileURLWithPath: "/usr/bin/shortcuts"), arguments: ["list"],
                                                 stdin: nil, timeout: .seconds(20), outputLimit: 256 * 1024)
            check(shortcuts.exitCode == 0 && !shortcuts.timedOut,
                  "`shortcuts list` exits 0 (exit \(shortcuts.exitCode), timed out \(shortcuts.timedOut))")
        } catch {
            fail("`shortcuts list` couldn't run: \(error.localizedDescription)")
        }
        do {
            let script = try await runner.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", "return 1"],
                                              stdin: nil, timeout: .seconds(20), outputLimit: 4096)
            check(script.exitCode == 0 && script.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1",
                  "ProcessRunner runs `osascript -e 'return 1'` (exit \(script.exitCode))")
        } catch {
            fail("osascript couldn't run: \(error.localizedDescription)")
        }
    }

    // MARK: - Step helpers

    private static let shortcutPrompt = "run my shortcut"
    /// DemoShortcutsService's output for “Resize Images”, which the mock's follow-up quotes.
    private static let shortcutOutput = "Resized 12 images"
    /// Slack after a card's arming moment for the executor's own clock.
    private static let armingMargin: TimeInterval = 0.15
    /// A process id no app has: the fake apps the Services and paste steps name.
    private static let fakeAppPID: pid_t = 999_999
    /// An answer taller than any demo reply, for bounding the scroll when no scroll view can be measured.
    private static let fallbackAnswerHeight: Double = 2_000
    private static let upArrowCharacters = String(Character(UnicodeScalar(UInt16(NSUpArrowFunctionKey)) ?? " "))
    private static let downArrowCharacters = String(Character(UnicodeScalar(UInt16(NSDownArrowFunctionKey)) ?? " "))

    /// Open, engaged, on Chat, nothing streaming, with the composer ready.
    private func ensureOpenEngaged(_ vm: NotchViewModel) async {
        if vm.isOpen {
            vm.engage()
        } else {
            vm.open(reason: .programmatic, focus: true)
        }
        if vm.route != .chat {
            vm.navigate(to: .chat)
        }
        if vm.chat.isStreaming {
            vm.chat.cancel()
        }
        let panel = controller?.debugPanel
        _ = await waitUntil(2) {
            vm.renderedShapeSize.width >= NotchMetrics.openWidth - 0.5
                && (panel.map { self.composerTextView($0) != nil } ?? true || Self.isScreenLocked)
        }
    }

    /// `ensureOpenEngaged` plus ⌘N: the step's own conversation.
    private func startFreshChat(_ vm: NotchViewModel, _ chat: ChatSession) async {
        await ensureOpenEngaged(vm)
        vm.newChat()
        _ = await waitUntil(1) { chat.messages.isEmpty }
    }

    /// Waits for the current approval to be on screen and reviewed (its visibility stamp).
    private func waitForVisibleApproval(_ vm: NotchViewModel, _ chat: ChatSession)
        async -> (PendingApproval, NotchViewModel.ApprovalVisibility)? {
        let visible = await waitUntil(15) {
            guard let approval = chat.pendingApproval else { return false }
            return vm.approvalVisibility?.callID == approval.callID
        }
        guard visible, let approval = chat.pendingApproval, let visibility = vm.approvalVisibility else {
            fail("the approval card is shown and reviewed (pending: \(chat.pendingApproval != nil), "
                 + "visible: \(vm.approvalVisibility != nil))")
            return nil
        }
        return (approval, visibility)
    }

    /// Presses ⌘↩ (trusted input) once the card has armed for its current visibility stamp. If the stamp moved (the
    /// card left the screen and came back) the arming starts over, so it waits again, up to three times.
    private func approveOnceArmed(_ approval: PendingApproval, _ vm: NotchViewModel, _ chat: ChatSession) async -> Bool {
        let callID = approval.callID
        for attempt in 1...4 {
            let stamped = await waitUntil(5) { vm.approvalVisibility?.callID == callID }
            guard stamped, let visibility = vm.approvalVisibility, let card = chat.pendingApproval, card.callID == callID
            else {
                note("attempt \(attempt): the card isn't stamped visible (open \(vm.isOpen), route \(vm.route), "
                     + "prompt \(String(describing: vm.currentPrompt?.id)))")
                continue
            }
            await waitUntilUptime(visibility.sinceUptime + card.armingDelay.timeInterval + Self.armingMargin)
            vm.perform(.promptPrimary, hardwareConfirmed: true)
            // Answered once the call leaves its card: it runs (a permission card first runs its steps, then the
            // approval comes back as a fresh card that arms from zero again).
            let answered = await waitUntil(3) {
                guard let status = self.toolCall(callID, in: chat)?.status else { return false }
                return status != .awaitingApproval && status != .needsPermission && status != .queued
            }
            if answered { return true }
            let restamped = vm.approvalVisibility.map { $0.since != visibility.since } ?? true
            note("attempt \(attempt): the \(Self.label(of: card.kind)) card is still up after ⌘↩ (visibility "
                 + "\(restamped ? "re-stamped" : "unchanged"), status "
                 + "\(String(describing: toolCall(callID, in: chat)?.status)))")
        }
        return false
    }

    private static func label(of kind: PendingApproval.Kind) -> String {
        switch kind {
        case .approval: return "approval"
        case .consent: return "consent"
        case .permission: return "permission"
        }
    }

    /// The conversation's scroll view: the tallest document among the panel's scroll views.
    private func conversationScrollView(in panel: NSPanel) -> NSScrollView? {
        var found: [NSScrollView] = []
        var pending = panel.contentView.map { [$0] } ?? []
        while let view = pending.popLast() {
            if let scrollView = view as? NSScrollView { found.append(scrollView) }
            pending.append(contentsOf: view.subviews)
        }
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    private func toolCall(_ id: String, in chat: ChatSession) -> ToolCall? {
        for message in chat.messages.reversed() {
            if let call = message.toolCalls.first(where: { $0.id == id }) { return call }
        }
        return nil
    }

    private func dentistEvents(in store: any EventKitProviding) async -> [CalendarEventRecord] {
        let start = Calendar.current.startOfDay(for: Date())
        let end = start.addingTimeInterval(3 * 86_400)
        let events = (try? await store.events(from: start, to: end, calendarIDs: nil)) ?? []
        return events.filter { $0.title == "Dentist" }
    }

    /// A key-down through the panel's own key handling (its local monitor) when the panel is key. While the screen is
    /// locked AppKit makes no window key, so the same key goes through the key map and `perform` directly.
    /// With `retakeKeyboard`, an open notch whose panel lost the keyboard to another app first takes it back (as a
    /// person would by clicking into it).
    private func pressKey(_ keyCode: Int, _ characters: String, _ flags: NSEvent.ModifierFlags,
                          _ vm: NotchViewModel, _ controller: NotchWindowController, retakeKeyboard: Bool = true) async {
        let panel = controller.debugPanel
        if retakeKeyboard, vm.isOpen, !panel.isKeyWindow, !Self.isScreenLocked {
            vm.engage()
            let retaken = await waitUntil(1) { panel.isKeyWindow }
            note("took the keyboard back before key \(keyCode) (\(retaken ? "done" : "failed"))")
        }
        if panel.isKeyWindow,
           let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                        isARepeat: false, keyCode: UInt16(keyCode)) {
            NSApp.sendEvent(event)
        } else {
            let textView = panel.firstResponder as? NSTextView
            let context = vm.keyContext(hasMarkedText: false,
                                        composerIsFirstResponder: vm.route == .chat && textView?.isEditable == true,
                                        clipboardWantsAttachmentPaste: false)
            if let command = NotchKeyCommands.command(keyCode: UInt16(keyCode), characters: characters, flags: flags,
                                                      context: context) {
                vm.perform(command, hardwareConfirmed: false)
            }
            if Self.isScreenLocked {
                current?.skipped.append("key \(keyCode) went through the key map directly (screen locked)")
            } else {
                fail("the panel wasn't key for key \(keyCode)")
            }
        }
        await pause(0.15)
    }

    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("otto-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        tempFiles.append(folder)
        return folder
    }

    private static func posixPermissions(of url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    /// How the running binary is signed when it carries a certificate (not ad hoc), else nil. Never names the signer.
    private static var stableSigningIdentity: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        guard flags & SecCodeSignatureFlags.adhoc.rawValue == 0,
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              !certificates.isEmpty else { return nil }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return team == nil ? "a certificate without a team" : "a certificate with a team identifier"
    }

    // MARK: - Helpers

    /// Attempts of a retryable step (the first plus the reruns after outside activity).
    private static let maximumAttempts = 3

    /// Runs one step. A step marked `retryable` sets up its own state; when it fails while another app took the
    /// keyboard or someone clicked outside Otto (the Mac is in use: that closes or unfocuses the notch under the
    /// script), it runs again, up to `maximumAttempts` in all, and the report keeps each earlier attempt's failures
    /// as a note.
    private func step(_ name: String, retryable: Bool = false, _ body: () async throws -> Void) async {
        let start = ContinuousClock.now
        var attempt = 1
        var earlier: [String] = []
        while true {
            current = StepReport(name: name, passed: true, failures: [], skipped: [], notes: [], captures: [], durationMs: 0)
            let interference = SelfTestInterference()
            do {
                try await body()
            } catch {
                fail("threw: \(error.localizedDescription)")
            }
            interference.stop()
            guard let failures = current?.failures, !failures.isEmpty, retryable, attempt < Self.maximumAttempts,
                  interference.events > 0 else {
                if interference.events > 0 {
                    note("outside activity during the step: \(interference.summary)")
                }
                break
            }
            earlier.append("attempt \(attempt) failed while the Mac was in use (\(interference.summary)): "
                           + failures.joined(separator: "; "))
            attempt += 1
            await pause(0.5)
        }
        guard var finished = current else { return }
        finished.notes.insert(contentsOf: earlier, at: 0)
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

    /// Waits (up to 2 s) until the rendered shape has kept its size for 100 ms, so a capture shows the settled layout
    /// rather than a frame of the resize animation.
    private func settleShape(_ vm: NotchViewModel?) async {
        guard let vm else { return }
        var last = vm.renderedShapeSize
        var stableSince = ContinuousClock.now
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            if vm.renderedShapeSize != last {
                last = vm.renderedShapeSize
                stableSince = ContinuousClock.now
            } else if ContinuousClock.now - stableSince >= .milliseconds(100) {
                return
            }
        }
    }

    /// Sleeps until `instant` on the continuous clock.
    private func waitUntilInstant(_ instant: ContinuousClock.Instant) async {
        let remaining = instant - ContinuousClock.now
        guard remaining > .zero else { return }
        try? await Task.sleep(for: remaining)
    }

    /// Sleeps until the system uptime reaches `uptime`.
    private func waitUntilUptime(_ uptime: TimeInterval) async {
        let remaining = uptime - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return }
        try? await Task.sleep(for: .milliseconds(Int((remaining * 1000).rounded(.up))))
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

    /// Ends the reply, flushes the graph's stores, drops its throwaway preferences and removes the temp files.
    private func cleanUp() {
        composition?.terminate()
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
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

// MARK: - Fakes for the dry-run paste and the idle clock

/// A key sender that records ⌘V instead of posting it.
private final class SelfTestKeySender: KeySending {
    private(set) var pasteCount = 0

    var isSecureInputEnabled: Bool { false }

    func areModifiersDown() -> Bool { false }

    func postPaste() throws {
        pasteCount += 1
    }
}

/// A pretend target app: running, frontmost once asked, Accessibility granted, and a focused value that changes
/// when the paste lands. Sleeps return at once.
@MainActor private final class SelfTestInsertEnvironment: InsertEnvironment {
    private let target: AppRef
    private var isFrontmost = false
    private var pasteLanded = false
    private(set) var activationRequests = 0

    init(target: AppRef) {
        self.target = target
    }

    var isAccessibilityTrusted: Bool { true }

    func frontmostPID() -> pid_t? {
        isFrontmost ? target.pid : nil
    }

    func isRunning(_ app: AppRef) -> Bool {
        app == target
    }

    func requestActivation(of app: AppRef) {
        activationRequests += 1
        isFrontmost = app == target
    }

    func isChromiumOrElectron(_ app: AppRef) -> Bool { false }

    func focusedElementIsSecure(in app: AppRef) async -> Bool { false }

    /// The first read is "before ⌘V"; every later read sees the pasted text.
    func focusedValueFingerprint(in app: AppRef) async -> ValueFingerprint? {
        defer { pasteLanded = true }
        return pasteLanded
            ? ValueFingerprint(characterCount: 42, valueHash: "after")
            : ValueFingerprint(characterCount: 12, valueHash: "before")
    }

    func selectionState(of snapshot: SelectionSnapshot) async -> SelectionState { .unknown }

    func restoreSelection(_ snapshot: SelectionSnapshot) async -> Bool { false }

    func sleep(for duration: Duration) async {}
}

/// Counts what the person at the Mac does while a step runs: other apps coming forward, clicks outside Otto's
/// windows, and whether they typed (the session's last hardware key-down; the self-test's own keys never reach the
/// HID system). Only counts; never records where or what.
@MainActor private final class SelfTestInterference {
    private var activations = 0
    private var clicks = 0
    private var typed = false
    private let startedAt = ContinuousClock.now
    private var observer: NSObjectProtocol?
    private var monitor: Any?

    init() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ownPID else { return }
            MainActor.assumeIsolated { self?.activations += 1 }
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.clicks += 1 }
        }
    }

    var events: Int { activations + clicks + (typed ? 1 : 0) }

    var summary: String {
        "\(activations) app activation(s), \(clicks) click(s) outside Otto" + (typed ? ", typing on the keyboard" : "")
    }

    func stop() {
        let elapsed = ContinuousClock.now - startedAt
        let sinceKeyDown = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        typed = sinceKeyDown < elapsedSeconds
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// What the fold step's permission flow answered, once it has.
@MainActor private final class SelfTestFlowResult {
    var granted: Bool?
}

/// The idle step's clock (History reads it through its injected `now`).
private final class SelfTestClock {
    var now = Date()
}

#endif
