import CoreGraphics
import Foundation
import ImageIO

/// A colour of an app's own, in sRGB: the one its icon gave.
nonisolated struct SwatchColor: Codable, Sendable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
}

nonisolated extension SwatchColor {
    static let lightnessRange = 0.52...0.82
    static let minimumChroma = 0.08

    /// The same hue, brought where it reads on a light and on a dark background alike: neither too dark nor too pale,
    /// and never washed out.
    var legible: SwatchColor {
        let lab = OKLab(self)
        let hue = lab.hue
        let lightness = min(max(lab.lightness, Self.lightnessRange.lowerBound), Self.lightnessRange.upperBound)
        let wanted = max(lab.chroma, Self.minimumChroma)
        if OKLab(lightness: lightness, chroma: wanted, hue: hue).isDisplayable {
            return OKLab(lightness: lightness, chroma: wanted, hue: hue).color
        }
        // sRGB cannot show every chroma at every lightness: the widest one it can, found by halving.
        var displayable = 0.0
        var tooWide = wanted
        for _ in 0..<16 {
            let middle = (displayable + tooWide) / 2
            if OKLab(lightness: lightness, chroma: middle, hue: hue).isDisplayable {
                displayable = middle
            } else {
                tooWide = middle
            }
        }
        return OKLab(lightness: lightness, chroma: displayable, hue: hue).color
    }
}

/// A colour as the eye weighs it (Oklab): lightness and chroma move without the hue drifting, which sRGB or HSB
/// components do not allow.
nonisolated struct OKLab: Sendable, Equatable {
    var lightness: Double
    var a: Double
    var b: Double

    var chroma: Double { (a * a + b * b).squareRoot() }
    /// In radians.
    var hue: Double { atan2(b, a) }

    init(lightness: Double, a: Double, b: Double) {
        self.lightness = lightness
        self.a = a
        self.b = b
    }

    init(lightness: Double, chroma: Double, hue: Double) {
        self.init(lightness: lightness, a: chroma * cos(hue), b: chroma * sin(hue))
    }

    init(_ color: SwatchColor) {
        let red = Self.linear(color.red)
        let green = Self.linear(color.green)
        let blue = Self.linear(color.blue)
        let l = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
        let m = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
        let s = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)
        lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    /// Linear sRGB components, which leave 0...1 for a colour no screen in sRGB shows.
    private var linearComponents: (red: Double, green: Double, blue: Double) {
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    var isDisplayable: Bool {
        let (red, green, blue) = linearComponents
        let range = -0.0001...1.0001
        return range.contains(red) && range.contains(green) && range.contains(blue)
    }

    /// The nearest sRGB colour, each component kept within what a screen shows.
    var color: SwatchColor {
        let (red, green, blue) = linearComponents
        return SwatchColor(red: Self.encoded(red), green: Self.encoded(green), blue: Self.encoded(blue))
    }

    private static func linear(_ component: Double) -> Double {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ component: Double) -> Double {
        let clamped = min(max(component, 0), 1)
        return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }
}

/// Finds the colour an icon is remembered by.
nonisolated enum IconColorExtractor {
    static let hueBins = 36
    /// Under this chroma a pixel is white, grey or black: it says nothing of the icon's colour.
    static let neutralChroma = 0.04
    /// An icon whose coloured pixels cover less than this has no colour of its own.
    static let minimumColouredShare = 0.03

    /// The hue that weighs the most in the image, each pixel counting for how vivid it is; nil for an image without
    /// colour. `pixels` holds RGBA bytes with straight alpha; a transparent pixel is not part of the icon.
    static func dominantColor(rgba pixels: [UInt8]) -> SwatchColor? {
        var weights = [Double](repeating: 0, count: hueBins)
        var sums = [OKLab](repeating: OKLab(lightness: 0, a: 0, b: 0), count: hueBins)
        var opaque = 0
        var coloured = 0
        for offset in stride(from: 0, to: pixels.count - 3, by: 4) where pixels[offset + 3] >= 128 {
            opaque += 1
            let lab = OKLab(SwatchColor(
                red: Double(pixels[offset]) / 255, green: Double(pixels[offset + 1]) / 255, blue: Double(pixels[offset + 2]) / 255
            ))
            let chroma = lab.chroma
            guard chroma >= neutralChroma else { continue }
            coloured += 1
            let turn = lab.hue / (2 * .pi) + (lab.hue < 0 ? 1 : 0)
            let bin = min(Int(turn * Double(hueBins)), hueBins - 1)
            weights[bin] += chroma
            sums[bin].lightness += chroma * lab.lightness
            sums[bin].a += chroma * lab.a
            sums[bin].b += chroma * lab.b
        }
        guard opaque > 0, Double(coloured) >= Double(opaque) * minimumColouredShare else { return nil }

        // A hue rarely falls in one bin: its neighbours on both sides count with it.
        func around(_ bin: Int) -> [Int] {
            [(bin + hueBins - 1) % hueBins, bin, (bin + 1) % hueBins]
        }
        guard let winner = weights.indices.max(by: { first, second in
            around(first).reduce(0) { $0 + weights[$1] } < around(second).reduce(0) { $0 + weights[$1] }
        }) else { return nil }
        let bins = around(winner)
        let weight = bins.reduce(0) { $0 + weights[$1] }
        guard weight > 0 else { return nil }
        return OKLab(
            lightness: bins.reduce(0) { $0 + sums[$1].lightness } / weight,
            a: bins.reduce(0) { $0 + sums[$1].a } / weight,
            b: bins.reduce(0) { $0 + sums[$1].b } / weight
        ).color
    }
}

/// Reads an icon's colour from its image file.
nonisolated enum IconColorReader {
    /// The image is counted this small: an icon's colour does not depend on its details.
    static let side = 40

    @concurrent static func color(ofImage data: Data) async -> SwatchColor? {
        pixels(ofImage: data).flatMap(IconColorExtractor.dominantColor(rgba:))
    }

    /// The image drawn small in sRGB, as RGBA bytes with straight alpha.
    static func pixels(ofImage data: Data, side: Int = side) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let base = context.data else { return nil }
        var pixels = [UInt8](UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: side * side * 4))
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for component in offset..<offset + 3 {
                pixels[component] = UInt8(min(255, Int(pixels[component]) * 255 / alpha))
            }
        }
        return pixels
    }
}
