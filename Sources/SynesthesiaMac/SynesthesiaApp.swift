import AppKit
import CodeEditing
import ContinuumKit
import LanguageClient
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
    @AppStorage("showsText") private var showsText = false

    init() {
        // Hosts are followed and MCP is served from launch, whether or not the window is open: synesthesia-mcp may
        // start the app in the background.
        AppModel.shared.start()
        AppModel.shared.showSimulatedHost(UserDefaults.standard.object(forKey: "showsSimulatedHost") as? Bool ?? true)
        AppModel.shared.workspace.showsText = UserDefaults.standard.bool(forKey: "showsText")
    }

    var body: some Scene {
        // One window, whose selection the MCP server's tools can change.
        Window("Synesthesia", id: "main") {
            ContinuumView(workspace: model.workspace)
                .environment(\.canvasSurface, MacCanvas.provider)
                .environment(\.codeTextSurface, MacCodeText.provider)
                .frame(minWidth: 760, minHeight: 520)
                .onChange(of: showsSimulatedHost) { _, shows in model.showSimulatedHost(shows) }
                .onChange(of: model.workspace.showsText) { _, shows in showsText = shows }
        }
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(after: .sidebar) {
                Toggle("Show Simulated Host", isOn: $showsSimulatedHost)
                Toggle("Show Meeplang", isOn: Binding(get: { model.workspace.showsText }, set: { model.workspace.showsText = $0 }))
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Divider()
                ZoomCommands()
            }
            CommandGroup(replacing: .saveItem) {
                TextCommands()
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

    /// Text with changes that aren't saved is saved, or not, before quitting, as the person chooses.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let edited = AppModel.shared.workspace.editedDocuments
            guard !edited.isEmpty else { return .terminateNow }
            let alert = NSAlert()
            let names = edited.map { ($0.path as NSString).lastPathComponent }.sorted()
            alert.messageText = edited.count == 1 ? "Save the changes to \(names[0])?" : "Save the changes to \(edited.count) pipelines?"
            alert.informativeText = edited.count == 1 ? "They'll be lost if you don't." : "\(names.joined(separator: ", ")) have changes that will be lost if you don't."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don't Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do {
                    for document in edited { try document.save() }
                    return .terminateNow
                } catch {
                    NSAlert(error: error).runModal()
                    return .terminateCancel
                }
            case .alertThirdButtonReturn:
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
    }
}

/// Saving and reverting the text showing in the focused window.
struct TextCommands: View {
    @FocusedValue(\.meeplangDocument) private var document

    var body: some View {
        Button("Save") {
            do { try document?.save() } catch { NSAlert(error: error).runModal() }
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(document == nil || document?.isReadOnly == true || document?.isEdited == false)
        Button("Revert to Saved") { document?.revert() }
            .disabled(document?.isEdited != true)
    }
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
    /// The `meep lsp` the text uses, once started.
    @ObservationIgnored private let languageProcess = ProcessBox()

    private init() {
        continuum = Continuum()
        let box = languageProcess
        let language = LanguageService {
            // meep, wherever it's installed, started as `meep lsp`; a server that stopped is replaced.
            guard let meep = LanguageServerProcess.findMeep() else {
                throw LanguageServerError.stopped("Couldn't find meep. Put it on your PATH, or set MEEP_EXECUTABLE to it.")
            }
            let process = try LanguageServerProcess(executable: meep)
            box.replace(with: process)
            return try await MeepLanguageServer.start(over: process.stream)
        }
        workspace = Workspace(continuum: continuum, language: language)
    }

    /// Starts following this Mac's daemon, at `$MEEP_HOME/daemon/meep.sock` or `~/.meep/daemon/meep.sock`, and serving
    /// MCP.
    func start() {
        guard !started else { return }
        started = true
        mcp.start(viewer: AppViewer(workspace: workspace))
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [mcp, languageProcess] _ in
            MainActor.assumeIsolated { mcp.stop() }
            languageProcess.replace(with: nil)
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

/// Holds the running `meep lsp`, stopping the one it replaces.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: LanguageServerProcess?

    func replace(with new: LanguageServerProcess?) {
        let old = lock.withLock {
            defer { process = new }
            return process
        }
        old?.terminate()
    }
}
