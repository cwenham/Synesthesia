import Foundation
import MeepClient
import Testing
@testable import Assistant

/// Against the real Claude API. These cost money, so they run only when `ANTHROPIC_API_KEY` is set. With
/// `CLAUDE_RECORD_FIXTURES` naming a folder, each response's events are saved there too, to refresh the fixtures from
/// what the API really sends.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.isEmpty == false, "calls the Claude API, which costs money"), .serialized)
struct LiveClaudeTests {
    @Test func aQuestionIsAnsweredWithTheToolsAndTheCacheIsRead() async throws {
        let viewer = try await TestViewer()
        defer { viewer.stop() }
        let key = try #require(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"])
        let chat = ClaudeChat(registry: ContinuumTools.registry(for: viewer), key: ClaudeKey(store: MemoryStore(key)), transport: Recording()) {
            SidebarPrompt.context(viewer)
        }
        chat.effort = .low
        chat.ask("How many pipelines does the host sim have, and which is busiest? Look with the tools, then answer in one sentence.")
        try await idle(chat)
        let problems = chat.entries.compactMap { if case .notice(let notice) = $0.kind { notice } else { nil } }
        #expect(problems.isEmpty, "\(problems)")
        let calls = chat.entries.compactMap { if case .tool(let call) = $0.kind { call } else { nil } }
        #expect(calls.contains { $0.state == .finished })
        #expect(chat.entries.contains { if case .reply(let text) = $0.kind { !text.isEmpty } else { false } })
        #expect(chat.dropped.allSatisfy { $0["reason"] != "prefix_binding_mismatch" })

        // The system prompt, tools and conversation so far come from the cache the second time.
        chat.ask("Which address did you look at first? One line.")
        try await idle(chat)
        #expect(chat.usage.cacheRead > 0)
    }

    private func idle(_ chat: ClaudeChat) async throws {
        let deadline = ContinuousClock.now + .seconds(240)
        while chat.isBusy {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The real API, with each response's events saved when asked to.
    final class Recording: HTTPStreaming {
        private let inner = URLSessionStreaming()
        private let folder = ProcessInfo.processInfo.environment["CLAUDE_RECORD_FIXTURES"]

        func open(_ request: URLRequest) async throws -> HTTPStream {
            let response = try await inner.open(request)
            guard let folder, !folder.isEmpty else { return response }
            let url = URL(fileURLWithPath: folder).appendingPathComponent("live-\(Int(Date().timeIntervalSince1970 * 1000)).sse")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let file = try FileHandle(forWritingTo: url)
            let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            let task = Task {
                do {
                    for try await chunk in response.body {
                        try? file.write(contentsOf: chunk)
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                try? file.close()
            }
            continuation.onTermination = { _ in task.cancel() }
            return HTTPStream(status: response.status, headers: response.headers, body: body)
        }
    }
}
