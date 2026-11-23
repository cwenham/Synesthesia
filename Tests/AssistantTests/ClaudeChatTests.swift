import ContinuumKit
import CoreGraphics
import Foundation
import ImageIO
import MeepClient
import Testing
import TestSupport
import UniformTypeIdentifiers
@testable import Assistant

/// Replays recorded API responses: a stream of server-sent events from a fixture, cut into small chunks so events and
/// characters are split across them as they are on the network; or an HTTP error; or a dropped connection. It keeps
/// each request it was sent.
final class FakeAPI: HTTPStreaming, @unchecked Sendable {
    enum Reply {
        /// A fixture's events, in chunks of `chunk` bytes: an odd size, so events and characters are split. Each chunk
        /// is a trip to the main actor and back, which the full suite keeps busy, so they aren't tiny; the parser's own
        /// tests split byte by byte.
        case sse(String, chunk: Int = 61)
        /// A fixture's events, then nothing until the request is cancelled.
        case hang(String)
        case status(Int, headers: [String: String] = [:], body: String)
        case failure(URLError.Code)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var sent: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func queue(_ more: Reply...) { lock.withLock { replies += more } }

    var requests: [URLRequest] { lock.withLock { sent } }
    var bodies: [JSONValue] { requests.compactMap { $0.httpBody.flatMap { try? JSONValue.parse($0) } } }

    func open(_ request: URLRequest) async throws -> HTTPStream {
        let reply: Reply? = lock.withLock {
            sent.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        switch reply {
        case .sse(let name, let size)?:
            let data = try Self.fixture(name)
            return HTTPStream(status: 200, headers: ["request-id": "req_test"], body: AsyncThrowingStream { continuation in
                var offset = 0
                while offset < data.count {
                    continuation.yield(data[offset..<min(offset + size, data.count)])
                    offset += size
                }
                continuation.finish()
            })
        case .hang(let name)?:
            let data = try Self.fixture(name)
            return HTTPStream(status: 200, headers: [:], body: AsyncThrowingStream { continuation in
                continuation.yield(data)
            })
        case .status(let code, let headers, let body)?:
            return HTTPStream(status: code, headers: headers.merging(["request-id": "req_test"]) { a, _ in a }, body: AsyncThrowingStream { continuation in
                continuation.yield(Data(body.utf8))
                continuation.finish()
            })
        case .failure(let code)?:
            throw URLError(code)
        case nil:
            Issue.record("A request no reply was queued for")
            throw URLError(.badServerResponse)
        }
    }

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}

/// Tools that stand in for the app's, so the loop can be tested on its own.
@MainActor
final class FakeTools {
    var ran: [String: [JSONValue]] = [:]

    var registry: ToolRegistry {
        ToolRegistry([
            Tool(name: "echo", title: "Echo", description: "Says its text back.",
                 inputSchema: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]) { input in
                self.ran["echo", default: []].append(input)
                return ToolResult([.text(input["text"]?.string ?? "")])
            },
            Tool(name: "count", title: "Count", description: "Counts to n.",
                 inputSchema: ["type": "object", "properties": ["n": ["type": "integer", "minimum": 1, "maximum": 10]], "required": ["n"]]) { input in
                self.ran["count", default: []].append(input)
                return .json(["counted": input["n"] ?? 0])
            },
            Tool(name: "change", title: "Change something", description: "Changes something.",
                 inputSchema: ["type": "object", "properties": ["address": ["type": "string"], "summary": ["type": "string"]]],
                 readOnly: false, asks: .change) { input in
                self.ran["change", default: []].append(input)
                return .json(["outcome": "accepted"])
            },
            Tool(name: "peek", title: "Peek at messages", description: "Reads messages.",
                 inputSchema: ["type": "object", "properties": ["address": ["type": "string"]]], asks: .sendsMessages) { input in
                self.ran["peek", default: []].append(input)
                return .json(["messages": [["content": "secret"]]])
            },
            Tool(name: "slow", title: "Wait", description: "Waits until it's cancelled.", inputSchema: ["type": "object"]) { input in
                self.ran["slow", default: []].append(input)
                try await Task.sleep(for: .seconds(60))
                return .json([:])
            },
            Tool(name: "picture", title: "Picture", description: "A big picture.", inputSchema: ["type": "object"]) { _ in
                ToolResult([.png(ClaudeChatTests.png(width: 3000, height: 2000)), .text("A picture.")])
            },
            Tool(name: "show", title: "Show", description: "Shows an address.", inputSchema: ["type": "object"], readOnly: false) { input in
                self.ran["show", default: []].append(input)
                return .json(["shown": input["address"] ?? ""])
            },
        ])
    }
}

@MainActor
struct ClaudeChatTests {
    private func chat(_ replies: [FakeAPI.Reply], tools: FakeTools = FakeTools(), key: String? = "test-key",
                      context: @escaping @MainActor () -> String? = { "[The canvas is on a pipeline: meep://sim/orders.]" }) -> (ClaudeChat, FakeAPI, FakeTools) {
        let api = FakeAPI(replies)
        let chat = ClaudeChat(registry: tools.registry, key: ClaudeKey(store: MemoryStore(key)), transport: api, system: "Test system prompt.", context: context)
        chat.backoff = { _ in .milliseconds(1) }
        return (chat, api, tools)
    }

    /// Waits for the conversation to finish its turn.
    private func idle(_ chat: ClaudeChat) async throws {
        try await until { !chat.isBusy }
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out")
                throw CancellationError()
            }
            // Not much more often than this: every look takes a turn on the main actor the other suites share.
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    private func notices(_ chat: ClaudeChat) -> [Notice] {
        chat.entries.compactMap { if case .notice(let notice) = $0.kind { notice } else { nil } }
    }

    private func calls(_ chat: ClaudeChat) -> [ToolCall] {
        chat.entries.compactMap { if case .tool(let call) = $0.kind { call } else { nil } }
    }

    private func replies(_ chat: ClaudeChat) -> [String] {
        chat.entries.compactMap { if case .reply(let text) = $0.kind { text } else { nil } }
    }

    /// The text of each tool result in a user message.
    private func results(_ message: JSONValue?) -> [(id: String, text: String, isError: Bool)] {
        (message?["content"]?.array ?? []).compactMap { block in
            guard block["type"] == "tool_result" else { return nil }
            let text = block["content"]?.array?.compactMap { $0["text"]?.string }.joined() ?? ""
            return (block["tool_use_id"]?.string ?? "", text, block["is_error"] == true)
        }
    }

    // MARK: Streaming and the request

    @Test func aQuestionIsAnsweredAsItStreams() async throws {
        let (chat, api, _) = chat([.sse("answer.sse", chunk: 13)])
        chat.ask("Which pipeline is busiest?")
        try await idle(chat)
        #expect(replies(chat) == ["The busiest pipeline is **orders**, at about 40 messages a second — see meep://sim/orders/m2."])
        let thinking = chat.entries.compactMap { if case .thinking(let text) = $0.kind { text } else { nil } }
        #expect(thinking == ["The person asks what's busiest. Orders is busiest — about 40 a second."])
        #expect(notices(chat).isEmpty)
        // The transcript: the question with the app's note, then the reply as it came, thinking signed.
        #expect(chat.messages.count == 2)
        let question = try #require(chat.messages.first?["content"]?.array)
        #expect(question.map { $0["text"]?.string } == ["[The canvas is on a pipeline: meep://sim/orders.]", "Which pipeline is busiest?"])
        let reply = try #require(chat.messages.last?["content"]?.array)
        #expect(reply.first == ["type": "thinking", "thinking": "The person asks what's busiest. Orders is busiest — about 40 a second.", "signature": "sig-answer-0"])
        #expect(reply.last?["type"] == "text")
        #expect(chat.usage == ChatUsage(input: 1200, output: 64, cacheRead: 1100, cacheWrite: 0, requests: 1))
        #expect(api.requests.count == 1)
    }

    @Test func theRequestIsShapedAsTheAPIAsks() async throws {
        let tools = FakeTools()
        let (chat, api, _) = chat([.sse("answer.sse")], tools: tools)
        chat.effort = .high
        chat.ask("Hello")
        try await idle(chat)
        let request = try #require(api.requests.first)
        #expect(request.url == URL(string: "https://api.anthropic.com/v1/messages"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        let betas = request.value(forHTTPHeaderField: "anthropic-beta")?.components(separatedBy: ",") ?? []
        #expect(Set(betas) == ["server-side-fallback-2026-07-01", "thinking-binding-controls-2026-08-01"])
        let body = try #require(api.bodies.first)
        #expect(body["model"] == "claude-opus-5-5")
        #expect(body["max_tokens"] == 64000)
        #expect(body["stream"] == true)
        #expect(body["thinking"] == ["type": "adaptive", "display": "summarized", "block_binding": ["prefix_mismatch_behavior": "drop_block"]])
        #expect(body["output_config"] == ["effort": "high"])
        #expect(body["fallbacks"] == "default")
        #expect(body["tool_choice"] == nil)
        #expect(body["temperature"] == nil)
        // Cached: the system prompt (and the tools before it), and the conversation's tail.
        #expect(body["system"] == [["type": "text", "text": "Test system prompt.", "cache_control": ["type": "ephemeral"]]])
        #expect(body["cache_control"] == ["type": "ephemeral"])
        // The same tools as MCP's, in the same order, each streaming its input.
        let sent = try #require(body["tools"]?.array)
        let registry = tools.registry
        #expect(sent.map { $0["name"]?.string } == registry.tools.map(\.name))
        for (definition, tool) in zip(sent, registry.tools) {
            #expect(definition["description"]?.string == tool.description)
            #expect(definition["input_schema"] == tool.inputSchema)
            #expect(definition["eager_input_streaming"] == true)
            #expect(definition["title"] == nil && definition["annotations"] == nil)
        }
    }

    @Test func theSameRequestIsByteForByteTheSameEachTime() {
        let tools = FakeTools().registry.tools
        let a = ClaudeAPI.request(body: ClaudeAPI.body(system: "S", tools: tools, messages: [["role": "user", "content": "hi"]], effort: .medium), key: "k")
        let b = ClaudeAPI.request(body: ClaudeAPI.body(system: "S", tools: tools, messages: [["role": "user", "content": "hi"]], effort: .medium), key: "k")
        #expect(a.httpBody == b.httpBody)
    }

    @Test func noKeyAsksForOneAndSendsNothing() async throws {
        let (chat, api, _) = chat([], key: nil)
        chat.ask("Hello")
        try await idle(chat)
        #expect(api.requests.isEmpty)
        let notice = try #require(notices(chat).last)
        #expect(notice.kind == .problem && notice.action == .openSettings)
        #expect(notice.title.contains("API key"))
        #expect(chat.canRetry)
    }

    // MARK: Tools

    @Test(.simulatedHosts) func toolsRunOverSeveralTurnsAndTheTranscriptOnlyGrows() async throws {
        let viewer = try await TestViewer(slowly: true)
        defer { viewer.stop() }
        let api = FakeAPI([.sse("loop-1.sse"), .sse("loop-2.sse", chunk: 11), .sse("loop-3.sse")])
        let chat = ClaudeChat(registry: ContinuumTools.registry(for: viewer), key: ClaudeKey(store: MemoryStore("test-key")), transport: api) {
            SidebarPrompt.context(viewer)
        }
        chat.ask("How is orders doing?")
        try await idle(chat)
        #expect(api.requests.count == 3)
        #expect(calls(chat).map(\.name) == ["list_continuum", "describe_pipeline"])
        #expect(calls(chat).allSatisfy { $0.state == .finished })
        #expect(calls(chat).last?.address == "meep://sim/orders")
        #expect(replies(chat).last == "Orders has its modules running; meep://sim/orders/m2 passes the most.")
        let bodies = api.bodies
        // Each request's messages begin with the last one's, unchanged, so the cache and thinking stay valid.
        for (earlier, later) in zip(bodies, bodies.dropFirst()) {
            let before = try #require(earlier["messages"]?.array)
            let after = try #require(later["messages"]?.array)
            #expect(after.count == before.count + 2)
            #expect(Array(after.prefix(before.count)) == before)
            #expect(earlier["system"] == later["system"] && earlier["tools"] == later["tools"])
        }
        // The second request answers list_continuum; the third, describe_pipeline, with the hosts and the pipeline.
        let second = try #require(bodies[1]["messages"]?.array)
        #expect(second[1]["content"]?.array?.last == ["type": "tool_use", "id": "toolu_list", "name": "list_continuum", "input": [:]])
        let listed = results(second[2])
        #expect(listed.map(\.id) == ["toolu_list"] && listed[0].text.contains("meep://sim/orders") && !listed[0].isError)
        let third = try #require(bodies[2]["messages"]?.array)
        #expect(third[3]["content"]?.array?.last?["input"] == ["address": "meep://sim/orders"])
        let described = results(third[4])
        #expect(described.first?.text.contains("meep://sim/orders/m1") == true)
        #expect(chat.dropped.isEmpty)
    }

    @Test func toolInputIsShownAsItStreams() throws {
        var reply = ClaudeReply()
        let events = try String(decoding: FakeAPI.fixture("loop-2.sse"), as: UTF8.self)
        var parser = SSEParser()
        var addresses: [String?] = []
        for event in parser.feed(Data(events.utf8)) {
            guard let json = try? JSONValue.parse(Data(event.data.utf8)) else { continue }
            if case .grew(let index) = try reply.apply(json), case .toolUse(let id, let name, let text, let input)? = reply.block(index)?.kind {
                addresses.append(ToolCall(id: id, name: name, title: name, json: text, input: input, state: .writing).address)
            }
        }
        // The address appears as soon as its first characters do, and grows.
        #expect(addresses == [nil, "meep://si", "meep://sim/orders", "meep://sim/orders"])
        #expect(reply.toolCalls.count == 1)
        guard case .toolUse(_, _, _, let input)? = reply.toolCalls.first?.kind else { Issue.record("No call"); return }
        #expect(input == ["address": "meep://sim/orders"])
    }

    @Test func inputThatIsntJSONIsntRun() async throws {
        let (chat, api, tools) = chat([.sse("invalid-json.sse"), .sse("answer.sse")])
        chat.ask("Echo something")
        try await idle(chat)
        #expect(tools.ran["echo"] == nil)
        #expect(calls(chat).first?.state == .failed("Its input wasn't JSON."))
        let second = try #require(api.bodies.last?["messages"]?.array)
        // The call goes back with empty input; its result is an error carrying what was sent.
        #expect(second[1]["content"]?.array?.first?["input"] == [:])
        let result = try #require(results(second[2]).first)
        #expect(result.isError)
        let parsed = try JSONValue.parse(Data(result.text.utf8))
        #expect(parsed == ["INVALID_JSON": "{\"text\": \"unterminated}"])
    }

    @Test func inputThatFailsItsSchemaIsntRun() async throws {
        let (chat, api, tools) = chat([.sse("invalid-input.sse"), .sse("answer.sse")])
        chat.ask("Count to fifty")
        try await idle(chat)
        #expect(tools.ran.isEmpty)
        let found = results(api.bodies.last?["messages"]?.array?[2])
        #expect(found.map(\.id) == ["toolu_count", "toolu_words"])
        #expect(found.allSatisfy { $0.isError })
        #expect(found[0].text.contains("input.n is 50, above its most, 10."))
        #expect(found[1].text.contains("input is missing text."))
    }

    @Test func imagesGoBackNoLargerThanTheModelReads() async throws {
        let (chat, api, _) = chat([.sse("capture.sse"), .sse("answer.sse")])
        chat.ask("What does it look like?")
        try await idle(chat)
        let result = try #require(api.bodies.last?["messages"]?.array?[2]["content"]?.array?.first)
        let image = try #require(result["content"]?.array?.first)
        #expect(image["type"] == "image")
        #expect(image["source"]?["media_type"] == "image/png")
        let data = try #require(image["source"]?["data"]?.string.flatMap { Data(base64Encoded: $0) })
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let size = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(size[kCGImagePropertyPixelWidth] as? Int == 1568)
        #expect((1045...1046).contains(size[kCGImagePropertyPixelHeight] as? Int ?? 0))
        // The sidebar shows the picture as it was.
        guard case .png(let shown)? = calls(chat).first?.result?.content.first, let original = CGImageSourceCreateWithData(shown as CFData, nil),
              let shownSize = CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [CFString: Any] else {
            Issue.record("No picture")
            return
        }
        #expect(shownSize[kCGImagePropertyPixelWidth] as? Int == 3000)
    }

    // MARK: Safety

    @Test func changesAreAllowedFirst() async throws {
        let (chat, api, tools) = chat([.sse("change-call.sse"), .sse("answer.sse")])
        chat.ask("Drop the empty orders")
        try await until { chat.approval != nil }
        let approval = try #require(chat.approval)
        #expect(approval.asks == .change && approval.tool == "change")
        #expect(approval.headline == "Claude wants to use Change something.")
        #expect(calls(chat).first?.state == .waiting)
        #expect(chat.activity == .askingPerson)
        chat.decide(.deny)
        try await idle(chat)
        #expect(tools.ran["change"] == nil)
        #expect(calls(chat).first?.state == .notRun("You didn't allow it."))
        let answered = api.bodies.last?["messages"]?.array?[2]
        let refused = try #require(results(answered).first)
        #expect(refused.isError && refused.text.contains("didn't allow"))

        // Allowed for the conversation: it runs, and isn't asked about again.
        api.queue(.sse("change-call.sse"), .sse("answer.sse"))
        chat.ask("Please, go ahead")
        try await until { chat.approval != nil }
        chat.decide(.conversation)
        try await idle(chat)
        #expect(tools.ran["change"]?.count == 1)
        api.queue(.sse("change-call.sse"), .sse("answer.sse"))
        chat.ask("And again")
        try await idle(chat)
        #expect(tools.ran["change"]?.count == 2)
        #expect(chat.allowed == ["change"])

        // Starting over forgets it.
        chat.startOver()
        #expect(chat.allowed.isEmpty && chat.messages.isEmpty && chat.entries.isEmpty)
    }

    @Test(.simulatedHosts) func theRealChangingToolsAreAskedAbout() async throws {
        let viewer = try await TestViewer(slowly: true)
        defer { viewer.stop() }
        let registry = ContinuumTools.registry(for: viewer)
        #expect(registry.tools.filter { $0.asks == .change }.map(\.name).sorted() == ["inject_message", "propose_edits"])
        #expect(registry.tools.filter { $0.asks == .sendsMessages }.map(\.name) == ["sample_tap"])
        // show changes only the view, so it isn't asked about.
        #expect(registry.tool("show")?.asks == nil)
        let proposal = ClaudeChat.approval(1, tool: try #require(registry.tool("propose_edits")), asks: .change, input: [
            "address": "meep://sim/orders", "summary": "Drop empty orders", "edits": [["kind": "remove", "module": "m3"]],
        ])
        #expect(proposal.headline == "Claude wants to propose an edit to meep://sim/orders.")
        #expect(proposal.detail == "Drop empty orders")
        #expect(proposal.note.contains("Nothing changes unless you accept"))
        let offer = ClaudeChat.approval(2, tool: try #require(registry.tool("inject_message")), asks: .change, input: ["address": "meep://sim/orders/m1", "text": "hello"])
        #expect(offer.detail == "hello" && offer.note.contains("Nothing is sent unless you send it"))
    }

    @Test func theFirstTapSaysMessagesGoToTheAPI() async throws {
        let (chat, _, tools) = chat([.sse("peek-call.sse"), .sse("answer.sse")])
        chat.ask("What's in m2's messages?")
        try await until { chat.approval != nil }
        let approval = try #require(chat.approval)
        #expect(approval.asks == .sendsMessages)
        #expect(approval.headline == "Claude wants to tap meep://sim/orders/m2 and read its messages.")
        #expect(approval.note.contains("sent to Anthropic's API"))
        chat.decide(.once)
        try await idle(chat)
        #expect(tools.ran["peek"]?.count == 1)
    }

    // MARK: Stop reasons

    @Test func aRefusalIsShownAndItsQuestionTakenAway() async throws {
        let (chat, api, _) = chat([.sse("refusal.sse"), .sse("answer.sse")])
        chat.ask("Something it won't answer")
        try await idle(chat)
        // What came before the refusal is incomplete, so it's gone; the question stays on screen.
        #expect(replies(chat).isEmpty)
        let notice = try #require(notices(chat).last)
        #expect(notice.kind == .refusal)
        #expect(notice.title == "Claude declined to answer that (cyber).")
        #expect(notice.detail?.contains("could enable cyber harm") == true)
        #expect(chat.messages.isEmpty)
        chat.ask("Something else")
        try await idle(chat)
        let sent = try #require(api.bodies.last?["messages"]?.array)
        #expect(sent.count == 1)
        #expect(sent[0]["content"]?.array?.last?["text"] == "Something else")
    }

    @Test func aReplyCutShortRunsNoToolsAndTheNextQuestionJoinsItsAnswers() async throws {
        let (chat, api, tools) = chat([.sse("max-tokens.sse"), .sse("answer.sse")])
        chat.ask("Write a lot")
        try await idle(chat)
        #expect(tools.ran.isEmpty)
        #expect(notices(chat).last?.kind == .limit)
        #expect(calls(chat).first?.state == .notRun("The reply reached its length limit first."))
        #expect(chat.messages.map { $0["role"]?.string } == ["user", "assistant", "user"])
        chat.ask("Carry on, briefly")
        try await idle(chat)
        let sent = try #require(api.bodies.last?["messages"]?.array)
        #expect(sent.map { $0["role"]?.string } == ["user", "assistant", "user"])
        let joined = try #require(sent[2]["content"]?.array)
        #expect(joined.map { $0["type"]?.string } == ["tool_result", "text", "text"])
        #expect(joined.last?["text"] == "Carry on, briefly")
    }

    @Test func afterAFallbackOnlyWhatFollowsTheSwitchRunsAndGoesBackWhole() async throws {
        let (chat, api, tools) = chat([.sse("fallback-midstream.sse"), .sse("answer.sse")])
        chat.ask("Tap it")
        try await idle(chat)
        #expect(tools.ran["echo"] == [["text": "after"]])
        #expect(calls(chat).map(\.state) == [.notRun("Its model declined before it was finished; another carried on."), .finished])
        #expect(notices(chat).first?.kind == .switched)
        #expect(notices(chat).first?.title == "claude-opus-5-5 declined this, so claude-opus-4-8 carried on.")
        let echoed = try #require(api.bodies.last?["messages"]?.array?[1]["content"]?.array)
        #expect(echoed.map { $0["type"]?.string } == ["text", "fallback", "text", "tool_use"])
        #expect(echoed.last?["id"] == "toolu_after")
        let answered = results(api.bodies.last?["messages"]?.array?[2])
        #expect(answered.map(\.id) == ["toolu_after"])
    }

    @Test func aFallbackBeforeAnyOutputIsNoted() async throws {
        let (chat, _, _) = chat([.sse("fallback.sse")])
        chat.ask("Read the tap")
        try await idle(chat)
        #expect(notices(chat).map(\.kind) == [.switched])
        #expect(replies(chat) == ["Here's what the tap shows."])
        #expect(chat.messages.last?["content"]?.array?.first?["type"] == "fallback")
    }

    // MARK: Errors

    @Test(arguments: [
        (401, "authentication_error", ClaudeAPIError.Kind.refusedKey, Notice.Action.openSettings),
        (400, "invalid_request_error", .invalidRequest, .startOver),
        (402, "billing_error", .billing, .retry),
        (413, "request_too_large", .tooLarge, .startOver),
    ])
    func errorsAreShownWithWhatToDo(status: Int, type: String, kind: ClaudeAPIError.Kind, action: Notice.Action) async throws {
        let body = #"{"type":"error","error":{"type":"\#(type)","message":"Something specific."},"request_id":"req_x"}"#
        let (chat, api, _) = chat([.status(status, body: body)])
        chat.ask("Hello")
        try await idle(chat)
        #expect(api.requests.count == 1)
        let notice = try #require(notices(chat).last)
        #expect(notice.kind == .problem && notice.action == action)
        #expect(notice.detail?.contains("Something specific.") == true)
        #expect(ClaudeAPIError.from(status: status, headers: [:], body: Data(body.utf8)).kind == kind)
    }

    @Test func rateLimitsAndOverloadsAreTriedAgain() async throws {
        let overloaded = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        let limited = #"{"type":"error","error":{"type":"rate_limit_error","message":"Slow down"}}"#
        let (chat, api, _) = chat([.status(429, headers: ["retry-after": "0"], body: limited), .status(529, body: overloaded), .sse("answer.sse")])
        chat.ask("Hello")
        try await idle(chat)
        #expect(api.requests.count == 3)
        #expect(notices(chat).isEmpty)
        #expect(replies(chat).count == 1)
    }

    @Test func aRateLimitWithoutRetryAfterIsntWaitedOut() async throws {
        let spend = #"{"type":"error","error":{"type":"rate_limit_error","message":"Spend cap","details":{"error_code":"enforced_spend_limit_reached"}}}"#
        let (chat, api, _) = chat([.status(429, body: spend)])
        chat.ask("Hello")
        try await idle(chat)
        #expect(api.requests.count == 1)
        #expect(notices(chat).last?.title == "Your organization has reached its spend limit.")
    }

    @Test func anOverloadInTheStreamIsTriedAgainWithoutItsHalfReply() async throws {
        let (chat, api, _) = chat([.sse("overloaded.sse"), .sse("answer.sse")])
        chat.ask("Hello")
        try await idle(chat)
        #expect(api.requests.count == 2)
        #expect(replies(chat).count == 1 && !replies(chat)[0].hasPrefix("Half"))
    }

    @Test func aDroppedConnectionIsTriedAgainThenReported() async throws {
        let (chat, api, _) = chat([.failure(.networkConnectionLost), .failure(.networkConnectionLost), .failure(.networkConnectionLost)])
        chat.ask("Hello")
        try await idle(chat)
        #expect(api.requests.count == 3)
        let notice = try #require(notices(chat).last)
        #expect(notice.title == "Couldn't reach the Claude API." && notice.action == .retry)
        #expect(chat.canRetry)
        api.queue(.sse("answer.sse"))
        chat.retry()
        try await idle(chat)
        #expect(replies(chat).count == 1)
        #expect(chat.messages.count == 2)
    }

    @Test func aStreamThatEndsEarlyIsntTakenAsAReply() async throws {
        let (chat, _, _) = chat([.sse("partial.sse"), .sse("partial.sse"), .sse("partial.sse")])
        chat.ask("Hello")
        try await idle(chat)
        #expect(replies(chat).isEmpty)
        #expect(notices(chat).last?.title == "Couldn't reach the Claude API.")
        #expect(chat.messages.count == 1)
    }

    // MARK: Stopping

    @Test func stoppingKeepsWhatWasWritten() async throws {
        let (chat, api, _) = chat([.hang("partial.sse")])
        chat.ask("Tell me everything")
        try await until { !replies(chat).isEmpty }
        chat.stop()
        try await idle(chat)
        #expect(replies(chat) == ["The first half of an answer"])
        #expect(notices(chat).last?.kind == .stopped)
        #expect(chat.messages.last == ["role": "assistant", "content": [["type": "text", "text": "The first half of an answer"]]])
        // The next question says so, and follows on.
        api.queue(.sse("answer.sse"))
        chat.ask("Shorter, please")
        try await idle(chat)
        let sent = try #require(api.bodies.last?["messages"]?.array)
        #expect(sent.map { $0["role"]?.string } == ["user", "assistant", "user"])
        #expect(sent[2]["content"]?.array?.first?["text"]?.string?.hasPrefix("[The person stopped your previous reply before it finished.]") == true)
    }

    @Test func stoppingARunningToolAnswersItsCall() async throws {
        let (chat, api, tools) = chat([.sse("slow-call.sse")])
        chat.ask("Wait")
        try await until { tools.ran["slow"] != nil }
        chat.stop()
        try await idle(chat)
        #expect(chat.messages.map { $0["role"]?.string } == ["user", "assistant", "user"])
        let result = try #require(results(chat.messages.last).first)
        #expect(result.id == "toolu_slow" && result.isError && result.text == "Cancelled.")
        #expect(api.requests.count == 1)
        api.queue(.sse("answer.sse"))
        chat.ask("Never mind")
        try await idle(chat)
        let joined = try #require(api.bodies.last?["messages"]?.array?[2]["content"]?.array)
        #expect(joined.first?["type"] == "tool_result" && joined.last?["text"] == "Never mind")
    }

    @Test func stoppingWhileAskingAnswersTheCall() async throws {
        let (chat, _, tools) = chat([.sse("change-call.sse")])
        chat.ask("Change it")
        try await until { chat.approval != nil }
        chat.stop()
        try await idle(chat)
        #expect(chat.approval == nil)
        #expect(tools.ran.isEmpty)
        let answered = results(chat.messages.last)
        #expect(answered.first?.text == "Not run: the person stopped Claude first.")
    }

    // MARK: Context and links

    @Test(.simulatedHosts) func eachQuestionCarriesTheFocusAndSelection() async throws {
        let viewer = try await TestViewer(slowly: true)
        defer { viewer.stop() }
        viewer.select(MeepAddress("meep://sim/orders"))
        let stage = try #require(viewer.stage)
        stage.select(["m2"], reveal: false)
        let context = SidebarPrompt.context(viewer)
        #expect(context.contains("meep://sim/orders"))
        #expect(context.contains("Selected in the list of hosts: meep://sim/orders."))
        #expect(context.contains("Selected on the canvas: meep://sim/orders/m2"))
        #expect(context.hasPrefix("[") && context.hasSuffix("]"))
    }

    @Test(.simulatedHosts) func modulesAndLinksAreNamedAsTheCanvasNamesThem() async throws {
        let viewer = try await TestViewer(slowly: true)
        defer { viewer.stop() }
        let result = try #require(await ContinuumTools.registry(for: viewer).call("describe_pipeline", arguments: ["address": "meep://sim/orders"]))
        guard case .text(let text)? = result.content.first else { Issue.record("No text"); return }
        let described = try JSONValue.parse(Data(text.utf8))
        let modules = try #require(described["modules"]?.array)
        let labels = Dictionary(uniqueKeysWithValues: modules.compactMap { module in module["key"]?.string.map { ($0, module["label"]?.string ?? "") } })
        let link = try #require(described["links"]?.array?.first)
        let from = try #require(link["from"]?.string), to = try #require(link["to"]?.string)
        #expect(link["named"]?.string == "\(labels[from] ?? "") → \(labels[to] ?? "")")
        #expect(SidebarPrompt.system.contains("never its key"))
    }

    @Test func aLinkShowsItsAddressWithTheShowTool() async throws {
        let (chat, _, tools) = chat([])
        await chat.show("meep://sim/orders/m2")
        #expect(tools.ran["show"] == [["address": "meep://sim/orders/m2"]])
    }

    // MARK: Helpers

    static func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

/// Server-sent events, read as the API sends them.
struct SSEParserTests {
    @Test func eventsAreReadWhereverChunksEnd() {
        let text = "event: a\ndata: {\"x\":\"é—1\"}\n\n: a comment\n\nevent: b\r\ndata: line one\r\ndata: line two\r\n\r\ndata: no name\n\n"
        let bytes = Array(text.utf8)
        for size in [1, 2, 3, 7, 1000] {
            var parser = SSEParser()
            var events: [ServerSentEvent] = []
            var offset = 0
            while offset < bytes.count {
                events += parser.feed(Data(bytes[offset..<min(offset + size, bytes.count)]))
                offset += size
            }
            events += parser.finish()
            #expect(events == [
                ServerSentEvent(event: "a", data: "{\"x\":\"é—1\"}"),
                ServerSentEvent(event: "b", data: "line one\nline two"),
                ServerSentEvent(event: nil, data: "no name"),
            ], "in chunks of \(size)")
        }
    }

    @Test func anEventTheStreamEndsInIsKept() {
        var parser = SSEParser()
        #expect(parser.feed(Data("event: last\ndata: {}".utf8)).isEmpty)
        #expect(parser.finish() == [ServerSentEvent(event: "last", data: "{}")])
    }
}

/// Tools' input checked against their schemas.
struct SchemaCheckTests {
    let schema: JSONValue = [
        "type": "object",
        "properties": [
            "address": ["type": "string"],
            "seconds": ["type": "number", "minimum": 1, "maximum": 30],
            "limit": ["type": "integer"],
            "sample": ["type": "number", "exclusiveMinimum": 0, "maximum": 1],
            "edits": ["type": "array", "minItems": 1, "items": ["type": "object", "properties": ["kind": ["type": "string", "enum": ["set", "add"]]], "required": ["kind"]]],
            "json": ["description": "Anything"],
        ],
        "required": ["address"],
    ]

    @Test func inputThatFitsHasNoProblem() {
        #expect(SchemaCheck.problem(with: ["address": "a", "seconds": 5, "limit": 3, "sample": 0.5, "edits": [["kind": "add"]], "json": [1, "x"]], against: schema) == nil)
        #expect(SchemaCheck.problem(with: ["address": "a", "other": true], against: schema) == nil)
    }

    @Test func eachProblemSaysWhere() {
        #expect(SchemaCheck.problem(with: [:], against: schema) == "input is missing address.")
        #expect(SchemaCheck.problem(with: ["address": 3], against: schema) == "input.address should be a string, not 3.")
        #expect(SchemaCheck.problem(with: ["address": "a", "seconds": 60], against: schema) == "input.seconds is 60, above its most, 30.")
        #expect(SchemaCheck.problem(with: ["address": "a", "limit": 2.5], against: schema) == "input.limit should be an integer, not 2.5.")
        #expect(SchemaCheck.problem(with: ["address": "a", "sample": 0], against: schema) == "input.sample must be more than 0.")
        #expect(SchemaCheck.problem(with: ["address": "a", "edits": []], against: schema) == "input.edits needs at least 1 item.")
        #expect(SchemaCheck.problem(with: ["address": "a", "edits": [["kind": "drop"]]], against: schema) == "input.edits[0].kind is \"drop\", but must be one of: set, add.")
        #expect(SchemaCheck.problem(with: "text", against: schema) == "input should be an object, not \"text\".")
        let closed: JSONValue = ["type": "object", "properties": ["a": ["type": "string"]], "additionalProperties": false]
        #expect(SchemaCheck.problem(with: ["b": 1], against: closed) == "input has b, which isn't one of its properties (a).")
    }

    @Test @MainActor func everyToolsSchemaAcceptsWhatItsDescriptionsSuggest() async throws {
        let viewer = try await TestViewer(slowly: true)
        defer { viewer.stop() }
        let registry = ContinuumTools.registry(for: viewer)
        let good: [String: JSONValue] = [
            "list_continuum": [:],
            "describe_pipeline": ["address": "meep://sim/orders"],
            "watch_counts": ["address": "meep://sim/orders", "seconds": 3],
            "show": ["address": "meep://sim/orders/m2"],
            "sample_tap": ["address": "meep://sim/orders/m2", "where": "msg is ErrorMessage", "sample": 0.5, "seconds": 5, "limit": 20],
            "inject_message": ["address": "meep://sim/orders/m1", "json": ["n": 1]],
            "propose_edits": ["address": "meep://sim/orders", "summary": "Gate", "edits": [["kind": "add", "module": "m2", "value": "Where msg.Count > 2 as Gate"]]],
        ]
        for (name, input) in good {
            let tool = try #require(registry.tool(name))
            #expect(SchemaCheck.problem(with: input, against: tool.inputSchema) == nil, "\(name)")
        }
    }
}

/// The reply as it's sent back.
struct ClaudeReplyTests {
    @Test func emptyTextIsLeftOutAndThinkingGoesBackSigned() throws {
        var reply = ClaudeReply()
        let events: [JSONValue] = [
            ["type": "message_start", "message": ["id": "m", "model": "claude-opus-5-5", "usage": ["input_tokens": 5]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "abc"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_stop", "index": 1],
            ["type": "content_block_start", "index": 2, "content_block": ["type": "redacted_thinking", "data": "xyz"]],
            ["type": "content_block_stop", "index": 2],
            ["type": "content_block_delta", "index": 2, "delta": ["type": "some_new_delta", "x": 1]],
            ["type": "something_new"],
            ["type": "message_delta", "delta": ["stop_reason": "end_turn", "stop_details": nil], "usage": ["output_tokens": 9]],
            ["type": "message_stop"],
        ]
        for event in events { _ = try reply.apply(event) }
        #expect(reply.isFinished && reply.stopReason == "end_turn" && reply.stopDetails == nil)
        #expect(reply.echo == [
            ["type": "thinking", "thinking": "", "signature": "abc"],
            ["type": "redacted_thinking", "data": "xyz"],
        ])
        #expect(reply.usage == ["input_tokens": 5, "output_tokens": 9])
    }

    @Test func anErrorEventIsThrown() {
        var reply = ClaudeReply()
        #expect(throws: ClaudeAPIError.self) {
            try reply.apply(["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]])
        }
    }
}
