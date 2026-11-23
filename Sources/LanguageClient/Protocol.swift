import Foundation
import MeepClient

// The parts of the Language Server Protocol Synesthesia uses, and `meep lsp`'s additions: `meep/graph`,
// `meep/graphChanged`, `meep/setBase` and `meep/verbs` (Meep2's docs/Design/Chat/lsp-graph.md). Names are the
// protocol's own, so they decode without mapping.

/// A place in a document: a line and a character, both counting from 0, characters in UTF-16 code units, as
/// `NSString` and Swift's `utf16` view count them.
public struct LSPPosition: Codable, Sendable, Hashable, Comparable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    public static func < (a: LSPPosition, b: LSPPosition) -> Bool {
        a.line < b.line || a.line == b.line && a.character < b.character
    }
}

/// A stretch of a document, from `start` up to but not including `end`.
public struct LSPRange: Codable, Sendable, Hashable {
    public var start: LSPPosition
    public var end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}

/// A mistake, warning or note the server found in a document.
public struct LSPDiagnostic: Codable, Sendable, Hashable {
    public enum Severity: Int, Codable, Sendable {
        case error = 1, warning, information, hint
    }

    public var range: LSPRange
    /// Errors when the server doesn't say.
    public var severity: Severity?
    public var source: String?
    public var message: String
    /// The file it's in, which `meep/graph`'s problems give, since a problem can be in an included file.
    public var uri: String?

    public init(range: LSPRange, severity: Severity? = .error, message: String, uri: String? = nil) {
        self.range = range
        self.severity = severity
        self.message = message
        self.uri = uri
    }

    public var isError: Bool { (severity ?? .error) == .error }
}

/// What `meep/graph` answers, and `meep/graphChanged` and `meep/setBase` carry: the document's pipeline as the same
/// graph the daemon gives, with keys that last while it's typed.
public struct GraphAnswer: Codable, Sendable, Equatable {
    public var uri: String
    /// The document's version now.
    public var version: Int
    /// Whether the graph is built from the text as it is now. While the text doesn't load, it's the last graph that
    /// did, and this is false.
    public var current: Bool
    /// The pipeline, or nil for a file that has never loaded. Spans count from 1, as the daemon's do.
    public var graph: PipelineGraph?
    /// The version of the text the graph was built from.
    public var builtFrom: Int?
    /// The errors that stop the text loading now.
    public var problems: [LSPDiagnostic]
    /// The lines that differ from the text the graph was built from, while it isn't current. Spans before and after
    /// are moved to match the text now; modules inside may have moved.
    public var changed: LSPRange?
    /// Keys that changed since the graph's last version, old to new. Present only when some did.
    public var renamed: [String: String]?
    /// The running pipeline the keys agree with, once `meep/setBase` has given one.
    public var base: Base?

    public struct Base: Codable, Sendable, Equatable {
        public var pipeline: String
        public var version: Int?
    }

    public init(
        uri: String, version: Int, current: Bool, graph: PipelineGraph?, builtFrom: Int? = nil, problems: [LSPDiagnostic] = [],
        changed: LSPRange? = nil, renamed: [String: String]? = nil, base: Base? = nil
    ) {
        self.uri = uri
        self.version = version
        self.current = current
        self.graph = graph
        self.builtFrom = builtFrom
        self.problems = problems
        self.changed = changed
        self.renamed = renamed
        self.base = base
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uri = try c.decode(String.self, forKey: .uri)
        version = try c.decode(Int.self, forKey: .version)
        current = try c.decodeIfPresent(Bool.self, forKey: .current) ?? true
        graph = try c.decodeIfPresent(PipelineGraph.self, forKey: .graph)
        builtFrom = try c.decodeIfPresent(Int.self, forKey: .builtFrom)
        problems = try c.decodeIfPresent([LSPDiagnostic].self, forKey: .problems) ?? []
        changed = try c.decodeIfPresent(LSPRange.self, forKey: .changed)
        renamed = try c.decodeIfPresent([String: String].self, forKey: .renamed)
        base = try c.decodeIfPresent(Base.self, forKey: .base)
    }
}

/// The names the server gives token types and modifiers, by their numbers in the data.
public struct SemanticTokensLegend: Codable, Sendable, Equatable {
    public var tokenTypes: [String]
    public var tokenModifiers: [String]

    public init(tokenTypes: [String], tokenModifiers: [String]) {
        self.tokenTypes = tokenTypes
        self.tokenModifiers = tokenModifiers
    }
}

/// A document's semantic tokens, five numbers each: the line (from the last token's), the start (from the last
/// token's, on the same line), the length, the type and the modifiers as bits.
public struct SemanticTokens: Codable, Sendable, Equatable {
    public var resultId: String?
    public var data: [Int]

    public init(resultId: String?, data: [Int]) {
        self.resultId = resultId
        self.data = data
    }
}

/// What changed in a document's semantic tokens since an earlier result.
public struct SemanticTokensDelta: Codable, Sendable, Equatable {
    public struct Edit: Codable, Sendable, Equatable {
        public var start: Int
        public var deleteCount: Int
        public var data: [Int]?
    }

    public var resultId: String?
    public var edits: [Edit]

    /// The tokens after the edits, applied to the earlier result's data.
    public func applied(to previous: [Int]) -> [Int] {
        var data = previous
        // From the end, so earlier edits' positions stay right.
        for edit in edits.sorted(by: { $0.start > $1.start }) {
            let start = min(edit.start, data.count)
            let end = min(start + edit.deleteCount, data.count)
            data.replaceSubrange(start..<end, with: edit.data ?? [])
        }
        return data
    }
}

/// What a server can do, of what Synesthesia asks for.
public struct ServerCapabilities: Sendable, Equatable {
    public var legend: SemanticTokensLegend?
    public var tokenDeltas: Bool
    public var hovers: Bool
    public var completions: Bool
    /// `meep/graph`, `meep/graphChanged` and `meep/setBase`.
    public var graph: Bool
    public var setBase: Bool
    /// `meep/verbs`.
    public var verbs: Bool
    /// `meep/applyEdits`.
    public var applyEdits: Bool

    public init(
        legend: SemanticTokensLegend? = nil, tokenDeltas: Bool = false, hovers: Bool = false, completions: Bool = false,
        graph: Bool = false, setBase: Bool = false, verbs: Bool = false, applyEdits: Bool = false
    ) {
        self.legend = legend
        self.tokenDeltas = tokenDeltas
        self.hovers = hovers
        self.completions = completions
        self.graph = graph
        self.setBase = setBase
        self.verbs = verbs
        self.applyEdits = applyEdits
    }
}

/// One verb and inflection from `meep/verbs`: what it does, its parameters, and where its C# is.
public struct VerbEntry: Codable, Sendable, Equatable {
    public struct Parameter: Codable, Sendable, Equatable {
        /// In kebab case, as Meeplang writes it.
        public var name: String
        /// In Meeplang's words: text, number, duration, bool, time, choice, list of …, and so on.
        public var type: String
        /// Whether it's the value written straight after the verb.
        public var positional: Bool
        public var required: Bool
        /// Whether it can be an expression worked out for each message.
        public var perMessage: Bool
        /// As Meeplang would write it. Required parameters have none.
        public var `default`: String?
        public var choices: [String]?
        public var description: String?
    }

    public struct Emitted: Codable, Sendable, Equatable {
        public var type: String
        /// The bool parameter that turns it on, if one does.
        public var when: String?
    }

    public struct Source: Codable, Sendable, Equatable {
        /// The C# file on this machine.
        public var file: String?
        public var line: Int?
        /// The file on the web, pinned to the commit the assembly was built from.
        public var url: String?

        public init(file: String?, line: Int?, url: String?) {
            self.file = file
            self.line = line
            self.url = url
        }
    }

    public var verb: String
    public var inflection: String
    /// The plugin it comes from, by the name the pipeline gives it, or nil for one that came with Meep.
    public var plugin: String?
    /// As the graph names roles: source, inlet, filter, outlet, step, router, tap.
    public var role: String
    /// source, passthrough or inflection.
    public var kind: String
    public var parameters: [Parameter]
    public var takes: [String]
    public var emits: [Emitted]
    public var emitsInput: Bool?
    public var description: String?
    /// The C# class.
    public var `class`: String?
    public var source: Source?
}

/// One suggestion from `textDocument/completion`.
public struct CompletionItem: Codable, Sendable, Equatable {
    public var label: String
    public var kind: Int?
    public var detail: String?
    public var insertText: String?
    public var documentation: Documentation?

    /// Plain text or markdown, as the protocol allows either.
    public struct Documentation: Codable, Sendable, Equatable {
        public var value: String

        public init(from decoder: any Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                value = text
            } else {
                value = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .value)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(value)
        }

        enum CodingKeys: String, CodingKey { case value }
    }
}

/// One of Meep2's edits, as `meep/applyEdits` and the daemon's `POST /pipelines/{name}/edits` take them.
public struct MeepEdit: Codable, Sendable, Equatable {
    /// The module: its key from the graph (`m3`), its name, its number, a verb only one module has, or `+N` for the
    /// module edit N of the same list added. Nil for edits to the defaults, constants and plugins.
    public var module: String?
    /// set, unset, set-modifier, remove-modifier, rename, add, insert, remove or remove-branch for a module;
    /// set-default, unset-default, set-const, unset-const, add-plugin or remove-plugin for the rest of the file.
    public var kind: String
    /// The parameter, modifier, setting, constant or plugin, for those edits.
    public var name: String?
    /// The value as Meeplang text, the new name, or the new module's line.
    public var value: String?

    public init(module: String?, kind: String, name: String? = nil, value: String? = nil) {
        self.module = module
        self.kind = kind
        self.name = name
        self.value = value
    }

    public static func set(_ module: String, _ name: String?, to value: String) -> MeepEdit {
        MeepEdit(module: module, kind: "set", name: name, value: value)
    }

    public static func unset(_ module: String, _ name: String?) -> MeepEdit {
        MeepEdit(module: module, kind: "unset", name: name)
    }

    public static func setModifier(_ module: String, _ name: String, to value: String? = nil) -> MeepEdit {
        MeepEdit(module: module, kind: "set-modifier", name: name, value: value)
    }

    public static func removeModifier(_ module: String, _ name: String) -> MeepEdit {
        MeepEdit(module: module, kind: "remove-modifier", name: name)
    }

    /// Gives a module a name with `as`, or with nil, takes its name away.
    public static func rename(_ module: String, to name: String?) -> MeepEdit {
        MeepEdit(module: module, kind: "rename", value: name)
    }

    /// Adds `line` as a new branch under a module.
    public static func add(_ line: String, under module: String) -> MeepEdit {
        MeepEdit(module: module, kind: "add", value: line)
    }

    /// Inserts `line` between a module and the modules under it.
    public static func insert(_ line: String, after module: String) -> MeepEdit {
        MeepEdit(module: module, kind: "insert", value: line)
    }

    /// Removes a module; the modules under it move up to take its place.
    public static func remove(_ module: String) -> MeepEdit {
        MeepEdit(module: module, kind: "remove")
    }

    /// Removes a module and everything under it.
    public static func removeBranch(_ module: String) -> MeepEdit {
        MeepEdit(module: module, kind: "remove-branch")
    }
}

/// A change to a document's text: replace `range` with `newText`.
public struct LSPTextEdit: Codable, Sendable, Equatable {
    public var range: LSPRange
    public var newText: String

    public init(range: LSPRange, newText: String) {
        self.range = range
        self.newText = newText
    }
}

/// What `meep/applyEdits` answers: the changes to the text that make the edits, against the version asked about,
/// and the keys new modules will have. With a preview, also the graph the text will have.
public struct EditAnswer: Decodable, Sendable, Equatable {
    public struct Document: Decodable, Sendable, Equatable {
        public var uri: String
        public var version: Int
    }

    public struct Added: Decodable, Sendable, Equatable {
        /// The edit that added it, counting from 0.
        public var edit: Int
        public var key: String
    }

    public var textDocument: Document
    public var edits: [LSPTextEdit]
    public var added: [Added]
    /// For a preview, the graph the text will have once the change is sent.
    public var graph: PipelineGraph?
    /// For a preview, keys that would be renamed, old to new.
    public var renamed: [String: String]?

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        textDocument = try c.decode(Document.self, forKey: .textDocument)
        edits = try c.decodeIfPresent([LSPTextEdit].self, forKey: .edits) ?? []
        added = try c.decodeIfPresent([Added].self, forKey: .added) ?? []
        graph = try c.decodeIfPresent(PipelineGraph.self, forKey: .graph)
        renamed = try c.decodeIfPresent([String: String].self, forKey: .renamed)
    }

    enum CodingKeys: String, CodingKey { case textDocument, edits, added, graph, renamed }
}
