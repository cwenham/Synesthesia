import Foundation
import Testing
@testable import MeepClient

/// Flow evidence as Meep2 a5de139 sends it, captured from two daemons on this Mac with names and addresses made
/// anonymous: this Mac's test daemon (`caller` with a Fetch to Lab's Listen and one to an API outside Meep, `front`
/// with Listens for clients outside Meep) and Lab's (`web`, whose Listen this Mac's Fetch and its own reach). Its
/// `GET /` with `sending`, the subscription's `hello` with the places' count order, its first update whole and a later
/// one with only what changed, and Lab's first update, in JSON and CBOR.
struct FlowContractTests {
    private func fixture(_ name: String, _ ext: String = "json") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func update(_ data: Data) throws -> SubscriptionUpdate {
        guard case .update(let update)? = try MeepJSON.subscriptionEvent(from: data) else {
            throw HostError.unreadable("Not an update.")
        }
        return update
    }

    @Test func aDaemonSaysWhereItsFetchesAndSendsSend() throws {
        struct Answer: Decodable { var body: DaemonInfo }
        let info = try MeepJSON.decoder.decode(Answer.self, from: fixture("flows-info")).body
        let sending = try #require(info.sending)
        #expect(sending.count == 3)
        // Worked out for each message, but the endpoint is fixed: quoted as written, with `computed`.
        let ask = try #require(sending.first { $0.label == "AskLab" })
        #expect(ask.isComputed)
        #expect(ask.address == "\"http://127.0.0.1:18080/hello/?name=local{msg.Count}\"")
        #expect(ask.endpoint == "127.0.0.1:18080")
        // Fixed: as written, with the port a web address implies when it gives none.
        let outside = try #require(sending.first { $0.label == "Outside" })
        #expect(!outside.isComputed)
        #expect(outside.endpoint == "localhost:18090")
        #expect(info.listening?.map(\.label) == ["Front", "Old"])
    }

    @Test func helloSaysHowPlacesAreCounted() throws {
        guard case .hello(let hello)? = try MeepJSON.subscriptionEvent(from: fixture("flows-hello")) else {
            Issue.record("Not a hello.")
            return
        }
        #expect(hello.counts == .standard)
        #expect(hello.counts.arrivals == ["received", "sent", "bytesReceived", "bytesSent", "failed", "rejected"])
        #expect(hello.counts.destinations == CountOrder.places)
        #expect(hello.plan?["pipelines"]?["*"]?["arrivals"]?["*"] == "1s")
    }

    @Test func theFirstUpdateHasEveryPlaceWhole() throws {
        let first = try update(fixture("flows-first"))
        // The host's declared sends come with the host's part, as its listens do.
        #expect(first.host?.sends?.count == 3)
        #expect(first.host?.sends?.first { $0.label == "Unused" }?.endpoint == "127.0.0.1:18080")
        let caller = try #require(first.pipelines?["caller"] ?? nil)
        #expect(caller.destinations?["m2"]??["127.0.0.1:18080"] == [32, 32, 471, 0, 0, 0])
        #expect(caller.destinations?["m5"]??["localhost:18090"] == [16, 16, 240, 0, 0, 0])
        // Lab's Listen said it's Meep; the API outside Meep didn't.
        #expect(caller.peers == ["127.0.0.1:18080": "89f87f18-7bc5-46b4-b9c5-2f33a9cf6a8a"])
        let front = try #require(first.pipelines?["front"] ?? nil)
        #expect(front.arrivals?["m1"]??["127.0.0.1"] == [14, 14, 0, 28, 0, 0])
        // Turned away with a 404: rejected, the sixth count.
        #expect(front.arrivals?["m3"]??["127.0.0.1"]??[5] == 15)
        #expect(front.clients == ["127.0.0.1": "localhost"])
        // Pipelines with no network modules have no places.
        #expect(first.pipelines?["busy"]??.arrivals == nil)
    }

    @Test func laterUpdatesCarryOnlyThePlacesThatChanged() throws {
        let later = try update(fixture("flows-changed"))
        let front = try #require(later.pipelines?["front"] ?? nil)
        // [16, 16, null, 64, null, 16]: bytes received and failures unchanged.
        #expect(front.arrivals?["m3"]??["127.0.0.1"] == [16, 16, nil, 64, nil, 16])
        #expect(front.clients == nil, "names come when found or changed")
        #expect(later.pipelines?["caller"]??.peers == nil)
        #expect(later.host?.sends == nil)
    }

    @Test func originsNameTheDaemonPipelineAndModule() throws {
        let lab = try update(fixture("flows-lab-first"))
        let web = try #require(lab.pipelines?["web"] ?? nil)
        let places = try #require(web.arrivals?["m1"] ?? nil)
        // From this Mac's caller, and from its own Fetch, both by origin.
        #expect(places.keys.sorted() == [
            "meep://4e9b8e61-914a-445f-bad4-9c8df0e4c739/caller/m2", "meep://89f87f18-7bc5-46b4-b9c5-2f33a9cf6a8a/web/m4",
        ])
        #expect(web.peers?["127.0.0.1:18080"] == "89f87f18-7bc5-46b4-b9c5-2f33a9cf6a8a")
    }

    @Test func cborCarriesTheSamePlaces() throws {
        let hello = try CBOR.json(from: fixture("flows-lab-hello", "cbor"))
        guard case .hello(let said)? = try MeepJSON.subscriptionEvent(from: hello) else {
            Issue.record("Not a hello.")
            return
        }
        #expect(said.counts.arrivals == CountOrder.places)
        let first = try update(CBOR.json(from: fixture("flows-lab-first", "cbor")))
        let web = try #require(first.pipelines?["web"] ?? nil)
        #expect(web.arrivals?["m1"]??.keys.contains { $0.hasPrefix("meep://") } == true)
        #expect(web.destinations?["m4"]??["127.0.0.1:18080"]??.count == 6)
        #expect(first.host?.sends?.first?.isComputed == true)
    }

    /// Folding, as Meep2's report gives it: the place goes null, `folded` names it, and `*` has its counts.
    @Test func foldedPlacesAreNamed() throws {
        let frame = #"""
        {"id":2,"event":"update","data":{"seq":9,"clock":1,"bytes":1,"pipelines":{"site":{
          "arrivals":{"m1":{"192.168.1.31":null,"*":[44,44,0,88,0,0]}},"folded":{"m1":["192.168.1.31"]}}}}}
        """#
        let later = try update(Data(frame.utf8))
        let site = try #require(later.pipelines?["site"] ?? nil)
        #expect(site.folded == ["m1": ["192.168.1.31"]])
        let m1 = try #require(site.arrivals?["m1"] ?? nil)
        #expect(m1["192.168.1.31"] == .some(nil))
        #expect(m1["*"] == [44, 44, 0, 88, 0, 0])
    }

    @Test func aPlanAsksForArrivalsAndDestinations() {
        let plan = PipelinePlan(totals: .seconds(2), arrivals: ["*": .seconds(1)], destinations: ["m2": .milliseconds(500)])
        #expect(plan.json["arrivals"]?["*"] == "1s")
        #expect(plan.json["destinations"]?["m2"] == "500ms")
        // Dropping them from a plan is a merge patch that nulls them.
        let before = SubscriptionPlan(pipelines: ["site": plan])
        let after = SubscriptionPlan(pipelines: ["site": PipelinePlan(totals: .seconds(2))])
        #expect(after.patch(from: before)?["pipelines"]?["site"]?["arrivals"] == .null)
    }
}
