import CodeEditing
import ContinuumKit
import CoreGraphics
import Foundation
import Simulation
import Stage
import Testing
import Transport
@testable import Assistant

/// A client's end of an MCP connection: sends requests, reads answers by id.
actor TestClient {
    private let stream: any ByteStream
    private var buffer = Data()
    private var nextID = 0

    init(_ stream: any ByteStream) { self.stream = stream }

    func send(_ message: JSONValue) async throws {
        try await stream.send(Data((message.text() + "\n").utf8))
    }

    func request(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        nextID += 1
        let id = nextID
        try await send(["jsonrpc": "2.0", "id": .number(id), "method": .string(method), "params": params])
        while true {
            let message = try await next()
            if message["id"] == .number(id) { return message }
        }
    }

    func next() async throws -> JSONValue {
        while true {
            if let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex...end)
                return try JSONValue.parse(Data(line))
            }
            guard let data = try await stream.receive() else { throw CancellationError() }
            buffer.append(data)
        }
    }
}

/// A viewer over a simulated Continuum, with a canvas that opens a stage for the selected pipeline.
@MainActor
final class TestViewer: Viewer {
    let continuum = Continuum()
    var selection: MeepAddress? {
        didSet { openCanvas() }
    }
    private(set) var stage: PipelineStage?
    var images = 0
    private var session: HostSession?

    init(statsEvery: Duration = .milliseconds(40)) async throws {
        let host = continuum.add(host: "sim", title: "Simulated", kind: .simulated)
        let link = SimulatedHost(name: "sim", latency: .milliseconds(1))
        let session = HostSession(host: host, settings: .init(statsEvery: statsEvery, watchedStatsEvery: .milliseconds(40), listEvery: .milliseconds(40))) { link }
        session.start()
        self.session = session
        let deadline = ContinuousClock.now + .seconds(5)
        // Rates need two readings, so wait for them only when counts come quickly.
        let waitsForRates = statsEvery < .seconds(1)
        while host.pipeline("orders")?.links.first?.isCounted != true || (waitsForRates && host.pipeline("orders")?.modules.first?.rates[.emitted] == 0) {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func stop() { session?.stop() }

    func select(_ address: MeepAddress) { selection = address }

    var reveals = 0
    func reveal() { reveals += 1 }

    func document(for pipeline: MeepPipeline) -> MeeplangDocument? { nil }
    var showsText: Bool { false }
    var language: LanguageService? { nil }

    func canvasImage() -> CGImage? {
        images += 1
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context?.makeImage()
    }

    /// As the app's canvas does: a stage for a selected pipeline, drawn once so it's laid out.
    private func openCanvas() {
        guard let selection, let pipeline = continuum.pipeline(at: selection) else {
            stage = nil
            return
        }
        guard stage?.pipeline !== pipeline else { return }
        let stage = PipelineStage(pipeline: pipeline, host: continuum.host(selection.host))
        _ = stage.frame(at: ProcessInfo.processInfo.systemUptime, viewSize: CGSize(width: 1000, height: 600))
        self.stage = stage
    }
}

@MainActor
struct MCPSessionTests {
    private func connect() async throws -> (TestClient, TestViewer, MCPSession) {
        let viewer = try await TestViewer()
        let (server, client) = MemoryStream.pair()
        let session = MCPSession(
            stream: server, registry: ContinuumTools.registry(for: viewer),
            info: .init(name: "synesthesia", title: "Synesthesia", version: "0.1", instructions: ContinuumTools.instructions)
        )
        Task { await session.run() }
        return (TestClient(client), viewer, session)
    }

    @Test func itIntroducesItselfAndListsItsTools() async throws {
        let (client, viewer, session) = try await connect()
        defer { viewer.stop() }
        let hello = try await client.request("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "claude-code", "version": "2.1"],
        ])
        #expect(hello["result"]?["protocolVersion"] == "2025-06-18")
        #expect(hello["result"]?["serverInfo"]?["name"] == "synesthesia")
        #expect(hello["result"]?["capabilities"]?["tools"] != nil)
        #expect(hello["result"]?["instructions"]?.string?.contains("meep://") == true)
        #expect(await session.client == "claude-code 2.1")
        try await client.send(["jsonrpc": "2.0", "method": "notifications/initialized"])

        let tools = try await client.request("tools/list")
        let names = tools["result"]?["tools"]?.array?.compactMap { $0["name"]?.string }
        #expect(names == ["list_continuum", "describe_pipeline", "read_pipeline_text", "describe_verbs", "watch_counts", "describe_view", "capture_view", "show"])
        for tool in tools["result"]?["tools"]?.array ?? [] {
            #expect(tool["inputSchema"]?["type"] == "object")
            #expect(tool["description"]?.string?.isEmpty == false)
        }
        #expect(try await client.request("ping")["result"] == [:])
    }

    @Test func anUnknownVersionGetsTheNewest() async throws {
        let (client, viewer, _) = try await connect()
        defer { viewer.stop() }
        let hello = try await client.request("initialize", ["protocolVersion": "2099-01-01"])
        #expect(hello["result"]?["protocolVersion"] == .string(MCPSession.protocolVersions[0]))
    }

    @Test func mistakesGetErrorsNotSilence() async throws {
        let (client, viewer, _) = try await connect()
        defer { viewer.stop() }
        #expect(try await client.request("resources/list")["error"]?["code"] == -32601)
        #expect(try await client.request("tools/call", ["name": "no_such_tool"])["error"]?["code"] == -32602)
        let failed = try await client.request("tools/call", ["name": "describe_pipeline", "arguments": ["address": "meep://sim/nothing"]])
        #expect(failed["result"]?["isError"] == true)
        #expect(failed["result"]?["content"]?.array?.first?["text"]?.string?.contains("orders") == true, "it says what there is")
        try await client.send("not json")
        // A line that isn't JSON gets a parse error, and the session carries on.
        #expect(try await client.next()["error"]?["code"] == -32700)
        #expect(try await client.request("ping")["result"] == [:])
    }

    @Test func aCancelledCallIsntAnswered() async throws {
        let (client, viewer, _) = try await connect()
        defer { viewer.stop() }
        try await client.send([
            "jsonrpc": "2.0", "id": 99, "method": "tools/call",
            "params": ["name": "watch_counts", "arguments": ["address": "meep://sim/orders", "seconds": 30]],
        ])
        try await client.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 99]])
        // The next answer is the ping's, not the cancelled call's.
        let answer = try await client.request("ping")
        #expect(answer["result"] == [:])
    }

    @Test func callsRunSideBySide() async throws {
        let (client, viewer, _) = try await connect()
        defer { viewer.stop() }
        let start = ContinuousClock.now
        async let slow = client.request("tools/call", ["name": "watch_counts", "arguments": ["address": "meep://sim/ticker", "seconds": 1]])
        let quick = try await client.request("tools/call", ["name": "list_continuum"])
        #expect(ContinuousClock.now - start < .milliseconds(900), "the quick call didn't wait for the slow one")
        #expect(quick["result"]?["isError"] == false)
        #expect(try await slow["result"]?["isError"] == false)
    }
}

@MainActor
struct ToolTests {
    private func call(_ registry: ToolRegistry, _ name: String, _ arguments: JSONValue = [:]) async throws -> (JSONValue?, ToolResult) {
        let result = try #require(await registry.call(name, arguments: arguments))
        guard case .text(let text)? = result.content.first else { return (nil, result) }
        return (try? JSONValue.parse(Data(text.utf8)), result)
    }

    @Test func theContinuumIsListed() async throws {
        let viewer = try await TestViewer()
        defer { viewer.stop() }
        let (json, _) = try await call(ContinuumTools.registry(for: viewer), "list_continuum")
        let host = try #require(json?["hosts"]?.array?.first)
        #expect(host["address"] == "meep://sim")
        #expect(host["status"] == "connected")
        #expect(host["pipelines"]?.array?.compactMap { $0["address"]?.string } == ["meep://sim/orders", "meep://sim/ticker", "meep://sim/sensors", "meep://sim/warehouse"])
        #expect((host["pipelines"]?.array?.first?["messagesPerSecond"]?.number ?? 0) > 0)
    }

    @Test func aPipelineIsDescribedWithItsCounts() async throws {
        let viewer = try await TestViewer()
        defer { viewer.stop() }
        let (json, _) = try await call(ContinuumTools.registry(for: viewer), "describe_pipeline", ["address": "meep://sim/orders"])
        let modules = try #require(json?["modules"]?.array)
        #expect(modules.map { $0["key"]?.string } == ["m1", "m2", "m3", "m4", "m5", "m6"])
        let valid = modules[1]
        #expect(valid["label"] == "Valid" && valid["role"] == "filter" && valid["verb"] == "Where")
        #expect((valid["counts"]?["received"]?.number ?? 0) > 0)
        #expect(valid["perSecond"]?["received"] != nil)
        let links = try #require(json?["links"]?.array)
        #expect(links.first { $0["key"] == "m3>m6" }?["port"] == "errors")
        #expect(json?["countsAreCurrent"] == true)
    }

    @Test(arguments: ["meep://sim/orders/m3", "sim/orders/m3", "orders/m3", "orders/Prices", "meep://sim/orders/3", "meep://sim/orders/%233"])
    func modulesAreFoundByKeyNameLabelOrNumber(address: String) async throws {
        let viewer = try await TestViewer()
        defer { viewer.stop() }
        let (_, _, module) = try ContinuumTools.resolve(.string(address), in: viewer, needsPipeline: true)
        #expect(module?.key == "m3", "\(address)")
    }

    @Test func countsAreWatchedOverAPeriod() async throws {
        let viewer = try await TestViewer(statsEvery: .seconds(10))
        defer { viewer.stop() }
        let registry = ContinuumTools.registry(for: viewer)
        let (json, _) = try await call(registry, "watch_counts", ["address": "meep://sim/orders/m2", "seconds": 1])
        #expect((json?["seconds"]?.number ?? 0) >= 1)
        let module = try #require(json?["modules"]?.array?.first)
        #expect(json?["modules"]?.array?.count == 1)
        #expect((module["rose"]?["received"]?.number ?? 0) > 50, "watching sped the counts up from every 10 seconds")
        #expect(json?["links"]?.array?.compactMap { $0["key"]?.string }.sorted() == ["m1>m2", "m2>m3"])
        #expect(viewer.continuum.pipeline(at: MeepAddress("meep://sim/orders")!)?.watchers == 0)
    }

    @Test func showingAModuleOpensItsPipelineAndMovesTheCanvas() async throws {
        let viewer = try await TestViewer()
        defer { viewer.stop() }
        let registry = ContinuumTools.registry(for: viewer)
        let (json, _) = try await call(registry, "show", ["address": "meep://sim/warehouse/Enrich"])
        #expect(json?["shown"] == "meep://sim/warehouse/m5")
        #expect(viewer.selection == MeepAddress("meep://sim/warehouse"))
        #expect(viewer.stage?.selection == ["m5"])
        #expect(viewer.reveals == 1, "the window is opened if it was closed")

        let (view, _) = try await call(registry, "describe_view")
        #expect(view?["canvas"]?["pipeline"] == "meep://sim/warehouse")
        let tiles = try #require(view?["canvas"]?["tiles"]?.array)
        #expect(tiles.count == 11)
        let enrich = try #require(tiles.first { $0["address"] == "meep://sim/warehouse/m5" })
        #expect(enrich["selected"] == true)
        #expect(enrich["label"]?.array?.first == "Enrich")
        #expect(view?["canvas"]?["wires"]?.array?.count == 10)

        let (_, image) = try await call(registry, "capture_view")
        guard case .png(let png)? = image.content.first else {
            Issue.record("capture_view gave no image")
            return
        }
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func withNothingOnTheCanvasTheToolsSaySo() async throws {
        let viewer = try await TestViewer()
        defer { viewer.stop() }
        let registry = ContinuumTools.registry(for: viewer)
        let (view, _) = try await call(registry, "describe_view")
        #expect(view?["canvas"] == .null)
        let (_, image) = try await call(registry, "capture_view")
        #expect(image.isError)
        let (shown, _) = try await call(registry, "show", ["address": "meep://sim"])
        #expect(shown?["shown"] == "meep://sim")
        #expect(viewer.selection == MeepAddress("meep://sim"))
    }

    @Test func textComesFromTheDaemonAndSaysWhenThereIsNone() async throws {
        let viewer = try await TestViewer()
        defer { viewer.stop() }
        // The simulated host's demo pipelines have no Meeplang.
        let (_, result) = try await call(ContinuumTools.registry(for: viewer), "read_pipeline_text", ["address": "orders"])
        #expect(result.isError)
        guard case .text(let message)? = result.content.first else { Issue.record("no text"); return }
        #expect(message.contains("has none"))
    }

    @Test func verbsNeedALanguageServer() async throws {
        let viewer = try await TestViewer()
        defer { viewer.stop() }
        let (_, result) = try await call(ContinuumTools.registry(for: viewer), "describe_verbs", ["verb": "Fetch"])
        #expect(result.isError)
    }
}

struct JSONValueTests {
    @Test func valuesKeepTheirKinds() throws {
        let text = #"{"a":1,"b":true,"c":1.5,"d":"x","e":null,"f":[1,false]}"#
        let value = try JSONValue.parse(Data(text.utf8))
        #expect(value["a"] == .number(1))
        #expect(value["b"] == .bool(true))
        #expect(value["c"] == .number(1.5))
        #expect(value["e"] == .null)
        #expect(value["f"] == [1, false])
        #expect(value.text() == text, "whole numbers are written without a point")
    }
}

struct SocketServerTests {
    private func temporaryPath() -> String {
        // Short, since a socket's path can be at most 103 bytes.
        "/tmp/syn-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test func connectionsAreServedAndTheFileRemoved() async throws {
        let path = temporaryPath()
        let server = try UnixSocketServer.listen(path: path) { stream in
            Task {
                while let data = try? await stream.receive() {
                    try? await stream.send(Data("echo ".utf8) + data)
                }
                stream.close()
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let client = try SocketStream.connect(path: path)
        try await client.send(Data("hello".utf8))
        #expect(try await client.receive() == Data("echo hello".utf8))
        client.close()
        #expect(throws: UnixSocketServer.Failure.alreadyServed(path)) {
            try UnixSocketServer.listen(path: path) { _ in }
        }
        server.close()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func aFileLeftBehindIsReplaced() throws {
        let path = temporaryPath()
        FileManager.default.createFile(atPath: path, contents: Data())
        let server = try UnixSocketServer.listen(path: path) { _ in }
        server.close()
    }

    @Test func aPathTooLongIsRefused() {
        let path = "/tmp/" + String(repeating: "x", count: 120)
        #expect(throws: UnixSocketServer.Failure.pathTooLong(path)) { try UnixSocketServer.listen(path: path) { _ in } }
    }
}

/// The bridge program, as Claude Code runs it, against a server in the test.
@MainActor
struct BridgeTests {
    nonisolated static var bridge: URL? {
        // Tests run from the package's build folder, beside the programs it built.
        var folder = URL(fileURLWithPath: #filePath)
        while folder.path != "/", !FileManager.default.fileExists(atPath: folder.appendingPathComponent("Package.swift").path) {
            folder.deleteLastPathComponent()
        }
        let built = folder.appendingPathComponent(".build/debug/synesthesia-mcp")
        return FileManager.default.isExecutableFile(atPath: built.path) ? built : nil
    }

    @Test(.enabled(if: BridgeTests.bridge != nil, "needs swift build to have built synesthesia-mcp"))
    func theBridgeCarriesTheProtocol() async throws {
        let viewer = try await TestViewer()
        defer { viewer.stop() }
        let registry = ContinuumTools.registry(for: viewer)
        let path = "/tmp/syn-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixSocketServer.listen(path: path) { stream in
            Task { await MCPSession(stream: stream, registry: registry, info: .init(name: "synesthesia", title: "Synesthesia", version: "0.1", instructions: "")).run() }
        }
        defer { server.close() }

        let process = Process()
        process.executableURL = BridgeTests.bridge
        process.arguments = ["--socket", path, "--no-launch"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_continuum","arguments":{}}}"#,
        ]
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        var received = Data()
        let deadline = ContinuousClock.now + .seconds(10)
        while String(decoding: received, as: UTF8.self).split(separator: "\n").count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            received.append(output.fileHandleForReading.availableDataNonBlocking)
        }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let answers = String(decoding: received, as: UTF8.self).split(separator: "\n").compactMap { try? JSONValue.parse(Data($0.utf8)) }
        #expect(answers.first { $0["id"] == 1 }?["result"]?["serverInfo"]?["name"] == "synesthesia")
        #expect(answers.first { $0["id"] == 2 }?["result"]?["isError"] == false)
        #expect(process.terminationStatus == 0, "it ends when its client does")
    }

    @Test(.enabled(if: BridgeTests.bridge != nil, "needs swift build to have built synesthesia-mcp"))
    func withNoAppItSaysSo() throws {
        let process = Process()
        process.executableURL = BridgeTests.bridge
        process.arguments = ["--socket", "/tmp/syn-nothing-here.sock", "--no-launch"]
        let errors = Pipe()
        process.standardError = errors
        process.standardInput = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 1)
        #expect(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("isn't serving MCP"))
    }
}

extension FileHandle {
    /// What's waiting to be read, without waiting for more.
    var availableDataNonBlocking: Data {
        let descriptor = fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(descriptor, F_SETFL, flags) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }
}
