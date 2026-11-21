import ContinuumKit
import Foundation
import Stage

/// What the sidebar tells Claude once, and what it sends with each question (design, section 8).
@MainActor
public enum SidebarPrompt {
    /// The system prompt: the MCP server's instructions, then how the sidebar differs. It's the same for every request,
    /// so it's cached with the tools; what changes goes in the questions.
    public static let system = ContinuumTools.instructions + "\n\n" + """
        You're in the sidebar of Synesthesia, beside the canvas the person is looking at. Each of their questions \
        starts with a note from the app, in square brackets, saying what the canvas is on and what's selected, as \
        addresses. Words such as "this", "here" and "it" mean those unless the question says otherwise. The note is \
        the app's, not the person's.

        Look before you answer: counts and rates change, so use the tools rather than guessing. Use show when \
        pointing at something helps the person see what you mean.

        Call things what the person sees them called. A module is its label on the canvas, such as Seconds or \
        WriteLine #2, never its key (m1, m2) or number, which the person doesn't see; a link between modules is named \
        by its ends, such as Seconds → WriteLine #2; hosts and pipelines go by their titles and names. To point at \
        one, make its name a Markdown link to its address, such as [Seconds](meep://local/slow/m1): the sidebar shows \
        the place when it's clicked. Don't write the address out as well.

        propose_edits and inject_message go beyond looking. The app asks the person before either runs, and then they \
        decide in the app: nothing changes until they accept a proposal or send a message. Use them only when the \
        person asks for a change or a message. sample_tap returns real message contents, which are sent to Anthropic's \
        API; the app asks the person first, so use it only when the contents matter.

        The sidebar is narrow. Answer in short paragraphs or short lists, aligned left, and put Meeplang in code \
        blocks. Avoid tables. If a tool fails, say so plainly and what would fix it.
        """

    /// The app's note on what the person is looking at and has selected, sent with each question so "why is this queue
    /// growing?" needs no explaining.
    public static func context(_ viewer: Viewer) -> String {
        var lines: [String] = []
        let continuum = viewer.continuum
        if let canvas = viewer.canvas {
            switch canvas.level {
            case .boundary:
                lines.append("The canvas is drawn back to the boundary: every host a node, and the endpoints outside Meep round them.")
            case .mesh:
                lines.append("The canvas shows the mesh of hosts.")
            case .host:
                let host = canvas.focus.flatMap { continuum.host($0.host) }
                lines.append("The canvas is on a host: \(canvas.focus.map { MeepAddress(host: $0.host).description } ?? "none")\(host.map { " (\($0.title))" } ?? "").")
            case .pipeline:
                lines.append("The canvas is on a pipeline: \(canvas.focus?.description ?? "none").")
            }
        }
        if let selection = viewer.selection {
            lines.append("Selected in the list of hosts: \(selection).")
        } else {
            lines.append("Nothing is selected in the list of hosts.")
        }
        if let stage = viewer.stage, !stage.selection.isEmpty {
            let pipeline = stage.pipeline
            let modules = stage.selection.sorted { (pipeline.module($0)?.number ?? 0) < (pipeline.module($1)?.number ?? 0) }.map { key in
                let label = pipeline.module(key)?.label.nilIfEmpty
                return pipeline.address.module(key).description + (label.map { " (\($0))" } ?? "")
            }
            lines.append("Selected on the canvas: \(modules.joined(separator: ", ")).")
        }
        if viewer.showsText, let stage = viewer.stage {
            let edited = viewer.document(for: stage.pipeline)?.isEdited == true
            lines.append("Its Meeplang is open beside the canvas\(edited ? ", with changes not saved" : "").")
        }
        return "[" + lines.joined(separator: " ") + "]"
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
