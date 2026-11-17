import Foundation
import MeepClient

/// Keeps one ``MeepHost`` up to date: connects to it, lists its pipelines, follows each live one's counts, fetches
/// graphs when they change, and reconnects when the host goes away.
///
/// This is the first, simplest form of the subscription planner in the design (section 4): every live pipeline once a
/// second, and those a view is showing in detail (``MeepPipeline/watchers``) several times a second. Later it will
/// ask only for what's on screen, within a budget for each host.
@MainActor
public final class HostSession {
    public let host: MeepHost
    private let connect: @Sendable () async throws -> any HostLink
    private let settings: Settings
    private var running: Task<Void, Never>?
    private var following: [String: (token: Int, every: Duration, task: Task<Void, Never>)] = [:]
    private var nextToken = 0
    private let clock = ContinuousClock()
    private let epoch: ContinuousClock.Instant

    public struct Settings: Sendable {
        /// How often each pipeline's counts come.
        public var statsEvery: Duration = .seconds(1)
        /// How often the counts come for a pipeline a view is showing in detail.
        public var watchedStatsEvery: Duration = .milliseconds(200)
        /// How often the list of pipelines is asked for again.
        public var listEvery: Duration = .seconds(2)
        /// How long to wait before trying an unreachable host again.
        public var retryAfter: Duration = .seconds(3)

        public init(
            statsEvery: Duration = .seconds(1), watchedStatsEvery: Duration = .milliseconds(200),
            listEvery: Duration = .seconds(2), retryAfter: Duration = .seconds(3)
        ) {
            self.statsEvery = statsEvery
            self.watchedStatsEvery = watchedStatsEvery
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
        host.link = nil
        stopFollowing()
    }

    private var now: Double {
        let elapsed = clock.now - epoch
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func run() async {
        while !Task.isCancelled {
            // A host that can't be reached keeps saying why while it's tried again, rather than flickering.
            if case .unreachable = host.status {} else if host.status != .connected { host.status = .connecting }
            var link: (any HostLink)?
            do {
                let opened = try await connect()
                link = opened
                host.info = try await opened.info()
                host.status = .connected
                host.link = opened
                try await follow(opened)
            } catch is CancellationError {
                break
            } catch {
                host.status = .unreachable(error.localizedDescription)
            }
            stopFollowing()
            host.link = nil
            await link?.close()
            try? await Task.sleep(for: settings.retryAfter)
        }
        stopFollowing()
    }

    /// Lists pipelines every so often, following each live one, until the link fails. Between lists it looks a few
    /// times a second for pipelines that a view has started or stopped showing, to change how often their counts come.
    private func follow(_ link: any HostLink) async throws {
        var listed: ContinuousClock.Instant?
        while !Task.isCancelled {
            if listed.map({ clock.now - $0 >= settings.listEvery }) ?? true {
                listed = clock.now
                host.apply(try await link.pipelines())
                for pipeline in host.pipelines where pipeline.graph == nil && !pipeline.state.isLive && pipeline.graphVersion == nil {
                    // An ended pipeline's final counts, once, so it doesn't show empty.
                    if let detail = try? await link.pipeline(pipeline.name) {
                        pipeline.apply(detail, at: now)
                        await fetchGraph(of: pipeline, over: link)
                    }
                }
            }
            followLive(over: link)
            try await Task.sleep(for: min(settings.listEvery, .milliseconds(250)))
        }
        throw CancellationError()
    }

    /// Starts and stops following pipelines' counts as they come and go, at the rate each needs.
    private func followLive(over link: any HostLink) {
        let live = Dictionary(uniqueKeysWithValues: host.pipelines.filter { $0.state.isLive }.map {
            ($0.name, $0.watchers > 0 ? settings.watchedStatsEvery : settings.statsEvery)
        })
        for (name, entry) in following where live[name] != entry.every {
            following.removeValue(forKey: name)
            entry.task.cancel()
        }
        for (name, every) in live where following[name] == nil {
            nextToken += 1
            let token = nextToken
            following[name] = (token, every, Task { await followStats(of: name, every: every, over: link, token: token) })
        }
    }

    private func followStats(of name: String, every: Duration, over link: any HostLink, token: Int) async {
        do {
            for try await event in link.stats(name, every: every) {
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
