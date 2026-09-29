//
//  PromoStage.swift
//  Otto
//
//  The promo stage: the real notch UI (`NotchRootView` driven by a real `NotchViewModel` and
//  `ChatSession`) filmed on a stylized MacBook display, for the README, the landing page and the
//  promo video.
//
//    Otto --promo <dir> --promo-scene <name>   one scene, played live for scripts/record_promo.swift
//    Otto --promo-stills <dir>                  the marketing stills (see PromoStills.swift)
//
//  The stage window is borderless and ordered *below the desktop*, so it never appears on the
//  user's screen, never takes focus and ignores the mouse; ScreenCaptureKit records it on its own.
//  A handshake through files in `<dir>` keeps the recorder and the choreography in step:
//  the app writes `ready.json`, waits for `go`, plays the scene, writes `timeline.json` and `done`,
//  then quits.
//
//  Nothing here touches the user's settings, Keychain or browser: the stage runs on a throwaway
//  defaults suite, an in-memory API key and `PromoLLMClient`.
//

// Debug tooling: compiled only into Debug builds, or into a Release build made with the
// OTTO_TOOLS compilation condition (scripts/make_media.sh does this to record footage).
#if DEBUG || OTTO_TOOLS

import AppKit
import Observation
import os
import SwiftUI

// MARK: - Stage state

/// Everything on the stage that isn't Otto itself: the pointer, the dragged files, the Settings window.
@MainActor @Observable final class PromoStageState {
    /// Pointer tip, in stage points.
    var pointer: CGPoint
    var isPointerVisible = true
    var isPointerPressed = false
    var isDraggingFiles = false
    /// Three document icons on the desktop (the files the story scene drags onto the notch).
    var showsDesktopFiles = false
    /// Finder-style selection highlight on those icons.
    var desktopFilesSelected = false
    /// Ghosted while their copies are being dragged, as Finder does.
    var desktopFilesDimmed = false
    var showsSettings = false
    /// Scales the Settings window about its top edge (the stills fit it into a smaller frame).
    var settingsScale: CGFloat = 1
    /// The composer's insertion point, in stage points (nil: hidden). The stage window never
    /// becomes key, so the text field can't draw its own caret; the director mirrors it.
    var caret: CGRect?
    var clock = PromoMenuBar.clock
    /// The frontmost app in the menu bar ("Otto" while its Settings window is focused).
    var menuBarApp = "Studio"
    /// Flips every frame while recording: an imperceptible one-point change in the corner that keeps
    /// ScreenCaptureKit delivering frames through still moments, so the recorder can tell a live stage
    /// from one the window server has stopped rendering.
    var heartbeat = false

    init(pointer: CGPoint) {
        self.pointer = pointer
    }
}

// MARK: - Stage view

struct PromoStageView: View {
    let layout: PromoLayout
    let wallpaper: CGImage?
    let viewModel: NotchViewModel
    let settings: AppSettings
    let state: PromoStageState

    var body: some View {
        ZStack(alignment: .topLeading) {
            PromoDisplay(layout: layout, wallpaper: wallpaper, clock: state.clock, appName: state.menuBarApp) {
                ZStack(alignment: .top) {
                    if state.showsDesktopFiles {
                        let center = PromoDirector.desktopFilesCenter(in: layout)
                        PromoDesktopFiles(isSelected: state.desktopFilesSelected)
                            .opacity(state.desktopFilesDimmed ? 0.45 : 1)
                            .position(x: center.x - layout.screenRect.minX, y: center.y - layout.screenRect.minY)
                            .frame(width: layout.screenRect.width, height: layout.screenRect.height, alignment: .topLeading)
                    }
                    if state.showsSettings {
                        PromoSettingsWindow(settings: settings, contentHeight: settingsHeight)
                            .scaleEffect(state.settingsScale, anchor: .top)
                            .padding(.top, layout.notchSize.height + settingsTopGap)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                    NotchRootView(viewModel: viewModel)
                        .frame(width: NotchMetrics.windowSize.width, height: NotchMetrics.windowSize.height)
                }
                .frame(width: layout.screenRect.width, alignment: .top)
            }

            if let caret = state.caret {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Theme.sendFill)
                    .frame(width: 2, height: caret.height)
                    .offset(x: caret.minX - 0.5, y: caret.minY)
                    .allowsHitTesting(false)
            }

            Rectangle()
                .fill(state.heartbeat ? Theme.rgb(0x0B0B0D) : Theme.rgb(0x0A0A0C))
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)

            ZStack(alignment: .topLeading) {
                if state.isDraggingFiles {
                    PromoDragStack()
                        .offset(x: 10, y: 16)
                        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .topLeading)))
                }
                PromoPointer(isPressed: state.isPointerPressed)
            }
            .offset(x: state.pointer.x, y: state.pointer.y)
            .opacity(state.isPointerVisible ? 1 : 0)
        }
        .frame(width: layout.stageSize.width, height: layout.stageSize.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    /// The Settings window hangs below the menu bar.
    private var settingsTopGap: CGFloat { state.settingsScale < 1 ? 14 : 24 }

    /// Sized to end cleanly after the Model group (the models and Response style, with its helper
    /// text), with even padding, so no row is ever cut mid-glyph.
    private var settingsHeight: CGFloat { PromoSettingsWindow.throughModelGroup }
}

// MARK: - Cast

/// The real Otto objects the stage films, on throwaway settings.
@MainActor
struct PromoCast {
    let settings: AppSettings
    let chat: ChatSession
    let viewModel: NotchViewModel

    static let defaultsSuite = "otto.promo"

    static func make() -> PromoCast? {
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else { return nil }
        defaults.removePersistentDomain(forName: defaultsSuite)
        let settings = AppSettings(defaults: defaults, usesKeychain: false)
        settings.model = .opus5
        settings.effort = .medium
        settings.webAccess = true
        // Never look at the user's real browser: the stage offers its own (fictional) tab.
        settings.suggestBrowserTab = false
        // In memory only (the Keychain is off for these settings): Settings shows a saved key.
        // A made-up value, assembled from parts so secret scanners don't mistake it for a real key.
        settings.apiKey = ["sk", "ant", "promo", "stage", "7Q2c"].joined(separator: "-")

        let chat = ChatSession(settings: settings, makeClient: { PromoLLMClient() })
        let viewModel = NotchViewModel(settings: settings, chat: chat)
        viewModel.closedNotchSize = PromoLayout.video.notchSize
        viewModel.hasPhysicalNotch = true
        return PromoCast(settings: settings, chat: chat, viewModel: viewModel)
    }

    /// Drops the throwaway defaults again.
    func tearDown() {
        chat.reset()
        UserDefaults(suiteName: Self.defaultsSuite)?.removePersistentDomain(forName: Self.defaultsSuite)
    }
}

// MARK: - Entry points

enum PromoStage {
    static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Promo")
    /// Keeps the process from being napped or throttled while it films off screen.
    private static var activity: NSObjectProtocol?
    private static var window: NSWindow?

    /// `--promo <dir> --promo-scene <name>`: opens the hidden stage, waits for `go`, plays the scene.
    @MainActor
    static func perform(scene name: String, handshakeDirectory directory: URL) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled],
            reason: "Recording Otto's promo stage"
        )
        // Whatever happens, never outlive the recording (or a recorder that died).
        startWatchdog(timeout: 1800)

        guard let scene = PromoScene(rawValue: name) else {
            fail("Unknown promo scene “\(name)”. Scenes: \(PromoScene.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fail("Couldn't create \(directory.path): \(error.localizedDescription)")
        }
        guard let cast = PromoCast.make() else { fail("Couldn't open the promo defaults suite.") }

        let layout = PromoLayout.video
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let wallpaper = PromoWallpaper.image(
            pixelSize: CGSize(width: layout.screenRect.width * scale, height: layout.screenRect.height * scale)
        )
        let state = PromoStageState(pointer: PromoDirector.restingPointer(in: layout))
        let director = PromoDirector(layout: layout, cast: cast, state: state)
        director.prepare(scene)

        let stage = makeStageWindow(
            size: layout.stageSize,
            rootView: PromoStageView(layout: layout, wallpaper: wallpaper, viewModel: cast.viewModel, settings: cast.settings, state: state)
        )
        window = stage
        startHeartbeat(state)

        Task { @MainActor in
            // Let SwiftUI lay out and settle before the recorder starts looking.
            try? await Task.sleep(for: .milliseconds(500))
            writeJSON(
                [
                    "windowNumber": stage.windowNumber,
                    "scene": scene.rawValue,
                    "stageWidth": layout.stageSize.width,
                    "stageHeight": layout.stageSize.height,
                    "backingScale": stage.backingScaleFactor,
                    // Diagnostics: an occluded stage on another Space may stop rendering.
                    "occlusionVisible": stage.occlusionState.contains(.visible),
                    "onActiveSpace": stage.isOnActiveSpace,
                ],
                to: directory.appendingPathComponent("ready.json")
            )
            let go = directory.appendingPathComponent("go")
            while !FileManager.default.fileExists(atPath: go.path) {
                try? await Task.sleep(for: .milliseconds(4))
            }
            director.startCaret(in: stage)
            director.begin()
            await director.play(scene)
            director.stopCaret()
            writeJSON(
                [
                    "scene": scene.rawValue,
                    "title": scene.title,
                    "summary": scene.summary,
                    "sceneDuration": director.elapsed,
                    "marks": director.marks,
                ],
                to: directory.appendingPathComponent("timeline.json")
            )
            FileManager.default.createFile(atPath: directory.appendingPathComponent("done").path, contents: Data())
            try? await Task.sleep(for: .milliseconds(300))
            cast.tearDown()
            stage.orderOut(nil)
            exit(0)
        }
    }

    /// A borderless window below the desktop: rendered and capturable, but never seen or clicked.
    @MainActor
    static func makeStageWindow<Content: View>(size: CGSize, rootView: Content) -> NSWindow {
        let screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let window = NSWindow(
            contentRect: CGRect(x: screenFrame.minX, y: screenFrame.minY, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.hasShadow = false
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "Otto Promo Stage"
        window.isExcludedFromWindowsMenu = true
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = CGRect(origin: .zero, size: size)
        window.contentView = hostingView
        window.orderFrontRegardless()
        return window
    }

    private static func startHeartbeat(_ state: PromoStageState) {
        Task { @MainActor in
            while true {
                state.heartbeat.toggle()
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    private static func startWatchdog(timeout: Double) {
        let parent = getppid()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let deadline = Date().addingTimeInterval(timeout)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler {
            if Date() > deadline {
                FileHandle.standardError.write(Data("promo stage timed out\n".utf8))
                exit(2)
            }
            // The recorder that launched us is gone: don't linger.
            if getppid() != parent {
                exit(3)
            }
        }
        timer.resume()
        watchdog = timer
    }

    private static var watchdog: DispatchSourceTimer?

    static func writeJSON(_ object: Any, to url: URL) {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Couldn't write \(url.path, privacy: .public): \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    static func fail(_ message: String) -> Never {
        logger.error("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("promo error: \(message)\n".utf8))
        exit(1)
    }
}

// MARK: - Scenes

enum PromoScene: String, CaseIterable {
    case story
    case hero
    case closed
    case hoverOpen = "hover-open"
    case context
    case screenshot
    case draft
    case glance
    case settings

    var title: String {
        switch self {
        case .story: return "One thread, start to finish"
        case .hero: return "Hover, ask, done"
        case .closed: return "Closed notch"
        case .hoverOpen: return "Hover to open"
        case .context: return "Drop in context"
        case .screenshot: return "Ask about a screenshot"
        case .draft: return "Draft from a file"
        case .glance: return "Tucks away while it works"
        case .settings: return "Settings"
        }
    }

    var summary: String {
        switch self {
        case .story:
            return "The promo film's continuous take: hover opens Otto, it tucks away → three files are dragged from the desktop onto the notch and the open tab is clicked in → “What should I fix before Friday?” is typed and sent with the send button → thinking, a web search with sources, the answer streams (a list with a Swift code block) → as the last bullet lands a click outside tucks it away; the orb and equalizer ears carry on, then the unread dot lights → a hover reopens the finished answer, Copy row in view → it tucks away again."
        case .hero:
            return "Closed notch → pointer hovers, Otto springs open → the browser-tab suggestion is clicked in → “Summarize this in 3 bullets” is typed and sent → Otto reads the page, searches the web and streams three bullets with sources → a click outside tucks it away while the ears finish the closing line → unread dot → the dot's ear retracts, so the take ends as it began."
        case .closed:
            return "The closed notch at rest in the menu bar; the pointer drifts across the wallpaper."
        case .hoverOpen:
            return "The pointer glides to the notch, it swells slightly, then springs open to the empty composer."
        case .context:
            return "Three files (launch-plan.md, screenshot.png, invoice.pdf) are dragged onto the closed notch: it opens, shows “Drop to attach”, and the chips land; the browser tab is offered as a dashed chip and clicked in; a question is typed."
        case .screenshot:
            return "screenshot.png attached, “What's wrong in this screenshot?” is typed and sent; Otto thinks, then answers with bullets and a Swift code block with a Copy button."
        case .draft:
            return "launch-plan.md attached, “Draft a friendly update for the team” is typed and sent; Otto streams a ready-to-paste update."
        case .glance:
            return "A reply is streaming when a click outside closes the notch: it tucks away with the orb and equalizer ears, the reply finishes, the unread dot appears, and a hover reopens the finished answer."
        case .settings:
            return "From the closed notch, the Settings window (API key saved in Keychain, model picker, response style) scales in over the wallpaper and Otto becomes the frontmost app in the menu bar."
        }
    }
}

// MARK: - Director

/// Plays a scene: moves the pointer, drives the real view model and logs key moments.
@MainActor
final class PromoDirector {
    let layout: PromoLayout
    let cast: PromoCast
    let state: PromoStageState
    private(set) var marks: [[String: Any]] = []
    private var startedAt = ContinuousClock.now
    /// Deterministic typing rhythm.
    private var random = PromoRandom(seed: 0x0770_5EED)

    private var viewModel: NotchViewModel { cast.viewModel }

    init(layout: PromoLayout, cast: PromoCast, state: PromoStageState) {
        self.layout = layout
        self.cast = cast
        self.state = state
    }

    var elapsed: Double {
        let duration = ContinuousClock.now - startedAt
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    func begin() {
        startedAt = .now
        mark("start")
    }

    func mark(_ event: String, _ note: String? = nil) {
        var entry: [String: Any] = ["t": (elapsed * 1000).rounded() / 1000, "event": event]
        if let note { entry["note"] = note }
        marks.append(entry)
    }

    // MARK: Geometry (stage points)

    /// Where the pointer rests between moments. Scenes start and (after a click outside) end
    /// here, so the hero clip loops cleanly.
    static func restingPointer(in layout: PromoLayout) -> CGPoint {
        CGPoint(x: layout.screenRect.minX + layout.screenRect.width * 0.76, y: layout.screenRect.minY + layout.screenRect.height * 0.64)
    }

    private var notchCenter: CGPoint {
        CGPoint(x: layout.notchTop.x + 6, y: layout.notchTop.y + layout.notchSize.height * 0.55)
    }

    private var panelLeft: CGFloat { layout.notchTop.x - NotchMetrics.openWidth / 2 }
    private var panelRight: CGFloat { layout.notchTop.x + NotchMetrics.openWidth / 2 }
    private var panelBottom: CGFloat { layout.notchTop.y + viewModel.renderedShapeSize.height }

    /// Center of the send button (bottom-right of the composer).
    private var sendButton: CGPoint {
        CGPoint(x: panelRight - 62, y: panelBottom - 44)
    }

    /// A point on the first chip of the (single-row) tray above the composer.
    private func chip(atX offset: CGFloat) -> CGPoint {
        CGPoint(x: panelLeft + 46 + offset, y: panelBottom - 104)
    }

    /// Where the context scene picks up its files.
    private var dragStart: CGPoint {
        CGPoint(x: layout.screenRect.minX + layout.screenRect.width * 0.24, y: layout.screenRect.minY + layout.screenRect.height * 0.66)
    }

    /// The middle one of the three desktop icons (the story scene grabs the group there). They sit
    /// in a column at the right edge of the desktop, as Finder arranges them, clear of every
    /// close-up on the notch.
    static func desktopFilesCenter(in layout: PromoLayout) -> CGPoint {
        CGPoint(x: layout.screenRect.maxX - 95, y: layout.screenRect.minY + layout.screenRect.height * 0.4)
    }

    /// Somewhere calm on the wallpaper, well clear of the panel.
    private var outside: CGPoint { Self.restingPointer(in: layout) }

    // MARK: Caret

    private var caretTask: Task<Void, Never>?
    /// The stage window (for the caret).
    private weak var stageWindow: NSWindow?

    /// Mirrors the composer's insertion point while the notch is open and engaged: solid while
    /// typing, then blinking like the system caret.
    func startCaret(in window: NSWindow) {
        stageWindow = window
        caretTask?.cancel()
        caretTask = Task { @MainActor [weak self, weak window] in
            var lastText = ""
            var lastChange = ContinuousClock.now
            while !Task.isCancelled, let self, let window {
                let vm = self.viewModel
                if vm.composerText != lastText {
                    lastText = vm.composerText
                    lastChange = .now
                }
                var caret: CGRect?
                if vm.isOpen && vm.isEngaged && !self.cast.chat.isStreaming,
                   let rect = PromoCaret.rect(in: window) {
                    let idle = ContinuousClock.now - lastChange
                    let seconds = Double(idle.components.seconds) + Double(idle.components.attoseconds) / 1e18
                    let visible = seconds < 0.5 || Int((seconds - 0.5) / 0.53) % 2 == 1
                    caret = visible ? rect : nil
                }
                if self.state.caret != caret { self.state.caret = caret }
                try? await Task.sleep(for: .milliseconds(12))
            }
        }
    }

    func stopCaret() {
        caretTask?.cancel()
        state.caret = nil
    }

    // MARK: Primitives

    func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    /// Glides the pointer along a gentle arc with an ease-in-out curve that settles softly.
    ///
    /// Driven frame by frame rather than with `withAnimation`: a SwiftUI animation started in the
    /// same update as a big layout change (e.g. sending a message) can stall at its first frame.
    func move(to point: CGPoint, duration: Double) async {
        let start = state.pointer
        let dx = point.x - start.x
        let dy = point.y - start.y
        // Bow the path slightly to one side, like a hand moving a mouse.
        let bow = min(0.08 * (dx * dx + dy * dy).squareRoot(), 40)
        let length = max((dx * dx + dy * dy).squareRoot(), 1)
        let normal = CGPoint(x: -dy / length * bow, y: dx / length * bow)
        let easing = PromoEasing(x1: 0.42, y1: 0, x2: 0.18, y2: 1)
        let began = ContinuousClock.now
        while true {
            let elapsed = ContinuousClock.now - began
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let progress = min(1, seconds / max(duration, 0.001))
            let eased = easing.value(at: progress)
            let arc = 4 * eased * (1 - eased)
            state.pointer = CGPoint(
                x: start.x + dx * eased + normal.x * arc,
                y: start.y + dy * eased + normal.y * arc
            )
            if progress >= 1 { break }
            try? await Task.sleep(for: .milliseconds(6))
        }
    }

    func click() async {
        withAnimation(.easeOut(duration: 0.07)) { state.isPointerPressed = true }
        await wait(0.1)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { state.isPointerPressed = false }
        await wait(0.08)
    }

    /// Types into the composer with a human, slightly uneven rhythm.
    func type(_ text: String, baseInterval: Double = 0.052) async {
        mark("type-start", text)
        for character in text {
            viewModel.composerText.append(character)
            var interval = baseInterval * random.next(in: 0.65...1.45)
            if character == " " { interval *= 1.25 }
            await wait(interval)
        }
        mark("type-end")
    }

    /// Pointer onto the notch, the hover swell, then the spring open (as the window controller does).
    func hoverOpen(glide: Double = 1.0) async {
        mark("pointer-to-notch")
        await move(to: notchCenter, duration: glide)
        withAnimation(Theme.Motion.hover) { viewModel.isHovering = true }
        mark("hover")
        await wait(0.32)
        viewModel.isHovering = false
        viewModel.open(reason: .hover, focus: false)
        mark("open")
    }

    /// Offers the fictional browser tab as the dashed suggestion chip.
    func suggestTab() {
        viewModel.debugSeed(
            presentation: .open,
            composerText: viewModel.composerText,
            attachments: viewModel.attachments,
            suggestedTab: PromoContent.browserTab(),
            hasUnreadReply: false
        )
        mark("tab-suggested")
    }

    func sendWithButton() async {
        await move(to: sendButton, duration: 0.6)
        await click()
        viewModel.send()
        mark("send")
    }

    /// Click on the wallpaper: the notch tucks away.
    func clickOutside(glide: Double = 0.8) async {
        await move(to: outside, duration: glide)
        await click()
        viewModel.close()
        mark("close")
    }

    /// Waits until the reply has fully streamed (or `limit` passes).
    func waitForReply(limit: Double = 20) async {
        let deadline = ContinuousClock.now + .milliseconds(Int(limit * 1000))
        while cast.chat.isStreaming && ContinuousClock.now < deadline {
            await wait(0.02)
        }
        mark("reply-complete")
    }

    /// Waits until the streaming reply's text contains `marker` (or `limit` passes).
    func waitForText(containing marker: String, limit: Double = 15) async {
        let deadline = ContinuousClock.now + .milliseconds(Int(limit * 1000))
        while !(cast.chat.messages.last?.text.contains(marker) ?? false) && ContinuousClock.now < deadline {
            await wait(0.01)
        }
        mark("text", marker)
    }

    /// Waits until the reply's text has started streaming (after thinking and tools).
    func waitForAnswerText(limit: Double = 10) async {
        let deadline = ContinuousClock.now + .milliseconds(Int(limit * 1000))
        while (cast.chat.messages.last?.text.isEmpty ?? true) && ContinuousClock.now < deadline {
            await wait(0.02)
        }
        mark("answer-streaming")
    }

    /// Marks each activity starting/finishing as it happens (for the editor's captions).
    private func watchActivities() {
        Task { @MainActor [weak self] in
            var seenStarted = Set<String>()
            var seenDone = Set<String>()
            var sawThinking = false
            var sawSources = false
            while let self, self.cast.chat.isStreaming || !sawThinking {
                if let message = self.cast.chat.messages.last, message.role == .assistant {
                    if message.isThinking && !sawThinking {
                        sawThinking = true
                        self.mark("thinking")
                    }
                    for activity in message.activities {
                        if seenStarted.insert(activity.id).inserted { self.mark("tool-start", activity.label) }
                        if activity.isDone, seenDone.insert(activity.id).inserted { self.mark("tool-done", activity.label) }
                    }
                    if !message.sources.isEmpty && !sawSources {
                        sawSources = true
                        self.mark("sources", message.sources.map(\.title).joined(separator: " · "))
                    }
                }
                try? await Task.sleep(for: .milliseconds(15))
                if !self.cast.chat.isStreaming && !sawThinking && self.elapsed > 30 { break }
            }
        }
    }

    // MARK: Scenes

    /// Sets the opening state, before the recorder starts (so the pre-roll matches it).
    func prepare(_ scene: PromoScene) {
        let vm = viewModel
        switch scene {
        case .story:
            vm.debugSeed(presentation: .closed, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
            state.showsDesktopFiles = true
            state.desktopFilesSelected = true
        case .hero, .closed, .hoverOpen:
            vm.debugSeed(presentation: .closed, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
        case .context:
            vm.debugSeed(presentation: .closed, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
            state.pointer = dragStart
        case .screenshot:
            vm.debugSeed(presentation: .open, composerText: "", attachments: [PromoContent.screenshotImage()], suggestedTab: nil, hasUnreadReply: false)
            state.pointer = CGPoint(x: layout.notchTop.x + 150, y: layout.notchTop.y + 230)
        case .draft:
            vm.debugSeed(presentation: .open, composerText: "", attachments: [PromoContent.launchPlan()], suggestedTab: nil, hasUnreadReply: false)
            state.pointer = CGPoint(x: layout.notchTop.x + 150, y: layout.notchTop.y + 230)
        case .glance:
            vm.debugSeed(presentation: .open, composerText: "", attachments: [PromoContent.browserTab()], suggestedTab: nil, hasUnreadReply: false)
            state.pointer = CGPoint(x: layout.notchTop.x + 180, y: layout.notchTop.y + 200)
        case .settings:
            // Picks up where the story ends: closed notch, pointer at rest. The window scales in.
            vm.debugSeed(presentation: .closed, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
            state.showsDesktopFiles = true
        }
    }

    func play(_ scene: PromoScene) async {
        switch scene {
        case .story: await playStory()
        case .hero: await playHero()
        case .closed: await playClosed()
        case .hoverOpen: await playHoverOpen()
        case .context: await playContext()
        case .screenshot: await playAsk(PromoContent.screenshot)
        case .draft: await playAsk(PromoContent.draft)
        case .glance: await playGlance()
        case .settings: await playSettings()
        }
        mark("end")
    }

    /// The README loop. The GIF crops tightly around the panel (1:1 with the master), so after
    /// sending, the pointer parks just right of the panel instead of far out on the wallpaper.
    private func playHero() async {
        await wait(0.15)
        await hoverOpen(glide: 0.85)
        await wait(0.45)
        suggestTab()
        await wait(0.55)
        // Click the dashed suggestion to attach the page.
        await move(to: chip(atX: 58), duration: 0.6)
        await click()
        viewModel.engage()
        viewModel.acceptSuggestedTab()
        mark("tab-attached")
        await wait(0.35)
        await type(PromoContent.summarize.prompt)
        await wait(0.3)
        watchActivities()
        await sendWithButton()
        await move(to: CGPoint(x: panelRight + 16, y: layout.notchTop.y + 236), duration: 0.8)
        await waitForAnswerText()
        // Let all three bullets land (the pointer sets off as the third starts), then tuck the
        // notch away while the closing line is still to come: the ears carry on.
        await waitForText(containing: "Quiet by default")
        await clickOutside(glide: 0.6)
        await waitForReply()
        await wait(0.75)
        // Loop reset: the unread dot's ear retracts into the notch (as it does once the reply is
        // read), so the take ends exactly as it began and the README loop has no seam.
        withAnimation(Theme.Motion.hover) { viewModel.hasUnreadReply = false }
        mark("ears-retract")
        await wait(0.7)
    }

    /// The promo film's one continuous take (see `PromoScene.summary`), so the question typed in
    /// the context beat is the one that is sent and answered.
    private func playStory() async {
        let vm = viewModel
        // An establishing beat on the whole display before the pointer sets off.
        await wait(1.6)
        // 1. One glance away: hover, it springs open; move off, it tucks away.
        await hoverOpen(glide: 1.0)
        await wait(1.45)
        let files = Self.desktopFilesCenter(in: layout)
        await move(to: CGPoint(x: panelRight + 30, y: layout.notchTop.y + 170), duration: 0.45)
        vm.close()
        mark("close")
        await move(to: CGPoint(x: files.x + 6, y: files.y - 8), duration: 0.85)
        await wait(0.25)

        // 2. Knows what you're looking at: drag three files onto the notch, add the open tab.
        withAnimation(.easeOut(duration: 0.07)) { state.isPointerPressed = true }
        await wait(0.1)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            state.isPointerPressed = false
            state.isDraggingFiles = true
            state.desktopFilesDimmed = true
        }
        mark("drag-start")
        await wait(0.2)
        await move(to: notchCenter, duration: 1.25)
        vm.open(reason: .drag, focus: false)
        mark("open", "drag")
        await wait(0.25)
        await move(to: CGPoint(x: layout.notchTop.x - 40, y: layout.notchTop.y + 60), duration: 0.35)
        vm.isDropTargeted = true
        mark("drop-target")
        await wait(0.6)
        vm.isDropTargeted = false
        withAnimation(.easeOut(duration: 0.18)) {
            state.isDraggingFiles = false
            state.desktopFilesDimmed = false
            state.desktopFilesSelected = false
        }
        vm.engage()
        mark("drop")
        for attachment in PromoContent.droppedFiles() {
            vm.addAttachment(attachment)
            await wait(0.12)
        }
        mark("chips-landed")
        await wait(0.35)
        suggestTab()
        await wait(0.45)
        // The dashed suggestion sits at the start of the tray's last row: click it in.
        await move(to: chip(atX: 58), duration: 0.6)
        await click()
        vm.acceptSuggestedTab()
        mark("tab-attached")
        await wait(0.3)
        await move(to: CGPoint(x: panelRight + 56, y: panelBottom - 20), duration: 0.5)
        await type(PromoContent.friday.prompt)
        await wait(0.35)

        // 3. Answers that stream in: send, think, search, stream.
        watchActivities()
        await sendWithButton()
        await move(to: CGPoint(x: panelRight + 70, y: layout.notchTop.y + 240), duration: 0.8)
        await waitForAnswerText()
        // The list, its code block and the sources stream in view. As the last bullet starts, the
        // pointer sets off: it lands, and the notch is tucked away before the closing line.
        await waitForText(containing: "Pay invoice")
        // Keeps working while you do: tuck it away mid-answer, the ears carry on.
        await clickOutside(glide: 0.75)
        await waitForReply()
        await wait(0.9)
        await hoverOpen(glide: 0.9)
        await wait(0.3)
        // Off the header, so the reopened answer reads clean (engaged: it stays open). It reopens at
        // the end of the reply, Copy row and all.
        vm.engage()
        await move(to: CGPoint(x: panelRight + 70, y: layout.notchTop.y + 300), duration: 0.6)
        await wait(1.0)
        // Tuck it away again: the film cuts from here into Settings.
        await clickOutside(glide: 0.5)
        await wait(0.9)
    }

    private func playClosed() async {
        await move(to: CGPoint(x: layout.screenRect.midX + 260, y: layout.screenRect.minY + 380), duration: 2.2)
        await move(to: CGPoint(x: layout.screenRect.midX + 420, y: layout.screenRect.minY + 300), duration: 1.6)
        await wait(0.4)
    }

    private func playHoverOpen() async {
        await wait(0.6)
        await hoverOpen(glide: 1.2)
        await wait(0.6)
        viewModel.engage()
        await move(to: CGPoint(x: panelRight + 80, y: layout.notchTop.y + 170), duration: 0.9)
        await wait(1.2)
    }

    private func playContext() async {
        await wait(0.5)
        // Pick up three files and carry them to the notch.
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { state.isDraggingFiles = true }
        mark("drag-start")
        await wait(0.3)
        await move(to: notchCenter, duration: 1.3)
        viewModel.open(reason: .drag, focus: false)
        mark("open", "drag")
        await wait(0.25)
        await move(to: CGPoint(x: layout.notchTop.x - 40, y: layout.notchTop.y + 60), duration: 0.35)
        viewModel.isDropTargeted = true
        mark("drop-target")
        await wait(0.7)
        viewModel.isDropTargeted = false
        withAnimation(.easeOut(duration: 0.18)) { state.isDraggingFiles = false }
        viewModel.engage()
        mark("drop")
        for attachment in PromoContent.droppedFiles() {
            viewModel.addAttachment(attachment)
            await wait(0.12)
        }
        mark("chips-landed")
        await wait(0.5)
        suggestTab()
        await move(to: CGPoint(x: panelRight + 60, y: layout.notchTop.y + 160), duration: 0.8)
        await wait(0.5)
        await type("What should I fix before Friday?")
        await wait(1.4)
    }

    private func playAsk(_ conversation: PromoConversation) async {
        await wait(0.6)
        viewModel.engage()
        await type(conversation.prompt)
        await wait(0.3)
        watchActivities()
        await sendWithButton()
        await move(to: CGPoint(x: panelRight + 70, y: layout.notchTop.y + 240), duration: 0.9)
        await waitForReply()
        await wait(2.2)
    }

    private func playGlance() async {
        await wait(0.4)
        viewModel.engage()
        viewModel.composerText = PromoContent.summarize.prompt
        watchActivities()
        await sendWithButton()
        await waitForAnswerText()
        await wait(0.8)
        await clickOutside(glide: 0.8)
        await waitForReply()
        await wait(1.8)
        await hoverOpen(glide: 1.0)
        await wait(2.2)
    }

    private func playSettings() async {
        await wait(0.35)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.92)) { state.showsSettings = true }
        // Settings is Otto's own window: Otto becomes the frontmost app in the menu bar.
        state.menuBarApp = "Otto"
        mark("settings-open")
        await wait(0.3)
        withAnimation(.easeOut(duration: 0.3)) { state.isPointerVisible = false }
        await wait(6.6)
    }
}

/// Finds the composer's text field in a stage window and reports where its caret would be.
@MainActor
enum PromoCaret {
    /// The insertion point at the end of the composer's text, in the window's top-left-origin points.
    static func rect(in window: NSWindow) -> CGRect? {
        guard let contentView = window.contentView,
              let field = composerField(in: contentView) else { return nil }
        // What the field shows (its binding can trail the view model by a frame while typing).
        let text = field.stringValue
        let font = field.font ?? NSFont.systemFont(ofSize: 15)
        let bounds = field.cell?.drawingRect(forBounds: field.bounds) ?? field.bounds
        // The field editor insets text by its line fragment padding (2 pt).
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let caretHeight = ceil(font.ascender - font.descender) + 1
        let lineTop = field.isFlipped ? bounds.minY : bounds.maxY - lineHeight
        let local = CGRect(x: bounds.minX + 3 + width, y: lineTop + (lineHeight - caretHeight) / 2, width: 2, height: caretHeight)
        let inWindow = field.convert(local, to: nil)
        // Window coordinates have a bottom-left origin; the stage is top-left.
        let height = contentView.bounds.height
        return CGRect(x: inWindow.minX, y: height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }

    /// The notch has one editable text field: the composer's.
    private static func composerField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let found = composerField(in: subview) { return found }
        }
        return nil
    }
}

/// A CSS-style cubic-bezier timing curve (x = time, y = progress).
struct PromoEasing {
    let x1: Double, y1: Double, x2: Double, y2: Double

    private func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }

    private func slope(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2)
    }

    func value(at x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        // Solve bezier_x(t) = x (Newton, with a bisection fallback), then evaluate y.
        var t = x
        for _ in 0..<8 {
            let error = bezier(t, x1, x2) - x
            let d = slope(t, x1, x2)
            if abs(error) < 1e-6 { break }
            if abs(d) < 1e-6 { break }
            t -= error / d
        }
        if t < 0 || t > 1 || abs(bezier(t, x1, x2) - x) > 1e-4 {
            var low = 0.0, high = 1.0
            t = x
            for _ in 0..<40 {
                if bezier(t, x1, x2) < x { low = t } else { high = t }
                t = (low + high) / 2
            }
        }
        return bezier(t, y1, y2)
    }
}

/// A tiny deterministic PRNG (SplitMix64) so every take types with the same rhythm.
struct PromoRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }
}

#endif
