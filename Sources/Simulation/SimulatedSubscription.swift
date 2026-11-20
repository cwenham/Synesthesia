import Foundation
import MeepClient

/// The host's counts at one moment, for its subscriptions to send.
struct SimulatedReading: Sendable {
    struct Pipeline: Sendable {
        var spec: PipelineSpec
        var modules: [ModuleStats]
        var links: [LinkDetail]
        /// Each module's time spent handling, in microseconds.
        var busy: [Int64]
    }

    var clock: Int64
    var elapsed: Double
    var pipelines: [String: Pipeline]
    var summaries: [PipelineSummary]
    var listening: [ListenAddress]
    var cores: Int
}

/// A subscription to a ``SimulatedHost``, sending as Meep2's does: `hello`, then updates on one grid of rates carrying
/// only what changed, with graph notices straight away, a heartbeat, and a budget that holds updates back and says so.
final class SimulatedSubscription: HostSubscription, @unchecked Sendable {
    let events: AsyncThrowingStream<SubscriptionEvent, any Error>
    private let continuation: AsyncThrowingStream<SubscriptionEvent, any Error>.Continuation
    private let lock = NSLock()
    private var plan: SubscriptionPlan
    private var resendAll = false
    /// Things asked for anew by a change, due at once.
    private var changed = false
    private var sent: Int64 = 0
    private var task: Task<Void, Never>?

    private let host: SimulatedHost

    init(host: SimulatedHost, plan: SubscriptionPlan) {
        self.host = host
        self.plan = plan
        (events, continuation) = AsyncThrowingStream<SubscriptionEvent, any Error>.makeStream()
        continuation.onTermination = { [weak self] _ in self?.task?.cancel() }
        task = Task { [weak self] in await self?.run(host) }
    }

    var sentBytes: Int64 { lock.withLock { sent } }

    func change(to plan: SubscriptionPlan) async throws {
        // A change takes the host's latency to arrive, as over a network; updates go on meanwhile.
        try await Task.sleep(for: await host.latency)
        lock.withLock {
            self.plan = plan
            changed = true
        }
        continuation.yield(.plan(plan.json))
    }

    func resend() async throws {
        lock.withLock { resendAll = true }
    }

    func cancel() async {
        finish()
    }

    func finish() {
        task?.cancel()
        continuation.finish()
    }

    // MARK: Sending

    /// What was last sent of each thing, to send only what changed.
    private struct Sent {
        var list: [String: PipelineSummary] = [:]
        var hostTotals: [String: Int64] = [:]
        var states: [String: Int] = [:]
        var listens: [ListenAddress]?
        var runtime: [String: JSONValue] = [:]
        var graphs: [String: Int] = [:]
        var totals: [String: [String: Int64]] = [:]
        var modules: [String: [String: [Int64]]] = [:]
        var links: [String: [String: [Int64]]] = [:]
        var bytes: [String: [String: [Int64]]] = [:]
        var timing: [String: [String: TimingHistogram]] = [:]
    }

    private func run(_ host: SimulatedHost) async {
        let order = CountOrder.standard
        do {
            try await host.answer()
            let identity = await host.identity
            continuation.yield(.hello(SubscriptionHello(host: identity, clock: await host.clockNow, counts: order, plan: lock.withLock { plan.json })))
        } catch {
            continuation.finish(throwing: error)
            return
        }
        var last = Sent()
        var due: [String: Double] = [:]
        var seq = 0
        var lastSent = -Double.infinity
        var tokens = Double(plan.budget ?? 0)
        var filledAt = 0.0
        while !Task.isCancelled {
            let reading = await host.reading()
            let (plan, whole, replanned) = lock.withLock { () -> (SubscriptionPlan, Bool, Bool) in
                defer { resendAll = false; changed = false }
                return (self.plan, resendAll, changed)
            }
            if whole { last = Sent() }
            if replanned { due = [:] }
            let now = reading.elapsed
            /// Whether `item` at `rate` is due now, moving it on to its next time on the grid if so.
            func isDue(_ item: String, _ rate: Duration?) -> Bool {
                guard let rate else { return false }
                let every = max(Double(rate.components.seconds) + Double(rate.components.attoseconds) / 1e18, 0.05)
                if let next = due[item], now < next { return false }
                due[item] = ((now / every).rounded(.down) + 1) * every
                return true
            }

            var update = SubscriptionUpdate(seq: seq + 1, clock: reading.clock, bytes: lock.withLock { sent })
            if isDue("list", plan.list) {
                var list: [String: PipelineSummary?] = [:]
                for summary in reading.summaries where last.list[summary.name] != summary {
                    list[summary.name] = summary
                    last.list[summary.name] = summary
                }
                for name in last.list.keys where !reading.summaries.contains(where: { $0.name == name }) {
                    list[name] = .some(nil)
                    last.list.removeValue(forKey: name)
                }
                if !list.isEmpty { update.list = list }
            }
            if isDue("host", plan.host) {
                var hostUpdate = HostUpdate()
                let totals = Self.totals(of: Array(reading.pipelines.values))
                let changedTotals = totals.filter { last.hostTotals[$0.key] != $0.value }
                if !changedTotals.isEmpty { hostUpdate.totals = changedTotals.mapValues { $0 } }
                last.hostTotals = totals
                let states = ["running": reading.summaries.count]
                if states != last.states {
                    hostUpdate.states = states.mapValues { $0 }
                    last.states = states
                }
                if last.listens != reading.listening {
                    hostUpdate.listens = reading.listening
                    last.listens = reading.listening
                }
                if hostUpdate != HostUpdate() { update.host = hostUpdate }
            }
            if isDue("runtime", plan.runtime) {
                let runtime = Self.runtime(reading)
                let changedRuntime = runtime.filter { last.runtime[$0.key] != $0.value }
                if !changedRuntime.isEmpty { update.runtime = changedRuntime }
                last.runtime = runtime
            }

            var pipelines: [String: PipelineUpdate?] = [:]
            for (name, pipeline) in reading.pipelines.sorted(by: { $0.key < $1.key }) {
                guard let entry = plan.pipelines[name] ?? plan.pipelines["*"] else {
                    // No longer asked for: forgotten, so asking again sends it whole.
                    last.graphs[name] = nil
                    last.totals[name] = nil
                    last.modules[name] = nil
                    last.links[name] = nil
                    last.bytes[name] = nil
                    last.timing[name] = nil
                    continue
                }
                var part = PipelineUpdate()
                let version = pipeline.spec.version
                if last.graphs[name] != version {
                    part.graph = GraphStamp(version: version, reason: last.graphs[name] == nil ? nil : "reload")
                    last.graphs[name] = version
                }
                if isDue("\(name)/totals", entry.totals) {
                    let totals = Self.totals(of: [pipeline])
                    let before = last.totals[name] ?? [:]
                    let changedTotals = totals.filter { before[$0.key] != $0.value }
                    if !changedTotals.isEmpty { part.totals = changedTotals.mapValues { $0 } }
                    last.totals[name] = totals
                }
                let keys = pipeline.spec.modules.indices.map { "m\($0 + 1)" }
                var modules: [String: [Int64?]?] = [:]
                var bytes: [String: [Int64?]?] = [:]
                var timing: [String: TimingHistogram?] = [:]
                for (index, key) in keys.enumerated() {
                    if isDue("\(name)/modules/\(key)", entry.modules[key] ?? entry.modules["*"]) {
                        let counts = pipeline.modules[index]
                        let array = [counts.received, counts.handled, counts.emitted, counts.passed, pipeline.busy[index], counts.queued,
                                     counts.dropped, counts.filtered, counts.failed, counts.restarts, counts.expired, counts.refused]
                        if let delta = Self.delta(array, from: last.modules[name]?[key]) { modules[key] = delta }
                        last.modules[name, default: [:]][key] = array
                    }
                    if isDue("\(name)/bytes/\(key)", entry.bytes[key] ?? entry.bytes["*"]), let traffic = Self.traffic(pipeline, index) {
                        if let delta = Self.delta(traffic, from: last.bytes[name]?[key]) { bytes[key] = delta }
                        last.bytes[name, default: [:]][key] = traffic
                    }
                    if isDue("\(name)/timing/\(key)", entry.timing[key] ?? entry.timing["*"]),
                       let histogram = Self.histogram(pipeline, index), last.timing[name]?[key] != histogram {
                        timing[key] = histogram
                        last.timing[name, default: [:]][key] = histogram
                    }
                }
                var links: [String: [Int64?]?] = [:]
                for link in pipeline.links where isDue("\(name)/links/\(link.key)", entry.links[link.key] ?? entry.links["*"]) {
                    let array = [link.carried, link.errors]
                    if let delta = Self.delta(array, from: last.links[name]?[link.key]) { links[link.key] = delta }
                    last.links[name, default: [:]][link.key] = array
                }
                if !modules.isEmpty { part.modules = modules }
                if !links.isEmpty { part.links = links }
                if !bytes.isEmpty { part.bytes = bytes }
                if !timing.isEmpty { part.timing = timing }
                if part != PipelineUpdate() { pipelines[name] = part }
            }
            for name in last.graphs.keys where reading.pipelines[name] == nil {
                pipelines[name] = .some(nil)
                last.graphs[name] = nil
            }
            if !pipelines.isEmpty { update.pipelines = pipelines }

            let heartbeat = plan.heartbeat.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 } ?? 5
            let empty = update.list == nil && update.host == nil && update.runtime == nil && update.pipelines == nil
            if !empty || now - lastSent >= heartbeat {
                let size = (try? JSONEncoder().encode(update).count) ?? 0
                // The budget is a bucket that fills at the budget's rate, a second's worth at most: an update waits
                // until there's enough in it, and says how long it waited. An update bigger than a second's worth
                // goes once the bucket is full, leaving it owing.
                if let budget = plan.budget, budget > 0 {
                    let rate = Double(budget)
                    tokens = min(rate, tokens + (now - filledAt) * rate)
                    filledAt = now
                    let needed = min(Double(size), rate)
                    if tokens < needed {
                        let wait = (needed - tokens) / rate
                        try? await Task.sleep(for: .milliseconds(Int(wait * 1000) + 1))
                        update.held = Int64(wait * 1_000_000)
                        tokens = needed
                        filledAt = now + wait
                    }
                    tokens -= Double(size)
                }
                seq += 1
                lastSent = now
                lock.withLock { sent += Int64(size) }
                if await !host.takeLostUpdate() {
                    update.received = Date()
                    continuation.yield(.update(update))
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// `values` against what was sent before: null for those unchanged, nothing after the last that changed, or nil if
    /// none did. The first time, all of them.
    static func delta(_ values: [Int64], from previous: [Int64]?) -> [Int64?]? {
        guard let previous, previous.count == values.count else { return values }
        var delta: [Int64?] = zip(values, previous).map { $0 == $1 ? nil : $0 }
        while let last = delta.last, last == nil { delta.removeLast() }
        return delta.isEmpty ? nil : delta
    }

    /// Every count added up over the pipelines' modules, as the daemon's totals are.
    static func totals(of pipelines: [SimulatedReading.Pipeline]) -> [String: Int64] {
        var totals: [String: Int64] = [:]
        for pipeline in pipelines {
            for (index, counts) in pipeline.modules.enumerated() {
                totals["received", default: 0] += counts.received
                totals["handled", default: 0] += counts.handled
                totals["emitted", default: 0] += counts.emitted
                totals["passed", default: 0] += counts.passed
                totals["busy", default: 0] += pipeline.busy[index]
                totals["queued", default: 0] += counts.queued
                totals["dropped", default: 0] += counts.dropped
                totals["filtered", default: 0] += counts.filtered
                totals["failed", default: 0] += counts.failed
                totals["restarts", default: 0] += counts.restarts
                totals["expired", default: 0] += counts.expired
                totals["refused", default: 0] += counts.refused
                if pipeline.spec.modules[index].from.isEmpty { totals["sourced", default: 0] += counts.emitted }
                if let traffic = traffic(pipeline, index) {
                    totals["bytesReceived", default: 0] += traffic[0]
                    totals["bytesSent", default: 0] += traffic[1]
                }
            }
        }
        for key in CountOrder.standard.totals where totals[key] == nil { totals[key] = 0 }
        return totals
    }

    /// Bytes in and out for the network verbs, `[received, sent]`, as Meep2 counts them for the module whose
    /// connection they cross.
    static func traffic(_ pipeline: SimulatedReading.Pipeline, _ index: Int) -> [Int64]? {
        let counts = pipeline.modules[index]
        switch pipeline.spec.modules[index].verb {
        case "Listen": return [counts.emitted * 220, counts.emitted * 40]
        case "Fetch": return [counts.handled * 820, 0]
        case "Send": return [counts.handled * 24, counts.handled * 310]
        default: return nil
        }
    }

    /// A module's handling times, spread about its average as real ones are, at scale 3: eight buckets a doubling.
    static func histogram(_ pipeline: SimulatedReading.Pipeline, _ index: Int) -> TimingHistogram? {
        let mean = pipeline.spec.modules[index].handlingTime
        let count = pipeline.modules[index].handled
        guard mean > 0, count > 0 else { return nil }
        let centre = Int((log2(mean) * 8).rounded(.down))
        let weights = (-8...8).map { exp(-Double($0 * $0) / 10) }
        let total = weights.reduce(0, +)
        var buckets = weights.map { Int64((Double(count) * $0 / total).rounded(.down)) }
        buckets[8] += count - buckets.reduce(0, +)
        return TimingHistogram(
            count: count, sum: Double(pipeline.busy[index]) / 1_000_000, min: pow(2, Double(centre - 8) / 8),
            max: pow(2, Double(centre + 9) / 8), zero: 0, offset: centre - 8, buckets: buckets
        )
    }

    /// The daemon's own metrics, made up from how busy its pipelines are.
    static func runtime(_ reading: SimulatedReading) -> [String: JSONValue] {
        let busy = Double(reading.pipelines.values.reduce(0) { $0 + $1.busy.reduce(0, +) }) / 1_000_000
        let elapsed = reading.elapsed
        let wobble = sin(elapsed / 9)
        return [
            "dotnet.process.cpu.count": .number(reading.cores),
            "dotnet.process.cpu.time": ["user": .rounded(busy * 1.15 + elapsed * 0.02, places: 3), "system": .rounded(busy * 0.1 + elapsed * 0.01, places: 3)],
            "dotnet.process.memory.working_set": .number(Double(Int64(90_000_000 + 2_000_000 * reading.pipelines.count) + Int64(4_000_000 * wobble))),
            "dotnet.gc.collections": ["gen0": .number(Int(elapsed / 3)), "gen1": .number(Int(elapsed / 30)), "gen2": .number(Int(elapsed / 300))],
            "host.load": ["1m": .rounded(1.2 + busy / max(elapsed, 1) + 0.4 * wobble, places: 2), "5m": .rounded(1.1 + busy / max(elapsed, 1), places: 2), "15m": 1.0],
            "host.memory.available": .number(17_179_869_184),
        ]
    }
}
