import Foundation
import SwiftUI

/// Claude's replies are Markdown. SwiftUI's `Text` reads only inline Markdown, so the blocks (paragraphs, lists,
/// headings, code, quotes) are found here and each drawn as text, aligned left. A reply that's still streaming in can
/// end anywhere, such as inside a code block, and still reads.
enum ChatMarkdown {
    enum Block: Equatable {
        case paragraph(String)
        case heading(String, level: Int)
        /// A list item, with how deeply it's nested and its marker: "•" or "1.".
        case item(String, depth: Int, marker: String)
        case code(String)
        case quote(String)
        /// A table, drawn as written, in a fixed-width face.
        case table(String)
        case rule
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var table: [String] = []
        var code: [String]?
        /// Whether the line before was a list item's, which a line without a gap continues.
        var inItem = false

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            if !table.isEmpty { blocks.append(.table(table.joined(separator: "\n"))) }
            paragraph = []
            quote = []
            table = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let continuing = inItem
            inItem = false
            if var open = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    open.append(line)
                    code = open
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                code = []
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if trimmed.hasPrefix("|") {
                if !paragraph.isEmpty || !quote.isEmpty { flush() }
                table.append(trimmed)
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                blocks.append(.rule)
                continue
            }
            if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
                continue
            }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !table.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = item(line) {
                flush()
                blocks.append(item)
                inItem = true
                continue
            }
            if !quote.isEmpty || !table.isEmpty { flush() }
            // A line that follows a list item without a gap continues it.
            if continuing, case .item(let text, let depth, let marker)? = blocks.last {
                blocks[blocks.count - 1] = .item(text + " " + trimmed, depth: depth, marker: marker)
                inItem = true
                continue
            }
            paragraph.append(trimmed)
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(String(line.dropFirst(hashes + 1)), level: hashes)
    }

    private static func item(_ line: String) -> Block? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let rest = line.dropFirst(indent)
        let depth = indent / 2
        for bullet in ["- ", "* ", "+ "] where rest.hasPrefix(bullet) {
            return .item(String(rest.dropFirst(2)), depth: depth, marker: "•")
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3, rest.dropFirst(digits.count).hasPrefix(". ") {
            return .item(String(rest.dropFirst(digits.count + 2)), depth: depth, marker: "\(digits).")
        }
        return nil
    }

    /// Inline Markdown (bold, italics, code, links), with every `meep://` address made a link, in code too, so
    /// clicking one shows the place.
    static func inline(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)
        linkAddresses(in: &attributed)
        return attributed
    }

    /// Characters an address doesn't end with, though they may follow it in a sentence.
    private static let trailing = CharacterSet(charactersIn: ".,;:!?)]}'\"”’")

    static func linkAddresses(in attributed: inout AttributedString) {
        let plain = String(attributed.characters)
        guard plain.contains("meep://") else { return }
        let pattern = /meep:\/\/[^\s`<>"'()\[\]{}]*/
        for match in plain.matches(of: pattern) {
            var address = String(plain[match.range])
            while let last = address.unicodeScalars.last, trailing.contains(last) { address.removeLast() }
            guard address.count > "meep://".count, let url = URL(string: address) ?? address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init) else { continue }
            let start = plain.distance(from: plain.startIndex, to: match.range.lowerBound)
            let lower = attributed.characters.index(attributed.startIndex, offsetBy: start)
            let upper = attributed.characters.index(lower, offsetBy: address.count)
            attributed[lower..<upper].link = url
        }
    }
}

/// A reply drawn from its Markdown blocks.
struct ChatMarkdownView: View {
    let text: String

    var body: some View {
        let blocks = ChatMarkdown.blocks(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: ChatMarkdown.Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(ChatMarkdown.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let text, let level):
            Text(ChatMarkdown.inline(text))
                .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 2)
        case .item(let text, let depth, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 12, alignment: .leading)
                Text(ChatMarkdown.inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .code(let code):
            // Scrolls sideways only when a line is too long for the sidebar.
            ViewThatFits(in: .horizontal) {
                codeText(code)
                ScrollView(.horizontal, showsIndicators: false) { codeText(code) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        case .quote(let text):
            Text(ChatMarkdown.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 2) }
                .fixedSize(horizontal: false, vertical: true)
        case .table(let table):
            ViewThatFits(in: .horizontal) {
                tableText(table)
                ScrollView(.horizontal, showsIndicators: false) { tableText(table) }
            }
        case .rule:
            Divider()
        }
    }

    private func codeText(_ code: String) -> some View {
        Text(code)
            .font(.system(.callout, design: .monospaced))
            .fixedSize()
            .padding(8)
    }

    private func tableText(_ table: String) -> some View {
        Text(table)
            .font(.system(.caption, design: .monospaced))
            .fixedSize()
    }
}
