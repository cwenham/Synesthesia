import Foundation

/// Where something is in the Continuum: `meep://<host>/<pipeline>/<module>`, such as `meep://local/ticker/Fetch`.
///
/// The host is the name Synesthesia knows it by ("local" for this Mac's daemon). The module is its key in the
/// pipeline's graph, its name, or its number. The MCP server, the sidebar, links and the breadcrumb all use these.
public struct MeepAddress: Hashable, Sendable, CustomStringConvertible, Codable {
    public var host: String
    public var pipeline: String?
    public var module: String?

    public init(host: String, pipeline: String? = nil, module: String? = nil) {
        self.host = host
        self.pipeline = pipeline
        self.module = pipeline == nil ? nil : module
    }

    /// Reads an address, or returns nil if it isn't one.
    public init?(_ text: String) {
        guard text.hasPrefix("meep://") else { return nil }
        let parts = text.dropFirst("meep://".count).split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).removingPercentEncoding ?? String($0) }
        guard let host = parts.first, !host.isEmpty, parts.count <= 3, !parts.dropFirst().contains(where: \.isEmpty) else {
            return nil
        }
        self.init(host: host, pipeline: parts.count > 1 ? parts[1] : nil, module: parts.count > 2 ? parts[2] : nil)
    }

    public var description: String {
        let parts = [host, pipeline, module].compactMap { $0 }.map(Self.escaped)
        return "meep://" + parts.joined(separator: "/")
    }

    private static let allowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return allowed
    }()

    /// A part escaped as in a URL's path; most need nothing, so they're checked quickly first.
    private static func escaped(_ part: String) -> String {
        let plain = part.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F || byte == 0x2E
        }
        return plain ? part : part.addingPercentEncoding(withAllowedCharacters: allowed) ?? part
    }

    /// The address one level up: a module's pipeline, a pipeline's host. A host is its own parent.
    public var parent: MeepAddress {
        if module != nil { return MeepAddress(host: host, pipeline: pipeline) }
        return MeepAddress(host: host)
    }

    /// The address of a module in this pipeline.
    public func module(_ module: String) -> MeepAddress {
        MeepAddress(host: host, pipeline: pipeline, module: module)
    }

    /// The address of a pipeline on this host.
    public func pipeline(_ pipeline: String) -> MeepAddress {
        MeepAddress(host: host, pipeline: pipeline)
    }
}
