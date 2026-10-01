#!/usr/bin/env swift
//
//  make_icon.swift
//  Otto
//
//  Renders Otto's app icon — a near-black squircle with a fine grain, a soft charcoal notch
//  silhouette hanging from the top edge and a small warm-white orb — at 1024 px, then writes every
//  macOS AppIcon size plus Contents.json. Also renders the iPhone app's icon: the same felt, full bleed
//  (iOS rounds the corners itself), with a Dynamic Island pill in place of the notch, as one 1024 px PNG.
//
//  Usage: swift scripts/make_icon.swift [path/to/Assets.xcassets] [path/to/iOS/Assets.xcassets]
//         (default to Otto/Assets.xcassets and OttoiOS/Assets.xcassets next to this script's parent directory)
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Paths

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let repositoryRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let catalogURL: URL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    : repositoryRoot.appendingPathComponent("Otto/Assets.xcassets")
let iconSetURL = catalogURL.appendingPathComponent("AppIcon.appiconset")
let iOSCatalogURL: URL = CommandLine.arguments.count > 2
    ? URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    : repositoryRoot.appendingPathComponent("OttoiOS/Assets.xcassets")
let iOSIconSetURL = iOSCatalogURL.appendingPathComponent("AppIcon.appiconset")

// MARK: - Drawing helpers

let canvas: CGFloat = 1024
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
    guard let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: stops.map(\.0) as CFArray,
        locations: stops.map(\.1)
    ) else {
        fatalError("Could not create gradient")
    }
    return gradient
}

func makeContext(size: Int) -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a \(size)×\(size) bitmap context")
    }
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    return context
}

/// Superellipse (|x|^n + |y|^n = 1) — a close match for the macOS icon squircle.
func squirclePath(center: CGPoint, radius: CGFloat, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        let x = center.x + radius * copysign(pow(abs(cosT), 2 / exponent), cosT)
        let y = center.y + radius * copysign(pow(abs(sinT), 2 / exponent), sinT)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Notch silhouette in bottom-left-origin coordinates: `frame.maxY` is the top edge (flared with
/// concave corners of `top`), sides inset by `top`, convex bottom corners of `bottom`.
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

/// Deterministic grayscale noise (xorshift64*), so regenerating the icon is byte-stable.
func makeNoiseImage(size: Int, seed: UInt64) -> CGImage {
    var state = seed
    var pixels = [UInt8](repeating: 0, count: size * size)
    for index in pixels.indices {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = state &* 2_685_821_657_736_338_717
        pixels[index] = UInt8(truncatingIfNeeded: value >> 56)
    }
    let gray = CGColorSpaceCreateDeviceGray()
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(
              width: size,
              height: size,
              bitsPerComponent: 8,
              bitsPerPixel: 8,
              bytesPerRow: size,
              space: gray,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
              provider: provider,
              decode: nil,
              shouldInterpolate: false,
              intent: .defaultIntent
          )
    else {
        fatalError("Could not create the noise image")
    }
    return image
}

func strokeWithGradient(_ context: CGContext, path: CGPath, lineWidth: CGFloat, gradient: CGGradient, from start: CGPoint, to end: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.setLineWidth(lineWidth)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(gradient, start: start, end: end, options: [])
    context.restoreGState()
}

// MARK: - Master artwork

func renderMaster() -> CGImage {
    let context = makeContext(size: Int(canvas))
    let center = CGPoint(x: canvas / 2, y: canvas / 2)
    let bodyRadius: CGFloat = 412 // 824 pt body on the 1024 canvas, per the macOS icon grid
    let body = squirclePath(center: center, radius: bodyRadius)
    let bodyTop = center.y + bodyRadius
    let bodyBottom = center.y - bodyRadius

    // Drop shadow under the body.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.45))
    context.addPath(body)
    context.setFillColor(color(0x0D0D0E))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(body)
    context.clip()

    // Near-black body with a faint top light.
    context.drawLinearGradient(
        gradient([(color(0x141416), 0), (color(0x08080A), 1)]),
        start: CGPoint(x: center.x, y: bodyTop),
        end: CGPoint(x: center.x, y: bodyBottom),
        options: []
    )
    context.drawRadialGradient(
        gradient([(color(0xFFFFFF, 0.045), 0), (color(0xFFFFFF, 0), 1)]),
        startCenter: CGPoint(x: center.x, y: bodyTop - 40), startRadius: 0,
        endCenter: CGPoint(x: center.x, y: bodyTop - 40), endRadius: 620,
        options: []
    )

    // Notch silhouette hanging from the top edge (clipped by the squircle).
    let notchFrame = CGRect(x: center.x - 236, y: bodyTop - 236, width: 472, height: 236)
    let notch = notchPath(frame: notchFrame, top: 40, bottom: 96)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.7))
    context.addPath(notch)
    context.setFillColor(color(0x202023))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(notch)
    context.clip()
    context.drawLinearGradient(
        gradient([(color(0x2A2A2E), 0), (color(0x1D1D20), 1)]),
        start: CGPoint(x: center.x, y: notchFrame.maxY),
        end: CGPoint(x: center.x, y: notchFrame.minY),
        options: []
    )
    context.restoreGState()

    // Top-lit rim on the clay notch.
    strokeWithGradient(
        context,
        path: notch,
        lineWidth: 5,
        gradient: gradient([(color(0xFFFFFF, 0.02), 0), (color(0xFFFFFF, 0.10), 0.55), (color(0xFFFFFF, 0.03), 1)]),
        from: CGPoint(x: center.x, y: notchFrame.maxY),
        to: CGPoint(x: center.x, y: notchFrame.minY)
    )

    // Warm glow cast by the orb.
    let orbCenter = CGPoint(x: center.x, y: notchFrame.minY + 104)
    let orbRadius: CGFloat = 40
    context.drawRadialGradient(
        gradient([(color(0xF4F1EA, 0.24), 0), (color(0xF4F1EA, 0.06), 0.45), (color(0xF4F1EA, 0), 1)]),
        startCenter: orbCenter, startRadius: 0,
        endCenter: orbCenter, endRadius: 190,
        options: []
    )

    // Grain over everything inside the body.
    context.saveGState()
    context.setBlendMode(.screen)
    context.setAlpha(0.07)
    context.draw(makeNoiseImage(size: Int(canvas), seed: 0x4D49_4C4C_4552), in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
    context.restoreGState()

    // The orb: warm white sphere lit from the upper left.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x000000, 0.55))
    context.addEllipse(in: CGRect(x: orbCenter.x - orbRadius, y: orbCenter.y - orbRadius, width: orbRadius * 2, height: orbRadius * 2))
    context.setFillColor(color(0x8C8A86))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addEllipse(in: CGRect(x: orbCenter.x - orbRadius, y: orbCenter.y - orbRadius, width: orbRadius * 2, height: orbRadius * 2))
    context.clip()
    let highlight = CGPoint(x: orbCenter.x - orbRadius * 0.35, y: orbCenter.y + orbRadius * 0.4)
    context.drawRadialGradient(
        gradient([(color(0xFFFDF8), 0), (color(0xF4F1EA), 0.35), (color(0xC9C6BF), 0.75), (color(0x8C8A86), 1)]),
        startCenter: highlight, startRadius: 0,
        endCenter: orbCenter, endRadius: orbRadius * 1.08,
        options: [.drawsAfterEndLocation]
    )
    context.restoreGState()

    context.restoreGState() // body clip

    // Hairline top-lit edge on the body.
    strokeWithGradient(
        context,
        path: body,
        lineWidth: 4,
        gradient: gradient([(color(0xFFFFFF, 0.14), 0), (color(0xFFFFFF, 0.03), 0.5), (color(0xFFFFFF, 0.01), 1)]),
        from: CGPoint(x: center.x, y: bodyTop),
        to: CGPoint(x: center.x, y: bodyBottom)
    )

    guard let image = context.makeImage() else { fatalError("Could not render the icon") }
    return image
}

// MARK: - iPhone artwork

/// The iPhone icon: the body's felt to every edge (no squircle, shadow or rim: iOS masks the corners), and a
/// charcoal Dynamic Island pill near the top with the orb in its middle. Same colors, glow and grain as the Mac.
func renderIOSMaster() -> CGImage {
    let context = makeContext(size: Int(canvas))
    let center = CGPoint(x: canvas / 2, y: canvas / 2)

    context.drawLinearGradient(
        gradient([(color(0x141416), 0), (color(0x08080A), 1)]),
        start: CGPoint(x: center.x, y: canvas),
        end: CGPoint(x: center.x, y: 0),
        options: []
    )
    context.drawRadialGradient(
        gradient([(color(0xFFFFFF, 0.045), 0), (color(0xFFFFFF, 0), 1)]),
        startCenter: CGPoint(x: center.x, y: canvas - 40), startRadius: 0,
        endCenter: CGPoint(x: center.x, y: canvas - 40), endRadius: 620,
        options: []
    )

    // The Dynamic Island: a capsule 560 × 168 whose top edge sits 150 px below the canvas top.
    let pillFrame = CGRect(x: center.x - 280, y: canvas - 150 - 168, width: 560, height: 168)
    let pill = CGPath(roundedRect: pillFrame, cornerWidth: 84, cornerHeight: 84, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.7))
    context.addPath(pill)
    context.setFillColor(color(0x202023))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(pill)
    context.clip()
    context.drawLinearGradient(
        gradient([(color(0x2A2A2E), 0), (color(0x1D1D20), 1)]),
        start: CGPoint(x: center.x, y: pillFrame.maxY),
        end: CGPoint(x: center.x, y: pillFrame.minY),
        options: []
    )
    context.restoreGState()

    strokeWithGradient(
        context,
        path: pill,
        lineWidth: 5,
        gradient: gradient([(color(0xFFFFFF, 0.02), 0), (color(0xFFFFFF, 0.10), 0.55), (color(0xFFFFFF, 0.03), 1)]),
        from: CGPoint(x: center.x, y: pillFrame.maxY),
        to: CGPoint(x: center.x, y: pillFrame.minY)
    )

    let orbCenter = CGPoint(x: center.x, y: pillFrame.midY)
    let orbRadius: CGFloat = 40
    context.drawRadialGradient(
        gradient([(color(0xF4F1EA, 0.24), 0), (color(0xF4F1EA, 0.06), 0.45), (color(0xF4F1EA, 0), 1)]),
        startCenter: orbCenter, startRadius: 0,
        endCenter: orbCenter, endRadius: 190,
        options: []
    )

    context.saveGState()
    context.setBlendMode(.screen)
    context.setAlpha(0.07)
    context.draw(makeNoiseImage(size: Int(canvas), seed: 0x4D49_4C4C_4552), in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
    context.restoreGState()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x000000, 0.55))
    context.addEllipse(in: CGRect(x: orbCenter.x - orbRadius, y: orbCenter.y - orbRadius, width: orbRadius * 2, height: orbRadius * 2))
    context.setFillColor(color(0x8C8A86))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addEllipse(in: CGRect(x: orbCenter.x - orbRadius, y: orbCenter.y - orbRadius, width: orbRadius * 2, height: orbRadius * 2))
    context.clip()
    let highlight = CGPoint(x: orbCenter.x - orbRadius * 0.35, y: orbCenter.y + orbRadius * 0.4)
    context.drawRadialGradient(
        gradient([(color(0xFFFDF8), 0), (color(0xF4F1EA), 0.35), (color(0xC9C6BF), 0.75), (color(0x8C8A86), 1)]),
        startCenter: highlight, startRadius: 0,
        endCenter: orbCenter, endRadius: orbRadius * 1.08,
        options: [.drawsAfterEndLocation]
    )
    context.restoreGState()

    guard let image = context.makeImage() else { fatalError("Could not render the iPhone icon") }
    return image
}

/// iOS rejects an app icon with an alpha channel, so the iPhone icon is written opaque.
func opaque(_ image: CGImage) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        fatalError("Could not create an opaque bitmap context")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let result = context.makeImage() else { fatalError("Could not flatten the iPhone icon") }
    return result
}

// MARK: - Output

func resized(_ image: CGImage, to pixels: Int) -> CGImage {
    if pixels == image.width { return image }
    let context = makeContext(size: pixels)
    context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let result = context.makeImage() else { fatalError("Could not resize the icon to \(pixels) px") }
    return result
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}

struct IconSlot {
    let points: Int
    let scale: Int
    var pixels: Int { points * scale }
    var filename: String { "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png" }
}

let slots: [IconSlot] = [16, 32, 128, 256, 512].flatMap { points in
    [IconSlot(points: points, scale: 1), IconSlot(points: points, scale: 2)]
}

do {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: iconSetURL, withIntermediateDirectories: true)

    let master = renderMaster()
    for slot in slots {
        let url = iconSetURL.appendingPathComponent(slot.filename)
        try writePNG(resized(master, to: slot.pixels), to: url)
        print("wrote \(url.path)")
    }

    let images = slots.map { slot -> [String: String] in
        [
            "filename": slot.filename,
            "idiom": "mac",
            "scale": "\(slot.scale)x",
            "size": "\(slot.points)x\(slot.points)",
        ]
    }
    let info = ["author": "xcode", "version": 1] as [String: Any]
    let iconSetContents: [String: Any] = ["images": images, "info": info]
    let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
    try JSONSerialization.data(withJSONObject: iconSetContents, options: options)
        .write(to: iconSetURL.appendingPathComponent("Contents.json"))

    let catalogContentsURL = catalogURL.appendingPathComponent("Contents.json")
    if !fileManager.fileExists(atPath: catalogContentsURL.path) {
        try JSONSerialization.data(withJSONObject: ["info": info], options: options).write(to: catalogContentsURL)
    }
    print("AppIcon written to \(iconSetURL.path)")

    // The iPhone app: one opaque 1024 px universal icon.
    try fileManager.createDirectory(at: iOSIconSetURL, withIntermediateDirectories: true)
    let iOSIconURL = iOSIconSetURL.appendingPathComponent("AppIcon.png")
    try writePNG(opaque(renderIOSMaster()), to: iOSIconURL)
    print("wrote \(iOSIconURL.path)")
    let iOSImages: [[String: String]] = [
        ["filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"],
    ]
    try JSONSerialization.data(withJSONObject: ["images": iOSImages, "info": info], options: options)
        .write(to: iOSIconSetURL.appendingPathComponent("Contents.json"))
    let iOSCatalogContentsURL = iOSCatalogURL.appendingPathComponent("Contents.json")
    if !fileManager.fileExists(atPath: iOSCatalogContentsURL.path) {
        try JSONSerialization.data(withJSONObject: ["info": info], options: options).write(to: iOSCatalogContentsURL)
    }
} catch {
    FileHandle.standardError.write(Data("make_icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
