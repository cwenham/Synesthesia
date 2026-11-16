import Darwin
import Foundation

/// Where the app serves MCP: `$SYNESTHESIA_MCP_SOCKET`, or `~/Library/Application Support/Synesthesia/mcp.sock`.
/// The app and `synesthesia-mcp` both look here.
public enum MCPSocket {
    public static var defaultPath: String {
        if let path = ProcessInfo.processInfo.environment["SYNESTHESIA_MCP_SOCKET"], !path.isEmpty { return path }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Synesthesia/mcp.sock").path
    }
}

/// Listens on a Unix domain socket and hands each connection over as a ``ByteStream``, as the app does for its MCP
/// server. The socket file is readable and writable only by its owner.
public final class UnixSocketServer: @unchecked Sendable {
    public let path: String
    private let listener: Int32
    private let source: DispatchSourceRead

    public enum Failure: Error, Equatable, LocalizedError {
        /// The path is longer than a Unix socket's 104 bytes.
        case pathTooLong(String)
        /// Something else is already listening there, such as another copy of the app.
        case alreadyServed(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .pathTooLong(let path): "\(path) is too long for a Unix socket, which can have at most 103 bytes."
            case .alreadyServed(let path): "Something is already listening on \(path)."
            case .failed(let reason): reason
            }
        }
    }

    private init(path: String, listener: Int32, accept: @escaping @Sendable (SocketStream) -> Void) {
        self.path = path
        self.listener = listener
        source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: DispatchQueue(label: "UnixSocketServer"))
        source.setEventHandler { [listener] in
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            accept(SocketStream(descriptor: client))
        }
        source.setCancelHandler { [listener] in Darwin.close(listener) }
        source.resume()
    }

    /// Starts listening on `path`, making its folder if need be. A socket file left by an earlier run is replaced;
    /// one something is still listening on isn't.
    public static func listen(path: String, accept: @escaping @Sendable (SocketStream) -> Void) throws -> UnixSocketServer {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw Failure.pathTooLong(path) }
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: path) {
            if let live = try? SocketStream.connect(path: path) {
                live.close()
                throw Failure.alreadyServed(path)
            }
            unlink(path)
        }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure.failed("Couldn't make a socket: \(String(cString: strerror(errno))).") }
        var address = sockaddr_un(path: path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(listener, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(listener)
            throw Failure.failed("Couldn't listen on \(path): \(reason).")
        }
        return UnixSocketServer(path: path, listener: listener, accept: accept)
    }

    /// Stops listening and removes the socket file. Connections already made carry on.
    public func close() {
        source.cancel()
        unlink(path)
    }
}

/// A ``ByteStream`` over a connected socket's file descriptor.
public final class SocketStream: ByteStream, @unchecked Sendable {
    private let descriptor: Int32
    private let reads: DispatchSourceRead
    private let writes = DispatchQueue(label: "SocketStream.write")
    private let lock = NSLock()
    private var arrived: [Data] = []
    private var ended = false
    private var closed = false
    private var waiting: CheckedContinuation<Data?, any Error>?

    init(descriptor: Int32) {
        self.descriptor = descriptor
        var on: Int32 = 1
        // A write to a socket the other end has closed fails instead of killing the process.
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        reads = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "SocketStream.read"))
        reads.setEventHandler { [weak self] in self?.readAvailable() }
        reads.resume()
    }

    /// Connects to a socket something is listening on.
    public static func connect(path: String) throws -> SocketStream {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TransportError.failed(String(cString: strerror(errno))) }
        var address = sockaddr_un(path: path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            throw TransportError.notListening(path)
        }
        return SocketStream(descriptor: descriptor)
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count > 0 {
            deliver(Data(buffer[0..<count]))
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            reads.cancel()
            deliver(nil)
        }
    }

    private func deliver(_ data: Data?) {
        lock.lock()
        if let waiting {
            self.waiting = nil
            lock.unlock()
            waiting.resume(returning: data)
            return
        }
        if let data { arrived.append(data) } else { ended = true }
        lock.unlock()
    }

    public func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !arrived.isEmpty {
                let data = arrived.removeFirst()
                lock.unlock()
                continuation.resume(returning: data)
            } else if ended || closed {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiting = continuation
                lock.unlock()
            }
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writes.async { [descriptor] in
                var sent = 0
                while sent < data.count {
                    let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + sent, data.count - sent) }
                    if count < 0 {
                        if errno == EINTR { continue }
                        continuation.resume(throwing: TransportError.failed("The socket closed: \(String(cString: strerror(errno)))."))
                        return
                    }
                    sent += count
                }
                continuation.resume()
            }
        }
    }

    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let waiting = self.waiting
        self.waiting = nil
        lock.unlock()
        waiting?.resume(returning: nil)
        reads.cancel()
        // Close once anything already sent has gone.
        writes.async { [descriptor] in
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }
}

extension sockaddr_un {
    init(path: String) {
        self.init()
        sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &sun_path) { raw in
            let bytes = Array(path.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
    }
}
