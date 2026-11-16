import CryptoKit
import Foundation

/// A whole message received over a ``WebSocket``.
public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

/// The client end of a WebSocket (RFC 6455) over any ``ByteStream``.
///
/// Network.framework's own WebSocket can't be pointed at a path on a Unix socket, and the Meep daemon serves its
/// API at `/ws` on one, so this does the handshake and framing itself. It answers pings, joins fragmented
/// messages and masks what it sends, as a client must.
public actor WebSocket {
    private let stream: any ByteStream
    private var buffer: [UInt8]
    private var fragments: (opcode: WebSocketFrame.Opcode, payload: [UInt8])?
    private var closed = false

    private init(stream: any ByteStream, leftover: [UInt8]) {
        self.stream = stream
        buffer = leftover
    }

    /// Opens a WebSocket at `path` over `stream`, which must be freshly connected.
    public static func connect(
        over stream: any ByteStream,
        host: String = "localhost",
        path: String,
        headers: [String: String] = [:]
    ) async throws -> WebSocket {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        var request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        request += "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            request += "\(name): \(value)\r\n"
        }
        request += "\r\n"
        try await stream.send(Data(request.utf8))

        var received: [UInt8] = []
        let end: Int
        while true {
            if let found = HandshakeReply.endOfHeaders(in: received) {
                end = found
                break
            }
            guard received.count < 16 * 1024 else {
                throw TransportError.protocolViolation("The handshake's reply was too long.")
            }
            guard let more = try await stream.receive() else {
                throw TransportError.protocolViolation("The connection closed during the WebSocket handshake.")
            }
            received += more
        }
        let reply = try HandshakeReply(String(decoding: received[..<end], as: UTF8.self))
        try reply.check(key: key)
        return WebSocket(stream: stream, leftover: Array(received[end...]))
    }

    /// Sends a text message.
    public func send(text: String) async throws {
        try await send(WebSocketFrame(opcode: .text, payload: Array(text.utf8)))
    }

    /// Sends a binary message.
    public func send(binary: Data) async throws {
        try await send(WebSocketFrame(opcode: .binary, payload: Array(binary)))
    }

    private func send(_ frame: WebSocketFrame) async throws {
        guard !closed else { throw TransportError.failed("The WebSocket is closed.") }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        try await stream.send(Data(frame.encoded(mask: mask)))
    }

    /// The next whole message, or nil once the WebSocket has closed.
    public func receive() async throws -> WebSocketMessage? {
        while true {
            while let frame = try WebSocketFrame.decode(from: &buffer) {
                if let message = try await handle(frame) { return message }
                if closed { return nil }
            }
            guard !closed, let more = try await stream.receive() else {
                closed = true
                return nil
            }
            buffer += more
        }
    }

    private func handle(_ frame: WebSocketFrame) async throws -> WebSocketMessage? {
        switch frame.opcode {
        case .ping:
            try? await send(WebSocketFrame(opcode: .pong, payload: frame.payload))
            return nil
        case .pong:
            return nil
        case .close:
            if !closed {
                try? await send(WebSocketFrame(opcode: .close, payload: Array(frame.payload.prefix(2))))
                closed = true
                stream.close()
            }
            return nil
        case .continuation:
            guard var started = fragments else {
                throw TransportError.protocolViolation("A continuation frame came without a message to continue.")
            }
            started.payload += frame.payload
            fragments = frame.fin ? nil : started
            return frame.fin ? try message(started.opcode, started.payload) : nil
        case .text, .binary:
            guard fragments == nil else {
                throw TransportError.protocolViolation("A new message started before the last one finished.")
            }
            if frame.fin { return try message(frame.opcode, frame.payload) }
            fragments = (frame.opcode, frame.payload)
            return nil
        }
    }

    private func message(_ opcode: WebSocketFrame.Opcode, _ payload: [UInt8]) throws -> WebSocketMessage {
        if opcode == .binary { return .binary(Data(payload)) }
        guard let text = String(validating: payload, as: UTF8.self) else {
            throw TransportError.protocolViolation("A text message wasn't UTF-8.")
        }
        return .text(text)
    }

    /// Closes the WebSocket, telling the other end why, and then the stream under it.
    public func close(code: UInt16 = 1000, reason: String = "") async {
        guard !closed else { return }
        let payload = [UInt8(code >> 8), UInt8(code & 0xFF)] + Array(reason.utf8.prefix(123))
        try? await send(WebSocketFrame(opcode: .close, payload: payload))
        closed = true
        stream.close()
    }
}

/// One WebSocket frame, as RFC 6455 section 5.2 lays it out.
public struct WebSocketFrame: Equatable, Sendable {
    public enum Opcode: UInt8, Sendable {
        case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
    }

    public var fin: Bool
    public var opcode: Opcode
    public var payload: [UInt8]

    public init(fin: Bool = true, opcode: Opcode, payload: [UInt8]) {
        self.fin = fin
        self.opcode = opcode
        self.payload = payload
    }

    /// The frame as bytes, masked with `mask` if one is given, as a client's frames must be.
    public func encoded(mask: [UInt8]? = nil) -> [UInt8] {
        var bytes: [UInt8] = [(fin ? 0x80 : 0) | opcode.rawValue]
        let maskBit: UInt8 = mask == nil ? 0 : 0x80
        switch payload.count {
        case ..<126:
            bytes.append(maskBit | UInt8(payload.count))
        case ..<65536:
            bytes.append(maskBit | 126)
            bytes += [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        default:
            bytes.append(maskBit | 127)
            bytes += (0..<8).reversed().map { UInt8((UInt64(payload.count) >> (UInt64($0) * 8)) & 0xFF) }
        }
        if let mask {
            bytes += mask
            bytes += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        } else {
            bytes += payload
        }
        return bytes
    }

    /// Takes one whole frame off the front of `buffer`, or returns nil if the buffer doesn't hold one yet.
    public static func decode(from buffer: inout [UInt8]) throws -> WebSocketFrame? {
        guard buffer.count >= 2 else { return nil }
        guard let opcode = Opcode(rawValue: buffer[0] & 0x0F) else {
            throw TransportError.protocolViolation("Unknown WebSocket opcode \(buffer[0] & 0x0F).")
        }
        let fin = buffer[0] & 0x80 != 0
        let masked = buffer[1] & 0x80 != 0
        var length = Int(buffer[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = Int(buffer[2]) << 8 | Int(buffer[3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            var value: UInt64 = 0
            for byte in buffer[2..<10] { value = value << 8 | UInt64(byte) }
            guard value <= UInt64(Int32.max) else {
                throw TransportError.protocolViolation("A WebSocket frame said it was \(value) bytes long.")
            }
            length = Int(value)
            offset = 10
        }
        let maskLength = masked ? 4 : 0
        guard buffer.count >= offset + maskLength + length else { return nil }
        var payload = Array(buffer[(offset + maskLength)..<(offset + maskLength + length)])
        if masked {
            let mask = Array(buffer[offset..<(offset + 4)])
            for index in payload.indices { payload[index] ^= mask[index % 4] }
        }
        buffer.removeFirst(offset + maskLength + length)
        return WebSocketFrame(fin: fin, opcode: opcode, payload: payload)
    }
}

/// The server's reply to the opening handshake.
struct HandshakeReply {
    let status: Int
    let headers: [String: String]

    init(_ text: String) throws {
        let lines = text.components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw TransportError.protocolViolation("The handshake's reply didn't start with a status line.")
        }
        self.status = status
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
    }

    func check(key: String) throws {
        guard status == 101 else {
            throw TransportError.protocolViolation("The server refused the WebSocket with status \(status).")
        }
        guard headers["sec-websocket-accept"] == Self.accept(for: key) else {
            throw TransportError.protocolViolation("The server's Sec-WebSocket-Accept didn't match the key.")
        }
    }

    /// What the server must answer to `key`, from RFC 6455 section 4.2.2.
    static func accept(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    /// Where the headers end, just after the blank line, if they have.
    static func endOfHeaders(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4)
        where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index + 4
        }
        return nil
    }
}
