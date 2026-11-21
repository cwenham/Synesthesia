import Foundation

/// Works out what a host should send, and how often, within a byte budget (design, section 4, "Staying within budget"):
/// detail follows the camera, so a pipeline drawn as a dot needs its totals now and then, one drawn as tiles its
/// modules' counts, and the one in focus everything several times a second.
///
/// It starts from rates for each level of detail, estimates the bytes a second they'd cost, and slows them all down
/// together until the estimate is under the budget. Each estimate is corrected by what the host really sends, and an
/// update the host's own budget held back counts as being over.
public struct SubscriptionPlanner: Sendable, Equatable {
    /// How much a pipeline is shown, from least to most.
    public enum Detail: Int, Comparable, Sendable, CaseIterable {
        /// Off screen: its totals now and then, for the sidebar and the host's roll-ups.
        case listed
        /// A dot or a district: its totals.
        case totals
        /// Tiles too small to read: totals, and each module's and link's counts.
        case modules
        /// In focus: all of that more often, with handling times and bytes.
        case full

        public static func < (a: Detail, b: Detail) -> Bool { a.rawValue < b.rawValue }
    }

    /// How much of a pipeline's flows and boundary the canvas draws, for asking for its Listens' arrivals and its
    /// Fetches' and Sends' destinations (Meep2 a5de139) only while they're on screen, at the design's refresh for the
    /// level they're seen at (section 2).
    public enum FlowDetail: Int, Comparable, Sendable, CaseIterable {
        /// Not drawn: nothing is asked for.
        case none
        /// Its host is a node of the mesh, at the boundary's distance: every 5 seconds.
        case far
        /// Its district is on screen, at the mesh's or a host's distance: every 2 seconds.
        case near
        /// Its tiles are showing: every second.
        case close

        public static func < (a: FlowDetail, b: FlowDetail) -> Bool { a.rawValue < b.rawValue }

        /// Seconds between updates, or nil for none.
        public var every: Double? {
            switch self {
            case .none: nil
            case .far: 5
            case .near: 2
            case .close: 1
            }
        }
    }

    /// How often each thing should come, in seconds.
    public struct Rates: Sendable, Equatable {
        public var list: Double
        public var host: Double
        public var runtime: Double
        /// For every pipeline not named in ``pipelines``.
        public var others: Double
        public var pipelines: [String: PipelineRates]
        /// How much slower than the usual rates, to keep under the budget: 1 when it's not needed.
        public var slowdown: Double
        /// What these rates are estimated to cost, in bytes a second, before correcting by what was measured.
        public var estimate: Double
    }

    public struct PipelineRates: Sendable, Equatable {
        public var totals: Double
        public var modules: Double?
        public var links: Double?
        public var timing: Double?
        public var bytes: Double?
        /// Its Listens' arrivals and its Fetches' and Sends' destinations.
        public var places: Double?
    }

    /// What a pipeline is like, for estimating what it costs.
    public struct Shape: Sendable, Equatable {
        public var modules: Int
        public var links: Int
        /// Its Listens, Fetches and Sends: the modules that count places.
        public var network: Int

        public init(modules: Int, links: Int, network: Int = 0) {
            self.modules = modules
            self.links = links
            self.network = network
        }
    }

    /// Bytes a second the host may send; nil for no limit.
    public var budget: Double?
    /// Whether updates come as CBOR, which is about half the size of JSON.
    public var compact: Bool
    /// What the host really sends, against the estimate, smoothed: 1 when they agree.
    public private(set) var calibration: Double = 1

    public init(budget: Double?, compact: Bool = true) {
        self.budget = budget
        self.compact = compact
    }

    /// The usual rates, in seconds, with no budget to keep to.
    public static func usual(_ detail: Detail) -> PipelineRates {
        switch detail {
        case .listed: PipelineRates(totals: 2)
        case .totals: PipelineRates(totals: 1)
        case .modules: PipelineRates(totals: 1, modules: 0.5, links: 0.5)
        case .full: PipelineRates(totals: 1, modules: 0.2, links: 0.2, timing: 2, bytes: 1)
        }
    }

    /// The rates for pipelines shown at `details`, with their flows drawn at `flows`, the others being listed only,
    /// within the budget. A pipeline's places are asked for only when it has modules that count them.
    public func rates(for details: [String: Detail], flows: [String: FlowDetail] = [:], shapes: [String: Shape], others: Int) -> Rates {
        func scaled(_ seconds: Double, by factor: Double, limit: Double) -> Double {
            Self.nice(min(max(seconds * factor, seconds), limit))
        }
        func build(_ factor: Double) -> Rates {
            var pipelines: [String: PipelineRates] = [:]
            for name in Set(details.keys).union(flows.keys) {
                let detail = details[name] ?? .listed
                let places = (shapes[name]?.network ?? 0) > 0 ? flows[name]?.every : nil
                guard detail > .listed || places != nil else { continue }
                let usual = Self.usual(detail)
                pipelines[name] = PipelineRates(
                    totals: scaled(usual.totals, by: factor, limit: 10),
                    modules: usual.modules.map { scaled($0, by: factor, limit: 10) },
                    links: usual.links.map { scaled($0, by: factor, limit: 10) },
                    timing: usual.timing.map { scaled($0, by: factor, limit: 30) },
                    bytes: usual.bytes.map { scaled($0, by: factor, limit: 30) },
                    places: places.map { scaled($0, by: factor, limit: 30) }
                )
            }
            var rates = Rates(
                list: scaled(2, by: factor, limit: 10), host: scaled(1, by: factor, limit: 10), runtime: scaled(2, by: factor, limit: 30),
                others: scaled(2, by: factor, limit: 30), pipelines: pipelines, slowdown: factor, estimate: 0
            )
            rates.estimate = estimate(rates, shapes: shapes, others: others)
            return rates
        }
        var factor = 1.0
        var rates = build(factor)
        guard let budget, budget > 0 else { return rates }
        // Slow everything down together, a step at a time, until the corrected estimate fits, leaving a fifth spare.
        while rates.estimate * calibration > budget * 0.8, factor < 64 {
            factor *= 1.5
            rates = build(factor)
        }
        return rates
    }

    /// Bytes a second `rates` should cost.
    public func estimate(_ rates: Rates, shapes: [String: Shape], others: Int) -> Double {
        let k = compact ? 0.55 : 1.0
        var total = 300 * k / rates.host + 450 * k / rates.runtime + 40 * k / rates.list
        total += Double(others) * 120 * k / rates.others
        var fastest = min(rates.host, rates.runtime, rates.others)
        for (name, pipeline) in rates.pipelines {
            let shape = shapes[name] ?? Shape(modules: 6, links: 6)
            total += 160 * k / pipeline.totals
            if let modules = pipeline.modules { total += Double(shape.modules) * 42 * k / modules }
            if let links = pipeline.links { total += Double(shape.links) * 18 * k / links }
            if let timing = pipeline.timing { total += Double(shape.modules) * 300 * k / timing }
            if let bytes = pipeline.bytes { total += 2 * 30 * k / bytes }
            // A few places for each module that counts them, whose counts change, plus peers and names now and then.
            if let places = pipeline.places { total += Double(max(shape.network, 1)) * 3 * 70 * k / places }
            fastest = min(fastest, pipeline.totals, pipeline.modules ?? .infinity, pipeline.links ?? .infinity)
        }
        // Each update's own frame.
        total += 70 / max(fastest, 0.05)
        return total
    }

    /// Takes what the host really sent over a period, against what the rates were estimated to cost, and whether
    /// the host's budget held any update back.
    public mutating func observe(sent bytesPerSecond: Double, estimated: Double, held: Bool) {
        guard estimated > 0, bytesPerSecond > 0 else { return }
        var ratio = min(max(bytesPerSecond / estimated, 0.1), 10)
        if held { ratio = max(ratio, calibration) * 1.5 }
        calibration += (ratio - calibration) * 0.5
    }

    /// A rate rounded to the nearest of a few usual ones, so small changes don't change the plan.
    public static func nice(_ seconds: Double) -> Double {
        let ladder = [0.1, 0.2, 0.25, 0.5, 1, 2, 3, 5, 10, 15, 20, 30, 60]
        return ladder.first { $0 >= seconds * 0.999 } ?? 60
    }
}
