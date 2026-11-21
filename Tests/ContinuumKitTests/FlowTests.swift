import FlowKit
import Foundation
import MeepClient
import Simulation
import Testing
import Transport
@testable import ContinuumKit

/// Addresses as Meep2 gives them, read without evaluating Meeplang.
struct NetworkAddressTests {
    @Test func listenAndSendAddressesAreRead() throws {
        let listen = try #require(NetworkAddress.address("http://0.0.0.0:8080/hooks/"))
        #expect(listen.scheme == "http" && listen.host == "0.0.0.0" && listen.port == 8080 && listen.path == "/hooks/")
        #expect(listen.family == .web)
        let secure = try #require(NetworkAddress.address("https://API.Example.com/stops"))
        #expect(secure.host == "api.example.com" && secure.port == 443 && secure.path == "/stops")
        let tcp = try #require(NetworkAddress.address("tcp://printer.local:9100"))
        #expect(tcp.family == .tcp && tcp.port == 9100 && tcp.path == nil)
        let v6 = try #require(NetworkAddress.address("ws://[::1]:7000/chat/"))
        #expect(v6.host == "::1" && v6.port == 7000 && v6.family == .web)
    }

    @Test func anAddressWorkedOutForEachMessageIsReadAsFarAsItsFirstBrace() throws {
        // Cut in the query: the path is whole.
        let query = try #require(NetworkAddress.address("\"http://127.0.0.1:18080/hello/?name=local{msg.Count}\"", computed: true))
        #expect(query.path == "/hello/" && !query.pathIsPartial)
        // Cut in the path: known only so far.
        let path = try #require(NetworkAddress.address("\"https://api.example.com/stops/{msg.StopId}\"", computed: true))
        #expect(path.path == "/stops/" && path.pathIsPartial)
        // Cut in the host: nothing to go on.
        #expect(NetworkAddress.address("\"http://{msg.Host}/\"", computed: true) == nil)
    }

    @Test func endpointsAreRead() throws {
        let endpoint = try #require(NetworkAddress.endpoint("studio.local:8080"))
        #expect(endpoint.host == "studio.local" && endpoint.port == 8080 && endpoint.scheme == nil)
        #expect(NetworkAddress.endpoint("[::1]:443")?.host == "::1")
        #expect(NetworkAddress.endpoint("*") == nil)
    }

    @Test func endpointsAreGroupedByDomain() {
        #expect(NetworkAddress.domain(of: "api.example.com") == "example.com")
        #expect(NetworkAddress.domain(of: "shop-web-1.EXAMPLE.com") == "example.com")
        #expect(NetworkAddress.domain(of: "shop.example.co.uk") == "example.co.uk")
        #expect(NetworkAddress.domain(of: "laptop.local") == "laptop.local")
        #expect(NetworkAddress.domain(of: "localhost") == "localhost")
        #expect(NetworkAddress.domain(of: "192.168.1.30") == "192.168.1.30")
    }
}

/// Flows between pipelines and the boundary, worked out from places, peers, clients and declared addresses as Meep2
/// a5de139 gives them (its report's "What a client has to do").
@MainActor
struct FlowMapTests {
    let localID = "4e9b8e61-914a-445f-bad4-9c8df0e4c739"
    let labID = "89f87f18-7bc5-46b4-b9c5-2f33a9cf6a8a"

    /// This Mac's daemon and Lab's, on one machine, as in the captured fixtures, and a host on another machine.
    private func continuum() -> Continuum {
        let continuum = Continuum()
        let local = continuum.add(host: "local", kind: .local(socketPath: "/tmp/a.sock"))
        local.identity = HostIdentity(id: localID, names: ["studio", "studio.local"], addresses: ["192.168.0.10"], version: "1")
        local.status = .connected
        local.apply([summary("caller"), summary("front")])
        local.listens = [ListenAddress(pipeline: "front", module: "m1", label: "Front", address: "http://127.0.0.1:18085/in/")]
        local.sends = [
            SendAddress(pipeline: "caller", module: "m2", label: "AskLab", address: "\"http://127.0.0.1:18080/hello/?name={msg.Count}\"", computed: true, endpoint: "127.0.0.1:18080"),
            SendAddress(pipeline: "caller", module: "m5", label: "Outside", address: "http://localhost:18090/", computed: false, endpoint: "localhost:18090"),
            SendAddress(pipeline: "caller", module: "m9", label: "Unused", address: "http://127.0.0.1:18080/hello/", computed: false, endpoint: "127.0.0.1:18080"),
            SendAddress(pipeline: "caller", module: "m11", label: "Far", address: "http://far.example.net:9000/in/x", endpoint: "far.example.net:9000"),
        ]
        let lab = continuum.add(host: "lab", kind: .remote(SSHTarget(destination: "localhost", port: 2222)))
        lab.identity = HostIdentity(id: labID, names: ["studio", "studio.local"], addresses: ["192.168.0.10"], version: "1")
        lab.status = .connected
        lab.apply([summary("web")])
        lab.listens = [
            ListenAddress(pipeline: "web", module: "m1", label: "Greetings", address: "http://127.0.0.1:18080/hello/"),
            ListenAddress(pipeline: "web", module: "m7", label: "Root", address: "http://127.0.0.1:18080/"),
        ]
        let far = continuum.add(host: "far", kind: .simulated)
        far.identity = HostIdentity(id: "f0000000-0000-4000-8000-000000000000", names: ["far", "far.example.net"], addresses: ["10.9.9.9"], version: "1")
        far.status = .connected
        far.apply([summary("intake")])
        far.listens = [ListenAddress(pipeline: "intake", module: "m1", label: "In", address: "http://0.0.0.0:9000/in/")]
        return continuum
    }

    private func summary(_ name: String) -> PipelineSummary {
        PipelineSummary(name: name, path: "/\(name).meep", state: .running, started: Date())
    }

    /// Gives a module its places twice, a second apart, so it has rates: each count rising by `perSecond`.
    private func count(_ continuum: Continuum, _ address: String, _ kind: PlaceKind, _ places: [String: [Int64]], perSecond: [Int64] = [10, 10, 100, 50, 0, 0]) {
        let at = MeepAddress(address)!
        let pipeline = continuum.pipeline(at: at)!
        let module = pipeline.module(at.module!) ?? pipeline.addModule(at.module!)
        module.apply(places: places.mapValues { $0.map { Optional($0) } }, kind: kind, order: CountOrder.places, folded: [], at: 1)
        let later = places.mapValues { counts in zip(counts, perSecond).map { Optional($0 + $1) } }
        module.apply(places: later, kind: kind, order: CountOrder.places, folded: [], at: 2)
    }

    @Test func aDeclaredAddressReachesTheListenItMatches() throws {
        let continuum = continuum()
        let local = continuum.host("local")!
        // On one machine, a loopback address reaches the other daemon's Listen on that port, the longest path first.
        let matches = continuum.listens(reachedBy: "127.0.0.1:18080", address: "\"http://127.0.0.1:18080/hello/?name={msg.Count}\"", computed: true, from: local)
        #expect(matches.map { "\($0.0.name)/\($0.1.module)" } == ["lab/m1"])
        // Without a path to go on, the root's Listen is as good as any: both.
        #expect(continuum.listens(reachedBy: "127.0.0.1:18080", from: local).count == 2)
        // Another machine by its name, at a Listen bound to every address, on its port and path.
        #expect(continuum.listens(reachedBy: "far.example.net:9000", address: "http://far.example.net:9000/in/x", from: local).map(\.0.name) == ["far"])
        #expect(continuum.listens(reachedBy: "10.9.9.9:9000", address: "http://10.9.9.9:9000/in/", from: local).map(\.0.name) == ["far"])
        #expect(continuum.listens(reachedBy: "far.example.net:9001", from: local).isEmpty, "another port")
        #expect(continuum.listens(reachedBy: "far.example.net:9000", address: "http://far.example.net:9000/out/", from: local).isEmpty, "another path")
        #expect(continuum.listens(reachedBy: "far.example.net:9000", address: "tcp://far.example.net:9000", from: local).isEmpty, "TCP isn't HTTP")
        // From another machine, loopback is that machine, not this one.
        #expect(continuum.listens(reachedBy: "127.0.0.1:18080", from: continuum.host("far")!).isEmpty)
    }

    @Test func anOriginAtAListenIsAnObservedFlowWhichItsDeclarationConfirms() throws {
        let continuum = continuum()
        count(continuum, "meep://lab/web/m1", .arrivals, ["meep://\(localID)/caller/m2": [32, 32, 0, 480, 0, 0]])
        count(continuum, "meep://local/caller/m2", .destinations, ["127.0.0.1:18080": [32, 32, 480, 0, 0, 0]], perSecond: [10, 10, 150, 0, 1, 0])
        continuum.pipeline(at: MeepAddress("meep://local/caller")!)!.peers = ["127.0.0.1:18080": labID]
        let map = continuum.flowMap()
        // Seen from both ends, and declared: one flow.
        let flows = map.flows.filter { $0.from == MeepAddress("meep://local/caller/m2")! }
        #expect(flows.count == 1)
        let flow = try #require(flows.first)
        #expect(flow.to == MeepAddress("meep://lab/web/m1")!)
        #expect(flow.observed && flow.declared && !flow.byAddress && flow.crossesHosts)
        #expect(abs(flow.rate - 10) < 0.01, "the Listen's arrivals give the rate")
        #expect(flow.failed > 0.5, "the Fetch adds failures the Listen never saw")
        #expect(flow.evidence == "declared and observed")
    }

    @Test func aDeclaredAddressWithNothingSeenIsDeclaredOnly() throws {
        let map = continuum().flowMap()
        let unused = try #require(map.flows.first { $0.from == MeepAddress("meep://local/caller/m9")! })
        #expect(unused.to == MeepAddress("meep://lab/web/m1")!)
        #expect(unused.declared && !unused.observed)
        #expect(unused.rate == 0)
        // To another machine's Listen, by its name.
        #expect(map.flows.contains { $0.from == MeepAddress("meep://local/caller/m11")! && $0.to.host == "far" && $0.declared })
    }

    @Test func aDestinationThatSaysItsMeepReachesThatHostsListen() throws {
        let continuum = continuum()
        count(continuum, "meep://local/caller/m2", .destinations, ["127.0.0.1:18080": [5, 5, 50, 0, 0, 0]])
        continuum.pipeline(at: MeepAddress("meep://local/caller")!)!.peers = ["127.0.0.1:18080": labID]
        continuum.host("local")!.sends = []
        let flow = try #require(continuum.flowMap().flows.first)
        // The Listen's arrivals aren't followed, but the endpoint and the declared address together name the Listen.
        #expect(flow.to.host == "lab")
        #expect(flow.observed && !flow.declared)
        #expect(abs(flow.rate - 10) < 0.01)
    }

    @Test func aTCPSendReachingAKnownListenIsSeenByAddress() throws {
        let continuum = continuum()
        let far = continuum.host("far")!
        far.listens.append(ListenAddress(pipeline: "intake", module: "m4", label: "Printer", address: "tcp://0.0.0.0:9100"))
        let local = continuum.host("local")!
        local.sends.append(SendAddress(pipeline: "caller", module: "m12", label: "Print", address: "tcp://far.example.net:9100", endpoint: "far.example.net:9100"))
        // TCP carries no origin, so its destination never says it's Meep.
        count(continuum, "meep://local/caller/m12", .destinations, ["far.example.net:9100": [0, 4, 0, 400, 0, 0]], perSecond: [0, 2, 0, 200, 0, 0])
        let flow = try #require(continuum.flowMap().flows.first { $0.from == MeepAddress("meep://local/caller/m12")! })
        #expect(flow.to == MeepAddress("meep://far/intake/m4")!)
        #expect(flow.observed && flow.byAddress && flow.declared)
        #expect(flow.evidence == "declared, and seen by address")
        #expect(abs(flow.rate - 2) < 0.01)
        #expect(!continuum.flowMap().boundary.contains { $0.places.contains("far.example.net:9100") }, "not outside")
    }

    @Test func originsFromDaemonsNobodyFollowsAreAnotherMeep() throws {
        let continuum = continuum()
        let stranger = "7c3e9a1b-5d2f-4e8a-9b6c-0d1e2f3a4b5c"
        count(continuum, "meep://lab/web/m1", .arrivals, ["meep://\(stranger)/collector/m2": [3, 3, 0, 9, 0, 0], "meep://*": [1, 1, 0, 3, 0, 0]])
        let map = continuum.flowMap()
        let other = try #require(map.boundary.first { $0.kind == .otherMeep })
        #expect(other.name.hasPrefix("Another Meep"))
        #expect(other.domain == "Meep")
        #expect(other.links.first?.module == MeepAddress("meep://lab/web/m1")!)
        #expect(other.links.first?.direction == .inbound)
        #expect(map.boundary.contains { $0.kind == .pastLimit && $0.id == "meep://*" })
        #expect(!map.flows.contains { $0.observed }, "not a flow between known hosts")
    }

    @Test func endpointsOutsideMeepAreGroupedByTheirNames() throws {
        let continuum = continuum()
        let front = continuum.pipeline(at: MeepAddress("meep://local/front")!)!
        front.clients = ["192.168.1.30": "laptop.example.net", "192.168.1.31": "laptop.example.net"]
        count(continuum, "meep://local/front/m1", .arrivals, [
            "192.168.1.30": [10, 10, 0, 20, 0, 0], "192.168.1.31": [5, 5, 0, 10, 0, 2], "203.0.113.9": [1, 1, 0, 2, 0, 0], "*": [40, 40, 0, 80, 0, 0],
        ], perSecond: [4, 4, 0, 8, 1, 2])
        count(continuum, "meep://local/caller/m5", .destinations, ["localhost:18090": [16, 16, 240, 0, 0, 0]])
        let map = continuum.flowMap()
        // Two addresses with one name are one endpoint, known by both.
        let laptop = try #require(map.boundary.first { $0.name == "laptop.example.net" })
        #expect(laptop.places.sorted() == ["192.168.1.30", "192.168.1.31"])
        #expect(laptop.domain == "example.net")
        #expect(laptop.kind == .outside)
        #expect(abs(laptop.rateIn - 8) < 0.01, "both addresses' requests")
        #expect(abs(laptop.rateOut - 8) < 0.01, "and replies")
        #expect(abs(laptop.failed - 2) < 0.01 && abs(laptop.rejected - 4) < 0.01)
        // An address with no name is its own.
        #expect(map.boundary.contains { $0.name == "203.0.113.9" && $0.domain == "203.0.113.9" })
        // What a Fetch reaches outside Meep, outbound.
        let api = try #require(map.boundary.first { $0.places.contains("localhost:18090") })
        #expect(api.links.first?.direction == .outbound && api.rateOut > 0)
        // Everything past a module's limit.
        #expect(map.boundary.contains { $0.kind == .pastLimit && $0.id == "*" && $0.rateIn > 0 })
        // The far host's declared Listen isn't outside: it's a flow.
        #expect(!map.boundary.contains { $0.name == "far.example.net" })
    }

    @Test func aFoldedPlacesCountsMoveIntoTheStarWithoutAJump() throws {
        let continuum = continuum()
        let module = continuum.pipeline(at: MeepAddress("meep://local/front")!)!.addModule("m1")
        let order = CountOrder.places
        module.apply(places: ["10.0.0.1": [100, 100, 0, 0, 0, 0], "*": [1000, 1000, 0, 0, 0, 0]], kind: .arrivals, order: order, folded: [], at: 1)
        module.apply(places: ["10.0.0.1": [110, 110], "*": [1010, 1010]], kind: .arrivals, order: order, folded: [], at: 2)
        #expect(abs(module.places["*"]!.rate("received") - 10) < 0.01)
        // 10.0.0.1 is folded: it goes, and `*` now holds its 110 as well as 10 new.
        let star: [Int64?] = [1010 + 110 + 10, 1010 + 110 + 10]
        module.apply(places: ["10.0.0.1": nil, "*": star], kind: .arrivals, order: order, folded: ["10.0.0.1"], at: 3)
        #expect(module.places["10.0.0.1"] == nil)
        #expect(module.places["*"]!["received"] == 1130)
        #expect(module.places["*"]!.rate("received") < 15, "not 120")
    }

    @Test func placesNoLongerFollowedHaveNoRates() throws {
        let continuum = continuum()
        count(continuum, "meep://lab/web/m1", .arrivals, ["meep://\(localID)/caller/m2": [32, 32, 0, 480, 0, 0]])
        #expect(continuum.flowMap().flows.first { $0.observed }?.rate ?? 0 > 0)
        continuum.pipeline(at: MeepAddress("meep://lab/web")!)!.module("m1")!.placesFollowed = false
        let flow = try #require(continuum.flowMap().flows.first { $0.observed })
        #expect(flow.rate == 0 && !flow.current, "as last seen")
    }
}

/// Two simulated hosts, one's Fetch reaching the other's Listen, followed by sessions as the app follows them.
@MainActor
struct SimulatedFlowTests {
    private let feederID = SimulatedHost.id(for: "feeder")

    private func hosts(flows: SubscriptionPlanner.FlowDetail = .near) -> (Continuum, [HostSession], SimulatedHost, SimulatedHost) {
        let feeder = SimulatedHost(name: "feeder", latency: .milliseconds(1), pipelines: [
            PipelineSpec(name: "feed", modules: [
                .init("Interval", .source, name: "Ticks", rate: 50),
                .init("Fetch", .step, name: "Ask", from: [0], fails: 0.02, address: "http://site.simulated:8443/in/{msg.Count}", peer: SimulatedHost.id(for: "site")),
                .init("Send", .outlet, name: "Report", from: [1], address: "https://reports.example.com/upload"),
            ]),
        ])
        let site = SimulatedHost(name: "site", latency: .milliseconds(1), pipelines: [
            PipelineSpec(name: "front", modules: [
                .init("Listen", .inlet, name: "In", rate: 80, address: "http://0.0.0.0:8443/in/", clients: [
                    .meep(feederID, "feed", "m2", share: 0.6),
                    SimulatedClient("198.51.100.9", name: "laptop.example.net", share: 0.3, rejects: 0.1),
                    SimulatedClient("198.51.100.10", name: "phone.example.net", share: 0.1),
                ]),
                .init("Send", .outlet, name: "Reply", from: [0]),
            ]),
        ])
        let continuum = Continuum()
        var sessions: [HostSession] = []
        for link in [feeder, site] {
            let host = continuum.add(host: link.name, kind: .simulated)
            let session = HostSession(host: host, settings: .init(replanEvery: .milliseconds(30), rateScale: 0.1, leastFlowDetail: flows)) { link }
            session.start()
            sessions.append(session)
        }
        return (continuum, sessions, feeder, site)
    }

    @Test func aFetchReachingAnotherHostsListenIsAnObservedFlow() async throws {
        let (continuum, sessions, _, _) = hosts()
        defer { sessions.forEach { $0.stop() } }
        try await waitForFlows(continuum) { map in
            map.flows.contains { $0.observed && $0.rate > 1 } && map.boundary.contains { $0.name == "laptop.example.net" && $0.rateIn > 1 }
        }
        let map = continuum.flowMap()
        let flow = try #require(map.flows.first { $0.from == MeepAddress("meep://feeder/feed/m2")! })
        #expect(flow.to == MeepAddress("meep://site/front/m1")!)
        #expect(flow.declared && flow.observed, "its declared address matches the Listen, and its origin was seen")
        #expect(flow.crossesHosts)
        // The boundary: clients outside Meep, grouped by domain, and the API the Send reaches.
        let laptop = try #require(map.boundary.first { $0.name == "laptop.example.net" })
        #expect(laptop.domain == "example.net")
        try await waitForFlows(continuum) { $0.boundary.first { $0.name == "laptop.example.net" }?.rejected ?? 0 > 0 }
        #expect(map.boundary.contains { $0.places == ["reports.example.com:443"] && $0.links.first?.direction == .outbound })
        #expect(continuum.host("feeder")?.sends.count == 2)
    }

    @Test func placesAreAskedForOnlyWhileTheirFlowsAreShown() async throws {
        let (continuum, sessions, _, _) = hosts(flows: .none)
        defer { sessions.forEach { $0.stop() } }
        let site = try #require(continuum.host("site"))
        try await waitUntil { site.pipelines.first?.graph != nil && site.intake > 0 }
        try await Task.sleep(for: .milliseconds(300))
        let front = try #require(site.pipeline("front"))
        #expect(front.modules.allSatisfy { $0.places.isEmpty }, "nothing shown, nothing asked for")
        #expect(site.traffic.flows.isEmpty)
        front.flowsShownAs = .near
        try await waitUntil { front.module("m1")?.places.isEmpty == false }
        #expect(site.traffic.flows[.near] == 1)
        #expect(front.module("m1")?.placesFollowed == true)
        // Off screen again: no longer asked for, and their rates no longer current.
        front.flowsShownAs = .none
        try await waitUntil { front.module("m1")?.placesFollowed == false }
    }

    @Test func aFoldedClientMovesIntoTheStar() async throws {
        let (continuum, sessions, _, site) = hosts()
        defer { sessions.forEach { $0.stop() } }
        try await waitUntil { continuum.host("site")?.pipeline("front") != nil }
        let front = try #require(continuum.host("site")?.pipeline("front"))
        try await waitUntil { front.module("m1")?.places["198.51.100.10"].map { $0.rate("received") > 0 } ?? false }
        await site.fold("198.51.100.10", of: "m1", in: "front")
        try await waitUntil { front.module("m1")?.places["198.51.100.10"] == nil && front.module("m1")?.places["*"] != nil }
        // Its counts carried on under `*`, with no jump in `*`'s rate: about a tenth of the Listen's 80 a second.
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            let star = front.module("m1")?.places["*"]?.rate("received") ?? 0
            #expect(star < 40, "\(star) a second")
        }
        #expect(continuum.flowMap().boundary.contains { $0.id == "*" && $0.kind == .pastLimit })
    }
}

/// Against two real daemons, when `MEEP_TEST_SOCKET` and `MEEP_TEST_FLOW_SOCKET` name their sockets and a Fetch on the
/// first reaches a Listen on the second (Meep2 a5de139 or later): an observed flow between them.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MEEP_TEST_SOCKET"] != nil && ProcessInfo.processInfo.environment["MEEP_TEST_FLOW_SOCKET"] != nil))
struct LiveFlowTests {
    @Test func aFetchOnOneDaemonReachingAListenOnAnotherIsAnObservedFlow() async throws {
        let environment = ProcessInfo.processInfo.environment
        let continuum = Continuum()
        var sessions: [HostSession] = []
        for (name, socket) in [("here", environment["MEEP_TEST_SOCKET"] ?? ""), ("there", environment["MEEP_TEST_FLOW_SOCKET"] ?? "")] {
            let host = continuum.add(host: name, kind: .local(socketPath: socket))
            let session = HostSession(host: host, settings: .init(replanEvery: .milliseconds(50), rateScale: 0.2, leastFlowDetail: .close)) {
                try await DaemonConnection.connect(socketPath: socket)
            }
            session.start()
            sessions.append(session)
        }
        defer { sessions.forEach { $0.stop() } }
        try await waitForFlows(continuum, seconds: 30) { map in
            map.flows.contains { $0.from.host == "here" && $0.to.host == "there" && $0.observed && $0.rate > 0 }
        }
        let map = continuum.flowMap()
        let flow = try #require(map.flows.first { $0.from.host == "here" && $0.to.host == "there" && $0.observed })
        #expect(flow.to.module != nil, "the Listen's arrivals name it")
        #expect(flow.declared, "the Fetch's declared endpoint matches the Listen")
        #expect(continuum.host("here")?.sends.isEmpty == false)
        #expect(continuum.host("there")?.identity?.id != continuum.host("here")?.identity?.id)
    }
}

/// Waits until the flow map satisfies `condition`, working it out only a few times a second, so other suites' work on
/// the main actor isn't crowded out.
@MainActor
func waitForFlows(_ continuum: Continuum, seconds: Double = 20, _ condition: (FlowMap) -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition(continuum.flowMap()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for flows.")
            return
        }
        try await Task.sleep(for: .milliseconds(150))
    }
}
