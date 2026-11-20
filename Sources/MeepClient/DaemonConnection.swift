import Foundation
import Transport

/// A connection to a Meep daemon: one WebSocket on its `/ws`, carrying any number of requests and streams at once,
/// each matched to its replies by id.
///
/// A request is `{"id": 1, "method": "GET", "path": "/pipelines"}`; its answer is `{"id": 1, "status": 200,
/// "body": …}`. A stream sends `{"id": 1, "event": "stats", "data": …}` until an event called `end`, and the client
/// stops one early with `{"id": 1, "cancel": true}`.
public actor DaemonConnection: HostLink {
    private let socket: WebSocket
    private var nextID = 1
    private var answers: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var streams: [Int: AsyncThrowingStream<Data, any Error>.Continuation] = [:]
    private var reading: Task<Void, Never>?
    private var gone: HostError?

    /// The usual control socket: `$MEEP_HOME/daemon/meep.sock`, or `~/.meep/daemon/meep.sock`.
    public static var defaultSocketPath: String {
        let home = ProcessInfo.processInfo.environment["MEEP_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".meep")
        return (home as NSString).appendingPathComponent("daemon/meep.sock")
    }

    /// Connects to the daemon listening on the Unix socket at `socketPath`.
    public static func connect(socketPath: String = defaultSocketPath) async throws -> DaemonConnection {
        let stream = try await UnixSocketStream.connect(path: socketPath)
        do {
            return try await open(over: stream)
        } catch {
            stream.close()
            throw error
        }
    }

    /// Opens the API's WebSocket over a stream already connected to a daemon, however it got there.
    public static func open(over stream: any ByteStream) async throws -> DaemonConnection {
        let socket = try await WebSocket.connect(over: stream, path: "/ws")
        let connection = DaemonConnection(socket: socket)
        await connection.startReading()
        return connection
    }

    private init(socket: WebSocket) {
        self.socket = socket
    }

    private func startReading() {
        reading = Task { [socket] in
            do {
                while let message = try await socket.receive() {
                    switch message {
                    case .text(let text):
                        self.dispatch(Data(text.utf8))
                    case .binary(let data):
                        // A subscription asked for CBOR sends its events as binary frames, read here as JSON.
                        if let json = try? CBOR.json(from: data) { self.dispatch(json) }
                    }
                }
                self.fail(.disconnected("The daemon closed the connection."))
            } catch {
                self.fail(.disconnected("The connection to the daemon failed: \(error.localizedDescription)"))
            }
        }
    }

    private func dispatch(_ frame: Data) {
        guard let header = try? JSONDecoder().decode(FrameHeader.self, from: frame), let id = header.id.number else {
            return
        }
        if let event = header.event {
            streams[id]?.yield(frame)
            if event == "end" { streams.removeValue(forKey: id)?.finish() }
        } else if let status = header.status {
            if let answer = answers.removeValue(forKey: id) {
                answer.resume(returning: frame)
            } else if status >= 400, let stream = streams.removeValue(forKey: id) {
                // A stream the daemon refused, such as stats for a pipeline that has stopped, gets an answer
                // instead of events.
                let problem = try? MeepJSON.decoder.decode(AnswerFrame<Problem>.self, from: frame)
                stream.finish(throwing: Self.refusal(problem ?? AnswerFrame(id: header.id, status: status, body: nil)))
            }
        }
    }

    private func fail(_ error: HostError) {
        guard gone == nil else { return }
        gone = error
        for answer in answers.values { answer.resume(throwing: error) }
        for stream in streams.values { stream.finish(throwing: error) }
        answers.removeAll()
        streams.removeAll()
    }

    public func close() async {
        fail(.disconnected("The connection was closed."))
        reading?.cancel()
        await socket.close()
        for closing in whenClosed { closing() }
        whenClosed = []
    }

    private var whenClosed: [@Sendable () -> Void] = []

    /// Runs `body` when the connection is closed, as for closing the tunnel it runs through.
    public func onClose(_ body: @escaping @Sendable () -> Void) {
        whenClosed.append(body)
    }

    // MARK: Requests

    /// Sends a request and returns its answer's body, throwing ``HostError/refused(status:message:details:)`` for a
    /// status of 400 or more.
    public func request<Body: Decodable & Sendable>(_ method: String, _ path: String, as type: Body.Type) async throws -> Body? {
        try await request(method, path, json: Empty?.none, as: type)
    }

    /// Sends a request with a JSON body and returns its answer's body.
    public func request<Body: Decodable & Sendable, Sent: Encodable & Sendable>(
        _ method: String, _ path: String, json: Sent?, text: String? = nil, as type: Body.Type
    ) async throws -> Body? {
        let frame = try await send(method, path, json: json, text: text)
        let answer: AnswerFrame<Body>
        do {
            answer = try MeepJSON.decoder.decode(AnswerFrame<Body>.self, from: frame)
        } catch {
            if let problem = try? MeepJSON.decoder.decode(AnswerFrame<Problem>.self, from: frame), problem.status >= 400 {
                throw Self.refusal(problem)
            }
            throw HostError.unreadable("The daemon's answer to \(method) \(path) couldn't be read: \(error)")
        }
        if answer.status >= 400 {
            let problem = try? MeepJSON.decoder.decode(AnswerFrame<Problem>.self, from: frame)
            throw Self.refusal(problem ?? AnswerFrame(id: .number(0), status: answer.status, body: nil))
        }
        return answer.body
    }

    private static func refusal(_ frame: AnswerFrame<Problem>) -> HostError {
        .refused(status: frame.status, message: frame.body?.error ?? "The daemon refused with status \(frame.status).", details: frame.body?.details ?? [])
    }

    private func send<Sent: Encodable & Sendable>(_ method: String, _ path: String, json: Sent?, text body: String? = nil) async throws -> Data {
        if let gone { throw gone }
        let id = nextID
        nextID += 1
        let text = try String(decoding: JSONEncoder().encode(RequestFrame(id: id, method: method, path: path, json: json, text: body)), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            answers[id] = continuation
            Task {
                do {
                    try await socket.send(text: text)
                } catch {
                    self.answers.removeValue(forKey: id)?.resume(throwing: HostError.disconnected(error.localizedDescription))
                }
            }
        }
    }

    /// Opens a stream, giving each event's whole frame.
    public nonisolated func stream(_ path: String) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let opening = Task { await self.open(path, into: continuation) }
            continuation.onTermination = { _ in
                Task {
                    guard let id = await opening.value else { return }
                    await self.cancel(id)
                }
            }
        }
    }

    private func open(_ path: String, into continuation: AsyncThrowingStream<Data, any Error>.Continuation) async -> Int? {
        if let gone {
            continuation.finish(throwing: gone)
            return nil
        }
        let id = nextID
        nextID += 1
        streams[id] = continuation
        do {
            let frame = RequestFrame<Empty>(id: id, method: "GET", path: path, json: nil, text: nil)
            try await socket.send(text: String(decoding: JSONEncoder().encode(frame), as: UTF8.self))
        } catch {
            streams.removeValue(forKey: id)?.finish(throwing: HostError.disconnected(error.localizedDescription))
        }
        return id
    }

    private func cancel(_ id: Int) async {
        guard streams.removeValue(forKey: id) != nil, gone == nil else { return }
        try? await socket.send(text: #"{"id":\#(id),"cancel":true}"#)
    }

    // MARK: Subscriptions

    /// Starts a subscription (`POST /subscribe`), returning its id and its frames.
    fileprivate func openSubscription(_ plan: JSONValue) async throws -> (id: Int, frames: AsyncThrowingStream<Data, any Error>) {
        if let gone { throw gone }
        let id = nextID
        nextID += 1
        let (frames, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        streams[id] = continuation
        continuation.onTermination = { _ in Task { await self.cancel(id) } }
        do {
            let frame = RequestFrame(id: id, method: "POST", path: "/subscribe", json: plan, text: nil)
            try await socket.send(text: String(decoding: JSONEncoder().encode(frame), as: UTF8.self))
        } catch {
            streams.removeValue(forKey: id)?.finish(throwing: HostError.disconnected(error.localizedDescription))
            throw HostError.disconnected(error.localizedDescription)
        }
        return (id, frames)
    }

    /// Sends a stream's control message, such as a subscription's change: `{"id": 3, "change": …}`.
    fileprivate func control(_ id: Int, _ message: [String: JSONValue]) async throws {
        if let gone { throw gone }
        guard streams[id] != nil else { throw HostError.disconnected("The subscription has ended.") }
        var object = message
        object["id"] = .number(id)
        try await socket.send(text: JSONValue.object(object).text())
    }

    public func subscribe(_ plan: SubscriptionPlan) async throws -> any HostSubscription {
        let (id, frames) = try await openSubscription(plan.json)
        return DaemonSubscription(connection: self, id: id, plan: plan, frames: frames)
    }

    // MARK: HostLink

    public func info() async throws -> DaemonInfo {
        try await required(request("GET", "/", as: DaemonInfo.self), "/")
    }

    public func pipelines() async throws -> [PipelineSummary] {
        try await request("GET", "/pipelines", as: [PipelineSummary].self) ?? []
    }

    public func pipeline(_ name: String) async throws -> PipelineDetail {
        let path = "/pipelines/\(Self.escape(name))"
        return try await required(request("GET", path, as: PipelineDetail.self), path)
    }

    public func graph(_ name: String) async throws -> PipelineGraph {
        let path = "/pipelines/\(Self.escape(name))/graph"
        return try await required(request("GET", path, as: PipelineGraph.self), path)
    }

    public func source(_ name: String) async throws -> SourceText {
        let path = "/pipelines/\(Self.escape(name))/source"
        return try await required(request("GET", path, as: SourceText.self), path)
    }

    public func reload(_ name: String) async throws {
        _ = try await request("POST", "/pipelines/\(Self.escape(name))/reload", json: Empty(), as: Ignored.self)
    }

    /// An answer whose body isn't needed.
    struct Ignored: Decodable, Sendable {}

    public nonisolated func tap(_ name: String, module: String, where condition: String?, sample: Double?) -> AsyncThrowingStream<TapEvent, any Error> {
        var query: [String] = []
        if let condition, !condition.isEmpty { query.append("where=" + Self.escapeQuery(condition)) }
        if let sample { query.append("sample=\(sample)") }
        let path = "/pipelines/\(Self.escape(name))/modules/\(Self.escape(module))/tap" + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
        let frames = stream(path)
        return AsyncThrowingStream { continuation in
            let reading = Task {
                do {
                    for try await frame in frames {
                        let header = try MeepJSON.decoder.decode(FrameHeader.self, from: frame)
                        guard header.event == "message" else { continue }
                        guard let event = try MeepJSON.decoder.decode(EventFrame<TapEvent>.self, from: frame).data else {
                            throw HostError.unreadable("A tap's message had no data.")
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reading.cancel() }
        }
    }

    public func inject(_ name: String, module: String, _ body: InjectBody) async throws -> Injected {
        let path = "/pipelines/\(Self.escape(name))/modules/\(Self.escape(module))/inject"
        let answer: Injected?
        switch body {
        case .text(let text): answer = try await request("POST", path, json: Empty?.none, text: text, as: Injected.self)
        case .json(let json): answer = try await request("POST", path, json: json, as: Injected.self)
        }
        return try required(answer, path)
    }

    /// Escapes a query's value, so its `&`, `=`, `+` and spaces stay part of it.
    static func escapeQuery(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    public nonisolated func stats(_ name: String, every interval: Duration) -> AsyncThrowingStream<StatsEvent, any Error> {
        let frames = stream("/pipelines/\(Self.escape(name))/stats?every=\(interval.meepText)")
        return AsyncThrowingStream { continuation in
            let reading = Task {
                do {
                    for try await frame in frames {
                        continuation.yield(try Self.statsEvent(from: frame))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reading.cancel() }
        }
    }

    static func statsEvent(from frame: Data) throws -> StatsEvent {
        let header = try MeepJSON.decoder.decode(FrameHeader.self, from: frame)
        switch header.event {
        case "stats":
            guard let detail = try MeepJSON.decoder.decode(EventFrame<PipelineDetail>.self, from: frame).data else {
                throw HostError.unreadable("A stats event had no data.")
            }
            return .stats(detail)
        case "graph":
            guard let notice = try MeepJSON.decoder.decode(EventFrame<GraphNotice>.self, from: frame).data else {
                throw HostError.unreadable("A graph event had no data.")
            }
            return .graph(notice)
        default:
            let end = try? MeepJSON.decoder.decode(EventFrame<EndReason>.self, from: frame).data
            return .end(end?.reason ?? "The stream ended.")
        }
    }

    private func required<T>(_ value: T?, _ path: String) throws -> T {
        guard let value else { throw HostError.unreadable("The daemon's answer to \(path) was empty.") }
        return value
    }

    /// Escapes one part of a path, so a name with a slash or space stays one part.
    static func escape(_ part: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return part.addingPercentEncoding(withAllowedCharacters: allowed) ?? part
    }
}

// MARK: Frames

/// A body for requests that have none.
public struct Empty: Codable, Sendable {}

/// An id as the daemon echoes it: we send numbers, but it takes strings too.
enum FrameID: Decodable {
    case number(Int)
    case text(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    var number: Int? {
        switch self {
        case .number(let number): number
        case .text(let text): Int(text)
        }
    }
}

struct FrameHeader: Decodable {
    var id: FrameID
    var status: Int?
    var event: String?
}

struct RequestFrame<Body: Encodable>: Encodable {
    var id: Int
    var method: String
    var path: String
    var json: Body?
    /// A text body, as for injecting text.
    var text: String?
}

struct AnswerFrame<Body: Decodable>: Decodable {
    var id: FrameID
    var status: Int
    var body: Body?
}

struct EventFrame<Payload: Decodable>: Decodable {
    var id: FrameID
    var event: String
    var data: Payload?
}

struct EndReason: Decodable {
    var reason: String
}

/// A subscription on a daemon's connection: its events, read from JSON or CBOR frames, and its changes, sent as merge
/// patches against the last plan sent.
final class DaemonSubscription: HostSubscription {
    let events: AsyncThrowingStream<SubscriptionEvent, any Error>
    private let connection: DaemonConnection
    private let id: Int
    private let sent: PlanBox

    /// The last plan sent, so a change is sent as only what moved.
    private actor PlanBox {
        var plan: SubscriptionPlan
        init(_ plan: SubscriptionPlan) { self.plan = plan }
        func swap(_ new: SubscriptionPlan) -> SubscriptionPlan {
            defer { plan = new }
            return plan
        }
    }

    init(connection: DaemonConnection, id: Int, plan: SubscriptionPlan, frames: AsyncThrowingStream<Data, any Error>) {
        self.connection = connection
        self.id = id
        sent = PlanBox(plan)
        events = AsyncThrowingStream { continuation in
            let reading = Task {
                do {
                    for try await frame in frames {
                        let header = try MeepJSON.decoder.decode(FrameHeader.self, from: frame)
                        if header.event == "end" { break }
                        if case .update(var update)? = try MeepJSON.subscriptionEvent(from: frame) {
                            update.received = Date()
                            continuation.yield(.update(update))
                        } else if let event = try MeepJSON.subscriptionEvent(from: frame) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reading.cancel() }
        }
    }

    func change(to plan: SubscriptionPlan) async throws {
        let old = await sent.swap(plan)
        guard let patch = plan.patch(from: old) else { return }
        try await connection.control(id, ["change": patch])
    }

    func resend() async throws {
        try await connection.control(id, ["resend": true])
    }

    func cancel() async {
        try? await connection.control(id, ["cancel": true])
    }
}
