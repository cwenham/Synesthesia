import FlowKit
import Foundation

/// The modules that run one inflection, wherever they are in the Continuum, with their handling times merged (design,
/// section 4, "Digests"): what the code level's gutter shows beside the inflection's class.
public struct InflectionTimes: Sendable, Equatable {
    /// One module that runs it.
    public struct Use: Sendable, Equatable {
        public var address: MeepAddress
        /// As the canvas labels it.
        public var label: String
        public var hostTitle: String
        /// Its handling times since its pipeline started, once its host has sent them.
        public var timing: HandlingHistogram?
        /// Whether its parameters fit more than one inflection, so its times are counted under each.
        public var shared: Bool

        /// `Prices in orders on Simulated`.
        public var place: String { "\(label) in \(address.pipeline ?? "") on \(hostTitle)" }
    }

    public var uses: [Use]

    /// Every module's times added together.
    public var merged: HandlingHistogram {
        HandlingHistogram.merged(uses.compactMap(\.timing))
    }

    /// The modules whose times have come.
    public var timed: [Use] { uses.filter { $0.timing.map { !$0.isEmpty } ?? false } }

    /// The modules, by pipeline, for asking their hosts for their times.
    public var keysByPipeline: [MeepAddress: Set<String>] {
        uses.reduce(into: [:]) { result, use in
            guard let module = use.address.module else { return }
            result[MeepAddress(host: use.address.host, pipeline: use.address.pipeline), default: []].insert(module)
        }
    }

    /// The whole figures, for hover text: how many handled, the median, 99th percentile, mean, fastest and slowest,
    /// then each module's median and 99th percentile.
    public func summary(named name: String) -> String {
        guard !uses.isEmpty else { return "No module in the Continuum runs \(name)." }
        let modules = uses.count == 1 ? "1 module" : "\(uses.count) modules"
        let merged = merged
        guard !merged.isEmpty else {
            return "\(name) runs in \(modules), with no handling times yet: they come from hosts with subscriptions, while the code shows."
        }
        var lines = ["\(name), from \(timed.count) of \(modules): \(merged.count.formatted()) messages handled."]
        var figures: [String] = []
        if let value = merged.quantile(0.5) { figures.append("median \(TimeText.duration(value))") }
        if let value = merged.quantile(0.99) { figures.append("99th percentile \(TimeText.duration(value))") }
        if let value = merged.mean { figures.append("mean \(TimeText.duration(value))") }
        if let value = merged.min { figures.append("fastest \(TimeText.duration(value))") }
        if let value = merged.max { figures.append("slowest \(TimeText.duration(value))") }
        if !figures.isEmpty { lines.append(figures.joined(separator: ", ").capitalizedFirst + ".") }
        for use in uses {
            guard let timing = use.timing, !timing.isEmpty else {
                lines.append("• \(use.place): no times yet.")
                continue
            }
            let median = timing.quantile(0.5).map(TimeText.duration) ?? "—"
            let p99 = timing.quantile(0.99).map(TimeText.duration) ?? "—"
            lines.append("• \(use.place): median \(median), 99th percentile \(p99), \(timing.count.formatted()) handled\(use.shared ? " (it could be another inflection too, so it's counted under each)" : "").")
        }
        return lines.joined(separator: "\n")
    }
}

extension Continuum {
    /// The modules on every host that run `verb`'s `inflection`, from `plugin` (nil for Meep's own), as their pipelines'
    /// graphs say.
    public func times(ofVerb verb: String, inflection: String, plugin: String?) -> InflectionTimes {
        var uses: [InflectionTimes.Use] = []
        for host in hosts {
            for pipeline in host.pipelines {
                for module in pipeline.modules where module.verb == verb && module.plugin == plugin && module.inflections.contains(inflection) {
                    uses.append(InflectionTimes.Use(
                        address: pipeline.address.module(module.key), label: module.label.isEmpty ? module.verb : module.label,
                        hostTitle: host.title, timing: module.timing, shared: module.inflections.count > 1
                    ))
                }
            }
        }
        return InflectionTimes(uses: uses)
    }
}

/// Durations as people read them: 850 µs, 4.1 ms, 1.2 s.
public enum TimeText {
    public static func duration(_ seconds: Double) -> String {
        switch seconds {
        case ..<0.000_001: return "0 µs"
        case ..<0.001: return "\(Int((seconds * 1_000_000).rounded())) µs"
        case ..<0.01: return (seconds * 1000).formatted(.number.precision(.fractionLength(2))) + " ms"
        case ..<1: return (seconds * 1000).formatted(.number.precision(.fractionLength(seconds < 0.1 ? 1 : 0))) + " ms"
        case ..<60: return seconds.formatted(.number.precision(.fractionLength(seconds < 10 ? 2 : 1))) + " s"
        default: return "\(Int(seconds / 60)) min \(Int(seconds.truncatingRemainder(dividingBy: 60))) s"
        }
    }

    /// Short, for a gutter: 850µs, 4.1ms, 1.2s.
    public static func compact(_ seconds: Double) -> String {
        switch seconds {
        case ..<0.001: return "\(Int((seconds * 1_000_000).rounded()))µs"
        case ..<0.01: return (seconds * 1000).formatted(.number.precision(.fractionLength(1))) + "ms"
        case ..<1: return "\(Int((seconds * 1000).rounded()))ms"
        default: return seconds.formatted(.number.precision(.fractionLength(1))) + "s"
        }
    }
}

extension String {
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
