import Foundation
import Transport

/// The hosts the person has added, and the budget each host's connection keeps to, kept in Application Support
/// (design, section 9, "Storage") as JSON.
public struct HostStore: Codable, Sendable, Equatable {
    /// A host on another machine, reached through SSH.
    public struct Remote: Codable, Sendable, Equatable {
        /// The name in its addresses: `meep://<name>/…`.
        public var name: String
        public var title: String
        public var target: SSHTarget
        /// Bytes a second; nil for no limit.
        public var budget: Double?

        public init(name: String, title: String, target: SSHTarget, budget: Double?) {
            self.name = name
            self.title = title
            self.target = target
            self.budget = budget
        }
    }

    public var remotes: [Remote] = []
    /// Budgets the person set for the hosts that aren't added, such as `local`, by name. A budget of 0 is none.
    public var budgets: [String: Double] = [:]

    public init(remotes: [Remote] = [], budgets: [String: Double] = [:]) {
        self.remotes = remotes
        self.budgets = budgets
    }

    /// `$SYNESTHESIA_HOSTS`, or `~/Library/Application Support/Synesthesia/hosts.json`.
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["SYNESTHESIA_HOSTS"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Synesthesia/hosts.json")
    }

    /// What's kept at `url`, or nothing if there's nothing there yet or it can't be read.
    public static func load(from url: URL = defaultURL) -> HostStore {
        guard let data = try? Data(contentsOf: url), let store = try? JSONDecoder().decode(HostStore.self, from: data) else { return HostStore() }
        return store
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// A name for a new host's addresses, from what it's called: lower case, with dashes, not one already taken.
    public static func name(for title: String, taken: Set<String>) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        var base = String(title.lowercased().map { allowed.contains($0) ? $0 : "-" })
        while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "host" }
        var name = base
        var number = 2
        while taken.contains(name) {
            name = "\(base)-\(number)"
            number += 1
        }
        return name
    }
}
