import ContinuumKit
import FlowKit
import Foundation
import LanguageClient
import MeepClient
import Observation

/// Level 1 of the zoom ladder (design, section 2): the C# of every inflection a module's verb has, the one the module
/// resolves to first, each with the handling times of the modules that run it. It shows where the Meeplang does, beside
/// the canvas, read-only; editing and rebuilding come later.
///
/// Where each inflection's C# is comes from `meep lsp`'s verb catalogue, and the text from ``SourceLibrary``. While
/// it's shown (``startAskingForTimes()``), it asks the hosts of the modules that run its inflections for their handling
/// times, through each host's planner, within its budget.
@MainActor @Observable
public final class CodeLevel {
    public let subject: CodeSubject
    @ObservationIgnored public let continuum: Continuum
    /// Every inflection of the verb: those the module resolves to first, then the rest in the catalogue's order.
    public private(set) var inflections: [InflectionCode] = []
    /// The inflection shown, by name (`Fetch.HTTP`).
    public var shown: String?
    /// Whether the catalogue is still being read, and why it couldn't be.
    public private(set) var state: State = .loading
    /// What the view has on screen, from 0, for tools to describe.
    public var visibleLines: ClosedRange<Int>?
    /// A number that's new each time the view should bring the shown inflection's declaration into view.
    public private(set) var revealRequest = 0

    @ObservationIgnored private var library: SourceLibrary?
    @ObservationIgnored private var asking: Task<Void, Never>?
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private let asker = "code-\(UUID().uuidString)"
    @ObservationIgnored private var analysed: [String: CSharpText] = [:]

    public enum State: Sendable, Equatable {
        case loading
        case ready
        case failed(SourceProblem)
    }

    public init(subject: CodeSubject, continuum: Continuum) {
        self.subject = subject
        self.continuum = continuum
    }

    /// The pipeline it was opened from, as `MeepPipeline.id` names it.
    public var pipelineID: String? { subject.pipeline.map { "\($0.host)/\($0.pipeline ?? "")" } }

    /// The inflection shown, once the catalogue is read.
    public var shownCode: InflectionCode? {
        inflections.first { $0.name == shown } ?? inflections.first
    }

    /// Shows an inflection, revealing its declaration.
    public func show(_ name: String) {
        shown = name
        revealRequest += 1
    }

    /// Brings the shown inflection's declaration into view again.
    public func revealDeclaration() {
        revealRequest += 1
    }

    // MARK: Reading

    /// Reads the verb catalogue for the module's pipeline (`uri`, so its plugins' verbs are in it), then each
    /// inflection's C#, the shown one first.
    public func load(using service: LanguageService, uri: String?, library: SourceLibrary) async {
        self.library = library
        state = .loading
        let catalogue: [VerbEntry]
        do {
            catalogue = try await service.verbs(for: uri)
        } catch {
            // A pipeline whose file isn't on this Mac can't be opened by the server; Meep's own verbs still can.
            guard uri != nil, let plain = try? await service.verbs(for: nil) else {
                state = .failed(.noCatalogue(reason: error.localizedDescription))
                return
            }
            catalogue = plain
        }
        await load(catalogue: catalogue, library: library)
    }

    /// Reads each inflection's C#, from a catalogue already in hand.
    public func load(catalogue: [VerbEntry], library: SourceLibrary) async {
        self.library = library
        let entries = catalogue.filter { $0.verb.caseInsensitiveCompare(subject.verb) == .orderedSame && $0.plugin == subject.plugin }
        guard !entries.isEmpty else {
            if let plugin = subject.plugin, !subject.isHere {
                state = .failed(.pluginNotHere(plugin: plugin, host: subject.hostTitle))
            } else {
                state = .failed(.unknownVerb(verb: subject.verb, host: subject.isHere ? nil : subject.hostTitle))
            }
            return
        }
        let resolved = subject.resolved.compactMap { name in entries.first { $0.inflection == name } }
        let rest = entries.filter { entry in !resolved.contains { $0.inflection == entry.inflection } }
        inflections = (resolved + rest).map { InflectionCode(entry: $0, runsHere: subject.resolved.contains($0.inflection)) }
        if shown == nil || !inflections.contains(where: { $0.name == shown }) {
            let named = subject.inflection.flatMap { name in inflections.first { $0.entry.inflection == name } }
            shown = (named ?? inflections.first)?.name
        }
        state = .ready
        revealRequest += 1
        // The shown one first, then the others together.
        if let first = shownCode { await read(first, from: library) }
        await withTaskGroup(of: Void.self) { group in
            for code in inflections where code.outcome == nil {
                group.addTask { await self.read(code, from: library) }
            }
        }
    }

    /// Tries again to read an inflection whose C# couldn't be read, such as when GitHub couldn't be reached.
    public func retry(_ code: InflectionCode) async {
        guard let library else { return }
        code.outcome = nil
        await read(code, from: library)
        if code.name == shownCode?.name { revealRequest += 1 }
    }

    private func read(_ code: InflectionCode, from library: SourceLibrary) async {
        let outcome = await library.source(of: code.entry.source, plugin: code.entry.plugin)
        if let file = outcome.file {
            let text: CSharpText
            if let known = analysed[file.identity], known.text == file.text {
                text = known
            } else {
                let source = file.text
                text = await Task.detached(priority: .userInitiated) { CSharpText(source) }.value
                analysed[file.identity] = text
            }
            code.text = text
            code.span = text.span(ofClass: code.entry.class ?? code.entry.inflection, near: code.entry.source?.line.map { $0 - 1 })
        }
        code.outcome = outcome
    }

    /// Waits until every inflection's C# has been read, or couldn't be.
    public func loaded() async {
        while state == .loading || inflections.contains(where: { $0.outcome == nil }) {
            if case .failed = state { return }
            try? await Task.sleep(for: .milliseconds(20))
            if Task.isCancelled { return }
        }
    }

    // MARK: What it says

    /// A note on where the C# shown comes from, when it may not be what the module runs: a module on another host is
    /// shown this Mac's copy.
    public var note: String? {
        guard !subject.isHere, inflections.contains(where: { $0.text != nil }) else { return nil }
        return "\(subject.hostTitle) is another machine, whose files aren't here. This is this Mac's copy of Meep's source, which may not be exactly what \(subject.hostTitle) runs."
    }

    /// The modules that run an inflection, wherever they are, with their handling times.
    public func times(of code: InflectionCode) -> InflectionTimes {
        continuum.times(ofVerb: code.entry.verb, inflection: code.entry.inflection, plugin: code.entry.plugin)
    }

    /// The inflections declared in the same file as `code`, each at its declaration's line: the gutter's marks.
    public func marks(sharingFileWith code: InflectionCode) -> [Mark] {
        guard let identity = code.outcome?.file?.identity else { return [] }
        return inflections.compactMap { other in
            guard other.outcome?.file?.identity == identity, let span = other.span else { return nil }
            return Mark(line: span.declaration, code: other)
        }
    }

    /// An inflection's class, at the line that declares it.
    public struct Mark {
        public let line: Int
        public let code: InflectionCode
    }

    // MARK: Asking for times

    /// Asks the hosts of the modules that run the verb's inflections for their handling times, once a second as
    /// modules come and go, until ``stopAskingForTimes()``.
    public func startAskingForTimes() {
        guard asking == nil else { return }
        asking = Task { [weak self] in
            while !Task.isCancelled {
                self?.askForTimes()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stopAskingForTimes() {
        asking?.cancel()
        asking = nil
        for id in asked { pipeline(id)?.endTimingAsk(by: asker) }
        asked = []
    }

    private func askForTimes() {
        var wanted: [String: Set<String>] = [:]
        let entries = inflections.isEmpty ? [] : inflections
        for code in entries {
            for (address, keys) in times(of: code).keysByPipeline {
                wanted["\(address.host)/\(address.pipeline ?? "")", default: []].formUnion(keys)
            }
        }
        for (id, keys) in wanted { pipeline(id)?.askForTiming(of: keys, by: asker) }
        for id in asked.subtracting(wanted.keys) { pipeline(id)?.endTimingAsk(by: asker) }
        asked = Set(wanted.keys)
    }

    private func pipeline(_ id: String) -> MeepPipeline? {
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return continuum.host(parts[0])?.pipeline(parts[1])
    }
}

/// What the code level is about: a module and its verb, or a verb on its own.
public struct CodeSubject: Sendable, Equatable {
    /// The module's pipeline, if it's about a module.
    public var pipeline: MeepAddress?
    /// The module's key.
    public var key: String?
    /// The module as the canvas labels it, or the verb.
    public var label: String
    public var verb: String
    /// Its plugin, by the name its pipeline gives it, or nil for Meep's own.
    public var plugin: String?
    /// The inflections the module resolves to.
    public var resolved: [String]
    /// An inflection asked for by name, to show first.
    public var inflection: String?
    public var hostTitle: String
    /// Whether the module's host is this Mac, whose files are here.
    public var isHere: Bool

    public init(
        pipeline: MeepAddress? = nil, key: String? = nil, label: String, verb: String, plugin: String? = nil, resolved: [String] = [],
        inflection: String? = nil, hostTitle: String = "This Mac", isHere: Bool = true
    ) {
        self.pipeline = pipeline
        self.key = key
        self.label = label
        self.verb = verb
        self.plugin = plugin
        self.resolved = resolved
        self.inflection = inflection
        self.hostTitle = hostTitle
        self.isHere = isHere
    }

    /// The module with `key` in a pipeline: as the open text has it, if it does, so a module typed but not running
    /// yet has its C# too; otherwise as it runs.
    @MainActor
    public static func module(_ key: String, in pipeline: MeepPipeline, host: MeepHost?, document: MeeplangDocument?) -> CodeSubject? {
        let isHere: Bool = switch host?.kind {
        case .remote?: false
        default: true
        }
        let title = host?.title ?? pipeline.host
        if let graph = document?.answer?.graph, let module = graph.modules.first(where: { $0.key == key }) {
            return CodeSubject(
                pipeline: pipeline.address, key: key, label: module.module, verb: module.verb, plugin: module.plugin,
                resolved: module.inflections, hostTitle: title, isHere: isHere
            )
        }
        guard let module = pipeline.module(key), !module.verb.isEmpty else { return nil }
        return CodeSubject(
            pipeline: pipeline.address, key: key, label: module.label, verb: module.verb, plugin: module.plugin,
            resolved: module.inflections, hostTitle: title, isHere: isHere
        )
    }

    /// What a module's C# is called: `Fetch.HTTP` for one inflection that isn't the verb's own name, otherwise `Fetch`.
    public static func name(verb: String, inflections: [String]) -> String {
        inflections.count == 1 && inflections[0] != verb ? "\(verb).\(inflections[0])" : verb
    }

    /// What its C# is called, such as `Fetch.HTTP`.
    public var name: String { Self.name(verb: verb, inflections: resolved) }

    /// The module's address, if it's about one.
    public var address: MeepAddress? {
        guard let pipeline, let key else { return nil }
        return pipeline.module(key)
    }
}

/// One inflection of the verb, and its C# once read.
@MainActor @Observable
public final class InflectionCode: Identifiable {
    public let entry: VerbEntry
    /// Whether the module the code level is about resolves to it.
    public let runsHere: Bool
    /// What reading its C# came to; nil while it's being read.
    public internal(set) var outcome: SourceOutcome?
    /// Its file's text, coloured.
    public internal(set) var text: CSharpText?
    /// Where its class is in the file, once read.
    public internal(set) var span: CSharpText.TypeSpan?

    init(entry: VerbEntry, runsHere: Bool) {
        self.entry = entry
        self.runsHere = runsHere
    }

    public nonisolated var id: String { name }

    /// `Fetch.HTTP`, or `Where` for a verb with one inflection of its own name.
    public nonisolated var name: String {
        entry.inflection == entry.verb ? entry.verb : "\(entry.verb).\(entry.inflection)"
    }

    /// The file's name, such as `Fetch.cs`.
    public var fileName: String? {
        if let file = entry.source?.file { return (file as NSString).lastPathComponent }
        return entry.source?.url.flatMap { URL(string: $0)?.lastPathComponent }
    }

    /// The line that declares its class, from 1, as the file has it now, or as the catalogue said.
    public var declarationLine: Int? {
        span.map { $0.declaration + 1 } ?? entry.source?.line
    }

    /// The file on this Mac, when that's where its C# came from.
    public var localPath: String? {
        if case .loaded(let file)? = outcome, case .file(let path) = file.origin { return path }
        return nil
    }

    /// Where its C# came from, in a few words: `Fetch.cs on this Mac` or `GitHub, at 810c2fc (kept on this Mac)`.
    public var originText: String? {
        guard case .loaded(let file)? = outcome else { return nil }
        switch file.origin {
        case .file(let path):
            return "\((path as NSString).abbreviatingWithTildeInPath), on this Mac"
        case .sourceLink(let url, let cached):
            let commit = SourceLinkPage.commit(of: url).map { " at \($0)" } ?? ""
            return "\(SourceLinkPage.site(of: url))\(commit), from its SourceLink\(cached ? " (kept on this Mac)" : "")"
        }
    }
}
