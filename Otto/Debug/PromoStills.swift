//
//  PromoStills.swift
//  Otto
//
//  `Otto --promo-stills <dir>`: renders the marketing stills from the real views on the promo stage.
//
//    <dir>/screens/ask.png, context.png, answer.png, actions.png, glance.png, settings.png,
//                  shelf.png, voice.png, recents.png                           2080 × 1300 (2.5×)
//    <dir>/social-preview.png                                                  1280 × 640
//    <dir>/icon.png                                                            512 × 512
//    <dir>/poster-stage.png   3072 × 1728: the video stage with the film's finished answer and no
//                             pointer, which scripts/make_video.swift frames for the poster
//
//  Every still runs on the 1.1 promo cast (`PromoCast.make()`) and is checked with
//  `PromoCast.privacyProblem()` before it is captured.
//
//  Everything but the icon is written opaque (RGB, no alpha channel).
//
//  Views are hosted in a stage window below the desktop (never visible) and captured at 2×.
//

// Debug tooling: compiled only into Debug builds, or into a Release build made with the
// OTTO_TOOLS compilation condition (scripts/make_media.sh does this to record footage).
#if DEBUG || OTTO_TOOLS

import AppKit
import SwiftUI

extension PromoStage {
    /// Pixel density of the stills.
    static let stillScale: CGFloat = 2.5

    @MainActor
    static func renderStills(to directory: URL) {
        // Watchdog on a background queue: if rendering wedges the main thread, still exit non-zero.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 180) {
            FileHandle.standardError.write(Data("Promo stills timed out.\n".utf8))
            exit(1)
        }
        Task { @MainActor in
            let failures = await renderAllStills(to: directory)
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// Returns the number of stills that failed.
    @MainActor
    private static func renderAllStills(to directory: URL) async -> Int {
        let screens = directory.appendingPathComponent("screens", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: screens, withIntermediateDirectories: true)
        } catch {
            fail("Couldn't create \(screens.path): \(error.localizedDescription)")
        }
        let layout = PromoLayout.still
        let wallpaper = PromoWallpaper.image(
            pixelSize: CGSize(width: layout.screenRect.width * stillScale, height: layout.screenRect.height * stillScale)
        )

        var failures = 0
        var answerImage: CGImage?
        for still in PromoStill.allCases {
            let layout = still.layout
            guard let cast = PromoCast.make() else { fail("Couldn't open the promo defaults suite.") }
            let state = PromoStageState(pointer: .zero)
            guard let viewModel = await still.seed(cast: cast, state: state, layout: layout) else {
                cast.tearDown()
                report("Couldn't set up \(still.fileName).")
                failures += 1
                continue
            }
            if let problem = cast.privacyProblem() {
                cast.tearDown()
                report("\(still.fileName): \(problem)")
                failures += 1
                continue
            }
            let view = PromoStageView(layout: layout, wallpaper: wallpaper, viewModel: viewModel, settings: cast.settings, state: state)
            let crop = still.crop(in: layout)
            let image = await capture(
                view,
                size: layout.stageSize,
                settle: still.settleTime,
                scale: stillScale * layout.stageSize.width / crop.width,
                crop: crop,
                beforeCapture: { window in
                    // A focused composer shows its caret.
                    if still == .ask, let caret = PromoCaret.rect(in: window) {
                        state.caret = caret
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
            )
            // The glance still is mostly wallpaper at this framing: add a loupe on the closed notch
            // (rendered again at a higher scale, so it stays crisp) to show its activity ears.
            var loupe: CGImage?
            if still == .glance {
                loupe = await capture(
                    view,
                    size: layout.stageSize,
                    settle: still.settleTime,
                    scale: stillScale * GlanceLoupe.magnification,
                    crop: GlanceLoupe.sourceRect(in: layout)
                )
            }
            cast.tearDown()
            guard var image else {
                report("Couldn't render \(still.fileName).")
                failures += 1
                continue
            }
            if still == .glance, let loupe, let composed = GlanceLoupe.compose(still: image, loupe: loupe, layout: layout) {
                image = composed
            }
            if still == .answer { answerImage = image }
            if !writePNG(image, to: screens.appendingPathComponent(still.fileName), opaque: true) { failures += 1 }
        }

        // The poster's plate: the video stage at 2× (the masters' resolution) with the film's
        // finished answer reopened under the notch, and no pointer.
        if let poster = await renderPosterStage() {
            if !writePNG(poster, to: directory.appendingPathComponent("poster-stage.png"), opaque: true) { failures += 1 }
        } else {
            report("Couldn't render poster-stage.png.")
            failures += 1
        }

        // Social preview, built around the answer shot.
        let social = PromoSocialPreview(productShot: answerImage, wallpaper: wallpaper)
        if let image = await capture(social, size: PromoSocialPreview.size, settle: 0.4),
           let downsampled = resample(image, to: PromoSocialPreview.size) {
            if !writePNG(downsampled, to: directory.appendingPathComponent("social-preview.png"), opaque: true) { failures += 1 }
        } else {
            report("Couldn't render social-preview.png.")
            failures += 1
        }

        // App icon at 512 px, straight from the app's own icon.
        if let icon = appIcon(pixels: 512) {
            if !writePNG(icon, to: directory.appendingPathComponent("icon.png")) { failures += 1 }
        } else {
            report("Couldn't load the app icon.")
            failures += 1
        }
        return failures
    }

    @MainActor
    private static func renderPosterStage() async -> CGImage? {
        let layout = PromoLayout.video
        guard let cast = PromoCast.make() else { return nil }
        defer { cast.tearDown() }
        let wallpaper = PromoWallpaper.image(
            pixelSize: CGSize(width: layout.screenRect.width * 2, height: layout.screenRect.height * 2)
        )
        let state = PromoStageState(pointer: .zero)
        state.isPointerVisible = false
        await cast.warmUp()
        cast.chat.debugSeed(
            messages: PromoContent.finishedTurn(PromoContent.friday, attachments: PromoContent.droppedFiles() + [PromoContent.browserTab()]),
            isStreaming: false
        )
        cast.viewModel.debugSeed(presentation: .open, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
        let view = PromoStageView(layout: layout, wallpaper: wallpaper, viewModel: cast.viewModel, settings: cast.settings, state: state)
        return await capture(view, size: layout.stageSize, settle: 0.9, scale: 2)
    }

    // MARK: Capture

    @MainActor
    /// Renders `content` at `scale` pixels per point; `crop` (in points) trims the result.
    static func capture<Content: View>(
        _ content: Content,
        size: CGSize,
        settle: Double,
        scale: CGFloat = stillScale,
        crop: CGRect? = nil,
        beforeCapture: (@MainActor (NSWindow) async -> Void)? = nil
    ) async -> CGImage? {
        let root = content
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            .transaction { $0.disablesAnimations = true }
        let window = makeStageWindow(size: size, rootView: root)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        try? await Task.sleep(for: .milliseconds(Int(settle * 1000)))
        await beforeCapture?(window)
        guard let view = window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return nil }
        guard let crop else { return image }
        // CGImage space: top-left origin, pixels.
        let pixels = CGRect(
            x: (crop.minX * scale).rounded(),
            y: (crop.minY * scale).rounded(),
            width: (crop.width * scale).rounded(),
            height: (crop.height * scale).rounded()
        )
        return image.cropping(to: pixels)
    }

    static func resample(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: Int(size.width),
                  height: Int(size.height),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    @MainActor
    static func appIcon(pixels: Int) -> CGImage? {
        guard let icon = PromoStage.bundledIcon,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixels,
                  height: pixels,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// The icon exactly as designed (from the bundle's .icns), not the system-styled
    /// `applicationIconImage`, which newer macOS versions may tint.
    @MainActor
    static var bundledIcon: NSImage? {
        Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    }

    /// Writes an sRGB PNG; `opaque` flattens it to RGB (no alpha channel). Returns false (and
    /// reports) on failure.
    @discardableResult
    static func writePNG(_ image: CGImage, to url: URL, opaque: Bool = false) -> Bool {
        let image = opaque ? (flattened(image) ?? image) : image
        let rep = NSBitmapImageRep(cgImage: image)
        let converted = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
        guard let data = converted.representation(using: .png, properties: [:]) else {
            report("Couldn't encode \(url.lastPathComponent).")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            print(url.path)
            return true
        } catch {
            report("Couldn't write \(url.path): \(error.localizedDescription)")
            return false
        }
    }

    /// The image drawn onto black in an RGB context without alpha.
    static func flattened(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    static func report(_ message: String) {
        logger.error("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("promo stills: \(message)\n".utf8))
    }
}

// MARK: - Stills

enum PromoStill: CaseIterable {
    case ask
    case context
    case answer
    case actions
    case glance
    case settings
    case shelf
    case voice
    case recents

    var fileName: String {
        switch self {
        case .ask: return "ask.png"
        case .context: return "context.png"
        case .answer: return "answer.png"
        case .actions: return "actions.png"
        case .glance: return "glance.png"
        case .settings: return "settings.png"
        case .shelf: return "shelf.png"
        case .voice: return "voice.png"
        case .recents: return "recents.png"
        }
    }

    /// The stage composition the still is shot on: the same display for every still.
    var layout: PromoLayout { PromoLayout.still }

    /// The part of the stage the still shows, in points: the whole display, for every still, so
    /// the set shares one camera.
    func crop(in layout: PromoLayout) -> CGRect {
        CGRect(origin: .zero, size: layout.stageSize)
    }

    /// Seconds to let SwiftUI lay out (and measure its preference round-trips) before capture.
    var settleTime: Double {
        switch self {
        case .answer, .actions, .recents: return 0.9
        default: return 0.6
        }
    }

    /// The approval card has been on screen and reviewed for a minute, so it is armed and its ring is
    /// full (as `SnapshotStage.showArmedApproval`).
    static func armedApproval() -> NotchDebugSeed {
        var features = NotchDebugSeed()
        features.approvalVisibleSince = Date(timeIntervalSinceNow: -60)
        return features
    }

    /// Sets the still's state and returns the view model to film (nil: the setup failed). Async, so a
    /// still can await setup first (permission statuses, a turn played off camera at
    /// `cast.timing.scale` 0, Shelf thumbnails).
    @MainActor
    func seed(cast: PromoCast, state: PromoStageState, layout: PromoLayout) async -> NotchViewModel? {
        let vm = cast.viewModel
        let chat = cast.chat
        let top = layout.notchTop
        await cast.warmUp()
        switch self {
        case .ask:
            chat.debugSeed(messages: [], isStreaming: false)
            vm.debugSeed(
                presentation: .open,
                composerText: PromoContent.summarize.prompt,
                attachments: [PromoContent.browserTab()],
                suggestedTab: nil,
                hasUnreadReply: false
            )
            state.pointer = CGPoint(x: top.x + 232, y: top.y + 138)

        case .context:
            chat.debugSeed(messages: [], isStreaming: false)
            vm.debugSeed(
                presentation: .open,
                composerText: "",
                attachments: PromoContent.droppedFiles(),
                suggestedTab: PromoContent.browserTab(),
                hasUnreadReply: false
            )
            state.pointer = CGPoint(x: top.x - 150, y: top.y + 112)

        case .answer:
            chat.debugSeed(
                messages: PromoContent.finishedTurn(PromoContent.summarize, attachments: [PromoContent.browserTab()]),
                isStreaming: false
            )
            vm.debugSeed(presentation: .open, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
            state.isPointerVisible = false

        case .actions:
            // A fresh chat: the schedule prompt goes through the real tool registry and executor at
            // scale 0, up to the calendar card, which is then shown armed.
            chat.debugSeed(messages: [], isStreaming: false)
            guard await cast.sendUntilApproval(PromoContent.schedule) else { return nil }
            vm.debugSeed(presentation: .open, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
            vm.debugSeed(features: Self.armedApproval())
            state.isPointerVisible = false

        case .glance:
            // The reply finished while the notch was closed: its first line drops under the camera,
            // with the unread dot. `debugSeed` holds the preview without a countdown.
            let messages = PromoContent.finishedTurn(PromoContent.summarize, attachments: [PromoContent.browserTab()])
            chat.debugSeed(messages: messages, isStreaming: false)
            vm.debugSeed(presentation: .closed, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: true)
            guard let answer = messages.last, let preview = ReplyPreview.make(from: answer) else { return nil }
            vm.glance.debugSeed(phase: .idle, preview: preview)
            // Off to the side, where a hand rests after clicking away: never in the empty middle.
            state.pointer = CGPoint(x: layout.screenRect.maxX - 150, y: layout.screenRect.minY + layout.screenRect.height * 0.7)

        case .settings:
            chat.debugSeed(messages: [], isStreaming: false)
            vm.debugSeed(presentation: .closed, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
            state.showsSettings = true
            // The 1.1 window (560 pt wide, toolbar, Models through Response style) is 542 pt tall: at
            // 0.78 it ends about 20 pt above the still's bottom edge.
            state.settingsScale = 0.78
            // Settings is Otto's own window, so Otto is the frontmost app in the menu bar.
            state.menuBarApp = "Otto"
            state.isPointerVisible = false

        case .shelf:
            return await seedShelf(cast: cast, state: state)

        case .voice:
            chat.debugSeed(messages: [], isStreaming: false)
            vm.voice.debugSeed(phase: .listening, finalized: StillFixtures.voiceFinalized,
                               volatile: StillFixtures.voiceVolatile, levels: StillFixtures.voiceLevels)
            vm.debugSeed(presentation: .open, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
            state.isPointerVisible = false

        case .recents:
            chat.debugSeed(messages: [], isStreaming: false)
            // Reads the in-memory index first, as History does at launch.
            await vm.history.start()
            let summaries = StillFixtures.recentSummaries(currentID: chat.conversationID, now: vm.history.now())
            vm.history.debugSeed(summaries: summaries, continuation: nil)
            vm.recents.refresh()
            var features = NotchDebugSeed()
            features.route = .history
            vm.debugSeed(presentation: .open, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
            vm.debugSeed(features: features)
            // The row under the current conversation, as after ⌘Y.
            let rows = vm.recents.rows
            guard rows.count > 1 else { return nil }
            vm.recents.selectedID = rows[1].id
            state.isPointerVisible = false
        }
        return vm
    }

    /// The Shelf page with the five desktop files, the last two selected. The cast's Shelf renders
    /// with Quick Look, so this still films its own view model over the same cast with a Shelf whose
    /// thumbnails are painted (`StillShelfThumbnailer`): no file is ever read by Quick Look and no
    /// system type icon appears. The files live in the cast's fixture folder, which `tearDown` removes.
    @MainActor
    private func seedShelf(cast: PromoCast, state: PromoStageState) async -> NotchViewModel? {
        let chat = cast.chat
        let base = cast.viewModel
        let shelf = ShelfController(store: ShelfStore(directory: nil, thumbnailer: StillShelfThumbnailer()), settings: cast.settings)
        let services = NotchServices(
            permissions: cast.permissions,
            approvals: cast.approvals,
            voice: base.voice,
            history: base.history,
            recents: base.recents,
            glance: GlanceController.inert(settings: cast.settings, chat: chat),
            ledger: base.ledger,
            nowPlaying: base.nowPlaying,
            calendar: base.calendar,
            shelf: shelf,
            suggestions: base.suggestions,
            inserter: base.inserter,
            notifications: nil
        )
        let vm = NotchViewModel(settings: cast.settings, chat: chat, services: services)
        vm.closedNotchSize = base.closedNotchSize
        vm.hasPhysicalNotch = true
        vm.openExternalURL = { _ in }
        vm.debugFrontmostApp = PromoContent.studioApp

        chat.debugSeed(messages: [], isStreaming: false)
        var urls: [URL] = []
        do {
            let folder = try cast.makeFixtureDirectory()
            for file in StillFixtures.shelfFiles {
                let url = folder.appendingPathComponent(file.name)
                try file.contents.write(to: url, options: .atomic)
                urls.append(url)
            }
        } catch {
            PromoStage.report("Couldn't write the Shelf fixtures: \(error.localizedDescription)")
            return nil
        }
        let result = shelf.add(fileURLs: urls)
        guard result.added.count == urls.count else {
            PromoStage.report("Only \(result.added.count) of \(urls.count) files reached the Shelf.")
            return nil
        }
        let selectedNames = StillFixtures.shelfSelection
        let picked = shelf.store.items.filter { selectedNames.contains($0.name) }.map(\.id)
        for (index, id) in picked.enumerated() {
            shelf.select(id, modifiers: index == 0 ? [] : .command)
        }
        let items = shelf.store.items
        let painted = await PromoCast.waitUntil(timeout: 5) {
            items.allSatisfy { shelf.store.renderedThumbnail(for: $0.id) != nil }
        }
        guard painted else {
            PromoStage.report("The Shelf thumbnails never rendered.")
            return nil
        }
        var features = NotchDebugSeed()
        features.route = .shelf
        vm.debugSeed(presentation: .open, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
        vm.debugSeed(features: features)
        state.isPointerVisible = false
        return vm
    }
}

// MARK: - Still fixtures

/// Content only the new 1.1 stills show, all from the film's fictional world.
enum StillFixtures {
    // MARK: Voice

    /// What the voice still "hears": the heard words in white, the words still settling in gray.
    static let voiceFinalized = "Write a quick launch"
    static let voiceVolatile = "update for the team"
    static let voiceLevels: [Float] = [0.3, 0.52, 0.74, 0.46, 0.8, 0.58, 0.36, 0.7, 0.5, 0.62]

    // MARK: Shelf

    /// The five desktop files, in the order they reach the Shelf. The PNGs are only a signature and
    /// the PDF only a header: `StillShelfThumbnailer` paints every tile, so no file is ever decoded.
    static let shelfFiles: [(name: String, contents: Data)] = [
        ("launch-plan.md", Data("# Launch plan\n\n- Landing page: final\n- Release notes: review (Sam)\n".utf8)),
        ("screenshot.png", Data([0x89, 0x50, 0x4E, 0x47])),
        ("invoice.pdf", Data("%PDF-1.4\n%promo\n".utf8)),
        ("release-notes.md", Data("# Release notes\n\n- Sign-up works with pasted addresses\n- Calmer notifications\n".utf8)),
        ("hero-draft.png", Data([0x89, 0x50, 0x4E, 0x47])),
    ]

    /// The two files the film parks on the Shelf.
    static let shelfSelection: Set<String> = ["release-notes.md", "hero-draft.png"]

    // MARK: Recents

    /// Five conversations from the film's world: two today, two yesterday and one earlier in the week.
    /// The first is the current conversation. Five, not six: Recents grows with its rows, and with a
    /// sixth its footer (Open, Delete, Back and the retention line) runs off the bottom of the still.
    static func recentSummaries(currentID: UUID, now: Date) -> [ConversationSummary] {
        let rows: [(title: String, preview: String, search: String, hoursAgo: Double, messages: Int)] = [
            ("What to fix before Friday", "Three things stand between you and a calm Friday launch.",
             "What should I fix before Friday?\nThree things stand between you and a calm Friday launch.", 0.3, 4),
            ("Summarize On Calm Software", "Interruptions are the real cost.",
             "Summarize this in 3 bullets\nInterruptions are the real cost.", 1.5, 2),
            ("Why the sign-up button stays disabled", "The email field keeps a trailing space.",
             "Why does the sign-up button stay disabled?\nThe email field keeps a trailing space.", 26, 6),
            ("Team update for launch day", "Launch is on track for Friday.",
             "Write a short update for the team about launch day.\nLaunch is on track for Friday.", 30, 2),
            ("Invoice #1042 questions", "It's due Friday, the same day you ship.",
             "When is invoice #1042 due?\nIt's due Friday, the same day you ship.", 120, 2),
        ]
        return rows.enumerated().map { index, row in
            let updated = now.addingTimeInterval(-row.hoursAgo * 3_600)
            return ConversationSummary(
                id: index == 0 ? currentID : UUID(),
                title: row.title,
                preview: row.preview,
                searchText: row.search,
                createdAt: updated.addingTimeInterval(-600),
                updatedAt: updated,
                messageCount: row.messages,
                attachmentCount: 0,
                model: ModelOption.opus5.rawValue,
                blobs: [:],
                fileBytes: 4_096,
                fileModifiedAt: updated
            )
        }
    }
}

// MARK: - Shelf thumbnails

/// Paints every Shelf tile the shelf still shows, standing in for Quick Look so the tiles look the
/// same on every Mac and never show a system icon: hero-draft.png is a small dusk painting,
/// screenshot.png is `PromoContent.screenshotThumbnail`, a PDF is a white page with lines and a
/// small PDF label, and text files are a page of gray lines.
private struct StillShelfThumbnailer: ShelfThumbnailing {
    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> CGImage? {
        let name = url.lastPathComponent
        let side = max(size.width, size.height) * scale
        if name == "hero-draft.png" {
            return await MainActor.run { Self.cgImage(Self.heroPainting(side: side), side: side) }
        }
        if name == "screenshot.png" {
            return await MainActor.run { Self.cgImage(PromoContent.screenshotThumbnail(), side: side) }
        }
        switch url.pathExtension.lowercased() {
        case "pdf": return Self.page(size: size, scale: scale, pdfLabel: true)
        case "md", "txt": return Self.page(size: size, scale: scale, pdfLabel: false)
        default: return nil
        }
    }

    @MainActor
    private static func cgImage(_ image: NSImage, side: CGFloat) -> CGImage? {
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// A warm sky, a low sun and two dark hills, drawn in a 64-point square.
    @MainActor
    private static func heroPainting(side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let transform = NSAffineTransform()
            transform.scale(by: side / 64)
            transform.concat()
            NSGradient(colors: [
                NSColor(srgbRed: 0.95, green: 0.78, blue: 0.58, alpha: 1),
                NSColor(srgbRed: 0.55, green: 0.47, blue: 0.62, alpha: 1),
            ])?.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), angle: 90)
            NSColor(srgbRed: 0.99, green: 0.9, blue: 0.72, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 34, y: 26, width: 18, height: 18)).fill()
            NSColor(srgbRed: 0.36, green: 0.34, blue: 0.45, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: -24, y: -30, width: 80, height: 58)).fill()
            NSColor(srgbRed: 0.22, green: 0.22, blue: 0.3, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 18, y: -38, width: 76, height: 56)).fill()
            return true
        }
    }

    /// A white page (a document icon's proportions) with gray lines of "text"; a PDF also gets a small
    /// red label in its lower corner.
    private static func page(size: CGSize, scale: CGFloat, pdfLabel: Bool) -> CGImage? {
        let height = max(1, Int(size.height * scale))
        let width = max(1, Int(CGFloat(height) * 0.8))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let radius = w * 0.06
        context.setFillColor(CGColor(srgbRed: 0.98, green: 0.98, blue: 0.97, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: radius,
                               cornerHeight: radius, transform: nil))
        context.fillPath()
        let margin = w * 0.14
        let lineHeight = h * 0.035
        let pitch = h * 0.075
        let widths: [CGFloat] = pdfLabel ? [0.45, 0.9, 0.84, 0.0, 0.7, 0.7, 0.7]
                                         : [0.55, 0.9, 0.82, 0.88, 0.6, 0.0, 0.86, 0.78, 0.9, 0.5]
        var lineTop = h - margin * 1.2
        for (index, fraction) in widths.enumerated() {
            if fraction > 0 {
                let isHeading = index == 0
                context.setFillColor(isHeading ? CGColor(srgbRed: 0.35, green: 0.36, blue: 0.4, alpha: 1)
                                               : CGColor(srgbRed: 0.72, green: 0.72, blue: 0.74, alpha: 1))
                let line = CGRect(x: margin, y: lineTop - lineHeight, width: (w - margin * 2) * fraction,
                                  height: isHeading ? lineHeight * 1.4 : lineHeight)
                context.addPath(CGPath(roundedRect: line, cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2,
                                       transform: nil))
                context.fillPath()
            }
            lineTop -= pitch
        }
        guard pdfLabel else { return context.makeImage() }
        // The label: a small red tag with "PDF" in white, in the lower right.
        let tag = CGRect(x: w - margin - w * 0.34, y: margin * 0.9, width: w * 0.34, height: h * 0.12)
        context.setFillColor(CGColor(srgbRed: 0.86, green: 0.25, blue: 0.22, alpha: 1))
        context.addPath(CGPath(roundedRect: tag, cornerWidth: tag.height * 0.22, cornerHeight: tag.height * 0.22,
                               transform: nil))
        context.fillPath()
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, tag.height * 0.62, nil)
        let text = NSAttributedString(string: "PDF", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: tag.midX - bounds.width / 2 - bounds.minX,
                                       y: tag.midY - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}

// MARK: - Glance loupe

/// A magnified inset of the closed notch for the glance still: the source region is outlined on the
/// notch and shown again below it, 1.85× larger, on a card in Otto's panel style. The region takes in
/// the reply preview under the camera (372 × 68 pt), so the inset is 1721 × 315 px; its top edge stays
/// at y 330 px, centered, as in 1.0.
enum GlanceLoupe {
    static let magnification: CGFloat = 1.85

    /// The closed notch with its ears and the reply preview under it, in stage points. The preview is
    /// 368 pt wide, and "View" ends 6 pt left of it (measured on the 1.1 render of this still). So the
    /// region keeps a 2 pt margin either side, and its outline sits 1.6 pt outside that. Any wider and
    /// the inset cuts a menu title and the battery icon in half, or the outline runs through "View".
    static func sourceRect(in layout: PromoLayout) -> CGRect {
        let width: CGFloat = 372
        let height: CGFloat = 68
        return CGRect(x: layout.notchTop.x - width / 2, y: layout.notchTop.y - 3, width: width, height: height)
    }

    static func compose(still: CGImage, loupe: CGImage, layout: PromoLayout) -> CGImage? {
        let scale = PromoStage.stillScale
        let width = still.width, height = still.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        // Work in top-left-origin pixels, like the stills.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        func draw(_ image: CGImage, in rect: CGRect) {
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
            ctx.restoreGState()
        }
        ctx.interpolationQuality = .high
        draw(still, in: CGRect(x: 0, y: 0, width: width, height: height))

        let source = sourceRect(in: layout)
        let sourcePx = CGRect(x: source.minX * scale, y: source.minY * scale, width: source.width * scale, height: source.height * scale)
            .insetBy(dx: -4, dy: -2)
        let insetSize = CGSize(width: CGFloat(loupe.width), height: CGFloat(loupe.height))
        let inset = CGRect(x: (CGFloat(width) - insetSize.width) / 2, y: 330, width: insetSize.width, height: insetSize.height)
        let radius: CGFloat = 34

        // Faint guides from the outlined notch down to the inset.
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: sourcePx.minX + 12, y: sourcePx.maxY))
        ctx.addLine(to: CGPoint(x: inset.minX + radius, y: inset.minY))
        ctx.move(to: CGPoint(x: sourcePx.maxX - 12, y: sourcePx.maxY))
        ctx.addLine(to: CGPoint(x: inset.maxX - radius, y: inset.minY))
        ctx.strokePath()
        ctx.addPath(CGPath(roundedRect: sourcePx, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.42))
        ctx.setLineWidth(3)
        ctx.strokePath()

        // The inset: a lifted card holding the magnified notch.
        let card = CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 24), blur: 60, color: CGColor(gray: 0, alpha: 0.55))
        ctx.addPath(card)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(card)
        ctx.clip()
        draw(loupe, in: inset)
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: inset.insetBy(dx: 1.5, dy: 1.5), cornerWidth: radius - 1.5, cornerHeight: radius - 1.5, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.2))
        ctx.setLineWidth(3)
        ctx.strokePath()
        return ctx.makeImage()
    }
}

// MARK: - Social preview

/// GitHub's social card (1280 × 640): icon, name, tagline and subline on the left, the answer
/// shot (lid, menu bar, open notch) on the right, fading into the graphite backdrop.
struct PromoSocialPreview: View {
    static let size = CGSize(width: 1280, height: 640)

    let productShot: CGImage?
    let wallpaper: CGImage?

    private static let shotWidth: CGFloat = 780

    private func lidMask(scale: CGFloat) -> some View {
        let lid = PromoLayout.still.lidRect
        return RoundedRectangle(cornerRadius: PromoLayout.still.lidCornerRadius * scale, style: .continuous)
            .frame(width: lid.width * scale, height: lid.height * scale)
            .offset(x: lid.minX * scale, y: lid.minY * scale)
    }

    var body: some View {
        let stage = PromoLayout.still.stageSize
        let shotHeight = Self.shotWidth * stage.height / stage.width
        ZStack(alignment: .topLeading) {
            PromoBackdrop()
            // A faint wash of the wallpaper's dusk, so the card isn't flat black.
            RadialGradient(
                colors: [Theme.rgb(0x5B3F8C).opacity(0.35), .clear],
                center: UnitPoint(x: 0.78, y: 0.95),
                startRadius: 0,
                endRadius: 620
            )

            if let productShot {
                Image(decorative: productShot, scale: PromoStage.stillScale)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Self.shotWidth, height: shotHeight)
                    // Only the lid (no studio backdrop), fading out towards the bottom.
                    .mask(alignment: .topLeading) { lidMask(scale: Self.shotWidth / stage.width) }
                    .mask {
                        LinearGradient(
                            stops: [.init(color: .black, location: 0.72), .init(color: .clear, location: 1)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 16)
                    // Whole lid inside the card, so the menu bar's clock is never cut at the edge.
                    .offset(x: Self.size.width - Self.shotWidth - 22, y: 64)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    if let icon = PromoStage.bundledIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 84, height: 84)
                            // A soft pool of light, so the near-black icon lifts off the card.
                            .background {
                                Circle()
                                    .fill(RadialGradient(colors: [Color.white.opacity(0.14), .clear], center: .center, startRadius: 0, endRadius: 70))
                                    .frame(width: 150, height: 150)
                            }
                    }
                    Text("Otto")
                        .font(.system(size: 58, weight: .medium, design: .serif))
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(.leading, -8)
                .padding(.bottom, 34)
                Text("The AI assistant\nthat lives in your notch.")
                    .font(.system(size: 36, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Color.white)
                    .lineSpacing(4)
                    .fixedSize()
                    .padding(.bottom, 18)
                Text("Hover the notch, ask anything,\nget back to work.")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineSpacing(4)
                    .fixedSize()
                    .padding(.bottom, 40)
                // Plain factual wording for the API (no "Powered by" badge: Anthropic's trademark
                // guidelines ask for approval before using its marks that way). Two lines, so the
                // row stays clear of the product shot.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Native macOS")
                        Text("·").foregroundStyle(Color.white.opacity(0.35))
                        Text("Open source (MIT)")
                    }
                    Text("Uses the Claude API with your own key")
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.62))
            }
            .padding(.leading, 72)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

#endif
