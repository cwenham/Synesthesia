import CoreGraphics
import Foundation

extension TileShape {
    /// Where a horizontal line `y` from the tile's middle meets its right edge, from its middle, for a tile of
    /// `size`.
    public func rightEdge(atY y: CGFloat, size: CGSize) -> CGFloat {
        let (hx, hy) = (size.width / 2, size.height / 2)
        let along = min(max(y, -hy), hy)
        switch self {
        case .rectangle, .receive: return hx
        case .circle: return (hx * hx - along * along).squareRoot()
        // The inverted triangle's right edge runs from its top right corner to its point at the bottom.
        case .filter: return hx * (hy - along) / (2 * hy)
        case .send: return hx - 2 * hx * abs(along) / (2 * hy)
        }
    }

    /// Where a horizontal line `y` from the tile's middle meets its left edge, from its middle.
    public func leftEdge(atY y: CGFloat, size: CGSize) -> CGFloat {
        let (hx, hy) = (size.width / 2, size.height / 2)
        let along = min(max(y, -hy), hy)
        switch self {
        case .rectangle, .send: return -hx
        case .circle: return -(hx * hx - along * along).squareRoot()
        case .filter: return -hx * (hy - along) / (2 * hy)
        case .receive: return -hx + 2 * hx * abs(along) / (2 * hy)
        }
    }

    /// Whether `point`, from the tile's middle, is inside the shape.
    public func contains(_ point: CGPoint, size: CGSize) -> Bool {
        let hy = size.height / 2
        guard abs(point.y) <= hy else { return false }
        return point.x >= leftEdge(atY: point.y, size: size) - 2 && point.x <= rightEdge(atY: point.y, size: size) + 2
    }
}

/// Routes wires as smooth curves that leave and arrive level, through the bends the layout gives.
public enum WireRouter {
    /// The points of a wire from `start` to `end` through `bends`, as cubic curves with level tangents, flattened.
    public static func route(from start: CGPoint, to end: CGPoint, through bends: [CGPoint]) -> [CGPoint] {
        let stops = [start] + bends + [end]
        var points: [CGPoint] = [start]
        for (a, b) in zip(stops, stops.dropFirst()) {
            // A wire going back leftwards still leaves to the right and arrives from the left, looping round.
            let reach = max(abs(b.x - a.x) * 0.5, b.x < a.x ? 60 : 12)
            let c1 = CGPoint(x: a.x + reach, y: a.y)
            let c2 = CGPoint(x: b.x - reach, y: b.y)
            let span = hypot(b.x - a.x, b.y - a.y) + abs(b.y - a.y)
            let steps = min(max(Int(span / 10), 6), 40)
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let u = 1 - t
                let x = u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x
                let y = u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y
                points.append(CGPoint(x: x, y: y))
            }
        }
        return points
    }
}
