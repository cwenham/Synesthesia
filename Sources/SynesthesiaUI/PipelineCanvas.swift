import CodeEditing
import ContinuumKit
import LanguageClient
import MeepClient
import Stage
import SwiftUI

/// Makes the view that draws the Continuum's stage. Each platform supplies its own (on the Mac a Metal view) through the
/// environment, so this package stays free of AppKit and UIKit (design, section 9: `CanvasSurface`).
public struct CanvasSurfaceProvider {
    public let make: @MainActor (ContinuumStage) -> AnyView

    public init(make: @escaping @MainActor (ContinuumStage) -> AnyView) {
        self.make = make
    }
}

extension EnvironmentValues {
    @Entry public var canvasSurface: CanvasSurfaceProvider?
    @Entry public var codeTextSurface: CodeTextSurfaceProvider?
    @Entry public var workspace: Workspace?
}

extension FocusedValues {
    /// The canvas in the focused window, for the View menu's zoom commands.
    @Entry public var continuumStage: ContinuumStage?
}

/// The Continuum drawn live, in one zoom from the mesh of hosts to a pipeline's tiles. Hovering shows the numbers
/// behind what's drawn: a tile's or wire's, a pipeline's roll-up, or a host's.
struct ContinuumCanvas: View {
    let canvas: ContinuumStage
    @Environment(\.canvasSurface) private var surface
    @Environment(\.workspace) private var workspace
    @Environment(\.pipelineEditor) private var editor

    var body: some View {
        HStack(spacing: 0) {
            // The palette docks beside the canvas, so it stays open while verbs are dragged from it.
            if let editor, editor.showsPalette, editor.canEdit {
                VerbPalette(verbs: editor.verbs, editor: editor)
                    .task { await editor.loadVerbs() }
                Divider()
            }
            content
        }
        .focusedSceneValue(\.continuumStage, canvas)
    }

    private var content: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let surface {
                    surface.make(canvas)
                } else {
                    ContentUnavailableView("No canvas here", systemImage: "square.dashed",
                                           description: Text("This platform has no canvas yet."))
                }
                if let hovered = canvas.hovered {
                    // Beside the pointer, below and right of it, or wherever it fits.
                    let pointer = canvas.pointer
                    let room = geometry.size
                    card(for: hovered)
                        .fixedSize()
                        .alignmentGuide(.leading) { card in
                            let x = pointer.x + 18
                            return x + card.width > room.width - 8 ? -max(8, pointer.x - 12 - card.width) : -x
                        }
                        .alignmentGuide(.top) { card in
                            let y = pointer.y + 18
                            return y + card.height > room.height - 8 ? -max(8, room.height - 8 - card.height) : -y
                        }
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) { ZoomButtons(canvas: canvas).padding(10) }
            .overlay(alignment: .bottomLeading) {
                if let editor, editor.canEdit, !editor.showsPalette, canvas.level == .pipeline {
                    Button { editor.showsPalette = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .padding(6)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.12)))
                        .environment(\.colorScheme, .dark)
                        .help("Show the verbs, to drag onto a tile, a wire or the background")
                        .accessibilityLabel("Show the Verbs")
                        .padding(10)
                }
            }
            .overlay(alignment: .topLeading) { LevelBadge(canvas: canvas).padding(10) }
            .overlay(alignment: .top) {
                if let notice = editor?.notice {
                    CanvasNotice(notice: notice) { editor?.dismissNotice() }.padding(10)
                }
            }
        }
    }

    @ViewBuilder private func card(for hit: ContinuumHit) -> some View {
        switch hit {
        case .inside(let address, let inside):
            if let pipeline = canvas.continuum.pipeline(at: address) {
                HoverCard(hit: inside, stage: canvas.stage(for: pipeline))
            }
        case .pipeline(let address):
            if let pipeline = canvas.continuum.pipeline(at: address) {
                PipelineCard(pipeline: pipeline, host: canvas.continuum.host(address.host))
            }
        case .host(let name):
            if let host = canvas.continuum.host(name) { HostCard(host: host) }
        }
    }
}

/// Which level of the zoom the canvas is at, in its corner.
struct LevelBadge: View {
    let canvas: ContinuumStage

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.45), in: Capsule())
            .help("The canvas zooms from the mesh of hosts, to a host's pipelines, to a pipeline's modules. Double-click a host or pipeline to zoom into it, or the background to see everything.")
            .allowsHitTesting(true)
    }

    private var text: String {
        switch canvas.level {
        case .mesh: "Mesh"
        case .host: "Host"
        case .pipeline: "Pipeline"
        }
    }
}

struct ZoomButtons: View {
    let canvas: ContinuumStage

    var body: some View {
        HStack(spacing: 2) {
            Button { canvas.step(zoomingIn: false) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out (⌘-)")
            Button { canvas.fit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Zoom to fit what's selected (⌘0), or double-click the background to see everything")
            Button { canvas.step(zoomingIn: true) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in (⌘=)")
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }
}

/// A pipeline's roll-up beside the pointer, when it's drawn as a district.
struct PipelineCard: View {
    let pipeline: MeepPipeline
    let host: MeepHost?

    var body: some View {
        let current = (host?.isReachable ?? false) && pipeline.state.isLive
        VStack(alignment: .leading, spacing: 6) {
            Text(pipeline.name).font(.headline)
            Text("\(pipeline.state.rawValue) on \(host?.title ?? pipeline.host), \(pipeline.modules.count) modules").foregroundStyle(.secondary)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                row("In from sources", current ? Format.rate(pipeline.intake) + "/s" : "—")
                row("Through modules", current ? Format.rate(pipeline.throughput) + "/s" : "—")
                row("Cores handling", current ? Format.cores(pipeline.load) : "—")
                if let busiest = pipeline.modules.max(by: { $0.load < $1.load }), busiest.load > 0.005 {
                    row("Busiest", "\(busiest.label), \(Int((busiest.load * 100).rounded()))%")
                }
                if pipeline.errorRate > 0 { row("Failing", Format.rate(pipeline.errorRate) + "/s") }
                if pipeline.queued > 0 { row("Waiting", pipeline.queued.formatted()) }
                let bandwidth = pipeline.bandwidth
                if bandwidth.received + bandwidth.sent > 0 {
                    row("Network", "\(StageFormat.bytes(bandwidth.received))/s in, \(StageFormat.bytes(bandwidth.sent))/s out")
                }
                if let median = pipeline.timing.quantile(0.5), let tail = pipeline.timing.quantile(0.99) {
                    row("Handling", "p50 \(StageFormat.duration(median)), p99 \(StageFormat.duration(tail))")
                }
            }
            if !current { Text("Not current: these are the counts when last seen.").font(.caption).foregroundStyle(.orange) }
            Text("Double-click to zoom in.").font(.caption).foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

/// A host's roll-up and connection beside the pointer.
struct HostCard: View {
    let host: MeepHost

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(host.title).font(.headline)
            Text(host.kind.summary).foregroundStyle(.secondary)
            if let route = host.route {
                Text(route).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let identity = host.identity {
                Text(([identity.names.first].compactMap { $0 } + identity.addresses.prefix(2)).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if host.isReachable {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                    row("Pipelines", "\(host.pipelines.count)")
                    row("In from sources", Format.rate(host.intake) + "/s")
                    row("Cores handling", Format.cores(host.load))
                    if let headroom = host.headroom {
                        row("Cores spare", "\(Int((headroom.spare * 100).rounded()))% of \(headroom.cores)")
                    }
                    if let memory = host.runtime.workingSet { row("Daemon's memory", StageFormat.bytes(memory)) }
                    if host.traffic.subscribed {
                        row("Connection", "\(StageFormat.bytes(host.traffic.bandwidth))/s" + (host.budget.map { " of \(StageFormat.bytes($0))/s" } ?? ""))
                        if host.traffic.slowdown > 1 {
                            row("To stay in budget", String(format: "%.1f× slower", host.traffic.slowdown))
                        }
                    }
                    if let offset = host.clockOffset { row("Clock", String(format: "%+.2f s from this Mac", offset)) }
                }
            } else {
                Text(host.statusText).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("Double-click to zoom in.").font(.caption).foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

extension View {
    /// The hover cards' look: dark, rounded, left-aligned.
    func cardStyle() -> some View {
        font(.callout)
            .padding(10)
            .frame(maxWidth: 360, alignment: .leading)
            .background(Color(white: 0.09).opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.14)))
            .environment(\.colorScheme, .dark)
    }
}

/// The numbers behind a tile or wire, beside the pointer: labels in full, every count that isn't zero, and what a
/// wire's particles mean.
struct HoverCard: View {
    let hit: StageHit
    let stage: PipelineStage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch hit {
            case .tile(let key):
                if let module = stage.module(key) { moduleCard(module) }
            case .wire(let key):
                if let link = stage.link(key) { wireCard(link) }
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: 340, alignment: .leading)
        .background(Color(white: 0.09).opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.14)))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private func moduleCard(_ module: StageModule) -> some View {
        let graph = module.graph
        Text(module.label).font(.headline)
        Text(describe(module)).foregroundStyle(.secondary)
        if let graph, !graph.parameters.isEmpty {
            Text(graph.parameters.map(\.text).joined(separator: " ")).font(.callout.monospaced())
                .fixedSize(horizontal: false, vertical: true)
        }
        if let graph {
            Text("\((graph.span.file as NSString).lastPathComponent), line \(graph.span.startLine)").font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        if module.isBeingEdited {
            Text("Being edited: its lines don't load yet, so this is how it was.").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if module.isNew {
            Text("Not running yet. Save the text to run it; a daemon watching the file reloads it.").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            counts(of: module)
        }
    }

    @ViewBuilder private func counts(of module: StageModule) -> some View {
        let current = stage.isCurrent
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
            ForEach(rows(for: module), id: \.name) { row in
                GridRow {
                    Text(row.name).foregroundStyle(.secondary)
                    Text(row.count.formatted()).monospacedDigit()
                    Text(current && row.rate != nil ? StageFormat.rate(row.rate!) : "").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        if !current { Text("Not current: these are the counts when last seen.").font(.caption).foregroundStyle(.orange) }
    }

    @ViewBuilder private func wireCard(_ shown: StageLink) -> some View {
        let from = stage.module(shown.from)?.label ?? shown.from
        let to = stage.module(shown.to)?.label ?? shown.to
        Text("\(from) → \(to)").font(.headline)
        Text(shown.port == .errors ? "Errors only (@errors)" : shown.input > 1 ? "Into input \(shown.input)" : "Messages, and errors going past")
            .foregroundStyle(.secondary)
        if !shown.types.isEmpty {
            Text(shown.types.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        Divider()
        if shown.isNew {
            Text("Not running yet: it carries nothing until the text is saved and loaded.").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let link = shown.live, link.isCounted {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                GridRow {
                    Text("Carried").foregroundStyle(.secondary)
                    Text(link.carried.formatted()).monospacedDigit()
                    Text(stage.isCurrent ? StageFormat.rate(link.rate) : "").monospacedDigit().foregroundStyle(.secondary)
                }
                if link.errors > 0 {
                    GridRow {
                        Text("Errors").foregroundStyle(.secondary)
                        Text(link.errors.formatted()).monospacedDigit()
                        Text(stage.isCurrent ? StageFormat.rate(link.errorRate) : "").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Text(particleNote(rate: max(link.rate - link.errorRate, 0))).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("This daemon doesn't count what each link carries, so the particles follow what the next module received.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func describe(_ module: StageModule) -> String {
        var parts = [module.verb]
        if let role = module.role { parts.append(role.rawValue) }
        let inflections = module.inflections.filter { $0 != module.verb }
        if !inflections.isEmpty { parts.append("as " + inflections.joined(separator: " or ")) }
        return parts.joined(separator: ", ")
    }

    private struct Row {
        var name: String
        var count: Int64
        var rate: Double?
    }

    private func rows(for module: StageModule) -> [Row] {
        let c = module.counts
        var rows: [Row] = [
            Row(name: "Received", count: c.received, rate: module.rate(.received)),
            Row(name: "Emitted", count: c.emitted, rate: module.rate(.emitted)),
            Row(name: "Passed on", count: c.passed, rate: module.rate(.passed)),
        ]
        if module.role == .filter { rows.append(Row(name: "Held back", count: c.heldBack, rate: module.rate(.heldBack))) }
        rows += [
            Row(name: "Filtered", count: c.filtered, rate: module.rate(.filtered)),
            Row(name: "Failed", count: c.failed, rate: module.rate(.failed)),
            Row(name: "Refused", count: c.refused, rate: module.rate(.refused)),
            Row(name: "Dropped", count: c.dropped, rate: module.rate(.dropped)),
            Row(name: "Expired", count: c.expired, rate: module.rate(.expired)),
            Row(name: "Queued now", count: c.queued, rate: nil),
        ]
        return rows.filter { $0.count != 0 || $0.name == "Received" && module.role != .source }
    }

    private func particleNote(rate: Double) -> String {
        rate >= Flow.messagesBelow
            ? "Streaks show the rate: busier wires are denser, but there are more messages than streaks."
            : "Each dot is one message."
    }
}
