import CoreGraphics
import Foundation

/// A graph to lay out: boxes of known sizes, and the links between them.
public struct LayoutGraph: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        public var id: String
        public var size: CGSize

        public init(id: String, size: CGSize) {
            self.id = id
            self.size = size
        }
    }

    public struct Edge: Sendable, Equatable {
        public var id: String
        public var from: String
        public var to: String
        /// Which of the receiving node's inputs it is, counting from 1; inputs are stacked top to bottom.
        public var input: Int

        public init(id: String, from: String, to: String, input: Int = 1) {
            self.id = id
            self.from = from
            self.to = to
            self.input = input
        }
    }

    /// In the order they're written, which the layout keeps where it can.
    public var nodes: [Node]
    public var edges: [Edge]

    public init(nodes: [Node], edges: [Edge]) {
        self.nodes = nodes
        self.edges = edges
    }
}

/// Where everything went.
public struct Layout: Sendable, Equatable {
    /// Each node's frame, by id.
    public var frames: [String: CGRect]
    /// Each edge's bends: the points it passes between its ends, left to right, empty when it goes straight from one
    /// column to the next.
    public var bends: [String: [CGPoint]]
    /// Edges that go back against the flow, from right to left, to break a cycle.
    public var backward: Set<String>
    /// Each node's column, counting from 0 at the left.
    public var columns: [String: Int]
    /// The frames' bounds, from (0, 0).
    public var bounds: CGRect

    public static let empty = Layout(frames: [:], bends: [:], backward: [], columns: [:], bounds: .zero)
}

/// A layered (Sugiyama-style) layout, flowing left to right: sources in the first column, each node a column after
/// the latest of the nodes it takes from, then ordered within columns to cross as few edges as it can, then placed
/// so edges run as straight as they can.
///
/// It runs in a frame or two for a pipeline of a hundred modules. Positions from an earlier layout go in as hints,
/// so an edit moves as little as it can.
public struct LayeredLayout: Sendable {
    /// Space between columns, before room for the edges between them.
    public var columnGap: CGFloat = 72
    /// Space between nodes in a column.
    public var rowGap: CGFloat = 28
    /// How much room a bend takes in a column it passes through.
    public var bendSize = CGSize(width: 16, height: 14)
    /// Rounds of reordering to cut crossings.
    public var orderingRounds = 12
    /// Rounds of straightening.
    public var placingRounds = 40
    /// Where nodes sit in their column: centred, or with their left edges lined up.
    public var columnAlignment = ColumnAlignment.center
    /// The height over which a node's inputs spread down its left side, centred on its middle; nil for half its
    /// height.
    public var inputSpan: CGFloat?
    /// The most room between one input and the next.
    public var inputSpacing: CGFloat = 14

    public enum ColumnAlignment: Sendable {
        case center
        case leading
    }

    public init() {}

    /// Where input `input` of `inputs` meets a node, down from its middle: spread evenly over `span`, at most
    /// `spacing` apart, input 1 at the top.
    public static func inputOffset(input: Int, of inputs: Int, span: CGFloat, spacing: CGFloat) -> CGFloat {
        guard inputs > 1 else { return 0 }
        let spread = min(span, CGFloat(inputs - 1) * spacing)
        return -spread / 2 + spread * CGFloat(input - 1) / CGFloat(inputs - 1)
    }

    /// Lays out `graph`. `previous` gives centres from an earlier layout, by id, so nodes keep their order.
    public func layout(_ graph: LayoutGraph, previous: [String: CGPoint] = [:]) -> Layout {
        guard !graph.nodes.isEmpty else { return .empty }
        var work = Work(graph: graph)
        work.breakCycles()
        work.assignColumns()
        work.addBends(size: bendSize)
        work.order(rounds: orderingRounds, previous: previous)
        work.inputSpan = inputSpan
        work.inputSpacing = inputSpacing
        work.place(rounds: placingRounds, rowGap: rowGap, columnGap: columnGap, alignment: columnAlignment)
        return work.result()
    }
}

/// The layout's working state: nodes by index, real ones first, then the bends added for long edges.
private struct Work {
    struct Vertex {
        var id: String
        var size: CGSize
        var isBend: Bool
        var column = 0
        var y: CGFloat = 0
        var x: CGFloat = 0
        /// The node's place in the input, which breaks ties so the layout is the same each time.
        var rank: Int
    }

    /// An edge between adjacent columns, after long edges are split.
    struct Segment {
        var from: Int
        var to: Int
        /// The edge it's part of.
        var edge: Int
        /// The input at the far end, for the segment that reaches the edge's real target.
        var input: Int
    }

    let graph: LayoutGraph
    var vertices: [Vertex]
    /// Edges as (from, to) indices, turned to run left to right.
    var edges: [(from: Int, to: Int)] = []
    var reversed: Set<Int> = []
    var segments: [Segment] = []
    /// The vertices of each edge from start to end, bends included.
    var chains: [[Int]] = []
    /// Each column's vertices, top to bottom.
    var columns: [[Int]] = [] {
        didSet { position = Self.positions(of: columns, count: vertices.count) }
    }
    /// Each vertex's neighbours in the column to its left and right, as places that ``crossings(_:above:)`` compares.
    var leftOf: [[(vertex: Int, bias: Double)]] = []
    var rightOf: [[(vertex: Int, bias: Double)]] = []
    /// Each vertex's place in its column.
    var position: [Int] = []
    /// The segments from each column to the next.
    var between: [[Int]] = []
    /// The highest input number reaching each vertex.
    var inputCount: [Int] = []
    var inputSpan: CGFloat?
    var inputSpacing: CGFloat = 14

    static func positions(of columns: [[Int]], count: Int) -> [Int] {
        var position = [Int](repeating: 0, count: count)
        for column in columns {
            for (place, vertex) in column.enumerated() { position[vertex] = place }
        }
        return position
    }

    init(graph: LayoutGraph) {
        self.graph = graph
        vertices = graph.nodes.enumerated().map { Vertex(id: $1.id, size: $1.size, isBend: false, rank: $0) }
        let index = Dictionary(graph.nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        edges = graph.edges.map { (index[$0.from] ?? -1, index[$0.to] ?? -1) }
    }

    /// Turns round the edges that close a cycle, found by a depth-first walk from the nodes in their written order.
    mutating func breakCycles() {
        var state = [UInt8](repeating: 0, count: vertices.count) // 0 unseen, 1 on the path, 2 done
        var outgoing = [[Int]](repeating: [], count: vertices.count)
        for (number, edge) in edges.enumerated() where edge.from >= 0 && edge.to >= 0 {
            outgoing[edge.from].append(number)
        }
        func visit(_ start: Int) {
            var stack: [(vertex: Int, next: Int)] = [(start, 0)]
            state[start] = 1
            while let top = stack.last {
                let out = outgoing[top.vertex]
                if top.next < out.count {
                    stack[stack.count - 1].next += 1
                    let number = out[top.next]
                    let target = edges[number].to
                    if state[target] == 1 {
                        reversed.insert(number)
                    } else if state[target] == 0 {
                        state[target] = 1
                        stack.append((target, 0))
                    }
                } else {
                    state[top.vertex] = 2
                    stack.removeLast()
                }
            }
        }
        // Start from the sources, so a cycle is broken at the edge that comes back, then from anything left.
        let hasIncoming = Set(edges.filter { $0.from >= 0 && $0.to >= 0 && $0.from != $0.to }.map(\.to))
        for vertex in vertices.indices where !hasIncoming.contains(vertex) && state[vertex] == 0 { visit(vertex) }
        for vertex in vertices.indices where state[vertex] == 0 { visit(vertex) }
        for number in reversed {
            edges[number] = (edges[number].to, edges[number].from)
        }
    }

    /// Puts each node a column after the latest node it takes from, then pulls nodes that start nothing in their
    /// column (sources) right, next to what they feed, so their edges are short.
    mutating func assignColumns() {
        let count = vertices.count
        var incoming = [[Int]](repeating: [], count: count)
        var outgoing = [[Int]](repeating: [], count: count)
        for edge in edges where edge.from >= 0 && edge.to >= 0 && edge.from != edge.to {
            incoming[edge.to].append(edge.from)
            outgoing[edge.from].append(edge.to)
        }
        // Kahn's order, taking ready nodes in their written order.
        var remaining = incoming.map(\.count)
        var ready = (0..<count).filter { remaining[$0] == 0 }
        var order: [Int] = []
        while !ready.isEmpty {
            let vertex = ready.removeFirst()
            order.append(vertex)
            for next in outgoing[vertex] {
                remaining[next] -= 1
                if remaining[next] == 0 { ready.append(next) }
            }
        }
        for vertex in order {
            vertices[vertex].column = incoming[vertex].map { vertices[$0].column + 1 }.max() ?? 0
        }
        for vertex in order.reversed() where incoming[vertex].isEmpty && !outgoing[vertex].isEmpty {
            vertices[vertex].column = max(0, (outgoing[vertex].map { vertices[$0].column }.min() ?? 1) - 1)
        }
    }

    /// Splits edges that span more than one column with bends, one in each column they cross.
    mutating func addBends(size: CGSize) {
        for (number, edge) in edges.enumerated() {
            guard edge.from >= 0, edge.to >= 0, edge.from != edge.to else {
                chains.append([])
                continue
            }
            var chain = [edge.from]
            var last = edge.from
            let input = graph.edges[number].input
            let span = vertices[edge.to].column - vertices[edge.from].column
            if span > 1 {
                for step in 1..<span {
                    let bend = vertices.count
                    vertices.append(Vertex(
                        id: "\(graph.edges[number].id)#\(step)", size: size, isBend: true,
                        column: vertices[edge.from].column + step, rank: vertices.count
                    ))
                    segments.append(Segment(from: last, to: bend, edge: number, input: 1))
                    chain.append(bend)
                    last = bend
                }
            }
            segments.append(Segment(from: last, to: edge.to, edge: number, input: reversed.contains(number) ? 1 : input))
            chain.append(edge.to)
            chains.append(chain)
        }
    }

    // MARK: Ordering

    /// Orders each column to cut crossings: barycentres swept left and right, then swaps of neighbours, keeping the
    /// best order seen.
    mutating func order(rounds: Int, previous: [String: CGPoint]) {
        let columnCount = (vertices.map(\.column).max() ?? 0) + 1
        columns = Array(repeating: [], count: columnCount)
        // Start from a walk in written order, so a tree comes out as it's written; earlier positions win over that.
        var seen = Set<Int>()
        var walk: [Int] = []
        var outgoing = [[Int]](repeating: [], count: vertices.count)
        for segment in segments { outgoing[segment.from].append(segment.to) }
        func visit(_ vertex: Int) {
            var stack = [vertex]
            while let top = stack.popLast() {
                guard seen.insert(top).inserted else { continue }
                walk.append(top)
                stack.append(contentsOf: outgoing[top].reversed())
            }
        }
        for vertex in vertices.indices.sorted(by: { vertices[$0].rank < vertices[$1].rank }) { visit(vertex) }
        let walkPlace = Dictionary(uniqueKeysWithValues: walk.enumerated().map { ($1, $0) })
        var start = columns
        for vertex in walk { start[vertices[vertex].column].append(vertex) }
        if !previous.isEmpty {
            let ids = vertices.map(\.id)
            for column in start.indices {
                start[column].sort { a, b in
                    switch (previous[ids[a]], previous[ids[b]]) {
                    case let (pa?, pb?) where pa.y != pb.y: return pa.y < pb.y
                    default: return walkPlace[a]! < walkPlace[b]!
                    }
                }
            }
        }
        columns = start

        between = Array(repeating: [], count: columnCount)
        for (number, segment) in segments.enumerated() where vertices[segment.from].column + 1 == vertices[segment.to].column {
            between[vertices[segment.from].column].append(number)
        }
        inputCount = [Int](repeating: 1, count: vertices.count)
        leftOf = Array(repeating: [], count: vertices.count)
        rightOf = Array(repeating: [], count: vertices.count)
        for segment in segments {
            inputCount[segment.to] = max(inputCount[segment.to], segment.input)
            leftOf[segment.to].append((segment.from, 0))
            rightOf[segment.from].append((segment.to, Double(segment.input - 1) * 0.001))
        }

        var best = columns
        var bestCrossings = crossings()
        guard bestCrossings > 0 else { return }
        for round in 0..<rounds {
            if round % 2 == 0 {
                for column in 1..<max(1, columns.count) { sortByBarycentre(column, facing: column - 1) }
            } else {
                for column in stride(from: columns.count - 2, through: 0, by: -1) { sortByBarycentre(column, facing: column + 1) }
            }
            transpose()
            let count = crossings()
            if count < bestCrossings {
                best = columns
                bestCrossings = count
                if count == 0 { break }
            }
        }
        columns = best
    }

    /// Sorts a column by the mean place of each vertex's neighbours in the column it faces; vertices with none there
    /// keep their place.
    private mutating func sortByBarycentre(_ column: Int, facing other: Int) {
        var neighbours: [Int: [Double]] = [:]
        for number in between[min(column, other)] {
            let segment = segments[number]
            if other < column {
                // Inputs lower down pull a little lower, so a merge's inputs keep their order.
                neighbours[segment.to, default: []].append(Double(position[segment.from]) + Double(segment.input - 1) * 0.001)
            } else {
                neighbours[segment.from, default: []].append(Double(position[segment.to]))
            }
        }
        let keyed = columns[column].enumerated().map { position, vertex -> (vertex: Int, key: Double, position: Int) in
            let near = neighbours[vertex] ?? []
            return (vertex, near.isEmpty ? Double(position) : near.reduce(0, +) / Double(near.count), position)
        }
        columns[column] = keyed.sorted { a, b in a.key != b.key ? a.key < b.key : a.position < b.position }.map(\.vertex)
    }

    /// Swaps neighbours in a column wherever that alone crosses fewer edges.
    private mutating func transpose() {
        var improved = true
        var passes = 0
        while improved && passes < 4 {
            improved = false
            passes += 1
            for column in columns.indices where columns[column].count > 1 {
                var members = columns[column]
                for place in 0..<(members.count - 1) {
                    let (upper, lower) = (members[place], members[place + 1])
                    if crossings(lower, above: upper) < crossings(upper, above: lower) {
                        members.swapAt(place, place + 1)
                        position[upper] = place + 1
                        position[lower] = place
                        improved = true
                    }
                }
                columns[column] = members
            }
        }
    }

    /// Crossings between the edges of `upper` and those of `lower`, with `upper` placed just above `lower`.
    private func crossings(_ upper: Int, above lower: Int) -> Int {
        var count = 0
        for a in leftOf[upper] {
            for b in leftOf[lower] where position[a.vertex] > position[b.vertex] { count += 1 }
        }
        for a in rightOf[upper] {
            for b in rightOf[lower] where Double(position[a.vertex]) + a.bias > Double(position[b.vertex]) + b.bias { count += 1 }
        }
        return count
    }

    /// Crossings between every pair of adjacent columns.
    func crossings() -> Int {
        guard columns.count > 1 else { return 0 }
        return (0..<(columns.count - 1)).reduce(0) { $0 + crossings(between: $1) }
    }

    private func crossings(around column: Int) -> Int {
        var count = 0
        if column > 0 { count += crossings(between: column - 1) }
        if column < columns.count - 1 { count += crossings(between: column) }
        return count
    }

    /// Crossings between a column and the next: pairs of segments whose ends are in opposite orders.
    private func crossings(between column: Int) -> Int {
        var pairs: [(Double, Double)] = []
        pairs.reserveCapacity(between[column].count)
        for number in between[column] {
            let segment = segments[number]
            pairs.append((Double(position[segment.from]), Double(position[segment.to]) + Double(segment.input - 1) * 0.001))
        }
        pairs.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var count = 0
        for i in pairs.indices {
            for j in (i + 1)..<pairs.count where pairs[j].1 < pairs[i].1 && pairs[j].0 != pairs[i].0 {
                count += 1
            }
        }
        return count
    }

    // MARK: Placing

    /// Places columns left to right, then moves vertices up and down to straighten edges, keeping each column's
    /// order and gaps: each round sets each column as close as its gaps allow to where its neighbours pull it.
    mutating func place(rounds: Int, rowGap: CGFloat, columnGap: CGFloat, alignment: LayeredLayout.ColumnAlignment) {
        // Start stacked, each column centred on 0.
        for column in columns {
            var y: CGFloat = 0
            for vertex in column {
                vertices[vertex].y = y + vertices[vertex].size.height / 2
                y += vertices[vertex].size.height + gap(after: vertex, in: column, rowGap: rowGap)
            }
            let middle = y / 2
            for vertex in column { vertices[vertex].y -= middle }
        }
        var left = [[(vertex: Int, offset: CGFloat)]](repeating: [], count: vertices.count)
        var right = [[(vertex: Int, offset: CGFloat)]](repeating: [], count: vertices.count)
        for segment in segments {
            let offset = inputOffset(segment)
            left[segment.to].append((segment.from, offset))
            right[segment.from].append((segment.to, -offset))
        }
        for round in 0..<rounds {
            let order: [Int] = round % 2 == 0 ? Array(columns.indices) : columns.indices.reversed()
            for column in order {
                let useLeft = round % 4 < 2
                straighten(column, toward: useLeft ? left : right, also: round >= rounds / 2 ? (useLeft ? right : left) : nil, rowGap: rowGap)
            }
        }
        // Columns left to right, each as wide as its widest node, with more room where many edges cross.
        var x: CGFloat = 0
        for (number, column) in columns.enumerated() {
            let width = column.map { vertices[$0].size.width }.max() ?? 0
            for vertex in column {
                // Bends go through the middle of a column, whatever the alignment.
                let leading = alignment == .leading && !vertices[vertex].isBend
                vertices[vertex].x = leading ? x + vertices[vertex].size.width / 2 : x + width / 2
            }
            let crossing = number < between.count ? between[number].count : 0
            x += width + columnGap + CGFloat(min(crossing, 8)) * 6
        }
    }

    /// Where an input meets a node, from its centre: inputs are spread down its left side.
    private func inputOffset(_ segment: Segment) -> CGFloat {
        let target = vertices[segment.to]
        guard !target.isBend else { return 0 }
        return LayeredLayout.inputOffset(
            input: segment.input, of: inputCount[segment.to], span: inputSpan ?? target.size.height * 0.5, spacing: inputSpacing
        )
    }

    private func gap(after vertex: Int, in column: [Int], rowGap: CGFloat) -> CGFloat {
        let place = position[vertex]
        guard place + 1 < column.count else { return 0 }
        let bends = vertices[vertex].isBend || vertices[column[place + 1]].isBend
        return bends ? rowGap / 2 : rowGap
    }

    /// Sets one column's vertices as near as their gaps allow to the mean of where their neighbours want them, by
    /// pooling adjacent violators: the least-squares answer that keeps the column's order and gaps.
    private mutating func straighten(
        _ column: Int, toward pulls: [[(vertex: Int, offset: CGFloat)]], also extra: [[(vertex: Int, offset: CGFloat)]]?,
        rowGap: CGFloat
    ) {
        let members = columns[column]
        guard !members.isEmpty else { return }
        var wanted: [CGFloat] = []
        var weights: [CGFloat] = []
        for vertex in members {
            var near = pulls[vertex]
            if let extra { near += extra[vertex] }
            if near.isEmpty {
                wanted.append(vertices[vertex].y)
                weights.append(0.2)
            } else {
                // A node wants its input's end level with the vertex feeding it.
                let mean = near.reduce(0) { $0 + vertices[$1.vertex].y - $1.offset } / CGFloat(near.count)
                wanted.append(mean)
                weights.append(vertices[vertex].isBend ? 4 : 1)
            }
        }
        // Offsets turn "each at least its gap below the last" into "each no higher than the last".
        var offsets: [CGFloat] = [0]
        for index in 1..<members.count {
            let above = vertices[members[index - 1]]
            let below = vertices[members[index]]
            offsets.append(offsets[index - 1] + above.size.height / 2 + gap(after: members[index - 1], in: members, rowGap: rowGap) + below.size.height / 2)
        }
        let targets = zip(wanted, offsets).map { $0 - $1 }
        let solved = poolAdjacentViolators(targets, weights: weights)
        for (index, vertex) in members.enumerated() {
            vertices[vertex].y = solved[index] + offsets[index]
        }
    }

    func result() -> Layout {
        var frames: [String: CGRect] = [:]
        var columnOf: [String: Int] = [:]
        for vertex in vertices where !vertex.isBend {
            frames[vertex.id] = CGRect(
                x: vertex.x - vertex.size.width / 2, y: vertex.y - vertex.size.height / 2,
                width: vertex.size.width, height: vertex.size.height
            )
            columnOf[vertex.id] = vertex.column
        }
        // From exact least and greatest edges: unions chained in the dictionary's order round differently each time.
        let bounds = frames.isEmpty ? CGRect.null : CGRect(
            x: frames.values.map(\.minX).min()!, y: frames.values.map(\.minY).min()!,
            width: frames.values.map(\.maxX).max()! - frames.values.map(\.minX).min()!,
            height: frames.values.map(\.maxY).max()! - frames.values.map(\.minY).min()!
        )
        let shift = CGPoint(x: -bounds.minX, y: -bounds.minY)
        for (id, frame) in frames { frames[id] = frame.offsetBy(dx: shift.x, dy: shift.y) }
        var bends: [String: [CGPoint]] = [:]
        var backward = Set<String>()
        for (number, edge) in graph.edges.enumerated() {
            let chain = chains[number]
            var points = chain.dropFirst().dropLast().map { CGPoint(x: vertices[$0].x + shift.x, y: vertices[$0].y + shift.y) }
            if reversed.contains(number) {
                points.reverse()
                backward.insert(edge.id)
            }
            bends[edge.id] = points
        }
        return Layout(
            frames: frames, bends: bends, backward: backward, columns: columnOf,
            bounds: CGRect(origin: .zero, size: bounds.isNull ? .zero : bounds.size)
        )
    }
}

/// The non-decreasing sequence nearest `values` in weighted least squares.
func poolAdjacentViolators(_ values: [CGFloat], weights: [CGFloat]) -> [CGFloat] {
    var blocks: [(value: CGFloat, weight: CGFloat, count: Int)] = []
    for (value, weight) in zip(values, weights) {
        blocks.append((value, max(weight, 0.0001), 1))
        while blocks.count > 1, blocks[blocks.count - 2].value > blocks[blocks.count - 1].value {
            let last = blocks.removeLast()
            let previous = blocks.removeLast()
            let weight = previous.weight + last.weight
            blocks.append(((previous.value * previous.weight + last.value * last.weight) / weight, weight, previous.count + last.count))
        }
    }
    return blocks.flatMap { Array(repeating: $0.value, count: $0.count) }
}
