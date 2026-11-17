import ContinuumKit
import MeepClient
import Stage
import SwiftUI

extension StageColor {
    var swiftUI: Color { Color(red: Double(x), green: Double(y), blue: Double(z)) }
}

/// The probes open on a pipeline, side by side, under the canvas (design, section 6): each a debug tap's messages,
/// newest first.
struct ProbeDock: View {
    let probes: [Probe]
    let stage: PipelineStage
    @Environment(\.workspace) private var workspace

    var body: some View {
        if probes.isEmpty {
            ContentUnavailableView {
                Label("No probes", systemImage: "scope")
            } description: {
                Text("Right-click a tile or a wire and choose Probe, to see the messages that go past.")
            }
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(probes) { probe in
                        ProbeColumn(probe: probe, stage: stage)
                            .frame(width: 340)
                        Divider()
                    }
                }
            }
        }
    }
}

/// One probe: what it's on, its condition and sample, what it couldn't show, and its messages.
struct ProbeColumn: View {
    @Bindable var probe: Probe
    let stage: PipelineStage
    @Environment(\.workspace) private var workspace
    @State private var condition = ""
    @State private var expanded: Set<String> = []
    @FocusState private var editingCondition: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(PipelineStage.color(ofProbe: probe.colorIndex).swiftUI).frame(width: 9, height: 9)
                Text(probe.title).fontWeight(.semibold).lineLimit(1).help(probe.title)
                Spacer()
                Button {
                    if probe.state == .paused { probe.start() } else { probe.pause() }
                } label: {
                    Image(systemName: probe.state == .paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderless)
                .help(probe.state == .paused ? "Start tapping again" : "Stop tapping for now, keeping what's here")
                Menu {
                    Toggle("Keep with the Pipeline", isOn: Binding(get: { probe.isSaved }, set: { keep in
                        probe.isSaved = keep
                        workspace?.saveProbes(for: probe.pipeline)
                    }))
                    Button("Clear") { probe.clear() }
                    Divider()
                    Button("Close Probe") { workspace?.closeProbe(probe) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Keep this probe with the pipeline's file, clear it, or close it")
            }
            HStack(spacing: 6) {
                TextField("Where… (msg.Count > 2)", text: $condition)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .focused($editingCondition)
                    .onSubmit { apply() }
                    .onChange(of: editingCondition) { _, now in if !now { apply() } }
                    .help("A Meeplang condition on msg, as Where takes. Return, or leaving the field, applies it; empty shows every message.")
                SampleMenu(sample: $probe.sample)
            }
            status
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(probe.messages) { message in
                            MessageRow(message: message, stage: stage, expanded: Binding(
                                get: { expanded.contains(message.id) },
                                set: { if $0 { expanded.insert(message.id) } else { expanded.remove(message.id) } }
                            ))
                            .id(message.id)
                        }
                    }
                }
                .onChange(of: stage.openedMessage) { _, opened in
                    guard let opened, opened.probe == probe.id, let id = opened.message else { return }
                    expanded.insert(id)
                    withAnimation { reader.scrollTo(id, anchor: .top) }
                }
            }
        }
        .padding(8)
        .onAppear { condition = probe.condition }
        .background(stage.openedMessage?.probe == probe.id ? Color.white.opacity(0.04) : .clear)
    }

    private func apply() {
        guard condition.trimmingCharacters(in: .whitespaces) != probe.condition else { return }
        probe.condition = condition.trimmingCharacters(in: .whitespaces)
        if probe.isSaved { workspace?.saveProbes(for: probe.pipeline) }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 8) {
            switch probe.state {
            case .starting: Text("Opening the tap…")
            case .running: Text("\(probe.seen) seen").monospacedDigit()
            case .paused: Text("Paused, \(probe.seen) seen").monospacedDigit()
            case .ended(let reason): Text(reason).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if probe.notShown > 0 {
                Text("\(probe.notShown) not shown: the view fell behind").foregroundStyle(.orange).monospacedDigit()
                    .help("The tap leaves messages out rather than slow the pipeline; this is how many it left out.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// How many messages a probe shows: every one, or a share.
struct SampleMenu: View {
    @Binding var sample: Double
    private let shares: [(Double, String)] = [(1, "Every message"), (0.5, "1 in 2"), (0.1, "1 in 10"), (0.01, "1 in 100")]

    var body: some View {
        Menu {
            ForEach(shares, id: \.0) { share, label in
                Button(label) { sample = share }
            }
        } label: {
            Text(sample >= 1 ? "All" : "1 in \(Int((1 / sample).rounded()))").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The share of messages shown")
    }
}

/// A message a probe saw: its type, when, and the module that made it; opened, its content as a tree and its
/// ancestors, each of which picks out the module that made it.
struct MessageRow: View {
    let message: TappedMessage
    let stage: PipelineStage
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Not a Button: a button tracks the mouse itself, so a drag from it never starts.
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
                Text(message.type).foregroundStyle(message.isError ? .red : .primary)
                Text(Self.time.string(from: message.created)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let from = message.emittedBy {
                    Text("from \(from)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            .onDrag { NSItemProvider(object: MessageDrag.payload(for: message) as NSString) }
            .help("Click to open it; drag it onto a tile or a wire to send it again")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(expanded ? "Closes it" : "Opens it")
            .accessibilityAction { expanded.toggle() }
            if expanded {
                if let content = message.content {
                    JSONTree(value: content).padding(.leading, 16)
                }
                if let fam = message.fam, !fam.isEmpty {
                    HStack(spacing: 4) {
                        Text("fam").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(fam.enumerated()), id: \.offset) { _, ancestor in
                            Button("\(ancestor.type)\(ancestor.emittedBy.map { " from " + $0 } ?? "")") { pick(ancestor.emittedBy) }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .help("Pick out the module that made it")
                        }
                    }
                    .padding(.leading, 16)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Selects the module the daemon names as having made a message.
    private func pick(_ module: String?) {
        guard let module, let key = stage.modules.first(where: { $0.label == module || $0.name == module })?.key else { return }
        stage.select([key])
    }

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// What a dragged message carries: its content as JSON, to send again.
enum MessageDrag {
    static let prefix = "meep-message:"

    static func payload(for message: TappedMessage) -> String {
        prefix + (message.content ?? .null).text(pretty: true)
    }

    static func body(in payload: String) -> String? {
        payload.hasPrefix(prefix) ? String(payload.dropFirst(prefix.count)) : nil
    }
}

/// JSON as a tree: objects and arrays open and close, values show as they are.
struct JSONTree: View {
    let value: JSONValue
    var label: String?

    var body: some View {
        switch value {
        case .object(let object):
            DisclosureGroup {
                ForEach(object.keys.sorted(), id: \.self) { key in
                    JSONTree(value: object[key] ?? .null, label: key).padding(.leading, 8)
                }
            } label: {
                Text(label.map { "\($0)  {\(object.count)}" } ?? "{\(object.count)}").font(.caption.monospaced())
            }
            .disclosureGroupStyle(TreeStyle(startsOpen: label == nil))
        case .array(let array):
            DisclosureGroup {
                ForEach(Array(array.enumerated()), id: \.offset) { index, item in
                    JSONTree(value: item, label: "\(index)").padding(.leading, 8)
                }
            } label: {
                Text(label.map { "\($0)  [\(array.count)]" } ?? "[\(array.count)]").font(.caption.monospaced())
            }
            .disclosureGroupStyle(TreeStyle(startsOpen: false))
        default:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let label { Text(label).foregroundStyle(.secondary) }
                Text(value.text()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption.monospaced())
        }
    }
}

/// A disclosure group that may start open.
struct TreeStyle: DisclosureGroupStyle {
    let startsOpen: Bool

    func makeBody(configuration: Configuration) -> some View {
        TreeBody(configuration: configuration, startsOpen: startsOpen)
    }

    struct TreeBody: View {
        let configuration: DisclosureGroupStyleConfiguration
        let startsOpen: Bool
        @State private var open: Bool?

        var body: some View {
            let isOpen = open ?? startsOpen
            VStack(alignment: .leading, spacing: 1) {
                Button { open = !isOpen } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 9)
                        configuration.label
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if isOpen { configuration.content }
            }
        }
    }
}

// MARK: Sending messages

/// A message to send into a module, as text or JSON (design, section 6). Before it's sent, the path it will take is lit
/// on the canvas, and modules with effects outside the pipeline are named. Sending needs the daemon's inject capability.
struct InjectComposer: View {
    let request: Workspace.InjectionRequest
    let pipeline: MeepPipeline
    let host: MeepHost?
    let stage: PipelineStage
    @Environment(\.workspace) private var workspace
    @State private var body_ = ""
    @State private var isJSON = false
    @State private var problem: String?
    @State private var sending = false

    private var module: StageModule? { stage.module(request.key) }

    private var canInject: Bool { host?.info?.capabilities.contains("inject") ?? false }

    /// The modules the message would reach, other than where it starts.
    private var reached: [StageModule] {
        stage.path(from: request.key).compactMap { stage.module($0) }.filter { $0.key != request.key }
            .sorted { (stage.tileKeys.firstIndex(of: $0.key) ?? 0) < (stage.tileKeys.firstIndex(of: $1.key) ?? 0) }
    }

    private var parsed: JSONValue? {
        guard isJSON else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(body_.utf8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send a message into \(module?.label ?? request.key)").font(.headline)
            if let asker = request.askedBy {
                Label("\(asker) asks to send this message. Nothing is sent unless you send it.", systemImage: "sparkles")
                    .font(.callout).foregroundStyle(Color(red: 0.73, green: 0.55, blue: 1))
            }
            Picker("As", selection: $isJSON) {
                Text("Text").tag(false)
                Text("JSON").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            TextEditor(text: $body_)
                .font(.callout.monospaced())
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
            if isJSON, parsed == nil, !body_.isEmpty {
                Text("That isn't JSON yet.").font(.caption).foregroundStyle(.orange)
            } else if isJSON {
                Text("Sent as JSON, the daemon makes a JsonMessage of it.").font(.caption).foregroundStyle(.secondary)
            }
            pathNote
            if !canInject {
                Label("This connection may only observe, so it can't send messages. The daemon's owner can give it inject.", systemImage: "lock")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { close(.notSent) }
                    .keyboardShortcut(.cancelAction)
                Button("Send") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canInject || sending || (isJSON && parsed == nil))
                    .help(canInject ? "Send it (⌘↩)" : "Needs the inject capability")
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear {
            body_ = request.body
            isJSON = request.isJSON
            stage.litPath = stage.path(from: request.key)
        }
        .onDisappear { stage.litPath = [] }
    }

    @ViewBuilder private var pathNote: some View {
        let outlets = reached.filter { $0.role == .outlet }
        VStack(alignment: .leading, spacing: 2) {
            if reached.isEmpty {
                Text("It goes nowhere after \(module?.label ?? "it"); its path is lit on the canvas.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("It can go on to \(Self.list(reached.map(\.label))), lit on the canvas.").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !outlets.isEmpty {
                Label("This will reach \(Self.list(outlets.map(\.label))), which send outside the pipeline.", systemImage: "arrow.up.forward.square")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func send() {
        guard let link = host?.link, let number = stage.pipeline.module(request.key)?.number ?? module?.graph?.number else {
            problem = "\(host?.title ?? "The host") can't be reached."
            return
        }
        let body: InjectBody = isJSON ? .json(parsed ?? .null) : .text(body_)
        sending = true
        Task {
            do {
                let injected = try await link.inject(pipeline.name, module: "\(number)", body)
                stage.traceInjection(into: request.key)
                close(.sent(injected))
            } catch {
                problem = error.localizedDescription
                sending = false
            }
        }
    }

    private func close(_ outcome: Workspace.InjectionOutcome) {
        stage.litPath = []
        workspace?.finishInjection(request, outcome)
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}
