import Foundation
import MeepClient

/// Keeps one ``MeepHost`` up to date: connects to it, lists its pipelines, follows each live one's counts, fetches
/// graphs when they change, and reconnects when the host goes away.
///
/// This is the first, simplest form of the subscription planner in the design (section 4): every live pipeline at
/// one rate. Later it will ask only for what's on screen, within a budget for each host.
@MainActor
public final class HostSession {
    public let host: MeepHost
    private let connect: @Sendable () async throws -> any HostLink
    private let settings: Settings
    private var running: Task<Void, Never>?
    private var following: [String: (token: Int, task: Task<Void, Never>)] = [:]
    private var nextToken = 0
    private let clock = ContinuousClock()
    private let epoch: ContinuousClock.Instant

    public struct Settings: Sendable {
        /// How often each pipeline's counts come.
        public var statsEvery: Duration = .seconds(1)
        /// How often the list of pipelines is asked for again.
        public var listEvery: Duration = .seconds(2)
        /// How long to wait before trying an unreachable host again.
        public var retryAfter: Duration = .seconds(3)

        public init(statsEvery: Duration = .seconds(1), listEvery: Duration = .seconds(2), retryAfter: Duration = .seconds(3)) {
            self.statsEvery = statsEvery
            self.listEvery = listEvery
            self.retryAfter = retryAfter
        }
    }

    public init(host: MeepHost, settings: Settings = Settings(), connect: @escaping @Sendable () async throws -> any HostLink) {
        self.host = host
        self.settings = settings
        self.connect = connect
        epoch = clock.now
    }

    /// Starts keeping the host up to date, until ``stop()``.
    public func start() {
        guard running == nil else { return }
        running = Task { await run() }
    }

    public func stop() {
        running?.cancel()
        running = nil
        stopFollowing()
    }

    private var now: Double {
        let elapsed = clock.now - epoch
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func run() async {
        while !Task.isCancelled {
            if host.status != .connected { host.status = .connecting }
            var link: (any HostLink)?
            do {
                let opened = try await connect()
                link = opened
                host.info = try await opened.info()
                host.status = .connected
                try await follow(opened)
            } catch is CancellationError {
                break
            } catch {
                host.status = .unreachable(error.localizedDescription)
            }
            stopFollowing()
            await link?.close()
            try? await Task.sleep(for: settings.retryAfter)
        }
        stopFollowing()
    }

    /// Lists pipelines every so often, following each live one, until the link fails.
    private func follow(_ link: any HostLink) async throws {
        while !Task.isCancelled {
            host.apply(try await link.pipelines())
            let live = Set(host.pipelines.filter { $0.state.isLive }.map(\.name))
            for name in following.keys where !live.contains(name) {
                following.removeValue(forKey: name)?.task.cancel()
            }
            for name in live where following[name] == nil {
                nextToken += 1
                let token = nextToken
                following[name] = (token, Task { await followStats(of: name, over: link, token: token) })
            }
            for pipeline in host.pipelines where pipeline.graph == nil && !pipeline.state.isLive && pipeline.graphVersion == nil {
                // An ended pipeline's final counts, once, so it doesn't show empty.
                if let detail = try? await link.pipeline(pipeline.name) {
                    pipeline.apply(detail, at: now)
                    await fetchGraph(of: pipeline, over: link)
                }
            }
            try await Task.sleep(for: settings.listEvery)
        }
        throw CancellationError()
    }

    private func followStats(of name: String, over link: any HostLink, token: Int) async {
        do {
            for try await event in link.stats(name, every: settings.statsEvery) {
                guard let pipeline = host.pipeline(name) else { continue }
                switch event {
                case .stats(let detail):
                    pipeline.apply(detail, at: now)
                    if pipeline.needsGraph { await fetchGraph(of: pipeline, over: link) }
                case .graph(let notice):
                    if pipeline.graph?.version != notice.version { await fetchGraph(of: pipeline, over: link) }
                case .end:
                    break
                }
            }
        } catch {
            // The list's next poll notices a lost connection; a stream for a pipeline that went is simply dropped.
        }
        // Let the next look at the list start another, unless one has replaced this already.
        if following[name]?.token == token { following.removeValue(forKey: name) }
    }

    private func fetchGraph(of pipeline: MeepPipeline, over link: any HostLink) async {
        if let graph = try? await link.graph(pipeline.name) {
            pipeline.apply(graph)
        }
    }

    private func stopFollowing() {
        for entry in following.values { entry.task.cancel() }
        following.removeAll()
    }
}
