import Foundation
import MeepClient

/// A pretend Meep host: pipelines with believable, steadily changing counts, served through the same ``HostLink``
/// as a real daemon, with whatever latency you choose.
///
/// It's for tests, and for building the host and mesh levels without fifty real machines. Its counts are worked
/// out from the time since it started, so they only go up, wobble like real traffic, and cost nothing to keep.
public actor SimulatedHost: HostLink {
    public nonisolated let name: String
    /// Its lasting ID, as a daemon keeps one, made from its name so it's the same each time.
    public nonisolated let id: String
    /// How long each answer takes.
    public var latency: Duration
    /// How far its clock is ahead of this Mac's, as another machine's may be.
    public let clockSkew: Duration
    /// How many processor cores it says it has.
    public let cores: Int
    private(set) var pipelineSpecs: [PipelineSpec]
    private let clock = ContinuousClock()
    private let epoch: ContinuousClock.Instant
    private let started: Date
    private var closed = false
    /// What a client may do: observe only, unless made with more, as a test of injecting.
    public let capabilities: [String]
    /// Messages sent in, by pipeline and module label, for taps on that module to show.
    private var injected: [String: [TappedMessage]] = [:]
    private var injections = 0

    public init(
        name: String = "simulated", latency: Duration = .milliseconds(20), pipelines: [PipelineSpec] = PipelineSpec.demo,
        capabilities: [String] = ["observe"], clockSkew: Duration = .zero, cores: Int = 8
    ) {
        self.name = name
        id = Self.id(for: name)
        self.latency = latency
        pipelineSpecs = pipelines
        self.capabilities = capabilities
        self.clockSkew = clockSkew
        self.cores = cores
        epoch = clock.now
        started = Date()
    }

    /// A UUID made from a name, so a simulated host keeps its ID from one run to the next.
    public static func id(for name: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let low = hash &* 0x9E3779B97F4A7C15
        let hex = String(format: "%016llx%016llx", hash, low)
        let chars = Array(hex)
        return "\(String(chars[0..<8]))-\(String(chars[8..<12]))-4\(String(chars[13..<16]))-8\(String(chars[17..<20]))-\(String(chars[20..<32]))"
    }

    var elapsed: Double {
        let duration = clock.now - epoch
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Its clock, in microseconds since 1970, skewed as it was made.
    var clockNow: Int64 {
        let skew = Double(clockSkew.components.seconds) + Double(clockSkew.components.attoseconds) / 1e18
        return Int64(((Date().timeIntervalSince1970 + skew) * 1_000_000).rounded())
    }

    var identity: HostIdentity {
        HostIdentity(id: id, names: [name, "\(name).simulated"], addresses: ["10.0.0.\((Int(id.prefix(2), radix: 16) ?? 0) % 200 + 20)"], version: "simulated", pid: 0)
    }

    func answer() async throws {
        if closed { throw HostError.disconnected("The simulated host was closed.") }
        try await Task.sleep(for: latency)
    }

    public func info() async throws -> DaemonInfo {
        try await answer()
        let identity = identity
        return DaemonInfo(
            version: "simulated", processId: 0, socket: "simulated://\(name)", capabilities: capabilities, pipelines: pipelineSpecs.map(\.name),
            id: id, names: identity.names, addresses: identity.addresses, listening: listening, sending: sending, clock: clockNow
        )
    }

    /// Where its Listens are bound: as each says, or a made-up address.
    var listening: [ListenAddress] {
        pipelineSpecs.flatMap { spec in
            spec.modules.indices.filter { spec.modules[$0].verb == "Listen" }.map { index in
                ListenAddress(pipeline: spec.name, module: "m\(index + 1)", label: spec.label(index), address: spec.listenAddress(index))
            }
        }
    }

    /// Where its Fetches and Sends with addresses send, as Meep2 declares them.
    var sending: [SendAddress] {
        pipelineSpecs.flatMap { spec in
            spec.modules.indices.compactMap { index -> SendAddress? in
                let module = spec.modules[index]
                guard module.verb == "Fetch" || module.verb == "Send", let address = module.address else { return nil }
                let computed = address.contains("{")
                return SendAddress(
                    pipeline: spec.name, module: "m\(index + 1)", label: spec.label(index), address: computed ? "\"\(address)\"" : address,
                    computed: computed, endpoint: PipelineSpec.endpoint(of: address)
                )
            }
        }
    }

    /// Places folded into `*`, by pipeline and module key, as a Listen or Fetch makes room for a new one.
    private(set) var folded: [String: [String: Set<String>]] = [:]

    /// Folds a module's place into `*` (or `meep://*`), as Meep2 does when a new place needs its room: from now on its
    /// counts are `*`'s, and the next update names it in `folded`.
    public func fold(_ place: String, of module: String, in pipeline: String) {
        folded[pipeline, default: [:]][module, default: []].insert(place)
    }

    var summaries: [PipelineSummary] {
        pipelineSpecs.map {
            PipelineSummary(name: $0.name, path: $0.path, state: .running, started: started, watching: $0.watching, graphVersion: $0.version)
        }
    }

    public func pipelines() async throws -> [PipelineSummary] {
        try await answer()
        return summaries
    }

    public func pipeline(_ name: String) async throws -> PipelineDetail {
        try await answer()
        return try detail(of: spec(name))
    }

    public func graph(_ name: String) async throws -> PipelineGraph {
        try await answer()
        return try spec(name).graph
    }

    /// Replaces a pipeline with `spec`, as a reload would, giving its graph the next version.
    public func reload(_ name: String, as spec: PipelineSpec) {
        guard let index = pipelineSpecs.firstIndex(where: { $0.name == name }) else { return }
        var changed = spec
        changed.version = pipelineSpecs[index].version + 1
        pipelineSpecs[index] = changed
    }

    public func source(_ name: String) async throws -> SourceText {
        try await answer()
        let spec = try spec(name)
        guard let text = spec.text else {
            throw HostError.refused(status: 404, message: "\(name) is simulated, so it has no Meeplang.", details: [])
        }
        return SourceText(path: spec.path, text: text)
    }

    public func reload(_ name: String) async throws {
        try await answer()
        _ = try spec(name)
        throw HostError.refused(status: 403, message: "A simulated host only lets you observe.", details: [])
    }

    /// Made-up messages from a module, at its rate up to 20 a second, as a tap shows them, with any sent into it. It
    /// can't work out Meeplang conditions, so it refuses one.
    public nonisolated func tap(_ name: String, module: String, where condition: String?, sample: Double?) -> AsyncThrowingStream<TapEvent, any Error> {
        AsyncThrowingStream { continuation in
            let tapping = Task {
                do {
                    try await self.answer()
                    if let condition, !condition.isEmpty {
                        throw HostError.refused(status: 400, message: "A simulated host can't work out conditions such as \(condition).", details: [])
                    }
                    let (spec, index) = try await self.findModule(module, of: name)
                    let share = min(max(sample ?? 1, 0.001), 1)
                    var count = 0
                    var shown = 0.0
                    while !Task.isCancelled {
                        for message in await self.takeInjected(name, label: spec.label(index)) {
                            continuation.yield(TapEvent(dropped: 0, message: message))
                        }
                        let rate = await self.outputRate(of: index, in: spec)
                        count += 1
                        shown += share
                        if rate > 0, shown >= 1 {
                            shown -= 1
                            let source = spec.modules[index].role == .source || spec.modules[index].role == .inlet
                            continuation.yield(TapEvent(dropped: 0, message: TappedMessage(
                                type: source ? "Tick" : "Message", id: UUID().uuidString.lowercased(), created: Date(),
                                emittedBy: source ? spec.label(index) : spec.modules[index].from.first.map { spec.label($0) },
                                content: ["Count": .number(Double(count))]
                            )))
                        }
                        let every = rate > 0 ? 1 / min(rate, 20) : 0.25
                        try await Task.sleep(for: .milliseconds(Int(every * 1000)))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in tapping.cancel() }
        }
    }

    /// Takes a message into a module, for taps on it to show, if this host lets clients inject.
    public func inject(_ name: String, module: String, _ body: InjectBody) async throws -> Injected {
        try await answer()
        let (spec, index) = try findModule(module, of: name)
        guard capabilities.contains("inject") else {
            throw HostError.refused(status: 403, message: "That needs the inject capability, and you have observe.", details: [])
        }
        injections += 1
        let id = UUID().uuidString.lowercased()
        let content: JSONValue
        let type: String
        switch body {
        case .text(let text):
            type = "TextMessage"
            content = ["Text": .string(text)]
        case .json(let json):
            type = "JsonMessage"
            content = json
        }
        let label = spec.label(index)
        injected["\(name)/\(label)", default: []].append(TappedMessage(type: type, id: id, created: Date(), emittedBy: "Injector", content: content))
        return Injected(id: id, type: type, module: label)
    }

    private func takeInjected(_ name: String, label: String) -> [TappedMessage] {
        injected.removeValue(forKey: "\(name)/\(label)") ?? []
    }

    /// A module by its number, its name or its label, as the daemon finds them.
    private func findModule(_ id: String, of name: String) throws -> (PipelineSpec, Int) {
        let spec = try spec(name)
        let index = Int(id).map { $0 - 1 }
            ?? spec.modules.indices.first { spec.modules[$0].name == id || spec.label($0) == id }
        guard let index, spec.modules.indices.contains(index) else {
            throw HostError.refused(status: 404, message: "\(name) has no module called \(id).", details: [])
        }
        return (spec, index)
    }

    /// Messages a second a module emits or passes on now.
    private func outputRate(of index: Int, in spec: PipelineSpec) -> Double {
        let now = elapsed
        guard now > 1 else { return spec.modules[index].rate }
        let after = spec.counts(at: now)[index].counts
        let before = spec.counts(at: now - 1)[index].counts
        return Double(after.emitted + after.passed - before.emitted - before.passed)
    }

    public nonisolated func stats(_ name: String, every interval: Duration) -> AsyncThrowingStream<StatsEvent, any Error> {
        AsyncThrowingStream { continuation in
            let ticking = Task {
                do {
                    var version: Int?
                    while !Task.isCancelled {
                        let detail = try await self.pipeline(name)
                        // A reload is announced, as the daemon announces it, before the counts that follow it.
                        if let graphVersion = detail.graphVersion, version != nil, graphVersion != version {
                            continuation.yield(.graph(GraphNotice(version: graphVersion, reason: "reload")))
                        }
                        version = detail.graphVersion
                        continuation.yield(.stats(detail))
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
        for subscription in subscriptions { subscription.finish() }
        subscriptions.removeAll()
    }

    // MARK: Subscriptions

    private var subscriptions: [SimulatedSubscription] = []
    /// Updates to skip, as a lost frame would, for testing what a client does about a gap.
    var updatesToLose = 0

    public func subscribe(_ plan: SubscriptionPlan) async throws -> any HostSubscription {
        try await answer()
        let subscription = SimulatedSubscription(host: self, plan: plan)
        subscriptions.append(subscription)
        return subscription
    }

    /// Skips the next update's sequence number, as if it had been lost on the way.
    public func loseNextUpdate() {
        updatesToLose += 1
    }

    /// Bytes a second its subscriptions have sent over the last few seconds, for tests of budgets.
    public var subscriptionsSent: Int64 {
        subscriptions.reduce(0) { $0 + $1.sentBytes }
    }

    func takeLostUpdate() -> Bool {
        guard updatesToLose > 0 else { return false }
        updatesToLose -= 1
        return true
    }

    /// Every pipeline's module counts, link counts, bytes and handling times now.
    func reading() -> SimulatedReading {
        let now = elapsed
        var pipelines: [String: SimulatedReading.Pipeline] = [:]
        for spec in pipelineSpecs {
            // One pass works out every module's and link's counts; places are worked out only when they're asked for.
            let (counts, links) = spec.flow(at: now)
            pipelines[spec.name] = SimulatedReading.Pipeline(
                spec: spec, modules: counts, links: links,
                busy: counts.indices.map { Int64((Double(counts[$0].handled) * spec.modules[$0].handlingTime * 1_000_000).rounded()) },
                folded: folded[spec.name] ?? [:]
            )
        }
        return SimulatedReading(
            clock: clockNow, elapsed: now, pipelines: pipelines, summaries: summaries, listening: listening, sending: sending, cores: cores,
            folded: folded
        )
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
            modules: spec.counts(at: elapsed), graphVersion: spec.graph.version, links: spec.linkCounts(at: elapsed),
            watching: spec.watching
        )
    }
}

/// Where some of what a simulated Listen receives comes from.
public struct SimulatedClient: Sendable {
    /// As Meep2 keys it: a client's address, `meep://<daemon ID>/<pipeline>/<key>` from another Meep host, or `*`.
    public var place: String
    /// Its reverse-DNS name, for a client's address.
    public var name: String?
    /// The share of the Listen's messages that come from it.
    public var share: Double
    /// The shares of its requests answered with 5xx, and turned away with 4xx.
    public var fails: Double
    public var rejects: Double

    public init(_ place: String, name: String? = nil, share: Double, fails: Double = 0, rejects: Double = 0) {
        self.place = place
        self.name = name
        self.share = share
        self.fails = fails
        self.rejects = rejects
    }

    /// From a module on another Meep host.
    public static func meep(_ daemon: String, _ pipeline: String, _ module: String, share: Double) -> SimulatedClient {
        SimulatedClient("meep://\(daemon)/\(pipeline)/\(module)", share: share)
    }
}

/// A simulated pipeline: its graph, and how fast messages flow through each module.
public struct PipelineSpec: Sendable {
    public var name: String
    public var path: String
    public var modules: [ModuleSpec]
    /// The Meeplang it runs, if it has any; the demo pipelines don't, since their verbs are made up.
    public var text: String?
    /// Its graph's version, which counts up with each reload.
    public var version = 1
    /// Whether the daemon says it's watching the file; nil, as a daemon from before Meep2 0278da4 says nothing.
    public var watching: Bool?

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
        /// How long it takes to handle a message, on average, in seconds.
        public var handlingTime: Double
        /// For a Listen, where it's bound; for a Fetch or Send, where it sends, with `{…}` for what's worked out for
        /// each message.
        public var address: String?
        /// For a Listen, where what it receives comes from, each with its share.
        public var clients: [SimulatedClient]
        /// For a Fetch or Send whose far end is a Meep host, that daemon's ID.
        public var peer: String?
        /// For a Fetch or Send, the share of what it sends that's turned away (4xx).
        public var rejects: Double

        public init(
            _ verb: String, _ role: VerbRole, name: String? = nil, from: [Int] = [], rate: Double = 0, passes: Double = 1,
            fails: Double = 0, drops: Double = 0, queue: Double = 0, errorsOnly: Bool = false, handlingTime: Double? = nil,
            address: String? = nil, clients: [SimulatedClient] = [], peer: String? = nil, rejects: Double = 0
        ) {
            self.address = address
            self.clients = clients
            self.peer = peer
            self.rejects = rejects
            self.handlingTime = from.isEmpty ? 0 : handlingTime ?? (verb == "Fetch" ? 0.004 : verb == "Send" || verb == "Save" ? 0.0012
                : role == .filter ? 0.00003 : role == .outlet ? 0.0002 : 0.0005)
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

    public init(name: String, modules: [ModuleSpec], path: String? = nil, text: String? = nil) {
        self.name = name
        self.path = path ?? "/simulated/\(name).meep"
        self.modules = modules
        self.text = text
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
        return PipelineGraph(name: name, path: path, version: version, modules: graphModules, links: links)
    }

    func label(_ index: Int) -> String {
        modules[index].name ?? "\(modules[index].verb) #\(index + 1)"
    }

    /// Where a Listen is bound: as its spec says, or a made-up address.
    func listenAddress(_ index: Int) -> String {
        modules[index].address ?? "http://0.0.0.0:\(8000 + index)/\(name)/"
    }

    /// An address's endpoint, as Meep2 keys destinations: `host:port`, in lower case, with 80 or 443 for a web address
    /// that gives none; nil when the host or port is worked out for each message.
    static func endpoint(of address: String) -> String? {
        let literal = address.split(separator: "{", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? address
        guard let schemeEnd = literal.range(of: "://") else { return nil }
        let scheme = literal[..<schemeEnd.lowerBound].lowercased()
        let rest = literal[schemeEnd.upperBound...]
        guard let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? (address.contains("{") ? nil : rest.endIndex) else { return nil }
        let authority = rest[..<end].lowercased()
        if authority.contains(":") { return authority }
        let port = scheme == "https" || scheme == "wss" ? 443 : scheme == "tcp" ? nil : 80
        return port.map { "\(authority):\($0)" }
    }

    /// Each Listen's counts by where they came from, and each Fetch's and Send's by where it connected, `seconds`
    /// after it started, as Meep2 counts them: `[received, sent, bytesReceived, bytesSent, failed, rejected]`. Places
    /// in `folded` count under `*` (or `meep://*`).
    func places(at seconds: Double, modules counts: [ModuleStats], folded: [String: Set<String>] = [:]) -> [String: [String: [Int64]]] {
        var result: [String: [String: [Int64]]] = [:]
        for (index, module) in modules.enumerated() {
            let key = "m\(index + 1)"
            var places: [String: [Int64]] = [:]
            func add(_ place: String, _ values: [Int64]) {
                let folds = folded[key]?.contains(place) == true
                let into = folds ? (place.hasPrefix("meep://") ? "meep://*" : "*") : place
                places[into] = zip(places[into] ?? [0, 0, 0, 0, 0, 0], values).map { $0 + $1 }
            }
            if module.verb == "Listen" {
                let total = Double(counts[index].emitted)
                for client in module.clients {
                    let received = total * client.share
                    let rejected = received * client.rejects
                    let failed = received * client.fails
                    let values = [Int64(received), Int64(received), Int64(received * 220), Int64(received * 40), Int64(failed), Int64(rejected)]
                    guard values[0] > 0 else { continue }
                    add(client.place, values)
                }
            } else if module.verb == "Fetch" || module.verb == "Send", let address = module.address, let endpoint = Self.endpoint(of: address) {
                let sent = Double(counts[index].handled)
                guard sent > 0 else { continue }
                let failed = Double(counts[index].failed)
                let rejected = sent * module.rejects
                let answered = max(0, sent - failed)
                let fetches = module.verb == "Fetch"
                add(endpoint, [Int64(answered), Int64(sent), Int64(sent * (fetches ? 820 : 24)), Int64(sent * (fetches ? 0 : 310)), Int64(failed), Int64(rejected)])
            }
            if !places.isEmpty { result[key] = places }
        }
        return result
    }

    /// Names for the clients' addresses its Listens hear from, as reverse DNS gives them.
    var clientNames: [String: String] {
        var names: [String: String] = [:]
        for module in modules { for client in module.clients { if let name = client.name { names[client.place] = name } } }
        return names
    }

    /// Which endpoints its Fetches and Sends reach are Meep hosts.
    var peers: [String: String] {
        var peers: [String: String] = [:]
        for module in modules {
            if let peer = module.peer, let address = module.address, let endpoint = Self.endpoint(of: address) { peers[endpoint] = peer }
        }
        return peers
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
    func flow(at seconds: Double) -> (modules: [ModuleStats], links: [LinkDetail]) {
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

    /// Four pipelines of different shapes and speeds, for a host called `simulated`, with flows between them and
    /// endpoints outside Meep: clients of its Listens, APIs its Fetches and Sends reach, another Meep it doesn't know,
    /// and clients past a Listen's limit.
    public static let demo: [PipelineSpec] = {
        let me = SimulatedHost.id(for: "simulated")
        let stranger = "7c3e9a1b-5d2f-4e8a-9b6c-0d1e2f3a4b5c"
        return [
            PipelineSpec(name: "orders", modules: [
                ModuleSpec("Listen", .inlet, name: "Orders", rate: 140, address: "http://0.0.0.0:8443/orders/", clients: [
                    SimulatedClient("203.0.113.7", name: "shop-web-1.example.com", share: 0.45),
                    SimulatedClient("203.0.113.8", name: "shop-web-2.example.com", share: 0.4, fails: 0.002),
                    SimulatedClient("198.51.100.23", share: 0.1, rejects: 0.3),
                    .meep(me, "warehouse", "m7", share: 0.05),
                ]),
                ModuleSpec("Where", .filter, name: "Valid", from: [0], passes: 0.92, fails: 0.002, queue: 1),
                ModuleSpec("Fetch", .step, name: "Prices", from: [1], fails: 0.01, queue: 6, address: "https://prices.example.com/v2/{msg.Sku}", rejects: 0.004),
                ModuleSpec("Save", .outlet, from: [2], queue: 2),
                ModuleSpec("Send", .outlet, name: "Reply", from: [2]),
                ModuleSpec("WriteLine", .outlet, name: "Problems", from: [2], errorsOnly: true),
            ]),
            PipelineSpec(name: "ticker", modules: [
                ModuleSpec("Interval", .source, name: "Ticks", rate: 2),
                ModuleSpec("WriteLine", .outlet, from: [0]),
                // Declared, but nothing reaches it yet: a flow drawn dashed.
                ModuleSpec("Send", .outlet, name: "Heartbeat", from: [0], drops: 1, address: "http://simulated.simulated:8001/readings/", peer: me),
            ]),
            PipelineSpec(name: "sensors", modules: [
                ModuleSpec("Listen", .inlet, name: "Readings", rate: 2400, address: "http://0.0.0.0:8001/readings/", clients:
                    (1...9).map { SimulatedClient("10.1.0.\($0)", name: "sensor-\($0).plant.example.net", share: 0.09) }
                    + [SimulatedClient("*", share: 0.19)]),
                ModuleSpec("Listen", .inlet, name: "Backfill", rate: 300, address: "http://0.0.0.0:8001/backfill/", clients: [
                    .meep(stranger, "collector", "m2", share: 1),
                ]),
                ModuleSpec("Batch", .step, from: [0, 1], passes: 0.01, queue: 40, handlingTime: 0.00025),
                ModuleSpec("Classify", .step, from: [2], fails: 0.03, queue: 3),
                ModuleSpec("Send", .outlet, name: "Alerts", from: [3], drops: 0.05, address: "https://alerts.example.com/hooks/sensors"),
                ModuleSpec("Save", .outlet, name: "Rejects", from: [3], errorsOnly: true),
            ]),
            PipelineSpec(name: "warehouse", modules: [
                ModuleSpec("Read", .source, name: "Files", rate: 50),
                ModuleSpec("Listen", .inlet, name: "Uploads", rate: 30, address: "http://0.0.0.0:8002/uploads/", clients: [
                    SimulatedClient("192.0.2.44", name: "uploads.partner.example.org", share: 0.7),
                    SimulatedClient("192.0.2.45", name: "uploads.partner.example.org", share: 0.3, rejects: 0.05),
                ]),
                ModuleSpec("Parse", .step, from: [0, 1], fails: 0.02, queue: 2),
                ModuleSpec("Where", .filter, name: "Fresh", from: [2], passes: 0.7),
                ModuleSpec("Fetch", .step, name: "Enrich", from: [3], fails: 0.01, queue: 12, address: "https://enrich.example.org/lookup?id={msg.Id}"),
                ModuleSpec("Where", .filter, name: "Large", from: [4], passes: 0.1),
                ModuleSpec("Send", .outlet, name: "Archive", from: [4], address: "http://simulated.simulated:8443/orders/", peer: me),
                ModuleSpec("Save", .outlet, name: "Warehouse", from: [4], queue: 4),
                ModuleSpec("Send", .outlet, name: "Alerts", from: [5], address: "https://hooks.example.com/alerts"),
                ModuleSpec("WriteLine", .outlet, name: "Rejects", from: [2], errorsOnly: true),
                ModuleSpec("WriteLine", .outlet, name: "Problems", from: [4], errorsOnly: true),
            ]),
        ]
    }()
}
