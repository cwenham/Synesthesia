import Foundation
import MeepClient

/// A pretend Meep host: pipelines with believable, steadily changing counts, served through the same ``HostLink``
/// as a real daemon, with whatever latency you choose.
///
/// It's for tests, and for building the host and mesh levels without fifty real machines. Its counts are worked
/// out from the time since it started, so they only go up, wobble like real traffic, and cost nothing to keep.
public actor SimulatedHost: HostLink {
    public let name: String
    /// How long each answer takes.
    public var latency: Duration
    private let pipelineSpecs: [PipelineSpec]
    private let clock = ContinuousClock()
    private let epoch: ContinuousClock.Instant
    private let started: Date
    private var closed = false

    public init(name: String = "simulated", latency: Duration = .milliseconds(20), pipelines: [PipelineSpec] = PipelineSpec.demo) {
        self.name = name
        self.latency = latency
        pipelineSpecs = pipelines
        epoch = clock.now
        started = Date()
    }

    private var elapsed: Double {
        let duration = clock.now - epoch
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func answer() async throws {
        if closed { throw HostError.disconnected("The simulated host was closed.") }
        try await Task.sleep(for: latency)
    }

    public func info() async throws -> DaemonInfo {
        try await answer()
        return DaemonInfo(version: "simulated", processId: 0, socket: "simulated://\(name)", capabilities: ["observe"], pipelines: pipelineSpecs.map(\.name))
    }

    public func pipelines() async throws -> [PipelineSummary] {
        try await answer()
        return pipelineSpecs.map { PipelineSummary(name: $0.name, path: $0.path, state: .running, started: started) }
    }

    public func pipeline(_ name: String) async throws -> PipelineDetail {
        try await answer()
        return try detail(of: spec(name))
    }

    public func graph(_ name: String) async throws -> PipelineGraph {
        try await answer()
        return try spec(name).graph
    }

    public nonisolated func stats(_ name: String, every interval: Duration) -> AsyncThrowingStream<StatsEvent, any Error> {
        AsyncThrowingStream { continuation in
            let ticking = Task {
                do {
                    while !Task.isCancelled {
                        try await continuation.yield(.stats(self.pipeline(name)))
                        try await Task.sleep(for: interval)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in ticking.cancel() }
        }
    }

    public func close() async {
        closed = true
    }

    private func spec(_ name: String) throws -> PipelineSpec {
        guard let spec = pipelineSpecs.first(where: { $0.name == name }) else {
            throw HostError.refused(status: 404, message: "There's no pipeline called \(name).", details: [])
        }
        return spec
    }

    private func detail(of spec: PipelineSpec) -> PipelineDetail {
        PipelineDetail(
            name: spec.name, path: spec.path, state: .running, started: started,
            modules: spec.counts(at: elapsed), graphVersion: spec.graph.version, links: spec.linkCounts(at: elapsed)
        )
    }
}

/// A simulated pipeline: its graph, and how fast messages flow through each module.
public struct PipelineSpec: Sendable {
    public var name: String
    public var path: String
    public var modules: [ModuleSpec]

    /// One module, and how it treats what reaches it.
    public struct ModuleSpec: Sendable {
        public var verb: String
        public var role: VerbRole
        public var name: String?
        /// The modules it takes messages from, by index; none for a source.
        public var from: [Int]
        /// For a source, messages a second.
        public var rate: Double
        /// For a filter, the share of what it handles that it passes on; for a step, how many new messages it
        /// emits for each it handles.
        public var passes: Double
        /// The share of what it handles that fails, each failure becoming an error.
        public var fails: Double
        /// The share of what reaches it that it drops.
        public var drops: Double
        /// How many messages wait in its buffer, on average.
        public var queue: Double
        /// Whether it takes only errors, as a module with `@errors` does.
        public var errorsOnly: Bool

        public init(
            _ verb: String, _ role: VerbRole, name: String? = nil, from: [Int] = [], rate: Double = 0, passes: Double = 1,
            fails: Double = 0, drops: Double = 0, queue: Double = 0, errorsOnly: Bool = false
        ) {
            self.verb = verb
            self.role = role
            self.name = name
            self.from = from
            self.rate = rate
            self.passes = passes
            self.fails = fails
            self.drops = drops
            self.queue = queue
            self.errorsOnly = errorsOnly
        }
    }

    public init(name: String, modules: [ModuleSpec]) {
        self.name = name
        path = "/simulated/\(name).meep"
        self.modules = modules
    }

    /// The graph a daemon would give for it.
    public var graph: PipelineGraph {
        let graphModules = modules.enumerated().map { index, module in
            GraphModule(
                key: "m\(index + 1)", number: index + 1, module: label(index), verb: module.verb, role: module.role,
                inflections: [module.verb],
                span: GraphSpan(file: path, startLine: index + 1, startColumn: 1, endLine: index + 1, endColumn: 20),
                name: module.name, under: module.from.first.map { "m\($0 + 1)" }
            )
        }
        let links = modules.enumerated().flatMap { index, module in
            module.from.enumerated().map { input, from in
                GraphLink(
                    from: "m\(from + 1)", to: "m\(index + 1)", input: input + 1, port: module.errorsOnly ? .errors : .main,
                    types: module.errorsOnly ? ["ErrorMessage"] : ["ErrorMessage", "Message"]
                )
            }
        }
        return PipelineGraph(name: name, path: path, version: 1, modules: graphModules, links: links)
    }

    private func label(_ index: Int) -> String {
        modules[index].name ?? "\(modules[index].verb) #\(index + 1)"
    }

    /// Each module's counts `seconds` after the pipeline started.
    public func counts(at seconds: Double) -> [ModuleDetail] {
        flow(at: seconds).modules.enumerated().map { index, stats in
            ModuleDetail(number: index + 1, module: label(index), verb: modules[index].verb, name: modules[index].name, counts: stats)
        }
    }

    /// What each link has carried `seconds` after the pipeline started, keyed as the graph's links are.
    public func linkCounts(at seconds: Double) -> [LinkDetail] {
        flow(at: seconds).links
    }

    /// Works out every module's and link's counts as Meep2 keeps them: what a module passes on or emits goes along
    /// each of its links, and so do its errors and those passing by it, but a module with `@errors` takes only errors.
    private func flow(at seconds: Double) -> (modules: [ModuleStats], links: [LinkDetail]) {
        var messagesOut = [Double](repeating: 0, count: modules.count)
        var errorsOut = [Double](repeating: 0, count: modules.count)
        var stats: [ModuleStats] = []
        var links: [LinkDetail] = []
        for (index, module) in modules.enumerated() {
            var counts = ModuleStats()
            // A wobbling rate whose total since the start only rises: the integral of rate × (1 + 0.3 sin(t/7 + phase)).
            let phase = Double(index) * 1.7
            if module.from.isEmpty {
                let total = max(0, module.rate * (seconds - 0.3 * 7 * (cos(seconds / 7 + phase) - cos(phase))))
                messagesOut[index] = total
                counts.emitted = Int64(total)
            } else {
                for from in module.from {
                    let errors = errorsOut[from]
                    let carried = module.errorsOnly ? errors : messagesOut[from] + errors
                    links.append(LinkDetail(key: "m\(from + 1)>m\(index + 1)", carried: Int64(carried), errors: Int64(errors)))
                }
                let reaching = module.from.reduce(0) { $0 + (module.errorsOnly ? errorsOut[$1] : messagesOut[$1]) }
                let passingBy = module.errorsOnly ? 0 : module.from.reduce(0) { $0 + errorsOut[$1] }
                let dropped = reaching * module.drops
                let queued = min(reaching - dropped, max(0, module.queue * (1 + sin(seconds / 3 + phase))))
                let handled = max(0, reaching - dropped - queued)
                let failed = handled * module.fails
                let succeeded = handled - failed
                counts.received = Int64(reaching - dropped)
                counts.handled = Int64(handled)
                counts.dropped = Int64(dropped)
                counts.failed = Int64(failed)
                counts.queued = Int64(queued.rounded())
                switch module.role {
                case .filter:
                    counts.passed = Int64(succeeded * module.passes)
                    counts.emitted = Int64(failed)
                    messagesOut[index] = succeeded * module.passes
                case .step:
                    counts.emitted = Int64(succeeded * module.passes + failed)
                    messagesOut[index] = succeeded * module.passes
                default:
                    counts.passed = Int64(succeeded)
                    counts.emitted = Int64(failed)
                    messagesOut[index] = succeeded
                }
                errorsOut[index] = failed + passingBy
            }
            stats.append(counts)
        }
        return (stats, links)
    }

    /// Four pipelines of different shapes and speeds.
    public static let demo: [PipelineSpec] = [
        PipelineSpec(name: "orders", modules: [
            ModuleSpec("Listen", .inlet, name: "Orders", rate: 140),
            ModuleSpec("Where", .filter, name: "Valid", from: [0], passes: 0.92, fails: 0.002, queue: 1),
            ModuleSpec("Fetch", .step, name: "Prices", from: [1], fails: 0.01, queue: 6),
            ModuleSpec("Save", .outlet, from: [2], queue: 2),
            ModuleSpec("Send", .outlet, name: "Reply", from: [2]),
            ModuleSpec("WriteLine", .outlet, name: "Problems", from: [2], errorsOnly: true),
        ]),
        PipelineSpec(name: "ticker", modules: [
            ModuleSpec("Interval", .source, name: "Ticks", rate: 2),
            ModuleSpec("WriteLine", .outlet, from: [0]),
        ]),
        PipelineSpec(name: "sensors", modules: [
            ModuleSpec("Listen", .inlet, name: "Readings", rate: 2400),
            ModuleSpec("Listen", .inlet, name: "Backfill", rate: 300),
            ModuleSpec("Batch", .step, from: [0, 1], passes: 0.01, queue: 40),
            ModuleSpec("Classify", .step, from: [2], fails: 0.03, queue: 3),
            ModuleSpec("Send", .outlet, name: "Alerts", from: [3], drops: 0.05),
            ModuleSpec("Save", .outlet, name: "Rejects", from: [3], errorsOnly: true),
        ]),
        PipelineSpec(name: "warehouse", modules: [
            ModuleSpec("Read", .source, name: "Files", rate: 50),
            ModuleSpec("Listen", .inlet, name: "Uploads", rate: 30),
            ModuleSpec("Parse", .step, from: [0, 1], fails: 0.02, queue: 2),
            ModuleSpec("Where", .filter, name: "Fresh", from: [2], passes: 0.7),
            ModuleSpec("Fetch", .step, name: "Enrich", from: [3], fails: 0.01, queue: 12),
            ModuleSpec("Where", .filter, name: "Large", from: [4], passes: 0.1),
            ModuleSpec("Send", .outlet, name: "Archive", from: [4]),
            ModuleSpec("Save", .outlet, name: "Warehouse", from: [4], queue: 4),
            ModuleSpec("Send", .outlet, name: "Alerts", from: [5]),
            ModuleSpec("WriteLine", .outlet, name: "Rejects", from: [2], errorsOnly: true),
            ModuleSpec("WriteLine", .outlet, name: "Problems", from: [4], errorsOnly: true),
        ]),
    ]
}
