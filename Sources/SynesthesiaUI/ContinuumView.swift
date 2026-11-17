import ContinuumKit
import MeepClient
import Stage
import SwiftUI

/// The Continuum: hosts and their pipelines on the left; on the right, the selected host's pipelines, or the selected
/// pipeline drawn live on the canvas above a table of its modules' counts.
public struct ContinuumView: View {
    @Bindable var workspace: Workspace
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
                        ForEach(host.pipelines) { pipeline in
                            PipelineRow(pipeline: pipeline, current: host.isReachable)
                                .tag(pipeline.address)
                                .padding(.leading, 12)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let selection = workspace.selection, let pipeline = continuum.pipeline(at: selection) {
                PipelineDetailView(pipeline: pipeline, host: continuum.host(selection.host))
                    .id(pipeline.id)
            } else if let selection = workspace.selection, let host = continuum.host(selection.host) {
                HostDetailView(host: host, selection: $workspace.selection)
            } else {
                ContentUnavailableView("Nothing selected", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Choose a host or a pipeline."))
            }
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

struct HostDetailView: View {
    let host: MeepHost
    @Binding var selection: MeepAddress?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Breadcrumb(parts: ["Continuum", host.title])
            HStack(spacing: 8) {
                StatusDot(status: host.status)
                Text(host.statusText).foregroundStyle(.secondary)
            }
            if let info = host.info {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Version").foregroundStyle(.secondary); Text(info.version) }
                    GridRow { Text("Address").foregroundStyle(.secondary); Text(host.address.description).textSelection(.enabled) }
                    GridRow { Text("Socket").foregroundStyle(.secondary); Text(info.socket).textSelection(.enabled) }
                    GridRow { Text("You may").foregroundStyle(.secondary); Text(info.capabilities.joined(separator: ", ")) }
                }
            }
            Table(host.pipelines) {
                TableColumn("Pipeline") { pipeline in
                    Button(pipeline.name) { selection = pipeline.address }
                        .buttonStyle(.link)
                }
                TableColumn("State") { pipeline in
                    Label(pipeline.state.rawValue, systemImage: pipeline.state.symbol)
                        .foregroundStyle(host.isReachable ? pipeline.state.tint : .secondary)
                }
                TableColumn("Messages/s") { pipeline in
                    Text(host.isReachable ? Format.rate(pipeline.throughput) : "—").monospacedDigit()
                }
                TableColumn("Restarts") { pipeline in
                    Text("\(pipeline.restarts)").monospacedDigit()
                }
                TableColumn("File") { pipeline in
                    Text(pipeline.path).foregroundStyle(.secondary).help(pipeline.path)
                }
            }
        }
        .padding()
    }
}

struct PipelineDetailView: View {
    let pipeline: MeepPipeline
    let host: MeepHost?
    /// The stage the canvas draws, which the text beside it shares.
    @State private var stage: PipelineStage
    @Environment(\.workspace) private var workspace
    @AppStorage("textPaneWidth") private var textWidth = PipelineDetailView.usualTextWidth

    static let usualTextWidth = 440.0

    init(pipeline: MeepPipeline, host: MeepHost?) {
        self.pipeline = pipeline
        self.host = host
        _stage = State(initialValue: PipelineStage(pipeline: pipeline, host: host))
    }

    private var showsText: Bool { workspace?.showsText ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            .padding([.horizontal, .top])
            .padding(.bottom, 10)
            #if os(macOS)
            VSplitView {
                canvasAndText
                    .frame(minHeight: 240, idealHeight: 480, maxHeight: .infinity)
                ModuleTable(modules: pipeline.modules, current: host?.isReachable ?? false)
                    .frame(minHeight: 90, idealHeight: 170, maxHeight: .infinity)
            }
            #else
            canvasAndText
            #endif
        }
        .onChange(of: stage.textRequest) { _, request in
            if let request { workspace?.showText(of: pipeline, at: request.key) }
        }
    }

    /// The canvas, with the text beside it when it's showing: levels 1 and 2 open beside level 3 rather than
    /// replacing it (design, section 2).
    private var canvasAndText: some View {
        GeometryReader { geometry in
            let widest = max(Self.minimumTextWidth, geometry.size.width - Self.minimumCanvasWidth)
            HStack(spacing: 0) {
                PipelineCanvas(stage: stage)
                    .frame(minWidth: Self.minimumCanvasWidth)
                if showsText {
                    PaneEdge(width: $textWidth, range: Self.minimumTextWidth...widest, usual: Self.usualTextWidth)
                    TextPane(pipeline: pipeline, host: host, stage: stage)
                        .frame(width: min(max(textWidth, Self.minimumTextWidth), widest))
                }
            }
        }
    }

    static let minimumCanvasWidth = 320.0
    static let minimumTextWidth = 260.0
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
            TableColumn("Received") { module in Count(value: module.counts.received) }
                .width(min: 50, ideal: 72)
            TableColumn("Emitted") { module in Count(value: module.counts.emitted) }
                .width(min: 50, ideal: 72)
            TableColumn("Filtered") { module in Count(value: module.counts.filtered) }
                .width(min: 50, ideal: 72)
            TableColumn("Failed") { module in Count(value: module.counts.failed, alert: true) }
                .width(min: 50, ideal: 72)
            TableColumn("Dropped") { module in Count(value: module.counts.dropped, alert: true) }
                .width(min: 50, ideal: 72)
            TableColumn("Queued") { module in Count(value: module.counts.queued) }
                .width(min: 50, ideal: 72)
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
