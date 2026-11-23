import AppKit
import Assistant
import CodeEditing
import ContinuumKit
import LanguageClient
import MeepClient
import Foundation
import ImageIO
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

    func select(_ address: MeepAddress?) {
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

    func document(for pipeline: MeepPipeline) -> MeeplangDocument? {
        workspace.document(for: pipeline)
    }

    var showsText: Bool { workspace.showsText }

    var language: LanguageService? { workspace.language }

    func probes(for pipeline: MeepPipeline) -> [Probe] {
        workspace.probes(for: pipeline)
    }

    var code: CodeLevel? { workspace.code }

    var sources: SourceLibrary? { workspace.sources }

    func showCode(of pipeline: MeepPipeline, host: MeepHost, at key: String, inflection: String?) -> CodeLevel? {
        reveal()
        return workspace.showCode(of: pipeline, host: host, at: key, inflection: inflection)
    }

    /// Opens the pipeline with the message in the composer, and waits for the person to send it or not.
    func inject(_ body: InjectBody, into key: String, of pipeline: MeepPipeline, on host: MeepHost, timeout: Duration) async -> InjectionResult {
        reveal()
        let (text, isJSON): (String, Bool) = switch body {
        case .text(let text): (text, false)
        case .json(let json): (json.text(pretty: true), true)
        }
        workspace.compose(into: key, of: pipeline, body: text, isJSON: isJSON, askedBy: "Claude")
        guard let request = workspace.injection else { return .notSent }
        let outcome = await withTaskGroup(of: Workspace.InjectionOutcome?.self) { group in
            group.addTask { await self.workspace.outcome(of: request) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        switch outcome {
        case .sent(let injected)?: return .sent(injected)
        case .notSent?: return .notSent
        case nil: return .undecided
        }
    }

    /// Opens the pipeline with its text beside the canvas, shows the edits as a proposal, and waits for the person.
    func propose(_ edits: [MeepEdit], summary: String, to pipeline: MeepPipeline, on host: MeepHost, timeout: Duration) async throws -> ProposalResult {
        reveal()
        workspace.selection = pipeline.address
        workspace.showsText = true
        await workspace.openText(for: pipeline, host: host)
        guard let document = workspace.document(for: pipeline) else {
            throw ToolError(workspace.textProblems[pipeline.id] ?? "\(pipeline.name)'s text couldn't be opened.")
        }
        guard !document.isReadOnly else { throw ToolError("\(pipeline.name) is on \(host.title), whose text can't be edited here yet.") }
        guard await document.ready() else {
            throw ToolError(document.answer?.current == false
                ? "\(pipeline.name)'s text doesn't load as it is, so edits can't be made until the person mends it."
                : "The language server hasn't answered for \(pipeline.name) yet. Try again.")
        }
        let proposal: MeeplangDocument.Proposal
        do {
            proposal = try await document.propose(edits, summary: summary)
        } catch {
            throw ToolError(error.localizedDescription)
        }
        let outcome = await withTaskGroup(of: MeeplangDocument.ProposalOutcome?.self) { group in
            group.addTask { await document.decision(on: proposal) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        switch outcome {
        case .accepted(let keys)?: return .accepted(added: keys)
        case .rejected?: return .rejected
        case .withdrawn?: return .withdrawn
        case nil: return .undecided
        }
    }

    var canvas: ContinuumStage? { workspace.canvas }

    /// The canvas as it's drawn now. A window that's covered doesn't draw, so a canvas that hasn't been drawn yet is
    /// drawn here, at the size of the window's canvas when it's known.
    func canvasImage() -> CGImage? {
        let canvas = workspace.canvas
        guard let renderer = MacCanvas.renderer else { return nil }
        let size = canvas.currentViewSize.width > 0 ? canvas.currentViewSize : CGSize(width: 1400, height: 860)
        let snapshot = canvas.frame(at: CACurrentMediaTime(), viewSize: size)
        let image = renderer.image(of: snapshot, size: size, pixelScale: NSScreen.main?.backingScaleFactor ?? 2)
        if let image, let folder = ProcessInfo.processInfo.environment["SYNESTHESIA_CAPTURES"], !folder.isEmpty {
            WindowCapture.save(canvas: image, to: folder)
        }
        return image
    }
}

/// Serves the tools over MCP on the app's socket, for as long as the app runs (design, section 8). Each connection,
/// such as one Claude Code session through `synesthesia-mcp`, gets its own session.
@MainActor
final class MCPService {
    private var server: UnixSocketServer?
    /// Why it isn't serving, if it isn't.
    private(set) var problem: String?

    /// Serves the tools in `registry`: the same ones the Claude sidebar uses.
    func start(registry: ToolRegistry) {
        guard server == nil else { return }
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

/// With `SYNESTHESIA_CAPTURES` naming a folder, each capture_view also saves the whole window there, as the app draws
/// it: its views, with the Metal canvas drawn in where it is. It needs no screen recording, so a step can be looked at
/// while the window is covered.
@MainActor
enum WindowCapture {
    private static var count = 0

    static func save(canvas: CGImage, to folder: String) {
        count += 1
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        write(canvas, to: URL(fileURLWithPath: folder).appendingPathComponent("canvas-\(count).png"))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let views = rep.cgImage else { return }
        let scale = CGFloat(views.width) / content.bounds.width
        guard let context = CGContext(
            data: nil, width: views.width, height: views.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        // The window's own background first: parts drawn with vibrancy leave it clear.
        var background = NSColor.windowBackgroundColor.cgColor
        window.effectiveAppearance.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.cgColor }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: views.width, height: views.height))
        context.draw(views, in: CGRect(x: 0, y: 0, width: views.width, height: views.height))
        if let view = find(CanvasMTKView.self, in: content) {
            // The canvas's frame in the content view, with y up, as Core Graphics has it.
            let frame = view.convert(view.bounds, to: content)
            let flipped = content.isFlipped ? CGRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height) : frame
            context.draw(canvas, in: CGRect(x: flipped.minX * scale, y: flipped.minY * scale, width: flipped.width * scale, height: flipped.height * scale))
        }
        if let whole = context.makeImage() {
            write(whole, to: URL(fileURLWithPath: folder).appendingPathComponent("window-\(count).png"))
        }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        for child in view.subviews {
            if let found = find(type, in: child) { return found }
        }
        return nil
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
