import Foundation
import LanguageClient

/// The one stretch where two texts differ, in UTF-16 offsets of the first: what a text view replaces to turn one into
/// the other without touching the rest, so its selection and scrolling stay where they were.
public struct TextDifference: Equatable, Sendable {
    /// The stretch of the old text that changes.
    public var range: Range<Int>
    /// What it becomes.
    public var replacement: String

    public init(range: Range<Int>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    public init(from old: String, to new: String) {
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        // A character written as two code units isn't split between what stays and what changes.
        if prefix > 0, (0xD800...0xDBFF).contains(a[prefix - 1]) { prefix -= 1 }
        if suffix > 0, a.count - suffix < a.count, (0xDC00...0xDFFF).contains(a[a.count - suffix]) { suffix -= 1 }
        range = prefix..<(a.count - suffix)
        replacement = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
    }

    /// `text` with the server's changes made, each against `text` as it is, positions read with `lines`.
    public static func applying(_ edits: [LSPTextEdit], to text: String, lines: LineIndex) -> String {
        let result = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.start > $1.range.start }) {
            let range = lines.range(of: edit.range)
            result.replaceCharacters(in: NSRange(location: range.lowerBound, length: range.count), with: edit.newText)
        }
        return result as String
    }
}

/// A line of a comparison between two texts, for showing what a change does.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable {
        case same, removed, added
    }

    public var kind: Kind
    public var text: String
    /// Its line in the old text, from 1, for lines that are there.
    public var oldLine: Int?
    /// Its line in the new text, from 1.
    public var newLine: Int?

    /// The lines that differ between two texts, with `context` lines around each change, in order.
    public static func between(_ old: String, _ new: String, context: Int = 1) -> [DiffLine] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        // The longest common subsequence of lines, from the end, then walked from the start.
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var all: [DiffLine] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                all.append(DiffLine(kind: .same, text: a[i], oldLine: i + 1, newLine: j + 1))
                i += 1
                j += 1
            } else if i < a.count, j == b.count || lengths[i + 1][j] >= lengths[i][j + 1] {
                // A removed line comes before what replaces it, as diffs show them.
                all.append(DiffLine(kind: .removed, text: a[i], oldLine: i + 1, newLine: nil))
                i += 1
            } else {
                all.append(DiffLine(kind: .added, text: b[j], oldLine: nil, newLine: j + 1))
                j += 1
            }
        }
        // Keep the changes and a little around them.
        let changed = all.indices.filter { all[$0].kind != .same }
        return all.indices.filter { index in changed.contains { abs($0 - index) <= context } }.map { all[$0] }
    }
}
