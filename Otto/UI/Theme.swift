//
//  Theme.swift
//  Otto
//
//  Design tokens and the shared visual primitives of the notch: the fine foam grain,
//  raised "clay" surfaces, the Otto orb and a few small animated indicators.
//

import AppKit
import SwiftUI

// MARK: - Tokens

enum Theme {
    // Surfaces
    /// The open panel: a smooth matte near-black base. Texture is kept for the raised forms, so
    /// the panel carries only a faint grain (with it the base renders ≈ #070708, stdev ≈ 2).
    static let panel = rgb(0x060607)
    /// Raised clay forms are lit from above like a pillow: each body is a vertical gradient from a
    /// lit upper face to a shaded underside (see `ClayStyle`).
    /// The composer slab. Measured with the grain, top glow and rim laid over it, this renders
    /// ≈ 29 / 21 / 10 luminance across its top third / middle / bottom edge (mean ≈ 20).
    static let slabGradient: [Gradient.Stop] = [
        .init(color: rgb(0x18191B), location: 0),
        .init(color: rgb(0x131416), location: 0.35),
        .init(color: rgb(0x0B0C0D), location: 1),
    ]
    /// The chip tray (the slab recipe at 70 %).
    static let trayGradient: [Gradient.Stop] = [
        .init(color: rgb(0x1B1C1F), location: 0),
        .init(color: rgb(0x0D0E10), location: 1),
    ]
    /// The domed ⋮ pebble (and the disabled send disc, which ends a touch lighter).
    static let pebbleGradient: [Gradient.Stop] = [
        .init(color: rgb(0x2A2B2E), location: 0),
        .init(color: rgb(0x131416), location: 1),
    ]
    /// The puffy selected chip resting on the tray.
    static let chipGradient: [Gradient.Stop] = [
        .init(color: rgb(0x2B2C2F), location: 0),
        .init(color: rgb(0x17181A), location: 1),
    ]
    /// Slightly lifted flat clay: the user's message bubble.
    static let clayRaised = rgb(0x1C1D1F)
    /// Flat fill of code blocks. Deliberately not a gradient: a streaming block grows every line,
    /// and a gradient would be re-rasterized over its whole area each time.
    static let codeFill = rgb(0x0E0E0F)

    // Text
    // Every text color passes WCAG AA (4.5:1) on the panel, the code well and the lightest flat
    // surface, clayRaised (scripts: contrast_check.py --tokens Otto/UI/Theme.swift --matrix).
    // Tertiary text carries model names, code languages and the Copy row, so it is readable text,
    // not decoration. Measured on panel / clayRaised: primary 17.3 / 14.4, secondary 8.06 / 6.72,
    // muted 6.29 / 5.24, tertiary 5.66 / 4.72. The steps keep primary > secondary > muted > tertiary.
    // The chip and pebble gradients are lighter still (tops #2B2C2F / #2A2B2E): there tertiary drops to
    // 3.91 / 3.96, so text on a `.chip` or `.pebble` surface (key hints in secondary buttons, a selected
    // Recents row's date) uses secondary (5.56 / 5.64) or brighter. Never dim text with `.opacity`: dim the
    // chrome around it instead.
    static let textPrimary = rgb(0xEDEDED)
    static let textSecondary = rgb(0xA3A3A8)
    static let textTertiary = rgb(0x87878C)
    /// The tertiary step for text on grained clay (`.tray`, `.raised`: dock cards, the Shelf bar, the Now Playing
    /// strip). The grain's highlights lift the surface to #242528 (90th percentile) and #2D2E30 (99th), where
    /// `textTertiary` drops to 4.29 / 3.80; this measures 5.61 / 4.97 there and 6.43 on the clay's median.
    /// Labels, meta lines and footnotes on clay use it and keep their rank through size and weight.
    static let textTertiaryOnClay = rgb(0x9C9CA1)
    /// The composer's placeholder and status ("Ask Otto anything…", "Waiting for your OK…"): 5.12 on the
    /// slab's lit top (#18191B), 4.86 on #1D1E20.
    static let placeholder = rgb(0x8A8A8F)
    /// Assistant reply body text: a touch softer than `textPrimary`.
    static let textBody = rgb(0xE2E2E4)
    /// Tool activity and thought-process rows.
    static let textMuted = rgb(0x8F8F94)
    /// Chip labels: a softer white than body text, so chips stay quieter than the composer.
    static let chipLabel = Color.white.opacity(0.82)
    /// Source pill labels: secondary to the reply body they cite.
    static let sourceLabel = Color.white.opacity(0.62)
    static let sourceLabelHover = Color.white.opacity(0.8)
    static let error = rgb(0xFF8A80)

    // Accents
    /// Cool light grey of the send disc (also the text-field caret and drop-target accents).
    static let sendFill = rgb(0xD6D7D9)
    /// The send disc's domed falloff, top to bottom.
    static let sendTop = rgb(0xE2E3E5)
    static let sendBottom = rgb(0xC9CACC)
    static let sendGlyph = rgb(0x1A1A1C)
    /// Key hints on the send gradient ("⌘↩" on a primary button): solid, 5.38 on its darker end (#C9CACC).
    static let sendHint = rgb(0x4A4A4E)
    /// The disabled disc reads as clay (the pebble gradient), not a flat grey hole.
    static let sendDisabledGradient: [Gradient.Stop] = [
        .init(color: rgb(0x2A2B2E), location: 0),
        .init(color: rgb(0x18191B), location: 1),
    ]
    static let sendDisabledGlyph = Color.white.opacity(0.35)
    /// Unselected context chips are just icon + label resting on the foam: no plate at rest…
    static let chipFill = Color.clear
    /// …and a soft plate under the pointer.
    static let chipLiftedFill = Color.white.opacity(0.06)
    /// Source pills (a reply's links): a whisper of a plate, a little more on hover.
    static let sourcePillFill = Color.white.opacity(0.035)
    static let sourcePillHoverFill = Color.white.opacity(0.08)
    static let orbLight = rgb(0xF4F1EA)
    static let orbDark = rgb(0x8C8A86)
    static let badgeFill = rgb(0xE6E4DF)
    static let badgeText = rgb(0x1C1C1E)
    static let link = rgb(0xE4DDCF)
    static let inlineCodeText = rgb(0xE8DCC8)
    static let inlineCodeBackground = Color.white.opacity(0.06)
    static let codeText = rgb(0xD9D6CF)
    static let hairline = Color.white.opacity(0.07)

    /// Opaque sRGB color from a 0xRRGGBB literal.
    static func rgb(_ hex: UInt32, opacity: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    // Type
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let wordmark = Font.system(size: 15, weight: .medium, design: .serif)
    static let bodySize: CGFloat = 14
    static let codeSize: CGFloat = 12.5

    // Motion
    enum Motion {
        static let open = Animation.spring(response: 0.42, dampingFraction: 0.82)
        static let close = Animation.spring(response: 0.34, dampingFraction: 0.9)
        static let hover = Animation.spring(response: 0.3, dampingFraction: 0.78)
        static let content = Animation.spring(response: 0.36, dampingFraction: 0.86)
        static let press = Animation.spring(response: 0.2, dampingFraction: 0.7)
    }
}

extension Theme {
    /// Warm amber: the approval glyph, the caution banner, "needs your OK".
    static let attention = rgb(0xEBC07A)
    /// The listening dot only.
    static let recording = rgb(0xFF6B5E)
    /// Neutral notice line.
    static let notice = textSecondary
}

extension Theme.Motion {
    /// Prompts entering and leaving the dock.
    static let dock = Animation.spring(response: 0.38, dampingFraction: 0.84)
}

// MARK: - Grain

/// Fine monochrome grain for the panel itself (the base the clay forms sit on). The 256×256
/// texture is generated once, deterministically, and tiled at 2× so each grain is half a point.
/// Kept faint; used under code blocks. (The open panel itself carries a softened `ClayGrain`.)
struct NoiseTexture: View {
    static let panelOpacity: Double = 0.035

    var opacity: Double = NoiseTexture.panelOpacity

    var body: some View {
        if let image = Self.image {
            Image(decorative: image, scale: 2)
                .resizable(resizingMode: .tile)
                .opacity(opacity)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    static let image: CGImage? = makeImage(side: 256, seed: 0x4D49_4C4C_4552)

    /// Two layers of value noise: per-pixel white noise for the fine grain, plus a softly blurred
    /// layer that clumps the grain into felt-like cells. Both wrap around so the tile is seamless.
    private static func makeImage(side: Int, seed: UInt64) -> CGImage? {
        guard side > 0 else { return nil }
        var generator = SplitMix64(seed: seed)
        let count = side * side
        var fine = [Float](repeating: 0, count: count)
        var coarse = [Float](repeating: 0, count: count)
        for index in 0..<count {
            fine[index] = generator.nextUnit()
            coarse[index] = generator.nextUnit()
        }
        let clumps = GrainMath.wrappedBoxBlur(coarse, side: side, radius: 2)

        var pixels = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            // The blurred layer concentrates around 0.5; stretch it back out before mixing.
            let felt = min(max((clumps[index] - 0.5) * 3.4 + 0.5, 0), 1)
            let mixed = 0.55 * fine[index] + 0.45 * felt
            // Bias toward dark so additive blending reads as grain rather than a lifted gray.
            let shaped = pow(min(max(mixed, 0), 1), 1.3)
            pixels[index] = UInt8(min(max(shaped * 255, 0), 255))
        }
        return GrainMath.grayImage(pixels, side: side)
    }
}

/// The fine foam of raised clay, like the reference's soft-touch surface: a field of tiny, uneven
/// pores (weighted cellular noise, ~3.3 pt cells jittered ±35 % in size) whose edges are softened
/// with a Gaussian before lighting, so no crisp cell outline survives. The softened height map's
/// vertical slope gives an emboss lit from above: slopes facing the light are laid on as white,
/// slopes facing away as black. Deterministic and seamless; generated once at 2× (one texel per
/// device pixel on Retina) and tiled.
///
/// The two layers are premultiplied white / black images drawn with normal blending: a small
/// alpha of white over a dark surface is effectively additive (`plusLighter`), and black at alpha
/// `a` is exactly a multiply by `1 - a`. Unlike blend modes, this does not depend on what the
/// grain happens to be composited against (a clipped overlay renders into its own layer, where a
/// multiply blends with transparency and shows up as a light haze).
struct ClayGrain: View {
    /// Scales both the highlight and the shade (1 on the composer, less on quieter surfaces).
    var intensity: Double = 1
    /// On raised clay the crinkle shows where light hits: the highlight layer fades from full on
    /// the upper face to 30 % on the shaded underside (the shade layer is left unmasked), which is
    /// much of what makes the foam read as a 3D material rather than a wallpaper.
    var fadesWithLight: Bool = false

    static let highlightOpacity: Double = 0.10
    static let shadeOpacity: Double = 0.14

    var body: some View {
        if let relief = Self.relief {
            ZStack {
                Image(decorative: relief.shade, scale: Self.scale)
                    .resizable(resizingMode: .tile)
                    .opacity(Self.shadeOpacity * intensity)
                Image(decorative: relief.highlight, scale: Self.scale)
                    .resizable(resizingMode: .tile)
                    .opacity(Self.highlightOpacity * intensity)
                    .mask {
                        if fadesWithLight {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black.opacity(0.8), location: 0.35),
                                    .init(color: .black.opacity(0.3), location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        } else {
                            Color.black
                        }
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private struct Relief {
        /// White, opaque where a slope faces the light.
        let highlight: CGImage
        /// Black, opaque where a slope faces away from the light.
        let shade: CGImage
    }

    /// Texels per point.
    private static let scale: CGFloat = 2
    /// 512 texels = a 256 pt tile with 78 × 78 cells (≈ 6.6 texels, 3.3 pt each).
    private static let side = 512
    private static let cellsPerSide = 78
    /// Gaussian softening of the height map before lighting, in texels (0.7 pt).
    private static let softening: Float = 1.4

    private static let relief: Relief? = makeRelief(seed: 0x4D49_4C4C_4552_434C)

    private static func makeRelief(seed: UInt64) -> Relief? {
        let side = Self.side
        let cells = Self.cellsPerSide
        let count = side * side
        let cellSize = Float(side) / Float(cells)
        var generator = SplitMix64(seed: seed)

        // One freely jittered feature point, a random height and a size weight per cell. Dividing
        // distances by the weight (0.65…1.35) grows or shrinks each cell by up to 35 %, so the
        // field never reads as a tiled grid.
        let cellCount = cells * cells
        var featureX = [Float](repeating: 0, count: cellCount)
        var featureY = [Float](repeating: 0, count: cellCount)
        var amplitude = [Float](repeating: 0, count: cellCount)
        var inverseWeight = [Float](repeating: 0, count: cellCount)
        for index in 0..<cellCount {
            featureX[index] = generator.nextUnit()
            featureY[index] = generator.nextUnit()
            amplitude[index] = 0.55 + 0.45 * generator.nextUnit()
            inverseWeight[index] = 1 / (0.65 + 0.7 * generator.nextUnit())
        }

        var height = [Float](repeating: 0, count: count)
        height.withUnsafeMutableBufferPointer { out in
            featureX.withUnsafeBufferPointer { fxs in
                featureY.withUnsafeBufferPointer { fys in
                    amplitude.withUnsafeBufferPointer { amps in
                        inverseWeight.withUnsafeBufferPointer { weights in
                            for y in 0..<side {
                                let py = Float(y) + 0.5
                                let cellY = min(Int(py / cellSize), cells - 1)
                                for x in 0..<side {
                                    let px = Float(x) + 0.5
                                    let cellX = min(Int(px / cellSize), cells - 1)
                                    // Weighted distances to the nearest (f1) and second-nearest
                                    // (f2) feature points, wrapping so the tile is seamless. A 5 × 5
                                    // neighbourhood covers the reach of the largest weights.
                                    var f1 = Float.greatestFiniteMagnitude
                                    var f2 = Float.greatestFiniteMagnitude
                                    var cellHeight: Float = 1
                                    for dy in -2...2 {
                                        let gy = cellY + dy
                                        let row = ((gy + cells) % cells) * cells
                                        for dx in -2...2 {
                                            let gx = cellX + dx
                                            let index = row + (gx + cells) % cells
                                            let fx = (Float(gx) + fxs[index]) * cellSize
                                            let fy = (Float(gy) + fys[index]) * cellSize
                                            let ddx = px - fx
                                            let ddy = py - fy
                                            let distance = (ddx * ddx + ddy * ddy).squareRoot() * weights[index]
                                            if distance < f1 {
                                                f2 = f1
                                                f1 = distance
                                                cellHeight = amps[index]
                                            } else if distance < f2 {
                                                f2 = distance
                                            }
                                        }
                                    }
                                    // f2 − f1 is 0 on the crease between two cells and grows toward
                                    // each centre: smoothstep it into a plateau, dome it slightly.
                                    let ridge = min(max((f2 - f1) / cellSize / 0.45, 0), 1)
                                    let plateau = ridge * ridge * (3 - 2 * ridge)
                                    let dome = 1 - 0.35 * min(f1 / cellSize, 1)
                                    out[y * side + x] = plateau * dome * cellHeight
                                }
                            }
                        }
                    }
                }
            }
        }
        // Soften before lighting, so the creases become pores rather than polygon outlines.
        height = GrainMath.wrappedGaussianBlur(height, side: side, sigma: Self.softening)

        // Emboss: the height map minus itself shifted down by 1 pt. Positive where the surface
        // rises going down the screen, i.e. on the upper, light-facing edge of a cell.
        let shift = Int(Self.scale)
        var emboss = [Float](repeating: 0, count: count)
        var magnitudes = [Float](repeating: 0, count: count)
        for y in 0..<side {
            let above = (y - shift + side) % side
            for x in 0..<side {
                let value = height[y * side + x] - height[above * side + x]
                emboss[y * side + x] = value
                magnitudes[y * side + x] = abs(value)
            }
        }
        // Normalize against a high percentile so the strongest slopes saturate.
        magnitudes.sort()
        let reference = max(magnitudes[Int(Float(count - 1) * 0.97)], .ulpOfOne)

        var light = [UInt8](repeating: 0, count: count)
        var shade = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            let slope = min(max(emboss[index] / reference, -1), 1)
            let amount = UInt8(min(max(abs(slope) * 255, 0), 255))
            if slope > 0 { light[index] = amount } else { shade[index] = amount }
        }
        guard
            let highlight = GrainMath.coverageImage(light, side: side, white: true),
            let shadeImage = GrainMath.coverageImage(shade, side: side, white: false)
        else { return nil }
        return Relief(highlight: highlight, shade: shadeImage)
    }
}

private enum GrainMath {
    /// Separable Gaussian blur with wrap-around edges (keeps the tile seamless).
    static func wrappedGaussianBlur(_ values: [Float], side: Int, sigma: Float) -> [Float] {
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = (-radius...radius).map { offset -> Float in
            let x = Float(offset)
            return exp(-(x * x) / (2 * sigma * sigma))
        }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var horizontal = [Float](repeating: 0, count: values.count)
        for y in 0..<side {
            for x in 0..<side {
                var sum: Float = 0
                for offset in -radius...radius {
                    sum += values[y * side + (x + offset + side) % side] * kernel[offset + radius]
                }
                horizontal[y * side + x] = sum
            }
        }
        var result = [Float](repeating: 0, count: values.count)
        for y in 0..<side {
            for x in 0..<side {
                var sum: Float = 0
                for offset in -radius...radius {
                    sum += horizontal[((y + offset + side) % side) * side + x] * kernel[offset + radius]
                }
                result[y * side + x] = sum
            }
        }
        return result
    }

    /// Separable box blur with wrap-around edges (keeps the tile seamless).
    static func wrappedBoxBlur(_ values: [Float], side: Int, radius: Int) -> [Float] {
        let window = Float(radius * 2 + 1)
        var horizontal = [Float](repeating: 0, count: values.count)
        for y in 0..<side {
            for x in 0..<side {
                var sum: Float = 0
                for offset in -radius...radius {
                    let sx = (x + offset + side) % side
                    sum += values[y * side + sx]
                }
                horizontal[y * side + x] = sum / window
            }
        }
        var result = [Float](repeating: 0, count: values.count)
        for y in 0..<side {
            for x in 0..<side {
                var sum: Float = 0
                for offset in -radius...radius {
                    let sy = (y + offset + side) % side
                    sum += horizontal[sy * side + x]
                }
                result[y * side + x] = sum / window
            }
        }
        return result
    }

    /// A premultiplied RGBA square image of solid white (or black) with `coverage` as alpha.
    static func coverageImage(_ coverage: [UInt8], side: Int, white: Bool) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: coverage.count * 4)
        for (index, alpha) in coverage.enumerated() {
            let value = white ? alpha : 0
            pixels[index * 4] = value
            pixels[index * 4 + 1] = value
            pixels[index * 4 + 2] = value
            pixels[index * 4 + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// An 8-bit grayscale, non-interpolated square image.
    static func grayImage(_ pixels: [UInt8], side: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

/// Tiny deterministic PRNG (SplitMix64) so the grain is identical on every launch and snapshot.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }
}

// MARK: - Clay

/// How a clay form is lit and seated. Every raised form shares one recipe — a body lit from the
/// top like a pillow (a vertical gradient), a rolled highlight along the top edge, a soft inner
/// glow under it, an inner shade rolling away along the bottom, a drop shadow and a contact
/// shadow — scaled per form.
struct ClayStyle {
    var gradient: [Gradient.Stop] = Theme.slabGradient
    /// Strength of the foam grain (`ClayGrain.intensity`).
    var grain: Double = 1
    /// Scales the rim, inner glow and inner shade (and both shadows' opacity).
    var strength: Double = 1
    var shadowOpacity: Double = 0.85
    var shadowRadius: CGFloat = 12
    var shadowY: CGFloat = 6
    /// The tight contact shadow that seats the edge onto the base.
    var contactOpacity: Double = 0.65

    /// The composer slab.
    static let slab = ClayStyle()
    /// The chip tray: the slab recipe at 70 %, on its own gradient.
    static let tray = ClayStyle(gradient: Theme.trayGradient, strength: 0.7)
    /// The ⋮ pebble: a lighter, domed gradient, half the grain, a tighter shadow.
    static let pebble = ClayStyle(
        gradient: Theme.pebbleGradient,
        grain: 0.5,
        shadowOpacity: 0.7,
        shadowRadius: 6,
        shadowY: 3
    )
    /// The puffy selected chip resting on the tray.
    static let chip = ClayStyle(
        gradient: Theme.chipGradient,
        grain: 0.8,
        shadowOpacity: 0.6,
        shadowRadius: 5,
        shadowY: 2
    )
}

/// A raised, softly lit "clay" surface (see `ClayStyle`). Used for the composer slab, the chip
/// tray, the selected chip and the ⋮ pebble.
///
/// Every light and shade band is a gradient mask rather than a blur: it costs no offscreen pass
/// while the composer resizes, and renders identically in layer snapshots (which drop blur
/// filters).
struct ClaySurface<S: InsettableShape>: View {
    var shape: S
    var style: ClayStyle = .slab
    var isPressed: Bool = false
    var isHighlighted: Bool = false

    /// Rim and glow light, dimmed while pressed.
    private var light: Double { style.strength * (isPressed ? 0.5 : 1) }

    /// The rolled edge: `rimSteps` nested inner strokes, each `rimWidth / rimSteps` wider than the
    /// last, add up to a highlight of `rimOpacity` at the edge fading to nothing `rimWidth` inward.
    private static var rimWidth: CGFloat { 3 }
    private static var rimSteps: Int { 6 }
    private static var rimOpacity: Double { 0.12 }

    var body: some View {
        shape
            .fill(LinearGradient(stops: style.gradient, startPoint: .top, endPoint: .bottom))
            .overlay {
                if style.grain > 0 {
                    ClayGrain(intensity: style.grain, fadesWithLight: true)
                        .clipShape(shape)
                }
            }
            .overlay {
                // Inner shade along the bottom (black 0.45 easing out over 18 pt), so the
                // underside rolls away softly into the contact shadow.
                edgeBand(Color.black.opacity(0.45 * style.strength), depth: 18, alignment: .bottom)
            }
            .overlay {
                // Soft inner glow under the lit top face (white 0.06 over 10 pt).
                edgeBand(Color.white.opacity(0.06 * light), depth: 10, alignment: .top)
            }
            .overlay {
                // Pressed sinks the form a little; hover lifts it a touch.
                shape.fill(
                    isPressed
                        ? Color.black.opacity(0.18)
                        : Color.white.opacity(isHighlighted ? 0.035 : 0)
                )
            }
            .overlay { rolledRim }
            .background {
                // Drop shadow, then a tight contact shadow so the edge sits in a near-black moat
                // on the base.
                LayeredShadow(
                    shape: shape,
                    opacity: style.shadowOpacity * style.strength,
                    radius: isPressed ? style.shadowRadius * 0.5 : style.shadowRadius,
                    y: isPressed ? style.shadowY * 0.5 : style.shadowY
                )
                LayeredShadow(shape: shape, opacity: style.contactOpacity * style.strength, radius: 2, y: 1.5, layers: 4)
            }
    }

    /// A soft highlight rolling over the top edge: brightest at the outline, gone `rimWidth`
    /// inward, and only across the top (1 at the top, 0.35 at 15 %, nothing from 30 % of the
    /// height), so the side walls below the corner arcs carry no line.
    private var rolledRim: some View {
        let stepOpacity = 1 - pow(1 - Self.rimOpacity * light, 1 / Double(Self.rimSteps))
        return ZStack {
            ForEach(1...Self.rimSteps, id: \.self) { step in
                shape.strokeBorder(
                    Color.white.opacity(stepOpacity),
                    lineWidth: Self.rimWidth * CGFloat(step) / CGFloat(Self.rimSteps)
                )
            }
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.35), location: 0.15),
                    .init(color: .clear, location: 0.3),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    /// The shape filled with `color`, strongest at one edge and easing out over `depth` points.
    private func edgeBand(_ color: Color, depth: CGFloat, alignment: VerticalAlignment) -> some View {
        let atBottom = alignment == .bottom
        return shape
            .fill(color)
            .mask(alignment: atBottom ? .bottom : .top) {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.55), location: 0.3),
                        .init(color: .black.opacity(0.18), location: 0.65),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: atBottom ? .bottom : .top,
                    endPoint: atBottom ? .top : .bottom
                )
                .frame(height: depth)
            }
    }
}

/// A soft drop shadow built from nested copies of the shape, grown from `radius` inside the outline
/// to `radius` outside it, each a faint black: where they overlap they add up to `opacity`, and
/// the stack falls off like a blurred edge (half strength at the outline, nothing `radius` out).
///
/// Used instead of `.shadow` on the clay: a SwiftUI shadow becomes a blur filter on the layer as
/// soon as the view hosts an AppKit control (the composer's text field), and layer snapshots drop
/// blur filters — the composer's shadow simply vanished from the renders. Plain fills render the
/// same everywhere, and cost no offscreen pass while the composer resizes.
struct LayeredShadow<S: InsettableShape>: View {
    var shape: S
    var opacity: Double
    var radius: CGFloat
    var y: CGFloat
    var layers: Int = 12

    var body: some View {
        let count = max(layers, 1)
        let layerOpacity = 1 - pow(1 - min(max(opacity, 0), 0.999), 1 / Double(count))
        ZStack {
            ForEach(0..<count, id: \.self) { index in
                // Insets from +radius (inside) to −radius (outside), centred on each step.
                let inset = radius - 2 * radius * (CGFloat(index) + 0.5) / CGFloat(count)
                shape
                    .inset(by: inset)
                    .fill(Color.black.opacity(layerOpacity))
            }
        }
        .offset(y: y)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Places a rounded-rectangle clay surface behind the view.
    func clay(
        cornerRadius: CGFloat,
        style: ClayStyle = .slab,
        isPressed: Bool = false,
        isHighlighted: Bool = false
    ) -> some View {
        background(
            ClaySurface(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                style: style,
                isPressed: isPressed,
                isHighlighted: isHighlighted
            )
        )
    }

    /// Places a clay surface of any insettable shape (e.g. `Circle()`) behind the view.
    func clay<S: InsettableShape>(
        in shape: S,
        style: ClayStyle = .slab,
        isPressed: Bool = false,
        isHighlighted: Bool = false
    ) -> some View {
        background(ClaySurface(shape: shape, style: style, isPressed: isPressed, isHighlighted: isHighlighted))
    }
}

/// Chrome for a round `Menu` button. A menu does not route its label through a custom
/// `ButtonStyle`, so this tracks the pointer and the menu itself: it is "open" while some menu is
/// presented and that menu was opened with the pointer on this button. Apply it to the `Menu`
/// (after `.fixedSize()`), not to its label.
struct MenuButtonChromeModifier: ViewModifier {
    enum Style {
        /// A raised clay pebble (the ⋮ button): highlights on hover, pressed clay scaled to 0.97
        /// while its menu shows.
        case clay
        /// No surface at rest (the composer's +): a faint disc on hover, a dimmer disc and a 0.94
        /// scale while its menu shows.
        case ghost
    }

    /// Whether some menu is currently open (`NotchViewModel.isMenuPresented`).
    let isMenuPresented: Bool
    var style: Style = .clay
    /// Diameter of the visible chrome, centred in the button; `nil` fills the button (so the hit
    /// area can be larger than the pebble).
    var diameter: CGFloat?
    @State private var isHovering = false
    /// The open menu belongs to this button: it opened while the pointer was on it.
    @State private var isOpen = false

    func body(content: Content) -> some View {
        content
            .background { chrome.frame(width: diameter, height: diameter) }
            .scaleEffect(isOpen ? (style == .clay ? 0.97 : 0.94) : 1)
            .animation(Theme.Motion.press, value: isOpen)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
            .onChange(of: isMenuPresented) { _, presented in
                isOpen = presented && (isHovering || isOpen)
            }
    }

    @ViewBuilder
    private var chrome: some View {
        switch style {
        case .clay:
            ClaySurface(
                shape: Circle(),
                style: .pebble,
                isPressed: isOpen,
                isHighlighted: isHovering && !isOpen
            )
        case .ghost:
            Circle().fill(Color.white.opacity(isOpen ? 0.04 : (isHovering ? 0.07 : 0)))
        }
    }
}

extension View {
    func clayMenuButton(isMenuPresented: Bool, diameter: CGFloat? = nil) -> some View {
        modifier(MenuButtonChromeModifier(isMenuPresented: isMenuPresented, style: .clay, diameter: diameter))
    }

    func ghostMenuButton(isMenuPresented: Bool, diameter: CGFloat? = nil) -> some View {
        modifier(MenuButtonChromeModifier(isMenuPresented: isMenuPresented, style: .ghost, diameter: diameter))
    }
}

/// Plain button style with a gentle press scale (used for the send button and inline actions).
struct PressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

// MARK: - Orb

/// Otto's mark: a small warm-white sphere with a soft glow. Breathes while `isActive`.
struct OttoOrb: View {
    var size: CGFloat
    var isActive: Bool

    init(size: CGFloat = 14, isActive: Bool = false) {
        self.size = size
        self.isActive = isActive
    }

    var body: some View {
        if isActive {
            sphere
                .phaseAnimator([false, true]) { content, expanded in
                    content
                        .scaleEffect(expanded ? 1.1 : 0.9)
                        .opacity(expanded ? 1 : 0.72)
                } animation: { _ in
                    .easeInOut(duration: 1.05)
                }
        } else {
            sphere
        }
    }

    private var sphere: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Theme.orbLight, Theme.orbDark],
                        center: UnitPoint(x: 0.36, y: 0.3),
                        startRadius: 0,
                        endRadius: size * 0.78
                    )
                )
            Circle()
                .fill(Color.white.opacity(0.85))
                .frame(width: size * 0.3, height: size * 0.3)
                .offset(x: -size * 0.15, y: -size * 0.18)
                .blur(radius: size * 0.07)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // A tight, faint glow: at 12 pt a wider one bleeds into the surrounding black and blurs
        // the mark.
        .shadow(color: Theme.orbLight.opacity(isActive ? 0.5 : 0.35), radius: size * 0.25)
        .shadow(color: .black.opacity(0.45), radius: 1.2, x: 0, y: 1)
        .accessibilityHidden(true)
    }
}

// MARK: - Small indicators

/// Three bouncing bars shown in the closed notch's right ear while a reply streams.
struct ActivityEqualizer: View {
    var isAnimating: Bool = true
    var color: Color = Theme.orbLight

    private static let speeds: [Double] = [7.1, 9.3, 6.2]
    private static let phases: [Double] = [0, 1.7, 3.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimating)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: barHeight(index: index, time: time))
                }
            }
            .frame(height: 13)
        }
        .accessibilityLabel("Otto is replying")
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        guard isAnimating else { return 5 }
        let wave = sin(time * Self.speeds[index] + Self.phases[index])
        let wobble = sin(time * Self.speeds[(index + 1) % 3] * 0.43 + Self.phases[index] * 2)
        let value = 0.5 + 0.32 * wave + 0.18 * wobble
        return 3.5 + CGFloat(max(0, min(1, value))) * 9.5
    }
}

/// A small rotating arc; drawn in SwiftUI so it matches the palette and renders in snapshots.
struct MiniSpinner: View {
    var size: CGFloat = 11
    var lineWidth: CGFloat = 1.6
    var color: Color = Theme.textSecondary

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let turns = context.date.timeIntervalSinceReferenceDate / 0.9
            Circle()
                .trim(from: 0.12, to: 0.82)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees((turns - turns.rounded(.down)) * 360))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("In progress")
    }
}

/// Sweeps a soft highlight across the content (e.g. "Thinking…", pending chips).
struct ShimmerModifier: ViewModifier {
    var isActive: Bool = true
    var period: Double = 1.6

    func body(content: Content) -> some View {
        if isActive {
            content
                .overlay {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        let raw = context.date.timeIntervalSinceReferenceDate / period
                        let phase = raw - raw.rounded(.down)
                        GeometryReader { proxy in
                            let width = proxy.size.width
                            let band = max(width * 0.45, 40)
                            LinearGradient(
                                colors: [.clear, Color.white.opacity(0.55), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: band)
                            .offset(x: -band + (width + band) * phase)
                        }
                    }
                    .mask(content)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}

extension View {
    func shimmer(isActive: Bool = true) -> some View {
        modifier(ShimmerModifier(isActive: isActive))
    }
}

/// Three vertical dots (⋮), drawn rather than using an SF Symbol so they match the reference.
struct VerticalDots: View {
    var dotSize: CGFloat = 2.75
    /// Gap between dots; 1.75 pt gives a 4.5 pt center-to-center pitch with 2.75 pt dots.
    var spacing: CGFloat = 1.75
    var color: Color = Color.white.opacity(0.88)

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(color).frame(width: dotSize, height: dotSize)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Icons

/// Resolves and caches application icons by bundle identifier (browser chips).
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]
    private static var misses: Set<String> = []

    static func icon(forBundleID bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        if misses.contains(bundleID) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            misses.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}
