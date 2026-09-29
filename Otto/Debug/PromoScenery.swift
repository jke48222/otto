//
//  PromoScenery.swift
//  Otto
//
//  The set the promo stage films on: an original, procedurally generated dusk wallpaper, the top
//  edge of a stylized MacBook display (aluminium rim, black bezel, camera, a neutral menu bar), a
//  synthetic pointer, dragged file tiles and a mock Settings window. The real `NotchRootView` sits
//  on top of all of it, at the notch.
//

// Debug tooling: compiled only into Debug builds, or into a Release build made with the
// OTTO_TOOLS compilation condition (scripts/make_media.sh does this to record footage).
#if DEBUG || OTTO_TOOLS

import AppKit
import CoreImage
import SwiftUI

// MARK: - Layout

/// Geometry of one stage composition, in points.
struct PromoLayout {
    /// The whole frame.
    var stageSize: CGSize
    /// Backdrop visible above the laptop's lid.
    var topMargin: CGFloat
    /// Backdrop visible left and right of the lid.
    var sideMargin: CGFloat
    /// Black glass between the lid's edge and the screen.
    var bezel: CGFloat = 13
    var rimWidth: CGFloat = 2
    var lidCornerRadius: CGFloat = 26
    var screenCornerRadius: CGFloat = 13
    /// The camera housing, which is also the closed notch and the menu bar's height.
    var notchSize = CGSize(width: 190, height: 32)
    /// Fewer menus and status items, for narrow screens where the open panel would cover them.
    var compactMenuBar = false

    /// The video stage: 16:9, captured at 2× and delivered at 1920×1080, so the UI reads 1.25× larger.
    static let video = PromoLayout(stageSize: CGSize(width: 1536, height: 864), topMargin: 30, sideMargin: 30)
    /// The feature stills: 16:10, rendered at 2.5× (2080×1300). The display is a little narrower
    /// than the video's, so Otto fills more of the frame and its text reads at README width.
    static let still = PromoLayout(stageSize: CGSize(width: 832, height: 520), topMargin: 14, sideMargin: 16, compactMenuBar: true)

    /// The lid, extending past the bottom of the frame.
    var lidRect: CGRect {
        CGRect(x: sideMargin, y: topMargin, width: stageSize.width - sideMargin * 2, height: stageSize.height - topMargin + 60)
    }

    /// The visible part of the screen (inside the bezel, down to the bottom of the frame).
    var screenRect: CGRect {
        let lid = lidRect.insetBy(dx: rimWidth + bezel, dy: 0)
        let top = lidRect.minY + rimWidth + bezel
        return CGRect(x: lid.minX, y: top, width: lid.width, height: stageSize.height - top)
    }

    /// Top-center of the screen: where the notch hangs from.
    var notchTop: CGPoint { CGPoint(x: screenRect.midX, y: screenRect.minY) }

    /// The notch window's frame (the same fixed size the app uses), top-centered on the notch.
    var notchWindowRect: CGRect {
        let size = NotchMetrics.windowSize
        return CGRect(x: notchTop.x - size.width / 2, y: notchTop.y, width: size.width, height: size.height)
    }
}

// MARK: - Wallpaper

/// An original dusk wallpaper: an indigo-to-peach sky, a soft lavender haze behind the notch, two
/// faint aurora ribbons, layered dunes and a fine film grain. Deterministic for a given size.
enum PromoWallpaper {
    private static var cache: [String: CGImage] = [:]

    @MainActor
    static func image(pixelSize: CGSize) -> CGImage? {
        let key = "\(Int(pixelSize.width))x\(Int(pixelSize.height))"
        if let cached = cache[key] { return cached }
        let image = make(width: Int(pixelSize.width), height: Int(pixelSize.height))
        cache[key] = image
        return image
    }

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        )
        // Draw with a top-left origin, like the SwiftUI stage.
        context?.translateBy(x: 0, y: CGFloat(height))
        context?.scaleBy(x: 1, y: -1)
        return context
    }

    private static func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient? {
        CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: stops.map { color($0.0, $0.1) } as CFArray,
            locations: stops.map(\.2)
        )
    }

    private static func make(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let w = CGFloat(width)
        let h = CGFloat(height)

        // 1. Sky.
        guard let sky = context(width: width, height: height),
              let skyGradient = gradient([
                  (0x0F1030, 1, 0.00),
                  (0x1F1C52, 1, 0.26),
                  (0x3B2C73, 1, 0.50),
                  (0x7A4687, 1, 0.70),
                  (0xC76C84, 1, 0.84),
                  (0xF0A27F, 1, 0.94),
                  (0xF7C595, 1, 1.00),
              ]) else { return nil }
        sky.drawLinearGradient(skyGradient, start: .zero, end: CGPoint(x: 0, y: h), options: [.drawsAfterEndLocation])

        // 2. A luminous haze behind the notch, so the black panel reads crisply against it.
        if let haze = gradient([(0xB9A6FF, 0.42, 0), (0x8C7BEA, 0.16, 0.45), (0x6A5ACD, 0, 1)]) {
            sky.drawRadialGradient(
                haze,
                startCenter: CGPoint(x: w * 0.5, y: h * 0.16), startRadius: 0,
                endCenter: CGPoint(x: w * 0.5, y: h * 0.16), endRadius: w * 0.46,
                options: []
            )
        }
        // Warm bloom rising off the horizon.
        if let bloom = gradient([(0xFFB38A, 0.45, 0), (0xF08A7A, 0.12, 0.5), (0xF08A7A, 0, 1)]) {
            sky.drawRadialGradient(
                bloom,
                startCenter: CGPoint(x: w * 0.62, y: h * 1.02), startRadius: 0,
                endCenter: CGPoint(x: w * 0.62, y: h * 1.02), endRadius: w * 0.55,
                options: []
            )
        }
        guard let skyImage = sky.makeImage() else { return nil }

        // 3. Aurora ribbons, drawn crisp and then blurred into haze.
        guard let ribbons = context(width: width, height: height) else { return nil }
        ribbons.setLineCap(.round)
        let ribbonSpecs: [(UInt32, CGFloat, [CGPoint], CGFloat)] = [
            (0x57D6C4, 0.34, [CGPoint(x: -0.05, y: 0.40), CGPoint(x: 0.22, y: 0.14), CGPoint(x: 0.48, y: 0.30), CGPoint(x: 0.78, y: 0.08)], 0.07),
            (0x7FA8FF, 0.30, [CGPoint(x: 0.30, y: 0.46), CGPoint(x: 0.55, y: 0.26), CGPoint(x: 0.80, y: 0.42), CGPoint(x: 1.08, y: 0.18)], 0.06),
            (0xE39BD8, 0.18, [CGPoint(x: -0.08, y: 0.58), CGPoint(x: 0.20, y: 0.46), CGPoint(x: 0.42, y: 0.60), CGPoint(x: 0.66, y: 0.50)], 0.05),
        ]
        for (hex, alpha, points, lineWidth) in ribbonSpecs {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: points[0].x * w, y: points[0].y * h))
            path.addCurve(
                to: CGPoint(x: points[3].x * w, y: points[3].y * h),
                control1: CGPoint(x: points[1].x * w, y: points[1].y * h),
                control2: CGPoint(x: points[2].x * w, y: points[2].y * h)
            )
            ribbons.addPath(path)
            ribbons.setStrokeColor(color(hex, alpha))
            ribbons.setLineWidth(lineWidth * h)
            ribbons.strokePath()
        }
        guard let ribbonImage = ribbons.makeImage() else { return nil }

        // 4. Dunes: a hazy far ridge, a mid ridge and a dark foreground, each softened a little.
        guard let dunes = context(width: width, height: height) else { return nil }
        let ridges: [(CGFloat, [CGFloat], [(UInt32, CGFloat, CGFloat)])] = [
            (0.80, [0.78, 0.74, 0.79, 0.73, 0.77], [(0x9A5C8E, 0.55, 0), (0x6E3F74, 0.75, 1)]),
            (0.87, [0.88, 0.83, 0.86, 0.90, 0.84], [(0x4A2B5E, 0.92, 0), (0x2E1D44, 1, 1)]),
            (0.93, [0.95, 0.92, 0.96, 0.93, 0.97], [(0x1E1530, 1, 0), (0x120C1E, 1, 1)]),
        ]
        for (_, heights, stops) in ridges {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: 0, y: heights[0] * h))
            let segments = heights.count - 1
            for index in 1...segments {
                let x0 = CGFloat(index - 1) / CGFloat(segments) * w
                let x1 = CGFloat(index) / CGFloat(segments) * w
                path.addCurve(
                    to: CGPoint(x: x1, y: heights[index] * h),
                    control1: CGPoint(x: x0 + (x1 - x0) * 0.5, y: heights[index - 1] * h),
                    control2: CGPoint(x: x0 + (x1 - x0) * 0.5, y: heights[index] * h)
                )
            }
            path.addLine(to: CGPoint(x: w, y: h))
            path.closeSubpath()
            dunes.saveGState()
            dunes.addPath(path)
            dunes.clip()
            let top = (heights.min() ?? 0.8) * h
            if let fill = gradient(stops) {
                dunes.drawLinearGradient(fill, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: h), options: [])
            }
            dunes.restoreGState()
        }
        guard let duneImage = dunes.makeImage() else { return nil }

        // 5. Composite, blur the soft layers and add grain.
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        let base = CIImage(cgImage: skyImage)
        let ribbonLayer = CIImage(cgImage: ribbonImage)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(w) * 0.035)
            .cropped(to: extent)
        let duneLayer = CIImage(cgImage: duneImage)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(w) * 0.0022)
            .cropped(to: extent)

        var composite = ribbonLayer.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: base])
        composite = duneLayer.composited(over: composite)

        let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any])
        guard let smooth = ciContext.createCGImage(
            composite.cropped(to: extent),
            from: extent,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        ) else { return nil }
        return addingGrain(to: smooth)
    }

    /// Fine monochrome film grain (±3 levels, mostly ±1): it dithers the gradients (no banding) and
    /// gives the sky a faint texture without reading as noise. Seeded, so every render matches.
    private static func addingGrain(to image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let data = context.data else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var random = PromoRandom(seed: 0x6A1A_5EED)
        var bits: UInt64 = 0
        var available = 0
        for pixel in 0..<(width * height) {
            if available == 0 {
                bits = random.next()
                available = 10
            }
            // Triangular distribution in -3…3 (sum of two 0…3 draws, recentred).
            let delta = Int(bits & 0x3) + Int((bits >> 2) & 0x3) - 3
            bits >>= 6
            available -= 1
            let base = pixel * 4
            pixels[base] = UInt8(clamping: Int(pixels[base]) + delta)
            pixels[base + 1] = UInt8(clamping: Int(pixels[base + 1]) + delta)
            pixels[base + 2] = UInt8(clamping: Int(pixels[base + 2]) + delta)
        }
        return context.makeImage()
    }
}

// MARK: - Display

/// The MacBook's lid seen head-on: backdrop, aluminium rim, black bezel, the screen (wallpaper and
/// menu bar) and the camera. `content` is drawn on the screen, above the wallpaper and menu bar.
struct PromoDisplay<Content: View>: View {
    let layout: PromoLayout
    let wallpaper: CGImage?
    var clock = PromoMenuBar.clock
    /// The frontmost app's name, first in the menu bar.
    var appName = "Studio"
    @ViewBuilder var content: () -> Content

    var body: some View {
        let lid = layout.lidRect
        let screen = layout.screenRect
        ZStack(alignment: .topLeading) {
            PromoBackdrop()

            // Lid: a thin brushed-aluminium rim around black glass.
            RoundedRectangle(cornerRadius: layout.lidCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.rgb(0x9A9CA1), Theme.rgb(0x4A4B4F), Theme.rgb(0x2A2B2E)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: lid.width, height: lid.height)
                .shadow(color: .black.opacity(0.55), radius: 30, x: 0, y: 18)
                .offset(x: lid.minX, y: lid.minY)
            RoundedRectangle(cornerRadius: layout.lidCornerRadius - layout.rimWidth, style: .continuous)
                .fill(Theme.rgb(0x050506))
                .overlay {
                    // Glass: the faintest sheen across the bezel.
                    RoundedRectangle(cornerRadius: layout.lidCornerRadius - layout.rimWidth, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.06), .clear],
                                startPoint: .topLeading,
                                endPoint: UnitPoint(x: 0.35, y: 0.25)
                            )
                        )
                }
                .frame(width: lid.width - layout.rimWidth * 2, height: lid.height - layout.rimWidth * 2)
                .offset(x: lid.minX + layout.rimWidth, y: lid.minY + layout.rimWidth)

            // Screen.
            ZStack(alignment: .topLeading) {
                if let wallpaper {
                    Image(decorative: wallpaper, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: screen.width, height: screen.height)
                } else {
                    Theme.rgb(0x2B2A66)
                }
                PromoMenuBar(height: layout.notchSize.height, clock: clock, appName: appName, compact: layout.compactMenuBar)
                    .frame(width: screen.width)
                content()
                    .frame(width: screen.width, height: screen.height, alignment: .topLeading)
            }
            .frame(width: screen.width, height: screen.height, alignment: .topLeading)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: layout.screenCornerRadius,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: layout.screenCornerRadius,
                    style: .continuous
                )
            )
            .offset(x: screen.minX, y: screen.minY)

            // The camera sits in the housing, just above the notch's top edge.
            PromoCameraLens()
                .position(x: screen.midX, y: screen.minY - layout.bezel * 0.5)
        }
        .frame(width: layout.stageSize.width, height: layout.stageSize.height, alignment: .topLeading)
        .clipped()
    }
}

/// The studio behind the laptop: near-black graphite with a soft pool of light at the top.
struct PromoBackdrop: View {
    var body: some View {
        ZStack {
            Theme.rgb(0x0A0A0C)
            RadialGradient(
                colors: [Theme.rgb(0x2A2A31), Theme.rgb(0x0A0A0C).opacity(0)],
                center: UnitPoint(x: 0.5, y: 0),
                startRadius: 0,
                endRadius: 900
            )
        }
    }
}

/// A tiny dark lens with a hint of blue coating.
struct PromoCameraLens: View {
    var body: some View {
        ZStack {
            Circle().fill(Theme.rgb(0x0B0C10)).frame(width: 7, height: 7)
            Circle()
                .fill(RadialGradient(colors: [Theme.rgb(0x1E2A44), Theme.rgb(0x0B0C10)], center: .center, startRadius: 0, endRadius: 2.5))
                .frame(width: 4, height: 4)
            Circle().fill(Color.white.opacity(0.22)).frame(width: 1.2, height: 1.2).offset(x: -0.8, y: -0.8)
        }
        .accessibilityHidden(true)
    }
}

/// A neutral menu bar: a made-up app's menus on the left, status icons and the clock on the right.
struct PromoMenuBar: View {
    /// One clock for every piece of media: the short form fits beside the open panel in the
    /// narrower stills, so the film uses it too.
    static let clock = "Tue 9:41 AM"

    let height: CGFloat
    let clock: String
    var appName = "Studio"
    var compact = false

    private var menus: [String] { compact ? ["File", "Edit", "View"] : ["File", "Edit", "View", "Window", "Help"] }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: compact ? 18 : 20) {
                Text(appName)
                    .font(.system(size: 13.5, weight: .bold))
                ForEach(menus, id: \.self) { title in
                    Text(title).font(.system(size: 13.5, weight: .regular))
                }
            }
            .padding(.leading, 22)
            Spacer(minLength: 0)
            HStack(spacing: 18) {
                Image(systemName: "battery.75percent")
                    .font(.system(size: 15, weight: .regular))
                Image(systemName: "wifi")
                    .font(.system(size: 13.5, weight: .semibold))
                if !compact {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "switch.2")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(clock)
                    .font(.system(size: 13.5, weight: .medium))
                    .monospacedDigit()
            }
            .padding(.trailing, 20)
        }
        .foregroundStyle(Color.white.opacity(0.94))
        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
        .frame(height: height)
        .background(Color.black.opacity(0.16))
        .accessibilityHidden(true)
    }
}

// MARK: - Pointer

/// The classic arrow pointer: black with a white keyline and a soft shadow.
struct PromoPointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Designed on a 17 × 25 grid, tip at the origin.
        let sx = rect.width / 17
        let sy = rect.height / 25
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(0, 0))
        path.addLine(to: p(0, 20.6))
        path.addLine(to: p(4.9, 15.9))
        path.addLine(to: p(8.2, 23.6))
        path.addLine(to: p(11.4, 22.2))
        path.addLine(to: p(8.2, 14.6))
        path.addLine(to: p(14.6, 14.6))
        path.closeSubpath()
        return path
    }
}

struct PromoPointer: View {
    var isPressed = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            PromoPointerShape()
                .fill(Color.black)
                .overlay {
                    PromoPointerShape()
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                }
                .frame(width: 17, height: 25)
                .shadow(color: .black.opacity(0.35), radius: 2.5, x: 0, y: 1.5)
        }
        // Scale about the tip, so a click doesn't move the hot spot.
        .scaleEffect(isPressed ? 0.86 : 1, anchor: .topLeading)
        .frame(width: 17, height: 25, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

// MARK: - Dragged files

/// A generic document tile (no system icons): a paper sheet with a folded corner and a type label.
struct PromoFileTile: View {
    let badge: String
    let tint: Color
    var width: CGFloat = 46

    var body: some View {
        let height = width * 1.26
        ZStack(alignment: .bottom) {
            PromoPaperShape(fold: width * 0.28)
                .fill(LinearGradient(colors: [Color.white, Theme.rgb(0xE9E9EE)], startPoint: .top, endPoint: .bottom))
                .overlay { PromoPaperShape(fold: width * 0.28).stroke(Color.black.opacity(0.12), lineWidth: 0.6) }
            VStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule().fill(Color.black.opacity(0.1)).frame(width: width * (index == 2 ? 0.34 : 0.52), height: 2)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, height * 0.3)
            Text(badge)
                .font(.system(size: width * 0.19, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint))
                .padding(.bottom, height * 0.12)
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 4)
    }
}

private struct PromoPaperShape: Shape {
    let fold: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 3, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 3))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - 3, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + 3, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - 3), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 3))
        path.addQuadCurve(to: CGPoint(x: rect.minX + 3, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        // The fold itself.
        path.move(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY + fold))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        return path
    }
}

/// The three files as desktop icons (tile + name) in a column centered on the middle one, with the
/// Finder selection look (a soft plate behind each tile, the name on an accent capsule).
struct PromoDesktopFiles: View {
    var isSelected = false

    static let names = ["launch-plan.md", "screenshot.png", "invoice.pdf"]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(PromoDragStack.tiles.enumerated()), id: \.offset) { index, tile in
                VStack(spacing: 5) {
                    PromoFileTile(badge: tile.0, tint: tile.1, width: 44)
                        .padding(7)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(isSelected ? 0.2 : 0))
                        }
                    Text(Self.names[index])
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .shadow(color: .black.opacity(isSelected ? 0 : 0.6), radius: 1.5, y: 0.5)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background {
                            Capsule().fill(Theme.rgb(0x2F6FE4).opacity(isSelected ? 1 : 0))
                        }
                        .fixedSize()
                }
                .frame(width: 92)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The fanned stack of files carried by the pointer, with a count badge.
struct PromoDragStack: View {
    static let tiles: [(String, Color)] = [
        ("MD", Theme.rgb(0x5E6AD2)),
        ("PNG", Theme.rgb(0x2FA37A)),
        ("PDF", Theme.rgb(0xD9534F)),
    ]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                ForEach(Array(Self.tiles.enumerated()), id: \.offset) { index, tile in
                    PromoFileTile(badge: tile.0, tint: tile.1)
                        .rotationEffect(.degrees(Double(index - 1) * 9))
                        .offset(x: CGFloat(index - 1) * 16, y: CGFloat(abs(index - 1)) * 3)
                }
            }
            .frame(width: 96, height: 72)
            Text("\(Self.tiles.count)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(minWidth: 20, minHeight: 20)
                .background(Circle().fill(Theme.rgb(0xFF453A)))
                .offset(x: 6, y: -8)
        }
        .opacity(0.94)
        .accessibilityHidden(true)
    }
}

// MARK: - Settings window

/// A macOS-style window around the real `SettingsView`, for the Settings shot.
struct PromoSettingsWindow: View {
    let settings: AppSettings
    /// The pane showing; the film and settings.png show Models (the key in Keychain, models, prices).
    var tab: SettingsTab = .models
    var contentHeight: CGFloat = 560

    /// The real Settings window's content width.
    static let width = SettingsWindowController.contentWidth
    /// The unified title bar and toolbar: traffic lights and the pane's title, then one item per tab.
    static let chromeHeight: CGFloat = 80
    /// Content height that ends just after the Models pane's Response style group (its helper line
    /// included), before the next group's card. Measured on a 1.1 render of this window (settings.png
    /// seeded at `settingsScale` 0.5 with a 900 pt pane, 1.25 px per pt): the Model group's card ends
    /// 452.8 pt below the toolbar and the Web search card starts at 466.4 pt, so 462 leaves 9 pt of
    /// the form's background under the card and never a sliver of the next one.
    static let throughModelGroup: CGFloat = 462

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            chrome
            SettingsView(settings: settings, tab: tab, services: .inert(settings: settings))
                // No overlay scroller flashing in as the window appears.
                .scrollIndicators(.never)
                // Pin the pane to the top and let the window cut it off.
                .frame(width: Self.width, height: contentHeight, alignment: .top)
                .background(Theme.rgb(0x1F1F21))
                .clipped()
        }
        .frame(width: Self.width)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
        .background {
            shape.fill(Color.black).shadow(color: .black.opacity(0.5), radius: 40, x: 0, y: 24)
        }
        .environment(\.colorScheme, .dark)
    }

    /// Drawn, since the stage hosts the pane in a borderless window: the title is the selected tab's,
    /// and the items come from `SettingsTab` (symbol over title), as the real toolbar shows them.
    private var chrome: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(tab.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                HStack(spacing: 8) {
                    Circle().fill(Theme.rgb(0xFF5F57)).frame(width: 12, height: 12)
                    Circle().fill(Theme.rgb(0x4A4A4D)).frame(width: 12, height: 12)
                    Circle().fill(Theme.rgb(0x4A4A4D)).frame(width: 12, height: 12)
                    Spacer()
                }
                .padding(.leading, 12)
            }
            .frame(height: 28)
            HStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { item in
                    toolbarItem(item)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.chromeHeight - 28, alignment: .top)
        }
        .frame(width: Self.width, height: Self.chromeHeight)
        .background(Theme.rgb(0x2A2A2C))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.5)).frame(height: 1) }
    }

    private func toolbarItem(_ item: SettingsTab) -> some View {
        let isSelected = item == tab
        return VStack(spacing: 3) {
            Image(systemName: item.symbol)
                .font(.system(size: 17, weight: .regular))
                .frame(height: 20)
            Text(item.title)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .foregroundStyle(isSelected ? Theme.rgb(0x0A84FF) : Color.white.opacity(0.62))
        .frame(width: 62, height: 44)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.1))
            }
        }
    }
}

#endif
