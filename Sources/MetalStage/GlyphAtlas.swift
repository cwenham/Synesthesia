import CoreGraphics
import CoreText
import Metal

/// Glyphs as signed distance fields in one texture, made on first use with Core Text, so text is sharp at every
/// zoom from one drawing of each glyph (design, section 7).
@MainActor
final class GlyphAtlas {
    /// The size glyphs are drawn at in the atlas, in pixels to the em.
    static let em: CGFloat = 48
    /// Glyphs are drawn this many times larger to find their outlines, so edges fall between pixels, not on them.
    static let supersample = 4
    /// How far, in texels, distances are kept from each glyph's outline.
    static let spread: CGFloat = 5
    static let side = 2048

    struct Entry {
        /// Where it is in the atlas, from 0 to 1.
        var uvMin: SIMD2<Float>
        var uvMax: SIMD2<Float>
        /// Its box in em pixels: the lower left corner from the glyph's origin, y up, and its size.
        var origin: CGPoint
        var size: CGSize
    }

    private struct Key: Hashable {
        var font: String
        var glyph: CGGlyph
    }

    let texture: MTLTexture
    private var entries: [Key: Entry?] = [:]
    private var fonts: [String: CTFont] = [:]
    // Shelf packing: rows of glyphs, left to right, top to bottom.
    private var shelfX = 1
    private var shelfY = 1
    private var shelfHeight = 0

    init?(device: MTLDevice) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: Self.side, height: Self.side, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "Glyph atlas"
        self.texture = texture
    }

    /// The glyph's place in the atlas, drawing it there first if it's new; nil for one with nothing to draw, such
    /// as a space.
    func entry(for glyph: CGGlyph, in font: CTFont) -> Entry? {
        let name = CTFontCopyPostScriptName(font) as String
        let key = Key(font: name, glyph: glyph)
        if let known = entries[key] { return known }
        let made = draw(glyph, font: atlasFont(named: name, like: font))
        entries[key] = made
        return made
    }

    private func atlasFont(named name: String, like font: CTFont) -> CTFont {
        if let known = fonts[name] { return known }
        let made = CTFontCreateCopyWithAttributes(font, Self.em, nil, nil)
        fonts[name] = made
        return made
    }

    private func draw(_ glyph: CGGlyph, font: CTFont) -> Entry? {
        guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { return nil }
        let bounds = path.boundingBoxOfPath
        guard !bounds.isEmpty, bounds.width > 0, bounds.height > 0 else { return nil }
        let pad = Int(Self.spread) + 1
        let width = Int(bounds.width.rounded(.up)) + pad * 2
        let height = Int(bounds.height.rounded(.up)) + pad * 2
        if shelfX + width + 1 > Self.side {
            shelfX = 1
            shelfY += shelfHeight + 1
            shelfHeight = 0
        }
        guard shelfY + height + 1 <= Self.side else { return nil } // Full: such a glyph isn't drawn.

        // Coverage, drawn larger, top row first, as CGBitmapContext keeps it.
        let f = Self.supersample
        let (bigWidth, bigHeight) = (width * f, height * f)
        var coverage = [UInt8](repeating: 0, count: bigWidth * bigHeight)
        let origin = CGPoint(x: bounds.minX.rounded(.down) - CGFloat(pad), y: bounds.minY.rounded(.down) - CGFloat(pad))
        coverage.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: bigWidth, height: bigHeight, bitsPerComponent: 8, bytesPerRow: bigWidth,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.setFillColor(gray: 1, alpha: 1)
            context.scaleBy(x: CGFloat(f), y: CGFloat(f))
            context.translateBy(x: -origin.x, y: -origin.y)
            context.addPath(path)
            context.fillPath()
        }
        let field = Self.distanceField(coverage, width: bigWidth, height: bigHeight, spread: Self.spread, supersample: f)
        texture.replace(
            region: MTLRegionMake2D(shelfX, shelfY, width, height), mipmapLevel: 0, withBytes: field, bytesPerRow: width
        )
        let side = Float(Self.side)
        let entry = Entry(
            uvMin: SIMD2(Float(shelfX) / side, Float(shelfY) / side),
            uvMax: SIMD2(Float(shelfX + width) / side, Float(shelfY + height) / side),
            origin: origin, size: CGSize(width: width, height: height)
        )
        shelfX += width + 1
        shelfHeight = max(shelfHeight, height)
        return entry
    }

    /// Each pixel's signed distance from the outline, inside positive, as 0.5 plus the distance over twice
    /// `spread`. The coverage is `supersample` times the field's size each way; it's cut at half, and each pixel of
    /// the field takes the mean distance of the four samples at its middle.
    static func distanceField(_ coverage: [UInt8], width: Int, height: Int, spread: CGFloat, supersample f: Int = 1) -> [UInt8] {
        let inside = coverage.map { $0 >= 128 }
        let toOutside = squaredDistances(width: width, height: height) { inside[$0] }
        let toInside = squaredDistances(width: width, height: height) { !inside[$0] }
        func signed(_ index: Int) -> Float {
            inside[index] ? toOutside[index].squareRoot() - 0.5 : -(toInside[index].squareRoot() - 0.5)
        }
        let (fieldWidth, fieldHeight) = (width / f, height / f)
        var field = [UInt8](repeating: 0, count: fieldWidth * fieldHeight)
        for y in 0..<fieldHeight {
            for x in 0..<fieldWidth {
                var distance: Float
                if f == 1 {
                    distance = signed(y * width + x)
                } else {
                    let (cx, cy) = (x * f + f / 2, y * f + f / 2)
                    distance = (signed((cy - 1) * width + cx - 1) + signed((cy - 1) * width + cx)
                        + signed(cy * width + cx - 1) + signed(cy * width + cx)) / 4 / Float(f)
                }
                let value = 0.5 + Double(distance) / (2 * Double(spread))
                field[y * fieldWidth + x] = UInt8(max(0, min(255, (value * 255).rounded())))
            }
        }
        return field
    }

    /// The squared distance from each pixel to the nearest pixel where `isFar` is false, by Felzenszwalb and
    /// Huttenlocher's transform, columns then rows.
    static func squaredDistances(width: Int, height: Int, isFar: (Int) -> Bool) -> [Float] {
        let infinity: Float = 1e12
        var grid = [Float](repeating: 0, count: width * height)
        for index in grid.indices where isFar(index) { grid[index] = infinity }
        let longest = max(width, height)
        var line = [Float](repeating: 0, count: longest)
        var result = [Float](repeating: 0, count: longest)
        var v = [Int](repeating: 0, count: longest)
        var z = [Float](repeating: 0, count: longest + 1)
        grid.withUnsafeMutableBufferPointer { grid in
            line.withUnsafeMutableBufferPointer { line in
                result.withUnsafeMutableBufferPointer { result in
                    v.withUnsafeMutableBufferPointer { v in
                        z.withUnsafeMutableBufferPointer { z in
                            for x in 0..<width {
                                for y in 0..<height { line[y] = grid[y * width + x] }
                                transform(line, count: height, into: result, v: v, z: z)
                                for y in 0..<height { grid[y * width + x] = result[y] }
                            }
                            for y in 0..<height {
                                for x in 0..<width { line[x] = grid[y * width + x] }
                                transform(line, count: width, into: result, v: v, z: z)
                                for x in 0..<width { grid[y * width + x] = result[x] }
                            }
                        }
                    }
                }
            }
        }
        return grid
    }

    /// One dimension of the transform: the lower envelope of parabolas rooted at each sample.
    private static func transform(
        _ f: UnsafeMutableBufferPointer<Float>, count n: Int, into d: UnsafeMutableBufferPointer<Float>,
        v: UnsafeMutableBufferPointer<Int>, z: UnsafeMutableBufferPointer<Float>
    ) {
        guard n > 0 else { return }
        var k = 0
        v[0] = 0
        z[0] = -.infinity
        z[1] = .infinity
        var q = 1
        while q < n {
            let fq = f[q] + Float(q * q)
            var s: Float
            while true {
                let p = v[k]
                s = (fq - (f[p] + Float(p * p))) / Float(2 * (q - p))
                if s <= z[k] { k -= 1 } else { break }
            }
            k += 1
            v[k] = q
            z[k] = s
            z[k + 1] = .infinity
            q += 1
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Float(q) { k += 1 }
            let p = v[k]
            d[q] = Float((q - p) * (q - p)) + f[p]
        }
    }
}
