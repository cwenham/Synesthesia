import CodeEditing
import ContinuumKit
import CoreGraphics
import FlowKit
import Foundation
import ImageIO
import LanguageClient
import MeepClient
import Stage
import UniformTypeIdentifiers

/// What the tools need from the app: the Continuum, what's selected, and the canvas. The Mac app supplies it; the
/// iPad's will too.
@MainActor
public protocol Viewer: AnyObject {
    var continuum: Continuum { get }
    /// What's selected in the sidebar: a host or a pipeline.
    var selection: MeepAddress? { get }
    /// The stage the canvas is drawing, if a pipeline is showing.
    var stage: PipelineStage? { get }
    /// Selects a host or pipeline in the sidebar.
    func select(_ address: MeepAddress)
    /// Opens the window if it's closed, without taking the person's focus.
    func reveal()
    /// The canvas as it's drawn now, if a pipeline is showing.
    func canvasImage() -> CGImage?
    /// A pipeline's text, if it's open beside the canvas or has changes that aren't saved.
    func document(for pipeline: MeepPipeline) -> MeeplangDocument?
    /// Whether the text shows beside the canvas.
    var showsText: Bool { get }
    /// The language server, for the verb catalogue.
    var language: LanguageService? { get }
}

/// The tools for looking at the Continuum and showing things in it (design, section 8): step 3's set.
@MainActor
public enum ContinuumTools {
    public static let instructions = """
        Synesthesia shows Meep pipelines live: the hosts it follows (Meep daemons), their pipelines, and each \
        pipeline's modules and the links between them, with counts of the messages that go through. Everything \
        has an address: meep://<host>/<pipeline>/<module>, such as meep://local/orders/m3. A module is named by \
        its key (m1, m2, …, which lasts through reloads), its name or its number. "local" is this Mac's daemon.

        Start with list_continuum. describe_pipeline gives a pipeline's modules, links and counts; watch_counts \
        measures them over a few seconds; read_pipeline_text gives its Meeplang, as the person is editing it if \
        they are; describe_verbs says what each verb does and takes. describe_view says what the canvas and the \
        text beside it show, which is cheaper and more exact than capture_view's image. show points the app at an \
        address so the person can see what you mean.
        """

    public static func registry(for viewer: Viewer) -> ToolRegistry {
        ToolRegistry([
            listContinuum(viewer),
            describePipeline(viewer),
            readPipelineText(viewer),
            describeVerbs(viewer),
            watchCounts(viewer),
            describeView(viewer),
            captureView(viewer),
            show(viewer),
        ])
    }

    static let addressSchema: JSONValue = [
        "type": "string",
        "description": "An address, such as meep://local/orders or meep://local/orders/m3. The host can be left out when only one host has a pipeline of that name.",
    ]

    // MARK: Looking

    static func listContinuum(_ viewer: Viewer) -> Tool {
        Tool(
            name: "list_continuum", title: "List the Continuum",
            description: "Lists the hosts Synesthesia follows, whether each can be reached, and their pipelines with their state and messages a second. Also says what's selected in the app.",
            inputSchema: ["type": "object", "properties": [:]]
        ) { _ in
            .json([
                "selected": viewer.selection.map { .string($0.description) } ?? .null,
                "hosts": .array(viewer.continuum.hosts.map { host in
                    var entry: [String: JSONValue] = [
                        "address": .string(host.address.description), "title": .string(host.title),
                        "status": .string(host.statusDescription),
                        "pipelines": .array(host.pipelines.map { pipeline in
                            var item: [String: JSONValue] = [
                                "address": .string(pipeline.address.description), "state": .string(pipeline.state.rawValue),
                                "modules": .number(pipeline.modules.count),
                            ]
                            if host.isReachable, pipeline.state.isLive { item["messagesPerSecond"] = .rounded(pipeline.throughput, places: 1) }
                            if pipeline.restarts > 0 { item["restarts"] = .number(pipeline.restarts) }
                            if let reason = pipeline.reason { item["reason"] = .string(reason) }
                            return .object(item)
                        }),
                    ]
                    if let info = host.info { entry["meepVersion"] = .string(info.version) }
                    return .object(entry)
                }),
            ])
        }
    }

    static func describePipeline(_ viewer: Viewer) -> Tool {
        Tool(
            name: "describe_pipeline", title: "Describe a pipeline",
            description: "A pipeline's modules (verb, role, parameters, where each is written) and links, with every count that isn't zero and current rates per second. Rates are smoothed over about two seconds; use watch_counts to measure over a period.",
            inputSchema: ["type": "object", "properties": ["address": addressSchema], "required": ["address"]]
        ) { arguments in
            let (host, pipeline, _) = try resolve(arguments["address"], in: viewer, needsPipeline: true)
            let current = host.isReachable && pipeline!.state.isLive
            return .json(describe(pipeline!, host: host, current: current))
        }
    }

    static func readPipelineText(_ viewer: Viewer) -> Tool {
        Tool(
            name: "read_pipeline_text", title: "Read a pipeline's Meeplang",
            description: "A pipeline's Meeplang, with line numbers, and which module is written on which line. If the person has it open with changes they haven't saved, it's their text as it is now, and says so; otherwise it's what the daemon runs.",
            inputSchema: ["type": "object", "properties": ["address": addressSchema], "required": ["address"]]
        ) { arguments in
            let (host, found, _) = try resolve(arguments["address"], in: viewer, needsPipeline: true)
            let pipeline = found!
            var note: String?
            let path: String
            let text: String
            var modules = pipeline.graph?.modules ?? []
            if let document = viewer.document(for: pipeline) {
                (path, text) = (document.path, document.text)
                if document.isEdited { note = "This is the text as the person is editing it, with changes they haven't saved; the pipeline runs the saved file." }
                if let graph = document.answer?.graph { modules = graph.modules }
            } else if let link = host.link, let source = try? await link.source(pipeline.name) {
                (path, text) = (source.path, source.text)
                if source.edited { note = "The daemon runs edits made through its API that aren't in the file." }
            } else if case .local = host.kind, let file = try? String(contentsOfFile: pipeline.path, encoding: .utf8) {
                (path, text) = (pipeline.path, file)
            } else {
                throw ToolError("Couldn't read \(pipeline.name)'s text: \(host.title) can't be reached, or has none for it.")
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let numbered = lines.prefix(2000).enumerated().map { String(format: "%4d  ", $0 + 1) + $1 }.joined(separator: "\n")
            let where_ = modules.map { "\($0.key) \($0.module): line \($0.span.startLine)\($0.span.file == path ? "" : " of \($0.span.file)")" }
            var result = "\(path)\n\n\(numbered)"
            if let note { result = "\(note)\n\n" + result }
            if lines.count > 2000 { result += "\n… \(lines.count - 2000) more lines" }
            if !where_.isEmpty { result += "\n\nModules:\n" + where_.joined(separator: "\n") }
            return ToolResult([.text(result)])
        }
    }

    static func describeVerbs(_ viewer: Viewer) -> Tool {
        Tool(
            name: "describe_verbs", title: "Describe Meeplang's verbs",
            description: "What each verb and inflection does, from Meep's catalogue: its role, its parameters with their types, defaults and descriptions, the message types it takes and emits, and where its C# is. Give a verb, such as Fetch or Fetch.HTTP, for one; leave it out for a list of all. With a pipeline's address, it includes the verbs its plugins add.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "verb": ["type": "string", "description": "A verb, such as Fetch, or a verb and inflection, such as Fetch.HTTP."],
                    "address": addressSchema,
                ],
            ]
        ) { arguments in
            guard let language = viewer.language else { throw ToolError("This app has no language server to ask.") }
            var uri: String?
            if arguments["address"] != nil {
                let (_, pipeline, _) = try resolve(arguments["address"], in: viewer, needsPipeline: true)
                uri = viewer.document(for: pipeline!)?.uri ?? MeepLanguageServer.uri(forPath: pipeline!.path)
            }
            let verbs: [VerbEntry]
            do {
                verbs = try await language.verbs(for: uri)
            } catch {
                throw ToolError("meep lsp couldn't be asked: \(error.localizedDescription)")
            }
            guard let asked = arguments["verb"]?.string?.trimmingCharacters(in: .whitespaces), !asked.isEmpty else {
                // All of them, briefly.
                return .json(.array(verbs.map { verb in
                    .object([
                        "verb": .string(verb.inflection == verb.verb ? verb.verb : "\(verb.verb).\(verb.inflection)"),
                        "role": .string(verb.role),
                        "summary": .string(String((verb.description ?? "").prefix(160))),
                    ])
                }))
            }
            let parts = asked.split(separator: ".", maxSplits: 1).map { String($0).lowercased() }
            let matches = verbs.filter { $0.verb.lowercased() == parts[0] && (parts.count == 1 || $0.inflection.lowercased() == parts[1]) }
            guard !matches.isEmpty else {
                throw ToolError("There's no verb called \(asked). There are: \(Set(verbs.map(\.verb)).sorted().joined(separator: ", ")).")
            }
            return .json(.array(matches.map(describe)))
        }
    }

    static func describe(_ verb: VerbEntry) -> JSONValue {
        var entry: [String: JSONValue] = [
            "verb": .string(verb.verb), "inflection": .string(verb.inflection), "role": .string(verb.role),
            "parameters": .array(verb.parameters.map { parameter in
                var item: [String: JSONValue] = ["name": .string(parameter.name), "type": .string(parameter.type)]
                if parameter.positional { item["afterTheVerb"] = true }
                if parameter.required { item["required"] = true }
                if parameter.perMessage { item["perMessage"] = true }
                if let value = parameter.default { item["default"] = .string(value) }
                if let choices = parameter.choices { item["choices"] = .array(choices.map { .string($0) }) }
                if let description = parameter.description { item["description"] = .string(description) }
                return .object(item)
            }),
            "takes": .array(verb.takes.map { .string($0) }),
            "emits": .array(verb.emits.map { emitted in .string(emitted.when.map { "\(emitted.type), when \($0) is true" } ?? emitted.type) }),
        ]
        if let description = verb.description { entry["description"] = .string(description) }
        if let file = verb.source?.file { entry["source"] = .string(verb.source?.line.map { "\(file):\($0)" } ?? file) }
        return .object(entry)
    }

    static func watchCounts(_ viewer: Viewer) -> Tool {
        Tool(
            name: "watch_counts", title: "Watch counts over a period",
            description: "Measures a pipeline's counts, or one module's, over a few seconds: how much each count rose, and the rate per second over that time, for each module and link. The pipeline's counts come several times a second while it's watched.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "address": addressSchema,
                    "seconds": ["type": "number", "minimum": 1, "maximum": 60, "default": 5, "description": "How long to watch, from 1 to 60 seconds."],
                ],
                "required": ["address"],
            ]
        ) { arguments in
            let (host, pipeline, module) = try resolve(arguments["address"], in: viewer, needsPipeline: true)
            guard let pipeline else { throw ToolError("No pipeline.") }
            guard host.isReachable, pipeline.state.isLive else {
                throw ToolError("\(pipeline.address) isn't running on a host that can be reached, so its counts aren't changing.")
            }
            let seconds = min(max(arguments["seconds"]?.number ?? 5, 1), 60)
            pipeline.watchers += 1
            defer { pipeline.watchers -= 1 }
            let before = Counts(pipeline)
            let start = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .seconds(seconds))
            let after = Counts(pipeline)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let keys = module.map { key in Set([key.key]) } ?? Set(pipeline.modules.map(\.key))
            var modules: [JSONValue] = []
            for model in pipeline.modules where keys.contains(model.key) {
                let rises = after.modules[model.key, default: [:]].compactMap { kind, value -> (String, Int64)? in
                    // What's held back is worked out, and means something only for a filter.
                    guard kind != .heldBack || model.role == .filter else { return nil }
                    let rise = value - (before.modules[model.key]?[kind] ?? 0)
                    return rise > 0 ? (kind.rawValue, rise) : nil
                }.sorted { $0.0 < $1.0 }
                var entry: [String: JSONValue] = [
                    "address": .string(pipeline.address.module(model.key).description), "label": .string(model.label),
                    "rose": .object(Dictionary(uniqueKeysWithValues: rises.map { ($0.0, .number($0.1)) })),
                    "perSecond": .object(Dictionary(uniqueKeysWithValues: rises.map { ($0.0, .rounded(Double($0.1) / elapsed)) })),
                ]
                if model.counts.queued > 0 { entry["queuedNow"] = .number(model.counts.queued) }
                modules.append(.object(entry))
            }
            var links: [JSONValue] = []
            for link in pipeline.links where keys.contains(link.from) || keys.contains(link.to) {
                let carried = (after.links[link.key]?.0 ?? 0) - (before.links[link.key]?.0 ?? 0)
                let errors = (after.links[link.key]?.1 ?? 0) - (before.links[link.key]?.1 ?? 0)
                links.append([
                    "key": .string(link.key), "carried": .number(carried), "errors": .number(errors),
                    "perSecond": .rounded(Double(carried) / elapsed), "errorsPerSecond": .rounded(Double(errors) / elapsed),
                ])
            }
            return .json([
                "address": .string((module.map { pipeline.address.module($0.key) } ?? pipeline.address).description),
                "seconds": .rounded(elapsed, places: 1),
                "modules": .array(modules), "links": .array(links),
                "note": "Counts arrive a few times a second, so the period's ends are each up to a fifth of a second late.",
            ])
        }
    }

    // MARK: The canvas

    static func describeView(_ viewer: Viewer) -> Tool {
        Tool(
            name: "describe_view", title: "Describe what the canvas shows",
            description: "What the app's canvas is showing, as structure: the pipeline, the zoom, each tile's place on screen and its label, and on each wire whether particles show single messages or a rate. When the Meeplang is open beside it, says whether it's saved, whether it loads, and its problems; the canvas then draws the text as typed, with modules not running yet marked. Cheaper and more exact than capture_view.",
            inputSchema: ["type": "object", "properties": [:]]
        ) { _ in
            var result: [String: JSONValue] = ["selected": viewer.selection.map { .string($0.description) } ?? .null]
            guard let stage = viewer.stage, stage.currentViewSize.width > 0 else {
                result["canvas"] = .null
                result["note"] = "No pipeline is on the canvas. Use show with a pipeline's address."
                return .json(.object(result))
            }
            result["canvas"] = describe(stage)
            if viewer.showsText, let document = viewer.document(for: stage.pipeline) {
                result["text"] = describe(document)
            }
            return .json(.object(result))
        }
    }

    static func captureView(_ viewer: Viewer) -> Tool {
        Tool(
            name: "capture_view", title: "Capture the canvas",
            description: "An image of the canvas as it's drawn now. describe_view is cheaper and gives exact numbers; use this to see how things look.",
            inputSchema: ["type": "object", "properties": [:]]
        ) { _ in
            guard viewer.stage != nil, let image = viewer.canvasImage(), let png = png(image) else {
                throw ToolError("No pipeline is on the canvas. Use show with a pipeline's address.")
            }
            return ToolResult([.png(png), .text("The canvas at \(image.width)×\(image.height) pixels.")])
        }
    }

    // MARK: Showing

    static func show(_ viewer: Viewer) -> Tool {
        Tool(
            name: "show", title: "Show something in the app",
            description: "Points the app at an address so the person can see what you mean: a host or pipeline is selected in the sidebar; a module's pipeline is opened on the canvas, which moves to the module and selects it.",
            inputSchema: ["type": "object", "properties": ["address": addressSchema], "required": ["address"]],
            readOnly: false
        ) { arguments in
            let (host, pipeline, module) = try resolve(arguments["address"], in: viewer, needsPipeline: false)
            viewer.reveal()
            guard let pipeline else {
                viewer.select(host.address)
                return .json(["shown": .string(host.address.description)])
            }
            viewer.select(pipeline.address)
            guard let module else { return .json(["shown": .string(pipeline.address.description)]) }
            // The canvas opens its stage once SwiftUI has shown the pipeline, and lays it out on its first frame.
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !(viewer.stage?.pipeline === pipeline && viewer.stage?.isLaidOut == true) {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw ToolError("\(pipeline.address) is selected, but its canvas didn't open. Is the window showing?")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            viewer.stage?.show(module.key)
            return .json(["shown": .string(pipeline.address.module(module.key).description), "label": .string(module.label)])
        }
    }

    // MARK: Descriptions

    static func describe(_ pipeline: MeepPipeline, host: MeepHost, current: Bool) -> JSONValue {
        var result: [String: JSONValue] = [
            "address": .string(pipeline.address.description), "host": .string(host.title),
            "state": .string(pipeline.state.rawValue), "file": .string(pipeline.path),
            "countsAreCurrent": .bool(current),
        ]
        if !current { result["note"] = "The host can't be reached or the pipeline isn't running, so these counts are as last seen, and there are no rates." }
        if let started = pipeline.started { result["started"] = .string(started.formatted(.iso8601)) }
        if let ended = pipeline.ended { result["ended"] = .string(ended.formatted(.iso8601)) }
        if let reason = pipeline.reason { result["reason"] = .string(reason) }
        if pipeline.restarts > 0 { result["restarts"] = .number(pipeline.restarts) }
        if !pipeline.warnings.isEmpty { result["warnings"] = .array(pipeline.warnings.map { .string($0) }) }
        let graph = pipeline.graph
        result["modules"] = .array(pipeline.modules.map { module in
            let written = graph?.modules.first { $0.key == module.key }
            var entry: [String: JSONValue] = [
                "address": .string(pipeline.address.module(module.key).description), "key": .string(module.key),
                "label": .string(module.label), "verb": .string(module.verb), "number": .number(module.number),
            ]
            if let name = module.name { entry["name"] = .string(name) }
            if let role = module.role { entry["role"] = .string(role.rawValue) }
            if module.inflections != [module.verb], !module.inflections.isEmpty { entry["inflections"] = .array(module.inflections.map { .string($0) }) }
            if let written {
                if !written.parameters.isEmpty { entry["parameters"] = .array(written.parameters.map { .string($0.text) }) }
                if !written.modifiers.isEmpty { entry["modifiers"] = .array(written.modifiers.map { .string("@" + $0.name) }) }
                entry["line"] = .number(written.span.startLine)
                if written.span.file != pipeline.path { entry["file"] = .string(written.span.file) }
            }
            entry["counts"] = counts(module.counts, role: module.role)
            if current {
                let rates = CountKind.allCases.compactMap { kind -> (String, JSONValue)? in
                    let rate = module.rates[kind]
                    return rate >= 0.005 ? (kind.rawValue, .rounded(rate)) : nil
                }
                if !rates.isEmpty { entry["perSecond"] = .object(Dictionary(uniqueKeysWithValues: rates)) }
            }
            return .object(entry)
        })
        result["links"] = .array(pipeline.links.map { link in
            var entry: [String: JSONValue] = [
                "key": .string(link.key), "from": .string(link.from), "to": .string(link.to), "port": .string(link.port.rawValue),
            ]
            if link.input > 1 { entry["input"] = .number(link.input) }
            if !link.types.isEmpty { entry["types"] = .array(link.types.map { .string($0) }) }
            if link.isCounted {
                entry["carried"] = .number(link.carried)
                if link.errors > 0 { entry["errors"] = .number(link.errors) }
                if current {
                    entry["perSecond"] = .rounded(link.rate)
                    if link.errorRate >= 0.005 { entry["errorsPerSecond"] = .rounded(link.errorRate) }
                }
            }
            return .object(entry)
        })
        return .object(result)
    }

    static func counts(_ stats: ModuleStats, role: VerbRole?) -> JSONValue {
        var counts: [String: JSONValue] = [:]
        for (kind, value) in stats.byKind where value != 0 && kind != .heldBack {
            counts[kind.rawValue] = .number(value)
        }
        // Worked out, as Meep2 doesn't count it: what a filter took and neither passed on nor made errors of.
        if role == .filter, stats.heldBack > 0 { counts["heldBack"] = .number(stats.heldBack) }
        if stats.queued > 0 { counts["queuedNow"] = .number(stats.queued) }
        if stats.restarts > 0 { counts["restarts"] = .number(stats.restarts) }
        return .object(counts)
    }

    static func describe(_ stage: PipelineStage) -> JSONValue {
        let size = stage.currentViewSize
        let snapshot = stage.frame(at: ProcessInfo.processInfo.systemUptime, viewSize: size)
        let camera = snapshot.camera
        let screen = CGRect(origin: .zero, size: size)
        let pipeline = stage.pipeline
        func rect(_ r: CGRect) -> JSONValue {
            [.rounded(r.minX, places: 0), .rounded(r.minY, places: 0), .rounded(r.width, places: 0), .rounded(r.height, places: 0)]
        }
        let tiles: [JSONValue] = snapshot.tiles.map { tile in
            let shown = camera.viewRect(tile.frame, in: size)
            var entry: [String: JSONValue] = [
                "address": .string(pipeline.address.module(tile.id).description),
                "shape": .string(String(describing: tile.shape)),
                "frame": rect(shown),
                "onScreen": .bool(screen.intersects(shown)),
                "label": .array(snapshot.texts.filter { $0.tile == tile.id }.map { .string($0.string) }),
            ]
            if tile.isSelected { entry["selected"] = true }
            if tile.isHovered { entry["hovered"] = true }
            if let module = stage.module(tile.id) {
                if module.isNew { entry["notRunningYet"] = true }
                if module.isBeingEdited { entry["beingEdited"] = true }
            }
            if tile.flash > 0 { entry["flashingRed"] = true }
            let queued = snapshot.overParticles.filter { $0.owner == "\(tile.id).queued" }.count
            if queued > 0 { entry["queueDots"] = .number(queued) }
            for (flow, name) in [("held", "heldBackParticles"), ("dropped", "droppedParticles"), ("expired", "expiredParticles")] {
                let id = "\(tile.id).\(flow)"
                if snapshot.overStreams.contains(where: { $0.path.id == id }) {
                    entry[name] = "rate"
                } else if case let count = snapshot.overParticles.filter({ $0.owner == id }).count, count > 0 {
                    entry[name] = .number(count)
                }
            }
            return .object(entry)
        }
        let wires: [JSONValue] = snapshot.wires.map { wire in
            let box = wire.points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            var entry: [String: JSONValue] = [
                "key": .string(wire.id), "kind": .string(String(describing: wire.kind)),
                "onScreen": .bool(screen.intersects(camera.viewRect(box, in: size))),
            ]
            let streams = snapshot.streams.filter { $0.path.id == wire.id }
            let singles = snapshot.particles.filter { $0.owner == wire.id }
            let messageStream = streams.contains { $0.color != Theme.error }
            let errorStream = streams.contains { $0.color == Theme.error }
            let messages = singles.filter { $0.color != Theme.error }.count
            let errors = singles.filter { $0.color == Theme.error }.count
            entry["messages"] = messageStream ? "rate streaks" : (messages > 0 ? .string("\(messages) single messages") : "none now")
            if errorStream || errors > 0 { entry["errors"] = errorStream ? "rate streaks" : .string("\(errors) single errors") }
            if wire.isHovered { entry["hovered"] = true }
            return .object(entry)
        }
        var result: [String: JSONValue] = [
            "pipeline": .string(pipeline.address.description),
            "viewSize": [.rounded(size.width, places: 0), .rounded(size.height, places: 0)],
            "zoom": .rounded(camera.scale),
            "countsAreCurrent": .bool(stage.isCurrent),
            "tiles": .array(tiles), "wires": .array(wires),
            "particles": "Below 5 messages a second a wire shows single messages, one dot each; above that, streaks whose density follows the log of the rate.",
        ]
        if !stage.selection.isEmpty { result["selected"] = .array(stage.selection.sorted().map { .string(pipeline.address.module($0).description) }) }
        if let hovered = stage.hovered {
            switch hovered {
            case .tile(let key): result["hovered"] = .string(pipeline.address.module(key).description)
            case .wire(let key): result["hovered"] = .string("wire \(key)")
            }
        }
        return .object(result)
    }

    /// The text beside the canvas: its file, whether it's saved and loads, and its problems.
    static func describe(_ document: MeeplangDocument) -> JSONValue {
        var entry: [String: JSONValue] = [
            "file": .string(document.path),
            "unsavedChanges": .bool(document.isEdited),
            "status": .string(String(describing: document.status)),
            "lines": .number(document.lines.lineCount),
        ]
        if let answer = document.answer {
            entry["loads"] = .bool(answer.current)
            if !answer.current, let changed = answer.changed {
                entry["linesBeingMended"] = .string("\(changed.start.line + 1) to \(max(changed.start.line + 1, changed.end.line))")
            }
        }
        if !document.diagnostics.isEmpty { entry["problems"] = .array(document.problemLines.map { .string($0) }) }
        if document.isReadOnly { entry["readOnly"] = true }
        if let problem = document.baseProblem { entry["keysNote"] = .string(problem) }
        return .object(entry)
    }

    // MARK: Helpers

    /// The host, pipeline and module an address names. The host may be left out when only one host has a pipeline
    /// of that name; a module may be named by its key, name, label or number.
    static func resolve(_ argument: JSONValue?, in viewer: Viewer, needsPipeline: Bool) throws -> (MeepHost, MeepPipeline?, MeepModule?) {
        guard let text = argument?.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            throw ToolError("Give an address, such as meep://local/orders.")
        }
        let continuum = viewer.continuum
        var address = MeepAddress(text.hasPrefix("meep://") ? text : "meep://" + text)
        if address.map({ continuum.host($0.host) == nil }) ?? true, !text.hasPrefix("meep://") {
            // Perhaps a pipeline's name, with or without a module, on whichever host has it.
            let parts = text.split(separator: "/").map(String.init)
            let hosts = continuum.hosts.filter { $0.pipeline(parts[0]) != nil }
            if hosts.count == 1, parts.count <= 2 {
                address = MeepAddress(host: hosts[0].name, pipeline: parts[0], module: parts.count > 1 ? parts[1] : nil)
            } else if hosts.count > 1 {
                throw ToolError("More than one host has a pipeline called \(parts[0]): \(hosts.map { $0.address.pipeline(parts[0]).description }.joined(separator: ", ")).")
            }
        }
        guard let address else { throw ToolError("\(text) isn't an address. Addresses look like meep://local/orders/m3.") }
        guard let host = continuum.host(address.host) else {
            throw ToolError("There's no host called \(address.host). The hosts are \(continuum.hosts.map(\.name).joined(separator: ", ")).")
        }
        guard let name = address.pipeline else {
            if needsPipeline { throw ToolError("\(address) is a host; give a pipeline's address.") }
            return (host, nil, nil)
        }
        guard let pipeline = host.pipeline(name) else {
            throw ToolError("\(host.title) has no pipeline called \(name). It has \(host.pipelines.map(\.name).joined(separator: ", ")).")
        }
        guard let moduleName = address.module else { return (host, pipeline, nil) }
        let module = pipeline.module(moduleName)
            ?? pipeline.modules.first { $0.name == moduleName }
            ?? pipeline.modules.first { $0.label == moduleName }
            ?? Int(moduleName.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).flatMap { number in pipeline.modules.first { $0.number == number } }
        guard let module else {
            throw ToolError("\(pipeline.address) has no module called \(moduleName). Its modules are \(pipeline.modules.map { "\($0.key) (\($0.label))" }.joined(separator: ", ")).")
        }
        return (host, pipeline, module)
    }

    struct Counts {
        var modules: [String: [CountKind: Int64]]
        var links: [String: (Int64, Int64)]

        @MainActor init(_ pipeline: MeepPipeline) {
            modules = Dictionary(uniqueKeysWithValues: pipeline.modules.map { ($0.key, $0.counts.byKind) })
            links = Dictionary(uniqueKeysWithValues: pipeline.links.map { ($0.key, ($0.carried, $0.errors)) })
        }
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

extension MeepHost {
    /// Its status in words, for tools.
    var statusDescription: String {
        switch status {
        case .connecting: "connecting"
        case .connected: "connected"
        case .unreachable(let reason): "can't be reached: \(reason)"
        }
    }
}
