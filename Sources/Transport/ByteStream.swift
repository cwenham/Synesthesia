import Foundation
import Network

/// A two-way stream of bytes: a Unix socket now; TCP with TLS, and tunnels, later. Everything above it, such as
/// ``WebSocket``, works the same over any of them, which is what makes a remote host look like the local one.
public protocol ByteStream: Sendable {
    /// Sends bytes, returning once the stream has taken them.
    func send(_ data: Data) async throws

    /// The next bytes to arrive, or nil when the other end has closed the stream.
    func receive() async throws -> Data?

    /// Closes the stream. Waiting `receive` calls end with nil or an error.
    func close()
}

/// Why a ``ByteStream`` couldn't be opened or failed.
public enum TransportError: Error, Equatable, LocalizedError {
    /// Nothing is listening at the address, as when the daemon isn't running.
    case notListening(String)
    /// The connection failed after it opened.
    case failed(String)
    /// The other end broke the protocol.
    case protocolViolation(String)

    public var errorDescription: String? {
        switch self {
        case .notListening(let address): "Nothing is listening on \(address)."
        case .failed(let reason): reason
        case .protocolViolation(let reason): reason
        }
    }
}

/// A ``ByteStream`` over a Unix domain socket, such as the Meep daemon's `~/.meep/daemon/meep.sock`.
public final class UnixSocketStream: ByteStream {
    private let connection: NWConnection
    private let path: String

    private init(path: String) {
        self.path = path
        connection = NWConnection(to: .unix(path: path), using: .tcp)
    }

    /// Connects to the socket at `path`, throwing ``TransportError/notListening(_:)`` if nothing is there.
    public static func connect(path: String) async throws -> UnixSocketStream {
        guard FileManager.default.fileExists(atPath: path) else { throw TransportError.notListening(path) }
        let stream = UnixSocketStream(path: path)
        try await stream.start()
        return stream
    }

    private func start() async throws {
        let path = path
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume() }
                case .waiting(let error), .failed(let error):
                    // A Unix socket that refuses a connection doesn't get better by waiting.
                    once.run {
                        connection.cancel()
                        if case .posix(let code) = error, code == .ECONNREFUSED || code == .ENOENT {
                            continuation.resume(throwing: TransportError.notListening(path))
                        } else {
                            continuation.resume(throwing: TransportError.failed(error.localizedDescription))
                        }
                    }
                case .cancelled:
                    once.run { continuation.resume(throwing: TransportError.failed("The connection to \(path) was cancelled.")) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    public func send(_ data: Data) async throws {
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: TransportError.failed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receive() async throws -> Data? {
        let connection = connection
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    if case .posix(let code) = error, code == .ECANCELED {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: TransportError.failed(error.localizedDescription))
                    }
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    public func close() {
        connection.cancel()
    }
}

/// Runs a closure the first time only, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
