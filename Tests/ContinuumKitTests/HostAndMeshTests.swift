import FlowKit
import Foundation
import MeepClient
import Simulation
import Testing
import Transport
@testable import ContinuumKit

/// Following hosts with one subscription each (design, section 4), within their budgets, with the roll-ups the host
/// and mesh levels draw.
@MainActor
struct SubscriptionSessionTests {
    private func follow(_ link: SimulatedHost, budget: Double? = nil, settings: HostSession.Settings = .init(replanEvery: .milliseconds(50), rateScale: 0.1))
        -> (MeepHost, HostSession) {
        let continuum = Continuum()
        let host = continuum.add(host: link.name, kind: .simulated)
        host.budget = budget
        let session = HostSession(host: host, settings: settings) { link }
        session.start()
        return (host, session)
    }

    @Test func aHostSaysWhoItIsAndItsRollUpsArrive() async throws {
        let link = SimulatedHost(name: "sim", latency: .milliseconds(1))
        let (host, session) = follow(link)
        defer { session.stop() }
        try await waitUntil { host.pipelines.count == 4 && host.pipelines.allSatisfy { $0.graph != nil } && host.intake > 0 && host.runtime.cores != nil }
        #expect(host.identity?.id == link.id)
        #expect(host.identity?.names.first == "sim")
        #expect(host.traffic.subscribed)
        #expect(host.listens.contains { $0.pipeline == "orders" && $0.module == "m1" })
        // The host's totals, each pipeline's, and its machine.
        let orders = try #require(host.pipeline("orders"))
        try await waitUntil { orders.intake > 100 && host.load > 0 && (host.runtime.cpuRate ?? 0) > 0 }
        #expect(orders.totals["sourced"] > 0)
        #expect(host.headroom.map { $0.cores == 8 && $0.spare > 0 && $0.spare < 1 } == true)
        try await waitUntil { host.traffic.bandwidth > 0 }
        // Nothing is shown, so no module's counts are asked for.
        #expect(orders.modules.allSatisfy { $0.lastRead == nil })
        #expect(orders.links.allSatisfy { !$0.isCounted })
    }

    @Test func whatsShownIsWhatsAskedFor() async throws {
        let link = SimulatedHost(name: "sim", latency: .milliseconds(1))
        let (host, session) = follow(link)
        defer { session.stop() }
        try await waitUntil { host.pipeline("warehouse")?.graph != nil }
        let warehouse = try #require(host.pipeline("warehouse"))
        // Drawn as tiles: modules' and links' counts.
        warehouse.shownAs = .modules
        try await waitUntil { warehouse.links.allSatisfy(\.isCounted) && warehouse.modules.allSatisfy { $0.lastRead != nil } }
        #expect(warehouse.modules.allSatisfy { $0.timing == nil }, "handling times only in focus")
        #expect(host.traffic.detail[.modules] == 1)
        // In focus: handling times and bytes too, merged into the pipeline's and the host's.
        warehouse.shownAs = .full
        try await waitUntil { warehouse.timing.count > 0 && warehouse.modules.contains { $0.traffic != nil } }
        #expect(warehouse.timing.quantile(0.5) != nil)
        #expect(host.timing.count == warehouse.timing.count)
        let fetch = try #require(warehouse.module("m5"))
        try await waitUntil { fetch.load > 0 }
        #expect(fetch.load < 1)
        // Off screen again: once the plan has changed, its links' counts stop coming.
        warehouse.shownAs = .listed
        var stopped = false
        let deadline = ContinuousClock.now + .seconds(8)
        while !stopped, ContinuousClock.now < deadline {
            let carried = warehouse.links[0].carried
            try await Task.sleep(for: .milliseconds(600))
            stopped = warehouse.links[0].carried == carried
        }
        #expect(stopped)
        #expect(host.traffic.detail[.modules] == nil && host.traffic.detail[.full] == nil)
    }

    @Test func ratesStayTrueWhenAPipelineIsShownAgain() async throws {
        // Over a slow link, updates already on their way arrive after the plan has changed.
        let link = SimulatedHost(name: "sim", latency: .milliseconds(150), pipelines: [PipelineSpec.demo[0]])
        let (host, session) = follow(link)
        defer { session.stop() }
        try await waitUntil { host.pipeline("orders")?.graph != nil }
        let orders = try #require(host.pipeline("orders"))
        let inlet = try #require(orders.module("m1"))
        for _ in 0..<2 {
            orders.shownAs = .modules
            try await waitUntil { inlet.lastRead != nil && inlet.rates[.emitted] > 50 }
            orders.shownAs = .listed
            try await Task.sleep(for: .seconds(4))
            // Shown again: its rate is about what it was, 140 a second or so, not the gap's messages over a moment.
            orders.shownAs = .modules
            var fastest = 0.0
            let end = ContinuousClock.now + .milliseconds(600)
            while ContinuousClock.now < end {
                fastest = max(fastest, inlet.rates[.emitted])
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(fastest < 260, "an inlet of about 140 a second read \(fastest) a second")
        }
    }

    @Test func aTightBudgetSlowsThePlanAndTheHostSaysWhenItHeldBack() async throws {
        let link = SimulatedHost(name: "sim", latency: .milliseconds(1))
        let (host, session) = follow(link, budget: 1_500, settings: .init(leastDetail: .full, replanEvery: .milliseconds(50), rateScale: 1))
        defer { session.stop() }
        // Every pipeline in full at the usual rates is far over 1.5 KB/s.
        try await waitUntil { host.pipelines.count == 4 && host.traffic.slowdown > 1 }
        #expect(host.traffic.estimate <= 1_500 * 0.8)
        // Near the budget once the first, whole update has passed: the planner aims under it, and the host holds back
        // what's over and says so.
        try await waitUntil(seconds: 15) { host.traffic.bandwidth > 0 }
        try await Task.sleep(for: .seconds(5))
        #expect(host.traffic.bandwidth < 1_500 * 2)
    }

    @Test func aMissedUpdateIsAskedForAgainWhole() async throws {
        let link = SimulatedHost(name: "sim", latency: .milliseconds(1))
        let (host, session) = follow(link, settings: .init(leastDetail: .modules, replanEvery: .milliseconds(50), rateScale: 0.1))
        defer { session.stop() }
        try await waitUntil { host.pipeline("orders")?.links.first?.isCounted == true }
        await link.loseNextUpdate()
        try await waitUntil { host.traffic.gaps == 1 }
        let orders = try #require(host.pipeline("orders"))
        let carried = orders.links[0].carried
        try await waitUntil { orders.links[0].carried > carried }
    }

    @Test func aHostsClockOffsetIsEstimated() async throws {
        let link = SimulatedHost(name: "sim", latency: .milliseconds(1), clockSkew: .milliseconds(2500))
        let (host, session) = follow(link)
        defer { session.stop() }
        try await waitUntil { host.clockOffset != nil }
        try await Task.sleep(for: .milliseconds(800))
        let offset = try #require(host.clockOffset)
        #expect(abs(offset - 2.5) < 0.25)
    }

    @Test func aHostWhoseTunnelFailsSaysWhyAndKeepsTrying() async throws {
        let continuum = Continuum()
        let target = SSHTarget(destination: "pi@lab-2")
        let host = continuum.add(host: "lab-2", kind: .remote(target))
        #expect(host.budget == 64_000, "a host over SSH starts with a lower budget")
        let attempts = Counter()
        let session = HostSession(host: host, settings: .init(retryAfter: .milliseconds(20))) {
            await attempts.add()
            throw TunnelError("pi@lab-2 didn't accept a key.")
        }
        session.start()
        defer { session.stop() }
        try await waitUntil { await attempts.value >= 2 }
        #expect(host.status == .unreachable("pi@lab-2 didn't accept a key."))
        #expect(host.kind.summary == "SSH to pi@lab-2")
    }

    @Test func headroomCountsTheBusiestOfTheDaemonAndTheMachine() {
        let quiet = Headroom(cores: 8, pipelines: 1, daemon: 2, machineLoad: 1)
        #expect(quiet.spare == 0.75)
        let crowded = Headroom(cores: 8, pipelines: 1, daemon: 2, machineLoad: 6)
        #expect(crowded.spare == 0.25, "other programs' load leaves less")
    }
}

struct HostStoreTests {
    @Test func namesAreMadeFromTitlesAndKeptApart() {
        #expect(HostStore.name(for: "Lab 2", taken: []) == "lab-2")
        #expect(HostStore.name(for: "Lab 2", taken: ["lab-2"]) == "lab-2-2")
        #expect(HostStore.name(for: "Ünïcode Box!", taken: []) == "n-code-box")
        #expect(HostStore.name(for: "!!!", taken: []) == "host")
    }

    @Test func hostsAndBudgetsAreKept() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synesthesia-hosts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var store = HostStore()
        store.remotes.append(.init(name: "lab", title: "Lab", target: SSHTarget(destination: "me@lab", port: 2222, options: ["-i", "~/.ssh/lab"]), budget: 32_000))
        store.budgets["local"] = 500_000
        try store.save(to: url)
        #expect(HostStore.load(from: url) == store)
        #expect(HostStore.load(from: url.appendingPathExtension("missing")) == HostStore())
        // A target written before ssh options were kept still reads.
        let older = #"{"destination": "me@lab"}"#
        #expect(try JSONDecoder().decode(SSHTarget.self, from: Data(older.utf8)) == SSHTarget(destination: "me@lab"))
    }
}

/// Against a real daemon, when `MEEP_TEST_SOCKET` names its socket: the session follows it with a subscription.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MEEP_TEST_SOCKET"] != nil))
struct LiveSubscriptionTests {
    private var socket: String { ProcessInfo.processInfo.environment["MEEP_TEST_SOCKET"] ?? "" }
    private var pipeline: String { ProcessInfo.processInfo.environment["MEEP_TEST_PIPELINE"] ?? "busy" }

    @Test func aDaemonIsFollowedWithOneSubscription() async throws {
        let continuum = Continuum()
        let host = continuum.add(host: "test", kind: .local(socketPath: socket))
        let socket = socket
        let session = HostSession(host: host, settings: .init(replanEvery: .milliseconds(50), rateScale: 0.2)) {
            try await DaemonConnection.connect(socketPath: socket)
        }
        session.start()
        defer { session.stop() }
        try await waitUntil { host.pipeline(self.pipeline)?.graph != nil && host.intake > 0 }
        #expect(host.traffic.subscribed)
        #expect(host.identity?.id == host.info?.id)
        let busy = try #require(host.pipeline(pipeline))
        busy.shownAs = .full
        try await waitUntil { busy.links.allSatisfy(\.isCounted) && busy.timing.count > 0 && host.runtime.cores != nil }
        #expect(busy.intake > 0)
        #expect(host.headroom != nil)
        #expect(abs(host.clockOffset ?? 99) < 1, "the daemon is on this Mac")
        try await waitUntil { host.traffic.bandwidth > 0 }
    }
}

/// Through SSH, when `MEEP_TEST_SSH` names a destination whose daemon can be reached: `MEEP_TEST_SSH_PORT`, the ssh
/// options in `MEEP_TEST_SSH_OPTIONS`, and how to run meep there in `MEEP_TEST_SSH_MEEP`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MEEP_TEST_SSH"] != nil))
struct LiveTunnelTests {
    @Test func aDaemonIsReachedThroughSSH() async throws {
        let environment = ProcessInfo.processInfo.environment
        let target = SSHTarget(
            destination: environment["MEEP_TEST_SSH"] ?? "", port: environment["MEEP_TEST_SSH_PORT"].flatMap(Int.init),
            meepCommand: environment["MEEP_TEST_SSH_MEEP"] ?? "meep",
            options: (environment["MEEP_TEST_SSH_OPTIONS"] ?? "").split(separator: " ").map(String.init)
        )
        let tunnel = try await SSHTunnelProvider(folder: FileManager.default.temporaryDirectory.appendingPathComponent("syn-tunnels").path).open(target)
        defer { tunnel.close() }
        let daemon = try await DaemonConnection.open(over: tunnel.connect())
        let info = try await daemon.info()
        #expect(info.id != nil)
        #expect(info.id == tunnel.expectedID, "meep daemon socket named the daemon that answered")
        let subscription = try await daemon.subscribe(SubscriptionPlan(encoding: .cbor, list: .seconds(1)))
        for try await event in subscription.events {
            if case .update(let update) = event {
                #expect(update.list?.isEmpty == false)
                break
            }
        }
        await daemon.close()
    }
}
