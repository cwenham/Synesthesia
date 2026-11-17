import CodeEditing
import ContinuumKit
import LanguageClient
import MeepClient
import Stage
import SwiftUI

extension EnvironmentValues {
    /// The editing of the pipeline showing, for the canvas, the text pane and the inspector.
    @Entry public var pipelineEditor: PipelineEditor?
}

/// What a dragged verb carries: `meep-verb:` and the verb, with its inflection when it has several.
enum VerbDrag {
    static let prefix = "meep-verb:"

    static func payload(for verb: VerbEntry) -> String {
        prefix + "\(verb.verb).\(verb.inflection)"
    }

    static func verb(in payload: String, from verbs: [VerbEntry]) -> VerbEntry? {
        guard payload.hasPrefix(prefix) else { return nil }
        let parts = payload.dropFirst(prefix.count).split(separator: ".", maxSplits: 1).map(String.init)
        return verbs.first { $0.verb == parts.first && (parts.count == 1 || $0.inflection == parts[1]) }
    }
}

// MARK: The inspector

/// The selected module's name, parameters and modifiers, from the verb catalogue, each changed with Meep2's own edit
/// (design, section 5: the inspector does `set`). Shown above the text.
struct ModuleInspector: View {
    let key: String
    let module: GraphModule
    let document: MeeplangDocument
    let editor: PipelineEditor
    @AppStorage("inspectorShowsDetail") private var expanded = true

    /// The modifiers Meeplang has, and whether each takes a value.
    static let modifiers: [(name: String, takesValue: Bool, help: String)] = [
        ("buffer", true, "How many messages may wait for it, such as @buffer=100."),
        ("expires", true, "How long a message may wait before it's dropped, such as @expires=5s."),
        ("on-error", true, "What to do when it fails a message."),
        ("errors", false, "Takes only errors from the module above it."),
        ("no-errors", false, "Takes no errors from the module above it."),
        ("bypass", false, "Passes messages on without handling them."),
        ("accept-expired", false, "Takes messages that have expired."),
    ]

    private var entry: VerbEntry? {
        document.verbs.first { $0.verb == module.verb && module.inflections.contains($0.inflection) }
            ?? document.verbs.first { $0.verb == module.verb }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 10)
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide the module's parameters" : "Show the module's parameters")
                Text(module.module).fontWeight(.semibold)
                Text(entry.map { $0.inflection == $0.verb ? $0.verb : "\($0.verb).\($0.inflection)" } ?? module.verb)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Delete", role: .destructive) { editor.delete([key], branch: false) }
                    Button("Delete with Everything Under It", role: .destructive) { editor.delete([key], branch: true) }
                } label: {
                    Image(systemName: "trash")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Delete this module (⌫), or with everything under it (⌥⌫)")
            }
            if expanded {
                if let description = entry?.description {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(description)
                }
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    GridRow {
                        Text("name").foregroundStyle(.secondary).help("Its name, given with as, which edits and other modules can use.")
                        InspectorField(current: module.name ?? "", placeholder: module.module, help: "Its name, with as") {
                            editor.rename(key, to: $0)
                        }
                    }
                    ForEach(parameters, id: \.name) { parameter in
                        GridRow {
                            Text(parameter.label)
                                .foregroundStyle(parameter.required ? .primary : .secondary)
                                .lineLimit(1)
                                .help(parameter.help)
                            InspectorField(current: parameter.current, placeholder: parameter.placeholder, help: parameter.help) {
                                editor.set(key, parameter: parameter.positional ? nil : parameter.name, to: $0)
                            }
                        }
                    }
                }
                modifierRow
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .task(id: document.uri) { await document.loadVerbs() }
    }

    private struct Parameter {
        var name: String
        var label: String
        var positional: Bool
        var required: Bool
        var current: String
        var placeholder: String
        var help: String
    }

    /// The verb's parameters with the values written now, the one after the verb first; any written that the
    /// catalogue doesn't know are listed too, so nothing written is hidden.
    private var parameters: [Parameter] {
        let written = module.parameters
        var list: [Parameter] = []
        for parameter in entry?.parameters ?? [] {
            let value = written.first { parameter.positional ? $0.name == nil : $0.name == parameter.name }?.text ?? ""
            var help = parameter.name + ": " + parameter.type
            if parameter.perMessage { help += ", worked out for each message" }
            if parameter.required { help += ", required" }
            if let description = parameter.description { help += ". " + description }
            list.append(Parameter(
                name: parameter.name, label: parameter.name, positional: parameter.positional, required: parameter.required,
                current: value, placeholder: parameter.default ?? parameter.type, help: help
            ))
        }
        for extra in written where !list.contains(where: { extra.name == nil ? $0.positional : $0.name == extra.name }) {
            list.append(Parameter(
                name: extra.name ?? "value", label: extra.name ?? "value", positional: extra.name == nil, required: false,
                current: extra.text, placeholder: "", help: extra.name ?? "The value written after the verb"
            ))
        }
        return list
    }

    private var modifierRow: some View {
        HStack(spacing: 6) {
            ForEach(module.modifiers, id: \.name) { modifier in
                HStack(spacing: 2) {
                    Text("@" + modifier.name + (modifier.value.map { "=" + $0 } ?? "")).font(.caption.monospaced())
                    Button { editor.removeModifier(key, modifier.name) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove @\(modifier.name)")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            }
            Menu("Add @…") {
                ForEach(Self.modifiers.filter { name in !module.modifiers.contains { $0.name == name.name } }, id: \.name) { modifier in
                    Button("@\(modifier.name)") {
                        editor.setModifier(key, modifier.name, to: modifier.takesValue ? defaultValue(of: modifier.name) : nil)
                    }
                    .help(modifier.help)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
        }
    }

    private func defaultValue(of modifier: String) -> String? {
        switch modifier {
        case "buffer": "100"
        case "expires": "1m"
        case "on-error": "drop"
        default: nil
        }
    }
}

/// A field that edits when it's committed with Return or left, and follows the text when it isn't being typed in.
struct InspectorField: View {
    let current: String
    let placeholder: String
    let help: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospaced())
            .frame(minWidth: 90)
            .focused($focused)
            .help(help)
            .onAppear { text = current }
            .onChange(of: current) { _, value in if !focused { text = value } }
            .onSubmit { send() }
            .onChange(of: focused) { _, now in if !now { send() } }
    }

    private func send() {
        guard text != current else { return }
        commit(text)
    }
}

// MARK: The palette

/// Every verb the pipeline can use, to drag onto the canvas: onto a tile to add a branch under it, onto a wire to put
/// it between, or onto the background for a new source. Clicking one adds it under the selected tile.
struct VerbPalette: View {
    let verbs: [VerbEntry]
    let editor: PipelineEditor
    @State private var search = ""

    private static let roles = ["source", "inlet", "filter", "step", "router", "tap", "outlet"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Find a verb", text: $search).textFieldStyle(.roundedBorder)
            Text("Drag onto a tile, a wire or the background, or click to add under the selected tile.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(Self.roles, id: \.self) { role in
                    let matching = shown.filter { $0.role == role }
                    if !matching.isEmpty {
                        Section(role.capitalized + "s") {
                            ForEach(matching, id: \.self.id) { verb in row(verb) }
                        }
                    }
                }
                let others = shown.filter { !Self.roles.contains($0.role) }
                if !others.isEmpty {
                    Section("Others") { ForEach(others, id: \.self.id) { verb in row(verb) } }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if verbs.isEmpty { ProgressView("Asking meep lsp…") }
            }
        }
        .padding(10)
        .frame(width: 300, height: 420)
    }

    private var shown: [VerbEntry] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return verbs }
        return verbs.filter { "\($0.verb).\($0.inflection) \($0.description ?? "")".lowercased().contains(needle) }
    }

    private func row(_ verb: VerbEntry) -> some View {
        let name = verb.inflection == verb.verb ? verb.verb : "\(verb.verb).\(verb.inflection)"
        return Button { add(verb) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.monospaced())
                if let description = verb.description {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help([name, verb.description].compactMap { $0 }.joined(separator: ": "))
        .accessibilityLabel(name)
        .accessibilityHint("Adds it under the selected tile; or drag it onto the canvas")
        .draggable(VerbDrag.payload(for: verb))
    }

    private func add(_ verb: VerbEntry) {
        if editor.stage.selection.count == 1, let key = editor.stage.selection.first {
            editor.request(verb, at: .under(key))
        } else if verb.role == "source" || verb.role == "inlet" {
            editor.request(verb, at: .atEnd)
        } else {
            editor.say("Select a tile to add \(verb.verb) under, or drag it onto one.", problem: false)
        }
    }
}

extension VerbEntry {
    var id: String { "\(verb).\(inflection)" }
}

/// The values a new module needs before it's written: its required parameters, any others, and a name.
struct NewModuleForm: View {
    let pending: PipelineEditor.PendingModule
    let editor: PipelineEditor
    @State private var values: [String: String] = [:]
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let verb = pending.verb
        VStack(alignment: .leading, spacing: 10) {
            Text("New \(verb.inflection == verb.verb ? verb.verb : "\(verb.verb).\(verb.inflection)")").font(.headline)
            if let description = verb.description {
                Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(verb.parameters.sorted { $0.required && !$1.required }, id: \.name) { parameter in
                    GridRow {
                        Text(parameter.name + (parameter.required ? " *" : ""))
                            .foregroundStyle(parameter.required ? .primary : .secondary)
                            .help(parameter.description ?? parameter.type)
                        TextField(parameter.default ?? parameter.type, text: Binding(
                            get: { values[parameter.name] ?? "" }, set: { values[parameter.name] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .frame(minWidth: 180)
                        .help([parameter.type, parameter.description].compactMap { $0 }.joined(separator: ". "))
                    }
                }
                GridRow {
                    Text("name").foregroundStyle(.secondary)
                    TextField("none", text: $name).textFieldStyle(.roundedBorder).frame(minWidth: 180)
                }
            }
            Text("* Required. Text is quoted for you; anything else is written as Meeplang.")
                .font(.caption).foregroundStyle(.secondary)
            Text(NewModule.line(for: verb, values: values, name: name))
                .font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel") { editor.pendingModule = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    editor.write(NewModule.line(for: verb, values: values, name: name), at: pending.placement, verb: verb)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(verb.parameters.contains { $0.required && (values[$0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

// MARK: Proposals and notices

/// Edits proposed, such as by Claude, shown until the person accepts or rejects them: what they're for, each edit in
/// words, and the lines they change (design, section 8).
struct ProposalBanner: View {
    let proposal: MeeplangDocument.Proposal
    let document: MeeplangDocument
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Color(red: 0.73, green: 0.55, blue: 1))
                Text("Proposed: \(proposal.summary)").fontWeight(.semibold).lineLimit(2)
                Spacer(minLength: 4)
                Button("Reject") { document.rejectProposal() }
                Button("Accept") {
                    Task {
                        do { try await document.acceptProposal() } catch { problem = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help("Make these edits (⌘↩). They can be undone as one step.")
            }
            ForEach(Array(proposal.edits.enumerated()), id: \.offset) { _, edit in
                Text("• " + EditWords.describe(edit)).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(proposal.difference.enumerated()), id: \.offset) { _, line in
                        Text((line.kind == .added ? "+ " : line.kind == .removed ? "− " : "  ") + line.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(line.kind == .added ? .green : line.kind == .removed ? .red : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 120)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .padding(10)
        .background(Color(red: 0.73, green: 0.55, blue: 1).opacity(0.1))
    }
}

/// An edit in words, as Meep2 says them.
enum EditWords {
    static func describe(_ edit: MeepEdit) -> String {
        var module = edit.module ?? ""
        // +N names the module edit N of the same list adds.
        if module.hasPrefix("+"), let index = Int(module.dropFirst()) { module = "the module edit \(index + 1) adds" }
        switch edit.kind {
        case "set": return edit.name.map { "set \(module)'s \($0) to \(edit.value ?? "")" } ?? "set \(module)'s value to \(edit.value ?? "")"
        case "unset": return edit.name.map { "remove \(module)'s \($0)" } ?? "remove \(module)'s value"
        case "set-modifier": return "set @\(edit.name ?? "")\(edit.value.map { "=" + $0 } ?? "") on \(module)"
        case "remove-modifier": return "remove @\(edit.name ?? "") from \(module)"
        case "rename": return edit.value.map { "name \(module) \($0)" } ?? "take \(module)'s name away"
        case "add": return "add \(edit.value ?? "") under \(module)"
        case "insert": return "insert \(edit.value ?? "") after \(module)"
        case "remove": return "remove \(module)"
        case "remove-branch": return "remove \(module) and everything under it"
        default: return "\(edit.kind) \(edit.name ?? "") \(edit.value ?? "")"
        }
    }
}

/// Why the last gesture couldn't be done, or what to do instead, over the top of the canvas.
struct CanvasNotice: View {
    let notice: PipelineEditor.Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: notice.isProblem ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(notice.isProblem ? .orange : .secondary)
            Text(notice.text).fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Color(white: 0.09).opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.14)))
        .environment(\.colorScheme, .dark)
    }
}

/// Verbs dragged onto the canvas: onto a tile, a wire or the background, with what they'd land on lit as they move.
struct CanvasDropDelegate: DropDelegate {
    let stage: PipelineStage
    /// Nil until the canvas can edit, when nothing is taken.
    let editor: PipelineEditor?
    let verbs: () -> [VerbEntry]

    func validateDrop(info: DropInfo) -> Bool {
        (editor?.canEdit ?? false) && info.hasItemsConforming(to: [.plainText, .utf8PlainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        stage.dropTarget = stage.hit(at: info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        stage.dropTarget = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = stage.hit(at: info.location)
        stage.dropTarget = nil
        guard let editor, let provider = info.itemProviders(for: [.plainText, .utf8PlainText]).first else { return false }
        _ = provider.loadTransferable(type: String.self) { result in
            guard case .success(let payload) = result else { return }
            Task { @MainActor in
                guard let verb = VerbDrag.verb(in: payload, from: verbs()) else { return }
                switch target {
                case .tile(let key): editor.request(verb, at: .under(key))
                case .wire(let key): editor.request(verb, at: .onWire(key))
                case nil: editor.request(verb, at: .atEnd)
                }
            }
        }
        return true
    }
}
