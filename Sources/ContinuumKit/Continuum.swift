import FlowKit
import Foundation
import MeepClient
import Observation
import Transport

/// Everything Synesthesia can reach that's built on Meep: its hosts, their pipelines and their modules.
///
/// The model lives on the main actor, where SwiftUI reads it. Each host is kept up to date by a ``HostSession``,
/// which talks to it off the main actor and hands over what it hears.
@MainActor @Observable
public final class Continuum {
    public private(set) var hosts: [MeepHost] = []

    public init() {}

    /// Adds a host, or returns the one already known by that name.
    @discardableResult
    public func add(host name: String, title: String? = nil, kind: MeepHost.Kind) -> MeepHost {
        if let existing = hosts.first(where: { $0.name == name }) { return existing }
        let host = MeepHost(name: name, title: title ?? name, kind: kind)
        hosts.append(host)
        return host
    }

    public func remove(host name: String) {
        hosts.removeAll { $0.name == name }
    }

    public func host(_ name: String) -> MeepHost? {
        hosts.first { $0.name == name }
    }

    /// Whatever is at an address: a host, a pipeline or a module.
    public func pipeline(at address: MeepAddress) -> MeepPipeline? {
        guard let name = address.pipeline else { return nil }
        return host(address.host)?.pipeline(name)
    }

    public func module(at address: MeepAddress) -> MeepModule? {
        guard let key = address.module else { return nil }
        return pipeline(at: address)?.module(key)
    }
}

/// One Meep daemon, or a pretend one.
@MainActor @Observable
public final class MeepHost: Identifiable {
    public enum Kind: Sendable, Equatable {
        /// The daemon on this Mac, over its Unix socket.
        case local(socketPath: String)
        /// A daemon on another machine, through its socket forwarded over SSH.
        case remote(SSHTarget)
        /// A pretend host from the Simulation package.
        case simulated

        /// The byte budget a connection of this kind starts with (design, section 4): lower over SSH.
        public var usualBudget: Double {
            switch self {
            case .local: 1_000_000
            case .remote: 64_000
            case .simulated: 256_000
            }
        }

        /// How it's reached, for people.
        public var summary: String {
            switch self {
            case .local(let socket): "this Mac, at \(socket)"
            case .remote(let target): "SSH to \(target.description)"
            case .simulated: "simulated"
            }
        }
    }

    public enum Status: Sendable, Equatable {
        case connecting
        case connected
        /// It can't be reached, and why; Synesthesia keeps trying.
        case unreachable(String)
    }

    /// The name in its addresses, such as `local`.
    public let name: String
    /// What it's called on screen.
    public var title: String
    public let kind: Kind
    public internal(set) var status: Status = .connecting
    public internal(set) var info: DaemonInfo?
    public internal(set) var pipelines: [MeepPipeline] = []
    /// The link to it while it's connected, for asking it for more than the session follows, such as a pipeline's
    /// text, or to reload one.
    @ObservationIgnored public internal(set) var link: (any HostLink)?
    /// Who the daemon is: its lasting ID, names and addresses, once it has said. Kept while it can't be reached.
    public internal(set) var identity: HostIdentity?
    /// Where its Listens are bound.
    public internal(set) var listens: [ListenAddress] = []
    /// Where its Fetches and Sends send, as declared when their pipelines started (Meep2 a5de139).
    public internal(set) var sends: [SendAddress] = []
    /// How far its clock is ahead of this Mac's, in seconds, estimated from when its updates arrive.
    public internal(set) var clockOffset: Double?
    /// How its connection reaches it, when there's more to say than its kind: through a forwarded socket, or relayed.
    public var route: String?
    /// Its totals, added up over every pipeline by the daemon, with their rates.
    public internal(set) var totals = CountSet()
    /// How many of its pipelines are in each state.
    public internal(set) var states: [String: Int] = [:]
    /// Its processor, memory and garbage collection, from .NET's runtime metrics.
    public internal(set) var runtime = HostRuntime()
    /// Bytes a second its connection may carry (design, section 4): the planner lowers rates to stay under it. Nil
    /// for no limit.
    public var budget: Double?
    /// What its connection carries, and how the planner is keeping it within ``budget``.
    public internal(set) var traffic = HostTraffic()

    public nonisolated var id: String { name }
    public var address: MeepAddress { MeepAddress(host: name) }

    init(name: String, title: String, kind: Kind) {
        self.name = name
        self.title = title
        self.kind = kind
        budget = kind.usualBudget
    }

    public func pipeline(_ name: String) -> MeepPipeline? {
        pipelines.first { $0.name == name }
    }

    /// Messages a second received by all its pipelines' modules, or 0 while it can't be reached.
    public var throughput: Double {
        guard isReachable else { return 0 }
        if !totals.isEmpty { return totals.rate("received") }
        return pipelines.reduce(0) { $0 + $1.throughput }
    }

    /// Messages a second coming into its pipelines from their sources, or 0 while it can't be reached.
    public var intake: Double {
        guard isReachable else { return 0 }
        if !totals.isEmpty { return totals.rate("sourced") }
        return pipelines.reduce(0) { $0 + $1.intake }
    }

    /// Processor cores its pipelines keep busy handling messages: their modules' handling time a second.
    public var load: Double {
        guard isReachable else { return 0 }
        if !totals.isEmpty { return totals.rate("busy") / 1_000_000 }
        return pipelines.reduce(0) { $0 + $1.load }
    }

    /// Failures and refusals a second, over all its pipelines.
    public var errorRate: Double {
        guard isReachable else { return 0 }
        if !totals.isEmpty { return totals.rate("failed") + totals.rate("refused") }
        return pipelines.reduce(0) { $0 + $1.errorRate }
    }

    /// Its handling times, merged from every pipeline's that's known (design, section 4, "Digests").
    public var timing: HandlingHistogram {
        HandlingHistogram.merged(pipelines.map(\.timing))
    }

    /// How its machine's processor time is used: by its pipelines, by the rest of the daemon, and what's left.
    public var headroom: Headroom? {
        guard isReachable, let cores = runtime.cores, cores > 0 else { return nil }
        let daemon = runtime.cpuRate
        let pipelines = min(load, daemon ?? load)
        return Headroom(cores: cores, pipelines: pipelines, daemon: daemon, machineLoad: runtime.load1m)
    }

    /// Whether what it shows is current. While it isn't, its pipelines are as last seen.
    public var isReachable: Bool { status == .connected }

    /// Takes the host's list of pipelines, adding and removing as it says.
    func apply(_ summaries: [PipelineSummary]) {
        var kept: [MeepPipeline] = []
        for summary in summaries {
            let pipeline = pipeline(summary.name) ?? MeepPipeline(host: name, name: summary.name)
            pipeline.apply(summary)
            kept.append(pipeline)
        }
        pipelines = kept
    }
}

/// A pipeline on a host.
@MainActor @Observable
public final class MeepPipeline: Identifiable {
    public let host: String
    public let name: String
    public internal(set) var path = ""
    public internal(set) var state: PipelineState = .starting
    public internal(set) var started: Date?
    public internal(set) var ended: Date?
    public internal(set) var reason: String?
    public internal(set) var restarts = 0
    public internal(set) var warnings: [String] = []
    /// Whether the daemon reloads it when its file changes; nil when the daemon doesn't say.
    public internal(set) var watching: Bool?
    public internal(set) var modules: [MeepModule] = []
    /// The links between its modules, from its graph, with what each has carried.
    public internal(set) var links: [MeepLink] = []
    /// Its graph, once fetched: links, roles and where each module is written.
    public internal(set) var graph: PipelineGraph?
    /// The graph version its latest counts belong to.
    public internal(set) var graphVersion: Int?
    /// How many views are showing it in detail, such as a canvas. While any are, its counts come more often.
    public var watchers = 0
    /// How much the canvas shows of it, for the planner to ask for what's drawn and no more (design, section 4).
    public var shownAs: SubscriptionPlanner.Detail = .listed
    /// How much of its flows and boundary the canvas draws, for the planner to ask for its places only then.
    public var flowsShownAs: SubscriptionPlanner.FlowDetail = .none
    /// Modules whose handling times are shown somewhere other than the canvas, such as the code level's gutter, by who
    /// asked: the planner asks for their times, however little of the pipeline the canvas shows.
    @ObservationIgnored private var timingAsks: [String: Set<String>] = [:]
    /// Its totals: each count added up over its modules by the daemon, with `sourced` and its bytes.
    public internal(set) var totals = CountSet()
    /// Names for the addresses of clients outside Meep that its Listens have heard from, by reverse DNS.
    public internal(set) var clients: [String: String] = [:]
    /// Which of the places its Fetches and Sends connect to are Meep hosts, by `host:port`: their daemons' IDs.
    public internal(set) var peers: [String: String] = [:]
    /// The latest counts for its links, kept for links its graph hasn't got yet: the counts can arrive first.
    @ObservationIgnored private var linkCounts: (counts: [String: LinkDetail], time: Double)?

    public nonisolated var id: String { "\(host)/\(name)" }
    public var address: MeepAddress { MeepAddress(host: host, pipeline: name) }

    init(host: String, name: String) {
        self.host = host
        self.name = name
    }

    public func module(_ key: String) -> MeepModule? {
        modules.first { $0.key == key }
    }

    /// A module a subscription has counts for before the graph has come, by its key.
    func addModule(_ key: String) -> MeepModule {
        let module = MeepModule(key: key)
        modules.append(module)
        return module
    }

    public func link(_ key: String) -> MeepLink? {
        links.first { $0.key == key }
    }

    /// Messages a second received by all its modules, or 0 once it has ended.
    public var throughput: Double {
        guard state.isLive else { return 0 }
        if !totals.isEmpty { return totals.rate("received") }
        return modules.reduce(0) { $0 + $1.rates[.received] }
    }

    /// Messages a second its sources bring in, or 0 once it has ended.
    public var intake: Double {
        guard state.isLive else { return 0 }
        if !totals.isEmpty { return totals.rate("sourced") }
        return modules.filter { $0.role == .source || $0.role == .inlet }.reduce(0) { $0 + $1.rates[.emitted] }
    }

    /// Processor cores it keeps busy handling messages: its modules' handling time a second.
    public var load: Double {
        guard state.isLive else { return 0 }
        if !totals.isEmpty { return totals.rate("busy") / 1_000_000 }
        return modules.reduce(0) { $0 + $1.load }
    }

    /// Failures and refusals a second.
    public var errorRate: Double {
        guard state.isLive else { return 0 }
        if !totals.isEmpty { return totals.rate("failed") + totals.rate("refused") }
        return modules.reduce(0) { $0 + $1.rates[.failed] + $1.rates[.refused] }
    }

    /// Messages waiting in its modules' buffers now.
    public var queued: Int64 {
        if !totals.isEmpty { return totals["queued"] }
        return modules.reduce(0) { $0 + $1.counts.queued }
    }

    /// Bytes a second its network verbs receive and send.
    public var bandwidth: (received: Double, sent: Double) {
        (totals.rate("bytesReceived"), totals.rate("bytesSent"))
    }

    /// Its handling times, merged from its modules' (design, section 4, "Digests").
    public var timing: HandlingHistogram {
        HandlingHistogram.merged(modules.compactMap(\.timing))
    }

    /// What the planner should ask its host for: everything while a view shows it in detail, otherwise what the
    /// canvas draws of it.
    public var detail: SubscriptionPlanner.Detail {
        watchers > 0 ? .full : shownAs
    }

    /// How much of its flows the planner should ask for: every second while a view shows it in detail, otherwise what
    /// the canvas draws.
    public var flowDetail: SubscriptionPlanner.FlowDetail {
        watchers > 0 ? max(flowsShownAs, .close) : flowsShownAs
    }

    /// The modules whose handling times have been asked for, whatever the canvas shows.
    public var timingWanted: Set<String> {
        timingAsks.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    /// Asks for these modules' handling times until ``endTimingAsk(by:)``, replacing what `asker` asked before.
    public func askForTiming(of keys: Set<String>, by asker: String) {
        if keys.isEmpty { timingAsks.removeValue(forKey: asker) } else { timingAsks[asker] = keys }
    }

    public func endTimingAsk(by asker: String) {
        timingAsks.removeValue(forKey: asker)
    }

    /// Whether its graph is older than its counts, so it should be fetched again.
    public var needsGraph: Bool {
        guard let graphVersion else { return false }
        return graph?.version != graphVersion
    }

    func apply(_ summary: PipelineSummary) {
        path = summary.path
        state = summary.state
        started = summary.started
        ended = summary.ended
        reason = summary.reason
        restarts = summary.restarts
        warnings = summary.warnings
        watching = summary.watching
    }

    /// Takes the pipeline's counts at `time`, in seconds on a steady clock.
    func apply(_ detail: PipelineDetail, at time: Double) {
        path = detail.path
        state = detail.state
        started = detail.started
        ended = detail.ended
        reason = detail.reason
        restarts = detail.restarts
        graphVersion = detail.graphVersion
        if let watching = detail.watching { self.watching = watching }

        var kept: [MeepModule] = []
        for module in detail.modules {
            let graphModule = graph.flatMap { graph in graph.modules.first { $0.number == module.number } }
            let key = graphModule?.key ?? "#\(module.number)"
            let model = modules.first { $0.key == key } ?? MeepModule(key: key)
            model.apply(module, graph: graphModule, at: time)
            kept.append(model)
        }
        modules = kept

        if let counted = detail.links {
            linkCounts = (Dictionary(counted.map { ($0.key, $0) }, uniquingKeysWith: { $1 }), time)
            for link in counted {
                self.link(link.key)?.apply(link, at: time)
            }
        }
    }

    /// Takes a new version of the graph, giving modules their lasting keys.
    func apply(_ graph: PipelineGraph) {
        self.graph = graph
        var kept: [MeepModule] = []
        for graphModule in graph.modules {
            let model = modules.first { $0.key == graphModule.key }
                ?? modules.first { $0.key == "#\(graphModule.number)" }.map { $0.rekeyed(graphModule.key) }
                ?? MeepModule(key: graphModule.key)
            model.apply(graphModule)
            kept.append(model)
        }
        modules = kept
        // A link kept through a reload keeps its object, and its counts, as the daemon keeps them.
        links = graph.links.map { graphLink in
            if let model = link(graphLink.key) {
                model.apply(graphLink)
                return model
            }
            let model = MeepLink(key: graphLink.key)
            model.apply(graphLink)
            if let linkCounts, let counted = linkCounts.counts[graphLink.key] {
                model.apply(counted, at: linkCounts.time)
            }
            return model
        }
    }
}

/// A link between two modules: a wire on the canvas.
@MainActor @Observable
public final class MeepLink: Identifiable {
    /// `from>to`, from the modules' keys, so it lasts as they do.
    public let key: String
    public internal(set) var from = ""
    public internal(set) var to = ""
    /// Which of the receiving module's inputs it is, counting from 1.
    public internal(set) var input = 1
    public internal(set) var port = LinkPort.main
    public internal(set) var types: [String] = []
    /// Whether the daemon counts what it carries. Daemons before Meep2 ee030d7 don't.
    public internal(set) var isCounted = false
    /// Messages it has carried, errors included.
    public internal(set) var carried: Int64 = 0
    /// How many of ``carried`` were errors.
    public internal(set) var errors: Int64 = 0
    /// When its counts were last read, in seconds on the session's clock.
    public internal(set) var lastRead: Double?
    /// Messages a second, errors included.
    public var rate: Double { carriedMeter.rate }
    /// Errors a second.
    public var errorRate: Double { errorMeter.rate }

    private var carriedMeter = RateMeter()
    private var errorMeter = RateMeter()

    public nonisolated var id: String { key }

    init(key: String) {
        self.key = key
    }

    func apply(_ link: GraphLink) {
        from = link.from
        to = link.to
        input = link.input
        port = link.linkPort
        types = link.types
    }

    /// Takes `[carried, errors]` from a subscription: null keeps one as it was. With nil, reads them again as
    /// unchanged.
    func apply(_ values: [Int64?]?, at time: Double) {
        var detail = LinkDetail(key: key, carried: carried, errors: errors)
        if let values {
            if values.count > 0, let value = values[0] { detail.carried = value }
            if values.count > 1, let value = values[1] { detail.errors = value }
        }
        apply(detail, at: time)
    }

    func apply(_ detail: LinkDetail, at time: Double) {
        lastRead = time
        isCounted = true
        carried = detail.carried
        errors = detail.errors
        carriedMeter.update(detail.carried, at: time)
        errorMeter.update(detail.errors, at: time)
    }
}

/// A module in a pipeline.
@MainActor @Observable
public final class MeepModule: Identifiable {
    /// Its key in the pipeline's graph, which lasts through reloads, or `#number` until the graph is known.
    public private(set) var key: String
    public internal(set) var number = 0
    /// How it's shown: its name, or its verb and number.
    public internal(set) var label = ""
    public internal(set) var verb = ""
    public internal(set) var name: String?
    public internal(set) var role: VerbRole?
    /// The inflections its parameters fit, as the loader found: usually one, such as `HTTP` for a Fetch of an
    /// `https://` address.
    public internal(set) var inflections: [String] = []
    /// The plugin its verb comes from, by the name its pipeline gives it, or nil for one of Meep's own.
    public internal(set) var plugin: String?
    public internal(set) var counts = ModuleStats.zero
    public internal(set) var rates = RateSet()
    /// Microseconds spent handling messages since the pipeline started.
    public internal(set) var busy: Int64 = 0
    /// Its handling times since the pipeline started, when the host sends them.
    public internal(set) var timing: HandlingHistogram?
    /// Bytes its connections have received and sent, for the network verbs that count them.
    public internal(set) var traffic: CountSet?
    /// When its counts were last read, in seconds on the session's clock.
    public internal(set) var lastRead: Double?
    /// A Listen's counts by where messages came from, or a Fetch's or Send's by where it connected, in
    /// ``CountOrder/places``' names, with their rates (Meep2 a5de139). `*` and `meep://*` hold what's past its limit.
    public internal(set) var places: [String: CountSet] = [:]
    /// Which kind its ``places`` are.
    public internal(set) var placeKind: PlaceKind?
    /// When its places were last read.
    public internal(set) var placesRead: Double?
    /// Whether its places are being followed now. While they aren't, their counts are as last seen and their rates
    /// mean nothing.
    public internal(set) var placesFollowed = false
    private var busyMeter = RateMeter()

    /// How busy it is, from 0 to 1: its handling time a second. A module handles one message at a time, so near 1
    /// it's the bottleneck and its queue will grow (design, section 4, "Load").
    public var load: Double { busyMeter.rate / 1_000_000 }
    /// Its rate over the last minute: what it emits for a source, otherwise what it receives.
    public internal(set) var history = RateHistory()

    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(key: String) {
        self.key = key
    }

    fileprivate func rekeyed(_ key: String) -> MeepModule {
        self.key = key
        return self
    }

    func apply(_ detail: ModuleDetail, graph: GraphModule?, at time: Double) {
        number = detail.number
        label = detail.module
        verb = detail.verb
        name = detail.name
        counts = detail.counts
        rates.update(detail.counts.byKind, at: time)
        if let graph { apply(graph) }
        history.record(activity, at: time)
    }

    /// Takes counts from a subscription, in `order`: null keeps a count as it was. With nil, reads them again as
    /// unchanged, so rates fall when nothing has come.
    func apply(_ values: [Int64?]?, order: [String], at time: Double) {
        if let values {
            let (stats, busy) = counts.applying(values, order: order)
            counts = stats
            if let busy { self.busy = busy }
        }
        lastRead = time
        rates.update(counts.byKind, at: time)
        busyMeter.update(busy, at: time)
        history.record(activity, at: time)
    }

    /// Takes its places from a subscription: `folded` first, each one's counts carried into `*` (or `meep://*`), so
    /// `*`'s rate doesn't jump; then the counts that changed, in `order`, null keeping a count as it was; then reads
    /// every place at `time`. With nil, reads them all again as unchanged.
    func apply(places values: [String: [Int64?]?]?, kind: PlaceKind, order: [String], folded: [String], at time: Double) {
        placeKind = kind
        for place in folded {
            guard let counts = places.removeValue(forKey: place) else { continue }
            let star = place.hasPrefix("meep://") ? "meep://*" : "*"
            places[star, default: CountSet()].carry(counts)
        }
        for (place, counts) in values ?? [:] {
            guard let counts else {
                places.removeValue(forKey: place)
                continue
            }
            var changed: [String: Int64?] = [:]
            for (index, value) in counts.enumerated() where index < order.count {
                if let value { changed[order[index]] = value }
            }
            places[place, default: CountSet()].read(changed, at: time)
        }
        for place in places.keys where values?[place] == nil {
            places[place]?.read(at: time)
        }
        placesRead = time
        placesFollowed = true
    }

    /// Forgets its places, as when the host says it has none.
    func clearPlaces() {
        places = [:]
        placesRead = nil
    }

    /// Takes its bytes from a subscription, `[received, sent]`.
    func apply(traffic values: [Int64?]?, at time: Double) {
        var set = traffic ?? CountSet()
        if let values {
            var changed: [String: Int64?] = [:]
            if values.count > 0, let received = values[0] { changed["received"] = received }
            if values.count > 1, let sent = values[1] { changed["sent"] = sent }
            set.read(changed, at: time)
        } else {
            set.read(at: time)
        }
        traffic = set
    }

    func apply(timing histogram: TimingHistogram, scale: Int) {
        timing = HandlingHistogram(
            scale: scale, count: histogram.count, sum: histogram.sum, min: histogram.min, max: histogram.max,
            zero: histogram.zero, offset: histogram.offset, buckets: histogram.buckets
        )
    }

    /// Messages a second through it: what a source emits, or what anything else receives.
    public var activity: Double {
        role == .source || role == .inlet || counts.received == 0 && counts.emitted > 0 ? rates[.emitted] : rates[.received]
    }

    func apply(_ graph: GraphModule) {
        number = graph.number
        label = graph.module
        verb = graph.verb
        name = graph.name
        role = graph.verbRole
        inflections = graph.inflections
        plugin = graph.plugin
    }
}

/// Which way a module's places face.
public enum PlaceKind: String, Sendable {
    /// A Listen's: where what it receives came from.
    case arrivals
    /// A Fetch's or Send's: where it connected to send.
    case destinations
}

extension ModuleStats {
    /// The cumulative counts, by kind, for rates.
    public var byKind: [CountKind: Int64] {
        [
            .received: received, .handled: handled, .emitted: emitted, .passed: passed, .heldBack: heldBack,
            .dropped: dropped, .filtered: filtered, .failed: failed, .expired: expired, .refused: refused,
        ]
    }
}


/// A host's processor, memory and garbage collection, from the runtime metrics a subscription sends.
public struct HostRuntime: Sendable, Equatable {
    /// Each metric as last sent, by its OpenTelemetry name.
    public private(set) var metrics: [String: JSONValue] = [:]
    private var cpuMeter = RateMeter(smoothing: 3)

    public init() {}

    /// Processor cores the daemon can use.
    public var cores: Int? { metrics["dotnet.process.cpu.count"]?.number.map { Int($0) } }
    /// Cores the daemon's process keeps busy: its processor time a second, user and system.
    public var cpuRate: Double? { metrics["dotnet.process.cpu.time"] == nil ? nil : cpuMeter.rate / 1_000_000 }
    /// Bytes of memory the daemon's process uses.
    public var workingSet: Double? { metrics["dotnet.process.memory.working_set"]?.number }
    /// The machine's memory, or its container's limit.
    public var memoryAvailable: Double? { metrics["host.memory.available"]?.number }
    /// The machine's load average over the last minute.
    public var load1m: Double? { metrics["host.load"]?["1m"]?.number }
    /// Garbage collections so far, all generations.
    public var collections: Double? {
        guard case .object(let generations)? = metrics["dotnet.gc.collections"] else { return nil }
        return generations.values.compactMap(\.number).reduce(0, +)
    }

    /// Takes the metrics that changed; one with attributes merges by attribute.
    mutating func apply(_ changed: [String: JSONValue], at time: Double) {
        for (name, value) in changed {
            if case .object(let parts) = value, case .object(var old)? = metrics[name] {
                for (key, part) in parts { old[key] = part }
                metrics[name] = .object(old)
            } else if value == .null {
                metrics.removeValue(forKey: name)
            } else {
                metrics[name] = value
            }
        }
        read(at: time)
    }

    mutating func read(at time: Double) {
        if case .object(let parts)? = metrics["dotnet.process.cpu.time"] {
            let seconds = parts.values.compactMap(\.number).reduce(0, +)
            cpuMeter.update(Int64((seconds * 1_000_000).rounded()), at: time)
        }
    }
}

/// How a machine's processor time is used: the "clock cycles" view (design, section 4, "Load").
public struct Headroom: Sendable, Equatable {
    /// Cores the daemon can use.
    public var cores: Int
    /// Cores its pipelines keep busy handling messages.
    public var pipelines: Double
    /// Cores the daemon's whole process uses, pipelines included, when it says.
    public var daemon: Double?
    /// The machine's load average over the last minute, which counts other programs too.
    public var machineLoad: Double?

    /// The share of the cores left, from 0 to 1: what neither the daemon nor, by its load, anything else is using.
    public var spare: Double {
        let used = max(daemon ?? pipelines, min(machineLoad ?? 0, Double(cores)))
        return max(0, 1 - used / Double(cores))
    }
}

/// What a host's connection carries, and how the planner keeps it within its budget.
public struct HostTraffic: Sendable, Equatable {
    /// Whether it follows the host with one subscription (Meep2 0c83a49 and later), or with the older stats streams.
    public internal(set) var subscribed = false
    /// Bytes a second it has carried lately, as the host counts them.
    public internal(set) var bandwidth: Double = 0
    /// What the planner's rates were estimated to cost, in bytes a second.
    public internal(set) var estimate: Double = 0
    /// How much slower than usual the planner asks for things, to stay under the budget: 1 when it needn't.
    public internal(set) var slowdown: Double = 1
    /// When the host's budget last held an update back, in seconds on the session's clock.
    public internal(set) var lastHeld: Double?
    /// Updates that went missing and were asked for again.
    public internal(set) var gaps = 0
    /// Why the host refused the last change of plan, if it did.
    public internal(set) var problem: String?
    /// What's asked for: how many pipelines in each level of detail.
    public internal(set) var detail: [SubscriptionPlanner.Detail: Int] = [:]
    /// How many pipelines' flows are asked for, at each distance.
    public internal(set) var flows: [SubscriptionPlanner.FlowDetail: Int] = [:]

    public init() {}
}
