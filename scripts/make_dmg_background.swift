#!/usr/bin/env swift
//
//  make_dmg_background.swift
//  Otto
//
//  Renders the background of Otto's installer disk image: the matte near-black, finely grained
//  panel of the notch, a small clay notch hanging from the top edge with the warm Otto orb, a soft
//  "drag to install" arrow between the two icon wells, and a caption. Everything is drawn in code
//  with a seeded grain, so the output is byte-stable between runs.
//
//  Usage: swift scripts/make_dmg_background.swift <output-directory>
//
//  Writes background.png (660×420) and background@2x.png (1320×840) into the directory.
//  scripts/release.sh merges them into a HiDPI background.tiff with tiffutil.
//
//  The layout constants below must match the Finder window that release.sh scripts:
//  window content 660×420 pt, icon size 128, app icon centered at (170, 196), Applications at
//  (490, 196), top-left origin.
//

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Layout (points, top-left origin)

let width: CGFloat = 660
let height: CGFloat = 420
let appIconCenter = CGPoint(x: 170, y: 196)
let applicationsCenter = CGPoint(x: 490, y: 196)
let iconSize: CGFloat = 128

// MARK: - Helpers

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: colorSpace,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha,
        ]
    ) ?? CGColor(gray: 0, alpha: alpha)
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    guard let gradient = CGGradient(colorsSpace: colorSpace, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1)) else {
        fatalError("Could not create gradient")
    }
    return gradient
}

/// Deterministic grayscale noise (xorshift64*), same recipe as scripts/make_icon.swift.
func makeNoiseImage(width: Int, height: Int, seed: UInt64) -> CGImage {
    var state = seed
    var pixels = [UInt8](repeating: 0, count: width * height)
    for index in pixels.indices {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = state &* 2_685_821_657_736_338_717
        pixels[index] = UInt8(truncatingIfNeeded: value >> 56)
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(
              width: width, height: height,
              bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
              space: CGColorSpaceCreateDeviceGray(),
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
          )
    else { fatalError("Could not create the noise image") }
    return image
}

/// Notch silhouette hanging from `frame.maxY` (bottom-left origin): concave flares of `top`,
/// convex bottom corners of `bottom`. Same shape as the icon's notch.
func notchPath(frame: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let minX = frame.minX, maxX = frame.maxX, minY = frame.minY, maxY = frame.maxY
    path.move(to: CGPoint(x: minX, y: maxY))
    path.addArc(tangent1End: CGPoint(x: minX + top, y: maxY), tangent2End: CGPoint(x: minX + top, y: maxY - top), radius: top)
    path.addLine(to: CGPoint(x: minX + top, y: minY + bottom))
    path.addArc(tangent1End: CGPoint(x: minX + top, y: minY), tangent2End: CGPoint(x: minX + top + bottom, y: minY), radius: bottom)
    path.addLine(to: CGPoint(x: maxX - top - bottom, y: minY))
    path.addArc(tangent1End: CGPoint(x: maxX - top, y: minY), tangent2End: CGPoint(x: maxX - top, y: minY + bottom), radius: bottom)
    path.addLine(to: CGPoint(x: maxX - top, y: maxY - top))
    path.addArc(tangent1End: CGPoint(x: maxX - top, y: maxY), tangent2End: CGPoint(x: maxX, y: maxY), radius: top)
    path.closeSubpath()
    return path
}

func strokeWithGradient(_ context: CGContext, path: CGPath, lineWidth: CGFloat, gradient: CGGradient, from start: CGPoint, to end: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.setLineWidth(lineWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(gradient, start: start, end: end, options: [])
    context.restoreGState()
}

/// Draws `text` centered on `center` (bottom-left origin) with the given font and color.
func drawCentered(_ text: String, font: NSFont, color textColor: CGColor, kern: CGFloat = 0, center: CGPoint, in context: CGContext) {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor,
        NSAttributedString.Key(kCTKernAttributeName as String): kern,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
    context.saveGState()
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: center.x - bounds.width / 2 - bounds.minX, y: center.y - bounds.height / 2 - bounds.minY)
    CTLineDraw(line, context)
    context.restoreGState()
}

func systemFont(_ size: CGFloat, weight: NSFont.Weight, design: NSFontDescriptor.SystemDesign = .default) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
    return NSFont(descriptor: descriptor, size: size) ?? base
}

// MARK: - Artwork

func render(scale: CGFloat) -> CGImage {
    let pixelWidth = Int(width * scale), pixelHeight = Int(height * scale)
    guard let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Could not create the bitmap context") }
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    context.setAllowsFontSmoothing(true)
    context.scaleBy(x: scale, y: scale)

    /// Converts a top-left-origin y to the context's bottom-left origin.
    func y(_ top: CGFloat) -> CGFloat { height - top }
    let full = CGRect(x: 0, y: 0, width: width, height: height)
    let midX = width / 2

    // Matte near-black base (Theme.panel) with a whisper of top light, like the open notch.
    context.setFillColor(color(0x060607))
    context.fill(full)
    context.drawLinearGradient(
        gradient([(color(0x111113), 0), (color(0x08080A), 0.55), (color(0x050506), 1)]),
        start: CGPoint(x: midX, y: height), end: CGPoint(x: midX, y: 0), options: []
    )
    context.drawRadialGradient(
        gradient([(color(0xFFFFFF, 0.05), 0), (color(0xFFFFFF, 0), 1)]),
        startCenter: CGPoint(x: midX, y: y(0)), startRadius: 0,
        endCenter: CGPoint(x: midX, y: y(0)), endRadius: 360, options: []
    )

    // Two soft wells the icons rest in: a faint lit disc with a darker core.
    for center in [appIconCenter, applicationsCenter] {
        let c = CGPoint(x: center.x, y: y(center.y + 6))
        context.drawRadialGradient(
            gradient([(color(0xFFFFFF, 0.035), 0), (color(0xFFFFFF, 0.018), 0.55), (color(0xFFFFFF, 0), 1)]),
            startCenter: c, startRadius: 0, endCenter: c, endRadius: iconSize * 0.95, options: []
        )
    }

    // The notch, hanging from the top edge.
    let notchFrame = CGRect(x: midX - 96, y: y(40), width: 192, height: 40)
    let notch = notchPath(frame: notchFrame, top: 8, bottom: 16)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: color(0x000000, 0.8))
    context.addPath(notch)
    context.setFillColor(color(0x1A1A1D))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(notch)
    context.clip()
    context.drawLinearGradient(
        gradient([(color(0x232326), 0), (color(0x17171A), 1)]),
        start: CGPoint(x: midX, y: notchFrame.maxY), end: CGPoint(x: midX, y: notchFrame.minY), options: []
    )
    context.restoreGState()
    strokeWithGradient(
        context, path: notch, lineWidth: 1,
        gradient: gradient([(color(0xFFFFFF, 0.0), 0), (color(0xFFFFFF, 0.09), 0.7), (color(0xFFFFFF, 0.03), 1)]),
        from: CGPoint(x: midX, y: notchFrame.maxY), to: CGPoint(x: midX, y: notchFrame.minY)
    )

    // The orb's warm glow spilling out under the notch.
    let orbCenter = CGPoint(x: midX, y: y(21))
    let orbRadius: CGFloat = 6
    context.drawRadialGradient(
        gradient([(color(0xF4F1EA, 0.20), 0), (color(0xF4F1EA, 0.05), 0.4), (color(0xF4F1EA, 0), 1)]),
        startCenter: orbCenter, startRadius: 0, endCenter: orbCenter, endRadius: 70, options: []
    )
    // The orb itself: a warm white sphere lit from the upper left.
    let orbRect = CGRect(x: orbCenter.x - orbRadius, y: orbCenter.y - orbRadius, width: orbRadius * 2, height: orbRadius * 2)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: color(0x000000, 0.6))
    context.addEllipse(in: orbRect)
    context.setFillColor(color(0x8C8A86))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addEllipse(in: orbRect)
    context.clip()
    let highlight = CGPoint(x: orbCenter.x - orbRadius * 0.35, y: orbCenter.y + orbRadius * 0.4)
    context.drawRadialGradient(
        gradient([(color(0xFFFDF8), 0), (color(0xF4F1EA), 0.35), (color(0xC9C6BF), 0.75), (color(0x8C8A86), 1)]),
        startCenter: highlight, startRadius: 0, endCenter: orbCenter, endRadius: orbRadius * 1.08,
        options: [.drawsAfterEndLocation]
    )
    context.restoreGState()

    // Wordmark + subline under the notch.
    drawCentered("Otto", font: systemFont(26, weight: .medium, design: .serif), color: color(0xEDEDED),
                 center: CGPoint(x: midX, y: y(74)), in: context)
    drawCentered("The AI assistant that lives in your notch.", font: systemFont(12, weight: .regular),
                 color: color(0xA3A3A8), center: CGPoint(x: midX, y: y(100)), in: context)

    // "Drag to install" arrow: a gently arched dashed stroke with a rounded chevron head.
    let arrowStart = CGPoint(x: appIconCenter.x + 88, y: y(appIconCenter.y))
    let arrowEnd = CGPoint(x: applicationsCenter.x - 90, y: y(applicationsCenter.y))
    let arc = CGMutablePath()
    arc.move(to: arrowStart)
    arc.addQuadCurve(to: arrowEnd, control: CGPoint(x: midX, y: arrowStart.y + 22))
    context.saveGState()
    context.addPath(arc)
    context.setLineWidth(2)
    context.setLineCap(.round)
    context.setLineDash(phase: 0, lengths: [0.1, 7])
    context.setStrokeColor(color(0xF4F1EA, 0.42))
    context.strokePath()
    context.restoreGState()
    // Chevron aligned with the curve's end tangent (control → end).
    let control = CGPoint(x: midX, y: arrowStart.y + 22)
    let angle = atan2(arrowEnd.y - control.y, arrowEnd.x - control.x)
    let head = CGMutablePath()
    let wing: CGFloat = 9, spread: CGFloat = .pi / 4.2
    let tip = CGPoint(x: arrowEnd.x + 3 * cos(angle), y: arrowEnd.y + 3 * sin(angle))
    head.move(to: CGPoint(x: tip.x - wing * cos(angle - spread), y: tip.y - wing * sin(angle - spread)))
    head.addLine(to: tip)
    head.addLine(to: CGPoint(x: tip.x - wing * cos(angle + spread), y: tip.y - wing * sin(angle + spread)))
    context.saveGState()
    context.addPath(head)
    context.setLineWidth(2)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(color(0xF4F1EA, 0.55))
    context.strokePath()
    context.restoreGState()

    // Label plates. Finder draws icon labels in black (light mode) or white (dark mode) no matter
    // what the background is, so each label sits on a mid-tone clay pill (relative luminance ≈ 0.18,
    // ≥ 4.5:1 against both black and white text).
    for center in [appIconCenter, applicationsCenter] {
        let plate = CGRect(x: center.x - 56, y: y(center.y + iconSize / 2 + 30), width: 112, height: 22)
        let path = CGPath(roundedRect: plate, cornerWidth: 11, cornerHeight: 11, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 4, color: color(0x000000, 0.6))
        context.addPath(path)
        context.setFillColor(color(0x767471))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(
            gradient([(color(0x7E7C79), 0), (color(0x72706D), 1)]),
            start: CGPoint(x: plate.midX, y: plate.maxY), end: CGPoint(x: plate.midX, y: plate.minY), options: []
        )
        context.restoreGState()
        strokeWithGradient(
            context, path: path, lineWidth: 1,
            gradient: gradient([(color(0xFFFFFF, 0.22), 0), (color(0xFFFFFF, 0.02), 1)]),
            from: CGPoint(x: plate.midX, y: plate.maxY), to: CGPoint(x: plate.midX, y: plate.minY)
        )
    }

    // Caption.
    drawCentered("Drag Otto into Applications to install", font: systemFont(12.5, weight: .medium),
                 color: color(0xB4B4B8), center: CGPoint(x: midX, y: y(352)), in: context)
    drawCentered("Then open it from Applications and hover the notch.", font: systemFont(11, weight: .regular),
                 color: color(0x87878C), center: CGPoint(x: midX, y: y(372)), in: context)

    // Fine foam grain over everything.
    context.saveGState()
    context.setBlendMode(.screen)
    context.setAlpha(0.05)
    context.draw(makeNoiseImage(width: pixelWidth, height: pixelHeight, seed: 0x4F54_544F_444D_47),
                 in: full)
    context.restoreGState()

    guard let image = context.makeImage() else { fatalError("Could not render the background") }
    return image
}

func writePNG(_ image: CGImage, to url: URL, dpi: CGFloat) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make_dmg_background.swift <output-directory>\n".utf8))
    exit(2)
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
do {
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    try writePNG(render(scale: 1), to: outputURL.appendingPathComponent("background.png"), dpi: 72)
    try writePNG(render(scale: 2), to: outputURL.appendingPathComponent("background@2x.png"), dpi: 144)
    print("wrote \(outputURL.path)/background.png and background@2x.png")
} catch {
    FileHandle.standardError.write(Data("make_dmg_background: \(error.localizedDescription)\n".utf8))
    exit(1)
}
