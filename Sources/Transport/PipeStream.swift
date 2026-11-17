import Foundation

/// A ``ByteStream`` over a pair of file handles, such as the standard input and output of a program Synesthesia
/// started (on the Mac, `meep lsp`).
public final class PipeStream: ByteStream, @unchecked Sendable {
    private let reading: FileHandle
    private let writing: FileHandle
    private let chunks: AsyncStream<Data>
    private var iterator: AsyncStream<Data>.Iterator
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var closed = false

    /// Reads from `reading` and writes to `writing`. Closing the stream closes both.
    public init(reading: FileHandle, writing: FileHandle) {
        self.reading = reading
        self.writing = writing
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        self.chunks = chunks
        iterator = chunks.makeAsyncIterator()
        reading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
    }

    public func send(_ data: Data) async throws {
        guard !lock.withLock({ closed }) else { throw TransportError.failed("The stream is closed.") }
        do {
            // One message at a time, so two senders' bytes can't interleave.
            try writeLock.withLock { try writing.write(contentsOf: data) }
        } catch {
            throw TransportError.failed("Couldn't write to the program: \(error.localizedDescription)")
        }
    }

    public func receive() async throws -> Data? {
        // One reader at a time takes chunks in order; the iterator's state is shared by its copies.
        var copy = lock.withLock { iterator }
        return await copy.next()
    }

    public func close() {
        let first = lock.withLock {
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        reading.readabilityHandler = nil
        try? writing.close()
        try? reading.close()
    }
}

/// Two ends of a byte stream in memory: what one sends, the other receives. For tests, and for joining two parts of
/// one process.
public final class MemoryStream: ByteStream, @unchecked Sendable {
    private let peer: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.Iterator
    private let lock = NSLock()

    private init(incoming: AsyncStream<Data>, peer: AsyncStream<Data>.Continuation) {
        self.peer = peer
        iterator = incoming.makeAsyncIterator()
    }

    /// Two streams joined to each other.
    public static func pair() -> (MemoryStream, MemoryStream) {
        let (a, toA) = AsyncStream<Data>.makeStream()
        let (b, toB) = AsyncStream<Data>.makeStream()
        return (MemoryStream(incoming: a, peer: toB), MemoryStream(incoming: b, peer: toA))
    }

    public func send(_ data: Data) async throws { peer.yield(data) }

    public func receive() async throws -> Data? {
        var copy = lock.withLock { iterator }
        return await copy.next()
    }

    /// Closes this end: the other end's next receive gives nil.
    public func close() { peer.finish() }
}
