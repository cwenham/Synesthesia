import Foundation
import LanguageClient

/// What a word in Meeplang is, for colouring, from `meep lsp`'s semantic tokens. The platform's text view picks a
/// colour for each.
public enum TokenStyle: String, Sendable, CaseIterable {
    case keyword
    /// A verb, such as Fetch.
    case verb
    /// An inflection (`Fetch.HTTP`), or a method called in an expression.
    case method
    /// A plugin's name.
    case namespace
    /// A template, where it's declared or used.
    case template
    /// A named parameter, or a template's parameter.
    case parameter
    /// A setting under `defaults`, or a member in an expression.
    case property
    /// A module's name after `as`.
    case name
    case constant
    /// `msg` and `fam`.
    case builtin
    /// A message type, after `is`.
    case type
    /// `@errors`, `@buffer=5`.
    case decorator
    case string
    case number
    case `operator`
    case comment
    case variable

    /// The style for a token of `type` with `modifiers`, as `meep lsp` names them (Meep2's lsp-graph report).
    public static func of(type: String, modifiers: Set<String>) -> TokenStyle {
        switch type {
        case "function": .verb
        case "macro": .template
        case "method": .method
        case "namespace": .namespace
        case "parameter": .parameter
        case "property": .property
        case "type": .type
        case "decorator": .decorator
        case "keyword": .keyword
        case "string": .string
        case "number": .number
        case "operator": .operator
        case "comment": .comment
        case "variable":
            modifiers.contains("defaultLibrary") ? .builtin
                : modifiers.contains("readonly") ? .constant
                : modifiers.contains("declaration") ? .name
                : .variable
        default: .variable
        }
    }
}

/// A stretch of text to colour, in UTF-16 offsets.
public struct Highlight: Sendable, Equatable {
    public var range: Range<Int>
    public var style: TokenStyle

    public init(range: Range<Int>, style: TokenStyle) {
        self.range = range
        self.style = style
    }

    /// The highlights semantic tokens' data gives, with the server's legend, in a text whose lines are `lines`.
    public static func from(_ data: [Int], legend: SemanticTokensLegend, lines: LineIndex) -> [Highlight] {
        var highlights: [Highlight] = []
        highlights.reserveCapacity(data.count / 5)
        var line = 0
        var start = 0
        var index = 0
        while index + 4 < data.count {
            let deltaLine = data[index]
            let deltaStart = data[index + 1]
            let length = data[index + 2]
            let type = data[index + 3]
            let bits = data[index + 4]
            index += 5
            line += deltaLine
            start = deltaLine == 0 ? start + deltaStart : deltaStart
            guard line < lines.lineCount, type >= 0, type < legend.tokenTypes.count else { continue }
            var modifiers: Set<String> = []
            for (bit, name) in legend.tokenModifiers.enumerated() where bits & (1 << bit) != 0 { modifiers.insert(name) }
            let lineRange = lines.range(ofLine: line)
            let from = min(lineRange.lowerBound + start, lines.length)
            // A token may run past its line, as a comment the server measured differently might; it's cut at the line.
            let to = min(from + length, max(lineRange.upperBound, from))
            guard to > from else { continue }
            highlights.append(Highlight(range: from..<to, style: .of(type: legend.tokenTypes[type], modifiers: modifiers)))
        }
        return highlights
    }
}
