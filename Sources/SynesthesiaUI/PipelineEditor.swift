import CodeEditing
import ContinuumKit
import Foundation
import LanguageClient
import MeepClient
import Observation
import Stage

/// Turns gestures on the canvas into edits of the pipeline's text (design, section 5): Meep2's own edits through
/// `meep lsp`, and the moves the canvas writes itself (Q2). Each gesture is one step in the text's undo history. The
/// text opens beside the canvas for the first edit, so every change shows in both.
@MainActor @Observable
public final class PipelineEditor: StageEditing {
    public let pipeline: MeepPipeline
    public let host: MeepHost?
    public let stage: PipelineStage
    let workspace: Workspace

    /// Something to tell the person about the last gesture, such as why an edit couldn't be made.
    public private(set) var notice: Notice?
    /// A verb dropped or chosen that needs values before it can be written.
    public var pendingModule: PendingModule?

    public struct Notice: Equatable, Sendable {
        public let id: Int
        public let text: String
        public let isProblem: Bool
    }

    /// Where a module asked for will go, once its values are given.
    public enum Placement: Equatable, Sendable {
        /// As a new branch under a module.
        case under(String)
        /// Between a module and the module a wire takes its messages to.
        case onWire(String)
        /// On a line of its own at the end of the file, as a source.
        case atEnd
    }

    /// A verb to write a module for, with where it goes.
    public struct PendingModule: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let verb: VerbEntry
        public let placement: Placement
    }

    @ObservationIgnored private var notices = 0
    @ObservationIgnored private var clearing: Task<Void, Never>?

    public init(pipeline: MeepPipeline, host: MeepHost?, stage: PipelineStage, workspace: Workspace) {
        self.pipeline = pipeline
        self.host = host
        self.stage = stage
        self.workspace = workspace
    }

    /// The pipeline's text, if it's open.
    public var document: MeeplangDocument? { workspace.document(for: pipeline) }

    public var undoManager: UndoManager? { document?.undoManager }

    /// Whether the canvas can edit: the text is on this Mac, or not open yet.
    public var canEdit: Bool { !(document?.isReadOnly ?? false) && workspace.language != nil }

    // MARK: Gestures

    public func delete(_ keys: Set<String>, branch: Bool) {
        guard !keys.isEmpty else { return }
        // Taking a branch out takes what's under it, so a module under another being taken out isn't named again.
        let graph = document?.answer?.graph ?? pipeline.graph
        var named = keys
        if branch, let graph {
            named.subtract(keys.flatMap { BranchMove.descendants(of: $0, in: graph) })
        }
        let ordered = stage.tileKeys.filter(named.contains)
        let edits = ordered.map { branch ? MeepEdit.removeBranch($0) : MeepEdit.remove($0) }
        let label = ordered.count == 1 ? (stage.module(ordered[0])?.label ?? ordered[0]) : "\(ordered.count) Modules"
        perform(branch ? "Delete \(label) and Everything Under It" : "Delete \(label)") { document in
            try await document.apply(edits, named: branch ? "Delete \(label) and Everything Under It" : "Delete \(label)")
            self.stage.select([], reveal: false)
        }
    }

    public func move(_ key: String, under target: String) {
        let name = stage.module(key)?.label ?? key
        let onto = stage.module(target)?.label ?? target
        perform("Move \(name)") { document in
            guard let graph = document.answer?.graph else { throw DocumentError("The text's graph isn't here yet.") }
            let text = try BranchMove.moving(key, under: target, in: document.text, graph: graph, file: document.path)
            document.change(to: text, named: "Move \(name) under \(onto)")
        }
    }

    /// Changes a parameter, or with a nil name, the value written after the verb. An empty value takes it out.
    public func set(_ key: String, parameter: String?, to value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let label = parameter ?? "the value"
        let edit = trimmed.isEmpty ? MeepEdit.unset(key, parameter) : MeepEdit.set(key, parameter, to: trimmed)
        perform("Set \(label)") { document in try await document.apply([edit], named: trimmed.isEmpty ? "Remove \(label)" : "Set \(label)") }
    }

    public func rename(_ key: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        perform("Rename") { document in
            try await document.apply([.rename(key, to: trimmed.isEmpty ? nil : trimmed)], named: trimmed.isEmpty ? "Remove the Name" : "Name It \(trimmed)")
        }
    }

    public func setModifier(_ key: String, _ name: String, to value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespaces)
        perform("Set @\(name)") { document in
            try await document.apply([.setModifier(key, name, to: trimmed?.isEmpty == false ? trimmed : nil)], named: "Set @\(name)")
        }
    }

    public func removeModifier(_ key: String, _ name: String) {
        perform("Remove @\(name)") { document in try await document.apply([.removeModifier(key, name)], named: "Remove @\(name)") }
    }

    /// Asks for a verb's module where it was dropped or chosen: at once if it needs no values, or after the person
    /// gives them.
    public func request(_ verb: VerbEntry, at placement: Placement) {
        if verb.parameters.contains(where: \.required) {
            pendingModule = PendingModule(verb: verb, placement: placement)
        } else {
            write(NewModule.line(for: verb, values: [:], name: nil), at: placement, verb: verb)
        }
    }

    /// Writes a module's line where it goes, then selects it.
    public func write(_ line: String, at placement: Placement, verb: VerbEntry) {
        pendingModule = nil
        let action = "Add \(verb.verb)"
        perform(action) { document in
            let added: [String]
            switch placement {
            case .under(let key):
                added = try await document.apply([.add(line, under: key)], named: action)
            case .onWire(let link):
                added = try await self.insert(line, onWire: link, in: document, named: action)
            case .atEnd:
                let text = document.text
                document.change(to: text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + line + "\n", named: action)
                added = []
            }
            await self.select(added, orLineOf: placement == .atEnd ? document.lines.lineCount - 2 : nil, in: document)
        }
    }

    /// Puts a module on a wire. When the wire's source has only this one branch, that's Meep2's `insert`. When it has
    /// others, the module is added as a new branch and the wire's target moved under it, written as one change.
    private func insert(_ line: String, onWire key: String, in document: MeeplangDocument, named action: String) async throws -> [String] {
        guard let graph = document.answer?.graph, let link = graph.links.first(where: { $0.key == key }),
              let target = graph.modules.first(where: { $0.key == link.to }) else {
            throw DocumentError("The wire has gone. Try again.")
        }
        guard target.under == link.from else {
            throw DocumentError("This wire joins streams (a + line or @errors), so a module can't go on it here. Drop it onto a tile to add a branch.")
        }
        let branches = graph.modules.filter { $0.under == link.from }
        if branches.count == 1 {
            return try await document.apply([.insert(line, after: link.from)], named: action)
        }
        let proposal = try await document.propose([.add(line, under: link.from)], summary: action)
        document.rejectProposal()
        guard let previewGraph = proposal.graph, let added = proposal.added.first else {
            throw DocumentError("meep lsp didn't say where the new module would be.")
        }
        let text = try BranchMove.moving(target.key, under: added, in: proposal.text, graph: previewGraph, file: document.path)
        document.change(to: text, named: action)
        return []
    }

    // MARK: Undo

    public func undo() {
        guard let undoManager, undoManager.canUndo else { return }
        undoManager.undo()
    }

    public func redo() {
        guard let undoManager, undoManager.canRedo else { return }
        undoManager.redo()
    }

    // MARK: Doing it

    /// Opens the text, waits until its keys are the daemon's, then makes the change, saying why if it can't be made.
    private func perform(_ action: String, _ body: @escaping @MainActor (MeeplangDocument) async throws -> Void) {
        workspace.showsText = true
        Task { @MainActor in
            await workspace.openText(for: pipeline, host: host)
            guard let document = workspace.document(for: pipeline) else {
                say(workspace.textProblems[pipeline.id] ?? "The text couldn't be opened, so it can't be edited.", problem: true)
                return
            }
            guard !document.isReadOnly else {
                say("\(pipeline.name) is on \(host?.title ?? "another host"), whose text can't be edited here yet.", problem: true)
                return
            }
            guard await document.ready() else {
                say(document.answer?.current == false
                    ? "The text doesn't load, so it can't be edited from the canvas until it's mended."
                    : "The language server hasn't answered, so it can't be edited yet.", problem: true)
                return
            }
            do {
                try await body(document)
            } catch {
                say(error.localizedDescription, problem: true)
            }
        }
    }

    /// Selects modules once they're on the canvas: by key, or the module written on a line, from 0.
    private func select(_ keys: [String], orLineOf line: Int?, in document: MeeplangDocument) async {
        for _ in 0..<100 {
            if !keys.isEmpty, keys.allSatisfy({ stage.module($0) != nil }) {
                stage.select(Set(keys))
                return
            }
            if keys.isEmpty, let line, let key = document.module(atLine: line), stage.module(key) != nil {
                stage.select([key])
                return
            }
            if keys.isEmpty, line == nil { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func say(_ text: String, problem: Bool) {
        notices += 1
        notice = Notice(id: notices, text: text, isProblem: problem)
        clearing?.cancel()
        let id = notices
        clearing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.notice?.id == id else { return }
            self.notice = nil
        }
    }

    public func dismissNotice() {
        notice = nil
    }
}

/// A new module's line, from its verb and the values given for its parameters.
public enum NewModule {
    /// The line to write: the verb (with its inflection when it has several), the value after the verb, named values,
    /// and its name. Text values are quoted if they aren't already.
    public static func line(for verb: VerbEntry, values: [String: String], name: String?) -> String {
        var parts = [verb.kind == "inflection" && verb.inflection != verb.verb ? "\(verb.verb).\(verb.inflection)" : verb.verb]
        for parameter in verb.parameters {
            guard let raw = values[parameter.name]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { continue }
            let value = quoted(raw, as: parameter.type)
            parts.append(parameter.positional ? value : "\(parameter.name)=\(value)")
        }
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { parts.append("as \(name)") }
        return parts.joined(separator: " ")
    }

    /// Text is written in quotes in Meeplang; a value typed without them gets them.
    public static func quoted(_ value: String, as type: String) -> String {
        guard type == "text" || type == "path", !value.hasPrefix("\"") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
