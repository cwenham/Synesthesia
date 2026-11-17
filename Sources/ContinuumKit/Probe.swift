import Foundation
import MeepClient
import Observation

/// A probe on a module's output or a wire (design, section 6): a debug tap through the host, keeping the latest
/// messages, newest first, and counting those it couldn't show.
@MainActor @Observable
public final class Probe: Identifiable {
    /// What it's on: a module's output, or one wire, by key.
    public enum Target: Hashable, Codable, Sendable {
        case module(String)
        case wire(String)
    }

    public enum State: Equatable, Sendable {
        case starting
        case running
        case paused
        /// The tap ended, and why: the pipeline stopped, or the condition was refused.
        case ended(String)
    }

    public nonisolated let id = UUID()
    public let pipeline: MeepPipeline
    public let host: MeepHost
    public let target: Target
    /// A Meeplang condition on `msg`, as `Where` takes; empty for every message.
    public var condition: String { didSet { if condition != oldValue { restart() } } }
    /// The share of messages shown, from just over 0 to 1.
    public var sample: Double { didSet { if sample != oldValue { restart() } } }
    /// Kept with the pipeline's file, in `.synesthesia/probes.json`, to open again with it.
    public var isSaved = false
    /// Which of the probes' colours it's drawn in.
    public let colorIndex: Int
    /// The latest messages, newest first, up to ``keep``.
    public private(set) var messages: [TappedMessage] = []
    /// When each message arrived, by its id, in seconds on the system's steady clock, for drawing it on the canvas.
    public private(set) var arrivals: [(id: String, time: Double, isError: Bool)] = []
    /// Messages the tap left out because its reader fell behind, since it opened.
    public private(set) var notShown: Int64 = 0
    /// Messages seen since it opened.
    public private(set) var seen = 0
    public private(set) var state: State = .starting
    /// How many messages it keeps.
    public var keep = 200

    @ObservationIgnored private var tapping: Task<Void, Never>?
    @ObservationIgnored private var tappedNumber: Int?
    @ObservationIgnored private var droppedBefore: Int64 = 0

    public init(pipeline: MeepPipeline, host: MeepHost, target: Target, condition: String = "", sample: Double = 1, colorIndex: Int = 0) {
        self.pipeline = pipeline
        self.host = host
        self.target = target
        self.condition = condition
        self.sample = sample
        self.colorIndex = colorIndex
    }

    /// The module whose output is tapped: the module itself, or a wire's source.
    public var tappedKey: String? {
        switch target {
        case .module(let key): key
        case .wire(let key): pipeline.link(key)?.from ?? key.split(separator: ">").first.map(String.init)
        }
    }

    /// What it's on, in words.
    public var title: String {
        switch target {
        case .module(let key):
            return (pipeline.module(key)?.label ?? key) + " out"
        case .wire(let key):
            let link = pipeline.link(key)
            let from = link.flatMap { pipeline.module($0.from)?.label } ?? key
            let to = link.flatMap { pipeline.module($0.to)?.label } ?? ""
            return "\(from) → \(to)" + (link?.port == .errors ? " (errors)" : "")
        }
    }

    /// The condition the tap is opened with: a wire into an @errors module carries only errors.
    public var tapCondition: String? {
        let given = condition.trimmingCharacters(in: .whitespaces)
        var errorsOnly = false
        if case .wire(let key) = target, pipeline.link(key)?.port == .errors { errorsOnly = true }
        switch (errorsOnly, given.isEmpty) {
        case (false, true): return nil
        case (false, false): return given
        case (true, true): return "msg is ErrorMessage"
        case (true, false): return "(msg is ErrorMessage) and (\(given))"
        }
    }

    // MARK: Tapping

    /// Opens the tap, and opens it again if the module's number changes in a reload.
    public func start() {
        guard tapping == nil else { return }
        state = .starting
        followGraph()
        tapping = Task { [weak self] in await self?.tap() }
    }

    public func stop() {
        tapping?.cancel()
        tapping = nil
        if state == .running || state == .starting { state = .paused }
    }

    /// Stops for now, keeping what it has.
    public func pause() {
        stop()
        state = .paused
    }

    public func clear() {
        messages.removeAll()
        arrivals.removeAll()
        seen = 0
        notShown = 0
    }

    private func restart() {
        guard tapping != nil || state == .starting else { return }
        stop()
        start()
    }

    private func tap() async {
        guard let key = tappedKey, let module = pipeline.module(key), let link = host.link else {
            state = .ended("\(host.title) can't be reached, or the module has gone.")
            tapping = nil
            return
        }
        tappedNumber = module.number
        droppedBefore = -1
        do {
            state = .running
            for try await event in link.tap(pipeline.name, module: "\(module.number)", where: tapCondition, sample: sample < 1 ? sample : nil) {
                take(event)
            }
            if !Task.isCancelled { state = .ended("\(pipeline.name) has stopped.") }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { state = .ended(error.localizedDescription) }
        }
        if !Task.isCancelled { tapping = nil }
    }

    /// Takes a message the tap saw.
    func take(_ event: TapEvent) {
        if droppedBefore < 0 { droppedBefore = event.dropped }
        notShown = max(0, event.dropped - droppedBefore)
        seen += 1
        messages.insert(event.message, at: 0)
        if messages.count > keep { messages.removeLast(messages.count - keep) }
        let now = ProcessInfo.processInfo.systemUptime
        arrivals = arrivals.filter { now - $0.time < 3 } + [(event.message.id, now, event.message.isError)]
    }

    /// Opens the tap again when a reload changes the module's number, since the daemon finds modules by number.
    private func followGraph() {
        withObservationTracking {
            _ = pipeline.graph?.version
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.tapping != nil else { return }
                if let key = self.tappedKey, let number = self.pipeline.module(key)?.number, number != self.tappedNumber {
                    self.restart()
                } else {
                    self.followGraph()
                }
            }
        }
    }
}

/// Probes kept with a pipeline's file, in `.synesthesia/probes.json` beside it (design, Q7), so a debugging setup
/// opens again with the pipeline.
public enum ProbeStore {
    public struct Saved: Codable, Equatable, Sendable {
        /// The pipeline's file name, as several pipelines' files can share a folder.
        public var file: String
        public var target: Probe.Target
        /// What it was on when saved, for finding it again if keys have changed.
        public var label: String
        public var condition: String
        public var sample: Double

        public init(file: String, target: Probe.Target, label: String, condition: String, sample: Double) {
            self.file = file
            self.target = target
            self.label = label
            self.condition = condition
            self.sample = sample
        }
    }

    struct File: Codable {
        var probes: [Saved]
    }

    /// Where a pipeline's folder keeps them.
    public static func url(besides pipelineFile: String) -> URL {
        URL(fileURLWithPath: pipelineFile).deletingLastPathComponent().appendingPathComponent(".synesthesia/probes.json")
    }

    /// The probes saved for a pipeline's file.
    public static func load(for pipelineFile: String) -> [Saved] {
        let name = (pipelineFile as NSString).lastPathComponent
        guard let data = try? Data(contentsOf: url(besides: pipelineFile)),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.probes.filter { $0.file == name }
    }

    /// Saves a pipeline's probes, keeping other files' in the same folder.
    public static func save(_ probes: [Saved], for pipelineFile: String) throws {
        let name = (pipelineFile as NSString).lastPathComponent
        let url = url(besides: pipelineFile)
        var all = (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url)))?.probes ?? []
        all.removeAll { $0.file == name }
        all += probes
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(probes: all)).write(to: url, options: .atomic)
    }
}
