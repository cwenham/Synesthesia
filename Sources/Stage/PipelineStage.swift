import ContinuumKit
import CoreGraphics
import FlowKit
import Foundation
import LayoutKit
import MeepClient
import Observation

/// Something on the stage under the pointer.
public enum StageHit: Hashable, Sendable {
    /// A module's tile, by its key.
    case tile(String)
    /// A link's wire, by its key.
    case wire(String)
}

/// Keys held with a click.
public struct StageModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = StageModifiers(rawValue: 1)
    public static let shift = StageModifiers(rawValue: 2)
}

/// An element for VoiceOver: what it is and where it's shown, in view points.
public struct StageAccessibilityItem: Sendable, Equatable {
    public var hit: StageHit
    public var label: String
    public var frame: CGRect
}

/// One pipeline as a stage: its modules as tiles laid out left to right, its links as wires, and particles from its
/// live counts. A renderer asks it for a ``StageSnapshot`` each frame; a canvas sends it the pointer and gestures.
///
/// It reads the model each frame rather than being told of changes, so it's always drawing the latest counts.
/// Only what SwiftUI shows beside the canvas (what's hovered and selected) is observable.
@MainActor @Observable
public final class PipelineStage {
    public let pipeline: MeepPipeline
    public let host: MeepHost?

    /// What the pointer is over.
    public private(set) var hovered: StageHit?
    /// Where the pointer is, in view points.
    public private(set) var pointer: CGPoint = .zero
    /// The selected modules, by key.
    public private(set) var selection: Set<String> = []

    @ObservationIgnored private var tiles: [String: PlacedTile] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var bends: [String: [CGPoint]] = [:]
    @ObservationIgnored private var oldBends: [String: [CGPoint]] = [:]
    @ObservationIgnored private var backward: Set<String> = []
    @ObservationIgnored private var bounds: CGRect = .zero
    @ObservationIgnored private var signature = ""
    @ObservationIgnored private var moving: Easing<Double>?
    @ObservationIgnored private var wires: [String: StageWire] = [:]
    @ObservationIgnored private var wiresNeedRouting = true

    @ObservationIgnored private var camera = Camera()
    @ObservationIgnored private var cameraEasing: Easing<Camera>?
    /// Whether the person has moved the camera; until they do, it follows the layout.
    @ObservationIgnored private var cameraMoved = false
    @ObservationIgnored private var fitted = false
    @ObservationIgnored private var viewSize: CGSize = .zero
    @ObservationIgnored private var time: Double = 0

    @ObservationIgnored private var wireFlows: [String: WireFlows] = [:]
    @ObservationIgnored private var tileFlows: [String: TileFlows] = [:]

    private struct PlacedTile {
        var shape: TileShape
        var size: CGSize
        /// The node's frame from the layout: the tile at its top left, its label below.
        var frame: CGRect
        var from: CGRect?
        var color: StageColor
        var title: String
        var detail: String
    }

    private struct WireFlows {
        var messages = Flow()
        var errors = Flow()
    }

    private struct TileFlows {
        var heldBack = Flow()
        var dropped = Flow()
        var expired = Flow()
        var failures: Int64?
        var flashed: Double = -10
    }

    public init(pipeline: MeepPipeline, host: MeepHost?) {
        self.pipeline = pipeline
        self.host = host
    }

    /// Whether the counts are live: the host can be reached and the pipeline is running.
    public var isCurrent: Bool {
        (host?.isReachable ?? true) && pipeline.state.isLive
    }

    // MARK: Each frame

    /// Everything to draw at `time`, in seconds on a steady clock, in a view of `size` points.
    public func frame(at time: Double, viewSize size: CGSize) -> StageSnapshot {
        let elapsed = self.time == 0 ? 0 : min(max(time - self.time, 0), 0.1)
        self.time = time
        if size != viewSize {
            viewSize = size
            if !cameraMoved, fitted { camera = Camera.fitting(bounds, in: size) }
        }
        layOutIfChanged()
        if !fitted, !tiles.isEmpty, size.width > 0 {
            camera = Camera.fitting(bounds, in: size)
            fitted = true
        }
        if let easing = cameraEasing {
            camera = easing.value(at: time)
            if easing.isDone(at: time) { cameraEasing = nil }
        }

        var snapshot = StageSnapshot()
        snapshot.camera = camera
        snapshot.time = time
        let current = isCurrent
        let progress = moving.map { CGFloat($0.progress(at: time)) } ?? 1
        if let moving, moving.isDone(at: time) {
            self.moving = nil
            for key in tiles.keys { tiles[key]?.from = nil }
            oldBends = [:]
            wiresNeedRouting = true
        }
        if moving != nil { wiresNeedRouting = true }

        // Tiles.
        var faces: [String: CGRect] = [:]
        for key in order {
            guard let tile = tiles[key] else { continue }
            let node = tile.from.map { mix($0, tile.frame, progress) } ?? tile.frame
            let face = CGRect(origin: node.origin, size: tile.size)
            faces[key] = face
        }

        // Wires, routed again only when tiles have moved.
        if wiresNeedRouting {
            route(faces: faces, progress: progress)
            wiresNeedRouting = moving != nil
        }
        for link in pipeline.links {
            guard var wire = wires[link.key] else { continue }
            wire.isHovered = hovered == .wire(link.key)
            if !current { wire.color = Theme.dimmed.with(alpha: 0.6) }
            snapshot.wires.append(wire)
        }

        // Particles along the wires.
        for link in pipeline.links {
            guard let wire = wires[link.key] else { continue }
            var flows = wireFlows[link.key] ?? WireFlows()
            let counts = counts(of: link)
            let color = particleColor(from: link.from)
            if current {
                flows.messages.observe(counts.messages, rate: counts.messageRate, at: time)
                flows.errors.observe(counts.errors, rate: counts.errorRate, at: time)
            } else {
                flows.messages.stop()
                flows.errors.stop()
            }
            flows.messages.advance(to: time, by: elapsed, rate: counts.messageRate, length: wire.length)
            flows.errors.advance(to: time, by: elapsed, rate: counts.errorRate, length: wire.length)
            add(flows.messages.draw(on: wire, rate: counts.messageRate, at: time, color: color), to: &snapshot, over: false)
            add(flows.errors.draw(on: wire, rate: counts.errorRate, at: time, color: Theme.error), to: &snapshot, over: false)
            wireFlows[link.key] = flows
        }

        // Tiles, with what ends inside them, spills off them, and waits at them.
        for key in order {
            guard let tile = tiles[key], let face = faces[key], let module = pipeline.module(key) else { continue }
            var flows = tileFlows[key] ?? TileFlows()
            let failures = module.counts.failed + module.counts.refused
            if current, let before = flows.failures, failures > before { flows.flashed = time }
            flows.failures = failures
            let flash = Float(max(0, 1 - (time - flows.flashed) / 0.7))

            let center = CGPoint(x: face.midX, y: face.midY)
            let inlet = CGPoint(x: center.x + tile.shape.leftEdge(atY: 0, size: tile.size) + 2, y: center.y)
            if module.role == .filter {
                let path = StageWire(id: "\(key).held", kind: .main, points: [inlet, CGPoint(x: center.x, y: center.y - 4)], color: .zero)
                drawTileFlow(&flows.heldBack, count: module.counts.heldBack, rate: module.rates[.heldBack], path: path,
                             color: tile.color, current: current, elapsed: elapsed, into: &snapshot)
            }
            let bottom = CGPoint(x: center.x + 6, y: face.maxY + Theme.tileDepth - 2)
            let spill = StageWire(id: "\(key).dropped", kind: .main, points: WireRouter.route(
                from: bottom, to: CGPoint(x: bottom.x + 26, y: bottom.y + 34), through: []), color: .zero)
            drawTileFlow(&flows.dropped, count: module.counts.dropped, rate: module.rates[.dropped], path: spill,
                         color: Theme.dropped, current: current, elapsed: elapsed, into: &snapshot)
            let top = CGPoint(x: center.x - 8, y: face.minY + 4)
            let rise = StageWire(id: "\(key).expired", kind: .main, points: [top, CGPoint(x: top.x - 6, y: top.y - 30)], color: .zero)
            drawTileFlow(&flows.expired, count: module.counts.expired, rate: module.rates[.expired], path: rise,
                         color: Theme.expired, current: current, elapsed: elapsed, into: &snapshot)
            tileFlows[key] = flows

            if module.counts.queued > 0 {
                pile(module.counts.queued, at: inlet, color: tile.color.with(alpha: current ? 0.9 : 0.4), owner: "\(key).queued", into: &snapshot)
            }

            snapshot.tiles.append(StageTile(
                id: key, shape: tile.shape, frame: face, color: current ? tile.color : Theme.dimmed.mixed(with: tile.color, by: 0.25),
                flash: current ? flash : 0, isHovered: hovered == .tile(key), isSelected: selection.contains(key), isDimmed: !current
            ))
            addLabel(for: module, tile: tile, face: face, current: current, into: &snapshot)
        }
        return snapshot
    }

    // MARK: Layout

    /// Lays the pipeline out again when its modules or links change, easing tiles from where they were.
    private func layOutIfChanged() {
        let keys = pipeline.modules.map(\.key)
        let signature = keys.joined(separator: ",") + "|" + pipeline.links.map(\.key).joined(separator: ",")
            + "|" + pipeline.modules.map { "\($0.role?.rawValue ?? "")\($0.label)" }.joined(separator: ",")
        guard signature != self.signature else { return }
        self.signature = signature
        let shaper = TextShaper.shared
        var nodes: [LayoutGraph.Node] = []
        var made: [String: PlacedTile] = [:]
        for module in pipeline.modules {
            let shape = Theme.shape(for: module.role)
            let size = Theme.tileSize(for: shape)
            let title = shaper.truncated(module.label, font: Theme.titleFont, width: 180)
            let detail = shaper.truncated(detailText(for: module), font: Theme.detailFont, width: 180)
            let labelWidth = max(shaper.width(of: title, font: Theme.titleFont), shaper.width(of: detail, font: Theme.detailFont), 64)
            let nodeSize = CGSize(width: max(size.width, labelWidth), height: Theme.tileHeight + Theme.tileDepth + Theme.labelHeight)
            nodes.append(LayoutGraph.Node(id: module.key, size: nodeSize))
            made[module.key] = PlacedTile(
                shape: shape, size: size, frame: CGRect(origin: .zero, size: nodeSize), from: nil,
                color: Theme.color(for: module.role), title: title, detail: detail
            )
        }
        let edges = pipeline.links.map { LayoutGraph.Edge(id: $0.key, from: $0.from, to: $0.to, input: $0.input) }
        var layout = LayeredLayout()
        layout.columnAlignment = .leading
        layout.inputSpan = Theme.inputSpan
        // Earlier places as hints, by the middle of each tile.
        let previous = tiles.mapValues { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
        let result = layout.layout(LayoutGraph(nodes: nodes, edges: edges), previous: previous)

        let hadTiles = !tiles.isEmpty
        oldBends = hadTiles ? bends : [:]
        for (key, frame) in result.frames {
            made[key]?.frame = frame
            if hadTiles, let before = tiles[key] {
                // Moves are eased, from where the tile is drawn now.
                let drawnAt = before.from.map { mix($0, before.frame, CGFloat(moving?.progress(at: time) ?? 1)) } ?? before.frame
                made[key]?.from = drawnAt
            }
        }
        tiles = made
        order = pipeline.modules.map(\.key)
        bends = result.bends
        backward = result.backward
        bounds = result.bounds
        wiresNeedRouting = true
        wireFlows = wireFlows.filter { key, _ in pipeline.link(key) != nil }
        tileFlows = tileFlows.filter { key, _ in made[key] != nil }
        if hadTiles {
            moving = Easing(from: 0, to: 1, start: time, duration: 0.8)
            if !cameraMoved, viewSize.width > 0 {
                cameraEasing = Easing(from: camera, to: Camera.fitting(bounds, in: viewSize), start: time)
            }
        }
    }

    private func detailText(for module: MeepModule) -> String {
        let graphModule = pipeline.graph?.modules.first { $0.key == module.key }
        let parameter = graphModule?.parameters.first?.text
        let modifiers = graphModule?.modifiers.map { "@\($0.name)" } ?? []
        var parts: [String] = []
        // An unnamed module's title is its verb and number already.
        if module.name != nil { parts.append(module.verb) }
        if let parameter { parts.append(parameter) }
        parts += modifiers
        return parts.joined(separator: " ")
    }

    /// Routes each wire from its source's right edge to its input on the target's left edge, through its bends.
    private func route(faces: [String: CGRect], progress: CGFloat) {
        var routed: [String: StageWire] = [:]
        for link in pipeline.links {
            guard let fromFace = faces[link.from], let toFace = faces[link.to],
                  let fromTile = tiles[link.from], let toTile = tiles[link.to] else { continue }
            let inputs = pipeline.links.filter { $0.to == link.to }.map(\.input).max() ?? 1
            let offset = LayeredLayout.inputOffset(input: link.input, of: inputs, span: Theme.inputSpan, spacing: 14)
            // Ends just inside the shapes, under the tiles, so no gap shows.
            let start = CGPoint(x: fromFace.midX + fromTile.shape.rightEdge(atY: 0, size: fromTile.size) - 3, y: fromFace.midY)
            let end = CGPoint(x: toFace.midX + toTile.shape.leftEdge(atY: offset, size: toTile.size) + 3, y: toFace.midY + offset)
            var through = bends[link.key] ?? []
            // Bends from the layout are where the tiles' nodes' middles go; tiles sit at their top, so shift them up.
            let shift = (Theme.tileHeight + Theme.tileDepth + Theme.labelHeight) / 2 - Theme.tileHeight / 2
            through = through.map { CGPoint(x: $0.x, y: $0.y - shift) }
            if progress < 1, let old = oldBends[link.key], old.count == through.count {
                through = zip(old, through).map { o, n in
                    let o = CGPoint(x: o.x, y: o.y - shift)
                    return CGPoint(x: o.x + (n.x - o.x) * progress, y: o.y + (n.y - o.y) * progress)
                }
            }
            let kind: StageWire.Kind = backward.contains(link.key) ? .backward : (link.port == .errors ? .errors : .main)
            routed[link.key] = StageWire(
                id: link.key, kind: kind, points: WireRouter.route(from: start, to: end, through: through),
                color: kind == .errors ? Theme.errorWire : Theme.wire
            )
        }
        wires = routed
    }

    // MARK: Particles

    private struct LinkCounts {
        var messages: Int64
        var errors: Int64
        var messageRate: Double
        var errorRate: Double
    }

    /// What a link carried: its own counts, or for a daemon too old to count links, what its module received.
    private func counts(of link: MeepLink) -> LinkCounts {
        if link.isCounted {
            return LinkCounts(
                messages: link.carried - link.errors, errors: link.errors,
                messageRate: max(link.rate - link.errorRate, 0), errorRate: link.errorRate
            )
        }
        let single = pipeline.links.filter { $0.to == link.to }.count == 1
        guard single, link.port == .main, let target = pipeline.module(link.to) else {
            return LinkCounts(messages: 0, errors: 0, messageRate: 0, errorRate: 0)
        }
        return LinkCounts(messages: target.counts.received, errors: 0, messageRate: target.rates[.received], errorRate: 0)
    }

    private func particleColor(from key: String) -> StageColor {
        let base = tiles[key]?.color ?? Theme.title
        return base.mixed(with: StageColor(1, 1, 1, 1), by: 0.35)
    }

    private func drawTileFlow(
        _ flow: inout Flow, count: Int64, rate: Double, path: StageWire, color: StageColor, current: Bool,
        elapsed: Double, into snapshot: inout StageSnapshot
    ) {
        if current { flow.observe(count, rate: rate, at: time) } else { flow.stop() }
        flow.advance(to: time, by: elapsed, rate: rate, length: path.length)
        add(flow.draw(on: path, rate: rate, at: time, color: color, fading: true), to: &snapshot, over: true)
    }

    private func add(_ drawn: (stream: ParticleStream?, particles: [StageParticle]), to snapshot: inout StageSnapshot, over: Bool) {
        if over {
            if let stream = drawn.stream { snapshot.overStreams.append(stream) }
            snapshot.overParticles += drawn.particles
        } else {
            if let stream = drawn.stream { snapshot.streams.append(stream) }
            snapshot.particles += drawn.particles
        }
    }

    /// Messages waiting at a module, heaped on the wire at its input: one dot each up to 8, then more slowly.
    private func pile(_ queued: Int64, at inlet: CGPoint, color: StageColor, owner: String, into snapshot: inout StageSnapshot) {
        let dots = Self.pileSize(for: queued)
        let perRow = 5
        for index in 0..<dots {
            let row = index / perRow
            let column = index % perRow
            let x = inlet.x - 9 - CGFloat(column) * 5.4 - CGFloat(row) * 2.7
            let y = inlet.y - CGFloat(row) * 4.6
            snapshot.overParticles.append(StageParticle(position: CGPoint(x: x, y: y), color: color, size: 2.1, style: .message, owner: owner))
        }
    }

    /// How many dots show `queued` messages.
    public nonisolated static func pileSize(for queued: Int64) -> Int {
        guard queued > 8 else { return Int(max(queued, 0)) }
        return min(8 + Int(4 * log2(Double(queued) / 8)), 30)
    }

    // MARK: Labels

    private func addLabel(for module: MeepModule, tile: PlacedTile, face: CGRect, current: Bool, into snapshot: inout StageSnapshot) {
        // Text too small to read isn't drawn.
        let x = face.minX
        var y = face.maxY + Theme.tileDepth + Theme.labelGap
        if camera.scale * Theme.titleFont.size >= 4.5 {
            snapshot.texts.append(StageText(tile.title, at: CGPoint(x: x, y: y), font: Theme.titleFont, color: current ? Theme.title : Theme.detail, tile: module.key))
        }
        y += Theme.lineHeights[1]
        guard camera.scale * Theme.detailFont.size >= 5.5 else { return }
        snapshot.texts.append(StageText(tile.detail, at: CGPoint(x: x, y: y), font: Theme.detailFont, color: Theme.detail, tile: module.key))
        y += Theme.lineHeights[2]
        guard current else { return }
        var rate = StageFormat.rate(module.role == .source || module.counts.received == 0 && module.counts.emitted > 0
            ? module.rates[.emitted] : module.rates[.received])
        if module.counts.queued > 0 { rate += ", \(StageFormat.count(module.counts.queued)) queued" }
        snapshot.texts.append(StageText(rate, at: CGPoint(x: x, y: y), font: Theme.rateFont, color: tile.color, tile: module.key))
    }

    // MARK: Pointer and gestures

    /// What's at `point`, in view points: a tile (or its label) before a wire.
    public func hit(at point: CGPoint) -> StageHit? {
        let world = camera.worldPoint(point, in: viewSize)
        for key in order.reversed() {
            guard let tile = tiles[key] else { continue }
            let face = CGRect(origin: tile.frame.origin, size: tile.size)
            let local = CGPoint(x: world.x - face.midX, y: world.y - face.midY)
            if tile.shape.contains(local, size: tile.size) { return .tile(key) }
            let label = CGRect(x: tile.frame.minX, y: face.maxY + Theme.tileDepth, width: tile.frame.width, height: Theme.labelHeight)
            if label.contains(world) { return .tile(key) }
        }
        let reach = 5 / camera.scale + 1
        var best: (key: String, distance: CGFloat)?
        for (key, wire) in wires {
            let distance = wire.distance(to: world)
            if distance <= reach, distance < best?.distance ?? .infinity { best = (key, distance) }
        }
        return best.map { .wire($0.key) }
    }

    public func hover(at point: CGPoint?) {
        guard let point else {
            if hovered != nil { hovered = nil }
            return
        }
        pointer = point
        let hit = hit(at: point)
        if hit != hovered { hovered = hit }
    }

    /// A click: selects the tile under it, or clears the selection. ⌘ adds or removes one tile, as in Finder.
    public func click(at point: CGPoint, modifiers: StageModifiers = []) {
        guard case .tile(let key)? = hit(at: point) else {
            if !modifiers.contains(.command) { selection = [] }
            return
        }
        if modifiers.contains(.command) {
            if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
        } else {
            selection = [key]
        }
    }

    /// Scrolling moves the view, as content dragged by `offset` view points.
    public func pan(by offset: CGVector) {
        cameraEasing = nil
        cameraMoved = true
        camera = camera.panned(by: offset)
    }

    /// Pinching zooms around the pointer, following the fingers.
    public func zoom(by factor: CGFloat, at point: CGPoint) {
        cameraEasing = nil
        cameraMoved = true
        camera = camera.zoomed(by: factor, at: point, in: viewSize)
    }

    /// Zooms in or out a step around the middle, eased.
    public func step(zoomingIn: Bool) {
        let target = (cameraEasing?.to ?? camera).zoomed(by: zoomingIn ? 1.5 : 1 / 1.5, at: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2), in: viewSize)
        cameraMoved = true
        cameraEasing = Easing(from: camera, to: target, start: time)
    }

    /// Shows the whole pipeline, eased, and follows its layout again.
    public func fit() {
        cameraMoved = false
        cameraEasing = Easing(from: camera, to: Camera.fitting(bounds, in: viewSize), start: time)
    }

    /// The camera now, for tests and overlays.
    public var currentCamera: Camera { camera }

    /// The size of the view it was last drawn in, in points.
    public var currentViewSize: CGSize { viewSize }

    /// Shows a module: selects its tile and eases the camera to centre it, close enough to read.
    @discardableResult
    public func show(_ key: String) -> Bool {
        guard let tile = tiles[key] else { return false }
        selection = [key]
        let middle = CGPoint(x: tile.frame.minX + tile.size.width / 2, y: tile.frame.minY + tile.frame.height / 2)
        let target = Camera(center: middle, scale: min(max((cameraEasing?.to ?? camera).scale, 1), Camera.maximumScale))
        cameraMoved = true
        cameraEasing = Easing(from: camera, to: target, start: time)
        return true
    }

    /// The modules it has tiles for, by key, in the order they're written.
    public var tileKeys: [String] { order }

    /// Whether it has been laid out, so it has tiles to show.
    public var isLaidOut: Bool { !tiles.isEmpty }

    /// Where a tile's face is shown, in view points.
    public func viewFrame(of key: String) -> CGRect? {
        guard let tile = tiles[key] else { return nil }
        return camera.viewRect(CGRect(origin: tile.frame.origin, size: tile.size), in: viewSize)
    }

    /// Tiles and wires for VoiceOver, with what each is doing.
    public func accessibilityItems() -> [StageAccessibilityItem] {
        var items: [StageAccessibilityItem] = []
        for module in pipeline.modules {
            guard let frame = viewFrame(of: module.key) else { continue }
            let role = module.role?.rawValue ?? "module"
            let rate = isCurrent ? ", \(StageFormat.rate(module.rates[.received])) in" : ""
            items.append(StageAccessibilityItem(hit: .tile(module.key), label: "\(module.label), \(module.verb) \(role)\(rate)", frame: frame))
        }
        for link in pipeline.links {
            guard let wire = wires[link.key], let from = pipeline.module(link.from), let to = pipeline.module(link.to) else { continue }
            let box = wire.points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            let rate = isCurrent ? ", \(StageFormat.rate(link.rate))" : ""
            items.append(StageAccessibilityItem(
                hit: .wire(link.key), label: "Wire from \(from.label) to \(to.label)\(link.port == .errors ? ", errors only" : "")\(rate)",
                frame: camera.viewRect(box.insetBy(dx: -2, dy: -2), in: viewSize)
            ))
        }
        return items
    }

    private func mix(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t, width: b.width, height: b.height)
    }
}
