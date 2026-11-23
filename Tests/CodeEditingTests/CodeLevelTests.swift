import ContinuumKit
import FlowKit
import Foundation
import LanguageClient
import MeepClient
import Simulation
import Testing
import TestSupport
@testable import CodeEditing

/// Reads the fixtures: `Fetch.cs` from Meep2 at 810c2fc, and `meep lsp`'s answer to `meep/verbs` from the same build.
enum CodeFixtures {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    static var fetchSource: String { try! String(contentsOf: url("Fetch.cs"), encoding: .utf8) }

    static var verbs: [VerbEntry] {
        struct Reply: Decodable {
            struct Result: Decodable { var verbs: [VerbEntry] }
            var result: Result
        }
        return try! JSONDecoder().decode(Reply.self, from: Data(contentsOf: url("verbs.json"))).result.verbs
    }

    /// The catalogue with every file moved to `folder`, as if Meep were built there, so tests choose what's on "this
    /// Mac".
    static func verbs(filesIn folder: URL) -> [VerbEntry] {
        verbs.map { entry in
            var entry = entry
            if let file = entry.source?.file { entry.source?.file = folder.appendingPathComponent((file as NSString).lastPathComponent).path }
            return entry
        }
    }

    static func temporaryFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("code-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// Answers SourceLink addresses from memory, counting what it's asked, in place of GitHub.
actor FakeSourceFetcher: SourceFetching {
    var files: [String: Data] = [:]
    var failure: (any Error)?
    private(set) var asked: [String] = []
    /// How long each answer takes.
    var delay: Duration = .zero

    init(_ files: [String: String] = [:]) {
        self.files = files.mapValues { Data($0.utf8) }
    }

    func set(failure: (any Error)?) { self.failure = failure }

    func fetch(_ url: URL) async throws -> Data {
        asked.append(url.absoluteString)
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        guard let data = files[url.absoluteString] else { throw SourceFetchError.status(404) }
        return data
    }
}

@Suite("C#, as the code level colours it")
struct CSharpTests {
    private func styles(_ text: String) -> [(String, TokenStyle)] {
        let code = CSharpText(text)
        let units = Array(text.utf16)
        return code.highlights.map { (String(decoding: units[$0.range], as: UTF16.self), $0.style) }
    }

    @Test func colouresKeywordsTypesMethodsAndLiterals() {
        let found = styles("""
            public sealed class Http : AInflection<Message>
            {
                public int Count => Parse("12", 0x1F) + 'x';
            }
            """)
        #expect(found.contains { $0 == ("public", .keyword) })
        #expect(found.contains { $0 == ("class", .keyword) })
        #expect(found.contains { $0 == ("Http", .type) })
        #expect(found.contains { $0 == ("AInflection", .type) })
        #expect(found.contains { $0 == ("Parse", .method) })
        #expect(found.contains { $0 == ("\"12\"", .string) })
        #expect(found.contains { $0 == ("0x1F", .number) })
        #expect(found.contains { $0 == ("'x'", .string) })
        #expect(!found.contains { $0.0 == "Count" && $0.1 == .keyword })
    }

    @Test func readsEveryKindOfString() {
        let text = #"""
            var a = $"total {(ok ? "yes" : "no")} }} {{";
            var b = @"C:\path\""quoted""";
            var c = """
                raw "with" quotes { }
                """;
            var d = $$"""{{x}} and {not a hole}""";
            """#
        let found = styles(text).filter { $0.1 == .string }.map(\.0)
        #expect(found.count == 4)
        #expect(found[0] == #"$"total {(ok ? "yes" : "no")} }} {{""#)
        #expect(found[1] == #"@"C:\path\""quoted""""#)
        let three = String(repeating: "\"", count: 3)
        #expect(found[2].hasPrefix("var") == false && found[2].hasPrefix(three) && found[2].hasSuffix(three))
        #expect(found[3] == #"$$"""{{x}} and {not a hole}""""#)
    }

    @Test func colouresCommentsAttributesAndDirectives() {
        let found = styles("""
            #if DEBUG
            /// <summary>Fetches.</summary>
            [Verb("Fetch", Inflection = "HTTP"), Emits(typeof(HttpResponse))]
            [return: NotNull]
            int x; // after
            /* block { } */
            #endif
            """)
        #expect(found.contains { $0 == ("#if DEBUG", .decorator) })
        #expect(found.contains { $0 == ("/// <summary>Fetches.</summary>", .comment) })
        #expect(found.contains { $0 == ("Verb", .decorator) })
        #expect(found.contains { $0 == ("Emits", .decorator) })
        #expect(found.contains { $0 == ("NotNull", .decorator) })
        #expect(!found.contains { $0 == ("Inflection", .decorator) })
        #expect(found.contains { $0 == ("// after", .comment) })
        #expect(found.contains { $0 == ("/* block { } */", .comment) })
    }

    @Test func findsAClassFromItsDeclarationToItsClosingBrace() {
        let text = """
            namespace N;

            /// <summary>One.</summary>
            [Verb("One")]
            public sealed class One(int x) : Base
            {
                string s = "}";
                // }
                void M() { if (x > 0) { } }
            }

            public record Point(int X, int Y);
            """
        let code = CSharpText(text)
        let one = code.span(ofClass: "N.One", near: 4)
        #expect(one == CSharpText.TypeSpan(declaration: 4, first: 2, last: 9))
        #expect(code.span(ofClass: "Point", near: nil) == CSharpText.TypeSpan(declaration: 11, first: 11, last: 11))
        #expect(code.span(ofClass: "Missing", near: 3) == nil)
        #expect(CSharpText.shortName("Meep2.Modules.Outer+Inner`1") == "Inner")
    }

    @Test func findsMeepsInflectionsInARealFile() {
        let code = CSharpText(CodeFixtures.fetchSource)
        let http = code.span(ofClass: "Meep2.Modules.HttpFetch", near: 18)
        #expect(http?.declaration == 18)
        #expect(code.line(18).contains("class HttpFetch"))
        #expect(code.line(http!.first).hasPrefix("///"))
        #expect(code.line(http!.last) == "}")
        let file = code.span(ofClass: "Meep2.Modules.FileFetch", near: 212)
        #expect(file?.declaration == 212)
        #expect(file!.declaration > http!.last)
    }

    @Test func findsAClassThatMovedSinceMeepWasBuilt() {
        // Lines added above it since the PDB was written: it's found by name, nearest where it was.
        let moved = String(repeating: "// new line\n", count: 7) + CodeFixtures.fetchSource
        let code = CSharpText(moved)
        #expect(code.span(ofClass: "Meep2.Modules.FileFetch", near: 212)?.declaration == 219)
        #expect(code.span(ofClass: "Meep2.Modules.HttpFetch", near: 18)?.declaration == 25)
    }
}

@Suite("Reading an inflection's C#")
struct SourceLibraryTests {
    static let address = "https://raw.githubusercontent.com/cwenham/Meep2/810c2fcd6e5d13f61424baea5d67bab16714b02a/src/Meep2.Modules/Fetch.cs"

    @Test func readsTheFileWhenItsOnThisMac() async throws {
        let folder = CodeFixtures.temporaryFolder()
        let path = folder.appendingPathComponent("Fetch.cs").path
        try CodeFixtures.fetchSource.write(toFile: path, atomically: true, encoding: .utf8)
        let fetcher = FakeSourceFetcher()
        let library = SourceLibrary(cache: folder.appendingPathComponent("cache"), fetcher: fetcher)
        let outcome = await library.source(of: VerbEntry.Source(file: path, line: 19, url: Self.address), plugin: nil)
        #expect(outcome.file?.origin == .file(path))
        #expect(outcome.file?.text == CodeFixtures.fetchSource)
        #expect(await fetcher.asked.isEmpty)
    }

    @Test func readsTheSourceLinkOnceAndKeepsIt() async throws {
        let folder = CodeFixtures.temporaryFolder()
        let cache = folder.appendingPathComponent("cache")
        let fetcher = FakeSourceFetcher([Self.address: CodeFixtures.fetchSource])
        let location = VerbEntry.Source(file: "/not/on/this/mac/Fetch.cs", line: 19, url: Self.address)

        let first = await SourceLibrary(cache: cache, fetcher: fetcher).source(of: location, plugin: nil)
        #expect(first.file?.origin == .sourceLink(url: Self.address, cached: false))
        #expect(first.file?.text == CodeFixtures.fetchSource)

        // Another run of the app: it's read from the cache, not GitHub.
        let second = await SourceLibrary(cache: cache, fetcher: fetcher).source(of: location, plugin: nil)
        #expect(second.file?.origin == .sourceLink(url: Self.address, cached: true))
        #expect(second.file?.text == CodeFixtures.fetchSource)
        #expect(await fetcher.asked == [Self.address])
    }

    @Test func asksOnceForAFileManyInflectionsShare() async throws {
        let fetcher = FakeSourceFetcher([Self.address: CodeFixtures.fetchSource])
        await fetcher.setDelay(.milliseconds(100))
        let library = SourceLibrary(cache: nil, fetcher: fetcher)
        let location = VerbEntry.Source(file: nil, line: 19, url: Self.address)
        async let a = library.source(of: location, plugin: nil)
        async let b = library.source(of: location, plugin: nil)
        let (first, second) = await (a, b)
        #expect(first.file?.text == second.file?.text)
        #expect(await fetcher.asked.count == 1)
    }

    @Test func saysWhyWhenThereIsNone() async {
        let fetcher = FakeSourceFetcher()
        let library = SourceLibrary(cache: nil, fetcher: fetcher)
        #expect(await library.source(of: nil, plugin: "Lab") == .unavailable(.noLocation(plugin: "Lab")))
        #expect(SourceProblem.noLocation(plugin: "Lab").message.contains("Lab doesn't ship its PDB"))
        #expect(await library.source(of: .init(file: "/gone/A.cs", line: 3, url: nil), plugin: nil) == .unavailable(.fileMissing(path: "/gone/A.cs")))

        let missing = await library.source(of: .init(file: "/gone/A.cs", line: 3, url: Self.address), plugin: nil)
        guard case .unavailable(let problem) = missing else { Issue.record("Expected a problem"); return }
        #expect(problem.canRetry)
        #expect(problem.message.contains("raw.githubusercontent.com"))
        #expect(problem.message.contains("404"))

        let plain = await library.source(of: .init(file: nil, line: 3, url: "http://example.com/A.cs"), plugin: nil)
        #expect(plain == .unavailable(.fetchFailed(url: "http://example.com/A.cs", reason: "it isn't an https address")))
        #expect(await fetcher.asked == [Self.address])
    }

    @Test func turnsSourceLinkIntoGitHubsPage() {
        #expect(SourceLinkPage.page(for: Self.address, line: 213)?.absoluteString
            == "https://github.com/cwenham/Meep2/blob/810c2fcd6e5d13f61424baea5d67bab16714b02a/src/Meep2.Modules/Fetch.cs#L213")
        #expect(SourceLinkPage.commit(of: Self.address) == "810c2fc")
        #expect(SourceLinkPage.site(of: Self.address) == "GitHub")
        #expect(SourceLinkPage.page(for: "https://gitlab.example.com/a/b.cs", line: 2)?.absoluteString == "https://gitlab.example.com/a/b.cs")
    }
}

extension FakeSourceFetcher {
    func setDelay(_ delay: Duration) { self.delay = delay }
}

@Suite("The code level")
@MainActor
struct CodeLevelTests {
    private func fetchModule(isHere: Bool = true, plugin: String? = nil, resolved: [String] = ["HTTP"]) -> CodeSubject {
        CodeSubject(
            pipeline: MeepAddress(host: "sim", pipeline: "orders"), key: "m3", label: "Prices", verb: "Fetch", plugin: plugin,
            resolved: resolved, hostTitle: isHere ? "This Mac" : "Lab", isHere: isHere
        )
    }

    @Test func showsTheInflectionTheModuleResolvesToFirst() async throws {
        let folder = CodeFixtures.temporaryFolder()
        let fetcher = FakeSourceFetcher([SourceLibraryTests.address: CodeFixtures.fetchSource])
        let level = CodeLevel(subject: fetchModule(resolved: ["File"]), continuum: Continuum())
        await level.load(catalogue: CodeFixtures.verbs(filesIn: folder), library: SourceLibrary(cache: nil, fetcher: fetcher))
        #expect(level.state == .ready)
        #expect(level.inflections.map(\.name) == ["Fetch.File", "Fetch.HTTP"])
        #expect(level.inflections.map(\.runsHere) == [true, false])
        #expect(level.shownCode?.name == "Fetch.File")
        // Both are in Fetch.cs, which isn't in the folder, so it came from the SourceLink, once.
        let shown = try #require(level.shownCode)
        #expect(shown.declarationLine == 213)
        #expect(shown.text?.line(212).contains("class FileFetch") == true)
        #expect(shown.originText == "GitHub at 810c2fc, from its SourceLink")
        #expect(await fetcher.asked.count == 1)
        // The gutter marks both classes in the file.
        #expect(level.marks(sharingFileWith: shown).map(\.line) == [212, 18])
        #expect(level.note == nil)
    }

    @Test func readsTheLocalFileFirst() async throws {
        let folder = CodeFixtures.temporaryFolder()
        try CodeFixtures.fetchSource.write(to: folder.appendingPathComponent("Fetch.cs"), atomically: true, encoding: .utf8)
        let fetcher = FakeSourceFetcher()
        let level = CodeLevel(subject: fetchModule(), continuum: Continuum())
        await level.load(catalogue: CodeFixtures.verbs(filesIn: folder), library: SourceLibrary(cache: nil, fetcher: fetcher))
        let shown = try #require(level.shownCode)
        #expect(shown.name == "Fetch.HTTP")
        #expect(shown.localPath == folder.appendingPathComponent("Fetch.cs").path)
        #expect(shown.originText?.hasSuffix("Fetch.cs, on this Mac") == true)
        #expect(await fetcher.asked.isEmpty)
    }

    @Test func saysWhyWhenThereIsNoCode() async {
        // A plugin on another host that this Mac hasn't got.
        let remote = CodeLevel(subject: fetchModule(isHere: false, plugin: "Lab"), continuum: Continuum())
        await remote.load(catalogue: CodeFixtures.verbs, library: SourceLibrary(cache: nil, fetcher: FakeSourceFetcher()))
        #expect(remote.state == .failed(.pluginNotHere(plugin: "Lab", host: "Lab")))

        let unknown = CodeLevel(subject: CodeSubject(label: "Parse", verb: "Parse"), continuum: Continuum())
        await unknown.load(catalogue: CodeFixtures.verbs, library: SourceLibrary(cache: nil, fetcher: FakeSourceFetcher()))
        #expect(unknown.state == .failed(.unknownVerb(verb: "Parse", host: nil)))
    }

    @Test func saysAnotherHostsCodeIsThisMacsCopy() async throws {
        let fetcher = FakeSourceFetcher([SourceLibraryTests.address: CodeFixtures.fetchSource])
        let level = CodeLevel(subject: fetchModule(isHere: false), continuum: Continuum())
        await level.load(catalogue: CodeFixtures.verbs, library: SourceLibrary(cache: nil, fetcher: fetcher))
        #expect(level.note?.contains("this Mac's copy") == true)
    }

    @Test func triesAgainAfterAFailedFetch() async throws {
        let fetcher = FakeSourceFetcher([SourceLibraryTests.address: CodeFixtures.fetchSource])
        await fetcher.set(failure: URLError(.notConnectedToInternet))
        let level = CodeLevel(subject: fetchModule(), continuum: Continuum())
        await level.load(catalogue: CodeFixtures.verbs(filesIn: CodeFixtures.temporaryFolder()), library: SourceLibrary(cache: nil, fetcher: fetcher))
        let shown = try #require(level.shownCode)
        guard case .unavailable(let problem)? = shown.outcome else { Issue.record("Expected a problem"); return }
        #expect(problem.canRetry)
        await fetcher.set(failure: nil)
        await level.retry(shown)
        #expect(shown.text != nil)
    }

    /// The code level asks the planner for the times of every module running the verb's inflections, though no
    /// canvas shows their pipelines, and stops when it's hidden.
    @Test(.simulatedHosts) func asksForTheTimesOfEveryModuleRunningIt() async throws {
        let continuum = Continuum()
        let host = continuum.add(host: "sim", title: "Simulated", kind: .simulated)
        let link = SimulatedHost(name: "sim", latency: .milliseconds(1))
        let session = HostSession(host: host, settings: .init(replanEvery: .milliseconds(50), rateScale: 0.1)) { link }
        session.start()
        defer { session.stop() }
        try await waitFor { host.pipeline("orders")?.graph != nil && host.pipeline("warehouse")?.graph != nil }
        #expect(host.pipelines.allSatisfy { $0.detail == .listed })

        let level = CodeLevel(subject: fetchModule(), continuum: continuum)
        await level.load(catalogue: CodeFixtures.verbs, library: SourceLibrary(cache: nil, fetcher: FakeSourceFetcher([SourceLibraryTests.address: CodeFixtures.fetchSource])))
        let http = try #require(level.inflections.first { $0.name == "Fetch.HTTP" })
        // Prices in orders and Enrich in warehouse.
        #expect(level.times(of: http).uses.map(\.label).sorted() == ["Enrich", "Prices"])
        #expect(level.times(of: http).merged.isEmpty)

        level.startAskingForTimes()
        try await waitFor { level.times(of: http).timed.count == 2 }
        #expect(host.pipeline("orders")?.timingWanted == ["m3"])
        // Only the modules running Fetch's inflections had their times sent.
        #expect(host.pipeline("orders")?.modules.filter { $0.timing != nil }.map(\.key) == ["m3"])
        let merged = level.times(of: http).merged
        #expect(merged.count > 0)
        #expect(merged.quantile(0.5)! > 0.001)
        let summary = level.times(of: http).summary(named: http.name)
        #expect(summary.contains("Fetch.HTTP, from 2 of 2 modules"))
        #expect(summary.contains("Prices in orders on Simulated: median"))

        level.stopAskingForTimes()
        #expect(host.pipeline("orders")?.timingWanted.isEmpty == true)
    }

    private func waitFor(_ condition: @MainActor () -> Bool, seconds: Double = 20) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@Suite("Planning times shown outside the canvas")
struct TimingPlanTests {
    @Test func asksForTheTimesOfModulesShownElsewhere() {
        let planner = SubscriptionPlanner(budget: nil)
        let shapes = ["a": SubscriptionPlanner.Shape(modules: 40, links: 40), "b": SubscriptionPlanner.Shape(modules: 6, links: 6)]
        let rates = planner.rates(for: ["b": .full], timing: ["a": 2, "b": 1], shapes: shapes, others: 0)
        // A listed pipeline gets the two modules' times at the rate one in focus has them, with its totals.
        #expect(rates.pipelines["a"]?.timing == 2)
        #expect(rates.pipelines["a"]?.timedModules == 2)
        #expect(rates.pipelines["a"]?.modules == nil)
        // One in focus already has every module's.
        #expect(rates.pipelines["b"]?.timedModules == nil)
        let without = planner.rates(for: ["b": .full], shapes: shapes, others: 0)
        #expect(without.pipelines["a"] == nil)
        // Two modules' times cost far less than forty's.
        #expect(rates.estimate - without.estimate < Double(40) * 300 * 0.55 / 2 / 4)
    }

    @Test func slowsTimesWithEverythingElseUnderABudget() {
        let shapes = ["a": SubscriptionPlanner.Shape(modules: 40, links: 40)]
        let free = SubscriptionPlanner(budget: nil).rates(for: [:], timing: ["a": 30], shapes: shapes, others: 0)
        let tight = SubscriptionPlanner(budget: 1000).rates(for: [:], timing: ["a": 30], shapes: shapes, others: 0)
        #expect(tight.pipelines["a"]!.timing! > free.pipelines["a"]!.timing!)
        #expect(tight.slowdown > 1)
    }
}

/// Against the real `meep lsp`, when `MEEP_EXECUTABLE` names one built from Meep2 at 2ef2d35 or later: every core
/// inflection says where its C# is, and the code level reads and finds each one's class.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MEEP_EXECUTABLE"] != nil))
struct LiveCodeTests {
    @Test func everyCoreInflectionsClassIsFound() async throws {
        let meep = ProcessInfo.processInfo.environment["MEEP_EXECUTABLE"]!
        let service = LanguageService {
            let process = try LanguageServerProcess(executable: meep)
            return try await MeepLanguageServer.start(over: process.stream)
        }
        let catalogue = try await service.verbs()
        let core = catalogue.filter { $0.plugin == nil }
        #expect(core.count >= 24)
        for entry in core {
            #expect(entry.source?.line != nil, "\(entry.verb).\(entry.inflection) has no line")
            #expect(entry.source?.url?.hasPrefix("https://") == true, "\(entry.verb).\(entry.inflection) has no SourceLink")
        }
        // Read from this Mac when Meep was built here; GitHub isn't asked in the tests.
        let library = SourceLibrary(cache: nil, fetcher: FakeSourceFetcher())
        for verb in Set(core.map(\.verb)).sorted() {
            let level = CodeLevel(subject: CodeSubject(label: verb, verb: verb), continuum: Continuum())
            await level.load(catalogue: catalogue, library: library)
            for code in level.inflections {
                guard let path = code.entry.source?.file, FileManager.default.fileExists(atPath: path) else { continue }
                #expect(code.localPath == path)
                let span = try #require(code.span, "\(code.name)'s class wasn't found in \(path)")
                let line = code.text?.line(span.declaration) ?? ""
                #expect(line.contains("class \(CSharpText.shortName(code.entry.class ?? ""))"), "\(code.name): \(line)")
            }
        }
    }
}

/// Against a real daemon, when `MEEP_TEST_SOCKET` names its socket (Meep2 0c83a49 or later), with `busy` running: the
/// code level's ask brings the times of a pipeline the canvas isn't showing.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MEEP_TEST_SOCKET"] != nil))
struct LiveCodeTimingTests {
    @Test func theDaemonSendsTheTimesTheCodeLevelAsksFor() async throws {
        let socket = ProcessInfo.processInfo.environment["MEEP_TEST_SOCKET"]!
        let name = ProcessInfo.processInfo.environment["MEEP_TEST_PIPELINE"] ?? "busy"
        let continuum = Continuum()
        let host = continuum.add(host: "test", kind: .local(socketPath: socket))
        let session = HostSession(host: host, settings: .init(replanEvery: .milliseconds(50), rateScale: 0.2)) {
            try await DaemonConnection.connect(socketPath: socket)
        }
        session.start()
        defer { session.stop() }
        let deadline = ContinuousClock.now + .seconds(20)
        while host.pipeline(name)?.graph == nil {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pipeline = try #require(host.pipeline(name))
        #expect(pipeline.detail == .listed)
        let module = try #require(pipeline.modules.first { $0.verb == "WriteLine" })
        #expect(module.timing == nil)

        let level = CodeLevel(subject: try #require(CodeSubject.module(module.key, in: pipeline, host: host, document: nil)), continuum: continuum)
        await level.load(catalogue: CodeFixtures.verbs, library: SourceLibrary(cache: nil, fetcher: FakeSourceFetcher()))
        let writeLine = try #require(level.shownCode)
        #expect(writeLine.name == "WriteLine")
        level.startAskingForTimes()
        defer { level.stopAskingForTimes() }
        while level.times(of: writeLine).timed.isEmpty {
            guard ContinuousClock.now < deadline + .seconds(10) else {
                Issue.record("No times came")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Only the modules asked for: the Interval and the Where have none.
        #expect(pipeline.modules.filter { $0.timing != nil }.allSatisfy { $0.verb == "WriteLine" })
        #expect(level.times(of: writeLine).merged.count > 0)
    }
}
