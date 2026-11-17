import Foundation
import LanguageClient
import Observation

/// The app's one `meep lsp`, shared by every open document: started when first needed, started again if it stops,
/// with what it says sent to the document it's about.
///
/// Everything sent to the server goes through one queue, in the order it's given, so a change always reaches the
/// server before a question about it.
@MainActor @Observable
public final class LanguageService {
    public enum State: Equatable, Sendable {
        /// Not started yet: nothing has needed it.
        case idle
        case starting
        case running
        /// It couldn't be started, or stopped, and why. It's tried again when next needed, after a pause.
        case unavailable(String)
    }

    public private(set) var state: State = .idle
    /// What the running server can do.
    public private(set) var capabilities: ServerCapabilities?

    @ObservationIgnored private let launch: @Sendable () async throws -> MeepLanguageServer
    @ObservationIgnored private var server: MeepLanguageServer?
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var documents: [String: WeakDocument] = [:]
    @ObservationIgnored private let queue: AsyncStream<@MainActor () async -> Void>.Continuation
    @ObservationIgnored private var draining: Task<Void, Never>?
    @ObservationIgnored private var failedAt: Date?
    /// How long to wait before trying to start a server that couldn't be started.
    @ObservationIgnored public var retryAfter: TimeInterval = 20

    private struct WeakDocument {
        weak var document: MeeplangDocument?
    }

    /// `launch` starts a server and returns it initialized. On the Mac it starts `meep lsp`.
    public init(launch: @escaping @Sendable () async throws -> MeepLanguageServer) {
        self.launch = launch
        let (operations, queue) = AsyncStream<@MainActor () async -> Void>.makeStream()
        self.queue = queue
        draining = Task { @MainActor in
            for await operation in operations { await operation() }
        }
    }

    /// Runs `body` with the server, after everything given before it, and returns what it returns.
    public func perform<Result: Sendable>(_ body: @escaping @MainActor (MeepLanguageServer) async throws -> Result) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.yield { [self] in
                do {
                    let server = try await running()
                    continuation.resume(returning: try await body(server))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Sends something that needs no answer, after everything given before it.
    public func send(_ body: @escaping @MainActor (MeepLanguageServer) async throws -> Void) {
        queue.yield { [self] in
            guard let server = try? await running() else { return }
            try? await body(server)
        }
    }

    /// Every verb and inflection a document can use, or the core modules' without one.
    public func verbs(for uri: String? = nil) async throws -> [VerbEntry] {
        try await perform { try await $0.verbs(uri) }
    }

    /// Stops the server, as the app quits.
    public func stop() async {
        listening?.cancel()
        if let server { await server.shutdown() }
        server = nil
        state = .idle
    }

    // MARK: Documents

    func register(_ document: MeeplangDocument) {
        documents[document.uri] = WeakDocument(document: document)
    }

    func unregister(_ document: MeeplangDocument) {
        if documents[document.uri]?.document === document { documents.removeValue(forKey: document.uri) }
    }

    // MARK: Starting

    /// The running server, started (and the open documents opened in it again) if it isn't running.
    private func running() async throws -> MeepLanguageServer {
        if let server, await server.connection.stopped == nil { return server }
        if let failedAt, Date().timeIntervalSince(failedAt) < retryAfter, case .unavailable(let reason) = state {
            throw LanguageServerError.stopped(reason)
        }
        server = nil
        state = .starting
        let started: MeepLanguageServer
        do {
            started = try await launch()
        } catch {
            failedAt = Date()
            state = .unavailable(error.localizedDescription)
            throw error
        }
        server = started
        failedAt = nil
        capabilities = await started.capabilities
        state = .running
        listen(to: started)
        for entry in documents.values {
            guard let document = entry.document else { continue }
            await document.reopen(in: started)
        }
        return started
    }

    private func listen(to server: MeepLanguageServer) {
        listening?.cancel()
        listening = Task { [weak self] in
            for await event in server.events {
                guard let self else { return }
                switch event {
                case .diagnostics(let uri, let diagnostics):
                    self.documents[uri]?.document?.take(diagnostics)
                case .graphChanged(let answer):
                    self.documents[answer.uri]?.document?.take(answer)
                }
            }
            guard let self, !Task.isCancelled, self.server === server else { return }
            self.stoppedByItself()
        }
    }

    /// Says so, and starts it again for the open documents, unless it has stopped three times in a minute.
    private func stoppedByItself() {
        server = nil
        let now = Date()
        stops = stops.filter { now.timeIntervalSince($0) < 60 } + [now]
        state = .unavailable(stops.count > 3 ? "meep lsp keeps stopping." : "meep lsp stopped.")
        if stops.count > 3 { failedAt = now }
        if documents.values.contains(where: { $0.document != nil }) {
            queue.yield { [self] in _ = try? await running() }
        }
    }

    @ObservationIgnored private var stops: [Date] = []
}
