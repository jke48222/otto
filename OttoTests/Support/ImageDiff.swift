//
//  ImageDiff.swift
//  OttoTests
//
//  Pixel comparison for snapshot regression tests: both images are drawn into the same 8-bit sRGB
//  RGBA buffer, and a pixel counts as different when any channel differs by more than the tolerance.
//

import AppKit
import CoreGraphics
import Foundation

enum ImageDiff {
    struct Result: Equatable {
        let width: Int
        let height: Int
        let differingPixels: Int
        /// The largest per-channel difference found (0…255).
        let maxChannelDelta: Int

        var totalPixels: Int { width * height }
        var differingFraction: Double { totalPixels == 0 ? 0 : Double(differingPixels) / Double(totalPixels) }
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case sizeMismatch(expected: CGSize, actual: CGSize)

        var description: String {
            switch self {
            case .unreadable(let path):
                return "Couldn't read an image at \(path)"
            case .sizeMismatch(let expected, let actual):
                return "Image size \(Int(actual.width))×\(Int(actual.height)) doesn't match the baseline's "
                    + "\(Int(expected.width))×\(Int(expected.height))"
            }
        }
    }

    /// Compares two PNG (or any ImageIO-readable) files pixel by pixel.
    static func compare(_ expectedURL: URL, _ actualURL: URL, tolerance: Int = 8) throws -> Result {
        let expected = try image(at: expectedURL)
        let actual = try image(at: actualURL)
        return try compare(expected, actual, tolerance: tolerance)
    }

    /// Compares two images of the same pixel size. `tolerance` is the largest per-channel difference (0…255)
    /// that still counts as equal.
    static func compare(_ expected: CGImage, _ actual: CGImage, tolerance: Int = 8) throws -> Result {
        guard expected.width == actual.width, expected.height == actual.height else {
            throw Failure.sizeMismatch(expected: CGSize(width: expected.width, height: expected.height),
                                       actual: CGSize(width: actual.width, height: actual.height))
        }
        let expectedPixels = try rgba(expected)
        let actualPixels = try rgba(actual)
        var differing = 0
        var maxDelta = 0
        var index = 0
        while index < expectedPixels.count {
            var pixelDelta = 0
            for channel in 0..<4 {
                let delta = abs(Int(expectedPixels[index + channel]) - Int(actualPixels[index + channel]))
                pixelDelta = max(pixelDelta, delta)
            }
            if pixelDelta > tolerance { differing += 1 }
            maxDelta = max(maxDelta, pixelDelta)
            index += 4
        }
        return Result(width: expected.width, height: expected.height, differingPixels: differing,
                      maxChannelDelta: maxDelta)
    }

    static func image(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.unreadable(url.path)
        }
        return image
    }

    // MARK: - Private

    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw Failure.unreadable("sRGB color space")
        }
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure.unreadable("bitmap context") }
        return pixels
    }
}
