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
    /// The files the pointer carries (the drag stack's tiles and count badge).
    var draggedFiles: [PromoDesktopFile] = PromoDesktopFile.contextFiles
    /// The five document icons on the desktop (`PromoDesktopFile.all`).
    var showsDesktopFiles = false
    /// Indexes of the icons with the Finder selection highlight.
    var desktopFilesSelected: Set<Int> = []
    /// Indexes of the icons ghosted while their copies are dragged, as Finder does.
    var desktopFilesDimmed: Set<Int> = []
    var showsSettings = false
    /// Scales the Settings window about its top edge (the stills fit it into a smaller frame).
    var settingsScale: CGFloat = 1
    /// The composer's insertion point, in stage points (nil: hidden). The stage window never
    /// becomes key, so the text field can't draw its own caret; the director mirrors it.
    var caret: CGRect?
    var clock = PromoMenuBar.clock
    /// The frontmost app in the menu bar ("Otto" while its Settings window is focused).
    var menuBarApp = PromoContent.studioApp.name
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
                        PromoDesktopFiles(layout: layout, selected: state.desktopFilesSelected,
                                          dimmed: state.desktopFilesDimmed)
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
                    PromoDragStack(tiles: state.draggedFiles)
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

/// How fast the scripted replies play: 1 while filming, 0 for off-camera pre-rolls and stills. Read
/// when each turn's client is made, so a change applies from the next request on.
@MainActor final class PromoTiming {
    var scale: Double = 1
}

/// The words a voice take "hears". `ScriptedSpeechEngine` is made when listening starts, so a take
/// sets `steps` in its prepare (empty: the pill listens and hears nothing).
@MainActor final class PromoVoiceScript {
    var steps: [(delay: Duration, text: String, level: Float)] = []
}

/// No relaunch on the stage.
private struct PromoRelauncher: AppRelaunching {
    func relaunch() {}
}

/// Never pastes: no key events.
private final class PromoKeySender: KeySending {
    var isSecureInputEnabled: Bool { false }
    func areModifiersDown() -> Bool { false }
    func postPaste() throws {}
}

/// The stage's insert environment. Every app reads as not running, so no reply ever offers "Paste into"
/// (the frontmost app the notch records is the fictional `PromoContent.studioApp` anyway), and nothing
/// here looks at a real app, activates one or posts a key.
private final class PromoInsertEnvironment: InsertEnvironment {
    var isAccessibilityTrusted: Bool { false }
    func frontmostPID() -> pid_t? { nil }
    func isRunning(_ app: AppRef) -> Bool { false }
    func requestActivation(of app: AppRef) {}
    func isChromiumOrElectron(_ app: AppRef) -> Bool { false }
    func focusedElementIsSecure(in app: AppRef) async -> Bool { false }
    func focusedValueFingerprint(in app: AppRef) async -> ValueFingerprint? { nil }
    func selectionState(of snapshot: SelectionSnapshot) async -> SelectionState { .unknown }
    func restoreSelection(_ snapshot: SelectionSnapshot) async -> Bool { false }
    func sleep(for duration: Duration) async {}
}

/// The real Otto objects the stage films, on throwaway settings. Modeled on `SnapshotStage.init`: the
/// real tool registry (only the calendar tool the film needs) and `ToolExecutor` over the demo calendar,
/// permissions and approvals on a throwaway suite, the glance started (so the closed notch grows its
/// phase ears), voice on a scripted engine, history in memory and the Shelf on.
@MainActor
struct PromoCast {
    let settings: AppSettings
    let chat: ChatSession
    let viewModel: NotchViewModel
    let permissions: PermissionsCenter
    let approvals: ApprovalStore
    let tools: ToolRegistry
    let executor: ToolExecutor
    /// The demo calendar, seeded around `PromoContent.stageNow` (nothing of it is ever listed on stage:
    /// its seeded events carry demo locations and attendees).
    let eventKit: DemoEventKitService
    let timing: PromoTiming
    let voiceScript: PromoVoiceScript
    /// A per-run folder for fixture files a take drops or shelves (`makeFixtureDirectory()`); removed by
    /// `tearDown`.
    let fixtureDirectory: URL

    static let defaultsSuite = "otto.promo"

    /// Granted, so no permission card or TCC prompt ever shows: the calendar tool, voice and speech.
    private static let permissionStatuses: [Permission: PermissionStatus] = [
        .calendars: .granted,
        .reminders: .granted,
        .microphone: .granted,
        .speechRecognition: .granted,
    ]

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
        settings.actions.enabled = true
        settings.voice.enabled = true
        settings.voice.spokenReplies = .off
        settings.shelf.enabled = true
        settings.glance.replyPreviews = true
        settings.history.noticeAcknowledged = true

        let permissions = PermissionsCenter(probe: StaticPermissionProbe(permissionStatuses, default: .notDetermined),
                                            defaults: defaults,
                                            openURL: { _ in },
                                            relauncher: PromoRelauncher())
        let approvals = ApprovalStore(defaults: defaults)
        let eventKit = DemoEventKitService(now: PromoContent.stageNow, timeZone: PromoContent.stageZone)
        let tools = ToolRegistry(tools: [CalendarCreateEventTool(eventKit: eventKit, clock: PromoContent.stageClock)])
        // The executor stays on the real clock: it times the approval card's arming with it.
        let executor = ToolExecutor(permissions: permissions, approvals: approvals, log: nil)
        let timing = PromoTiming()
        let chat = ChatSession(settings: settings, makeClient: { PromoLLMClient(timeScale: timing.scale) }, tools: tools,
                               executor: executor, permissions: permissions, isDemo: false)

        let voiceScript = PromoVoiceScript()
        var services = NotchServices.inert(settings: settings, chat: chat)
        services.permissions = permissions
        services.approvals = approvals
        services.voice = VoiceController(settings: settings,
                                         makeEngine: { ScriptedSpeechEngine(script: voiceScript.steps) },
                                         interruptions: InertVoiceInterruptions(),
                                         holdProbe: { _ in nil })
        let history = HistoryController(settings: settings, chat: chat, store: ConversationStore(location: .inMemory),
                                        now: { PromoContent.stageNow })
        services.history = history
        services.recents = RecentsState(history: history)
        // Painted tiles: Quick Look and system type icons never appear on stage.
        services.shelf = ShelfController(store: ShelfStore(directory: nil, thumbnailer: PromoShelfThumbnailer()),
                                         settings: settings)
        services.inserter = InsertCoordinator(
            inserter: AnswerInserter(pasteboard: NSPasteboard.withUniqueName(), keys: PromoKeySender(),
                                     environment: PromoInsertEnvironment()),
            settings: settings
        )

        let viewModel = NotchViewModel(settings: settings, chat: chat, services: services)
        viewModel.closedNotchSize = PromoLayout.video.notchSize
        viewModel.hasPhysicalNotch = true
        // A services graph makes link opening live; the stage never opens anything.
        viewModel.openExternalURL = { _ in }
        // The privacy fix: the notch records the fictional Studio app, never the Mac's frontmost app.
        viewModel.debugFrontmostApp = PromoContent.studioApp
        // Phase ears on the closed notch, and the reply preview. Nothing posts: the inert glance has no
        // notification presenter or attention monitor.
        viewModel.glance.start()

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("otto-promo-\(UUID().uuidString)", isDirectory: true)
        return PromoCast(settings: settings, chat: chat, viewModel: viewModel, permissions: permissions,
                         approvals: approvals, tools: tools, executor: executor, eventKit: eventKit, timing: timing,
                         voiceScript: voiceScript, fixtureDirectory: fixtureDirectory)
    }

    /// Caches every permission status before anything reads it, so no row or card changes on camera.
    func warmUp() async {
        await permissions.refresh(Permission.systemWide)
    }

    /// Creates the per-run fixture folder and returns it.
    @discardableResult
    func makeFixtureDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        return fixtureDirectory
    }

    /// Removes the per-run fixture folder (and whatever a take wrote into it).
    func removeFixtureDirectory() {
        try? FileManager.default.removeItem(at: fixtureDirectory)
    }

    /// Leaves nothing running (a scripted turn, a pending approval), removes the fixture folder and drops
    /// the throwaway defaults again.
    func tearDown() {
        chat.reset()
        viewModel.inserter.reset()
        removeFixtureDirectory()
        UserDefaults(suiteName: Self.defaultsSuite)?.removePersistentDomain(forName: Self.defaultsSuite)
    }

    // MARK: Tool turns

    /// Sends an action turn's prompt (instantly, at `timing.scale` 0) and waits for its approval card.
    /// Returns false if the card never came. The scale is left at 0; set it back when the turn is done.
    func sendUntilApproval(_ conversation: PromoConversation, timeout: Double = 10) async -> Bool {
        timing.scale = 0
        chat.send(text: conversation.prompt, attachments: [])
        return await Self.waitUntil(timeout: timeout) { chat.pendingApproval != nil }
    }

    /// Plays a whole action turn off camera: sends it, approves the card as a reviewed hardware click
    /// would (the executor still checks the call), and waits for the confirmation to finish. The
    /// transcript then shows the added row with its Undo link. Returns false if any step timed out.
    func preRollActionTurn(_ conversation: PromoConversation, timeout: Double = 10) async -> Bool {
        defer { timing.scale = 1 }
        guard await sendUntilApproval(conversation, timeout: timeout) else { return false }
        chat.resolveApproval(.run(ApprovalOptions()), hardwareConfirmed: true,
                             visibleSince: Date(timeIntervalSinceNow: -60))
        return await Self.waitUntil(timeout: timeout) { !chat.isStreaming && chat.pendingApproval == nil }
    }

    /// Polls `condition` every 20 ms until it holds (true) or `timeout` seconds pass (false).
    static func waitUntil(timeout: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    // MARK: Privacy

    /// Why the stage is not safe to film, or nil: the notch recorded an app other than the fictional
    /// Studio app, or a reply offers to paste somewhere.
    func privacyProblem() -> String? {
        if let app = viewModel.openContextApp, app != PromoContent.studioApp {
            return "The notch recorded a real frontmost app (\(app.name))."
        }
        if viewModel.inserter.targets.values.contains(where: { $0.app != PromoContent.studioApp }) {
            return "A turn recorded a real app as its paste target."
        }
        for message in chat.messages where message.role == .assistant {
            if viewModel.insertTarget(forAssistant: message.id) != nil {
                return "A reply offers \u{201C}Paste into\u{201D}."
            }
        }
        return nil
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
        // The recorder stops the stage as soon as it sees `done` (or kills a stalled take), so the fixture
        // folder is removed before `done`, on a failure and on SIGTERM, not only in tearDown.
        cleanupDirectory = cast.fixtureDirectory
        startTerminationCleanup()

        let layout = PromoLayout.video
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let wallpaper = PromoWallpaper.image(
            pixelSize: CGSize(width: layout.screenRect.width * scale, height: layout.screenRect.height * scale)
        )
        let state = PromoStageState(pointer: PromoDirector.restingPointer(in: layout))
        let director = PromoDirector(layout: layout, cast: cast, state: state)

        let stage = makeStageWindow(
            size: layout.stageSize,
            rootView: PromoStageView(layout: layout, wallpaper: wallpaper, viewModel: cast.viewModel, settings: cast.settings, state: state)
        )
        window = stage
        startHeartbeat(state)

        Task { @MainActor in
            // The opening state (and any off-camera pre-roll) is set before the recorder looks.
            await director.prepare(scene)
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
            if let problem = cast.privacyProblem() {
                fail("Take \(scene.rawValue) isn't safe to publish: \(problem)")
            }
            cast.removeFixtureDirectory()
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
        // No order-in/out animation (see SnapshotRenderer.render): a closed stage window would strand its
        // animation's worker thread.
        window.animationBehavior = .none
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
            var last = ContinuousClock.now
            while true {
                state.heartbeat.toggle()
                try? await Task.sleep(for: .milliseconds(8))
                let gap = ContinuousClock.now - last
                last = .now
                if gap > .milliseconds(60), ProcessInfo.processInfo.environment["OTTO_PROMO_HITCHES"] != nil {
                    FileHandle.standardError.write(Data("promo hitch: \(gap)\n".utf8))
                }
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
                removeCleanupDirectory()
                exit(2)
            }
            // The recorder that launched us is gone: don't linger.
            if getppid() != parent {
                removeCleanupDirectory()
                exit(3)
            }
        }
        timer.resume()
        watchdog = timer
    }

    private static var watchdog: DispatchSourceTimer?
    private static var terminationSource: DispatchSourceSignal?
    /// The per-run fixture folder, removed on every way out.
    nonisolated(unsafe) private static var cleanupDirectory: URL?

    private static func removeCleanupDirectory() {
        if let directory = cleanupDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func startTerminationCleanup() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            removeCleanupDirectory()
            exit(0)
        }
        source.resume()
        terminationSource = source
    }

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
        removeCleanupDirectory()
        exit(1)
    }
}

// MARK: - Scenes

enum PromoScene: String, CaseIterable {
    case story
    case act
    case shelfVoice = "shelf-voice"
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
        case .act: return "Acts with your OK"
        case .shelfVoice: return "Keeps files at hand, then asks out loud"
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
            return "The film's first take: hover opens Otto and the pointer leaves, so it tucks away → three desktop files are dragged onto the notch, the split wells show and the right “Ask about it” well takes them as chips → the open tab is clicked in, “What should I fix before Friday?” is typed and sent with the send button → thinking, a web search with sources, the list streams (with a Swift code block) → as “Pay invoice” lands a click outside tucks it away, and the orb and writing glyph carry on → the reply finishes and its first line drops under the camera → the pointer rests on it, so the preview holds."
        case .act:
            return "Picks up on story's last frame: the pointer rests on the reply preview → a click opens the answer → “Schedule Sam's review for tomorrow at 10” is typed and sent → one line streams, then the calendar card rises and its ring fills → once armed, the pointer clicks Add Event → the row reads Added “Release notes review” with Undo, and a short confirmation streams → the pointer rests by Undo, then a click outside tucks it away."
        case .shelfVoice:
            return "Picks up on act's closed notch: two desktop files are dragged onto the notch → the split wells show and the left “Keep on Shelf” well takes them → two tiles land selected on the Shelf page, and after the landing hold the notch folds away → the listening pill grows and “Write a quick launch update for the team” builds word by word → on release it sends, the notch opens under the act turn and a paste-ready update streams → a click outside tucks it away."
        case .hero:
            return "Closed notch → pointer hovers, Otto springs open → the browser-tab suggestion is clicked in → “Summarize this in 3 bullets” is typed and sent → Otto reads the page, searches the web and streams three bullets with sources → a click outside tucks it away while the writing glyph finishes the closing line → the reply's first line drops under the camera for its real 4 s and retracts to the unread dot → the dot's ear retracts, so the take ends as it began (a loop reset, not product behavior: the real notch keeps the dot until the reply is read)."
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
            return "From the closed notch, the Settings window scales in on the Models tab (the API key saved in Keychain, the models with their prices, response style) and Otto becomes the frontmost app in the menu bar."
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

    // Pointer targets on Otto's own UI are offsets from the notch and the open panel, measured on 1.1 renders
    // of this stage (PromoLayout.video, 2 px per pt in the master): frames extracted from the recorded takes at
    // the marks named below. Re-measure them whenever the notch's layout changes.

    /// Where the pointer rests between moments. Scenes start and (after a click outside) end
    /// here, so the takes cut together and the hero clip loops cleanly.
    static func restingPointer(in layout: PromoLayout) -> CGPoint {
        CGPoint(x: layout.screenRect.minX + layout.screenRect.width * 0.76, y: layout.screenRect.minY + layout.screenRect.height * 0.64)
    }

    private var notchCenter: CGPoint {
        CGPoint(x: layout.notchTop.x + 6, y: layout.notchTop.y + layout.notchSize.height * 0.55)
    }

    private var panelLeft: CGFloat { layout.notchTop.x - NotchMetrics.openWidth / 2 }
    private var panelRight: CGFloat { layout.notchTop.x + NotchMetrics.openWidth / 2 }
    private var panelBottom: CGFloat { layout.notchTop.y + viewModel.renderedShapeSize.height }

    /// Center of the send button (bottom-right of the composer). Still holds on 1.1
    /// (docs/snapshots/approval-event.png, and story at send).
    private var sendButton: CGPoint {
        CGPoint(x: panelRight - 62, y: panelBottom - 44)
    }

    /// A point on the chip tray's last row, `offset` from the tray's leading edge (story at tab-attached).
    private func chip(atX offset: CGFloat) -> CGPoint {
        CGPoint(x: panelLeft + 46 + offset, y: panelBottom - 104)
    }

    /// Beside the composer, off the panel (the pointer waits here while typing).
    private var besideComposer: CGPoint {
        CGPoint(x: panelRight + 56, y: panelBottom - 20)
    }

    /// The drop wells split the open panel down the middle (DropZonesOverlay); these sit in each well's upper
    /// half, on its title (story at zone-ask, shelf-voice at zone-shelf).
    private var rightWell: CGPoint {
        CGPoint(x: layout.notchTop.x + NotchMetrics.openWidth / 4, y: layout.notchTop.y + Self.wellTitleY)
    }

    private var leftWell: CGPoint {
        CGPoint(x: layout.notchTop.x - NotchMetrics.openWidth / 4, y: layout.notchTop.y + Self.wellTitleY)
    }

    static let wellTitleY: CGFloat = 70

    /// On the reply preview's text, under the camera (story at pointer-on-preview; act starts here).
    private var previewDropPoint: CGPoint {
        CGPoint(x: layout.notchTop.x + Self.previewDropOffset.width, y: layout.notchTop.y + Self.previewDropOffset.height)
    }

    static let previewDropOffset = CGSize(width: 40, height: 46)

    /// The approval card's Add Event button (act at approval-armed).
    private var addEventButton: CGPoint {
        CGPoint(x: panelRight - Self.addEventInset.width, y: panelBottom - Self.addEventInset.height)
    }

    static let addEventInset = CGSize(width: 110, height: 109)

    /// Just right of the Added row's Undo link, not on it (act at rest-by-undo).
    private var undoRest: CGPoint {
        CGPoint(x: panelRight - Self.undoRestInset.width, y: panelBottom - Self.undoRestInset.height)
    }

    static let undoRestInset = CGSize(width: 28, height: 150)

    /// Desktop icons: one column at the desktop's right edge, as Finder arranges them, clear of every close-up
    /// on the notch. `desktopIconCenter` is the center of icon `index` (tile and name together).
    static let desktopIconPitch: CGFloat = 98

    static func desktopIconCenter(_ index: Int, in layout: PromoLayout) -> CGPoint {
        CGPoint(x: layout.screenRect.maxX - 125,
                y: layout.screenRect.minY + layout.notchSize.height + 78 + CGFloat(index) * desktopIconPitch)
    }

    /// Where the pointer grabs a selected group: on the tile of icon `index`, left of center, so the carried
    /// stack (which hangs right of the pointer) stays on the screen.
    private func grabPoint(on index: Int) -> CGPoint {
        let icon = Self.desktopIconCenter(index, in: layout)
        return CGPoint(x: icon.x - 6, y: icon.y - 12)
    }

    /// Somewhere calm on the wallpaper, well clear of the panel.
    private var outside: CGPoint { Self.restingPointer(in: layout) }

    /// Where the context scene picks up its files.
    private var dragStart: CGPoint {
        CGPoint(x: layout.screenRect.minX + layout.screenRect.width * 0.24, y: layout.screenRect.minY + layout.screenRect.height * 0.66)
    }

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
        didOpen(nil)
    }

    /// After every open the director performs: the privacy guard (the notch keeps no frontmost app, so no
    /// reply can offer to paste anywhere), then the `open` mark.
    private func didOpen(_ note: String?) {
        viewModel.setOpenContextApp(nil)
        mark("open", note)
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

    func sendWithButton(glide: Double = 0.6) async {
        await move(to: sendButton, duration: glide)
        await click()
        send(note: "button")
    }

    /// Sends the composer (Return, or after the button's click), refusing to film a turn whose paste
    /// target could name a real app.
    func send(note: String? = "return") {
        checkPrivacy()
        viewModel.send()
        mark("send", note)
    }

    /// Stops the take if the stage could show a real app's name or icon (see `PromoCast.privacyProblem`).
    func checkPrivacy() {
        if viewModel.openContextApp != nil {
            PromoStage.fail("The notch holds a frontmost app at a send (\(viewModel.openContextApp?.name ?? "")).")
        }
        if let problem = cast.privacyProblem() {
            PromoStage.fail(problem)
        }
    }

    /// Click on the wallpaper: the notch tucks away.
    func clickOutside(glide: Double = 0.8) async {
        await move(to: outside, duration: glide)
        await click()
        viewModel.close()
        mark("close", "click")
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

    /// When the reply preview last dropped under the camera (director time).
    private var previewShownAt: Double?

    /// Waits for the closed notch's reply preview (the real one, after a reply finishes while closed) and
    /// marks it. The take fails if it never comes.
    func waitForPreview(limit: Double = 6) async {
        let arrived = await PromoCast.waitUntil(timeout: limit) { self.viewModel.glance.preview != nil }
        guard arrived else { PromoStage.fail("The reply preview never dropped under the camera.") }
        previewShownAt = elapsed
        mark("preview")
    }

    /// Seconds left on the preview's real countdown, if it has been running unhovered since it appeared.
    private var previewCountdownLeft: Double {
        let shown = previewShownAt ?? elapsed
        return ReplyPreviewMetrics.visibleDuration.timeInterval - (elapsed - shown)
    }

    /// Polls `condition` every 20 ms (director time), failing the take with `problem` after `limit` seconds.
    private func require(_ problem: String, limit: Double, _ condition: @escaping @MainActor () -> Bool) async {
        let met = await PromoCast.waitUntil(timeout: limit, condition)
        if !met { PromoStage.fail(problem) }
    }

    // MARK: Watchers

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

    /// The approval card's life, for the camera and the approve: approval-shown (the card is pending),
    /// approval-visible (the card stamped itself reviewed), approval-armed (its arming delay has passed, as
    /// SelfTest's `approveOnceArmed` waits), then the client call's tool-start, tool-done and undo-visible.
    private(set) var isApprovalArmed = false

    private func watchActions() {
        Task { @MainActor [weak self] in
            var shown: String?
            var visible = false
            var shownAt = 0.0
            var started = Set<String>()
            var done = Set<String>()
            var undoMarked = Set<String>()
            let began = self?.elapsed ?? 0
            while let self, self.elapsed - began < 40 {
                if let approval = self.cast.chat.pendingApproval {
                    if shown != approval.callID {
                        shown = approval.callID
                        visible = false
                        shownAt = self.elapsed
                        self.mark("approval-shown", approval.toolName)
                    }
                    if !visible, let visibility = self.viewModel.approvalVisibility, visibility.callID == approval.callID {
                        visible = true
                        self.mark("approval-visible")
                    } else if !visible, self.elapsed - shownAt > 3 {
                        // The card never stamped itself in the stage window: the same call the card makes.
                        PromoStage.logger.notice("approval visibility fallback: noteApprovalReviewed")
                        self.viewModel.noteApprovalReviewed(callID: approval.callID)
                        if self.viewModel.approvalVisibility?.callID == approval.callID {
                            visible = true
                            self.mark("approval-visible", "fallback")
                        }
                    }
                    if visible, !self.isApprovalArmed, let visibility = self.viewModel.approvalVisibility,
                       ProcessInfo.processInfo.systemUptime >= visibility.sinceUptime + approval.armingDelay.timeInterval + 0.05 {
                        self.isApprovalArmed = true
                        self.mark("approval-armed")
                    }
                }
                for call in self.cast.chat.messages.last?.toolCalls ?? [] {
                    if call.status == .running || call.status.isTerminal, started.insert(call.id).inserted {
                        self.mark("tool-start", call.name)
                    }
                    if call.status.isTerminal, done.insert(call.id).inserted {
                        self.mark("tool-done", call.name)
                    }
                    if ToolCallCard.canUndo(call, now: Date()), undoMarked.insert(call.id).inserted {
                        self.mark("undo-visible")
                    }
                }
                if !undoMarked.isEmpty && !self.cast.chat.isStreaming { break }
                try? await Task.sleep(for: .milliseconds(15))
            }
        }
    }

    /// Marks listening once, and one `transcript` per change of the words heard (note = the text).
    private func watchVoice() {
        Task { @MainActor [weak self] in
            var sawListening = false
            var heard = ""
            let began = self?.elapsed ?? 0
            while let self, self.elapsed - began < 15 {
                let voice = self.viewModel.voice
                if voice.phase == .listening, !sawListening {
                    sawListening = true
                    self.mark("listening")
                }
                let text = voice.transcript
                if !text.isEmpty, text != heard {
                    heard = text
                    self.mark("transcript", text)
                }
                if sawListening, voice.phase == .idle { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    // MARK: Drag

    /// Presses on the icons `indexes` and picks up their copies: selected, ghosted, carried as a stack.
    private func pickUp(_ indexes: Set<Int>, files: [PromoDesktopFile]) async {
        withAnimation(.easeOut(duration: 0.07)) {
            state.isPointerPressed = true
            state.desktopFilesSelected = indexes
        }
        await wait(0.1)
        state.draggedFiles = files
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            state.isPointerPressed = false
            state.isDraggingFiles = true
            state.desktopFilesDimmed = indexes
        }
        mark("drag-start")
    }

    /// The drop: the stack is gone and the icons are back to normal.
    private func endDrag() {
        withAnimation(.easeOut(duration: 0.18)) {
            state.isDraggingFiles = false
            state.desktopFilesDimmed = []
            state.desktopFilesSelected = []
        }
    }

    // MARK: Scenes

    /// Sets the opening state, before the recorder starts (so the pre-roll matches it). Async, so a
    /// take can await setup (permission statuses, an off-camera pre-roll of a turn) before `ready.json`.
    func prepare(_ scene: PromoScene) async {
        let vm = viewModel
        await cast.warmUp()
        switch scene {
        case .story:
            vm.debugSeed(presentation: .closed, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
            state.showsDesktopFiles = true
            state.desktopFilesSelected = [0, 1, 2]
        case .act:
            await prepareAct()
        case .shelfVoice:
            await prepareShelfVoice()
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
            // Picks up where shelf-voice ends: closed notch, pointer at rest. The window scales in.
            vm.debugSeed(presentation: .closed, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
            state.showsDesktopFiles = true
        }
    }

    /// The finished Friday turn (the three files and the tab), as story leaves it.
    private func seedFridayTurn() -> ChatMessage {
        let turn = PromoContent.finishedTurn(PromoContent.friday,
                                             attachments: PromoContent.droppedFiles() + [PromoContent.browserTab()])
        cast.chat.debugSeed(messages: turn, isStreaming: false)
        return turn[1]
    }

    /// Story's last frame: the notch closed on the unread Friday answer, its first line dropped under the
    /// camera with the pointer resting on it (so it holds, brightened, and runs no countdown).
    private func prepareAct() async {
        // An Undo token expires 10 minutes after the stage's clock, checked against the real one.
        guard Date() < PromoContent.stageNow else {
            PromoStage.fail("The stage date (\(PromoContent.stageNow)) has passed: Undo would expire on camera.")
        }
        let answer = seedFridayTurn()
        await warmConversationLayout()
        let vm = viewModel
        vm.debugSeed(presentation: .closed, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: true)
        vm.glance.debugSeed(phase: .idle, preview: ReplyPreview.make(from: answer))
        vm.isHovering = true
        vm.glance.isPreviewHovered = true
        state.showsDesktopFiles = true
        state.pointer = previewDropPoint
        fridayAnswerID = answer.id
    }

    /// Opens the seeded conversation once off camera and closes it again, so its first layout (the Markdown,
    /// the code block, the chips) isn't paid for on camera: laid out cold, the first open on a long transcript
    /// holds the main thread for a few frames.
    private func warmConversationLayout() async {
        viewModel.open(reason: .programmatic, focus: false)
        viewModel.setOpenContextApp(nil)
        await wait(0.8)
        viewModel.close()
        await wait(0.3)
    }

    private var fridayAnswerID: UUID?
    /// shelf-voice's two files, written to the cast's per-run folder.
    private var shelfFileURLs: [URL] = []

    /// Act's last state, off camera: the act turn played and approved (so the voice answer opens under
    /// the same Added row and Undo), the notch closed and read, the pointer at rest.
    private func prepareShelfVoice() async {
        guard Date() < PromoContent.stageNow else {
            PromoStage.fail("The stage date (\(PromoContent.stageNow)) has passed: Undo would expire on camera.")
        }
        _ = seedFridayTurn()
        cast.voiceScript.steps = PromoContent.voiceScript
        guard await cast.preRollActionTurn(PromoContent.schedule) else {
            PromoStage.fail("The act turn's off-camera pre-roll didn't finish.")
        }
        guard let call = cast.chat.messages.last?.toolCalls.first, call.status == .succeeded else {
            PromoStage.fail("The pre-rolled calendar call didn't succeed.")
        }
        // Let the glance settle on the finished turn, then clear what it left on the closed notch.
        await wait(0.4)
        await warmConversationLayout()
        let vm = viewModel
        vm.debugSeed(presentation: .closed, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
        vm.glance.debugSeed(phase: .idle, preview: nil)
        state.showsDesktopFiles = true
        state.pointer = Self.restingPointer(in: layout)
        do {
            shelfFileURLs = try PromoContent.writeFixtures(PromoContent.shelfFixtures, to: cast.makeFixtureDirectory())
        } catch {
            PromoStage.fail("Couldn't write the Shelf fixtures: \(error.localizedDescription)")
        }
        await cast.permissions.refresh([.microphone, .speechRecognition])
    }

    func play(_ scene: PromoScene) async {
        switch scene {
        case .story: await playStory()
        case .act: await playAct()
        case .shelfVoice: await playShelfVoice()
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
        await hoverOpen(glide: 0.7)
        await wait(0.3)
        suggestTab()
        await wait(0.35)
        // Click the dashed suggestion to attach the page.
        await move(to: chip(atX: 58), duration: 0.5)
        await click()
        viewModel.engage()
        viewModel.acceptSuggestedTab()
        mark("tab-attached")
        await wait(0.25)
        await type(PromoContent.summarize.prompt, baseInterval: 0.044)
        await wait(0.3)
        watchActivities()
        await sendWithButton(glide: 0.5)
        await move(to: CGPoint(x: panelRight + 16, y: layout.notchTop.y + 236), duration: 0.8)
        await waitForAnswerText()
        // Let all three bullets land (the pointer sets off as the third starts), then tuck the
        // notch away while the closing line is still to come: the writing glyph carries on.
        await waitForText(containing: "Quiet by default")
        await clickOutside(glide: 0.6)
        await waitForReply()
        // The real preview: the reply's first line drops under the camera for its 4 s, then retracts.
        await waitForPreview()
        await require("The reply preview never retracted.", limit: 8) { self.viewModel.glance.preview == nil }
        mark("preview-retract")
        await wait(0.25)
        // Loop reset, not product behavior: the real notch keeps the unread dot until the reply is read.
        // For the README loop the dot's ear retracts into the notch (as it does once the reply is read), so
        // the take ends exactly as it began and the loop has no seam.
        withAnimation(Theme.Motion.hover) { viewModel.hasUnreadReply = false }
        mark("ears-retract")
        await wait(0.7)
    }

    /// The film's first take (see `PromoScene.summary`): the question typed in the context beat is the one
    /// that is sent and answered, and the take ends on the reply preview the act take opens.
    private func playStory() async {
        let vm = viewModel
        // An establishing beat on the whole display before the pointer sets off.
        await wait(0.8)
        // 1. One glance away: hover, it springs open; the pointer leaves, it tucks away.
        await hoverOpen(glide: 1.0)
        await wait(1.2)
        await move(to: CGPoint(x: panelRight + 30, y: layout.notchTop.y + 170), duration: 0.45)
        vm.close()
        mark("close", "leave")

        // 2. Knows what you're looking at: drag three files onto the notch, add the open tab.
        await move(to: grabPoint(on: 1), duration: 0.8)
        await wait(0.2)
        await pickUp([0, 1, 2], files: PromoDesktopFile.contextFiles)
        await wait(0.2)
        await move(to: notchCenter, duration: 1.2)
        vm.open(reason: .drag, focus: false)
        didOpen("drag")
        await wait(0.15)
        // The Shelf is on, so the drag shows the split wells.
        vm.updateDropSession(DropSession(zone: .ask, itemCount: 3, acceptsShelf: true))
        vm.isDropTargeted = true
        mark("drop-zones")
        await move(to: rightWell, duration: 0.35)
        mark("zone-ask")
        await wait(0.45)
        vm.updateDropSession(nil)
        vm.isDropTargeted = false
        endDrag()
        vm.engage()
        mark("drop")
        for attachment in PromoContent.droppedFiles() {
            vm.addAttachment(attachment)
            await wait(0.12)
        }
        mark("chips-landed")
        await wait(0.3)
        suggestTab()
        await wait(0.35)
        // The dashed suggestion sits at the start of the tray's last row: click it in.
        await move(to: chip(atX: 58), duration: 0.5)
        await click()
        vm.acceptSuggestedTab()
        mark("tab-attached")
        await wait(0.25)
        await move(to: besideComposer, duration: 0.45)
        await type(PromoContent.friday.prompt, baseInterval: 0.044)
        await wait(0.3)

        // 3. Answers that stream in: send, think, search, stream.
        watchActivities()
        await sendWithButton()
        await move(to: CGPoint(x: panelRight + 70, y: layout.notchTop.y + 240), duration: 0.8)
        await waitForAnswerText()
        // As the last bullet starts, the pointer sets off: it lands, and the notch is tucked away
        // before the closing line.
        await waitForText(containing: "Pay invoice")
        // 4. Keeps working while you do: tuck it away mid-answer, the orb and writing glyph carry on.
        await clickOutside(glide: 0.75)
        await waitForReply()
        await waitForPreview()
        await wait(0.7)
        mark("pointer-to-preview")
        await move(to: previewDropPoint, duration: 0.8)
        // What ReplyPreviewDrop's .onHover does: the countdown pauses and the line brightens.
        withAnimation(Theme.Motion.hover) {
            vm.isHovering = true
            vm.glance.isPreviewHovered = true
        }
        guard vm.glance.preview != nil, previewCountdownLeft >= 1.0 else {
            PromoStage.fail("The preview had \(String(format: "%.2f", previewCountdownLeft)) s left at pointer-on-preview (needs 1.0).")
        }
        mark("pointer-on-preview", String(format: "%.2f s left", previewCountdownLeft))
        await wait(0.6)
        guard vm.glance.preview != nil else { PromoStage.fail("The preview was gone at the cut.") }
    }

    /// Acts with your OK: opens the answer from the preview, asks for an event, approves it once armed.
    private func playAct() async {
        let vm = viewModel
        await wait(0.2)
        await click()
        mark("click")
        // The preview's click path: open focused at the answer's first line.
        vm.openToReply(fridayAnswerID)
        didOpen("preview")
        vm.isHovering = false
        vm.glance.isPreviewHovered = false
        await wait(0.4)
        await move(to: besideComposer, duration: 0.45)
        await type(PromoContent.schedule.prompt, baseInterval: 0.04)
        await wait(0.15)
        watchActivities()
        watchActions()
        send(note: "return")
        await waitForAnswerText()
        await require("The approval card never armed.", limit: 20) { self.isApprovalArmed }
        guard vm.composerText.isEmpty, vm.composerPlaceholder == "Waiting for your OK\u{2026}" else {
            PromoStage.fail("The composer doesn't read \u{201C}Waiting for your OK\u{2026}\u{201D} while the card is up.")
        }
        await wait(0.6)
        await move(to: addEventButton, duration: 0.5)
        await click()
        // The existing SelfTest seam (trusted input); the executor still enforces arming.
        vm.resolveApproval(.run(vm.approvalOptions), input: .trusted(.pointer))
        mark("approve")
        await waitForReply()
        guard let call = cast.chat.messages.last?.toolCalls.first, call.status == .succeeded, call.approvedVia != nil,
              ToolCallCard.canUndo(call, now: Date()) else {
            PromoStage.fail("The calendar call didn't succeed with a live Undo.")
        }
        await move(to: undoRest, duration: 0.4)
        await wait(0.4)
        mark("rest-by-undo")
        await clickOutside(glide: 0.5)
        await wait(0.8)
    }

    /// Keeps files at hand, then asks out loud.
    private func playShelfVoice() async {
        let vm = viewModel
        await wait(0.3)
        // Keeps files at hand: drag the last two icons onto the left well.
        await move(to: grabPoint(on: 3), duration: 0.6)
        await pickUp([3, 4], files: PromoDesktopFile.shelfFiles)
        await wait(0.15)
        await move(to: notchCenter, duration: 1.0)
        vm.open(reason: .drag, focus: false)
        didOpen("drag")
        vm.updateDropSession(DropSession(zone: .ask, itemCount: 2, acceptsShelf: true))
        vm.isDropTargeted = true
        mark("drop-zones")
        await move(to: leftWell, duration: 0.45)
        vm.updateDropSession(DropSession(zone: .shelf, itemCount: 2, acceptsShelf: true))
        mark("zone-shelf")
        await wait(0.35)
        endDrag()
        let providers = shelfFileURLs.compactMap { NSItemProvider(contentsOf: $0) }
        guard providers.count == 2, vm.performDrop(providers, zone: .shelf) else {
            PromoStage.fail("The Shelf drop was refused.")
        }
        mark("drop")
        await require("The two Shelf tiles never landed with painted thumbnails.", limit: 6) {
            let items = vm.shelf.store.items
            return items.count == 2 && items.allSatisfy { vm.shelf.store.renderedThumbnail(for: $0.id) != nil }
        }
        mark("tiles-landed")
        await move(to: Self.restingPointer(in: layout), duration: 0.5)
        await require("The Shelf's landing hold never let go.", limit: 6) { !vm.shelf.isHoldingLanding }
        mark("landing-released")
        vm.close()
        mark("close", "fold")

        // Ask out loud: hold the shortcut, talk, let go.
        await wait(0.5)
        watchVoice()
        vm.beginVoice(.hold(.shortcut))
        mark("voice-start")
        let prompt = PromoContent.launchUpdate.prompt
        await require("The pill never heard the whole prompt.", limit: 6) { vm.voice.transcript == prompt }
        await wait(0.3)
        let previousUser = cast.chat.lastUserMessage?.id
        watchActivities()
        vm.finishVoice(send: true)
        mark("voice-release")
        var sent = false
        var opened = false
        await require("The voice turn never sent and opened.", limit: 4) {
            if !sent, self.cast.chat.lastUserMessage?.id != previousUser {
                sent = true
                self.mark("send", "voice")
            }
            if !opened, vm.isOpen {
                opened = true
                self.didOpen("voice")
            }
            return sent && opened
        }
        guard cast.chat.lastUserMessage?.text == prompt else {
            PromoStage.fail("The sent text isn't the prompt (\(cast.chat.lastUserMessage?.text ?? "nil")).")
        }
        await waitForAnswerText()
        await waitForReply()
        await wait(0.5)
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
        didOpen("drag")
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
