import ContinuumKit
import MeepClient
import Stage
import SwiftUI

// Flows between pipelines and the boundary, beside the canvas: hover cards for a flow and an endpoint, and the tables
// the docks show at the host, mesh and boundary levels.

/// A flow between pipelines beside the pointer: its ends, how it's known, and what it carries.
struct FlowCard: View {
    let flow: MeshFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(flow.fromLabel) → \(flow.toLabel)").font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(flow.crossesHosts ? "From \(flow.from.host) to \(flow.to.host)" : "On \(flow.from.host)").foregroundStyle(.secondary)
            Text(flow.evidence.prefix(1).uppercased() + flow.evidence.dropFirst()).font(.caption).foregroundStyle(flow.observed ? .secondary : Color.orange)
            if flow.observed {
                Divider()
                FlowNumbers(rate: flow.rate, replies: flow.replies, failed: flow.failed, rejected: flow.rejected, bytesOut: flow.bytesOut, bytesBack: flow.bytesBack)
            } else {
                Text("Its address matches the Listen's, so this is where it would go. Nothing has been seen to cross yet.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Double-click to see both ends.").font(.caption).foregroundStyle(.secondary)
        }
        .cardStyle()
    }
}

/// The flows between two hosts drawn as nodes, added up.
struct HostFlowCard: View {
    let from: String
    let to: String
    let flows: [MeshFlow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(from) → \(to)").font(.headline)
            Text("\(flows.count) flow\(flows.count == 1 ? "" : "s") between their pipelines").foregroundStyle(.secondary)
            Divider()
            FlowNumbers(
                rate: flows.reduce(0) { $0 + $1.rate }, replies: flows.reduce(0) { $0 + $1.replies },
                failed: flows.reduce(0) { $0 + $1.failed }, rejected: flows.reduce(0) { $0 + $1.rejected },
                bytesOut: flows.reduce(0) { $0 + $1.bytesOut }, bytesBack: flows.reduce(0) { $0 + $1.bytesBack }
            )
            ForEach(flows.prefix(6)) { flow in
                Text("\(flow.fromLabel) → \(flow.toLabel)  \(flow.observed ? StageFormat.rate(flow.rate) : "declared")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if flows.count > 6 { Text("and \(flows.count - 6) more").font(.caption).foregroundStyle(.secondary) }
            Text("Double-click to see both hosts.").font(.caption).foregroundStyle(.secondary)
        }
        .cardStyle()
    }
}

/// What a flow or a link to the boundary carries: messages and replies, failures and rejections, and bytes.
struct FlowNumbers: View {
    let rate: Double
    let replies: Double
    let failed: Double
    let rejected: Double
    let bytesOut: Double
    let bytesBack: Double

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
            row("Messages", Format.rate(rate) + "/s")
            row("Replies back", Format.rate(replies) + "/s")
            if failed > 0.005 { row("Failing", Format.rate(failed) + "/s", tint: .red) }
            if rejected > 0.005 { row("Turned away (4xx)", Format.rate(rejected) + "/s", tint: .orange) }
            if bytesOut + bytesBack > 0 { row("Bytes", "\(StageFormat.bytes(bytesOut))/s there, \(StageFormat.bytes(bytesBack))/s back") }
        }
    }

    private func row(_ name: String, _ value: String, tint: Color? = nil) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).monospacedDigit().foregroundStyle(tint ?? .primary)
        }
    }
}

/// An endpoint on the boundary beside the pointer: what it is, its rates, and each module that talks to it.
struct EndpointCard: View {
    let endpoint: BoundaryEndpoint

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(endpoint.name).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(kind).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !endpoint.places.isEmpty, endpoint.kind == .outside {
                Text(endpoint.places.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                GridRow { Text("In").foregroundStyle(.secondary); Text(Format.rate(endpoint.rateIn) + "/s").monospacedDigit() }
                GridRow { Text("Out").foregroundStyle(.secondary); Text(Format.rate(endpoint.rateOut) + "/s").monospacedDigit() }
                if endpoint.failed > 0.005 {
                    GridRow { Text("Failing").foregroundStyle(.secondary); Text(Format.rate(endpoint.failed) + "/s").monospacedDigit().foregroundStyle(.red) }
                }
                if endpoint.rejected > 0.005 {
                    GridRow { Text("Turned away (4xx)").foregroundStyle(.secondary); Text(Format.rate(endpoint.rejected) + "/s").monospacedDigit().foregroundStyle(.orange) }
                }
                if endpoint.bytesIn + endpoint.bytesOut > 0 {
                    GridRow {
                        Text("Bytes").foregroundStyle(.secondary)
                        Text("\(StageFormat.bytes(endpoint.bytesIn))/s in, \(StageFormat.bytes(endpoint.bytesOut))/s out").monospacedDigit()
                    }
                }
            }
            Divider()
            ForEach(endpoint.links.prefix(8)) { link in
                Text(describe(link)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(describe(link))
            }
            if endpoint.links.count > 8 { Text("and \(endpoint.links.count - 8) more").font(.caption).foregroundStyle(.secondary) }
            Text("Double-click to see it with what it talks to.").font(.caption).foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var kind: String {
        switch endpoint.kind {
        case .outside: endpoint.isDeclaredOnly ? "Outside Meep, declared by a Fetch or Send; nothing sent yet" : "Outside Meep, in \(endpoint.domain)"
        case .otherMeep: "A Meep daemon Synesthesia doesn't follow, or a meep run"
        case .pastLimit: "Everything past modules' limits on places, and what was folded there"
        }
    }

    private func describe(_ link: BoundaryLink) -> String {
        let arrow = link.direction == .inbound ? "→" : "←"
        let rate = link.observed ? "\(Format.rate(link.rate))/s" : "declared"
        return "\(arrow) \(link.module.host) › \(link.moduleLabel)  \(rate)"
    }
}

/// Every flow touching what's shown, in a table: its ends, how it's known, and its rates.
struct FlowsTable: View {
    let flows: [MeshFlow]

    var body: some View {
        if flows.isEmpty {
            EmptyDockMessage(text: "No flows between pipelines yet. A Fetch or Send whose address reaches a known host's Listen shows here, dashed until messages are seen to cross.")
        } else {
            Table(flows) {
                TableColumn("From") { flow in Text("\(flow.from.host) › \(flow.fromLabel)").help(flow.from.description) }
                TableColumn("To") { flow in Text("\(flow.to.host) › \(flow.toLabel)").help(flow.to.description) }
                TableColumn("Known") { flow in Text(flow.evidence).foregroundStyle(flow.observed ? .primary : Color.orange) }
                    .width(min: 80, ideal: 150)
                TableColumn("Messages/s") { flow in Rate(value: flow.observed ? flow.rate : nil) }
                    .width(min: 60, ideal: 80)
                TableColumn("Failing/s") { flow in Rate(value: flow.observed ? flow.failed : nil) }
                    .width(min: 50, ideal: 64)
                TableColumn("4xx/s") { flow in Rate(value: flow.observed ? flow.rejected : nil) }
                    .width(min: 40, ideal: 56)
                TableColumn("Bytes/s") { flow in
                    Text(flow.observed ? StageFormat.bytes(flow.bytesOut + flow.bytesBack) : "—").monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 50, ideal: 70)
            }
        }
    }
}

/// Every endpoint on the boundary, grouped by domain: what it is, its rates, and how many modules talk to it.
struct BoundaryTable: View {
    let endpoints: [BoundaryEndpoint]

    var body: some View {
        if endpoints.isEmpty {
            EmptyDockMessage(text: "Nothing outside Meep yet. Clients of Listens, and APIs that Fetches and Sends reach, show here once they're counted.")
        } else {
            Table(endpoints.sorted { ($0.domain, $0.name) < ($1.domain, $1.name) }) {
                TableColumn("Endpoint") { endpoint in Text(endpoint.name).help(endpoint.places.joined(separator: ", ")) }
                TableColumn("Group") { endpoint in Text(endpoint.domain.isEmpty ? "—" : endpoint.domain).foregroundStyle(.secondary) }
                    .width(min: 70, ideal: 120)
                TableColumn("In/s") { endpoint in Rate(value: endpoint.isDeclaredOnly ? nil : endpoint.rateIn) }
                    .width(min: 44, ideal: 60)
                TableColumn("Out/s") { endpoint in Rate(value: endpoint.isDeclaredOnly ? nil : endpoint.rateOut) }
                    .width(min: 44, ideal: 60)
                TableColumn("Failing/s") { endpoint in Rate(value: endpoint.isDeclaredOnly ? nil : endpoint.failed) }
                    .width(min: 50, ideal: 64)
                TableColumn("4xx/s") { endpoint in Rate(value: endpoint.isDeclaredOnly ? nil : endpoint.rejected) }
                    .width(min: 40, ideal: 56)
                TableColumn("Talks to") { endpoint in
                    let modules = Set(endpoint.links.map { "\($0.module.host) › \($0.moduleLabel)" }).sorted()
                    Text(modules.joined(separator: ", ")).foregroundStyle(.secondary).help(modules.joined(separator: "\n"))
                }
            }
        }
    }
}

/// A short message filling a dock's space below its tabs, as a tab with nothing in it yet shows.
struct EmptyDockMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 520, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Under the canvas at the mesh and boundary levels: the hosts, the flows between their pipelines, and the boundary,
/// with tabs that stay at the top whichever is showing.
struct MeshDock: View {
    let continuum: Continuum
    let canvas: ContinuumStage
    @Binding var selection: MeepAddress?
    @AppStorage("meshDockTab") private var tab = "hosts"

    var body: some View {
        let map = canvas.flowMap
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Show", selection: $tab) {
                    Text("Hosts").tag("hosts")
                    Text(map.flows.isEmpty ? "Flows" : "Flows (\(map.flows.count))").tag("flows")
                    Text(map.boundary.isEmpty ? "Boundary" : "Boundary (\(map.boundary.count))").tag("boundary")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            switch tab {
            case "flows": FlowsTable(flows: map.flows)
            case "boundary": BoundaryTable(endpoints: map.boundary)
            default: HostsTable(continuum: continuum, selection: $selection)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Drawing back to the boundary shows its table; coming in again, the hosts'.
        .onChange(of: canvas.level) { _, level in
            if level == .boundary { tab = "boundary" } else if tab == "boundary" { tab = "hosts" }
        }
    }
}

/// Under the canvas at the host level: its pipelines, and the flows into and out of them and to the boundary.
struct HostDock: View {
    let host: MeepHost
    let canvas: ContinuumStage
    @Binding var selection: MeepAddress?
    @AppStorage("hostDockTab") private var tab = "pipelines"

    var body: some View {
        let map = canvas.flowMap
        let flows = map.flows(touching: host.address)
        let boundary = map.boundary.filter { endpoint in endpoint.links.contains { $0.module.host == host.name } }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Show", selection: $tab) {
                    Text("Pipelines").tag("pipelines")
                    Text(flows.isEmpty ? "Flows" : "Flows (\(flows.count))").tag("flows")
                    Text(boundary.isEmpty ? "Boundary" : "Boundary (\(boundary.count))").tag("boundary")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            switch tab {
            case "flows": FlowsTable(flows: flows)
            case "boundary": BoundaryTable(endpoints: boundary)
            default: HostPipelinesTable(host: host, selection: $selection)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
