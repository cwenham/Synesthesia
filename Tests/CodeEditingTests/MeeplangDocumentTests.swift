import ContinuumKit
import Foundation
import LanguageClient
import MeepClient
import Simulation
import Testing
import Transport
@testable import CodeEditing

/// A stand-in for `meep lsp`, enough to test a document against: each line of text is a module, keyed `m` and its
/// line number unless a base says otherwise, and the first word of each line is coloured as a verb.
actor FakeLanguageServer {
    struct Received: Sendable {
        var method: String
        var json: Data
        var params: [String: Any] { (try? JSONSerialization.jsonObject(with: json) as? [String: Any]) ?? [:] }
    }

    private let stream: MemoryStream
    private(set) var received: [Received] = []
    private var texts: [String: (text: String, version: Int)] = [:]
    private var subscribed: Set<String> = []
    /// Keys a base gave, by line number from 1.
    private var baseKeys: [Int: String] = [:]
    private var lastKeys: [String] = []
    private var graphVersion = 0
    private var lastGraph = ""

    init(_ stream: MemoryStream) { self.stream = stream }

    static func start() async throws -> (MeepLanguageServer, FakeLanguageServer) {
        let (client, end) = MemoryStream.pair()
        let fake = FakeLanguageServer(end)
        Task { await fake.run() }
        return (try await MeepLanguageServer.start(over: client), fake)
    }

    func methods() -> [String] { received.map(\.method) }

    func run() async {
        var buffer = Data()
        while let data = try? await stream.receive() {
            buffer.append(data)
            while let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let length = Int(header.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))!
                guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { break }
                let body = buffer[end.upperBound..<buffer.index(end.upperBound, offsetBy: length)]
                buffer = Data(buffer[buffer.index(end.upperBound, offsetBy: length)...])
                await handle(Data(body))
            }
        }
    }

    private func handle(_ body: Data) async {
        let message = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        let method = message["method"] as! String
        let params = message["params"] as? [String: Any] ?? [:]
        received.append(Received(method: method, json: (try? JSONSerialization.data(withJSONObject: params)) ?? Data()))
        let uri = (params["textDocument"] as? [String: Any])?["uri"] as? String ?? ""
        var result: Any = NSNull()
        switch method {
        case "initialize":
            result = ["capabilities": [
                "semanticTokensProvider": ["legend": ["tokenTypes": ["function", "comment"], "tokenModifiers": ["declaration"]], "full": ["delta": false]],
                "hoverProvider": true,
                "experimental": ["meep": ["graph": true, "setBase": true, "verbs": true]],
            ]]
        case "textDocument/didOpen", "textDocument/didChange":
            let document = params["textDocument"] as! [String: Any]
            let text = (document["text"] as? String) ?? ((params["contentChanges"] as! [[String: Any]]).last!["text"] as! String)
            texts[uri] = (text, document["version"] as! Int)
            if subscribed.contains(uri) { await notify("meep/graphChanged", answer(uri)) }
        case "meep/graph":
            if params["subscribe"] as? Bool == true { subscribed.insert(uri) }
            result = answer(uri)
        case "meep/setBase":
            baseKeys = [:]
            for module in ((params["graph"] as? [String: Any])?["modules"] as? [[String: Any]]) ?? [] {
                baseKeys[module["number"] as! Int] = module["key"] as? String
            }
            result = answer(uri)
        case "textDocument/semanticTokens/full":
            let lines = (texts[uri]?.text ?? "").components(separatedBy: "\n")
            var data: [Int] = []
            var last = 0
            for (index, line) in lines.enumerated() {
                guard let word = line.split(separator: " ").first, let start = line.range(of: word)?.lowerBound else { continue }
                data += [index - last, line.distance(from: line.startIndex, to: start), word.count, line.hasPrefix("//") ? 1 : 0, 0]
                last = index
            }
            result = ["resultId": "1", "data": data]
        default:
            break
        }
        if let id = message["id"] { await send(["jsonrpc": "2.0", "id": id, "result": result]) }
    }

    /// The graph for a document's text now: a module for each line that isn't blank or a comment.
    private func answer(_ uri: String) -> [String: Any] {
        let (text, version) = texts[uri] ?? ("", 0)
        let path = URL(string: uri)!.path
        var modules: [[String: Any]] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() where !line.isEmpty && !line.hasPrefix("//") {
            let number = modules.count + 1
            let verb = String(line.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")
            let span: [String: Any] = ["file": path, "startLine": index + 1, "startColumn": 1, "endLine": index + 1, "endColumn": line.utf16.count + 1]
            modules.append([
                "key": baseKeys[number] ?? "m\(number)", "number": number, "module": "\(verb) #\(number)", "verb": verb, "role": "step",
                "inflections": [verb], "parameters": [], "modifiers": [], "span": span, "feeder": false,
            ])
        }
        let keys = modules.map { $0["key"] as! String }
        var renamed: [String: String] = [:]
        for (old, new) in zip(lastKeys, keys) where old != new && lastKeys.count == keys.count { renamed[old] = new }
        lastKeys = keys
        let description = keys.joined(separator: ",")
        if description != lastGraph { graphVersion += 1 }
        lastGraph = description
        let graph: [String: Any] = ["name": "test", "path": path, "version": graphVersion, "modules": modules, "links": []]
        var answer: [String: Any] = ["uri": uri, "version": version, "current": !text.contains("!!"), "graph": graph, "builtFrom": version, "problems": []]
        if !renamed.isEmpty { answer["renamed"] = renamed }
        return answer
    }

    private func notify(_ method: String, _ params: [String: Any]) async {
        await send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func publish(_ uri: String, message: String, line: Int) async {
        await notify("textDocument/publishDiagnostics", ["uri": uri, "diagnostics": [[
            "range": ["start": ["line": line, "character": 0], "end": ["line": line, "character": 3]], "severity": 1, "message": message,
        ]]])
    }

    private func send(_ message: [String: Any]) async {
        let body = try! JSONSerialization.data(withJSONObject: message)
        try? await stream.send(Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body)
    }
}

/// Waits up to ten seconds for `condition`: long, since other suites can keep the main actor busy.
@MainActor
func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
struct MeeplangDocumentTests {
    private func temporaryFile(_ text: String) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("synesthesia-doc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("test.meep").path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func service() async throws -> (LanguageService, FakeLanguageServer) {
        let (server, fake) = try await FakeLanguageServer.start()
        return (LanguageService { server }, fake)
    }

    @Test func openingAFileOpensItSubscribesAndColoursIt() async throws {
        let (service, fake) = try await service()
        let path = try temporaryFile("// a comment\nInterval 1s\nWriteLine \"x\"")
        let document = MeeplangDocument(path: path, text: try String(contentsOfFile: path, encoding: .utf8), service: service)
        #expect(await eventually { document.answer?.graph?.modules.count == 2 && !document.highlights.isEmpty })
        #expect(await fake.methods().prefix(4) == ["initialize", "initialized", "textDocument/didOpen", "meep/graph"])
        #expect(document.highlights.map(\.style) == [.comment, .verb, .verb])
        #expect(document.highlights[1].range == 13..<21)
        #expect(document.modulesByLine == [1: ["m1"], 2: ["m2"]])
        #expect(document.module(atLine: 2) == "m2")
        #expect(document.module(atLine: 0) == nil)
        #expect(document.range(of: "m2") == 25..<38)
        #expect(service.state == .running)
    }

    @Test func editsGoInOrderAndTheGraphFollows() async throws {
        let (service, fake) = try await service()
        let path = try temporaryFile("Interval 1s")
        let document = MeeplangDocument(path: path, text: "Interval 1s", service: service)
        #expect(await eventually { document.answer != nil })
        document.edit("Interval 1s\nWhere x")
        document.edit("Interval 1s\nWhere x\nWriteLine y")
        #expect(document.version == 3)
        #expect(document.status == .edited)
        #expect(await eventually { document.answer?.version == 3 && document.answer?.graph?.modules.count == 3 })
        let changes = await fake.received.filter { $0.method == "textDocument/didChange" }
        #expect(changes.map { ($0.params["textDocument"] as? [String: Any])?["version"] as? Int } == [2, 3])
        // Back to what's saved, it's no longer edited.
        document.edit("Interval 1s")
        #expect(document.status == .saved)
    }

    @Test func problemsArriveForTheirDocument() async throws {
        let (service, fake) = try await service()
        let path = try temporaryFile("Intervl 1s")
        let document = MeeplangDocument(path: path, text: "Intervl 1s", service: service)
        #expect(await eventually { document.answer != nil })
        await fake.publish(document.uri, message: "There's no verb called Intervl.", line: 0)
        await fake.publish("file:///elsewhere.meep", message: "Not this one.", line: 3)
        #expect(await eventually { !document.diagnostics.isEmpty })
        #expect(document.problemLines == ["Line 1: There's no verb called Intervl."])
    }

    @Test func savingWritesTheFileAndWaitsForTheDaemon() async throws {
        let (service, _) = try await service()
        let path = try temporaryFile("Interval 1s")
        let document = MeeplangDocument(path: path, text: "Interval 1s", service: service)
        document.reloadTimeout = .milliseconds(100)
        document.edit("Interval 2s")
        try document.save()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "Interval 2s")
        #expect(!document.isEdited)
        // Not running in a daemon: saved is all there is.
        #expect(document.status == .saved)
    }

    @Test func theFileChangingElsewhereIsTakenUnlessThereAreChangesHere() async throws {
        let (continuum, host, session, simulated, path) = try await runningPipeline(text: "Interval 1s\nWriteLine x")
        defer { session.stop() }
        let (service, _) = try await service()
        let pipeline = try #require(host.pipeline("test"))
        let document = try await MeeplangDocument.open(pipeline, host: host, service: service)
        #expect(await eventually { document.answer?.base != nil || document.answer != nil })
        _ = continuum

        // Changed on disk and reloaded by the daemon, with nothing unsaved here: the view takes the new text.
        let changed = "Interval 1s\nWhere y\nWriteLine x"
        try changed.write(toFile: path, atomically: false, encoding: .utf8)
        await simulated.reload("test", as: spec(text: changed, path: path))
        #expect(await eventually { document.replacement?.text == changed })
        #expect(document.text == changed && !document.isEdited)

        // With changes here, it says so instead.
        document.edit(changed + "\nWriteLine z")
        let again = "Interval 5s\nWhere y\nWriteLine x"
        try again.write(toFile: path, atomically: false, encoding: .utf8)
        await simulated.reload("test", as: spec(text: again, path: path))
        #expect(await eventually { document.status == .changedElsewhere })
        #expect(document.text == changed + "\nWriteLine z")
    }

    @Test func aFileSavedByAnotherEditorIsTakenWithoutADaemon() async throws {
        let (service, _) = try await service()
        let path = try temporaryFile("Interval 1s")
        let document = MeeplangDocument(path: path, text: "Interval 1s", service: service)
        // In place, and then by replacing the file, as editors do.
        try "Interval 2s".write(toFile: path, atomically: false, encoding: .utf8)
        #expect(await eventually { document.text == "Interval 2s" })
        try "Interval 3s".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(await eventually { document.text == "Interval 3s" })
        try "Interval 4s".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(await eventually { document.text == "Interval 4s" && document.replacement?.text == "Interval 4s" })
        #expect(!document.isEdited)
        document.close()
    }

    @Test func aRunningPipelinesKeysBecomeTheDocumentsAndRenamesAreSaid() async throws {
        let (_, host, session, simulated, path) = try await runningPipeline(text: "Interval 1s\nWriteLine x")
        defer { session.stop() }
        let (service, fake) = try await service()
        let pipeline = try #require(host.pipeline("test"))
        let document = try await MeeplangDocument.open(pipeline, host: host, service: service)
        #expect(!document.isReadOnly)
        #expect(await eventually { await fake.received.contains { $0.method == "meep/setBase" } })
        let base = try #require(await fake.received.first { $0.method == "meep/setBase" }?.params)
        #expect(base["text"] as? String == "Interval 1s\nWriteLine x")
        #expect(base["pipeline"] as? String == "test")

        // The daemon reloads it with other keys (as one that was taken out and put back would have).
        var reloaded = spec(text: "Interval 1s\nWriteLine x", path: path)
        reloaded.modules = [.init("Interval", .source, rate: 2), .init("WriteLine", .step, from: [0])]
        await simulated.reload("test", as: reloaded)
        #expect(await eventually { await fake.received.filter { $0.method == "meep/setBase" }.count == 2 })
        // The simulated daemon keys modules m1 and m2 either way, so nothing is renamed; a fake base with other keys is.
        _ = try await service.perform { server in
            try await server.setBase(document.uri, pipeline: "test", graph: PipelineGraph(
                name: "test", path: path, version: 9,
                modules: [
                    GraphModule(key: "m1", number: 1, module: "Interval #1", verb: "Interval", role: .source, span: GraphSpan(file: path, startLine: 1, startColumn: 1, endLine: 1, endColumn: 12)),
                    GraphModule(key: "m4", number: 2, module: "WriteLine #2", verb: "WriteLine", role: .step, span: GraphSpan(file: path, startLine: 2, startColumn: 1, endLine: 2, endColumn: 12)),
                ], links: []
            ), text: "Interval 1s\nWriteLine x")
        }.map { document.take($0) }
        #expect(document.renaming?.keys == ["m2": "m4"])
        #expect(document.modulesByLine[1] == ["m4"])
    }

    @Test func savingARunningPipelineWaitsForItsReload() async throws {
        let (_, host, session, simulated, path) = try await runningPipeline(text: "Interval 1s")
        defer { session.stop() }
        let (service, fake) = try await service()
        let document = try await MeeplangDocument.open(try #require(host.pipeline("test")), host: host, service: service)
        document.reloadTimeout = .seconds(3)
        #expect(await eventually { await fake.received.contains { $0.method == "meep/setBase" } })

        // A daemon that reloads it: the base's text becomes what was saved.
        document.edit("Interval 2s")
        try document.save()
        #expect(document.status == .reloading)
        await simulated.reload("test", as: spec(text: "Interval 2s", path: path))
        #expect(await eventually { if case .reloaded = document.status { true } else { false } })

        // One that doesn't: it says so.
        document.edit("Interval 3s")
        try document.save()
        #expect(await eventually { document.status == .notWatched })
    }

    private func spec(text: String, path: String) -> PipelineSpec {
        let modules = text.components(separatedBy: "\n").enumerated().map { index, line in
            PipelineSpec.ModuleSpec(String(line.split(separator: " ").first!), index == 0 ? .source : .step, from: index == 0 ? [] : [index - 1], rate: 2)
        }
        return PipelineSpec(name: "test", modules: modules, path: path, text: text)
    }

    private func runningPipeline(text: String) async throws -> (Continuum, MeepHost, HostSession, SimulatedHost, String) {
        let path = try temporaryFile(text)
        let simulated = SimulatedHost(name: "local", latency: .milliseconds(1), pipelines: [spec(text: text, path: path)])
        let continuum = Continuum()
        let host = continuum.add(host: "local", kind: .local(socketPath: "/nowhere"))
        let session = HostSession(host: host, settings: .init(statsEvery: .milliseconds(50), watchedStatsEvery: .milliseconds(50), listEvery: .milliseconds(100))) { simulated }
        session.start()
        #expect(await eventually { host.pipeline("test")?.graph != nil && host.link != nil })
        return (continuum, host, session, simulated, path)
    }
}

struct LineIndexTests {
    @Test func offsetsCountUTF16AsThePositionsDo() {
        let lines = LineIndex("Where é > 1\n    WriteLine \"🙂 {x}\"\n")
        #expect(lines.lineCount == 3)
        #expect(lines.range(ofLine: 0) == 0..<11)
        #expect(lines.range(ofLine: 1) == 12..<34)
        #expect(lines.offset(of: LSPPosition(line: 1, character: 15)) == 27)
        #expect(lines.position(at: 27) == LSPPosition(line: 1, character: 15))
        #expect(lines.line(at: 11) == 0 && lines.line(at: 12) == 1 && lines.line(at: 36) == 2)
        // Past the end of a line, a position stays on it.
        #expect(lines.offset(of: LSPPosition(line: 0, character: 99)) == 11)
        #expect(lines.range(of: GraphSpan(file: "", startLine: 2, startColumn: 5, endLine: 2, endColumn: 14)) == 16..<25)
    }

    @Test func tokensBecomeStylesByTypeAndModifier() {
        let legend = SemanticTokensLegend(tokenTypes: ["function", "variable", "string"], tokenModifiers: ["declaration", "readonly", "defaultLibrary"])
        let lines = LineIndex("Fetch x as Check\nWhere msg.Count")
        // Fetch (verb), Check (a name: variable + declaration), msg (builtin: variable + readonly + defaultLibrary).
        let data = [0, 0, 5, 0, 0, 0, 11, 5, 1, 1, 1, 6, 3, 1, 0b110]
        let highlights = Highlight.from(data, legend: legend, lines: lines)
        #expect(highlights.map(\.style) == [.verb, .name, .builtin])
        #expect(highlights.map(\.range) == [0..<5, 11..<16, 23..<26])
    }
}
