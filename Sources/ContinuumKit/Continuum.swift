import FlowKit
import Foundation
import MeepClient
import Observation

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
        /// A pretend host from the Simulation package.
        case simulated
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

    public nonisolated var id: String { name }
    public var address: MeepAddress { MeepAddress(host: name) }

    init(name: String, title: String, kind: Kind) {
        self.name = name
        self.title = title
        self.kind = kind
    }

    public func pipeline(_ name: String) -> MeepPipeline? {
        pipelines.first { $0.name == name }
    }

    /// Messages a second received by all its pipelines' modules, or 0 while it can't be reached.
    public var throughput: Double {
        guard isReachable else { return 0 }
        return pipelines.reduce(0) { $0 + $1.throughput }
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
    public internal(set) var modules: [MeepModule] = []
    /// The links between its modules, from its graph, with what each has carried.
    public internal(set) var links: [MeepLink] = []
    /// Its graph, once fetched: links, roles and where each module is written.
    public internal(set) var graph: PipelineGraph?
    /// The graph version its latest counts belong to.
    public internal(set) var graphVersion: Int?
    /// How many views are showing it in detail, such as a canvas. While any are, its counts come more often.
    public var watchers = 0
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

    public func link(_ key: String) -> MeepLink? {
        links.first { $0.key == key }
    }

    /// Messages a second received by all its modules, or 0 once it has ended.
    public var throughput: Double {
        guard state.isLive else { return 0 }
        return modules.reduce(0) { $0 + $1.rates[.received] }
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

    func apply(_ detail: LinkDetail, at time: Double) {
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
    public internal(set) var inflections: [String] = []
    public internal(set) var counts = ModuleStats.zero
    public internal(set) var rates = RateSet()
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
    }
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
