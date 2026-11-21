import FlowKit
import Foundation
import MeepClient

// Flows between pipelines, and the boundary (design, section 3), from what Meep2 a5de139 gives: each Listen's arrivals
// by origin or client address, each Fetch's and Send's destinations by endpoint with which are Meep hosts (`peers`),
// the clients' names, and the addresses Fetches and Sends declare (`sends`). Its report's "What a client has to do" is
// the contract: Synesthesia matches addresses itself, and never works out Meeplang.

/// The parts of a network address: a Listen's or a Send's (`http://studio.local:8080/in/`), or an endpoint as
/// destinations are keyed (`studio.local:8080`).
public struct NetworkAddress: Sendable, Hashable {
    public enum Family: Sendable, Hashable {
        /// HTTP and WebSocket, which can share a port.
        case web
        case tcp
        case other(String)
    }

    /// `http`, `https`, `ws`, `wss` or `tcp`; nil for an endpoint, which says only where.
    public var scheme: String?
    /// In lower case, without an IPv6 address's brackets.
    public var host: String
    public var port: Int?
    /// From its first `/`, without the query; nil for an endpoint or TCP.
    public var path: String?
    /// For an address worked out for each message: the path is only known this far.
    public var pathIsPartial = false

    public var family: Family? {
        switch scheme {
        case nil: nil
        case "http", "https", "ws", "wss": .web
        case "tcp": .tcp
        case let other?: .other(other)
        }
    }

    /// An endpoint, `host:port` or `[v6]:port`.
    public static func endpoint(_ text: String) -> NetworkAddress? {
        let (host, port) = splitHostPort(text)
        guard !host.isEmpty, let port else { return nil }
        return NetworkAddress(scheme: nil, host: host, port: port, path: nil)
    }

    /// A Listen's or a Send's address. One worked out for each message is read as far as its first `{`; nil when
    /// that leaves no host.
    public static func address(_ text: String, computed: Bool = false) -> NetworkAddress? {
        var literal = text.trimmingCharacters(in: .whitespaces)
        if literal.hasPrefix("\""), literal.count > 1 { literal.removeFirst() }
        if literal.hasSuffix("\"") { literal.removeLast() }
        var partial = false
        if computed || literal.contains("{"), let brace = literal.firstIndex(of: "{") {
            literal = String(literal[..<brace])
            partial = true
        }
        guard let schemeEnd = literal.range(of: "://") else { return nil }
        let scheme = literal[..<schemeEnd.lowerBound].lowercased()
        let rest = literal[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        // A brace inside the authority leaves the host or port unknown.
        if partial, authorityEnd == rest.endIndex { return nil }
        let (host, explicitPort) = splitHostPort(String(rest[..<authorityEnd]))
        guard !host.isEmpty else { return nil }
        let port = explicitPort ?? (scheme == "https" || scheme == "wss" ? 443 : scheme == "http" || scheme == "ws" ? 80 : nil)
        var path: String?
        var pathIsPartial = false
        if scheme != "tcp" {
            let remainder = rest[authorityEnd...]
            let queryStart = remainder.firstIndex { $0 == "?" || $0 == "#" }
            path = queryStart.map { String(remainder[..<$0]) } ?? String(remainder)
            if path?.isEmpty ?? true { path = "/" }
            // Cut inside the path, its end is unknown; cut in the query, the path is whole.
            pathIsPartial = partial && queryStart == nil
        }
        return NetworkAddress(scheme: scheme, host: host, port: port, path: path, pathIsPartial: pathIsPartial)
    }

    private static func splitHostPort(_ text: String) -> (String, Int?) {
        let text = text.lowercased()
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let after = text[text.index(after: close)...]
            return (host, after.hasPrefix(":") ? Int(after.dropFirst()) : nil)
        }
        // A bare IPv6 address has several colons and no port.
        if text.filter({ $0 == ":" }).count > 1 { return (text, nil) }
        guard let colon = text.lastIndex(of: ":") else { return (text, nil) }
        return (String(text[..<colon]), Int(text[text.index(after: colon)...]))
    }

    /// `localhost`, `::1` or any of 127.0.0.0/8: this machine, whichever it is.
    public static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    /// A Listen bound to every address the machine has.
    public static func isWildcard(_ host: String) -> Bool {
        ["0.0.0.0", "::", "*", "+", ""].contains(host)
    }

    public static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// The domain a name belongs to, for grouping the boundary's endpoints: `api.example.com` is `example.com`,
    /// `shop.example.co.uk` is `example.co.uk`. Addresses and single names are their own.
    public static func domain(of name: String) -> String {
        let host = name.lowercased()
        guard !isIPAddress(host) else { return host }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        let second = labels[labels.count - 2]
        let last = labels[labels.count - 1]
        if last.count == 2, ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"].contains(second) {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }
}

/// A flow between two pipelines' modules, on one host or across hosts: a Fetch or Send reaching a Listen.
public struct MeshFlow: Identifiable, Sendable, Equatable {
    /// `<from> > <to>`.
    public var id: String
    /// The Fetch or Send: a module on a host Synesthesia follows.
    public var from: MeepAddress
    /// The Listen; or its host alone, when its destinations say it's that host but not which Listen.
    public var to: MeepAddress
    public var fromLabel: String
    public var toLabel: String
    /// Its address matches the Listen's: a guess, which works before anything runs. Drawn dashed until observed.
    public var declared: Bool
    /// Messages were seen to cross: an arrival by origin, or a destination that says it's Meep.
    public var observed: Bool
    /// Seen only by address, as over TCP, which carries no origin.
    public var byAddress: Bool
    /// Messages sent along it so far, for single particles.
    public var count: Int64
    /// Messages a second along it, and replies back.
    public var rate: Double
    public var replies: Double
    /// Failures (5xx, no answer) and rejections (4xx) a second.
    public var failed: Double
    public var rejected: Double
    /// Bytes a second, each way.
    public var bytesOut: Double
    public var bytesBack: Double
    /// Whether its rates are current: its counts are being followed now, from a host that can be reached.
    public var current = true

    /// Whether both ends are in one pipeline, as a Fetch asking its own pipeline's Listen.
    public var isWithinPipeline: Bool { from.host == to.host && from.pipeline == to.pipeline }
    /// Whether it crosses between hosts.
    public var crossesHosts: Bool { from.host != to.host }

    /// How it's known, in words.
    public var evidence: String {
        switch (declared, observed) {
        case (true, true): byAddress ? "declared, and seen by address" : "declared and observed"
        case (false, true): byAddress ? "seen by address" : "observed"
        default: "declared only: nothing seen yet"
        }
    }
}

/// An endpoint outside the Continuum: a client outside Meep, an API or broker a Fetch or Send reaches, another Meep
/// Synesthesia doesn't follow, or everything past modules' limits.
public struct BoundaryEndpoint: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// Not built on Meep.
        case outside
        /// A Meep daemon Synesthesia doesn't follow, or a `meep run`, by its ID.
        case otherMeep
        /// Everything past a module's limit (`*`, or `meep://*`), and what was folded there.
        case pastLimit
    }

    public var id: String
    public var kind: Kind
    /// What it's called: its name, its address, or which Meep.
    public var name: String
    /// The group it's drawn in: its domain, `Meep` for other Meeps, or nothing for what's past limits.
    public var domain: String
    /// The addresses and `host:port`s it's known by.
    public var places: [String]
    /// Each module that talks to it, and how.
    public var links: [BoundaryLink]

    /// Messages a second from it into the Continuum, and to it from the Continuum.
    public var rateIn: Double { links.reduce(0) { $0 + $1.rateIn } }
    public var rateOut: Double { links.reduce(0) { $0 + $1.rateOut } }
    public var failed: Double { links.reduce(0) { $0 + $1.failed } }
    public var rejected: Double { links.reduce(0) { $0 + $1.rejected } }
    public var bytesIn: Double { links.reduce(0) { $0 + $1.bytesIn } }
    public var bytesOut: Double { links.reduce(0) { $0 + $1.bytesOut } }
    /// Messages a second either way: how much it matters, for placing labels.
    public var traffic: Double { rateIn + rateOut }
    /// Known only from a declared address: nothing has been seen to cross.
    public var isDeclaredOnly: Bool { links.allSatisfy { !$0.observed } }
}

/// One module's traffic with a boundary endpoint.
public struct BoundaryLink: Identifiable, Sendable, Equatable {
    public enum Direction: String, Sendable {
        /// Into a Listen, from a client.
        case inbound
        /// From a Fetch or Send, to what it reaches.
        case outbound
    }

    public var id: String
    public var module: MeepAddress
    public var moduleLabel: String
    /// The place it's counted under: a client's address, `host:port`, a `meep://` origin, or `*`.
    public var place: String
    public var direction: Direction
    /// Messages have been counted; false for a declared address only.
    public var observed: Bool
    /// Messages crossing so far (requests in for a Listen, requests out for a Fetch or Send), for single particles.
    public var count: Int64
    /// Messages a second into the Continuum (requests to a Listen, replies to a Fetch) and out of it.
    public var rateIn: Double
    public var rateOut: Double
    public var failed: Double
    public var rejected: Double
    public var bytesIn: Double
    public var bytesOut: Double
    /// Whether its rates are current: its counts are being followed now, from a host that can be reached.
    public var current = true

    /// Messages a second in the direction it was started: what a client sends, or what a Fetch or Send sends.
    public var rate: Double { direction == .inbound ? rateIn : rateOut }
}

/// Every flow between pipelines and every endpoint on the boundary, worked out from the Continuum as it is now.
public struct FlowMap: Sendable, Equatable {
    public var flows: [MeshFlow] = []
    public var boundary: [BoundaryEndpoint] = []

    public init(flows: [MeshFlow] = [], boundary: [BoundaryEndpoint] = []) {
        self.flows = flows
        self.boundary = boundary
    }

    /// The flows into or out of a pipeline, or a host's pipelines.
    public func flows(touching address: MeepAddress) -> [MeshFlow] {
        flows.filter { touches($0.from, address) || touches($0.to, address) }
    }

    /// The boundary's links with a pipeline, or a host's pipelines.
    public func boundaryLinks(touching address: MeepAddress) -> [(BoundaryEndpoint, BoundaryLink)] {
        boundary.flatMap { endpoint in endpoint.links.filter { touches($0.module, address) }.map { (endpoint, $0) } }
    }

    private func touches(_ end: MeepAddress, _ address: MeepAddress) -> Bool {
        end.host == address.host && (address.pipeline == nil || end.pipeline == address.pipeline)
            && (address.module == nil || end.module == address.module)
    }
}

extension Continuum {
    /// The flows and the boundary as they are now.
    public func flowMap() -> FlowMap {
        FlowMapBuilder(hosts: hosts).build()
    }

    /// The Listens on known hosts that a Fetch's or Send's endpoint reaches, best first: on the port it names, at an
    /// address that reaches it, and with a path that fits, the longest first.
    public func listens(reachedBy endpoint: String, address: String? = nil, computed: Bool = false, from sender: MeepHost) -> [(MeepHost, ListenAddress)] {
        FlowMapBuilder(hosts: hosts).listens(reachedBy: endpoint, address: address, computed: computed, from: sender)
    }
}

/// Works out a ``FlowMap``.
@MainActor
final class FlowMapBuilder {
    let hosts: [MeepHost]
    private let byID: [String: MeepHost]
    /// Clients' names from every pipeline, so a destination at an address a client came from gets its name.
    private let names: [String: String]
    /// What's worked out more than once while building: addresses read, hosts' names, machines and labels.
    private var parsed: [String: NetworkAddress?] = [:]
    private var knownNames: [ObjectIdentifier: Set<String>] = [:]
    private var machines: [ObjectIdentifier: Set<String>] = [:]
    private var labels: [MeepAddress: String] = [:]

    init(hosts: [MeepHost]) {
        self.hosts = hosts
        var byID: [String: MeepHost] = [:]
        var names: [String: String] = [:]
        for host in hosts {
            if let id = host.identity?.id { byID[id] = host }
            for pipeline in host.pipelines {
                names.merge(pipeline.clients) { first, _ in first }
            }
        }
        self.byID = byID
        self.names = names
    }

    private func address(_ text: String, computed: Bool = false) -> NetworkAddress? {
        let key = computed ? "{}" + text : text
        if let known = parsed[key] { return known }
        let address = NetworkAddress.address(text, computed: computed)
        parsed[key] = address
        return address
    }

    private func names(of host: MeepHost) -> Set<String> {
        if let known = knownNames[ObjectIdentifier(host)] { return known }
        let names = Set(((host.identity?.names ?? []) + (host.identity?.addresses ?? [])).map { $0.lowercased() })
        knownNames[ObjectIdentifier(host)] = names
        return names
    }

    /// The names and addresses a host's machine goes by, in lower case, for telling whether two hosts share one.
    private func machine(_ host: MeepHost) -> Set<String> {
        if let known = machines[ObjectIdentifier(host)] { return known }
        let parts = machineParts(host)
        machines[ObjectIdentifier(host)] = parts
        return parts
    }

    private func machineParts(_ host: MeepHost) -> Set<String> {
        var parts = Set((host.identity?.names ?? []) + (host.identity?.addresses ?? []))
            .map { $0.lowercased() }.filter { !NetworkAddress.isLoopback($0) }
        switch host.kind {
        case .local: parts.append("this mac")
        case .remote(let target) where NetworkAddress.isLoopback(target.destination.lowercased()): parts.append("this mac")
        default: break
        }
        return Set(parts)
    }

    private func sameMachine(_ a: MeepHost, _ b: MeepHost) -> Bool {
        a === b || !machine(a).isDisjoint(with: machine(b))
    }

    func listens(reachedBy endpoint: String, address: String?, computed: Bool, from sender: MeepHost) -> [(MeepHost, ListenAddress)] {
        guard let target = NetworkAddress.endpoint(endpoint), let port = target.port else { return [] }
        let sent = address.flatMap { self.address($0, computed: computed) }
        var found: [(MeepHost, ListenAddress, Int)] = []
        for host in hosts {
            let known = names(of: host)
            for listen in host.listens {
                guard let bound = self.address(listen.address), bound.port == port else { continue }
                if let family = sent?.family, family != bound.family { continue }
                let reaches: Bool
                if NetworkAddress.isLoopback(target.host) {
                    reaches = sameMachine(sender, host) && (NetworkAddress.isLoopback(bound.host) || NetworkAddress.isWildcard(bound.host))
                } else if target.host == bound.host {
                    reaches = true
                } else {
                    reaches = (NetworkAddress.isWildcard(bound.host) || known.contains(bound.host)) && known.contains(target.host)
                }
                guard reaches else { continue }
                // The path, where both have one: the Listen's is where the Send's starts, or, for a path known only
                // so far, either starts the other.
                var length = 0
                if let listenPath = bound.path, let sentPath = sent?.path {
                    let fits = sent?.pathIsPartial == true
                        ? sentPath.hasPrefix(listenPath) || listenPath.hasPrefix(sentPath)
                        : sentPath.hasPrefix(listenPath) || (sentPath + "/").hasPrefix(listenPath)
                    guard fits else { continue }
                    length = listenPath.count
                }
                found.append((host, listen, length))
            }
        }
        // Several Listens on one host and port: the one whose path fits longest, as routing would choose.
        var best: [ObjectIdentifier: Int] = [:]
        for (host, _, length) in found { best[ObjectIdentifier(host), default: -1] = max(best[ObjectIdentifier(host)] ?? -1, length) }
        return found.filter { best[ObjectIdentifier($0.0)] == $0.2 }.map { ($0.0, $0.1) }
    }

    func build() -> FlowMap {
        var flows: [String: MeshFlow] = [:]
        var endpoints: [String: BoundaryEndpoint] = [:]

        func label(_ address: MeepAddress) -> String {
            if let known = labels[address] { return known }
            let made: String
            if let host = hosts.first(where: { $0.name == address.host }) {
                if let pipelineName = address.pipeline, let pipeline = host.pipeline(pipelineName) {
                    if let key = address.module {
                        let module = pipeline.module(key)
                        made = "\(pipelineName) › \(module.map { $0.label.isEmpty ? key : $0.label } ?? key)"
                    } else {
                        made = pipelineName
                    }
                } else {
                    made = host.title
                }
            } else {
                made = address.description
            }
            labels[address] = made
            return made
        }
        func link(_ endpoint: String, kind: BoundaryEndpoint.Kind, name: String, domain: String, place: String, _ item: BoundaryLink) {
            var entry = endpoints[endpoint] ?? BoundaryEndpoint(id: endpoint, kind: kind, name: name, domain: domain, places: [], links: [])
            if !entry.places.contains(place) { entry.places.append(place) }
            if let index = entry.links.firstIndex(where: { $0.id == item.id }) {
                if item.observed { entry.links[index] = item }
            } else {
                entry.links.append(item)
            }
            endpoints[endpoint] = entry
        }
        func outsideKey(_ host: String) -> (id: String, name: String) {
            let name = names[host] ?? host
            return ("outside:\(name.lowercased())", name)
        }

        // Observed: what each Listen received, and what each Fetch and Send sent.
        for host in hosts {
            for pipeline in host.pipelines {
                for module in pipeline.modules where !module.places.isEmpty {
                    let address = pipeline.address.module(module.key)
                    // Counts no longer followed are as last seen: they say a place exists, but their rates mean nothing.
                    let current = module.placesFollowed && host.isReachable
                    let live = current ? 1.0 : 0
                    for (place, counts) in module.places.sorted(by: { $0.key < $1.key }) {
                        let received = counts.rate("received") * live, sent = counts.rate("sent") * live
                        let failed = counts.rate("failed") * live, rejected = counts.rate("rejected") * live
                        let bytesIn = counts.rate("bytesReceived") * live, bytesOut = counts.rate("bytesSent") * live
                        switch module.placeKind {
                        case .arrivals?:
                            let item = BoundaryLink(
                                id: "\(address) < \(place)", module: address, moduleLabel: label(address), place: place, direction: .inbound,
                                observed: true, count: counts["received"], rateIn: received, rateOut: sent, failed: failed, rejected: rejected,
                                bytesIn: bytesIn, bytesOut: bytesOut, current: current
                            )
                            if place == "*" {
                                link("*", kind: .pastLimit, name: "Others past limits", domain: "", place: place, item)
                            } else if place == "meep://*" {
                                link("meep://*", kind: .pastLimit, name: "Meep origins past limits", domain: "Meep", place: place, item)
                            } else if let origin = MeepOrigin(place) {
                                if let source = byID[origin.daemon], let pipelineName = origin.pipeline {
                                    let from = MeepAddress(host: source.name, pipeline: pipelineName, module: origin.module)
                                    let id = "\(from) > \(address)"
                                    var flow = flows[id] ?? MeshFlow(
                                        id: id, from: from, to: address, fromLabel: label(from), toLabel: label(address), declared: false,
                                        observed: true, byAddress: false, count: 0, rate: 0, replies: 0, failed: 0, rejected: 0, bytesOut: 0, bytesBack: 0
                                    )
                                    flow.observed = true
                                    flow.byAddress = false
                                    flow.current = current
                                    flow.count = counts["received"]
                                    flow.rate = received
                                    flow.replies = sent
                                    flow.failed = max(flow.failed, failed)
                                    flow.rejected = max(flow.rejected, rejected)
                                    flow.bytesOut = bytesIn
                                    flow.bytesBack = bytesOut
                                    flows[id] = flow
                                } else {
                                    link("meep:\(origin.daemon)", kind: .otherMeep, name: "Another Meep (\(origin.daemon.prefix(8)))", domain: "Meep", place: place, item)
                                }
                            } else {
                                let (id, name) = outsideKey(place)
                                link(id, kind: .outside, name: name, domain: NetworkAddress.domain(of: name), place: place, item)
                            }
                        case .destinations?:
                            let item = BoundaryLink(
                                id: "\(address) > \(place)", module: address, moduleLabel: label(address), place: place, direction: .outbound,
                                observed: true, count: counts["sent"], rateIn: received, rateOut: sent, failed: failed, rejected: rejected,
                                bytesIn: bytesIn, bytesOut: bytesOut, current: current
                            )
                            if place == "*" {
                                link("*", kind: .pastLimit, name: "Others past limits", domain: "", place: place, item)
                                continue
                            }
                            let declared = host.sends.first { $0.pipeline == pipeline.name && $0.module == module.key }
                            var to: MeepAddress?
                            var byAddress = false
                            if let id = pipeline.peers[place] {
                                guard let target = byID[id] else {
                                    link("meep:\(id)", kind: .otherMeep, name: "Another Meep (\(id.prefix(8)))", domain: "Meep", place: place, item)
                                    continue
                                }
                                let listen = listens(reachedBy: place, address: declared?.address, computed: declared?.isComputed ?? false, from: host)
                                    .first { $0.0 === target }?.1
                                to = listen.map { target.address.pipeline($0.pipeline).module($0.module) } ?? target.address
                            } else if let (target, listen) = listens(reachedBy: place, address: declared?.address, computed: declared?.isComputed ?? false, from: host).first {
                                // Not known as Meep, but a known host's Listen is bound there: over TCP, which carries
                                // no origin, or before the first answer.
                                to = target.address.pipeline(listen.pipeline).module(listen.module)
                                byAddress = true
                            }
                            guard let to else {
                                let endpointHost = NetworkAddress.endpoint(place)?.host ?? place
                                let (id, name) = outsideKey(endpointHost)
                                link(id, kind: .outside, name: name, domain: NetworkAddress.domain(of: name), place: place, item)
                                continue
                            }
                            let id = "\(address) > \(to)"
                            if var flow = flows[id], flow.current || !current {
                                // Its Listen's arrivals already gave the rate; the sender adds failures the Listen
                                // never saw, such as refused connections.
                                flow.failed = max(flow.failed, failed)
                                flow.rejected = max(flow.rejected, rejected)
                                flows[id] = flow
                            } else {
                                // The sender's counts, where the Listen's aren't followed now or aren't known.
                                flows[id] = MeshFlow(
                                    id: id, from: address, to: to, fromLabel: label(address), toLabel: label(to), declared: flows[id]?.declared ?? false,
                                    observed: true, byAddress: byAddress && flows[id] == nil, count: counts["sent"], rate: sent, replies: received,
                                    failed: max(failed, flows[id]?.failed ?? 0), rejected: max(rejected, flows[id]?.rejected ?? 0),
                                    bytesOut: bytesOut, bytesBack: bytesIn, current: current
                                )
                            }
                        case nil:
                            break
                        }
                    }
                }
            }
        }
        // A flow known from its sender only as reaching a host, when its Listen's arrivals name the same sender and a
        // Listen on that host, is that flow.
        for (id, flow) in flows where flow.to.pipeline == nil {
            if flows.values.contains(where: { $0.from == flow.from && $0.to.host == flow.to.host && $0.to.pipeline != nil }) {
                flows.removeValue(forKey: id)
            }
        }

        // Declared: each Fetch's and Send's address, matched with the Listens on known hosts.
        for host in hosts {
            for send in host.sends {
                let from = MeepAddress(host: host.name, pipeline: send.pipeline, module: send.module)
                guard let endpoint = send.endpoint else { continue }
                let matches = listens(reachedBy: endpoint, address: send.address, computed: send.isComputed, from: host)
                if matches.isEmpty {
                    let item = BoundaryLink(
                        id: "\(from) > \(endpoint)", module: from, moduleLabel: label(from), place: endpoint, direction: .outbound, observed: false,
                        count: 0, rateIn: 0, rateOut: 0, failed: 0, rejected: 0, bytesIn: 0, bytesOut: 0
                    )
                    let endpointHost = NetworkAddress.endpoint(endpoint)?.host ?? endpoint
                    // Unless what's observed says it's Meep, and so already a flow.
                    if flows.values.contains(where: { $0.from == from && $0.observed }) { continue }
                    let (id, name) = outsideKey(endpointHost)
                    link(id, kind: .outside, name: name, domain: NetworkAddress.domain(of: name), place: endpoint, item)
                    continue
                }
                for (target, listen) in matches {
                    let to = target.address.pipeline(listen.pipeline).module(listen.module)
                    let id = "\(from) > \(to)"
                    if flows[id] != nil {
                        flows[id]?.declared = true
                    } else if let (hostOnly, flow) = flows.first(where: { $0.value.from == from && $0.value.to == target.address }) {
                        // Observed reaching this host: the declaration says which Listen.
                        flows.removeValue(forKey: hostOnly)
                        var named = flow
                        named.id = id
                        named.to = to
                        named.toLabel = label(to)
                        named.declared = true
                        flows[id] = named
                    } else {
                        flows[id] = MeshFlow(
                            id: id, from: from, to: to, fromLabel: label(from), toLabel: label(to), declared: true, observed: false, byAddress: false,
                            count: 0, rate: 0, replies: 0, failed: 0, rejected: 0, bytesOut: 0, bytesBack: 0
                        )
                    }
                }
            }
        }

        var boundary = endpoints.values.sorted { $0.id < $1.id }
        for index in boundary.indices { boundary[index].links.sort { $0.id < $1.id } }
        return FlowMap(flows: flows.values.sorted { $0.id < $1.id }, boundary: boundary)
    }
}

/// An origin as a Listen's arrivals key it: `meep://<daemon ID>/<pipeline>/<module key>`, each part escaped as in a URL.
public struct MeepOrigin: Sendable, Hashable {
    public var daemon: String
    public var pipeline: String?
    public var module: String?

    public init?(_ place: String) {
        guard place.hasPrefix("meep://"), place != "meep://*" else { return nil }
        let parts = place.dropFirst("meep://".count).split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).removingPercentEncoding ?? String($0) }
        guard let daemon = parts.first, !daemon.isEmpty else { return nil }
        self.daemon = daemon
        pipeline = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        module = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
    }
}
