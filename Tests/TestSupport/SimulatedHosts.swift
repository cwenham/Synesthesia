import Foundation
import Testing

/// For tests that run simulated hosts: only a few run at once, however many suites run beside them.
///
/// Each host's session hands its updates to the model on the main actor, which every `@MainActor` test shares. Run
/// all at once, as Swift Testing would, they kept the main thread fully busy on a quiet Mac, so on a busy or
/// throttled one it fell behind and tests across the suite timed out waiting for it, the hosts' or not. Through this
/// gate the hosts' share of the main actor stays the same whatever else the Mac is doing.
///
///     @Suite(.simulatedHosts) struct FollowingTests { … }
///     @Test(.simulatedHosts) func countsArrive() async throws { … }
///
/// `SYNESTHESIA_TEST_HOSTS` sets how many run at once (4 unless it's set).
public struct SimulatedHosts: TestTrait, SuiteTrait, TestScoping {
    public var isRecursive: Bool { true }

    /// Each test case takes a place of its own, and a suite none.
    public func scopeProvider(for test: Test, testCase: Test.Case?) -> SimulatedHosts? {
        testCase == nil ? nil : self
    }

    public func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        await HostGate.shared.enter()
        do {
            try await function()
        } catch {
            await HostGate.shared.leave()
            throw error
        }
        await HostGate.shared.leave()
    }
}

extension Trait where Self == SimulatedHosts {
    /// Runs the test, or each of a suite's, as one of only a few running simulated hosts at once.
    public static var simulatedHosts: SimulatedHosts { SimulatedHosts() }
}

/// The places, taken first come, first served.
actor HostGate {
    static let shared = HostGate(places: ProcessInfo.processInfo.environment["SYNESTHESIA_TEST_HOSTS"].flatMap(Int.init) ?? 4)

    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(places: Int) {
        free = max(1, places)
    }

    func enter() async {
        if free > 0 {
            free -= 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    func leave() {
        if waiting.isEmpty {
            free += 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
