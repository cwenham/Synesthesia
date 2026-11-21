import Foundation
import Testing
@testable import FlowKit

struct HistogramTests {
    /// Handling times at scale 3: bucket `i` holds times above 2^(i/8) seconds, up to 2^((i+1)/8).
    @Test func histogramsMergeByAddingBucketsAtTheSameIndex() {
        let a = HandlingHistogram(count: 6, sum: 0.006, min: 0.0008, max: 0.0012, offset: -80, buckets: [1, 4, 1])
        let b = HandlingHistogram(count: 5, sum: 0.5, min: 0.09, max: 0.11, offset: -27, buckets: [2, 3])
        let c = HandlingHistogram(count: 3, sum: 0.003, min: 0.0009, max: 0.0011, offset: -79, buckets: [2, 1])
        let merged = HandlingHistogram.merged([a, b, c, .empty])
        #expect(merged.count == 14)
        #expect(merged.sum == 0.509)
        #expect(merged.offset == -80)
        #expect(merged.buckets.count == 80 - 27 + 2)
        #expect(merged.buckets[0] == 1 && merged.buckets[1] == 6 && merged.buckets[2] == 2)
        #expect(merged.buckets[53] == 2 && merged.buckets[54] == 3)
        #expect(merged.buckets.reduce(0, +) == merged.count)
        #expect(merged.min == 0.0008 && merged.max == 0.11)
    }

    @Test func quantilesComeFromTheBuckets() throws {
        // 90 around a millisecond, 10 around a tenth of a second.
        let histogram = HandlingHistogram(count: 100, sum: 1.09, min: 0.0009, max: 0.12, offset: -80, buckets: [90] + Array(repeating: 0, count: 52) + [10])
        let median = try #require(histogram.quantile(0.5))
        #expect(median > 0.0009 && median < 0.0011)
        let tail = try #require(histogram.quantile(0.99))
        #expect(tail > 0.09 && tail <= 0.12)
        #expect(HandlingHistogram.empty.quantile(0.5) == nil)
        #expect(abs((histogram.mean ?? 0) - 0.0109) < 0.000_001)
    }

    @Test func aDifferenceIsWhatHappenedBetween() {
        let earlier = HandlingHistogram(count: 10, sum: 0.01, offset: -80, buckets: [10])
        let later = HandlingHistogram(count: 25, sum: 0.5, offset: -80, buckets: [12, 0, 13])
        let between = later.subtracting(earlier)
        #expect(between.count == 15)
        #expect(between.buckets == [2, 0, 13])
        #expect(abs(between.sum - 0.49) < 1e-9)
        #expect(between.min == nil)
    }
}

struct CountSetTests {
    @Test func ratesFallWhenCountsStopChanging() {
        var counts = CountSet(smoothing: 0)
        counts.read(["received": 100, "busy": 0], at: 0)
        counts.read(["received": 200, "busy": 500_000], at: 1)
        #expect(counts.rate("received") == 100)
        #expect(counts.rate("busy") == 500_000)
        // Nothing changed, so nothing was sent: read again as it was.
        counts.read(at: 2)
        #expect(counts.rate("received") == 0)
        #expect(counts["received"] == 200)
        counts.read(["busy": nil], at: 3)
        #expect(counts.values["busy"] == nil, "null means it's gone")
    }
}

struct SubscriptionPlannerTests {
    let shapes = ["orders": SubscriptionPlanner.Shape(modules: 6, links: 5), "warehouse": SubscriptionPlanner.Shape(modules: 11, links: 11)]

    @Test func withoutABudgetEachDetailHasItsUsualRates() {
        let planner = SubscriptionPlanner(budget: nil)
        let rates = planner.rates(for: ["orders": .full, "warehouse": .totals, "ticker": .listed], shapes: shapes, others: 2)
        #expect(rates.slowdown == 1)
        #expect(rates.pipelines["orders"] == SubscriptionPlanner.usual(.full))
        #expect(rates.pipelines["warehouse"] == SubscriptionPlanner.PipelineRates(totals: 1))
        #expect(rates.pipelines["ticker"] == nil, "listed pipelines share the others' totals")
        #expect(rates.estimate > 0)
    }

    @Test func aBudgetSlowsEverythingDownTogether() {
        let generous = SubscriptionPlanner(budget: 1_000_000).rates(for: ["orders": .full, "warehouse": .modules], shapes: shapes, others: 10)
        #expect(generous.slowdown == 1)
        let tight = SubscriptionPlanner(budget: 2_000).rates(for: ["orders": .full, "warehouse": .modules], shapes: shapes, others: 10)
        #expect(tight.slowdown > 1)
        #expect(tight.estimate <= 2_000 * 0.8)
        #expect(tight.pipelines["orders"]!.modules! > generous.pipelines["orders"]!.modules!)
        #expect(tight.pipelines["orders"]!.modules! <= tight.pipelines["warehouse"]!.modules!, "what's in focus still comes most often")
    }

    @Test func whatTheHostReallySendsCorrectsTheEstimate() {
        var planner = SubscriptionPlanner(budget: 4_000)
        let first = planner.rates(for: ["orders": .full], shapes: shapes, others: 3)
        // The host sends three times what was estimated, and its budget held an update back.
        planner.observe(sent: first.estimate * 3, estimated: first.estimate, held: true)
        #expect(planner.calibration > 2)
        let second = planner.rates(for: ["orders": .full], shapes: shapes, others: 3)
        #expect(second.slowdown > first.slowdown)
        #expect(first.slowdown == 1)
        #expect(second.estimate * planner.calibration <= 4_000 * 0.8)
    }

    @Test(arguments: [(0.07, 0.1), (0.2, 0.2), (0.3, 0.5), (0.75, 1.0), (4.0, 5.0), (100.0, 60.0)])
    func ratesAreRoundedToUsualOnes(seconds: Double, nice: Double) {
        #expect(SubscriptionPlanner.nice(seconds) == nice)
    }
}

/// Asking for places (arrivals and destinations) only for flows on screen, at the design's refresh for each level.
struct FlowPlanningTests {
    private let shapes = [
        "front": SubscriptionPlanner.Shape(modules: 4, links: 3, network: 2),
        "busy": SubscriptionPlanner.Shape(modules: 4, links: 3, network: 0),
    ]

    @Test func placesFollowTheDistanceFlowsAreSeenAt() {
        let planner = SubscriptionPlanner(budget: nil)
        let far = planner.rates(for: [:], flows: ["front": .far], shapes: shapes, others: 1)
        #expect(far.pipelines["front"]?.places == 5, "the boundary's refresh")
        #expect(far.pipelines["front"]?.modules == nil, "flows alone don't ask for modules")
        #expect(planner.rates(for: ["front": .totals], flows: ["front": .near], shapes: shapes, others: 1).pipelines["front"]?.places == 2)
        #expect(planner.rates(for: ["front": .full], flows: ["front": .close], shapes: shapes, others: 1).pipelines["front"]?.places == 1)
        // Not shown: none.
        #expect(planner.rates(for: ["front": .totals], flows: [:], shapes: shapes, others: 1).pipelines["front"]?.places == nil)
    }

    @Test func aPipelineWithNothingThatCountsPlacesIsntAskedForThem() {
        let rates = SubscriptionPlanner(budget: nil).rates(for: [:], flows: ["busy": .close], shapes: shapes, others: 1)
        #expect(rates.pipelines["busy"] == nil)
    }

    @Test func placesCostSomethingAndSlowDownWithTheRest() {
        let planner = SubscriptionPlanner(budget: nil)
        let without = planner.rates(for: ["front": .totals], shapes: shapes, others: 0)
        let with = planner.rates(for: ["front": .totals], flows: ["front": .close], shapes: shapes, others: 0)
        #expect(with.estimate > without.estimate)
        let tight = SubscriptionPlanner(budget: 200).rates(for: ["front": .totals], flows: ["front": .close], shapes: shapes, others: 0)
        #expect(tight.slowdown > 1)
        #expect((tight.pipelines["front"]?.places ?? 0) > 1)
    }
}
