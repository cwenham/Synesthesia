import ContinuumKit
import Foundation
import LanguageClient
import MeepClient
import Simulation
import Stage
import Testing
import TestSupport
@testable import SynesthesiaUI

struct NewModuleTests {
    private func verb(_ json: String) throws -> VerbEntry {
        try JSONDecoder().decode(VerbEntry.self, from: Data(json.utf8))
    }

    @Test func aNewModulesLineHasItsValuesQuotedWhereTheyAreText() throws {
        let fetch = try verb("""
            {"verb": "Fetch", "inflection": "HTTP", "role": "step", "kind": "inflection", "takes": [], "emits": [],
             "parameters": [
               {"name": "url", "type": "text", "positional": true, "required": true, "perMessage": true},
               {"name": "timeout", "type": "duration", "positional": false, "required": false, "perMessage": false, "default": "1m40s"}]}
            """)
        #expect(NewModule.line(for: fetch, values: ["url": "https://example.com", "timeout": "5s"], name: "Check")
            == #"Fetch.HTTP "https://example.com" timeout=5s as Check"#)
        // Already quoted, or left out, it's written as given.
        #expect(NewModule.line(for: fetch, values: ["url": #""{msg.Url}""#], name: nil) == #"Fetch.HTTP "{msg.Url}""#)
        let interval = try verb("""
            {"verb": "Interval", "inflection": "Interval", "role": "source", "kind": "source", "takes": [], "emits": [],
             "parameters": [{"name": "period", "type": "duration", "positional": true, "required": true, "perMessage": false}]}
            """)
        #expect(NewModule.line(for: interval, values: ["period": "1s"], name: "") == "Interval 1s")
    }

    @Test func editsAreSaidInWords() {
        #expect(EditWords.describe(.insert("Where x", after: "m3")) == "insert Where x after m3")
        #expect(EditWords.describe(.setModifier("+0", "buffer", to: "10")) == "set @buffer=10 on the module edit 1 adds")
        #expect(EditWords.describe(.removeBranch("m4")) == "remove m4 and everything under it")
    }
}

@MainActor
@Suite(.simulatedHosts)
struct SavedProbeTests {
    @Test func savedProbesOpenAgainWithThePipelineFindingMovedModulesByName() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("synesthesia-saved-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("ticker.meep").path
        var spec = try #require(PipelineSpec.demo.first { $0.name == "ticker" })
        spec.path = path
        let ticker = spec
        let continuum = Continuum()
        let host = continuum.add(host: "local", kind: .local(socketPath: "/nowhere"))
        let session = HostSession(host: host, settings: .init(leastDetail: .modules, replanEvery: .milliseconds(50), rateScale: 0.1)) {
            SimulatedHost(name: "local", latency: .milliseconds(1), pipelines: [ticker])
        }
        session.start()
        defer { session.stop() }
        let deadline = ContinuousClock.now + .seconds(10)
        while host.pipeline("ticker")?.graph == nil || host.link == nil {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pipeline = try #require(host.pipeline("ticker"))
        let first = try #require(pipeline.modules.first)
        // One saved by a key that's now another's name, one by a key that has gone.
        try ProbeStore.save([
            ProbeStore.Saved(file: "ticker.meep", target: .module(first.key), label: "\(first.label) out", condition: "", sample: 0.5),
            ProbeStore.Saved(file: "ticker.meep", target: .module("m99"), label: "\(first.label) out", condition: "", sample: 1),
            ProbeStore.Saved(file: "ticker.meep", target: .module("m98"), label: "Gone out", condition: "", sample: 1),
        ], for: path)
        let workspace = Workspace(continuum: continuum)
        workspace.openSavedProbes(for: pipeline, host: host)
        let probes = workspace.probes(for: pipeline)
        // The first and second are the same probe now, so it's opened once; the gone one isn't.
        #expect(probes.count == 1)
        #expect(probes.allSatisfy { $0.isSaved && $0.target == .module(first.key) })
        #expect(probes.first?.sample == 0.5)
        // Opened once only.
        workspace.openSavedProbes(for: pipeline, host: host)
        #expect(workspace.probes(for: pipeline).count == probes.count)
        workspace.setProbesRunning(false, for: pipeline)
        #expect(probes.allSatisfy { $0.state == .paused })
    }
}

@MainActor
@Suite(.simulatedHosts)
struct DropTests {
    private func editing() async throws -> (PipelineEditor, PipelineStage, Workspace, HostSession) {
        let continuum = Continuum()
        let host = continuum.add(host: "sim", kind: .simulated)
        let session = HostSession(host: host, settings: .init(leastDetail: .modules, replanEvery: .milliseconds(50), rateScale: 0.1)) {
            SimulatedHost(name: "sim", latency: .milliseconds(1))
        }
        session.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while host.pipeline("warehouse")?.links.isEmpty != false {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pipeline = try #require(host.pipeline("warehouse"))
        let stage = PipelineStage(pipeline: pipeline, host: host)
        let workspace = Workspace(continuum: continuum)
        return (PipelineEditor(pipeline: pipeline, host: host, stage: stage, workspace: workspace), stage, workspace, session)
    }

    @Test func aMessageDroppedOnAWireIsSentToItsTarget() async throws {
        let (editor, stage, workspace, session) = try await editing()
        defer { session.stop() }
        let link = try #require(stage.links.first)
        #expect(editor.drop(MessageDrag.prefix + #"{"Count": 1}"#, on: .wire(link.key)))
        #expect(workspace.injection?.key == link.to)
        #expect(workspace.injection?.isJSON == true)
        #expect(workspace.injection?.body == #"{"Count": 1}"#)

        let tile = try #require(stage.modules.first)
        #expect(editor.drop(MessageDrag.prefix + "{}", on: .tile(tile.key)))
        #expect(workspace.injection?.key == tile.key)

        // On the background there's nowhere to send it, and it says so.
        #expect(!editor.drop(MessageDrag.prefix + "{}", on: nil))
        #expect(editor.notice?.text.contains("tile") == true)
        // Anything else isn't taken.
        #expect(!editor.drop("just some text", on: .tile(tile.key)))
    }

    @Test func aTileDroppedWhereItCantGoSaysWhatDragsDo() async throws {
        let (editor, stage, _, session) = try await editing()
        defer { session.stop() }
        let tile = try #require(stage.modules.first)
        editor.move(tile.key, under: nil)
        #expect(editor.notice?.text.contains("Drop \(tile.label) on another tile") == true)
    }
}
