import SwiftUI

/// Preferences choose a provider for an explicit action. They never authorize a
/// request, read credentials, or change automatic on-device work.
struct IntelligenceSettings: View {
    let preferences: AIProviderPreferences
    var appModel: AppModel? = nil
    var showingActivity: Binding<Bool>? = nil

    @State private var localShowingActivity = false
    @State private var showAdvancedOverrides = false
    @AppStorage(EditorPreferences.aiSummariesKey) private var aiSummaries = false
    @AppStorage(EditorPreferences.aiSummaryPlacementKey) private var aiSummaryPlacement = AISummaryPlacement.defaultValue.rawValue

    init(
        preferences: AIProviderPreferences,
        appModel: AppModel? = nil,
        showingActivity: Binding<Bool>? = nil
    ) {
        self.preferences = preferences
        self.appModel = appModel
        self.showingActivity = showingActivity
    }

    var body: some View {
        Section("General AI") {
            Picker("Default AI provider", selection: Binding(
                get: { preferences.settings.defaultProvider },
                set: { preferences.setDefaultProvider($0) }
            )) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            Text(preferences.settings.defaultProvider == .onDevice
                 ? "Processes supported explicit actions privately on this Mac."
                 : "Uses your configured OpenAI connection for supported explicit actions. Submitted content leaves this Mac and API charges may apply.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Enable on-device AI summaries", isOn: $aiSummaries)
            Picker("Summary placement", selection: $aiSummaryPlacement) {
                ForEach(AISummaryPlacement.allCases, id: \.rawValue) { placement in
                    Text(placement.title).tag(placement.rawValue)
                }
            }
            LabeledContent("On-device availability", value: onDeviceStatusText)
            Text("Changes apply to future explicit requests only. Existing summaries, titles, and classifications are never regenerated automatically. Background titles and source processing always remain on-device.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Advanced") {
            DisclosureGroup("Per-action provider overrides", isExpanded: $showAdvancedOverrides) {
                ForEach(AIAction.configurableActions) { action in
                    Picker(selection: overrideBinding(for: action)) {
                        Text("Use Default (\(preferences.settings.defaultProvider.displayName))")
                            .tag(AIProviderPreference.inheritDefault)
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.displayName).tag(AIProviderPreference.specific(provider))
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.displayName)
                            Text(detail(for: action)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .pickerStyle(.menu)
                    if let explanation = capabilityExplanation(for: action) {
                        Label(explanation, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Reset Overrides") { preferences.resetOverrides() }
                        .disabled(!hasOverrides)
                }
                Text("Content enrichment generates the summary and LCC classification together. Noema never switches providers automatically when an override is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if hasOverrides {
                showAdvancedOverrides = true
            }
        }
        Section("AI Activity") {
            LabeledContent("Activity History") {
                Button("AI Activity…") {
                    openActivityHistory()
                }
                .sheet(isPresented: $localShowingActivity) {
                    AIActivityHistoryView(model: appModel)
                }
            }
            Text("Inspect local technical metadata, token usage, and retention settings for past AI operations.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var onDeviceStatusText: String {
        if let appModel {
            return appModel.aiClient.unavailabilityReason() ?? "Available"
        }
        return OnDeviceSummary.unavailabilityReason ?? "Available"
    }

    private func openActivityHistory() {
        if let showingActivity {
            showingActivity.wrappedValue = true
        } else {
            localShowingActivity = true
        }
    }

    private var hasOverrides: Bool {
        preferences.settings.overrides.values.contains { preference in
            if case .specific = preference { return true }
            return false
        }
    }

    private func overrideBinding(for action: AIAction) -> Binding<AIProviderPreference> {
        Binding(
            get: { preferences.settings.overrides[action.preferenceAction] ?? .inheritDefault },
            set: { preferences.setOverride($0, for: action) }
        )
    }

    private func capabilityExplanation(for action: AIAction) -> String? {
        let provider = preferences.settings.preferredProvider(for: action)
        return switch AIProviderCapabilities.capability(for: action, provider: provider).support {
        case .supported: nil
        case .unsupported: AIProviderUnavailableReason.unsupportedAction.errorMessage
        case .unauthorized: AIProviderUnavailableReason.unauthorizedAction.errorMessage
        case .future: AIProviderUnavailableReason.futureAction.errorMessage
        }
    }

    private func detail(for action: AIAction) -> String {
        switch action {
        case .summarizePage: "Generate or refresh a summary and its LCC classification together."
        case .summarizeSource: "Generate a source summary and classification together."
        case .suggestTitle: "Suggest a descriptive page or source title."
        case .classifyLCC: "Classify the selected page or source."
        case .processSource: "Process source content or draft a linked page."
        case .composePage: "Create a reviewable page from a source, topic or URL."
        }
    }
}
