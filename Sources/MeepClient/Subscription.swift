import Foundation

// One subscription per connection (Meep2 0c83a49, `POST /subscribe` over `/ws`): a plan of what to send and how often,
// changed in place as the camera moves, answered with `hello` and then `update`s carrying only what changed.

/// What a subscription asks a daemon for, and how often. Nothing is sent for what isn't in it.
public struct SubscriptionPlan: Sendable, Equatable {
    /// JSON or CBOR, fixed when the subscription starts.
    public var encoding: SubscriptionEncoding
    /// The pipelines and their states.
    public var list: Duration?
    /// The host's totals, how many pipelines are in each state, and where its Listens are bound.
    public var host: Duration?
    /// The daemon's CPU, memory and garbage collection, and the machine's load and memory.
    public var runtime: Duration?
    /// An update goes at least this often, even with nothing in it; 5 s unless given.
    public var heartbeat: Duration?
    /// Bytes a second the daemon keeps under, by holding updates back; a backstop for the planner's rates.
    public var budget: Int?
    /// By pipeline name, or `"*"` for every pipeline not named. A named pipeline's entry replaces `"*"`'s for it.
    public var pipelines: [String: PipelinePlan]

    public init(
        encoding: SubscriptionEncoding = .json, list: Duration? = nil, host: Duration? = nil, runtime: Duration? = nil,
        heartbeat: Duration? = nil, budget: Int? = nil, pipelines: [String: PipelinePlan] = [:]
    ) {
        self.encoding = encoding
        self.list = list
        self.host = host
        self.runtime = runtime
        self.heartbeat = heartbeat
        self.budget = budget
        self.pipelines = pipelines
    }

    /// The plan as the daemon reads it.
    public var json: JSONValue {
        var object: [String: JSONValue] = ["encoding": .string(encoding.rawValue)]
        if let list { object["list"] = .string(list.meepText) }
        if let host { object["host"] = .string(host.meepText) }
        if let runtime { object["runtime"] = .string(runtime.meepText) }
        if let heartbeat { object["heartbeat"] = .string(heartbeat.meepText) }
        if let budget { object["budget"] = .number(budget) }
        object["pipelines"] = .object(pipelines.mapValues(\.json))
        return .object(object)
    }

    /// What to send the daemon to change `old` into this: a JSON merge patch (RFC 7396), or nil if nothing changed.
    public func patch(from old: SubscriptionPlan) -> JSONValue? {
        JSONValue.mergePatch(from: old.json, to: json)
    }
}

public enum SubscriptionEncoding: String, Sendable, Equatable {
    case json, cbor
}

/// What to send for one pipeline: its totals, and each module's and link's counts, histograms and bytes, and its
/// Listens' arrivals and its Fetches' and Sends' destinations, by key or `"*"` for the rest.
public struct PipelinePlan: Sendable, Equatable {
    public var totals: Duration?
    public var modules: [String: Duration]
    public var links: [String: Duration]
    public var timing: [String: Duration]
    public var bytes: [String: Duration]
    /// What each Listen receives, by where it comes from (Meep2 a5de139).
    public var arrivals: [String: Duration]
    /// What each Fetch and Send sends, by where it connected, with which of those are Meep hosts (Meep2 a5de139).
    public var destinations: [String: Duration]

    public init(
        totals: Duration? = nil, modules: [String: Duration] = [:], links: [String: Duration] = [:],
        timing: [String: Duration] = [:], bytes: [String: Duration] = [:], arrivals: [String: Duration] = [:],
        destinations: [String: Duration] = [:]
    ) {
        self.totals = totals
        self.modules = modules
        self.links = links
        self.timing = timing
        self.bytes = bytes
        self.arrivals = arrivals
        self.destinations = destinations
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = [:]
        if let totals { object["totals"] = .string(totals.meepText) }
        func rates(_ map: [String: Duration]) -> JSONValue { .object(map.mapValues { .string($0.meepText) }) }
        if !modules.isEmpty { object["modules"] = rates(modules) }
        if !links.isEmpty { object["links"] = rates(links) }
        if !timing.isEmpty { object["timing"] = rates(timing) }
        if !bytes.isEmpty { object["bytes"] = rates(bytes) }
        if !arrivals.isEmpty { object["arrivals"] = rates(arrivals) }
        if !destinations.isEmpty { object["destinations"] = rates(destinations) }
        return .object(object)
    }
}

extension JSONValue {
    /// The merge patch (RFC 7396) that turns `old` into `new`: objects are compared key by key, a key that's gone is
    /// null, and anything else that differs is replaced whole. Nil when they're the same.
    public static func mergePatch(from old: JSONValue, to new: JSONValue) -> JSONValue? {
        guard old != new else { return nil }
        guard case .object(let before) = old, case .object(let after) = new else { return new }
        var patch: [String: JSONValue] = [:]
        for key in before.keys where after[key] == nil { patch[key] = .null }
        for (key, value) in after {
            if let previous = before[key] {
                if let change = mergePatch(from: previous, to: value) { patch[key] = change }
            } else {
                patch[key] = value
            }
        }
        return patch.isEmpty ? nil : .object(patch)
    }
}

// MARK: What it sends

/// One event from a subscription.
public enum SubscriptionEvent: Sendable, Equatable {
    /// First: who the host is, its clock, and the order its counts come in.
    case hello(SubscriptionHello)
    /// What changed since the last update.
    case update(SubscriptionUpdate)
    /// A change was taken; the plan as it now stands.
    case plan(JSONValue)
    /// A change was refused, and why; the plan is as it was.
    case problem(String)
}

/// Who the host is and how to read its updates.
public struct SubscriptionHello: Decodable, Sendable, Equatable {
    public var host: HostIdentity
    /// The daemon's clock, in microseconds since 1970 (UTC).
    public var clock: Int64
    public var counts: CountOrder
    public var timing: TimingScale?
    public var plan: JSONValue?

    public init(host: HostIdentity, clock: Int64, counts: CountOrder = .standard, timing: TimingScale? = TimingScale(scale: 3, unit: "s"), plan: JSONValue? = nil) {
        self.host = host
        self.clock = clock
        self.counts = counts
        self.timing = timing
        self.plan = plan
    }
}

/// A daemon's lasting identity: its ID, made once, and where it is.
public struct HostIdentity: Codable, Sendable, Equatable {
    public var id: String
    public var names: [String]
    public var addresses: [String]
    public var version: String
    public var pid: Int

    public init(id: String, names: [String] = [], addresses: [String] = [], version: String, pid: Int = 0) {
        self.id = id
        self.names = names
        self.addresses = addresses
        self.version = version
        self.pid = pid
    }
}

/// The order of the counts in each array an update carries.
public struct CountOrder: Codable, Sendable, Equatable {
    public var modules: [String]
    public var links: [String]
    public var bytes: [String]
    public var totals: [String]
    /// A Listen's counts for each place messages arrive from; nil from daemons before Meep2 a5de139.
    public var arrivals: [String]?
    /// A Fetch's or Send's counts for each place it sends to; nil from daemons before Meep2 a5de139.
    public var destinations: [String]?

    /// The order of a place's counts in Meep2 a5de139, for arrivals and destinations alike.
    public static let places = ["received", "sent", "bytesReceived", "bytesSent", "failed", "rejected"]

    public static let standard = CountOrder(
        modules: ["received", "handled", "emitted", "passed", "busy", "queued", "dropped", "filtered", "failed", "restarts", "expired", "refused"],
        links: ["carried", "errors"], bytes: ["received", "sent"],
        totals: ["received", "handled", "emitted", "passed", "busy", "queued", "dropped", "filtered", "failed", "restarts", "expired", "refused", "sourced", "bytesReceived", "bytesSent"],
        arrivals: places, destinations: places
    )

    public init(modules: [String], links: [String], bytes: [String], totals: [String], arrivals: [String]? = nil, destinations: [String]? = nil) {
        self.modules = modules
        self.links = links
        self.bytes = bytes
        self.totals = totals
        self.arrivals = arrivals
        self.destinations = destinations
    }
}

/// How handling-time histograms are bucketed: OpenTelemetry's exponential form at a fixed scale, in seconds.
public struct TimingScale: Codable, Sendable, Equatable {
    public var scale: Int
    public var unit: String

    public init(scale: Int, unit: String) {
        self.scale = scale
        self.unit = unit
    }
}

/// What changed since the last update. In every map, a key whose value is null has gone; in a counts array, null is a
/// count that hasn't changed, and counts after the last that changed are left off.
public struct SubscriptionUpdate: Codable, Sendable, Equatable {
    /// Counts from 1, up by one each update; a gap means one was missed.
    public var seq: Int
    /// The daemon's clock as the update was made, in microseconds since 1970 (UTC).
    public var clock: Int64
    /// What the subscription had sent before this update, its own frames included.
    public var bytes: Int64
    /// How long the daemon's budget held this update past when it was due, in microseconds, when it did.
    public var held: Int64?
    public var list: [String: PipelineSummary?]?
    public var host: HostUpdate?
    /// Each runtime metric by its OpenTelemetry name: a number, or numbers by the values of its attributes.
    public var runtime: [String: JSONValue]?
    public var pipelines: [String: PipelineUpdate?]?
    /// When it arrived, on this Mac's clock, taken where it was read rather than when it's applied, for estimating the
    /// host's clock offset. Not part of what the daemon sends.
    public var received: Date?

    enum CodingKeys: String, CodingKey {
        case seq, clock, bytes, held, list, host, runtime, pipelines
    }

    public init(
        seq: Int, clock: Int64, bytes: Int64, held: Int64? = nil, list: [String: PipelineSummary?]? = nil, host: HostUpdate? = nil,
        runtime: [String: JSONValue]? = nil, pipelines: [String: PipelineUpdate?]? = nil
    ) {
        self.seq = seq
        self.clock = clock
        self.bytes = bytes
        self.held = held
        self.list = list
        self.host = host
        self.runtime = runtime
        self.pipelines = pipelines
    }
}

/// The host's totals, its pipelines' states, where its Listens are bound and where its Fetches and Sends send: only
/// what changed.
public struct HostUpdate: Codable, Sendable, Equatable {
    public var totals: [String: Int64?]?
    /// How many pipelines are in each state.
    public var states: [String: Int?]?
    public var listens: [ListenAddress]?
    /// Where its Fetches and Sends send, whole when it changes (Meep2 a5de139).
    public var sends: [SendAddress]?

    public init(totals: [String: Int64?]? = nil, states: [String: Int?]? = nil, listens: [ListenAddress]? = nil, sends: [SendAddress]? = nil) {
        self.totals = totals
        self.states = states
        self.listens = listens
        self.sends = sends
    }
}

/// One pipeline's part of an update: only what changed.
public struct PipelineUpdate: Codable, Sendable, Equatable {
    /// Its graph's version, with its first update and whenever it changes.
    public var graph: GraphStamp?
    /// Each count added up over its modules, with `sourced` (what its sources emitted) and its bytes, by name.
    public var totals: [String: Int64?]?
    /// Each module's counts, by key, in the order `hello` gives.
    public var modules: [String: [Int64?]?]?
    /// Each link's `[carried, errors]`, by the graph's link key.
    public var links: [String: [Int64?]?]?
    /// `[received, sent]`, for modules that count bytes.
    public var bytes: [String: [Int64?]?]?
    /// Each module's handling-time histogram, whole, when it changed.
    public var timing: [String: TimingHistogram?]?
    /// Each Listen's counts by where they came from: `meep://<daemon ID>/<pipeline>/<key>` from another Meep host, the
    /// client's address from outside, and `meep://*` and `*` for what's past its limit. In `hello`'s order.
    public var arrivals: [String: [String: [Int64?]?]?]?
    /// Each Fetch's and Send's counts by the `host:port` it connected to, and `*` past its limit.
    public var destinations: [String: [String: [Int64?]?]?]?
    /// Names for clients' addresses, from reverse DNS, when found or changed.
    public var clients: [String: String?]?
    /// Which destinations are Meep hosts, by their daemons' IDs; null when one stops being known as Meep.
    public var peers: [String: String?]?
    /// Places folded into `*` (or `meep://*`) in this update, by module key; their entries are null beside it.
    public var folded: [String: [String]]?

    public init(
        graph: GraphStamp? = nil, totals: [String: Int64?]? = nil, modules: [String: [Int64?]?]? = nil,
        links: [String: [Int64?]?]? = nil, bytes: [String: [Int64?]?]? = nil, timing: [String: TimingHistogram?]? = nil,
        arrivals: [String: [String: [Int64?]?]?]? = nil, destinations: [String: [String: [Int64?]?]?]? = nil,
        clients: [String: String?]? = nil, peers: [String: String?]? = nil, folded: [String: [String]]? = nil
    ) {
        self.graph = graph
        self.totals = totals
        self.modules = modules
        self.links = links
        self.bytes = bytes
        self.timing = timing
        self.arrivals = arrivals
        self.destinations = destinations
        self.clients = clients
        self.peers = peers
        self.folded = folded
    }
}

/// A graph's version, and why it changed when it has.
public struct GraphStamp: Codable, Sendable, Equatable {
    public var version: Int
    public var reason: String?

    public init(version: Int, reason: String? = nil) {
        self.version = version
        self.reason = reason
    }
}

/// A module's handling times since its pipeline started, as an OpenTelemetry exponential histogram: bucket `i` holds
/// times above `2^(i / 2^scale)` seconds and up to the next bucket's, counting from ``offset``.
public struct TimingHistogram: Codable, Sendable, Equatable {
    public var count: Int64
    /// Seconds.
    public var sum: Double
    public var min: Double?
    public var max: Double?
    /// Times too small to bucket.
    public var zero: Int64
    public var offset: Int
    public var buckets: [Int64]

    public init(count: Int64, sum: Double, min: Double? = nil, max: Double? = nil, zero: Int64 = 0, offset: Int, buckets: [Int64]) {
        self.count = count
        self.sum = sum
        self.min = min
        self.max = max
        self.zero = zero
        self.offset = offset
        self.buckets = buckets
    }
}

extension ModuleStats {
    /// Counts from a subscription's array, in `order`, over `previous`: null keeps a count as it was.
    public func applying(_ values: [Int64?], order: [String]) -> (stats: ModuleStats, busy: Int64?) {
        var stats = self
        var busy: Int64?
        for (index, value) in values.enumerated() where index < order.count {
            guard let value else { continue }
            switch order[index] {
            case "received": stats.received = value
            case "handled": stats.handled = value
            case "emitted": stats.emitted = value
            case "passed": stats.passed = value
            case "busy": busy = value
            case "queued": stats.queued = value
            case "dropped": stats.dropped = value
            case "filtered": stats.filtered = value
            case "failed": stats.failed = value
            case "restarts": stats.restarts = value
            case "expired": stats.expired = value
            case "refused": stats.refused = value
            default: break
            }
        }
        return (stats, busy)
    }
}

/// A subscription that's running: its events, and changing it as it goes.
public protocol HostSubscription: Sendable {
    /// `hello`, then updates, plans and problems, until it's cancelled or the connection goes.
    var events: AsyncThrowingStream<SubscriptionEvent, any Error> { get }
    /// Asks for `plan` from now on. Things newly asked for come whole in the next update; things dropped are
    /// forgotten. The daemon answers with a ``SubscriptionEvent/plan(_:)`` or a ``SubscriptionEvent/problem(_:)``.
    func change(to plan: SubscriptionPlan) async throws
    /// Asks for everything whole in the next update, as after a missed one.
    func resend() async throws
    /// Ends it.
    func cancel() async
}

extension MeepJSON {
    /// Reads one event of a subscription from its whole frame, as JSON.
    public static func subscriptionEvent(from frame: Data) throws -> SubscriptionEvent? {
        let header = try decoder.decode(FrameHeader.self, from: frame)
        switch header.event {
        case "hello":
            guard let hello = try decoder.decode(EventFrame<SubscriptionHello>.self, from: frame).data else {
                throw HostError.unreadable("A subscription's hello had no data.")
            }
            return .hello(hello)
        case "update":
            guard let update = try decoder.decode(EventFrame<SubscriptionUpdate>.self, from: frame).data else {
                throw HostError.unreadable("A subscription's update had no data.")
            }
            return .update(update)
        case "plan":
            return .plan(try decoder.decode(EventFrame<JSONValue>.self, from: frame).data ?? .null)
        case "problem":
            let problem = try? decoder.decode(EventFrame<Problem>.self, from: frame).data
            return .problem(problem?.error ?? "The daemon refused the change.")
        default:
            return nil
        }
    }
}
