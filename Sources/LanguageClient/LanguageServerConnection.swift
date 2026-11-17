import Foundation
import Transport

/// Why a language server request failed.
public enum LanguageServerError: Error, Equatable, LocalizedError {
    /// The code a server refuses with when the text has changed since the version asked about (`ContentModified`).
    public static let contentModified = -32801
    /// The code for a request that was understood but couldn't be done (`RequestFailed`).
    public static let requestFailed = -32803

    /// The server answered with an error: for `meep/applyEdits`, which edit failed, counting from 0, or for a stale
    /// version, the server's version.
    case refused(code: Int, message: String, edit: Int? = nil, version: Int? = nil)
    /// The server has stopped, or the stream to it closed.
    case stopped(String)
    /// The server sent something that couldn't be read.
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .refused(_, let message, _, _): message
        case .stopped(let reason): reason
        case .unreadable(let reason): reason
        }
    }
}

/// JSON-RPC to a language server over a byte stream, framed as the Language Server Protocol frames it: a
/// `Content-Length` header, a blank line, then that many bytes of JSON.
///
/// Messages go out in the order they're given to it, so a caller that awaits each in turn (a change, then a request
/// about it) has them handled in that order, as the protocol needs.
public actor LanguageServerConnection {
    /// A notification from the server.
    public struct Notice: Sendable {
        public let method: String
        /// The whole message, for ``params(as:)``.
        public let frame: Data

        /// The notification's parameters, read as `type`.
        public func params<T: Decodable>(as type: T.Type) throws -> T {
            guard let params = try JSONDecoder().decode(Incoming<T>.self, from: frame).params else {
                throw LanguageServerError.unreadable("\(method) had no parameters.")
            }
            return params
        }
    }

    private let stream: any ByteStream
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var reading: Task<Void, Never>?
    private var writing: Task<Void, Never>?
    private let outbox: AsyncStream<Data>.Continuation
    private let outgoing: AsyncStream<Data>
    private let notices: AsyncStream<Notice>.Continuation
    private var gone: LanguageServerError?

    /// The server's notifications, in the order they came, until it stops.
    public nonisolated let notifications: AsyncStream<Notice>

    public init(stream: any ByteStream) {
        self.stream = stream
        (outgoing, outbox) = AsyncStream<Data>.makeStream()
        (notifications, notices) = AsyncStream<Notice>.makeStream()
    }

    /// Starts reading what the server sends, and writing what's given to it.
    public func start() {
        guard reading == nil else { return }
        let stream = stream
        let outgoing = outgoing
        writing = Task {
            for await frame in outgoing {
                do {
                    try await stream.send(frame)
                } catch {
                    self.fail(.stopped("Couldn't write to the language server: \(error.localizedDescription)"))
                    return
                }
            }
        }
        reading = Task {
            var reader = FrameReader()
            do {
                while let data = try await stream.receive() {
                    for message in try reader.append(data) { self.dispatch(message) }
                }
                self.fail(.stopped("The language server stopped."))
            } catch {
                self.fail(.stopped("The language server stopped: \(error.localizedDescription)"))
            }
        }
    }

    /// Whether the server has stopped, and why.
    public var stopped: LanguageServerError? { gone }

    /// Sends a request and returns its result, or nil for a null result.
    public func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String, _ params: Params?, as type: Result.Type
    ) async throws -> Result? {
        if let gone { throw gone }
        let id = nextID
        nextID += 1
        let frame = try Self.frame(Outgoing(id: id, method: method, params: params))
        let answer = try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            outbox.yield(frame)
        }
        let response: Response<Result>
        do {
            response = try JSONDecoder().decode(Response<Result>.self, from: answer)
        } catch {
            if let failure = try? JSONDecoder().decode(Response<Ignored>.self, from: answer).error {
                throw failure.error
            }
            throw LanguageServerError.unreadable("The answer to \(method) couldn't be read: \(error)")
        }
        if let failure = response.error { throw failure.error }
        return response.result
    }

    /// Sends a notification, which has no answer.
    public func notify<Params: Encodable & Sendable>(_ method: String, _ params: Params?) throws {
        if let gone { throw gone }
        outbox.yield(try Self.frame(Outgoing(id: nil, method: method, params: params)))
    }

    /// Closes the stream. Waiting requests fail.
    public func close() {
        fail(.stopped("The connection to the language server was closed."))
        stream.close()
    }

    private func dispatch(_ message: Data) {
        guard let header = try? JSONDecoder().decode(Header.self, from: message) else { return }
        switch (header.method, header.id) {
        case (let method?, nil):
            notices.yield(Notice(method: method, frame: message))
        case (_?, let id?):
            // A request from the server, such as for configuration. Synesthesia offers none, so it answers null.
            if let frame = try? Self.frame(Reply(id: id)) { outbox.yield(frame) }
        case (nil, let id?):
            if let number = id.number, let continuation = waiting.removeValue(forKey: number) {
                continuation.resume(returning: message)
            }
        case (nil, nil):
            break
        }
    }

    private func fail(_ error: LanguageServerError) {
        guard gone == nil else { return }
        gone = error
        for continuation in waiting.values { continuation.resume(throwing: error) }
        waiting.removeAll()
        outbox.finish()
        notices.finish()
        reading?.cancel()
    }

    static func frame<Message: Encodable>(_ message: Message) throws -> Data {
        let body = try JSONEncoder().encode(message)
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    // MARK: Messages

    struct Outgoing<Params: Encodable>: Encodable {
        var jsonrpc = "2.0"
        var id: Int?
        var method: String
        var params: Params?

        init(id: Int?, method: String, params: Params?) {
            self.id = id
            self.method = method
            self.params = params
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(jsonrpc, forKey: .jsonrpc)
            try c.encodeIfPresent(id, forKey: .id)
            try c.encode(method, forKey: .method)
            try c.encodeIfPresent(params, forKey: .params)
        }

        enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }
    }

    struct Reply: Encodable {
        var jsonrpc = "2.0"
        var id: MessageID

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(jsonrpc, forKey: .jsonrpc)
            try c.encode(id, forKey: .id)
            try c.encodeNil(forKey: .result)
        }

        enum CodingKeys: String, CodingKey { case jsonrpc, id, result }
    }

    struct Header: Decodable {
        var id: MessageID?
        var method: String?
    }

    struct Response<Result: Decodable>: Decodable {
        var result: Result?
        var error: Failure?
    }

    struct Incoming<Params: Decodable>: Decodable {
        var params: Params?
    }

    struct Failure: Decodable {
        var code: Int
        var message: String
        var data: Details?

        struct Details: Decodable {
            var edit: Int?
            var version: Int?
        }

        var error: LanguageServerError {
            .refused(code: code, message: message, edit: data?.edit, version: data?.version)
        }
    }

    struct Ignored: Decodable {}
}

/// An id as JSON-RPC allows it: a number or a string.
enum MessageID: Codable, Sendable, Equatable {
    case number(Int)
    case text(String)

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let number = try? c.decode(Int.self) { self = .number(number) } else { self = .text(try c.decode(String.self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let number): try c.encode(number)
        case .text(let text): try c.encode(text)
        }
    }

    var number: Int? {
        switch self {
        case .number(let number): number
        case .text(let text): Int(text)
        }
    }
}

/// Splits what arrives into whole messages, by their `Content-Length` headers.
struct FrameReader {
    private var buffer = Data()
    private static let blankLine = Data("\r\n\r\n".utf8)

    /// Takes more bytes, returning the messages they complete.
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        while let end = buffer.range(of: Self.blankLine) {
            let headers = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            guard let length = Self.contentLength(in: headers) else {
                throw LanguageServerError.unreadable("A message from the language server had no Content-Length: \(headers)")
            }
            let bodyStart = end.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { break }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            messages.append(Data(buffer[bodyStart..<bodyEnd]))
            buffer = Data(buffer[bodyEnd...])
        }
        return messages
    }

    private static func contentLength(in headers: String) -> Int? {
        for line in headers.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}
