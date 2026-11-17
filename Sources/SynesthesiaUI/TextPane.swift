import CodeEditing
import ContinuumKit
import LanguageClient
import MeepClient
import Stage
import SwiftUI

/// Makes the view that shows and edits a pipeline's Meeplang. Each platform supplies its own (on the Mac a TextKit 2
/// text view) through the environment, as it does the canvas (design, section 9: `CodeTextSurface`).
public struct CodeTextSurfaceProvider {
    public let make: @MainActor (MeeplangDocument, PipelineStage, Workspace) -> AnyView

    public init(make: @escaping @MainActor (MeeplangDocument, PipelineStage, Workspace) -> AnyView) {
        self.make = make
    }
}

extension FocusedValues {
    /// The text showing in the focused window, for the File menu's Save and Revert.
    @Entry public var meeplangDocument: MeeplangDocument?
}

/// A pipeline's Meeplang beside its canvas (design, section 2, levels 1 and 2): edited with colours and problems
/// from `meep lsp`, with the canvas following it as it's typed and each module's counts in the gutter.
struct TextPane: View {
    let pipeline: MeepPipeline
    let host: MeepHost?
    let stage: PipelineStage
    @Environment(\.workspace) private var workspace
    @Environment(\.codeTextSurface) private var surface
    @State private var appliedRenaming = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let workspace, let document = workspace.document(for: pipeline) {
                TextHeader(document: document, service: workspace.language)
                Divider()
                if let surface {
                    surface.make(document, stage, workspace)
                } else {
                    ContentUnavailableView("No text view here", systemImage: "doc.text", description: Text("This platform can't show text yet."))
                }
                if !document.diagnostics.isEmpty {
                    Divider()
                    ProblemList(document: document, pipeline: pipeline)
                }
            } else if let problem = workspace?.textProblems[pipeline.id] {
                ContentUnavailableView("Can't show the text", systemImage: "doc.text", description: Text(problem))
            } else if workspace?.language == nil {
                ContentUnavailableView("No language server", systemImage: "doc.text", description: Text("This platform can't start meep lsp."))
            } else {
                ProgressView("Opening \(pipeline.name)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(white: 0.075))
        .task(id: pipeline.id) { await workspace?.openText(for: pipeline, host: host) }
        .onChange(of: linkState, initial: true) { _, state in follow(state) }
        .onDisappear {
            stage.show(text: nil)
            workspace?.closeText(for: pipeline)
        }
        .focusedSceneValue(\.meeplangDocument, workspace?.document(for: pipeline))
    }

    /// What the canvas takes from the text: its graph, and keys renamed.
    private struct LinkState: Equatable {
        var answer: GraphAnswer?
        var renaming: MeeplangDocument.Renaming?
        var path: String?
    }

    private var linkState: LinkState {
        let document = workspace?.document(for: pipeline)
        return LinkState(answer: document?.answer, renaming: document?.renaming, path: document?.path)
    }

    /// Draws the text's graph on the canvas, moving renamed tiles first.
    private func follow(_ state: LinkState) {
        var renamed: [String: String]?
        if let renaming = state.renaming, renaming.id != appliedRenaming {
            appliedRenaming = renaming.id
            renamed = renaming.keys
        }
        guard let answer = state.answer, let graph = answer.graph, let path = state.path else {
            stage.show(text: nil, renamed: renamed)
            return
        }
        let changed = answer.changed.map { range in
            (range.start.line + 1)...max(range.start.line + 1, range.end.character == 0 ? range.end.line : range.end.line + 1)
        }
        stage.show(text: TextGraph(graph: graph, current: answer.current, changedLines: changed, file: path), renamed: renamed)
    }
}

/// The file, whether it's saved and whether the daemon runs what's saved, and the buttons for saving.
struct TextHeader: View {
    let document: MeeplangDocument
    let service: LanguageService?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text((document.path as NSString).lastPathComponent)
                    .fontWeight(.semibold)
                    .help(document.path)
                if document.isEdited { Text("Edited").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                if document.isEdited || document.status == .changedElsewhere {
                    Button("Revert") { document.revert() }
                        .help(document.status == .changedElsewhere ? "Take the file as it is on disk, losing the changes here." : "Put back the saved text.")
                }
                if !document.isReadOnly {
                    Button("Save") { save() }
                        .disabled(!document.isEdited && document.status != .changedElsewhere)
                        .help(saveHelp)
                }
            }
            .buttonStyle(.borderless)
            if let status = statusLine {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: status.symbol).foregroundStyle(status.color)
                    Text(status.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if status.offersReload {
                        Button("Reload") { Task { await document.reloadPipeline() } }
                            .buttonStyle(.link)
                            .help("Ask the daemon to load the saved file now.")
                    }
                }
                .font(.caption)
            }
            if case .unavailable(let reason)? = service?.state {
                Label("No colours, problems or live graph: \(reason)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = document.baseProblem {
                Label(problem, systemImage: "key").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var saveHelp: String {
        document.pipeline?.state.isLive == true
            ? "Save (⌘S). A daemon watching the file reloads it, keeping each module's state."
            : "Save (⌘S)."
    }

    private func save() {
        do { try document.save() } catch { saveError = error.localizedDescription }
    }

    @State private var saveError: String?

    private struct StatusLine {
        var text: String
        var symbol: String
        var color: Color
        var offersReload = false
    }

    private var statusLine: StatusLine? {
        if let saveError { return StatusLine(text: "Couldn't save: \(saveError)", symbol: "xmark.octagon", color: .red) }
        if document.isReadOnly {
            return StatusLine(text: "From \(document.host?.title ?? "the daemon"), as it runs. Text from other hosts can't be edited yet.", symbol: "lock", color: .secondary)
        }
        switch document.status {
        case .saved, .edited:
            return nil
        case .reloading:
            return StatusLine(text: "Saved. Waiting for the daemon to load it…", symbol: "arrow.triangle.2.circlepath", color: .secondary)
        case .reloaded:
            return StatusLine(text: "Saved and running: the daemon has loaded it.", symbol: "checkmark.circle", color: .green)
        case .notWatched:
            return StatusLine(text: "Saved, but the daemon isn't watching this file, so it runs as it was.", symbol: "pause.circle", color: .orange, offersReload: true)
        case .savedBroken:
            return StatusLine(text: "Saved, but it doesn't load, so the pipeline runs as it was.", symbol: "exclamationmark.triangle", color: .orange)
        case .reloadFailed(let reason):
            return StatusLine(text: "The daemon couldn't load it: \(reason)", symbol: "xmark.octagon", color: .red, offersReload: true)
        case .changedElsewhere:
            return StatusLine(text: "The file changed on disk. Revert to take it, or save to replace it.", symbol: "exclamationmark.triangle", color: .orange)
        }
    }
}

/// The problems in the text, each taking the text to its line when clicked.
struct ProblemList: View {
    let document: MeeplangDocument
    let pipeline: MeepPipeline
    @Environment(\.workspace) private var workspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(zip(document.diagnostics.indices, document.problemLines)), id: \.0) { index, line in
                    let diagnostic = document.diagnostics[index]
                    Button {
                        workspace?.showText(of: pipeline, atLine: diagnostic.range.start.line)
                    } label: {
                        Label {
                            Text(line).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: diagnostic.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(diagnostic.isError ? .red : .orange)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Go to the line")
                }
            }
            .font(.caption)
            .padding(8)
        }
        .frame(maxHeight: 96)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The edge between the canvas and the text: drag it to resize the text, double-click it for the usual width.
struct PaneEdge: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let usual: Double
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            #if os(macOS)
            .pointerStyle(.frameResize(position: .leading))
            #endif
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let from = start ?? width
                        start = from
                        width = min(max(from - drag.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in start = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { width = usual })
            .help("Drag to resize the text; double-click for the usual width")
    }
}
