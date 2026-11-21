import Foundation
import MeepClient

/// The Claude Messages API, as the sidebar uses it (design, section 8; Q8): one streamed request a turn over HTTPS,
/// with the person's own key. There's no Anthropic SDK for Swift, so this is a small client of the API's documented
/// shapes: the request, server-sent events, and errors.
public enum ClaudeAPI {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let version = "2026-10-21"
    public static let model = "claude-opus-5-5"
    /// Room for thinking as well as the reply: thinking counts toward it.
    public static let maxTokens = 64_000
    /// Betas the requests use:
    /// - `server-side-fallback`: a request a safety classifier declines is answered by the model Anthropic recommends
    ///   for that kind of refusal (`fallbacks: "default"`), rather than failing.
    /// - `thinking-binding-controls`: the transcript is append-only, so thinking blocks stay valid; if that's ever
    ///   broken, the blocks are dropped (`drop_block`) and listed in `input_transformations`, rather than failing.
    public static let betas = ["server-side-fallback-2026-07-01", "thinking-binding-controls-2026-08-01"]

    /// The request's body. The system prompt and tools are the same for every request of a conversation, and come
    /// first, so they're cached together (`cache_control` on the system prompt); the conversation's growing tail is
    /// cached by the top-level `cache_control`.
    public static func body(system: String, tools: [Tool], messages: [JSONValue], effort: Effort) -> JSONValue {
        [
            "model": .string(model),
            "max_tokens": .number(maxTokens),
            "stream": true,
            // Thinking is always on with this model; effort sets how much. Summaries of it are shown, collapsed.
            "thinking": [
                "type": "adaptive", "display": "summarized",
                "block_binding": ["prefix_mismatch_behavior": "drop_block"],
            ],
            "output_config": ["effort": .string(effort.rawValue)],
            "system": [["type": "text", "text": .string(system), "cache_control": ["type": "ephemeral"]]],
            "tools": .array(tools.map(\.apiDefinition)),
            "messages": .array(messages),
            "cache_control": ["type": "ephemeral"],
            "fallbacks": "default",
        ]
    }

    /// The HTTP request for a body. The key goes in its header and nowhere else.
    public static func request(body: JSONValue, key: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(body.text().utf8)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        // Between events, not overall: the stream pings while the model thinks.
        request.timeoutInterval = 300
        return request
    }
}

/// How much Claude thinks before it answers, and so how long and how much an answer costs. The API's default for
/// `claude-opus-5-5` is medium; the sidebar always says which.
public enum Effort: String, CaseIterable, Sendable, Identifiable {
    case low, medium, high, xhigh, max
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Most"
        }
    }
}

// MARK: HTTP

/// An HTTP response whose body arrives as it's sent.
public struct HTTPStream: Sendable {
    public var status: Int
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, any Error>

    public init(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, any Error>) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// The whole body, for an error's JSON.
    public func collect(limit: Int = 1 << 20) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            if data.count > limit { break }
        }
        return data
    }
}

/// Sends a request and streams its response: URLSession in the app, recorded streams in tests.
public protocol HTTPStreaming: Sendable {
    func open(_ request: URLRequest) async throws -> HTTPStream
}

/// HTTPS through URLSession, ephemeral so nothing of a conversation is cached on disk. Cancelling the task that reads
/// the body cancels the request.
public final class URLSessionStreaming: HTTPStreaming {
    private let session = URLSession(configuration: .ephemeral)

    public init() {}

    public func open(_ request: URLRequest) async throws -> HTTPStream {
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let receiver = Receiver(body: continuation)
        let task = session.dataTask(with: request)
        task.delegate = receiver
        continuation.onTermination = { _ in task.cancel() }
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<HTTPURLResponse, any Error>) in
                receiver.wait(waiting)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        return HTTPStream(status: response.statusCode, headers: headers, body: body)
    }

    /// The task's delegate: hands over the response once, then the body as it comes.
    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<HTTPURLResponse, any Error>?
        private let body: AsyncThrowingStream<Data, any Error>.Continuation

        init(body: AsyncThrowingStream<Data, any Error>.Continuation) {
            self.body = body
        }

        func wait(_ continuation: CheckedContinuation<HTTPURLResponse, any Error>) {
            lock.withLock { waiting = continuation }
        }

        private func takeWaiting() -> CheckedContinuation<HTTPURLResponse, any Error>? {
            lock.withLock {
                defer { waiting = nil }
                return waiting
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
            if let http = response as? HTTPURLResponse {
                takeWaiting()?.resume(returning: http)
            } else {
                takeWaiting()?.resume(throwing: URLError(.badServerResponse))
            }
            return .allow
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            body.yield(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            if let error {
                takeWaiting()?.resume(throwing: error)
                body.finish(throwing: error)
            } else {
                takeWaiting()?.resume(throwing: URLError(.badServerResponse))
                body.finish()
            }
        }
    }
}

// MARK: Server-sent events

/// One server-sent event: its name and its data.
public struct ServerSentEvent: Equatable, Sendable {
    public var event: String?
    public var data: String
}

/// Reads server-sent events from bytes as they arrive, in chunks that can end anywhere.
public struct SSEParser: Sendable {
    private var buffer = Data()
    private var event: String?
    private var data: [String] = []

    public init() {}

    /// The events completed by a chunk.
    public mutating func feed(_ chunk: Data) -> [ServerSentEvent] {
        buffer.append(chunk)
        var events: [ServerSentEvent] = []
        // A newline byte is never part of a longer UTF-8 character, so each line decodes whole.
        while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var line = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            if let finished = take(String(decoding: line, as: UTF8.self)) { events.append(finished) }
        }
        return events
    }

    /// An event the stream ended in the middle of, if any.
    public mutating func finish() -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        if !buffer.isEmpty, let last = take(String(decoding: buffer, as: UTF8.self)) { events.append(last) }
        buffer.removeAll()
        if let last = take("") { events.append(last) }
        return events
    }

    private mutating func take(_ line: String) -> ServerSentEvent? {
        if line.isEmpty {
            defer {
                event = nil
                data = []
            }
            guard !data.isEmpty else { return nil }
            return ServerSentEvent(event: event, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[line.startIndex..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }
}

// MARK: Errors

/// Why a request to the API didn't get an answer, in words the person can act on.
public struct ClaudeAPIError: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case missingKey
        case refusedKey
        case permission
        case billing
        case notFound
        case tooLarge
        case rateLimited(retryAfter: Double?)
        case spendLimit
        case overloaded
        case server
        case invalidRequest
        case network
        case unexpected
    }

    public var kind: Kind
    /// The HTTP status, if there was one.
    public var status: Int?
    /// The API's own type and message, if it sent one.
    public var type: String?
    public var message: String?
    public var requestID: String?

    public init(kind: Kind, status: Int? = nil, type: String? = nil, message: String? = nil, requestID: String? = nil) {
        self.kind = kind
        self.status = status
        self.type = type
        self.message = message
        self.requestID = requestID
    }

    /// Whether to try again on its own, after a short wait. A rate limit is waited out only when it says how long:
    /// one without retry-after may be a spend cap.
    public var isRetryable: Bool {
        switch kind {
        case .rateLimited(let after): after != nil
        case .overloaded, .server, .network: true
        default: false
        }
    }

    /// From an HTTP response that wasn't 200, with its body.
    static func from(status: Int, headers: [String: String], body: Data) -> ClaudeAPIError {
        let json = try? JSONValue.parse(body)
        let type = json?["error"]?["type"]?.string
        let message = json?["error"]?["message"]?.string ?? (body.isEmpty ? nil : String(decoding: body.prefix(500), as: UTF8.self))
        let requestID = headers["request-id"] ?? json?["request_id"]?.string
        let retryAfter = headers["retry-after"].flatMap(Double.init)
        let kind: Kind
        switch (status, type) {
        case (401, _), (_, "authentication_error"): kind = .refusedKey
        case (402, _), (_, "billing_error"): kind = .billing
        case (403, _), (_, "permission_error"): kind = .permission
        case (404, _), (_, "not_found_error"): kind = .notFound
        case (413, _), (_, "request_too_large"): kind = .tooLarge
        case (429, _), (_, "rate_limit_error"):
            // A spend cap's 429 has no retry-after, and keeps failing until access resumes.
            let spend = json?["error"]?["details"]?["error_code"]?.string == "enforced_spend_limit_reached"
            kind = spend ? .spendLimit : .rateLimited(retryAfter: retryAfter)
        case (529, _), (_, "overloaded_error"): kind = .overloaded
        case (500..., _), (_, "api_error"), (_, "timeout_error"): kind = .server
        case (400, _), (_, "invalid_request_error"): kind = .invalidRequest
        default: kind = .unexpected
        }
        return ClaudeAPIError(kind: kind, status: status, type: type, message: message, requestID: requestID)
    }

    /// From an `error` event in the middle of a stream.
    static func from(event json: JSONValue, requestID: String?) -> ClaudeAPIError {
        let type = json["error"]?["type"]?.string
        let message = json["error"]?["message"]?.string
        let kind: Kind = switch type {
        case "overloaded_error": .overloaded
        case "api_error", "timeout_error": .server
        case "rate_limit_error": .rateLimited(retryAfter: nil)
        case "invalid_request_error": .invalidRequest
        case "authentication_error": .refusedKey
        case "permission_error": .permission
        case "billing_error": .billing
        default: .unexpected
        }
        return ClaudeAPIError(kind: kind, type: type, message: message, requestID: requestID)
    }
}
