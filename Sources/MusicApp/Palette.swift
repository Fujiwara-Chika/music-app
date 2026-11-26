import SwiftUI
import AppKit

/// foobox derives its whole colour scheme from the current album cover
/// (`foobox.color.by.cover`, on by default), which is why the reference
/// screenshot is navy — the cover of DAWN is navy. This mirrors that: the
/// surface ladder keeps its designed luminance, only the hue/saturation follow
/// the artwork, so text contrast never depends on the picture.
struct Palette: Equatable {
    var windowBG: Color
    var rowBG: Color
    var columnHeader: Color
    var albumHeaderBG: Color
    var selection: Color
    var panelBG: Color
    var transportBG: Color
    var separator: Color
    var controlBG: Color
    var accent: Color
    var sliderFill: Color
    var sliderTrack: Color

    /// Cheap identity for `animation(value:)` — `Color` equality is not useful here.
    var token: Int = 0

    static func == (lhs: Palette, rhs: Palette) -> Bool { lhs.token == rhs.token }

    /// The palette the reference screenshot was measured on (DAWN's navy), also
    /// used whenever a track has no artwork to sample. It reads the values from
    /// `Theme` so the sampled colours live in exactly one place.
    static let reference = Palette(
        windowBG: Theme.windowBG,
        rowBG: Theme.rowBG,
        columnHeader: Theme.columnHeader,
        albumHeaderBG: Theme.albumHeaderBG,
        selection: Theme.selection,
        panelBG: Theme.panelBG,
        transportBG: Theme.transportBG,
        separator: Theme.separator,
        controlBG: Theme.controlBG,
        accent: Theme.accent,
        sliderFill: Theme.sliderFill,
        sliderTrack: Theme.sliderTrack,
        token: 0
    )

    /// Fades every large surface by `opacity`, so a translucent window shows the
    /// blurred backdrop underneath. Text, selection and accents keep their weight:
    /// only the big fills get softer.
    func washed(by opacity: Double) -> Palette {
        guard opacity < 0.999 else { return self }
        let soft = max(0.12, opacity)
        var p = self
        p.windowBG = windowBG.opacity(soft)
        p.rowBG = rowBG.opacity(soft)
        // Bands sit *on top of* a pane's own translucent fill, so their alpha
        // stacks: 0.55 under 0.55 is 0.80, which reads as "this strip stayed
        // opaque". Fade them much faster than the base (opacity^6 is 1 at full
        // opacity, so the reference look is untouched, and near 0 at 45%) — the
        // band then tints the base instead of hiding the backdrop.
        let band = pow(opacity, 6)
        p.columnHeader = columnHeader.opacity(band)
        p.albumHeaderBG = albumHeaderBG.opacity(band)
        p.panelBG = panelBG.opacity(soft)
        p.transportBG = transportBG.opacity(soft)
        p.controlBG = controlBG.opacity(soft)
        p.separator = separator.opacity(max(0.5, opacity))
        return p
    }

    // MARK: - Sampling

    private static func saturation(of maxComponent: Double, _ delta: Double) -> Double {
        maxComponent > 0 ? delta / maxComponent : 0
    }

    /// Hue and saturation of the artwork, weighted towards the pixels a person
    /// actually notices: chromatic, mid-bright ones. Near-black and near-white
    /// pixels carry no hue and would wash the result out.
    static func dominantArtworkColor(_ image: NSImage?) -> (hue: Double, saturation: Double)? {
        guard let image,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels,
                                      width: side,
                                      height: side,
                                      bitsPerComponent: 8,
                                      bytesPerRow: side * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Bucket the pixels by hue and take the heaviest bucket, then average
        // inside it. A plain weighted mean would let a large cream background
        // drag a pink cover's cast towards brown.
        let bucketCount = 24
        var bucketWeight = [Double](repeating: 0, count: bucketCount)
        var bucketX = [Double](repeating: 0, count: bucketCount)
        var bucketY = [Double](repeating: 0, count: bucketCount)
        var bucketSaturation = [Double](repeating: 0, count: bucketCount)

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let delta = maxC - minC
            // Below this the pixel is basically grey; letting those in is what
            // turns a pink cover into a brown one.
            guard maxC > 0.08, delta > 0.02, saturation(of: maxC, delta) > 0.18 else { continue }

            var hue = 0.0
            if maxC == r {
                hue = (g - b) / delta
            } else if maxC == g {
                hue = 2 + (b - r) / delta
            } else {
                hue = 4 + (r - g) / delta
            }
            hue /= 6
            if hue < 0 { hue += 1 }

            let pixelSaturation = delta / maxC
            let weight = pixelSaturation * pixelSaturation * pixelSaturation
                * min(1, maxC * 1.6) * (1 - abs(maxC - 0.55))
            guard weight > 0.002 else { continue }

            let bucket = min(bucketCount - 1, Int(hue * Double(bucketCount)))
            bucketWeight[bucket] += weight
            bucketX[bucket] += cos(hue * 2 * .pi) * weight
            bucketY[bucket] += sin(hue * 2 * .pi) * weight
            bucketSaturation[bucket] += pixelSaturation * weight
        }

        guard let best = bucketWeight.indices.max(by: { bucketWeight[$0] < bucketWeight[$1] }),
              bucketWeight[best] > 0 else { return nil }

        // Fold in the neighbouring buckets so a slightly split cluster still
        // averages into one hue.
        var x = 0.0
        var y = 0.0
        var totalWeight = 0.0
        var saturationSum = 0.0
        for offset in [-1, 0, 1] {
            let bucket = (best + offset + bucketCount) % bucketCount
            x += bucketX[bucket]
            y += bucketY[bucket]
            saturationSum += bucketSaturation[bucket]
            totalWeight += bucketWeight[bucket]
        }
        guard totalWeight > 0 else { return nil }

        var hue = atan2(y, x) / (2 * .pi)
        if hue < 0 { hue += 1 }
        return (hue, min(1, max(0, saturationSum / totalWeight)))
    }

    /// Builds the surface ladder around one hue. `value` is the brightness the
    /// reference screenshot shows for each surface, so switching covers keeps
    /// exactly the same contrast while changing the cast.
    static func derive(from image: NSImage?, token: Int? = nil) -> Palette {
        guard let sample = dominantArtworkColor(image) else { return reference }

        let h = sample.hue
        let s = sample.saturation

        func surface(_ saturationScale: Double,
                     _ brightness: Double,
                     minSaturation: Double = 0,
                     maxSaturation: Double = 1) -> Color {
            Color(hue: h,
                  saturation: min(maxSaturation, max(minSaturation, s * saturationScale)),
                  brightness: brightness)
        }

        return Palette(
            windowBG: surface(0.95, 0.26, minSaturation: 0.18, maxSaturation: 0.62),
            rowBG: surface(0.90, 0.28, minSaturation: 0.16, maxSaturation: 0.60),
            columnHeader: surface(0.62, 0.31, minSaturation: 0.12, maxSaturation: 0.52),
            albumHeaderBG: surface(0.70, 0.29, minSaturation: 0.12, maxSaturation: 0.55),
            selection: surface(1.45, 0.57, minSaturation: 0.55, maxSaturation: 0.92),
            panelBG: surface(0.92, 0.23, minSaturation: 0.18, maxSaturation: 0.62),
            transportBG: surface(0.90, 0.27, minSaturation: 0.16, maxSaturation: 0.60),
            separator: surface(0.85, 0.20, minSaturation: 0.15, maxSaturation: 0.55),
            controlBG: surface(0.55, 0.33, minSaturation: 0.10, maxSaturation: 0.45),
            accent: surface(1.10, 0.84, minSaturation: 0.45),
            sliderFill: surface(1.30, 0.62, minSaturation: 0.45),
            sliderTrack: surface(0.85, 0.39, minSaturation: 0.15),
            token: token ?? Self.token(for: h, s)
        )
    }

    private static func token(for hue: Double, _ saturation: Double) -> Int {
        Int(hue * 360) &* 1000 &+ Int(saturation * 100)
    }
}

// MARK: - Environment plumbing

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.reference
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
