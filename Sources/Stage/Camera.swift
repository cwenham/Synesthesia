import CoreGraphics
import Foundation

/// Where the stage is seen from: the world point at the middle of the view, and how many view points a world unit
/// takes.
public struct Camera: Sendable, Equatable {
    public var center: CGPoint
    public var scale: CGFloat

    public static let minimumScale: CGFloat = 0.08
    public static let maximumScale: CGFloat = 6

    public init(center: CGPoint = .zero, scale: CGFloat = 1) {
        self.center = center
        self.scale = scale
    }

    public func viewPoint(_ world: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (world.x - center.x) * scale + size.width / 2, y: (world.y - center.y) * scale + size.height / 2)
    }

    public func worldPoint(_ view: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (view.x - size.width / 2) / scale + center.x, y: (view.y - size.height / 2) / scale + center.y)
    }

    public func viewRect(_ world: CGRect, in size: CGSize) -> CGRect {
        let origin = viewPoint(world.origin, in: size)
        return CGRect(x: origin.x, y: origin.y, width: world.width * scale, height: world.height * scale)
    }

    /// Zoomed by `factor`, keeping the world point under `anchor` (in view points) where it is.
    public func zoomed(by factor: CGFloat, at anchor: CGPoint, in size: CGSize) -> Camera {
        let fixed = worldPoint(anchor, in: size)
        let scale = min(max(scale * factor, Self.minimumScale), Self.maximumScale)
        let center = CGPoint(x: fixed.x - (anchor.x - size.width / 2) / scale, y: fixed.y - (anchor.y - size.height / 2) / scale)
        return Camera(center: center, scale: scale)
    }

    /// Moved by `offset` in view points, as content dragged that far.
    public func panned(by offset: CGVector) -> Camera {
        Camera(center: CGPoint(x: center.x - offset.dx / scale, y: center.y - offset.dy / scale), scale: scale)
    }

    /// The camera that shows all of `rect` in a view of `size`, with a margin, no closer than 1.5 to 1.
    public static func fitting(_ rect: CGRect, in size: CGSize, margin: CGFloat = 48) -> Camera {
        guard rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else {
            return Camera(center: CGPoint(x: rect.midX, y: rect.midY), scale: 1)
        }
        let scale = min((size.width - margin * 2) / rect.width, (size.height - margin * 2) / rect.height, 1.5)
        return Camera(center: CGPoint(x: rect.midX, y: rect.midY), scale: min(max(scale, minimumScale), maximumScale))
    }
}

/// A change eased over time, starting fast and slowing down, as the UX notes ask for changes of scale.
public struct Easing<Value: Sendable>: Sendable {
    public var from: Value
    public var to: Value
    public var start: Double
    public var duration: Double

    public init(from: Value, to: Value, start: Double, duration: Double = 0.9) {
        self.from = from
        self.to = to
        self.start = start
        self.duration = duration
    }

    /// From 0 to 1 at `time`, eased out.
    public func progress(at time: Double) -> Double {
        guard duration > 0 else { return 1 }
        let t = min(max((time - start) / duration, 0), 1)
        return 1 - pow(1 - t, 3)
    }

    public func isDone(at time: Double) -> Bool { time >= start + duration }
}

extension Easing where Value == Camera {
    /// The camera at `time`. The scale eases in its logarithm, so zooming feels even, and the centre follows it.
    public func value(at time: Double) -> Camera {
        let p = CGFloat(progress(at: time))
        let scale = exp(log(from.scale) + (log(to.scale) - log(from.scale)) * p)
        let center = CGPoint(x: from.center.x + (to.center.x - from.center.x) * p, y: from.center.y + (to.center.y - from.center.y) * p)
        return Camera(center: center, scale: scale)
    }
}

extension Easing where Value == CGRect {
    public func value(at time: Double) -> CGRect {
        let p = CGFloat(progress(at: time))
        return CGRect(
            x: from.minX + (to.minX - from.minX) * p, y: from.minY + (to.minY - from.minY) * p,
            width: from.width + (to.width - from.width) * p, height: from.height + (to.height - from.height) * p
        )
    }
}
