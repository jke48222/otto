//
//  SnapshotRenderer.swift
//  Otto
//
//  Renders PNGs of the real notch UI in seeded states (`Otto --snapshot <dir>`), for docs and
//  visual review. Views are hosted in an off-screen window and captured at 2×.
//

// Debug tooling: compiled only into Debug builds, or into a Release build made with the
// OTTO_TOOLS compilation condition (scripts/make_media.sh does this to record footage).
#if DEBUG || OTTO_TOOLS

import AppKit
import os
import SwiftUI

enum SnapshotRenderer {
    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Snapshots")
    private static let canvasSize = CGSize(width: 760, height: 600)
    private static let settingsSize = CGSize(width: 480, height: 560)
    private static let scale: CGFloat = 2
    private static let defaultsSuite = "otto.snapshots"

    @MainActor
    static func renderAll(to directory: URL) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            report(error: "Couldn't create \(directory.path): \(error.localizedDescription)")
            return
        }
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            report(error: "Couldn't open the \(defaultsSuite) defaults suite.")
            return
        }
        // Start from defaults every time so snapshots are reproducible.
        defaults.removePersistentDomain(forName: defaultsSuite)
        let settings = AppSettings(defaults: defaults)

        for scenario in Scenario.allCases {
            let chat = ChatSession(settings: settings, makeClient: { MockLLMClient(latencyScale: 0) })
            let viewModel = NotchViewModel(settings: settings, chat: chat)
            viewModel.closedNotchSize = CGSize(width: 190, height: 32)
            viewModel.hasPhysicalNotch = true
            scenario.seed(viewModel: viewModel, chat: chat)

            await render(
                SnapshotCanvas(viewModel: viewModel, size: canvasSize),
                size: canvasSize,
                background: .black,
                expectsNotchAtTop: true,
                to: directory.appendingPathComponent(scenario.fileName)
            )
            // Leave nothing running (e.g. a demo stream) between scenarios.
            chat.reset()
        }

        await render(
            SettingsView(settings: settings),
            size: settingsSize,
            background: .windowBackgroundColor,
            expectsNotchAtTop: false,
            to: directory.appendingPathComponent("settings.png")
        )

        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    // MARK: - Rendering

    @MainActor
    private static func render<Content: View>(
        _ content: Content,
        size: CGSize,
        background: NSColor,
        expectsNotchAtTop: Bool,
        to url: URL
    ) async {
        let root = content
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            .transaction { $0.disablesAnimations = true }

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = background
        window.contentView = hostingView
        window.orderFrontRegardless()

        // Let SwiftUI lay out, measure (preference/geometry round-trips) and settle.
        try? await Task.sleep(for: .milliseconds(400))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        var image = captureCachedDisplay(of: hostingView, size: size)
        if let captured = image, !isUsable(captured, expectsNotchAtTop: expectsNotchAtTop) {
            logger.notice("Cached display of \(url.lastPathComponent, privacy: .public) looked blank; using ImageRenderer.")
            image = nil
        }
        if image == nil {
            image = renderWithImageRenderer(root, size: size)
        }

        window.orderOut(nil)
        window.contentView = nil
        window.close()

        guard let image else {
            report(error: "Couldn't render \(url.lastPathComponent).")
            return
        }
        write(image, size: size, to: url)
    }

    @MainActor
    private static func captureCachedDisplay(of view: NSView, size: CGSize) -> CGImage? {
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
        // Point size < pixel size ⇒ the view draws at 2×.
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    @MainActor
    private static func renderWithImageRenderer<Content: View>(_ content: Content, size: CGSize) -> CGImage? {
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = scale
        return renderer.cgImage
    }

    /// Rejects captures that are fully transparent or a single flat color, and — for notch
    /// canvases — captures where the dark notch at the top centre is missing.
    private static func isUsable(_ image: CGImage, expectsNotchAtTop: Bool) -> Bool {
        let width = 64
        let height = 50
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = context.data else { return false }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var minLuma = Int.max
        var maxLuma = Int.min
        var maxAlpha: UInt8 = 0
        for index in 0..<(width * height) {
            let base = index * 4
            let luma = Int(pixels[base]) + Int(pixels[base + 1]) + Int(pixels[base + 2])
            minLuma = min(minLuma, luma)
            maxLuma = max(maxLuma, luma)
            maxAlpha = max(maxAlpha, pixels[base + 3])
        }
        guard maxAlpha > 0, maxLuma - minLuma > 12 else { return false }

        if expectsNotchAtTop {
            // Bitmap-context memory is stored top row first, so row 0 is the top edge of the image.
            let base = (width / 2) * 4
            let luma = Int(pixels[base]) + Int(pixels[base + 1]) + Int(pixels[base + 2])
            return luma < 90 && pixels[base + 3] > 200
        }
        return true
    }

    private static func write(_ image: CGImage, size: CGSize, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = size
        // Convert (not retag) to sRGB: ImageRenderer output may be in an extended/linear space.
        let converted = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
        guard let data = converted.representation(using: .png, properties: [:]) else {
            report(error: "Couldn't encode \(url.lastPathComponent) as PNG.")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            logger.info("Wrote \(url.path, privacy: .public)")
            print(url.path)
        } catch {
            report(error: "Couldn't write \(url.path): \(error.localizedDescription)")
        }
    }

    private static func report(error message: String) {
        logger.error("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("snapshot error: \(message)\n".utf8))
    }
}

// MARK: - Scenarios

private enum Scenario: CaseIterable {
    case closed
    case closedActivity
    case openEmpty
    case openChips
    case conversation
    case streaming

    var fileName: String {
        switch self {
        case .closed: return "closed.png"
        case .closedActivity: return "closed-activity.png"
        case .openEmpty: return "open-empty.png"
        case .openChips: return "open-chips.png"
        case .conversation: return "conversation.png"
        case .streaming: return "streaming.png"
        }
    }

    @MainActor
    func seed(viewModel: NotchViewModel, chat: ChatSession) {
        switch self {
        case .closed:
            chat.debugSeed(messages: [], isStreaming: false)
            viewModel.debugSeed(presentation: .closed, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)

        case .closedActivity:
            chat.debugSeed(messages: SnapshotFixtures.streamingTurn(), isStreaming: true)
            viewModel.debugSeed(presentation: .closed, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)

        case .openEmpty:
            chat.debugSeed(messages: [], isStreaming: false)
            viewModel.debugSeed(presentation: .open, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)

        case .openChips:
            chat.debugSeed(messages: [], isStreaming: false)
            viewModel.debugSeed(
                presentation: .open,
                composerText: "Hi otto",
                attachments: SnapshotFixtures.referenceChips(),
                suggestedTab: nil,
                hasUnreadReply: false
            )

        case .conversation:
            chat.debugSeed(messages: SnapshotFixtures.conversation(), isStreaming: false)
            viewModel.debugSeed(presentation: .open, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)

        case .streaming:
            chat.debugSeed(messages: SnapshotFixtures.streamingTurn(), isStreaming: true)
            viewModel.debugSeed(presentation: .open, composerText: "", attachments: [], suggestedTab: nil, hasUnreadReply: false)
        }
    }
}

// MARK: - Fixtures

private enum SnapshotFixtures {
    /// The four sample chips shown in the README hero shot.
    static func referenceChips() -> [Attachment] {
        var chips: [Attachment] = []
        if let url = URL(string: "https://techcrunch.com/") {
            chips.append(
                Attachment(
                    kind: .webPage,
                    displayName: "TechCrunch",
                    badge: "WEB",
                    sourceURL: url,
                    appBundleID: "com.google.Chrome",
                    payload: .webPage(title: "TechCrunch", url: url),
                    byteCount: 0
                )
            )
        }
        chips.append(
            Attachment(
                kind: .image,
                displayName: "AI_Man_cea775f8.png",
                badge: "PNG",
                sourceURL: URL(fileURLWithPath: "/Users/Shared/AI_Man_cea775f8.png"),
                thumbnail: portraitThumbnail(),
                payload: .image(mediaType: "image/png", base64: ""),
                byteCount: 1_284_096
            )
        )
        chips.append(
            Attachment(
                kind: .pdf,
                displayName: "PDFcea775f5d9.pdf",
                badge: "PDF",
                sourceURL: URL(fileURLWithPath: "/Users/Shared/PDFcea775f5d9.pdf"),
                payload: .pdf(base64: ""),
                byteCount: 842_112
            )
        )
        chips.append(
            Attachment(
                kind: .text,
                displayName: "cat-meme.txt",
                badge: "TXT",
                sourceURL: URL(fileURLWithPath: "/Users/Shared/cat-meme.txt"),
                payload: .text("I can has cheezburger?"),
                byteCount: 22
            )
        )
        return chips
    }

    static func conversation() -> [ChatMessage] {
        let notes = Attachment(
            kind: .text,
            displayName: "concurrency-notes.md",
            badge: "MD",
            sourceURL: URL(fileURLWithPath: "/Users/Shared/concurrency-notes.md"),
            payload: .text("Swift 6.2 notes"),
            byteCount: 2_048
        )
        let user = ChatMessage(
            role: .user,
            text: "What changed in Swift concurrency this year? Keep it short.",
            attachments: [notes],
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        let answer = """
        **Swift 6.2** made concurrency far more approachable:

        - **Main actor by default** for app targets — most UI code needs no annotations.
        - `@concurrent` opts heavy work into the background *explicitly*:

        ```swift
        @concurrent func thumbnails(for urls: [URL]) async -> [NSImage]
        ```
        """
        let assistant = ChatMessage(
            role: .assistant,
            text: answer,
            thinking: "The user wants a short summary of this year's concurrency changes, checked against their notes. I'll search for the Swift 6.2 release details and keep the answer tight.",
            activities: [
                ToolActivity(id: "srvtoolu_snapshot_1", kind: .webSearch, label: "Searching “Swift 6.2 concurrency changes”", isDone: true),
            ],
            sources: sources([
                ("Swift 6.2 Released", "https://www.swift.org/blog/swift-6.2-released/"),
                ("Adopting strict concurrency", "https://developer.apple.com/documentation/swift/adoptingswift6"),
                ("Approachable Concurrency", "https://forums.swift.org/t/approachable-concurrency/"),
            ]),
            state: .complete,
            model: ModelOption.opus5.rawValue,
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_010)
        )
        return [user, assistant]
    }

    static func streamingTurn() -> [ChatMessage] {
        let user = ChatMessage(
            role: .user,
            text: "What's new for SwiftUI in the latest macOS release notes?",
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_100)
        )
        let assistant = ChatMessage(
            role: .assistant,
            text: "I found Apple's release notes. The highlights so far:\n\n- **Layout** — `Grid` and custom layouts now animate size changes more smoothly\n- **Text** — ",
            thinking: "Look up the current release notes, then summarise the SwiftUI section.",
            activities: [
                ToolActivity(id: "srvtoolu_snapshot_2", kind: .webSearch, label: "Searching “macOS release notes SwiftUI”", isDone: true),
                ToolActivity(id: "srvtoolu_snapshot_3", kind: .webFetch, label: "Reading developer.apple.com", isDone: false),
            ],
            sources: sources([
                ("macOS Release Notes", "https://developer.apple.com/documentation/macos-release-notes"),
            ]),
            state: .streaming,
            model: ModelOption.opus5.rawValue,
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_110)
        )
        return [user, assistant]
    }

    private static func sources(_ pairs: [(String, String)]) -> [SourceLink] {
        pairs.compactMap { title, address in
            URL(string: address).map { SourceLink(title: title, url: $0) }
        }
    }

    /// A small painted stand-in for the reference's portrait thumbnail.
    private static func portraitThumbnail() -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let backdrop = NSGradient(
                colors: [
                    NSColor(srgbRed: 0.93, green: 0.72, blue: 0.52, alpha: 1),
                    NSColor(srgbRed: 0.42, green: 0.30, blue: 0.36, alpha: 1),
                ]
            )
            backdrop?.draw(in: rect, angle: -70)

            NSColor(srgbRed: 0.16, green: 0.13, blue: 0.14, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 8, y: -22, width: 48, height: 44)).fill()
            NSColor(srgbRed: 0.86, green: 0.66, blue: 0.53, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 21, y: 22, width: 22, height: 26)).fill()
            NSColor(srgbRed: 0.2, green: 0.15, blue: 0.13, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 19, y: 37, width: 26, height: 15)).fill()
            return true
        }
    }
}

// MARK: - Canvas

/// A wallpaper-like backdrop with a translucent menu bar, with the real notch drawn on top.
private struct SnapshotCanvas: View {
    let viewModel: NotchViewModel
    let size: CGSize

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                stops: [
                    .init(color: Theme.rgb(0x6FA8DC), location: 0),
                    .init(color: Theme.rgb(0xA9CBE6), location: 0.42),
                    .init(color: Theme.rgb(0x8DB07A), location: 0.7),
                    .init(color: Theme.rgb(0x4F7A45), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Soft clouds and a hill line, blurred so the backdrop reads as a photo out of focus.
            Canvas { context, canvasSize in
                context.addFilter(.blur(radius: 18))
                let cloud = Color.white.opacity(0.55)
                for (x, y, w, h) in [(0.12, 0.2, 0.22, 0.07), (0.62, 0.14, 0.26, 0.08), (0.84, 0.34, 0.18, 0.06)] {
                    let rect = CGRect(
                        x: canvasSize.width * x,
                        y: canvasSize.height * y,
                        width: canvasSize.width * w,
                        height: canvasSize.height * h
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(cloud))
                }
                var hills = Path()
                hills.move(to: CGPoint(x: 0, y: canvasSize.height * 0.72))
                hills.addCurve(
                    to: CGPoint(x: canvasSize.width, y: canvasSize.height * 0.66),
                    control1: CGPoint(x: canvasSize.width * 0.3, y: canvasSize.height * 0.58),
                    control2: CGPoint(x: canvasSize.width * 0.65, y: canvasSize.height * 0.78)
                )
                hills.addLine(to: CGPoint(x: canvasSize.width, y: canvasSize.height))
                hills.addLine(to: CGPoint(x: 0, y: canvasSize.height))
                hills.closeSubpath()
                context.fill(hills, with: .color(Theme.rgb(0x3E6B3A).opacity(0.55)))
            }

            Rectangle()
                .fill(Color.white.opacity(0.16))
                .frame(height: viewModel.closedNotchSize.height)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5)
                }

            NotchRootView(viewModel: viewModel)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

#endif
