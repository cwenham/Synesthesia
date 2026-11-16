// synesthesia-mcp: joins an MCP client's standard input and output to the Synesthesia app's MCP socket, for clients
// such as Claude Code that start a server as a program (design, section 8). It's a plain pipe: the app speaks the
// protocol. If the app isn't running, it starts it and waits for the socket.
//
// Usage: synesthesia-mcp [--socket <path>] [--no-launch]

import Darwin
import Foundation
import Transport

@main
enum Bridge {
    static func main() {
        signal(SIGPIPE, SIG_IGN)

        var socketPath = MCPSocket.defaultPath
        var launches = true
        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--socket": socketPath = arguments.next() ?? socketPath
            case "--no-launch": launches = false
            default:
                FileHandle.standardError.write(Data("usage: synesthesia-mcp [--socket <path>] [--no-launch]\n".utf8))
                exit(2)
            }
        }

        var descriptor = connect(to: socketPath)
        if descriptor == nil, launches {
            // Start the app this program is inside, or the one Launch Services knows, in the background.
            let bundle = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = bundle.pathExtension == "app" ? ["-g", bundle.path] : ["-g", "-b", "com.synesthesia.mac"]
            try? open.run()
            open.waitUntilExit()
            let deadline = Date().addingTimeInterval(20)
            while descriptor == nil, Date() < deadline {
                usleep(250_000)
                descriptor = connect(to: socketPath)
            }
        }
        guard let socket = descriptor else {
            say("Synesthesia isn't serving MCP at \(socketPath). Is the app running?")
            exit(1)
        }

        let toApp = Thread {
            pump(from: STDIN_FILENO, to: socket)
            // The client has finished: say so, and let the app's answers drain.
            shutdown(socket, SHUT_WR)
        }
        toApp.start()
        pump(from: socket, to: STDOUT_FILENO)
        exit(0)
    }

    static func connect(to socketPath: String) -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(socketPath.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected == 0 { return descriptor }
        close(descriptor)
        return nil
    }

    static func say(_ message: String) {
        FileHandle.standardError.write(Data("synesthesia-mcp: \(message)\n".utf8))
    }

    /// Copies everything from one descriptor to another until the first ends.
    @Sendable static func pump(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            var sent = 0
            while sent < count {
                let wrote = buffer.withUnsafeBytes { write(destination, $0.baseAddress! + sent, count - sent) }
                if wrote < 0, errno == EINTR { continue }
                guard wrote > 0 else { return }
                sent += wrote
            }
        }
    }
}
