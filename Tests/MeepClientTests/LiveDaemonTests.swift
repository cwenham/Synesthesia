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

    @Test func nothingListeningIsSaidPlainly() async {
        await #expect(throws: (any Error).self) {
            _ = try await DaemonConnection.connect(socketPath: "/tmp/no-such-meep.sock")
        }
    }
}
