import Foundation

// The daemon's API contracts, mirroring Meep2's `src/Meep2.Daemon/Contracts.cs`. Property names are the camel-case
// names the daemon writes, and properties the daemon leaves out when they're null are optional here.

/// What the daemon says about itself, and what the asking client may do.
public struct DaemonInfo: Codable, Sendable, Equatable {
    public var version: String
    public var processId: Int
    public var socket: String
    /// observe, inject and control, or fewer.
    public var capabilities: [String]
    /// The names of the pipelines it runs, or ran recently.
    public var pipelines: [String]

    public init(version: String, processId: Int, socket: String, capabilities: [String], pipelines: [String]) {
        self.version = version
        self.processId = processId
        self.socket = socket
        self.capabilities = capabilities
        self.pipelines = pipelines
    }
}

/// Where a pipeline is in its life.
public enum PipelineState: String, Codable, Sendable, CaseIterable {
    case starting, running, restarting, stopping, finished, failed, stopped
    /// A state a newer daemon has that this version doesn't know.
    case unknown

    public init(from decoder: any Decoder) throws {
        self = PipelineState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    /// Whether it may still be sending counts.
    public var isLive: Bool { self == .starting || self == .running || self == .restarting || self == .stopping }
}

/// A pipeline the daemon runs, or ran recently.
public struct PipelineSummary: Codable, Sendable, Equatable {
    public var name: String
    public var path: String
    public var state: PipelineState
    public var started: Date
    public var warnings: [String]
    public var ended: Date?
    public var reason: String?
    public var restarts: Int

    public init(
        name: String, path: String, state: PipelineState, started: Date, warnings: [String] = [],
        ended: Date? = nil, reason: String? = nil, restarts: Int = 0
    ) {
        self.name = name
        self.path = path
        self.state = state
        self.started = started
        self.warnings = warnings
        self.ended = ended
        self.reason = reason
        self.restarts = restarts
    }
}

/// A pipeline with its modules and their counts, final ones if it has ended.
public struct PipelineDetail: Codable, Sendable, Equatable {
    public var name: String
    public var path: String
    public var state: PipelineState
    public var started: Date
    public var modules: [ModuleDetail]
    /// The version of its graph, so a client drawing it can tell when to ask for the graph again. Nil until loaded.
    public var graphVersion: Int?
    public var ended: Date?
    public var reason: String?
    public var restarts: Int

    public init(
        name: String, path: String, state: PipelineState, started: Date, modules: [ModuleDetail],
        graphVersion: Int? = nil, ended: Date? = nil, reason: String? = nil, restarts: Int = 0
    ) {
        self.name = name
        self.path = path
        self.state = state
        self.started = started
        self.modules = modules
        self.graphVersion = graphVersion
        self.ended = ended
        self.reason = reason
        self.restarts = restarts
    }
}

/// One module of a running pipeline.
public struct ModuleDetail: Codable, Sendable, Equatable {
    /// Its position in the pipeline, counting from 1.
    public var number: Int
    /// How it's shown: its name, or its verb and number.
    public var module: String
    public var verb: String
    /// The name it was given with `as`, if any.
    public var name: String?
    /// Its counts since the pipeline started.
    public var counts: ModuleStats

    public init(number: Int, module: String, verb: String, name: String? = nil, counts: ModuleStats) {
        self.number = number
        self.module = module
        self.verb = verb
        self.name = name
        self.counts = counts
    }
}

/// A module's counts since its pipeline started. All are cumulative except ``queued``.
public struct ModuleStats: Codable, Sendable, Equatable {
    public var received: Int64
    public var handled: Int64
    public var emitted: Int64
    public var dropped: Int64
    public var filtered: Int64
    public var failed: Int64
    public var restarts: Int64
    public var expired: Int64
    public var refused: Int64
    /// Messages waiting in the module's buffer now.
    public var queued: Int64

    public init(
        received: Int64 = 0, handled: Int64 = 0, emitted: Int64 = 0, dropped: Int64 = 0, filtered: Int64 = 0,
        failed: Int64 = 0, restarts: Int64 = 0, expired: Int64 = 0, refused: Int64 = 0, queued: Int64 = 0
    ) {
        self.received = received
        self.handled = handled
        self.emitted = emitted
        self.dropped = dropped
        self.filtered = filtered
        self.failed = failed
        self.restarts = restarts
        self.expired = expired
        self.refused = refused
        self.queued = queued
    }

    public static let zero = ModuleStats()
}

/// What a verb does with messages, which the canvas shows as the module's shape.
public enum VerbRole: String, Codable, Sendable {
    /// Makes messages itself, as Interval does. A circle.
    case source
    /// A source whose messages come in from outside, as Listen's do. A triangle pointing left.
    case inlet
    /// Passes on some of what it receives, unchanged, as Where does. An inverted triangle.
    case filter
    /// Sends messages out of the pipeline, as Send does. A triangle pointing right.
    case outlet
    /// Anything else. A rectangle.
    case step
}

/// A pipeline as a graph, from `GET /pipelines/{name}/graph`.
public struct PipelineGraph: Codable, Sendable, Equatable {
    public var name: String
    public var path: String
    /// Counts up from 1 each time the graph changes; starts at 1 again when the pipeline is started again.
    public var version: Int
    public var modules: [GraphModule]
    public var links: [GraphLink]

    public init(name: String, path: String, version: Int, modules: [GraphModule], links: [GraphLink]) {
        self.name = name
        self.path = path
        self.version = version
        self.modules = modules
        self.links = links
    }
}

/// One module of a pipeline's graph.
public struct GraphModule: Codable, Sendable, Equatable {
    /// A name for the module that lasts through reloads, edits and restarts, though its number may change.
    public var key: String
    public var number: Int
    public var module: String
    public var verb: String
    /// The role as the daemon names it; see ``verbRole`` for it as an enum.
    public var role: String
    public var inflections: [String]
    public var parameters: [GraphParameter]
    public var modifiers: [GraphModifier]
    public var span: GraphSpan
    public var name: String?
    public var plugin: String?
    /// The key of the module it's indented under.
    public var under: String?
    /// Whether its line starts with `+`.
    public var feeder: Bool
    public var copyOf: String?
    public var templates: [GraphTemplateUse]?
    public var include: GraphInclude?

    /// The role, or ``VerbRole/step`` for one this version doesn't know.
    public var verbRole: VerbRole { VerbRole(rawValue: role) ?? .step }

    public init(
        key: String, number: Int, module: String, verb: String, role: VerbRole, inflections: [String] = [],
        parameters: [GraphParameter] = [], modifiers: [GraphModifier] = [], span: GraphSpan, name: String? = nil,
        plugin: String? = nil, under: String? = nil, feeder: Bool = false, copyOf: String? = nil,
        templates: [GraphTemplateUse]? = nil, include: GraphInclude? = nil
    ) {
        self.key = key
        self.number = number
        self.module = module
        self.verb = verb
        self.role = role.rawValue
        self.inflections = inflections
        self.parameters = parameters
        self.modifiers = modifiers
        self.span = span
        self.name = name
        self.plugin = plugin
        self.under = under
        self.feeder = feeder
        self.copyOf = copyOf
        self.templates = templates
        self.include = include
    }
}

/// One of a module's parameters, as written.
public struct GraphParameter: Codable, Sendable, Equatable {
    /// Its name, or nil for the value written straight after the verb.
    public var name: String?
    public var text: String
    public var span: GraphSpan
    /// For a module a template made, its value with the template's parameters put in.
    public var value: String?

    public init(name: String? = nil, text: String, span: GraphSpan, value: String? = nil) {
        self.name = name
        self.text = text
        self.span = span
        self.value = value
    }
}

/// One of a module's `@` modifiers, as written.
public struct GraphModifier: Codable, Sendable, Equatable {
    public var name: String
    public var value: String?
    public var span: GraphSpan
}

/// A line that uses a template.
public struct GraphTemplateUse: Codable, Sendable, Equatable {
    public var template: String
    public var span: GraphSpan
}

/// An `#include` line.
public struct GraphInclude: Codable, Sendable, Equatable {
    public var path: String
    public var span: GraphSpan
}

/// Which messages a link carries.
public enum LinkPort: String, Codable, Sendable {
    /// Messages and errors.
    case main
    /// Only errors, into a module with `@errors`.
    case errors
    /// No errors, into a module with `@no-errors`.
    case noErrors = "no-errors"
}

/// A link between two modules: everything one emits goes to the other.
public struct GraphLink: Codable, Sendable, Equatable {
    /// `from>to`, from the modules' keys.
    public var key: String
    public var from: String
    public var to: String
    /// Which of the receiving module's inputs it is, counting from 1.
    public var input: Int
    /// The port as the daemon names it; see ``linkPort`` for it as an enum.
    public var port: String
    public var types: [String]
    /// Whether it can carry types the loader can't name.
    public var undeclared: Bool

    public var linkPort: LinkPort { LinkPort(rawValue: port) ?? .main }

    public init(from: String, to: String, input: Int = 1, port: LinkPort = .main, types: [String] = [], undeclared: Bool = false) {
        key = "\(from)>\(to)"
        self.from = from
        self.to = to
        self.input = input
        self.port = port.rawValue
        self.types = types
        self.undeclared = undeclared
    }
}

/// Where something is written. Lines and columns count from 1, columns in UTF-16 code units, as Swift's `utf16`
/// view counts them. The end is just after the last character.
public struct GraphSpan: Codable, Sendable, Equatable {
    public var file: String
    public var startLine: Int
    public var startColumn: Int
    public var endLine: Int
    public var endColumn: Int

    public init(file: String, startLine: Int, startColumn: Int, endLine: Int, endColumn: Int) {
        self.file = file
        self.startLine = startLine
        self.startColumn = startColumn
        self.endLine = endLine
        self.endColumn = endColumn
    }
}

/// A pipeline's graph has a new version.
public struct GraphNotice: Codable, Sendable, Equatable {
    public var version: Int
    /// reload, edit or restart.
    public var reason: String

    public init(version: Int, reason: String) {
        self.version = version
        self.reason = reason
    }
}

/// Why the daemon refused a request.
public struct Problem: Codable, Sendable, Equatable {
    public var error: String
    public var details: [String]?
}
