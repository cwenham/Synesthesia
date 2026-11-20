import Foundation
import Testing
import MeepClient

/// Tests against a real Meep daemon, when `MEEP_TEST_SOCKET` names its socket and it runs a pipeline that ticks
/// steadily, named by `MEEP_TEST_PIPELINE`. Skipped otherwise.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MEEP_TEST_SOCKET"] != nil))
struct LiveDaemonTests {
    private var socket: String { ProcessInfo.processInfo.environment["MEEP_TEST_SOCKET"] ?? "" }
    private var pipeline: String { ProcessInfo.processInfo.environment["MEEP_TEST_PIPELINE"] ?? "busy" }

    @Test func requestsAreAnsweredOverOneWebSocket() async throws {
        let daemon = try await DaemonConnection.connect(socketPath: socket)
        // Several at once, to check answers find their requests.
        async let info = daemon.info()
        async let pipelines = daemon.pipelines()
        async let detail = daemon.pipeline(pipeline)
        async let graph = daemon.graph(pipeline)
        #expect(try await info.capabilities.contains("observe"))
        #expect(try await pipelines.contains { $0.name == pipeline })
        #expect(try await detail.modules.count == graph.modules.count)
        await daemon.close()
    }

    @Test func aRefusalSaysWhy() async throws {
        let daemon = try await DaemonConnection.connect(socketPath: socket)
        await #expect(throws: HostError.self) { try await daemon.pipeline("no-such-pipeline") }
        await daemon.close()
    }

    @Test func statsStreamAndCanBeStopped() async throws {
        let daemon = try await DaemonConnection.connect(socketPath: socket)
        var received: [Int64] = []
        for try await event in daemon.stats(pipeline, every: .milliseconds(100)) {
            if case .stats(let detail) = event {
                received.append(detail.modules.reduce(0) { $0 + $1.counts.received })
            }
            if received.count == 3 { break }
        }
        #expect(received.count == 3)
        #expect(received == received.sorted())
        // The connection still answers after the stream was stopped.
        #expect(try await daemon.info().version.isEmpty == false)
        await daemon.close()
    }

    @Test func aRefusedStreamEndsWithTheReason() async throws {
        let daemon = try await DaemonConnection.connect(socketPath: socket)
        await #expect(throws: HostError.self) {
            for try await _ in daemon.stats("no-such-pipeline", every: .seconds(1)) {}
        }
        await daemon.close()
    }

    @Test func aTapShowsMessagesThatMeetItsCondition() async throws {
        let daemon = try await DaemonConnection.connect(socketPath: socket)
        let graph = try await daemon.graph(pipeline)
        let source = try #require(graph.modules.first { $0.verbRole == .source })
        var counts: [Double] = []
        for try await event in daemon.tap(pipeline, module: "\(source.number)", where: "msg.Count % 2 == 0", sample: nil) {
            counts.append(event.message.content?["Count"]?.number ?? -1)
            if counts.count == 3 { break }
        }
        #expect(counts.count == 3)
        #expect(counts.allSatisfy { $0.truncatingRemainder(dividingBy: 2) == 0 })
        await #expect(throws: HostError.self) {
            for try await _ in daemon.tap(pipeline, module: "\(source.number)", where: "msg.Count >", sample: nil) {}
        }
        await daemon.close()
    }

    @Test func injectingSaysWhatWasSent() async throws {
        let daemon = try await DaemonConnection.connect(socketPath: socket)
        guard try await daemon.info().capabilities.contains("inject") else { return }
        let graph = try await daemon.graph(pipeline)
        let last = try #require(graph.modules.last)
        let text = try await daemon.inject(pipeline, module: "\(last.number)", .text("from Synesthesia's tests"))
        #expect(text.type == "TextMessage")
        #expect(text.module == last.module)
        let json = try await daemon.inject(pipeline, module: "\(last.number)", .json(["Count": 6, "Note": "test"]))
        #expect(json.type == "JsonMessage")
        await daemon.close()
    }

    @Test func aDaemonSaysWhoItIsAndItsClock() async throws {
        let daemon = try await DaemonConnection.connect(socketPath: socket)
        let info = try await daemon.info()
        let id = try #require(info.id)
        #expect(UUID(uuidString: id) != nil)
        #expect(info.names?.isEmpty == false)
        let clock = try #require(info.clock)
        #expect(abs(Double(clock) / 1_000_000 - Date().timeIntervalSince1970) < 60)
        #expect(try await daemon.pipelines().first { $0.name == pipeline }?.graphVersion != nil)
        await daemon.close()
    }

    @Test(arguments: [SubscriptionEncoding.json, .cbor])
    func aSubscriptionSendsOnlyWhatChanged(encoding: SubscriptionEncoding) async throws {
        let daemon = try await DaemonConnection.connect(socketPath: socket)
        let id = try await daemon.info().id
        let plan = SubscriptionPlan(
            encoding: encoding, list: .seconds(1), host: .milliseconds(200),
            pipelines: [pipeline: PipelinePlan(totals: .milliseconds(100), modules: ["*": .milliseconds(100)], links: ["*": .milliseconds(100)])]
        )
        let subscription = try await daemon.subscribe(plan)
        var hello: SubscriptionHello?
        var updates: [SubscriptionUpdate] = []
        for try await event in subscription.events {
            switch event {
            case .hello(let said): hello = said
            case .update(let update): updates.append(update)
            default: break
            }
            if updates.count == 4 { break }
        }
        let said = try #require(hello)
        #expect(said.host.id == id)
        #expect(said.counts.modules.first == "received")
        #expect(updates.map(\.seq) == [1, 2, 3, 4])
        let first = try #require(updates[0].pipelines?[pipeline] ?? nil)
        #expect(first.graph?.version != nil, "the first update says the graph's version")
        #expect(first.modules?.values.allSatisfy { $0?.count == said.counts.modules.count } == true, "the first update has every count")
        #expect(updates[0].list?[pipeline] != nil)
        // Later ones carry only what changed: never the list again, and counts arrays cut short.
        let later = updates.dropFirst().compactMap { $0.pipelines?[pipeline] ?? nil }
        #expect(updates.dropFirst().allSatisfy { $0.list == nil })
        #expect(later.contains { part in part.modules?.values.contains { ($0?.count ?? 0) < said.counts.modules.count } == true })
        #expect(updates.last!.bytes > updates.first!.bytes)
        await daemon.close()
    }

    @Test func aSubscriptionChangesInPlace() async throws {
        let daemon = try await DaemonConnection.connect(socketPath: socket)
        let subscription = try await daemon.subscribe(SubscriptionPlan(encoding: .cbor, pipelines: ["*": PipelinePlan(totals: .milliseconds(200))]))
        var changed = false
        var timed = false
        for try await event in subscription.events {
            switch event {
            case .update(let update):
                if !changed {
                    #expect(update.pipelines?[pipeline]??.modules == nil, "modules weren't asked for yet")
                    changed = true
                    try await subscription.change(to: SubscriptionPlan(encoding: .cbor, pipelines: [
                        "*": PipelinePlan(totals: .milliseconds(200)),
                        pipeline: PipelinePlan(modules: ["*": .milliseconds(100)], timing: ["*": .milliseconds(100)]),
                    ]))
                } else if let part = update.pipelines?[pipeline] ?? nil, let timing = part.timing, !timing.isEmpty {
                    let histogram = try #require(timing.values.first ?? nil)
                    #expect(histogram.buckets.reduce(0, +) + histogram.zero == histogram.count)
                    timed = true
                }
            case .plan(let plan):
                #expect(plan["pipelines"]?[pipeline]?["timing"] != nil)
            case .problem(let problem):
                Issue.record("The change was refused: \(problem)")
            case .hello:
                break
            }
            if timed { break }
        }
        #expect(timed)
        await daemon.close()
    }

    @Test func nothingListeningIsSaidPlainly() async {
        await #expect(throws: (any Error).self) {
            _ = try await DaemonConnection.connect(socketPath: "/tmp/no-such-meep.sock")
        }
    }
}
