import ContinuumKit
import CoreGraphics
import Foundation
import Metal
import MeepClient
import Simulation
import Stage
import Testing
@testable import MetalStage

/// The Continuum drawn whole, off screen, at each level of the zoom: the mesh of hosts, one host's districts, and one
/// pipeline's tiles. With `SYNESTHESIA_SNAPSHOTS` set, each is saved as a PNG.
@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a GPU"))
struct ContinuumRendererTests {
    let size = CGSize(width: 1400, height: 860)

    @Test func everyLevelIsDrawn() async throws {
        let renderer = try #require(StageRenderer())
        let (continuum, sessions) = try await mesh()
        defer { sessions.forEach { $0.stop() } }
        let canvas = ContinuumStage(continuum: continuum)
        var time = ProcessInfo.processInfo.systemUptime

        func settle(_ seconds: Double) async throws {
            let end = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < end {
                time = ProcessInfo.processInfo.systemUptime
                _ = canvas.frame(at: time, viewSize: size)
                try await Task.sleep(for: .milliseconds(16))
            }
        }

        // The mesh: every host, each a plate with its pipelines on it.
        try await settle(0.5)
        canvas.show(nil, animated: false)
        try await settle(1.2)
        var snapshot = canvas.frame(at: time, viewSize: size)
        let mesh = try #require(renderer.image(of: snapshot, size: size))
        StageRendererTests().save(mesh, as: "continuum-mesh")
        #expect(canvas.level == .mesh)
        #expect(renderer.lastCounts.regions >= 3 + 9, "a plate for each host and pipeline")

        // Further out, hosts become nodes.
        canvas.zoom(by: 0.2, at: CGPoint(x: size.width / 2, y: size.height / 2))
        try await settle(0.3)
        snapshot = canvas.frame(at: time, viewSize: size)
        let nodes = try #require(renderer.image(of: snapshot, size: size))
        StageRendererTests().save(nodes, as: "continuum-nodes")
        #expect(snapshot.regions.contains { $0.id.hasPrefix("node:") })

        // One host: its pipelines as districts, with their tiles as blocks or tiles.
        canvas.show(MeepAddress(host: "east"), animated: false)
        try await settle(1.2)
        snapshot = canvas.frame(at: time, viewSize: size)
        let host = try #require(renderer.image(of: snapshot, size: size))
        StageRendererTests().save(host, as: "continuum-host")
        #expect(canvas.level == .host)

        // One pipeline, drawn by its own stage in the same world.
        canvas.show(MeepAddress(host: "east", pipeline: "warehouse"), animated: false)
        try await settle(1.5)
        snapshot = canvas.frame(at: time, viewSize: size)
        let pipeline = try #require(renderer.image(of: snapshot, size: size))
        StageRendererTests().save(pipeline, as: "continuum-pipeline")
        #expect(canvas.level == .pipeline)
        #expect(snapshot.tiles.count >= 11)
        #expect(renderer.lastCounts.particles + renderer.lastCounts.streamed > 0)
    }

    /// Flows between hosts and pipelines, and the boundary round the mesh: at the mesh's distance, with hosts as nodes,
    /// and at a host's.
    @Test func flowsAndTheBoundaryAreDrawn() async throws {
        let renderer = try #require(StageRenderer())
        let continuum = Continuum()
        let simulatedID = SimulatedHost.id(for: "simulated")
        let specs: [(String, [PipelineSpec])] = [
            ("simulated", PipelineSpec.demo),
            ("edge", [
                PipelineSpec(name: "checkout", modules: [
                    .init("Listen", .inlet, name: "Basket", rate: 30, address: "http://0.0.0.0:9443/basket/", clients: [
                        SimulatedClient("203.0.113.70", name: "shop.example.com", share: 0.8),
                        SimulatedClient("203.0.113.71", name: "app.example.com", share: 0.2, rejects: 0.2),
                    ]),
                    .init("Fetch", .step, name: "Place order", from: [0], fails: 0.03, address: "http://simulated.simulated:8443/orders/", peer: simulatedID),
                    .init("Send", .outlet, name: "Receipt", from: [1], address: "https://mail.example.org/send"),
                ]),
            ]),
            ("lab", [PipelineSpec.demo[1]]),
        ]
        var sessions: [HostSession] = []
        for (name, pipelines) in specs {
            let host = continuum.add(host: name, kind: .simulated)
            let link = SimulatedHost(name: name, latency: .milliseconds(1), pipelines: pipelines)
            let session = HostSession(host: host, settings: .init(replanEvery: .milliseconds(80), rateScale: 0.4)) { link }
            session.start()
            sessions.append(session)
        }
        defer { sessions.forEach { $0.stop() } }
        let canvas = ContinuumStage(continuum: continuum)
        var time = ProcessInfo.processInfo.systemUptime
        func settle(_ seconds: Double) async throws {
            let end = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < end {
                time = ProcessInfo.processInfo.systemUptime
                _ = canvas.frame(at: time, viewSize: size)
                try await Task.sleep(for: .milliseconds(16))
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while !(canvas.flowMap.flows.contains { $0.crossesHosts && $0.observed } && canvas.flowMap.boundary.count >= 8) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CancellationError() }
            time = ProcessInfo.processInfo.systemUptime
            _ = canvas.frame(at: time, viewSize: size)
            try await Task.sleep(for: .milliseconds(150))
        }
        canvas.show(nil, animated: false)
        try await settle(2.5)
        var snapshot = canvas.frame(at: time, viewSize: size)
        StageRendererTests().save(try #require(renderer.image(of: snapshot, size: size)), as: "flows-mesh")
        #expect(snapshot.wires.contains { $0.kind == .flow && $0.id.hasPrefix("flow:meep://edge/checkout/m2") })
        #expect(snapshot.wires.contains { $0.kind == .declared }, "the ticker's heartbeat, declared only")
        #expect(snapshot.labelPlates.contains { $0.id.hasPrefix("endpoint:") })

        canvas.showBoundary(animated: false)
        try await settle(0.5)
        snapshot = canvas.frame(at: time, viewSize: size)
        StageRendererTests().save(try #require(renderer.image(of: snapshot, size: size)), as: "flows-boundary")
        #expect(canvas.level == .boundary)
        #expect(snapshot.wires.contains { $0.id == "flow:hosts:edge>simulated" })

        canvas.show(MeepAddress(host: "simulated"), animated: false)
        try await settle(1.5)
        snapshot = canvas.frame(at: time, viewSize: size)
        StageRendererTests().save(try #require(renderer.image(of: snapshot, size: size)), as: "flows-host")
        #expect(snapshot.wires.contains { $0.id.hasPrefix("flow:meep://simulated/warehouse/m7") }, "between districts on one host")
    }

    /// Three simulated hosts of different sizes, one with a clock that's a second and a half ahead.
    private func mesh() async throws -> (Continuum, [HostSession]) {
        let continuum = Continuum()
        let specs: [(String, [PipelineSpec], Duration)] = [
            ("west", Array(PipelineSpec.demo.prefix(2)), .zero),
            ("east", PipelineSpec.demo, .milliseconds(1500)),
            ("north", [PipelineSpec.demo[2]], .zero),
        ]
        var sessions: [HostSession] = []
        for (name, pipelines, skew) in specs {
            let host = continuum.add(host: name, kind: .simulated)
            let link = SimulatedHost(name: name, latency: .milliseconds(1), pipelines: pipelines, clockSkew: skew)
            let session = HostSession(host: host, settings: .init(leastDetail: .modules, replanEvery: .milliseconds(50), rateScale: 0.2)) { link }
            session.start()
            sessions.append(session)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while continuum.hosts.contains(where: { $0.pipelines.isEmpty || $0.pipelines.contains { $0.graph == nil } }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(800))
        return (continuum, sessions)
    }
}
