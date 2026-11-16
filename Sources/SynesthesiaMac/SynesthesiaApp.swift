import AppKit
import ContinuumKit
import MeepClient
import Observation
import Simulation
import Stage
import SwiftUI
import SynesthesiaUI

@main
struct SynesthesiaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel.shared
    @AppStorage("showsSimulatedHost") private var showsSimulatedHost = true

    init() {
        // Hosts are followed and MCP is served from launch, whether or not the window is open: synesthesia-mcp may
        // start the app in the background.
        AppModel.shared.start()
        AppModel.shared.showSimulatedHost(UserDefaults.standard.object(forKey: "showsSimulatedHost") as? Bool ?? true)
    }

    var body: some Scene {
        // One window, whose selection the MCP server's tools can change.
        Window("Synesthesia", id: "main") {
            ContinuumView(workspace: model.workspace)
                .environment(\.canvasSurface, MacCanvas.provider)
                .frame(minWidth: 760, minHeight: 520)
                .onChange(of: showsSimulatedHost) { _, shows in model.showSimulatedHost(shows) }
        }
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(after: .sidebar) {
                Toggle("Show Simulated Host", isOn: $showsSimulatedHost)
                Divider()
                ZoomCommands()
            }
            CommandGroup(after: .appInfo) {
                Button("Copy Claude Code Setup Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MCPService.claudeCodeCommand, forType: .string)
                }
                .help("Copies the command that adds Synesthesia's MCP server to Claude Code, to paste in a terminal.")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app keeps following hosts and serving MCP with its window closed; clicking its Dock icon opens it again.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Zooming the canvas in the focused window.
struct ZoomCommands: View {
    @FocusedValue(\.pipelineStage) private var stage

    var body: some View {
        Button("Zoom In") { stage?.step(zoomingIn: true) }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(stage == nil)
        Button("Zoom Out") { stage?.step(zoomingIn: false) }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(stage == nil)
        Button("Zoom to Fit") { stage?.fit() }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(stage == nil)
    }
}

/// The Continuum this Mac starts with, and the sessions keeping its hosts up to date.
@MainActor @Observable
final class AppModel {
    /// The app's one model, made at launch.
    static let shared = AppModel()

    let continuum: Continuum
    let workspace: Workspace
    @ObservationIgnored private var sessions: [String: HostSession] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private let mcp = MCPService()

    private init() {
        continuum = Continuum()
        workspace = Workspace(continuum: continuum)
    }

    /// Starts following this Mac's daemon, at `$MEEP_HOME/daemon/meep.sock` or `~/.meep/daemon/meep.sock`, and serving
    /// MCP.
    func start() {
        guard !started else { return }
        started = true
        mcp.start(viewer: AppViewer(workspace: workspace))
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [mcp] _ in
            MainActor.assumeIsolated { mcp.stop() }
        }
        let socket = DaemonConnection.defaultSocketPath
        let local = continuum.add(host: "local", title: "This Mac", kind: .local(socketPath: socket))
        follow(local) { try await DaemonConnection.connect(socketPath: socket) }
    }

    /// Adds or removes the pretend host, which shows what the views do with busier pipelines than you may have.
    func showSimulatedHost(_ shows: Bool) {
        if shows, sessions["simulated"] == nil {
            let host = continuum.add(host: "simulated", title: "Simulated", kind: .simulated)
            follow(host) { SimulatedHost(name: "simulated") }
        } else if !shows, let session = sessions.removeValue(forKey: "simulated") {
            session.stop()
            continuum.remove(host: "simulated")
        }
    }

    private func follow(_ host: MeepHost, connect: @escaping @Sendable () async throws -> any HostLink) {
        let session = HostSession(host: host, connect: connect)
        sessions[host.name] = session
        session.start()
    }
}
