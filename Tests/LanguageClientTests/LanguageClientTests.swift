import Foundation
import MeepClient
import Testing
import Transport
@testable import LanguageClient

/// What `meep lsp` answered for `shapes.meep`, captured from Meep2 at 810c2fc: Fixtures/*.json.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// The `result` of a captured answer.
    static func result(_ name: String) throws -> Any {
        let message = try JSONSerialization.jsonObject(with: data(name)) as? [String: Any]
        return try #require(message?["result"])
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }
}

/// A language server that answers from the captured fixtures, and says what it was sent.
actor ScriptedServer {
    private let stream: MemoryStream
    /// What it was sent, in order.
    struct Received: Sendable {
        var method: String
        var json: Data
        var params: [String: Any] { (try? JSONSerialization.jsonObject(with: json) as? [String: Any]) ?? [:] }
    }

    private(set) var received: [Received] = []
    private var answers: [String: Any] = [:]

    init(_ stream: MemoryStream) {
        self.stream = stream
    }

    private var failures: [String: Data] = [:]

    func answer(_ method: String, with result: Any) {
        answers[method] = result
    }

    /// Answers `method` with this error, as JSON, until told otherwise.
    func fail(_ method: String, with error: Data) {
        failures[method] = error
    }

    func run() async {
        var reader = FrameReader()
        while let data = try? await stream.receive() {
            guard let messages = try? reader.append(data) else { return }
            for message in messages {
                guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
                      let method = object["method"] as? String else { continue }
                let params = (try? JSONSerialization.data(withJSONObject: object["params"] as? [String: Any] ?? [:])) ?? Data()
                received.append(Received(method: method, json: params))
                if let id = object["id"] {
                    if let failure = failures[method], let error = try? JSONSerialization.jsonObject(with: failure) {
                        await send(["jsonrpc": "2.0", "id": id, "error": error])
                    } else {
                        await send(["jsonrpc": "2.0", "id": id, "result": answers[method] ?? NSNull()])
                    }
                }
            }
        }
    }

    func send(_ message: [String: Any]) async {
        await send(json: try! JSONSerialization.data(withJSONObject: message))
    }

    func send(json body: Data) async {
        try? await stream.send(Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body)
    }

    func methods() -> [String] { received.map(\.method) }
}

struct FrameReaderTests {
    @Test func messagesAreSplitByTheirLengthsWhereverTheChunksBreak() throws {
        let one = try LanguageServerConnection.frame(["a": "é and more"])
        let two = try LanguageServerConnection.frame(["b": 2])
        let all = one + two
        for split in [1, 7, one.count - 1, one.count, one.count + 3] {
            var reader = FrameReader()
            var messages = try reader.append(all.prefix(split))
            messages += try reader.append(all.dropFirst(split))
            #expect(messages.count == 2)
            #expect(String(decoding: messages[0], as: UTF8.self) == #"{"a":"é and more"}"#)
        }
    }

    @Test func aMessageWithoutALengthIsRefused() {
        var reader = FrameReader()
        #expect(throws: LanguageServerError.self) { try reader.append(Data("Content-Type: x\r\n\r\n{}".utf8)) }
    }
}

struct ProtocolTests {
    @Test func theGraphIsTheDaemonsWithTheDocumentsVersion() throws {
        let answer = try JSONDecoder().decode(GraphAnswer.self, from: JSONSerialization.data(withJSONObject: Fixture.result("graph.json")))
        #expect(answer.version == 1)
        #expect(answer.current)
        let graph = try #require(answer.graph)
        #expect(graph.modules.map(\.module) == ["Fast", "Slow", "Keep", "Log", "Risky", "WriteLine #6", "WriteLine #7"])
        #expect(graph.modules.map(\.key) == ["m1", "m2", "m3", "m4", "m5", "m6", "m7"])
        #expect(graph.links.count == 6)
        #expect(graph.modules[2].verbRole == .filter)
        #expect(graph.modules[2].span.startLine == 4)
    }

    @Test func brokenTextKeepsTheLastGraphAndSaysWhatChanged() throws {
        let answer = try JSONDecoder().decode(GraphAnswer.self, from: JSONSerialization.data(withJSONObject: Fixture.result("graph-broken.json")))
        #expect(!answer.current)
        #expect(answer.version == 3)
        #expect(answer.builtFrom == 2)
        #expect(answer.problems.first?.message.contains("isn't closed") == true)
        #expect(answer.problems.first?.range.start == LSPPosition(line: 3, character: 14))
        #expect(answer.changed == LSPRange(start: LSPPosition(line: 3, character: 0), end: LSPPosition(line: 4, character: 0)))
        // The Where inserted at version 2 has a key of its own, and the rest kept theirs.
        let graph = try #require(answer.graph)
        #expect(graph.modules.count == 8)
        #expect(graph.modules.first { $0.verb == "Where" && $0.name == nil }?.key == "m8")
    }

    @Test func theVerbCatalogueHasTypesDefaultsAndSource() throws {
        struct Verbs: Decodable { var verbs: [VerbEntry] }
        let verbs = try JSONDecoder().decode(Verbs.self, from: JSONSerialization.data(withJSONObject: Fixture.result("verbs.json"))).verbs
        let http = try #require(verbs.first { $0.verb == "Fetch" && $0.inflection == "HTTP" })
        #expect(http.role == "step")
        #expect(http.parameters.first?.positional == true)
        #expect(http.parameters.first { $0.name == "timeout" }?.default == "1m40s")
        #expect(http.source?.file?.hasSuffix("Fetch.cs") == true)
        #expect(verbs.first { $0.verb == "Where" }?.role == "filter")
    }

    @Test func hoversAndCompletionsAreRead() throws {
        let hover = try JSONDecoder().decode(Hover.self, from: JSONSerialization.data(withJSONObject: Fixture.result("hover.json")))
        #expect(hover.text.hasPrefix("**Interval** (source)"))
        let completions = try JSONDecoder().decode(Completions.self, from: JSONSerialization.data(withJSONObject: Fixture.result("completion.json")))
        #expect(completions.items.contains { $0.label == "WriteLine" })
    }

    @Test func aDeltaIsAppliedToTheEarlierTokens() {
        let delta = SemanticTokensDelta(resultId: "2", edits: [
            .init(start: 5, deleteCount: 5, data: [1, 0, 3, 2, 0, 0, 4, 1, 1, 0]),
            .init(start: 0, deleteCount: 0, data: [9, 9, 9, 9, 9]),
        ])
        let before = [0, 0, 4, 5, 0, 1, 2, 6, 3, 0, 1, 0, 2, 8, 0]
        #expect(delta.applied(to: before) == [9, 9, 9, 9, 9, 0, 0, 4, 5, 0, 1, 0, 3, 2, 0, 0, 4, 1, 1, 0, 1, 0, 2, 8, 0])
    }
}

struct LanguageServerTests {
    private func start() async throws -> (MeepLanguageServer, ScriptedServer, Task<Void, Never>) {
        let (client, end) = MemoryStream.pair()
        let script = ScriptedServer(end)
        await script.answer("initialize", with: try Fixture.result("initialize.json"))
        await script.answer("meep/graph", with: try Fixture.result("graph.json"))
        await script.answer("textDocument/semanticTokens/full", with: try Fixture.result("tokens.json"))
        let running = Task { await script.run() }
        return (try await MeepLanguageServer.start(over: client), script, running)
    }

    @Test func itLearnsWhatTheServerCanDo() async throws {
        let (server, script, running) = try await start()
        defer { running.cancel() }
        let capabilities = await server.capabilities
        #expect(capabilities.graph && capabilities.setBase && capabilities.verbs)
        #expect(capabilities.tokenDeltas && capabilities.hovers && capabilities.completions)
        #expect(capabilities.legend?.tokenTypes.first == "namespace")
        try await Task.sleep(for: .milliseconds(20))
        #expect(await script.methods() == ["initialize", "initialized"])
    }

    @Test func changesGoInOrderBeforeWhatsAskedAboutThem() async throws {
        let (server, script, running) = try await start()
        defer { running.cancel() }
        let uri = MeepLanguageServer.uri(forPath: "/tmp/synesthesia-fixtures/shapes.meep")
        try await server.open(uri, text: try Fixture.text("shapes.meep"), version: 1)
        try await server.change(uri, text: "Interval 1s", version: 2)
        let answer = try await server.graph(uri, subscribe: true)
        #expect(answer?.graph?.modules.count == 7)
        let received = await script.received
        #expect(received.map(\.method) == ["initialize", "initialized", "textDocument/didOpen", "textDocument/didChange", "meep/graph"])
        #expect(received[4].params["subscribe"] as? Bool == true)
        #expect((received[3].params["textDocument"] as? [String: Any])?["version"] as? Int == 2)
    }

    @Test func aBaseWithNoGraphSaysSoInsteadOfLeavingItOut() async throws {
        let (server, script, running) = try await start()
        defer { running.cancel() }
        _ = try await server.setBase("file:///x.meep", pipeline: "x", graph: nil, text: nil)
        let params = try #require(await script.received.last?.params)
        #expect(params["graph"] is NSNull)
        #expect(params["pipeline"] as? String == "x")
    }

    @Test func notificationsBecomeEvents() async throws {
        let (server, script, running) = try await start()
        defer { running.cancel() }
        let notices = try JSONSerialization.jsonObject(with: Fixture.data("notifications.json")) as! [[String: Any]]
        var events = server.events.makeAsyncIterator()
        for notice in notices { await script.send(json: try JSONSerialization.data(withJSONObject: notice)) }
        var seen: [ServerEvent] = []
        for _ in notices { if let event = await events.next() { seen.append(event) } }
        let graphs = seen.compactMap { if case .graphChanged(let answer) = $0 { answer } else { nil } }
        #expect(graphs.map(\.version) == [2, 3])
        #expect(graphs.map(\.current) == [true, false])
        let problems = seen.compactMap { if case .diagnostics(_, let list) = $0 { list.count } else { nil } }
        #expect(problems.contains(2))
    }

    @Test func requestsFailWhenTheServerStops() async throws {
        let (client, end) = MemoryStream.pair()
        let script = ScriptedServer(end)
        await script.answer("initialize", with: try Fixture.result("initialize.json"))
        let running = Task { await script.run() }
        let server = try await MeepLanguageServer.start(over: client)
        running.cancel()
        end.close()
        await #expect(throws: LanguageServerError.self) { _ = try await server.graph("file:///x.meep") }
    }
}

/// Against the real `meep lsp`, when `MEEP_EXECUTABLE` names a `meep` built from Meep2 at 2ef2d35 or later.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MEEP_EXECUTABLE"] != nil))
struct LiveLanguageServerTests {
    @Test func typingKeepsKeysAndTokenDeltasMatchAWholeSet() async throws {
        let process = try LanguageServerProcess(executable: ProcessInfo.processInfo.environment["MEEP_EXECUTABLE"]!)
        defer { process.terminate() }
        let server = try await MeepLanguageServer.start(over: process.stream)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("synesthesia-lsp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("shapes.meep").path
        let text = try Fixture.text("shapes.meep")
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let uri = MeepLanguageServer.uri(forPath: path)

        try await server.open(uri, text: text, version: 1)
        let first = try #require(try await server.graph(uri, subscribe: true)?.graph)
        let before = try #require(try await server.semanticTokens(uri))

        var lines = text.components(separatedBy: "\n")
        lines.insert("    Where msg.Count > 2", at: 5)
        try await server.change(uri, text: lines.joined(separator: "\n"), version: 2)
        let after = try #require(try await server.graph(uri)?.graph)
        let kept = Set(first.modules.map(\.key)).subtracting(after.modules.map(\.key))
        #expect(kept.isEmpty)
        #expect(after.modules.count == first.modules.count + 1)

        let delta = try #require(try await server.semanticTokens(uri))
        #expect(delta.data != before.data)
        let fresh = try await MeepLanguageServer.start(over: LanguageServerProcess(executable: process.executable).stream)
        try await fresh.open(uri, text: lines.joined(separator: "\n"), version: 1)
        #expect(try await fresh.semanticTokens(uri)?.data == delta.data)
        await fresh.shutdown()

        let verbs = try await server.verbs(uri)
        #expect(verbs.count >= 24)
        await server.shutdown()
    }
}

struct EditTests {
    private func answer(_ name: String) throws -> EditAnswer {
        try JSONDecoder().decode(EditAnswer.self, from: JSONSerialization.data(withJSONObject: Fixture.result(name)))
    }

    @Test func anEditIsTheChangeToTheText() throws {
        let set = try answer("apply-set.json")
        #expect(set.textDocument.version == 1)
        #expect(set.edits == [LSPTextEdit(range: LSPRange(start: LSPPosition(line: 3, character: 18), end: LSPPosition(line: 3, character: 24)), newText: "3 != 1")])
        #expect(set.added.isEmpty && set.graph == nil)
    }

    @Test func aPreviewHasTheGraphAndTheNewModulesKeys() throws {
        let preview = try answer("apply-insert-preview.json")
        #expect(preview.added.map(\.key) == ["m8"])
        let graph = try #require(preview.graph)
        #expect(graph.modules.first { $0.key == "m8" }?.name == "Gate")
        #expect(graph.modules.first { $0.key == "m8" }?.modifiers.first?.name == "buffer")
    }

    @Test func refusalsSayWhichEditAndWhichVersion() async throws {
        let (client, end) = MemoryStream.pair()
        let script = ScriptedServer(end)
        await script.answer("initialize", with: try Fixture.result("initialize.json"))
        let running = Task { await script.run() }
        defer { running.cancel() }
        let server = try await MeepLanguageServer.start(over: client)
        for (fixture, expected) in [("apply-failed.json", LanguageServerError.requestFailed), ("apply-stale.json", LanguageServerError.contentModified)] {
            let failure = try JSONSerialization.jsonObject(with: Fixture.data(fixture)) as! [String: Any]
            await script.fail("meep/applyEdits", with: try JSONSerialization.data(withJSONObject: failure["error"]!))
            do {
                _ = try await server.applyEdits("file:///x.meep", version: 1, edits: [.remove("m3")])
                Issue.record("\(fixture) was taken")
            } catch let LanguageServerError.refused(code, message, edit, version) {
                #expect(code == expected)
                #expect(!message.isEmpty)
                if fixture == "apply-failed.json" { #expect(edit == 1) } else { #expect(version == 1) }
            }
        }
        let sent = try #require(await script.received.last?.params)
        #expect((sent["edits"] as? [[String: Any]])?.first?["kind"] as? String == "remove")
        #expect(sent["preview"] == nil)
    }
}

extension LiveLanguageServerTests {
    @Test func editsComeBackAsTextAndTheNewModuleHasItsKey() async throws {
        let process = try LanguageServerProcess(executable: ProcessInfo.processInfo.environment["MEEP_EXECUTABLE"]!)
        defer { process.terminate() }
        let server = try await MeepLanguageServer.start(over: process.stream)
        #expect(await server.capabilities.applyEdits)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("synesthesia-edits-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("shapes.meep").path
        let text = try Fixture.text("shapes.meep")
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let uri = MeepLanguageServer.uri(forPath: path)
        try await server.open(uri, text: text, version: 1)
        _ = try await server.graph(uri, subscribe: false)

        let answer = try await server.applyEdits(uri, version: 1, edits: [.add("WriteLine \"also\" as Also", under: "m5"), .setModifier("+0", "buffer", to: "3")], preview: true)
        let key = try #require(answer.added.first?.key)
        // Applying the changes as an editor would gives the graph the preview promised.
        let changed = NSMutableString(string: text)
        let lines = text.components(separatedBy: "\n")
        func offset(_ position: LSPPosition) -> Int {
            lines.prefix(position.line).reduce(0) { $0 + ($1 as NSString).length + 1 } + position.character
        }
        for edit in answer.edits.sorted(by: { $0.range.start > $1.range.start }) {
            let start = offset(edit.range.start)
            changed.replaceCharacters(in: NSRange(location: start, length: offset(edit.range.end) - start), with: edit.newText)
        }
        try await server.change(uri, text: changed as String, version: 2)
        let after = try #require(try await server.graph(uri)?.graph)
        #expect(after == answer.graph)
        #expect(after.modules.first { $0.key == key }?.name == "Also")

        await #expect(throws: LanguageServerError.self) { _ = try await server.applyEdits(uri, version: 1, edits: [.remove(key)]) }
        await server.shutdown()
    }
}
