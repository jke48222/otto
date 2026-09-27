//
//  PromoStills.swift
//  Otto
//
//  `Otto --promo-stills <dir>`: renders the marketing stills from the real views on the promo stage.
//
//    <dir>/screens/ask.png, context.png, answer.png, glance.png, settings.png   2080 × 1300 (2.5×)
//    <dir>/social-preview.png                                                  1280 × 640
//    <dir>/icon.png                                                            512 × 512
//    <dir>/poster-stage.png   3072 × 1728: the video stage with the film's finished answer and no
//                             pointer, which scripts/make_video.swift frames for the poster
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
            still.seed(cast: cast, state: state, layout: layout)
            let view = PromoStageView(layout: layout, wallpaper: wallpaper, viewModel: cast.viewModel, settings: cast.settings, state: state)
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
    case glance
    case settings

    var fileName: String {
        switch self {
        case .ask: return "ask.png"
        case .context: return "context.png"
        case .answer: return "answer.png"
        case .glance: return "glance.png"
        case .settings: return "settings.png"
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
        case .answer: return 0.9
        default: return 0.6
        }
    }

    @MainActor
    func seed(cast: PromoCast, state: PromoStageState, layout: PromoLayout) {
        let vm = cast.viewModel
        let chat = cast.chat
        let top = layout.notchTop
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

        case .glance:
            chat.debugSeed(
                messages: PromoContent.finishedTurn(PromoContent.summarize, attachments: [PromoContent.browserTab()], streamedFraction: 0.6),
                isStreaming: true
            )
            vm.debugSeed(presentation: .closed, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
            // Off to the side, where a hand rests after clicking away: never in the empty middle.
            state.pointer = CGPoint(x: layout.screenRect.maxX - 150, y: layout.screenRect.minY + layout.screenRect.height * 0.7)

        case .settings:
            chat.debugSeed(messages: [], isStreaming: false)
            vm.debugSeed(presentation: .closed, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
            state.showsSettings = true
            state.settingsScale = 0.9
            // Settings is Otto's own window, so Otto is the frontmost app in the menu bar.
            state.menuBarApp = "Otto"
            state.isPointerVisible = false
        }
    }
}

// MARK: - Glance loupe

/// A magnified inset of the closed notch for the glance still: the source region is outlined on the
/// notch and shown again below it, 2.4× larger, on a card in Otto's panel style.
enum GlanceLoupe {
    static let magnification: CGFloat = 2.4

    /// The closed notch with its ears and a little menu bar either side, in stage points.
    static func sourceRect(in layout: PromoLayout) -> CGRect {
        let width: CGFloat = 300
        let height: CGFloat = 46
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
            .insetBy(dx: -6, dy: -2)
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
