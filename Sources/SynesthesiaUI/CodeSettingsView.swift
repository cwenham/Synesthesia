import SwiftUI

/// Where the code level opens C#: the editor chosen from those installed, kept between runs.
public struct CodeSettingsView: View {
    let editors: CodeEditors
    @AppStorage(CodeEditors.choiceKey) private var saved = ""

    public init(editors: CodeEditors) {
        self.editors = editors
    }

    public var body: some View {
        let installed = editors.installed()
        Form {
            Section("C#") {
                if installed.isEmpty {
                    Text("Neither Rider nor VS Code is installed, so C# opens in the browser, from its SourceLink, when it can.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Open C# in", selection: Binding(get: { editors.chosen(saved)?.id ?? "" }, set: { saved = $0 })) {
                        ForEach(installed) { Text($0.name).tag($0.id) }
                    }
                }
                Text("The code level shows the C# of a module's verb beside the canvas. Its Open button opens the file at the class's line in this editor; a file that isn't on this Mac opens on GitHub instead, at the commit Meep was built from.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 200)
    }
}
