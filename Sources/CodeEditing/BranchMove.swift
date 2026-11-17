import Foundation
import MeepClient

/// Moves a module, with everything under it, to be under another module, by rewriting its lines: one of the two
/// gestures Meep2 has no edit for, whose text the canvas writes itself (design, Q2). `meep lsp` then checks the new
/// text like any other change, and its matching keeps the moved modules' keys (Meep2 Q195).
public enum BranchMove {
    /// `text` with `key`'s branch moved under `target`, from the text's `graph`. Throws why when it can't be done.
    public static func moving(_ key: String, under target: String, in text: String, graph: PipelineGraph, file: String) throws -> String {
        let modules = Dictionary(graph.modules.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        guard let moving = modules[key], let parent = modules[target] else {
            throw DocumentError("The modules have changed. Try again.")
        }
        guard key != target else { throw DocumentError("A module can't go under itself.") }
        let path = canonical(file)
        for module in [moving, parent] {
            guard canonical(module.span.file) == path, module.templates == nil || module.templates?.isEmpty == true, module.include == nil else {
                throw DocumentError("\(module.module) is written in a template or another file, so it can't be moved here.")
            }
        }
        guard !moving.feeder else {
            throw DocumentError("\(moving.module) is a + line, feeding the module after it, so moving it would change what that receives. Change it in the text.")
        }
        let below = descendants(of: key, in: graph)
        guard !below.contains(target) else { throw DocumentError("\(parent.module) is under \(moving.module), so it can't take it.") }
        guard moving.under != target else { throw DocumentError("\(moving.module) is under \(parent.module) already.") }

        var lines = text.components(separatedBy: "\n")
        // The branch's lines, counting from 0: the module's, those under it, and any comment written right above it.
        var first = moving.span.startLine - 1
        let last = ([moving] + below.compactMap { modules[$0] }).map { $0.span.endLine - 1 }.max() ?? first
        let others = graph.modules.filter { $0.key != key && !below.contains($0.key) && canonical($0.span.file) == path }
        guard !others.contains(where: { ($0.span.startLine - 1) > first && ($0.span.startLine - 1) <= last }) else {
            throw DocumentError("\(moving.module)'s branch isn't written in one piece, so it can't be moved here. Move it in the text.")
        }
        while first > 0, lines[first - 1].trimmingCharacters(in: .whitespaces).hasPrefix("//") { first -= 1 }
        guard last < lines.count else { throw DocumentError("The text has changed. Try again.") }
        let block = Array(lines[first...last])
        lines.removeSubrange(first...last)

        // Where it goes: after the target's own branch, as its last, indented as the target's others are.
        let parentBelow = descendants(of: target, in: graph).filter { $0 != key && !below.contains($0) }
        let parentLast = ([parent] + parentBelow.compactMap { modules[$0] }).map { $0.span.endLine - 1 }.max() ?? (parent.span.endLine - 1)
        let insertAt = (parentLast > last ? parentLast - block.count : parentLast) + 1
        let parentLine = lines[parent.span.startLine - 1 > last ? parent.span.startLine - 1 - block.count : parent.span.startLine - 1]
        let child = graph.modules.first { $0.under == target && $0.key != key && !below.contains($0.key) }
        let indent: String
        if let child, canonical(child.span.file) == path {
            let childLine = text.components(separatedBy: "\n")[child.span.startLine - 1]
            indent = leading(childLine)
        } else {
            indent = leading(parentLine) + "    "
        }
        let from = leading(text.components(separatedBy: "\n")[moving.span.startLine - 1])
        let moved = block.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            let rest = line.hasPrefix(from) ? String(line.dropFirst(from.count)) : line.trimmingCharacters(in: .whitespaces)
            return indent + rest
        }
        lines.insert(contentsOf: moved, at: min(insertAt, lines.count))
        return lines.joined(separator: "\n")
    }

    /// The keys of every module under `key`, at any depth.
    public static func descendants(of key: String, in graph: PipelineGraph) -> [String] {
        var found: [String] = []
        var frontier = [key]
        while let next = frontier.popLast() {
            let children = graph.modules.filter { $0.under == next }.map(\.key)
            found += children
            frontier += children
        }
        return found
    }

    private static func leading(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
