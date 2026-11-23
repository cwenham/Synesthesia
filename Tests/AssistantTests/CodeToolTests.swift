import CodeEditing
import ContinuumKit
import Foundation
import LanguageClient
import MeepClient
import Testing
import TestSupport
import Transport
@testable import Assistant

/// The fixtures other suites captured: `meep lsp`'s answers to `initialize` and `meep/verbs` (Meep2 810c2fc), and
/// `Fetch.cs` from the same commit.
enum SharedFixtures {
    static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    static func data(_ path: String) -> Data {
        try! Data(contentsOf: tests.appendingPathComponent(path))
    }

    static var fetchSource: String { String(decoding: data("CodeEditingTests/Fixtures/Fetch.cs"), as: UTF8.self) }
    static let sourceLink = "https://raw.githubusercontent.com/cwenham/Meep2/810c2fcd6e5d13f61424baea5d67bab16714b02a/src/Meep2.Modules/Fetch.cs"
}

/// A stand-in for `meep lsp` that answers `initialize` and `meep/verbs` as the real one did, with every file the
/// catalogue names missing from this Mac, so C# comes from SourceLink, and everything else with null.
actor VerbsOnlyLanguageServer {
    private let stream: MemoryStream
    private let initialize: JSONValue
    private let verbs: JSONValue

    init(_ stream: MemoryStream) {
        self.stream = stream
        initialize = (try! JSONValue.parse(SharedFixtures.data("LanguageClientTests/Fixtures/initialize.json")))["result"]!
        var verbs = (try! JSONValue.parse(SharedFixtures.data("LanguageClientTests/Fixtures/verbs.json")))["result"]!
        if case .object(var result) = verbs, let entries = result["verbs"]?.array {
            result["verbs"] = .array(entries.map { entry in
                guard case .object(var object) = entry, case .object(var source)? = object["source"] else { return entry }
                source["file"] = .string("/not/on/this/mac/" + ((source["file"]?.string ?? "") as NSString).lastPathComponent)
                object["source"] = .object(source)
                return .object(object)
            })
            verbs = .object(result)
        }
        self.verbs = verbs
    }

    @MainActor static func service() -> LanguageService {
        LanguageService {
            let (client, end) = MemoryStream.pair()
            let fake = VerbsOnlyLanguageServer(end)
            Task { await fake.run() }
            return try await MeepLanguageServer.start(over: client)
        }
    }

    func run() async {
        var buffer = Data()
        while let data = try? await stream.receive() {
            buffer.append(data)
            while let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let length = Int(header.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))!
                guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { break }
                let body = Data(buffer[end.upperBound..<buffer.index(end.upperBound, offsetBy: length)])
                buffer = Data(buffer[buffer.index(end.upperBound, offsetBy: length)...])
                await handle(body)
            }
        }
    }

    private func handle(_ body: Data) async {
        guard let message = try? JSONValue.parse(body), let id = message["id"] else { return }
        let result: JSONValue = switch message["method"]?.string {
        case "initialize": initialize
        case "meep/verbs": verbs
        default: .null
        }
        let reply = JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).text()
        let bytes = Data(reply.utf8)
        try? await stream.send(Data("Content-Length: \(bytes.count)\r\n\r\n".utf8) + bytes)
    }
}

/// Answers the one SourceLink address in the fixtures, in place of GitHub, counting what it's asked.
actor GitHubStandIn: SourceFetching {
    private(set) var asked = 0

    func fetch(_ url: URL) async throws -> Data {
        asked += 1
        guard url.absoluteString == SharedFixtures.sourceLink else { throw SourceFetchError.status(404) }
        return Data(SharedFixtures.fetchSource.utf8)
    }
}

@MainActor
@Suite(.simulatedHosts)
struct CodeToolTests {
    private func viewer() async throws -> (TestViewer, GitHubStandIn) {
        let viewer = try await TestViewer(slowly: true)
        let github = GitHubStandIn()
        viewer.language = VerbsOnlyLanguageServer.service()
        viewer.sources = SourceLibrary(cache: nil, fetcher: github)
        return (viewer, github)
    }

    private func call(_ registry: ToolRegistry, _ name: String, _ arguments: JSONValue) async throws -> (JSONValue?, ToolResult) {
        let result = try #require(await registry.call(name, arguments: arguments))
        guard case .text(let text)? = result.content.first else { return (nil, result) }
        return (try? JSONValue.parse(Data(text.utf8)), result)
    }

    private func code(_ result: ToolResult) -> String? {
        guard result.content.count > 1, case .text(let text) = result.content[1] else { return nil }
        return text
    }

    /// A module's inflection: its class from GitHub, with line numbers, and the times of the two modules that run it,
    /// which the tool asks for since nothing on screen does.
    @Test func givesAModulesInflectionWithItsTimes() async throws {
        let (viewer, github) = try await viewer()
        defer { viewer.stop() }
        let (json, result) = try await call(ContinuumTools.registry(for: viewer), "read_inflection_source", ["address": "meep://sim/orders/Prices"])
        #expect(!result.isError)
        #expect(json?["inflection"] == "Fetch.HTTP")
        #expect(json?["moduleRunsIt"] == true)
        #expect(json?["module"]?["label"] == "Prices")
        #expect(json?["line"] == 19)
        #expect(json?["source"]?["from"] == "SourceLink")
        #expect(json?["source"]?["page"]?.string?.hasSuffix("/blob/810c2fcd6e5d13f61424baea5d67bab16714b02a/src/Meep2.Modules/Fetch.cs#L19") == true)
        #expect(json?["otherInflections"]?.array?.first?["inflection"] == "Fetch.File")
        #expect(json?["otherInflections"]?.array?.first?["line"] == 213)
        // Prices and Enrich run it; the tool asked for their times, and stopped asking.
        #expect(json?["handling"]?["modulesRunningIt"] == 2)
        #expect((json?["handling"]?["seconds"]?["p50"]?.number ?? 0) > 0.001)
        #expect(json?["handling"]?["byModule"]?.array?.count == 2)
        #expect(viewer.continuum.host("sim")?.pipeline("orders")?.timingWanted.isEmpty == true)
        let text = try #require(code(result))
        #expect(text.contains("  19  public sealed class HttpFetch"))
        #expect(text.hasPrefix("   9  /// <summary>"))
        #expect(!text.contains("class FileFetch"))
        #expect(await github.asked == 1)
    }

    @Test func givesAnInflectionByNameOrTheWholeFile() async throws {
        let (viewer, _) = try await viewer()
        defer { viewer.stop() }
        let registry = ContinuumTools.registry(for: viewer)
        let (file, fileResult) = try await call(registry, "read_inflection_source", ["verb": "Fetch.File", "whole": true])
        #expect(file?["inflection"] == "Fetch.File")
        #expect(code(fileResult)?.contains("class HttpFetch") == true)
        #expect(code(fileResult)?.contains(" 213  public sealed class FileFetch") == true)

        // A verb with several inflections, none named: a list to choose from.
        let (list, listResult) = try await call(registry, "read_inflection_source", ["verb": "Fetch"])
        #expect(list?["inflections"]?.array?.count == 2)
        #expect(code(listResult) == nil)

        let (_, wrong) = try await call(registry, "read_inflection_source", ["verb": "Fetch.FTP"])
        #expect(wrong.isError)
        let (_, unknown) = try await call(registry, "read_inflection_source", ["verb": "Juggle"])
        #expect(unknown.isError)
    }

    @Test func saysWhyThereIsNoSource() async throws {
        let (viewer, _) = try await viewer()
        defer { viewer.stop() }
        // Batch's file isn't on this Mac, and GitHub's stand-in doesn't have it.
        let (json, result) = try await call(ContinuumTools.registry(for: viewer), "read_inflection_source", ["verb": "Batch"])
        #expect(!result.isError)
        #expect(json?["noSource"]?.string?.contains("404") == true)
        #expect(code(result) == nil)
    }

    @Test func needsALanguageServer() async throws {
        let viewer = try await TestViewer(slowly: true)
        defer { viewer.stop() }
        let (_, result) = try await call(ContinuumTools.registry(for: viewer), "read_inflection_source", ["verb": "Fetch.HTTP"])
        #expect(result.isError)
    }

    /// show opens a module's C#, and describe_view and the sidebar's note describe it.
    @Test func theCodeLevelIsShownAndDescribed() async throws {
        let (viewer, _) = try await viewer()
        defer { viewer.stop() }
        let registry = ContinuumTools.registry(for: viewer)
        let (shown, _) = try await call(registry, "show", ["address": "meep://sim/orders/Prices", "code": true])
        #expect(shown?["code"] == "Fetch.HTTP")
        let level = try #require(viewer.code)
        await level.loaded()
        level.visibleLines = 9...40

        let (view, _) = try await call(registry, "describe_view", [:])
        let code = try #require(view?["code"])
        #expect(code["verb"] == "Fetch")
        #expect(code["module"]?["label"] == "Prices")
        #expect(code["shown"]?["inflection"] == "Fetch.HTTP")
        #expect(code["shown"]?["moduleRunsIt"] == true)
        #expect(code["shown"]?["linesOnScreen"] == "10–41")
        #expect(code["shown"]?["classLines"]?.string?.hasPrefix("9–") == true)
        #expect(code["inflections"] == ["Fetch.HTTP (the module's)", "Fetch.File"])
        #expect(view?["text"] == nil)

        let note = SidebarPrompt.context(viewer)
        #expect(note.contains("The C# of Fetch.HTTP of meep://sim/orders/m3 (Prices) shows beside the canvas"))
    }
}
