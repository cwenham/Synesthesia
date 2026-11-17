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
    /// The host or pipeline selected in the sidebar.
    public var selection: MeepAddress?
    /// The stage the canvas is drawing, while a pipeline is showing.
    public private(set) var stage: PipelineStage?
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

    @ObservationIgnored private var focuses = 0
    @ObservationIgnored private var opening: Set<String> = []

    public init(continuum: Continuum, language: LanguageService? = nil) {
        self.continuum = continuum
        self.language = language
    }

    func showing(_ stage: PipelineStage) {
        self.stage = stage
    }

    func hidden(_ stage: PipelineStage) {
        if self.stage === stage { self.stage = nil }
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

    /// Closes every text, for quitting.
    public func closeAllText() {
        for document in documents.values { document.close() }
        documents.removeAll()
    }
}
