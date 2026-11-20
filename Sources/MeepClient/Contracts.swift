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
    /// A lasting ID for the daemon, made once and kept in its folder, so it's known however it's reached. Nil from
    /// daemons older than Meep2 0c83a49.
    public var id: String?
    /// The machine's names, short and in full.
    public var names: [String]?
    /// The machine's addresses on the networks it's on, IPv4 first.
    public var addresses: [String]?
    /// Where its Listens are bound.
    public var listening: [ListenAddress]?
    /// The daemon's clock when it answered, in microseconds since 1970 (UTC).
    public var clock: Int64?

    public init(
        version: String, processId: Int, socket: String, capabilities: [String], pipelines: [String], id: String? = nil,
        names: [String]? = nil, addresses: [String]? = nil, listening: [ListenAddress]? = nil, clock: Int64? = nil
    ) {
        self.version = version
        self.processId = processId
        self.socket = socket
        self.capabilities = capabilities
        self.pipelines = pipelines
        self.id = id
        self.names = names
        self.addresses = addresses
        self.listening = listening
        self.clock = clock
    }
}

/// Where a Listen is bound: `http://0.0.0.0:8080/hooks/`, say, for one on every network.
public struct ListenAddress: Codable, Sendable, Equatable {
    public var pipeline: String
    /// The Listen's key in its pipeline's graph.
    public var module: String
    public var label: String
    public var address: String

    public init(pipeline: String, module: String, label: String, address: String) {
        self.pipeline = pipeline
        self.module = module
        self.label = label
        self.address = address
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
    /// Whether the daemon reloads it when its file changes. Nil from daemons older than Meep2 0278da4, which don't say.
    public var watching: Bool?
    /// The version of its graph, so a client knows when to fetch it again. Nil from daemons older than Meep2 0c83a49.
    public var graphVersion: Int?

    public init(
        name: String, path: String, state: PipelineState, started: Date, warnings: [String] = [],
        ended: Date? = nil, reason: String? = nil, restarts: Int = 0, watching: Bool? = nil, graphVersion: Int? = nil
    ) {
        self.name = name
        self.path = path
        self.state = state
        self.started = started
        self.warnings = warnings
        self.ended = ended
        self.reason = reason
        self.restarts = restarts
        self.watching = watching
        self.graphVersion = graphVersion
    }

    /// Reads warnings and restarts the daemon leaves out as none, as a subscription's list does.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try c.decode(String.self, forKey: .name), path: try c.decode(String.self, forKey: .path),
            state: try c.decode(PipelineState.self, forKey: .state), started: try c.decode(Date.self, forKey: .started),
            warnings: try c.decodeIfPresent([String].self, forKey: .warnings) ?? [],
            ended: try c.decodeIfPresent(Date.self, forKey: .ended), reason: try c.decodeIfPresent(String.self, forKey: .reason),
            restarts: try c.decodeIfPresent(Int.self, forKey: .restarts) ?? 0, watching: try c.decodeIfPresent(Bool.self, forKey: .watching),
            graphVersion: try c.decodeIfPresent(Int.self, forKey: .graphVersion)
        )
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
    /// What each link of its graph has carried, keyed as the graph's links are. Nil until loaded, and from daemons
    /// older than Meep2 ee030d7.
    public var links: [LinkDetail]?
    public var ended: Date?
    public var reason: String?
    public var restarts: Int
    /// Whether the daemon reloads it when its file changes. Nil from daemons older than Meep2 0278da4.
    public var watching: Bool?

    public init(
        name: String, path: String, state: PipelineState, started: Date, modules: [ModuleDetail],
        graphVersion: Int? = nil, links: [LinkDetail]? = nil, ended: Date? = nil, reason: String? = nil, restarts: Int = 0,
        watching: Bool? = nil
    ) {
        self.name = name
        self.path = path
        self.state = state
        self.started = started
        self.modules = modules
        self.graphVersion = graphVersion
        self.links = links
        self.ended = ended
        self.reason = reason
        self.restarts = restarts
        self.watching = watching
    }
}

/// One link of a running pipeline, and what it has carried since the pipeline started.
public struct LinkDetail: Codable, Sendable, Equatable {
    /// `from>to`, as the graph's link has it.
    public var key: String
    /// Messages that went along it, errors included. Like the modules' counts, it only goes up.
    public var carried: Int64
    /// How many of ``carried`` were errors.
    public var errors: Int64

    public init(key: String, carried: Int64, errors: Int64 = 0) {
        self.key = key
        self.carried = carried
        self.errors = errors
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        carried = try container.decode(Int64.self, forKey: .carried)
        errors = try container.decodeIfPresent(Int64.self, forKey: .errors) ?? 0
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
    /// New messages and errors it emitted, not counting those it passed on unchanged.
    public var emitted: Int64
    /// Messages it passed on unchanged, as a filter does with those it keeps. From Meep2 ee030d7; 0 before.
    public var passed: Int64
    public var dropped: Int64
    /// Messages that stopped here because its options exclude them, such as other messages reaching an errors-only
    /// module. Not what a filter holds back: that's ``heldBack``.
    public var filtered: Int64
    public var failed: Int64
    public var restarts: Int64
    public var expired: Int64
    public var refused: Int64
    /// Messages waiting in the module's buffer now.
    public var queued: Int64

    public init(
        received: Int64 = 0, handled: Int64 = 0, emitted: Int64 = 0, passed: Int64 = 0, dropped: Int64 = 0,
        filtered: Int64 = 0, failed: Int64 = 0, restarts: Int64 = 0, expired: Int64 = 0, refused: Int64 = 0,
        queued: Int64 = 0
    ) {
        self.received = received
        self.handled = handled
        self.emitted = emitted
        self.passed = passed
        self.dropped = dropped
        self.filtered = filtered
        self.failed = failed
        self.restarts = restarts
        self.expired = expired
        self.refused = refused
        self.queued = queued
    }

    /// Reads any count the daemon leaves out as 0, so a daemon from before a count was added still reads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) throws -> Int64 { try c.decodeIfPresent(Int64.self, forKey: key) ?? 0 }
        self.init(
            received: try count(.received), handled: try count(.handled), emitted: try count(.emitted),
            passed: try count(.passed), dropped: try count(.dropped), filtered: try count(.filtered),
            failed: try count(.failed), restarts: try count(.restarts), expired: try count(.expired),
            refused: try count(.refused), queued: try count(.queued)
        )
    }

    /// Messages a filter took and neither passed on nor turned into errors: what it held back. Meep2 has no count
    /// for this, so it's worked out; it means something only for a filter.
    public var heldBack: Int64 { max(0, handled - passed - emitted) }

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

/// The text a running pipeline runs from, from `GET /pipelines/{name}/source`.
public struct SourceText: Codable, Sendable, Equatable {
    /// The file it came from.
    public var path: String
    /// Its text now: the file as loaded or last reloaded, with any edits made through the API since.
    public var text: String
    /// Whether edits made through the API make it differ from the file as loaded.
    public var edited: Bool

    public init(path: String, text: String, edited: Bool = false) {
        self.path = path
        self.text = text
        self.edited = edited
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

/// A message a debug tap saw, as the daemon writes it for people to look at: who it is, and its content as JSON.
/// It's for showing; it can't be read back as the message itself.
public struct TappedMessage: Codable, Sendable, Equatable, Identifiable {
    /// Its type's name, such as Tick or ErrorMessage.
    public var type: String
    public var id: String
    public var created: Date
    /// The module that made it, as the daemon names modules: its name, or its verb and number.
    public var emittedBy: String?
    public var expires: String?
    public var leases: [String]?
    /// Its public properties, with long text cut short and nesting stopped after a few levels.
    public var content: JSONValue?
    /// Its nearest ancestors, nearest first, as `fam` searches them.
    public var fam: [Ancestor]?

    public struct Ancestor: Codable, Sendable, Equatable {
        public var type: String
        public var id: String
        public var created: Date
        public var emittedBy: String?

        public init(type: String, id: String, created: Date, emittedBy: String? = nil) {
            self.type = type
            self.id = id
            self.created = created
            self.emittedBy = emittedBy
        }
    }

    public init(
        type: String, id: String, created: Date, emittedBy: String? = nil, expires: String? = nil, leases: [String]? = nil,
        content: JSONValue? = nil, fam: [Ancestor]? = nil
    ) {
        self.type = type
        self.id = id
        self.created = created
        self.emittedBy = emittedBy
        self.expires = expires
        self.leases = leases
        self.content = content
        self.fam = fam
    }

    /// Whether it's an error, which travels @errors wires.
    public var isError: Bool { type == "ErrorMessage" || type.hasSuffix("Error") }
}

/// One message from a debug tap, with how many the tap has had to leave out so far because its reader fell behind.
public struct TapEvent: Codable, Sendable, Equatable {
    public var dropped: Int64
    public var message: TappedMessage

    public init(dropped: Int64, message: TappedMessage) {
        self.dropped = dropped
        self.message = message
    }
}

/// What to send into a module: text, or JSON, which the daemon makes a `JsonMessage` of.
public enum InjectBody: Sendable, Equatable {
    case text(String)
    case json(JSONValue)
}

/// A message the daemon sent into a pipeline.
public struct Injected: Codable, Sendable, Equatable {
    public var id: String
    /// TextMessage or JsonMessage.
    public var type: String
    /// The module it went to, as the daemon names it.
    public var module: String

    public init(id: String, type: String, module: String) {
        self.id = id
        self.type = type
        self.module = module
    }
}
