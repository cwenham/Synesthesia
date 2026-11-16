import CoreGraphics
import simd

/// A colour as the renderer takes it: red, green, blue and alpha from 0 to 1, not premultiplied.
public typealias StageColor = SIMD4<Float>

extension StageColor {
    /// From a hex value such as `0x39D5FF`.
    public init(hex: UInt32, alpha: Float = 1) {
        self.init(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255, alpha)
    }

    public func with(alpha: Float) -> StageColor { StageColor(x, y, z, alpha) }

    /// Mixed toward `other` by `amount`, from 0 (all this) to 1 (all other).
    public func mixed(with other: StageColor, by amount: Float) -> StageColor { self + (other - self) * amount }
}

/// A tile's outline, from what its verb does (the theme notes in the design).
public enum TileShape: Int32, Sendable, CaseIterable {
    /// Rounded rectangle, the default.
    case rectangle = 0
    /// A true source, which makes messages itself.
    case circle = 1
    /// An inverted triangle: a filter, which lets some messages through.
    case filter = 2
    /// Pointing right: sends messages out of the pipeline.
    case send = 3
    /// Pointing left: receives messages from outside.
    case receive = 4
}

/// A module drawn as a tile: a shape with depth, a hatched shadow and an outline in its role's colour.
public struct StageTile: Sendable, Equatable {
    public var id: String
    public var shape: TileShape
    /// The tile's face, in world units; its depth hangs below this.
    public var frame: CGRect
    public var color: StageColor
    /// How far the red flash of a failure has faded, from 1 (just failed) to 0.
    public var flash: Float
    public var isHovered: Bool
    public var isSelected: Bool
    /// Greyed, as for a pipeline that has ended or a host that can't be reached.
    public var isDimmed: Bool

    public init(id: String, shape: TileShape, frame: CGRect, color: StageColor, flash: Float = 0, isHovered: Bool = false, isSelected: Bool = false, isDimmed: Bool = false) {
        self.id = id
        self.shape = shape
        self.frame = frame
        self.color = color
        self.flash = flash
        self.isHovered = isHovered
        self.isSelected = isSelected
        self.isDimmed = isDimmed
    }
}

/// A wire between tiles, as a polyline with the length along it at each point, so particles can be placed on it.
public struct StageWire: Sendable, Equatable {
    public enum Kind: Int32, Sendable {
        case main = 0
        /// Carries only errors, to a module with `@errors`.
        case errors = 1
        /// Goes back against the flow, closing a cycle.
        case backward = 2
    }

    public var id: String
    public var kind: Kind
    public var points: [CGPoint]
    /// The length from the start to each point.
    public var lengths: [CGFloat]
    public var color: StageColor
    public var isHovered: Bool

    public var length: CGFloat { lengths.last ?? 0 }

    public init(id: String, kind: Kind, points: [CGPoint], color: StageColor, isHovered: Bool = false) {
        self.id = id
        self.kind = kind
        self.points = points
        self.color = color
        self.isHovered = isHovered
        var lengths: [CGFloat] = [0]
        for (a, b) in zip(points, points.dropFirst()) { lengths.append(lengths.last! + hypot(b.x - a.x, b.y - a.y)) }
        self.lengths = lengths
    }

    /// The point `distance` along the wire, and the direction it runs there.
    public func point(at distance: CGFloat) -> (point: CGPoint, direction: CGVector) {
        guard points.count > 1 else { return (points.first ?? .zero, CGVector(dx: 1, dy: 0)) }
        let along = min(max(distance, 0), length)
        var low = 0
        var high = lengths.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if lengths[middle] <= along { low = middle } else { high = middle }
        }
        let span = lengths[high] - lengths[low]
        let t = span > 0 ? (along - lengths[low]) / span : 0
        let a = points[low]
        let b = points[high]
        let direction = span > 0 ? CGVector(dx: (b.x - a.x) / span, dy: (b.y - a.y) / span) : CGVector(dx: 1, dy: 0)
        return (CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), direction)
    }

    /// The distance from `point` to the nearest part of the wire.
    public func distance(to point: CGPoint) -> CGFloat {
        var best = CGFloat.infinity
        for (a, b) in zip(points, points.dropFirst()) {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let span = dx * dx + dy * dy
            let t = span > 0 ? min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / span, 0), 1) : 0
            best = min(best, hypot(point.x - (a.x + dx * t), point.y - (a.y + dy * t)))
        }
        return best
    }
}

/// How particles look. They change style where one stops being one message, so you can tell which you're seeing.
public enum ParticleStyle: Int32, Sendable {
    /// One particle is one message: a round dot with a halo.
    case message = 0
    /// Particles show a rate, not single messages: short streaks.
    case rate = 1
    /// Fading as it goes, for messages that end inside a module or spill off it.
    case fading = 2
}

/// Evenly spaced particles moving along a path, drawn on the GPU from the path, a spacing and a running phase, so a
/// million messages a second cost the same to draw as one.
public struct ParticleStream: Sendable, Equatable {
    /// The path, as a wire.
    public var path: StageWire
    /// Distance between particles, in world units.
    public var spacing: CGFloat
    /// How far the first particle is along, from 0 up to ``spacing``.
    public var phase: CGFloat
    public var color: StageColor
    /// Its particles' radius, in world units.
    public var size: CGFloat
    public var style: ParticleStyle

    public init(path: StageWire, spacing: CGFloat, phase: CGFloat, color: StageColor, size: CGFloat, style: ParticleStyle) {
        self.path = path
        self.spacing = spacing
        self.phase = phase
        self.color = color
        self.size = size
        self.style = style
    }

    /// How many particles it has on its path.
    public var count: Int {
        guard spacing > 0, path.length > 0 else { return 0 }
        return Int(((path.length - phase) / spacing).rounded(.down)) + 1
    }
}

/// One particle placed on its own, such as a message on a slow wire or a queued one.
public struct StageParticle: Sendable, Equatable {
    public var position: CGPoint
    /// The way it's heading, for streaks.
    public var direction: CGVector
    public var color: StageColor
    public var size: CGFloat
    public var style: ParticleStyle

    public init(position: CGPoint, direction: CGVector = CGVector(dx: 1, dy: 0), color: StageColor, size: CGFloat, style: ParticleStyle) {
        self.position = position
        self.direction = direction
        self.color = color
        self.size = size
        self.style = style
    }
}

/// A font for the stage's text, from the system's.
public struct StageFont: Sendable, Hashable {
    public enum Weight: Sendable, Hashable { case regular, medium, semibold }

    public var size: CGFloat
    public var weight: Weight
    /// Digits all one width, for numbers that change.
    public var monospacedDigits: Bool

    public init(size: CGFloat, weight: Weight = .regular, monospacedDigits: Bool = false) {
        self.size = size
        self.weight = weight
        self.monospacedDigits = monospacedDigits
    }
}

/// A line of text in world units, aligned left from its origin, which is on its baseline.
public struct StageText: Sendable, Equatable {
    public var string: String
    public var origin: CGPoint
    public var font: StageFont
    public var color: StageColor

    public init(_ string: String, at origin: CGPoint, font: StageFont, color: StageColor) {
        self.string = string
        self.origin = origin
        self.font = font
        self.color = color
    }
}

/// Everything to draw in one frame, independent of the renderer.
public struct StageSnapshot: Sendable {
    public var tiles: [StageTile] = []
    public var wires: [StageWire] = []
    /// Streams along wires, drawn under the tiles.
    public var streams: [ParticleStream] = []
    /// Particles placed one by one, drawn under the tiles.
    public var particles: [StageParticle] = []
    /// Streams and particles drawn over the tiles, such as those ending inside one.
    public var overStreams: [ParticleStream] = []
    public var overParticles: [StageParticle] = []
    public var texts: [StageText] = []
    public var camera = Camera()
    public var background = Theme.background
    /// Seconds on the stage's clock, for anything the renderer animates itself.
    public var time: Double = 0

    public init() {}
}
