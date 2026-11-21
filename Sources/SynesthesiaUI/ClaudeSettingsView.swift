import Assistant
import SwiftUI

/// Claude's settings: the person's API key, kept in their Keychain, and how much Claude thinks. Shown in the app's
/// Settings window, and on the iPad as a sheet from the sidebar.
public struct ClaudeSettingsView: View {
    @Bindable var chat: ClaudeChat
    @State private var draft = ""
    @AppStorage(ClaudeSettingsView.effortKey) private var savedEffort = Effort.medium.rawValue

    /// Where the effort is kept between runs.
    public static let effortKey = "claudeEffort"

    public init(chat: ClaudeChat) {
        self.chat = chat
    }

    public var body: some View {
        Form {
            Section("Anthropic API key") {
                if chat.key.isSaved {
                    LabeledContent {
                        Button("Remove", role: .destructive) { chat.key.remove() }
                    } label: {
                        Label("A key is saved in your Keychain.", systemImage: "key.fill")
                    }
                }
                SecureField(chat.key.isSaved ? "Replace it" : "Key", text: $draft, prompt: Text("sk-ant-…"))
                    .onSubmit(save)
                HStack {
                    Button(chat.key.isSaved ? "Replace Key" : "Save Key", action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Link("Open the Claude Console", destination: URL(string: "https://platform.claude.com")!)
                        .font(.callout)
                }
                if let problem = chat.key.problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                Text("It's kept in your Keychain and sent only to Anthropic's API, with each question. The sidebar asks Claude with it, using \(ClaudeAPI.model), and Anthropic bills your account for what it uses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Thinking") {
                Picker("Effort", selection: $chat.effort) {
                    ForEach(Effort.allCases) { Text($0.title).tag($0) }
                }
                Text("How much Claude thinks before it answers. More is slower and costs more. Medium suits most questions; try High for hard ones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // Tall enough for a saved key's row and a problem, so saving a key doesn't bring a scroll bar.
        .frame(minWidth: 440, minHeight: 440)
        .onChange(of: chat.effort) { _, effort in savedEffort = effort.rawValue }
    }

    private func save() {
        chat.key.save(draft)
        draft = ""
    }
}
