import Foundation
import Testing
import MeepClient
import Simulation
@testable import ContinuumKit

struct AddressTests {
    @Test(arguments: ["meep://local", "meep://local/ticker", "meep://local/ticker/Fetch", "meep://lab-2/a%20b/m3"])
    func addressesReadAndWriteTheSame(text: String) throws {
        let address = try #require(MeepAddress(text))
        #expect(address.description == text)
    }

    @Test func partsAreRead() throws {
        let address = try #require(MeepAddress("meep://local/ticker/Fetch"))
        #expect(address.host == "local")
        #expect(address.pipeline == "ticker")
        #expect(address.module == "Fetch")
        #expect(address.parent == MeepAddress(host: "local", pipeline: "ticker"))
        #expect(address.parent.parent == MeepAddress(host: "local"))
    }

    @Test(arguments: ["", "local/ticker", "http://local", "meep://", "meep:///ticker", "meep://local//Fetch", "meep://a/b/c/d"])
    func notAddressesAreRefused(text: String) {
        #expect(MeepAddress(text) == nil)
    }
}

@MainActor
struct HostSessionTests {
    @Test func aSimulatedHostFillsInTheContinuum() async throws {
        let continuum = Continuum()
        let host = continuum.add(host: "sim", kind: .simulated)
        let link = SimulatedHost(name: "sim", latency: .milliseconds(1))
        let session = HostSession(host: host, settings: .init(statsEvery: .milliseconds(50), listEvery: .milliseconds(50))) { link }
        session.start()
        defer { session.stop() }

        try await waitUntil { host.pipelines.count == 3 && host.pipeline("orders")?.graph != nil }
        #expect(host.status == .connected)
        let orders = try #require(continuum.pipeline(at: MeepAddress("meep://sim/orders")!))
        #expect(orders.modules.map(\.key) == ["m1", "m2", "m3", "m4", "m5"])
        #expect(orders.modules.map(\.role) == [.inlet, .filter, .step, .outlet, .outlet])

        try await waitUntil { orders.throughput > 0 }
        #expect(continuum.module(at: MeepAddress("meep://sim/orders/m1")!)?.label == "Orders")
    }

    @Test func aHostThatGoesAwayShowsNoRates() async throws {
        let continuum = Continuum()
        let host = continuum.add(host: "sim", kind: .simulated)
        let session = HostSession(host: host, settings: .init(statsEvery: .milliseconds(50), listEvery: .milliseconds(50))) {
            SimulatedHost(name: "sim", latency: .milliseconds(1))
        }
        session.start()
        try await waitUntil { host.throughput > 0 }
        session.stop()
        host.status = .unreachable("gone")
        #expect(host.throughput == 0)
        #expect(host.pipelines.count == 3, "its pipelines stay, as last seen")
    }

    @Test func anUnreachableHostSaysSoAndKeepsTrying() async throws {
        let continuum = Continuum()
        let host = continuum.add(host: "gone", kind: .local(socketPath: "/tmp/no-such-meep.sock"))
        let attempts = Counter()
        let session = HostSession(host: host, settings: .init(retryAfter: .milliseconds(20))) {
            await attempts.add()
            return try await DaemonConnection.connect(socketPath: "/tmp/no-such-meep.sock")
        }
        session.start()
        defer { session.stop() }
        try await waitUntil { await attempts.value >= 2 }
        guard case .unreachable(let reason) = host.status else {
            Issue.record("The host should be unreachable, not \(host.status).")
            return
        }
        #expect(reason.contains("/tmp/no-such-meep.sock"))
    }

    @Test func modulesKeepTheirPlaceWhenTheGraphRenumbersThem() {
        let pipeline = MeepPipeline(host: "h", name: "p")
        let span = GraphSpan(file: "p.meep", startLine: 1, startColumn: 1, endLine: 1, endColumn: 2)
        pipeline.apply(PipelineGraph(name: "p", path: "p.meep", version: 1, modules: [
            GraphModule(key: "m1", number: 1, module: "Ticks", verb: "Interval", role: .source, span: span),
            GraphModule(key: "m2", number: 2, module: "WriteLine #2", verb: "WriteLine", role: .outlet, span: span),
        ], links: []))
        let writer = pipeline.module("m2")
        // A Where inserted between them: WriteLine is #3 now but keeps its key, and its object.
        pipeline.apply(PipelineGraph(name: "p", path: "p.meep", version: 2, modules: [
            GraphModule(key: "m1", number: 1, module: "Ticks", verb: "Interval", role: .source, span: span),
            GraphModule(key: "m3", number: 2, module: "Where #2", verb: "Where", role: .filter, span: span),
            GraphModule(key: "m2", number: 3, module: "WriteLine #3", verb: "WriteLine", role: .outlet, span: span),
        ], links: []))
        #expect(pipeline.modules.map(\.key) == ["m1", "m3", "m2"])
        #expect(pipeline.module("m2") === writer)
        #expect(writer?.number == 3)
    }
}

/// Waits until `condition` holds, failing after `seconds`.
@MainActor
func waitUntil(seconds: Double = 5, _ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting.")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

actor Counter {
    private(set) var value = 0
    func add() { value += 1 }
}
