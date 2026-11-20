import FlowKit
import Foundation
import MeepClient

/// Keeps one ``MeepHost`` up to date: connects to it, follows its pipelines and their counts, fetches graphs when they
/// change, and reconnects when the host goes away.
///
/// With a daemon from Meep2 0c83a49 or later it follows the host with one subscription, planned to ask only for what's
/// shown (design, section 4): each pipeline at the detail the canvas draws it with (``MeepPipeline/detail``), slowed
/// down together to keep the connection within the host's byte budget. The plan is changed in place as the camera
/// moves. With an older daemon it falls back to step 1's way: the list every two seconds and a stats stream for each
/// live pipeline.
@MainActor
public final class HostSession {
    public let host: MeepHost
    private let connect: @Sendable () async throws -> any HostLink
    private let settings: Settings
    private var running: Task<Void, Never>?
    private var following: [String: (token: Int, every: Duration, task: Task<Void, Never>)] = [:]
    private var nextToken = 0
    private let clock = ContinuousClock()
    private let epoch: ContinuousClock.Instant
    private var fetching: Set<String> = []

    public struct Settings: Sendable {
        /// How often each pipeline's counts come, from a daemon without subscriptions.
        public var statsEvery: Duration = .seconds(1)
        /// How often the counts come for a pipeline a view is showing in detail, from a daemon without subscriptions.
        public var watchedStatsEvery: Duration = .milliseconds(200)
        /// How often the list of pipelines is asked for again, from a daemon without subscriptions.
        public var listEvery: Duration = .seconds(2)
        /// How long to wait before trying an unreachable host again.
        public var retryAfter: Duration = .seconds(3)
        /// The least every pipeline is followed with, whatever's shown.
        public var leastDetail: SubscriptionPlanner.Detail = .listed
        /// How often the plan is looked at again, to follow the camera.
        public var replanEvery: Duration = .milliseconds(300)
        /// Every rate the planner chooses is multiplied by this, down to the daemon's least of 50 ms: tests make it
        /// small, to see things change quickly.
        public var rateScale: Double = 1
        /// JSON or CBOR, which is about half the size.
        public var encoding: SubscriptionEncoding = .cbor
        /// Whether to use a subscription when the daemon has them; false to follow it as step 1 did.
        public var subscribes = true

        public init(
            statsEvery: Duration = .seconds(1), watchedStatsEvery: Duration = .milliseconds(200),
            listEvery: Duration = .seconds(2), retryAfter: Duration = .seconds(3), leastDetail: SubscriptionPlanner.Detail = .listed,
            replanEvery: Duration = .milliseconds(300), rateScale: Double = 1, encoding: SubscriptionEncoding = .cbor, subscribes: Bool = true
        ) {
            self.statsEvery = statsEvery
            self.watchedStatsEvery = watchedStatsEvery
            self.listEvery = listEvery
            self.retryAfter = retryAfter
            self.leastDetail = leastDetail
            self.replanEvery = replanEvery
            self.rateScale = rateScale
            self.encoding = encoding
            self.subscribes = subscribes
        }
    }

    public init(host: MeepHost, settings: Settings = Settings(), connect: @escaping @Sendable () async throws -> any HostLink) {
        self.host = host
        self.settings = settings
        self.connect = connect
        epoch = clock.now
    }

    /// Starts keeping the host up to date, until ``stop()``.
    public func start() {
        guard running == nil else { return }
        running = Task { await run() }
    }

    public func stop() {
        running?.cancel()
        running = nil
        host.link = nil
        stopFollowing()
    }

    private var now: Double {
        let elapsed = clock.now - epoch
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func run() async {
        while !Task.isCancelled {
            // A host that can't be reached keeps saying why while it's tried again, rather than flickering.
            if case .unreachable = host.status {} else if host.status != .connected { host.status = .connecting }
            var link: (any HostLink)?
            do {
                let opened = try await connect()
                link = opened
                let info = try await opened.info()
                host.info = info
                if let id = info.id {
                    host.identity = HostIdentity(id: id, names: info.names ?? [], addresses: info.addresses ?? [], version: info.version, pid: info.processId)
                }
                host.listens = info.listening ?? host.listens
                host.status = .connected
                host.link = opened
                if settings.subscribes, info.id != nil {
                    try await followSubscription(opened)
                } else {
                    host.traffic.subscribed = false
                    try await follow(opened)
                }
            } catch is CancellationError {
                break
            } catch {
                host.status = .unreachable(error.localizedDescription)
            }
            stopFollowing()
            host.link = nil
            await link?.close()
            try? await Task.sleep(for: settings.retryAfter)
        }
        stopFollowing()
    }

    // MARK: One subscription

    /// What's needed to read a subscription's updates, from its `hello`.
    private struct Reading {
        var order = CountOrder.standard
        var scale = 3
        /// The host's clock and this session's at the hello, to put the host's times on this session's clock.
        var hostStart: Int64 = 0
        var localStart: Double = 0
        var seq = 0
        /// The summaries the list has given, by name; updates carry only those that changed.
        var summaries: [String: PipelineSummary] = [:]
        /// Bytes the subscription had sent, and when, a few updates back, for its bandwidth.
        var sentAt: [(time: Double, bytes: Int64)] = []
        /// The latest of the host's clock less this Mac's, over recent updates; the largest is the least delayed.
        var offsets: [Double] = []
        var heldUntil: Double = 0
    }

    /// The plan the subscription has now, and what the planner estimated it costs.
    private var plan = SubscriptionPlan()
    private var rates: SubscriptionPlanner.Rates?
    private var planner = SubscriptionPlanner(budget: nil)

    /// Follows the host through one subscription until it fails, changing the plan as what's shown changes.
    private func followSubscription(_ link: any HostLink) async throws {
        planner = SubscriptionPlanner(budget: host.budget, compact: settings.encoding == .cbor)
        plan = makePlan()
        let subscription = try await link.subscribe(plan)
        host.traffic.subscribed = true
        defer { Task { await subscription.cancel() } }

        // The plan follows what's shown, and the budget, a few times a second.
        let replanning = Task { [weak self] in
            var lastCalibrated = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.settings.replanEvery ?? .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                planner.budget = host.budget
                if now - lastCalibrated > 3, host.traffic.bandwidth > 0, let estimate = rates?.estimate {
                    lastCalibrated = now
                    let held = (host.traffic.lastHeld ?? -100) > now - 3
                    planner.observe(sent: host.traffic.bandwidth, estimated: estimate, held: held)
                }
                let next = makePlan()
                if next != plan {
                    plan = next
                    try? await subscription.change(to: next)
                }
            }
        }
        defer { replanning.cancel() }

        var reading = Reading()
        for try await event in subscription.events {
            switch event {
            case .hello(let hello):
                host.identity = hello.host
                reading.order = hello.counts
                reading.scale = hello.timing?.scale ?? 3
                reading.hostStart = hello.clock
                reading.localStart = now
                reading.seq = 0
            case .update(let update):
                if reading.seq > 0, update.seq != reading.seq + 1 {
                    // One went missing: ask for everything whole, rather than trust counts that may be stale.
                    host.traffic.gaps += 1
                    try? await subscription.resend()
                }
                reading.seq = update.seq
                apply(update, reading: &reading, plan: plan)
            case .plan:
                host.traffic.problem = nil
            case .problem(let message):
                host.traffic.problem = message
            }
        }
        throw HostError.disconnected("The host ended the subscription.")
    }

    /// The plan for what's shown now, within the budget.
    private func makePlan() -> SubscriptionPlan {
        var details: [String: SubscriptionPlanner.Detail] = [:]
        var shapes: [String: SubscriptionPlanner.Shape] = [:]
        for pipeline in host.pipelines {
            let detail = max(pipeline.detail, settings.leastDetail)
            guard detail > .listed else { continue }
            details[pipeline.name] = detail
            shapes[pipeline.name] = SubscriptionPlanner.Shape(modules: pipeline.modules.count, links: pipeline.links.count)
        }
        let rates = planner.rates(for: details, shapes: shapes, others: max(0, host.pipelines.count - details.count))
        self.rates = rates
        host.traffic.slowdown = rates.slowdown
        host.traffic.estimate = rates.estimate
        var counted: [SubscriptionPlanner.Detail: Int] = [:]
        for pipeline in host.pipelines { counted[max(pipeline.detail, settings.leastDetail), default: 0] += 1 }
        host.traffic.detail = counted

        func duration(_ seconds: Double) -> Duration { .milliseconds(max(50, Int((seconds * settings.rateScale * 1000).rounded()))) }
        var pipelines: [String: PipelinePlan] = ["*": PipelinePlan(totals: duration(rates.others))]
        for (name, entry) in rates.pipelines {
            pipelines[name] = PipelinePlan(
                totals: duration(entry.totals),
                modules: entry.modules.map { ["*": duration($0)] } ?? [:],
                links: entry.links.map { ["*": duration($0)] } ?? [:],
                timing: entry.timing.map { ["*": duration($0)] } ?? [:],
                bytes: entry.bytes.map { ["*": duration($0)] } ?? [:]
            )
        }
        return SubscriptionPlan(
            encoding: settings.encoding, list: duration(rates.list), host: duration(rates.host), runtime: duration(rates.runtime),
            budget: host.budget.map { Int($0) }, pipelines: pipelines
        )
    }

    /// Takes one update into the model, on this session's clock.
    private func apply(_ update: SubscriptionUpdate, reading: inout Reading, plan: SubscriptionPlan) {
        let time = reading.localStart + Double(update.clock - reading.hostStart) / 1_000_000
        let arrived = now

        // The clock offset: the host's clock less this Mac's when each update arrived. Delays only make it smaller,
        // so the largest of the last few is the best guess.
        reading.offsets.append(Double(update.clock) / 1_000_000 - (update.received ?? Date()).timeIntervalSince1970)
        if reading.offsets.count > 20 { reading.offsets.removeFirst() }
        host.clockOffset = reading.offsets.max()

        // Bandwidth, from what the host says it has sent, over the last few seconds.
        reading.sentAt.append((arrived, update.bytes))
        reading.sentAt.removeAll { $0.time < arrived - 4 }
        if let first = reading.sentAt.first, let last = reading.sentAt.last, last.time - first.time > 0.5 {
            host.traffic.bandwidth = Double(last.bytes - first.bytes) / (last.time - first.time)
        }
        if update.held != nil { host.traffic.lastHeld = arrived }

        if let list = update.list {
            for (name, summary) in list {
                if let summary { reading.summaries[name] = summary } else { reading.summaries.removeValue(forKey: name) }
            }
            host.apply(reading.summaries.values.sorted { $0.name < $1.name })
        }
        if let hostUpdate = update.host {
            if let totals = hostUpdate.totals { host.totals.read(totals, at: time) }
            if let states = hostUpdate.states {
                for (state, count) in states {
                if let count { host.states[state] = count } else { host.states.removeValue(forKey: state) }
            }
            }
            if let listens = hostUpdate.listens { host.listens = listens }
        } else if let every = plan.host.map(seconds), let last = host.totals.lastRead, time - last > 1.5 * every, time - last < 6 * every {
            host.totals.read(at: time)
        }
        if let runtime = update.runtime {
            host.runtime.apply(runtime, at: time)
        }

        for pipeline in host.pipelines {
            let part = update.pipelines?[pipeline.name] ?? nil
            let entry = plan.pipelines[pipeline.name] ?? plan.pipelines["*"]
            apply(part, to: pipeline, entry: entry, at: time, reading: reading)
        }
    }

    private func apply(_ part: PipelineUpdate?, to pipeline: MeepPipeline, entry: PipelinePlan?, at time: Double, reading: Reading) {
        if let stamp = part?.graph {
            pipeline.graphVersion = stamp.version
        }
        if pipeline.needsGraph || pipeline.graph == nil && part?.graph != nil { fetchGraph(of: pipeline) }

        // Each thing asked for is read when it comes, or as unchanged once it's late, so its rates fall to 0. Only
        // while it's being followed, though: one asked for again after a gap is waited for, since an update already on
        // its way when the plan changed won't have it, and reading its old counts now would make the next look like a
        // burst.
        func late(_ last: Double?, _ every: Duration?) -> Bool {
            guard let every, let last else { return false }
            let gap = time - last
            return gap > 1.5 * seconds(every) && gap < 6 * seconds(every)
        }
        if let totals = part?.totals {
            pipeline.totals.read(totals, at: time)
        } else if late(pipeline.totals.lastRead, entry?.totals), !pipeline.totals.isEmpty {
            pipeline.totals.read(at: time)
        }
        let modulesEvery = entry?.modules["*"]
        for (key, values) in part?.modules ?? [:] {
            let module = pipeline.module(key) ?? pipeline.addModule(key)
            module.apply(values, order: reading.order.modules, at: time)
        }
        for module in pipeline.modules where part?.modules?[module.key] == nil && module.lastRead != nil && late(module.lastRead, modulesEvery) {
            module.apply(nil, order: reading.order.modules, at: time)
        }
        let linksEvery = entry?.links["*"]
        for link in pipeline.links {
            if let values = part?.links?[link.key] {
                link.apply(values, at: time)
            } else if link.isCounted, late(link.lastRead, linksEvery) {
                link.apply(nil, at: time)
            }
        }
        for (key, values) in part?.bytes ?? [:] {
            pipeline.module(key)?.apply(traffic: values, at: time)
        }
        for (key, histogram) in part?.timing ?? [:] {
            if let histogram { pipeline.module(key)?.apply(timing: histogram, scale: reading.scale) }
        }
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Fetches a pipeline's graph, once at a time.
    private func fetchGraph(of pipeline: MeepPipeline) {
        guard let link = host.link, !fetching.contains(pipeline.name) else { return }
        fetching.insert(pipeline.name)
        Task {
            defer { fetching.remove(pipeline.name) }
            if let graph = try? await link.graph(pipeline.name) { pipeline.apply(graph) }
        }
    }

    // MARK: Without subscriptions

    /// Lists pipelines every so often, following each live one, until the link fails. Between lists it looks a few
    /// times a second for pipelines that a view has started or stopped showing, to change how often their counts come.
    private func follow(_ link: any HostLink) async throws {
        var listed: ContinuousClock.Instant?
        while !Task.isCancelled {
            if listed.map({ clock.now - $0 >= settings.listEvery }) ?? true {
                listed = clock.now
                host.apply(try await link.pipelines())
                for pipeline in host.pipelines where pipeline.graph == nil && !pipeline.state.isLive && pipeline.graphVersion == nil {
                    // An ended pipeline's final counts, once, so it doesn't show empty.
                    if let detail = try? await link.pipeline(pipeline.name) {
                        pipeline.apply(detail, at: now)
                        await fetchGraph(of: pipeline, over: link)
                    }
                }
            }
            followLive(over: link)
            try await Task.sleep(for: min(settings.listEvery, .milliseconds(250)))
        }
        throw CancellationError()
    }

    /// Starts and stops following pipelines' counts as they come and go, at the rate each needs.
    private func followLive(over link: any HostLink) {
        let live = Dictionary(uniqueKeysWithValues: host.pipelines.filter { $0.state.isLive }.map {
            ($0.name, $0.watchers > 0 ? settings.watchedStatsEvery : settings.statsEvery)
        })
        for (name, entry) in following where live[name] != entry.every {
            following.removeValue(forKey: name)
            entry.task.cancel()
        }
        for (name, every) in live where following[name] == nil {
            nextToken += 1
            let token = nextToken
            following[name] = (token, every, Task { await followStats(of: name, every: every, over: link, token: token) })
        }
    }

    private func followStats(of name: String, every: Duration, over link: any HostLink, token: Int) async {
        do {
            for try await event in link.stats(name, every: every) {
                guard let pipeline = host.pipeline(name) else { continue }
                switch event {
                case .stats(let detail):
                    pipeline.apply(detail, at: now)
                    if pipeline.needsGraph { await fetchGraph(of: pipeline, over: link) }
                case .graph(let notice):
                    if pipeline.graph?.version != notice.version { await fetchGraph(of: pipeline, over: link) }
                case .end:
                    break
                }
            }
        } catch {
            // The list's next poll notices a lost connection; a stream for a pipeline that went is simply dropped.
        }
        // Let the next look at the list start another, unless one has replaced this already.
        if following[name]?.token == token { following.removeValue(forKey: name) }
    }

    private func fetchGraph(of pipeline: MeepPipeline, over link: any HostLink) async {
        if let graph = try? await link.graph(pipeline.name) {
            pipeline.apply(graph)
        }
    }

    private func stopFollowing() {
        for entry in following.values { entry.task.cancel() }
        following.removeAll()
    }
}
