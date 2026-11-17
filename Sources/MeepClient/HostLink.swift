import Foundation

/// What Synesthesia needs from a host: a real Meep daemon (``DaemonConnection``), or a pretend one from the
/// Simulation package. The rest of the app can't tell them apart, which is how a remote host, the local one and a
/// simulated one all look the same.
public protocol HostLink: Sendable {
    /// What the host says about itself.
    func info() async throws -> DaemonInfo

    /// The pipelines it runs, or ran recently.
    func pipelines() async throws -> [PipelineSummary]

    /// One pipeline, with its modules and their counts.
    func pipeline(_ name: String) async throws -> PipelineDetail

    /// One pipeline's graph.
    func graph(_ name: String) async throws -> PipelineGraph

    /// The text a pipeline runs: its file as loaded or last reloaded, with any edits made through the API since.
    func source(_ name: String) async throws -> SourceText

    /// Loads a pipeline's file again and applies the changes, keeping matched modules' state. Fails, leaving it
    /// running as it was, when the file doesn't load.
    func reload(_ name: String) async throws

    /// A pipeline's counts every so often, and notices when its graph changes, until it ends or the stream is
    /// dropped. A restarted pipeline's counts start again from zero.
    func stats(_ name: String, every interval: Duration) -> AsyncThrowingStream<StatsEvent, any Error>

    /// Closes the link. Streams end, and waiting requests fail.
    func close() async
}

/// One event from ``HostLink/stats(_:every:)``.
public enum StatsEvent: Sendable, Equatable {
    /// The pipeline and its modules' counts now.
    case stats(PipelineDetail)
    /// Its graph has a new version.
    case graph(GraphNotice)
    /// The stream has ended, and why.
    case end(String)
}

/// Why a request to a host failed.
public enum HostError: Error, Equatable, LocalizedError {
    /// The host answered with a refusal.
    case refused(status: Int, message: String, details: [String])
    /// The connection to the host has gone.
    case disconnected(String)
    /// The host sent something this version can't read.
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .refused(_, let message, let details): ([message] + details).joined(separator: "\n")
        case .disconnected(let reason): reason
        case .unreadable(let reason): reason
        }
    }
}

extension Duration {
    /// The duration as the daemon writes them, such as `500ms`.
    var meepText: String {
        let milliseconds = max(50, Int((Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15).rounded()))
        return milliseconds % 1000 == 0 ? "\(milliseconds / 1000)s" : "\(milliseconds)ms"
    }
}
