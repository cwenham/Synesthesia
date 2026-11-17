import CoreGraphics
import MeepClient

/// The look from the design's theme notes: bright wireframe colours on an off-black background, tiles with depth
/// like Mahjong tiles, and hatched shadows.
public enum Theme {
    public static let background = StageColor(hex: 0x111216)
    /// The faint dots of the grid behind everything.
    public static let grid = StageColor(hex: 0x23262E)

    /// Each role's colour.
    public static func color(for role: VerbRole?) -> StageColor {
        switch role {
        case .source: StageColor(hex: 0x39D5FF) // cyan
        case .inlet: StageColor(hex: 0x7C8CFF) // periwinkle
        case .filter: StageColor(hex: 0xFF52D9) // magenta
        case .step: StageColor(hex: 0xFFC23D) // amber
        case .outlet: StageColor(hex: 0x6CFF8E) // green
        case nil: StageColor(hex: 0xB8BCC6)
        }
    }

    public static func shape(for role: VerbRole?) -> TileShape {
        switch role {
        case .source: .circle
        case .inlet: .receive
        case .filter: .filter
        case .outlet: .send
        case .step, nil: .rectangle
        }
    }

    public static let error = StageColor(hex: 0xFF4D5E)
    public static let dropped = StageColor(hex: 0xFF9A3D)
    public static let expired = StageColor(hex: 0x8A8F9C)
    /// Wires, dim so their particles stand out.
    public static let wire = StageColor(hex: 0x3A4254)
    public static let errorWire = StageColor(hex: 0x6B2C36)
    public static let dimmed = StageColor(hex: 0x4A4E58)
    /// A module written in lines being mended, while the text doesn't load: white, unlike any role's colour.
    public static let editing = StageColor(hex: 0xF4F6FA)
    /// What a proposal would add or change, waiting for the person to accept it: violet, unlike any role's colour.
    public static let proposed = StageColor(hex: 0xB98CFF)

    public static let title = StageColor(hex: 0xE8EBF0)
    public static let detail = StageColor(hex: 0x8C93A3)

    public static let titleFont = StageFont(size: 13, weight: .semibold)
    public static let detailFont = StageFont(size: 11)
    public static let rateFont = StageFont(size: 11, weight: .medium, monospacedDigits: true)

    /// The tiles' sizes, by shape. All are as tall, so wires between them run straight.
    public static func tileSize(for shape: TileShape) -> CGSize {
        switch shape {
        case .rectangle: CGSize(width: 108, height: tileHeight)
        case .circle: CGSize(width: tileHeight, height: tileHeight)
        case .filter, .send, .receive: CGSize(width: 62, height: tileHeight)
        }
    }

    public static let tileHeight: CGFloat = 52
    /// How far a tile's side shows below its face.
    public static let tileDepth: CGFloat = 6
    /// Where the hatched shadow falls, from the tile.
    public static let shadowOffset = CGVector(dx: 6, dy: 7)
    /// From the bottom of a tile's side to its label's first baseline.
    public static let labelGap: CGFloat = 20
    /// The label's three lines, baseline to baseline.
    public static let lineHeights: [CGFloat] = [0, 15, 14]
    /// Room for the label under a tile.
    public static let labelHeight: CGFloat = 52
    /// The height over which a tile's inputs spread down its left side.
    public static let inputSpan: CGFloat = 28
}
