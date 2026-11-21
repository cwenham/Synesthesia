import CoreGraphics
import Foundation
import Testing
@testable import LayoutKit

/// The mesh's damped force layout and the boundary's places round its edge (design, section 7).
struct ForceLayoutTests {
    private let sizes: [String: CGSize] = [
        "local": CGSize(width: 1800, height: 1100), "lab": CGSize(width: 900, height: 600),
        "simulated": CGSize(width: 2000, height: 1400), "far": CGSize(width: 800, height: 500),
    ]

    private func nodes(_ ids: [String], at positions: [String: CGPoint] = [:]) -> [ForceLayout.Node] {
        ids.map { ForceLayout.Node(id: $0, size: sizes[$0]!, position: positions[$0]) }
    }

    private func frames(_ places: [String: CGPoint]) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        for (id, center) in places {
            let size = sizes[id]!
            result[id] = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        }
        return result
    }

    @Test func boxesNeverOverlapAndKeepTheirGap() {
        let layout = ForceLayout(gap: 520)
        let placed = frames(layout.layOut(nodes(["local", "lab", "simulated", "far"]), edges: [ForceLayout.Edge("local", "lab")]))
        let all = Array(placed.values)
        for i in all.indices {
            for j in all.indices where j > i {
                #expect(!all[i].insetBy(dx: -259, dy: -259).intersects(all[j].insetBy(dx: -259, dy: -259)), "\(all[i]) and \(all[j])")
            }
        }
    }

    @Test func aFlowPullsItsHostsTogether() {
        let layout = ForceLayout(gap: 520)
        let ids = ["local", "lab", "simulated", "far"]
        func distance(_ places: [String: CGPoint], _ a: String, _ b: String) -> CGFloat {
            hypot(places[a]!.x - places[b]!.x, places[a]!.y - places[b]!.y)
        }
        let apart = layout.layOut(nodes(ids), edges: [])
        let pulled = layout.layOut(nodes(ids), edges: [ForceLayout.Edge("lab", "far", weight: 4)])
        #expect(distance(pulled, "lab", "far") < distance(apart, "lab", "far"))
    }

    @Test func theSameHostsAndFlowsAlwaysSettleTheSameWay() {
        let layout = ForceLayout(gap: 520)
        let ids = ["local", "lab", "simulated"]
        let edges = [ForceLayout.Edge("local", "lab"), ForceLayout.Edge("simulated", "local", weight: 2)]
        #expect(layout.layOut(nodes(ids), edges: edges) == layout.layOut(nodes(ids), edges: edges))
    }

    @Test func aNewHostMovesTheOthersLittle() {
        let layout = ForceLayout(gap: 520)
        let first = layout.layOut(nodes(["local", "lab", "simulated"]), edges: [ForceLayout.Edge("local", "lab")])
        let again = layout.layOut(nodes(["local", "lab", "simulated", "far"], at: first), edges: [ForceLayout.Edge("local", "lab")])
        for id in ["local", "lab", "simulated"] {
            let moved = hypot(again[id]!.x - first[id]!.x, again[id]!.y - first[id]!.y)
            #expect(moved < 1500, "\(id) moved \(moved)")
        }
        // Laid out again from where they are, nothing moves.
        let settled = layout.layOut(nodes(["local", "lab", "simulated", "far"], at: again), edges: [ForceLayout.Edge("local", "lab")])
        for id in again.keys {
            #expect(hypot(settled[id]!.x - again[id]!.x, settled[id]!.y - again[id]!.y) < 200, "\(id)")
        }
    }

    @Test func theWholeComesOutWiderThanTall() {
        let layout = ForceLayout(gap: 520)
        let ids = ["local", "lab", "simulated", "far"]
        let union = frames(layout.layOut(nodes(ids), edges: [])).values.reduce(CGRect.null) { $0.union($1) }
        #expect(union.width > union.height)
    }

    @Test func endpointsSitRoundTheEdgeNearWhereTheyPointAndTogetherByGroup() {
        let region = CGRect(x: -1000, y: -500, width: 2000, height: 1000)
        let items = [
            EdgeLayout.Item(id: "api.example.com", group: "example.com", angle: 0, importance: 10),
            EdgeLayout.Item(id: "hooks.example.com", group: "example.com", angle: .pi, importance: 1),
            EdgeLayout.Item(id: "laptop.local", group: "laptop.local", angle: .pi / 2, importance: 5),
            EdgeLayout.Item(id: "nowhere", group: "nowhere", angle: nil),
        ]
        let places = EdgeLayout().layOut(items, around: region, margin: 300)
        #expect(places.count == 4)
        for place in places.values {
            #expect(!region.insetBy(dx: -299, dy: -299).contains(place.point), "outside the region and its margin")
        }
        // The two of example.com are neighbours round the edge.
        let order = places.sorted { $0.value.angle < $1.value.angle }.map(\.key)
        let a = order.firstIndex(of: "api.example.com")!, b = order.firstIndex(of: "hooks.example.com")!
        #expect(abs(a - b) == 1 || abs(a - b) == order.count - 1)
        // laptop.local points down (y runs down), so it sits below the middle.
        #expect(places["laptop.local"]!.point.y > region.midY)
    }

    @Test func endpointsKeepTheirSpacing() {
        let items = (0..<40).map { EdgeLayout.Item(id: "e\($0)", group: "g\($0 % 3)", angle: 0.3) }
        let places = EdgeLayout(spacing: 1.0 / 28).layOut(items, around: CGRect(x: 0, y: 0, width: 1000, height: 1000), margin: 100)
        let angles = places.values.map(\.angle).sorted()
        let gaps = zip(angles, angles.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { $0 > 2 * .pi / 40 * 0.99 })
    }

    @Test func groupsWantingTheSamePlaceStayTogether() {
        let items = ["a", "b", "c"].flatMap { group in (0..<4).map { EdgeLayout.Item(id: "\(group)\($0)", group: group, angle: 0.3 + Double($0) * 0.01) } }
        let places = EdgeLayout().layOut(items, around: CGRect(x: 0, y: 0, width: 1000, height: 600), margin: 100)
        let order = places.sorted { $0.value.angle < $1.value.angle }.map { String($0.key.prefix(1)) }
        // Round the circle, each group's run is unbroken: the group changes three times at most.
        let changes = zip(order, order.dropFirst() + [order[0]]).filter { $0 != $1 }.count
        #expect(changes == 3, "\(order)")
    }

    @Test func runsMeetingRoundTheBackDontOverlap() {
        // Groups wanting to be just either side of the start, so the last run would run into the first.
        var items: [EdgeLayout.Item] = []
        for (group, angle) in [("a", 6.0), ("b", 0.2), ("c", 5.6), ("d", 0.6)] {
            for index in 0..<5 { items.append(EdgeLayout.Item(id: "\(group)\(index)", group: group, angle: angle)) }
        }
        let places = EdgeLayout(spacing: 1.0 / 28).layOut(items, around: CGRect(x: 0, y: 0, width: 1000, height: 600), margin: 100)
        let angles: [Double] = places.values.map { $0.angle }.sorted()
        var gaps: [Double] = zip(angles, angles.dropFirst()).map { $1 - $0 }
        gaps.append(angles[0] + 2 * Double.pi - angles[angles.count - 1])
        let step = 2 * Double.pi / 28
        #expect(gaps.allSatisfy { $0 > step * 0.99 }, "\(gaps.map { ($0 / step * 100).rounded() / 100 })")
    }
}
