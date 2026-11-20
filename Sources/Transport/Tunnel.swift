import Foundation

/// A Meep daemon on another machine, reached by forwarding its Unix socket over SSH (`ssh -L`), as Meep2's step 7
/// planned: the daemon sees a connection from its own user, through sshd, and gives it every capability, as it would
/// locally. Nothing is opened to anyone else: ssh makes the local end of the forward readable only by you.
public struct SSHTarget: Codable, Sendable, Hashable {
    /// Where to log in: `user@host`, `host`, or a name from `~/.ssh/config`.
    public var destination: String
    /// The SSH port, when it isn't 22 or what `~/.ssh/config` says.
    public var port: Int?
    /// The daemon's socket on the host, in full. When it's nil, `meep daemon socket` is asked for it first.
    public var remoteSocket: String?
    /// How to run meep on the host, for `meep daemon socket`: `meep`, unless it isn't on the `PATH` a non-interactive
    /// shell there has, or its daemon has a `MEEP_HOME` of its own (`MEEP_HOME=/srv/meep /opt/meep/meep`).
    public var meepCommand: String
    /// Other options for ssh, such as `-i ~/.ssh/lab -J gateway`, for what `~/.ssh/config` doesn't say.
    public var options: [String]

    public init(destination: String, port: Int? = nil, remoteSocket: String? = nil, meepCommand: String = "meep", options: [String] = []) {
        self.destination = destination
        self.port = port
        self.remoteSocket = remoteSocket
        self.meepCommand = meepCommand
        self.options = options
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        destination = try c.decode(String.self, forKey: .destination)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        remoteSocket = try c.decodeIfPresent(String.self, forKey: .remoteSocket)
        meepCommand = try c.decodeIfPresent(String.self, forKey: .meepCommand) ?? "meep"
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
    }

    /// The destination with its port, as people write it: `pi@lab-2:2222`.
    public var description: String {
        port.map { "\(destination):\($0)" } ?? destination
    }
}

/// A way through to a daemon on another machine, open until it's closed.
public protocol Tunnel: Sendable {
    /// How it reaches the daemon, for people: forwarded to a local socket, or relayed through the SSH session.
    var route: String { get }
    /// The daemon's ID, as `meep daemon socket` printed it, to check against the daemon's own once connected; nil when
    /// the socket was given rather than asked for.
    var expectedID: String? { get }
    /// A new connection to the daemon through it.
    func connect() async throws -> any ByteStream
    /// Closes it. Connections through it end.
    func close()
}

/// Opens tunnels to daemons on other machines: ssh on the Mac; mutual TLS later, on every platform (design, section 9).
public protocol TunnelProvider: Sendable {
    func open(_ target: SSHTarget) async throws -> any Tunnel
}

/// Why a tunnel couldn't be opened, in words for the person.
public struct TunnelError: Error, Equatable, LocalizedError {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

#if os(macOS)
/// Tunnels made with the Mac's own `ssh`, which uses the person's keys, agent and `~/.ssh/config`. It never asks for a
/// password (`BatchMode`): a host needs a key that logs in without one.
///
/// It forwards the daemon's socket to a local one (`ssh -L`), as Meep2's report on prompt 5 describes. Where the host's
/// sshd won't forward sockets (`AllowStreamLocalForwarding no`, `DisableForwarding`, or an sshd not running as root),
/// it relays the socket through the SSH session instead, with `nc -U` on the host: the daemon still sees its own user,
/// and nothing listens on this Mac.
public struct SSHTunnelProvider: TunnelProvider {
    public var ssh: String
    /// Where the local ends go: kept short, as a Unix socket's path can have at most 103 bytes.
    public var folder: String

    public init(ssh: String = "/usr/bin/ssh", folder: String? = nil) {
        self.ssh = ssh
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.folder = folder ?? support.appendingPathComponent("Synesthesia/tunnels").path
    }

    /// The options every ssh here has: no prompts, a time limit to connect, and keep-alives so a dead link is noticed.
    func options(_ target: SSHTarget) -> [String] {
        var options = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]
        if let port = target.port { options += ["-p", String(port)] }
        return options + target.options
    }

    public func open(_ target: SSHTarget) async throws -> any Tunnel {
        var remote = target.remoteSocket.flatMap { $0.isEmpty ? nil : $0 }
        var expectedID: String?
        if remote == nil {
            let said = try await run(options(target) + [target.destination, "\(target.meepCommand) daemon socket"], target: target)
            let lines = said.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let socket = lines.first, socket.hasPrefix("/") else {
                throw TunnelError("\(target.description) didn't say where its daemon's socket is: \(said)")
            }
            remote = socket
            expectedID = lines.count > 1 ? lines[1] : nil
        }
        guard let remote else { throw TunnelError("\(target.description) didn't say where its daemon's socket is.") }
        do {
            return try await forward(target, to: remote, expectedID: expectedID)
        } catch let refused as ForwardRefused {
            // The host won't forward sockets: relay through the session instead, if it has nc.
            do {
                _ = try await run(options(target) + [target.destination, "command -v nc"], target: target)
            } catch {
                throw TunnelError("\(target.description) wouldn't forward the daemon's socket (\(refused.said)), and has no nc to relay it through the SSH session instead.")
            }
            return RelayTunnel(ssh: ssh, arguments: options(target) + [target.destination, "nc -U '\(remote)'"], target: target,
                               expectedID: expectedID, refused: refused.said)
        }
    }

    /// The forward was set up, but the host's sshd refused to connect it to the daemon's socket.
    struct ForwardRefused: Error {
        var said: String
    }

    /// Forwards the daemon's socket to a local one, and checks something answers through it.
    func forward(_ target: SSHTarget, to remote: String, expectedID: String?) async throws -> any Tunnel {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let local = (folder as NSString).appendingPathComponent("\(Self.shortName(for: "\(target.description) \(remote)")).sock")
        guard local.utf8.count < 104 else { throw TunnelError("\(local) is too long for a Unix socket.") }
        try? FileManager.default.removeItem(atPath: local)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ssh)
        process.arguments = ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindUnlink=yes"] + options(target)
            + ["-L", "\(local):\(remote)", target.destination]
        let errors = Collected()
        let pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { handle in errors.append(handle.availableData) }
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw TunnelError("Couldn't start \(ssh): \(error.localizedDescription)")
        }
        let tunnel = ForwardTunnel(process: process, localSocket: local, expectedID: expectedID)
        // The forward is ready once its local end exists; ssh leaving before then means it failed, and says why.
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: local) {
            if !process.isRunning {
                try await Task.sleep(for: .milliseconds(50))
                throw TunnelError(Self.explain(errors.text, target: target, forwarding: true))
            }
            if Date() > deadline {
                tunnel.close()
                throw TunnelError("ssh to \(target.description) didn't open the forward within 20 seconds.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Something must answer through it: an sshd can set up the forward and then refuse each connection.
        if try await !Self.answers(local) {
            tunnel.close()
            try await Task.sleep(for: .milliseconds(100))
            let said = errors.text
            if said.contains("open failed") || said.contains("prohibited") || said.contains("denied") {
                throw ForwardRefused(said: said.split(whereSeparator: \.isNewline).last.map(String.init) ?? said)
            }
            throw TunnelError("Nothing answered through the forward to \(remote) on \(target.description). \(said)")
        }
        return tunnel
    }

    /// Whether the daemon answers a plain request through a local socket within a few seconds.
    static func answers(_ path: String) async throws -> Bool {
        let stream = try await UnixSocketStream.connect(path: path)
        defer { stream.close() }
        try await stream.send(Data("GET / HTTP/1.1\r\nHost: meep\r\nConnection: close\r\n\r\n".utf8))
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { ((try? await stream.receive()) ?? nil)?.isEmpty == false }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            stream.close()
            return first
        }
    }

    /// Runs ssh to completion, returning what it printed, or throwing what it said went wrong.
    func run(_ arguments: [String], target: SSHTarget) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ssh)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: TunnelError("Couldn't start \(ssh): \(error.localizedDescription)"))
            }
        }
        let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let complaint = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw TunnelError(Self.explain(complaint.isEmpty ? said : complaint, target: target, forwarding: false, status: process.terminationStatus))
        }
        return said
    }

    /// What ssh said, put plainly, with what to do about the usual problems.
    static func explain(_ said: String, target: SSHTarget, forwarding: Bool, status: Int32 = 0) -> String {
        let text = said.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("Warning: Permanently added") }
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if status == 127 || text.contains("command not found") {
            return "meep isn't on the PATH a non-interactive shell has on \(target.description). Give its full path, or the daemon's socket, in the host's settings. (\(text))"
        }
        if text.contains("Permission denied") {
            return "\(target.description) didn't accept a key. Synesthesia can't type a password, so the host needs a key that logs in without one, through ssh-agent or ~/.ssh/config. (\(text))"
        }
        if text.contains("Host key verification failed") {
            return "\(target.description)'s host key isn't known yet. Log in once with ssh in a terminal to check and keep it. (\(text))"
        }
        return text.isEmpty ? "ssh to \(target.description) ended without saying why." : text
    }

    /// A short, stable name for a tunnel's local socket.
    static func shortName(for text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 36)
    }
}

/// What a program has written so far, gathered as it comes.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ more: Data) {
        lock.withLock { data.append(more) }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// An `ssh -N -L` running for one tunnel: connections go to its local end.
final class ForwardTunnel: Tunnel, @unchecked Sendable {
    let localSocket: String
    let expectedID: String?
    private let process: Process

    init(process: Process, localSocket: String, expectedID: String?) {
        self.process = process
        self.localSocket = localSocket
        self.expectedID = expectedID
    }

    var route: String { "socket forwarded to \(localSocket)" }

    func connect() async throws -> any ByteStream {
        guard process.isRunning else { throw TunnelError("The SSH forward has ended.") }
        return try await UnixSocketStream.connect(path: localSocket)
    }

    func close() {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(atPath: localSocket)
    }

    deinit { close() }
}

/// Each connection an `ssh host nc -U <socket>` of its own, its standard input and output joined to the daemon's
/// socket through the SSH session.
final class RelayTunnel: Tunnel, @unchecked Sendable {
    let expectedID: String?
    private let ssh: String
    private let arguments: [String]
    private let target: SSHTarget
    /// Why the forward was refused, for people.
    private let refused: String
    private let lock = NSLock()
    private var processes: [Process] = []
    private var closed = false

    init(ssh: String, arguments: [String], target: SSHTarget, expectedID: String?, refused: String) {
        self.ssh = ssh
        self.arguments = arguments
        self.target = target
        self.expectedID = expectedID
        self.refused = refused
    }

    var route: String { "relayed through the SSH session with nc, since the host wouldn't forward the socket (\(refused))" }

    func connect() async throws -> any ByteStream {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ssh)
        process.arguments = arguments
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try lock.withLock {
            guard !closed else { throw TunnelError("The tunnel to \(target.description) is closed.") }
            try process.run()
            processes.removeAll { !$0.isRunning }
            processes.append(process)
        }
        return PipeStream(reading: output.fileHandleForReading, writing: input.fileHandleForWriting)
    }

    func close() {
        let running = lock.withLock {
            closed = true
            defer { processes = [] }
            return processes
        }
        for process in running where process.isRunning { process.terminate() }
    }

    deinit { close() }
}
#endif
