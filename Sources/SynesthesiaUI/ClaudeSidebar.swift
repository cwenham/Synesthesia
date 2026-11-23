import Assistant
import CoreGraphics
import Foundation
import ImageIO
import MeepClient
import SwiftUI

extension EnvironmentValues {
    /// The Claude sidebar's conversation, if the app offers one.
    @Entry public var claude: ClaudeChat?
}

/// Claude in the app (design, section 8): a conversation about what's on screen, with replies streaming in, each tool
/// call shown as it runs, and tools that go beyond looking allowed by the person first. Shared by the Mac and the iPad.
public struct ClaudeSidebar: View {
    @Bindable var chat: ClaudeChat
    @State private var draft = ""
    @FocusState private var composing: Bool
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #else
    @State private var showsSettings = false
    #endif

    public init(chat: ClaudeChat) {
        self.chat = chat
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            conversation
            if let approval = chat.approval {
                Divider()
                ApprovalCard(approval: approval) { chat.decide($0) }
                    .padding(12)
            }
            if chat.isBusy || chat.canRetry {
                StatusLine(chat: chat)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            if !chat.key.isSaved {
                KeyBanner(open: openClaudeSettings)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            Divider()
            composer
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "meep" else { return .systemAction }
            Task { await chat.show(url.absoluteString) }
            return .handled
        })
        .environment(\.noticeAction) { action in
            switch action {
            case .openSettings: openClaudeSettings()
            case .retry: chat.retry()
            case .startOver: chat.startOver()
            }
        }
        #if !os(macOS)
        .sheet(isPresented: $showsSettings) {
            NavigationStack { ClaudeSettingsView(chat: chat) }
        }
        #endif
        .onAppear { composing = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Claude", systemImage: "sparkles")
                .font(.headline)
                .labelStyle(.titleAndIcon)
            Spacer()
            Menu {
                Button("New Conversation") { chat.startOver() }
                    .disabled(chat.entries.isEmpty && !chat.isBusy)
                Divider()
                Picker("Effort", selection: $chat.effort) {
                    ForEach(Effort.allCases) { Text($0.title).tag($0) }
                }
                Button("Claude Settings…") { openClaudeSettings() }
                if chat.usage.requests > 0 {
                    Divider()
                    Text(usageText)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New conversation, effort and settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var usageText: String {
        let usage = chat.usage
        let read = usage.input + usage.cacheRead + usage.cacheWrite
        let cached = read > 0 ? Int((Double(usage.cacheRead) / Double(read) * 100).rounded()) : 0
        return "This conversation: \(usage.requests) request\(usage.requests == 1 ? "" : "s"), \(read.formatted()) tokens read (\(cached)% from the cache), \(usage.output.formatted()) written"
    }

    @ViewBuilder private var conversation: some View {
        if chat.entries.isEmpty {
            // In a scroll view, like the conversation, so its text never makes the window taller than it is.
            ScrollView {
                EmptyConversation()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ScrollView {
                ChatTranscript(entries: chat.entries, lazy: true)
                    .padding(12)
            }
            .defaultScrollAnchor(.bottom)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about what's on screen", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($composing)
                .onSubmit(send)
            if chat.isBusy {
                Button(action: chat.stop) {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop Claude (⌘.)")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Ask (Return)")
            }
        }
        .padding(12)
    }

    private func send() {
        guard !chat.isBusy, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        chat.ask(draft)
        draft = ""
    }

    private func openClaudeSettings() {
        UserDefaults.standard.set(SettingsTab.claude.rawValue, forKey: SettingsTab.key)
        #if os(macOS)
        openSettings()
        #else
        showsSettings = true
        #endif
    }
}

/// The tabs of the app's Settings window, so the sidebar can open it at Claude's.
public enum SettingsTab: String {
    case canvas, code, claude
    public static let key = "settingsTab"
}

extension EnvironmentValues {
    @Entry var noticeAction: (Notice.Action) -> Void = { _ in }
}

/// Before the first question: what the sidebar is for, and what it sends where.
struct EmptyConversation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about what's on screen.")
                .font(.title3.weight(.semibold))
            Text("Each question goes with what the canvas is on and what you've selected, so “why is this queue growing?” needs no explaining.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("For example:").foregroundStyle(.secondary)
                Text("• Which module is the slowest here?")
                Text("• Why are messages going to @errors?")
                Text("• Add a Where that drops empty orders.")
            }
            .font(.callout)
            Text("Your questions, the app's note of what's on screen, and what the tools return are sent to Anthropic's API with your key. Claude asks before it taps real messages, offers a message to send, or proposes edits.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
    }
}

/// Asks for a key when none is kept.
struct KeyBanner: View {
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Claude needs your Anthropic API key.", systemImage: "key")
                .font(.callout.weight(.medium))
            Button("Open Settings…", action: open)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The conversation's entries, one under another.
struct ChatTranscript: View {
    let entries: [ChatEntry]
    /// Whether entries are made only as they scroll into sight, as in the sidebar; not when drawn off screen.
    var lazy = false

    var body: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 12) { rows }
        } else {
            VStack(alignment: .leading, spacing: 12) { rows }
        }
    }

    private var rows: some View {
        ForEach(entries) { entry in
            EntryView(entry: entry)
        }
    }
}

/// One entry in the conversation.
struct EntryView: View {
    let entry: ChatEntry

    var body: some View {
        switch entry.kind {
        case .question(let text):
            VStack(alignment: .leading, spacing: 3) {
                Text("You").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .reply(let text):
            ChatMarkdownView(text: text)
        case .thinking(let text):
            ThinkingView(text: text)
        case .tool(let call):
            ToolCallView(call: call)
        case .notice(let notice):
            NoticeView(notice: notice)
        }
    }
}

/// A summary of Claude's thinking, folded to its first line.
struct ThinkingView: View {
    let text: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(open ? "Thinking" : firstLine)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(.secondary)
                .font(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Fold the summary of Claude's thinking" : text)
            if open {
                Text(ChatMarkdown.inline(text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14)
            }
        }
    }

    private var firstLine: String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        return line.replacingOccurrences(of: "**", with: "")
    }
}

/// A tool call: what it is, what it's about, whether it ran, and, unfolded, its input and result.
struct ToolCallView: View {
    let call: ToolCall
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    status.frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(call.title).font(.callout.weight(.medium))
                        if let address = call.address, !address.isEmpty {
                            Text(address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let note = stateNote {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(call.name): \(open ? "fold" : "show") its input and result")
            if open { details }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var status: some View {
        switch call.state {
        case .writing, .running:
            ProgressView().controlSize(.mini)
        case .waiting:
            Image(systemName: "hand.raised").foregroundStyle(.orange)
        case .finished:
            Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        case .notRun:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private var stateNote: String? {
        switch call.state {
        case .waiting: "Waiting for you to allow it."
        case .failed(let why?): why
        case .notRun(let why): why
        default: nil
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Block(text: call.input.map { $0.text(pretty: true) } ?? call.json)
            if let result = call.result {
                Text(result.isError ? "Result (failed)" : "Result").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(result.content.enumerated()), id: \.offset) { _, content in
                    switch content {
                    case .text(let text): Block(text: text)
                    case .png(let data): Picture(data: data)
                    }
                }
            }
        }
    }

    /// Text in a fixed-width face, scrolling when long.
    private struct Block: View {
        let text: String

        var body: some View {
            ScrollView([.vertical, .horizontal]) {
                Text(text.count > 20_000 ? String(text.prefix(20_000)) + "\n…" : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: 220)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private struct Picture: View {
        let data: Data

        var body: some View {
            if let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

/// Something the sidebar says, with what to do about it.
struct NoticeView: View {
    let notice: Notice
    @Environment(\.noticeAction) private var act

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title).font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = notice.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action = notice.action {
                    Button(title(of: action)) { act(action) }
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(notice.kind == .stopped ? 0 : 10)
        .background(notice.kind == .stopped ? Color.clear : color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch notice.kind {
        case .refusal: "hand.raised.slash"
        case .limit: "gauge.with.dots.needle.100percent"
        case .problem: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle"
        case .switched: "arrow.triangle.branch"
        }
    }

    private var color: Color {
        switch notice.kind {
        case .refusal, .limit: .purple
        case .problem: .orange
        case .stopped: .secondary
        case .switched: .blue
        }
    }

    private func title(of action: Notice.Action) -> String {
        switch action {
        case .openSettings: "Open Settings…"
        case .retry: "Try Again"
        case .startOver: "New Conversation"
        }
    }
}

/// A tool waiting for the person to allow it, with what it would do and what allowing it means.
struct ApprovalCard: View {
    let approval: Approval
    let decide: (Approval.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(ChatMarkdown.inline(approval.headline))
                    .font(.callout.weight(.semibold))
            } icon: {
                Image(systemName: approval.asks == .sendsMessages ? "eye" : "hand.raised").foregroundStyle(.orange)
            }
            if let detail = approval.detail, !detail.isEmpty {
                // Long details are cut short, and shown whole on hover; allowed, they show whole in the app too.
                detailText(detail)
                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .help(detail)
            }
            Text(approval.note)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Allow") { decide(.once) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Don't Allow") { decide(.deny) }
                    .keyboardShortcut(.cancelAction)
            }
            Button(approval.asks == .sendsMessages ? "Allow taps in this conversation" : "Allow in this conversation") { decide(.conversation) }
                #if os(macOS)
                .buttonStyle(.link)
                #else
                .buttonStyle(.borderless)
                #endif
                .font(.callout)
                .help("Don't ask again for this until the conversation starts over.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func detailText(_ detail: String) -> some View {
        Text(detail)
            .font(approval.tool == "inject_message" ? .system(.caption, design: .monospaced) : .callout)
            .lineLimit(8)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
    }
}

/// What the sidebar is doing now, or what to do after a problem.
struct StatusLine: View {
    let chat: ClaudeChat

    var body: some View {
        HStack(spacing: 6) {
            if chat.isBusy {
                if chat.activity != .askingPerson { ProgressView().controlSize(.small) }
                Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            } else if chat.canRetry {
                Button("Try Again", action: chat.retry).controlSize(.small)
            }
            Spacer(minLength: 0)
        }
    }

    private var text: String {
        switch chat.activity {
        case .idle: ""
        case .waiting: "Asking Claude…"
        case .thinking: "Thinking…"
        case .writing: "Writing…"
        case .writingTool(let title): "Getting ready: \(title)…"
        case .running(let title): "Running: \(title)…"
        case .askingPerson: "Waiting for you to allow it."
        case .retrying(let seconds, let why): "Trying again in \(seconds) s: \(why)."
        }
    }
}
