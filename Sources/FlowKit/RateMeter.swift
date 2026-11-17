import Foundation

/// Turns a cumulative count into a rate per second.
///
/// The daemon's counts only go up, so the rate is the difference between two readings over the time between them,
/// and a missed reading loses nothing. A count that goes down means the pipeline restarted and counts from zero
/// again, so everything since the restart is counted as new. Rates are smoothed over `smoothing` seconds, so they
/// glide rather than jump when readings are uneven.
public struct RateMeter: Sendable, Equatable {
    /// The rate per second, or 0 until there have been two readings.
    public private(set) var rate: Double = 0

    /// How many seconds of readings the rate is smoothed over; 0 for none.
    public var smoothing: Double

    private var last: (time: Double, value: Int64)?
    private var measured = false

    public init(smoothing: Double = 2) {
        self.smoothing = smoothing
    }

    /// Takes a reading of the count at `time`, in seconds on any steady clock, and returns the rate.
    @discardableResult
    public mutating func update(_ value: Int64, at time: Double) -> Double {
        defer { last = (time, value) }
        guard let last else { return rate }
        let elapsed = time - last.time
        guard elapsed > 0 else { return rate }
        let added = value >= last.value ? value - last.value : value
        let instant = Double(added) / elapsed
        if !measured || smoothing <= 0 {
            rate = instant
            measured = true
        } else {
            let weight = 1 - exp(-elapsed / smoothing)
            rate += (instant - rate) * weight
        }
        return rate
    }

    /// Forgets the readings, as for a pipeline that has started again under a new identity.
    public mutating func reset() {
        rate = 0
        last = nil
        measured = false
    }

    public static func == (lhs: RateMeter, rhs: RateMeter) -> Bool {
        lhs.rate == rhs.rate && lhs.smoothing == rhs.smoothing && lhs.last?.time == rhs.last?.time
            && lhs.last?.value == rhs.last?.value && lhs.measured == rhs.measured
    }
}

/// The cumulative counts Synesthesia shows rates for. `heldBack` isn't one of the daemon's: it's what a filter took
/// and neither passed on nor turned into errors.
public enum CountKind: String, CaseIterable, Sendable, Hashable {
    case received, handled, emitted, passed, heldBack, dropped, filtered, failed, expired, refused
}

/// A rate for each kind of count, for one module.
public struct RateSet: Sendable, Equatable {
    private var meters: [CountKind: RateMeter]

    public init(smoothing: Double = 2) {
        meters = Dictionary(uniqueKeysWithValues: CountKind.allCases.map { ($0, RateMeter(smoothing: smoothing)) })
    }

    /// Takes a reading of each count at `time`.
    public mutating func update(_ counts: [CountKind: Int64], at time: Double) {
        for (kind, value) in counts {
            meters[kind, default: RateMeter()].update(value, at: time)
        }
    }

    /// The rate per second of one kind of count.
    public subscript(kind: CountKind) -> Double {
        meters[kind]?.rate ?? 0
    }
}

/// A rate's last minute or so, one sample a second, oldest first: what a sparkline draws.
public struct RateHistory: Sendable, Equatable {
    /// How many seconds it keeps.
    public let capacity: Int
    public private(set) var samples: [Double] = []
    private var second: Int?

    public init(capacity: Int = 60) {
        self.capacity = capacity
    }

    /// Takes the rate at `time`, in seconds on a steady clock. Readings within the same second replace each other;
    /// seconds without one take the reading before, so the line doesn't dip where readings were sparse.
    public mutating func record(_ rate: Double, at time: Double) {
        let now = Int(time.rounded(.down))
        defer { second = now }
        guard let second, now >= second else {
            samples = [rate]
            return
        }
        if now == second, !samples.isEmpty {
            samples[samples.count - 1] = rate
            return
        }
        let skipped = now - second - 1
        if skipped >= capacity {
            samples = [rate]
            return
        }
        if let last = samples.last, skipped > 0 { samples += Array(repeating: last, count: skipped) }
        samples.append(rate)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    public mutating func reset() {
        samples = []
        second = nil
    }
}
