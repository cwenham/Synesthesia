import ContinuumKit
import CoreGraphics
import FlowKit
import LayoutKit
import Foundation
import MeepClient
import Observation

/// Something on the Continuum's canvas under the pointer.
public enum ContinuumHit: Hashable, Sendable {
    /// A host's plate or node, by its name.
    case host(String)
    /// A pipeline's plate, by its address.
    case pipeline(MeepAddress)
    /// A tile or wire of a pipeline drawn in full.
    case inside(MeepAddress, StageHit)
    /// A flow between pipelines, by its ``MeshFlow/id``, or between hosts drawn as nodes, as `hosts:<from>><to>`.
    case flow(String)
    /// An endpoint on the boundary, by its ``BoundaryEndpoint/id``.
    case endpoint(String)

    /// The address of what was hit: a host, a pipeline, or a module; nil for a flow or the boundary.
    public var address: MeepAddress? {
        switch self {
        case .host(let name): MeepAddress(host: name)
        case .pipeline(let address): address
        case .inside(let address, .tile(let key)): address.module(key)
        case .inside(let address, .wire): address
        case .flow, .endpoint: nil
        }
    }

    /// What was hit, in words: an address, or a flow's or endpoint's ID.
    public var description: String {
        switch self {
        case .flow(let id): "flow \(id)"
        case .endpoint(let id): "boundary \(id)"
        default: address?.description ?? ""
        }
    }
}

/// The levels of the zoom ladder the canvas draws (design, section 2): 3 to 6.
public enum ZoomLevel: String, Sendable, Comparable {
    /// The edge of the Continuum: hosts as nodes, and the endpoints outside Meep round them.
    case boundary
    /// Hosts as plates with their pipelines on them, and the flows between them.
    case mesh
    /// One host's pipelines as districts.
    case host
    /// One pipeline's modules as tiles.
    case pipeline

    private var rank: Int { self == .boundary ? -1 : self == .mesh ? 0 : self == .host ? 1 : 2 }
    public static func < (a: ZoomLevel, b: ZoomLevel) -> Bool { a.rank < b.rank }
}

/// The whole Continuum as one stage, in one continuous zoom like a map (design, section 2, Q1): zoomed out, each host
/// is a node of the mesh; closer, a plate with its pipelines on it as districts, packed by size; closer still, each
/// district shows its pipeline's tiles, wires and particles, drawn by the pipeline's own ``PipelineStage`` in the same
/// world and through the same camera, so nothing jumps between levels. Each level is drawn from the same model,
/// rolled up further.
///
/// It also tells the planner what's shown (``MeepPipeline/shownAs``), so each host is asked only for what's on screen,
/// at a detail that suits its size there (design, section 4).
@MainActor @Observable
public final class ContinuumStage {
    public let continuum: Continuum

    /// What the pointer is over.
    public private(set) var hovered: ContinuumHit?
    /// Where the pointer is, in view points.
    public private(set) var pointer: CGPoint = .zero
    /// What the view is about: the pipeline or host it has settled on, or nil for the mesh.
    public private(set) var focus: MeepAddress?
    /// The level the view is at, from what it's settled on.
    public internal(set) var level: ZoomLevel = .mesh
    /// Called when the person has moved the view and it has settled on something else, for the app to select it.
    @ObservationIgnored public var onFocus: ((MeepAddress?) -> Void)?
    /// A plate clicked, for the app to select.
    @ObservationIgnored public var onSelect: ((MeepAddress) -> Void)?
    /// What's selected, drawn lit: a host or a pipeline.
    @ObservationIgnored public var selected: MeepAddress?

    @ObservationIgnored var stages: [String: PipelineStage] = [:]
    @ObservationIgnored var hostPlaces: [String: Placed] = [:]
    @ObservationIgnored var districtPlaces: [String: Placed] = [:]
    @ObservationIgnored var everything: CGRect = .zero
    @ObservationIgnored private var signature = ""

    /// The flows and the boundary, worked out from the Continuum four times a second: views beside the canvas read
    /// them from here rather than working them out on every update.
    public private(set) var flowMap = FlowMap()
    @ObservationIgnored private var flowMapAt: Double = -.infinity
    /// Each endpoint's place round the edge, as a point eased like a plate, and its angle.
    @ObservationIgnored var endpointPlaces: [String: Placed] = [:]
    @ObservationIgnored var endpointAngles: [String: Double] = [:]
    @ObservationIgnored var boundarySignature = ""
    /// Where the mesh's hosts are, with room for their headers: the region the boundary sits round.
    @ObservationIgnored var meshBounds: CGRect = .zero
    /// Particles along each flow and boundary link, worked out in points on screen.
    @ObservationIgnored var flowParticles: [String: Flow] = [:]
    /// What was drawn last frame, for the pointer: flows' paths and endpoints' markers, in world units.
    @ObservationIgnored var drawnFlows: [(id: String, wire: StageWire)] = []
    @ObservationIgnored var drawnEndpoints: [(id: String, frame: CGRect)] = []

    @ObservationIgnored var camera = Camera(scale: 0.1)
    @ObservationIgnored var cameraEasing: Easing<Camera>?
    @ObservationIgnored var viewSize: CGSize = .zero
    @ObservationIgnored var time: Double = 0
    @ObservationIgnored private var fitted = false
    /// Waiting to show something once the view has a size.
    @ObservationIgnored var pendingShow: MeepAddress??
    /// Waiting to show the boundary once the view has a size.
    @ObservationIgnored var pendingBoundary = false
    /// When the person last moved the view; it settles on a focus a moment after.
    @ObservationIgnored var movedAt: Double?
    /// Whether the view keeps showing its focus whole as hosts and pipelines come and go, until the person moves it.
    @ObservationIgnored private var followsLayout = true
    @ObservationIgnored private var pastClosest: CGFloat = 1

    @ObservationIgnored public private(set) var theme = Theme.current
    @ObservationIgnored private var starSpeed: Double = 0
    @ObservationIgnored private var starTravel: Double = 0
    @ObservationIgnored private var starOpacity: Float = 0

    /// Where something is, and where it was, while it eases to a new place.
    struct Placed {
        var frame: CGRect
        var from: CGRect?
        var start: Double

        func at(_ time: Double) -> CGRect {
            guard let from else { return frame }
            let easing = Easing(from: from, to: frame, start: start, duration: 0.8)
            return easing.value(at: time)
        }
    }

    public init(continuum: Continuum) {
        self.continuum = continuum
    }

    // MARK: Pipelines' stages

    /// The stage that draws a pipeline, made the first time it's asked for. It shares this stage's world and camera.
    public func stage(for pipeline: MeepPipeline) -> PipelineStage {
        if let stage = stages[pipeline.id], stage.pipeline === pipeline { return stage }
        let stage = PipelineStage(pipeline: pipeline, host: continuum.host(pipeline.host))
        stage.cameraMover = { [weak self] target in self?.ease(to: target) }
        if viewSize.width > 0 { stage.share(camera, viewSize: viewSize) }
        stages[pipeline.id] = stage
        signature = ""
        return stage
    }

    /// The stage of the pipeline the view is about, at the pipeline level.
    public var focusedStage: PipelineStage? {
        guard level == .pipeline, let focus, let pipeline = continuum.pipeline(at: focus) else { return nil }
        return stage(for: pipeline)
    }

    /// The pipeline drawn in full under `point`, in view points, if its tiles are showing.
    public func pipelineStage(at point: CGPoint) -> PipelineStage? {
        guard tilesReachable else { return nil }
        let world = camera.worldPoint(point, in: viewSize)
        for host in continuum.hosts.reversed() {
            for pipeline in host.pipelines.reversed() {
                guard let frame = districtPlaces[pipeline.id]?.at(time), frame.contains(world) else { continue }
                let stage = stage(for: pipeline)
                stage.share(camera, viewSize: viewSize)
                return stage
            }
        }
        return nil
    }

    // MARK: Each frame

    /// Everything to draw at `time`, in seconds on a steady clock, in a view of `size` points.
    public func frame(at time: Double, viewSize size: CGSize) -> StageSnapshot {
        let elapsed = self.time == 0 ? 0 : min(max(time - self.time, 0), 0.1)
        self.time = time
        if Theme.current != theme { theme = Theme.current; signature = "" }
        advanceStars(by: elapsed)
        if time - flowMapAt > 0.25 || time < flowMapAt {
            flowMapAt = time
            let map = continuum.flowMap()
            if map != flowMap { flowMap = map }
        }
        layOut()
        placeBoundary()
        if size != viewSize {
            let first = viewSize.width == 0
            viewSize = size
            if first || !fitted, size.width > 0 {
                fitted = true
                let target = pendingShow ?? nil
                pendingShow = nil
                if pendingBoundary, target == nil {
                    pendingBoundary = false
                    showBoundary(animated: false)
                } else {
                    show(target, animated: false)
                }
            } else if followsLayout, focus?.module == nil, let target = target(for: focus) {
                // The view changed size, as when what's above or below it changed: what it shows whole stays whole.
                if cameraEasing != nil {
                    cameraEasing = Easing(from: camera, to: target, start: time)
                } else {
                    camera = target
                }
            }
        }
        if let easing = cameraEasing {
            camera = easing.value(at: time)
            if easing.isDone(at: time) { cameraEasing = nil }
        }
        settleIfStill()
        followBoundaryLevel()

        var snapshot = StageSnapshot()
        snapshot.camera = camera
        snapshot.time = time
        snapshot.theme = theme
        snapshot.starTravel = starTravel
        snapshot.starOpacity = starOpacity
        snapshot.starSpeed = starSpeed
        let look = theme.continuum
        let scale = camera.scale
        let screen = CGRect(origin: camera.worldPoint(.zero, in: size), size: CGSize(width: size.width / scale, height: size.height / scale))
        // Hosts too small to read on screen become nodes of the mesh, fading across a range of zooms, all together so
        // the mesh is drawn one way at a time.
        let plate = plateness
        let tilesShown = scale >= look.tilesFrom && plate > 0.99
        var nodeLabels: [NodeLabel] = []
        addContinuumRegion(opacity: plate, into: &snapshot)

        for host in continuum.hosts {
            guard let hostFrame = hostPlaces[host.name]?.at(time) else { continue }
            let reachable = host.isReachable
            let address = host.address
            let stroke = reachable ? look.hostStroke : look.unreachable
            if plate > 0 {
                snapshot.regions.append(StageRegion(
                    id: "host:\(host.name)", frame: hostFrame, cornerRadius: look.hostCorner,
                    fill: look.hostFill.with(alpha: look.hostFill.w * plate), stroke: stroke.with(alpha: plate),
                    strokeWidth: 1.6, isDashed: !reachable, isHovered: hovered == .host(host.name),
                    isSelected: selected == address
                ))
                addHostHeader(host, frame: hostFrame, opacity: plate, into: &snapshot)
            }
            if plate < 1 {
                nodeLabels += addNode(host, frame: hostFrame, opacity: 1 - plate, into: &snapshot)
            }

            for pipeline in host.pipelines {
                guard let frame = districtPlaces[pipeline.id]?.at(time) else { continue }
                let onScreen = frame.intersects(screen) && plate > 0.05
                let detail: SubscriptionPlanner.Detail = !onScreen ? .listed
                    : level == .pipeline && focus == pipeline.address ? .full : tilesShown ? .modules : .totals
                if pipeline.shownAs != detail { pipeline.shownAs = detail }
                // Its flows: every second with its tiles showing, every 2 s as a district, every 5 s inside a node.
                let nodeOnScreen = plate < 0.5 && hostFrame.insetBy(dx: -hostFrame.width, dy: -hostFrame.height).intersects(screen)
                let flows: SubscriptionPlanner.FlowDetail = plate < 0.5 ? (nodeOnScreen ? .far : .none) : onScreen ? (tilesShown ? .close : .near) : .none
                if pipeline.flowsShownAs != flows { pipeline.flowsShownAs = flows }
                guard onScreen else { continue }
                addDistrict(pipeline, host: host, frame: frame, opacity: plate, tiles: tilesShown, into: &snapshot)
            }
        }
        addFlows(plate: plate, tiles: tilesShown, screen: screen, elapsed: elapsed, into: &snapshot)
        let endpointLabels = addBoundary(plate: plate, screen: screen, elapsed: elapsed, into: &snapshot)
        placeNodeLabels(nodeLabels + endpointLabels, into: &snapshot)
        return snapshot
    }

    /// A node's or an endpoint's name and roll-up, waiting to be placed.
    struct NodeLabel {
        var texts: [StageText]
        /// Where the label and its node are on screen, in view points.
        var area: CGRect
        var node: CGRect
        /// Busier hosts' labels are placed first.
        var importance: Double
    }

    /// Places nodes' labels busiest first, leaving out any that would touch one placed already or another node, as
    /// labels along an axis are (the UX notes, "Keep labels from piling up"). A hidden one shows on hover.
    private func placeNodeLabels(_ labels: [NodeLabel], into snapshot: inout StageSnapshot) {
        var taken: [CGRect] = []
        for label in labels.sorted(by: { $0.importance > $1.importance }) {
            let hoveredHere = labels.count > 1 && hovered.map { hit in
                switch hit {
                case .endpoint(let id): label.texts.first?.tile == "endpoint:\(id)"
                default: label.texts.first?.tile == "node:\(hit.address?.host ?? "")"
                }
            } == true
            let clear = !taken.contains { $0.intersects(label.area) } && !labels.contains { $0.node != label.node && $0.node.intersects(label.area) }
            guard clear || hoveredHere else { continue }
            taken.append(label.area)
            snapshot.texts += label.texts
        }
    }

    /// Whether tiles and wires are big enough to point at: drawn from further out, but too small to aim at there, so
    /// the pointer finds their pipeline's plate instead.
    private var tilesReachable: Bool {
        camera.scale >= max(theme.continuum.tilesFrom, 0.3) && plateness > 0.99
    }

    /// Whether hosts are drawn as nodes of the mesh, being too small on screen to show their pipelines.
    public var drawsNodes: Bool { plateness < 0.5 }

    /// How much hosts are drawn as plates rather than nodes, from 0 to 1, from how wide they are on screen on average.
    var plateness: Float {
        let widths = hostPlaces.values.map(\.frame.width)
        guard !widths.isEmpty else { return 1 }
        let mean = widths.reduce(0, +) / CGFloat(widths.count)
        let look = theme.continuum
        return Float(smoothstep(look.nodeBelow, look.nodeBelow * 1.6, mean * camera.scale))
    }

    private func smoothstep(_ low: CGFloat, _ high: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func advanceStars(by elapsed: Double) {
        let field = theme.starfield
        starSpeed += (field.speed - starSpeed) * (1 - exp(-elapsed * 3))
        starTravel = (starTravel + starSpeed * elapsed).truncatingRemainder(dividingBy: 100)
        starOpacity += ((field.isOn ? 1 : 0) - starOpacity) * Float(1 - exp(-elapsed * 4))
        if !field.isOn, starOpacity < 0.002 { starOpacity = 0 }
    }

    /// Text that keeps its size on screen, as world units at the current zoom.
    func worldFont(_ font: StageFont) -> StageFont {
        StageFont(size: font.size / camera.scale, weight: font.weight, monospacedDigits: font.monospacedDigits)
    }

    /// `text` cut short to fit `width` world units in `font`, measured at its size in points, so the cut is cached.
    private func fitted(_ text: String, _ font: StageFont, width: CGFloat) -> String? {
        let points = width * camera.scale
        guard points > 24 else { return nil }
        return TextShaper.shared.truncated(text, font: font, width: points)
    }

    /// A host's name, roll-up and meters, just above its plate's top left, keeping their size on screen, so they never
    /// cover its pipelines.
    private func addHostHeader(_ host: MeepHost, frame: CGRect, opacity: Float, into snapshot: inout StageSnapshot) {
        let look = theme.continuum
        let scale = camera.scale
        let left = frame.minX + 6 / scale
        let width = frame.width - 12 / scale
        let titleFont = worldFont(look.hostTitleFont)
        let detailFont = worldFont(look.detailFont)
        let meterTop = frame.minY - 14 / scale
        guard let title = fitted("\(host.title)  ·  \(host.kind.summary)", look.hostTitleFont, width: width) else { return }
        let color = (host.isReachable ? theme.colors.title : theme.colors.detail).with(alpha: opacity)
        snapshot.texts.append(StageText(title, at: CGPoint(x: left, y: meterTop - 25 / scale), font: titleFont, color: color))
        if let line = fitted(HostSummary(host).line, look.detailFont, width: width) {
            snapshot.texts.append(StageText(line, at: CGPoint(x: left, y: meterTop - 8 / scale), font: detailFont,
                                            color: theme.colors.detail.with(alpha: opacity)))
        }
        // Meters: the cores its pipelines keep busy, and its connection against its budget.
        let meterWidth = min(width / 2 - 8 / scale, 220 / scale)
        if let headroom = host.headroom {
            addMeter(id: "cpu:\(host.name)", at: CGPoint(x: left, y: meterTop), width: meterWidth, share: 1 - headroom.spare,
                     color: look.heat(1 - headroom.spare), opacity: opacity, into: &snapshot)
        }
        if let budget = host.budget, host.traffic.subscribed {
            addMeter(id: "budget:\(host.name)", at: CGPoint(x: left + meterWidth + 14 / scale, y: meterTop), width: meterWidth,
                     share: host.traffic.bandwidth / budget, color: theme.roles.inlet.color, opacity: opacity, into: &snapshot)
        }
    }

    private func addMeter(id: String, at origin: CGPoint, width: CGFloat, share: Double, color: StageColor, opacity: Float, into snapshot: inout StageSnapshot) {
        let look = theme.continuum
        let height = 5 / camera.scale
        let track = CGRect(x: origin.x, y: origin.y, width: width, height: height)
        snapshot.regions.append(StageRegion(id: id + ".track", frame: track, cornerRadius: height / 2, fill: look.meterTrack.with(alpha: opacity),
                                            stroke: .zero, strokeWidth: 0))
        let filled = CGFloat(min(max(share, 0), 1)) * width
        guard filled > 0 else { return }
        snapshot.regions.append(StageRegion(id: id, frame: CGRect(x: origin.x, y: origin.y, width: max(filled, height), height: height),
                                            cornerRadius: height / 2, fill: color.with(alpha: opacity), stroke: .zero, strokeWidth: 0))
    }

    /// A host as a node of the mesh: a disc whose colour is how busy its cores are, with its name and rate below,
    /// returned to be placed once every node is drawn.
    private func addNode(_ host: MeepHost, frame: CGRect, opacity: Float, into snapshot: inout StageSnapshot) -> [NodeLabel] {
        let look = theme.continuum
        let scale = camera.scale
        let radius = look.nodeSize / 2 / scale
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let busy = 1 - (host.headroom?.spare ?? 1)
        let color = host.isReachable ? look.heat(busy) : look.unreachable
        snapshot.regions.append(StageRegion(
            id: "node:\(host.name)", frame: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
            cornerRadius: radius, fill: look.hostFill.mixed(with: color, by: 0.25).with(alpha: opacity), stroke: color.with(alpha: opacity),
            strokeWidth: 2, isDashed: !host.isReachable, isHovered: hovered == .host(host.name), isSelected: selected == host.address,
            glow: host.isReachable ? Float(min(host.intake / 2000, 1)) * 0.5 : 0
        ))
        let titleWidth = TextShaper.shared.width(of: host.title, font: look.hostTitleFont) / scale
        let line = HostSummary(host).short
        let lineWidth = TextShaper.shared.width(of: line, font: look.detailFont) / scale
        let texts = [
            StageText(host.title, at: CGPoint(x: center.x - titleWidth / 2, y: center.y + radius + 22 / scale),
                      font: worldFont(look.hostTitleFont), color: theme.colors.title.with(alpha: opacity), tile: "node:\(host.name)"),
            StageText(line, at: CGPoint(x: center.x - lineWidth / 2, y: center.y + radius + 39 / scale),
                      font: worldFont(look.detailFont), color: theme.colors.detail.with(alpha: opacity), tile: "node:\(host.name)"),
        ]
        let widest = max(titleWidth, lineWidth)
        let area = camera.viewRect(CGRect(x: center.x - widest / 2, y: center.y + radius + 4 / scale, width: widest, height: 40 / scale), in: viewSize)
        let node = camera.viewRect(CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), in: viewSize)
        return [NodeLabel(texts: texts, area: area, node: node, importance: host.intake + (host.isReachable ? 1 : 0))]
    }

    /// A pipeline as a district on its host: a plate coloured by how busy it is, its name and roll-up at its top, and
    /// on it the pipeline itself, drawn in full when there's room, or its tiles as small blocks when not.
    private func addDistrict(_ pipeline: MeepPipeline, host: MeepHost, frame: CGRect, opacity: Float, tiles: Bool, into snapshot: inout StageSnapshot) {
        let look = theme.continuum
        let scale = camera.scale
        let current = host.isReachable && pipeline.state.isLive
        let busiest = pipeline.modules.map(\.load).max() ?? 0
        let heat = look.heat(busiest)
        let stroke: StageColor = !current ? look.unreachable : pipeline.errorRate > 0 ? theme.colors.error.mixed(with: look.districtStroke, by: 0.4)
            : look.districtStroke.mixed(with: heat, by: 0.35)
        snapshot.regions.append(StageRegion(
            id: "district:\(pipeline.id)", frame: frame, cornerRadius: look.districtCorner,
            fill: look.districtFill.mixed(with: heat, by: current ? Float(min(busiest, 1)) * 0.22 : 0).with(alpha: look.districtFill.w * opacity),
            stroke: stroke.with(alpha: opacity), strokeWidth: 1.2, isDashed: !current,
            isHovered: hovered == .pipeline(pipeline.address), isSelected: selected == pipeline.address
        ))

        // The header keeps its size on screen when zoomed out, and grows with the tiles when zoomed in, so it stays in
        // the room left for it then. Zoomed out it can cover the top of the pipeline, so it has a plate behind it.
        let textScale = min(scale, 0.9)
        let left = frame.minX + look.districtPadding * 0.5
        let width = frame.width - look.districtPadding
        let top = frame.minY + 10 / textScale
        let titleFont = StageFont(size: look.titleFont.size / textScale, weight: look.titleFont.weight)
        let detailFont = StageFont(size: look.detailFont.size / textScale, weight: look.detailFont.weight, monospacedDigits: true)
        if width * scale > 30 {
            let title = TextShaper.shared.truncated(pipeline.name, font: look.titleFont, width: width * textScale)
            let line = TextShaper.shared.truncated(PipelineSummaryLine(pipeline, current: current).line, font: look.detailFont, width: width * textScale)
            let bottom = top + (look.titleFont.size + 21) / textScale
            if bottom > frame.minY + look.districtHeader {
                snapshot.labelPlates.append(StageRegion(
                    id: "header:\(pipeline.id)", frame: CGRect(x: frame.minX + 1 / scale, y: frame.minY + 1 / scale, width: frame.width - 2 / scale, height: bottom - frame.minY),
                    cornerRadius: look.districtCorner, fill: look.districtFill.with(alpha: 0.8 * opacity), stroke: .zero, strokeWidth: 0
                ))
            }
            snapshot.texts.append(StageText(title, at: CGPoint(x: left, y: top + look.titleFont.size / textScale), font: titleFont,
                                            color: (current ? theme.colors.title : theme.colors.detail).with(alpha: opacity)))
            snapshot.texts.append(StageText(line, at: CGPoint(x: left, y: top + (look.titleFont.size + 15) / textScale),
                                            font: detailFont, color: theme.colors.detail.with(alpha: opacity)))
        }

        let stage = stage(for: pipeline)
        if tiles {
            stage.share(camera, viewSize: viewSize)
            let drawn = stage.frame(at: time, viewSize: viewSize)
            snapshot.tiles += drawn.tiles
            snapshot.wires += drawn.wires
            snapshot.streams += drawn.streams
            snapshot.particles += drawn.particles
            snapshot.overStreams += drawn.overStreams
            snapshot.overParticles += drawn.overParticles
            snapshot.texts += drawn.texts
        } else if frame.width * scale > 50 {
            // Too small for tiles: each module a block in its role's colour, as on a map of a city.
            for tile in stage.tileFrames {
                let module = pipeline.module(tile.key)
                let glow = Float(min(module?.load ?? 0, 1))
                snapshot.regions.append(StageRegion(
                    id: "block:\(pipeline.id)/\(tile.key)", frame: tile.frame, cornerRadius: tile.shape == .circle ? tile.frame.height / 2 : 10,
                    fill: tile.color.with(alpha: (current ? 0.55 : 0.25) * opacity), stroke: tile.color.with(alpha: (current ? 0.9 : 0.4) * opacity),
                    strokeWidth: 1, glow: current ? glow : 0
                ))
            }
        }
    }

    // MARK: Layout

    /// Packs each host's pipelines into districts, and the hosts into the mesh, when what's there or its sizes change.
    /// Districts and hosts that move ease to their new places, and pipelines' tiles with them.
    func layOut() {
        let look = theme.continuum
        var hostSizes: [(host: MeepHost, size: CGSize, districts: [(MeepPipeline, CGRect)])] = []
        var key = "\(look.hostGap),\(look.districtGap)"
        for host in continuum.hosts {
            var sizes: [(MeepPipeline, CGSize)] = []
            for pipeline in host.pipelines {
                let stage = stage(for: pipeline)
                stage.prepare(at: time)
                let content = stage.layoutBounds.isEmpty ? CGSize(width: 260, height: 120) : stage.layoutBounds.size
                let size = CGSize(width: max(content.width + look.districtPadding * 2, 320),
                                  height: content.height + look.districtPadding * 2 + look.districtHeader)
                sizes.append((pipeline, size))
                key += "|\(pipeline.id):\(Int(size.width))x\(Int(size.height))"
            }
            // Districts packed by size, tallest first, so rows waste little room.
            let order = sizes.indices.sorted { sizes[$0].1.height != sizes[$1].1.height ? sizes[$0].1.height > sizes[$1].1.height : sizes[$0].0.name < sizes[$1].0.name }
            let (places, packed) = Self.shelfPack(order.map { sizes[$0].1 }, gap: look.districtGap, aspect: 1.7)
            let districts = zip(order, places).map { index, place in (sizes[index].0, CGRect(origin: place, size: sizes[index].1)) }
            let content = packed.width > 0 ? packed : CGSize(width: 520, height: 160)
            let size = CGSize(width: max(content.width + look.hostPadding * 2, 760), height: content.height + look.hostPadding + look.hostHeader)
            hostSizes.append((host, size, districts))
            key += "#\(host.name):\(host.pipelines.count)"
        }
        // The flows between hosts pull them together: which hosts, and whether seen, not how busy, so the mesh moves
        // only when what talks to what changes.
        let edges = hostEdges()
        key += "~" + edges.map { "\($0.a)>\($0.b):\($0.weight)" }.joined(separator: ",")
        guard key != signature else { return }
        let first = signature.isEmpty && hostPlaces.isEmpty
        signature = key
        defer {
            // What the view shows whole stays whole as the layout changes, eased, until the person moves the view.
            if followsLayout, fitted, viewSize.width > 0, focus?.module == nil {
                if let target = target(for: focus) { cameraEasing = Easing(from: camera, to: target, start: time) }
            }
        }

        // The mesh: a damped force layout (design, section 7), from where each host was.
        let centres = ForceLayout(gap: look.hostGap, aspect: 1.8).layOut(
            hostSizes.map { entry in
                ForceLayout.Node(id: entry.host.name, size: entry.size, position: hostPlaces[entry.host.name].map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) })
            },
            edges: edges
        )
        let hostOrigins = hostSizes.map { entry in
            let centre = centres[entry.host.name] ?? .zero
            return CGPoint(x: centre.x - entry.size.width / 2, y: centre.y - entry.size.height / 2)
        }
        var newHosts: [String: Placed] = [:]
        var newDistricts: [String: Placed] = [:]
        var all = CGRect.null
        for ((host, size, districts), origin) in zip(hostSizes, hostOrigins) {
            let frame = CGRect(origin: origin, size: size)
            all = all.union(frame)
            newHosts[host.name] = place(frame, was: hostPlaces[host.name], first: first)
            for (pipeline, local) in districts {
                let district = local.offsetBy(dx: origin.x + look.hostPadding, dy: origin.y + look.hostHeader)
                let placedBefore = districtPlaces[pipeline.id] != nil
                newDistricts[pipeline.id] = place(district, was: districtPlaces[pipeline.id], first: first)
                stage(for: pipeline).place(
                    at: CGPoint(x: district.minX + look.districtPadding, y: district.minY + look.districtHeader + look.districtPadding * 0.6),
                    animated: placedBefore && !first
                )
            }
        }
        hostPlaces = newHosts
        districtPlaces = newDistricts
        // Room above for the top row's headers, which sit over their plates.
        meshBounds = all.isNull ? .zero : CGRect(x: all.minX, y: all.minY - 320, width: all.width, height: all.height + 320)
        everything = meshBounds
        boundarySignature = ""
        let shown = Set(newDistricts.keys)
        stages = stages.filter { shown.contains($0.key) }
    }

    func place(_ frame: CGRect, was: Placed?, first: Bool) -> Placed {
        guard let was, !first, was.frame != frame else { return was.map { Placed(frame: frame, from: $0.from, start: $0.start) } ?? Placed(frame: frame, from: nil, start: time) }
        return Placed(frame: frame, from: was.at(time), start: time)
    }

    /// Places boxes in rows, left to right, wrapping at a width that makes the whole about `aspect` times as wide as
    /// it's tall. Returns each box's top left and the size of the whole.
    public static func shelfPack(_ sizes: [CGSize], gap: CGFloat, aspect: CGFloat) -> ([CGPoint], CGSize) {
        guard !sizes.isEmpty else { return ([], .zero) }
        let area = sizes.reduce(0) { $0 + ($1.width + gap) * ($1.height + gap) }
        let widest = sizes.map(\.width).max() ?? 0
        let target = max(widest, (area * aspect).squareRoot())
        var places: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var row: CGFloat = 0
        var width: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > target {
                x = 0
                y += row + gap
                row = 0
            }
            places.append(CGPoint(x: x, y: y))
            width = max(width, x + size.width)
            x += size.width + gap
            row = max(row, size.height)
        }
        return (places, CGSize(width: width, height: y + row))
    }

    /// Where a host or pipeline is drawn, in world units.
    public func frame(of address: MeepAddress) -> CGRect? {
        if let pipeline = address.pipeline {
            return districtPlaces["\(address.host)/\(pipeline)"]?.at(time)
        }
        return hostPlaces[address.host]?.at(time)
    }

    // MARK: Camera

    /// The camera now, for tests and overlays.
    public var currentCamera: Camera { camera }
    public var currentViewSize: CGSize { viewSize }

    /// The least zoom: enough to see the whole mesh with room round it.
    private var minimumScale: CGFloat {
        let all = fitting(everything, cap: 1)
        return min(Camera.minimumScale, all.scale * 0.5)
    }

    func fitting(_ rect: CGRect, cap: CGFloat = 1.5, margin: CGFloat = 40) -> Camera {
        guard rect.width > 0, rect.height > 0, viewSize.width > margin * 2, viewSize.height > margin * 2 else {
            return Camera(center: CGPoint(x: rect.midX, y: rect.midY), scale: camera.scale)
        }
        let scale = min((viewSize.width - margin * 2) / rect.width, (viewSize.height - margin * 2) / rect.height, cap)
        return Camera(center: CGPoint(x: rect.midX, y: rect.midY), scale: min(max(scale, 0.002), Camera.maximumScale))
    }

    func ease(to target: Camera) {
        cameraEasing = Easing(from: camera, to: target, start: time)
    }

    /// Eases the view to show something: a module close enough to read, a pipeline whole, a host with its pipelines,
    /// or the whole mesh for nil. The view's focus becomes it at once.
    public func show(_ address: MeepAddress?, animated: Bool = true) {
        guard viewSize.width > 0 else {
            pendingShow = .some(address)
            pendingBoundary = false
            return
        }
        layOut()
        movedAt = nil
        followsLayout = address?.module == nil
        var target: Camera?
        if let address, let pipelineName = address.pipeline, let pipeline = continuum.pipeline(at: address) {
            let district = districtPlaces[pipeline.id]?.frame
            if let key = address.module ?? nil, let stage = stages[pipeline.id] {
                stage.share(camera, viewSize: viewSize)
                if let module = pipeline.module(key) ?? pipeline.modules.first(where: { $0.name == key || $0.label == key }) {
                    _ = stage.show(module.key)
                }
                target = cameraEasing?.to
            } else if let district {
                target = fitting(district)
            }
            setFocus(MeepAddress(host: address.host, pipeline: pipelineName))
        } else if let address, let frame = hostPlaces[address.host]?.frame {
            target = fitting(CGRect(x: frame.minX, y: frame.minY - 200, width: frame.width, height: frame.height + 200), cap: 0.8)
            setFocus(MeepAddress(host: address.host))
        } else {
            // The mesh: its hosts whole, as plates; the boundary round them is further out.
            level = .mesh
            setFocus(nil)
            target = fitting(meshBounds.isEmpty ? everything : meshBounds, cap: 0.5)
        }
        guard let target else { return }
        if animated {
            ease(to: target)
        } else {
            cameraEasing = nil
            camera = target
        }
    }

    /// The camera that shows a pipeline, a host or the whole mesh whole.
    private func target(for address: MeepAddress?) -> Camera? {
        if let address, address.pipeline != nil {
            return districtPlaces["\(address.host)/\(address.pipeline!)"].map { fitting($0.frame) }
        }
        if let address {
            return hostPlaces[address.host].map { fitting(CGRect(x: $0.frame.minX, y: $0.frame.minY - 200, width: $0.frame.width, height: $0.frame.height + 200), cap: 0.8) }
        }
        if level == .boundary { return boundaryTarget() }
        let mesh = meshBounds.isEmpty ? everything : meshBounds
        return mesh.isEmpty ? nil : fitting(mesh, cap: 0.5)
    }

    /// Shows the whole of what the view is about: a pipeline, a host, the mesh, or the boundary round it, eased.
    public func fit() {
        if focus == nil, level == .boundary { showBoundary() } else { show(focus) }
    }

    /// Scrolling moves the view, as content dragged by `offset` view points.
    public func pan(by offset: CGVector) {
        cameraEasing = nil
        followsLayout = false
        camera = camera.panned(by: offset)
        movedAt = time
    }

    /// Pinching zooms around the pointer. Going on past the closest zoom over a tile opens its text beside the canvas
    /// (design, section 2).
    public func zoom(by factor: CGFloat, at point: CGPoint) {
        cameraEasing = nil
        followsLayout = false
        if factor > 1, camera.scale >= Camera.maximumScale * 0.999 {
            pastClosest *= factor
            if pastClosest > 1.6, case .inside(let address, .tile(let key))? = hit(at: point), let pipeline = continuum.pipeline(at: address) {
                pastClosest = 1
                stage(for: pipeline).requestText(at: key)
            }
        } else if factor < 1 {
            pastClosest = 1
        }
        camera = zoomed(camera, by: factor, at: point)
        movedAt = time
    }

    /// Zooms in or out a step around the middle, eased. Zooming in at the closest zoom opens the selected module's text.
    public func step(zoomingIn: Bool) {
        let from = cameraEasing?.to ?? camera
        if zoomingIn, from.scale >= Camera.maximumScale * 0.999, let stage = focusedStage, let key = stage.tileKeys.first(where: stage.selection.contains) {
            stage.requestText(at: key)
            return
        }
        ease(to: zoomed(from, by: zoomingIn ? 1.5 : 1 / 1.5, at: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)))
        followsLayout = false
        movedAt = time + 0.9
    }

    private func zoomed(_ camera: Camera, by factor: CGFloat, at anchor: CGPoint) -> Camera {
        let fixed = camera.worldPoint(anchor, in: viewSize)
        let scale = min(max(camera.scale * factor, minimumScale), Camera.maximumScale)
        let center = CGPoint(x: fixed.x - (anchor.x - viewSize.width / 2) / scale, y: fixed.y - (anchor.y - viewSize.height / 2) / scale)
        return Camera(center: center, scale: scale)
    }

    // MARK: Focus

    /// Once the person has stopped moving the view, settles on what it's about: the pipeline filling it, the host
    /// filling it, or the mesh. Thresholds are lower for what it's already about, so it doesn't flicker.
    private func settleIfStill() {
        guard let movedAt, time - movedAt > 0.35, cameraEasing == nil else { return }
        self.movedAt = nil
        let settled = focusNow()
        if settled != focus {
            setFocus(settled)
            onFocus?(settled)
        }
    }

    func setFocus(_ address: MeepAddress?) {
        if focus != address { focus = address }
        let level: ZoomLevel = address?.pipeline != nil ? .pipeline : address != nil ? .host : self.level == .boundary && plateness < 0.6 ? .boundary : .mesh
        if self.level != level { self.level = level }
    }

    /// What the view is about now, from what fills it.
    func focusNow() -> MeepAddress? {
        let scale = camera.scale
        let center = camera.center
        let width = viewSize.width
        if scale >= theme.continuum.tilesFrom * 2 {
            for host in continuum.hosts {
                for pipeline in host.pipelines {
                    guard let frame = districtPlaces[pipeline.id]?.frame, frame.insetBy(dx: -40, dy: -40).contains(center) else { continue }
                    let share = max(frame.width * scale / width, frame.height * scale / max(viewSize.height, 1))
                    if share >= (focus == pipeline.address ? 0.3 : 0.45) { return pipeline.address }
                }
            }
        }
        for host in continuum.hosts {
            guard let frame = hostPlaces[host.name]?.frame, frame.contains(center) else { continue }
            let share = max(frame.width * scale / width, frame.height * scale / max(viewSize.height, 1))
            if share >= (focus?.host == host.name ? 0.3 : 0.45) { return host.address }
        }
        return nil
    }

    // MARK: Pointer

    /// What's at `point`, in view points: an endpoint on the boundary; a pipeline's tile or wire when it's drawn in
    /// full; a flow; else a pipeline's plate, else a host.
    public func hit(at point: CGPoint) -> ContinuumHit? {
        if let id = endpoint(at: point) { return .endpoint(id) }
        let under = plateHit(at: point)
        if case .inside? = under { return under }
        if let id = flow(at: point) { return .flow(id) }
        return under
    }

    private func plateHit(at point: CGPoint) -> ContinuumHit? {
        let world = camera.worldPoint(point, in: viewSize)
        let look = theme.continuum
        for host in continuum.hosts.reversed() {
            guard let hostFrame = hostPlaces[host.name]?.at(time) else { continue }
            let plate = plateness > 0.5
            if !plate {
                let radius = look.nodeSize / 2 / camera.scale
                if hypot(world.x - hostFrame.midX, world.y - hostFrame.midY) <= radius + 4 / camera.scale { return .host(host.name) }
                continue
            }
            for pipeline in host.pipelines.reversed() {
                guard let frame = districtPlaces[pipeline.id]?.at(time), frame.contains(world) else { continue }
                if tilesReachable {
                    let stage = stage(for: pipeline)
                    stage.share(camera, viewSize: viewSize)
                    if let inside = stage.hit(at: point) { return .inside(pipeline.address, inside) }
                }
                return .pipeline(pipeline.address)
            }
            if hostFrame.contains(world) { return .host(host.name) }
        }
        return nil
    }

    public func hover(at point: CGPoint?) {
        guard let point else {
            if hovered != nil { hovered = nil }
            for stage in stages.values { stage.hover(at: nil) }
            return
        }
        pointer = point
        let hit = hit(at: point)
        for (id, stage) in stages {
            if case .inside(let address, _)? = hit, "\(address.host)/\(address.pipeline ?? "")" == id {
                stage.hover(at: point)
            } else if stage.hovered != nil {
                stage.hover(at: nil)
            }
        }
        if hit != hovered { hovered = hit }
    }

    /// A click: inside a pipeline drawn in full, as on its own canvas; on a plate, selects it.
    public func click(at point: CGPoint, modifiers: StageModifiers = []) {
        let hit = hit(at: point)
        if let stage = pipelineStage(at: point), case .inside? = hit {
            stage.click(at: point, modifiers: modifiers)
            return
        }
        if let stage = pipelineStage(at: point), stage.tracer(at: point) != nil {
            stage.click(at: point, modifiers: modifiers)
            return
        }
        for stage in stages.values where !stage.selection.isEmpty && !modifiers.contains(.command) { stage.select([], reveal: false) }
        switch hit {
        case .host(let name)?: onSelect?(MeepAddress(host: name))
        case .pipeline(let address)?: onSelect?(address)
        default: break
        }
    }

    /// A double click: opens a tile's text; zooms into a pipeline or host; or shows the whole mesh.
    public func doubleClick(at point: CGPoint) {
        switch hit(at: point) {
        case .inside(let address, .tile(let key))?:
            if let pipeline = continuum.pipeline(at: address) { stage(for: pipeline).requestText(at: key) }
        case .inside(let address, .wire)?, .pipeline(let address)?:
            show(address)
            onFocus?(address)
        case .host(let name)?:
            show(MeepAddress(host: name))
            onFocus?(MeepAddress(host: name))
        case .flow(let id)?:
            showFlow(id)
        case .endpoint(let id)?:
            showEndpoint(id)
        case nil:
            show(nil)
            onFocus?(nil)
        }
    }

    /// Hosts, pipelines, and the tiles and wires of those drawn in full, and the boundary's endpoints, for VoiceOver.
    public func accessibilityItems() -> [StageAccessibilityItem] {
        var items: [StageAccessibilityItem] = []
        let screen = CGRect(origin: .zero, size: viewSize)
        for (id, frame) in endpointsOnScreen where frame.intersects(screen) {
            guard let endpoint = flowMap.boundary.first(where: { $0.id == id }) else { continue }
            items.append(StageAccessibilityItem(hit: .tile("endpoint:\(id)"), label: "Outside: \(endpoint.name), \(Self.ratesLine(endpoint))", frame: frame))
        }
        for host in continuum.hosts {
            guard let frame = hostPlaces[host.name]?.at(time) else { continue }
            let shown = camera.viewRect(frame, in: viewSize)
            guard shown.intersects(screen) else { continue }
            items.append(StageAccessibilityItem(hit: .tile("host:\(host.name)"), label: "Host \(host.title): \(HostSummary(host).line)", frame: shown))
            for pipeline in host.pipelines {
                guard let district = districtPlaces[pipeline.id]?.at(time) else { continue }
                let rect = camera.viewRect(district, in: viewSize)
                guard rect.intersects(screen) else { continue }
                items.append(StageAccessibilityItem(hit: .tile("pipeline:\(pipeline.id)"), label: "Pipeline \(pipeline.name): \(PipelineSummaryLine(pipeline, current: host.isReachable).line)", frame: rect))
                if camera.scale >= theme.continuum.tilesFrom { items += stage(for: pipeline).accessibilityItems() }
            }
        }
        return items
    }
}

// MARK: Roll-ups in words

/// A host's roll-up as one line: its pipelines, rate, cores and connection.
public struct HostSummary {
    public let line: String
    public let short: String

    @MainActor public init(_ host: MeepHost) {
        guard host.isReachable else {
            line = "can't be reached; as last seen"
            short = "unreachable"
            return
        }
        var parts = ["\(host.pipelines.count) pipeline\(host.pipelines.count == 1 ? "" : "s")"]
        parts.append("\(StageFormat.rate(host.intake)) in")
        if let headroom = host.headroom {
            parts.append("\(Self.cores(headroom.daemon ?? headroom.pipelines)) of \(headroom.cores) cores")
        } else if host.load > 0 {
            parts.append("\(Self.cores(host.load)) cores busy")
        }
        if let budget = host.budget, host.traffic.subscribed {
            parts.append("\(StageFormat.bytes(host.traffic.bandwidth))/s of \(StageFormat.bytes(budget))/s")
        }
        line = parts.joined(separator: "  ·  ")
        short = "\(StageFormat.rate(host.intake)) in" + (host.headroom.map { "  ·  \(Int(((1 - $0.spare) * 100).rounded()))% busy" } ?? "")
    }

    static func cores(_ value: Double) -> String {
        value < 0.1 ? String(format: "%.2f", value) : String(format: "%.1f", value)
    }
}

/// A pipeline's roll-up as one line: what comes in, how busy it is, errors and handling time.
public struct PipelineSummaryLine {
    public let line: String

    @MainActor public init(_ pipeline: MeepPipeline, current: Bool) {
        guard current else {
            line = pipeline.state.isLive ? "as last seen" : pipeline.state.rawValue
            return
        }
        var parts = ["\(StageFormat.rate(pipeline.intake)) in"]
        let busiest = pipeline.modules.map(\.load).max() ?? 0
        if busiest > 0.005 { parts.append("busiest \(Int((busiest * 100).rounded()))%") }
        if pipeline.errorRate > 0.05 { parts.append("\(StageFormat.rate(pipeline.errorRate)) failing") }
        if pipeline.queued > 0 { parts.append("\(StageFormat.count(pipeline.queued)) queued") }
        if let median = pipeline.timing.quantile(0.5) { parts.append("p50 \(StageFormat.duration(median))") }
        line = parts.joined(separator: "  ·  ")
    }
}
