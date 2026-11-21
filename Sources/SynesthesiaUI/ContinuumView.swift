import ContinuumKit
import FlowKit
import MeepClient
import Stage
import SwiftUI
import Transport

/// What the app does to the list of hosts: adding one reached over SSH, removing one, and keeping a budget. The
/// platform supplies it, since it knows how to start tunnels and where to keep hosts.
@MainActor
public protocol HostManaging: AnyObject {
    /// Adds a host on another machine, reached by forwarding its daemon's socket over SSH.
    func addRemoteHost(title: String, target: SSHTarget, budget: Double?)
    /// Stops following a host added with ``addRemoteHost(title:target:budget:)``.
    func removeHost(_ host: MeepHost)
    /// Keeps a host's byte budget for next time.
    func budgetChanged(_ host: MeepHost)
}

extension EnvironmentValues {
    @Entry public var hostManaging: HostManaging?
}

/// The Continuum: hosts and their pipelines on the left; on the right, one canvas that zooms continuously from the mesh
/// of hosts to one host's pipelines and into one pipeline (design, section 2), with what's above and below it following
/// the level: a pipeline's counts and probes, a host's pipelines, or the hosts.
public struct ContinuumView: View {
    @Bindable var workspace: Workspace
    @State private var addingHost = false
    @Environment(\.hostManaging) private var hostManaging
    @Environment(\.claude) private var claude
    private var continuum: Continuum { workspace.continuum }

    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $workspace.selection) {
                ForEach(continuum.hosts) { host in
                    Section {
                        HostRow(host: host)
                            .tag(host.address)
                            .contextMenu {
                                if case .remote = host.kind, let hostManaging {
                                    Button("Remove \(host.title)") { hostManaging.removeHost(host) }
                                }
                            }
                        ForEach(host.pipelines) { pipeline in
                            PipelineRow(pipeline: pipeline, current: host.isReachable)
                                .tag(pipeline.address)
                                .padding(.leading, 12)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .safeAreaInset(edge: .bottom) {
                if hostManaging != nil {
                    HStack {
                        Button { addingHost = true } label: { Label("Add Host…", systemImage: "plus") }
                            .buttonStyle(.borderless)
                            .help("Follow a Meep daemon on another machine, through SSH")
                        Spacer()
                    }
                    .padding(8)
                }
            }
        } detail: {
            ContinuumDetail(workspace: workspace)
                .inspector(isPresented: claude == nil ? .constant(false) : $workspace.showsClaude) {
                    if let claude {
                        ClaudeSidebar(chat: claude)
                            .inspectorColumnWidth(min: 300, ideal: 380, max: 680)
                    }
                }
                .toolbar {
                    if claude != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                workspace.showsClaude.toggle()
                            } label: {
                                Label("Claude", systemImage: "sparkles")
                            }
                            .help(workspace.showsClaude ? "Hide Claude" : "Ask Claude about what's on screen")
                        }
                    }
                }
                // A tool waiting for the person is shown, even if the sidebar was closed while Claude worked.
                .onChange(of: claude?.approval?.id) { _, waiting in
                    if waiting != nil { workspace.showsClaude = true }
                }
        }
        .sheet(isPresented: $addingHost) {
            if let hostManaging { AddHostForm(manager: hostManaging) }
        }
        .environment(\.workspace, workspace)
    }
}

struct HostRow: View {
    let host: MeepHost

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: host.status)
            Text(host.title).fontWeight(.semibold)
            if case .remote = host.kind {
                Image(systemName: "network").font(.caption).foregroundStyle(.secondary).help("Reached through SSH")
            }
            Spacer()
            if host.status == .connected {
                Text(Format.rate(host.throughput)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .help(host.statusText)
    }
}

struct PipelineRow: View {
    let pipeline: MeepPipeline
    /// Whether its host can be reached, so what's shown is current.
    let current: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: pipeline.state.symbol)
                .foregroundStyle(current ? pipeline.state.tint : .secondary)
                .help(current ? pipeline.state.rawValue : "\(pipeline.state.rawValue) when last seen")
            Text(pipeline.name)
                .foregroundStyle(current ? .primary : .secondary)
            Spacer()
            if current, pipeline.state.isLive {
                Text(Format.rate(pipeline.throughput)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusDot: View {
    let status: MeepHost.Status

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch status {
        case .connecting: .yellow
        case .connected: .green
        case .unreachable: .gray
        }
    }
}

/// The right side: a header and a dock for what's selected, round the one canvas.
struct ContinuumDetail: View {
    @Bindable var workspace: Workspace
    @AppStorage("textPaneWidth") private var textWidth = ContinuumDetail.usualTextWidth

    static let usualTextWidth = 440.0
    static let minimumCanvasWidth = 320.0
    static let minimumTextWidth = 260.0

    private var continuum: Continuum { workspace.continuum }
    private var pipeline: MeepPipeline? { workspace.selection.flatMap { continuum.pipeline(at: $0) } }
    private var host: MeepHost? { workspace.selection.flatMap { continuum.host($0.host) } }

    var body: some View {
        let pipeline = pipeline
        let host = host
        let editor = pipeline.map { workspace.editor(for: $0, host: host) }
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let pipeline, let editor {
                    PipelineHeader(pipeline: pipeline, host: host, stage: editor.stage)
                } else if let host {
                    HostHeader(host: host)
                } else {
                    MeshHeader(continuum: continuum, canvas: workspace.canvas)
                }
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 10)
            #if os(macOS)
            VSplitView {
                canvasAndText(pipeline: pipeline, host: host, editor: editor)
                    .frame(minHeight: 240, idealHeight: 480, maxHeight: .infinity)
                dock(pipeline: pipeline, host: host, editor: editor)
                    .frame(minHeight: 90, idealHeight: 200, maxHeight: .infinity)
            }
            #else
            canvasAndText(pipeline: pipeline, host: host, editor: editor)
            #endif
        }
        .background {
            // What a pipeline in focus needs while it is: its probes running, the text's requests followed.
            if let pipeline, let editor {
                PipelineFocus(pipeline: pipeline, host: host, stage: editor.stage, editor: editor).id(pipeline.id)
            }
        }
        .environment(\.pipelineEditor, editor)
    }

    /// The canvas, with the text beside it when a pipeline's is showing: levels 1 and 2 open beside level 3 rather than
    /// replacing it (design, section 2).
    private func canvasAndText(pipeline: MeepPipeline?, host: MeepHost?, editor: PipelineEditor?) -> some View {
        GeometryReader { geometry in
            let widest = max(Self.minimumTextWidth, geometry.size.width - Self.minimumCanvasWidth)
            HStack(spacing: 0) {
                ContinuumCanvas(canvas: workspace.canvas)
                    .frame(minWidth: Self.minimumCanvasWidth)
                if workspace.showsText, let pipeline, let editor {
                    PaneEdge(width: $textWidth, range: Self.minimumTextWidth...widest, usual: Self.usualTextWidth)
                    TextPane(pipeline: pipeline, host: host, stage: editor.stage)
                        .frame(width: min(max(textWidth, Self.minimumTextWidth), widest))
                        .id(pipeline.id)
                }
            }
        }
    }

    /// Under the canvas: a pipeline's modules or probes, a host's pipelines, or the hosts.
    @ViewBuilder private func dock(pipeline: MeepPipeline?, host: MeepHost?, editor: PipelineEditor?) -> some View {
        if let pipeline, let editor {
            PipelineDock(pipeline: pipeline, host: host, editor: editor)
                .id(pipeline.id)
        } else if let host {
            HostDock(host: host, canvas: workspace.canvas, selection: $workspace.selection)
        } else {
            MeshDock(continuum: continuum, canvas: workspace.canvas, selection: $workspace.selection)
        }
    }
}

/// Keeps what a pipeline in focus needs: its saved probes opened and running while it's in focus, the canvas's asks to
/// open the text followed, and the workspace told which stage is in focus.
private struct PipelineFocus: View {
    let pipeline: MeepPipeline
    let host: MeepHost?
    let stage: PipelineStage
    let editor: PipelineEditor
    @Environment(\.workspace) private var workspace
    @State private var previousProbes: Int?

    var body: some View {
        Color.clear
            .onAppear {
                guard let workspace else { return }
                workspace.showing(stage)
                if let host { workspace.openSavedProbes(for: pipeline, host: host) }
                workspace.setProbesRunning(true, for: pipeline)
                stage.probes = workspace.probes(for: pipeline)
            }
            .onDisappear {
                workspace?.setProbesRunning(false, for: pipeline)
                workspace?.hidden(stage)
            }
            .onChange(of: stage.textRequest) { _, request in
                if let request { workspace?.showText(of: pipeline, at: request.key) }
            }
            .onChange(of: workspace?.probes(for: pipeline).map(\.id) ?? []) { _, _ in
                stage.probes = workspace?.probes(for: pipeline) ?? []
                if !stage.probes.isEmpty, stage.probes.count > (previousProbes ?? 0) { editor.showsProbes = true }
                previousProbes = stage.probes.count
            }
            .onChange(of: stage.openedMessage) { _, opened in if opened != nil { editor.showsProbes = true } }
            .sheet(item: Binding(get: { editor.pendingModule }, set: { editor.pendingModule = $0 })) { pending in
                NewModuleForm(pending: pending, editor: editor)
            }
    }
}

/// Where you are, and the whole mesh's roll-up.
struct MeshHeader: View {
    let continuum: Continuum
    let canvas: ContinuumStage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Breadcrumb(parts: canvas.level == .boundary ? ["Continuum", "Boundary"] : ["Continuum"])
            HStack(spacing: 16) {
                let reachable = continuum.hosts.filter(\.isReachable)
                Text("\(continuum.hosts.count) host\(continuum.hosts.count == 1 ? "" : "s"), \(reachable.count) reachable")
                Text("\(continuum.hosts.reduce(0) { $0 + $1.pipelines.count }) pipelines").foregroundStyle(.secondary)
                Text("\(Format.rate(continuum.hosts.reduce(0) { $0 + $1.intake })) messages/s in").monospacedDigit().foregroundStyle(.secondary)
                    .help("Messages a second coming into every pipeline on every host from their sources")
                Text("\(Format.cores(continuum.hosts.reduce(0) { $0 + $1.load })) cores handling").monospacedDigit().foregroundStyle(.secondary)
                    .help("Processor cores the pipelines on every host keep busy handling messages")
                let map = canvas.flowMap
                if !map.flows.isEmpty {
                    let seen = map.flows.filter(\.observed).count
                    Text("\(map.flows.count) flow\(map.flows.count == 1 ? "" : "s"), \(seen) seen").foregroundStyle(.secondary)
                        .help("Flows between pipelines: seen ones are drawn solid, those only declared by a Fetch's or Send's address dashed")
                }
                if !map.boundary.isEmpty {
                    Text("\(map.boundary.count) outside").foregroundStyle(.secondary)
                        .help("Endpoints outside Meep that the pipelines talk to, drawn round the edge of the mesh")
                }
                Spacer()
                Text("Zoom into a host or a pipeline, or choose one on the left.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Where you are, and a host's identity, roll-up and budget.
struct HostHeader: View {
    let host: MeepHost
    @Environment(\.hostManaging) private var hostManaging

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Breadcrumb(parts: ["Continuum", host.title])
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    StatusDot(status: host.status)
                    Text(host.statusText).foregroundStyle(.secondary).lineLimit(2).help(host.statusText)
                }
                Text(host.kind.summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(host.route.map { "\(host.kind.summary): \($0)" } ?? host.kind.summary)
                if let route = host.route, route.contains("relayed") {
                    Image(systemName: "arrow.triangle.swap").foregroundStyle(.secondary).help(route)
                }
                Spacer()
                BudgetField(host: host) { hostManaging?.budgetChanged(host) }
            }
            HStack(spacing: 16) {
                if let identity = host.identity {
                    Text(identity.names.first ?? identity.id).help("The daemon's ID: \(identity.id)\nNames: \(identity.names.joined(separator: ", "))\nAddresses: \(identity.addresses.joined(separator: ", "))")
                }
                if host.isReachable {
                    Text("\(Format.rate(host.intake)) messages/s in").monospacedDigit()
                        .help("Messages a second coming into its pipelines from their sources")
                    if let headroom = host.headroom {
                        HeadroomMeter(headroom: headroom)
                    } else if host.load > 0 {
                        Text("\(Format.cores(host.load)) cores handling").monospacedDigit()
                    }
                    if let median = host.timing.quantile(0.5), let tail = host.timing.quantile(0.99) {
                        Text("handling p50 \(StageFormat.duration(median)), p99 \(StageFormat.duration(tail))").monospacedDigit()
                            .help("Handling times over every module whose times have come, since their pipelines started")
                    }
                    if let offset = host.clockOffset, abs(offset) >= 0.05 {
                        Text("clock \(String(format: "%+.2f", offset)) s").monospacedDigit().foregroundStyle(abs(offset) > 2 ? .orange : .secondary)
                            .help("How far its clock is ahead of this Mac's, from when its updates arrive")
                    }
                }
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

/// A host's processor cores: the share its pipelines and daemon use, and what's spare.
struct HeadroomMeter: View {
    let headroom: Headroom

    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: 1 - headroom.spare)
                .progressViewStyle(.linear)
                .frame(width: 70)
                .tint(headroom.spare < 0.2 ? .red : headroom.spare < 0.5 ? .orange : .green)
            Text("\(Int((headroom.spare * 100).rounded()))% of \(headroom.cores) cores spare").monospacedDigit()
        }
        .help(help)
    }

    private var help: String {
        var lines = ["Its pipelines keep \(Format.cores(headroom.pipelines)) cores busy handling messages."]
        if let daemon = headroom.daemon { lines.append("The daemon uses \(Format.cores(daemon)) cores in all.") }
        if let load = headroom.machineLoad { lines.append("The machine's load over the last minute is \(String(format: "%.1f", load)), which counts other programs.") }
        return lines.joined(separator: "\n")
    }
}

/// A host's byte budget, and what its connection carries against it.
struct BudgetField: View {
    @Bindable var host: MeepHost
    let changed: () -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            if host.traffic.subscribed {
                ProgressView(value: min(host.traffic.bandwidth / max(host.budget ?? .infinity, 1), 1))
                    .progressViewStyle(.linear)
                    .frame(width: 60)
                    .tint(held ? .orange : .accentColor)
                Text("\(StageFormat.bytes(host.traffic.bandwidth))/s of").monospacedDigit().foregroundStyle(.secondary)
            }
            TextField("No limit", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 60, idealWidth: 70, maxWidth: 110)
                .fixedSize()
                .multilineTextAlignment(.trailing)
                .onSubmit(apply)
            Text("KB/s").foregroundStyle(.secondary)
        }
        .font(.callout)
        .help(help)
        .onAppear { text = host.budget.map { Self.kilobytes($0) } ?? "" }
        .onChange(of: host.budget) { _, budget in text = budget.map { Self.kilobytes($0) } ?? "" }
    }

    private var held: Bool { host.traffic.slowdown > 1 }

    private func apply() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            host.budget = nil
        } else if let value = Double(trimmed), value > 0 {
            host.budget = value * 1000
        }
        text = host.budget.map { Self.kilobytes($0) } ?? ""
        changed()
    }

    static func kilobytes(_ bytes: Double) -> String {
        let value = bytes / 1000
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private var help: String {
        guard host.traffic.subscribed else {
            return "The byte budget for this host's connection. This daemon is older than Meep2 0c83a49, so it can't be kept to: its counts come as stats streams."
        }
        var text = "The byte budget for this host's connection: the most it may carry a second. Synesthesia asks only for what's on screen, and slows everything down together to stay under it."
        if held { text += String(format: "\nNow asking for things %.1f times less often than usual, to stay under it.", host.traffic.slowdown) }
        if host.traffic.gaps > 0 { text += "\n\(host.traffic.gaps) updates went missing and were asked for again." }
        if let problem = host.traffic.problem { text += "\nThe host refused the last change: \(problem)" }
        return text
    }
}

/// A pipeline's header: where you are, its state, its roll-up and its file.
struct PipelineHeader: View {
    let pipeline: MeepPipeline
    let host: MeepHost?
    let stage: PipelineStage
    @Environment(\.workspace) private var workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Breadcrumb(parts: ["Continuum", host?.title ?? pipeline.host, pipeline.name])
            if let host, !host.isReachable {
                Label("\(host.title) can't be reached, so these are the counts from when it last could. \(host.statusText)",
                      systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 16) {
                Label(pipeline.state.rawValue, systemImage: pipeline.state.symbol).foregroundStyle(pipeline.state.tint)
                if let started = pipeline.started {
                    Text("Started \(started.formatted(date: .abbreviated, time: .standard))").foregroundStyle(.secondary)
                }
                if pipeline.restarts > 0 {
                    Text("Restarted \(pipeline.restarts)×").foregroundStyle(.orange)
                }
                if let reason = pipeline.reason {
                    Text(reason).foregroundStyle(.secondary).lineLimit(2).help(reason)
                }
                if host?.isReachable == true, pipeline.state.isLive {
                    Text(PipelineSummaryLine(pipeline, current: true).line).monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(1).help("Messages a second in from its sources, its busiest module, failures, messages waiting and its median handling time")
                }
                Spacer()
                Text(pipeline.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    .help(pipeline.path).textSelection(.enabled)
                if let workspace {
                    Toggle(isOn: Binding(get: { workspace.showsText }, set: { workspace.showsText = $0 })) {
                        Label("Meeplang", systemImage: "doc.text")
                    }
                    .toggleStyle(.button)
                    .help("Show the pipeline's Meeplang beside the canvas (⌥⌘T). Zooming in past the closest zoom over a tile, or double-clicking it, opens it at that module.")
                }
            }
        }
    }
}

/// Under a pipeline: its modules' counts, or its probes' messages.
struct PipelineDock: View {
    let pipeline: MeepPipeline
    let host: MeepHost?
    @Bindable var editor: PipelineEditor
    @Environment(\.workspace) private var workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Show", selection: $editor.showsProbes) {
                    Text("Modules").tag(false)
                    Text(probeCount == 0 ? "Probes" : "Probes (\(probeCount))").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            if editor.showsProbes {
                ProbeDock(probes: workspace?.probes(for: pipeline) ?? [], stage: editor.stage)
            } else {
                ModuleTable(modules: pipeline.modules, current: host?.isReachable ?? false)
            }
        }
        // The tabs stay at the top whichever is showing, though the probes' view may not fill the height.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: Binding(
            get: { workspace?.injection.flatMap { $0.pipeline == pipeline.id ? $0 : nil } },
            set: { if $0 == nil, let request = workspace?.injection { workspace?.finishInjection(request, .notSent) } }
        )) { request in
            InjectComposer(request: request, pipeline: pipeline, host: host, stage: editor.stage)
        }
    }

    private var probeCount: Int { workspace?.probes(for: pipeline).count ?? 0 }
}

/// A host's pipelines, with their roll-ups.
struct HostPipelinesTable: View {
    let host: MeepHost
    @Binding var selection: MeepAddress?

    var body: some View {
        Table(host.pipelines) {
            TableColumn("Pipeline") { pipeline in
                Button(pipeline.name) { selection = pipeline.address }
                    .buttonStyle(.link)
            }
            TableColumn("State") { pipeline in
                Label(pipeline.state.rawValue, systemImage: pipeline.state.symbol)
                    .foregroundStyle(host.isReachable ? pipeline.state.tint : .secondary)
            }
            TableColumn("In/s") { pipeline in Rate(value: host.isReachable ? pipeline.intake : nil) }
                .width(min: 50, ideal: 64)
            TableColumn("Messages/s") { pipeline in Rate(value: host.isReachable ? pipeline.throughput : nil) }
                .width(min: 60, ideal: 80)
            TableColumn("Cores") { pipeline in
                Text(host.isReachable ? Format.cores(pipeline.load) : "—").monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                    .help("Processor cores it keeps busy handling messages")
            }
            .width(min: 44, ideal: 54)
            TableColumn("Failing/s") { pipeline in Rate(value: host.isReachable ? pipeline.errorRate : nil) }
                .width(min: 50, ideal: 64)
            TableColumn("p50") { pipeline in
                Text(pipeline.timing.quantile(0.5).map(StageFormat.duration) ?? "—").monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                    .help("Its median handling time, when its modules' times have come: they do while it's shown in detail")
            }
            .width(min: 50, ideal: 64)
            TableColumn("Restarts") { pipeline in
                Text("\(pipeline.restarts)").monospacedDigit()
            }
            .width(min: 40, ideal: 56)
            TableColumn("File") { pipeline in
                Text(pipeline.path).foregroundStyle(.secondary).help(pipeline.path)
            }
        }
    }
}

/// Every host, with its roll-up, budget and how it's reached.
struct HostsTable: View {
    let continuum: Continuum
    @Binding var selection: MeepAddress?

    var body: some View {
        Table(continuum.hosts) {
            TableColumn("Host") { host in
                HStack(spacing: 6) {
                    StatusDot(status: host.status)
                    Button(host.title) { selection = host.address }.buttonStyle(.link)
                }
                .help(host.statusText)
            }
            .width(min: 100, ideal: 140)
            TableColumn("Reached by") { host in
                Text(host.kind.summary).foregroundStyle(.secondary).help(host.kind.summary)
            }
            .width(min: 100, ideal: 200)
            TableColumn("Pipelines") { host in Text("\(host.pipelines.count)").monospacedDigit() }
                .width(min: 50, ideal: 64)
            TableColumn("In/s") { host in Rate(value: host.isReachable ? host.intake : nil) }
                .width(min: 50, ideal: 64)
            TableColumn("Cores spare") { host in
                Text(host.headroom.map { "\(Int(($0.spare * 100).rounded()))% of \($0.cores)" } ?? "—").monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Carrying") { host in
                Text(host.traffic.subscribed ? "\(StageFormat.bytes(host.traffic.bandwidth))/s" : "—").monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help("Bytes a second its connection carries")
            }
            .width(min: 60, ideal: 80)
            TableColumn("Budget") { host in
                Text(host.budget.map { "\(StageFormat.bytes($0))/s" } ?? "none").monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundStyle(host.traffic.slowdown > 1 ? .orange : .primary)
                    .help(host.traffic.slowdown > 1 ? String(format: "Asking for things %.1f times less often than usual, to stay under it", host.traffic.slowdown) : "Within it")
            }
            .width(min: 60, ideal: 80)
            TableColumn("Clock") { host in
                Text(host.clockOffset.map { abs($0) < 0.005 ? "0.00 s" : String(format: "%+.2f s", $0) } ?? "—").monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help("How far its clock is ahead of this Mac's")
            }
            .width(min: 50, ideal: 64)
        }
    }
}

/// Adds a host on another machine, reached through SSH.
struct AddHostForm: View {
    let manager: HostManaging
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var title = ""
    @State private var port = ""
    @State private var socket = ""
    @State private var command = "meep"
    @State private var budget = "64"
    @State private var options = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Host").font(.headline)
            Text("Synesthesia forwards the daemon's socket over SSH, so the daemon sees you as its own user. It can't type a password: the host needs a key that logs in without one.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("SSH destination", text: $destination, prompt: Text("user@host, or a name from ~/.ssh/config"))
                TextField("Name", text: $title, prompt: Text(destination.isEmpty ? "As it's shown" : shortName))
                TextField("Port", text: $port, prompt: Text("22, or as ~/.ssh/config says"))
                TextField("Daemon's socket", text: $socket, prompt: Text("Asked for with meep daemon socket"))
                    .help("The daemon's socket on the host, in full. Left empty, Synesthesia runs meep daemon socket there to find it.")
                TextField("meep there", text: $command)
                    .help("How to run meep on the host, for meep daemon socket: its full path if a non-interactive shell there can't find it, with MEEP_HOME=… before it if the daemon has its own.")
                TextField("Other ssh options", text: $options, prompt: Text("Such as -i ~/.ssh/lab -J gateway"))
                    .help("Options for ssh that ~/.ssh/config doesn't give, such as a key or a jump host.")
                TextField("Budget, KB/s", text: $budget)
                    .help("The most the connection may carry a second. Synesthesia asks only for what's on screen, and slows down to stay under it.")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    let target = SSHTarget(
                        destination: destination.trimmingCharacters(in: .whitespaces), port: Int(port),
                        remoteSocket: socket.isEmpty ? nil : socket, meepCommand: command.isEmpty ? "meep" : command,
                        options: options.split(separator: " ").map(String.init)
                    )
                    manager.addRemoteHost(title: title.isEmpty ? shortName : title, target: target, budget: Double(budget).map { $0 * 1000 })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(destination.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var shortName: String {
        let host = destination.split(separator: "@").last.map(String.init) ?? destination
        return host.split(separator: ".").first.map(String.init) ?? host
    }
}

struct ModuleTable: View {
    let modules: [MeepModule]
    /// Whether the counts are current; rates are only shown while they are.
    let current: Bool

    var body: some View {
        Table(modules) {
            TableColumn("Module") { module in
                HStack(spacing: 6) {
                    Image(systemName: module.role.symbol)
                        .frame(width: 16)
                        .foregroundStyle(.tint)
                        .help(module.role?.rawValue ?? "role not known yet")
                    Text(module.label)
                }
                .help(module.inflections.isEmpty ? module.verb : "\(module.verb): \(module.inflections.joined(separator: ", "))")
            }
            .width(min: 140, ideal: 180)
            TableColumn("In/s") { module in Rate(value: current ? module.rates[.received] : nil) }
                .width(min: 50, ideal: 60)
            TableColumn("Out/s") { module in Rate(value: current ? module.rates[.emitted] : nil) }
                .width(min: 50, ideal: 60)
            TableColumn("Busy") { module in
                Text(current && module.role != .source ? "\(Int((module.load * 100).rounded()))%" : "—").monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundStyle(module.load > 0.8 ? .red : module.load > 0.5 ? .orange : .primary)
                    .help("How busy it is: its handling time a second. Near 100% it's the bottleneck, and its queue will grow.")
            }
            .width(min: 40, ideal: 50)
            TableColumn("p50") { module in
                Text(module.timing?.quantile(0.5).map(StageFormat.duration) ?? "—").monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(module.timing.flatMap { timing in timing.quantile(0.99).map { "Median handling time; p99 \(StageFormat.duration($0)), over \(timing.count.formatted()) messages" } } ?? "Its handling time, once it comes")
            }
            .width(min: 50, ideal: 60)
            Group {
                TableColumn("Received") { (module: MeepModule) in Count(value: module.counts.received) }
                    .width(min: 50, ideal: 72)
                TableColumn("Emitted") { (module: MeepModule) in Count(value: module.counts.emitted) }
                    .width(min: 50, ideal: 72)
                TableColumn("Filtered") { (module: MeepModule) in Count(value: module.counts.filtered) }
                    .width(min: 50, ideal: 72)
                TableColumn("Failed") { (module: MeepModule) in Count(value: module.counts.failed, alert: true) }
                    .width(min: 50, ideal: 72)
                TableColumn("Dropped") { (module: MeepModule) in Count(value: module.counts.dropped, alert: true) }
                    .width(min: 50, ideal: 72)
                TableColumn("Queued") { (module: MeepModule) in Count(value: module.counts.queued) }
                    .width(min: 50, ideal: 72)
            }
        }
    }
}

struct Rate: View {
    /// The rate, or nil when it isn't known now.
    let value: Double?

    var body: some View {
        Text(value.map(Format.rate) ?? "—").monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct Count: View {
    let value: Int64
    var alert = false

    var body: some View {
        Text(value.formatted())
            .monospacedDigit()
            .foregroundStyle(alert && value > 0 ? .red : .primary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Where you are: Continuum › local › ticker.
struct Breadcrumb: View {
    let parts: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                Text(part).foregroundStyle(index == parts.count - 1 ? .primary : .secondary)
            }
        }
        .font(.headline)
    }
}

enum Format {
    /// Processor cores, to two places when there are few.
    static func cores(_ value: Double) -> String {
        value < 0.1 ? value.formatted(.number.precision(.fractionLength(2))) : value.formatted(.number.precision(.fractionLength(1)))
    }

    /// A rate per second: one decimal place below 10, whole numbers above, thousands as k.
    static func rate(_ value: Double) -> String {
        switch value {
        case ..<0.05: "0"
        case ..<10: value.formatted(.number.precision(.fractionLength(1)))
        case ..<10_000: value.formatted(.number.precision(.fractionLength(0)))
        default: (value / 1000).formatted(.number.precision(.fractionLength(1))) + "k"
        }
    }
}

extension MeepHost {
    var statusText: String {
        switch status {
        case .connecting: "Connecting…"
        case .connected: info.map { "Connected to Meep \($0.version)" } ?? "Connected"
        case .unreachable(let reason): reason
        }
    }
}

extension PipelineState {
    var symbol: String {
        switch self {
        case .starting: "hourglass"
        case .running: "play.circle.fill"
        case .restarting: "arrow.clockwise.circle"
        case .stopping: "stop.circle"
        case .finished: "checkmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .running: .green
        case .restarting, .stopping, .starting: .orange
        case .failed: .red
        default: .secondary
        }
    }
}

extension Optional where Wrapped == VerbRole {
    /// The shape the canvas will draw for the role, as an SF Symbol.
    var symbol: String {
        switch self {
        case .source: "circle"
        case .inlet: "arrowtriangle.left"
        case .filter: "arrowtriangle.down"
        case .outlet: "arrowtriangle.right"
        case .step: "rectangle"
        case nil: "square.dashed"
        }
    }
}
