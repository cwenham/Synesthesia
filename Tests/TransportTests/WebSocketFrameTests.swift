import Foundation
import Testing
@testable import Transport

struct WebSocketFrameTests {
    @Test func acceptKeyMatchesTheRFCExample() {
        // RFC 6455, section 1.3.
        #expect(HandshakeReply.accept(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test(arguments: [0, 5, 125, 126, 1000, 65535, 65536, 200_000])
    func framesSurviveEncodingAndDecoding(length: Int) throws {
        let payload = (0..<length).map { UInt8($0 % 251) }
        for mask in [nil, [UInt8(1), 2, 3, 4]] {
            var bytes = WebSocketFrame(opcode: .binary, payload: payload).encoded(mask: mask)
            let decoded = try #require(try WebSocketFrame.decode(from: &bytes))
            #expect(decoded.payload == payload)
            #expect(decoded.opcode == .binary)
            #expect(decoded.fin)
            #expect(bytes.isEmpty)
        }
    }

    @Test func aPartFrameWaitsForTheRest() throws {
        let whole = WebSocketFrame(opcode: .text, payload: Array("hello, world".utf8)).encoded()
        var part = Array(whole.prefix(5))
        #expect(try WebSocketFrame.decode(from: &part) == nil)
        #expect(part.count == 5)
        part += whole.dropFirst(5)
        #expect(try WebSocketFrame.decode(from: &part)?.payload == Array("hello, world".utf8))
    }

    @Test func twoFramesInOneReadComeOutOneByOne() throws {
        var bytes = WebSocketFrame(opcode: .text, payload: Array("one".utf8)).encoded()
            + WebSocketFrame(opcode: .ping, payload: []).encoded()
        #expect(try WebSocketFrame.decode(from: &bytes)?.opcode == .text)
        #expect(try WebSocketFrame.decode(from: &bytes)?.opcode == .ping)
        #expect(bytes.isEmpty)
    }

    @Test func theEndOfHeadersIsFound() {
        let reply = Array("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\nrest".utf8)
        #expect(HandshakeReply.endOfHeaders(in: reply) == reply.count - 4)
        #expect(HandshakeReply.endOfHeaders(in: Array("HTTP/1.1 101\r\n".utf8)) == nil)
    }

    @Test func aWebSocketTalksOverAnyByteStream() async throws {
        let stream = ScriptedStream()
        async let opened = WebSocket.connect(over: stream, path: "/ws")
        let request = String(decoding: await stream.nextSent(), as: UTF8.self)
        #expect(request.hasPrefix("GET /ws HTTP/1.1\r\n"))
        let key = try #require(request.split(separator: "\r\n").first { $0.hasPrefix("Sec-WebSocket-Key: ") }?.dropFirst(19))
        let reply = "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: \(HandshakeReply.accept(for: String(key)))\r\n\r\n"
        // The reply arrives with the first frame stuck to it, and a ping that must be answered.
        await stream.deliver(Array(reply.utf8) + WebSocketFrame(opcode: .ping, payload: [9]).encoded()
            + WebSocketFrame(fin: false, opcode: .text, payload: Array("hel".utf8)).encoded())
        let socket = try await opened
        await stream.deliver(WebSocketFrame(opcode: .continuation, payload: Array("lo".utf8)).encoded())
        #expect(try await socket.receive() == .text("hello"))

        var pong = Array(await stream.nextSent())
        let frame = try #require(try WebSocketFrame.decode(from: &pong))
        #expect(frame.opcode == .pong)
        #expect(frame.payload == [9])

        try await socket.send(text: "hi")
        var sent = Array(await stream.nextSent())
        #expect(sent[1] & 0x80 != 0, "a client's frames are masked")
        #expect(try WebSocketFrame.decode(from: &sent)?.payload == Array("hi".utf8))

        await stream.deliver(WebSocketFrame(opcode: .close, payload: [3, 232]).encoded())
        #expect(try await socket.receive() == nil)
    }
}

/// A byte stream whose other end is the test.
actor ScriptedStream: ByteStream {
    private var incoming: [Data] = []
    private var receivers: [CheckedContinuation<Data?, any Error>] = []
    private var sent: [Data] = []
    private var senders: [CheckedContinuation<Data, Never>] = []
    private var closed = false

    func send(_ data: Data) async throws {
        if senders.isEmpty { sent.append(data) } else { senders.removeFirst().resume(returning: data) }
    }

    func receive() async throws -> Data? {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if closed { return nil }
        return try await withCheckedThrowingContinuation { receivers.append($0) }
    }

    nonisolated func close() {
        Task { await self.finish() }
    }

    private func finish() {
        closed = true
        for receiver in receivers { receiver.resume(returning: nil) }
        receivers.removeAll()
    }

    func deliver(_ bytes: [UInt8]) {
        if receivers.isEmpty { incoming.append(Data(bytes)) } else { receivers.removeFirst().resume(returning: Data(bytes)) }
    }

    func nextSent() async -> Data {
        if !sent.isEmpty { return sent.removeFirst() }
        return await withCheckedContinuation { senders.append($0) }
    }
}
