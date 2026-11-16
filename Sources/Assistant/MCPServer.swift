import Foundation
import Transport

/// The Model Context Protocol, served over one connection: JSON-RPC 2.0 messages, one to a line, as MCP's stdio
/// transport has them. The app serves it on a Unix socket, and `synesthesia-mcp` joins a client's standard input and
/// output to that socket.
///
/// Only what tools need is here: `initialize`, `ping`, `tools/list`, `tools/call` and cancelling a call. Requests
/// are handled at the same time, so a tool that waits doesn't hold up the others.
public actor MCPSession {
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let stream: any ByteStream
    private let registry: ToolRegistry
    private let info: ServerInfo
    private var buffer = Data()
    private var running: [JSONValue: Task<Void, Never>] = [:]
    /// The client's name and version, once it has said.
    public private(set) var client: String?

    public struct ServerInfo: Sendable {
        public var name: String
        public var title: String
        public var version: String
        /// What the server is for and how to use it, which clients show to the model.
        public var instructions: String

        public init(name: String, title: String, version: String, instructions: String) {
            self.name = name
            self.title = title
            self.version = version
            self.instructions = instructions
        }
    }

    public init(stream: any ByteStream, registry: ToolRegistry, info: ServerInfo) {
        self.stream = stream
        self.registry = registry
        self.info = info
    }

    /// Serves the connection until the client closes it.
    public func run() async {
        while let data = try? await stream.receive() {
            buffer.append(data)
            while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex...end)
                guard !line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }) else { continue }
                await handle(Data(line))
            }
        }
        for task in running.values { task.cancel() }
        stream.close()
    }

    private func handle(_ line: Data) async {
        guard let message = try? JSONValue.parse(line), case .object = message else {
            await send(error: -32700, message: "That isn't JSON.", id: .null)
            return
        }
        let id = message["id"]
        guard let method = message["method"]?.string else {
            return // A response to something the server asked; it asks nothing yet.
        }
        let params = message["params"] ?? [:]
        guard let id else {
            notified(method, params: params)
            return
        }
        switch method {
        case "initialize":
            if let name = params["clientInfo"]?["name"]?.string {
                client = [name, params["clientInfo"]?["version"]?.string].compactMap { $0 }.joined(separator: " ")
            }
            let asked = params["protocolVersion"]?.string ?? Self.protocolVersions[0]
            let version = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
            await send(result: [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(info.name), "title": .string(info.title), "version": .string(info.version)],
                "instructions": .string(info.instructions),
            ], id: id)
        case "ping":
            await send(result: [:], id: id)
        case "tools/list":
            await send(result: ["tools": .array(registry.tools.map(\.definition))], id: id)
        case "tools/call":
            guard let name = params["name"]?.string else {
                await send(error: -32602, message: "tools/call needs the tool's name.", id: id)
                return
            }
            guard registry.tool(name) != nil else {
                await send(error: -32602, message: "There's no tool called \(name).", id: id)
                return
            }
            let arguments = params["arguments"] ?? [:]
            let registry = registry
            running[id] = Task {
                let result = await registry.call(name, arguments: arguments) ?? .failure("There's no tool called \(name).")
                await self.finish(id, result: result)
            }
        default:
            await send(error: -32601, message: "This server doesn't do \(method).", id: id)
        }
    }

    private func finish(_ id: JSONValue, result: ToolResult) async {
        guard running.removeValue(forKey: id) != nil else { return } // Cancelled: no answer is due.
        await send(result: result.mcp, id: id)
    }

    private func notified(_ method: String, params: JSONValue) {
        if method == "notifications/cancelled", let id = params["requestId"] {
            running.removeValue(forKey: id)?.cancel()
        }
    }

    private func send(result: JSONValue, id: JSONValue) async {
        await write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(error code: Int, message: String, id: JSONValue) async {
        await write(["jsonrpc": "2.0", "id": id, "error": ["code": .number(code), "message": .string(message)]])
    }

    private func write(_ message: JSONValue) async {
        try? await stream.send(Data((message.text() + "\n").utf8))
    }
}
