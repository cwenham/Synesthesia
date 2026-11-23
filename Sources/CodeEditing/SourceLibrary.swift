import CryptoKit
import Foundation
import LanguageClient

/// Reads an inflection's C# for the code level (design, section 2, level 1), from where Meep's verb catalogue says it
/// is (`meep/verbs`' `source`, read from the PDB):
///
/// 1. the file, when it's on this Mac;
/// 2. otherwise the SourceLink address, read over HTTPS and kept in a cache, since it's pinned to a commit and never
///    changes;
/// 3. otherwise nothing, with why.
public actor SourceLibrary {
    private let cache: URL?
    private let fetcher: any SourceFetching
    private var fetching: [String: Task<Data, any Error>] = [:]

    /// With `cache` nil, what's read over HTTPS is kept only in memory.
    public init(cache: URL? = SourceLibrary.defaultCache, fetcher: any SourceFetching = URLSessionSourceFetcher()) {
        self.cache = cache
        self.fetcher = fetcher
    }

    /// `~/Library/Caches/Synesthesia/SourceLink`.
    public static var defaultCache: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Synesthesia", isDirectory: true).appendingPathComponent("SourceLink", isDirectory: true)
    }

    /// The C# of an inflection, or why there's none. `plugin` is named in the reason when a plugin has no PDB.
    public func source(of location: VerbEntry.Source?, plugin: String?) async -> SourceOutcome {
        guard let location, location.file != nil || location.url != nil else {
            return .unavailable(.noLocation(plugin: plugin))
        }
        if let path = location.file, let text = Self.readLocal(path) {
            return .loaded(SourceFile(text: text, origin: .file(path)))
        }
        guard let address = location.url else {
            return .unavailable(.fileMissing(path: location.file ?? ""))
        }
        guard let url = URL(string: address), url.scheme?.lowercased() == "https" else {
            return .unavailable(.fetchFailed(url: address, reason: "it isn't an https address"))
        }
        if let data = readCached(address) {
            guard let text = Self.text(data) else { return .unavailable(.notText(url: address)) }
            return .loaded(SourceFile(text: text, origin: .sourceLink(url: address, cached: true)))
        }
        do {
            let data = try await fetch(url, key: address)
            guard let text = Self.text(data) else { return .unavailable(.notText(url: address)) }
            writeCached(data, for: address)
            return .loaded(SourceFile(text: text, origin: .sourceLink(url: address, cached: false)))
        } catch is CancellationError {
            return .unavailable(.fetchFailed(url: address, reason: "it was cancelled"))
        } catch {
            return .unavailable(.fetchFailed(url: address, reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    /// Fetches each address once at a time, however many inflections in its file ask.
    private func fetch(_ url: URL, key: String) async throws -> Data {
        if let running = fetching[key] { return try await running.value }
        let fetcher = fetcher
        let task = Task { try await fetcher.fetch(url) }
        fetching[key] = task
        defer { fetching[key] = nil }
        return try await task.value
    }

    private static func readLocal(_ path: String) -> String? {
        guard FileManager.default.isReadableFile(atPath: path), let data = FileManager.default.contents(atPath: path) else { return nil }
        return text(data)
    }

    /// UTF-8, with or without a byte-order mark; anything else isn't shown as C#.
    private static func text(_ data: Data) -> String? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // Windows line endings would show as two breaks to a line in some views, and offsets count one.
        if text.contains("\r\n") { text = text.replacingOccurrences(of: "\r\n", with: "\n") }
        return text
    }

    // MARK: The cache

    private func cacheFile(for address: String) -> URL? {
        let digest = SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = (URL(string: address)?.pathExtension).flatMap { $0.isEmpty ? nil : $0 } ?? "txt"
        return cache?.appendingPathComponent("\(digest).\(ext)")
    }

    private func readCached(_ address: String) -> Data? {
        guard let file = cacheFile(for: address) else { return memory[address] }
        return FileManager.default.contents(atPath: file.path)
    }

    private var memory: [String: Data] = [:]

    private func writeCached(_ data: Data, for address: String) {
        guard let file = cacheFile(for: address) else {
            memory[address] = data
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

/// An inflection's C#, and where it came from.
public struct SourceFile: Sendable, Equatable {
    public var text: String
    public var origin: Origin

    public enum Origin: Sendable, Equatable {
        /// The file on this Mac.
        case file(String)
        /// Read over HTTPS from the SourceLink address, now or before (`cached`).
        case sourceLink(url: String, cached: Bool)
    }

    public init(text: String, origin: Origin) {
        self.text = text
        self.origin = origin
    }

    /// The file or address: two inflections with the same one share their file.
    public var identity: String {
        switch origin {
        case .file(let path): path
        case .sourceLink(let url, _): url
        }
    }
}

/// What reading an inflection's C# came to.
public enum SourceOutcome: Sendable, Equatable {
    case loaded(SourceFile)
    case unavailable(SourceProblem)

    public var file: SourceFile? {
        if case .loaded(let file) = self { return file }
        return nil
    }
}

/// Why there's no C# to show, said plainly.
public enum SourceProblem: Sendable, Equatable {
    /// The catalogue doesn't say where it is: a plugin without its PDB, usually.
    case noLocation(plugin: String?)
    /// The PDB names a file that isn't on this Mac, and has no SourceLink.
    case fileMissing(path: String)
    /// Reading the SourceLink address failed.
    case fetchFailed(url: String, reason: String)
    /// What came back isn't text.
    case notText(url: String)
    /// The module runs on another host from a plugin this Mac hasn't got.
    case pluginNotHere(plugin: String, host: String)
    /// This Mac's Meep doesn't know the verb at all.
    case unknownVerb(verb: String, host: String?)
    /// The verb catalogue couldn't be read.
    case noCatalogue(reason: String)

    public var message: String {
        switch self {
        case .noLocation(let plugin?):
            "The plugin \(plugin) doesn't ship its PDB, so Meep can't say where its C# is."
        case .noLocation(nil):
            "Meep's catalogue doesn't say where its C# is: its assembly has no PDB beside it."
        case .fileMissing(let path):
            "Its file, \(path), isn't on this Mac, and its PDB has no SourceLink address to read it from."
        case .fetchFailed(let url, let reason):
            "Its file isn't on this Mac, and reading it from \(URL(string: url)?.host ?? url) failed: \(reason)"
        case .notText(let url):
            "What \(URL(string: url)?.host ?? url) sent for it isn't text."
        case .pluginNotHere(let plugin, let host):
            "\(host) runs it from the plugin \(plugin), which isn't on this Mac, so its C# isn't here."
        case .unknownVerb(let verb, let host?):
            "This Mac's Meep doesn't know \(verb), so its C# isn't here. \(host) may have it from a plugin that isn't on this Mac."
        case .unknownVerb(let verb, nil):
            "Meep's catalogue doesn't know \(verb)."
        case .noCatalogue(let reason):
            "Meep's verb catalogue couldn't be read: \(reason)"
        }
    }

    /// Whether trying again could help.
    public var canRetry: Bool {
        switch self {
        case .fetchFailed, .noCatalogue: true
        default: false
        }
    }
}

/// Reads an address over HTTPS: `URLSession` in the app, a fake in the tests.
public protocol SourceFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

/// Reads over HTTPS with an ephemeral session, so nothing is kept but what ``SourceLibrary`` keeps.
public struct URLSessionSourceFetcher: SourceFetching {
    /// The most a source file may be.
    public static let limit = 8 << 20

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["Accept": "text/plain, */*"]
        session = URLSession(configuration: configuration)
    }

    public func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceFetchError.status(http.statusCode)
        }
        guard data.count <= Self.limit else { throw SourceFetchError.tooLarge(data.count) }
        return data
    }
}

public enum SourceFetchError: Error, LocalizedError, Equatable {
    case status(Int)
    case tooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .status(404): "it isn't there (404): the repository may be private, or the commit not pushed"
        case .status(let code): "the server answered \(code)"
        case .tooLarge(let bytes): "it's \(bytes / 1_048_576) MB, too large to show"
        }
    }
}

/// The page to open in a browser for a SourceLink address: GitHub's page for the file, at the line, rather than the raw
/// text the address gives.
public enum SourceLinkPage {
    public static func page(for address: String, line: Int?) -> URL? {
        guard let url = URL(string: address) else { return nil }
        guard url.host?.lowercased() == "raw.githubusercontent.com" else { return url }
        // /owner/repo/commit/path…
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return url }
        let rest = parts[3...].joined(separator: "/")
        var page = "https://github.com/\(parts[0])/\(parts[1])/blob/\(parts[2])/\(rest)"
        if let line { page += "#L\(line)" }
        return URL(string: page) ?? url
    }

    /// The commit a GitHub SourceLink address is pinned to, shortened, for saying where the text came from.
    public static func commit(of address: String) -> String? {
        guard let url = URL(string: address), url.host?.lowercased() == "raw.githubusercontent.com" else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return nil }
        return String(parts[2].prefix(7))
    }

    /// The site, such as GitHub, for saying where the text came from.
    public static func site(of address: String) -> String {
        guard let host = URL(string: address)?.host?.lowercased() else { return address }
        if host == "raw.githubusercontent.com" || host.hasSuffix("github.com") { return "GitHub" }
        if host.contains("gitlab") { return "GitLab" }
        if host.contains("bitbucket") { return "Bitbucket" }
        if host.contains("dev.azure.com") || host.contains("visualstudio.com") { return "Azure DevOps" }
        return host
    }
}
