import ContinuumKit
import MeepClient
import Stage
import SwiftUI

/// Makes the view that draws a stage. Each platform supplies its own (on the Mac a Metal view) through the
/// environment, so this package stays free of AppKit and UIKit (design, section 9: `CanvasSurface`).
public struct CanvasSurfaceProvider {
    public let make: @MainActor (PipelineStage) -> AnyView

    public init(make: @escaping @MainActor (PipelineStage) -> AnyView) {
        self.make = make
    }
}

extension EnvironmentValues {
    @Entry public var canvasSurface: CanvasSurfaceProvider?
    @Entry public var codeTextSurface: CodeTextSurfaceProvider?
    @Entry public var workspace: Workspace?
}

extension FocusedValues {
    /// The stage in the focused window, for the View menu's zoom commands.
    @Entry public var pipelineStage: PipelineStage?
}

/// A pipeline drawn live: its modules as tiles, links as wires, particles from its counts. Hovering shows the
/// numbers behind what's drawn.
struct PipelineCanvas: View {
    let stage: PipelineStage
    @Environment(\.canvasSurface) private var surface
    @Environment(\.workspace) private var workspace

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let surface {
                    surface.make(stage)
                } else {
                    ContentUnavailableView("No canvas here", systemImage: "square.dashed",
                                           description: Text("This platform has no canvas yet."))
                }
                if let hovered = stage.hovered {
                    // Beside the pointer, below and right of it, or wherever it fits.
                    let pointer = stage.pointer
                    let room = geometry.size
                    HoverCard(hit: hovered, stage: stage)
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
            .overlay(alignment: .bottomTrailing) { ZoomButtons(stage: stage).padding(10) }
        }
        .onAppear {
            stage.pipeline.watchers += 1
            workspace?.showing(stage)
        }
        .onDisappear {
            stage.pipeline.watchers -= 1
            workspace?.hidden(stage)
        }
        .focusedSceneValue(\.pipelineStage, stage)
    }
}

struct ZoomButtons: View {
    let stage: PipelineStage

    var body: some View {
        HStack(spacing: 2) {
            Button { stage.step(zoomingIn: false) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out (⌘-)")
            Button { stage.fit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Zoom to fit (⌘0), or double-click the background")
            Button { stage.step(zoomingIn: true) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in (⌘=)")
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.12)))
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
