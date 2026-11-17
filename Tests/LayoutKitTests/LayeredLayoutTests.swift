import CoreGraphics
import Testing
@testable import LayoutKit

struct LayeredLayoutTests {
    private let box = CGSize(width: 100, height: 60)

    private func graph(_ nodes: [String], _ edges: [(String, String)], inputs: [String: Int] = [:]) -> LayoutGraph {
        LayoutGraph(
            nodes: nodes.map { .init(id: $0, size: box) },
            edges: edges.map { .init(id: "\($0)>\($1)", from: $0, to: $1, input: inputs["\($0)>\($1)"] ?? 1) }
        )
    }

    @Test func aChainRunsInAStraightRow() {
        let layout = LayeredLayout().layout(graph(["a", "b", "c"], [("a", "b"), ("b", "c")]))
        let frames = ["a", "b", "c"].map { layout.frames[$0]! }
        #expect(frames.map(\.midY) == [frames[0].midY, frames[0].midY, frames[0].midY])
        #expect(frames[0].maxX < frames[1].minX && frames[1].maxX < frames[2].minX)
        #expect(layout.columns == ["a": 0, "b": 1, "c": 2])
        #expect(layout.bounds.origin == .zero)
    }

    @Test func aFanOutCentresItsSource() {
        let layout = LayeredLayout().layout(graph(["a", "b", "c"], [("a", "b"), ("a", "c")]))
        let (a, b, c) = (layout.frames["a"]!, layout.frames["b"]!, layout.frames["c"]!)
        #expect(b.maxY <= c.minY, "children keep their written order, top to bottom")
        #expect(abs(a.midY - (b.midY + c.midY) / 2) < 1)
    }

    @Test func aMergesInputsKeepTheirOrder() {
        // Two sources into input 2 and input 1 of one node, written in the other order.
        let layout = LayeredLayout().layout(graph(["s", "t", "m"], [("s", "m"), ("t", "m")], inputs: ["s>m": 2, "t>m": 1]))
        #expect(layout.frames["t"]!.midY < layout.frames["s"]!.midY, "input 1 is fed from above")
        #expect(layout.columns["s"] == 0 && layout.columns["t"] == 0 && layout.columns["m"] == 1)
    }

    @Test func aSourceSitsNextToWhatItFeeds() {
        // b feeds d, which is two columns along; b moves right to sit beside it.
        let layout = LayeredLayout().layout(graph(["a", "c", "b", "d"], [("a", "c"), ("c", "d"), ("b", "d")]))
        #expect(layout.columns["b"] == 1)
        #expect(layout.bends["b>d"]!.isEmpty)
    }

    @Test func aLongEdgeBendsThroughTheColumnsBetween() {
        let layout = LayeredLayout().layout(graph(["a", "b", "c", "d"], [("a", "b"), ("b", "c"), ("c", "d"), ("a", "d")]))
        let bends = layout.bends["a>d"]!
        #expect(bends.count == 2)
        #expect(bends.map(\.x) == bends.map(\.x).sorted())
        // The bends don't sit on top of the chain's boxes.
        for bend in bends {
            #expect(!["b", "c"].contains { layout.frames[$0]!.contains(bend) })
        }
    }

    @Test func aCycleIsBrokenAndSaidToGoBack() {
        let layout = LayeredLayout().layout(graph(["a", "b", "c"], [("a", "b"), ("b", "c"), ("c", "a")]))
        #expect(layout.backward == ["c>a"])
        #expect(layout.frames.count == 3)
        #expect(layout.bends["c>a"]!.map(\.x) == layout.bends["c>a"]!.map(\.x).sorted(by: >), "it bends right to left")
    }

    @Test func aTreeHasNoCrossings() {
        let tree = graph(
            ["r", "a", "b", "a1", "a2", "b1", "b2", "b3"],
            [("r", "a"), ("r", "b"), ("a", "a1"), ("a", "a2"), ("b", "b1"), ("b", "b2"), ("b", "b3")]
        )
        let layout = LayeredLayout().layout(tree)
        #expect(crossings(in: layout, of: tree) == 0)
        let leaves = ["a1", "a2", "b1", "b2", "b3"].map { layout.frames[$0]!.midY }
        #expect(leaves == leaves.sorted(), "a tree comes out as it's written")
    }

    @Test(arguments: [3, 7, 11, 19])
    func nothingOverlapsAndItsTheSameEachTime(seed: Int) {
        let random = randomGraph(nodes: 24, edges: 34, seed: seed)
        let layout = LayeredLayout().layout(random)
        #expect(layout == LayeredLayout().layout(random))
        let frames = Array(layout.frames.values)
        for i in frames.indices {
            for j in frames.indices where j > i {
                #expect(!frames[i].insetBy(dx: 1, dy: 1).intersects(frames[j]), "seed \(seed)")
            }
        }
        for edge in random.edges where layout.backward.isEmpty {
            #expect(layout.frames[edge.from]!.midX < layout.frames[edge.to]!.midX)
        }
    }

    @Test func orderingCutsCrossings() {
        // Written so the obvious order crosses: a feeds the lower node, b the upper one.
        let crossed = graph(["a", "b", "y", "x"], [("a", "x"), ("b", "y")])
        let layout = LayeredLayout().layout(crossed)
        #expect(crossings(in: layout, of: crossed) == 0)
    }

    @Test func earlierPositionsKeepTheOrder() {
        let fan = graph(["a", "b", "c"], [("a", "b"), ("a", "c")])
        let first = LayeredLayout().layout(fan)
        // Before, c was above b; with nothing to choose between them, the layout keeps that.
        let previous = ["a": CGPoint(x: 50, y: 50), "b": CGPoint(x: 200, y: 100), "c": CGPoint(x: 200, y: 0)]
        let second = LayeredLayout().layout(fan, previous: previous)
        #expect(first.frames["b"]!.midY < first.frames["c"]!.midY)
        #expect(second.frames["c"]!.midY < second.frames["b"]!.midY)
    }

    @Test func poolingKeepsOrderAndFindsTheMean() {
        #expect(poolAdjacentViolators([1, 3, 2, 4], weights: [1, 1, 1, 1]) == [1, 2.5, 2.5, 4])
        #expect(poolAdjacentViolators([5, 1], weights: [3, 1]) == [4, 4])
    }

    @Test func aHundredModulesLayOutQuickly() {
        let big = randomGraph(nodes: 100, edges: 140, seed: 5)
        let clock = ContinuousClock()
        let took = clock.measure { _ = LayeredLayout().layout(big) }
        // A debug build is several times slower than the app's release build, and slower again beside the other
        // suites on a busy machine; this catches the 8 seconds layout once took, not a busy moment.
        #if DEBUG
        #expect(took < .milliseconds(2500), "took \(took)")
        #else
        #expect(took < .milliseconds(100), "took \(took)")
        #endif
    }

    // MARK: Helpers

    /// Crossings between straight segments from centre to centre through the bends.
    private func crossings(in layout: Layout, of graph: LayoutGraph) -> Int {
        var lines: [(CGPoint, CGPoint)] = []
        for edge in graph.edges {
            let points = [layout.frames[edge.from]!.center] + layout.bends[edge.id]! + [layout.frames[edge.to]!.center]
            for (a, b) in zip(points, points.dropFirst()) { lines.append((a, b)) }
        }
        var count = 0
        for i in lines.indices {
            for j in lines.indices where j > i && intersects(lines[i], lines[j]) { count += 1 }
        }
        return count
    }

    private func intersects(_ p: (CGPoint, CGPoint), _ q: (CGPoint, CGPoint)) -> Bool {
        func side(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        let shares = [p.0, p.1].contains { a in [q.0, q.1].contains { b in abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 } }
        if shares { return false }
        return side(p.0, p.1, q.0) * side(p.0, p.1, q.1) < 0 && side(q.0, q.1, p.0) * side(q.0, q.1, p.1) < 0
    }

    /// A random graph whose edges all go from an earlier node to a later one.
    private func randomGraph(nodes: Int, edges: Int, seed: Int) -> LayoutGraph {
        var state = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let ids = (0..<nodes).map { "n\($0)" }
        var pairs = Set<String>()
        var list: [LayoutGraph.Edge] = []
        while list.count < edges {
            let a = next(nodes - 1)
            let b = a + 1 + next(min(4, nodes - a - 1))
            guard pairs.insert("\(a)>\(b)").inserted else { continue }
            list.append(.init(id: "n\(a)>n\(b)", from: ids[a], to: ids[b]))
        }
        return LayoutGraph(nodes: ids.enumerated().map { .init(id: $1, size: CGSize(width: 60 + CGFloat($0 % 3) * 30, height: 40 + CGFloat($0 % 2) * 30)) }, edges: list)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
