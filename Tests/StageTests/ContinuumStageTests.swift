@testable import ContinuumKit
import CoreGraphics
import Foundation
import MeepClient
import Simulation
import Testing
import TestSupport
@testable import Stage

/// The continuous zoom (design, section 2): hosts and their pipelines in one world, drawn at the level the camera is
/// at, and asking each host only for what's shown.
@MainActor
@Suite(.simulatedHosts)
struct ContinuumStageTests {
    let size = CGSize(width: 1200, height: 800)

    /// Two simulated hosts, with their graphs in.
    private func mesh() async throws -> (Continuum, [HostSession]) {
        let continuum = Continuum()
        var sessions: [HostSession] = []
        for (name, pipelines) in [("west", Array(PipelineSpec.demo.prefix(2))), ("east", PipelineSpec.demo)] {
            let host = continuum.add(host: name, kind: .simulated)
            let link = SimulatedHost(name: name, latency: .milliseconds(1), pipelines: pipelines)
            let session = HostSession(host: host, settings: .init(replanEvery: .milliseconds(30), rateScale: 0.1)) { link }
            session.start()
            sessions.append(session)
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while continuum.hosts.contains(where: { $0.pipelines.isEmpty || $0.pipelines.contains { $0.graph == nil } }) {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
        return (continuum, sessions)
    }

    /// Draws frames for `seconds` of the stage's clock, so easing and settling run, without waiting that long.
    private func run(_ canvas: ContinuumStage, from time: inout Double, for seconds: Double) {
        let end = time + seconds
        while time < end {
            time += 1.0 / 60
            _ = canvas.frame(at: time, viewSize: size)
        }
    }

    @Test func pipelinesAreDistrictsOnTheirHostsPlates() async throws {
        let (continuum, sessions) = try await mesh()
        defer { sessions.forEach { $0.stop() } }
        let canvas = ContinuumStage(continuum: continuum)
        var time = 1.0
        run(canvas, from: &time, for: 0.1)
        let west = try #require(canvas.frame(of: MeepAddress(host: "west")))
        let east = try #require(canvas.frame(of: MeepAddress(host: "east")))
        #expect(!west.intersects(east))
        for host in continuum.hosts {
            let plate = try #require(canvas.frame(of: host.address))
            var districts: [CGRect] = []
            for pipeline in host.pipelines {
                let district = try #require(canvas.frame(of: pipeline.address))
                #expect(plate.contains(district))
                #expect(!districts.contains { $0.intersects(district) }, "districts don't overlap")
                districts.append(district)
                // The pipeline's own stage draws it there, in the same world.
                let stage = canvas.stage(for: pipeline)
                #expect(district.contains(stage.layoutBounds))
            }
        }
    }

    @Test func showingSomethingZoomsToItAndSetsTheLevel() async throws {
        let (continuum, sessions) = try await mesh()
        defer { sessions.forEach { $0.stop() } }
        let canvas = ContinuumStage(continuum: continuum)
        var time = 1.0
        run(canvas, from: &time, for: 0.1)
        #expect(canvas.level == .mesh)

        let warehouse = MeepAddress(host: "east", pipeline: "warehouse")
        canvas.show(warehouse)
        #expect(canvas.level == .pipeline)
        #expect(canvas.focus == warehouse)
        run(canvas, from: &time, for: 1)
        let district = try #require(canvas.frame(of: warehouse))
        let shown = canvas.currentCamera.viewRect(district, in: size)
        #expect(CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1).contains(shown), "the whole pipeline is in view")
        #expect(shown.width > size.width * 0.6 || shown.height > size.height * 0.6)
        let snapshot = canvas.frame(at: time, viewSize: size)
        #expect(snapshot.tiles.count >= 11, "its tiles are drawn")
        #expect(continuum.pipeline(at: warehouse)?.shownAs == .full, "the pipeline in focus is asked for in full")

        canvas.show(MeepAddress(host: "west"))
        #expect(canvas.level == .host)
        run(canvas, from: &time, for: 1)
        #expect(continuum.pipeline(at: warehouse)?.shownAs != .full, "out of focus, it's asked for less")

        canvas.show(nil)
        #expect(canvas.level == .mesh)
        #expect(canvas.focus == nil)
    }

    @Test func movingTheViewSettlesOnWhatFillsIt() async throws {
        let (continuum, sessions) = try await mesh()
        defer { sessions.forEach { $0.stop() } }
        let canvas = ContinuumStage(continuum: continuum)
        var focused: [MeepAddress?] = []
        canvas.onFocus = { focused.append($0) }
        var time = 1.0
        run(canvas, from: &time, for: 0.1)
        canvas.show(MeepAddress(host: "east", pipeline: "orders"), animated: false)
        run(canvas, from: &time, for: 0.2)
        // Zooming out a long way, around the middle, ends on the mesh, once the view stops moving.
        for _ in 0..<12 {
            canvas.zoom(by: 0.7, at: CGPoint(x: size.width / 2, y: size.height / 2))
            time += 1.0 / 60
            _ = canvas.frame(at: time, viewSize: size)
        }
        #expect(focused.isEmpty, "nothing settles while it moves")
        run(canvas, from: &time, for: 0.6)
        #expect(focused.last == .some(nil))
        // So far out that every host is a node: the edge of the Continuum, level 6.
        #expect(canvas.drawsNodes)
        #expect(canvas.level == .boundary)
        // Zooming back in over the same place settles on the pipeline again, past its host.
        for _ in 0..<12 {
            canvas.zoom(by: 1 / 0.7, at: CGPoint(x: size.width / 2, y: size.height / 2))
            time += 1.0 / 60
            _ = canvas.frame(at: time, viewSize: size)
        }
        run(canvas, from: &time, for: 0.6)
        #expect(canvas.level == .pipeline)
        #expect(focused.last == .some(MeepAddress(host: "east", pipeline: "orders")))
    }

    @Test func thePointerFindsTilesHostsAndPipelines() async throws {
        let (continuum, sessions) = try await mesh()
        defer { sessions.forEach { $0.stop() } }
        let canvas = ContinuumStage(continuum: continuum)
        var time = 1.0
        run(canvas, from: &time, for: 0.1)
        let orders = MeepAddress(host: "east", pipeline: "orders")
        canvas.show(orders, animated: false)
        run(canvas, from: &time, for: 0.2)
        let stage = try #require(canvas.focusedStage)
        let tile = try #require(stage.viewFrame(of: "m3"))
        #expect(canvas.hit(at: CGPoint(x: tile.midX, y: tile.midY)) == .inside(orders, .tile("m3")))
        #expect(canvas.pipelineStage(at: CGPoint(x: tile.midX, y: tile.midY)) === stage)

        // From further out, where tiles are too small to aim at, a pipeline is its plate, and a host's plate around it
        // is the host.
        canvas.show(nil, animated: false)
        canvas.zoom(by: 0.2 / canvas.currentCamera.scale, at: CGPoint(x: size.width / 2, y: size.height / 2))
        run(canvas, from: &time, for: 0.2)
        #expect(!canvas.drawsNodes)
        let camera = canvas.currentCamera
        let district = camera.viewRect(try #require(canvas.frame(of: orders)), in: size)
        #expect(canvas.hit(at: CGPoint(x: district.midX, y: district.midY)) == .pipeline(orders))
        let plate = camera.viewRect(try #require(canvas.frame(of: MeepAddress(host: "east"))), in: size)
        #expect(canvas.hit(at: CGPoint(x: plate.maxX - 3, y: plate.maxY - 3)) == .host("east"))
        #expect(canvas.hit(at: CGPoint(x: 2, y: 2)) == nil)
        // A double click on the plate zooms into the pipeline.
        var focused: MeepAddress??
        canvas.onFocus = { focused = .some($0) }
        canvas.doubleClick(at: CGPoint(x: district.midX, y: district.midY))
        #expect(focused == .some(orders))
        #expect(canvas.level == .pipeline)
    }

    @Test func farOutHostsBecomeNodesTogether() async throws {
        let (continuum, sessions) = try await mesh()
        defer { sessions.forEach { $0.stop() } }
        let canvas = ContinuumStage(continuum: continuum)
        var time = 1.0
        run(canvas, from: &time, for: 0.1)
        canvas.show(nil, animated: false)
        run(canvas, from: &time, for: 0.1)
        #expect(!canvas.drawsNodes)
        canvas.zoom(by: 0.15, at: CGPoint(x: size.width / 2, y: size.height / 2))
        run(canvas, from: &time, for: 0.1)
        #expect(canvas.drawsNodes)
        let snapshot = canvas.frame(at: time, viewSize: size)
        #expect(snapshot.regions.filter { $0.id.hasPrefix("node:") }.count == 2, "one node each, both drawn the same way")
        #expect(snapshot.tiles.isEmpty)
        #expect(continuum.hosts.flatMap(\.pipelines).allSatisfy { $0.shownAs == .listed }, "nodes need only the hosts' totals")
    }

    @Test func districtsArePackedWithoutOverlap() {
        let sizes = [CGSize(width: 400, height: 300), CGSize(width: 900, height: 500), CGSize(width: 200, height: 100), CGSize(width: 500, height: 300)]
        let (places, whole) = ContinuumStage.shelfPack(sizes, gap: 50, aspect: 1.6)
        let frames = zip(places, sizes).map { CGRect(origin: $0, size: $1) }
        for (index, frame) in frames.enumerated() {
            #expect(CGRect(origin: .zero, size: whole).contains(frame))
            for other in frames[(index + 1)...] { #expect(!frame.insetBy(dx: -24, dy: -24).intersects(other)) }
        }
        #expect(whole.width / whole.height < 4)
    }
}
