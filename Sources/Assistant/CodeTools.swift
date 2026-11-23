import CodeEditing
import ContinuumKit
import FlowKit
import Foundation
import LanguageClient
import MeepClient

/// The code level's tool (design, section 2, level 1): the C# behind a verb, with the handling times of the modules
/// that run it. Read-only, like the view; editing and rebuilding come later.
extension ContinuumTools {
    /// How long the tool waits for handling times it had to ask for.
    nonisolated(unsafe) static var timingWait: Duration = .seconds(4)

    static func readInflectionSource(_ viewer: Viewer) -> Tool {
        Tool(
            name: "read_inflection_source", title: "Read an inflection's C#",
            description: "The C# behind a verb: the inflection a module runs (give the module's address), or one you name, such as Fetch.HTTP. Says where the C# came from (the file on this Mac, or its SourceLink address at the commit Meep was built from, read over HTTPS), and gives its class with its documentation and attributes, with line numbers, or the whole file with whole set. Gives the handling times of every module in the Continuum that runs it, merged (median, 99th percentile, mean, fastest, slowest), then each module's, asking hosts for them if they haven't come. Lists the verb's other inflections with where each is. Modules on other hosts are shown this Mac's copy of Meep's source, which may not be exactly what they run.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "address": ["type": "string", "description": "A module's address, such as meep://local/orders/m3, for the inflection it runs."],
                    "verb": ["type": "string", "description": "A verb and inflection, such as Fetch.HTTP, or a verb with one inflection, such as Where. With an address, picks another of its verb's inflections."],
                    "whole": ["type": "boolean", "default": false, "description": "The whole file rather than the class."],
                ],
            ]
        ) { arguments in
            let level = try await loadCode(arguments, in: viewer)
            let named = arguments["verb"]?.string.flatMap(Self.inflection(in:))
            let chosen: InflectionCode
            if let named {
                guard let match = level.inflections.first(where: { $0.entry.inflection.caseInsensitiveCompare(named) == .orderedSame }) else {
                    throw ToolError("\(level.subject.verb) has no inflection called \(named). It has \(level.inflections.map(\.name).joined(separator: ", ")).")
                }
                chosen = match
            } else if level.subject.key != nil || level.inflections.count == 1, let first = level.inflections.first {
                chosen = first
            } else {
                // A verb with several inflections, none named: say what there is.
                await waitForTimes(of: level)
                return .json(.object([
                    "verb": .string(level.subject.verb),
                    "note": .string("\(level.subject.verb) has \(level.inflections.count) inflections. Name one, such as \(level.inflections[0].name), for its C#."),
                    "inflections": .array(level.inflections.map { describe($0, in: level) }),
                ]))
            }
            await waitForTimes(of: level)
            var result: [String: JSONValue] = describe(chosen, in: level).objectValue ?? [:]
            if let address = level.subject.address {
                result["module"] = .object(["address": .string(address.description), "label": .string(level.subject.label)])
                result["moduleRunsIt"] = .bool(chosen.runsHere)
                if !chosen.runsHere { result["moduleRuns"] = .array(level.subject.resolved.map { .string($0) }) }
            }
            if let note = level.note { result["note"] = .string(note) }
            let others = level.inflections.filter { $0 !== chosen }
            if !others.isEmpty { result["otherInflections"] = .array(others.map { describe($0, in: level, briefly: true) }) }
            var content: [ToolResult.Content] = [.text(JSONValue.object(result).text(pretty: true))]
            if let text = chosen.text {
                content.append(.text(numbered(text, span: chosen.span, whole: arguments["whole"]?.bool ?? false, declaration: chosen.declarationLine)))
            }
            return ToolResult(content)
        }
    }

    /// Reads the catalogue and every inflection's C# for what the arguments name, as the code level would show it.
    static func loadCode(_ arguments: JSONValue, in viewer: Viewer) async throws -> CodeLevel {
        guard let language = viewer.language else { throw ToolError("This app has no language server to ask for Meep's verb catalogue.") }
        var subject: CodeSubject
        var uri: String?
        if arguments["address"] != nil {
            let (host, pipeline, module) = try resolve(arguments["address"], in: viewer, needsPipeline: true)
            guard let pipeline, let module else {
                throw ToolError("Give a module's address, such as meep://local/orders/m3, or a verb such as Fetch.HTTP.")
            }
            let document = viewer.document(for: pipeline)
            guard let found = CodeSubject.module(module.key, in: pipeline, host: host, document: document) else {
                throw ToolError("\(pipeline.address.module(module.key)) has no verb yet: its pipeline's graph hasn't come.")
            }
            subject = found
            uri = document?.uri ?? MeepLanguageServer.uri(forPath: pipeline.path)
        } else if let text = arguments["verb"]?.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            let verb = String(text.split(separator: ".", maxSplits: 1)[0])
            subject = CodeSubject(label: verb, verb: verb, inflection: inflection(in: text))
        } else {
            throw ToolError("Give a module's address, such as meep://local/orders/m3, or a verb, such as Fetch.HTTP.")
        }
        if let named = arguments["verb"]?.string.flatMap(inflection(in:)) { subject.inflection = named }
        let level = CodeLevel(subject: subject, continuum: viewer.continuum)
        await level.load(using: language, uri: uri, library: viewer.sources ?? SourceLibrary())
        if case .failed(let problem) = level.state { throw ToolError(problem.message) }
        await level.loaded()
        return level
    }

    /// `HTTP` from `Fetch.HTTP`.
    static func inflection(in text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }

    /// Asks for the times of the modules that run the verb, if none have come, and waits a little for them.
    static func waitForTimes(of level: CodeLevel) async {
        let reachable = level.inflections.flatMap { level.times(of: $0).uses }.contains { use in
            level.continuum.host(use.address.host)?.isReachable == true
        }
        let haveTimes = level.inflections.contains { !level.times(of: $0).timed.isEmpty }
        guard reachable, !haveTimes else { return }
        level.startAskingForTimes()
        defer { level.stopAskingForTimes() }
        let deadline = ContinuousClock.now + timingWait
        while ContinuousClock.now < deadline, !level.inflections.contains(where: { !level.times(of: $0).timed.isEmpty }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// An inflection: where its C# is, where it came from, and the times of the modules that run it.
    static func describe(_ code: InflectionCode, in level: CodeLevel, briefly: Bool = false) -> JSONValue {
        var entry: [String: JSONValue] = ["inflection": .string(code.name)]
        if let className = code.entry.class { entry["class"] = .string(className) }
        if let plugin = code.entry.plugin { entry["plugin"] = .string(plugin) }
        if let line = code.declarationLine { entry["line"] = .number(line) }
        switch code.outcome {
        case .loaded(let file)?:
            switch file.origin {
            case .file(let path):
                entry["source"] = .object(["from": "this Mac", "file": .string(path)])
            case .sourceLink(let url, let cached):
                var source: [String: JSONValue] = ["from": "SourceLink", "url": .string(url), "keptOnThisMac": .bool(cached)]
                if let page = SourceLinkPage.page(for: url, line: code.declarationLine) { source["page"] = .string(page.absoluteString) }
                entry["source"] = .object(source)
            }
            if !briefly, let span = code.span { entry["classLines"] = .string("\(span.first + 1)–\(span.last + 1) of \(code.text?.lines.lineCount ?? 0)") }
        case .unavailable(let problem)?:
            entry["noSource"] = .string(problem.message)
        case nil:
            entry["noSource"] = "It's still being read."
        }
        entry["handling"] = describe(level.times(of: code), briefly: briefly)
        if !briefly, let description = code.entry.description { entry["description"] = .string(description) }
        return .object(entry)
    }

    static func describe(_ times: InflectionTimes, briefly: Bool) -> JSONValue {
        var entry: [String: JSONValue] = ["modulesRunningIt": .number(times.uses.count)]
        let merged = times.merged
        guard !merged.isEmpty else {
            if !times.uses.isEmpty { entry["note"] = "No handling times have come from their hosts." }
            return .object(entry)
        }
        entry["seconds"] = seconds(merged)
        if !briefly {
            entry["byModule"] = .array(times.uses.map { use in
                var item: [String: JSONValue] = ["module": .string(use.address.description), "label": .string(use.label), "host": .string(use.hostTitle)]
                if let timing = use.timing, !timing.isEmpty { item["seconds"] = seconds(timing) }
                if use.shared { item["couldBeAnotherInflection"] = true }
                return .object(item)
            })
        }
        return .object(entry)
    }

    private static func seconds(_ histogram: HandlingHistogram) -> JSONValue {
        var entry: [String: JSONValue] = ["messages": .number(histogram.count)]
        func put(_ key: String, _ value: Double?) {
            if let value { entry[key] = .number((value * 1_000_000).rounded() / 1_000_000) }
        }
        put("p50", histogram.quantile(0.5))
        put("p99", histogram.quantile(0.99))
        put("mean", histogram.mean)
        put("fastest", histogram.min)
        put("slowest", histogram.max)
        return .object(entry)
    }

    /// The class, with its documentation and attributes, or the whole file, with line numbers.
    static func numbered(_ text: CSharpText, span: CSharpText.TypeSpan?, whole: Bool, declaration: Int?) -> String {
        let count = text.lines.lineCount
        var range: ClosedRange<Int>
        if whole {
            range = 0...max(0, count - 1)
        } else if let span {
            range = span.lines
        } else {
            let line = max(0, (declaration ?? 1) - 1)
            range = max(0, line - 10)...min(count - 1, line + 60)
        }
        let limit = whole ? 2000 : 400
        let shown = range.lowerBound...min(range.upperBound, range.lowerBound + limit - 1)
        var lines = shown.map { String(format: "%4d  ", $0 + 1) + text.line($0) }
        if shown.upperBound < range.upperBound {
            lines.append("… \(range.upperBound - shown.upperBound) more lines\(whole ? "" : "; ask with whole for the file")")
        }
        return lines.joined(separator: "\n")
    }

    /// What the code level shows, for describe_view.
    static func describe(_ level: CodeLevel) -> JSONValue {
        var entry: [String: JSONValue] = ["verb": .string(level.subject.verb)]
        if let address = level.subject.address {
            entry["module"] = .object(["address": .string(address.description), "label": .string(level.subject.label)])
        }
        switch level.state {
        case .loading: entry["state"] = "reading the verb catalogue"
        case .failed(let problem): entry["noSource"] = .string(problem.message)
        case .ready: break
        }
        if let shown = level.shownCode {
            var shownEntry = describe(shown, in: level, briefly: true).objectValue ?? [:]
            if let lines = level.visibleLines { shownEntry["linesOnScreen"] = .string("\(lines.lowerBound + 1)–\(lines.upperBound + 1)") }
            if let span = shown.span { shownEntry["classLines"] = .string("\(span.first + 1)–\(span.last + 1)") }
            if level.subject.key != nil { shownEntry["moduleRunsIt"] = .bool(shown.runsHere) }
            entry["shown"] = .object(shownEntry)
        }
        entry["inflections"] = .array(level.inflections.map { .string($0.runsHere && level.subject.key != nil ? "\($0.name) (the module's)" : $0.name) })
        if let note = level.note { entry["note"] = .string(note) }
        return .object(entry)
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }
}
