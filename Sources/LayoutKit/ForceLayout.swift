import CoreGraphics
import Foundation

/// A damped force layout for the mesh (design, section 7): hosts as boxes, pulled together by the flows between them
/// and pushed apart by each other, settling where the forces balance.
///
/// It's deterministic, with no randomness, so the same hosts and flows always settle the same way, and it starts from
/// where things were, so a new flow or host moves the rest as little as it can. Boxes never overlap: a last pass
/// pushes apart any that still would, with `gap` between them. The caller eases from the old places to the new.
public struct ForceLayout: Sendable {
    /// A box to place, with where it was, if it has been placed before.
    public struct Node: Sendable, Equatable {
        public var id: String
        public var size: CGSize
        public var position: CGPoint?

        public init(id: String, size: CGSize, position: CGPoint? = nil) {
            self.id = id
            self.size = size
            self.position = position
        }
    }

    /// A pull between two boxes, stronger for a larger weight, such as a busier flow.
    public struct Edge: Sendable, Equatable {
        public var a: String
        public var b: String
        public var weight: Double

        public init(_ a: String, _ b: String, weight: Double = 1) {
            self.a = a
            self.b = b
            self.weight = weight
        }
    }

    /// Room between boxes, in world units.
    public var gap: CGFloat
    /// How much wider than tall the whole should come out: the pull to the middle is this much stronger up and down.
    public var aspect: CGFloat
    /// Steps of the simulation.
    public var steps: Int

    public init(gap: CGFloat, aspect: CGFloat = 1.7, steps: Int = 300) {
        self.gap = gap
        self.aspect = aspect
        self.steps = steps
    }

    /// Each box's centre once the forces have settled. The whole is centred where the boxes placed before were, or on
    /// the origin.
    public func layOut(_ nodes: [Node], edges: [Edge]) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let count = nodes.count
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        let radii = nodes.map { hypot($0.size.width, $0.size.height) / 2 + gap / 2 }
        let scale = radii.reduce(0, +) / CGFloat(count)

        // Where to start: where each was, and new ones beside what they're pulled to, or on a spiral round the rest.
        var positions = [CGPoint](repeating: .zero, count: count)
        var placed = [Bool](repeating: false, count: count)
        for (i, node) in nodes.enumerated() {
            if let position = node.position {
                positions[i] = position
                placed[i] = true
            }
        }
        let anchor = placed.contains(true) ? centroid(positions.enumerated().filter { placed[$0.offset] }.map(\.element)) : .zero
        var spiral = 0
        for i in 0..<count where !placed[i] {
            let partners = edges.compactMap { edge -> Int? in
                guard let a = index[edge.a], let b = index[edge.b] else { return nil }
                return a == i && placed[b] ? b : b == i && placed[a] ? a : nil
            }
            let golden = 2.399963 * Double(spiral)
            let reach = scale * (partners.isEmpty ? 2 * CGFloat(Double(spiral + 1).squareRoot()) : 2)
            let base = partners.isEmpty ? anchor : centroid(partners.map { positions[$0] })
            positions[i] = CGPoint(x: base.x + reach * CGFloat(cos(golden)) * aspect.squareRoot(), y: base.y + reach * CGFloat(sin(golden)))
            placed[i] = true
            spiral += 1
        }
        let start = centroid(positions)

        var velocities = [CGVector](repeating: .zero, count: count)
        let pairs = edges.compactMap { edge -> (Int, Int, CGFloat)? in
            guard let a = index[edge.a], let b = index[edge.b], a != b else { return nil }
            return (a, b, CGFloat(max(edge.weight, 0.1)))
        }
        for step in 0..<steps {
            // Cooling: no box moves far in one step, and less as it settles, so it comes to rest.
            let temperature = 1 - CGFloat(step) / CGFloat(steps)
            var forces = [CGVector](repeating: .zero, count: count)
            let middle = centroid(positions)
            for i in 0..<count {
                // Apart: boxes push each other once they come within reach, harder the nearer they are.
                for j in stride(from: i + 1, to: count, by: 1) {
                    var dx = positions[j].x - positions[i].x
                    var dy = positions[j].y - positions[i].y
                    var distance = hypot(dx, dy)
                    if distance < 1 {
                        // On top of each other: apart along a direction fixed by their order.
                        let angle = Double(i * 7 + j * 13)
                        dx = CGFloat(cos(angle))
                        dy = CGFloat(sin(angle))
                        distance = 1
                    }
                    let reach = (radii[i] + radii[j]) * 1.25
                    guard distance < reach else { continue }
                    let push = (reach - distance) * 0.5
                    let fx = dx / distance * push
                    let fy = dy / distance * push
                    forces[i].dx -= fx
                    forces[i].dy -= fy
                    forces[j].dx += fx
                    forces[j].dy += fy
                }
                // In: a pull to the middle, stronger up and down, so the whole comes out wider than tall.
                forces[i].dx += (middle.x - positions[i].x) * 0.05
                forces[i].dy += (middle.y - positions[i].y) * 0.05 * aspect
            }
            // Together: each flow pulls its two ends toward being side by side.
            for (a, b, weight) in pairs {
                let dx = positions[b].x - positions[a].x
                let dy = positions[b].y - positions[a].y
                let distance = max(hypot(dx, dy), 1)
                let rest = radii[a] + radii[b]
                guard distance > rest else { continue }
                let pull = (distance - rest) * 0.1 * min(weight, 4)
                let fx = dx / distance * pull
                let fy = dy / distance * pull
                forces[a].dx += fx
                forces[a].dy += fy
                forces[b].dx -= fx
                forces[b].dy -= fy
            }
            // Damped: each step keeps half the last one's velocity.
            let limit = scale * 0.2 * max(temperature, 0.01)
            for i in 0..<count {
                velocities[i].dx = (velocities[i].dx + forces[i].dx) * 0.5
                velocities[i].dy = (velocities[i].dy + forces[i].dy) * 0.5
                let speed = hypot(velocities[i].dx, velocities[i].dy)
                if speed > limit {
                    velocities[i].dx *= limit / speed
                    velocities[i].dy *= limit / speed
                }
                positions[i].x += velocities[i].dx
                positions[i].y += velocities[i].dy
            }
        }

        positions = separated(positions, sizes: nodes.map(\.size))
        // Keep the whole where it started, so adding a host doesn't move the rest across the screen.
        let settled = centroid(positions)
        let target = nodes.contains { $0.position != nil } ? start : .zero
        let shift = CGVector(dx: target.x - settled.x, dy: target.y - settled.y)
        var result: [String: CGPoint] = [:]
        for (i, node) in nodes.enumerated() {
            result[node.id] = CGPoint(x: (positions[i].x + shift.dx).rounded(), y: (positions[i].y + shift.dy).rounded())
        }
        return result
    }

    /// Pushes apart boxes that would overlap, with `gap` between, along whichever way is shorter.
    private func separated(_ input: [CGPoint], sizes: [CGSize]) -> [CGPoint] {
        var positions = input
        for _ in 0..<60 {
            var moved = false
            for i in 0..<positions.count {
                for j in stride(from: i + 1, to: positions.count, by: 1) {
                    let needX = (sizes[i].width + sizes[j].width) / 2 + gap
                    let needY = (sizes[i].height + sizes[j].height) / 2 + gap
                    let dx = positions[j].x - positions[i].x
                    let dy = positions[j].y - positions[i].y
                    let overlapX = needX - abs(dx)
                    let overlapY = needY - abs(dy)
                    guard overlapX > 0.5, overlapY > 0.5 else { continue }
                    moved = true
                    if overlapX / needX < overlapY / needY {
                        let push = overlapX / 2 * (dx < 0 ? -1 : 1)
                        positions[i].x -= push
                        positions[j].x += push
                    } else {
                        let push = overlapY / 2 * (dy < 0 ? -1 : 1)
                        positions[i].y -= push
                        positions[j].y += push
                    }
                }
            }
            if !moved { break }
        }
        return positions
    }

    private func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
}

/// Places endpoints round the edge of a region (design, section 7): each near the angle it would point to, with those
/// of one group side by side, spread so none sits closer than a share of the way round to the next.
public struct EdgeLayout: Sendable {
    public struct Item: Sendable, Equatable {
        public var id: String
        /// Items of one group sit together, in a run round the edge.
        public var group: String
        /// Where it would like to be, as an angle from the region's centre, in radians (0 to the right, clockwise on a
        /// canvas whose y runs down); nil for nowhere in particular.
        public var angle: Double?
        /// How much it matters: when there's no room, the most important keep closest to where they'd like to be.
        public var importance: Double

        public init(id: String, group: String, angle: Double?, importance: Double = 0) {
            self.id = id
            self.group = group
            self.angle = angle
            self.importance = importance
        }
    }

    /// Where an item went: its point, and its angle round the edge.
    public struct Place: Sendable, Equatable {
        public var point: CGPoint
        public var angle: Double
    }

    /// The least room between neighbours, as a share of the whole way round.
    public var spacing: Double

    public init(spacing: Double = 1.0 / 28) {
        self.spacing = spacing
    }

    /// The ellipse through the corners of `region` grown by `margin`, keeping its shape: its centre and radii.
    public static func ellipse(around region: CGRect, margin: CGFloat) -> (center: CGPoint, rx: CGFloat, ry: CGFloat) {
        (CGPoint(x: region.midX, y: region.midY), (region.width / 2 + margin) * CGFloat(2.0.squareRoot()),
         (region.height / 2 + margin) * CGFloat(2.0.squareRoot()))
    }

    /// Places `items` on the ellipse through the corners of `region` grown by `margin`.
    public func layOut(_ items: [Item], around region: CGRect, margin: CGFloat) -> [String: Place] {
        guard !items.isEmpty else { return [:] }
        let (center, rx, ry) = Self.ellipse(around: region, margin: margin)
        let tau = 2 * Double.pi

        // Each group is a run of its items, in order of where they'd like to be, then their names, and would like to be
        // centred on its items' mean angle.
        var members: [String: [Item]] = [:]
        for item in items { members[item.group, default: []].append(item) }
        func mean(_ angles: [Double]) -> Double? {
            guard !angles.isEmpty else { return nil }
            let x = angles.reduce(0) { $0 + cos($1) }
            let y = angles.reduce(0) { $0 + sin($1) }
            return abs(x) < 1e-9 && abs(y) < 1e-9 ? angles[0] : atan2(y, x)
        }
        let step = min(spacing, 1 / Double(items.count)) * tau
        struct Run { var name: String; var wants: Double?; var items: [Item]; var start = 0.0; var width: Double }
        var runs = members.map { name, group -> Run in
            let wants = mean(group.compactMap(\.angle))
            let ordered = group.sorted {
                let a = $0.angle.map { offset($0, from: wants ?? 0) } ?? 10, b = $1.angle.map { offset($0, from: wants ?? 0) } ?? 10
                return a != b ? a < b : $0.id < $1.id
            }
            return Run(name: name, wants: wants.map(normalized), items: ordered, width: Double(group.count) * step)
        }
        .sorted { ($0.wants ?? 10, $0.name) < ($1.wants ?? 10, $1.name) }

        // Runs that would like to be nowhere in particular go after the rest. Then each run starts where it would be
        // centred, pushed on past the one before, all the way round once; and where the last would run into the first
        // round the back, pushed back again, until they fit.
        var cursor = 0.0
        for index in runs.indices {
            let wanted = (runs[index].wants ?? cursor + runs[index].width / 2) - runs[index].width / 2
            runs[index].start = index == 0 ? wanted : max(wanted, cursor)
            cursor = runs[index].start + runs[index].width
        }
        let total = runs.reduce(0) { $0 + $1.width }
        if total <= tau, runs.count > 1 {
            for _ in 0..<20 {
                guard let first = runs.first, let last = runs.last, last.start + last.width > first.start + tau + 1e-9 else { break }
                // Backward: each run ends where the next starts, the last where the first starts, once round.
                var limit = first.start + tau
                for index in runs.indices.reversed() {
                    runs[index].start = min(runs[index].start, limit - runs[index].width)
                    limit = runs[index].start
                }
                // Forward again, keeping order.
                for index in runs.indices.dropFirst() {
                    runs[index].start = max(runs[index].start, runs[index - 1].start + runs[index - 1].width)
                }
            }
        }
        // The whole turned to sit as near as it can to where the runs wanted, weighed by how much their items matter.
        var turn = 0.0
        var weight = 0.0
        for run in runs {
            guard let wants = run.wants else { continue }
            let importance = run.items.reduce(0) { $0 + $1.importance } + 1
            let centre = run.start + run.width / 2
            turn += atan2(sin(wants - centre), cos(wants - centre)) * importance
            weight += importance
        }
        if weight > 0 { turn /= weight }
        let span = (runs.last.map { $0.start + $0.width } ?? 0) - (runs.first?.start ?? 0)
        if span > tau {
            // More than goes round once: squeezed evenly.
            let squeeze = tau / span
            let first = runs.first?.start ?? 0
            for index in runs.indices { runs[index].start = first + (runs[index].start - first) * squeeze }
        }
        let squeeze = span > tau ? tau / span : 1

        var result: [String: Place] = [:]
        for run in runs {
            for (offset, item) in run.items.enumerated() {
                let theta = run.start + turn + (Double(offset) + 0.5) * step * squeeze
                result[item.id] = Place(point: CGPoint(x: center.x + rx * CGFloat(cos(theta)), y: center.y + ry * CGFloat(sin(theta))), angle: normalized(theta))
            }
        }
        return result
    }

    /// The angle `angle` is past `origin`, from -π to π.
    private func offset(_ angle: Double, from origin: Double) -> Double {
        atan2(sin(angle - origin), cos(angle - origin))
    }

    private func normalized(_ angle: Double) -> Double {
        let tau = 2 * Double.pi
        let value = angle.truncatingRemainder(dividingBy: tau)
        return value < 0 ? value + tau : value
    }
}
