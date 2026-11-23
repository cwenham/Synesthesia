@testable import ContinuumKit
import CoreGraphics
import Foundation
import MeepClient
import Simulation
import Testing
import TestSupport
@testable import Stage

/// Flows and the boundary on the Continuum's canvas (design, sections 2, 3 and 7): drawn between districts and tiles,
/// between hosts as nodes, the mesh laid out by forces with eased moves, and endpoints outside Meep round its edge.
@MainActor
@Suite(.simulatedHosts)
struct ContinuumFlowsTests {
    let size = CGSize(width: 1200, height: 800)
    private let feederID = SimulatedHost.id(for: "feeder")

    /// A feeder whose Fetch reaches a site's Listen, a Send declared to the site that sends nothing, and a host with no
    /// flows; the site's Listen hears from clients outside Meep, and the feeder's Send reaches an API outside it.
    private func mesh() async throws -> (Continuum, [HostSession]) {
        let siteID = SimulatedHost.id(for: "site")
        let specs: [(String, [PipelineSpec])] = [
            ("feeder", [PipelineSpec(name: "feed", modules: [
                .init("Interval", .source, name: "Ticks", rate: 40),
                .init("Fetch", .step, name: "Ask", from: [0], address: "http://site.simulated:8443/in/", peer: siteID),
                .init("Send", .outlet, name: "Report", from: [1], address: "https://reports.example.com/upload"),
                .init("Send", .outlet, name: "Quiet", from: [0], drops: 1, address: "http://site.simulated:8443/in/", peer: siteID),
            ])]),
            ("site", [PipelineSpec(name: "front", modules: [
                .init("Listen", .inlet, name: "In", rate: 60, address: "http://0.0.0.0:8443/in/", clients: [
                    .meep(feederID, "feed", "m2", share: 0.6),
                    SimulatedClient("198.51.100.9", name: "laptop.example.net", share: 0.4),
                ]),
                .init("Send", .outlet, name: "Reply", from: [0]),
            ])]),
            ("lonely", [PipelineSpec(name: "ticker", modules: [.init("Interval", .source, rate: 2), .init("WriteLine", .outlet, from: [0])])]),
        ]
        let continuum = Continuum()
        var sessions: [HostSession] = []
        for (name, pipelines) in specs {
            let host = continuum.add(host: name, kind: .simulated)
            let link = SimulatedHost(name: name, latency: .milliseconds(1), pipelines: pipelines)
            let session = HostSession(host: host, settings: .init(replanEvery: .milliseconds(60), rateScale: 0.3)) { link }
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

    /// Draws frames for `seconds` of the stage's clock, yielding the main actor every few, so other suites' work there
    /// isn't held up for long.
    private func run(_ canvas: ContinuumStage, from time: inout Double, for seconds: Double) async -> StageSnapshot {
        let end = time + seconds
        var snapshot = StageSnapshot()
        var frames = 0
        while time < end {
            time += 1.0 / 60
            snapshot = canvas.frame(at: time, viewSize: size)
            frames += 1
            // A short sleep, rather than a yield, lets the main actor run work of any priority meanwhile, such as the
            // sessions' updates in other suites.
            if frames % 4 == 0 { try? await Task.sleep(for: .milliseconds(2)) }
        }
        return snapshot
    }

    /// Draws frames, letting real time pass so the hosts' updates come, until `condition` holds.
    private func draw(_ canvas: ContinuumStage, from time: inout Double, until condition: (StageSnapshot) -> Bool) async throws -> StageSnapshot {
        let deadline = ContinuousClock.now + .seconds(20)
        while true {
            // A few frames, then real time for the hosts' updates, leaving the main actor to other suites meanwhile.
            let snapshot = await run(canvas, from: &time, for: 0.05)
            if condition(snapshot) { return snapshot }
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out")
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(120))
        }
    }

    @Test func flowsAreDrawnSolidWhenSeenAndDashedWhenOnlyDeclared() async throws {
        let (continuum, sessions) = try await mesh()
        defer { sessions.forEach { $0.stop() } }
        let canvas = ContinuumStage(continuum: continuum)
        var time = 1.0
        canvas.show(nil, animated: false)
        _ = try await draw(canvas, from: &time) { snapshot in
            snapshot.wires.contains { $0.id == "flow:meep://feeder/feed/m2 > meep://site/front/m1" && $0.kind == .flow }
                && (!snapshot.streams.isEmpty || !snapshot.particles.isEmpty)
        }
        // Once the hosts have eased to where the flows pull them.
        let snapshot = await run(canvas, from: &time, for: 1.5)
        let seen = try #require(snapshot.wires.first { $0.id == "flow:meep://feeder/feed/m2 > meep://site/front/m1" })
        #expect(seen.kind == .flow)
        let quiet = try #require(snapshot.wires.first { $0.id == "flow:meep://feeder/feed/m4 > meep://site/front/m1" })
        #expect(quiet.kind == .declared, "declared, nothing seen: dashed")
        // It runs from its district on the feeder to the site's.
        let feed = try #require(canvas.frame(of: MeepAddress(host: "feeder", pipeline: "feed")))
        let front = try #require(canvas.frame(of: MeepAddress(host: "site", pipeline: "front")))
        #expect(feed.insetBy(dx: -2, dy: -2).contains(seen.points.first!))
        #expect(front.insetBy(dx: -2, dy: -2).contains(seen.points.last!))
        // Each district's flows are asked for at the mesh's distance, or every second once its tiles show.
        #expect(continuum.host("site")?.pipeline("front")?.flowsShownAs ?? .none >= .near)
    }

    @Test func theMeshIsLaidOutByForcesAndMovesEase() async throws {
        let (continuum, sessions) = try await mesh()
        defer { sessions.forEach { $0.stop() } }
        let canvas = ContinuumStage(continuum: continuum)
        var time = 1.0
        canvas.show(nil, animated: false)
        // Until flows are known, then while the hosts move to where they pull them, no host jumps between frames.
        _ = try await draw(canvas, from: &time) { _ in canvas.flowMap.flows.contains { $0.observed } }
        var last: [String: CGRect] = [:]
        var biggest: CGFloat = 0
        for _ in 0..<90 {
            _ = await run(canvas, from: &time, for: 1.0 / 60)
            try? await Task.sleep(for: .milliseconds(2))
            for host in continuum.hosts {
                let frame = try #require(canvas.frame(of: host.address))
                if let before = last[host.name] { biggest = max(biggest, hypot(frame.midX - before.midX, frame.midY - before.midY)) }
                last[host.name] = frame
            }
        }
        #expect(biggest < 400, "eased, not jumped: \(biggest)")
        let frames = continuum.hosts.compactMap { canvas.frame(of: $0.address) }
        for (i, a) in frames.enumerated() {
            for b in frames.dropFirst(i + 1) { #expect(!a.intersects(b)) }
        }
    }

    @Test func theBoundarySitsRoundTheMeshAndThePointerFindsIt() async throws {
        let (continuum, sessions) = try await mesh()
        defer { sessions.forEach { $0.stop() } }
        let canvas = ContinuumStage(continuum: continuum)
        var time = 1.0
        canvas.show(nil, animated: false)
        let snapshot = try await draw(canvas, from: &time) { snapshot in
            snapshot.labelPlates.contains { $0.id == "endpoint:outside:laptop.example.net" } && snapshot.labelPlates.contains { $0.id == "endpoint:outside:reports.example.com" }
        }
        let hosts = continuum.hosts.compactMap { canvas.frame(of: $0.address) }.reduce(CGRect.null) { $0.union($1) }
        let laptop = try #require(snapshot.labelPlates.first { $0.id == "endpoint:outside:laptop.example.net" })
        #expect(!hosts.intersects(laptop.frame), "outside the mesh")
        // A line runs from the client into the site's Listen.
        #expect(snapshot.wires.contains { $0.id.hasPrefix("flow:meep://site/front/m1 < 198.51.100.9") })
        // The pointer finds it, and a flow's line.
        let centre = canvas.currentCamera.viewPoint(CGPoint(x: laptop.frame.midX, y: laptop.frame.midY), in: size)
        #expect(canvas.hit(at: centre) == .endpoint("outside:laptop.example.net"))
        let wire = try #require(snapshot.wires.first { $0.id == "flow:meep://feeder/feed/m2 > meep://site/front/m1" })
        let middle = canvas.currentCamera.viewPoint(wire.point(at: wire.length / 2).point, in: size)
        #expect(canvas.hit(at: middle) == .flow("meep://feeder/feed/m2 > meep://site/front/m1"))
    }

    @Test func drawingBackToTheBoundaryMakesHostsNodesWithFlowsBetweenThem() async throws {
        let (continuum, sessions) = try await mesh()
        defer { sessions.forEach { $0.stop() } }
        let canvas = ContinuumStage(continuum: continuum)
        var time = 1.0
        canvas.show(nil, animated: false)
        _ = try await draw(canvas, from: &time) { _ in canvas.flowMap.flows.contains { $0.observed } && !canvas.flowMap.boundary.isEmpty }
        canvas.showBoundary()
        let snapshot = try await draw(canvas, from: &time) { snapshot in
            canvas.drawsNodes && snapshot.wires.contains { $0.id == "flow:hosts:feeder>site" }
        }
        #expect(canvas.level == .boundary)
        #expect(snapshot.regions.contains { $0.id == "continuum" }, "the Continuum's edge")
        #expect(snapshot.texts.contains { $0.string == "laptop.example.net" })
        // Inside a node, a pipeline's flows are asked for at the boundary's distance.
        #expect(continuum.host("site")?.pipeline("front")?.flowsShownAs == .far)
        #expect(continuum.host("lonely")?.pipeline("ticker")?.flowsShownAs == .far)
        // Zooming into the site's pipeline asks for them every second.
        canvas.show(MeepAddress(host: "site", pipeline: "front"))
        _ = await run(canvas, from: &time, for: 1.5)
        #expect(canvas.level == .pipeline)
        #expect(continuum.host("site")?.pipeline("front")?.flowsShownAs == .close)
    }
}
