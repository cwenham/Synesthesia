import AppKit
import Assistant
import ContinuumKit
import Foundation
import QuartzCore
import Stage
import SynesthesiaUI
import Transport

/// What the tools see of the app: its workspace, and the canvas drawn with the app's renderer.
@MainActor
final class AppViewer: Viewer {
    let workspace: Workspace

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    var continuum: Continuum { workspace.continuum }
    var selection: MeepAddress? { workspace.selection }
    var stage: PipelineStage? { workspace.stage }

    func select(_ address: MeepAddress) {
        workspace.selection = address
    }

    /// Asks Launch Services to open the app again, without activating it, which reopens its window if it's closed,
    /// as when synesthesia-mcp started the app in the background.
    func reveal() {
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
    }

    func canvasImage() -> CGImage? {
        guard let stage, let renderer = MacCanvas.renderer, stage.currentViewSize.width > 0 else { return nil }
        let snapshot = stage.frame(at: CACurrentMediaTime(), viewSize: stage.currentViewSize)
        return renderer.image(of: snapshot, size: stage.currentViewSize, pixelScale: NSScreen.main?.backingScaleFactor ?? 2)
    }
}

/// Serves the tools over MCP on the app's socket, for as long as the app runs (design, section 8). Each connection,
/// such as one Claude Code session through `synesthesia-mcp`, gets its own session.
@MainActor
final class MCPService {
    private var server: UnixSocketServer?
    /// Why it isn't serving, if it isn't.
    private(set) var problem: String?

    func start(viewer: AppViewer) {
        guard server == nil else { return }
        let registry = ContinuumTools.registry(for: viewer)
        let info = MCPSession.ServerInfo(
            name: "synesthesia", title: "Synesthesia", version: Bundle.main.shortVersion, instructions: ContinuumTools.instructions
        )
        do {
            server = try UnixSocketServer.listen(path: MCPSocket.defaultPath) { stream in
                Task { await MCPSession(stream: stream, registry: registry, info: info).run() }
            }
            problem = nil
        } catch {
            problem = error.localizedDescription
            FileHandle.standardError.write(Data("Synesthesia isn't serving MCP: \(error.localizedDescription)\n".utf8))
        }
    }

    func stop() {
        server?.close()
        server = nil
    }

    /// The command that adds this app's MCP server to Claude Code.
    static var claudeCodeCommand: String {
        let bridge = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/synesthesia-mcp").path
        return "claude mcp add synesthesia -- '\(bridge)'"
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
