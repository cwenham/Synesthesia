import Foundation
import MeepClient
import Transport

/// `meep lsp`, as Synesthesia uses it: documents opened and changed, and the Meeplang-specific requests on top of the
/// Language Server Protocol (`meep/graph`, `meep/setBase`, `meep/verbs`), with semantic tokens, hovers and
/// completions.
///
/// One server serves every open document. Its notifications (``events``) say which document each is for.
public actor MeepLanguageServer {
    public let connection: LanguageServerConnection
    /// What the server said it can do when it started.
    public private(set) var capabilities = ServerCapabilities()
    /// Each document's last semantic tokens, for asking only for what changed.
    private var tokens: [String: SemanticTokens] = [:]

    /// What the server says without being asked, until it stops.
    public nonisolated let events: AsyncStream<ServerEvent>

    private init(connection: LanguageServerConnection) {
        self.connection = connection
        let notices = connection.notifications
        events = AsyncStream { continuation in
            let task = Task {
                for await notice in notices {
                    if let event = ServerEvent(notice) { continuation.yield(event) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Starts talking to a server over `stream`: initializes it and learns what it can do.
    public static func start(over stream: any ByteStream) async throws -> MeepLanguageServer {
        let connection = LanguageServerConnection(stream: stream)
        await connection.start()
        let server = MeepLanguageServer(connection: connection)
        try await server.initialize()
        return server
    }

    private func initialize() async throws {
        let parameters = InitializeParams(
            processId: Int(ProcessInfo.processInfo.processIdentifier),
            clientInfo: .init(name: "Synesthesia", version: "0.1"),
            capabilities: .init()
        )
        guard let result = try await connection.request("initialize", parameters, as: InitializeResult.self) else {
            throw LanguageServerError.unreadable("The language server's answer to initialize was empty.")
        }
        let given = result.capabilities
        capabilities = ServerCapabilities(
            legend: given.semanticTokensProvider?.legend,
            tokenDeltas: given.semanticTokensProvider?.full?.delta ?? false,
            hovers: given.hoverProvider ?? false,
            completions: given.completionProvider != nil,
            graph: given.experimental?.meep?.graph ?? false,
            setBase: given.experimental?.meep?.setBase ?? false,
            verbs: given.experimental?.meep?.verbs ?? false
        )
        try await connection.notify("initialized", Empty())
    }

    // MARK: Documents

    public func open(_ uri: String, text: String, version: Int) async throws {
        tokens[uri] = nil
        try await connection.notify("textDocument/didOpen", DidOpen(textDocument: .init(uri: uri, languageId: "meeplang", version: version, text: text)))
    }

    /// The document's whole text has changed to `text`, as `meep lsp` takes changes.
    public func change(_ uri: String, text: String, version: Int) async throws {
        try await connection.notify("textDocument/didChange", DidChange(textDocument: .init(uri: uri, version: version), contentChanges: [.init(text: text)]))
    }

    public func close(_ uri: String) async throws {
        tokens[uri] = nil
        try await connection.notify("textDocument/didClose", DocumentParams(textDocument: .init(uri: uri)))
    }

    // MARK: The graph

    /// The document's pipeline as a graph. With `subscribe` true, ``ServerEvent/graphChanged(_:)`` follows each
    /// change of it; false stops them; nil leaves them as they are.
    public func graph(_ uri: String, subscribe: Bool? = nil) async throws -> GraphAnswer? {
        try await connection.request("meep/graph", GraphParams(textDocument: .init(uri: uri), subscribe: subscribe), as: GraphAnswer.self)
    }

    /// Gives the document a base: the running pipeline's graph and the text it runs, so the document's keys are the
    /// daemon's. A nil graph says the pipeline isn't running any more; keys stay as they are.
    public func setBase(_ uri: String, pipeline: String, graph: PipelineGraph?, text: String?) async throws -> GraphAnswer? {
        try await connection.request(
            "meep/setBase", SetBaseParams(textDocument: .init(uri: uri), pipeline: pipeline, graph: graph, text: text), as: GraphAnswer.self
        )
    }

    // MARK: Colouring, hovers and completions

    /// The document's semantic tokens, all of them, though asked for as a change from the last when the server can.
    public func semanticTokens(_ uri: String) async throws -> SemanticTokens? {
        let document = DocumentParams.Document(uri: uri)
        if capabilities.tokenDeltas, let previous = tokens[uri], let id = previous.resultId {
            if let delta = try await connection.request(
                "textDocument/semanticTokens/full/delta", DeltaParams(textDocument: document, previousResultId: id), as: DeltaOrTokens.self
            ) {
                let result = delta.tokens(after: previous)
                tokens[uri] = result
                return result
            }
            return nil
        }
        let result = try await connection.request("textDocument/semanticTokens/full", DocumentParams(textDocument: document), as: SemanticTokens.self)
        tokens[uri] = result
        return result
    }

    /// What the server says about the word at `position`, as markdown.
    public func hover(_ uri: String, at position: LSPPosition) async throws -> String? {
        try await connection.request("textDocument/hover", PositionParams(textDocument: .init(uri: uri), position: position), as: Hover.self)?.text
    }

    public func completions(_ uri: String, at position: LSPPosition) async throws -> [CompletionItem] {
        try await connection.request("textDocument/completion", PositionParams(textDocument: .init(uri: uri), position: position), as: Completions.self)?.items ?? []
    }

    /// Every verb and inflection the document can use, or without a document, the core modules'.
    public func verbs(_ uri: String? = nil) async throws -> [VerbEntry] {
        try await connection.request("meep/verbs", VerbsParams(textDocument: uri.map { .init(uri: $0) }), as: Verbs.self)?.verbs ?? []
    }

    /// Asks the server to shut down and exit, then closes the stream.
    public func shutdown() async {
        _ = try? await connection.request("shutdown", Empty?.none, as: Empty.self)
        try? await connection.notify("exit", Empty?.none)
        try? await Task.sleep(for: .milliseconds(50))
        await connection.close()
    }

    /// The `file:` URI the protocol names a file by.
    public nonisolated static func uri(forPath path: String) -> String {
        URL(fileURLWithPath: path).absoluteString
    }

    /// The path of a `file:` URI.
    public nonisolated static func path(forURI uri: String) -> String? {
        URL(string: uri).flatMap { $0.isFileURL ? $0.path : nil }
    }
}

/// Something a language server says without being asked.
public enum ServerEvent: Sendable, Equatable {
    /// The problems in a document now, replacing those it said before.
    case diagnostics(uri: String, [LSPDiagnostic])
    /// A subscribed document's graph has changed.
    case graphChanged(GraphAnswer)

    init?(_ notice: LanguageServerConnection.Notice) {
        switch notice.method {
        case "textDocument/publishDiagnostics":
            guard let params = try? notice.params(as: PublishDiagnostics.self) else { return nil }
            self = .diagnostics(uri: params.uri, params.diagnostics)
        case "meep/graphChanged":
            guard let answer = try? notice.params(as: GraphAnswer.self) else { return nil }
            self = .graphChanged(answer)
        default:
            return nil
        }
    }
}

// MARK: Messages

struct Empty: Codable, Sendable {}

struct InitializeParams: Encodable, Sendable {
    var processId: Int
    var clientInfo: ClientInfo
    var capabilities: ClientCapabilities

    struct ClientInfo: Encodable, Sendable {
        var name: String
        var version: String
    }

    struct ClientCapabilities: Encodable, Sendable {
        var textDocument = TextDocument()
        var experimental = ["meep": ["graph": true, "setBase": true, "verbs": true]]

        struct TextDocument: Encodable, Sendable {
            var hover = ["contentFormat": ["markdown", "plaintext"]]
            var publishDiagnostics = ["relatedInformation": false]
            var semanticTokens = SemanticTokens()
        }

        struct SemanticTokens: Encodable, Sendable {
            var requests = ["full": ["delta": true]]
            var tokenTypes: [String] = []
            var tokenModifiers: [String] = []
            var formats = ["relative"]
        }
    }
}

struct InitializeResult: Decodable, Sendable {
    var capabilities: Capabilities

    struct Capabilities: Decodable, Sendable {
        var semanticTokensProvider: TokensProvider?
        var hoverProvider: Bool?
        var completionProvider: CompletionProvider?
        var experimental: Experimental?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            semanticTokensProvider = try? c.decodeIfPresent(TokensProvider.self, forKey: .semanticTokensProvider)
            // hoverProvider may be true or an object of options.
            hoverProvider = (try? c.decodeIfPresent(Bool.self, forKey: .hoverProvider)) ?? c.contains(.hoverProvider)
            completionProvider = try? c.decodeIfPresent(CompletionProvider.self, forKey: .completionProvider)
            experimental = try? c.decodeIfPresent(Experimental.self, forKey: .experimental)
        }

        enum CodingKeys: String, CodingKey { case semanticTokensProvider, hoverProvider, completionProvider, experimental }
    }

    struct TokensProvider: Decodable, Sendable {
        var legend: SemanticTokensLegend
        var full: Full?

        struct Full: Decodable, Sendable {
            var delta: Bool?

            init(from decoder: any Decoder) throws {
                // full may be true, or an object saying whether deltas are offered.
                delta = (try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Bool.self, forKey: .delta)) ?? nil
            }

            enum CodingKeys: String, CodingKey { case delta }
        }
    }

    struct CompletionProvider: Decodable, Sendable {}

    struct Experimental: Decodable, Sendable {
        var meep: Meep?

        struct Meep: Decodable, Sendable {
            var graph: Bool?
            var setBase: Bool?
            var verbs: Bool?
        }
    }
}

struct DocumentParams: Encodable, Sendable {
    var textDocument: Document

    struct Document: Encodable, Sendable {
        var uri: String
    }
}

struct DidOpen: Encodable, Sendable {
    var textDocument: Item

    struct Item: Encodable, Sendable {
        var uri: String
        var languageId: String
        var version: Int
        var text: String
    }
}

struct DidChange: Encodable, Sendable {
    var textDocument: Versioned
    var contentChanges: [Change]

    struct Versioned: Encodable, Sendable {
        var uri: String
        var version: Int
    }

    struct Change: Encodable, Sendable {
        var text: String
    }
}

struct GraphParams: Encodable, Sendable {
    var textDocument: DocumentParams.Document
    var subscribe: Bool?
}

struct SetBaseParams: Encodable, Sendable {
    var textDocument: DocumentParams.Document
    var pipeline: String
    var graph: PipelineGraph?
    var text: String?

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(textDocument, forKey: .textDocument)
        try c.encode(pipeline, forKey: .pipeline)
        // A null graph says the pipeline has stopped, so it's written out rather than left out.
        if let graph { try c.encode(graph, forKey: .graph) } else { try c.encodeNil(forKey: .graph) }
        try c.encodeIfPresent(text, forKey: .text)
    }

    enum CodingKeys: String, CodingKey { case textDocument, pipeline, graph, text }
}

struct DeltaParams: Encodable, Sendable {
    var textDocument: DocumentParams.Document
    var previousResultId: String
}

/// A delta answer can be a whole set of tokens instead, when the server no longer has the earlier result.
struct DeltaOrTokens: Decodable, Sendable {
    var resultId: String?
    var edits: [SemanticTokensDelta.Edit]?
    var data: [Int]?

    func tokens(after previous: SemanticTokens) -> SemanticTokens {
        if let data { return SemanticTokens(resultId: resultId, data: data) }
        let delta = SemanticTokensDelta(resultId: resultId, edits: edits ?? [])
        return SemanticTokens(resultId: resultId, data: delta.applied(to: previous.data))
    }
}

struct PositionParams: Encodable, Sendable {
    var textDocument: DocumentParams.Document
    var position: LSPPosition
}

struct VerbsParams: Encodable, Sendable {
    var textDocument: DocumentParams.Document?
}

struct Verbs: Decodable, Sendable {
    var verbs: [VerbEntry]
}

struct PublishDiagnostics: Decodable, Sendable {
    var uri: String
    var diagnostics: [LSPDiagnostic]
}

/// A hover's contents, in any of the forms the protocol allows: markup, a string, or a list of them.
struct Hover: Decodable, Sendable {
    var text: String

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let markup = try? c.decode(Markup.self, forKey: .contents) {
            text = markup.value
        } else if let plain = try? c.decode(String.self, forKey: .contents) {
            text = plain
        } else {
            let parts = (try? c.decode([Markup].self, forKey: .contents)) ?? []
            text = parts.map(\.value).joined(separator: "\n\n")
        }
    }

    enum CodingKeys: String, CodingKey { case contents }

    struct Markup: Decodable, Sendable {
        var value: String

        init(from decoder: any Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                value = text
            } else {
                value = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .value)
            }
        }

        enum CodingKeys: String, CodingKey { case value }
    }
}

/// A completion answer: a list, or a list with whether it's complete.
struct Completions: Decodable, Sendable {
    var items: [CompletionItem]

    init(from decoder: any Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([CompletionItem].self) {
            items = list
        } else {
            items = try decoder.container(keyedBy: CodingKeys.self).decode([CompletionItem].self, forKey: .items)
        }
    }

    enum CodingKeys: String, CodingKey { case items }
}
