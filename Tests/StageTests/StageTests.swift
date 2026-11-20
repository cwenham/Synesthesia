@testable import ContinuumKit
import CoreGraphics
import CoreText
import Foundation
import MeepClient
import Simulation
import Testing
@testable import Stage

/// A simulated host's pipeline, filled in by a session, with the session still running so its counts go on rising.
@MainActor
func simulated(
    _ name: String, statsEvery: Duration = .milliseconds(30), pipelines: [PipelineSpec] = PipelineSpec.demo
) async throws -> (MeepPipeline, MeepHost, HostSession) {
    let continuum = Continuum()
    let host = continuum.add(host: "sim", kind: .simulated)
    let link = SimulatedHost(name: "sim", latency: .milliseconds(1), pipelines: pipelines)
    let session = HostSession(host: host, settings: .init(leastDetail: .modules, replanEvery: .milliseconds(30), rateScale: statsEvery < .milliseconds(100) ? 0.1 : 1)) { link }
    session.start()
    let deadline = ContinuousClock.now + .seconds(20)
    while host.pipeline(name)?.links.first?.isCounted != true || host.pipeline(name)?.modules.first?.role == nil {
        guard ContinuousClock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(10))
    }
    return (host.pipeline(name)!, host, session)
}

@MainActor
struct PipelineStageTests {
    let size = CGSize(width: 1200, height: 700)

    @Test func modulesBecomeTilesShapedByRole() async throws {
        let (pipeline, host, session) = try await simulated("orders")
        defer { session.stop() }
        let stage = PipelineStage(pipeline: pipeline, host: host)
        let snapshot = stage.frame(at: 1, viewSize: size)
        #expect(snapshot.tiles.map(\.id) == ["m1", "m2", "m3", "m4", "m5", "m6"])
        #expect(snapshot.tiles.map(\.shape) == [.receive, .filter, .rectangle, .send, .send, .send])
        #expect(snapshot.wires.map(\.id) == ["m1>m2", "m2>m3", "m3>m4", "m3>m5", "m3>m6"])
        #expect(snapshot.wires.first { $0.id == "m3>m6" }?.kind == .errors)
        for (i, a) in snapshot.tiles.enumerated() {
            for b in snapshot.tiles.dropFirst(i + 1) {
                #expect(!a.frame.intersects(b.frame), "\(a.id) and \(b.id) overlap")
            }
        }
        // Each wire leaves its source's right edge and reaches its target's left edge.
        let faces = Dictionary(uniqueKeysWithValues: snapshot.tiles.map { ($0.id, $0.frame) })
        for wire in snapshot.wires {
            let ends = wire.id.split(separator: ">").map(String.init)
            let (from, to) = (faces[ends[0]]!, faces[ends[1]]!)
            #expect(abs(wire.points.first!.y - from.midY) < 0.5)
            #expect(wire.points.first!.x > from.midX && wire.points.first!.x <= from.maxX)
            #expect(wire.points.last!.x < to.midX && wire.points.last!.x >= to.minX)
        }
        // A chain of single links runs straight.
        #expect(abs(faces["m1"]!.midY - faces["m2"]!.midY) < 0.5)
        #expect(snapshot.texts.contains { $0.string == "Orders" })
    }

    @Test func everythingFitsInTheView() async throws {
        let (pipeline, host, session) = try await simulated("warehouse")
        defer { session.stop() }
        let stage = PipelineStage(pipeline: pipeline, host: host)
        let snapshot = stage.frame(at: 1, viewSize: size)
        for tile in snapshot.tiles {
            let shown = snapshot.camera.viewRect(tile.frame, in: size)
            #expect(CGRect(origin: .zero, size: size).contains(shown), "\(tile.id) at \(shown)")
        }
    }

    @Test func particlesFollowTheCounts() async throws {
        // Busy enough that its errors and drops are always on screen.
        let spec = PipelineSpec(name: "faulty", modules: [
            .init("Listen", .inlet, name: "Readings", rate: 2400),
            .init("Classify", .step, from: [0], passes: 0.01, fails: 0.01),
            .init("Send", .outlet, name: "Alerts", from: [1], drops: 0.3),
            .init("Save", .outlet, name: "Rejects", from: [1], errorsOnly: true),
        ])
        let (pipeline, host, session) = try await simulated("faulty", pipelines: [spec])
        // The test gives the counts for each moment itself, so what it sees doesn't depend on how soon a busy machine
        // delivers them: in a full run, other suites keep the main actor busy and the session's counts fall behind.
        session.stop()
        let stage = PipelineStage(pipeline: pipeline, host: host)
        let started = Date()
        var snapshot = StageSnapshot()
        // Three seconds, a frame every 20 milliseconds, with the counts as they are at each.
        for step in 0...150 {
            let seconds = 10 + Double(step) * 0.02
            pipeline.apply(PipelineDetail(
                name: spec.name, path: spec.path, state: .running, started: started, modules: spec.counts(at: seconds),
                graphVersion: spec.graph.version, links: spec.linkCounts(at: seconds)
            ), at: seconds)
            snapshot = stage.frame(at: seconds, viewSize: size)
        }
        // Readings arrive at thousands a second, so their wire shows a rate, not single messages.
        let readings = try #require(snapshot.streams.first { $0.path.id == "m1>m2" })
        #expect(readings.style == .rate)
        #expect(readings.spacing < Flow.spacing(for: 10))
        // Classify fails about 24 a second, and its errors go to Rejects in red.
        let rejects = stage.link("m2>m4")?.live
        #expect(snapshot.streams.contains { $0.path.id == "m2>m4" && $0.color == Theme.standard.colors.error },
                "errors at \(rejects?.errorRate ?? -1)/s, \(rejects?.errors ?? -1) so far")
        // Alerts drops some: they spill off its tile.
        #expect(snapshot.overStreams.contains { $0.path.id == "m3.dropped" }
            || snapshot.overParticles.contains { $0.color.x == Theme.standard.colors.dropped.x })
    }

    @Test func aHostThatCantBeReachedIsDrawnGreyWithoutParticles() async throws {
        let (pipeline, host, session) = try await simulated("orders")
        let stage = PipelineStage(pipeline: pipeline, host: host)
        _ = stage.frame(at: 1, viewSize: size)
        session.stop()
        host.status = .unreachable("gone")
        let snapshot = stage.frame(at: 2, viewSize: size)
        #expect(snapshot.tiles.filter { !$0.isDimmed }.isEmpty)
        #expect(snapshot.streams.isEmpty && snapshot.particles.isEmpty)
        #expect(!snapshot.texts.contains { $0.string.hasSuffix("/s") }, "no rates while they aren't current")
    }

    @Test func pointingFindsTilesThenWires() async throws {
        let (pipeline, host, session) = try await simulated("orders")
        defer { session.stop() }
        let stage = PipelineStage(pipeline: pipeline, host: host)
        let snapshot = stage.frame(at: 1, viewSize: size)
        let valid = try #require(snapshot.tiles.first { $0.id == "m2" })
        let middle = snapshot.camera.viewPoint(CGPoint(x: valid.frame.midX, y: valid.frame.midY - 10), in: size)
        #expect(stage.hit(at: middle) == .tile("m2"))
        let wire = try #require(snapshot.wires.first { $0.id == "m1>m2" })
        let along = snapshot.camera.viewPoint(wire.point(at: wire.length / 2).point, in: size)
        #expect(stage.hit(at: along) == .wire("m1>m2"))
        #expect(stage.hit(at: CGPoint(x: 2, y: 2)) == nil)

        stage.hover(at: middle)
        #expect(stage.hovered == .tile("m2"))
        #expect(stage.frame(at: 1.1, viewSize: size).tiles.first { $0.id == "m2" }?.isHovered == true)
    }

    @Test func clickingSelectsAndCommandClickingAddsOrRemoves() async throws {
        let (pipeline, host, session) = try await simulated("orders")
        defer { session.stop() }
        let stage = PipelineStage(pipeline: pipeline, host: host)
        let snapshot = stage.frame(at: 1, viewSize: size)
        func centre(_ key: String) -> CGPoint {
            let frame = snapshot.tiles.first { $0.id == key }!.frame
            return snapshot.camera.viewPoint(CGPoint(x: frame.midX, y: frame.midY - 8), in: size)
        }
        stage.click(at: centre("m1"))
        #expect(stage.selection == ["m1"])
        stage.click(at: centre("m3"), modifiers: .command)
        #expect(stage.selection == ["m1", "m3"])
        stage.click(at: centre("m1"), modifiers: .command)
        #expect(stage.selection == ["m3"])
        stage.click(at: CGPoint(x: 2, y: 2))
        #expect(stage.selection.isEmpty)
    }

    @Test func zoomingStepsAreEasedAndFittingFollowsTheLayout() async throws {
        let (pipeline, host, session) = try await simulated("ticker")
        defer { session.stop() }
        let stage = PipelineStage(pipeline: pipeline, host: host)
        let fitted = stage.frame(at: 1, viewSize: size).camera
        stage.step(zoomingIn: true)
        let partWay = stage.frame(at: 1.2, viewSize: size).camera
        let done = stage.frame(at: 3, viewSize: size).camera
        #expect(partWay.scale > fitted.scale && partWay.scale < done.scale)
        #expect(abs(done.scale - fitted.scale * 1.5) < 0.001)
        stage.fit()
        #expect(abs(stage.frame(at: 5, viewSize: size).camera.scale - fitted.scale) < 0.001)
    }
}

struct FlowTests {
    @Test func slowCountsMakeOneParticleEach() {
        var flow = Flow()
        flow.observe(10, rate: 1, at: 0)
        flow.advance(to: 0, by: 0, rate: 1, length: 500)
        #expect(flow.travelling.isEmpty, "what came before the first reading isn't drawn")
        flow.observe(13, rate: 1, at: 1)
        flow.advance(to: 1, by: 1, rate: 1, length: 500)
        #expect(flow.travelling.count == 1, "three new messages, spread over the second they took")
        flow.advance(to: 1.9, by: 0.9, rate: 1, length: 500)
        #expect(flow.travelling.count == 3)
        #expect(!flow.showsRate)
        // Each lasts as long as it takes to cross the wire.
        flow.advance(to: 1 + 500 / Double(Flow.messageSpeed) + 1, by: 1, rate: 1, length: 500)
        #expect(flow.travelling.isEmpty)
    }

    @Test func fastCountsShowTheRateWithoutFlickering() {
        var flow = Flow()
        flow.observe(0, rate: 0, at: 0)
        flow.observe(100, rate: 6, at: 1)
        #expect(flow.showsRate)
        flow.observe(104, rate: 4, at: 2)
        #expect(flow.showsRate, "between the two thresholds it stays as it was")
        flow.observe(106, rate: 2, at: 3)
        #expect(!flow.showsRate)
    }

    @Test func busierWiresAreDenserButNeverFull() {
        let rates: [Double] = [5, 50, 500, 5_000, 50_000, 5_000_000]
        let spacings = rates.map(Flow.spacing(for:))
        #expect(spacings == spacings.sorted(by: >))
        #expect(spacings.last! >= 7)
        #expect(Flow.streamSpeed(for: 5_000_000) <= Flow.messageSpeed * 2.5)
    }

    @Test func aRestartCountsFromZeroWithoutABurst() {
        var flow = Flow()
        flow.observe(1000, rate: 1, at: 0)
        flow.observe(2, rate: 1, at: 1)
        flow.advance(to: 1, by: 1, rate: 1, length: 500)
        #expect(flow.travelling.isEmpty)
    }

    @Test func queuesPileUpSlowly() {
        #expect(PipelineStage.pileSize(for: 0) == 0)
        #expect(PipelineStage.pileSize(for: 5) == 5)
        #expect(PipelineStage.pileSize(for: 16) == 12)
        #expect(PipelineStage.pileSize(for: 1_000_000) == 30)
    }
}

struct CameraTests {
    let size = CGSize(width: 800, height: 600)

    @Test func zoomingKeepsThePointUnderThePointer() {
        let camera = Camera(center: CGPoint(x: 100, y: 50), scale: 1.2)
        let anchor = CGPoint(x: 620, y: 140)
        let before = camera.worldPoint(anchor, in: size)
        let zoomed = camera.zoomed(by: 1.7, at: anchor, in: size)
        let after = zoomed.worldPoint(anchor, in: size)
        #expect(abs(before.x - after.x) < 0.0001 && abs(before.y - after.y) < 0.0001)
        #expect(camera.zoomed(by: 1000, at: anchor, in: size).scale == Camera.maximumScale)
    }

    @Test func pointsGoThereAndBack() {
        let camera = Camera(center: CGPoint(x: -40, y: 300), scale: 0.6)
        let world = CGPoint(x: 12, y: 345)
        let back = camera.worldPoint(camera.viewPoint(world, in: size), in: size)
        #expect(abs(back.x - world.x) < 0.0001 && abs(back.y - world.y) < 0.0001)
    }

    @Test func fittingShowsAllOfIt() {
        let rect = CGRect(x: 0, y: 0, width: 2000, height: 300)
        let camera = Camera.fitting(rect, in: size)
        let shown = camera.viewRect(rect, in: size)
        #expect(shown.minX >= 0 && shown.maxX <= size.width && shown.minY >= 0 && shown.maxY <= size.height)
        #expect(Camera.fitting(CGRect(x: 0, y: 0, width: 10, height: 10), in: size).scale == 1.5, "small things aren't blown up")
    }

    @Test func easingStartsFastAndSettles() {
        let easing = Easing(from: Camera(scale: 1), to: Camera(scale: 4), start: 0, duration: 1)
        #expect(easing.value(at: 0).scale == 1)
        #expect(easing.value(at: 0.25).scale > 2, "most of the way in the first quarter")
        #expect(abs(easing.value(at: 1).scale - 4) < 0.0001)
        #expect(easing.isDone(at: 1))
    }
}

struct GeometryTests {
    @Test(arguments: TileShape.allCases)
    func edgesMeetTheOutlineAtTheMiddle(shape: TileShape) {
        let size = Theme.standard.tiles.size(for: shape)
        let right = shape.rightEdge(atY: 0, size: size)
        let left = shape.leftEdge(atY: 0, size: size)
        #expect(right > 0 && left < 0)
        #expect(shape.contains(CGPoint(x: (left + right) / 2, y: 0), size: size))
        #expect(!shape.contains(CGPoint(x: right + 5, y: 0), size: size))
    }

    @Test func wiresLeaveAndArriveLevel() {
        let points = WireRouter.route(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 80), through: [])
        #expect(points.first == CGPoint(x: 0, y: 0) && points.last == CGPoint(x: 200, y: 80))
        #expect(abs(points[1].y - points[0].y) < abs(points[1].x - points[0].x) * 0.2)
        let end = points.count - 1
        #expect(abs(points[end].y - points[end - 1].y) < abs(points[end].x - points[end - 1].x) * 0.2)
    }

    @Test func wiresAreMeasuredAlong() {
        let wire = StageWire(id: "w", kind: .main, points: [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 40), CGPoint(x: 30, y: 50)], color: .zero)
        #expect(wire.length == 60)
        #expect(wire.point(at: 25).point == CGPoint(x: 15, y: 20))
        #expect(wire.point(at: 55).point == CGPoint(x: 30, y: 45))
        #expect(abs(wire.distance(to: CGPoint(x: 40, y: 45)) - 10) < 0.0001)
    }
}

@MainActor
struct TextTests {
    @Test func labelsAreMeasuredAndCutShort() {
        let shaper = TextShaper.shared
        let width = shaper.width(of: "WriteLine #6", font: Theme.standard.labels.titleFont)
        #expect(width > 50 && width < 120)
        #expect(shaper.width(of: "W", font: StageFont(size: 26)) > shaper.width(of: "W", font: StageFont(size: 13)) * 1.9)
        let cut = shaper.truncated("a parameter far too long to show under a tile", font: Theme.standard.labels.detailFont, width: 120)
        #expect(cut.hasSuffix("…") && shaper.width(of: cut, font: Theme.standard.labels.detailFont) <= 120)
        #expect(shaper.truncated("short", font: Theme.standard.labels.detailFont, width: 120) == "short")
    }

    @Test func boldIsBold() {
        let regular = CTFontCopyPostScriptName(TextShaper.shared.font(StageFont(size: 13))) as String
        let semibold = CTFontCopyPostScriptName(TextShaper.shared.font(StageFont(size: 13, weight: .semibold))) as String
        #expect(regular != semibold, "\(regular) and \(semibold)")
    }
}

@MainActor
struct ProposalTests {
    let size = CGSize(width: 1100, height: 560)

    @Test func aProposalShowsWhatItAddsChangesAndTakesOut() async throws {
        let (pipeline, host, session) = try await simulated("orders")
        defer { session.stop() }
        let stage = PipelineStage(pipeline: pipeline, host: host)
        var graph = try #require(pipeline.graph)
        let removed = try #require(graph.modules.last)
        graph.modules.removeLast()
        graph.links.removeAll { $0.to == removed.key || $0.from == removed.key }
        graph.modules[1].parameters = [GraphParameter(text: "changed", span: graph.modules[1].span)]
        graph.modules.append(GraphModule(key: "m99", number: 99, module: "Gate", verb: "Where", role: .filter, span: graph.modules[0].span, name: "Gate", under: graph.modules[0].key))
        graph.links.append(GraphLink(from: graph.modules[0].key, to: "m99"))
        stage.show(proposal: ProposalGraph(graph: graph, added: ["m99"]))

        let snapshot = stage.frame(at: 1, viewSize: size)
        #expect(stage.module("m99")?.isProposed == true)
        #expect(stage.module(removed.key)?.isRemoved == true)
        #expect(stage.module(graph.modules[1].key)?.isChanged == true)
        #expect(stage.module(graph.modules[0].key)?.isChanged == false)
        let gate = try #require(snapshot.tiles.first { $0.id == "m99" })
        #expect(gate.isGhost && gate.color == Theme.standard.colors.proposed)
        #expect(snapshot.tiles.first { $0.id == removed.key }?.color == Theme.standard.colors.error)
        #expect(snapshot.texts.contains { $0.tile == "m99" && $0.string == "proposed" })
        #expect(snapshot.texts.contains { $0.tile == removed.key && $0.string == "to be removed" })
        #expect(stage.link("\(graph.modules[0].key)>m99")?.isProposed == true)

        // Rejected: what runs comes back.
        stage.show(proposal: nil)
        _ = stage.frame(at: 2, viewSize: size)
        #expect(stage.module("m99") == nil)
        #expect(stage.module(removed.key)?.isRemoved == false)
    }
}

@MainActor
struct ProbeDrawingTests {
    let size = CGSize(width: 1100, height: 560)

    @Test func aProbesMarkAndItsMessagesAreDrawnAndOpenWhenClicked() async throws {
        let (pipeline, host, session) = try await simulated("orders")
        defer { session.stop() }
        let stage = PipelineStage(pipeline: pipeline, host: host)
        let source = try #require(pipeline.modules.first)
        let probe = Probe(pipeline: pipeline, host: host, target: .module(source.key), colorIndex: 1)
        stage.probes = [probe]
        probe.start()
        try await waitFor { probe.seen > 0 }
        var snapshot = stage.frame(at: 1, viewSize: size)
        let mark = try #require(snapshot.overParticles.first { $0.owner == "probe:\(probe.id)" })
        #expect(mark.style == .tracer && mark.color == PipelineStage.color(ofProbe: 1))
        try await waitFor {
            snapshot = stage.frame(at: 1, viewSize: size)
            return snapshot.overParticles.contains { $0.owner.hasPrefix("tracer:") }
        }
        probe.stop()
        // Clicking the mark opens the probe.
        let point = snapshot.camera.viewPoint(mark.position, in: size)
        stage.click(at: point)
        #expect(stage.openedMessage?.probe == probe.id)
        #expect(stage.selection.isEmpty)
    }

    @Test func aMessagesPathIsEverythingDownstreamThatTakesThem() async throws {
        let (pipeline, host, session) = try await simulated("warehouse")
        defer { session.stop() }
        let stage = PipelineStage(pipeline: pipeline, host: host)
        _ = stage.frame(at: 1, viewSize: size)
        let first = try #require(pipeline.modules.first)
        let path = stage.path(from: first.key)
        #expect(path.contains(first.key))
        for link in pipeline.links where path.contains(link.from) && link.port != .errors {
            #expect(path.contains(link.key) && path.contains(link.to))
        }
        #expect(!pipeline.links.contains { $0.port == .errors && path.contains($0.key) })
    }
}

/// Waits up to ten seconds for `condition`.
@MainActor
func waitFor(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
struct TileDragTests {
    let size = CGSize(width: 1100, height: 560)

    @Test func aDraggedTileFollowsThePointerAndLightsOnlyWhereItCanGo() async throws {
        let (pipeline, host, session) = try await simulated("warehouse")
        defer { session.stop() }
        let stage = PipelineStage(pipeline: pipeline, host: host)
        _ = stage.frame(at: 1, viewSize: size)
        let graph = try #require(pipeline.graph)
        let child = try #require(graph.modules.first { $0.under != nil })
        let parent = try #require(child.under)
        let other = try #require(graph.modules.first { $0.key != child.key && $0.key != parent && !BranchDescendants.of(child.key, in: graph).contains($0.key) })

        #expect(stage.canMove(child.key, under: other.key))
        #expect(!stage.canMove(child.key, under: child.key), "not under itself")
        #expect(!stage.canMove(child.key, under: parent), "not where it is already")
        #expect(!stage.canMove(parent, under: child.key), "not under what's under it")

        // Over another tile, that tile is lit, and the ghost is drawn under the pointer.
        let over = try #require(stage.viewFrame(of: other.key))
        stage.dragTile(child.key, to: CGPoint(x: over.midX, y: over.midY))
        #expect(stage.dropTarget == .tile(other.key))
        let snapshot = stage.frame(at: 2, viewSize: size)
        let ghost = try #require(snapshot.tiles.last)
        #expect(ghost.id == "\(child.key).dragged" && ghost.isGhost)
        #expect(stage.endTileDrag() == other.key)
        #expect(stage.dropTarget == nil)

        // Over its own parent, nothing is lit and nothing would happen.
        let home = try #require(stage.viewFrame(of: parent))
        stage.dragTile(child.key, to: CGPoint(x: home.midX, y: home.midY))
        #expect(stage.dropTarget == nil)
        #expect(stage.endTileDrag() == nil)
        #expect(stage.frame(at: 3, viewSize: size).tiles.allSatisfy { !$0.id.hasSuffix(".dragged") })
    }
}

/// Everything under a module in a graph.
enum BranchDescendants {
    static func of(_ key: String, in graph: PipelineGraph) -> Set<String> {
        var found: Set<String> = []
        var frontier = [key]
        while let next = frontier.popLast() {
            for module in graph.modules where module.under == next && found.insert(module.key).inserted { frontier.append(module.key) }
        }
        return found
    }
}

@MainActor
struct ThemeTests {
    let size = CGSize(width: 1200, height: 700)

    @Test func aThemeSurvivesJSON() throws {
        var theme = Theme.standard
        theme.name = "Copy"
        theme.roles.filter.shape = .circle
        theme.tiles.shadow.offset = CGVector(dx: -3, dy: 9)
        let data = try JSONEncoder().encode(theme)
        #expect(try JSONDecoder().decode(Theme.self, from: data) == theme)
    }

    @Test func theStageDrawsWithTheCurrentThemeAndLaysOutAgainWhenTilesChange() async throws {
        let (pipeline, host, session) = try await simulated("orders")
        defer { session.stop() }
        let stage = PipelineStage(pipeline: pipeline, host: host)
        // No awaits from here, so no other test sees the theme changed.
        let before = stage.frame(at: 1, viewSize: size)
        let wide = before.tiles.first { $0.shape == .rectangle }!.frame.width
        var theme = Theme.standard
        theme.tiles.rectangleWidth = 160
        theme.roles.step.color = StageColor(hex: 0x123456)
        Theme.current = theme
        defer { Theme.current = .standard }
        let after = stage.frame(at: 1.1, viewSize: size)
        let tile = after.tiles.first { $0.shape == .rectangle }!
        #expect(after.theme == theme)
        #expect(tile.frame.width == 160 && wide == Theme.standard.tiles.rectangleWidth)
        #expect(tile.color == StageColor(hex: 0x123456))
    }

    @Test func theStarfieldFadesInEasesUpToSpeedAndFadesOut() async throws {
        let (pipeline, host, session) = try await simulated("orders")
        defer { session.stop() }
        let stage = PipelineStage(pipeline: pipeline, host: host)
        var time = 10.0
        var snapshot = stage.frame(at: time, viewSize: size)
        #expect(snapshot.starOpacity == 0 && snapshot.starSpeed == 0, "it starts still and unseen")
        for _ in 0..<240 {
            time += 1.0 / 60
            snapshot = stage.frame(at: time, viewSize: size)
        }
        let speed = Theme.standard.starfield.speed
        #expect(snapshot.starOpacity > 0.99)
        #expect(abs(snapshot.starSpeed - speed) < speed * 0.01)
        #expect(snapshot.starTravel > 0)

        var off = Theme.standard
        off.starfield.isOn = false
        Theme.current = off
        defer { Theme.current = .standard }
        for _ in 0..<240 {
            time += 1.0 / 60
            snapshot = stage.frame(at: time, viewSize: size)
        }
        #expect(snapshot.starOpacity == 0)
    }
}
