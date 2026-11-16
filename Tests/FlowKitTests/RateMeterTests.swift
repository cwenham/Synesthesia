import Testing
@testable import FlowKit

struct RateMeterTests {
    @Test func theFirstReadingGivesNoRate() {
        var meter = RateMeter()
        #expect(meter.update(100, at: 0) == 0)
    }

    @Test func aSteadyCountGivesItsRate() {
        var meter = RateMeter()
        for second in 0...10 { meter.update(Int64(second * 50), at: Double(second)) }
        #expect(abs(meter.rate - 50) < 0.001)
    }

    @Test func aMissedReadingLosesNothing() {
        var meter = RateMeter(smoothing: 0)
        meter.update(0, at: 0)
        #expect(meter.update(300, at: 3) == 100)
    }

    @Test func aRestartCountsFromZero() {
        var meter = RateMeter(smoothing: 0)
        meter.update(1000, at: 0)
        // The pipeline restarted and has counted 20 since.
        #expect(meter.update(20, at: 1) == 20)
    }

    @Test func smoothingGlidesTowardsAChange() {
        var meter = RateMeter(smoothing: 2)
        meter.update(0, at: 0)
        meter.update(10, at: 1)
        let jumped = meter.update(110, at: 2)
        #expect(jumped > 10 && jumped < 100)
    }

    @Test func aSetKeepsEachKindApart() {
        var rates = RateSet(smoothing: 0)
        rates.update([.received: 0, .failed: 0], at: 0)
        rates.update([.received: 40, .failed: 2], at: 2)
        #expect(rates[.received] == 20)
        #expect(rates[.failed] == 1)
        #expect(rates[.dropped] == 0)
    }
}
