import SwiftUI

enum EditorPreferences {
    static let showSemanticHeadingsKey = "showSemanticBlockHeadings"
}

struct NoemaSettings: View {
    @AppStorage(EditorPreferences.showSemanticHeadingsKey) private var showSemanticHeadings = false

    var body: some View {
        Form {
            Section("Block display") {
                Toggle("Show semantic block headings", isOn: $showSemanticHeadings)
                Text("Show names such as Idea and Question above block text. Icons are always shown.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Text("Noema follows macOS appearance, accent and highlight colors, and accessibility settings. Change these in System Settings.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped).padding(16).frame(width: 460)
    }
}
