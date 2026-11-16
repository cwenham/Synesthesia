import ContinuumKit
import MeepClient
import Observation
import Simulation
import SwiftUI
import SynesthesiaUI

@main
struct SynesthesiaApp: App {
    @State private var model = AppModel()
    @AppStorage("showsSimulatedHost") private var showsSimulatedHost = true

    var body: some Scene {
        WindowGroup("Synesthesia") {
            ContinuumView(continuum: model.continuum)
                .frame(minWidth: 760, minHeight: 420)
                .task {
                    model.start()
                    model.showSimulatedHost(showsSimulatedHost)
                }
                .onChange(of: showsSimulatedHost) { _, shows in model.showSimulatedHost(shows) }
        }
        .commands {
            CommandGroup(after: .sidebar) {
                Toggle("Show Simulated Host", isOn: $showsSimulatedHost)
            }
        }
    }
}

/// The Continuum this Mac starts with, and the sessions keeping its hosts up to date.
@MainActor @Observable
final class AppModel {
    let continuum = Continuum()
    @ObservationIgnored private var sessions: [String: HostSession] = [:]
    @ObservationIgnored private var started = false

    /// Starts following this Mac's daemon, at `$MEEP_HOME/daemon/meep.sock` or `~/.meep/daemon/meep.sock`.
    func start() {
        guard !started else { return }
        started = true
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
