import CodeEditing
import ContinuumKit
import FlowKit
import Foundation
import LanguageClient
import SwiftUI

/// Makes the view that shows an inflection's C#, read-only, with each class's handling times in its gutter. Each
/// platform supplies its own (on the Mac a TextKit 2 text view), as it does the Meeplang's.
public struct SourceTextSurfaceProvider {
    public let make: @MainActor (CodeLevel, InflectionCode, Workspace) -> AnyView

    public init(make: @escaping @MainActor (CodeLevel, InflectionCode, Workspace) -> AnyView) {
        self.make = make
    }
}

/// An editor that can open a file at a line, such as Rider or VS Code.
public struct ExternalEditor: Identifiable, Hashable, Sendable {
    /// Its bundle identifier.
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The editors installed, and opening a file in one at a line, or a page in the browser, as the platform does them.
public struct CodeEditors {
    public let installed: @MainActor () -> [ExternalEditor]
    /// Opens `path` at `line` (from 1) in the editor; returns why it couldn't, if it couldn't.
    public let open: @MainActor (_ path: String, _ line: Int?, _ editor: ExternalEditor) -> String?
    public let browse: @MainActor (URL) -> Void

    public init(
        installed: @escaping @MainActor () -> [ExternalEditor], open: @escaping @MainActor (String, Int?, ExternalEditor) -> String?,
        browse: @escaping @MainActor (URL) -> Void
    ) {
        self.installed = installed
        self.open = open
        self.browse = browse
    }

    /// Where the editor chosen is kept, by its bundle identifier.
    public static let choiceKey = "codeEditor"

    /// The editor chosen, if it's installed, or else the first that is.
    @MainActor
    public func chosen(_ saved: String) -> ExternalEditor? {
        let editors = installed()
        return editors.first { $0.id == saved } ?? editors.first
    }
}

extension EnvironmentValues {
    @Entry public var sourceTextSurface: SourceTextSurfaceProvider?
    @Entry public var codeEditors: CodeEditors?
}

/// Level 1 in the pane beside the canvas (design, section 2): the C# of the inflections behind a module's verb, the
/// one it resolves to first, read-only, with their handling times in the gutter. It asks for those times only while
/// it shows.
struct CodePane: View {
    let code: CodeLevel
    @Environment(\.sourceTextSurface) private var surface
    @Environment(\.workspace) private var workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CodeHeader(code: code)
            Divider()
            content
        }
        // Times are asked for while the code shows, and no longer.
        .onAppear { code.startAskingForTimes() }
        .onDisappear { code.stopAskingForTimes() }
    }

    @ViewBuilder private var content: some View {
        switch code.state {
        case .loading:
            Waiting(text: "Reading Meep's verb catalogue…")
        case .failed(let problem):
            NoCode(problem: problem, retry: nil)
        case .ready:
            if let shown = code.shownCode {
                switch shown.outcome {
                case nil:
                    Waiting(text: "Reading \(shown.fileName ?? shown.name)…")
                case .unavailable(let problem)?:
                    NoCode(problem: problem, retry: problem.canRetry ? { Task { await code.retry(shown) } } : nil)
                case .loaded?:
                    if let surface, let workspace {
                        surface.make(code, shown, workspace).id(shown.name)
                    } else {
                        NoCode(problem: nil, retry: nil)
                    }
                }
            }
        }
    }
}

/// Something being read, at the top left of the pane.
private struct Waiting: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Why there's no C# to show, aligned left, with Try Again when trying again could help.
private struct NoCode: View {
    let problem: SourceProblem?
    let retry: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("No C# to show", systemImage: "curlybraces").font(.headline)
                Text(problem?.message ?? "This platform can't show C# yet.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let retry {
                    Button("Try Again", action: retry)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Back to the Meeplang; the inflection, its file and where it came from; the others to choose from; its handling
/// times; and opening it in an editor.
struct CodeHeader: View {
    let code: CodeLevel
    @Environment(\.workspace) private var workspace
    @Environment(\.codeEditors) private var editors
    @AppStorage(CodeEditors.choiceKey) private var savedEditor = ""
    @State private var openProblem: String?

    var body: some View {
        let shown = code.shownCode
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { workspace?.closeCode() } label: {
                    Label("Meeplang", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back to the pipeline's Meeplang (⎋ in the code)")
                Spacer(minLength: 4)
                if let shown { openButton(shown) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "curlybraces").foregroundStyle(.secondary)
                Text(shown?.name ?? code.subject.verb).fontWeight(.semibold)
                if code.subject.key != nil {
                    Text(shown?.runsHere == false ? "not what \(code.subject.label) runs" : "what \(code.subject.label) runs")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(shown?.runsHere == false
                              ? "\(code.subject.label) resolves to \(code.subject.resolved.joined(separator: " or ")): this is another inflection of \(code.subject.verb)."
                              : "\(code.subject.label)'s parameters resolve it to this inflection.")
                }
            }
            if code.inflections.count > 1 { InflectionChips(code: code) }
            if let shown { origin(shown) }
            // Outside a scroll view, so held to a few lines, whole on hover: text held to its full height here would make
            // the window's content taller than the window at the widths SwiftUI tries (step 9).
            if let note = code.note {
                Label(note, systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange).lineLimit(3).help(note)
            }
            if let shown, shown.outcome?.file != nil { TimesLine(code: code, shown: shown) }
            if let openProblem {
                Label(openProblem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .lineLimit(2).help(openProblem)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .onChange(of: shown?.name) { _, _ in openProblem = nil }
    }

    /// The file and where it came from; clicking the line brings the class back into view.
    @ViewBuilder private func origin(_ shown: InflectionCode) -> some View {
        if let text = shown.originText {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(text).lineLimit(1).truncationMode(.head)
                    .help(shown.localPath ?? shown.entry.source?.url ?? text)
                    .textSelection(.enabled)
                if let line = shown.declarationLine {
                    Text("·")
                    Button("line \(line)") { code.revealDeclaration() }
                        .buttonStyle(.link)
                        .help("Show where \(CSharpText.shortName(shown.entry.class ?? shown.entry.inflection)) is declared")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Open in the chosen editor, with the others in its menu; a page in the browser when the file isn't on this Mac.
    @ViewBuilder private func openButton(_ shown: InflectionCode) -> some View {
        let page = shown.entry.source?.url.flatMap { SourceLinkPage.page(for: $0, line: shown.declarationLine) }
        if let path = shown.localPath, let editors, let chosen = editors.chosen(savedEditor) {
            Menu {
                ForEach(editors.installed()) { editor in
                    Button("Open in \(editor.name)") { open(path, shown.declarationLine, in: editor) }
                }
                if let page {
                    Divider()
                    Button("Open on \(SourceLinkPage.site(of: shown.entry.source?.url ?? ""))") { editors.browse(page) }
                }
            } label: {
                Label("Open in \(chosen.name)", systemImage: "arrow.up.forward.app")
            } primaryAction: {
                open(path, shown.declarationLine, in: chosen)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Open \((path as NSString).lastPathComponent) at line \(shown.declarationLine ?? 1) in \(chosen.name). The menu has the other editors; the one chosen is remembered, and is in Settings.")
        } else if let page, let editors {
            Button { editors.browse(page) } label: {
                Label("Open on \(SourceLinkPage.site(of: shown.entry.source?.url ?? ""))", systemImage: "safari")
            }
            .buttonStyle(.borderless)
            .help("The file isn't on this Mac: open its page, at the commit Meep was built from, in your browser.")
        }
    }

    private func open(_ path: String, _ line: Int?, in editor: ExternalEditor) {
        savedEditor = editor.id
        openProblem = editors?.open(path, line, editor)
    }
}

/// The verb's inflections, the module's first and marked, to choose which shows.
private struct InflectionChips: View {
    let code: CodeLevel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(code.inflections) { inflection in
                    let selected = inflection.name == code.shownCode?.name
                    Button { code.show(inflection.name) } label: {
                        HStack(spacing: 4) {
                            if inflection.runsHere {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                            }
                            Text(inflection.entry.inflection)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(selected ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.07)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(help(for: inflection))
                }
            }
        }
    }

    private func help(for inflection: InflectionCode) -> String {
        var text = inflection.name
        if inflection.runsHere, code.subject.key != nil { text += ": what \(code.subject.label) runs" }
        if let description = inflection.entry.description { text += ". " + description }
        return text
    }
}

/// The shown inflection's handling times, merged over every module that runs it, with the whole figures on hover.
private struct TimesLine: View {
    let code: CodeLevel
    let shown: InflectionCode

    var body: some View {
        let times = code.times(of: shown)
        let merged = times.merged
        HStack(spacing: 6) {
            Image(systemName: "stopwatch").foregroundStyle(.secondary)
            if times.uses.isEmpty {
                Text("No module in the Continuum runs it.")
            } else if merged.isEmpty {
                Text("\(times.uses.count) module\(times.uses.count == 1 ? "" : "s") run\(times.uses.count == 1 ? "s" : "") it; no handling times yet")
            } else {
                Text("p50 \(merged.quantile(0.5).map(TimeText.duration) ?? "—")").monospacedDigit()
                Text("p99 \(merged.quantile(0.99).map(TimeText.duration) ?? "—")").monospacedDigit()
                Text("· \(merged.count.formatted()) handled by \(times.timed.count) module\(times.timed.count == 1 ? "" : "s")")
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(times.summary(named: shown.name))
    }
}
