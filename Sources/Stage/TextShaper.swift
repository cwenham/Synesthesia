import CoreGraphics
import CoreText
import Foundation

/// One glyph of shaped text: which font and glyph, and where its origin is from the text's origin, in points at the
/// font's size, y down.
public struct ShapedGlyph {
    public var font: CTFont
    public var glyph: CGGlyph
    public var position: CGPoint
}

/// A line of text shaped by Core Text, with fallback fonts for characters the system font lacks.
public struct ShapedText {
    public var width: CGFloat
    public var ascent: CGFloat
    public var descent: CGFloat
    public var glyphs: [ShapedGlyph]
}

/// Shapes and measures the stage's text, so layout measures labels exactly as the renderer will draw them.
@MainActor
public final class TextShaper {
    public static let shared = TextShaper()

    private var fonts: [StageFont: CTFont] = [:]
    private var shaped: [ShapeKey: ShapedText] = [:]

    private struct ShapeKey: Hashable {
        var string: String
        var font: StageFont
    }

    public init() {}

    /// The system font at a size and weight.
    public func font(_ font: StageFont) -> CTFont {
        if let existing = fonts[font] { return existing }
        let base = CTFontCreateUIFontForLanguage(.system, font.size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, font.size, nil)
        let weight: CGFloat = switch font.weight {
        case .regular: 0
        case .medium: 0.23
        case .semibold: 0.3
        }
        var attributes: [CFString: Any] = [kCTFontTraitsAttribute: [kCTFontWeightTrait: weight]]
        if font.monospacedDigits {
            attributes[kCTFontFeatureSettingsAttribute] = [[
                kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector,
            ]]
        }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), attributes as CFDictionary)
        let made = CTFontCreateWithFontDescriptor(descriptor, font.size, nil)
        fonts[font] = made
        return made
    }

    public func shape(_ string: String, font: StageFont) -> ShapedText {
        let key = ShapeKey(string: string, font: font)
        if let existing = shaped[key] { return existing }
        let ctFont = self.font(font)
        let attributed = NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ctFont])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        var glyphs: [ShapedGlyph] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? ctFont
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &ids)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for index in 0..<count {
                glyphs.append(ShapedGlyph(font: runFont, glyph: ids[index], position: CGPoint(x: positions[index].x, y: -positions[index].y)))
            }
        }
        let result = ShapedText(width: width, ascent: ascent, descent: descent, glyphs: glyphs)
        // Rates change all the time, so don't keep every string ever drawn.
        if shaped.count > 4000 { shaped.removeAll(keepingCapacity: true) }
        shaped[key] = result
        return result
    }

    public func width(of string: String, font: StageFont) -> CGFloat {
        shape(string, font: font).width
    }

    /// `string`, cut short with an ellipsis to fit `width`.
    public func truncated(_ string: String, font: StageFont, width: CGFloat) -> String {
        guard self.width(of: string, font: font) > width else { return string }
        var characters = Array(string)
        while !characters.isEmpty {
            characters.removeLast()
            let attempt = String(characters).trimmingCharacters(in: .whitespaces) + "…"
            if self.width(of: attempt, font: font) <= width { return attempt }
        }
        return "…"
    }
}
