import ContinuumKit
import Foundation
import LanguageClient
import MeepClient
import Observation

/// A pipeline's Meeplang as it's edited beside the canvas (design, sections 2 and 5): the text, its colours and
/// problems, and its pipeline as a graph from `meep lsp`, with keys that agree with the running pipeline's so a
/// tile keeps its counts while its line is typed.
///
/// The platform's text view shows ``text`` and reports each edit with ``edit(_:)``. When the document needs the view
/// to take other text (reverting, or the file changing elsewhere) it sets ``replacement``.
@MainActor @Observable
public final class MeeplangDocument {
    /// Whether the text is saved, and whether the daemon runs what's saved.
    public enum Status: Equatable, Sendable {
        /// The file as it is.
        case saved
        /// Changed and not saved.
        case edited
        /// Saved; waiting for the daemon to load it again.
        case reloading
        /// The daemon loaded it, as saved.
        case reloaded(Date)
        /// Saved, but the daemon hasn't loaded it: it isn't watching the file. It runs as it was until reloaded.
        case notWatched
        /// Saved, but it doesn't load, so the daemon runs it as it was.
        case savedBroken
        /// The daemon couldn't reload it, and why.
        case reloadFailed(String)
        /// The file changed on disk while there were changes here that aren't saved.
        case changedElsewhere
    }

    /// Text the view should take in place of its own, with a number that's new each time.
    public struct Replacement: Equatable, Sendable {
        public let id: Int
        public let text: String
    }

    /// Keys that changed, old to new, with a number that's new each time, so the canvas can move each tile to its
    /// new key before drawing.
    public struct Renaming: Equatable, Sendable {
        public let id: Int
        public let keys: [String: String]
    }

    public let path: String
    public let uri: String
    /// The running pipeline whose text this is, if it's running.
    public let pipeline: MeepPipeline?
    public let host: MeepHost?
    public let service: LanguageService
    /// Text from another host's daemon can be read, not edited, for now.
    public let isReadOnly: Bool

    public private(set) var text: String
    /// Counts up with each change, as the language server numbers them.
    public private(set) var version = 1
    public private(set) var savedText: String
    public private(set) var lines: LineIndex
    /// The latest graph from the language server, with what's broken and what was renamed.
    public private(set) var answer: GraphAnswer?
    public private(set) var renaming: Renaming?
    /// The problems in the text now, from the language server.
    public private(set) var diagnostics: [LSPDiagnostic] = []
    /// Colours for the text at ``highlightsVersion``.
    public private(set) var highlights: [Highlight] = []
    public private(set) var highlightsVersion = 0
    public private(set) var status: Status = .saved
    public private(set) var replacement: Replacement?
    /// Why the keys may not be the daemon's, if they may not.
    public private(set) var baseProblem: String?

    public var isEdited: Bool { text != savedText }

    /// The modules written on each line of this file, from 0, by key, in the order they're written.
    public private(set) var modulesByLine: [Int: [String]] = [:]

    @ObservationIgnored private let canonicalPath: String
    @ObservationIgnored private var lastBase: (version: Int, text: String)?
    @ObservationIgnored private var tokensTask: Task<Void, Never>?
    @ObservationIgnored private var baseTask: Task<Void, Never>?
    @ObservationIgnored private var reloadWait: Task<Void, Never>?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var fileWatch: DispatchSourceFileSystemObject?
    @ObservationIgnored private var replacements = 0
    @ObservationIgnored private var renamings = 0
    /// How long to wait after saving for the daemon to reload, before saying it isn't watching.
    @ObservationIgnored public var reloadTimeout: Duration = .seconds(2)

    /// A document for text from `path`, opened in the language server, following `pipeline`'s keys if it's running.
    public init(path: String, text: String, pipeline: MeepPipeline? = nil, host: MeepHost? = nil, service: LanguageService, isReadOnly: Bool = false) {
        self.path = path
        uri = MeepLanguageServer.uri(forPath: path)
        canonicalPath = Self.canonical(path)
        self.text = text
        savedText = text
        lines = LineIndex(text)
        self.pipeline = pipeline
        self.host = host
        self.service = service
        self.isReadOnly = isReadOnly
        start()
    }

    /// Opens a pipeline's text: its file, if it's on this Mac, or what its daemon runs, read-only.
    public static func open(_ pipeline: MeepPipeline, host: MeepHost?, service: LanguageService) async throws -> MeeplangDocument {
        if case .local? = host?.kind, let text = try? String(contentsOfFile: pipeline.path, encoding: .utf8) {
            return MeeplangDocument(path: pipeline.path, text: text, pipeline: pipeline, host: host, service: service)
        }
        guard let link = host?.link else {
            throw DocumentError("\(host?.title ?? pipeline.host) can't be reached, so \(pipeline.name)'s text can't be read.")
        }
        let source = try await link.source(pipeline.name)
        return MeeplangDocument(path: source.path, text: source.text, pipeline: pipeline, host: host, service: service, isReadOnly: true)
    }

    // MARK: The language server

    private func start() {
        service.send { [weak self] server in
            guard let self, !self.closed else { return }
            self.service.register(self)
            await self.reopen(in: server)
        }
        followBase()
        refreshBase()
        watchFile()
    }

    /// Notices the file changing on disk, as when it's saved from another editor, whether or not a daemon reloads it.
    private func watchFile() {
        fileWatch?.cancel()
        fileWatch = nil
        guard !isReadOnly, !closed else { return }
        let descriptor = Darwin.open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.fileWatch else { return }
                let replaced = !source.data.intersection([.delete, .rename]).isEmpty
                self.checkDisk()
                // An editor that saves by replacing the file leaves this watching the old one, so it watches anew.
                if replaced { self.watchFile() }
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        fileWatch = source
    }

    /// Opens it in `server`, as when it first opens or the server has started again.
    func reopen(in server: MeepLanguageServer) async {
        try? await server.open(uri, text: text, version: version)
        if let answer = try? await server.graph(uri, subscribe: true) { take(answer) }
        lastBase = nil
        refreshBase()
        scheduleTokens(after: .zero)
    }

    /// Takes a graph the server sent or answered with.
    func take(_ answer: GraphAnswer) {
        guard answer.uri == uri, !closed else { return }
        if let keys = answer.renamed, !keys.isEmpty {
            renamings += 1
            renaming = Renaming(id: renamings, keys: keys)
        }
        // Answers can arrive out of order by a hair, a request's answer and a notification; an older one is dropped.
        if let current = self.answer, (answer.version, answer.graph?.version ?? 0) < (current.version, current.graph?.version ?? 0) {
            return
        }
        self.answer = answer
        modulesByLine = Self.modulesByLine(answer.graph, in: canonicalPath)
    }

    func take(_ diagnostics: [LSPDiagnostic]) {
        guard !closed else { return }
        self.diagnostics = diagnostics
    }

    private func scheduleTokens(after delay: Duration = .milliseconds(40)) {
        tokensTask?.cancel()
        tokensTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !self.closed else { return }
            let version = self.version
            let uri = self.uri
            guard let tokens = try? await self.service.perform({ try await $0.semanticTokens(uri) }),
                  let legend = self.service.capabilities?.legend, version == self.version else { return }
            self.highlights = Highlight.from(tokens.data, legend: legend, lines: self.lines)
            self.highlightsVersion = version
        }
    }

    // MARK: Editing

    /// The view's text has changed to `newText`.
    public func edit(_ newText: String) {
        guard newText != text, !closed else { return }
        apply(newText)
        if case .changedElsewhere = status { return }
        status = isEdited ? .edited : .saved
    }

    private func apply(_ newText: String) {
        text = newText
        version += 1
        lines = LineIndex(newText)
        let (uri, version) = (uri, version)
        service.send { try await $0.change(uri, text: newText, version: version) }
        scheduleTokens()
    }

    /// Gives the view `newText` to show, and takes it as the text.
    private func replace(with newText: String) {
        replacements += 1
        replacement = Replacement(id: replacements, text: newText)
        apply(newText)
    }

    /// Puts back the file as it is on disk, which is the saved text unless it changed elsewhere.
    public func revert() {
        if !isReadOnly, let disk = try? String(contentsOfFile: path, encoding: .utf8) { savedText = disk }
        if text != savedText { replace(with: savedText) }
        status = .saved
    }

    /// Writes the text to its file. A daemon watching the file reloads it within a few milliseconds; one that isn't
    /// runs the pipeline as it was until ``reloadPipeline()``.
    public func save() throws {
        guard !isReadOnly else { throw DocumentError("This text is from \(host?.title ?? "another host")'s daemon, and can't be saved here yet.") }
        // In place rather than by replacing the file, so whatever watches the file sees it change.
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        savedText = text
        reloadWait?.cancel()
        guard let pipeline, pipeline.state.isLive else {
            status = .saved
            return
        }
        if diagnostics.contains(where: \.isError) || answer?.current == false {
            status = .savedBroken
            return
        }
        guard lastBase?.text != text else {
            status = .saved
            return
        }
        status = .reloading
        reloadWait = Task { [weak self, reloadTimeout] in
            try? await Task.sleep(for: reloadTimeout)
            guard let self, !Task.isCancelled, self.status == .reloading else { return }
            self.status = .notWatched
        }
    }

    /// Asks the daemon to load the saved file again, for a daemon that isn't watching it.
    public func reloadPipeline() async {
        guard let pipeline, let link = host?.link else { return }
        status = .reloading
        do {
            try await link.reload(pipeline.name)
            status = .reloaded(Date())
            refreshBase()
        } catch {
            status = .reloadFailed(error.localizedDescription)
        }
    }

    /// Stops following the pipeline and closes the text in the language server.
    public func close() {
        guard !closed else { return }
        closed = true
        tokensTask?.cancel()
        baseTask?.cancel()
        reloadWait?.cancel()
        fileWatch?.cancel()
        fileWatch = nil
        service.unregister(self)
        let uri = uri
        service.send { try await $0.close(uri) }
    }

    // MARK: Keys the daemon's

    /// Follows the running pipeline: each new version of its graph is given to the language server as the base its
    /// keys agree with (Meep2's lsp-graph report, "What a client has to do").
    private func followBase() {
        guard let pipeline else { return }
        withObservationTracking {
            _ = pipeline.graph?.version
            _ = pipeline.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                self.refreshBase()
                self.followBase()
            }
        }
    }

    private func refreshBase() {
        guard let pipeline, let host, !closed else { return }
        baseTask?.cancel()
        baseTask = Task { [weak self] in
            guard let self else { return }
            await self.takeBase(of: pipeline, on: host)
            self.checkDisk()
        }
    }

    private func takeBase(of pipeline: MeepPipeline, on host: MeepHost) async {
        let uri = uri
        let name = pipeline.name
        guard pipeline.state.isLive else {
            // Stopped: keys stay as they are, and new ones carry on from them.
            guard lastBase != nil else { return }
            lastBase = nil
            _ = try? await service.perform { try await $0.setBase(uri, pipeline: name, graph: nil, text: nil) }
            return
        }
        guard let link = host.link else { return }
        do {
            // The text, then the graph, so a reload between them shows as a graph newer than the text, which the
            // server refuses, rather than the other way round.
            let source = try await link.source(name)
            let graph = try await link.graph(name)
            guard !Task.isCancelled else { return }
            if case .reloading = status, source.text == savedText { status = .reloaded(Date()) }
            if lastBase?.version == graph.version, lastBase?.text == source.text { return }
            let answer = try await service.perform { try await $0.setBase(uri, pipeline: name, graph: graph, text: source.text) }
            lastBase = (graph.version, source.text)
            baseProblem = nil
            if let answer { take(answer) }
        } catch is CancellationError {
        } catch {
            baseProblem = "The keys may not be the daemon's: \(error.localizedDescription)"
        }
    }

    /// Takes the file's text if it changed elsewhere and there's nothing unsaved here; says so if there is.
    private func checkDisk() {
        guard !isReadOnly, !closed, let disk = try? String(contentsOfFile: path, encoding: .utf8), disk != savedText else { return }
        if isEdited {
            status = .changedElsewhere
        } else {
            savedText = disk
            replace(with: disk)
            status = .saved
        }
    }

    // MARK: Lines and modules

    /// The innermost module written on `line` (from 0), by key.
    public func module(atLine line: Int) -> String? {
        guard let graph = answer?.graph else { return nil }
        var best: (key: String, size: Int)?
        for module in graph.modules {
            guard let span = spanHere(of: module) else { continue }
            let first = span.startLine - 1
            let last = span.endLine - 1
            guard line >= first, line <= last else { continue }
            let size = (last - first) * 10_000 + (span.endColumn - span.startColumn)
            if size < best?.size ?? .max { best = (module.key, size) }
        }
        return best?.key
    }

    /// Where a module is written in this file, in UTF-16 offsets: its own span, or the line that uses the template or
    /// include it came from.
    public func range(of key: String) -> Range<Int>? {
        guard let module = answer?.graph?.modules.first(where: { $0.key == key }), let span = spanHere(of: module) else { return nil }
        return lines.range(of: span)
    }

    /// The line, from 0, a module starts on in this file.
    public func line(of key: String) -> Int? {
        guard let module = answer?.graph?.modules.first(where: { $0.key == key }), let span = spanHere(of: module) else { return nil }
        return span.startLine - 1
    }

    private func spanHere(of module: GraphModule) -> GraphSpan? {
        Self.spanHere(of: module, in: canonicalPath)
    }

    private static func spanHere(of module: GraphModule, in path: String) -> GraphSpan? {
        if canonical(module.span.file) == path { return module.span }
        if let use = module.templates?.first(where: { canonical($0.span.file) == path }) { return use.span }
        if let include = module.include, canonical(include.span.file) == path { return include.span }
        return nil
    }

    private static func modulesByLine(_ graph: PipelineGraph?, in path: String) -> [Int: [String]] {
        var byLine: [Int: [String]] = [:]
        for module in graph?.modules ?? [] {
            guard let span = spanHere(of: module, in: path) else { continue }
            byLine[span.startLine - 1, default: []].append(module.key)
        }
        return byLine
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: Hovers and completions

    /// What the language server says about the word at `offset`, as markdown.
    public func hover(at offset: Int) async -> String? {
        let (uri, position) = (uri, lines.position(at: offset))
        return try? await service.perform { try await $0.hover(uri, at: position) }
    }

    /// What could be typed at `offset`.
    public func completions(at offset: Int) async -> [CompletionItem] {
        let (uri, position) = (uri, lines.position(at: offset))
        return (try? await service.perform { try await $0.completions(uri, at: position) }) ?? []
    }

    /// The errors and warnings now, as a line each for this file's, with the file's name for an included file's.
    public var problemLines: [String] {
        diagnostics.map { diagnostic in
            let file = diagnostic.uri.flatMap(MeepLanguageServer.path(forURI:)).map(Self.canonical)
            let place = file == nil || file == canonicalPath ? "Line \(diagnostic.range.start.line + 1)"
                : "\((file! as NSString).lastPathComponent), line \(diagnostic.range.start.line + 1)"
            return "\(place): \(diagnostic.message)"
        }
    }
}

/// Why a document couldn't be opened or saved.
public struct DocumentError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
