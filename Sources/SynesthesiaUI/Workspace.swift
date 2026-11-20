import CodeEditing
import ContinuumKit
import Foundation
import MeepClient
import Observation
import Stage

/// The window's state that isn't the Continuum itself: what's selected, the stage the canvas is drawing, and the
/// Meeplang open beside it. Tools, such as the MCP server's, read and change it as the person does.
@MainActor @Observable
public final class Workspace {
    public let continuum: Continuum
    /// The whole Continuum as the canvas draws it, in one zoom from the mesh to a pipeline (design, section 2).
    public let canvas: ContinuumStage
    /// The host or pipeline selected in the sidebar, or nil for the whole mesh. Selecting one moves the canvas to it;
    /// moving the canvas onto another selects that.
    public var selection: MeepAddress? {
        didSet {
            canvas.selected = selection
            if !followingCanvas, selection != oldValue { canvas.show(selection) }
        }
    }
    /// The stage of the pipeline in focus, while one is.
    public private(set) var stage: PipelineStage?
    /// Each pipeline's editor, made when it's first in focus, kept so its palette and notices stay as they were.
    @ObservationIgnored private var editors: [String: PipelineEditor] = [:]
    @ObservationIgnored private var followingCanvas = false
    /// Whether a pipeline's Meeplang shows beside its canvas.
    public var showsText = false
    /// The language server the text uses, if the platform can start one.
    public let language: LanguageService?
    /// Each pipeline's open text, by the pipeline's id. Text with changes not saved stays open while it's hidden.
    public private(set) var documents: [String: MeeplangDocument] = [:]
    /// Why a pipeline's text couldn't be opened, by the pipeline's id.
    public private(set) var textProblems: [String: String] = [:]
    /// The latest ask to scroll the text to a module, from the canvas or a tool.
    public private(set) var textFocus: TextFocus?

    /// A module or line to scroll the text to, with a number that's new each time.
    public struct TextFocus: Equatable, Sendable {
        public let id: Int
        public let pipeline: String
        /// The module's key.
        public let key: String?
        /// The line, from 0, when it's a line rather than a module.
        public let line: Int?
    }

    /// Each pipeline's probes, by the pipeline's id, in the order they were opened.
    public private(set) var probes: [String: [Probe]] = [:]
    /// A message waiting to be sent, in the composer, until the person sends it or doesn't.
    public private(set) var injection: InjectionRequest?

    /// A message to send into a module, shown in the composer before it goes (design, section 6).
    public struct InjectionRequest: Identifiable, Equatable, Sendable {
        public let id: Int
        public let pipeline: String
        public let key: String
        /// The text or JSON to start with.
        public let body: String
        public let isJSON: Bool
        /// Who asked: the person, or a tool such as Claude's.
        public let askedBy: String?
    }

    /// What became of a message in the composer.
    public enum InjectionOutcome: Equatable, Sendable {
        case sent(Injected)
        /// The person closed the composer without sending it, or another took its place.
        case notSent
    }

    @ObservationIgnored private var focuses = 0
    @ObservationIgnored private var opening: Set<String> = []
    @ObservationIgnored private var injections = 0
    @ObservationIgnored private var injectionWaiting: (id: Int, continuation: CheckedContinuation<InjectionOutcome, Never>)?
    @ObservationIgnored private var loadedProbes: Set<String> = []

    public init(continuum: Continuum, language: LanguageService? = nil) {
        self.continuum = continuum
        self.language = language
        canvas = ContinuumStage(continuum: continuum)
        canvas.onFocus = { [weak self] address in self?.follow(address) }
        canvas.onSelect = { [weak self] address in self?.follow(address) }
    }

    /// Selects what the canvas has settled on, without moving it.
    private func follow(_ address: MeepAddress?) {
        followingCanvas = true
        defer { followingCanvas = false }
        if selection != address { selection = address }
    }

    func showing(_ stage: PipelineStage) {
        self.stage = stage
    }

    func hidden(_ stage: PipelineStage) {
        if self.stage === stage { self.stage = nil }
    }

    /// The editor that turns the canvas's gestures on a pipeline into edits of its text.
    public func editor(for pipeline: MeepPipeline, host: MeepHost?) -> PipelineEditor {
        let stage = canvas.stage(for: pipeline)
        if let editor = editors[pipeline.id], editor.stage === stage { return editor }
        let editor = PipelineEditor(pipeline: pipeline, host: host, stage: stage, workspace: self)
        stage.editing = editor
        editors[pipeline.id] = editor
        return editor
    }

    // MARK: Text

    /// The open text of a pipeline, if it's open.
    public func document(for pipeline: MeepPipeline) -> MeeplangDocument? {
        documents[pipeline.id]
    }

    /// The text showing beside the canvas, if it is.
    public var shownDocument: MeeplangDocument? {
        guard showsText, let stage else { return nil }
        return documents[stage.pipeline.id]
    }

    /// Texts with changes that aren't saved.
    public var editedDocuments: [MeeplangDocument] {
        documents.values.filter(\.isEdited)
    }

    /// Opens a pipeline's text, if it isn't open, from its file on this Mac or from its daemon.
    public func openText(for pipeline: MeepPipeline, host: MeepHost?) async {
        guard let language, documents[pipeline.id] == nil, !opening.contains(pipeline.id) else { return }
        opening.insert(pipeline.id)
        defer { opening.remove(pipeline.id) }
        do {
            documents[pipeline.id] = try await MeeplangDocument.open(pipeline, host: host, service: language)
            textProblems[pipeline.id] = nil
        } catch {
            textProblems[pipeline.id] = error.localizedDescription
        }
    }

    /// Closes a pipeline's text, unless it has changes that aren't saved.
    public func closeText(for pipeline: MeepPipeline) {
        guard let document = documents[pipeline.id], !document.isEdited else { return }
        document.close()
        documents.removeValue(forKey: pipeline.id)
    }

    /// Shows the text beside the canvas, scrolled to a module.
    public func showText(of pipeline: MeepPipeline, at key: String?) {
        showsText = true
        guard let key else { return }
        focuses += 1
        textFocus = TextFocus(id: focuses, pipeline: pipeline.id, key: key, line: nil)
    }

    /// Shows the text beside the canvas, scrolled to a line, from 0.
    public func showText(of pipeline: MeepPipeline, atLine line: Int) {
        showsText = true
        focuses += 1
        textFocus = TextFocus(id: focuses, pipeline: pipeline.id, key: nil, line: line)
    }

    // MARK: Probes

    public func probes(for pipeline: MeepPipeline) -> [Probe] {
        probes[pipeline.id] ?? []
    }

    /// Opens a probe on a module's output or a wire, or shows the one already there.
    @discardableResult
    public func openProbe(on target: Probe.Target, in pipeline: MeepPipeline, host: MeepHost, condition: String = "", sample: Double = 1) -> Probe {
        if let open = probes(for: pipeline).first(where: { $0.target == target && $0.condition == condition }) {
            if open.state == .paused { open.start() }
            return open
        }
        let used = Set(probes(for: pipeline).map(\.colorIndex))
        let color = (0..<20).first { !used.contains($0) } ?? probes(for: pipeline).count
        let probe = Probe(pipeline: pipeline, host: host, target: target, condition: condition, sample: sample, colorIndex: color)
        probes[pipeline.id, default: []].append(probe)
        probe.start()
        return probe
    }

    public func closeProbe(_ probe: Probe) {
        probe.stop()
        probes[probe.pipeline.id]?.removeAll { $0 === probe }
        if probe.isSaved { saveProbes(for: probe.pipeline) }
    }

    /// Opens the probes kept with a pipeline's file, once, for a pipeline on this Mac.
    public func openSavedProbes(for pipeline: MeepPipeline, host: MeepHost) {
        guard case .local = host.kind, !loadedProbes.contains(pipeline.id) else { return }
        loadedProbes.insert(pipeline.id)
        for saved in ProbeStore.load(for: pipeline.path) {
            // Keys can change when a pipeline starts again; what it was on is found by its label if so.
            let target: Probe.Target
            switch saved.target {
            case .module(let key) where pipeline.module(key) == nil:
                guard let found = pipeline.modules.first(where: { "\($0.label) out" == saved.label }) else { continue }
                target = .module(found.key)
            default:
                target = saved.target
            }
            let probe = openProbe(on: target, in: pipeline, host: host, condition: saved.condition, sample: saved.sample)
            probe.isSaved = true
        }
    }

    /// Writes the probes kept for a pipeline to `.synesthesia/probes.json` beside its file.
    public func saveProbes(for pipeline: MeepPipeline) {
        let kept = probes(for: pipeline).filter(\.isSaved).map {
            ProbeStore.Saved(file: (pipeline.path as NSString).lastPathComponent, target: $0.target, label: $0.title, condition: $0.condition, sample: $0.sample)
        }
        try? ProbeStore.save(kept, for: pipeline.path)
    }

    /// Stops a pipeline's probes while it isn't showing, or starts them again.
    public func setProbesRunning(_ running: Bool, for pipeline: MeepPipeline) {
        for probe in probes(for: pipeline) {
            if running, probe.state == .paused { probe.start() } else if !running { probe.stop() }
        }
    }

    // MARK: Sending messages

    /// Opens the composer with a message to send into a module, which the person sends or doesn't.
    public func compose(into key: String, of pipeline: MeepPipeline, body: String = "", isJSON: Bool = false, askedBy: String? = nil) {
        selection = pipeline.address
        injections += 1
        if let waiting = injectionWaiting {
            injectionWaiting = nil
            waiting.continuation.resume(returning: .notSent)
        }
        injection = InjectionRequest(id: injections, pipeline: pipeline.id, key: key, body: body, isJSON: isJSON, askedBy: askedBy)
    }

    /// Waits for the person to send the message in the composer, or not.
    public func outcome(of request: InjectionRequest) async -> InjectionOutcome {
        guard injection?.id == request.id else { return .notSent }
        return await withCheckedContinuation { injectionWaiting = (request.id, $0) }
    }

    /// The composer has closed, having sent its message or not.
    public func finishInjection(_ request: InjectionRequest, _ outcome: InjectionOutcome) {
        if injection?.id == request.id { injection = nil }
        if let waiting = injectionWaiting, waiting.id == request.id {
            injectionWaiting = nil
            waiting.continuation.resume(returning: outcome)
        }
    }

    /// Closes every text, for quitting.
    public func closeAllText() {
        for document in documents.values { document.close() }
        documents.removeAll()
    }
}
