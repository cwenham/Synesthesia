import AppKit
import Assistant
import CodeEditing
import ContinuumKit
import LanguageClient
import MeepClient
import Observation
import Simulation
import Stage
import SwiftUI
import SynesthesiaUI
import Transport

@main
struct SynesthesiaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel.shared
    @AppStorage("showsSimulatedHost") private var showsSimulatedHost = true
    @AppStorage("showsText") private var showsText = false
    @AppStorage("showsClaude") private var showsClaude = false
    @AppStorage(SettingsTab.key) private var settingsTab = SettingsTab.canvas.rawValue
    @AppStorage(CanvasLook.starfieldKey) private var showsStarfield = true

    init() {
        // Writing to a tunnel or language server that has ended fails rather than ending the app.
        signal(SIGPIPE, SIG_IGN)
        // Hosts are followed and MCP is served from launch, whether or not the window is open: synesthesia-mcp may
        // start the app in the background.
        AppModel.shared.start()
        AppModel.shared.showSimulatedHost(UserDefaults.standard.object(forKey: "showsSimulatedHost") as? Bool ?? true)
        AppModel.shared.workspace.showsText = UserDefaults.standard.bool(forKey: "showsText")
        AppModel.shared.workspace.showsClaude = UserDefaults.standard.bool(forKey: "showsClaude")
        // The canvas's look, with the person's settings, and still stars when the system asks for less motion.
        CanvasLook.reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CanvasLook.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { CanvasLook.reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        }
    }

    var body: some Scene {
        // One window, whose selection the MCP server's tools can change.
        Window("Synesthesia", id: "main") {
            ContinuumView(workspace: model.workspace)
                .environment(\.canvasSurface, MacCanvas.provider)
                .environment(\.codeTextSurface, MacCodeText.provider)
                .environment(\.hostManaging, model)
                .environment(\.claude, model.claude)
                .frame(minWidth: 760, minHeight: 520)
                .onChange(of: showsSimulatedHost) { _, shows in model.showSimulatedHost(shows) }
                .onChange(of: model.workspace.showsText) { _, shows in showsText = shows }
                .onChange(of: model.workspace.showsClaude) { _, shows in showsClaude = shows }
        }
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(after: .sidebar) {
                Toggle("Show Simulated Host", isOn: $showsSimulatedHost)
                Toggle("Show Meeplang", isOn: Binding(get: { model.workspace.showsText }, set: { model.workspace.showsText = $0 }))
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Toggle("Show Claude", isOn: Binding(get: { model.workspace.showsClaude }, set: { model.workspace.showsClaude = $0 }))
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Toggle("Show Starfield", isOn: $showsStarfield)
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

        Settings {
            TabView(selection: $settingsTab) {
                CanvasSettingsView()
                    .tabItem { Label("Canvas", systemImage: "sparkle") }
                    .tag(SettingsTab.canvas.rawValue)
                ClaudeSettingsView(chat: model.claude)
                    .tabItem { Label("Claude", systemImage: "sparkles") }
                    .tag(SettingsTab.claude.rawValue)
            }
            .frame(width: 480)
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
    @FocusedValue(\.continuumStage) private var canvas

    var body: some View {
        Button("Zoom In") { canvas?.step(zoomingIn: true) }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(canvas == nil)
        Button("Zoom Out") { canvas?.step(zoomingIn: false) }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(canvas == nil)
        Button("Zoom to Fit") { canvas?.fit() }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(canvas == nil)
        Button("Show Every Host") { canvas?.show(nil) }
            .keyboardShortcut("0", modifiers: [.command, .shift])
            .disabled(canvas == nil)
    }
}

/// The Continuum this Mac starts with, and the sessions keeping its hosts up to date.
@MainActor @Observable
final class AppModel: HostManaging {
    /// The app's one model, made at launch.
    static let shared = AppModel()

    let continuum: Continuum
    let workspace: Workspace
    /// The Claude sidebar's conversation, with the same tools the MCP server offers.
    let claude: ClaudeChat
    @ObservationIgnored private let viewer: AppViewer
    @ObservationIgnored private let tools: ToolRegistry
    @ObservationIgnored private var sessions: [String: HostSession] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private let mcp = MCPService()
    /// The `meep lsp` the text uses, once started.
    @ObservationIgnored private let languageProcess = ProcessBox()
    /// The hosts the person added, and budgets they set, kept between runs.
    @ObservationIgnored private var store = HostStore.load()
    @ObservationIgnored private let tunnels = SSHTunnelProvider()

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
        let viewer = AppViewer(workspace: workspace)
        self.viewer = viewer
        // One set of tools, two ways in (design, section 8): MCP and the sidebar.
        tools = ContinuumTools.registry(for: viewer)
        claude = ClaudeChat(registry: tools, key: ClaudeKey(store: KeychainStore())) { SidebarPrompt.context(viewer) }
        if let saved = UserDefaults.standard.string(forKey: ClaudeSettingsView.effortKey), let effort = Effort(rawValue: saved) {
            claude.effort = effort
        }
    }

    /// Starts following this Mac's daemon, at `$MEEP_HOME/daemon/meep.sock` or `~/.meep/daemon/meep.sock`, and serving
    /// MCP.
    func start() {
        guard !started else { return }
        started = true
        mcp.start(registry: tools)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [mcp, languageProcess] _ in
            MainActor.assumeIsolated { mcp.stop() }
            languageProcess.replace(with: nil)
        }
        let socket = DaemonConnection.defaultSocketPath
        let local = continuum.add(host: "local", title: "This Mac", kind: .local(socketPath: socket))
        follow(local) { try await DaemonConnection.connect(socketPath: socket) }
        for remote in store.remotes { followRemote(remote) }
    }

    /// Adds or removes the pretend host, which shows what the views do with busier pipelines than you may have.
    func showSimulatedHost(_ shows: Bool) {
        if shows, sessions["simulated"] == nil {
            let host = continuum.add(host: "simulated", title: "Simulated", kind: .simulated)
            follow(host) { SimulatedHost(name: "simulated", clockSkew: .milliseconds(1200)) }
        } else if !shows, let session = sessions.removeValue(forKey: "simulated") {
            session.stop()
            continuum.remove(host: "simulated")
        }
    }

    private func follow(_ host: MeepHost, connect: @escaping @Sendable () async throws -> any HostLink) {
        if let saved = store.budgets[host.name] { host.budget = saved > 0 ? saved : nil }
        let session = HostSession(host: host, connect: connect)
        sessions[host.name] = session
        session.start()
    }

    // MARK: Hosts on other machines

    /// Follows a host through a tunnel: ssh forwards its daemon's socket to one here, and the connection closes the
    /// tunnel when it closes. A new tunnel is made each time the host is tried again.
    private func followRemote(_ remote: HostStore.Remote) {
        let host = continuum.add(host: remote.name, title: remote.title, kind: .remote(remote.target))
        host.budget = remote.budget
        let tunnels = tunnels
        let target = remote.target
        let session = HostSession(host: host) {
            let tunnel = try await tunnels.open(target)
            do {
                let connection = try await DaemonConnection.open(over: tunnel.connect())
                await connection.onClose { tunnel.close() }
                await MainActor.run { host.route = tunnel.route }
                if let expected = tunnel.expectedID, let id = try await connection.info().id, id != expected {
                    // Another daemon answered than the one meep daemon socket named, as when one has just restarted
                    // with a new ID; it's still the host's daemon, so follow it, but say so.
                    await MainActor.run { host.route = (host.route ?? "") + "; its daemon's ID changed to \(id)" }
                }
                return connection
            } catch {
                tunnel.close()
                throw error
            }
        }
        sessions[host.name] = session
        session.start()
    }

    func addRemoteHost(title: String, target: SSHTarget, budget: Double?) {
        let taken = Set(continuum.hosts.map(\.name))
        let remote = HostStore.Remote(name: HostStore.name(for: title, taken: taken), title: title, target: target, budget: budget)
        store.remotes.append(remote)
        try? store.save()
        followRemote(remote)
        workspace.selection = MeepAddress(host: remote.name)
    }

    func removeHost(_ host: MeepHost) {
        sessions.removeValue(forKey: host.name)?.stop()
        continuum.remove(host: host.name)
        store.remotes.removeAll { $0.name == host.name }
        try? store.save()
        if workspace.selection?.host == host.name { workspace.selection = nil }
    }

    func budgetChanged(_ host: MeepHost) {
        if let index = store.remotes.firstIndex(where: { $0.name == host.name }) {
            store.remotes[index].budget = host.budget
        } else {
            store.budgets[host.name] = host.budget ?? 0
        }
        try? store.save()
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
