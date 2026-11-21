import ContinuumKit
import CoreGraphics
import FlowKit
import Foundation
import LayoutKit
import MeepClient

// Flows between pipelines and hosts, and the boundary (design, sections 2, 3 and 7), drawn on the Continuum's stage:
// flows seen solid with particles, declared ones dashed; at a host's or the mesh's distance between districts and the
// tiles at their ends, and further out between hosts drawn as nodes; the endpoints outside Meep round the edge of the
// mesh, grouped by domain, each with its rates, failures and rejections.

extension ContinuumStage {
    // MARK: Layout

    /// The pairs of hosts that flows join, for the mesh's force layout: seen ones pull harder than declared ones. Only
    /// which hosts and whether seen, not how busy, so the mesh moves only when what talks to what changes.
    func hostEdges() -> [ForceLayout.Edge] {
        var weights: [String: ForceLayout.Edge] = [:]
        for flow in flowMap.flows where flow.crossesHosts {
            let (a, b) = flow.from.host < flow.to.host ? (flow.from.host, flow.to.host) : (flow.to.host, flow.from.host)
            let weight: Double = flow.observed ? 2 : 1
            weights["\(a)>\(b)"] = ForceLayout.Edge(a, b, weight: max(weights["\(a)>\(b)"]?.weight ?? 0, weight))
        }
        return weights.keys.sorted().compactMap { weights[$0] }
    }

    /// Places the boundary's endpoints round the edge of the mesh, each toward the pipelines it talks to, grouped by
    /// domain, when what's there or the mesh changes. Those that move ease, as hosts do.
    func placeBoundary() {
        let endpoints = flowMap.boundary
        let key = "\(meshBounds)|" + endpoints.map { endpoint in
            "\(endpoint.id)@\(endpoint.domain):" + Set(endpoint.links.map { "\($0.module.host)/\($0.module.pipeline ?? "")" }).sorted().joined(separator: ",")
        }.joined(separator: ";")
        guard key != boundarySignature else { return }
        boundarySignature = key
        guard !endpoints.isEmpty, !meshBounds.isEmpty else {
            endpointPlaces = [:]
            endpointAngles = [:]
            everything = meshBounds
            return
        }
        let first = endpointPlaces.isEmpty
        let centre = CGPoint(x: meshBounds.midX, y: meshBounds.midY)
        let items = endpoints.map { endpoint -> EdgeLayout.Item in
            let anchors = endpoint.links.compactMap { link -> CGPoint? in
                if let pipeline = link.module.pipeline, let frame = districtPlaces["\(link.module.host)/\(pipeline)"]?.frame {
                    return CGPoint(x: frame.midX, y: frame.midY)
                }
                return hostPlaces[link.module.host].map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
            }
            var angle: Double?
            if !anchors.isEmpty {
                let x = anchors.reduce(0) { $0 + $1.x } / CGFloat(anchors.count) - centre.x
                let y = anchors.reduce(0) { $0 + $1.y } / CGFloat(anchors.count) - centre.y
                if hypot(x, y) > 1 { angle = Double(atan2(y, x)) }
            }
            return EdgeLayout.Item(id: endpoint.id, group: endpoint.domain, angle: angle, importance: endpoint.traffic)
        }
        let margin = theme.flows.ringMargin
        let places = EdgeLayout().layOut(items, around: meshBounds, margin: margin)
        var next: [String: Placed] = [:]
        for (id, spot) in places {
            next[id] = place(CGRect(origin: spot.point, size: .zero), was: endpointPlaces[id], first: first)
        }
        endpointPlaces = next
        endpointAngles = places.mapValues(\.angle)
        // The view fits the mesh and the ring round it, with room for the endpoints' labels.
        let ring = places.values.reduce(meshBounds) { $0.union(CGRect(origin: $1.point, size: .zero)) }
        everything = ring.insetBy(dx: -margin * 0.7, dy: -margin * 0.35)
    }

    // MARK: Levels

    /// With nothing in focus, the level follows how far out the view is once it has settled: the boundary while hosts
    /// are nodes, the mesh while they're plates, with a gap between so it doesn't flicker.
    func followBoundaryLevel() {
        guard focus == nil, movedAt == nil, cameraEasing == nil, level == .mesh || level == .boundary else { return }
        let plate = plateness
        let next: ZoomLevel = plate < 0.4 ? .boundary : plate > 0.6 ? .mesh : level
        if next != level { level = next }
    }

    /// The camera that shows the edge of the Continuum: everything, far enough out that hosts are nodes.
    func boundaryTarget() -> Camera? {
        guard !everything.isEmpty else { return nil }
        var target = fitting(everything, cap: 0.5)
        let widths = hostPlaces.values.map(\.frame.width)
        if !widths.isEmpty {
            let mean = widths.reduce(0, +) / CGFloat(widths.count)
            target.scale = min(target.scale, theme.continuum.nodeBelow * 0.85 / mean)
        }
        return target
    }

    /// Eases out to the edge of the Continuum (level 6): every host a node, with the endpoints outside Meep round them.
    public func showBoundary(animated: Bool = true) {
        guard viewSize.width > 0 else {
            // Once the view has a size: it fits what it shows then.
            pendingShow = nil
            pendingBoundary = true
            return
        }
        layOut()
        placeBoundary()
        movedAt = nil
        setFocus(nil)
        level = .boundary
        guard let target = boundaryTarget() else { return }
        if animated {
            ease(to: target)
        } else {
            cameraEasing = nil
            camera = target
        }
    }

    /// Eases to show both ends of a flow, or of a flow between hosts.
    public func showFlow(_ id: String) {
        var area = CGRect.null
        if id.hasPrefix("hosts:") {
            for name in id.dropFirst("hosts:".count).split(separator: ">").map(String.init) {
                if let frame = hostPlaces[name]?.frame { area = area.union(frame) }
            }
        } else if let flow = flowMap.flows.first(where: { $0.id == id }) {
            for end in [flow.from, flow.to] {
                if let frame = frame(of: end.pipeline == nil ? end : end.parent) { area = area.union(frame) }
            }
        }
        guard !area.isNull else { return }
        movedAt = time + 0.9
        ease(to: fitting(area.insetBy(dx: -120, dy: -200), cap: 0.8))
    }

    /// Eases to show an endpoint and the pipelines it talks to.
    public func showEndpoint(_ id: String) {
        guard let point = endpointPlaces[id]?.frame.origin, let endpoint = flowMap.boundary.first(where: { $0.id == id }) else { return }
        var area = CGRect(origin: point, size: .zero)
        for link in endpoint.links {
            if let frame = frame(of: link.module.parent) ?? frame(of: MeepAddress(host: link.module.host)) { area = area.union(frame) }
        }
        movedAt = time + 0.9
        ease(to: fitting(area.insetBy(dx: -300, dy: -300), cap: 0.8))
    }

    // MARK: Drawing

    /// The Continuum's edge round the mesh, faint, clearer as the view draws back to the boundary.
    func addContinuumRegion(opacity plate: Float, into snapshot: inout StageSnapshot) {
        guard !endpointPlaces.isEmpty, !meshBounds.isEmpty else { return }
        let look = theme.flows
        let strength = 0.3 + 0.5 * (1 - plate)
        let frame = meshBounds.insetBy(dx: -look.ringMargin * 0.45, dy: -look.ringMargin * 0.45)
        snapshot.regions.append(StageRegion(
            id: "continuum", frame: frame, cornerRadius: min(frame.width, frame.height) * 0.3,
            fill: look.region.with(alpha: 0.035 * strength), stroke: look.region.with(alpha: 0.55 * strength), strokeWidth: 1.2, isDashed: true
        ))
        if plate < 0.95 {
            let font = worldFont(look.groupFont)
            snapshot.texts.append(StageText(
                "The Continuum", at: CGPoint(x: frame.minX + frame.width * 0.12, y: frame.minY + 26 / camera.scale), font: font,
                color: theme.colors.detail.with(alpha: 0.8 * (1 - plate))
            ))
        }
    }

    /// Flows between pipelines while hosts are plates, and between hosts while they're nodes, crossfading between the
    /// two as hosts do.
    func addFlows(plate: Float, tiles: Bool, screen: CGRect, elapsed: Double, into snapshot: inout StageSnapshot) {
        drawnFlows = []
        let look = theme.flows
        if plate > 0.02 {
            for flow in flowMap.flows {
                // One pipeline's Fetch asking its own Listen shows only once its tiles do.
                if flow.isWithinPipeline && !tiles { continue }
                guard let fromCentre = centre(of: flow.from), let toCentre = centre(of: flow.to),
                      let a = anchor(flow.from, outgoing: true, toward: toCentre), let b = anchor(flow.to, outgoing: false, toward: fromCentre) else { continue }
                let color = flow.observed ? look.observed : look.declared
                // Between tiles, a cable: out of the Send's right side and into the Listen's left, as wires are.
                let cable = tileFrame(flow.from) != nil && tileFrame(flow.to) != nil
                addFlowLine(
                    id: flow.id, from: a, to: b, bend: 0.16, observed: flow.observed, rate: flow.rate, count: flow.count,
                    trouble: flow.failed + flow.rejected, color: color, opacity: plate, screen: screen, elapsed: elapsed, cable: cable, into: &snapshot
                )
            }
        }
        if plate < 0.98 {
            // Hosts as nodes: the flows between each pair, added up.
            var pairs: [String: (from: String, to: String, rate: Double, count: Int64, trouble: Double, observed: Bool)] = [:]
            for flow in flowMap.flows where flow.crossesHosts {
                let id = "hosts:\(flow.from.host)>\(flow.to.host)"
                var pair = pairs[id] ?? (flow.from.host, flow.to.host, 0, 0, 0, false)
                pair.rate += flow.rate
                pair.count += flow.count
                pair.trouble += flow.failed + flow.rejected
                pair.observed = pair.observed || flow.observed
                pairs[id] = pair
            }
            let radius = theme.continuum.nodeSize / 2 / camera.scale
            for (id, pair) in pairs.sorted(by: { $0.key < $1.key }) {
                guard let fromFrame = hostPlaces[pair.from]?.at(time), let toFrame = hostPlaces[pair.to]?.at(time) else { continue }
                let a = CGPoint(x: fromFrame.midX, y: fromFrame.midY), b = CGPoint(x: toFrame.midX, y: toFrame.midY)
                let length = max(hypot(b.x - a.x, b.y - a.y), 1)
                let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
                addFlowLine(
                    id: id, from: CGPoint(x: a.x + ux * radius, y: a.y + uy * radius), to: CGPoint(x: b.x - ux * radius, y: b.y - uy * radius),
                    bend: 0.16, observed: pair.observed, rate: pair.rate, count: pair.count, trouble: pair.trouble,
                    color: pair.observed ? look.observed : look.declared, opacity: 1 - plate, screen: screen, elapsed: elapsed, into: &snapshot
                )
            }
        }
    }

    /// The boundary's endpoints round the edge, each with lines to the modules that talk to it, and its label, returned
    /// to be placed with the nodes' by importance.
    func addBoundary(plate: Float, screen: CGRect, elapsed: Double, into snapshot: inout StageSnapshot) -> [NodeLabel] {
        drawnEndpoints = []
        let look = theme.flows
        let scale = camera.scale
        let radius = look.endpointSize / 2 / scale
        var labels: [NodeLabel] = []
        var drawnIDs: Set<String> = Set(drawnFlows.map(\.id))
        var groups: [String: [(CGPoint, Double)]] = [:]
        for endpoint in flowMap.boundary {
            guard let point = endpointPlaces[endpoint.id]?.at(time).origin else { continue }
            let color = self.color(of: endpoint)
            // Lines to each module that talks to it: to its tile or district while hosts are plates, faint there so
            // flows between pipelines stand out, unless it's hovered; and added up for each host while they're nodes.
            let hoveredEndpoint = hovered == .endpoint(endpoint.id)
            if plate > 0.02 {
                for link in endpoint.links {
                    guard let moduleEnd = anchor(link.module, outgoing: link.direction == .outbound, toward: point) else { continue }
                    let edge = toward(point, moduleEnd, by: radius)
                    let (a, b) = link.direction == .inbound ? (edge, moduleEnd) : (moduleEnd, edge)
                    // Among plates, a short stub at the module, pointing the way to its endpoint, so lines to the edge
                    // don't cross the mesh; whole while the endpoint or the line is hovered.
                    let whole = hoveredEndpoint || hovered == .flow(link.id)
                    addFlowLine(
                        id: link.id, from: a, to: b, bend: 0.1, observed: link.observed, rate: link.rate, count: link.count,
                        trouble: link.failed + link.rejected, color: color, opacity: plate * (whole ? 1 : 0.7), screen: screen, elapsed: elapsed,
                        keep: whole ? nil : (120 / scale, link.direction == .inbound), into: &snapshot
                    )
                    drawnIDs.insert(link.id)
                }
            }
            if plate < 0.98 {
                var byHost: [String: (inbound: Bool, observed: Bool, rate: Double, count: Int64, trouble: Double)] = [:]
                for link in endpoint.links {
                    let key = "\(link.module.host)|\(link.direction.rawValue)"
                    var entry = byHost[key] ?? (link.direction == .inbound, false, 0, 0, 0)
                    entry.observed = entry.observed || link.observed
                    entry.rate += link.rate
                    entry.count += link.count
                    entry.trouble += link.failed + link.rejected
                    byHost[key] = entry
                }
                let nodeRadius = theme.continuum.nodeSize / 2 / scale
                for (key, entry) in byHost.sorted(by: { $0.key < $1.key }) {
                    let hostName = String(key.split(separator: "|").first ?? "")
                    guard let frame = hostPlaces[hostName]?.at(time) else { continue }
                    let node = toward(CGPoint(x: frame.midX, y: frame.midY), point, by: nodeRadius)
                    let edge = toward(point, node, by: radius)
                    let (a, b) = entry.inbound ? (edge, node) : (node, edge)
                    let id = "\(endpoint.id)|\(key)"
                    addFlowLine(
                        id: id, from: a, to: b, bend: 0.1, observed: entry.observed, rate: entry.rate, count: entry.count, trouble: entry.trouble,
                        color: color, opacity: (1 - plate) * 0.9, screen: screen, elapsed: elapsed, into: &snapshot
                    )
                    drawnIDs.insert(id)
                }
            }

            // The marker: a rounded square outside Meep, a disc for another Meep, dashed while only declared.
            let frame = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            let hoveredHere = hovered == .endpoint(endpoint.id)
            snapshot.labelPlates.append(StageRegion(
                id: "endpoint:\(endpoint.id)", frame: frame, cornerRadius: endpoint.kind == .outside ? radius * 0.35 : radius,
                fill: theme.canvas.background.mixed(with: color, by: 0.28), stroke: color, strokeWidth: 1.6, isDashed: endpoint.isDeclaredOnly,
                isHovered: hoveredHere, glow: Float(min(log10(1 + endpoint.traffic) / 3, 1)) * 0.5
            ))
            drawnEndpoints.append((endpoint.id, frame))
            groups[endpoint.domain, default: []].append((point, endpointAngles[endpoint.id] ?? 0))

            // Its label, outward from the ring: above or below the marker at the top and bottom, where markers sit side
            // by side; to the right on the right-hand side, and ending at the marker on the left.
            let title = endpoint.name
            let line = Self.ratesLine(endpoint)
            let titleWidth = TextShaper.shared.width(of: title, font: look.labelFont) / scale
            let lineWidth = TextShaper.shared.width(of: line, font: look.detailFont) / scale
            let widest = max(titleWidth, lineWidth)
            let angle = endpointAngles[endpoint.id] ?? 0
            let gap = 8 / scale
            let tile = "endpoint:\(endpoint.id)"
            let titleOrigin: CGPoint, lineOrigin: CGPoint, area: CGRect
            if abs(sin(angle)) > 0.75 {
                let above = sin(angle) < 0
                let left = point.x - radius
                let top = above ? point.y - radius - gap - 32 / scale : point.y + radius + gap
                titleOrigin = CGPoint(x: left, y: top + 13 / scale)
                lineOrigin = CGPoint(x: left, y: top + 28 / scale)
                area = CGRect(x: left, y: top, width: widest, height: 32 / scale)
            } else {
                let right = cos(angle) > 0
                titleOrigin = CGPoint(x: right ? point.x + radius + gap : point.x - radius - gap - titleWidth, y: point.y - 1 / scale)
                lineOrigin = CGPoint(x: right ? point.x + radius + gap : point.x - radius - gap - lineWidth, y: point.y + 14 / scale)
                area = CGRect(x: right ? point.x + radius + gap : point.x - radius - gap - widest, y: point.y - 15 / scale, width: widest, height: 34 / scale)
            }
            let texts = [
                StageText(title, at: titleOrigin, font: worldFont(look.labelFont), color: endpoint.isDeclaredOnly ? theme.colors.detail : theme.colors.title, tile: tile),
                StageText(line, at: lineOrigin, font: worldFont(look.detailFont), color: theme.colors.detail, tile: tile),
            ]
            let labelArea = camera.viewRect(area, in: viewSize)
            labels.append(NodeLabel(texts: texts, area: labelArea, node: camera.viewRect(frame, in: viewSize), importance: endpoint.traffic + (endpoint.kind == .otherMeep ? 0.5 : 0)))
        }

        // A domain with several endpoints is named once, just inside them, where few labels are.
        let ring = EdgeLayout.ellipse(around: meshBounds, margin: look.ringMargin)
        for (domain, members) in groups where members.count > 1 && !domain.isEmpty {
            let x = members.reduce(0) { $0 + cos($1.1) }, y = members.reduce(0) { $0 + sin($1.1) }
            let angle = atan2(y, x)
            let out = CGPoint(x: ring.center.x + ring.rx * 0.84 * CGFloat(cos(angle)), y: ring.center.y + ring.ry * 0.84 * CGFloat(sin(angle)))
            let font = look.groupFont
            let width = TextShaper.shared.width(of: domain, font: font) / scale
            let origin = CGPoint(x: out.x - width / 2, y: out.y)
            let text = StageText(domain, at: origin, font: worldFont(font), color: theme.colors.detail.with(alpha: 0.9), tile: "domain:\(domain)")
            let area = camera.viewRect(CGRect(x: origin.x, y: origin.y - 13 / scale, width: width, height: 16 / scale), in: viewSize)
            labels.append(NodeLabel(texts: [text], area: area, node: .zero, importance: -1))
        }
        flowParticles = flowParticles.filter { drawnIDs.contains($0.key) }
        return labels
    }

    /// An endpoint's colour: what meets it from the inside (a Listen's for clients, a Send's for what's sent to),
    /// Meep's for another Meep, grey past limits.
    func color(of endpoint: BoundaryEndpoint) -> StageColor {
        let look = theme.flows
        switch endpoint.kind {
        case .otherMeep: return look.otherMeep
        case .pastLimit: return look.pastLimit
        case .outside:
            let inbound = endpoint.links.contains { $0.direction == .inbound }
            let outbound = endpoint.links.contains { $0.direction == .outbound }
            return inbound && outbound ? look.observed : inbound ? look.inbound : look.outbound
        }
    }

    /// An endpoint's rates in words: in and out, failing and turned away.
    public static func ratesLine(_ endpoint: BoundaryEndpoint) -> String {
        if endpoint.isDeclaredOnly { return "declared: nothing sent yet" }
        var parts: [String] = []
        if endpoint.links.contains(where: { $0.direction == .inbound }) || endpoint.rateIn > 0 { parts.append("\(StageFormat.rate(endpoint.rateIn)) in") }
        if endpoint.links.contains(where: { $0.direction == .outbound }) || endpoint.rateOut > 0 { parts.append("\(StageFormat.rate(endpoint.rateOut)) out") }
        if endpoint.failed >= 0.05 { parts.append("\(StageFormat.rate(endpoint.failed)) failing") }
        if endpoint.rejected >= 0.05 { parts.append("\(StageFormat.rate(endpoint.rejected)) turned away") }
        return parts.joined(separator: "  ·  ")
    }

    /// One flow's line, curving to its left so flows both ways don't lie on each other, with an arrowhead at its end
    /// and, once seen, particles worked out in points on screen so they read at every zoom: one for each message while
    /// it's slow, a stream for its rate above that (design, section 4).
    func addFlowLine(
        id: String, from a: CGPoint, to b: CGPoint, bend: CGFloat, observed: Bool, rate: Double, count: Int64, trouble: Double,
        color: StageColor, opacity: Float, screen: CGRect, elapsed: Double, keep: (length: CGFloat, atEnd: Bool)? = nil,
        cable: Bool = false, into snapshot: inout StageSnapshot
    ) {
        guard opacity > 0.01 else { return }
        var points = cable ? Self.cable(from: a, to: b) : curve(from: a, to: b, bend: bend)
        if let keep { points = Self.cut(points, keeping: keep.length, atEnd: keep.atEnd) }
        let bounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let scale = camera.scale
        guard bounds.insetBy(dx: -20 / scale, dy: -20 / scale).intersects(screen) else { return }
        let look = theme.flows
        // Failing or turned away turns it toward red, by the share of what it carries.
        let share = rate > 0 ? min(trouble / rate, 1) : trouble > 0 ? 1 : 0
        var tint = color.mixed(with: theme.colors.error, by: Float(min(share * 1.5, 1)))
        tint = tint.with(alpha: tint.w * opacity * (observed ? 0.8 : 0.65))
        let hoveredHere = hovered == .flow(id)
        let wire = StageWire(
            id: "flow:\(id)", kind: observed ? .flow : .declared, points: points, color: tint, isHovered: hoveredHere,
            width: observed ? look.width(for: rate) : look.width
        )
        snapshot.wires.append(wire)
        drawnFlows.append((id, wire))
        // The arrowhead, a few points long, at the end.
        if points.count > 2, let end = points.last {
            let before = points[points.count - 3]
            let length = max(hypot(end.x - before.x, end.y - before.y), 0.0001)
            let ux = (end.x - before.x) / length, uy = (end.y - before.y) / length
            let size = 7 / scale
            let left = CGPoint(x: end.x - ux * size - uy * size * 0.6, y: end.y - uy * size + ux * size * 0.6)
            let right = CGPoint(x: end.x - ux * size + uy * size * 0.6, y: end.y - uy * size - ux * size * 0.6)
            snapshot.wires.append(StageWire(id: "arrow:\(id)", kind: .flow, points: [left, end, right], color: tint, width: observed ? look.width(for: rate) : look.width))
        }
        guard observed else { return }
        let path = StageWire(id: wire.id, kind: .flow, points: points.map { camera.viewPoint($0, in: viewSize) }, color: tint)
        var particles = flowParticles[id] ?? Flow()
        particles.observe(count, rate: rate, at: time)
        particles.advance(to: time, by: elapsed, rate: rate, length: path.length)
        flowParticles[id] = particles
        let dot = tint.mixed(with: theme.colors.highlight, by: theme.particles.lighten).with(alpha: min(1, opacity * 1.1))
        if particles.showsRate, rate > 0 {
            snapshot.streams.append(ParticleStream(
                path: wire, spacing: Flow.spacing(for: rate) / scale, phase: particles.phase / scale, color: dot, size: 1.5 / scale, style: .rate
            ))
        }
        for start in particles.travelling {
            let along = CGFloat(time - start) * Flow.messageSpeed / scale
            guard along <= wire.length else { continue }
            let spot = wire.point(at: along)
            snapshot.particles.append(StageParticle(position: spot.point, direction: spot.direction, color: dot, size: 2.3 / scale, style: .message, owner: wire.id))
        }
    }

    /// Only `length` of a path, from its start, or up to its end.
    static func cut(_ points: [CGPoint], keeping length: CGFloat, atEnd: Bool) -> [CGPoint] {
        let path = atEnd ? Array(points.reversed()) : points
        var kept = [path[0]]
        var left = length
        for (p, q) in zip(path, path.dropFirst()) {
            let step = hypot(q.x - p.x, q.y - p.y)
            if step >= left {
                let t = step > 0 ? left / step : 0
                kept.append(CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))
                break
            }
            kept.append(q)
            left -= step
        }
        return atEnd ? kept.reversed() : kept
    }

    /// A cable from `a` to `b`: leaving rightward and arriving from the left, looping round when `b` is behind `a`.
    static func cable(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        let dx = b.x - a.x, dy = b.y - a.y
        let reach = dx > 0 ? max(dx * 0.5, min(abs(dy) * 0.3, 600), 60) : max(abs(dy) * 0.6, -dx * 0.25, 160)
        let c1 = CGPoint(x: a.x + reach, y: a.y), c2 = CGPoint(x: b.x - reach, y: b.y)
        return (0...32).map { step -> CGPoint in
            let t = CGFloat(step) / 32
            let u = 1 - t
            let (w0, w1, w2, w3) = (u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t)
            let x: CGFloat = w0 * a.x + w1 * c1.x + w2 * c2.x + w3 * b.x
            let y: CGFloat = w0 * a.y + w1 * c1.y + w2 * c2.y + w3 * b.y
            return CGPoint(x: x, y: y)
        }
    }

    /// The frame of the tile or block a flow's end is drawn at, when its pipeline shows them.
    func tileFrame(_ address: MeepAddress) -> CGRect? {
        guard let pipeline = address.pipeline, let key = address.module,
              let district = districtPlaces["\(address.host)/\(pipeline)"]?.at(time), district.width * camera.scale > 50 else { return nil }
        return stages["\(address.host)/\(pipeline)"]?.tileFrames.first { $0.key == key }?.frame
    }

    /// A gentle curve from `a` to `b`, bowing to the left of the way it runs by `bend` of its length.
    func curve(from a: CGPoint, to b: CGPoint, bend: CGFloat) -> [CGPoint] {
        let dx = b.x - a.x, dy = b.y - a.y
        let control = CGPoint(x: (a.x + b.x) / 2 + dy * bend, y: (a.y + b.y) / 2 - dx * bend)
        return (0...20).map { step -> CGPoint in
            let t = CGFloat(step) / 20
            let u = 1 - t
            let (wa, wc, wb) = (u * u, 2 * u * t, t * t)
            let x: CGFloat = wa * a.x + wc * control.x + wb * b.x
            let y: CGFloat = wa * a.y + wc * control.y + wb * b.y
            return CGPoint(x: x, y: y)
        }
    }

    /// The point `distance` from `point` toward `target`.
    func toward(_ point: CGPoint, _ target: CGPoint, by distance: CGFloat) -> CGPoint {
        let length = hypot(target.x - point.x, target.y - point.y)
        guard length > 0.0001 else { return point }
        return CGPoint(x: point.x + (target.x - point.x) / length * distance, y: point.y + (target.y - point.y) / length * distance)
    }

    /// The middle of what an end of a flow is drawn on: its district, or its host.
    func centre(of address: MeepAddress) -> CGPoint? {
        if let pipeline = address.pipeline, let frame = districtPlaces["\(address.host)/\(pipeline)"]?.at(time) {
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        return hostPlaces[address.host].map { let frame = $0.at(time); return CGPoint(x: frame.midX, y: frame.midY) }
    }

    /// Where a flow meets a module: the side of its tile it faces (a Send's right, a Listen's left) while its blocks
    /// or tiles show; otherwise the edge of its district, or its host, toward the other end.
    func anchor(_ address: MeepAddress, outgoing: Bool, toward other: CGPoint) -> CGPoint? {
        guard let hostFrame = hostPlaces[address.host]?.at(time) else { return nil }
        if let pipeline = address.pipeline, let district = districtPlaces["\(address.host)/\(pipeline)"]?.at(time) {
            if let key = address.module, district.width * camera.scale > 50,
               let tile = stages["\(address.host)/\(pipeline)"]?.tileFrames.first(where: { $0.key == key }) {
                return CGPoint(x: outgoing ? tile.frame.maxX : tile.frame.minX, y: tile.frame.midY)
            }
            return border(of: district, toward: other)
        }
        return border(of: hostFrame, toward: other)
    }

    /// Where the line from a rectangle's middle to `point` leaves it.
    func border(of rect: CGRect, toward point: CGPoint) -> CGPoint {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let dx = point.x - centre.x, dy = point.y - centre.y
        guard abs(dx) > 0.0001 || abs(dy) > 0.0001 else { return centre }
        let tx = abs(dx) > 0.0001 ? rect.width / 2 / abs(dx) : .infinity
        let ty = abs(dy) > 0.0001 ? rect.height / 2 / abs(dy) : .infinity
        let t = min(tx, ty, 1)
        return CGPoint(x: centre.x + dx * t, y: centre.y + dy * t)
    }

    // MARK: Pointer

    /// The endpoint whose marker is under `point`, in view points.
    func endpoint(at point: CGPoint) -> String? {
        let world = camera.worldPoint(point, in: viewSize)
        let slack = 3 / camera.scale
        return drawnEndpoints.reversed().first { $0.frame.insetBy(dx: -slack, dy: -slack).contains(world) }?.id
    }

    /// The flow whose line passes within a few points of `point`.
    func flow(at point: CGPoint) -> String? {
        let world = camera.worldPoint(point, in: viewSize)
        var best: (id: String, distance: CGFloat)?
        for (id, wire) in drawnFlows {
            let distance = wire.distance(to: world) * camera.scale
            if distance < 5, distance < (best?.distance ?? .infinity) { best = (id, distance) }
        }
        return best?.id
    }

    /// What a flow drawn between hosts carries, added up, for hover cards and tools.
    public func hostFlow(_ id: String) -> (from: String, to: String, flows: [MeshFlow])? {
        guard id.hasPrefix("hosts:") else { return nil }
        let names = id.dropFirst("hosts:".count).split(separator: ">").map(String.init)
        guard names.count == 2 else { return nil }
        return (names[0], names[1], flowMap.flows.filter { $0.from.host == names[0] && $0.to.host == names[1] })
    }

    /// The endpoint and link a line to the boundary stands for, by the line's ID: a link's, or an endpoint's lines to a
    /// host drawn as a node.
    public func boundaryLink(_ id: String) -> (BoundaryEndpoint, BoundaryLink?)? {
        for endpoint in flowMap.boundary {
            if let link = endpoint.links.first(where: { $0.id == id }) { return (endpoint, link) }
            if id.hasPrefix(endpoint.id + "|") { return (endpoint, nil) }
        }
        return nil
    }

    /// The flows and endpoints on screen now, for describing the view.
    public var flowsOnScreen: [String] { drawnFlows.map(\.id) }
    public var endpointsOnScreen: [(id: String, frame: CGRect)] {
        drawnEndpoints.map { ($0.id, camera.viewRect($0.frame, in: viewSize)) }
    }
}
