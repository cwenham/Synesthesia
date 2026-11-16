import Foundation
import Testing
@testable import MeepClient

/// The fixtures are the daemon's own replies, with paths made anonymous: `busy` captured from Meep2 at 6d496dd, and
/// `shapes` (two timers merging, filters, a fan-out and handled errors) at ee030d7, with counts for each link.
struct ContractTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func infoReads() throws {
        let info = try MeepJSON.decoder.decode(DaemonInfo.self, from: fixture("info"))
        #expect(info.capabilities == ["observe", "inject", "control"])
        #expect(info.pipelines.contains("busy"))
    }

    @Test func pipelinesRead() throws {
        let pipelines = try MeepJSON.decoder.decode([PipelineSummary].self, from: fixture("pipelines"))
        #expect(pipelines.map(\.name) == ["busy", "slow"])
        // busy failed under Meep2's error policy when the fixture was captured, which shows how an ended one reads.
        #expect(pipelines[0].state == .failed)
        #expect(pipelines[0].ended != nil)
        #expect(pipelines[0].reason?.contains("errors nothing handled") == true)
        #expect(pipelines[1].state == .running)
        #expect(pipelines[1].ended == nil)
    }

    @Test func aPipelineReadsWithItsCounts() throws {
        let detail = try MeepJSON.decoder.decode(PipelineDetail.self, from: fixture("busy-detail"))
        #expect(detail.modules.map(\.module) == ["Ticks", "Thirds", "WriteLine #3", "Tap #4", "WriteLine #5"])
        #expect(detail.modules[0].name == "Ticks")
        #expect(detail.modules[2].name == nil)
        #expect(detail.graphVersion == 1)
        #expect(detail.modules[0].counts.emitted > 0)
    }

    @Test func aGraphReadsWithRolesPortsAndSpans() throws {
        let graph = try MeepJSON.decoder.decode(PipelineGraph.self, from: fixture("busy-graph"))
        #expect(graph.modules.map(\.key) == ["m1", "m2", "m3", "m4", "m5"])
        #expect(graph.modules.map(\.verbRole) == [.source, .filter, .outlet, .step, .outlet])
        let tap = try #require(graph.links.first { $0.to == "m4" })
        #expect(tap.from == "m2")
        #expect(tap.linkPort == .errors)
        #expect(graph.modules[1].parameters.first?.text == "msg.Count % 3 != 0")
        #expect(graph.modules[1].span.startLine == 3)
        #expect(graph.modules[3].modifiers.first?.name == "errors")
    }

    @Test func linksReadWithWhatTheyCarried() throws {
        let detail = try MeepJSON.decoder.decode(PipelineDetail.self, from: fixture("shapes-detail"))
        let graph = try MeepJSON.decoder.decode(PipelineGraph.self, from: fixture("shapes-graph"))
        let links = try #require(detail.links)
        #expect(links.map(\.key) == graph.links.map(\.key))
        let carried = Dictionary(uniqueKeysWithValues: links.map { ($0.key, $0) })
        // Two timers merge into Keep, on inputs 1 and 2.
        #expect(graph.links.filter { $0.to == "m3" }.map(\.input) == [1, 2])
        #expect(carried["m1>m3"]!.carried + carried["m2>m3"]!.carried == detail.modules[2].counts.received)
        // Risky's errors go down both its wires: past the WriteLine on the main one, and into the @errors one.
        #expect(carried["m5>m7"]!.carried == carried["m5>m7"]!.errors)
        #expect(carried["m5>m6"]!.errors == carried["m5>m7"]!.errors)
        #expect(carried["m5>m6"]!.carried - carried["m5>m6"]!.errors == detail.modules[5].counts.received)
    }

    @Test func aFiltersCountsAddUp() throws {
        let detail = try MeepJSON.decoder.decode(PipelineDetail.self, from: fixture("shapes-detail"))
        let keep = detail.modules[2].counts
        #expect(keep.passed > 0)
        #expect(keep.heldBack > 0, "Keep holds back every seventh tick")
        #expect(keep.passed + keep.emitted + keep.heldBack == keep.handled)
    }

    @Test func countsADaemonLeavesOutReadAsZero() throws {
        let stats = try MeepJSON.decoder.decode(ModuleStats.self, from: Data(#"{"received":3,"handled":3,"emitted":1}"#.utf8))
        #expect(stats == ModuleStats(received: 3, handled: 3, emitted: 1))
        let link = try MeepJSON.decoder.decode(LinkDetail.self, from: Data(#"{"key":"m1>m2","carried":4}"#.utf8))
        #expect(link.errors == 0)
    }

    @Test(arguments: [
        ("2026-11-16T16:22:01.325359+00:00", 1_794_846_121.325359),
        ("2026-11-16T16:22:01.3253591+00:00", 1_794_846_121.3253591),
        ("2026-11-16T16:22:01Z", 1_794_846_121.0),
        ("2026-11-16T17:22:01.5+01:00", 1_794_846_121.5),
        ("2026-11-16T11:22:01-05:00", 1_794_846_121.0),
    ])
    func datesReadAsDotNetWritesThem(text: String, seconds: Double) throws {
        let date = try #require(MeepJSON.parseDate(text))
        #expect(abs(date.timeIntervalSince1970 - seconds) < 0.000_001)
    }

    @Test(arguments: ["", "yesterday", "2026-11-16", "2026-11-16T16:22:01", "2026-11-16T16:22:01+0"])
    func notDatesAreRefused(text: String) {
        #expect(MeepJSON.parseDate(text) == nil)
    }

    @Test func streamEventsAreRead() throws {
        let detail = try String(decoding: fixture("busy-detail"), as: UTF8.self)
        #expect(try DaemonConnection.statsEvent(from: Data(#"{"id":3,"event":"stats","data":\#(detail)}"#.utf8)).isStats)
        #expect(try DaemonConnection.statsEvent(from: Data(#"{"id":3,"event":"graph","data":{"version":2,"reason":"reload"}}"#.utf8))
            == .graph(GraphNotice(version: 2, reason: "reload")))
        #expect(try DaemonConnection.statsEvent(from: Data(#"{"id":3,"event":"end","data":{"reason":"busy has finished."}}"#.utf8))
            == .end("busy has finished."))
    }

    @Test(arguments: [(Duration.seconds(1), "1s"), (.milliseconds(500), "500ms"), (.milliseconds(10), "50ms"), (.seconds(2), "2s")])
    func durationsAreWrittenAsTheDaemonReadsThem(duration: Duration, text: String) {
        #expect(duration.meepText == text)
    }

    @Test func namesAreEscapedAsOnePartOfAPath() {
        #expect(DaemonConnection.escape("busy") == "busy")
        #expect(DaemonConnection.escape("a b/c") == "a%20b%2Fc")
    }
}

extension StatsEvent {
    var isStats: Bool {
        if case .stats = self { return true }
        return false
    }
}
