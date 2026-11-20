import Foundation

/// Handling times as an OpenTelemetry exponential histogram at a fixed scale, as Meep2 keeps one for each module
/// (design, section 4, "Digests"). Every module's has the same scale, so a pipeline's, a host's and the mesh's are made
/// by adding modules' bucket by bucket, at any zoom, without asking the host again.
///
/// Bucket `i` holds times above `2^(i / 2^scale)` seconds and up to `2^((i + 1) / 2^scale)`; ``offset`` is the index of
/// the first in ``buckets``.
public struct HandlingHistogram: Sendable, Equatable {
    public var scale: Int
    public var count: Int64
    /// Seconds, all told.
    public var sum: Double
    public var min: Double?
    public var max: Double?
    /// Times too small to bucket.
    public var zero: Int64
    public var offset: Int
    public var buckets: [Int64]

    public init(scale: Int = 3, count: Int64 = 0, sum: Double = 0, min: Double? = nil, max: Double? = nil, zero: Int64 = 0, offset: Int = 0, buckets: [Int64] = []) {
        self.scale = scale
        self.count = count
        self.sum = sum
        self.min = min
        self.max = max
        self.zero = zero
        self.offset = offset
        self.buckets = buckets
    }

    public static let empty = HandlingHistogram()

    public var isEmpty: Bool { count == 0 }

    /// The average time, in seconds.
    public var mean: Double? { count > 0 ? sum / Double(count) : nil }

    /// Adds another's times to these. Both must have the same scale; one that doesn't is left out.
    public mutating func add(_ other: HandlingHistogram) {
        guard !other.isEmpty else { return }
        guard !isEmpty else {
            self = other
            return
        }
        guard other.scale == scale else { return }
        let low = Swift.min(offset, other.offset)
        let high = Swift.max(offset + buckets.count, other.offset + other.buckets.count)
        var merged = [Int64](repeating: 0, count: high - low)
        for (index, value) in buckets.enumerated() { merged[offset - low + index] += value }
        for (index, value) in other.buckets.enumerated() { merged[other.offset - low + index] += value }
        offset = low
        buckets = merged
        count += other.count
        sum += other.sum
        zero += other.zero
        min = [min, other.min].compactMap { $0 }.min()
        max = [max, other.max].compactMap { $0 }.max()
    }

    /// The sum of several.
    public static func merged<S: Sequence>(_ histograms: S) -> HandlingHistogram where S.Element == HandlingHistogram {
        var total = HandlingHistogram.empty
        for histogram in histograms { total.add(histogram) }
        return total
    }

    /// The times added since `earlier`, both being cumulative: what happened between them. Min and max can't be
    /// worked out for the difference, so they're left out.
    public func subtracting(_ earlier: HandlingHistogram) -> HandlingHistogram {
        guard !earlier.isEmpty, earlier.scale == scale, earlier.count <= count else { return self }
        var result = self
        for (index, value) in earlier.buckets.enumerated() {
            let at = earlier.offset + index - offset
            if at >= 0, at < result.buckets.count { result.buckets[at] = Swift.max(0, result.buckets[at] - value) }
        }
        result.count -= earlier.count
        result.sum = Swift.max(0, sum - earlier.sum)
        result.zero = Swift.max(0, zero - earlier.zero)
        result.min = nil
        result.max = nil
        return result
    }

    /// The time below which `q` of them fall, from 0 to 1, in seconds: the middle of the bucket it's in, on a log
    /// scale, kept within the smallest and largest seen.
    public func quantile(_ q: Double) -> Double? {
        guard count > 0 else { return nil }
        let target = Swift.max(1, (Double(count) * Swift.min(Swift.max(q, 0), 1)).rounded(.up))
        var seen = Double(zero)
        if seen >= target { return 0 }
        let base = pow(2, -Double(scale))
        for (index, value) in buckets.enumerated() {
            seen += Double(value)
            if seen >= target {
                let middle = pow(2, (Double(offset + index) + 0.5) * base)
                return Swift.min(Swift.max(middle, min ?? 0), max ?? .infinity)
            }
        }
        return max
    }
}
