import Foundation
import Testing
@testable import MeepClient

/// A subscription's events as Meep2 0c83a49 sends them, captured from a daemon running `busy`, `shapes` and `slow`,
/// with names, addresses and paths made anonymous: `hello`, the first update (everything whole), a later one (only
/// what changed), and the `plan` answering a change. The CBOR ones are the same daemon's, asked for in CBOR.
struct SubscriptionContractTests {
    /// The counts' order from Meep2 0c83a49, before arrivals and destinations.
    static var beforeFlows: CountOrder {
        var order = CountOrder.standard
        order.arrivals = nil
        order.destinations = nil
        return order
    }

    private func fixture(_ name: String, _ ext: String = "json") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func aDaemonSaysWhoItIs() throws {
        let info = try MeepJSON.decoder.decode(DaemonInfo.self, from: fixture("info-identity"))
        #expect(info.id == "98254d9a-206f-4759-92b5-927ab74d3254")
        #expect(info.names == ["example-mac-host-name", "example-mac-host-name.local"])
        #expect(info.addresses == ["192.168.0.10"])
        #expect(info.listening == [])
        #expect(info.clock == 1795194753541802)
        // An older daemon's answer still reads, without them.
        #expect(try MeepJSON.decoder.decode(DaemonInfo.self, from: fixture("info")).id == nil)
    }

    @Test func helloSaysWhoAndHowToRead() throws {
        guard case .hello(let hello)? = try MeepJSON.subscriptionEvent(from: fixture("subscribe-hello")) else {
            Issue.record("Not a hello.")
            return
        }
        #expect(hello.host.id == "98254d9a-206f-4759-92b5-927ab74d3254")
        #expect(hello.host.version == "1.0.0")
        #expect(hello.counts == Self.beforeFlows, "0c83a49 has no arrivals or destinations")
        #expect(hello.timing == TimingScale(scale: 3, unit: "s"))
        #expect(hello.plan?["pipelines"]?["busy"]?["modules"]?["*"] == "500ms")
    }

    @Test func theFirstUpdateHasEverythingWhole() throws {
        guard case .update(let update)? = try MeepJSON.subscriptionEvent(from: fixture("subscribe-first")) else {
            Issue.record("Not an update.")
            return
        }
        #expect(update.seq == 1)
        #expect(update.bytes == 840, "the hello's bytes")
        // The list's times are microseconds since 1970.
        let busy = try #require(update.list?["busy"] ?? nil)
        #expect(busy.state == .running)
        #expect(busy.graphVersion == 1)
        #expect(abs(busy.started.timeIntervalSince1970 - 1795194714.519204) < 0.000_01)
        #expect(update.host?.totals?["sourced"] == 362)
        #expect(update.host?.states?["running"] == 3)
        #expect(update.runtime?["dotnet.process.cpu.count"] == 16)
        #expect(update.runtime?["host.load"]?["1m"]?.number != nil)
        let part = try #require(update.pipelines?["busy"] ?? nil)
        #expect(part.graph == GraphStamp(version: 1))
        #expect(part.modules?.count == 4)
        #expect(part.modules?.values.allSatisfy { $0?.count == 12 } == true)
        #expect(part.links?["m2>m4"] == [45, 45])
        let timing = try #require(part.timing?["m2"] ?? nil)
        #expect(timing.buckets.reduce(0, +) + timing.zero == timing.count)
        #expect(part.timing?["m1"] == nil, "a source handles nothing, so has no times")
        // Pipelines asked for only as totals get no modules.
        #expect(update.pipelines?["shapes"]??.modules == nil)
        #expect(update.pipelines?["shapes"]??.totals?["received"] == 501)
    }

    @Test func laterUpdatesCarryOnlyWhatChanged() throws {
        guard case .update(let update)? = try MeepJSON.subscriptionEvent(from: fixture("subscribe-changed")) else {
            Issue.record("Not an update.")
            return
        }
        #expect(update.seq == 2)
        #expect(update.list == nil)
        let part = try #require(update.pipelines?["busy"] ?? nil)
        #expect(part.graph == nil)
        // [null, null, 230]: emitted is now 230, and nothing after it changed.
        #expect(part.modules?["m1"] == [nil, nil, 230])
        var source = ModuleStats(received: 0, handled: 0, emitted: 226)
        source = source.applying([nil, nil, 230], order: CountOrder.standard.modules).stats
        #expect(source.emitted == 230)
        #expect(source.received == 0)
        let (filter, busy) = ModuleStats.zero.applying((part.modules?["m2"] ?? nil) ?? [], order: CountOrder.standard.modules)
        #expect(filter.received == 230 && filter.emitted == 46 && filter.passed == 184)
        #expect(busy == 12608)
        #expect(part.totals?["queued"] == nil, "totals that didn't change are left out")
    }

    @Test func aChangeIsAnsweredWithThePlan() throws {
        guard case .plan(let plan)? = try MeepJSON.subscriptionEvent(from: fixture("subscribe-plan")) else {
            Issue.record("Not a plan.")
            return
        }
        #expect(plan["pipelines"]?["busy"]?["timing"] == nil)
        #expect(plan["pipelines"]?["slow"]?["modules"]?["*"] == "1s")
    }

    @Test func cborCarriesTheSameAsJSON() throws {
        let hello = try CBOR.json(from: fixture("subscribe-hello", "cbor"))
        guard case .hello(let said)? = try MeepJSON.subscriptionEvent(from: hello) else {
            Issue.record("Not a hello.")
            return
        }
        #expect(said.host.id == "98254d9a-206f-4759-92b5-927ab74d3254")
        #expect(said.counts == Self.beforeFlows)
        #expect(said.plan?["encoding"] == "cbor")
        let first = try CBOR.json(from: fixture("subscribe-first", "cbor"))
        guard case .update(let update)? = try MeepJSON.subscriptionEvent(from: first) else {
            Issue.record("Not an update.")
            return
        }
        #expect(update.seq == 1)
        #expect(update.list?.keys.sorted() == ["busy", "shapes", "slow"])
        let busy = try #require(update.pipelines?["busy"] ?? nil)
        #expect(busy.modules?.values.allSatisfy { $0?.count == 12 } == true)
        let timing = try #require(busy.timing?.values.first ?? nil)
        #expect(timing.sum > 0 && timing.sum < 1, "floats come through")
        #expect(timing.buckets.reduce(0, +) + timing.zero == timing.count)
        #expect(try fixture("subscribe-first", "cbor").count < fixture("subscribe-first").count, "CBOR is smaller")
    }

    /// RFC 8949's own examples, from its appendix A.
    @Test(arguments: [
        ("00", "0"), ("17", "23"), ("1818", "24"), ("1903e8", "1000"), ("1b000000e8d4a51000", "1000000000000"),
        ("20", "-1"), ("3863", "-100"), ("f93c00", "1"), ("f93e00", "1.5"), ("f9c400", "-4"), ("fa47c35000", "100000"),
        ("fb3ff199999999999a", "1.1"), ("f4", "false"), ("f5", "true"), ("f6", "null"), ("6449455446", "\"IETF\""),
        ("62225c", "\"\\\"\\\\\""), ("83010203", "[1,2,3]"), ("a201020304", "{\"1\":2,\"3\":4}"),
        ("a26161016162820203", "{\"a\":1,\"b\":[2,3]}"), ("9f018202039f0405ffff", "[1,[2,3],[4,5]]"),
        ("7f657374726561646d696e67ff", "\"streaming\""), ("c11a514b67b0", "1363896240"),
    ])
    func cborReadsAsTheRFCSays(hex: String, json: String) throws {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        #expect(String(decoding: try CBOR.json(from: Data(bytes)), as: UTF8.self) == json)
    }

    @Test func cborCutShortIsRefused() {
        #expect(throws: CBOR.Problem.truncated) { try CBOR.json(from: Data([0x83, 0x01, 0x02])) }
    }

    @Test func aPlanIsWrittenAsTheDaemonReadsIt() {
        let plan = SubscriptionPlan(
            encoding: .cbor, list: .seconds(2), host: .seconds(1), budget: 64_000,
            pipelines: ["*": PipelinePlan(totals: .seconds(5)), "orders": PipelinePlan(totals: .seconds(1), modules: ["*": .milliseconds(200)])]
        )
        #expect(plan.json == [
            "encoding": "cbor", "list": "2s", "host": "1s", "budget": 64000,
            "pipelines": ["*": ["totals": "5s"], "orders": ["totals": "1s", "modules": ["*": "200ms"]]],
        ])
    }

    @Test func aChangeIsSentAsAMergePatch() {
        let before = SubscriptionPlan(pipelines: [
            "*": PipelinePlan(totals: .seconds(5)), "orders": PipelinePlan(totals: .seconds(1), modules: ["*": .milliseconds(200)]),
            "ticker": PipelinePlan(totals: .seconds(1)),
        ])
        var after = before
        after.pipelines["orders"]?.modules = ["*": .milliseconds(500)]
        after.pipelines["ticker"] = nil
        after.pipelines["sensors"] = PipelinePlan(totals: .seconds(1))
        #expect(after.patch(from: before) == [
            "pipelines": ["orders": ["modules": ["*": "500ms"]], "ticker": nil, "sensors": ["totals": "1s"]],
        ])
        #expect(before.patch(from: before) == nil, "nothing changed, nothing to send")
    }
}
