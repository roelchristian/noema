import SwiftUI

enum EditorPreferences {
    static let aiSummariesKey = "enableOnDeviceAISummaries"
    static let showSemanticHeadingsKey = "showSemanticBlockHeadings"
}

struct NoemaSettings: View {
    @AppStorage(EditorPreferences.showSemanticHeadingsKey) private var showSemanticHeadings = false

    @AppStorage(EditorPreferences.aiSummariesKey) private var aiSummaries = false

    var body: some View {
        Form {
            Section("Block display") {
                Toggle("Show semantic block headings", isOn: $showSemanticHeadings)
                Text("Show names such as Idea and Question above block text. Icons are always shown.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Apple Intelligence") {
                Toggle("Enable on-device AI summaries", isOn: $aiSummaries)
                Text("Use Summarize on a page to generate a pinned Summary block on this Mac. Requires Apple Intelligence enabled in System Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(OnDeviceSummary.unavailabilityReason ?? "On-device model is available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Text("Noema follows macOS appearance, accent and highlight colors, and accessibility settings. Change these in System Settings.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped).padding(16).frame(width: 460)
    }
}
