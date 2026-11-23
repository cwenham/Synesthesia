import CodeEditing
import ContinuumKit
import Foundation
import LanguageClient
import MeepClient
import Simulation
import SwiftUI
import Testing
import TestSupport
@testable import SynesthesiaUI

/// `meep/verbs` and `Fetch.cs` as CodeEditingTests captured them, read from there.
private enum Captured {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("CodeEditingTests/Fixtures")

    static var verbs: [VerbEntry] {
        struct Reply: Decodable {
            struct Result: Decodable { var verbs: [VerbEntry] }
            var result: Result
        }
        let data = try! Data(contentsOf: fixtures.appendingPathComponent("verbs.json"))
        return try! JSONDecoder().decode(Reply.self, from: data).result.verbs.map { entry in
            var entry = entry
            let name = ((entry.source?.file ?? "") as NSString).lastPathComponent
            entry.source?.file = "/not/on/this/mac/" + name
            return entry
        }
    }

    static var fetch: Data { try! Data(contentsOf: fixtures.appendingPathComponent("Fetch.cs")) }
}

private struct OneFile: SourceFetching {
    let data: Data
    func fetch(_ url: URL) async throws -> Data {
        guard url.lastPathComponent == "Fetch.cs" else { throw SourceFetchError.status(404) }
        return data
    }
}

@MainActor
struct CodePaneTests {
    private func loaded(_ subject: CodeSubject) async -> CodeLevel {
        let level = CodeLevel(subject: subject, continuum: Continuum())
        await level.load(catalogue: Captured.verbs, library: SourceLibrary(cache: nil, fetcher: OneFile(data: Captured.fetch)))
        return level
    }

    private var prices: CodeSubject {
        CodeSubject(pipeline: MeepAddress(host: "local", pipeline: "orders"), key: "m3", label: "Prices", verb: "Fetch", resolved: ["HTTP"])
    }

    #if os(macOS)
    /// As the sidebar must (step 9), the code pane never makes the window's content taller than the window, in any of
    /// its states, at the narrow widths SwiftUI tries when sizing a window.
    @Test func theCodePaneNeverNeedsMoreHeightThanAWindowHas() async {
        let workspace = Workspace(continuum: Continuum())
        let reading = CodeLevel(subject: prices, continuum: Continuum())
        let shown = await loaded(prices)
        var remote = prices
        remote.isHere = false
        remote.hostTitle = "A host with a long name on another machine"
        let elsewhere = await loaded(remote)
        let failed = await loaded(CodeSubject(label: "Juggle", verb: "Juggle", hostTitle: "Lab", isHere: false))
        let batch = await loaded(CodeSubject(label: "Batch", verb: "Batch", resolved: ["Batch"]))
        for (name, level) in [("reading", reading), ("shown", shown), ("elsewhere", elsewhere), ("failed", failed), ("no source", batch)] {
            for width in [0.0, 40.0, 300.0] {
                let view = CodePane(code: level).environment(\.workspace, workspace)
                let least = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 0))
                #expect(least.height < 400, "\(name) at \(width) points wide needs \(least.height) points")
            }
        }
    }
    #endif

    @Test func theHeaderSaysWhatShowsAndWhereItCameFrom() async throws {
        let level = await loaded(prices)
        #expect(level.shownCode?.originText == "GitHub at 810c2fc, from its SourceLink")
        let editors = CodeEditors(installed: { [ExternalEditor(id: "com.jetbrains.rider", name: "Rider")] }, open: { _, _, _ in nil }, browse: { _ in })
        let view = CodeHeader(code: level)
            .environment(\.codeEditors, editors)
            .frame(width: 440)
            .background(Color(white: 0.075))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.height > 100)
        if let folder = ProcessInfo.processInfo.environment["SYNESTHESIA_SNAPSHOTS"] {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("code-header.png") as CFURL
            if let destination = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
    }

    @Test func theChosenEditorIsRememberedOrTheFirstInstalled() {
        let rider = ExternalEditor(id: "com.jetbrains.rider", name: "Rider")
        let code = ExternalEditor(id: "com.microsoft.VSCode", name: "VS Code")
        let editors = CodeEditors(installed: { [rider, code] }, open: { _, _, _ in nil }, browse: { _ in })
        #expect(editors.chosen("com.microsoft.VSCode") == code)
        #expect(editors.chosen("") == rider)
        #expect(editors.chosen("com.example.gone") == rider)
        let none = CodeEditors(installed: { [] }, open: { _, _, _ in nil }, browse: { _ in })
        #expect(none.chosen("com.jetbrains.rider") == nil)
    }

    /// The code belongs to the pipeline it was opened from: choosing another, or asking for the Meeplang, goes back.
    @Test(.simulatedHosts) func theCodeLevelGoesWhenThePipelineOrTextIsAskedFor() async throws {
        let continuum = Continuum()
        let host = continuum.add(host: "sim", title: "Simulated", kind: .simulated)
        let session = HostSession(host: host, settings: .init(replanEvery: .milliseconds(50), rateScale: 0.1)) {
            SimulatedHost(name: "sim", latency: .milliseconds(1))
        }
        session.start()
        defer { session.stop() }
        let deadline = ContinuousClock.now + .seconds(10)
        while host.pipeline("orders")?.graph == nil || host.pipeline("ticker")?.graph == nil {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
        let workspace = Workspace(continuum: continuum)
        let orders = try #require(host.pipeline("orders"))
        workspace.selection = orders.address
        let level = try #require(workspace.showCode(of: orders, host: host, at: "m3"))
        #expect(level.subject.verb == "Fetch")
        #expect(level.subject.resolved == ["HTTP"])
        #expect(level.subject.name == "Fetch.HTTP")
        #expect(workspace.showsText)
        #expect(workspace.code === level)
        // The same module again keeps it.
        #expect(workspace.showCode(of: orders, host: host, at: "m3") === level)

        workspace.showText(of: orders, at: "m3")
        #expect(workspace.code == nil)

        workspace.showCode(of: orders, host: host, at: "m3")
        workspace.selection = host.pipeline("ticker")?.address
        #expect(workspace.code == nil)
    }
}
