#if os(macOS)
import AppKit
#endif
import CoreGraphics
import Foundation
import ImageIO
import MeepClient
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Assistant
@testable import SynesthesiaUI

/// Claude's replies read as Markdown, with addresses made links.
struct ChatMarkdownTests {
    @Test func blocksAreFound() {
        let text = """
            ## Orders

            It's **busy**:
            - m2 passes the most
              and m3 the least
            1. First
            > Quoted

            After the list.
            - Second list

            | a | b |
            |---|---|
            ```
            Where msg.Count > 2
            """
        #expect(ChatMarkdown.blocks(text) == [
            .heading("Orders", level: 2),
            .paragraph("It's **busy**:"),
            .item("m2 passes the most and m3 the least", depth: 0, marker: "•"),
            .item("First", depth: 0, marker: "1."),
            .quote("Quoted"),
            .paragraph("After the list."),
            .item("Second list", depth: 0, marker: "•"),
            .table("| a | b |\n|---|---|"),
            // A code block still streaming in reads as code.
            .code("Where msg.Count > 2"),
        ])
    }

    @Test func addressesBecomeLinksEvenInCode() throws {
        let attributed = ChatMarkdown.inline("See meep://local/orders/m3, and `meep://local/orders` (it's busy).")
        let links = attributed.runs.compactMap { run in run.link.map { ($0.absoluteString, String(attributed[run.range].characters)) } }
        #expect(links.map(\.0) == ["meep://local/orders/m3", "meep://local/orders"])
        #expect(links.map(\.1) == ["meep://local/orders/m3", "meep://local/orders"])
    }

    @Test func aLabelLinkedToItsAddressReadsAsTheLabel() {
        let attributed = ChatMarkdown.inline("[Seconds](meep://local/slow/m1) feeds [WriteLine #2](meep://local/slow/m2).")
        let links = attributed.runs.compactMap { run in run.link.map { ($0.absoluteString, String(attributed[run.range].characters)) } }
        #expect(links.map(\.0) == ["meep://local/slow/m1", "meep://local/slow/m2"])
        #expect(links.map(\.1) == ["Seconds", "WriteLine #2"])
        #expect(String(attributed.characters) == "Seconds feeds WriteLine #2.")
    }

    @Test func textWithoutAddressesIsLeftAlone() {
        #expect(ChatMarkdown.inline("Nothing to link here.").runs.allSatisfy { $0.link == nil })
    }
}

/// Draws the sidebar's conversation off screen. With `SYNESTHESIA_SNAPSHOTS` set to a folder, it's saved there.
@MainActor
struct ClaudeSidebarTests {
    @Test func aConversationIsDrawnWithItsToolsAndNotices() throws {
        let chat = ClaudeChat(registry: ToolRegistry([]), key: ClaudeKey(store: MemoryStore("test")))
        chat.add(.question("Why is this queue growing?"))
        chat.add(.thinking("**Checking the queue.** The person has orders' Keep selected; I'll watch its counts."))
        var call = ToolCall(id: "1", name: "watch_counts", title: "Watch counts over a period",
                            json: #"{"address": "meep://local/orders/m3", "seconds": 5}"#,
                            input: ["address": "meep://local/orders/m3", "seconds": 5], state: .finished)
        call.result = .json(["received": 210, "passedOn": 140])
        chat.add(.tool(call))
        chat.add(.reply("""
            **Keep** (meep://local/orders/m3) takes in about 42 a second but passes on 28, so 14 a second wait.

            - Its handling time rose from 20 ms to 70 ms.
            - Downstream, `meep://local/orders/m4` is fine.

            Raising its `Parallel` would let it keep up:

            ```
            Keep(Parallel: 4)
            ```
            """))
        chat.add(.tool(ToolCall(id: "2", name: "propose_edits", title: "Propose edits to a pipeline",
                                json: #"{"address": "meep://local/orders"}"#, input: ["address": "meep://local/orders"], state: .waiting)))
        let approval = Approval(
            id: 1, tool: "propose_edits", asks: .change, headline: "Claude wants to propose an edit to meep://local/orders.",
            detail: "Let Keep handle four messages at once",
            note: "If you allow it, the edits show on the canvas and beside the text. Nothing changes unless you accept them there."
        )
        let view = VStack(alignment: .leading, spacing: 12) {
            ChatTranscript(entries: chat.entries)
            ApprovalCard(approval: approval) { _ in }
            NoticeView(notice: Notice(kind: .problem, title: "The Claude API didn't accept your key.",
                                      detail: "Check it in Settings, under Claude.", action: .openSettings))
        }
        .padding(12)
        .frame(width: 380)
        let image = try #require(render(view))
        save(image, as: "claude-sidebar")
        #expect(image.width == 760 && image.height > 600)
    }

    #if os(macOS)
    /// Laying out a window, SwiftUI asks how small each part can be, at the narrowest widths. Text held to its whole
    /// height outside a scroll view answers with a word to a line, and the sidebar once made the window's content far
    /// taller than the window, pushing the hosts, the headers and the docks out of sight.
    @Test func theSidebarNeverNeedsMoreHeightThanAWindowHas() {
        let chat = ClaudeChat(registry: ToolRegistry([]), key: ClaudeKey(store: MemoryStore(nil)))
        let talking = ClaudeChat(registry: ToolRegistry([]), key: ClaudeKey(store: MemoryStore("test")))
        talking.add(.question("Why is this queue growing?"))
        talking.add(.reply(String(repeating: "A reply with many words in it. ", count: 60)))
        talking.add(.notice(Notice(kind: .problem, title: "The Claude API didn't accept your key.",
                                   detail: "Check it in Settings, under Claude.", action: .openSettings)))
        let approval = Approval(
            id: 1, tool: "inject_message", asks: .change, headline: "Claude wants to offer a message to send into meep://local/orders/m1.",
            detail: String(repeating: "A long message with many words in it. ", count: 40),
            note: "If you allow it, the message opens in the composer. Nothing is sent unless you send it."
        )
        let views: [(String, AnyView)] = [
            ("sidebar", AnyView(ClaudeSidebar(chat: chat))),
            ("approval", AnyView(ApprovalCard(approval: approval) { _ in })),
            ("conversation", AnyView(ClaudeSidebar(chat: talking))),
        ]
        for (name, view) in views {
            for width in [0.0, 40.0, 300.0] {
                let least = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 0))
                #expect(least.height < 400, "\(name) at \(width) points wide needs \(least.height) points")
            }
        }
    }
    #endif

    @Test func beforeAQuestionItSaysWhatItSends() throws {
        let image = try #require(render(EmptyConversation().frame(width: 380)))
        save(image, as: "claude-empty")
        #expect(image.height > 200)
    }

    private func render(_ view: some View) -> CGImage? {
        let renderer = ImageRenderer(content: view.background(Color(white: 0.12)).environment(\.colorScheme, .dark))
        renderer.scale = 2
        return renderer.cgImage
    }

    private func save(_ image: CGImage, as name: String) {
        guard let folder = ProcessInfo.processInfo.environment["SYNESTHESIA_SNAPSHOTS"] else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
