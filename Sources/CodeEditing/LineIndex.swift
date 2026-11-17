import Foundation
import LanguageClient
import MeepClient

/// Where each line of a text starts, in UTF-16 code units, the unit `NSString`, the Language Server Protocol and
/// Meep's spans all count in. Turns positions, spans and offsets into each other.
public struct LineIndex: Sendable, Equatable {
    /// The offset each line starts at; the first is 0.
    public private(set) var starts: [Int]
    /// The text's length.
    public private(set) var length: Int

    public init(_ text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        self.starts = starts
        length = offset
    }

    public var lineCount: Int { starts.count }

    /// The line, from 0, that `offset` is on.
    public func line(at offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Where `line` (from 0) starts and ends, not counting its line break.
    public func range(ofLine line: Int) -> Range<Int> {
        guard line >= 0, line < starts.count else { return length..<length }
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : length
        return starts[line]..<max(starts[line], end)
    }

    /// The offset of a position, kept within the text.
    public func offset(of position: LSPPosition) -> Int {
        guard position.line < starts.count else { return length }
        let line = range(ofLine: max(position.line, 0))
        return min(line.lowerBound + max(position.character, 0), line.upperBound)
    }

    public func position(at offset: Int) -> LSPPosition {
        let clamped = min(max(offset, 0), length)
        let line = line(at: clamped)
        return LSPPosition(line: line, character: clamped - starts[line])
    }

    public func range(of range: LSPRange) -> Range<Int> {
        let start = offset(of: range.start)
        return start..<max(start, offset(of: range.end))
    }

    /// The offsets of a span from Meep's graph, whose lines and columns count from 1.
    public func range(of span: GraphSpan) -> Range<Int> {
        let start = offset(of: LSPPosition(line: span.startLine - 1, character: span.startColumn - 1))
        let end = offset(of: LSPPosition(line: span.endLine - 1, character: span.endColumn - 1))
        return start..<max(start, end)
    }
}
