import Foundation

/// C# as the code level shows it (design, section 2, level 1): coloured by a small lexer, with each class's lines
/// found by its braces. It's not a parser and doesn't need to be: it reads well enough to show code by, without a C#
/// language server, as step 10 asks. Offsets are UTF-16, as `NSString`, `LineIndex` and ``Highlight`` count.
public struct CSharpText: Sendable, Equatable {
    public let text: String
    public let lines: LineIndex
    /// The colours, in order.
    public let highlights: [Highlight]
    private let tokens: [Token]
    private let units: [UInt16]

    public init(_ text: String) {
        self.text = text
        lines = LineIndex(text)
        units = Array(text.utf16)
        var lexer = Lexer(units)
        tokens = lexer.run()
        highlights = tokens.compactMap { token in token.style.map { Highlight(range: token.range, style: $0) } }
    }

    /// A class, record, struct or interface in the text: where it's declared, where its attributes and documentation
    /// above start, and the line of its closing brace. Lines count from 0.
    public struct TypeSpan: Sendable, Equatable {
        /// The line with `class Name`.
        public var declaration: Int
        /// The first line of the documentation comment and attributes above it, or the declaration's.
        public var first: Int
        /// The line of its closing brace, or the declaration's if none was found.
        public var last: Int

        public var lines: ClosedRange<Int> { first...last }
    }

    /// The type a class name from Meep's catalogue (`Meep2.Modules.Fetch` or `Outer+Inner`) is declared as, starting
    /// at `line` (from 0) if the PDB's line declares it, or else the declaration of that name nearest to it: a file
    /// changed since Meep was built may have moved it.
    public func span(ofClass className: String, near line: Int?) -> TypeSpan? {
        let name = Self.shortName(className)
        var declarations: [(line: Int, index: Int)] = []
        for (index, token) in tokens.enumerated() where token.kind == .keyword && Self.typeKeywords.contains(word(token)) {
            guard let next = tokens[(index + 1)...].first(where: { $0.kind != .comment }),
                  [.identifier, .type, .method].contains(next.kind), word(next) == name else { continue }
            declarations.append((lines.line(at: token.range.lowerBound), index))
        }
        guard !declarations.isEmpty else { return nil }
        let target = line ?? 0
        let chosen = declarations.min { abs($0.line - target) < abs($1.line - target) }!
        return TypeSpan(declaration: chosen.line, first: leadingLine(above: chosen.line), last: closingLine(after: chosen.index) ?? chosen.line)
    }

    /// `Meep2.Modules.Fetch+Http`1` as it's written in C#: `Http`.
    public static func shortName(_ className: String) -> String {
        var name = Substring(className)
        if let dot = name.lastIndex(where: { $0 == "." || $0 == "+" }) { name = name[name.index(after: dot)...] }
        if let tick = name.firstIndex(of: "`") { name = name[..<tick] }
        return String(name)
    }

    static let typeKeywords: Set<String> = ["class", "record", "struct", "interface"]

    private func word(_ token: Token) -> String {
        String(decoding: units[token.range], as: UTF16.self)
    }

    /// The first line of the attributes and `///` documentation directly above `line`.
    private func leadingLine(above line: Int) -> Int {
        var first = line
        var candidate = line - 1
        while candidate >= 0 {
            let range = lines.range(ofLine: candidate)
            let content = lineText(range).trimmingCharacters(in: .whitespaces)
            guard content.hasPrefix("[") || content.hasPrefix("///") else { break }
            first = candidate
            candidate -= 1
        }
        return first
    }

    private func lineText(_ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    /// Line `line` (from 0), without its line break.
    public func line(_ line: Int) -> String {
        lineText(lines.range(ofLine: line))
    }

    /// The line of the brace that closes the body opened after the token at `index`.
    private func closingLine(after index: Int) -> Int? {
        var depth = 0
        var opened = false
        for token in tokens[(index + 1)...] {
            switch token.kind {
            case .open:
                depth += 1
                opened = true
            case .close:
                depth -= 1
                if opened, depth == 0 { return lines.line(at: token.range.lowerBound) }
            case .semicolon where !opened:
                // `record Point(int X, int Y);` has no body.
                return lines.line(at: token.range.lowerBound)
            default:
                break
            }
        }
        return nil
    }
}

// MARK: The lexer

struct Token: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case keyword, identifier, type, method, attribute, string, number, comment, preprocessor, open, close, semicolon, other
    }

    var range: Range<Int>
    var kind: Kind

    var style: TokenStyle? {
        switch kind {
        case .keyword: .keyword
        case .type: .type
        case .method: .method
        case .attribute: .decorator
        case .string: .string
        case .number: .number
        case .comment: .comment
        case .preprocessor: .decorator
        case .identifier, .open, .close, .semicolon, .other: nil
        }
    }
}

/// Reads C# into tokens: comments, strings of every kind (verbatim, interpolated with their holes, raw), characters,
/// numbers, words and braces.
struct Lexer {
    private let units: [UInt16]
    private var at = 0
    private var tokens: [Token] = []
    /// Whether nothing but spaces has come on this line yet, for attributes and `#if`.
    private var lineStart = true
    /// Whether the next word names an attribute: just after a `[` that starts a line, or a `,` within one.
    private var attributeNext = false
    private var inAttribute = 0
    /// Brackets within an attribute's arguments, where a comma doesn't start another attribute.
    private var attributeParens = 0

    init(_ units: [UInt16]) {
        self.units = units
    }

    static let keywords: Set<String> = [
        "abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char", "checked", "class", "const", "continue",
        "decimal", "default", "delegate", "do", "double", "else", "enum", "event", "explicit", "extern", "false", "finally",
        "fixed", "float", "for", "foreach", "goto", "if", "implicit", "in", "int", "interface", "internal", "is", "lock",
        "long", "namespace", "new", "null", "object", "operator", "out", "override", "params", "private", "protected",
        "public", "readonly", "ref", "return", "sbyte", "sealed", "short", "sizeof", "stackalloc", "static", "string",
        "struct", "switch", "this", "throw", "true", "try", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort",
        "using", "virtual", "void", "volatile", "while",
        // Contextual, but read as keywords wherever they're likely to be.
        "add", "and", "async", "await", "dynamic", "get", "global", "init", "managed", "nameof", "nint", "not", "notnull",
        "nuint", "or", "partial", "record", "remove", "required", "scoped", "set", "unmanaged", "value", "var", "when",
        "where", "with", "yield", "file",
    ]

    mutating func run() -> [Token] {
        while at < units.count {
            let unit = units[at]
            if unit == 0x0A {
                lineStart = true
                at += 1
                continue
            }
            if unit == 0x20 || unit == 0x09 || unit == 0x0D {
                at += 1
                continue
            }
            let start = at
            let wasLineStart = lineStart
            lineStart = false
            switch unit {
            case slash where peek(1) == slash:
                skipToLineEnd()
                add(start, .comment)
            case slash where peek(1) == star:
                at += 2
                while at < units.count, !(units[at] == star && peek(1) == slash) { at += 1 }
                at = min(at + 2, units.count)
                add(start, .comment)
            case hash where wasLineStart:
                skipToLineEnd()
                add(start, .preprocessor)
            case quote:
                skipString()
                add(start, .string)
            case at_ where peek(1) == quote || peek(1) == dollar && peek(2) == quote,
                 dollar where peek(1) == quote || peek(1) == dollar || peek(1) == at_ && peek(2) == quote:
                skipString()
                add(start, .string)
            case apostrophe:
                skipCharacter()
                add(start, .string)
            case 0x30...0x39:
                skipNumber()
                add(start, .number)
            case 0x2E where (0x30...0x39).contains(peek(1) ?? 0):
                skipNumber()
                add(start, .number)
            case openBrace:
                at += 1
                add(start, .open)
            case closeBrace:
                at += 1
                add(start, .close)
            case semicolon:
                at += 1
                add(start, .semicolon)
            case openBracket:
                at += 1
                if wasLineStart {
                    inAttribute = 1
                    attributeNext = true
                } else if inAttribute > 0 {
                    inAttribute += 1
                }
                add(start, .other)
            case closeBracket:
                at += 1
                if inAttribute > 0 { inAttribute -= 1 }
                if inAttribute == 0 {
                    attributeNext = false
                    attributeParens = 0
                }
                add(start, .other)
            case openParen:
                at += 1
                if inAttribute > 0 { attributeParens += 1 }
                add(start, .other)
            case closeParen:
                at += 1
                if inAttribute > 0, attributeParens > 0 { attributeParens -= 1 }
                add(start, .other)
            case comma:
                at += 1
                if inAttribute == 1, attributeParens == 0 { attributeNext = true }
                add(start, .other)
            default:
                if isWordStart(unit) {
                    readWord(start)
                } else {
                    at += 1
                    add(start, .other)
                }
            }
        }
        return tokens
    }

    // MARK: Words

    private mutating func readWord(_ start: Int) {
        if units[at] == at_ { at += 1 }
        while at < units.count, isWordPart(units[at]) { at += 1 }
        let word = String(decoding: units[start..<at], as: UTF16.self)
        if attributeNext {
            attributeNext = false
            // `[return: NotNull]` and `[assembly: …]` name a target first.
            if peekPastSpaces() == colon {
                add(start, .keyword)
                attributeNext = true
            } else {
                add(start, .attribute)
            }
            return
        }
        if Self.keywords.contains(word), units[start] != at_ {
            add(start, .keyword)
            return
        }
        let next = peekPastSpaces()
        if next == openParen || next == lessThan && genericCallFollows() {
            add(start, .method)
        } else if let first = word.unicodeScalars.first(where: { $0 != "@" }), CharacterSet.uppercaseLetters.contains(first) {
            add(start, .type)
        } else {
            add(start, .identifier)
        }
    }

    /// Whether `<…>(` follows, as in `Get<T>(`, rather than a comparison.
    private func genericCallFollows() -> Bool {
        var index = at
        while index < units.count, units[index] == 0x20 { index += 1 }
        guard index < units.count, units[index] == lessThan else { return false }
        var depth = 0
        while index < units.count {
            switch units[index] {
            case lessThan: depth += 1
            case greaterThan:
                depth -= 1
                if depth == 0 {
                    index += 1
                    while index < units.count, units[index] == 0x20 { index += 1 }
                    return index < units.count && units[index] == openParen
                }
            case 0x0A, semicolon, openBrace, closeBrace, openParen: return false
            default: break
            }
            index += 1
        }
        return false
    }

    private func isWordStart(_ unit: UInt16) -> Bool {
        unit == underscore || unit == at_ && at + 1 < units.count && isWordPart(units[at + 1]) || isLetter(unit)
    }

    private func isWordPart(_ unit: UInt16) -> Bool {
        unit == underscore || (0x30...0x39).contains(unit) || isLetter(unit)
    }

    private func isLetter(_ unit: UInt16) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit >= 0x80 && !(0xD800...0xDFFF).contains(unit)
            && Unicode.Scalar(unit).map { CharacterSet.letters.contains($0) } ?? false
    }

    // MARK: Literals

    /// Any string: `"…"`, `@"…"`, `$"…{hole}…"`, `$@"…"`, and raw `"""…"""` with as many `$` as its holes need.
    private mutating func skipString() {
        var verbatim = false
        var dollars = 0
        while at < units.count, units[at] == dollar || units[at] == at_ {
            if units[at] == dollar { dollars += 1 } else { verbatim = true }
            at += 1
        }
        guard at < units.count, units[at] == quote else { return }
        var quotes = 0
        while at + quotes < units.count, units[at + quotes] == quote { quotes += 1 }
        if quotes >= 3 {
            // Raw: it ends at a run of as many quotes. Its holes are left as string.
            at += quotes
            while at < units.count {
                if units[at] == quote {
                    var run = 0
                    while at + run < units.count, units[at + run] == quote { run += 1 }
                    at += run
                    if run >= quotes { return }
                } else {
                    at += 1
                }
            }
            return
        }
        at += 1
        while at < units.count {
            let unit = units[at]
            if unit == quote {
                if verbatim, peek(1) == quote {
                    at += 2
                    continue
                }
                at += 1
                return
            }
            if unit == backslash, !verbatim {
                at += 2
                continue
            }
            if unit == 0x0A, !verbatim { return }
            if unit == openBrace, dollars > 0 {
                if peek(1) == openBrace {
                    at += 2
                    continue
                }
                skipHole()
                continue
            }
            at += 1
        }
    }

    /// An interpolated string's `{…}`, which can hold code, and strings of its own.
    private mutating func skipHole() {
        var depth = 0
        while at < units.count {
            let unit = units[at]
            switch unit {
            case openBrace:
                depth += 1
                at += 1
            case closeBrace:
                depth -= 1
                at += 1
                if depth == 0 { return }
            case quote:
                skipString()
            case at_ where peek(1) == quote, dollar where peek(1) == quote || peek(1) == at_ || peek(1) == dollar:
                skipString()
            case apostrophe:
                skipCharacter()
            case 0x0A:
                return
            default:
                at += 1
            }
        }
    }

    private mutating func skipCharacter() {
        at += 1
        while at < units.count, units[at] != apostrophe, units[at] != 0x0A {
            at += units[at] == backslash ? 2 : 1
        }
        if at < units.count, units[at] == apostrophe { at += 1 }
    }

    private mutating func skipNumber() {
        while at < units.count {
            let unit = units[at]
            let isDigitish = (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit == underscore
            if isDigitish || unit == 0x2E && (0x30...0x39).contains(peek(1) ?? 0) { at += 1 } else { break }
        }
    }

    private mutating func skipToLineEnd() {
        while at < units.count, units[at] != 0x0A { at += 1 }
    }

    // MARK: Helpers

    private func peek(_ ahead: Int) -> UInt16? {
        at + ahead < units.count ? units[at + ahead] : nil
    }

    private func peekPastSpaces() -> UInt16? {
        var index = at
        while index < units.count, units[index] == 0x20 || units[index] == 0x09 { index += 1 }
        return index < units.count ? units[index] : nil
    }

    private mutating func add(_ start: Int, _ kind: Token.Kind) {
        tokens.append(Token(range: start..<at, kind: kind))
    }
}

private let slash: UInt16 = 0x2F
private let star: UInt16 = 0x2A
private let hash: UInt16 = 0x23
private let quote: UInt16 = 0x22
private let apostrophe: UInt16 = 0x27
private let at_: UInt16 = 0x40
private let dollar: UInt16 = 0x24
private let backslash: UInt16 = 0x5C
private let openBrace: UInt16 = 0x7B
private let closeBrace: UInt16 = 0x7D
private let openBracket: UInt16 = 0x5B
private let closeBracket: UInt16 = 0x5D
private let openParen: UInt16 = 0x28
private let closeParen: UInt16 = 0x29
private let lessThan: UInt16 = 0x3C
private let greaterThan: UInt16 = 0x3E
private let semicolon: UInt16 = 0x3B
private let comma: UInt16 = 0x2C
private let colon: UInt16 = 0x3A
private let underscore: UInt16 = 0x5F
