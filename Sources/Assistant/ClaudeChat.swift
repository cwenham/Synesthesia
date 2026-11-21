import CoreGraphics
import Foundation
import ImageIO
import MeepClient
import Observation
import UniformTypeIdentifiers

/// One thing shown in the sidebar's conversation. Its kind changes as a reply streams in, so only it is drawn again.
@MainActor @Observable
public final class ChatEntry: Identifiable {
    public let id: Int
    public internal(set) var kind: Kind
    /// The reply it came from, so a declined or failed reply's entries can be taken away.
    @ObservationIgnored var reply: String?

    init(id: Int, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public enum Kind: Equatable, Sendable {
        /// The person's question.
        case question(String)
        /// Claude's reply, as Markdown.
        case reply(String)
        /// A summary of Claude's thinking, or a note between tool calls.
        case thinking(String)
        case tool(ToolCall)
        case notice(Notice)
    }
}

/// A tool call as the sidebar shows it: its input as it's written, then whether it ran and what it gave.
public struct ToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    public var title: String
    /// The input as it streamed in.
    public var json: String
    /// The input once it's complete and parsed, if it parsed.
    public var input: JSONValue?
    public var state: State
    public var result: ToolResult?

    public enum State: Equatable, Sendable {
        case writing
        /// Waiting for the person to allow it.
        case waiting
        case running
        case finished
        /// It ran and said it failed, or its input was wrong.
        case failed(String?)
        /// It didn't run, and why.
        case notRun(String)
    }

    /// The address it's about, as soon as the input names one.
    public var address: String? {
        if let address = input?["address"]?.string { return address }
        guard let match = json.firstMatch(of: /"address"\s*:\s*"([^"\\]*)/), !match.1.isEmpty else { return nil }
        return String(match.1)
    }
}

/// Something the sidebar says about the conversation rather than Claude: a refusal, a limit, a problem, a stop.
public struct Notice: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case refusal, limit, problem, stopped, switched
    }

    /// What the person can do about it, as a button.
    public enum Action: Equatable, Sendable {
        case openSettings, retry, startOver
    }

    public var kind: Kind
    public var title: String
    public var detail: String?
    public var action: Action?
}

/// A tool waiting for the person to allow it (design, section 8: safety).
public struct Approval: Identifiable, Equatable, Sendable {
    public let id: Int
    public let tool: String
    public let asks: Tool.Asks
    /// What Claude wants to do, in a sentence.
    public let headline: String
    /// What it gave: a proposal's summary, a message, a tap's condition.
    public let detail: String?
    /// What allowing it does, and doesn't.
    public let note: String

    public enum Decision: Equatable, Sendable {
        case once
        /// Allows this tool, or taps, until the conversation starts over.
        case conversation
        case deny
    }
}

/// What the sidebar is doing, for its status line.
public enum ChatActivity: Equatable, Sendable {
    case idle
    /// The request is sent; nothing has come back yet.
    case waiting
    case thinking
    case writing
    case writingTool(String)
    case running(String)
    case askingPerson
    case retrying(seconds: Int, why: String)
}

/// Tokens a conversation has used, from each reply's `usage`.
public struct ChatUsage: Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var requests = 0
}

/// The Claude sidebar's conversation, and its loop of requests and tools (design, section 8). Each question goes with
/// the app's note of what the person is looking at; each reply streams in, and the tools it calls are the same ones
/// the MCP server offers, run here, with those that go beyond looking allowed by the person first.
///
/// The transcript the API sees only ever grows, so the cache and Claude's thinking stay valid from one request to the
/// next. The one thing changed in place is an unanswered question at its end, which a new question joins, or which a
/// refusal takes away.
@MainActor @Observable
public final class ClaudeChat {
    public private(set) var entries: [ChatEntry] = []
    public private(set) var activity: ChatActivity = .idle
    public private(set) var isBusy = false
    /// A tool waiting for the person's answer.
    public private(set) var approval: Approval?
    /// Tools allowed for this conversation, by name.
    public private(set) var allowed: Set<String> = []
    /// Whether the last request failed in a way trying again might mend.
    public private(set) var canRetry = false
    public private(set) var usage = ChatUsage()
    public var effort: Effort = .medium
    public let key: ClaudeKey
    public let registry: ToolRegistry

    @ObservationIgnored private let transport: any HTTPStreaming
    @ObservationIgnored private let context: @MainActor () -> String?
    @ObservationIgnored private let system: String
    /// The conversation as the API sees it.
    @ObservationIgnored public private(set) var messages: [JSONValue] = []
    /// The latest reply's report of thinking dropped after a change to the history, which should never happen.
    @ObservationIgnored public private(set) var dropped: [JSONValue] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastID = 0
    @ObservationIgnored private var deciding: (id: Int, continuation: CheckedContinuation<Approval.Decision?, Never>)?
    @ObservationIgnored private var stoppedLast = false
    /// How many requests one question can take before the sidebar stops it.
    @ObservationIgnored public var limit = 40
    /// How many times a request is tried again on its own, after a rate limit, an overload or a dropped connection.
    @ObservationIgnored public var retries = 2
    /// How long to wait before trying again, when the API doesn't say: 1, 2, 4… seconds.
    @ObservationIgnored public var backoff: @Sendable (Int) -> Duration = { attempt in .seconds(1 << min(attempt, 5)) }

    public init(
        registry: ToolRegistry, key: ClaudeKey, transport: any HTTPStreaming = URLSessionStreaming(),
        system: String = SidebarPrompt.system, context: @escaping @MainActor () -> String? = { nil }
    ) {
        self.registry = registry
        self.key = key
        self.transport = transport
        self.system = system
        self.context = context
    }

    // MARK: What the person does

    /// Asks a question, with the app's note of what's on screen.
    public func ask(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        add(.question(text))
        var note = context() ?? ""
        if stoppedLast {
            note = "[The person stopped your previous reply before it finished.]" + (note.isEmpty ? "" : " " + note)
            stoppedLast = false
        }
        var blocks: [JSONValue] = []
        if !note.isEmpty { blocks.append(["type": "text", "text": .string(note)]) }
        blocks.append(["type": "text", "text": .string(text)])
        // A question no reply answered, or tool results never sent, is joined rather than followed: roles alternate.
        if let last = messages.last, last["role"] == "user", let earlier = last["content"]?.array {
            messages[messages.count - 1] = ["role": "user", "content": .array(earlier + blocks)]
        } else {
            messages.append(["role": "user", "content": .array(blocks)])
        }
        start()
    }

    /// Sends the conversation again after a problem, as it was.
    public func retry() {
        guard !isBusy, messages.last?["role"] == "user" else { return }
        start()
    }

    /// Stops the reply or the tool that's running. What Claude wrote so far stays.
    public func stop() {
        task?.cancel()
        resolve(nil)
    }

    /// The person's answer to the tool waiting for it.
    public func decide(_ decision: Approval.Decision) {
        resolve(decision)
    }

    /// Clears the conversation, and what was allowed in it. A reply that's running is stopped first, and the
    /// conversation cleared once it has, so nothing of it lands in the new one.
    public func startOver() {
        guard let running = task else {
            clear()
            return
        }
        stop()
        Task { [weak self] in
            await running.value
            self?.clear()
        }
    }

    private func clear() {
        entries = []
        messages = []
        allowed = []
        usage = ChatUsage()
        approval = nil
        canRetry = false
        stoppedLast = false
        isBusy = false
        activity = .idle
    }

    /// Points the app at an address, as a link in a reply does, with the same tool Claude uses.
    public func show(_ address: String) async {
        _ = await registry.call("show", arguments: ["address": .string(address)])
    }

    // MARK: The loop

    private func start() {
        canRetry = false
        isBusy = true
        activity = .waiting
        task = Task { [weak self] in
            await self?.converse()
            self?.finished()
        }
    }

    private func finished() {
        task = nil
        isBusy = false
        approval = nil
        activity = .idle
    }

    private func converse() async {
        var requests = 0
        while !Task.isCancelled {
            requests += 1
            guard requests <= limit else {
                note(.limit, "Claude made \(limit) requests for this question without finishing, so it was stopped.",
                     "Ask it to carry on, or ask something narrower.")
                return
            }
            guard let reply = await request() else { return }
            guard await settle(reply) else { return }
        }
    }

    /// Sends the conversation and streams the reply, trying again on its own after a rate limit, an overload or a
    /// dropped connection. Nil if it failed or was stopped, having said so.
    private func request() async -> ClaudeReply? {
        guard let apiKey = key.value() else {
            canRetry = true
            note(.problem, "Claude needs your Anthropic API key.",
                 key.problem ?? "Add it in Settings, under Claude. It's kept in your Keychain, and sent only to Anthropic's API.",
                 action: .openSettings)
            return nil
        }
        let body = ClaudeAPI.body(system: system, tools: registry.tools, messages: messages, effort: effort)
        let request = ClaudeAPI.request(body: body, key: apiKey)
        var attempt = 0
        while true {
            activity = .waiting
            let streaming = StreamingReply(chat: self)
            do {
                try await stream(request, into: streaming)
                count(streaming.reply)
                return streaming.reply
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    stopped(streaming)
                    return nil
                }
                let failure = (error as? ClaudeAPIError) ?? ClaudeAPIError(kind: .network, message: error.localizedDescription)
                streaming.discard()
                if failure.isRetryable, attempt < retries {
                    attempt += 1
                    let wait: Duration = if case .rateLimited(let after?) = failure.kind { .seconds(after) } else { backoff(attempt) }
                    activity = .retrying(seconds: Int(wait.components.seconds), why: Self.retryReason(failure))
                    do {
                        try await Task.sleep(for: wait)
                    } catch {
                        stopped(nil)
                        return nil
                    }
                    continue
                }
                if failure.kind == .refusedKey { key.forget() }
                report(failure)
                return nil
            }
        }
    }

    private func stream(_ request: URLRequest, into streaming: StreamingReply) async throws {
        let response = try await transport.open(request)
        let requestID = response.headers["request-id"]
        guard response.status == 200 else {
            let data = try await response.collect()
            throw ClaudeAPIError.from(status: response.status, headers: response.headers, body: data)
        }
        var parser = SSEParser()
        for try await chunk in response.body {
            try Task.checkCancellation()
            for event in parser.feed(chunk) { try streaming.take(event, requestID: requestID) }
        }
        for event in parser.finish() { try streaming.take(event, requestID: requestID) }
        try Task.checkCancellation()
        guard streaming.reply.isFinished else {
            throw ClaudeAPIError(kind: .network, message: "The reply stopped coming before it finished.", requestID: requestID)
        }
    }

    /// What to do with a reply that finished: run its tools and carry on, or end the turn. True to carry on.
    private func settle(_ reply: ClaudeReply) async -> Bool {
        dropped = reply.inputTransformations
        let echo = reply.echo
        // Calls written before a switch to a fallback model aren't sent back, so they aren't run.
        let answerable = Set(reply.toolCalls.map(\.toolID))
        for block in reply.blocks where !block.toolID.isEmpty && !answerable.contains(block.toolID) {
            update(block.toolID) { $0.state = .notRun("Its model declined before it was finished; another carried on.") }
        }
        switch reply.stopReason {
        case "refusal":
            // What came before the refusal is incomplete: it's taken away, with the question that was declined.
            if let id = reply.id { entries.removeAll { $0.reply == id } }
            withdrawQuestion()
            let category = reply.stopDetails?["category"]?.string
            let explanation = reply.stopDetails?["explanation"]?.string
            note(.refusal, "Claude declined to answer that\(category.map { " (\($0))" } ?? "").",
                 [explanation, "Try asking another way. If it keeps happening, start a new conversation."].compactMap { $0 }.joined(separator: " "))
            return false
        case "tool_use":
            let calls = reply.toolCalls
            guard !echo.isEmpty else { return false }
            messages.append(["role": "assistant", "content": .array(echo)])
            guard !calls.isEmpty else { return false }
            let results = await answer(calls)
            messages.append(["role": "user", "content": .array(results)])
            if Task.isCancelled {
                note(.stopped, "Stopped.", nil)
                return false
            }
            return true
        case "max_tokens", "model_context_window_exceeded":
            if !echo.isEmpty { messages.append(["role": "assistant", "content": .array(echo)]) }
            // A call whose input may be cut short isn't run, but it's answered, so the conversation can go on.
            let calls = reply.toolCalls
            if !echo.isEmpty, !calls.isEmpty {
                let why = "Not run: the reply reached its length limit, so this call's input may be incomplete."
                messages.append(["role": "user", "content": .array(calls.map { Self.failure($0.toolID, why) })])
                for call in calls { update(call.toolID) { $0.state = .notRun("The reply reached its length limit first.") } }
            }
            if reply.stopReason == "max_tokens" {
                note(.limit, "Claude's reply reached its limit of \(ClaudeAPI.maxTokens.formatted()) tokens before it finished.",
                     "Ask it to carry on, or to answer more briefly.")
            } else {
                note(.limit, "This conversation is too long for Claude to carry on.", "Start a new conversation.", action: .startOver)
            }
            return false
        default:
            // end_turn, and anything newer that ends a turn.
            if !echo.isEmpty { messages.append(["role": "assistant", "content": .array(echo)]) }
            return false
        }
    }

    /// Answers each tool call in turn: checked, allowed by the person if it needs to be, then run. Every call gets a
    /// result, even when it's stopped, so the conversation stays whole.
    private func answer(_ calls: [ClaudeReply.Block]) async -> [JSONValue] {
        var results: [JSONValue] = []
        for call in calls {
            guard case .toolUse(let id, let name, let json, let input) = call.kind else { continue }
            if Task.isCancelled {
                update(id) { $0.state = .notRun("Stopped.") }
                results.append(Self.failure(id, "Not run: the person stopped Claude first."))
                continue
            }
            guard let input else {
                update(id) { $0.state = .failed("Its input wasn't JSON.") }
                results.append(Self.failure(id, (["INVALID_JSON": .string(json)] as JSONValue).text()))
                continue
            }
            guard let tool = registry.tool(name) else {
                update(id) { $0.state = .failed("There's no such tool.") }
                results.append(Self.failure(id, "There's no tool called \(name). The tools are: \(registry.tools.map(\.name).joined(separator: ", "))."))
                continue
            }
            if let problem = SchemaCheck.problem(with: input, against: tool.inputSchema) {
                update(id) { $0.state = .failed(problem) }
                results.append(Self.failure(id, (["INVALID_JSON": .string(json), "problem": .string(problem)] as JSONValue).text()))
                continue
            }
            if let asks = tool.asks, !allowed.contains(name) {
                update(id) { $0.state = .waiting }
                switch await approve(tool, asks: asks, input: input) {
                case .once?:
                    break
                case .conversation?:
                    allowed.insert(name)
                case .deny?:
                    update(id) { $0.state = .notRun("You didn't allow it.") }
                    results.append(Self.failure(id, "Not run: the person didn't allow it. Ask them before trying it again."))
                    continue
                case nil:
                    update(id) { $0.state = .notRun("Stopped.") }
                    results.append(Self.failure(id, "Not run: the person stopped Claude first."))
                    continue
                }
            }
            update(id) { $0.state = .running }
            activity = .running(tool.title)
            let result = await registry.call(name, arguments: input) ?? .failure("There's no tool called \(name).")
            update(id) {
                $0.result = result
                $0.state = result.isError ? .failed(nil) : .finished
            }
            results.append(Self.result(id, result))
        }
        return results
    }

    /// Asks the person whether a tool may run, and waits. Nil if Claude was stopped first.
    private func approve(_ tool: Tool, asks: Tool.Asks, input: JSONValue) async -> Approval.Decision? {
        lastID += 1
        let request = Self.approval(lastID, tool: tool, asks: asks, input: input)
        approval = request
        activity = .askingPerson
        let decision = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Approval.Decision?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    deciding = (request.id, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(nil) }
        }
        approval = nil
        return decision
    }

    private func resolve(_ decision: Approval.Decision?) {
        guard let waiting = deciding else { return }
        deciding = nil
        waiting.continuation.resume(returning: decision)
    }

    // MARK: Endings

    /// A reply stopped by the person: the text written so far stays, as Claude's turn, so the next question follows it.
    private func stopped(_ streaming: StreamingReply?) {
        if let streaming {
            let text = streaming.reply.textSoFar
            if !text.isEmpty { messages.append(["role": "assistant", "content": .array(text)]) }
            for block in streaming.reply.blocks {
                if case .toolUse(let id, _, _, _) = block.kind { update(id) { $0.state = .notRun("Stopped.") } }
            }
            stoppedLast = true
        }
        note(.stopped, "Stopped.", nil)
    }

    /// Takes away the question a refusal declined, keeping any tool results it was sent with.
    private func withdrawQuestion() {
        guard let last = messages.last, last["role"] == "user", let content = last["content"]?.array else { return }
        let kept = content.filter { $0["type"] == "tool_result" }
        if kept.isEmpty {
            messages.removeLast()
        } else {
            messages[messages.count - 1] = ["role": "user", "content": .array(kept)]
        }
    }

    private func report(_ failure: ClaudeAPIError) {
        let id = failure.requestID.map { " Request \($0)." } ?? ""
        let message = failure.message.map { " The API said: “\($0)”" } ?? ""
        switch failure.kind {
        case .missingKey:
            note(.problem, "Claude needs your Anthropic API key.", "Add it in Settings, under Claude.", action: .openSettings)
        case .refusedKey:
            note(.problem, "The Claude API didn't accept your key.",
                 "Check it in Settings, under Claude, or make a new one in the Claude Console at platform.claude.com.\(message)", action: .openSettings)
        case .permission:
            note(.problem, "Your key isn't allowed to do this.",
                 "Check your organization's access and workspace in the Claude Console.\(message)\(id)")
        case .billing:
            note(.problem, "There's a billing problem with your Anthropic account.",
                 "Check your payment details in the Claude Console, then try again.\(message)", action: .retry)
        case .notFound:
            note(.problem, "\(ClaudeAPI.model) isn't available to your key.",
                 "Check which models your organization can use in the Claude Console.\(message)\(id)")
        case .tooLarge:
            note(.problem, "This conversation is too large to send.", "Start a new conversation.\(message)\(id)", action: .startOver)
        case .rateLimited:
            note(.problem, "The Claude API is limiting how fast your key can ask.",
                 "Wait a minute, then try again.\(message)\(id)", action: .retry)
        case .spendLimit:
            note(.problem, "Your organization has reached its spend limit.",
                 "It needs raising in the Claude Console before Claude can answer.\(message)\(id)", action: .retry)
        case .overloaded:
            note(.problem, "Anthropic's API is overloaded.", "Try again in a moment.\(id)", action: .retry)
        case .server:
            note(.problem, "Anthropic's API had a problem.", "Try again in a moment.\(message)\(id)", action: .retry)
        case .invalidRequest:
            note(.problem, "The Claude API refused the request.",
                 "This is likely a mistake in Synesthesia. Starting a new conversation may get past it.\(message)\(id)", action: .startOver)
        case .network:
            note(.problem, "Couldn't reach the Claude API.",
                 "Check your connection, then try again.\(failure.message.map { " (\($0))" } ?? "")", action: .retry)
        case .unexpected:
            note(.problem, "The Claude API answered with something unexpected\(failure.status.map { " (HTTP \($0))" } ?? "").",
                 "Try again.\(message)\(id)", action: .retry)
        }
        canRetry = messages.last?["role"] == "user"
    }

    private static func retryReason(_ failure: ClaudeAPIError) -> String {
        switch failure.kind {
        case .rateLimited: "rate limited"
        case .overloaded: "the API is overloaded"
        case .network: "the connection dropped"
        default: "the API had a problem"
        }
    }

    // MARK: Entries

    @discardableResult
    func add(_ kind: ChatEntry.Kind, reply: String? = nil) -> ChatEntry {
        lastID += 1
        let entry = ChatEntry(id: lastID, kind: kind)
        entry.reply = reply
        entries.append(entry)
        return entry
    }

    func remove(_ entry: ChatEntry) {
        entries.removeAll { $0 === entry }
    }

    func set(_ activity: ChatActivity) {
        if self.activity != activity { self.activity = activity }
    }

    private func note(_ kind: Notice.Kind, _ title: String, _ detail: String?, action: Notice.Action? = nil) {
        add(.notice(Notice(kind: kind, title: title, detail: detail, action: action)))
    }

    /// Changes the tool call with this id where it's shown.
    private func update(_ id: String, _ change: (inout ToolCall) -> Void) {
        for entry in entries.reversed() {
            guard case .tool(var call) = entry.kind, call.id == id else { continue }
            change(&call)
            entry.kind = .tool(call)
            return
        }
    }

    private func count(_ reply: ClaudeReply) {
        let figures = reply.usage
        usage.requests += 1
        usage.input += Int(figures["input_tokens"]?.number ?? 0)
        usage.output += Int(figures["output_tokens"]?.number ?? 0)
        usage.cacheRead += Int(figures["cache_read_input_tokens"]?.number ?? 0)
        usage.cacheWrite += Int(figures["cache_creation_input_tokens"]?.number ?? 0)
    }

    // MARK: Results and approvals

    static func failure(_ id: String, _ text: String) -> JSONValue {
        ["type": "tool_result", "tool_use_id": .string(id), "content": [["type": "text", "text": .string(text)]], "is_error": true]
    }

    /// A tool's result as the API takes it: text, and images no larger than the model reads.
    static func result(_ id: String, _ result: ToolResult) -> JSONValue {
        var blocks: [JSONValue] = result.content.map { content in
            switch content {
            case .text(let text):
                return ["type": "text", "text": .string(text.isEmpty ? "(empty)" : text)]
            case .png(let data):
                return ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": .string(fitted(data).base64EncodedString())]]
            }
        }
        if blocks.isEmpty { blocks = [["type": "text", "text": "(no output)"]] }
        var entry: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(id), "content": .array(blocks)]
        if result.isError { entry["is_error"] = true }
        return .object(entry)
    }

    /// A PNG scaled down so its longest side is at most `longest` pixels, as the model reads images no larger.
    static func fitted(_ png: Data, longest: Int = 1568) -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > longest else { return png }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: longest,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return png }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return png }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return png }
        return data as Data
    }

    static func approval(_ id: Int, tool: Tool, asks: Tool.Asks, input: JSONValue) -> Approval {
        let address = input["address"]?.string ?? "a module"
        switch (tool.name, asks) {
        case ("propose_edits", _):
            let count = input["edits"]?.array?.count ?? 0
            return Approval(
                id: id, tool: tool.name, asks: asks,
                headline: "Claude wants to propose \(count == 1 ? "an edit" : "\(count) edits") to \(address).",
                detail: input["summary"]?.string,
                note: "If you allow it, the edits show on the canvas and beside the text. Nothing changes unless you accept them there."
            )
        case ("inject_message", _):
            let body = input["text"]?.string ?? input["json"].map { $0.text(pretty: true) }
            return Approval(
                id: id, tool: tool.name, asks: asks,
                headline: "Claude wants to offer a message to send into \(address).",
                detail: body.map { $0.count > 400 ? String($0.prefix(400)) + "…" : $0 },
                note: "If you allow it, the message opens in the composer. Nothing is sent unless you send it."
            )
        case (_, .sendsMessages):
            var parts: [String] = []
            if let condition = input["where"]?.string { parts.append("Where \(condition)") }
            if let sample = input["sample"]?.number { parts.append("a sample of \(Int(sample * 100))%") }
            if let seconds = input["seconds"]?.number { parts.append("for \(Int(seconds)) s") }
            return Approval(
                id: id, tool: tool.name, asks: asks,
                headline: "Claude wants to tap \(address) and read its messages.",
                detail: parts.isEmpty ? nil : parts.joined(separator: ", "),
                note: "Tapped messages are real message contents. They'll be sent to Anthropic's API as part of this conversation."
            )
        case (_, .change):
            return Approval(
                id: id, tool: tool.name, asks: asks, headline: "Claude wants to use \(tool.title).", detail: input.text(pretty: true),
                note: "It goes beyond looking at what's running."
            )
        }
    }
}

extension ClaudeReply.Block {
    var toolID: String {
        if case .toolUse(let id, _, _, _) = kind { return id }
        return ""
    }
}

/// A reply as it streams into the sidebar: the entries it has made so far, kept up to date with each event.
@MainActor
final class StreamingReply {
    private unowned let chat: ClaudeChat
    private(set) var reply = ClaudeReply()
    /// The entry made for each block, by index.
    private var made: [Int: ChatEntry] = [:]
    /// A name for this reply's entries until the API names it.
    private let tag = UUID().uuidString

    init(chat: ClaudeChat) {
        self.chat = chat
    }

    func take(_ event: ServerSentEvent, requestID: String?) throws {
        guard event.event != "ping", !event.data.isEmpty, let json = try? JSONValue.parse(Data(event.data.utf8)) else { return }
        let change: ClaudeReply.Change
        do {
            change = try reply.apply(json)
        } catch var failure as ClaudeAPIError {
            failure.requestID = failure.requestID ?? requestID
            throw failure
        }
        switch change {
        case .started(let index), .grew(let index), .finished(let index):
            show(index)
        case .message, .none:
            break
        }
    }

    /// Makes or brings up to date the entry for a block.
    private func show(_ index: Int) {
        guard let block = reply.block(index) else { return }
        let id = reply.id ?? tag
        switch block.kind {
        case .text(let text):
            chat.set(.writing)
            guard !text.isEmpty else { return }
            if let entry = made[index] { entry.kind = .reply(text) } else { made[index] = chat.add(.reply(text), reply: id) }
        case .thinking(let text, _):
            chat.set(.thinking)
            guard !text.isEmpty else { return }
            if let entry = made[index] { entry.kind = .thinking(text) } else { made[index] = chat.add(.thinking(text), reply: id) }
        case .toolUse(let callID, let name, let json, let input):
            let title = chat.registry.tool(name)?.title ?? name
            chat.set(.writingTool(title))
            if let entry = made[index], case .tool(var call) = entry.kind {
                call.json = json
                call.input = input
                if block.isComplete, input == nil { call.state = .failed("Its input wasn't JSON.") }
                entry.kind = .tool(call)
            } else {
                made[index] = chat.add(.tool(ToolCall(id: callID, name: name, title: title, json: json, input: input, state: .writing)), reply: id)
            }
        case .fallback(let raw):
            guard made[index] == nil else { return }
            let from = raw["from"]?["model"]?.string ?? ClaudeAPI.model
            let to = raw["to"]?["model"]?.string ?? "another model"
            let category = raw["trigger"]?["category"]?.string
            made[index] = chat.add(.notice(Notice(
                kind: .switched, title: "\(from) declined this\(category.map { " (\($0))" } ?? ""), so \(to) carried on.",
                detail: "Anthropic's safeguards sometimes decline harmless requests; another model answers instead."
            )), reply: id)
        case .other:
            break
        }
    }

    /// Takes away what this reply showed, before it's tried again or after it failed.
    func discard() {
        for entry in made.values { chat.remove(entry) }
        made = [:]
    }
}
