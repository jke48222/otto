//
//  make_video.swift
//  Otto
//
//  Cuts Otto's promo film, its poster and the README loop from the raw stage footage that
//  scripts/make_media.sh records. Everything is drawn here, so the cut is reproducible and needs no
//  editing app:
//
//  • Footage: the 3072×1728 masters are read with AVAssetReader (BGRA, BT.709) and framed by a
//    virtual camera. Camera moves are keyframed in *source* time, from the takes' own timeline marks
//    (their JSON sidecars), so a re-recorded take re-cuts itself. Moves ease with smootherstep and
//    zoom is interpolated in log space so push-ins feel even. Each frame is shifted at sub-pixel
//    precision at master resolution, then Lanczos-scaled to 1920×1080.
//  • Cadence: the masters are 60 fps screen captures of live SwiftUI, whose own timers (the activity
//    equalizer, shimmer) tick at 30 fps. The film is conformed to a constant 30 fps (every output
//    frame samples one source frame, never a blend).
//  • Collapses: when the notch tucks away, the app fades the panel's content out in 0.14 s while the
//    shape springs shut, so at 30 fps a frame or two would show an empty black slab. The edit instead
//    carries the last clean frame of the open panel down into the notch on the app's own close
//    spring, shrinking the shape and fading its content together (0.42 s), drawn a beat behind the
//    real collapse over the live frames, so it always covers it and nothing is skipped.
//  • Cards and captions: drawn with CoreText in Otto's look (near-black with a fine grain, warm
//    off-white type, the New York serif over SF Pro), then faded and lifted in. Caption titles are
//    66 px and sublines 38 px at 1080p, on a plate at least 960 px wide, so they still read in a
//    phone-width player.
//  • Output: raw BGRA frames are piped to ffmpeg/libx264 (High profile, yuv420p, BT.709, +faststart).
//    `--cues` writes the sound cues (clicks, the notch opening and closing, where the end card
//    starts) with their film times for scripts/make_audio.py. `--gif` writes the README loop's
//    frames (a 1:1 crop of the hero take, 22 fps by default) losslessly for scripts/make_video.sh to quantize.
//
//  Usage (see scripts/make_video.sh):
//
//    swiftc -O -suppress-warnings -o build/make_video scripts/make_video.swift
//    build/make_video --raw <raw dir> --icon docs/media/icon.png \
//        --out /tmp/picture.mp4 --poster docs/media/otto-promo-poster.jpg --cues /tmp/cues.json \
//        --gif /tmp/hero-frames.mkv \
//        [--fps 30] [--crf 20] [--gif-fps 22] [--stills 1.0,5.5 --stills-dir /tmp/qa] [--gif-stills 0,12.5] [--no-video]
//

import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import Foundation

// MARK: - Options

struct Options {
    var raw = ""
    var icon = ""
    var out = ""
    var poster = ""
    var cues = ""
    var gif = ""
    var fps = 30
    var gifFPS = 22
    var crf = 20
    var preset = "slower"
    var ffmpeg = "/opt/homebrew/bin/ffmpeg"
    var stills: [Double] = []
    var gifStills: [Double] = []
    var stillsDir = ""
    var video = true

    static func parse() -> Options {
        var o = Options()
        var args = Array(CommandLine.arguments.dropFirst())
        func value() -> String {
            guard !args.isEmpty else { fail("missing value") }
            return args.removeFirst()
        }
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--raw": o.raw = value()
            case "--icon": o.icon = value()
            case "--out": o.out = value()
            case "--poster": o.poster = value()
            case "--cues": o.cues = value()
            case "--gif": o.gif = value()
            case "--fps": o.fps = Int(value()) ?? 30
            case "--gif-fps": o.gifFPS = Int(value()) ?? 22
            case "--crf": o.crf = Int(value()) ?? 20
            case "--preset": o.preset = value()
            case "--ffmpeg": o.ffmpeg = value()
            case "--stills": o.stills = value().split(separator: ",").compactMap { Double($0) }
            case "--gif-stills": o.gifStills = value().split(separator: ",").compactMap { Double($0) }
            case "--stills-dir": o.stillsDir = value()
            case "--no-video": o.video = false
            default: fail("unknown option \(a)")
            }
        }
        if o.ffmpeg.isEmpty || !FileManager.default.isExecutableFile(atPath: o.ffmpeg) {
            o.ffmpeg = "/usr/local/bin/ffmpeg"
        }
        guard !o.raw.isEmpty, !o.icon.isEmpty else { fail("--raw and --icon are required") }
        return o
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("make_video: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func warn(_ message: String) {
    FileHandle.standardError.write(("make_video: " + message + "\n").data(using: .utf8)!)
}

let options = Options.parse()

// MARK: - Geometry & easing

let outW = 1920, outH = 1080
let outSize = CGSize(width: outW, height: outH)
let outRect = CGRect(origin: .zero, size: outSize)
/// The stage masters: 1536×864 pt at 2×.
let masterW = 3072.0, masterH = 1728.0
let masterRect = CGRect(x: 0, y: 0, width: masterW, height: masterH)
/// Where the notch hangs from, in master pixels (top-left origin): the screen's top edge.
let notchX = 1536.0
let screenTop = 90.0

func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
/// Smootherstep: zero velocity and acceleration at both ends.
func ease(_ x: Double) -> Double { let t = clamp01(x); return t * t * t * (t * (t * 6 - 15) + 10) }
/// Softer ease for fades and lifts (ease-out cubic).
func easeOut(_ x: Double) -> Double { let t = clamp01(x); return 1 - pow(1 - t, 3) }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

// MARK: - Rendering context

// Values pass straight through (no color management): the masters are BT.709 video, the cards are
// drawn in sRGB, and everything is blended in encoded space like a conventional video editor.
let device = MTLCreateSystemDefaultDevice()
let ciContext: CIContext = {
    let opts: [CIContextOption: Any] = [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false,
        .highQualityDownsample: true,
    ]
    if let d = device { return CIContext(mtlDevice: d, options: opts) }
    return CIContext(options: opts)
}()

// MARK: - Palette & type (Otto's look)

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func nsColor(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

enum Ink {
    static let background = srgb(0x0B0B0C)
    static let backgroundLift = srgb(0x1A1A1D)
    static let primary = nsColor(0xECEAE6)
    static let secondary = nsColor(0xB4B2AD)
    /// Fine print: at least #9A9AA0 on the near-black card, so it holds up when scaled down.
    static let fine = nsColor(0xA3A3A8)
    static let finer = nsColor(0x9A9AA0)
    static let buttonText = nsColor(0x161618)
}

func serif(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { return f }
    return NSFont(name: "NewYork-Medium", size: size) ?? base
}

func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

func attributed(_ s: String, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern])
}

// MARK: - Layer drawing

/// Deterministic noise so every run renders identical grain.
struct Noise {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0xFFFF) / 65535.0
    }
}

/// Draws a full-frame 1920×1080 layer (bottom-left origin, like Core Image) and returns it.
/// `grain` adds fine monochrome noise, scaled by coverage so transparent pixels stay clear.
func makeLayer(grain: Double = 0, seed: UInt64 = 1, _ draw: (CGContext) -> Void) -> CIImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: outW * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("CGContext") }
    ctx.interpolationQuality = .high
    ctx.setShouldSmoothFonts(false)
    ctx.setAllowsAntialiasing(true)
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()

    if grain > 0, let data = ctx.data {
        let p = data.bindMemory(to: UInt8.self, capacity: outW * outH * 4)
        var noise = Noise(state: seed)
        for i in 0..<(outW * outH) {
            let a = Double(p[i * 4 + 3])
            if a == 0 { continue }
            // Two uniforms → a soft triangular distribution around zero.
            let n = (noise.next() + noise.next() - 1) * grain * (a / 255)
            for c in 0..<3 {
                let v = Double(p[i * 4 + c]) + n
                p[i * 4 + c] = UInt8(max(0, min(a, v.rounded())))
            }
        }
    }
    guard let cg = ctx.makeImage() else { fail("makeImage") }
    return CIImage(cgImage: cg)
}

/// The shared card backdrop: near-black with a faint warm lift behind the type and a fine grain.
func cardBackground() -> CIImage {
    makeLayer(grain: 5.5, seed: 7) { ctx in
        ctx.setFillColor(Ink.background)
        ctx.fill(outRect)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let lift = CGGradient(
            colorsSpace: space,
            colors: [Ink.backgroundLift, srgb(0x0B0B0C, 0)] as CFArray,
            locations: [0, 1]
        )!
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) * 0.56)
        ctx.scaleBy(x: 1.6, y: 1)
        ctx.drawRadialGradient(lift, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 620, options: [])
        ctx.restoreGState()
        // A whisper of vignette to hold the eye in the middle.
        let vignette = CGGradient(
            colorsSpace: space,
            colors: [srgb(0x000000, 0), srgb(0x000000, 0.45)] as CFArray,
            locations: [0.55, 1]
        )!
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        ctx.scaleBy(x: 1.78, y: 1)
        ctx.drawRadialGradient(vignette, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 640, options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }
}

let iconImage: CGImage = {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: options.icon) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read icon \(options.icon)") }
    return img
}()

/// The icon's top rim: its own silhouette minus the silhouette nudged down by `rim` pixels (a thin
/// crescent along the top edge), filled with light that fades out down the sides.
func iconRim(size: CGFloat, rim: CGFloat) -> CGImage? {
    let px = Int(ceil(size))
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .high
    let box = CGRect(x: 0, y: 0, width: size, height: size)
    ctx.draw(iconImage, in: box)
    ctx.setBlendMode(.destinationOut)
    ctx.draw(iconImage, in: box.offsetBy(dx: 0, dy: -rim))
    ctx.setBlendMode(.sourceIn)
    let light = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [srgb(0xFFFFFF, 0.62), srgb(0xFFFFFF, 0.18), srgb(0xFFFFFF, 0)] as CFArray,
        locations: [0, 0.22, 0.5]
    )!
    ctx.drawLinearGradient(light, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
    return ctx.makeImage()
}

/// The near-black icon, lifted off a near-black ground: a faint pool of light behind it, a soft
/// shadow beneath and a 1 px rim of light along its top edge.
func drawLiftedIcon(_ ctx: CGContext, in rect: CGRect, pool: Bool = true) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    if pool {
        let glow = CGGradient(colorsSpace: space, colors: [srgb(0xFFFFFF, 0.075), srgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        let c = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.04)
        ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: rect.width * 0.95, options: [])
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -rect.height * 0.05), blur: rect.height * 0.16, color: srgb(0x000000, 0.9))
    ctx.draw(iconImage, in: rect)
    ctx.restoreGState()
    if let rim = iconRim(size: rect.width, rim: max(1, rect.width / 128)) {
        ctx.draw(rim, in: CGRect(x: rect.minX, y: rect.minY, width: CGFloat(rim.width), height: CGFloat(rim.height)))
    }
}

/// Draws the icon + "Otto" wordmark lockup centered on `centerY`.
func drawLockup(_ ctx: CGContext, centerY: CGFloat, iconSize: CGFloat, wordSize: CGFloat, gap: CGFloat) {
    let word = attributed("Otto", serif(wordSize, .medium), Ink.primary, kern: -wordSize * 0.012)
    let wsize = word.size()
    let total = iconSize + gap + wsize.width
    let x0 = (CGFloat(outW) - total) / 2
    drawLiftedIcon(ctx, in: CGRect(x: x0, y: centerY - iconSize / 2, width: iconSize, height: iconSize))
    let font = serif(wordSize, .medium)
    // Center the cap height (not the line box) on centerY.
    let baseline = centerY - font.capHeight / 2
    word.draw(at: CGPoint(x: x0 + iconSize + gap, y: baseline + font.descender))
}

func drawCentered(_ s: NSAttributedString, baselineY: CGFloat, font: NSFont) {
    let size = s.size()
    s.draw(at: CGPoint(x: (CGFloat(outW) - size.width) / 2, y: baselineY + font.descender))
}

// MARK: - Caption plates

/// A run in a caption line: plain text or a keycap.
enum Run { case text(String), key(String) }

/// Type and metrics for a caption plate. The film's plates are sized for a phone: a 1080p frame
/// shown 390 px wide still leaves ~13 px titles and ~8 px sublines.
struct PlateStyle {
    var head: NSFont
    var sub: NSFont
    var key: NSFont
    var lineHeight: CGFloat
    var minWidth: CGFloat
    var maxWidth: CGFloat
    var padX: CGFloat
    /// Subline baseline above the plate's bottom edge.
    var padBottom: CGFloat
    /// Last subline baseline to title baseline.
    var titleGap: CGFloat
    /// Space above the title's cap height.
    var padTop: CGFloat
    var iconSize: CGFloat
    var radius: CGFloat

    static let film = PlateStyle(
        head: serif(66, .medium), sub: sans(38, .regular), key: sans(33, .medium),
        lineHeight: 52, minWidth: 960, maxWidth: 1080, padX: 60, padBottom: 44, titleGap: 84,
        padTop: 40, iconSize: 0, radius: 40
    )
    static let poster = PlateStyle(
        head: serif(58, .medium), sub: sans(34, .regular), key: sans(30, .medium),
        lineHeight: 46, minWidth: 0, maxWidth: 1500, padX: 60, padBottom: 42, titleGap: 80,
        padTop: 42, iconSize: 76, radius: 40
    )
}

func runWidth(_ r: Run, _ style: PlateStyle) -> CGFloat {
    switch r {
    case .text(let s): return attributed(s, style.sub, Ink.secondary).size().width
    case .key(let s): return attributed(s, style.key, Ink.primary).size().width + style.key.pointSize * 0.9
    }
}

func lineWidth(_ line: [Run], _ style: PlateStyle) -> CGFloat { line.map { runWidth($0, style) }.reduce(0, +) }

/// Draws one subline of runs centered at `baseline`.
func drawRuns(_ ctx: CGContext, _ runs: [Run], baseline: CGFloat, centerX: CGFloat, style: PlateStyle) {
    var x = centerX - lineWidth(runs, style) / 2
    let k = style.key.pointSize
    for r in runs {
        switch r {
        case .text(let s):
            let a = attributed(s, style.sub, Ink.secondary)
            a.draw(at: CGPoint(x: x, y: baseline + style.sub.descender))
            x += a.size().width
        case .key(let s):
            let a = attributed(s, style.key, Ink.primary)
            let w = a.size().width + k * 0.9
            let cap = CGRect(x: x + k * 0.12, y: baseline - k * 0.36, width: w - k * 0.24, height: k * 1.5)
            ctx.addPath(CGPath(roundedRect: cap, cornerWidth: k * 0.3, cornerHeight: k * 0.3, transform: nil))
            ctx.setFillColor(srgb(0xFFFFFF, 0.1))
            ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: cap.insetBy(dx: 1, dy: 1), cornerWidth: k * 0.3 - 1, cornerHeight: k * 0.3 - 1, transform: nil))
            ctx.setStrokeColor(srgb(0xFFFFFF, 0.2))
            ctx.setLineWidth(2)
            ctx.strokePath()
            a.draw(at: CGPoint(x: cap.midX - a.size().width / 2, y: cap.midY - style.key.capHeight / 2 + style.key.descender - 0.5))
            x += w
        }
    }
}

/// Draws the plate's matte slab (Otto's panel material: near-black, top sheen, hairline rim).
func drawPlate(_ ctx: CGContext, _ plate: CGRect, radius: CGFloat) {
    let path = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 48, color: srgb(0x000000, 0.45))
    ctx.addPath(path)
    ctx.setFillColor(srgb(0x0A0A0B, 0.93))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let sheen = CGGradient(colorsSpace: space, colors: [srgb(0xFFFFFF, 0.05), srgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.midY), options: [])
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: 0.75, dy: 0.75), cornerWidth: radius - 0.75, cornerHeight: radius - 0.75, transform: nil))
    ctx.setStrokeColor(srgb(0xFFFFFF, 0.1))
    ctx.setLineWidth(1.5)
    ctx.strokePath()
}

/// Height of a plate with `lines` sublines.
func plateHeight(lines: Int, _ style: PlateStyle) -> CGFloat {
    style.padBottom + CGFloat(max(0, lines - 1)) * style.lineHeight + style.titleGap + style.head.capHeight + style.padTop
}

let captionPlateBottom: CGFloat = 48

/// A caption plate in the style of Otto's own panel: a serif title over one or two quieter SF Pro
/// lines, bottom-center. Everything (the icon's pool of light included) stays inside the plate.
func captionPlate(_ title: String, _ lines: [[Run]], style: PlateStyle = .film) -> CIImage {
    makeLayer(grain: 4, seed: 11) { ctx in
        let head = attributed(title, style.head, Ink.primary, kern: -0.5)
        let iconGap: CGFloat = style.iconSize > 0 ? 24 : 0
        let headW = head.size().width + style.iconSize + iconGap
        let subW = lines.map { lineWidth($0, style) }.max() ?? 0
        let contentW = max(headW, subW) + style.padX * 2
        if contentW > style.maxWidth + 0.5 {
            warn("caption “\(title)” is \(Int(contentW)) px wide (max \(Int(style.maxWidth)))")
        }
        let plateW = min(style.maxWidth, max(style.minWidth, contentW)).rounded()
        let plate = CGRect(
            x: ((CGFloat(outW) - plateW) / 2).rounded(), y: captionPlateBottom,
            width: plateW, height: plateHeight(lines: lines.count, style).rounded()
        )
        drawPlate(ctx, plate, radius: style.radius)

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: style.radius, cornerHeight: style.radius, transform: nil))
        ctx.clip()
        // Sublines from the bottom up, then the title.
        let firstBaseline = plate.minY + style.padBottom
        for (i, line) in lines.reversed().enumerated() {
            drawRuns(ctx, line, baseline: firstBaseline + CGFloat(i) * style.lineHeight, centerX: plate.midX, style: style)
        }
        let titleBaseline = firstBaseline + CGFloat(max(0, lines.count - 1)) * style.lineHeight + style.titleGap
        let x0 = plate.midX - headW / 2
        if style.iconSize > 0 {
            let capMid = titleBaseline + style.head.capHeight / 2
            drawLiftedIcon(ctx, in: CGRect(x: x0, y: capMid - style.iconSize / 2, width: style.iconSize, height: style.iconSize))
        }
        head.draw(at: CGPoint(x: x0 + style.iconSize + iconGap, y: titleBaseline + style.head.descender))
        ctx.restoreGState()
    }
}

// MARK: - Cards

struct CardItem {
    let image: CIImage
    /// Seconds after the card starts that this item begins to fade and rise in.
    let delay: Double
    let rise: Double
    var duration: Double = 0.9
}

struct Card {
    let start: Double
    let end: Double
    let fadeIn: Double
    let fadeOut: Double
    let background: CIImage
    let items: [CardItem]
}

/// The opener: a quick fade-up of the lockup and the tagline.
func titleCard(start: Double, end: Double) -> Card {
    let lockup = makeLayer { ctx in
        drawLockup(ctx, centerY: 604, iconSize: 164, wordSize: 164, gap: 32)
    }
    let tagline = makeLayer { ctx in
        let f = sans(58, .semibold)
        drawCentered(attributed("The AI assistant that lives in your notch.", f, Ink.primary, kern: -0.7), baselineY: 404, font: f)
    }
    return Card(
        start: start, end: end, fadeIn: 0, fadeOut: 0.45, background: cardBackground(),
        items: [
            CardItem(image: lockup, delay: 0.05, rise: 18, duration: 0.6),
            CardItem(image: tagline, delay: 0.25, rise: 12, duration: 0.6),
        ]
    )
}

func endCard(start: Double, end: Double) -> Card {
    let lockup = makeLayer { ctx in
        drawLockup(ctx, centerY: 734, iconSize: 128, wordSize: 124, gap: 26)
    }
    let tagline = makeLayer { ctx in
        let f = sans(52, .semibold)
        drawCentered(attributed("The AI assistant that lives in your notch.", f, Ink.primary, kern: -0.6), baselineY: 562, font: f)
        let g = sans(32, .regular)
        drawCentered(attributed("Hover the notch, ask anything, get back to work.", g, Ink.secondary), baselineY: 500, font: g)
    }
    let actions = makeLayer { ctx in
        // The repo address on a pill with a drawn right arrow. There is no download yet: the signed
        // build is not out, so the card points at the source and says the signed app is coming.
        let lf = sans(28, .semibold)
        let label = attributed("github.com/jke48222/otto", lf, Ink.buttonText, kern: -0.1)
        let lw = label.size().width
        let arrowW: CGFloat = 20
        let pillW = 34 + lw + 16 + arrowW + 32
        let pillH: CGFloat = 72
        let pill = CGRect(x: (CGFloat(outW) - pillW) / 2, y: 350, width: pillW, height: pillH)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: srgb(0x000000, 0.5))
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil))
        ctx.setFillColor(srgb(0xECEAE6))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil))
        ctx.clip()
        let dome = CGGradient(colorsSpace: space, colors: [srgb(0xF6F5F2), srgb(0xDCDAD5)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(dome, start: CGPoint(x: 0, y: pill.maxY), end: CGPoint(x: 0, y: pill.minY), options: [])
        ctx.restoreGState()
        label.draw(at: CGPoint(x: pill.minX + 34, y: pill.midY - lf.capHeight / 2 + lf.descender))
        // Arrow after the label: a stem and a chevron, stroked in the button ink.
        let ax = pill.minX + 34 + lw + 16
        let ay = pill.midY
        ctx.setStrokeColor(srgb(0x161618))
        ctx.setLineWidth(2.8)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: ax, y: ay)); ctx.addLine(to: CGPoint(x: ax + arrowW, y: ay))
        ctx.move(to: CGPoint(x: ax + arrowW - 8, y: ay + 8)); ctx.addLine(to: CGPoint(x: ax + arrowW, y: ay)); ctx.addLine(to: CGPoint(x: ax + arrowW - 8, y: ay - 8))
        ctx.strokePath()

        let g = sans(30, .medium)
        drawCentered(attributed("Build it from source today. The signed app is coming soon.", g, Ink.primary.withAlphaComponent(0.9), kern: 0.1), baselineY: 276, font: g)
    }
    let fine = makeLayer { ctx in
        let f = sans(24, .regular)
        drawCentered(attributed("Open source (MIT)  ·  macOS 14 or later  ·  Uses the Claude API with your own key", f, Ink.fine, kern: 0.1), baselineY: 132, font: f)
        let g = sans(22, .regular)
        drawCentered(attributed("Otto is an independent project and is not affiliated with Anthropic.", g, Ink.finer, kern: 0.1), baselineY: 90, font: g)
    }
    return Card(
        start: start, end: end, fadeIn: 0.6, fadeOut: 0, background: cardBackground(),
        items: [
            CardItem(image: lockup, delay: 0.2, rise: 20),
            CardItem(image: tagline, delay: 0.45, rise: 14),
            CardItem(image: actions, delay: 0.75, rise: 10),
            CardItem(image: fine, delay: 1.0, rise: 0),
        ]
    )
}

// MARK: - Footage

/// Sequential frame access into one master movie, re-seeking only when asked to jump.
final class FrameSource {
    let url: URL
    let asset: AVURLAsset
    let track: AVAssetTrack
    let duration: Double
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var current: (t: Double, buffer: CVPixelBuffer)?
    private var pending: (t: Double, buffer: CVPixelBuffer)?
    private var ended = false

    init(_ url: URL) {
        self.url = url
        asset = AVURLAsset(url: url)
        guard let t = asset.tracks(withMediaType: .video).first else { fail("no video track in \(url.path)") }
        track = t
        duration = asset.duration.seconds
    }

    private func open(at s: Double) {
        reader?.cancelReading()
        guard let r = try? AVAssetReader(asset: asset) else { fail("reader for \(url.lastPathComponent)") }
        let start = max(0, s - 0.05)
        r.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: asset.duration)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        o.alwaysCopiesSampleData = false
        r.add(o)
        guard r.startReading() else { fail("startReading \(url.lastPathComponent): \(String(describing: r.error))") }
        reader = r
        output = o
        current = nil
        pending = nil
        ended = false
    }

    private func pull() -> (t: Double, buffer: CVPixelBuffer)? {
        guard !ended, let o = output else { return nil }
        while let sample = o.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(sample) {
                return (CMSampleBufferGetPresentationTimeStamp(sample).seconds, pb)
            }
        }
        ended = true
        return nil
    }

    /// The frame showing at source time `s` (the last frame whose timestamp is ≤ s). Past the end,
    /// the final frame holds.
    func frame(at s: Double) -> CVPixelBuffer {
        let s = min(max(0, s), duration)
        if reader == nil { open(at: s) }
        if let c = current, s < c.t - 1e-4 || s > c.t + 1.0 { open(at: s) }
        if current == nil { current = pull() }
        while true {
            if pending == nil { pending = pull() }
            guard let p = pending, p.t <= s + 1e-4 else { break }
            current = p
            pending = nil
        }
        guard let c = current else { fail("no frames in \(url.lastPathComponent) near \(s)") }
        return c.buffer
    }

    /// A still copy of the frame at `s` (safe to keep: it does not pin the reader's buffers).
    func still(at s: Double) -> CGImage {
        let image = CIImage(cvPixelBuffer: frame(at: s))
        guard let cg = ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            fail("cannot copy a frame of \(url.lastPathComponent) at \(s)")
        }
        return cg
    }
}

// MARK: - Takes

let rawDir = URL(fileURLWithPath: options.raw)

/// One recorded take and its timeline (the recorder's sidecar JSON), in source seconds.
struct Take {
    let name: String
    let sceneStart: Double
    let duration: Double
    let marks: [(event: String, t: Double, note: String)]

    init(_ name: String) {
        self.name = name
        let url = rawDir.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = doc["marks"] as? [[String: Any]] else { fail("cannot read \(url.path)") }
        sceneStart = doc["sceneStart"] as? Double ?? 0.6
        duration = doc["duration"] as? Double ?? 0
        marks = list.compactMap { m in
            guard let e = m["event"] as? String, let t = m["t"] as? Double else { return nil }
            return (e, t, m["note"] as? String ?? "")
        }
    }

    /// The `n`th (1-based) mark named `event`, optionally with a note containing `note`.
    func t(_ event: String, _ n: Int = 1, note: String? = nil) -> Double {
        let hits = marks.filter { $0.event == event && (note == nil || $0.note.contains(note!)) }
        guard hits.count >= n else { fail("\(name).json has no mark “\(event)” #\(n)\(note.map { " (\($0))" } ?? "")") }
        return hits[n - 1].t
    }
}

// MARK: - Collapse

/// Pixel access to a still (RGBA8, top-left origin).
struct Pixels {
    let width: Int, height: Int
    let data: [UInt8]
    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        data = buffer
    }
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }
    /// The wallpaper (and the panel's shadow on it) is always tinted; Otto's panel is neutral.
    func isTinted(_ x: Int, _ y: Int) -> Bool {
        let (r, g, b) = rgb(x, y)
        return max(abs(b - r), abs(g - r), abs(b - g)) > 14
    }
    /// Otto's panel: a neutral near-black.
    func isPanel(_ x: Int, _ y: Int) -> Bool {
        let (r, g, b) = rgb(x, y)
        return max(r, g, b) < 58 && abs(b - r) < 9 && abs(g - r) < 9
    }
}

/// The closed states a collapse can land on, sized as the app sizes them. This mirrors
/// `ClosedNotchLayout.make` (Otto/Glance/ClosedGlance.swift) for the stage's 190×32 pt notch
/// (`PromoLayout.video.notchSize`) at 2×: plain is the notch itself; with ears (a phase glyph or the
/// unread dot) it grows `NotchMetrics.activityEarWidth` (34 pt) on each side. No collapse in the edit
/// lands on a hover, drop or listening-pill state, so their growth never applies here. `NotchShape`
/// spends `closedTopRadius` (6 pt) on each side on the flares into the screen edge, so the body the
/// drawn collapse shrinks into (like the open panel it starts from, measured below its flares) is
/// the layout width less 2 × 6 pt.
enum ClosedShape: String {
    case plain, ears

    static let notchPt = CGSize(width: 190, height: 32)
    static let activityEarWidthPt = 34.0
    static let closedTopRadiusPt = 6.0
    static let closedBottomRadiusPt = 12.0

    /// `ClosedNotchLayout.make(...).size`, in master pixels.
    var sizePx: CGSize {
        let w = ClosedShape.notchPt.width + (self == .ears ? 2 * ClosedShape.activityEarWidthPt : 0)
        return CGSize(width: w * 2, height: ClosedShape.notchPt.height * 2)
    }
    /// The shape's body below its top flares, in master pixels.
    var bodyPx: CGSize {
        CGSize(width: sizePx.width - 2 * ClosedShape.closedTopRadiusPt * 2, height: sizePx.height)
    }
}

/// The notch tucking away, as the edit shows it: the last clean frame of the open panel shrinks
/// into the closed notch while its content fades, over the live frames after the real collapse.
struct Collapse {
    /// The open panel (content and all), as a still in master space, cropped to `panel`.
    let panelImage: CIImage
    /// The open panel's shape and the closed notch's, in master pixels (Core Image, bottom-left).
    let panel: CGRect
    let closed: CGRect
    let openRadius: Double = 72
    let closedRadius: Double = ClosedShape.closedBottomRadiusPt * 2
    let fill: CIColor
    let duration: Double
    /// Source time at which the drawn collapse starts (just after `lastOpen`).
    let start: Double

    /// `source`: the take; `lastOpen`: source time of the last frame before the collapse starts;
    /// `shape`: the closed state it lands on. `label` names it in the QA printout.
    init(_ label: String, source: FrameSource, lastOpen: Double, shape: ClosedShape, duration: Double = collapseDuration) {
        start = lastOpen + 1.0 / 120
        let still = source.still(at: lastOpen)
        let px = Pixels(still)
        // The panel's bottom: scanning down a column inside its left edge (past the corner radius,
        // left of the composer's text), the first run of wallpaper (which is always tinted; the
        // panel, its text, chips and composer are neutral).
        func bottom(atX x: Int) -> Int {
            var run = 0
            var y = Int(screenTop) + 80
            while y < px.height {
                run = px.isTinted(x, y) ? run + 1 : 0
                if run >= 6 { return y - run + 1 }
                y += 1
            }
            fail("no open panel found at x \(x), t \(lastOpen)")
        }
        let panelBottom = max(bottom(atX: 1050), bottom(atX: 3072 - 1050))
        // Its left edge, a little above the bottom corner.
        let probeY = panelBottom - 120
        var left = 700
        while left < Int(notchX) && (px.isTinted(left, probeY) || px.isTinted(left + 3, probeY) || px.isTinted(left + 6, probeY)) { left += 1 }
        let halfW = notchX - Double(left)
        let top = screenTop
        panel = CGRect(x: notchX - halfW, y: masterH - Double(panelBottom), width: halfW * 2, height: Double(panelBottom) - top)
        let closedSize = shape.bodyPx
        let closedW = closedSize.width
        closed = CGRect(x: notchX - closedW / 2, y: masterH - top - closedSize.height, width: closedW, height: closedSize.height)
        var sum = (0, 0, 0)
        for dy in 0..<5 { for dx in 0..<5 {
            let c = px.rgb(left + 8 + dx, probeY + dy)
            sum = (sum.0 + c.0, sum.1 + c.1, sum.2 + c.2)
        } }
        fill = CIColor(red: CGFloat(sum.0) / 25 / 255, green: CGFloat(sum.1) / 25 / 255, blue: CGFloat(sum.2) / 25 / 255)
        let full = CIImage(cgImage: still)
        panelImage = full.cropped(to: panel)
        self.duration = duration
        // QA: the real closed shape just after the drawn collapse lands, measured across the notch's
        // middle row from the wallpaper side inward (the menu bar is tinted or light; Otto's shape
        // is near-black and neutral).
        let after = Pixels(source.still(at: start + duration + 0.05))
        let row = Int(screenTop + closedSize.height / 2)
        var edge = Int(notchX) - 700
        var run = 0
        while edge < Int(notchX) {
            run = after.isPanel(edge, row) ? run + 1 : 0
            if run >= 4 { edge -= 3; break }
            edge += 1
        }
        let measured = 2 * (notchX - Double(edge))
        print(String(format: "  collapse %@ at %.2f s: panel %.0f×%.0f px (bottom y %d) → %@, layout %.0f px, body %.0f px, measured %.0f px",
                     label, lastOpen, panel.width, panel.height, panelBottom, shape.rawValue, shape.sizePx.width, closedW, measured))
        if abs(measured - closedW) > 8 {
            warn(String(format: "collapse %@ lands on %.0f px but the live notch measures %.0f px", label, closedW, measured))
        }
    }

    /// The app's close spring (Theme.Motion.close: response 0.34, damping 0.9), as progress 0…1.
    static func spring(_ t: Double) -> Double {
        let omega = 2 * Double.pi / 0.34
        let x = max(0, t) * omega
        return 1 - (1 + x) * exp(-x)
    }

    /// The frame at progress `u` (0…1) over the live `background`. The shape follows the app's own
    /// close spring, a beat behind the real one underneath (measured: the real shape starts moving
    /// 0.02–0.05 s after the close, so it always stays covered); the content
    /// rides along inside it, fading steadily, so no frame shows an empty slab.
    func apply(over background: CIImage, u: Double) -> CIImage {
        let delay = 0.09
        let t = clamp01(u) * duration
        let e = min(1, Collapse.spring(t - delay) / Collapse.spring(duration - delay))
        let w = lerp(panel.width, closed.width, e)
        let h = lerp(panel.height, closed.height, e)
        let rect = CGRect(x: notchX - w / 2, y: masterH - screenTop - h, width: w, height: h)
        let radius = lerp(openRadius, closedRadius, e)
        let contentAlpha = max(0, 1 - pow(clamp01(t / (duration * 0.85)), 1.2))
        let settle = u < 0.78 ? 1.0 : 1 - ease((u - 0.78) / 0.22)

        let content = panelImage
            .transformed(by: CGAffineTransform(translationX: -panel.minX, y: -panel.minY))
            .transformed(by: CGAffineTransform(scaleX: w / panel.width, y: h / panel.height))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        let tint = CIColor(
            red: fill.red * CGFloat(1 - e), green: fill.green * CGFloat(1 - e), blue: fill.blue * CGFloat(1 - e)
        )
        let body = withAlpha(content, contentAlpha).composited(over: CIImage(color: tint).cropped(to: rect))
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + radius)),
            "inputRadius": radius,
            "inputColor": CIColor.white,
        ])!.outputImage!.cropped(to: rect)
        let shape = body.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ]).cropped(to: rect)
        // The open panel's drop shadow, easing away as it closes.
        let shadow = withAlpha(
            CIImage(color: .black).cropped(to: rect.insetBy(dx: 10, dy: 0).offsetBy(dx: 0, dy: -18))
                .applyingGaussianBlur(sigma: 22),
            0.42 * (1 - e)
        )
        return withAlpha(shape.composited(over: shadow), settle).composited(over: background).cropped(to: masterRect)
    }
}

// MARK: - Clips & camera

/// A camera key in source time: zoom (1 = the whole master), crop center x and crop top edge,
/// both in master pixels. Between keys the camera eases (smootherstep); equal neighbouring keys hold.
struct CamKey {
    let t: Double
    let zoom: Double
    let cx: Double
    let top: Double
}

struct Clip {
    let take: Take
    let source: FrameSource
    let outStart: Double
    let outEnd: Double
    let srcStart: Double
    let keys: [CamKey]
    var collapses: [Collapse] = []

    func srcTime(_ t: Double) -> Double { srcStart + (t - outStart) }

    func camera(_ s: Double) -> (zoom: Double, cx: Double, top: Double) {
        guard let first = keys.first, let last = keys.last else { return (1, masterW / 2, 0) }
        if s <= first.t { return (first.zoom, first.cx, first.top) }
        if s >= last.t { return (last.zoom, last.cx, last.top) }
        var i = 0
        while i + 1 < keys.count && keys[i + 1].t < s { i += 1 }
        let a = keys[i], b = keys[i + 1]
        let u = ease((s - a.t) / (b.t - a.t))
        let z = exp(lerp(log(a.zoom), log(b.zoom), u))
        return (z, lerp(a.cx, b.cx, u), lerp(a.top, b.top, u))
    }

    /// The master-space picture at film time `t` (with the collapse, while it runs).
    func master(at t: Double) -> CIImage {
        let s = srcTime(t)
        let image = CIImage(cvPixelBuffer: source.frame(at: s))
        for c in collapses where s >= c.start && s < c.start + c.duration {
            return c.apply(over: image, u: (s - c.start) / c.duration)
        }
        return image
    }
}

/// Frames a master-sized image with the camera (zoom, crop center x, crop top) into 1920×1080.
func frame(_ image: CIImage, zoom: Double, cx: Double, top: Double) -> CIImage {
    let w = masterW / zoom, h = masterH / zoom
    let x = min(max(0, cx - w / 2), masterW - w)
    let yTop = min(max(0, top), masterH - h)
    let yCI = masterH - yTop - h // Core Image's origin is bottom-left.
    let scale = Double(outW) / w
    return image
        .clampedToExtent()
        .transformed(by: CGAffineTransform(translationX: -x, y: -yCI))
        .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
        .cropped(to: outRect)
}

func framed(_ clip: Clip, at t: Double) -> CIImage {
    let cam = clip.camera(clip.srcTime(t))
    return frame(clip.master(at: t), zoom: cam.zoom, cx: cam.cx, top: cam.top)
}

func withAlpha(_ image: CIImage, _ alpha: Double) -> CIImage {
    if alpha >= 0.9999 { return image }
    return image.applyingFilter("CIColorMatrix", parameters: [
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, alpha))),
    ])
}

// MARK: - The edit
//
// Four takes carry the film (see Otto/Debug/PromoStage.swift), joined by hard, matched cuts:
//
//  • story: an establishing beat on the whole display → hover, Otto springs open (the camera holds
//    still for it) and tucks away as the pointer leaves → three files are dragged onto the notch, the
//    split wells show and the right "Ask Otto" well takes them → the open tab is clicked in and the
//    question sent → thinking, a web search with sources, the answer streams → tucked away mid-answer
//    (the orb and writing glyph carry on) → the reply's first line drops under the camera and the
//    pointer rests on it, so the preview holds.
//  • act, cut on that same closed notch and preview: a click opens the answer, a calendar request is
//    typed and sent, the card rises and arms, Add Event is clicked, the row turns into Added with
//    Undo, and a click outside tucks it away.
//  • shelf-voice, cut on the plain closed notch: two files are dragged onto the left "Keep on Shelf"
//    well and land as tiles, the notch folds, the listening pill builds the spoken prompt, and on
//    release a paste-ready update streams under the act turn; a click outside tucks it away.
//  • settings, cut on the plain closed notch again: the window scales in on the Models tab and Otto
//    takes the menu bar. Then the end card.
//
// Every time below is a source time from the takes' own marks, so a re-recorded take re-cuts
// itself. Framing is in master pixels (the notch hangs at x 1536, y 90). Measured framings (the
// card, the voice answer) come from 1.1 renders of the act and shelf-voice takes, noted beside them.

let story = Take("story")
let actTake = Take("act")
let shelfTake = Take("shelf-voice")
let settingsTake = Take("settings")
let storySource = FrameSource(rawDir.appendingPathComponent("story.mov"))
let actSource = FrameSource(rawDir.appendingPathComponent("act.mov"))
let shelfSource = FrameSource(rawDir.appendingPathComponent("shelf-voice.mov"))
let settingsSource = FrameSource(rawDir.appendingPathComponent("settings.mov"))

// Story marks.
let hover1 = story.t("hover"), open1 = story.t("open", 1), close1 = story.t("close", note: "leave")
let dragStart = story.t("drag-start"), openDrag = story.t("open", 2), dropZones = story.t("drop-zones")
let send = story.t("send"), thinking = story.t("thinking")
let close2 = story.t("close", note: "click")
let pointerOnPreview = story.t("pointer-on-preview")
// Act marks.
let actClick = actTake.t("click"), actOpen = actTake.t("open")
let actTypeStart = actTake.t("type-start"), approvalShown = actTake.t("approval-shown")
let actToolDone = actTake.t("tool-done"), actClose = actTake.t("close", note: "click")
// Shelf-voice marks.
let shelfDragStart = shelfTake.t("drag-start"), shelfOpenDrag = shelfTake.t("open", note: "drag")
let shelfDropZones = shelfTake.t("drop-zones"), shelfFold = shelfTake.t("close", note: "fold")
let voiceStart = shelfTake.t("voice-start"), voiceRelease = shelfTake.t("voice-release")
let voiceOpen = shelfTake.t("open", note: "voice"), shelfClose = shelfTake.t("close", note: "click")
// Settings marks.
let settingsOpen = settingsTake.t("settings-open")

/// A collapse is drawn from the last open frame, `collapseLead` before the close, over the live
/// frames of the real one (nothing is skipped: the pointer and the camera carry straight on).
let collapseLead = 0.03
let collapseDuration = 0.42
/// A matched cut lands this long after a collapse has finished drawing.
let cutAfterCollapse = 0.12

// Framings. Wherever the menu bar is in view, the zoom puts the frame's edges in the gaps between
// its labels (1.35, 1.5, 1.745, ≥ 1.91 around the notch), so no word is cut.
let wide = (zoom: 1.0, top: 0.0)
let springHold = 1.5
let settled = 1.745
let dropWide = (zoom: 1.2, cx: 1700.0)
let dropFraming = 2.0
/// The whole open panel above the caption. At 1.35 the frame is 2276 master px wide; centered on
/// the notch its right edge would slice the desktop icons' labels (x 2634–2830 in the masters), so it
/// sits 60 px left: edges at x 338 and 2614 fall between Edit (348) and File (304) on the left and
/// after the Wi-Fi glyph (2604) on the right, so no menu-bar word or icon label is cut.
let streamFraming = (zoom: 1.35, top: 70.0, cx: 1476.0)
let earsFraming = (zoom: 2.5, top: 16.0)
let reopenFraming = (zoom: 1.5, top: 20.0)
/// Settings (settings take at 5.0 s): the first model row, prices included, ends at master y 875
/// and the window's title bar starts at y 205. At 1.745 top 156 the row ends at 784 px, 34 px clear
/// of the plate, the key and Keychain rows read above it, and the menu bar (y 90–154) is wholly out
/// of frame, so no word in it is cut.
let settingsFraming = (zoom: 1.745, top: 156.0)
/// The armed calendar card (act take at approval-armed, 5.95 s): its lower edge sits at master
/// y 1041 and the prompt bubble's top at y 431. At 1.6 the camera maps master pixels 1:1 to film
/// pixels, so top 260 puts the card's edge at 781 px, 37 px above the 818 px plate top, with the
/// prompt, the streamed line and "Waiting for your OK" above it. The menu bar is out of frame.
let cardFraming = (zoom: 1.6, top: 260.0)
/// The wells (shelf-voice at zone-shelf, 3.3 s): labels at master y 595, so at 2.0 they sit at
/// 744 px, clear of the plate, and both wells read as targets. The same push as story's drop.
let wellsFraming = (zoom: dropFraming, top: 0.0)
/// The voice answer (shelf-voice at reply-complete, 10.1 s): its last line ends at master y 870 and
/// the panel at y 1038, so at the stream framing the whole panel (Added row, prompt, update) clears
/// the plate (last line 675 px, panel 817 px) with the menu bar whole.
let voiceAnswerFraming = streamFraming
let pillFraming = earsFraming

/// Film time at which the footage starts (under the title card's fade).
let footageIn = 1.9

func key(_ t: Double, _ zoom: Double, _ top: Double, cx: Double = notchX) -> CamKey {
    CamKey(t: t, zoom: zoom, cx: cx, top: top)
}

// Story: the collapses, then its camera.
let storyCollapses = [
    Collapse("story #1 (leave)", source: FrameSource(rawDir.appendingPathComponent("story.mov")), lastOpen: close1 - collapseLead, shape: .plain),
    Collapse("story #2 (tuck)", source: FrameSource(rawDir.appendingPathComponent("story.mov")), lastOpen: close2 - collapseLead, shape: .ears),
]
let storyKeys = [
    // Establishing: the whole display, bezel corners and menu bar included.
    key(story.sceneStart, wide.zoom, wide.top),
    key(hover1 - 1.2, wide.zoom, wide.top),
    // Push in as the pointer heads for the notch, and be still 0.3 s before it lands.
    key(hover1 - 0.3, springHold, 0),
    // Hold while it springs open and settles, then a gentle push until it tucks away.
    key(open1 + 0.75, springHold, 0),
    key(close1, settled, 0),
    // Widen to take in the files on the desktop and the notch.
    key(close1 + 0.15, settled, 0),
    key(close1 + 0.9, dropWide.zoom, 0, cx: dropWide.cx),
    // Carried up to the notch; push in on the wells as they show, and hold for the chips and tab.
    key(openDrag - 0.15, dropWide.zoom, 0, cx: dropWide.cx),
    key(dropZones + 0.5, dropFraming, 0),
    // Sent: ease out to the streaming framing, which holds the whole panel above the caption.
    key(send + 0.2, dropFraming, 0),
    key(send + 1.0, streamFraming.zoom, streamFraming.top, cx: streamFraming.cx),
    // Tucked away mid-answer: push in on the notch as it closes, and hold through the cut.
    key(close2 + 0.05, streamFraming.zoom, streamFraming.top, cx: streamFraming.cx),
    key(close2 + 0.85, earsFraming.zoom, earsFraming.top),
]
/// Story runs from under the title card to just after the pointer lands on the preview.
let clipA = Clip(take: story, source: storySource, outStart: footageIn,
                 outEnd: footageIn + (pointerOnPreview + 0.1) - (story.sceneStart + 0.05),
                 srcStart: story.sceneStart + 0.05, keys: storyKeys, collapses: storyCollapses)

// Act: picks up on story's last framing (the matched cut), follows the card, then tucks away.
let actCollapses = [
    Collapse("act (tuck)", source: FrameSource(rawDir.appendingPathComponent("act.mov")), lastOpen: actClose - collapseLead, shape: .plain),
]
let actKeys = [
    key(actTake.sceneStart, earsFraming.zoom, earsFraming.top),
    // The click opens the answer: ease out so it is seen whole.
    key(actClick - 0.05, earsFraming.zoom, earsFraming.top),
    key(actOpen + 0.55, reopenFraming.zoom, reopenFraming.top),
    // Typing (no plate): the panel as it grows.
    key(actTypeStart, reopenFraming.zoom, reopenFraming.top),
    key(actTypeStart + 0.7, streamFraming.zoom, streamFraming.top, cx: streamFraming.cx),
    // The card rises: push in on it and hold through the click on Add Event.
    key(approvalShown - 0.1, streamFraming.zoom, streamFraming.top, cx: streamFraming.cx),
    key(approvalShown + 0.6, cardFraming.zoom, cardFraming.top),
    key(actToolDone + 0.1, cardFraming.zoom, cardFraming.top),
    key(actToolDone + 0.9, streamFraming.zoom, streamFraming.top, cx: streamFraming.cx),
    // Tucked away: ease to the closed-notch framing under the collapse.
    key(actClose - collapseLead, streamFraming.zoom, streamFraming.top, cx: streamFraming.cx),
    key(actClose + 0.45, reopenFraming.zoom, reopenFraming.top),
]
let clipB: Clip = {
    let srcStart = actTake.sceneStart + 0.05
    let srcEnd = actCollapses[0].start + collapseDuration + cutAfterCollapse
    return Clip(take: actTake, source: actSource, outStart: clipA.outEnd, outEnd: clipA.outEnd + (srcEnd - srcStart),
                srcStart: srcStart, keys: actKeys, collapses: actCollapses)
}()

// Shelf-voice: the same closed notch, then the Shelf drop, the fold, the pill and the voice answer.
let shelfCollapses = [
    Collapse("shelf-voice #1 (fold)", source: FrameSource(rawDir.appendingPathComponent("shelf-voice.mov")), lastOpen: shelfFold - collapseLead, shape: .plain),
    Collapse("shelf-voice #2 (tuck)", source: FrameSource(rawDir.appendingPathComponent("shelf-voice.mov")), lastOpen: shelfClose - collapseLead, shape: .plain),
]
let shelfKeys = [
    key(shelfTake.sceneStart, reopenFraming.zoom, reopenFraming.top),
    // Widen to take in the two files on the desktop and the notch.
    key(shelfTake.sceneStart + 0.1, reopenFraming.zoom, reopenFraming.top),
    key(shelfDragStart - 0.1, dropWide.zoom, 0, cx: dropWide.cx),
    // Carried up: push in on the wells, and hold through the drop, the tiles and the fold.
    key(shelfOpenDrag - 0.15, dropWide.zoom, 0, cx: dropWide.cx),
    key(shelfDropZones + 0.4, wellsFraming.zoom, wellsFraming.top),
    // The listening pill grows: push in on the notch.
    key(voiceStart - 0.4, wellsFraming.zoom, wellsFraming.top),
    key(voiceStart + 0.2, pillFraming.zoom, pillFraming.top),
    // Released and sent: ease out to the answer as the notch opens.
    key(voiceRelease, pillFraming.zoom, pillFraming.top),
    key(voiceOpen + 0.6, voiceAnswerFraming.zoom, voiceAnswerFraming.top, cx: voiceAnswerFraming.cx),
    // Tucked away: ease to the closed-notch framing under the collapse.
    key(shelfClose - collapseLead, voiceAnswerFraming.zoom, voiceAnswerFraming.top, cx: voiceAnswerFraming.cx),
    key(shelfClose + 0.45, reopenFraming.zoom, reopenFraming.top),
]
let clipC: Clip = {
    let srcStart = shelfTake.sceneStart + 0.05
    let srcEnd = shelfCollapses[1].start + collapseDuration + cutAfterCollapse
    return Clip(take: shelfTake, source: shelfSource, outStart: clipB.outEnd, outEnd: clipB.outEnd + (srcEnd - srcStart),
                srcStart: srcStart, keys: shelfKeys, collapses: shelfCollapses)
}()

// Settings: from the closed-notch framing (the matched cut), pushing in and down with the window as
// it scales in, then holding until the end card.
let settingsSrcIn = settingsTake.sceneStart + 0.05
let settingsOpenFilm = clipC.outEnd + (settingsOpen - settingsSrcIn)
let endCardStart = settingsOpenFilm + 3.9
let endCardLength = 4.2
let totalDuration = ((endCardStart + endCardLength) * 30).rounded() / 30
let clipD = Clip(take: settingsTake, source: settingsSource, outStart: clipC.outEnd, outEnd: endCardStart + 0.7, srcStart: settingsSrcIn, keys: [
    key(settingsOpen - 0.05, reopenFraming.zoom, reopenFraming.top),
    key(settingsOpen + 0.55, settingsFraming.zoom, settingsFraming.top),
])

let clips = [clipA, clipB, clipC, clipD]

/// Maps a take's source time to film time (nil outside that take's clip).
func film(_ take: Take, _ s: Double) -> Double? {
    for clip in clips where clip.take.name == take.name {
        let t = clip.outStart + (s - clip.srcStart)
        if t >= clip.outStart - 1e-6 && t < clip.outEnd { return t }
    }
    return nil
}

func ft(_ take: Take, _ s: Double) -> Double {
    guard let t = film(take, s) else { fail("\(take.name) time \(String(format: "%.3f", s)) is not in the cut") }
    return t
}

/// Film time at which the tuck-away (mid-answer) collapse starts.
let tuck = ft(story, storyCollapses[1].start)

// MARK: - Captions

struct Caption {
    let start: Double
    let end: Double
    let image: CIImage
}

// The brief's exact text (production-brief.md §5). Titles carry no trailing period; each subline is
// one sentence on one line, so every plate's top sits at 818 px.
let captions: [Caption] = [
    Caption(start: ft(story, hover1), end: ft(story, dragStart + 0.3), image: captionPlate("One glance away", [
        [.text("Hover the notch or press "), .key("⌥"), .text(" "), .key("Space"), .text(" from any app.")],
    ])),
    Caption(start: ft(story, dragStart + 0.55), end: ft(story, send - 0.2), image: captionPlate("Knows what you\u{2019}re looking at", [
        [.text("Drop in files, then add the tab you\u{2019}re reading in one click.")],
    ])),
    Caption(start: ft(story, thinking + 0.15), end: tuck - 0.02, image: captionPlate("Answers that stream in", [
        [.text("It searches the web and cites its sources as it writes.")],
    ])),
    Caption(start: tuck + 0.3, end: ft(actTake, actOpen + 0.8), image: captionPlate("Keeps working while you do", [
        [.text("Tuck it away mid-answer, and the notch previews the reply.")],
    ])),
    Caption(start: ft(actTake, approvalShown - 0.3), end: ft(actTake, actClose - 0.2), image: captionPlate("Acts with your OK", [
        [.text("It shows exactly what it will add, then waits for your click.")],
    ])),
    Caption(start: ft(shelfTake, shelfDragStart + 0.2), end: ft(shelfTake, shelfFold - 0.05), image: captionPlate("Keeps files at hand", [
        [.text("Drop files on the left side of the notch to park them.")],
    ])),
    Caption(start: ft(shelfTake, voiceStart + 0.15), end: ft(shelfTake, shelfClose - 0.2), image: captionPlate("Ask out loud", [
        [.text("Hold "), .key("⌥"), .text(" "), .key("Space"), .text(" and talk, then let go to send.")],
    ])),
    Caption(start: settingsOpenFilm + 0.45, end: endCardStart - 0.2, image: captionPlate("Your key, your Mac", [
        [.text("Your key stays in Keychain, with no account or telemetry.")],
    ])),
]

let cards: [Card] = [
    titleCard(start: 0.0, end: footageIn + 0.5),
    endCard(start: endCardStart, end: totalDuration + 1),
]

let fadeFromBlack = 0.3

/// Sound cues in film time (scripts/make_audio.py), from every clip's own marks: the notch opening
/// and closing (a click outside lands 0.18 s before its close), the drag's press and the drop, the
/// tab, the preview and Add Event clicks (0.18 s before the action they trigger), the send (0.18 s
/// early for the button, on the mark for Return and voice), the listening pill and the Settings
/// window. Marks outside a take's clip make no sound.
let cues: [[String: Any]] = {
    var out: [[String: Any]] = []
    for clip in clips {
        let take = clip.take
        func add(_ s: Double, _ kind: String) {
            if let t = film(take, s) { out.append(["t": (t * 1000).rounded() / 1000, "kind": kind]) }
        }
        for m in take.marks {
            switch m.event {
            case "open": add(m.t, "open")
            case "close":
                if m.note == "click" { add(m.t - 0.18, "click") }
                add(m.t, "close")
            case "drag-start": add(m.t - 0.1, "click")
            case "drop": add(m.t, "drop")
            case "tab-attached", "click", "approve": add(m.t - 0.18, "click")
            case "send": add(m.t - (m.note == "button" ? 0.18 : 0), "send")
            case "voice-start": add(m.t, "listen")
            case "settings-open": add(m.t, "window")
            default: break
            }
        }
    }
    return out.sorted { ($0["t"] as! Double) < ($1["t"] as! Double) }
}()

// MARK: - Compositing

let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: outRect)

func compose(_ t: Double) -> CIImage {
    var frame = black

    // Clips abut with hard (matched) cuts: exactly one is ever on screen.
    for clip in clips where t >= clip.outStart && t < clip.outEnd {
        frame = framed(clip, at: t).composited(over: frame)
        break
    }

    for c in captions where t >= c.start && t < c.end {
        let inU = easeOut((t - c.start) / 0.45)
        let outU = ease((c.end - t) / 0.35)
        let a = min(inU, outU)
        let lift = (1 - inU) * 16
        frame = withAlpha(c.image.transformed(by: CGAffineTransform(translationX: 0, y: -lift)), a).composited(over: frame)
    }

    for card in cards where t >= card.start && t < card.end {
        let inA = card.fadeIn > 0 ? ease((t - card.start) / card.fadeIn) : 1
        let outA = card.fadeOut > 0 ? ease((card.end - t) / card.fadeOut) : 1
        let cardA = min(inA, outA)
        var layer = card.background
        for item in card.items {
            let u = easeOut((t - card.start - item.delay) / item.duration)
            if u <= 0 { continue }
            let rise = (1 - u) * item.rise
            layer = withAlpha(item.image.transformed(by: CGAffineTransform(translationX: 0, y: -rise)), u).composited(over: layer)
        }
        frame = withAlpha(layer.cropped(to: outRect), cardA).composited(over: frame)
    }

    if t < fadeFromBlack {
        frame = withAlpha(black, 1 - ease(t / fadeFromBlack)).composited(over: frame)
    }
    return frame.cropped(to: outRect)
}

func writeImage(_ image: CIImage, to path: String, jpeg: Bool, rect: CGRect = outRect) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let cg = ciContext.createCGImage(image, from: rect, format: .RGBA8, colorSpace: space) else { fail("createCGImage") }
    let url = URL(fileURLWithPath: path)
    let type = (jpeg ? "public.jpeg" : "public.png") as CFString
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { fail("cannot write \(path)") }
    let props: [CFString: Any] = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
    CGImageDestinationAddImage(dest, cg, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fail("cannot finalize \(path)") }
}

// MARK: - Poster

/// The poster: the film's act beat under the notch (rendered by `Otto --promo-stills` as
/// poster-stage.png: no pointer, the Friday answer above the calendar request and its armed card),
/// framed so the whole menu bar sits inside the frame (the crop edges fall in the bezel), with the
/// tagline on a plate led by the app icon.
func posterImage() -> CIImage {
    let url = rawDir.appendingPathComponent("poster-stage.png")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fail("missing \(url.path): run scripts/make_media.sh --stills-only (it writes the poster's plate)")
    }
    guard cg.width == Int(masterW), cg.height == Int(masterH) else { fail("poster-stage.png must be 3072×1728") }
    let stage = frame(CIImage(cgImage: cg), zoom: 1.05, cx: notchX, top: 40)
    let plate = captionPlate("The AI assistant that lives in your notch.", [
        [.text("Otto  ·  Hover the notch, ask anything, get back to work.")],
    ], style: .poster)
    return plate.composited(over: stage).cropped(to: outRect)
}

// MARK: - README loop

/// The README loop: a 1:1 crop of the hero take's master around the notch and the full-height panel
/// (no resampling, so the UI text stays as crisp as the app draws it), with the same collapse as the
/// film. It ends once the unread dot's ear has retracted into the notch, and its last frame is the
/// first frame again, so the loop has no seam.
let gifCrop = CGRect(x: 904, y: 40, width: 1280, height: 1000) // top-left origin

func renderGIF() {
    let hero = Take("hero")
    // From just before the pointer glides into the crop (it rests outside it), through the reply
    // preview's real 4 s, to the moment the unread dot's ear has retracted: ~15.6 s, plus the held
    // seam frame. The dot's retract is the loop's reset (the take's own note), not product behavior.
    let gifStart = hero.t("pointer-to-notch") + 0.14
    let heroClose = hero.t("close")
    let gifEndSrc = hero.t("ears-retract") + 0.36

    let heroSource = FrameSource(rawDir.appendingPathComponent("hero.mov"))
    let collapse = Collapse("hero (tuck)", source: FrameSource(rawDir.appendingPathComponent("hero.mov")), lastOpen: heroClose - collapseLead, shape: .ears)
    let liveLength = gifEndSrc - gifStart
    let fps = Double(options.gifFPS)
    let liveFrames = Int((liveLength * fps).rounded())
    let holdFrames = Int((0.2 * fps).rounded())
    let crop = CGRect(x: gifCrop.minX, y: masterH - gifCrop.maxY, width: gifCrop.width, height: gifCrop.height)
    let bounds = CGRect(origin: .zero, size: gifCrop.size)
    func picture(_ g: Double) -> CIImage {
        let s = gifStart + g
        var image = CIImage(cvPixelBuffer: heroSource.frame(at: s))
        if s >= collapse.start && s < collapse.start + collapse.duration {
            image = collapse.apply(over: image, u: (s - collapse.start) / collapse.duration)
        }
        return image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    if !options.gifStills.isEmpty {
        let dir = options.stillsDir.isEmpty ? "." : options.stillsDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for g in options.gifStills {
            writeImage(picture(g), to: "\(dir)/gif_\(String(format: "%06.2f", g)).png", jpeg: false, rect: bounds)
        }
    }
    guard !options.gif.isEmpty else { return }

    let ff = Process()
    ff.executableURL = URL(fileURLWithPath: options.ffmpeg)
    ff.arguments = [
        "-v", "error", "-y",
        "-f", "rawvideo", "-pix_fmt", "bgra", "-video_size", "\(Int(gifCrop.width))x\(Int(gifCrop.height))",
        "-framerate", "\(options.gifFPS)", "-i", "pipe:0",
        "-c:v", "ffv1", "-level", "3", "-pix_fmt", "bgr0", options.gif,
    ]
    let pipe = Pipe()
    ff.standardInput = pipe
    do { try ff.run() } catch { fail("cannot launch ffmpeg: \(error)") }
    let handle = pipe.fileHandleForWriting
    let rowBytes = Int(gifCrop.width) * 4
    var buffer = [UInt8](repeating: 0, count: rowBytes * Int(gifCrop.height))
    var first: Data?
    for i in 0..<liveFrames {
        autoreleasepool {
            buffer.withUnsafeMutableBytes { raw in
                ciContext.render(picture(Double(i) / fps), toBitmap: raw.baseAddress!, rowBytes: rowBytes, bounds: bounds, format: .BGRA8, colorSpace: nil)
            }
            let data = Data(buffer)
            if i == 0 { first = data }
            handle.write(data)
        }
    }
    // The seam: the loop's opening frame, held, so the last frame is the first.
    for _ in 0..<holdFrames { handle.write(first!) }
    try? handle.close()
    ff.waitUntilExit()
    guard ff.terminationStatus == 0 else { fail("ffmpeg (gif frames) exited with \(ff.terminationStatus)") }
    print(String(format: "wrote %@ (%d frames, %.2f s at %d fps)", options.gif, liveFrames + holdFrames, Double(liveFrames + holdFrames) / fps, options.gifFPS))
}

// MARK: - Run

print(String(format: "cut: footage %.2f, tuck %.2f, act %.2f, shelf-voice %.2f, settings %.2f (window %.2f), end card %.2f, total %.2f s",
             footageIn, tuck, clipB.outStart, clipC.outStart, clipD.outStart, settingsOpenFilm, endCardStart, totalDuration))
for (i, clip) in clips.enumerated() {
    print(String(format: "  clip %@ %@: film %.2f–%.2f (%.2f s), source %.2f–%.2f",
                 ["A", "B", "C", "D"][i], clip.take.name, clip.outStart, clip.outEnd, clip.outEnd - clip.outStart,
                 clip.srcStart, clip.srcTime(clip.outEnd)))
    if clip.outEnd - clip.outStart < 1.5 { warn("clip \(clip.take.name) is under 1.5 s") }
}
print(String(format: "  end card %.2f–%.2f (%.2f s)", endCardStart, totalDuration, totalDuration - endCardStart))
for c in captions { print(String(format: "  caption %.2f–%.2f (%.2f s)", c.start, c.end, c.end - c.start)) }

if !options.stills.isEmpty {
    let dir = options.stillsDir.isEmpty ? "." : options.stillsDir
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for t in options.stills {
        writeImage(compose(t), to: "\(dir)/still_\(String(format: "%06.2f", t)).png", jpeg: false)
    }
    print("wrote \(options.stills.count) stills to \(dir)")
}

if !options.poster.isEmpty {
    writeImage(posterImage(), to: options.poster, jpeg: true)
    print("wrote \(options.poster)")
}

if !options.cues.isEmpty {
    let doc: [String: Any] = ["duration": totalDuration, "endCard": endCardStart, "titleEnd": footageIn + 0.5, "cues": cues]
    guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]),
          (try? data.write(to: URL(fileURLWithPath: options.cues))) != nil else { fail("cannot write \(options.cues)") }
    print("wrote \(options.cues)")
}

if !options.gif.isEmpty || !options.gifStills.isEmpty {
    renderGIF()
}

if options.video && !options.out.isEmpty {
    let fps = options.fps
    let frameCount = Int((totalDuration * Double(fps)).rounded())
    let ff = Process()
    ff.executableURL = URL(fileURLWithPath: options.ffmpeg)
    ff.arguments = [
        "-v", "error", "-y",
        "-f", "rawvideo", "-pix_fmt", "bgra", "-video_size", "\(outW)x\(outH)", "-framerate", "\(fps)",
        "-color_range", "pc", "-i", "pipe:0",
        "-vf", "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int+lanczos,format=yuv420p,setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709",
        "-c:v", "libx264", "-profile:v", "high", "-preset", options.preset, "-crf", "\(options.crf)",
        "-tune", "film", "-g", "\(fps * 2)", "-bf", "3",
        "-pix_fmt", "yuv420p", "-color_range", "tv",
        "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
        "-movflags", "+faststart", "-tag:v", "avc1",
        options.out,
    ]
    let pipe = Pipe()
    ff.standardInput = pipe
    do { try ff.run() } catch { fail("cannot launch ffmpeg: \(error)") }
    let handle = pipe.fileHandleForWriting

    let rowBytes = outW * 4
    var buffer = [UInt8](repeating: 0, count: rowBytes * outH)
    let started = Date()
    for i in 0..<frameCount {
        autoreleasepool {
            let t = Double(i) / Double(fps)
            let image = compose(t)
            buffer.withUnsafeMutableBytes { raw in
                ciContext.render(image, toBitmap: raw.baseAddress!, rowBytes: rowBytes, bounds: outRect, format: .BGRA8, colorSpace: nil)
            }
            buffer.withUnsafeBytes { raw in handle.write(Data(raw)) }
        }
        if i % (fps * 5) == 0 {
            let elapsed = Date().timeIntervalSince(started)
            print(String(format: "  frame %d/%d  (%.1fs elapsed)", i, frameCount, elapsed))
        }
    }
    try? handle.close()
    ff.waitUntilExit()
    guard ff.terminationStatus == 0 else { fail("ffmpeg exited with \(ff.terminationStatus)") }
    print("wrote \(options.out) (\(frameCount) frames at \(fps) fps)")
}
